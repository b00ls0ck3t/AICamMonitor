import Foundation
import Vision
import CoreML
import AppKit
import Security

// --- Global Logger ---
class Logger {
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func log(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        print("[\(timestamp)] \(message)")
        fflush(stdout)
    }
}

// --- Keychain Access ---
func getPasswordFromKeychain(service: String, account: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: kCFBooleanTrue!,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
        Logger.log("Keychain access error: Status code \(status)")
        return nil
    }
    return String(data: data, encoding: .utf8)
}

// --- Utility: Find Executable ---
func findExecutable(named name: String) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    task.arguments = [name]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return path?.isEmpty == false ? path : nil
}


// --- Configuration Loader ---
struct AppConfig {
    let finalRTSP_URL: String
    let saveDirectory: URL
    let targetObjects: [String]
    let confidenceThreshold: Float
    let snapshotOnDetection: Bool
    let notificationCooldown: TimeInterval
    let debugTakeSnapshot: Bool

    init?() {
        Logger.log("Loading configuration from config.env...")
        let configPath = FileManager.default.currentDirectoryPath + "/config.env"
        guard FileManager.default.fileExists(atPath: configPath) else {
            Logger.log("Error: config.env not found. Please create it in the project root directory.")
            return nil
        }
        guard let configContents = try? String(contentsOfFile: configPath) else {
            Logger.log("Error: Could not read config.env.")
            return nil
        }

        var configDict = [String: String]()
        for line in configContents.split(whereSeparator: \.isNewline) {
            if line.starts(with: "#") || line.isEmpty { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                configDict[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .init(charactersIn: "\" "))
            }
        }

        Logger.log("Configuration loaded successfully from config.env.")

        guard let urlTemplate = configDict["RTSP_FEED_URL"], !urlTemplate.isEmpty, urlTemplate.starts(with: "rtsp://") else {
            Logger.log("Error: RTSP_FEED_URL is missing, a placeholder, or invalid in config.env.")
            return nil
        }
        
        guard let username = configDict["CAM_USERNAME"], !username.isEmpty else {
            Logger.log("Error: CAM_USERNAME is not set in config.env.")
            return nil
        }

        Logger.log("Retrieving camera credentials from Keychain for user '\(username)'...")
        guard let password = getPasswordFromKeychain(service: "AICamMonitor", account: username) else {
            Logger.log("Error: Could not retrieve password for user '\(username)' from Keychain.")
            Logger.log("Please run ./install.sh to set the password securely.")
            return nil
        }
        
        Logger.log("Successfully retrieved credentials for user '\(username)' from Keychain.")
        
        guard var components = URLComponents(string: urlTemplate) else {
            Logger.log("Error: The RTSP_FEED_URL '\(urlTemplate)' is not a valid URL.")
            return nil
        }
        components.user = username
        components.password = password
        
        guard let finalURL = components.url?.absoluteString else {
            Logger.log("Error: Failed to construct final authenticated RTSP URL.")
            return nil
        }
        self.finalRTSP_URL = finalURL
        Logger.log("RTSP URL constructed successfully.")

        self.saveDirectory = URL(fileURLWithPath: configDict["SNAPSHOT_DIRECTORY"] ?? "Captures")
        self.targetObjects = (configDict["OBJECTS_TO_MONITOR"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        self.confidenceThreshold = Float(configDict["DETECTION_THRESHOLD"] ?? "0.4") ?? 0.4
        self.snapshotOnDetection = (configDict["SNAPSHOT_ON_DETECTION"] ?? "true").lowercased() == "true"
        self.notificationCooldown = TimeInterval(configDict["NOTIFICATION_COOLDOWN"] ?? "10") ?? 10
        self.debugTakeSnapshot = (configDict["DEBUG_TAKE_SNAPSHOT"] ?? "false").lowercased() == "true"
    }
}

// --- AI Model Manager ---
class AIModelManager {
    private let model: VNCoreMLModel

    init?() {
        Logger.log("Initializing AI Model Manager...")
        let modelURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("src/AICamMonitor/Resources/yolov8n.mlmodelc")
        Logger.log("Looking for compiled model at: \(modelURL.path)")
        
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            Logger.log("Error: Compiled model 'yolov8n.mlmodelc' not found at \(modelURL.path). Please run ./install.sh")
            return nil
        }
        
        Logger.log("Found model file. Loading CoreML model...")
        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            self.model = try VNCoreMLModel(for: mlModel)
            Logger.log("AI Model loaded successfully and ready for inference.")
        } catch {
            Logger.log("Error: Failed to load AI model: \(error)")
            return nil
        }
    }

