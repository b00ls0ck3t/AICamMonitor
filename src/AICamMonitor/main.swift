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
        guard let configContents = try? String(contentsOfFile: configPath) else { return nil }
        var configDict = [String: String]()
        configContents.split(whereSeparator: \.isNewline).forEach { line in
            if line.starts(with: "#") || line.isEmpty { return }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                configDict[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .init(charactersIn: "\" "))
            }
        }
        self.saveDirectory = URL(fileURLWithPath: configDict["SNAPSHOT_DIRECTORY"] ?? "Captures")
        self.targetObjects = (configDict["OBJECTS_TO_MONITOR"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        self.confidenceThreshold = Float(configDict["DETECTION_THRESHOLD"] ?? "0.4") ?? 0.4
        self.snapshotOnDetection = (configDict["SNAPSHOT_ON_DETECTION"] ?? "true").lowercased() == "true"
        self.notificationCooldown = TimeInterval(configDict["NOTIFICATION_COOLDOWN"] ?? "10") ?? 10
        Logger.log("Configuration loaded.")
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
            Logger.log("Error: Compiled model not found at \(modelURL.path). Run ./install.sh")
            return nil
        }
        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            self.model = try VNCoreMLModel(for: mlModel)
            Logger.log("AI Model loaded successfully.")
        } catch {
            Logger.log("Error loading AI model: \(error)")
            return nil
        }
    }

    func performDetection(on buffer: CVImageBuffer, completion: @escaping ([(label: String, confidence: Float, box: CGRect)]) -> Void) {
        let request = VNCoreMLRequest(model: model) { (request, error) in
            guard let results = request.results as? [VNRecognizedObjectObservation], error == nil else {
                completion([])
                return
            }
            completion(results.map { ($0.labels.first?.identifier ?? "unknown", $0.confidence, $0.boundingBox) })
        }
        try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
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
        Logger.log("Processing frame #\(self.frameCount), size: \(data.count) bytes")

        guard let image = NSImage(data: data), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Logger.log("Warning: Could not decode JPEG data for frame #\(self.frameCount).")
            return
        }

        guard let pixelBuffer = createPixelBufferFromCGImage(cgImage) else {
            Logger.log("Warning: Failed to create pixel buffer for frame #\(self.frameCount).")
            return
        }

        modelManager.performDetection(on: pixelBuffer) { [weak self] detections in
            guard let self = self else { return }
            let filtered = detections.filter { $0.confidence >= self.config.confidenceThreshold && (self.config.targetObjects.isEmpty || self.config.targetObjects.contains($0.label)) }
            if !filtered.isEmpty {
                DispatchQueue.main.async { self.handleDetection(detections: filtered, frame: pixelBuffer) }
            }
        }
    }
    
    private func handleDetection(detections: [(label: String, confidence: Float, box: CGRect)], frame: CVImageBuffer) {
        let now = Date()
        if now.timeIntervalSince(lastSnapshotTime) < config.notificationCooldown { return }
        lastSnapshotTime = now
        let labels = detections.map { "\($0.label) (\(Int($0.confidence * 100))%)" }.joined(separator: ", ")
        Logger.log("🎯 DETECTION: \(labels)")

        if config.snapshotOnDetection {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate, .withTime, .withColonSeparatorInTime]
            let dateString = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
            let fileName = "\(dateString)_\(detections.first!.label).jpg"
            let saveURL = config.saveDirectory.appendingPathComponent(fileName)
            saveFrameAsJPEG(pixelBuffer: frame, at: saveURL)
        }
    }

    private func createPixelBufferFromCGImage(_ cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        var pixelBuffer: CVPixelBuffer?
        let options: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, options as CFDictionary, &pixelBuffer) == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func saveFrameAsJPEG(pixelBuffer: CVPixelBuffer, at url: URL) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cgImage, nil)
        if !CGImageDestinationFinalize(destination) { Logger.log("Error saving snapshot to \(url.path)") }
        else { Logger.log("📸 Snapshot saved: \(url.lastPathComponent)") }
    }
}

// --- Main Application ---
class Application {
    private let config: AppConfig
    private let frameProcessor: FrameProcessor
    private var clientSocket: Int32 = -1
    private let socketPath: String

    init?() {
        Logger.log("Initializing AI Cam Monitor application...")
        guard let config = AppConfig(), let modelManager = AIModelManager() else { return nil }
        self.config = config
        self.socketPath = config.socketPath
        self.frameProcessor = FrameProcessor(config: config, modelManager: modelManager)
        try? FileManager.default.createDirectory(at: config.saveDirectory, withIntermediateDirectories: true)
        Logger.log("Initialization complete.")
    }

    func run() {
        Logger.log("AI Cam Monitor starting up...")
        connectAndListen()
        RunLoop.main.run()
    }

    private func connectAndListen() {
        Logger.log("Attempting to connect to Python server at \(socketPath)...")
        
        // Wait for the socket file to be created by the Python server
        var attempts = 0
        while !FileManager.default.fileExists(atPath: socketPath) && attempts < 10 {
            Logger.log("Socket not found, waiting...")
            sleep(1)
            attempts += 1
        }
        
        clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientSocket != -1 else {
            Logger.log("Error creating socket: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            strncpy(ptr, socketPath, Int(MemoryLayout.size(ofValue: addr.sun_path)))
        }

        let status = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(clientSocket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard status == 0 else {
            Logger.log("Error connecting to socket: \(String(cString: strerror(errno))). Retrying in 5s.")
            close(clientSocket)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.connectAndListen() }
            return
        }

        Logger.log("Successfully connected to Python server.")
        
        // Listen for data on a background thread
        DispatchQueue.global(qos: .userInitiated).async {
            self.listenForFrames()
        }
    }
    
    private func listenForFrames() {
        while true {
            // Read the 4-byte size header
            let sizeBuffer = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
            defer { sizeBuffer.deallocate() }
            
            let bytesReadSize = read(clientSocket, sizeBuffer, MemoryLayout<UInt32>.size)
            guard bytesReadSize > 0 else {
                Logger.log("Server disconnected. Stopping listener.")
                break
            }
            
            let frameSize = Int(sizeBuffer.pointee)
            
            // Read the full frame data
            var frameBuffer = Data(count: frameSize)
            var totalBytesRead = 0
            while totalBytesRead < frameSize {
                let bytesRead = frameBuffer.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> Int in
                    read(clientSocket, ptr.baseAddress! + totalBytesRead, frameSize - totalBytesRead)
                }
                guard bytesRead > 0 else {
                    Logger.log("Error reading frame data or server disconnected.")
                    return
                }
                totalBytesRead += bytesRead
            }
            
            // Process the complete frame
            frameProcessor.processFrame(data: frameBuffer)
        }
        close(clientSocket)
    }
}

// --- Entry Point ---
Logger.log("Starting AI Cam Monitor...")
guard let app = Application() else {
    Logger.log("FATAL: Application failed to initialize.")
    exit(1)
}
app.run()

