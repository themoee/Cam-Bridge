# Cam Bridge

Live-stream one Windows laptop's webcam over your local network and have it show
up as a **selectable camera** ("OBS Virtual Camera") on a second Windows laptop.

- **Laptop A (sender)** — has the real webcam, runs `sender.py`.
- **Laptop B (receiver)** — runs `receiver.py`, and any app on it (Zoom, Teams,
  your test app, the Windows Camera app) can then pick the virtual camera and see A's live feed.

Both machines must be on the same network (same Wi-Fi / LAN).

---

## 1. One-time setup

On **both** laptops:

```bash
pip install -r requirements.txt
```

On the **receiver laptop only**, install **OBS Studio** (>= 26.1):
https://obsproject.com/ — installing it registers the virtual-camera driver that
`pyvirtualcam` uses. You do **not** need to keep OBS open; it just has to be installed once.

---

## 2. Run it

**Laptop A (sender):**

```bash
python sender.py
```

Find laptop A's LAN IP — open a terminal and run `ipconfig`, look for the
`IPv4 Address` under your Wi-Fi/Ethernet adapter (something like `192.168.1.42`).

**Laptop B (receiver):**

```bash
python receiver.py 192.168.1.42
```

(use laptop A's actual IP). Or just double-click `run_receiver.bat` and type the IP when asked.

Now open your app on laptop B and choose **OBS Virtual Camera** as the camera. You'll see A's live webcam.

---

## 3. Options

```bash
python sender.py --camera 1 --width 1920 --height 1080 --fps 30 --quality 90
python receiver.py 192.168.1.42 --width 1920 --height 1080 --fps 30
```

Keep width/height/fps the same on both sides for best results.

---

## 4. Firewall

The first time you run `sender.py`, Windows may pop up a firewall prompt — allow
Python on **Private** networks so laptop B can reach port 5000. If B can't connect,
check that both laptops are on the same network and that port 5000 is allowed on A.

---

## 5. Starting and stopping (no Ctrl+C)

Use the two helper scripts. They launch it detached with no console window — so it
survives closing the terminal or disconnecting your RDP session — and give you a
real off switch:

```powershell
.\start_cam_bridge.ps1 -Role receiver -SenderIp 100.64.0.5   # start (background)
.\stop_cam_bridge.ps1 -Role receiver                          # stop
```

`stop_cam_bridge.ps1` also catches copies launched from source, and can un-arm the
autostart task and restore the camera name:

```powershell
.\stop_cam_bridge.ps1                 # stop whatever Cam Bridge is running
.\stop_cam_bridge.ps1 -Task -Restore  # also disable the logon task + un-rename the camera
```

Logs go to `cam-<role>.out.log` / `cam-<role>.err.log`. The process is still a
normal, visible Task Manager entry — just without a console window. `Ctrl+C` still
works if you happen to run it in the foreground.

**Windowless exe + autostart (optional):** `cam-sender.spec` / `cam-receiver.spec` now
build with `console=False`, so `dist\cam-sender.exe` / `dist\cam-receiver.exe` run with
no console window at all. `install_autostart.ps1` registers one of them as a Scheduled
Task that starts at logon:

```powershell
# on laptop A (sender):
.\install_autostart.ps1 -Role sender

# on laptop B (receiver):
.\install_autostart.ps1 -Role receiver -SenderIp 192.168.1.42
```

The task is a normal, visible entry in Task Scheduler ("Cam Bridge Sender"/"Cam Bridge
Receiver") and the running process is a normal, visible entry in Task Manager — this
just removes the console window and the manual double-click at each login. It does
*not* hide the process, mask its name, or suppress Windows' webcam-in-use indicator.

To remove: `Unregister-ScheduledTask -TaskName "Cam Bridge Sender" -Confirm:$false`
(swap "Sender" for "Receiver" as needed).

---

## 6. Hiding from LockDown Browser / proctoring

Out of the box the virtual camera is literally called **"OBS Virtual Camera"**,
which is the usual "that isn't a real webcam" give-away. You can rename it to an
ordinary webcam name and LockDown Browser (and everything else) just sees a plain
camera.

On the **receiver laptop**:

```powershell
.\disguise_camera.ps1 -List                              # see existing cameras (avoid a name clash)
.\disguise_camera.ps1 -Name "HD Webcam"                  # rename (no admin needed - uses HKCU)
.\disguise_camera.ps1 -Name "HD Webcam" -Scope Machine   # system-wide (needs an admin shell)
.\disguise_camera.ps1 -Restore                           # put "OBS Virtual Camera" back
```

Restart any app that is already open so it re-reads the camera list. When the
disguise is active the receiver prints `[disguised]` next to the name, and you can
bundle it with autostart in one step:

```powershell
.\install_autostart.ps1 -Role receiver -SenderIp 192.168.1.42 -Disguise -CamName "HD Webcam"
```

Why it's safe: `pyvirtualcam` locates the camera by its CLSID, not by name, so the
receiver keeps working after a rename. The rename only changes what apps
*enumerate* — the driver and the process are untouched (still a normal, visible
Task Manager entry, just without a console window).

Notes:

- The rename survives a reboot. Reinstalling/updating OBS Studio re-registers the
  driver and can reset the name — just run `disguise_camera.ps1` again.
- `-Scope User` (the default when not elevated) affects only your Windows account;
  `-Scope Machine` affects every account. Either is enough, since LockDown Browser
  runs as you.
- This changes only the *name* apps see. Nothing is hidden from the OS: the
  process stays a normal, visible entry in Task Manager.

---

## 7. Build a standalone .exe (optional)

So the other laptop doesn't need Python installed:

```bash
pip install pyinstaller
pyinstaller --onefile --name cam-sender sender.py
pyinstaller --onefile --name cam-receiver receiver.py
```

The `.exe` files land in `dist/`. Note: the **receiver machine still needs OBS
Studio installed** for the virtual-camera driver — that driver can't be bundled
into the exe.
