import Foundation
import Vision
import CoreML
import AppKit

// --- Global Logger ---
class Logger {
    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)][Swift] \(message)")
        fflush(stdout)
    }
}

// --- Configuration Loader ---
struct AppConfig {
    let saveDirectory: URL
    let targetObjects: [String]
    let confidenceThreshold: Float
    let snapshotOnDetection: Bool
    let notificationCooldown: TimeInterval
    let socketPath = "/tmp/aicam.sock"

    init?() {
        Logger.log("Loading configuration...")
        let configPath = FileManager.default.currentDirectoryPath + "/config.env"
        guard let configContents = try? String(contentsOfFile: configPath) else { 
            Logger.log("Error: config.env not found")
            return nil 
        }
        
        var configDict = [String: String]()
        configContents.split(whereSeparator: \.isNewline).forEach { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.starts(with: "#") || trimmed.isEmpty { return }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                configDict[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .init(charactersIn: "\" "))
            }
        }
        
        self.saveDirectory = URL(fileURLWithPath: configDict["SNAPSHOT_DIRECTORY"] ?? "Captures")
        self.targetObjects = (configDict["OBJECTS_TO_MONITOR"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        self.confidenceThreshold = Float(configDict["DETECTION_THRESHOLD"] ?? "0.4") ?? 0.4
        self.snapshotOnDetection = (configDict["SNAPSHOT_ON_DETECTION"] ?? "true").lowercased() == "true"
        self.notificationCooldown = TimeInterval(configDict["NOTIFICATION_COOLDOWN"] ?? "10") ?? 10
        Logger.log("Configuration loaded. Target objects: \(targetObjects.isEmpty ? "ALL" : targetObjects.joined(separator: ", "))")
    }
}

// --- AI Model Manager ---
class AIModelManager {
    private let model: VNCoreMLModel
    
    init?() {
        Logger.log("Initializing AI Model Manager...")
        let modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc") ??
            URL(fileURLWithPath: "\(FileManager.default.currentDirectoryPath)/src/AICamMonitor/Resources/yolov8n.mlmodelc")
        
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            Logger.log("Error: Compiled model not found at \(modelURL.path). Run ./install.sh first")
            return nil
        }
        
        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            self.model = try VNCoreMLModel(for: mlModel)
            Logger.log("AI Model loaded successfully from \(modelURL.lastPathComponent)")
        } catch {
            Logger.log("Error loading AI model: \(error)")
            return nil
        }
    }

    func performDetection(on buffer: CVImageBuffer, completion: @escaping ([(label: String, confidence: Float, box: CGRect)]) -> Void) {
        let request = VNCoreMLRequest(model: model) { (request, error) in
            if let error = error {
                Logger.log("Detection error: \(error)")
                completion([])
                return
            }
            
            guard let results = request.results as? [VNRecognizedObjectObservation] else {
                completion([])
                return
            }
            
            let detections = results.compactMap { observation -> (label: String, confidence: Float, box: CGRect)? in
                guard let topLabel = observation.labels.first else { return nil }
                return (topLabel.identifier, observation.confidence, observation.boundingBox)
            }
            completion(detections)
        }
        
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        } catch {
            Logger.log("Error performing detection: \(error)")
            completion([])
        }
    }
}

// --- Frame Processor ---
class FrameProcessor {
    private let config: AppConfig
    private let modelManager: AIModelManager
    private var lastSnapshotTime = Date(timeIntervalSince1970: 0)
    private var frameCount = 0

    init(config: AppConfig, modelManager: AIModelManager) {
        self.config = config
        self.modelManager = modelManager
    }

    func processFrame(data: Data) {
        self.frameCount += 1
        
        // Log every 10th frame to avoid spam
        if frameCount % 10 == 1 {
            Logger.log("Processing frame #\(self.frameCount), size: \(data.count) bytes")
        }

        guard let image = NSImage(data: data), 
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Logger.log("Warning: Could not decode JPEG data for frame #\(self.frameCount)")
            return
        }

        guard let pixelBuffer = createPixelBufferFromCGImage(cgImage) else {
            Logger.log("Warning: Failed to create pixel buffer for frame #\(self.frameCount)")
            return
        }

