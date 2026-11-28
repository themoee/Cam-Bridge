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

$p = Start-Process -FilePath $file -ArgumentList $launchArgs -WorkingDirectory $root `
    -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru

Write-Host "Started $Role (pid $($p.Id)) using $(Split-Path $file -Leaf)."
Write-Host "  logs:  $outLog  /  $errLog"
Write-Host "  stop:  .\stop_cam_bridge.ps1 -Role $Role"
