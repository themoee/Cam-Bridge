@echo off
REM Run on the laptop that should see the remote webcam (laptop B).
set /p IP="Enter the sender laptop's LAN IP (e.g. 192.168.1.42): "
python receiver.py %IP%
pause
