#!/bin/bash
# AI Cam Monitor - One-Time Environment Setup
set -euo pipefail

# --- Configuration ---
INSTALL_DIR=$(pwd)
LOG_FILE="$INSTALL_DIR/setup.log"
YOLO_VARIANT="n"
MODEL_PACKAGE="yolov8${YOLO_VARIANT}.mlpackage"
COMPILED_MODEL="yolov8${YOLO_VARIANT}.mlmodelc"
DEST_DIR="$INSTALL_DIR/src/AICamMonitor/Resources"
KEYCHAIN_SERVICE="AICamMonitor"

# --- UI ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}--- Starting AI Cam Monitor One-Time Setup ---${NC}" | tee "$LOG_FILE"

# --- 1. Dependencies ---
echo "[1/3] Setting up dependencies (Homebrew, ffmpeg, Python)..." | tee -a "$LOG_FILE"
if ! command -v brew >/dev/null 2>&1; then
    echo "   > Homebrew not found. Installing..." | tee -a "$LOG_FILE"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
brew install coreutils ffmpeg >/dev/null 2>&1
python3 -m venv .venv; source .venv/bin/activate
pip install --upgrade pip >/dev/null 2>&1; pip install ultralytics coremltools >/dev/null 2>&1
deactivate
echo "   > Dependencies are ready." | tee -a "$LOG_FILE"

# --- 2. Keychain Setup ---
echo "[2/3] Setting up secure credential storage..." | tee -a "$LOG_FILE"
if [ ! -f "config.env" ]; then
    echo -e "${RED}Error: config.env not found. Please create it before running this script.${NC}"
    exit 1
fi
source config.env
if [ -z "$CAM_USERNAME" ]; then
    echo -e "${RED}Error: CAM_USERNAME is not set in config.env.${NC}"
    exit 1
fi

if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$CAM_USERNAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}A password for user '$CAM_USERNAME' already exists in the Keychain.${NC}"
    read -p "Do you want to update it? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$CAM_USERNAME" >/dev/null 2>&1
        SHOULD_ADD_PASSWORD="true"
    else
        echo "   > Skipping Keychain update." | tee -a "$LOG_FILE"
        SHOULD_ADD_PASSWORD="false"
    fi
fi

if [ "${SHOULD_ADD_PASSWORD:-true}" = "true" ]; then
    echo -n "Please enter the password for camera user '$CAM_USERNAME': "
    read -s CAM_PASSWORD
    echo
    if [ -z "$CAM_PASSWORD" ]; then
        echo -e "${RED}Error: Password cannot be empty.${NC}"
        exit 1
    fi
    security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$CAM_USERNAME" -w "$CAM_PASSWORD"
    echo -e "   > ${GREEN}Password securely stored in macOS Keychain.${NC}" | tee -a "$LOG_FILE"
fi

# --- 3. AI Model Compile ---
echo "[3/3] Setting up and Compiling AI Model..." | tee -a "$LOG_FILE"
if [ ! -f "$DEST_DIR/$COMPILED_MODEL/model.mlmodel" ]; then
    echo "   > AI model not compiled. Starting process..." | tee -a "$LOG_FILE"
    if [ ! -d "$INSTALL_DIR/$MODEL_PACKAGE" ]; then
        echo "   > Downloading model from Ultralytics..." | tee -a "$LOG_FILE"
        source .venv/bin/activate
        python -c "from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='coreml', nms=True, half=True)" >> "$LOG_FILE" 2>&1
        deactivate
    fi

    echo "   > Compiling model with CoreML tools..." | tee -a "$LOG_FILE"
    cat > "compile_model.swift" << EOF
import CoreML
import Foundation
let modelURL = URL(fileURLWithPath: "$MODEL_PACKAGE")
do {
    let compiledURL = try MLModel.compileModel(at: modelURL)
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: "$DEST_DIR"), withIntermediateDirectories: true)
    _ = try? FileManager.default.removeItem(at: URL(fileURLWithPath: "$DEST_DIR/$COMPILED_MODEL"))
    try FileManager.default.moveItem(at: compiledURL, to: URL(fileURLWithPath: "$DEST_DIR/$COMPILED_MODEL"))
} catch {
    print("Error compiling model: \(error)")
    exit(1)
}
EOF
    if ! swift compile_model.swift >> "$LOG_FILE" 2>&1; then
        echo -e "${RED}FATAL: Failed to compile the CoreML model. Check setup.log for details.${NC}"
        rm compile_model.swift; exit 1
    fi
    echo -e "   > ${GREEN}Model successfully compiled to '$DEST_DIR/$COMPILED_MODEL'${NC}" | tee -a "$LOG_FILE"
else
    echo "   > Compiled AI model already exists." | tee -a "$LOG_FILE"
fi

# --- Final Cleanup ---
rm -rf .venv compile_model.swift "$MODEL_PACKAGE" "yolov8n.pt"
echo "   > Cleanup complete." | tee -a "$LOG_FILE"

echo -e "\n${GREEN}--- Setup Complete! ---${NC}" | tee -a "$LOG_FILE"
echo -e "${YELLOW}The environment is ready. You can now run the application.${NC}"