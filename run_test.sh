#!/bin/bash
# Build and run the AICamMonitor application.
# Manages the Python UDS server and the Swift UDS client.
set -euo pipefail

PROJECT_NAME="AICamMonitor"
PYTHON_GRABBER="frame_grabber.py"
SOCKET_PATH="/tmp/aicam.sock"

# --- UI ---
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Cleanup Function ---
cleanup() {
    echo -e "\n${BLUE}--- Shutting down... ---${NC}"
    # Kill the Python background process
    if [ ! -z "${PYTHON_PID:-}" ]; then
        echo " > Stopping Python frame grabber (PID: $PYTHON_PID)..."
        kill "$PYTHON_PID" 2>/dev/null || true
    fi
    # Clean up the socket file
    if [ -e "$SOCKET_PATH" ]; then
        echo " > Cleaning up socket file..."
        rm -f "$SOCKET_PATH"
    fi
    echo "--- Shutdown complete. ---"
}

# Trap Ctrl+C (SIGINT) and script exit to run the cleanup function
trap cleanup SIGINT EXIT

# --- Main Script ---

echo -e "${BLUE}--- Preparing environment... ---${NC}"
# Ensure the socket is clean before starting
rm -f "$SOCKET_PATH"
echo " > Socket path is clean."

# Activate python virtual environment
source .venv/bin/activate
echo " > Python virtual environment activated."

echo -e "\n${BLUE}--- Starting Python Frame Grabber in background... ---${NC}"
python3 "$PYTHON_GRABBER" &
PYTHON_PID=$!
echo " > Frame Grabber started with PID: $PYTHON_PID"

echo -e "\n${BLUE}--- Building $PROJECT_NAME... ---${NC}"
if swift build; then
    echo -e "\n${GREEN}--- Build Succeeded. Running Swift AI Processor... ---${NC}"
    echo -e "${YELLOW}--- Press Ctrl+C to stop both processes. ---${NC}"
    swift run $PROJECT_NAME
else
    echo -e "\n${RED}--- Build Failed ---${NC}"
    exit 1
fi
