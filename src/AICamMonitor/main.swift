import Foundation
import Vision
import CoreML
import AppKit
import CoreImage

// --- Global Logger ---
class Logger {
    private static let versionId: String = {
        // Try to get git commit hash
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["rev-parse", "--short", "HEAD"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // Suppress errors
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let hash = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !hash.isEmpty {
                    return hash
                }
            }
        } catch {
            // Git command failed, fall back to timestamp
        }
        
        // Fallback: use timestamp-based unique ID
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "v\(formatter.string(from: Date()))"
    }()
    
    static func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        print("[\(timestamp)][\(versionId)][Swift] \(message)")
        fflush(stdout)
    }
}

// --- Zone Configuration ---
struct SafeZone {
    let points: [CGPoint]
    let name: String
    
    func contains(point: CGPoint) -> Bool {
        return isPointInPolygon(point: point, polygon: points)
    }
    
    private func isPointInPolygon(point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        
        var inside = false
        var j = polygon.count - 1
        
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            
            if ((pi.y > point.y) != (pj.y > point.y)) &&
               (point.x < (pj.x - pi.x) * (point.y - pi.y) / (pj.y - pi.y) + pi.x) {
                inside.toggle()
            }
            j = i
        }
        
        return inside
    }
}

// --- Keychain Manager ---
class KeychainManager {
    private static let keychainService = "AICamMonitor"
    
    static func getPassword(for username: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let passwordData = result as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            Logger.log("Error: Could not retrieve password from Keychain for user: \(username)")
            Logger.log("Make sure you've run ./install.sh to set up the password")
            return nil
        }
        
        return password
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
    let safeZone: SafeZone?
    let frameWidth: Int
    let frameHeight: Int
    let rtspUrl: String
    let alertRecipients: [String]

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
        
        // Get camera credentials
        guard let baseUrl = configDict["RTSP_FEED_URL"],
              let username = configDict["CAM_USERNAME"],
              let password = KeychainManager.getPassword(for: username) else {
            Logger.log("Error: Missing camera configuration or password")
            return nil
        }
        
        // Build authenticated RTSP URL
        self.rtspUrl = baseUrl.replacingOccurrences(of: "rtsp://", with: "rtsp://\(username):\(password)@")
        
        self.saveDirectory = URL(fileURLWithPath: configDict["SNAPSHOT_DIRECTORY"] ?? "BabyCaptures")
        self.targetObjects = (configDict["OBJECTS_TO_MONITOR"] ?? "person").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        self.confidenceThreshold = Float(configDict["DETECTION_THRESHOLD"] ?? "0.3") ?? 0.3
        self.snapshotOnDetection = (configDict["SNAPSHOT_ON_DETECTION"] ?? "true").lowercased() == "true"
        self.notificationCooldown = TimeInterval(configDict["NOTIFICATION_COOLDOWN"] ?? "30") ?? 30
        self.frameWidth = Int(configDict["FRAME_WIDTH"] ?? "1920") ?? 1920
        self.frameHeight = Int(configDict["FRAME_HEIGHT"] ?? "1080") ?? 1080
        
        // Load alert recipients
        self.alertRecipients = [
            configDict["ALERT_RECIPIENT_1"],
            configDict["ALERT_RECIPIENT_2"]
        ].compactMap { $0 }.filter { !$0.isEmpty }
        
        // Load safe zone configuration
        self.safeZone = Self.loadSafeZone()
        
        Logger.log("Configuration loaded. Target objects: \(targetObjects.joined(separator: ", "))")
        Logger.log("Alert recipients: \(alertRecipients.count) configured")
        if let zone = safeZone {
            Logger.log("Safe zone loaded: \(zone.name) with \(zone.points.count) points")
        } else {
            Logger.log("⚠️  No safe zone configured - run 'python3 calibrate_zone.py' first")
        }
    }
    
    private static func loadSafeZone() -> SafeZone? {
        let zonePath = FileManager.default.currentDirectoryPath + "/zone_config.json"
        guard let zoneData = try? Data(contentsOf: URL(fileURLWithPath: zonePath)),
              let json = try? JSONSerialization.jsonObject(with: zoneData) as? [String: Any],
              let name = json["name"] as? String,
              let pointsArray = json["points"] as? [[String: Double]] else {
            return nil
        }
        
        let points = pointsArray.compactMap { point -> CGPoint? in
            guard let x = point["x"], let y = point["y"] else { return nil }
            return CGPoint(x: x, y: y)
        }
        
        guard points.count >= 3 else { return nil }
        return SafeZone(points: points, name: name)
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
        
        request.imageCropAndScaleOption = .scaleFill
        
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        } catch {
            Logger.log("Error performing detection: \(error)")
            completion([])
        }
    }
}

