#!/usr/bin/env python3
import cv2
import os
import time
import sys
import socket
import struct
import signal
from datetime import datetime
from dotenv import load_dotenv

# --- Configuration ---
load_dotenv("config.env")

RTSP_URL = os.getenv("RTSP_FEED_URL")
CAM_USERNAME = os.getenv("CAM_USERNAME")
CAM_PASSWORD = os.getenv("CAM_PASSWORD")
FRAME_RATE = int(os.getenv("FRAME_RATE", 1))
SOCKET_PATH = "/tmp/aicam.sock"

# Global state for graceful shutdown
server_socket = None
client_connection = None
capture = None
running = True

def log_message(message):
    """Unified logging format with timestamps"""
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    print(f"[{timestamp}][frame_grabber.py] {message}")
    sys.stdout.flush()

def signal_handler(sig, frame):
    """Handle graceful shutdown on SIGINT/SIGTERM"""
    global running
    log_message(f"Received signal {sig}, shutting down gracefully...")
    running = False

def cleanup():
    """Clean up resources"""
    global server_socket, client_connection, capture
    
    if capture:
        capture.release()
        capture = None
    
    if client_connection:
        try:
            client_connection.close()
        except:
            pass
        client_connection = None
    
    if server_socket:
        try:
            server_socket.close()
        except:
            pass
        server_socket = None
    
    if os.path.exists(SOCKET_PATH):
        try:
            os.unlink(SOCKET_PATH)
            log_message("Socket file removed")
        except OSError as e:
            log_message(f"Warning: Could not remove socket file: {e}")

def validate_configuration():
    """Validate that all required configuration is present"""
    if not all([RTSP_URL, CAM_USERNAME, CAM_PASSWORD]):
        log_message("Error: RTSP_FEED_URL, CAM_USERNAME, or CAM_PASSWORD not found in config.env")
        return False
    
    if FRAME_RATE < 0.1 or FRAME_RATE > 30:
        log_message(f"Warning: Frame rate {FRAME_RATE} is unusual, proceeding anyway")
    
    return True

def create_server_socket():
    """Create and bind the Unix Domain Socket server"""
    global server_socket
    
    # Clean up any existing socket
    if os.path.exists(SOCKET_PATH):
        try:
            os.unlink(SOCKET_PATH)
        except OSError as e:
            log_message(f"Error removing existing socket: {e}")
            return False

    try:
        server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server_socket.bind(SOCKET_PATH)
        server_socket.listen(1)
        log_message(f"Server listening on {SOCKET_PATH}")
        return True
    except Exception as e:
        log_message(f"Error creating server socket: {e}")
        return False

def wait_for_client():
    """Wait for Swift client to connect"""
    global client_connection, running
    
    log_message("Waiting for Swift client to connect...")
    try:
        # Set a timeout to periodically check if we should shutdown
        server_socket.settimeout(1.0)
        
        while running:
            try:
                client_connection, _ = server_socket.accept()
                client_connection.settimeout(5.0)  # 5 second timeout for reads/writes
                log_message("Swift client connected")
                return True
            except socket.timeout:
                continue  # Check running flag and try again
            except Exception as e:
                log_message(f"Error accepting connection: {e}")
                return False
                
    except KeyboardInterrupt:
        return False

def create_rtsp_connection():
    """Create connection to RTSP stream with retries"""
    auth_url = RTSP_URL.replace("rtsp://", f"rtsp://{CAM_USERNAME}:{CAM_PASSWORD}@")
    masked_url = RTSP_URL.split('@')[1] if '@' in RTSP_URL else RTSP_URL
    log_message(f"Connecting to stream: {masked_url}")
    
    max_retries = 3
    for attempt in range(max_retries):
        try:
            cap = cv2.VideoCapture(auth_url)
            
            # Configure capture properties for better performance
            cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)  # Reduce buffer to get latest frames
            cap.set(cv2.CAP_PROP_FPS, FRAME_RATE)
            
            if cap.isOpened():
                # Test if we can actually read a frame
                ret, test_frame = cap.read()
                if ret and test_frame is not None:
                    log_message(f"Successfully connected to stream (attempt {attempt + 1})")
                    return cap
                else:
                    log_message(f"Connected but cannot read frames (attempt {attempt + 1})")
                    cap.release()
            else:
                log_message(f"Could not open stream (attempt {attempt + 1})")
                
        except Exception as e:
            log_message(f"Exception connecting to stream (attempt {attempt + 1}): {e}")
        
        if attempt < max_retries - 1:
            log_message(f"Retrying connection in 3 seconds...")
            time.sleep(3)
    
    return None

