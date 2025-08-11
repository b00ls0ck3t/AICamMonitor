#!/bin/bash

# AI Cam Monitor Deployment Script
# This script sets up and runs a local AI-powered security camera monitoring solution for macOS

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration with defaults
PROJECT_NAME="${PROJECT_NAME:-AICamMonitor}"
YOLO_PT_MODEL_NAME="${YOLO_PT_MODEL_NAME:-yolov8n.pt}"
COREML_MODEL_NAME="${COREML_MODEL_NAME:-yolov8n.mlpackage}"
YOLO_MODEL_DOWNLOAD_URL="${YOLO_MODEL_DOWNLOAD_URL:-https://github.com/ultralytics/assets/releases/download/v8.2.0/yolov8n.pt}"
DETECTION_THRESHOLD="${DETECTION_THRESHOLD:-0.7}"
OBJECTS_TO_MONITOR="${OBJECTS_TO_MONITOR:-person}"
NOTIFICATION_COOLDOWN_SECONDS="${NOTIFICATION_COOLDOWN_SECONDS:-300}"
SNAPSHOT_ON_DETECTION="${SNAPSHOT_ON_DETECTION:-false}"
SNAPSHOT_DIRECTORY="${SNAPSHOT_DIRECTORY:-/tmp/ai_cam_snapshots}"

# Required variables (must be set)
RTSP_FEED_URL="${RTSP_FEED_URL:-}"
RTSP_CREDS="${RTSP_CREDS:-}"

# Logging
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="deploy_${TIMESTAMP}.log"

log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log_info() {
    log "${BLUE}[INFO]${NC} $1"
}

log_success() {
    log "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    log "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    log "${RED}[ERROR]${NC} $1"
}

cleanup() {
    if [[ "${1:-}" == "--clean" ]]; then
        log_info "Cleaning up project files..."
        rm -rf "$PROJECT_NAME" .venv deploy_*.log config.env 2>/dev/null || true
        log_success "Cleanup completed"
        exit 0
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running on macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script is designed for macOS only"
        exit 1
    fi
    
    # Check for Apple Silicon (recommended)
    if [[ "$(uname -m)" != "arm64" ]]; then
        log_warning "This project is optimized for Apple Silicon Macs"
    fi
    
    # Check macOS version (need 13.0+)
    macos_version=$(sw_vers -productVersion | cut -d. -f1)
    if [[ "$macos_version" -lt 13 ]]; then
        log_error "macOS 13 (Ventura) or later is required"
        exit 1
    fi
    
    # Check for required variables
    if [[ -z "$RTSP_FEED_URL" ]]; then
        log_error "RTSP_FEED_URL environment variable is required"
        log_info "Example: export RTSP_FEED_URL='rtsp://10.0.60.130:554/h264Preview_01_main'"
        exit 1
    fi
    
    if [[ -z "$RTSP_CREDS" ]]; then
        log_error "RTSP_CREDS environment variable is required"
        log_info "Example: export RTSP_CREDS='username:password'"
        exit 1
    fi
    
    # Check for Xcode command line tools
    if ! xcode-select -p >/dev/null 2>&1; then
        log_error "Xcode command line tools not found. Please install with: xcode-select --install"
        exit 1
    fi
    
    log_success "Prerequisites check completed"
}

install_homebrew() {
    if command -v brew >/dev/null 2>&1; then
        log_info "Homebrew already installed"
    else
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Add Homebrew to PATH for Apple Silicon Macs
        if [[ "$(uname -m)" == "arm64" ]]; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
            eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        
        log_success "Homebrew installed"
    fi
}

install_ffmpeg() {
    if command -v ffmpeg >/dev/null 2>&1; then
        log_info "FFmpeg already installed"
    else
        log_info "Installing FFmpeg..."
        brew install ffmpeg
        log_success "FFmpeg installed"
    fi
}

setup_python_environment() {
    if [[ -d ".venv" ]]; then
        log_info "Python virtual environment already exists"
    else
        log_info "Creating Python virtual environment..."
        python3 -m venv .venv
        log_success "Python virtual environment created"
    fi
    
    log_info "Activating virtual environment and installing packages..."
    source .venv/bin/activate
    
    # Install required packages
    pip install --upgrade pip
    pip install ultralytics coremltools torch torchvision
    
    log_success "Python packages installed"
}

create_model_converter() {
    cat > convert_model.py << 'EOF'
#!/usr/bin/env python3
"""
YOLOv8 to Core ML Model Converter
Converts YOLOv8 PyTorch model to Core ML format for use with Apple's Vision framework
"""

import sys
import os
from ultralytics import YOLO
import coremltools as ct

def convert_yolo_to_coreml(pt_model_path, output_path):
    """Convert YOLOv8 PyTorch model to Core ML format"""
    try:
        print(f"Loading YOLOv8 model from {pt_model_path}...")
        model = YOLO(pt_model_path)
        
        print("Converting to Core ML format...")
        # Export with optimizations for Apple Silicon
        success = model.export(
            format='coreml',
            imgsz=640,  # Standard YOLO input size
            int8=False,  # Use float16 for better performance on Neural Engine
            nms=True,    # Include NMS in the model
            half=True    # Use half precision for smaller model size
        )
        
        if success:
            # The export creates a .mlpackage directory
            expected_output = pt_model_path.replace('.pt', '.mlpackage')
            if os.path.exists(expected_output):
                if expected_output != output_path:
                    import shutil
                    if os.path.exists(output_path):
                        shutil.rmtree(output_path)
                    shutil.move(expected_output, output_path)
                print(f"Model successfully converted to {output_path}")
                return True
            else:
                print(f"Error: Expected output {expected_output} not found")
                return False
        else:
            print("Error: Model conversion failed")
            return False
            
    except Exception as e:
        print(f"Error converting model: {e}")
        return False

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python convert_model.py <input_pt_file> <output_mlpackage_path>")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    if not os.path.exists(input_file):
        print(f"Error: Input file {input_file} not found")
        sys.exit(1)
    
    success = convert_yolo_to_coreml(input_file, output_file)
    sys.exit(0 if success else 1)
EOF
    
    chmod +x convert_model.py
}

