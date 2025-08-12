import cv2
import os
import time
import sys
import socket
import struct
from dotenv import load_dotenv

# --- Configuration ---
load_dotenv("config.env")

RTSP_URL = os.getenv("RTSP_FEED_URL")
CAM_USERNAME = os.getenv("CAM_USERNAME")
CAM_PASSWORD = os.getenv("CAM_PASSWORD")
FRAME_RATE = int(os.getenv("FRAME_RATE", 1))
SOCKET_PATH = "/tmp/aicam.sock"

# --- Main Logic ---
def main():
    """
    Connects to an RTSP stream, grabs frames, and sends them over a
    Unix Domain Socket.
    """
    print("[Python] Frame Grabber Server starting...")

    # --- Validate Configuration ---
    if not all([RTSP_URL, CAM_USERNAME, CAM_PASSWORD]):
        print("[Python] Error: RTSP_FEED_URL, CAM_USERNAME, or CAM_PASSWORD not found in config.env.")
        sys.exit(1)

    # --- Create Unix Domain Socket Server ---
    # Make sure the socket does not already exist
    try:
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
    except OSError as e:
        print(f"[Python] Error removing existing socket: {e}")
        sys.exit(1)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    server.listen(1)
    print(f"[Python] Server listening on {SOCKET_PATH}")

    # --- Accept Connection from Swift Client ---
    connection, _ = server.accept()
    print("[Python] Swift client connected.")

    # --- Construct Authenticated URL ---
    auth_url = RTSP_URL.replace("rtsp://", f"rtsp://{CAM_USERNAME}:{CAM_PASSWORD}@")
    print(f"[Python] Connecting to stream...")

    # --- Capture and Send Loop ---
    while True:
        cap = cv2.VideoCapture(auth_url)
        if not cap.isOpened():
            print("[Python] Error: Could not open video stream. Retrying in 10 seconds...")
            time.sleep(10)
            continue

        print("[Python] Successfully connected to video stream.")
        
        last_capture_time = 0
        capture_interval = 1.0 / FRAME_RATE

        while True:
            ret, frame = cap.read()
            if not ret:
                print("[Python] Error: Lost connection to stream. Reconnecting...")
                break

            current_time = time.time()
            if (current_time - last_capture_time) >= capture_interval:
                last_capture_time = current_time
                
                # Encode the frame as JPEG
                ret, jpeg_data = cv2.imencode('.jpg', frame, [cv2.IMWRITE_JPEG_QUALITY, 90])
                if not ret:
                    print("[Python] Error: Could not encode frame to JPEG.")
                    continue

                try:
                    # Simple protocol: send size of frame first, then the frame data
                    # Pack the size as a 4-byte unsigned integer
                    size_bytes = struct.pack('<I', len(jpeg_data))
                    connection.sendall(size_bytes)
                    connection.sendall(jpeg_data)
                    print(f"[Python] Sent frame ({len(jpeg_data)} bytes).")

                except (BrokenPipeError, ConnectionResetError):
                    print("[Python] Swift client disconnected. Exiting.")
                    return # Exit cleanly

        cap.release()
        time.sleep(5)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[Python] Server shutting down.")
    finally:
        # Clean up the socket file on exit
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        sys.exit(0)

