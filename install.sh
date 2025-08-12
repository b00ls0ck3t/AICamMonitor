#!/bin/bash
# AI Cam Monitor - Streamlined One-Time Setup
set -euo pipefail

# --- Configuration ---
INSTALL_DIR=$(pwd)
LOG_FILE="$INSTALL_DIR/logs/setup.log"
YOLO_VARIANT="n"
COMPILED_MODEL="yolov8${YOLO_VARIANT}.mlmodelc"
DEST_DIR="$INSTALL_DIR/src/AICamMonitor/Resources"
KEYCHAIN_SERVICE="AICamMonitor"

# --- UI Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# --- Logging Function ---
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp][install.sh] $message" | tee -a "$LOG_FILE"
}

# --- Setup Logging ---
mkdir -p logs
echo "=== AI Cam Monitor Setup Started at $(date) ===" > "$LOG_FILE"

log_message "Starting streamlined AI Cam Monitor setup"
echo -e "${BLUE}--- AI Cam Monitor Setup ---${NC}"

# --- 1. Python Virtual Environment (Create if missing) ---
echo "[1/3] Checking Python environment..." | tee -a "$LOG_FILE"

if [[ ! -d ".venv" ]]; then
    log_message "Creating Python virtual environment..."
    if python3 -m venv .venv >> "$LOG_FILE" 2>&1; then
        log_message "Virtual environment created successfully"
    else
        log_message "Error creating virtual environment"
        echo -e "${RED}Error: Failed to create Python virtual environment${NC}"
        exit 1
    fi
    
    log_message "Installing Python packages..."
    source .venv/bin/activate
    
    if pip install --upgrade pip >> "$LOG_FILE" 2>&1; then
        log_message "pip upgraded successfully"
    else
        log_message "Warning: Could not upgrade pip, proceeding anyway"
    fi
    
    if pip install ultralytics coremltools opencv-python python-dotenv >> "$LOG_FILE" 2>&1; then
        log_message "Python packages installed successfully"
    else
        log_message "Error installing Python packages"
        echo -e "${RED}Error: Failed to install required Python packages${NC}"
        exit 1
    fi
    
    deactivate
    echo -e "   > ${GREEN}Python environment created and configured${NC}"
else
    log_message "Python virtual environment already exists, skipping creation"
    echo "   > Python environment already exists ✓"
    
    # Check if packages are installed
    source .venv/bin/activate
    if python3 -c "import cv2, ultralytics, coremltools" 2>/dev/null; then
        log_message "Required Python packages are already installed"
        echo "   > Required packages are installed ✓"
    else
        log_message "Some Python packages missing, installing..."
        pip install ultralytics coremltools opencv-python python-dotenv >> "$LOG_FILE" 2>&1
        log_message "Missing packages installed"
        echo "   > Missing packages installed ✓"
    fi
    deactivate
fi

# --- 2. Configuration Validation ---
echo "[2/3] Validating configuration..." | tee -a "$LOG_FILE"

if [[ ! -f "config.env" ]]; then
    log_message "Creating template config.env file"
    cat > config.env << 'EOF'
# AI Baby Monitor Configuration
RTSP_FEED_URL=rtsp://10.0.60.130:554/h264Preview_01_main
CAM_USERNAME=automation
OBJECTS_TO_MONITOR=person
DETECTION_THRESHOLD=0.3
FRAME_RATE=2
FRAME_WIDTH=1920
FRAME_HEIGHT=1080
SNAPSHOT_ON_DETECTION=true
SNAPSHOT_DIRECTORY=./BabyCaptures
NOTIFICATION_COOLDOWN=30
ALERT_RECIPIENT_1=+1234567890
ALERT_RECIPIENT_2=user@icloud.com
EOF
    echo -e "   > ${YELLOW}Template config.env created - please edit with your camera details${NC}"
    log_message "Template config.env created"
else
    log_message "config.env already exists"
    echo "   > Configuration file exists ✓"
fi

source config.env
if [[ -z "${CAM_USERNAME:-}" ]]; then
    log_message "Error: CAM_USERNAME is not set in config.env"
    echo -e "${RED}Error: Please edit config.env with your camera details first${NC}"
    exit 1
fi

# --- Keychain Password Setup ---
log_message "Checking camera password in Keychain..."