    func performDetection(on buffer: CVImageBuffer, block: @escaping ([(label: String, confidence: Float, box: CGRect)]) -> Void) {
        let request = VNCoreMLRequest(model: model) { (request, error) in
            if let error = error { Logger.log("Vision request error: \(error.localizedDescription)"); block([]); return }
            guard let results = request.results as? [VNRecognizedObjectObservation] else { block([]); return }
            block(results.map { ($0.labels.first?.identifier ?? "unknown", $0.confidence, $0.boundingBox) })
        }
        try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
    }
}

// --- RTSP Stream Reader with Failsafe ---
class RTSPStreamReader {
    private var process: Process?
    private let rtspURL: String
    private let onFrameData: (Data) -> Void
    private var isRestarting = false
    private var connectionAttempts = 0
    
    init(rtspURL: String, onFrameData: @escaping (Data) -> Void) {
        self.rtspURL = rtspURL
        self.onFrameData = onFrameData
    }

    func start() {
        guard !isRestarting else { return }
        
        connectionAttempts += 1
        Logger.log("Connection attempt #\(connectionAttempts): Starting RTSP stream reader...")
        
        guard let ffmpegPath = findExecutable(named: "ffmpeg") else {
            Logger.log("FATAL: 'ffmpeg' executable not found in shell PATH. Please run ./install.sh.")
            exit(1)
        }
        
        Logger.log("Found ffmpeg at: \(ffmpegPath)")
        Logger.log("Attempting to connect to RTSP stream...")
        
        let stdErrPipe = Pipe()
        process = Process()
        process?.executableURL = URL(fileURLWithPath: ffmpegPath)
        process?.arguments = [
            "-v", "verbose",
            "-i", rtspURL,
            "-pix_fmt", "bgr24",
            "-f", "rawvideo",
            "-an",
            "-"
        ]
        
        let stdOutPipe = Pipe()
        process?.standardOutput = stdOutPipe
        process?.standardError = stdErrPipe
        
        stdOutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.onFrameData(handle.availableData) }
        
        stdErrPipe.fileHandleForReading.readabilityHandler = { handle in
            if let errorString = String(data: handle.availableData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !errorString.isEmpty {
                 Logger.log("ffmpeg: \(errorString)")
            }
        }
        
        process?.terminationHandler = { [weak self] process in
            guard let self = self, !self.isRestarting else { return }
            Logger.log("Error: ffmpeg process terminated unexpectedly (Code: \(process.terminationStatus)).")
            self.isRestarting = true
            Logger.log("Stream connection lost. Attempting to reconnect in 15 seconds...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                self.isRestarting = false
                self.start()
            }
        }
        
        do {
            try process?.run()
            Logger.log("ffmpeg process started successfully. Waiting for video data...")
        } catch {
            Logger.log("Error: Failed to start ffmpeg process: \(error.localizedDescription)")
        }
    }

    func stop() {
        Logger.log("Stopping RTSP stream reader...")
        isRestarting = true
        process?.terminate()
    }
}

// --- Main Application ---
class Application {
    let config: AppConfig
    private let modelManager: AIModelManager
    private var frameDataBuffer = Data()
    private var hasReceivedFrame = false
    private let frameWidth: Int
    private let frameHeight: Int
    private var lastSnapshotTime = Date(timeIntervalSince1970: 0)
    private var frameCount = 0
    private var lastHeartbeat = Date()
    
