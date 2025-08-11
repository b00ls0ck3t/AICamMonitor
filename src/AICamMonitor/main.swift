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

// --- Configuration Loader ---
struct AppConfig {
    let finalRTSP_URL: String
    let saveDirectory: URL
    let targetObjects: [String]
    let confidenceThreshold: Float
    let snapshotOnDetection: Bool
    let notificationCooldown: TimeInterval

    init?() {
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

        self.saveDirectory = URL(fileURLWithPath: configDict["SNAPSHOT_DIRECTORY"] ?? "Captures")
        self.targetObjects = (configDict["OBJECTS_TO_MONITOR"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        self.confidenceThreshold = Float(configDict["DETECTION_THRESHOLD"] ?? "0.4") ?? 0.4
        self.snapshotOnDetection = (configDict["SNAPSHOT_ON_DETECTION"] ?? "true").lowercased() == "true"
        self.notificationCooldown = TimeInterval(configDict["NOTIFICATION_COOLDOWN"] ?? "10") ?? 10
    }
}

// --- AI Model Manager ---
class AIModelManager {
    private let model: VNCoreMLModel

    init?() {
        let modelURL = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Resources/yolov8n.mlmodelc")
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            Logger.log("Error: Compiled model 'yolov8n.mlmodelc' not found at \(modelURL.path). Please run ./install.sh")
            return nil
        }
        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            self.model = try VNCoreMLModel(for: mlModel)
            Logger.log("AI Model loaded successfully.")
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

// --- RTSP Stream Reader with Failsafe ---
class RTSPStreamReader {
    private var process: Process?
    private let rtspURL: String
    private let onFrameData: (Data) -> Void
    private var isRestarting = false
    
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
        guard let ffmpegPath = findExecutable(named: "ffmpeg") else {
            Logger.log("FATAL: 'ffmpeg' executable not found in shell PATH. Please run ./install.sh.")
            exit(1)
        }
        
        Logger.log("Attempting to connect to stream with ffmpeg at: \(ffmpegPath)")
        
        let stdErrPipe = Pipe()
        process = Process()
        process?.executableURL = URL(fileURLWithPath: ffmpegPath)
        process?.arguments = ["-i", rtspURL, "-pix_fmt", "bgr24", "-f", "rawvideo", "-an", "-"]
        
        let stdOutPipe = Pipe()
        process?.standardOutput = stdOutPipe
        process?.standardError = stdErrPipe
        
        stdOutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                self?.onFrameData(data)
            }
        }
        
        stdErrPipe.fileHandleForReading.readabilityHandler = { handle in
            if let errorString = String(data: handle.availableData, encoding: .utf8), !errorString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Logger.log("ffmpeg ERROR: \(errorString.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        
        process?.terminationHandler = { [weak self] _ in
            guard let self = self, !self.isRestarting else { return }
            self.isRestarting = true
            Logger.log("Error: Video stream lost. Attempting to reconnect in 15 seconds...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                self.isRestarting = false
                self.start()
            }
        }
        
        do {
            try process?.run()
        } catch {
            Logger.log("Error: Failed to start ffmpeg process: \(error.localizedDescription)")
        }
    }

    func stop() {
        isRestarting = true
        process?.terminate()
    }
}

// --- Main Application ---
class Application {
    private let config: AppConfig
    private let modelManager: AIModelManager
    private var frameDataBuffer = Data()
    private var hasReceivedFrame = false
    private let frameWidth = 1920
    private let frameHeight = 1080
    private var lastSnapshotTime = Date(timeIntervalSince1970: 0)
    
    // CORRECTED: The streamReader is now a lazy var to solve the initialization error.
    private lazy var streamReader: RTSPStreamReader = {
        return RTSPStreamReader(rtspURL: self.config.finalRTSP_URL, onFrameData: { [weak self] data in
            self?.processFrameData(data)
        })
    }()

    init?() {
        guard let config = AppConfig() else { return nil }
        self.config = config
        
        guard let modelManager = AIModelManager() else { return nil }
        self.modelManager = modelManager
        
        try? FileManager.default.createDirectory(at: config.saveDirectory, withIntermediateDirectories: true, attributes: nil)
    }

    func run() {
        Logger.log("AI Cam Monitor Initialized. Starting stream reader.")
        Logger.log("----------------------------------------")
        Logger.log("Monitoring URL: rtsp://\(URL(string: config.finalRTSP_URL)?.host ?? "unknown"):...")
        Logger.log("Target Objects: \(config.targetObjects.isEmpty ? "any" : config.targetObjects.joined(separator: ", "))")
        Logger.log("Confidence Threshold: \(Int(config.confidenceThreshold * 100))%")
        Logger.log("Save Snapshots: \(config.snapshotOnDetection)")
        Logger.log("Notification Cooldown: \(config.notificationCooldown) seconds")
        Logger.log("Snapshot Directory: \(config.saveDirectory.path)")
        Logger.log("----------------------------------------")

        // Accessing self.streamReader here for the first time triggers its lazy initialization.
        streamReader.start()
        
        RunLoop.main.run()
    }
    
    private func processFrameData(_ data: Data) {
        if !hasReceivedFrame {
            Logger.log("Success! Video stream connected and receiving data.")
            hasReceivedFrame = true
        }
        
        frameDataBuffer.append(data)
        let frameSize = frameWidth * frameHeight * 3
        
        while frameDataBuffer.count >= frameSize {
            let frameData = frameDataBuffer.prefix(frameSize)
            frameDataBuffer.removeFirst(frameSize)
            
            guard let frameBuffer = createPixelBuffer(from: frameData, width: frameWidth, height: frameHeight) else { continue }
            
            modelManager.performDetection(on: frameBuffer) { [weak self] detections in
                guard let self = self else { return }
                let filteredDetections = detections.filter {
                    ($0.label != "unknown") && ($0.confidence >= self.config.confidenceThreshold) && (self.config.targetObjects.isEmpty || self.config.targetObjects.contains($0.label))
                }
                if !filteredDetections.isEmpty {
                    self.handleDetection(detections: filteredDetections, frame: frameBuffer)
                }
            }
        }
    }
    
    private func handleDetection(detections: [(label: String, confidence: Float, box: CGRect)], frame: CVImageBuffer) {
        let now = Date()
        if now.timeIntervalSince(lastSnapshotTime) < config.notificationCooldown { return }
        lastSnapshotTime = now
        
        let labels = detections.map { "\($0.label) (\(Int($0.confidence * 100))%)" }.joined(separator: ", ")
        Logger.log("Detection: \(labels)")

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
            let options = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!, kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!] as CFDictionary
            return CVPixelBufferCreateWithBytes(kCFAllocatorDefault, width, height, kCVPixelFormatType_24BGR, bytes.baseAddress!, width * 3, nil, nil, options, &pixelBuffer)
        }
        return status == kCVReturnSuccess ? pixelBuffer : nil
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
            Logger.log("Snapshot saved: \(url.path)")
        }
    }
}

// --- Entry Point ---
guard let app = Application() else {
    Logger.log("FATAL: Application failed to initialize. Check config.env and model files.")
    exit(1)
}
app.run()