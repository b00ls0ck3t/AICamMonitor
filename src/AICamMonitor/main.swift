import Foundation
import Vision
import CoreML
import AppKit
import Security
import LocalAuthentication

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
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
        Logger.log("Keychain access error: Status code \(status)")
        if status == -128 || status == -25293 {  // errSecUserCancel or errSecAuthFailed
            Logger.log("Keychain access requires user interaction. Please run: security unlock-keychain")
        }
        return nil
    }
    return String(data: data, encoding: .utf8)
}

// --- Configuration Loader ---
struct AppConfig {
    let finalRTSP_URL: String
    let saveDirectory: URL
    let targetObjects: [String]
    let confidenceThreshold: Float
    let snapshotOnDetection: Bool
    let notificationCooldown: TimeInterval
    let testCaptureOnStart: Bool

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
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .init(charactersIn: "\" "))
                configDict[key] = value
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

        let authenticatedURL = urlTemplate.replacingOccurrences(of: "rtsp://", with: "rtsp://\(username):\(password)@")
        self.finalRTSP_URL = authenticatedURL
        Logger.log("RTSP URL constructed successfully.")

        if let parsedURL = URL(string: authenticatedURL) {
            Logger.log("Final URL format: rtsp://\(username):***@\(parsedURL.host ?? "unknown"):\(parsedURL.port ?? 554)\(parsedURL.path)")
        }

        self.saveDirectory = URL(fileURLWithPath: configDict["SNAPSHOT_DIRECTORY"] ?? "Captures")
        self.targetObjects = (configDict["OBJECTS_TO_MONITOR"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        self.confidenceThreshold = Float(configDict["DETECTION_THRESHOLD"] ?? "0.4") ?? 0.4
        self.snapshotOnDetection = (configDict["SNAPSHOT_ON_DETECTION"] ?? "true").lowercased() == "true"
        self.notificationCooldown = TimeInterval(configDict["NOTIFICATION_COOLDOWN"] ?? "10") ?? 10
        self.testCaptureOnStart = (configDict["TEST_CAPTURE_ON_START"] ?? "true").lowercased() == "true"
    }
}

// --- AI Model Manager ---
class AIModelManager {
    private let model: VNCoreMLModel

    init?() {
        Logger.log("Initializing AI Model Manager...")
        
        // Look for the compiled model in the Resources directory
        guard let modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc") else {
            // Fallback to direct path if Bundle approach fails
            let fallbackURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("src/AICamMonitor/Resources/yolov8n.mlmodelc")
            
            Logger.log("Model not found in app bundle, trying fallback path: \(fallbackURL.path)")
            
            guard FileManager.default.fileExists(atPath: fallbackURL.path) else {
                Logger.log("Error: Compiled model 'yolov8n.mlmodelc' not found. Please run ./install.sh")
                return nil
            }
            
            Logger.log("Found model file at fallback location. Loading CoreML model...")
            do {
                let mlModel = try MLModel(contentsOf: fallbackURL)
                self.model = try VNCoreMLModel(for: mlModel)
                Logger.log("AI Model loaded successfully and ready for inference.")
                return
            } catch {
                Logger.log("Error: Failed to load AI model from fallback path: \(error)")
                return nil
            }
        }

        Logger.log("Found model file in bundle. Loading CoreML model...")
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
            if let error = error {
                Logger.log("Vision request error: \(error.localizedDescription)")
                block([])
                return
            }
            guard let results = request.results as? [VNRecognizedObjectObservation] else {
                block([])
                return
            }
            let detections = results.map { ($0.labels.first?.identifier ?? "unknown", $0.confidence, $0.boundingBox) }
            block(detections)
        }
        try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
    }
}