download_and_convert_model() {
    log_info "Setting up YOLO model..."
    
    # Download YOLOv8 model if not exists
    if [[ ! -f "$YOLO_PT_MODEL_NAME" ]]; then
        log_info "Downloading YOLOv8 model..."
        curl -L -o "$YOLO_PT_MODEL_NAME" "$YOLO_MODEL_DOWNLOAD_URL"
        log_success "YOLOv8 model downloaded"
    else
        log_info "YOLOv8 model already exists"
    fi
    
    # Convert to Core ML format if not exists
    if [[ ! -d "$COREML_MODEL_NAME" ]]; then
        log_info "Converting model to Core ML format..."
        source .venv/bin/activate
        python convert_model.py "$YOLO_PT_MODEL_NAME" "$COREML_MODEL_NAME"
        
        if [[ -d "$COREML_MODEL_NAME" ]]; then
            log_success "Model converted to Core ML format"
        else
            log_error "Model conversion failed"
            exit 1
        fi
    else
        log_info "Core ML model already exists"
    fi
}

create_swift_project() {
    if [[ -d "$PROJECT_NAME" ]]; then
        log_info "Swift project directory already exists"
    else
        log_info "Creating Swift project structure..."
        mkdir -p "$PROJECT_NAME"
        cd "$PROJECT_NAME"
        swift package init --type executable --name "$PROJECT_NAME"
        cd ..
        log_success "Swift project created"
    fi
    
    # Create Package.swift with dependencies
    cat > "$PROJECT_NAME/Package.swift" << EOF
// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "$PROJECT_NAME",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Add FFmpeg wrapper dependency here in the future
        // .package(url: "https://github.com/sunlubo/SwiftFFmpeg.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "$PROJECT_NAME",
            dependencies: [],
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
EOF
    
    # Create Resources directory and copy model
    mkdir -p "$PROJECT_NAME/Sources/$PROJECT_NAME/Resources"
    if [[ -d "$COREML_MODEL_NAME" ]]; then
        cp -r "$COREML_MODEL_NAME" "$PROJECT_NAME/Sources/$PROJECT_NAME/Resources/"
    fi
    
    # Copy main Swift file
    if [[ -f "main_app.swift" ]]; then
        cp "main_app.swift" "$PROJECT_NAME/Sources/$PROJECT_NAME/main.swift"
    else
        log_error "main_app.swift not found. Please ensure it's in the same directory as this script."
        exit 1
    fi
}

build_and_run() {
    log_info "Building Swift application..."
    cd "$PROJECT_NAME"
    
    # Set environment variables for the Swift app
    export RTSP_FEED_URL
    export RTSP_CREDS
    export DETECTION_THRESHOLD
    export OBJECTS_TO_MONITOR
    export NOTIFICATION_COOLDOWN_SECONDS
    export SNAPSHOT_ON_DETECTION
    export SNAPSHOT_DIRECTORY
    export COREML_MODEL_NAME
    
    # Create snapshot directory if needed
    if [[ "$SNAPSHOT_ON_DETECTION" == "true" ]]; then
        mkdir -p "$SNAPSHOT_DIRECTORY"
    fi
    
    swift build -c release
    
    if [[ $? -eq 0 ]]; then
        log_success "Build completed successfully"
        
        log_info "Starting AI Cam Monitor..."
        log_info "Configuration:"
        log_info "  RTSP Feed: $RTSP_FEED_URL"
        log_info "  Detection Threshold: $DETECTION_THRESHOLD"
        log_info "  Objects to Monitor: $OBJECTS_TO_MONITOR"
        log_info "  Notification Cooldown: ${NOTIFICATION_COOLDOWN_SECONDS}s"
        log_info "  Snapshot on Detection: $SNAPSHOT_ON_DETECTION"
        
        if [[ "$SNAPSHOT_ON_DETECTION" == "true" ]]; then
            log_info "  Snapshot Directory: $SNAPSHOT_DIRECTORY"
        fi
        
        log_warning "The application will request notification permissions on first run"
        log_info "Press Ctrl+C to stop the monitor"
        
        .build/release/"$PROJECT_NAME"
    else
        log_error "Build failed"
        exit 1
    fi
}

main() {
    log_info "Starting AI Cam Monitor deployment..."
    log_info "Timestamp: $TIMESTAMP"
    
    # Handle cleanup
    cleanup "$@"
    
    # Load config file if exists
    if [[ -f "config.env" ]]; then
        log_info "Loading configuration from config.env"
        source config.env
    fi
    
    check_prerequisites
    install_homebrew
    install_ffmpeg
    setup_python_environment
    create_model_converter
    download_and_convert_model
    create_swift_project
    build_and_run
    
    log_success "AI Cam Monitor deployment completed"
}

# Run main function with all arguments
main "$@"