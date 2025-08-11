# AI Cam Monitor

A homegrown, local AI-powered security camera monitoring solution for macOS that leverages Apple Silicon's Neural Engine to detect objects from RTSP video feeds and send local notifications.

## 🚀 Features

- **Local AI Processing**: Uses Apple's Core ML and Vision frameworks with YOLOv8
- **RTSP Stream Support**: Connects to IP cameras via RTSP protocol
- **Real-time Notifications**: macOS native notifications with optional image attachments
- **Configurable Detection**: Monitor specific objects with adjustable confidence thresholds
- **Snapshot Capture**: Save images when detections occur
- **Privacy First**: All processing happens locally on your Mac
- **One-Script Deployment**: Complete setup with a single bash script

## 📋 Prerequisites

- **macOS Device**: Apple Silicon Mac (M1/M2/M3/M4) running macOS 13+ recommended
- **Xcode**: Install from Mac App Store
- **Command Line Tools**: Run `xcode-select --install`
- **Internet Connection**: For downloading dependencies and models
- **RTSP Camera**: IP camera with RTSP stream support

## 🛠️ Quick Setup

### 1. Download the Project Files

Create a new directory and place these files:
- `deploy.sh` - Main deployment script
- `main_app.swift` - Swift application code
- `config.env.example` - Configuration template

### 2. Configure Your Settings

Copy the configuration template:
```bash
cp config.env.example config.env
```

Edit `config.env` with your camera details:
```bash
# REQUIRED: Your camera's RTSP URL
RTSP_FEED_URL="rtsp://192.168.1.100:554/stream1"

# REQUIRED: Camera credentials
RTSP_CREDS="admin:password123"

# OPTIONAL: Objects to detect
OBJECTS_TO_MONITOR="person,cat,dog,car"

# OPTIONAL: Enable snapshots
SNAPSHOT_ON_DETECTION="true"
SNAPSHOT_DIRECTORY="$HOME/Desktop/CameraSnapshots"
```

### 3. Deploy and Run

Make the script executable and run:
```bash
chmod +x deploy.sh
source config.env && ./deploy.sh
```

The script will automatically:
- Install Homebrew and FFmpeg
- Set up Python environment
- Download and convert YOLOv8 model to Core ML
- Build the Swift application
- Start monitoring

## 📱 First Run

When you first run the application:

1. **Grant Notification Permission**: macOS will ask for notification permissions - click "Allow"
2. **Monitor Output**: The terminal will show detection results and status messages
3. **Receive Notifications**: When objects are detected, you'll get native macOS notifications
4. **View Snapshots**: If enabled, check your snapshot directory for captured images

## ⚙️ Configuration Options

### Core Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `RTSP_FEED_URL` | Camera RTSP stream URL | *Required* |
| `RTSP_CREDS` | Username:password for camera | *Required* |
| `DETECTION_THRESHOLD` | Confidence threshold (0.0-1.0) | `0.7` |
| `OBJECTS_TO_MONITOR` | Comma-separated object list | `person` |
| `NOTIFICATION_COOLDOWN_SECONDS` | Seconds between notifications | `300` |

### Snapshot Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `SNAPSHOT_ON_DETECTION` | Save images on detection | `false` |
| `SNAPSHOT_DIRECTORY` | Where to save snapshots | `/tmp/ai_cam_snapshots` |

### Available Objects to Monitor

The system can detect 80+ object types including:
- **People & Animals**: person, cat, dog, bird, horse, cow
- **Vehicles**: car, bicycle, motorcycle, bus, truck, airplane
- **Common Items**: backpack, handbag, laptop, cell phone, bottle
- **Household**: chair, couch, tv, refrigerator, microwave

## 🎛️ Usage Examples

### Basic Person Detection
```bash
export RTSP_FEED_URL="rtsp://192.168.1.100:554/stream"
export RTSP_CREDS="admin:mypassword"
export OBJECTS_TO_MONITOR="person"
./deploy.sh
```

### Multi-Object Monitoring with Snapshots
```bash
# In config.env
RTSP_FEED_URL="rtsp://camera.local:554/h264Preview_01_main"
RTSP_CREDS="admin:securepass"
OBJECTS_TO_MONITOR="person,car,dog,cat"
DETECTION_THRESHOLD="0.8"
SNAPSHOT_ON_DETECTION="true"
SNAPSHOT_DIRECTORY="/Users/yourname/Desktop/SecuritySnapshots"
NOTIFICATION_COOLDOWN_SECONDS="60"

# Run
source config.env && ./deploy.sh
```

