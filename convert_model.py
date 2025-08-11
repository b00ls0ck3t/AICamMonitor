import sys, os
from ultralytics import YOLO
def convert(variant, out_path):
    try:
        model = YOLO(f"yolov8{variant}.pt")
        model.export(format='coreml', imgsz=640, nms=True, half=True)
        expected = f"yolov8{variant}.mlpackage"
        if os.path.exists(expected):
            import shutil
            if os.path.exists(out_path): shutil.rmtree(out_path)
            shutil.move(expected, out_path)
            return True
    except Exception as e: return False
if __name__ == "__main__":
    if not convert(sys.argv[1], sys.argv[2]): sys.exit(1)
