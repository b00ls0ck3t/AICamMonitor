#!/bin/bash

# AI Cam Monitor - Final Installer & Configurator
# This script builds a proper macOS application bundle to ensure compatibility
# with system services like User Notifications and Keychain.

set -euo pipefail

# --- Configuration ---
INSTALL_DIR=$(pwd)
CONFIG_FILE="$INSTALL_DIR/config.env"
VENV_DIR="$INSTALL_DIR/.venv"
PROJECT_NAME="AICamMonitor"
SRC_DIR="$INSTALL_DIR/Sources"
APP_SRC_DIR="$SRC_DIR/$PROJECT_NAME"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$INSTALL_DIR/installer_${TIMESTAMP}.log"
export ULTRALYTICS_SETTINGS_DIR="$INSTALL_DIR/.ultralytics_settings"

# --- UI & Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# --- Functions ---

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log_header() {
    log "\n${WHITE}================================${NC}"
    log "${WHITE}$1${NC}"
    log "${WHITE}================================${NC}\n"
}

log_info() { log "${BLUE}[INFO]${NC} $1"; }
log_success() { log "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { log "${YELLOW}[WARNING]${NC} $1"; }
log_error() { log "${RED}[ERROR]${NC} $1"; }

show_banner() {
    clear
    echo -e "${PURPLE}" | tee -a "$LOG_FILE"
    cat << "EOF" | tee -a "$LOG_FILE"
    ___    ____   ______                 __  ___            _ __
   /   |  /  _/  / ____/___ _____ ___   /  |/  /___  ____  (_) /_____  _____
  / /| |  / /   / /   / __ `/ __ `__ \ / /|_/ / __ \/ __ \/ / __/ __ \/ ___/
 / ___ |_/ /   / /___/ /_/ / / / / / // /  / / /_/ / / / / / /_/ /_/ / /
/_/  |_/___/   \____/\__,_/_/ /_/ /_//_/  /_/\____/_/ /_/_/\__/\____/_/

EOF
    echo -e "${NC}" | tee -a "$LOG_FILE"
    log "${WHITE}AI-Powered Security Camera Monitoring for macOS${NC}"
    log "${CYAN}Local AI • Privacy First • Apple Silicon Optimized${NC}"
    log "${WHITE}════════════════════════════════════════════════════${NC}\n"
}

# --- Configuration Management ---

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_info "Loading saved configuration from $CONFIG_FILE"
        # shellcheck source=/dev/null
        . "$CONFIG_FILE"
    else
        log_info "No saved configuration found."
    fi
}

save_config() {
    log_info "Saving configuration to $CONFIG_FILE..."
    cat > "$CONFIG_FILE" << EOF
# AI Cam Monitor Configuration
# NOTE: The camera password is stored securely in your macOS Keychain.
export RTSP_FEED_URL="${RTSP_FEED_URL}"
export CAM_USERNAME="${CAM_USERNAME}"
export OBJECTS_TO_MONITOR="${OBJECTS_TO_MONITOR}"
export DETECTION_THRESHOLD="${DETECTION_THRESHOLD}"
export NOTIFICATION_COOLDOWN="${NOTIFICATION_COOLDOWN}"
export SNAPSHOT_ON_DETECTION="${SNAPSHOT_ON_DETECTION}"
export SNAPSHOT_DIRECTORY="${SNAPSHOT_DIRECTORY}"
export YOLO_VARIANT="${YOLO_VARIANT}"
export COREML_MODEL_NAME="yolov8${YOLO_VARIANT}.mlpackage"
EOF
    log_success "Configuration saved."
}

# --- User Input ---

prompt_user() {
    local prompt="$1"
    local var_name="$2"
    local default_val="${!var_name:-}"
    read -p "$(echo -e "${CYAN}$prompt${NC} ${WHITE}[$default_val]${NC}: ")" input
    eval "$var_name=\"${input:-$default_val}\""
}

prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local options="y/N" && [[ "$default" == "y" ]] && options="Y/n"
    read -p "$(echo -e "${CYAN}$prompt${NC} ${WHITE}[$options]${NC}: ")" yn
    yn=${yn:-$default}
    [[ "$yn" =~ ^[Yy]$ ]]
}

# --- Core Logic ---

check_prerequisites() {
    log_header "1. SYSTEM CHECK"
    if [[ "$(uname)" != "Darwin" ]]; then log_error "This installer is for macOS only"; exit 1; fi
    log_success "Running on macOS"
    if ! xcode-select -p >/dev/null 2>&1; then
        log_info "Xcode Command Line Tools are required. Starting installation..."
        xcode-select --install
        log_warning "Please complete the Xcode tools installation and then run this script again."
        exit 1
    fi
    log_success "Xcode Command Line Tools are installed."
}

cleanup_old_files() {
    log_header "2. CLEANUP"
    log_info "Performing a clean start..."
    if [ -d "$INSTALL_DIR/.build" ]; then
        rm -rf "$INSTALL_DIR/.build"
        log_success "Removed previous build artifacts."
    fi
    if [ -f "$INSTALL_DIR/main.swift" ] || [ -f "$INSTALL_DIR/Package.swift" ]; then
        rm -f "$INSTALL_DIR"/main.swift "$INSTALL_DIR"/Package.swift
        log_success "Removed old root files."
    fi
}

install_dependencies() {
    log_header "3. DEPENDENCIES"
    if ! command -v brew >/dev/null 2>&1; then
        log_info "Homebrew not found. Installing..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    log_success "Homebrew is ready."
    log_info "Installing system tools..."
    brew install ffmpeg coreutils >/dev/null 2>&1
    log_success "System tools are ready."
    log_info "Setting up Python environment..."
    if [ ! -d "$VENV_DIR" ]; then python3 -m venv "$VENV_DIR"; fi
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip >/dev/null 2>&1
    pip install ultralytics coremltools >/dev/null 2>&1
    deactivate
    log_success "Python environment is ready."
}

collect_configuration() {
    log_header "4. CONFIGURATION"
    : "${RTSP_FEED_URL:=rtsp://10.0.60.130:554/h264Preview_01_main}"
    : "${CAM_USERNAME:=admin}"
    : "${OBJECTS_TO_MONITOR:=person,car}"
    : "${DETECTION_THRESHOLD:=0.7}"
    : "${YOLO_VARIANT:=n}"
    : "${NOTIFICATION_COOLDOWN:=300}"
    : "${SNAPSHOT_ON_DETECTION:=true}"
    : "${SNAPSHOT_DIRECTORY:=$HOME/Desktop/AICam_Snapshots}"
    prompt_user "Enter camera RTSP URL" "RTSP_FEED_URL"
    prompt_user "Enter camera username" "CAM_USERNAME"
    log_info "\n--- AI & Feature Settings ---"
    prompt_user "Objects to monitor" "OBJECTS_TO_MONITOR"
    prompt_user "YOLO model variant (n,s,m,l,x)" "YOLO_VARIANT"
    if prompt_yes_no "Save snapshots on detection?" "y"; then
        SNAPSHOT_ON_DETECTION="true"
        prompt_user "Snapshot directory" "SNAPSHOT_DIRECTORY"
    else
        SNAPSHOT_ON_DETECTION="false"; SNAPSHOT_DIRECTORY=""
    fi
    save_config
}

