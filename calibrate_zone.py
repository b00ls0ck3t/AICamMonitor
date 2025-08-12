#!/usr/bin/env python3
"""
Safe Zone Calibration Tool for Baby Monitor

This script allows you to define a safe zone polygon by clicking points on a live camera feed.
The zone coordinates are saved to zone_config.json for use by the main monitoring application.

Usage: python3 calibrate_zone.py
"""

import cv2
import json
import os
import sys
import subprocess
from datetime import datetime
from dotenv import load_dotenv

# --- Get Version ID ---
def get_version_id():
    """Get git commit hash or fallback to timestamp"""
    try:
        result = subprocess.run([
            'git', 'rev-parse', '--short', 'HEAD'
        ], capture_output=True, text=True, check=True)
        
        commit_hash = result.stdout.strip()
        if commit_hash:
            return commit_hash
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    
    # Fallback to timestamp-based ID
    return f"v{datetime.now().strftime('%Y%m%d_%H%M%S')}"

VERSION_ID = get_version_id()

# Configuration
load_dotenv("config.env")
RTSP_URL = os.getenv("RTSP_FEED_URL")
CAM_USERNAME = os.getenv("CAM_USERNAME") 
CAM_PASSWORD = os.getenv("CAM_PASSWORD")
ZONE_CONFIG_FILE = "zone_config.json"

# Global state
points = []
current_frame = None
window_name = "Baby Monitor - Safe Zone Calibration"

def log_message(message):
    """Unified logging with timestamps and version"""
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    print(f"[{timestamp}][{VERSION_ID}][calibrate_zone] {message}")

def mouse_callback(event, x, y, flags, param):
    """Handle mouse clicks to define zone points"""
    global points, current_frame
    
    if event == cv2.EVENT_LBUTTONDOWN:
        # Add point (normalize to 0-1 range)
        if current_frame is not None:
            height, width = current_frame.shape[:2]
            norm_x = x / width
            norm_y = y / height
            points.append((norm_x, norm_y))
            log_message(f"Added point {len(points)}: ({x}, {y}) -> normalized ({norm_x:.3f}, {norm_y:.3f})")
            
            # Redraw frame with updated points
            draw_zone_overlay()
    
    elif event == cv2.EVENT_RBUTTONDOWN:
        # Remove last point
        if points:
            removed = points.pop()
            log_message(f"Removed point: {removed}")
            draw_zone_overlay()