    private lazy var streamReader: RTSPStreamReader = {
        return RTSPStreamReader(rtspURL: self.config.finalRTSP_URL, onFrameData: { [weak self] data in self?.processFrameData(data) })
    }()

    init?() {
        Logger.log("Initializing AI Cam Monitor application...")
        
        guard let config = AppConfig() else { Logger.log("Failed to load configuration."); return nil }
        self.config = config
        
        if config.debugTakeSnapshot {
            Application.runDebugSnapshot(config: config)
            return nil
        }
        
        guard let resolution = Application.runStreamProbe(config: config) else { Logger.log("Stream probe failed. Aborting startup."); return nil }
        
        guard let modelManager = AIModelManager() else { Logger.log("Failed to initialize AI model."); return nil }

        self.modelManager = modelManager
        self.frameWidth = resolution.width
        self.frameHeight = resolution.height
        
        Logger.log("Creating snapshot directory: \(config.saveDirectory.path)")
        do {
            try FileManager.default.createDirectory(at: config.saveDirectory, withIntermediateDirectories: true)
            Logger.log("Snapshot directory ready.")
        } catch {
            Logger.log("Warning: Could not create snapshot directory: \(error)")
        }
        
        Logger.log("Application initialization completed successfully.")
    }

    private static func runStreamProbe(config: AppConfig) -> (width: Int, height: Int)? {
        Logger.log("--- Starting Stream Pre-flight Check ---")
        guard let ffprobePath = findExecutable(named: "ffprobe") else {
            Logger.log("FATAL: 'ffprobe' not found. Please reinstall via Homebrew or run ./install.sh")
            return nil
        }
        Logger.log("Probing stream with ffprobe at \(ffprobePath)...")
        
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=width,height",
            "-of", "csv=p=0",
            "-timeout", "5000000",
            config.finalRTSP_URL
        ]
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Logger.log("Stream Probe Error: \(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
                Logger.log("Please check your RTSP_FEED_URL, credentials in Keychain, and network connection.")
                return nil
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let res = output, !res.isEmpty, res.contains(",") {
                Logger.log("Stream Probe Success! Detected resolution: \(res)")
                Logger.log("--- Stream Pre-flight Check Passed ---")
                let parts = res.split(separator: ",").compactMap { Int($0) }
                if parts.count == 2 {
                    return (width: parts[0], height: parts[1])
                }
            }
            
            Logger.log("Stream Probe Failed: Could not get stream information. The URL may be incorrect or the camera unreachable.")
            return nil
            
        } catch {
            Logger.log("Stream Probe Failed: Could not run ffprobe process. Error: \(error)")
            return nil
        }
    }

    private static func runDebugSnapshot(config: AppConfig) {
        Logger.log("--- Running in Debug Snapshot Mode ---")
        guard let ffmpegPath = findExecutable(named: "ffmpeg") else {
            Logger.log("FATAL: 'ffmpeg' not found.")
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let saveURL = config.saveDirectory.appendingPathComponent("debug_snapshot_\(timestamp).jpg")

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-i", config.finalRTSP_URL,
            "-vframes", "1",
            "-q:v", "2",
            saveURL.path
        ]
        process.standardError = errorPipe
        
        Logger.log("Executing command: \(ffmpegPath) \(process.arguments!.joined(separator: " "))")

        do {
            try process.run()
            
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Logger.log("ffmpeg Debug Output:\n--- START ---\n\(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))\n--- END ---")
            }
            
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                Logger.log("Debug snapshot saved successfully to: \(saveURL.path)")
            } else {
                Logger.log("Debug snapshot failed. Check ffmpeg output above for errors.")
            }
        } catch {
            Logger.log("Error: Failed to run ffmpeg for debug snapshot: \(error)")
        }
    }


    func run() {
        Logger.log("AI Cam Monitor starting up...")
        Logger.log("========================================")
        if let url = URL(string: config.finalRTSP_URL) {
            let sanitizedURL = "rtsp://\(url.host ?? "unknown")\(url.path)"
            Logger.log("Monitoring URL: \(sanitizedURL)")
        }
        Logger.log("Target Objects: \(config.targetObjects.isEmpty ? "any" : config.targetObjects.joined(separator: ", "))")
        Logger.log("Confidence Threshold: \(Int(config.confidenceThreshold * 100))%")
        Logger.log("Save Snapshots: \(config.snapshotOnDetection)")
        Logger.log("Notification Cooldown: \(config.notificationCooldown) seconds")
        Logger.log("Snapshot Directory: \(config.saveDirectory.path)")
        Logger.log("========================================")

        streamReader.start()
        
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.hasReceivedFrame { Logger.log("Heartbeat: Application running normally. Frames processed: \(self.frameCount)") } 
            else { Logger.log("Heartbeat: Waiting for video stream connection...") }
        }
        
        Logger.log("Application is now running. Press Ctrl+C to stop.")
        RunLoop.main.run()
    }
    
    private func processFrameData(_ data: Data) {
        if !hasReceivedFrame {
            Logger.log("SUCCESS: Video stream connected! Receiving frame data from camera.")
            hasReceivedFrame = true
        }
        
        Logger.log("Received \(data.count) bytes from stream.")
        frameDataBuffer.append(data)
        let frameSize = frameWidth * frameHeight * 3
        
        while frameDataBuffer.count >= frameSize {
            let frameData = frameDataBuffer.prefix(frameSize)
            frameDataBuffer.removeFirst(frameSize)
            frameCount += 1
            
            if frameCount % 100 == 0 { Logger.log("Processing: Frame #\(frameCount) received and analyzed.") }
            guard let frameBuffer = createPixelBuffer(from: frameData, width: frameWidth, height: frameHeight) else { continue }
            
            modelManager.performDetection(on: frameBuffer) { [weak self] detections in
                guard let self = self else { return }
                let filtered = detections.filter { ($0.label != "unknown") && ($0.confidence >= self.config.confidenceThreshold) && (self.config.targetObjects.isEmpty || self.config.targetObjects.contains($0.label)) }
                if !filtered.isEmpty { self.handleDetection(detections: filtered, frame: frameBuffer) }
            }
        }
    }
    
    private func handleDetection(detections: [(label: String, confidence: Float, box: CGRect)], frame: CVImageBuffer) {
        let now = Date()
        if now.timeIntervalSince(lastSnapshotTime) < config.notificationCooldown { return }
        lastSnapshotTime = now
        
        let labels = detections.map { "\($0.label) (\(Int($0.confidence * 100))%)" }.joined(separator: ", ")
        Logger.log("Detection: \(labels) at frame #\(frameCount)")

        if config.snapshotOnDetection {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate, .withTime, .withColonSeparatorInTime]
            let dateString = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
            
            let fileName = "\(dateString)_\(detections.first!.label).jpg"
            let saveURL = config.saveDirectory.appendingPathComponent(fileName)
            saveFrameAsJPEG(pixelBuffer: frame, at: saveURL)
        }
    }

    private func createPixelBuffer(from data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        var mutableData = data
        let status = mutableData.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> CVReturn in
            let options: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
            return CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height, kCVPixelFormatType_24BGR, bytes.baseAddress!, width * 3, nil, nil, options as CFDictionary, &pixelBuffer)
        }
        return status == kCVReturnSuccess ? pixelBuffer : nil
    }

    private func saveFrameAsJPEG(pixelBuffer: CVPixelBuffer, at url: URL) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            Logger.log("Error: Failed to create image for saving."); return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        if !CGImageDestinationFinalize(destination) { Logger.log("Error: Failed to save image to \(url.path)") } 
        else { Logger.log("Snapshot saved: \(url.lastPathComponent)") }
    }
}

// --- Entry Point ---
Logger.log("Starting AI Cam Monitor...")
guard let app = Application() else {
    Logger.log("FATAL: Application failed to initialize. Review logs for details.")
    exit(1)
}
if app.config.debugTakeSnapshot == false {
    app.run()
}