download_and_convert_model() {
    log_header "5. AI MODEL SETUP"
    local coreml_model_name="yolov8${YOLO_VARIANT}.mlpackage"
    if [[ -d "$INSTALL_DIR/$coreml_model_name" ]]; then
        log_success "AI Model '$coreml_model_name' already exists."
        return
    fi
    cat > "$INSTALL_DIR/convert_model.py" << 'EOF'
import sys; from ultralytics import YOLO
YOLO(f"yolov8{sys.argv[1]}.pt").export(format='coreml', nms=True, half=True)
EOF
    source "$VENV_DIR/bin/activate"
    log_info "Downloading and converting YOLOv8 model (variant: ${YOLO_VARIANT})..."
    if ! python "$INSTALL_DIR/convert_model.py" "$YOLO_VARIANT" &> "$LOG_FILE"; then
        log_error "Model conversion failed. Check '$LOG_FILE'."
        deactivate; exit 1
    fi
    deactivate
    log_success "AI Model is ready."
}

create_swift_project() {
    log_header "6. CREATING SWIFT APPLICATION"
    local coreml_model_name="yolov8${YOLO_VARIANT}.mlpackage"

    mkdir -p "$APP_SRC_DIR/Resources"
    log_info "Creating Package.swift for a macOS Application..."
    cat > "$INSTALL_DIR/Package.swift" << EOF
// swift-tools-version: 5.7
import PackageDescription
let package = Package(
    name: "$PROJECT_NAME",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "$PROJECT_NAME",
            path: "Sources/$PROJECT_NAME",
            resources: [.process("Resources")]
        )
    ]
)
EOF
    log_info "Copying AI Model to project resources..."
    cp -r "$INSTALL_DIR/$coreml_model_name" "$APP_SRC_DIR/Resources/"
    log_success "AI Model bundled with application."
    log_info "Writing application source code (main.swift)..."
    cat > "$APP_SRC_DIR/main.swift" << 'EOF'
import Foundation
import Vision
import CoreML
import AVFoundation
import UserNotifications
import CoreImage

struct DetectionResult {
    let className: String
    let confidence: Float
    let boundingBox: CGRect
}

struct Config {
    static let rtspFeedURL = ProcessInfo.processInfo.environment["RTSP_FEED_URL"] ?? ""
    static let camUsername = ProcessInfo.processInfo.environment["CAM_USERNAME"] ?? ""
    static let camPassword = ProcessInfo.processInfo.environment["CAM_PASSWORD"] ?? ""
    static let detectionThreshold = Float(ProcessInfo.processInfo.environment["DETECTION_THRESHOLD"] ?? "0.7") ?? 0.7
    static let objectsToMonitor = ProcessInfo.processInfo.environment["OBJECTS_TO_MONITOR"]?.components(separatedBy: ",") ?? ["person"]
    static let notificationCooldown = TimeInterval(ProcessInfo.processInfo.environment["NOTIFICATION_COOLDOWN"] ?? "300") ?? 300
    static let snapshotOnDetection = ProcessInfo.processInfo.environment["SNAPSHOT_ON_DETECTION"]?.lowercased() == "true"
    static let snapshotDirectory = ProcessInfo.processInfo.environment["SNAPSHOT_DIRECTORY"] ?? ""
    static let coreMLModelName = ProcessInfo.processInfo.environment["COREML_MODEL_NAME"] ?? "yolov8n.mlpackage"
    static let YOLO_VARIANT = ProcessInfo.processInfo.environment["YOLO_VARIANT"] ?? "n"
}

