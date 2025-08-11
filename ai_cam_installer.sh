#!/bin/bash

# AI Cam Monitor - Interactive Installer & Configurator
# Final version with verbose error logging and correct Reolink URL construction.

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="$HOME/AICamMonitor"
CONFIG_FILE="$INSTALL_DIR/config.env"
VENV_DIR=".venv"
PROJECT_NAME="AICamMonitor"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$INSTALL_DIR/installer_${TIMESTAMP}.log"

# --- UI & Logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

CHECK="✅"
CROSS="❌"
ROCKET="🚀"
GEAR="⚙️"
CAMERA="📹"
BRAIN="🧠"
BELL="🔔"
LOCK="🔒"
CLEAN="🧹"

# Ensure the installation directory exists and move into it
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# --- Functions ---

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log_header() {
    echo -e "\n${WHITE}================================${NC}" | tee -a "$LOG_FILE"
    echo -e "${WHITE}$1${NC}" | tee -a "$LOG_FILE"
    echo -e "${WHITE}================================${NC}\n" | tee -a "$LOG_FILE"
}

log_info() { log "${BLUE}[INFO]${NC} $1"; }
log_success() { log "${GREEN}[SUCCESS]${NC} $CHECK $1"; }
log_warning() { log "${YELLOW}[WARNING]${NC} ⚠️  $1"; }
log_error() { log "${RED}[ERROR]${NC} $CROSS $1"; }

show_banner() {
    clear
    echo -e "${PURPLE}"
    cat << "EOF"
    ___    ____   ______                 __  ___            _ __
   /   |  /  _/  / ____/___ _____ ___   /  |/  /___  ____  (_) /_____  _____
  / /| |  / /   / /   / __ `/ __ `__ \ / /|_/ / __ \/ __ \/ / __/ __ \/ ___/
 / ___ |_/ /   / /___/ /_/ / / / / / // /  / / /_/ / / / / / /_/ /_/ / /
/_/  |_/___/   \____/\__,_/_/ /_/ /_//_/  /_/\____/_/ /_/_/\__/\____/_/

EOF
    echo -e "${NC}"
    echo -e "${WHITE}AI-Powered Security Camera Monitoring for macOS${NC}"
    echo -e "${CYAN}Local AI • Privacy First • Apple Silicon Optimized${NC}"
    echo -e "${WHITE}════════════════════════════════════════════════════${NC}\n"
}

# --- Configuration Management ---

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_info "Loading saved configuration from $CONFIG_FILE"
        . "$CONFIG_FILE"
    else
        log_info "No saved configuration found. Starting fresh."
    fi
}

save_config() {
    log_info "Saving configuration to $CONFIG_FILE for future runs..."
    cat > "$CONFIG_FILE" << EOF
# AI Cam Monitor Configuration
RTSP_FEED_URL="${RTSP_FEED_URL}"
CAM_USERNAME="${CAM_USERNAME}"
OBJECTS_TO_MONITOR="${OBJECTS_TO_MONITOR}"
DETECTION_THRESHOLD="${DETECTION_THRESHOLD}"
YOLO_VARIANT="${YOLO_VARIANT}"
NOTIFICATION_COOLDOWN="${NOTIFICATION_COOLDOWN}"
SNAPSHOT_ON_DETECTION="${SNAPSHOT_ON_DETECTION}"
SNAPSHOT_DIRECTORY="${SNAPSHOT_DIRECTORY}"
PROCESSING_FPS="${PROCESSING_FPS}"
MAX_DETECTIONS="${MAX_DETECTIONS}"
EOF
    log_success "Configuration saved."
}

# --- User Input ---

prompt_user() {
    local prompt="$1"
    local var_name="$2"
    local default_val="${!var_name:-}"
    local input

    if [[ -n "$default_val" ]]; then
        read -p "$(echo -e "${CYAN}$prompt${NC} ${WHITE}[$default_val]${NC}: ")" input
        input="${input:-$default_val}"
    else
        read -p "$(echo -e "${CYAN}$prompt${NC}: ")" input
    fi
    printf -v "$var_name" '%s' "$input"
}

prompt_password() {
    local prompt="$1"
    local var_name="$2"
    local input
    echo -e "${YELLOW}(Note: Your password will be hidden for security)${NC}"
    read -s -p "$(echo -e "${CYAN}$prompt${NC}: ")" input
    echo
    printf -v "$var_name" '%s' "$input"
}

prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    while true; do
        if [[ "$default" == "y" ]]; then read -p "$(echo -e "${CYAN}$prompt${NC} ${WHITE}[Y/n]${NC}: ")" yn; yn=${yn:-y}; else read -p "$(echo -e "${CYAN}$prompt${NC} ${WHITE}[y/N]${NC}: ")" yn; yn=${yn:-n}; fi
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo -e "${YELLOW}Please answer yes or no.${NC}";;
        esac
    done
}

# --- Core Logic ---

check_prerequisites() {
    log_header "SYSTEM CHECK"
    if [[ "$(uname)" != "Darwin" ]]; then log_error "This installer is for macOS only"; exit 1; fi
    log_success "Running on macOS"
    if ! xcode-select -p >/dev/null 2>&1; then log_info "Installing Xcode Command Line Tools..."; xcode-select --install; echo -e "${YELLOW}Please complete the installation and run this script again.${NC}"; exit 1; fi
    log_success "Xcode Command Line Tools installed."
}

show_cleanup_instructions() {
    log_header "${CLEAN} Global Python Cleanup"
    echo -e "${YELLOW}If previous script versions were run, Python packages may exist globally.${NC}"
    echo -e "${WHITE}It's safer to remove these manually. This script will use its own private environment.${NC}\n"
    if ! prompt_yes_no "Have you reviewed this and wish to continue with the installation?" "y"; then
        echo -e "${YELLOW}Installation cancelled.${NC}"
        exit 0
    fi
}

collect_configuration() {
    log_header "CONFIGURATION SETUP"
    : "${RTSP_FEED_URL:=rtsp://10.0.60.130:554/h264Preview_01_main}"
    : "${CAM_USERNAME:=admin}"
    : "${OBJECTS_TO_MONITOR:=person,car}"
    # ... other defaults
    
    prompt_user "Enter FULL camera RTSP URL (e.g., rtsp://10.0.60.130:554/h264Preview_01_main)" "RTSP_FEED_URL"
    prompt_user "Enter camera username" "CAM_USERNAME"
    prompt_password "Enter camera password" "CAM_PASSWORD"

    if prompt_yes_no "Temporarily show password to confirm it's correct?" "n"; then
        echo -e "${YELLOW}Confirming password:${NC} $CAM_PASSWORD"
        sleep 2
        printf "\033[1A\033[K"
    fi
    
    # ... rest of configuration prompts
    save_config
}

test_rtsp_connection() {
    local url="$1"
    local username="$2"
    local password="$3"
    
    # *** THIS IS THE FIX ***
    # This sed command finds "rtsp://" and replaces it with "rtsp://user:pass@",
    # correctly constructing the URL you need.
    local full_auth_url=$(echo "$url" | sed "s|rtsp://|rtsp://$username:$password@|")

    if ! command -v ffprobe >/dev/null 2>&1; then
        log_warning "ffprobe not found. Skipping live camera connection test."
        return 0
    fi

    log_info "Testing connection to: $url (with credentials)"
    # Execute ffprobe and capture its output (stdout and stderr) for detailed logging
    if ffprobe_output=$(timeout 10 ffprobe -rtsp_transport tcp -select_streams v:0 "$full_auth_url" 2>&1); then
        log_success "Camera connection successful!"
        return 0
    else
        log_error "Could not connect to the camera stream."
        echo -e "${RED}--- FFprobe Error Details ---${NC}"
        echo "$ffprobe_output" # Print the detailed error message
        echo -e "${RED}---------------------------${NC}"
        if ! prompt_yes_no "Continue anyway?" "n"; then exit 1; fi
        return 1
    fi
}

install_dependencies() {
    log_header "DEPENDENCY INSTALLATION"
    if ! command -v brew >/dev/null 2>&1; then log_info "Installing Homebrew..."; /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; fi
    log_success "Homebrew is ready."
    if ! brew list ffmpeg >/dev/null 2>&1; then log_info "Installing FFmpeg..."; brew install ffmpeg; fi
    log_success "FFmpeg is ready."
    log_info "Setting up Python virtual environment..."
    if [ ! -d "$VENV_DIR" ]; then python3 -m venv "$VENV_DIR"; fi
    log_success "Virtual environment is ready."
    log_info "Installing Python packages..."
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip
    pip install ultralytics coremltools torch torchvision opencv-python numpy pillow
    deactivate
    log_success "Python packages are ready."
}