def send_frame_data(frame_data):
    """Send frame data to Swift client with error handling"""
    try:
        # Send size header (little-endian)
        size_bytes = struct.pack('<I', len(frame_data))
        client_connection.sendall(size_bytes)
        
        # Send frame data
        client_connection.sendall(frame_data)
        return True
        
    except (BrokenPipeError, ConnectionResetError, socket.timeout):
        log_message("Swift client disconnected")
        return False
    except Exception as e:
        log_message(f"Error sending frame: {e}")
        return False

def capture_and_send_loop():
    """Main capture and send loop"""
    global capture, running
    
    capture_interval = 1.0 / FRAME_RATE
    last_capture_time = 0
    frame_count = 0
    connection_failures = 0
    max_connection_failures = 5
    
    while running:
        # Create/recreate RTSP connection if needed
        if not capture:
            capture = create_rtsp_connection()
            if not capture:
                log_message("Failed to connect to RTSP stream, retrying in 10 seconds...")
                time.sleep(10)
                continue
            connection_failures = 0
        
        try:
            ret, frame = capture.read()
            if not ret or frame is None:
                connection_failures += 1
                log_message(f"Failed to read frame (failure #{connection_failures})")
                
                if connection_failures >= max_connection_failures:
                    log_message("Too many connection failures, recreating connection...")
                    capture.release()
                    capture = None
                    time.sleep(5)
                    continue
                else:
                    time.sleep(1)
                    continue
            
            # Reset failure counter on successful read
            connection_failures = 0
            
            # Frame rate control
            current_time = time.time()
            if (current_time - last_capture_time) < capture_interval:
                continue
            
            last_capture_time = current_time
            frame_count += 1
            
            # Encode frame as JPEG
            encode_params = [cv2.IMWRITE_JPEG_QUALITY, 85]  # Slightly lower quality for better performance
            ret, jpeg_data = cv2.imencode('.jpg', frame, encode_params)
            
            if not ret or jpeg_data is None:
                log_message("Error encoding frame to JPEG")
                continue
            
            # Send to Swift client
            if not send_frame_data(jpeg_data):
                log_message("Client disconnected, waiting for reconnection...")
                break
            
            # Log progress every 50 frames
            if frame_count % 50 == 0:
                log_message(f"Sent frame #{frame_count} ({len(jpeg_data)} bytes)")
                
        except Exception as e:
            log_message(f"Unexpected error in capture loop: {e}")
            time.sleep(1)
    
    # Cleanup capture
    if capture:
        capture.release()
        capture = None

def main():
    """Main function"""
    global running
    
    log_message("Frame Grabber Server starting...")
    
    # Set up signal handlers
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    try:
        # Validate configuration
        if not validate_configuration():
            return 1
        
        # Create server socket
        if not create_server_socket():
            return 1
        
        # Main server loop
        while running:
            # Wait for client connection
            if not wait_for_client():
                break
            
            # Process frames while client is connected
            capture_and_send_loop()
            
            # Close client connection
            if client_connection:
                try:
                    client_connection.close()
                except:
                    pass
                client_connection = None
            
            if running:
                log_message("Waiting for next client connection...")
        
        return 0
        
    except KeyboardInterrupt:
        print("\n")
        log_message("Interrupted by user")
        return 0
    except Exception as e:
        log_message(f"Fatal error: {e}")
        return 1
    finally:
        cleanup()

if __name__ == "__main__":
    sys.exit(main())