// --- External ffmpeg Stream Reader ---
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

    private func findExecutable(named name: String) -> String? {
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

        // Capture JPEG frames periodically instead of continuous raw video
        let outputPath = "/tmp/aicam_frame_\(Int(Date().timeIntervalSince1970)).jpg"
        process?.arguments = [
            "-rtsp_transport", "tcp",
            "-i", rtspURL,
            "-frames:v", "1",        // Capture just 1 frame
            "-vf", "scale=640:480",  // Smaller resolution for testing
            "-vcodec", "mjpeg",
            "-q:v", "2",             // High quality JPEG
            "-y",                    // Overwrite output
            outputPath
        ]

        let stdOutPipe = Pipe()
        let stdErrPipe = Pipe()
        process?.standardOutput = stdOutPipe
        process?.standardError = stdErrPipe

        // For JPEG capture, we check the process completion rather than stdout
        stdErrPipe.fileHandleForReading.readabilityHandler = { handle in
            if let errorString = String(data: handle.availableData, encoding: .utf8), !errorString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleanError = errorString.trimmingCharacters(in: .whitespacesAndNewlines)

                if cleanError.contains("Connection refused") {
                    Logger.log("CONNECTION ERROR: Camera refused connection. Check IP address and port.")
                } else if cleanError.contains("401") || cleanError.contains("Unauthorized") {
                    Logger.log("AUTH ERROR: Invalid credentials. Check username/password in Keychain.")
                } else if cleanError.contains("timed out") || cleanError.contains("timeout") {
                    Logger.log("TIMEOUT ERROR: Connection timed out. Check network connectivity.")
                } else if cleanError.contains("No route to host") {
                    Logger.log("NETWORK ERROR: Cannot reach camera IP address.")
                } else if cleanError.contains("Stream") && cleanError.contains("fps") {
                    Logger.log("STREAM INFO: \(cleanError)")
                } else if cleanError.contains("Input #0") {
                    Logger.log("STREAM CONNECTED: \(cleanError)")
                } else if !cleanError.contains("ffmpeg version") && !cleanError.contains("libav") && !cleanError.contains("configuration:") {
                    Logger.log("ffmpeg: \(cleanError)")
                }
            }
        }

        process?.terminationHandler = { [weak self] process in
            guard let self = self, !self.isRestarting else { return }
            let exitCode = process.terminationStatus
            
            // Check if JPEG was created successfully
            if exitCode == 0 {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: outputPath)) {
                    Logger.log("SUCCESS: Captured JPEG frame (\(data.count) bytes)")
                    self.onFrameData(data) // Process the JPEG data
                    try? FileManager.default.removeItem(atPath: outputPath) // Clean up
                } else {
                    Logger.log("Warning: ffmpeg succeeded but no JPEG file found at \(outputPath)")
                }
            } else {
                Logger.log("ERROR: ffmpeg process terminated with exit code \(exitCode)")
                if exitCode == 1 {
                    Logger.log("This usually indicates a connection or authentication problem.")
                }
            }
            
            // Schedule next capture in 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard !self.isRestarting else { return }
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

// --- Stream Reader Protocol ---
protocol StreamReaderProtocol {
    func start()
    func stop()
}

// --- FFmpegKit Stream Reader (JPEG snapshots) ---
#if canImport(FFmpegKit)
class FFmpegKitStreamReader: StreamReaderProtocol {
    private let rtspURL: String
    private let onFrame: (Data) -> Void
    private var timer: Timer?
    private let captureInterval: TimeInterval = 1.0
    private let outputPath: String = "/tmp/aicam_frame.jpg"

    init(rtspURL: String, onFrame: @escaping (Data) -> Void) {
        self.rtspURL = rtspURL
        self.onFrame = onFrame
    }

    func start() {
        Logger.log("Using FFmpegKit stream reader.")
        timer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
        captureFrame()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func captureFrame() {
        let command = "-rtsp_transport tcp -i \"\(rtspURL)\" -frames:v 1 -vf scale=iw:-1 -vcodec mjpeg -q:v 2 -y \"\(outputPath)\""
        FFmpegKit.executeAsync(command) { [weak self] session in
            guard let self = self else { return }
            if let returnCode = session?.getReturnCode(), returnCode.isValueSuccess() {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: self.outputPath)) {
                    self.onFrame(data)
                }
            } else {
                Logger.log("FFmpegKit session failed with return code \(String(describing: session?.getReturnCode())).")
            }
        }
    }
}
#endif

// --- SwiftFFmpeg Stream Reader (fallback to FFmpegKit) ---
#if canImport(SwiftFFmpeg)
class SwiftFFmpegStreamReader: StreamReaderProtocol {
    private let rtspURL: String
    private let onFrame: (Data) -> Void
    private var ffmpegKitFallback: StreamReaderProtocol?

    init(rtspURL: String, onFrame: @escaping (Data) -> Void) {
        self.rtspURL = rtspURL
        self.onFrame = onFrame
        #if canImport(FFmpegKit)
        self.ffmpegKitFallback = FFmpegKitStreamReader(rtspURL: rtspURL, onFrame: onFrame)
        #else
        self.ffmpegKitFallback = nil
        #endif
    }