// --- Alert Manager ---
class AlertManager {
    private var lastAlertTime = Date(timeIntervalSince1970: 0)
    private let cooldownPeriod: TimeInterval
    private let alertRecipients: [String]
    
    init(cooldownPeriod: TimeInterval, alertRecipients: [String]) {
        self.cooldownPeriod = cooldownPeriod
        self.alertRecipients = alertRecipients
    }
    
    func sendZoneAlert(position: CGPoint, frameSize: CGSize) {
        let now = Date()
        guard now.timeIntervalSince(lastAlertTime) >= cooldownPeriod else {
            return // Still in cooldown
        }
        
        lastAlertTime = now
        
        let actualX = Int(position.x * frameSize.width)
        let actualY = Int(position.y * frameSize.height)
        let alertMessage = "🚨 BABY ALERT: Movement detected outside safe zone at position (\(actualX), \(actualY))"
        
        Logger.log(alertMessage)
        
        // Send system notification
        sendSystemNotification(title: "Baby Monitor Alert", message: "Baby moved outside safe zone")
        
        // Send iMessage alerts to configured recipients
        for recipient in alertRecipients {
            sendIMessageAlert(to: recipient, message: alertMessage)
        }
    }
    
    private func sendSystemNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    private func sendIMessageAlert(to recipient: String, message: String) {
        let scriptPath = "\(FileManager.default.currentDirectoryPath)/send_alert.scpt"
        
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            Logger.log("Warning: send_alert.scpt not found, skipping iMessage alert")
            return
        }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [scriptPath, message, recipient]
        
        do {
            try task.run()
            Logger.log("📱 iMessage alert sent to \(recipient)")
        } catch {
            Logger.log("Error sending iMessage alert: \(error)")
        }
    }
}

// --- Frame Processor ---
class FrameProcessor {
    private let config: AppConfig
    private let modelManager: AIModelManager
    private let alertManager: AlertManager
    private var lastSnapshotTime = Date(timeIntervalSince1970: 0)
    private var frameCount = 0

    init(config: AppConfig, modelManager: AIModelManager) {
        self.config = config
        self.modelManager = modelManager
        self.alertManager = AlertManager(cooldownPeriod: config.notificationCooldown, alertRecipients: config.alertRecipients)
    }

