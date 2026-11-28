"""
Cam Bridge - SENDER

Run this on the laptop whose webcam you want to share (laptop A).
It grabs the live webcam and streams JPEG frames over the LAN to a receiver.

    python sender.py                 # defaults: camera 0, port 5000, 1280x720@30
    python sender.py --camera 1 --quality 90

Then run receiver.py on the other laptop, pointing at this laptop's IP.
"""

import argparse
import socket
import struct
import sys

import cv2


def main():
    ap = argparse.ArgumentParser(description="Cam Bridge sender: stream this laptop's webcam over the LAN.")
    ap.add_argument("--host", default="0.0.0.0", help="Interface to listen on (default: all)")
    ap.add_argument("--port", type=int, default=5000, help="TCP port (default: 5000)")
    ap.add_argument("--camera", type=int, default=0, help="Webcam index (default: 0)")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--quality", type=int, default=80, help="JPEG quality 1-100 (default: 80)")
    args = ap.parse_args()

    cap = cv2.VideoCapture(args.camera, cv2.CAP_DSHOW)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)
    cap.set(cv2.CAP_PROP_FPS, args.fps)
    if not cap.isOpened():
        print(f"[sender] ERROR: could not open camera {args.camera}", file=sys.stderr)
        sys.exit(1)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.host, args.port))
    srv.listen(1)
    print(f"[sender] webcam open. Waiting for a receiver on port {args.port} ...  (stop: stop_cam_bridge.ps1 / Ctrl+C)")

    encode_params = [cv2.IMWRITE_JPEG_QUALITY, int(args.quality)]
    try:
        while True:
            conn, addr = srv.accept()
            print(f"[sender] receiver connected from {addr[0]}")
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            try:
                while True:
                    ok, frame = cap.read()
                    if not ok:
                        continue
                    ok, buf = cv2.imencode(".jpg", frame, encode_params)
                    if not ok:
                        continue
                    data = buf.tobytes()
                    # 4-byte big-endian length header, then the JPEG bytes
                    conn.sendall(struct.pack(">I", len(data)) + data)
            except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, OSError):
                print("[sender] receiver disconnected. Waiting for a new one ...")
            finally:
                conn.close()
    except KeyboardInterrupt:
        print("\n[sender] stopping.")
    finally:
        cap.release()
        srv.close()


if __name__ == "__main__":
    main()
