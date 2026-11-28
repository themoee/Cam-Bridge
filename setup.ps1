<#
.SYNOPSIS
    One-shot setup for the Cam Bridge RECEIVER (the machine that shows the
    virtual camera - e.g. your virtual server).

.DESCRIPTION
    Run this from inside a clone of the repo, on the receiver machine. It:
      0. sanity-checks Windows + Python + the repo files,
      1. installs the Python dependencies,
      2. makes sure OBS Studio is installed (needed ONLY for its virtual-camera
         driver - you never have to open OBS),
      3. renames the virtual camera away from "OBS Virtual Camera" (disguise),
      4. if -SenderIp is given, builds the exe and registers the logon autostart task.

    The SENDER machine (the laptop with the real webcam) only needs steps 0-1;
    everything after that is receiver-only.

    Needs an ELEVATED shell for: installing OBS, and -Scope Machine / the
    autostart task. Everything else works unelevated.

.PARAMETER SenderIp
    LAN / VPN (e.g. Tailscale) IP of the sender - the laptop with the webcam.
    If given, this also builds dist\cam-receiver.exe and registers the autostart task.

.PARAMETER CamName
    Camera name to advertise. Default: "HD Webcam".

.PARAMETER Scope
    User (default, no admin needed) or Machine (system-wide, needs admin) for the rename.

.EXAMPLE
    .\setup.ps1
    .\setup.ps1 -SenderIp 192.168.1.42
    .\setup.ps1 -SenderIp 100.64.0.5 -CamName "Integrated Camera" -Scope Machine
#>
[CmdletBinding()]
param(
    [string]$SenderIp,
    [string]$CamName = "HD Webcam",
    [ValidateSet("User", "Machine")][string]$Scope = "User"
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

function Step($n, $t) { Write-Host "`n== $n. $t ==" -ForegroundColor Cyan }
function Ok($m) { Write-Host "   OK: $m" -ForegroundColor Green }
function Warn($m) { Write-Host "   ! $m" -ForegroundColor Yellow }

$obsKey = 'HKLM:\SOFTWARE\Classes\CLSID\{A3FCE0F5-3493-419F-958A-ABA1250EC20B}'

# ---------------------------------------------------------------------------
Step 0 'Sanity checks'
if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
    Write-Error 'Cam Bridge is Windows-only (DirectShow + winreg).'
}
if (-not (Test-Path (Join-Path $root 'receiver.py'))) {
    Write-Error 'receiver.py not found - run this script from inside the repo.'
}
$py = Get-Command py -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
if (-not $py) {
    Write-Error "Python not found on PATH. Install Python 3.12 from python.org (tick 'Add to PATH') and retry."
}
$pyExe = $py.Source
$pyArgs = @()
if ((Split-Path $pyExe -Leaf) -in 'py.exe', 'py') { $pyArgs = @('-3') }
Ok "Windows + Python ($pyExe) + repo OK"

# ---------------------------------------------------------------------------
Step 1 'Installing Python dependencies'
& $pyExe @pyArgs -m pip install --upgrade pip
& $pyExe @pyArgs -m pip install -r (Join-Path $root 'requirements.txt')
Ok 'opencv / numpy / pyvirtualcam installed'

# ---------------------------------------------------------------------------
Step 2 'Checking the OBS virtual-camera driver'
if (Test-Path $obsKey) {
    Ok 'OBS virtual-camera driver already registered'
} else {
    Warn 'OBS not found - its virtual-camera driver is required (OBS itself need not run).'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host '   Installing OBS Studio via winget ...'
        winget install --id OBSProject.OBSStudio -e --accept-source-agreements --accept-package-agreements
        if (-not (Test-Path $obsKey)) { Warn 'Driver still not registered - reboot or re-run once OBS finishes installing.' }
    } else {
        Warn 'winget unavailable - install OBS from https://obsproject.com/ then re-run this script.'
    }
}

# ---------------------------------------------------------------------------
Step 3 "Disguising the virtual camera as '$CamName' ($Scope scope)"
& (Join-Path $root 'disguise_camera.ps1') -Name $CamName -Scope $Scope

# ---------------------------------------------------------------------------
if ($SenderIp) {
    Step 4 "Building exe + registering autostart (sender = $SenderIp)"
    & $pyExe @pyArgs -m pip install pyinstaller
    & $pyExe @pyArgs -m PyInstaller (Join-Path $root 'cam-receiver.spec') --noconfirm
    & (Join-Path $root 'install_autostart.ps1') -Role receiver -SenderIp $SenderIp -CamName $CamName
    Ok 'Autostart registered (if it warned about access, re-run this script elevated).'
} else {
    Step 4 'No -SenderIp given - skipping exe build + autostart'
    Warn "Later:  .\setup.ps1 -SenderIp <sender-ip>    (or run install_autostart.ps1 directly)"
}

Write-Host "`nSetup done." -ForegroundColor Cyan
Write-Host 'On the SENDER laptop:  py -3 sender.py' -ForegroundColor Cyan
Write-Host "On this receiver:      py -3 receiver.py <sender-ip>   (or let the autostart task run it)" -ForegroundColor Cyan
Write-Host "Stop it with:  .\stop_cam_bridge.ps1    (start detached with .\start_cam_bridge.ps1 -Role receiver -SenderIp <ip>)" -ForegroundColor Cyan