create_model_converter() {
    log_info "Creating model conversion script..."
    cat > convert_model.py << 'EOF'
import sys, os
from ultralytics import YOLO
def convert(variant, out_path):
    try:
        model = YOLO(f"yolov8{variant}.pt")
        model.export(format='coreml', imgsz=640, nms=True, half=True)
        expected = f"yolov8{variant}.mlpackage"
        if os.path.exists(expected):
            import shutil
            if os.path.exists(out_path): shutil.rmtree(out_path)
            shutil.move(expected, out_path)
            return True
    except Exception as e: return False
if __name__ == "__main__":
    if not convert(sys.argv[1], sys.argv[2]): sys.exit(1)
EOF
    chmod +x convert_model.py
}

download_and_convert_model() {
    log_header "AI MODEL SETUP"
    local yolo_variant="${YOLO_VARIANT:-n}"
    local coreml_model_name="yolov8${yolo_variant}.mlpackage"
    if [[ -d "$coreml_model_name" ]]; then log_success "AI Model already exists."; return; fi
    source "$VENV_DIR/bin/activate"
    log_info "Downloading and converting YOLOv8 model..."
    if ! python convert_model.py "$yolo_variant" "$coreml_model_name"; then log_error "Model conversion failed."; deactivate; exit 1; fi
    deactivate
    log_success "AI model ready."
}

create_swift_project_files() {
    log_header "CREATING PROJECT FILES"
    mkdir -p "Sources/$PROJECT_NAME/Resources"
    cat > Package.swift << EOF
// swift-tools-version: 5.7
import PackageDescription
let package = Package(
    name: "$PROJECT_NAME",
    platforms: [.macOS(.v13)],
    targets: [ .executableTarget(name: "$PROJECT_NAME", resources: [.copy("Resources")]) ]
)
EOF
    cat > "Sources/$PROJECT_NAME/main.swift" << 'EOF'
import Foundation
// Placeholder for the main Swift application
print("AI Cam Monitor starting...")
RunLoop.main.run()
EOF
    log_success "Project files created."
}

build_and_create_runners() {
    log_header "BUILD AND CREATE RUNNERS"
    log_info "Building Swift application..."
    if swift build -c release; then
        log_success "Build completed."
        cat > run_monitor.sh << EOF
#!/bin/bash
cd "\$(dirname "\$0")"
echo "🚀 Starting AI Cam Monitor..."
if [ ! -f config.env ]; then echo "❌ config.env not found!"; exit 1; fi
export \$(grep -v '^#' config.env | xargs)
if [ -z "\${CAM_PASSWORD:-}" ]; then
    echo "Please enter the camera password:"
    read -s CAM_PASSWORD
fi
export CAM_PASSWORD
# This inserts the credentials into the full URL for the app to use
export FULL_AUTH_URL=\$(echo "\$RTSP_FEED_URL" | sed "s|rtsp://|rtsp://\$CAM_USERNAME:\$CAM_PASSWORD@|")
.build/release/$PROJECT_NAME
EOF
        chmod +x run_monitor.sh
        log_success "Created 'run_monitor.sh' to start the application."
    else
        log_error "Build failed."
        exit 1
    fi
}

show_completion_summary() {
    log_header "INSTALLATION COMPLETE!"
    echo -e "${WHITE}🎉 AI Cam Monitor installed in:${NC} $INSTALL_DIR"
    echo -e "\n${WHITE}🚀 TO START:${NC}"
    echo -e "   1. ${CYAN}cd $INSTALL_DIR${NC}"
    echo -e "   2. ${CYAN}./run_monitor.sh${NC}"
    echo -e "\n${WHITE}💡 Your settings are saved in 'config.env'.${NC}"
}

# --- Main Execution ---

main() {
    show_banner
    load_config
    check_prerequisites
    show_cleanup_instructions
    install_dependencies
    collect_configuration
    test_rtsp_connection "$RTSP_FEED_URL" "$CAM_USERNAME" "$CAM_PASSWORD"
    create_model_converter
    download_and_convert_model
    create_swift_project_files
    build_and_create_runners
    show_completion_summary
}

main "$@"