    func start() {
        Logger.log("Using SwiftFFmpeg stream reader.")
        do {
            let fmtCtx = try AVFormatContext.openInput(url: rtspURL)
            try fmtCtx.findStreamInfo()
            guard let _ = fmtCtx.streams.first(where: { $0.codecpar?.codecType == .VIDEO }) else {
                Logger.log("SwiftFFmpeg: no video stream found. Falling back.")
                ffmpegKitFallback?.start()
                return
            }
            // If you wish to decode frames directly, implement AVCodecContext here.
            Logger.log("SwiftFFmpeg: video stream detected. Falling back to FFmpegKit for frame capture.")
            ffmpegKitFallback?.start()
        } catch {
            Logger.log("SwiftFFmpeg failed to open RTSP stream (\(error)). Falling back to FFmpegKit or external ffmpeg.")
            ffmpegKitFallback?.start()
        }
    }

    func stop() {
        ffmpegKitFallback?.stop()
    }
}
#endif

// --- Main Application ---
class Application {
    private let config: AppConfig
    private let modelManager: AIModelManager
    private var frameDataBuffer = Data()
    private var hasReceivedFrame = false
    private let frameWidth = 1920
    private let frameHeight = 1080
    private var lastSnapshotTime = Date(timeIntervalSince1970: 0)
    private var frameCount = 0
    private var lastHeartbeat = Date()

    private lazy var streamReader: RTSPStreamReader = {
        return RTSPStreamReader(rtspURL: self.config.finalRTSP_URL, onFrameData: { [weak self] data in
            self?.processFrameData(data)
        })
    }()

    init?() {
        Logger.log("Initializing AI Cam Monitor application...")

        guard let config = AppConfig() else {
            Logger.log("Failed to load configuration.")
            return nil
        }
        self.config = config

        if config.testCaptureOnStart {
            Logger.log("Running initial stream connectivity test...")
            if !Self.testStreamConnectivity(config: config) {
                Logger.log("Stream connectivity test failed. Please check your camera connection.")
                return nil
            }
        }

        guard let modelManager = AIModelManager() else {
            Logger.log("Failed to initialize AI model.")
            return nil
        }
        self.modelManager = modelManager

        Logger.log("Creating snapshot directory: \(config.saveDirectory.path)")
        do {
            try FileManager.default.createDirectory(at: config.saveDirectory, withIntermediateDirectories: true, attributes: nil)
            Logger.log("Snapshot directory ready.")
        } catch {
            Logger.log("Warning: Could not create snapshot directory: \(error)")
        }

        Logger.log("Application initialization completed successfully.")
    }