def draw_zone_overlay():
    """Draw the current zone polygon on the frame"""
    global current_frame, points
    
    if current_frame is None:
        return
    
    # Create a copy to draw on
    display_frame = current_frame.copy()
    height, width = display_frame.shape[:2]
    
    # Convert normalized points back to pixel coordinates
    pixel_points = [(int(x * width), int(y * height)) for x, y in points]
    
    # Draw points
    for i, (x, y) in enumerate(pixel_points):
        cv2.circle(display_frame, (x, y), 8, (0, 255, 0), -1)
        cv2.putText(display_frame, str(i+1), (x+12, y+5), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
    
    # Draw polygon lines
    if len(pixel_points) > 1:
        for i in range(len(pixel_points)):
            start = pixel_points[i]
            end = pixel_points[(i + 1) % len(pixel_points)]
            cv2.line(display_frame, start, end, (0, 255, 255), 2)
    
    # Draw polygon fill (semi-transparent)
    if len(pixel_points) >= 3:
        overlay = display_frame.copy()
        cv2.fillPoly(overlay, [np.array(pixel_points)], (0, 255, 0, 50))
        cv2.addWeighted(display_frame, 0.7, overlay, 0.3, 0, display_frame)
    
    # Add instructions
    instructions = [
        "Left click: Add point",
        "Right click: Remove last point", 
        "S: Save zone",
        "R: Reset all points",
        "Q: Quit without saving",
        f"Points: {len(points)}/∞"
    ]
    
    y_offset = 30
    for instruction in instructions:
        cv2.putText(display_frame, instruction, (10, y_offset), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
        cv2.putText(display_frame, instruction, (10, y_offset), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 1)
        y_offset += 30
    
    cv2.imshow(window_name, display_frame)

def save_zone_config():
    """Save the current zone configuration to JSON"""
    if len(points) < 3:
        log_message("Error: Need at least 3 points to define a zone")
        return False
    
    # Ask for zone name
    print("\nEnter a name for this safe zone (e.g., 'crib center', 'bed safe area'): ", end="")
    zone_name = input().strip()
    if not zone_name:
        zone_name = f"Safe Zone {datetime.now().strftime('%Y%m%d_%H%M%S')}"
    
    config = {
        "name": zone_name,
        "created": datetime.now().isoformat(),
        "points": [{"x": x, "y": y} for x, y in points]
    }
    
    try:
        with open(ZONE_CONFIG_FILE, 'w') as f:
            json.dump(config, f, indent=2)
        log_message(f"Zone configuration saved to {ZONE_CONFIG_FILE}")
        log_message(f"Zone '{zone_name}' has {len(points)} points")
        return True
    except Exception as e:
        log_message(f"Error saving zone config: {e}")
        return False

def load_existing_zone():
    """Load existing zone if available"""
    global points
    
    if os.path.exists(ZONE_CONFIG_FILE):
        try:
            with open(ZONE_CONFIG_FILE, 'r') as f:
                config = json.load(f)
            
            points = [(point["x"], point["y"]) for point in config["points"]]
            log_message(f"Loaded existing zone '{config['name']}' with {len(points)} points")
            return True
        except Exception as e:
            log_message(f"Error loading existing zone: {e}")
            return False
    return False

def main():
    """Main calibration function"""
    global current_frame
    
    log_message("Safe Zone Calibration Tool starting...")
    
    # Validate configuration
    if not all([RTSP_URL, CAM_USERNAME, CAM_PASSWORD]):
        log_message("Error: Missing camera configuration in config.env")
        return 1
    
    # Check for existing zone
    if load_existing_zone():
        print(f"\nFound existing zone configuration with {len(points)} points.")
        response = input("Do you want to (E)dit existing zone or (N)ew zone? [E/n]: ").strip().upper()
        if response == 'N':
            points = []
            log_message("Starting fresh zone configuration")
        else:
            log_message("Editing existing zone")
    
    # Connect to camera
    auth_url = RTSP_URL.replace("rtsp://", f"rtsp://{CAM_USERNAME}:{CAM_PASSWORD}@")
    log_message("Connecting to camera stream...")
    
    cap = cv2.VideoCapture(auth_url)
    if not cap.isOpened():
        log_message("Error: Could not connect to camera stream")
        return 1
    
    # Configure capture
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    
    # Test frame read
    ret, test_frame = cap.read()
    if not ret:
        log_message("Error: Could not read frame from camera")
        cap.release()
        return 1
    
    height, width = test_frame.shape[:2]
    log_message(f"Camera connected successfully. Frame size: {width}x{height}")
    
    # Set up window
    cv2.namedWindow(window_name, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(window_name, min(1200, width), min(800, height))
    cv2.setMouseCallback(window_name, mouse_callback)
    
    log_message("=== Calibration Interface Ready ===")
    print("\nCalibration Instructions:")
    print("• Left click to add points for the safe zone boundary")
    print("• Right click to remove the last point") 
    print("• Press 'S' to save the zone")
    print("• Press 'R' to reset all points")
    print("• Press 'Q' to quit without saving")
    print("• You need at least 3 points to create a valid zone")
    print(f"• Zone will be saved to: {ZONE_CONFIG_FILE}")
    
    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                log_message("Error reading frame from camera")
                break
            
            current_frame = frame
            draw_zone_overlay()
            
            key = cv2.waitKey(30) & 0xFF
            
            if key == ord('q') or key == ord('Q'):
                log_message("Calibration cancelled by user")
                break
            elif key == ord('s') or key == ord('S'):
                if save_zone_config():
                    log_message("✅ Zone saved successfully! You can now run the monitor.")
                    break
                else:
                    log_message("❌ Failed to save zone. Need at least 3 points.")
            elif key == ord('r') or key == ord('R'):
                points = []
                log_message("Reset all points")
                draw_zone_overlay()
    
    except KeyboardInterrupt:
        log_message("Calibration interrupted by user")
    
    finally:
        cap.release()
        cv2.destroyAllWindows()
        log_message("Calibration tool shutting down")
    
    return 0

if __name__ == "__main__":
    import numpy as np
    sys.exit(main())