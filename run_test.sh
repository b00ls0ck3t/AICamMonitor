#!/bin/bash
# Build and run the AICamMonitor application.
# Manages the Python UDS server and the Swift UDS client.
set -euo pipefail

PROJECT_NAME="AICamMonitor"
PYTHON_GRABBER="frame_grabber.py"
SOCKET_PATH="/tmp/aicam.sock"
LOG_DIR="logs"
LOG_FILE="$LOG_DIR/monitor_$(date +%Y%m%d_%H%M%S).log"

# --- UI Colors ---
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Logging Function ---
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp][run_test.sh] $message" | tee -a "$LOG_FILE"
}

# --- Cleanup Function ---
cleanup() {
    log_message "Shutdown signal received"
    echo -e "\n${BLUE}--- Shutting down... ---${NC}"
    
    # Kill the Python background process
    if [[ ! -z "${PYTHON_PID:-}" ]]; then
        log_message "Stopping Python frame grabber (PID: $PYTHON_PID)"
        echo " > Stopping Python frame grabber (PID: $PYTHON_PID)..."
        kill "$PYTHON_PID" 2>/dev/null || true
        wait "$PYTHON_PID" 2>/dev/null || true
        log_message "Python process terminated"
    fi
    
    # Clean up the socket file
    if [[ -e "$SOCKET_PATH" ]]; then
        log_message "Cleaning up socket file: $SOCKET_PATH"
        echo " > Cleaning up socket file..."
        rm -f "$SOCKET_PATH"
    fi
    
    # Deactivate Python virtual environment
    if [[ "${VIRTUAL_ENV:-}" != "" ]]; then
        deactivate 2>/dev/null || true
        log_message "Python virtual environment deactivated"
    fi
    
    log_message "=== Shutdown complete ==="
    echo "--- Shutdown complete. ---"
    echo "Full session log: $LOG_FILE"
}

# Trap Ctrl+C (SIGINT) and script exit to run the cleanup function
trap cleanup SIGINT EXIT

# --- Setup Logging ---
mkdir -p "$LOG_DIR"
log_message "=== AI Cam Monitor Test Session Started ==="

# --- Main Script ---
log_message "Preparing environment..."
echo -e "${BLUE}--- Preparing environment... ---${NC}"

# Ensure the socket is clean before starting
rm -f "$SOCKET_PATH"
log_message "Socket path cleaned: $SOCKET_PATH"
echo " > Socket path is clean." | tee -a "$LOG_FILE"

# Check if virtual environment exists
if [[ ! -d ".venv" ]]; then
    log_message "Error: Python virtual environment not found"
    echo -e "${RED}Error: Python virtual environment (.venv) not found.${NC}"
    echo "Please run ./install.sh first to set up the environment."
    exit 1
fi

# Activate Python virtual environment
log_message "Activating Python virtual environment"
source .venv/bin/activate
echo " > Python virtual environment activated." | tee -a "$LOG_FILE"

# Verify required Python packages
log_message "Verifying Python dependencies..."
if ! python3 -c "import cv2, socket, struct, dotenv" 2>>"$LOG_FILE"; then
    log_message "Error: Missing required Python packages"
    echo -e "${RED}Error: Missing required Python packages. Run ./install.sh to fix.${NC}"
    exit 1
fi
log_message "Python dependencies verified"

log_message "Starting Python Frame Grabber in background..."
echo -e "\n${BLUE}--- Starting Python Frame Grabber in background... ---${NC}"

# Start Python frame grabber with output redirected to log file
python3 "$PYTHON_GRABBER" >> "$LOG_FILE" 2>&1 &
PYTHON_PID=$!
log_message "Frame Grabber started with PID: $PYTHON_PID"
echo " > Frame Grabber started with PID: $PYTHON_PID" | tee -a "$LOG_FILE"

# Give Python process time to initialize
sleep 2

# Check if Python process is still running
if ! kill -0 "$PYTHON_PID" 2>/dev/null; then
    log_message "Error: Python process died immediately after startup"
    echo -e "${RED}Error: Python frame grabber failed to start. Check the log file.${NC}"
    echo "Last few lines of log:"
    tail -10 "$LOG_FILE"
    exit 1
fi

log_message "Building Swift project..."
echo -e "\n${BLUE}--- Building $PROJECT_NAME... ---${NC}"

# Build Swift project with output to log
if swift build >> "$LOG_FILE" 2>&1; then
    log_message "Swift build completed successfully"
    echo -e "\n${GREEN}--- Build Succeeded. Running Swift AI Processor... ---${NC}"
    echo -e "${YELLOW}--- Press Ctrl+C to stop both processes. ---${NC}"
    echo "--- Monitoring log file: $LOG_FILE ---"
    echo ""
    
    log_message "Starting Swift AI processor"
    
    # Run Swift application with output to both console and log file
    swift run $PROJECT_NAME 2>&1 | while IFS= read -r line; do
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$line"  # Display on console
        echo "[$timestamp] $line" >> "$LOG_FILE"  # Write to log with timestamp
    done
    
else
    log_message "Swift build failed"
    echo -e "\n${RED}--- Build Failed ---${NC}"
    echo "Build errors:"
    tail -20 "$LOG_FILE"
    exit 1
fi