import Foundation
import Vision
import CoreML
import AVFoundation
import UserNotifications
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Configuration
struct Config {
    static let rtspFeedURL = ProcessInfo.processInfo.environment["RTSP_FEED_URL"] ?? ""
    static let rtspCreds = ProcessInfo.processInfo.environment["RTSP_CREDS"] ?? ""
    static let detectionThreshold = Float(ProcessInfo.processInfo.environment["DETECTION_THRESHOLD"] ?? "0.7") ?? 0.7
    static let objectsToMonitor = ProcessInfo.processInfo.environment["OBJECTS_TO_MONITOR"]?.components(separatedBy: ",") ?? ["person"]
    static let notificationCooldown = TimeInterval(ProcessInfo.processInfo.environment["NOTIFICATION_COOLDOWN_SECONDS"] ?? "300") ?? 300
    static let snapshotOnDetection = ProcessInfo.processInfo.environment["SNAPSHOT_ON_DETECTION"]?.lowercased() == "true"
    static let snapshotDirectory = ProcessInfo.processInfo.environment["SNAPSHOT_DIRECTORY"] ?? "/tmp/ai_cam_snapshots"
    static let coreMLModelName = ProcessInfo.processInfo.environment["COREML_MODEL_NAME"] ?? "yolov8n.mlpackage"
}

// MARK: - YOLO Class Names
struct YOLOClasses {
    static let classNames = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
        "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
        "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
        "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake",
        "chair", "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop",
        "mouse", "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
        "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
    ]
}

// MARK: - Detection Result
struct DetectionResult {
    let className: String
    let confidence: Float
    let boundingBox: CGRect
}

// MARK: - Notification Manager
class NotificationManager {
    private var lastNotificationTimes: [String: Date] = [:]
    
    init() {
        setupNotifications()
    }
    
    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ Notification permission granted")
            } else {
                print("❌ Notification permission denied: \(error?.localizedDescription ?? "Unknown error")")
            }
        }
    }
    
    func sendDetectionNotification(for detections: [DetectionResult], snapshot: URL? = nil) {
        let now = Date()
        var notificationsSent = 0
        
        for detection in detections {
            // Check cooldown
            if let lastTime = lastNotificationTimes[detection.className],
               now.timeIntervalSince(lastTime) < Config.notificationCooldown {
                continue
            }
            
            lastNotificationTimes[detection.className] = now
            
            let content = UNMutableNotificationContent()
            content.title = "🔍 Object Detected"
            content.body = "Detected: \(detection.className.capitalized) (Confidence: \(String(format: "%.1f", detection.confidence * 100))%)"
            content.sound = .default
            
            // Add snapshot attachment if available
            if let snapshotURL = snapshot {
                do {
                    let attachment = try UNNotificationAttachment(identifier: UUID().uuidString, url: snapshotURL)
                    content.attachments = [attachment]
                } catch {
                    print("❌ Failed to attach snapshot: \(error)")
                }
            }
            
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    print("❌ Failed to send notification: \(error)")
                } else {
                    print("📱 Notification sent for \(detection.className)")
                }
            }
            
            notificationsSent += 1
        }
        
        if notificationsSent > 0 {
            print("📱 Sent \(notificationsSent) notification(s)")
        }
    }
}

// MARK: - Snapshot Manager
class SnapshotManager {
    private let snapshotDirectory: URL
    
    init() {
        snapshotDirectory = URL(fileURLWithPath: Config.snapshotDirectory)
        createSnapshotDirectory()
    }
    
    private func createSnapshotDirectory() {
        do {
            try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            print("📁 Snapshot directory ready: \(snapshotDirectory.path)")
        } catch {
            print("❌ Failed to create snapshot directory: \(error)")
        }
    }
    
    func saveSnapshot(from pixelBuffer: CVPixelBuffer, with detections: [DetectionResult]) -> URL? {
        guard Config.snapshotOnDetection else { return nil }
        
        let timestamp = DateFormatter().apply {
            $0.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        }.string(from: Date())
        
        let filename = "detection_\(timestamp).jpg"
        let fileURL = snapshotDirectory.appendingPathComponent(filename)
        
        if saveCVPixelBufferAsJPEG(pixelBuffer, to: fileURL) {
            print("📸 Snapshot saved: \(filename)")
            return fileURL
        } else {
            print("❌ Failed to save snapshot")
            return nil
        }
    }
    