    func processFrame(data: Data) {
        self.frameCount += 1
        
        // Log every 20th frame to avoid spam
        if frameCount % 20 == 1 {
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
                    self.handleDetection(detections: filtered, frame: pixelBuffer, originalData: data, frameSize: cgImage.size)
                }
            }
        }
    }
    
    private func handleDetection(detections: [(label: String, confidence: Float, box: CGRect)], frame: CVImageBuffer, originalData: Data, frameSize: CGSize) {
        
        // Check zone violations for baby monitoring
        if let safeZone = config.safeZone {
            for detection in detections {
                // Calculate center point of detection (Vision uses normalized coordinates)
                let centerX = detection.box.midX
                let centerY = 1.0 - detection.box.midY // Flip Y coordinate (Vision uses bottom-left origin)
                let centerPoint = CGPoint(x: centerX, y: centerY)
                
                if !safeZone.contains(point: centerPoint) {
                    Logger.log("🚨 ZONE VIOLATION: \(detection.label) detected outside safe zone at (\(Int(centerX * frameSize.width)), \(Int(centerY * frameSize.height)))")
                    alertManager.sendZoneAlert(position: centerPoint, frameSize: frameSize)
                    
                    // Always save snapshot on zone violation
                    saveSnapshot(detections: detections, frame: frame, timestamp: Date(), reason: "zone_violation")
                    return // Don't process regular detections if we have a violation
                }
            }
        }
        
        // Regular detection handling
        let now = Date()
        if now.timeIntervalSince(lastSnapshotTime) < config.notificationCooldown { 
            return 
        }
        lastSnapshotTime = now
        
        let labels = detections.map { "\($0.label) (\(Int($0.confidence * 100))%)" }.joined(separator: ", ")
        Logger.log("👶 MOVEMENT: \(labels)")

        if config.snapshotOnDetection {
            saveSnapshot(detections: detections, frame: frame, timestamp: now, reason: "movement")
        }
    }
    
    private func saveSnapshot(detections: [(label: String, confidence: Float, box: CGRect)], frame: CVImageBuffer, timestamp: Date, reason: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateString = formatter.string(from: timestamp)
        
        let primaryObject = detections.first?.label ?? "detection"
        let fileName = "\(dateString)_\(reason)_\(primaryObject).jpg"
        let saveURL = config.saveDirectory.appendingPathComponent(fileName)
        
        if saveFrameAsJPEG(pixelBuffer: frame, at: saveURL) {
            Logger.log("📸 Snapshot saved: \(fileName)")
        } else {
            Logger.log("❌ Failed to save snapshot: \(fileName)")
        }
    }

    // --- Utility Functions ---
    
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
        
        let properties: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.9]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        
        return CGImageDestinationFinalize(destination)
    }
}

extension CGImage {
    var size: CGSize {
        return CGSize(width: width, height: height)
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
        while !FileManager.default.fileExists(atPath: socketPath) && attempts < 60 {
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

        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            strncpy(ptr, socketPath, sunPathSize - 1)
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
        
        let frameSize = Int(UInt32(littleEndian: sizeBuffer))
        
        guard frameSize > 0 && frameSize < 10_000_000 else {
            Logger.log("Invalid frame size received: \(frameSize)")
            disconnect()
            return nil
        }
        
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

// --- Signal Handler ---
class SignalHandler {
    private static var sources: [DispatchSourceSignal] = []
    
    static func setupSignalHandling(onSignal: @escaping () -> Void) {
        // Block the signals so they don't terminate the process immediately
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        
        // Set up dispatch sources for graceful handling
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        
        sigintSource.setEventHandler {
            Logger.log("Received SIGINT (Ctrl+C)")
            onSignal()
        }
        
        sigtermSource.setEventHandler {
            Logger.log("Received SIGTERM")
            onSignal()
        }
        
        sigintSource.resume()
        sigtermSource.resume()
        
        sources = [sigintSource, sigtermSource]
    }
}

// --- Main Application ---
class Application {
    private let config: AppConfig
    private let frameProcessor: FrameProcessor
    private let socketManager: SocketManager
    private var isRunning = true

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
        Logger.log("👶 Baby Monitor starting up...")
        
        // Set up signal handling
        SignalHandler.setupSignalHandling { [weak self] in
            self?.stop()
        }
        
        // Start processing on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            self.processingLoop()
        }
        
        // Keep main thread alive
        RunLoop.main.run()
    }
    
    private func processingLoop() {
        while isRunning {
            guard socketManager.connect() else {
                if !isRunning { break }
                Logger.log("Failed to connect, retrying in 5 seconds...")
                sleep(5)
                continue
            }
            
            Logger.log("✅ Connected to frame grabber - monitoring active")
            
            while isRunning {
                guard let frameData = socketManager.readFrameData() else {
                    if isRunning {
                       Logger.log("Lost connection to server, attempting reconnection...")
                    }
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
        
        Logger.log("Processing loop terminated")
        DispatchQueue.main.async {
            exit(0)
        }
    }
    
    func stop() {
        Logger.log("Stopping baby monitor...")
        isRunning = false
        socketManager.disconnect()
    }
}

// --- Entry Point ---
Logger.log("Starting Baby Monitor System...")

guard let app = Application() else {
    Logger.log("FATAL: Application failed to initialize")
    exit(1)
}

app.run()