#!/bin/bash
# Build and run the AICamMonitor application.
# Includes a cleaning step to prevent build cache errors.
set -euo pipefail

PROJECT_NAME="AICamMonitor"
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}--- Cleaning build cache... ---${NC}"
swift package clean

echo -e "${BLUE}--- Building $PROJECT_NAME... ---${NC}"
if swift build; then
    echo -e "\n${GREEN}--- Build Succeeded. Running application... ---${NC}"
    swift run $PROJECT_NAME
else
    echo -e "\n${RED}--- Build Failed ---${NC}"
    exit 1
fi