"""
Cam Bridge - RECEIVER

Run this on the laptop that should SEE the remote webcam (laptop B).
It connects to the sender, decodes the live frames, and feeds them into a
virtual camera so any app on this laptop can pick it ("OBS Virtual Camera").

    python receiver.py 192.168.1.42            # the sender laptop's LAN IP
    python receiver.py 192.168.1.42 --port 5000

Requires a virtual-camera backend to be installed on THIS laptop:
install OBS Studio (>= 26.1) once - that registers the virtual camera driver.
You do NOT need to keep OBS open.

To stop LockDown Browser / proctoring noticing that the camera is synthetic, run
disguise_camera.ps1 to rename it (default "HD Webcam"); see README section 6.
"""

import argparse
import os
import platform
import socket
import struct
import sys
import time

import cv2
import numpy as np
import pyvirtualcam

try:
    import winreg  # Windows only
except ImportError:  # pragma: no cover - non-Windows
    winreg = None


def _ensure_stdio(role):
    """Windowless builds (console=False) have no console, so Python sets
    sys.stdout/sys.stderr to None and every print() is silently dropped.
    In that case log to cam-<role>.log next to the exe/script, so there is
    something to read when it runs in the background."""
    if sys.stdout is not None and sys.stderr is not None:
        return
    if getattr(sys, "frozen", False):
        base = os.path.dirname(os.path.abspath(sys.executable))
    else:
        base = os.path.dirname(os.path.abspath(__file__))
    log = open(os.path.join(base, f"cam-{role}.log"), "a", buffering=1, encoding="utf-8")
    sys.stdout = log
    sys.stderr = log

# DirectShow registration of the OBS virtual camera (the device pyvirtualcam drives).
_OBS_CATEGORY_GUID = "{860BB310-5D01-11d0-BD3B-00A0C911CE86}"
_OBS_FILTER_GUID = "{A3FCE0F5-3493-419F-958A-ABA1250EC20B}"


def _obs_registered_name():
    """The camera name apps would enumerate (post-disguise), or None.

    pyvirtualcam's OBS backend always *reports* "OBS Virtual Camera" even after
    disguise_camera.ps1 renames the device, so read the real name from the
    registry. Windows merges HKCU over HKLM to build HKEY_CLASSES_ROOT, so check
    the user hive first (it wins) then the machine hive.
    """
    if winreg is None or platform.system() != "Windows":
        return None
    sub = rf"SOFTWARE\Classes\CLSID\{_OBS_CATEGORY_GUID}\Instance\{_OBS_FILTER_GUID}"
    for root in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        try:
            with winreg.OpenKey(root, sub) as key:
                return winreg.QueryValueEx(key, "FriendlyName")[0]
        except OSError:
            continue
    return None


def recvall(sock, n):
    """Read exactly n bytes from sock, or return None if the stream ends."""
    data = bytearray()
    while len(data) < n:
        packet = sock.recv(n - len(data))
        if not packet:
            return None
        data.extend(packet)
    return data


def main():
    _ensure_stdio("receiver")
    ap = argparse.ArgumentParser(description="Cam Bridge receiver: show the remote webcam as a virtual camera.")
    ap.add_argument("sender_ip", help="LAN IP of the laptop running sender.py (e.g. 192.168.1.42)")
    ap.add_argument("--port", type=int, default=5000)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--backend", choices=["auto", "obs", "unitycapture"], default="auto",
                    help="Virtual-camera backend (default: auto-detect)")
    ap.add_argument("--device", default=None,
                    help="Virtual-camera device name to target (optional)")
    args = ap.parse_args()

    cam_kwargs = {}
    if args.backend != "auto":
        cam_kwargs["backend"] = args.backend
    if args.device:
        cam_kwargs["device"] = args.device

    try:
        cam = pyvirtualcam.Camera(width=args.width, height=args.height, fps=args.fps,
                                  fmt=pyvirtualcam.PixelFormat.BGR, **cam_kwargs)
    except (RuntimeError, ValueError) as e:
        print(f"[receiver] ERROR: no virtual camera backend ({e}).", file=sys.stderr)
        print("[receiver] Install OBS Studio on this laptop, then run this again.", file=sys.stderr)
        if args.device and args.backend in ("auto", "obs"):
            print("[receiver] Note: the OBS backend only accepts --device 'OBS Virtual Camera' "
                  "regardless of the disguise name; try again without --device.", file=sys.stderr)
        sys.exit(1)

    display_name = (_obs_registered_name() if cam.backend == "obs" else None) or cam.device
    disguised = cam.backend == "obs" and display_name != "OBS Virtual Camera"

    with cam:
        print(f"[receiver] virtual camera running: {display_name}{'  [disguised]' if disguised else ''}")
        print("[receiver] Running. Stop with stop_cam_bridge.ps1 (or Ctrl+C here).")
        try:
            while True:  # reconnect loop - the sender may come and go
                print(f"[receiver] connecting to {args.sender_ip}:{args.port} ...")
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                try:
                    sock.connect((args.sender_ip, args.port))
                except OSError as e:
                    print(f"[receiver] sender not reachable yet ({e}); retrying in 3 s ...")
                    sock.close()
                    time.sleep(3)
                    continue
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                print("[receiver] connected.")
                try:
                    while True:
                        header = recvall(sock, 4)
                        if header is None:
                            print("[receiver] sender closed the connection; reconnecting ...")
                            break
                        (length,) = struct.unpack(">I", header)
                        payload = recvall(sock, length)
                        if payload is None:
                            print("[receiver] stream ended; reconnecting ...")
                            break
                        frame = cv2.imdecode(np.frombuffer(payload, dtype=np.uint8), cv2.IMREAD_COLOR)
                        if frame is None:
                            continue
                        if frame.shape[1] != args.width or frame.shape[0] != args.height:
                            frame = cv2.resize(frame, (args.width, args.height))
                        cam.send(frame)
                        cam.sleep_until_next_frame()
                except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
                    print("[receiver] sender dropped the connection; reconnecting ...")
                finally:
                    sock.close()
        except KeyboardInterrupt:
            print("\n[receiver] stopping.")


if __name__ == "__main__":
    main()