### High-Sensitivity Pet Monitoring
```bash
export OBJECTS_TO_MONITOR="cat,dog,bird"
export DETECTION_THRESHOLD="0.5"
export NOTIFICATION_COOLDOWN_SECONDS="30"
./deploy.sh
```

## 🔧 Advanced Usage

### Camera URL Formats

Different camera brands use different RTSP URL formats:

**Hikvision**:
```
rtsp://username:password@192.168.1.100:554/h264Preview_01_main
```

**Dahua**:
```
rtsp://username:password@192.168.1.100:554/cam/realmonitor?channel=1&subtype=0
```

**Reolink**:
```
rtsp://username:password@192.168.1.100:554/h264Preview_01_main
```

**Generic**:
```
rtsp://username:password@192.168.1.100:554/stream1
```

### Special Characters in Passwords

If your password contains special characters, URL encode them:
- `@` becomes `%40`
- `#` becomes `%23`
- `$` becomes `%24`

Example: `MyP@ss#1` becomes `MyP%40ss%231`

### Running as Background Service

For continuous monitoring, consider creating a Launch Daemon:

1. Build the application first:
```bash
source config.env && ./deploy.sh
```

2. Create a launch daemon plist file at `/Library/LaunchDaemons/com.yourdomain.aicammonitor.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.yourdomain.aicammonitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/your/AICamMonitor/.build/release/AICamMonitor</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>RTSP_FEED_URL</key>
        <string>your_rtsp_url_here</string>
        <key>RTSP_CREDS</key>
        <string>username:password</string>
    </dict>
</dict>
</plist>
```

3. Load the service:
```bash
sudo launchctl load /Library/LaunchDaemons/com.yourdomain.aicammonitor.plist
```

## 🔍 Troubleshooting

### Common Issues

**"Model not found" error**:
- Ensure the model conversion completed successfully
- Check that `yolov8n.mlpackage` exists in the project directory

**No notifications appearing**:
- Grant notification permissions in System Preferences > Notifications
- Check that objects are being detected (console output)
- Verify notification cooldown settings

**High CPU usage**:
- Increase `DETECTION_THRESHOLD` to reduce false positives
- Consider using fewer objects to monitor
- The demo uses simulated frames - real RTSP will be more efficient

**Connection issues**:
- Verify RTSP URL is correct and accessible
- Test the stream in VLC: File > Open Network > Enter RTSP URL
- Check firewall settings
- Ensure camera supports the RTSP stream format

### Logging and Debugging

Monitor the application output for detailed information:
```bash
# Run with verbose output
source config.env && ./deploy.sh 2>&1 | tee monitor.log
```

Check the deployment logs:
```bash
tail -f deploy_*.log
```

### Performance Optimization

For optimal performance on Apple Silicon:
- Use YOLOv8 nano model (default) for speed
- Set appropriate detection threshold (0.7-0.8)
- Limit objects to monitor to only what you need
- Use reasonable notification cooldown periods

## 🚧 Current Limitations

This is a foundational implementation with some limitations:

1. **Simulated Video Stream**: The current `VideoFrameReader` creates dummy frames for demonstration. Real RTSP integration requires FFmpeg wrapper implementation.

2. **Basic Error Handling**: Network disconnections and stream errors need more robust handling.

3. **No Web Interface**: Configuration is file-based only.

## 🛣️ Future Enhancements

Planned improvements include:

- **Full RTSP Integration**: Complete FFmpeg wrapper for real video streams
- **Detection Zones**: Define specific areas for monitoring
- **Object Tracking**: Follow objects across frames to reduce duplicate notifications
- **Web Dashboard**: Browser-based configuration and monitoring
- **Home Assistant Integration**: MQTT support for smart home automation
- **Multi-Camera Support**: Monitor multiple streams simultaneously

## 🧹 Cleanup

To remove all generated files and start fresh:
```bash
./deploy.sh --clean
```

This removes:
- Swift project directory
- Python virtual environment  
- Downloaded models
- Log files

## 📄 License

This project is open source. Feel free to modify and adapt for your needs.

## 🤝 Contributing

Contributions welcome! Key areas for improvement:
- FFmpeg integration for real RTSP streams
- Enhanced error handling and reconnection logic  
- Additional notification methods (email, webhooks)
- Performance optimizations
- Cross-platform support

## ⚠️ Privacy Note

This system processes video locally on your device. No video data is transmitted to external services. All AI inference happens on-device using Apple's Neural Engine for privacy and performance.