        modelManager.performDetection(on: pixelBuffer) { [weak self] detections in
            guard let self = self else { return }
            
            let filtered = detections.filter { detection in
                let confidenceOk = detection.confidence >= self.config.confidenceThreshold
                let objectOk = self.config.targetObjects.isEmpty || self.config.targetObjects.contains(detection.label)
                return confidenceOk && objectOk
            }
            
            if !filtered.isEmpty {
                DispatchQueue.main.async {
                    self.handleDetection(detections: filtered, frame: pixelBuffer, originalData: data)
                }
            }
        }
    }
    
    private func handleDetection(detections: [(label: String, confidence: Float, box: CGRect)], frame: CVImageBuffer, originalData: Data) {
        let now = Date()
        if now.timeIntervalSince(lastSnapshotTime) < config.notificationCooldown { 
            return 
        }
        lastSnapshotTime = now
        
        let labels = detections.map { "\($0.label) (\(Int($0.confidence * 100))%)" }.joined(separator: ", ")
        Logger.log("🎯 DETECTION: \(labels)")

        if config.snapshotOnDetection {
            saveSnapshot(detections: detections, frame: frame, timestamp: now)
        }
    }
    
    private func saveSnapshot(detections: [(label: String, confidence: Float, box: CGRect)], frame: CVImageBuffer, timestamp: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateString = formatter.string(from: timestamp)
        
        let primaryObject = detections.first?.label ?? "detection"
        let fileName = "\(dateString)_\(primaryObject).jpg"
        let saveURL = config.saveDirectory.appendingPathComponent(fileName)
        
        if saveFrameAsJPEG(pixelBuffer: frame, at: saveURL) {
            Logger.log("📸 Snapshot saved: \(fileName)")
        } else {
            Logger.log("❌ Failed to save snapshot: \(fileName)")
        }
    }

    private func createPixelBufferFromCGImage(_ cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        var pixelBuffer: CVPixelBuffer?
        
        let options: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, options as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { 
            Logger.log("Error: Failed to create pixel buffer (status: \(status))")
            return nil 
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            Logger.log("Error: Failed to create CGContext for pixel buffer")
            return nil
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func saveFrameAsJPEG(pixelBuffer: CVPixelBuffer, at url: URL) -> Bool {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            Logger.log("Error: Could not create CGImage from pixel buffer")
            return false
        }
        
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            Logger.log("Error: Could not create image destination for \(url.path)")
            return false
        }
        
        // Set JPEG quality
        let properties: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.9]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        
        return CGImageDestinationFinalize(destination)
    }
}

// --- Socket Connection Manager ---
class SocketManager {
    private let socketPath: String
    private var clientSocket: Int32 = -1
    private var isConnected = false
    
    init(socketPath: String) {
        self.socketPath = socketPath
    }
    
