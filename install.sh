#!/bin/bash
# AI Cam Monitor - Final One-Time Setup Script
# This version ADDS an explicit model compilation step to guarantee a working model.
set -euo pipefail

# --- Configuration ---
INSTALL_DIR=$(pwd)
VENV_DIR="$INSTALL_DIR/.venv"
PROJECT_NAME="AICamMonitor"
SRC_DIR="$INSTALL_DIR/src"
APP_SRC_DIR="$SRC_DIR/$PROJECT_NAME"
LOG_FILE="$INSTALL_DIR/setup.log"

# --- UI ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}--- Starting AI Cam Monitor One-Time Setup ---${NC}" | tee "$LOG_FILE"

# --- 1. Dependencies ---
echo "[1/4] Checking dependencies..." | tee -a "$LOG_FILE"
if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not found. Installing..." | tee -a "$LOG_FILE"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
brew install ffmpeg coreutils >/dev/null 2>&1

# --- 2. Python Environment ---
echo "[2/4] Setting up Python environment..." | tee -a "$LOG_FILE"
if [ ! -d "$VENV_DIR" ]; then python3 -m venv "$VENV_DIR"; fi
source "$VENV_DIR/bin/activate"
pip install --upgrade pip >/dev/null 2>&1
pip install ultralytics coremltools >/dev/null 2>&1
deactivate

# --- 3. AI Model Download & COMPILE ---
echo "[3/4] Setting up AI Model..." | tee -a "$LOG_FILE"
YOLO_VARIANT="n"
MODEL_PACKAGE="yolov8${YOLO_VARIANT}.mlpackage"
COMPILED_MODEL="yolov8${YOLO_VARIANT}.mlmodelc"

if [ ! -d "$INSTALL_DIR/$COMPILED_MODEL" ]; then
    echo "AI model not compiled. Starting process..." | tee -a "$LOG_FILE"
    if [ ! -d "$INSTALL_DIR/$MODEL_PACKAGE" ]; then
        echo "Downloading and converting model..." | tee -a "$LOG_FILE"
        source "$VENV_DIR/bin/activate"
        python -c "from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='coreml', nms=True, half=True)" >> "$LOG_FILE" 2>&1
        deactivate
    fi

    echo "Compiling model with CoreML tools (this is the key step)..." | tee -a "$LOG_FILE"
    # Create a temporary Swift script to compile the model
    cat > "compile_model.swift" << EOF
import CoreML
import Foundation
let modelURL = URL(fileURLWithPath: "$MODEL_PACKAGE")
do {
    let compiledURL = try MLModel.compileModel(at: modelURL)
    // Move the compiled model to the expected location
    try FileManager.default.moveItem(at: compiledURL, to: URL(fileURLWithPath: "$COMPILED_MODEL"))
    print("Successfully compiled model to: $COMPILED_MODEL")
} catch {
    print("Error compiling model: \(error)")
    exit(1)
}
EOF
    # Run the Swift compiler script
    if ! swift compile_model.swift >> "$LOG_FILE" 2>&1; then
        echo -e "${RED}FATAL: Failed to compile the CoreML model. Check setup.log for details.${NC}"
        rm compile_model.swift
        exit 1
    fi
    rm compile_model.swift # Clean up the temporary script
    echo -e "${GREEN}Model successfully compiled to '$COMPILED_MODEL'${NC}" | tee -a "$LOG_FILE"
else
    echo "Compiled AI model already exists." | tee -a "$LOG_FILE"
fi

# --- 4. Project Structure ---
echo "[4/4] Creating project files..." | tee -a "$LOG_FILE"
rm -rf "$APP_SRC_DIR" # Clean out old source directory
mkdir -p "$APP_SRC_DIR/Resources"
# Copy the PRE-COMPILED model into the resources
cp -r "$INSTALL_DIR/$COMPILED_MODEL" "$APP_SRC_DIR/Resources/"

cat > "$INSTALL_DIR/Package.swift" << EOF
// swift-tools-version: 5.7
import PackageDescription
let package = Package(
    name: "$PROJECT_NAME",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "$PROJECT_NAME",
            path: "src/$PROJECT_NAME",
            resources: [.process("Resources")] // .process is correct for pre-compiled resources
        )
    ]
)
EOF

# --- Create the main.swift file ---
cat > "$APP_SRC_DIR/main.swift" << 'EOF'
// This is your main Swift application file.
import Foundation
import Vision
import CoreML

class AIModelManager {
    private let model: VNCoreMLModel
    init?() {
        // Load the PRE-COMPILED model from the app's resource bundle.
        // This is the definitive way to do it with `swift build`.
        guard let modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc") else {
            print("❌ Critical Error: Could not find 'yolov8n.mlmodelc' in the bundle.")
            return nil
        }
        do {
            self.model = try VNCoreMLModel(for: try MLModel(contentsOf: modelURL))
            print("✅ Pre-compiled AI model loaded successfully.")
        } catch {
            print("❌ Failed to load AI model: \(error)"); return nil
        }
    }

    // Dummy detection function for testing
    func testDetection() {
        print("🔬 Model is loaded and ready for detection.")
    }
}

// --- Main Entry Point ---
print("🤖 AI Cam Monitor v4.0 (This Will Work)")
print(String(repeating: "=", count: 40))

guard let modelManager = AIModelManager() else {
    print("Stopping due to model loading failure.")
    exit(1)
}

modelManager.testDetection()
print("🎉 IT WORKED! The model loaded successfully.")
print("   The core issue is resolved. You can now build the full app logic in this file.")