    private func saveCVPixelBufferAsJPEG(_ pixelBuffer: CVPixelBuffer, to url: URL) -> Bool {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            print("❌ Failed to create color space")
            return false
        }
        
        do {
            try context.writeJPEGRepresentation(of: ciImage, to: url, colorSpace: colorSpace)
            return true
        } catch {
            print("❌ Failed to write JPEG: \(error)")
            return false
        }
    }
}

// MARK: - AI Model Manager
class AIModelManager {
    private var model: VNCoreMLModel?
    
    init() {
        loadModel()
    }
    
    private func loadModel() {
        guard let modelURL = Bundle.main.url(forResource: Config.coreMLModelName.replacingOccurrences(of: ".mlpackage", with: ""), withExtension: "mlpackage") else {
            print("❌ Could not find model file: \(Config.coreMLModelName)")
            return
        }
        
        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            model = try VNCoreMLModel(for: mlModel)
            print("✅ AI model loaded successfully: \(Config.coreMLModelName)")
        } catch {
            print("❌ Failed to load AI model: \(error)")
        }
    }
    
    func detectObjects(in pixelBuffer: CVPixelBuffer, completion: @escaping ([DetectionResult]) -> Void) {
        guard let model = model else {
            print("❌ Model not loaded")
            completion([])
            return
        }
        
        let request = VNCoreMLRequest(model: model) { [weak self] request, error in
            guard let results = request.results as? [VNRecognizedObjectObservation], error == nil else {
                print("❌ Detection error: \(error?.localizedDescription ?? "Unknown")")
                completion([])
                return
            }
            
            let detections = self?.processDetectionResults(results) ?? []
            completion(detections)
        }
        
        request.imageCropAndScaleOption = .scaleFill
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        do {
            try handler.perform([request])
        } catch {
            print("❌ Failed to perform detection: \(error)")
            completion([])
        }
    }
    
    private func processDetectionResults(_ results: [VNRecognizedObjectObservation]) -> [DetectionResult] {
        var detections: [DetectionResult] = []
        
        for result in results {
            guard result.confidence >= Config.detectionThreshold,
                  let label = result.labels.first?.identifier else {
                continue
            }
            
            // Convert label index to class name
            let className: String
            if let classIndex = Int(label), classIndex < YOLOClasses.classNames.count {
                className = YOLOClasses.classNames[classIndex]
            } else {
                className = label
            }
            
            // Check if this object type should be monitored
            guard Config.objectsToMonitor.contains(className) else {
                continue
            }
            
            let detection = DetectionResult(
                className: className,
                confidence: result.confidence,
                boundingBox: result.boundingBox
            )
            
            detections.append(detection)
            print("🎯 Detected: \(className) (confidence: \(String(format: "%.3f", result.confidence)))")
        }
        
        return detections
    }
}

// MARK: - Video Frame Reader (Simplified RTSP)
class VideoFrameReader {
    private let rtspURL: String
    private let credentials: String
    private var isRunning = false
    private var frameProcessingQueue = DispatchQueue(label: "frame.processing", qos: .userInitiated)
    
    init(rtspURL: String, credentials: String) {
        self.rtspURL = rtspURL
        self.credentials = credentials
    }
    
    func startReading(frameHandler: @escaping (CVPixelBuffer) -> Void) {
        isRunning = true
        
        frameProcessingQueue.async { [weak self] in
            self?.processVideoStream(frameHandler: frameHandler)
        }
    }
    
    func stopReading() {
        isRunning = false
    }
    
