@echo off
REM Put this next to cam-receiver.exe. Run on laptop B (the one that sees the camera).
set /p IP="Enter the sender laptop's LAN IP (e.g. 192.168.1.42): "
cam-receiver.exe %IP%
pause