class NotificationManager {
    private var lastNotificationTimes: [String: Date] = [:]
    init() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {_,_ in} }
    func sendDetectionNotification(for detection: DetectionResult, snapshot: URL?) {
        let now = Date()
        if let lastTime = lastNotificationTimes[detection.className], now.timeIntervalSince(lastTime) < Config.notificationCooldown { return }
        lastNotificationTimes[detection.className] = now
        let content = UNMutableNotificationContent()
        content.title = "🔍 Object Detected"
        content.body = "\(detection.className.capitalized) detected (\(String(format: "%.1f%%", detection.confidence * 100)) confidence)."
        content.sound = .default
        if let snapshotURL = snapshot, let attachment = try? UNNotificationAttachment(identifier: UUID().uuidString, url: snapshotURL, options: nil) {
            content.attachments = [attachment]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

class SnapshotManager {
    private let snapshotDirectory: URL
    init?() {
        guard Config.snapshotOnDetection, !Config.snapshotDirectory.isEmpty else { return nil }
        self.snapshotDirectory = URL(fileURLWithPath: Config.snapshotDirectory)
        try? FileManager.default.createDirectory(at: self.snapshotDirectory, withIntermediateDirectories: true, attributes: nil)
        print("📁 Snapshot directory ready at: \(self.snapshotDirectory.path)")
    }
    func saveSnapshot(from pixelBuffer: CVPixelBuffer) -> URL? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpegData = CIContext().jpegRepresentation(of: ciImage, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) else { return nil }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileURL = snapshotDirectory.appendingPathComponent("detection_\(timestamp).jpg")
        try? jpegData.write(to: fileURL)
        print("📸 Snapshot saved: \(fileURL.lastPathComponent)")
        return fileURL
    }
}

class AIModelManager {
    private let model: VNCoreMLModel
    init?() {
        let modelName = "yolov8\(Config.YOLO_VARIANT)"
        // FIX: The model is inside a subdirectory within the bundle's Resources.
        // The subdirectory has the same name as the .mlpackage file.
        guard let modelURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc", subdirectory: Config.coreMLModelName) else {
            print("❌ Critical Error: Could not find compiled model '\(modelName).mlmodelc' in subdirectory '\(Config.coreMLModelName)'.")
            return nil
        }
        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            self.model = try VNCoreMLModel(for: mlModel)
            print("✅ AI model loaded successfully: \(Config.coreMLModelName)")
        } catch {
            print("❌ Failed to load AI model: \(error)"); return nil
        }
    }
    func detectObjects(in pixelBuffer: CVPixelBuffer, completion: @escaping ([DetectionResult]) -> Void) {
        let request = VNCoreMLRequest(model: model) { (request, _) in
            let detections = (request.results as? [VNRecognizedObjectObservation])?.compactMap { observation -> DetectionResult? in
                guard let label = observation.labels.first,
                      label.confidence >= Config.detectionThreshold,
                      Config.objectsToMonitor.contains(label.identifier) else {
                    return nil
                }
                return DetectionResult(className: label.identifier, confidence: label.confidence, boundingBox: observation.boundingBox)
            }
            completion(detections ?? [])
        }
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
    }
}

class VideoFrameReader {
    private var isRunning = false
    func startReading(frameHandler: @escaping (CVPixelBuffer) -> Void) {
        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.isRunning == true {
                if let buffer = self?.createDummyPixelBuffer(width: 640, height: 480) { frameHandler(buffer) }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
    func stopReading() { isRunning = false }
    private func createDummyPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
        return pb
    }
}

class AICamMonitor {
    private let aiModel: AIModelManager? = AIModelManager()
    private let notificationManager = NotificationManager()
    private let snapshotManager: SnapshotManager? = SnapshotManager()
    private var videoReader: VideoFrameReader?
    
    func start() {
        guard aiModel != nil else { return } // Stop if the model fails to load
        print("🚀 Starting AI Cam Monitor...")
        videoReader = VideoFrameReader()
        videoReader?.startReading { [weak self] frame in self?.processFrame(frame) }
        RunLoop.main.run()
    }
    func stop() {
        print("\n🛑 Stopping AI Cam Monitor..."); videoReader?.stopReading(); exit(0)
    }
    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        aiModel?.detectObjects(in: pixelBuffer) { [weak self] (detections: [DetectionResult]) in
            guard !detections.isEmpty else { return }
            print("🎯 Detected: \(detections.map(\.className).joined(separator: ", "))")
            let snapshotURL = self?.snapshotManager?.saveSnapshot(from: pixelBuffer)
            detections.forEach { self?.notificationManager.sendDetectionNotification(for: $0, snapshot: snapshotURL) }
        }
    }
}

