# AI Cam Monitor Configuration File
# Copy this to config.env and customize your settings

# REQUIRED: RTSP stream URL from your IP camera
# Examples:
# - Generic RTSP: rtsp://192.168.1.100:554/stream1
# - Hikvision: rtsp://192.168.1.100:554/h264Preview_01_main
# - Dahua: rtsp://192.168.1.100:554/cam/realmonitor?channel=1&subtype=0
# - Reolink: rtsp://192.168.1.100:554/h264Preview_01_main
RTSP_FEED_URL="rtsp://10.0.60.130:554/h264Preview_01_main"

# REQUIRED: RTSP credentials in format username:password
# Be careful with special characters - use URL encoding if needed
# Example: admin:MyP@ssw0rd becomes admin:MyP%40ssw0rd
RTSP_CREDS="admin:password123"

# OPTIONAL: Project name (default: AICamMonitor)
PROJECT_NAME="AICamMonitor"

# OPTIONAL: YOLO model settings
YOLO_PT_MODEL_NAME="yolov8n.pt"
COREML_MODEL_NAME="yolov8n.mlpackage"
YOLO_MODEL_DOWNLOAD_URL="https://github.com/ultralytics/assets/releases/download/v8.2.0/yolov8n.pt"

# OPTIONAL: Detection threshold (0.0-1.0, higher = more confident detections only)
DETECTION_THRESHOLD="0.7"

# OPTIONAL: Objects to monitor (comma-separated)
# Available objects: person, bicycle, car, motorcycle, airplane, bus, train, truck, boat,
# traffic light, fire hydrant, stop sign, parking meter, bench, bird, cat, dog, horse,
# sheep, cow, elephant, bear, zebra, giraffe, backpack, umbrella, handbag, tie, suitcase,
# frisbee, skis, snowboard, sports ball, kite, baseball bat, baseball glove, skateboard,
# surfboard, tennis racket, bottle, wine glass, cup, fork, knife, spoon, bowl, banana,
# apple, sandwich, orange, broccoli, carrot, hot dog, pizza, donut, cake, chair, couch,
# potted plant, bed, dining table, toilet, tv, laptop, mouse, remote, keyboard,
# cell phone, microwave, oven, toaster, sink, refrigerator, book, clock, vase, scissors,
# teddy bear, hair drier, toothbrush
OBJECTS_TO_MONITOR="person,cat,dog,car"

# OPTIONAL: Notification cooldown in seconds (prevents spam)
NOTIFICATION_COOLDOWN_SECONDS="300"

# OPTIONAL: Enable snapshot saving on detection (true/false)
SNAPSHOT_ON_DETECTION="true"

# OPTIONAL: Directory to save snapshots (will be created if doesn't exist)
SNAPSHOT_DIRECTORY="$HOME/Desktop/CameraSnapshots"