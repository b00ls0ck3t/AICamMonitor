#!/bin/bash
# AI Cam Monitor - Final One-Time Setup Script
# This script prepares the project by installing dependencies and, most importantly,
# explicitly compiling the Core ML model to ensure it's usable by the application.
set -euo pipefail

# --- Configuration ---
INSTALL_DIR=$(pwd)
PROJECT_NAME="AICamMonitor"
SRC_DIR="$INSTALL_DIR/src"
APP_SRC_DIR="$SRC_DIR/$PROJECT_NAME"
LOG_FILE="$INSTALL_DIR/setup.log"
YOLO_VARIANT="n"
MODEL_PACKAGE="yolov8${YOLO_VARIANT}.mlpackage"
COMPILED_MODEL="yolov8${YOLO_VARIANT}.mlmodelc"

# --- UI ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}--- Starting AI Cam Monitor One-Time Setup ---${NC}" | tee "$LOG_FILE"

# --- 1. Dependencies ---
echo "[1/3] Setting up dependencies..." | tee -a "$LOG_FILE"
if ! command -v brew >/dev/null 2>&1; then
    echo "   > Homebrew not found. Installing..." | tee -a "$LOG_FILE"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
brew install coreutils >/dev/null 2>&1
# Set up Python virtual environment for Ultralytics
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip >/dev/null 2>&1
pip install ultralytics coremltools >/dev/null 2>&1
deactivate
echo "   > Dependencies are ready." | tee -a "$LOG_FILE"

# --- 2. AI Model Download & COMPILE ---
echo "[2/3] Setting up and Compiling AI Model..." | tee -a "$LOG_FILE"
if [ ! -d "$INSTALL_DIR/$COMPILED_MODEL" ]; then
    echo "   > AI model not compiled. Starting process..." | tee -a "$LOG_FILE"
    if [ ! -d "$INSTALL_DIR/$MODEL_PACKAGE" ]; then
        echo "   > Downloading model from Ultralytics..." | tee -a "$LOG_FILE"
        source .venv/bin/activate
        python -c "from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='coreml', nms=True, half=True)" >> "$LOG_FILE" 2>&1
        deactivate
    fi

    echo "   > Compiling model with CoreML tools (this is the crucial fix)..." | tee -a "$LOG_FILE"
    # Create a temporary Swift script to compile the model
    cat > "compile_model.swift" << EOF
import CoreML
import Foundation
let modelURL = URL(fileURLWithPath: "$MODEL_PACKAGE")
do {
    let compiledURL = try MLModel.compileModel(at: modelURL)
    _ = try? FileManager.default.removeItem(at: URL(fileURLWithPath: "$COMPILED_MODEL"))
    try FileManager.default.moveItem(at: compiledURL, to: URL(fileURLWithPath: "$COMPILED_MODEL"))
} catch {
    print("Error compiling model: \(error)")
    exit(1)
}
EOF
    # Run the Swift compiler script
    if ! swift compile_model.swift >> "$LOG_FILE" 2>&1; then
        echo -e "${RED}FATAL: Failed to compile the CoreML model. Check setup.log for details.${NC}"
        rm compile_model.swift; exit 1
    fi
    echo -e "   > ${GREEN}Model successfully compiled to '$COMPILED_MODEL'${NC}" | tee -a "$LOG_FILE"
else
    echo "   > Compiled AI model already exists." | tee -a "$LOG_FILE"
fi

# --- 3. Project Structure & Cleanup ---
echo "[3/3] Creating project files and cleaning up..." | tee -a "$LOG_FILE"
rm -rf "$APP_SRC_DIR" # Clean out old source directory to be safe
mkdir -p "$APP_SRC_DIR/Resources"
# Copy the PRE-COMPILED model into the resources
cp -r "$INSTALL_DIR/$COMPILED_MODEL" "$APP_SRC_DIR/Resources/"

# This is the manifest file for the Swift Package Manager
cat > "$INSTALL_DIR/Package.swift" << EOF
// swift-tools-version: 5.7
import PackageDescription
let package = Package(name: "$PROJECT_NAME", platforms: [.macOS(.v12)],
    targets: [.executableTarget(name: "$PROJECT_NAME", path: "src/$PROJECT_NAME", resources: [.process("Resources")])])
EOF

# This creates the main application file with the correct code
cat > "$APP_SRC_DIR/main.swift" << 'EOF'
import Foundation
import Vision
import CoreML

class AIModelManager {
    private let model: VNCoreMLModel
    init?() {
        guard let modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc") else {
            print("❌ Critical Error: Could not find 'yolov8n.mlmodelc' in the app's resource bundle.")
            return nil
        }
        do {
            let mlModel = try MLModel(contentsOf: modelURL)
            self.model = try VNCoreMLModel(for: mlModel)
            print("✅ Pre-compiled AI model loaded successfully.")
        } catch {
            print("❌ Failed to load model from '\(modelURL)': \(error)"); return nil
        }
    }
    
    func testDetection() {
        print("🔬 Model is loaded and ready for detection logic.")
    }
}

// --- Main Entry Point ---
print("🤖 AI Cam Monitor v5.0 (Stable)")
print(String(repeating: "=", count: 40))

guard let modelManager = AIModelManager() else {
    print("Stopping due to model loading failure."); exit(1)
}

modelManager.testDetection()
print("🎉 IT WORKED! The model loaded successfully.")
print("   The core issue is resolved. You can now add full app logic to this file.")
EOF

# --- Final Cleanup ---
# Remove all temporary and source files, leaving only the essentials
rm -rf .venv compile_model.swift "$MODEL_PACKAGE" "$COMPILED_MODEL" yolov8n.pt
log_info "   > Cleanup complete."

echo -e "\n${GREEN}--- Setup Complete! ---${NC}" | tee -a "$LOG_FILE"
echo -e "${YELLOW}The project is ready. Use './run_test.sh' to build and test your code.${NC}"