    func connect() -> Bool {
        if isConnected {
            return true
        }
        
        Logger.log("Attempting to connect to Python server at \(socketPath)...")
        
        // Wait for the socket file to be created by the Python server
        var attempts = 0
        while !FileManager.default.fileExists(atPath: socketPath) && attempts < 30 {
            if attempts == 0 {
                Logger.log("Waiting for Python server to create socket...")
            }
            usleep(500_000) // 0.5 seconds
            attempts += 1
        }
        
        if !FileManager.default.fileExists(atPath: socketPath) {
            Logger.log("Error: Socket file not found after waiting. Is the Python server running?")
            return false
        }
        
        clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientSocket != -1 else {
            Logger.log("Error creating socket: \(String(cString: strerror(errno)))")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            strncpy(ptr, socketPath, Int(MemoryLayout.size(ofValue: addr.sun_path)))
        }

        let status = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(clientSocket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard status == 0 else {
            Logger.log("Error connecting to socket: \(String(cString: strerror(errno)))")
            close(clientSocket)
            clientSocket = -1
            return false
        }

        Logger.log("Successfully connected to Python server")
        isConnected = true
        return true
    }
    
    func readFrameData() -> Data? {
        guard isConnected && clientSocket != -1 else { return nil }
        
        // Read the 4-byte size header (little-endian)
        var sizeBuffer: UInt32 = 0
        let bytesReadSize = withUnsafeMutableBytes(of: &sizeBuffer) { ptr in
            read(clientSocket, ptr.baseAddress, MemoryLayout<UInt32>.size)
        }
        
        guard bytesReadSize == MemoryLayout<UInt32>.size else {
            if bytesReadSize == 0 {
                Logger.log("Server disconnected gracefully")
            } else {
                Logger.log("Error reading size header: \(bytesReadSize) bytes read")
            }
            disconnect()
            return nil
        }
        
        // Convert from little-endian if needed
        let frameSize = Int(sizeBuffer.littleEndian)
        
        // Sanity check frame size
        guard frameSize > 0 && frameSize < 10_000_000 else { // Max 10MB frame
            Logger.log("Invalid frame size received: \(frameSize)")
            disconnect()
            return nil
        }
        
        // Read the full frame data
        var frameBuffer = Data(count: frameSize)
        var totalBytesRead = 0
        
        while totalBytesRead < frameSize {
            let bytesRead = frameBuffer.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Int in
                read(clientSocket, ptr.baseAddress! + totalBytesRead, frameSize - totalBytesRead)
            }
            
            guard bytesRead > 0 else {
                Logger.log("Error reading frame data: connection lost")
                disconnect()
                return nil
            }
            
            totalBytesRead += bytesRead
        }
        
        return frameBuffer
    }
    
    func disconnect() {
        if clientSocket != -1 {
            close(clientSocket)
            clientSocket = -1
        }
        isConnected = false
    }
    
    deinit {
        disconnect()
    }
}

// --- Main Application ---
class Application {
    private let config: AppConfig
    private let frameProcessor: FrameProcessor
    private let socketManager: SocketManager
    private var isRunning = false

    init?() {
        Logger.log("Initializing AI Cam Monitor application...")
        
        guard let config = AppConfig() else {
            Logger.log("Error: Failed to load configuration")
            return nil
        }
        
        guard let modelManager = AIModelManager() else {
            Logger.log("Error: Failed to initialize AI model")
            return nil
        }
        
        self.config = config
        self.socketManager = SocketManager(socketPath: config.socketPath)
        self.frameProcessor = FrameProcessor(config: config, modelManager: modelManager)
        
        // Create save directory if needed
        do {
            try FileManager.default.createDirectory(at: config.saveDirectory, withIntermediateDirectories: true)
            Logger.log("Save directory ready: \(config.saveDirectory.path)")
        } catch {
            Logger.log("Warning: Could not create save directory: \(error)")
        }
        
        Logger.log("Initialization complete")
    }

    func run() {
        Logger.log("AI Cam Monitor starting up...")
        isRunning = true
        
        // Set up signal handling
        signal(SIGINT) { _ in
            Logger.log("Received interrupt signal, shutting down...")
            exit(0)
        }
        
        // Start the main processing loop on a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            self.processingLoop()
        }
        
        // Keep the main thread alive
        RunLoop.main.run()
    }
    
    private func processingLoop() {
        while isRunning {
            // Try to connect
            guard socketManager.connect() else {
                Logger.log("Failed to connect, retrying in 5 seconds...")
                sleep(5)
                continue
            }
            
            // Process frames
            while isRunning {
                guard let frameData = socketManager.readFrameData() else {
                    Logger.log("Lost connection to server, attempting reconnection...")
                    break
                }
                
                frameProcessor.processFrame(data: frameData)
            }
            
            socketManager.disconnect()
            if isRunning {
                Logger.log("Reconnecting in 2 seconds...")
                sleep(2)
            }
        }
    }
    
    func stop() {
        isRunning = false
        socketManager.disconnect()
    }
}

// --- Entry Point ---
Logger.log("Starting AI Cam Monitor...")

guard let app = Application() else {
    Logger.log("FATAL: Application failed to initialize")
    exit(1)
}

// Set up cleanup on exit
atexit {
    Logger.log("Application shutting down...")
}

app.run()