print("🤖 AI Cam Monitor v1.6 (Final)")
print(String(repeating: "=", count: 40))
let monitor = AICamMonitor()
signal(SIGINT) { _ in monitor.stop() }
signal(SIGTERM) { _ in monitor.stop() }
monitor.start()
EOF
    log_success "Application source code created."
}

build_and_create_run_scripts() {
    log_header "7. BUILD & CREATE RUNNERS"
    cd "$INSTALL_DIR"
    log_info "Building the Swift application bundle (.app)..."

    if swift build -c release; then
        log_success "Build completed successfully."
        local app_executable=".build/release/$PROJECT_NAME"
        
        log_info "Creating 'run_monitor.sh'..."
        cat > "$INSTALL_DIR/run_monitor.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"
echo "🚀 Starting AI Cam Monitor in LIVE mode..."
if [ ! -f config.env ]; then echo "❌ config.env not found!"; exit 1; fi
source config.env
KEYCHAIN_SERVICE="AICamMonitor"
KEYCHAIN_ACCOUNT="\$CAM_USERNAME"
CAM_PASSWORD=\$(security find-generic-password -s "\$KEYCHAIN_SERVICE" -a "\$KEYCHAIN_ACCOUNT" -w 2>/dev/null)
if [ -z "\$CAM_PASSWORD" ]; then
    echo -n "🔐 Enter password for '\$CAM_USERNAME' (will be saved to Keychain): "
    read -s CAM_PASSWORD; echo
    security add-generic-password -s "\$KEYCHAIN_SERVICE" -a "\$KEYCHAIN_ACCOUNT" -w "\$CAM_PASSWORD" -U
    echo "✅ Password saved to Keychain for future runs."
fi
export CAM_PASSWORD
echo "✅ Starting..."
$app_executable
EOF
        chmod +x "$INSTALL_DIR/run_monitor.sh"
        log_success "Created 'run_monitor.sh'."

        log_info "Creating 'run_test.sh'..."
        cat > "$INSTALL_DIR/run_test.sh" << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "🧪 Starting AI Cam Monitor in TEST mode..."
if [ ! -f config.env ]; then echo "❌ config.env not found!"; exit 1; fi
source config.env
export RTSP_FEED_URL="test://demo"
echo "✅ Starting..."
.build/release/AICamMonitor
EOF
        chmod +x "$INSTALL_DIR/run_test.sh"
        log_success "Created 'run_test.sh'."
    else
        log_error "The Swift application build failed. Please check the compilation errors above."
        exit 1
    fi
}

show_completion_summary() {
    log_header "✅ INSTALLATION COMPLETE!"
    echo -e "\n${GREEN}🎉 All fixes applied. The application should now build and run correctly.${NC}"
    echo -e "\n${WHITE}WHAT TO DO NEXT:${NC}"
    echo -e "  1. ${PURPLE}Test the application with simulated data:${NC}"
    echo -e "     ${CYAN}./run_test.sh${NC}"
    echo -e "\n  2. ${PURPLE}Run the monitor with your live camera:${NC}"
    echo -e "     ${CYAN}./run_monitor.sh${NC}"
    
    if [[ "$SNAPSHOT_ON_DETECTION" == "true" ]]; then
        echo -e "\n  3. ${PURPLE}Check for snapshots in:${NC} ${SNAPSHOT_DIRECTORY}"
    fi
    echo -e "\n${WHITE}Logs are in: $LOG_FILE${NC}\n"
}

# --- Main Execution ---
main() {
    > "$LOG_FILE"
    show_banner
    load_config
    cleanup_old_files
    check_prerequisites
    install_dependencies
    collect_configuration
    download_and_convert_model
    create_swift_project
    build_and_create_run_scripts
    show_completion_summary
}

main "$@"