SHOULD_ADD_PASSWORD="false"
if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$CAM_USERNAME" >/dev/null 2>&1; then
    echo -e "   > ${GREEN}Password already stored in Keychain for '$CAM_USERNAME' ✓${NC}"
    log_message "Password already exists in Keychain for user: $CAM_USERNAME"
    read -p "Do you want to update the password? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$CAM_USERNAME" >/dev/null 2>&1
        SHOULD_ADD_PASSWORD="true"
        log_message "Existing password will be updated"
    fi
else
    SHOULD_ADD_PASSWORD="true"
fi

if [[ "${SHOULD_ADD_PASSWORD}" = "true" ]]; then
    echo -n "Enter camera password for '$CAM_USERNAME': "
    read -s CAM_PASSWORD
    echo
    if [[ -z "$CAM_PASSWORD" ]]; then
        log_message "Error: Password cannot be empty"
        echo -e "${RED}Error: Password cannot be empty${NC}"
        exit 1
    fi
    
    if security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$CAM_USERNAME" -w "$CAM_PASSWORD" >> "$LOG_FILE" 2>&1; then
        log_message "Password securely stored in macOS Keychain"
        echo -e "   > ${GREEN}Password stored in Keychain ✓${NC}"
    else
        log_message "Error storing password in Keychain"
        echo -e "${RED}Error: Could not store password in Keychain${NC}"
        exit 1
    fi
fi

# --- 3. AI Model Setup (Only if missing) ---
echo "[3/3] Checking AI Model..." | tee -a "$LOG_FILE"

mkdir -p "$DEST_DIR"

if [[ -f "$DEST_DIR/$COMPILED_MODEL/model.mlmodel" ]]; then
    log_message "Compiled AI model already exists, skipping download/compilation"
    echo -e "   > ${GREEN}AI model already compiled ✓${NC}"
else
    log_message "AI model not found, downloading and compiling..."
    echo "   > Downloading and compiling AI model (this may take a few minutes)..."
    
    source .venv/bin/activate
    
    # Download and export model
    python3 -c "
from ultralytics import YOLO
import sys
try:
    print('Downloading YOLOv8 model...')
    model = YOLO('yolov8n.pt')
    print('Exporting to CoreML format...')
    model.export(format='coreml', nms=True, half=True)
    print('Model export completed successfully')
except Exception as e:
    print(f'Error exporting model: {e}')
    sys.exit(1)
" >> "$LOG_FILE" 2>&1
    
    if [[ $? -ne 0 ]]; then
        log_message "Error downloading/exporting model"
        echo -e "${RED}Error: Failed to download/export model. Check logs/setup.log${NC}"
        deactivate
        exit 1
    fi
    
    deactivate
    
    # Compile model
    log_message "Compiling model with CoreML tools..."
    
    cat > "compile_model.swift" << EOF
import CoreML
import Foundation

let modelURL = URL(fileURLWithPath: "yolov8n.mlpackage")
let destDir = URL(fileURLWithPath: "$DEST_DIR")
let compiledPath = URL(fileURLWithPath: "$DEST_DIR/$COMPILED_MODEL")

do {
    print("Compiling model...")
    let compiledURL = try MLModel.compileModel(at: modelURL)
    
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    
    if FileManager.default.fileExists(atPath: compiledPath.path) {
        try FileManager.default.removeItem(at: compiledPath)
    }
    
    try FileManager.default.moveItem(at: compiledURL, to: compiledPath)
    print("Model successfully compiled to: \(compiledPath.path)")
    
} catch {
    print("Error compiling model: \(error)")
    exit(1)
}
EOF
    
    if swift compile_model.swift >> "$LOG_FILE" 2>&1; then
        log_message "Model successfully compiled"
        echo -e "   > ${GREEN}AI model compiled successfully ✓${NC}"
    else
        log_message "FATAL: Failed to compile the CoreML model"
        echo -e "${RED}FATAL: Failed to compile the CoreML model${NC}"
        rm -f compile_model.swift
        exit 1
    fi
    
    # Cleanup temporary files
    rm -f compile_model.swift yolov8n.pt
    rm -rf yolov8n.mlpackage
    log_message "Temporary files cleaned up"
fi

# --- Success ---
log_message "=== Setup completed successfully ==="
echo -e "\n${GREEN}--- Setup Complete! ---${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Edit config.env with your camera details (if not done already)"
echo "  2. Run: python3 calibrate_zone.py (to set up safe zone)"
echo "  3. Run: ./run_test.sh (to start monitoring)"
echo ""
echo "Logs: logs/setup.log"