    private static func testStreamConnectivity(config: AppConfig) -> Bool {
        Logger.log("Testing stream connectivity for URL: \(config.finalRTSP_URL)")
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["ffprobe"]
        let whichPipe = Pipe()
        which.standardOutput = whichPipe
        do {
            try which.run()
            which.waitUntilExit()
        } catch {
            Logger.log("Failed to run 'which ffprobe': \(error)")
            return true
        }
        let ffprobePathData = whichPipe.fileHandleForReading.readDataToEndOfFile()
        guard let ffprobePath = String(data: ffprobePathData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ffprobePath.isEmpty else {
            Logger.log("ffprobe executable not found in PATH; skipping connectivity test.")
            return true
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = ["-v", "error", "-rtsp_transport", "tcp", "-i", config.finalRTSP_URL, "-show_streams", "-of", "json"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
        } catch {
            Logger.log("Error running ffprobe: \(error)")
            return true
        }
        let timeout: DispatchTime = .now() + 10
        DispatchQueue.global().asyncAfter(deadline: timeout) {
            if process.isRunning {
                Logger.log("ffprobe timed out during connectivity test; terminating.")
                process.terminate()
            }
        }
        process.waitUntilExit()
        let status = process.terminationStatus
        if status == 0 {
            Logger.log("Initial stream connectivity check passed.")
            return true
        } else {
            Logger.log("Initial stream connectivity check failed with exit code \(status).")
            return false
        }
    }

    func run() {
        Logger.log("AI Cam Monitor starting up...")
        Logger.log("========================================")
        if let url = URL(string: config.finalRTSP_URL) {
            Logger.log("Monitoring URL: rtsp://\(url.host ?? "unknown"):\(url.port ?? 554)\(url.path)")
        }
        Logger.log("Target Objects: \(config.targetObjects.isEmpty ? "any" : config.targetObjects.joined(separator: ", "))")
        Logger.log("Confidence Threshold: \(Int(config.confidenceThreshold * 100))%")
        Logger.log("Save Snapshots: \(config.snapshotOnDetection)")
        Logger.log("Notification Cooldown: \(config.notificationCooldown) seconds")
        Logger.log("Test Capture On Start: \(config.testCaptureOnStart)")
        Logger.log("Snapshot Directory: \(config.saveDirectory.path)")
        Logger.log("========================================")

        streamReader.start()

        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = Date()
            if self.hasReceivedFrame {
                Logger.log("Heartbeat: Application running normally. Frames processed: \(self.frameCount)")
            } else {
                let elapsed = Int(now.timeIntervalSince(self.lastHeartbeat))
                Logger.log("Heartbeat: Waiting for video stream connection... (\(elapsed)s elapsed)")
            }
            self.lastHeartbeat = now
        }

        Logger.log("Application is now running. Press Ctrl+C to stop.")
        RunLoop.main.run()
    }

    private func processFrameData(_ data: Data) {
        // For JPEG data, decode it directly
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Logger.log("Failed to decode JPEG frame.")
            return
        }
        
        if !hasReceivedFrame {
            Logger.log("SUCCESS: Video stream connected! Receiving JPEG frames from camera.")
            Logger.log("Frame data size: \(data.count) bytes")
            hasReceivedFrame = true
        }

        frameCount += 1
        Logger.log("Processing JPEG frame #\(frameCount) (\(cgImage.width)x\(cgImage.height))")

        // Create pixel buffer from the JPEG
        guard let pixelBuffer = createPixelBufferFromCGImage(cgImage) else {
            Logger.log("Warning: Failed to create pixel buffer for frame #\(frameCount)")
            return
        }

        modelManager.performDetection(on: pixelBuffer) { [weak self] detections in
            guard let self = self else { return }
            let filteredDetections = detections.filter {
                ($0.label != "unknown") && ($0.confidence >= self.config.confidenceThreshold) &&
                (self.config.targetObjects.isEmpty || self.config.targetObjects.contains($0.label))
            }
            if !filteredDetections.isEmpty {
                self.handleDetection(detections: filteredDetections, frame: pixelBuffer)
            }
        }
    }

    // Helper for JPEG frames (no longer used, but kept for reference)
    private func processCapturedFrame(_ data: Data) {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Logger.log("Failed to decode JPEG frame.")
            return
        }
        let width = cgImage.width
        let height = cgImage.height

        guard let pixelBuffer = createPixelBuffer(from: data, width: width, height: height) else {
            Logger.log("Failed to create pixel buffer from JPEG.")
            return
        }

        frameCount += 1
        hasReceivedFrame = true
        Logger.log("Processing captured frame #\(frameCount)")

        modelManager.performDetection(on: pixelBuffer) { [weak self] detections in
            guard let self = self else { return }
            let filteredDetections = detections.filter {
                ($0.label != "unknown") && ($0.confidence >= self.config.confidenceThreshold) &&
                (self.config.targetObjects.isEmpty || self.config.targetObjects.contains($0.label))
            }
            if !filteredDetections.isEmpty {
                self.handleDetection(detections: filteredDetections, frame: pixelBuffer)
            }
        }
    }

    private func handleDetection(detections: [(label: String, confidence: Float, box: CGRect)], frame: CVImageBuffer) {
        let now = Date()
        if now.timeIntervalSince(lastSnapshotTime) < config.notificationCooldown { return }
        lastSnapshotTime = now

        let labels = detections.map { "\($0.label) (\(Int($0.confidence * 100))%)" }.joined(separator: ", ")
        Logger.log("🎯 DETECTION: \(labels) at frame #\(frameCount)")

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
        let options = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary
        
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, options, &pixelBuffer)
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        
        return buffer
    }

    private func saveFrameAsJPEG(pixelBuffer: CVPixelBuffer, at url: URL) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            Logger.log("Error: Failed to create image for saving.")
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        if !CGImageDestinationFinalize(destination) {
            Logger.log("Error: Failed to save image to \(url.path)")
        } else {
            Logger.log("📸 Snapshot saved: \(url.lastPathComponent)")
        }
    }
}

// --- Entry Point ---
Logger.log("Starting AI Cam Monitor...")
guard let app = Application() else {
    Logger.log("FATAL: Application failed to initialize. Check config.env and model files.")
    exit(1)
}
app.run()