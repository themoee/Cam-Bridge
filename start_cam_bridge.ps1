<#
.SYNOPSIS
    Starts Cam Bridge in the background - no console window, so there is nothing
    to Ctrl+C.

.DESCRIPTION
    Launches the sender or receiver detached, so it keeps running even if you
    close the terminal or disconnect your RDP session. Prefers the built exe in
    dist\ ; falls back to pythonw running the .py from source. Output is
    redirected to cam-<role>.out.log / cam-<role>.err.log.

    Stop it with .\stop_cam_bridge.ps1.

.PARAMETER Role
    sender or receiver.

.PARAMETER SenderIp
    Required when -Role receiver: the sender's LAN / Tailscale IP.

.PARAMETER FromSource
    Force running the .py with pythonw instead of the dist exe.

.EXAMPLE
    .\start_cam_bridge.ps1 -Role receiver -SenderIp 100.64.0.5
    .\start_cam_bridge.ps1 -Role sender
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet("sender", "receiver")][string]$Role,
    [string]$SenderIp,
    [switch]$FromSource
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

if ($Role -eq 'receiver' -and -not $SenderIp) {
    Write-Error "Pass -SenderIp <sender-ip> when starting the receiver."
}

$outLog = Join-Path $root "cam-$Role.out.log"
$errLog = Join-Path $root "cam-$Role.err.log"

$extraArgs = @()
if ($Role -eq 'receiver') { $extraArgs += $SenderIp }

$env:PYTHONUNBUFFERED = '1'   # flush child logs even though there is no console

$exe = Join-Path $root "dist\cam-$Role.exe"
if ((-not $FromSource) -and (Test-Path $exe)) {
    $file = $exe
    $launchArgs = $extraArgs
} else {
    $file = 'pythonw'
    $launchArgs = @('-u', (Join-Path $root "$Role.py")) + $extraArgs
}

$procArgs = @{
    FilePath              = $file
    WorkingDirectory       = $root
    WindowStyle           = 'Hidden'
    PassThru              = $true
}
# Windowless exes have no stdout at all (the app logs to cam-<role>.log itself);
# only the pythonw path benefits from redirected console output.
if ($file -eq 'pythonw') {
    $procArgs.RedirectStandardOutput = $outLog
    $procArgs.RedirectStandardError = $errLog
}
# Start-Process on Windows PowerShell 5.1 rejects an empty -ArgumentList.
if ($launchArgs -and $launchArgs.Count) { $procArgs.ArgumentList = $launchArgs }

$p = Start-Process @procArgs

Write-Host "Started $Role (pid $($p.Id)) using $(Split-Path $file -Leaf)."
if ($file -eq 'pythonw') {
    Write-Host "  logs:  $outLog  /  $errLog"
} else {
    Write-Host "  log:   $(Join-Path $root "cam-$Role.log")"
}
Write-Host "  stop:  .\stop_cam_bridge.ps1 -Role $Role"
