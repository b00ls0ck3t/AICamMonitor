#!/bin/bash
# Build and run the AICamMonitor application, logging output.
set -euo pipefail

PROJECT_NAME="AICamMonitor"
LOG_DIR="logs"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/monitor_$TIMESTAMP.log"

# --- UI ---
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

echo -e "${BLUE}--- Building $PROJECT_NAME... ---${NC}"
# Build quietly, only showing output on error
if ! swift build >/dev/null 2>&1; then
    echo -e "${RED}--- Build Failed. See details below. ---${NC}"
    # Rerun build with output to show the error
    swift build
    exit 1
fi

echo -e "${GREEN}--- Build Succeeded. Starting Monitor... ---${NC}"
echo "--- Logging to $LOG_FILE ---"
echo "--- Press Ctrl+C to stop the monitor. ---"

# Use 'exec' to run the application, redirecting both stdout and stderr to the log file
# 'tee' allows us to see the output on the console AND write it to the file.
exec swift run $PROJECT_NAME 2>&1 | tee "$LOG_FILE"