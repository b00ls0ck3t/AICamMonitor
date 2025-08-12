#!/bin/bash
# AI Cam Monitor - One-Time Environment Setup
set -euo pipefail

# --- Configuration ---
INSTALL_DIR=$(pwd)
LOG_FILE="$INSTALL_DIR/logs/setup.log"
YOLO_VARIANT="n"
MODEL_PACKAGE="yolov8${YOLO_VARIANT}.mlpackage"
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

log_message "Starting AI Cam Monitor One-Time Setup"
echo -e "${BLUE}--- Starting AI Cam Monitor One-Time Setup ---${NC}"

# --- 1. System Dependencies ---
log_message "[1/4] Setting up system dependencies (Homebrew, ffmpeg)..."
echo "[1/4] Setting up system dependencies..." | tee -a "$LOG_FILE"

if ! command -v brew >/dev/null 2>&1; then
    log_message "Homebrew not found. Installing..."
    echo "   > Installing Homebrew..." | tee -a "$LOG_FILE"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >> "$LOG_FILE" 2>&1
    
    # Add Homebrew to PATH for this session
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        log_message "Added Apple Silicon Homebrew to PATH"
    elif [[ -f "/usr/local/bin/brew" ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
        log_message "Added Intel Homebrew to PATH"
    fi
fi

log_message "Installing/updating ffmpeg and coreutils via Homebrew..."
if brew install coreutils ffmpeg >> "$LOG_FILE" 2>&1; then
    log_message "System dependencies installed successfully"
else
    log_message "Error installing system dependencies - check setup.log"
    echo -e "${RED}Error: Failed to install system dependencies. Check logs/setup.log${NC}"
    exit 1
fi

# --- 2. Python Virtual Environment ---
log_message "[2/4] Setting up Python virtual environment..."
echo "[2/4] Setting up Python virtual environment..." | tee -a "$LOG_FILE"

# Remove existing venv if it exists and is broken
if [[ -d ".venv" ]]; then
    log_message "Removing existing virtual environment..."
    rm -rf .venv
fi

log_message "Creating new Python virtual environment..."
if python3 -m venv .venv >> "$LOG_FILE" 2>&1; then
    log_message "Virtual environment created successfully"
else
    log_message "Error creating virtual environment"
    echo -e "${RED}Error: Failed to create Python virtual environment${NC}"
    exit 1
fi

log_message "Activating virtual environment and installing Python packages..."
source .venv/bin/activate

# Upgrade pip first
if pip install --upgrade pip >> "$LOG_FILE" 2>&1; then
    log_message "pip upgraded successfully"
else
    log_message "Warning: Could not upgrade pip, proceeding anyway"
fi

# Install required packages
if pip install ultralytics coremltools opencv-python python-dotenv >> "$LOG_FILE" 2>&1; then
    log_message "Python packages installed successfully"
    pip list >> "$LOG_FILE" 2>&1
else
    log_message "Error installing Python packages"
    echo -e "${RED}Error: Failed to install required Python packages${NC}"
    deactivate
    exit 1
fi

deactivate
log_message "Python environment setup complete"

# --- 3. Configuration Validation ---
log_message "[3/4] Validating configuration..."
echo "[3/4] Validating configuration..." | tee -a "$LOG_FILE"

if [[ ! -f "config.env" ]]; then
    log_message "Error: config.env not found"
    echo -e "${RED}Error: config.env not found. Please create it before running this script.${NC}"
    echo "Example config.env:" | tee -a "$LOG_FILE"
    cat >> "$LOG_FILE" << 'EOF'
RTSP_FEED_URL=rtsp://192.168.1.100:554/h264Preview_01_main
CAM_USERNAME=your_username
OBJECTS_TO_MONITOR=person,car,truck
DETECTION_THRESHOLD=0.4
SNAPSHOT_DIRECTORY=./Captures
SNAPSHOT_ON_DETECTION=true
NOTIFICATION_COOLDOWN=10
FRAME_RATE=1
EOF
    exit 1
fi

source config.env
if [[ -z "${CAM_USERNAME:-}" ]]; then
    log_message "Error: CAM_USERNAME is not set in config.env"
    echo -e "${RED}Error: CAM_USERNAME is not set in config.env.${NC}"
    exit 1
fi

log_message "Configuration file validated successfully"

# --- Keychain Setup ---
log_message "Setting up secure credential storage in macOS Keychain..."

SHOULD_ADD_PASSWORD="false"
if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$CAM_USERNAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}A password for user '$CAM_USERNAME' already exists in the Keychain.${NC}"
    log_message "Password already exists in Keychain for user: $CAM_USERNAME"
    read -p "Do you want to update it? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$CAM_USERNAME" >/dev/null 2>&1
        SHOULD_ADD_PASSWORD="true"
        log_message "Existing password will be updated"
    else
        log_message "Skipping Keychain update per user request"
    fi
else
    SHOULD_ADD_PASSWORD="true"
fi

if [[ "${SHOULD_ADD_PASSWORD}" = "true" ]]; then
    echo -n "Please enter the password for camera user '$CAM_USERNAME': "
    read -s CAM_PASSWORD
    echo
    if [[ -z "$CAM_PASSWORD" ]]; then
        log_message "Error: Password cannot be empty"
        echo -e "${RED}Error: Password cannot be empty.${NC}"
        exit 1
    fi
    
    if security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$CAM_USERNAME" -w "$CAM_PASSWORD" >> "$LOG_FILE" 2>&1; then
        log_message "Password securely stored in macOS Keychain"
        echo -e "   > ${GREEN}Password securely stored in macOS Keychain.${NC}" | tee -a "$LOG_FILE"
    else
        log_message "Error storing password in Keychain"
        echo -e "${RED}Error: Could not store password in Keychain${NC}"
        exit 1
    fi
fi

# --- 4. AI Model Setup and Compilation ---
log_message "[4/4] Setting up and compiling AI Model..."
echo "[4/4] Setting up and compiling AI Model..." | tee -a "$LOG_FILE"

# Create Resources directory
mkdir -p "$DEST_DIR"

if [[ ! -f "$DEST_DIR/$COMPILED_MODEL/model.mlmodel" ]]; then
    log_message "AI model not compiled. Starting compilation process..."
    
    # Activate venv for model operations
    source .venv/bin/activate
    
    if [[ ! -d "$INSTALL_DIR/$MODEL_PACKAGE" ]]; then
        log_message "Downloading YOLO model from Ultralytics..."
        echo "   > Downloading model from Ultralytics..." | tee -a "$LOG_FILE"
        
        python3 -c "
from ultralytics import YOLO
import sys
try:
    model = YOLO('yolov8n.pt')
    model.export(format='coreml', nms=True, half=True)
    print('Model export completed successfully')
except Exception as e:
    print(f'Error exporting model: {e}')
    sys.exit(1)
" >> "$LOG_FILE" 2>&1
        
        if [[ $? -eq 0 ]]; then
            log_message "Model downloaded and exported successfully"
        else
            log_message "Error downloading/exporting model"
            echo -e "${RED}Error: Failed to download/export model. Check logs/setup.log${NC}"
            deactivate
            exit 1
        fi
    fi
    
    deactivate
    
    log_message "Compiling model with CoreML tools..."
    echo "   > Compiling model with CoreML tools..." | tee -a "$LOG_FILE"
    
    cat > "compile_model.swift" << EOF
import CoreML
import Foundation

let modelURL = URL(fileURLWithPath: "$MODEL_PACKAGE")
let destDir = URL(fileURLWithPath: "$DEST_DIR")
let compiledPath = URL(fileURLWithPath: "$DEST_DIR/$COMPILED_MODEL")

do {
    print("Compiling model at: \(modelURL.path)")
    let compiledURL = try MLModel.compileModel(at: modelURL)
    print("Model compiled to temporary location: \(compiledURL.path)")
    
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    
    // Remove existing compiled model if it exists
    if FileManager.default.fileExists(atPath: compiledPath.path) {
        try FileManager.default.removeItem(at: compiledPath)
        print("Removed existing compiled model")
    }
    
    try FileManager.default.moveItem(at: compiledURL, to: compiledPath)
    print("Model successfully moved to: \(compiledPath.path)")
    
} catch {
    print("Error compiling model: \(error)")
    exit(1)
}
EOF
    
    if swift compile_model.swift >> "$LOG_FILE" 2>&1; then
        log_message "Model successfully compiled to '$DEST_DIR/$COMPILED_MODEL'"
        echo -e "   > ${GREEN}Model successfully compiled${NC}" | tee -a "$LOG_FILE"
    else
        log_message "FATAL: Failed to compile the CoreML model"
        echo -e "${RED}FATAL: Failed to compile the CoreML model. Check logs/setup.log for details.${NC}"
        rm -f compile_model.swift
        exit 1
    fi
else
    log_message "Compiled AI model already exists at '$DEST_DIR/$COMPILED_MODEL'"
    echo "   > Compiled AI model already exists." | tee -a "$LOG_FILE"
fi

# --- Final Cleanup ---
log_message "Performing final cleanup..."
rm -f compile_model.swift
if [[ -f "yolov8n.pt" ]]; then
    rm -f "yolov8n.pt"
    log_message "Removed temporary model file"
fi
if [[ -d "$MODEL_PACKAGE" ]]; then
    rm -rf "$MODEL_PACKAGE"
    log_message "Removed temporary model package"
fi

log_message "Cleanup complete"

# --- Success ---
log_message "=== Setup completed successfully ==="
echo -e "\n${GREEN}--- Setup Complete! ---${NC}" | tee -a "$LOG_FILE"
echo -e "${YELLOW}The environment is ready. You can now run: ./run_test.sh${NC}"
echo "All logs are available in: logs/setup.log"