    private func processVideoStream(frameHandler: @escaping (CVPixelBuffer) -> Void) {
        print("🎥 Starting video stream processing...")
        print("📡 RTSP URL: \(rtspURL)")
        
        // This is a simplified implementation
        // In a real implementation, you would use FFmpeg or AVFoundation to:
        // 1. Connect to the RTSP stream
        // 2. Decode video packets
        // 3. Convert frames to CVPixelBuffer
        // 4. Call frameHandler for each frame
        
        // For now, we'll simulate frame processing
        var frameCount = 0
        
        while isRunning {
            frameCount += 1
            
            // Create a dummy pixel buffer for demonstration
            // In reality, this would be the actual video frame
            if let pixelBuffer = createDummyPixelBuffer() {
                frameHandler(pixelBuffer)
            }
            
            // Process at ~10 FPS to avoid overwhelming the system
            Thread.sleep(forTimeInterval: 0.1)
            
            // Print status every 100 frames
            if frameCount % 100 == 0 {
                print("📊 Processed \(frameCount) frames")
            }
        }
        
        print("🎥 Video stream processing stopped")
    }
    
    private func createDummyPixelBuffer() -> CVPixelBuffer? {
        // This creates a black 640x640 pixel buffer for demonstration
        // In reality, this would be the decoded video frame
        let width = 640
        let height = 640
        
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        
        if result == kCVReturnSuccess {
            return pixelBuffer
        }
        
        return nil
    }
}

// MARK: - Main Application
class AICamMonitor {
    private let aiModel = AIModelManager()
    private let notificationManager = NotificationManager()
    private let snapshotManager = SnapshotManager()
    private var videoReader: VideoFrameReader?
    private var isRunning = false
    
    func start() {
        print("🚀 Starting AI Cam Monitor...")
        print("⚙️  Configuration:")
        print("   • Detection Threshold: \(Config.detectionThreshold)")
        print("   • Objects to Monitor: \(Config.objectsToMonitor.joined(separator: ", "))")
        print("   • Notification Cooldown: \(Config.notificationCooldown)s")
        print("   • Snapshot on Detection: \(Config.snapshotOnDetection)")
        
        guard !Config.rtspFeedURL.isEmpty else {
            print("❌ RTSP_FEED_URL not configured")
            return
        }
        
        guard !Config.rtspCreds.isEmpty else {
            print("❌ RTSP_CREDS not configured")
            return
        }
        
        videoReader = VideoFrameReader(rtspURL: Config.rtspFeedURL, credentials: Config.rtspCreds)
        isRunning = true
        
        videoReader?.startReading { [weak self] pixelBuffer in
            self?.processFrame(pixelBuffer)
        }
        
        print("✅ AI Cam Monitor started successfully")
        print("💡 Note: This demo uses simulated video frames")
        print("🔧 To use real RTSP streams, implement FFmpeg integration in VideoFrameReader")
        
        // Keep the application running
        RunLoop.main.run()
    }
    
    func stop() {
        print("🛑 Stopping AI Cam Monitor...")
        isRunning = false
        videoReader?.stopReading()
        print("✅ AI Cam Monitor stopped")
    }
    
    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isRunning else { return }
        
        aiModel.detectObjects(in: pixelBuffer) { [weak self] detections in
            guard let self = self, !detections.isEmpty else { return }
            
            print("🔍 Found \(detections.count) detection(s):")
            for detection in detections {
                print("   • \(detection.className): \(String(format: "%.1f", detection.confidence * 100))%")
            }
            
            // Save snapshot if enabled
            let snapshotURL = self.snapshotManager.saveSnapshot(from: pixelBuffer, with: detections)
            
            // Send notifications
            self.notificationManager.sendDetectionNotification(for: detections, snapshot: snapshotURL)
        }
    }
}

// MARK: - Signal Handling
func setupSignalHandling(monitor: AICamMonitor) {
    signal(SIGINT) { _ in
        print("\n🛑 Received interrupt signal")
        monitor.stop()
        exit(0)
    }
    
    signal(SIGTERM) { _ in
        print("\n🛑 Received termination signal")
        monitor.stop()
        exit(0)
    }
}

// MARK: - Extension for DateFormatter
extension DateFormatter {
    func apply(_ closure: (DateFormatter) -> Void) -> DateFormatter {
        closure(self)
        return self
    }
}

// MARK: - Main Entry Point
print("🤖 AI Cam Monitor v1.0")
print("📱 macOS Security Camera AI Monitoring")
print("=" * 50)

let monitor = AICamMonitor()
setupSignalHandling(monitor: monitor)

// Start monitoring
monitor.start()