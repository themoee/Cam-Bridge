<#
.SYNOPSIS
    Stops a running Cam Bridge sender and/or receiver - no Ctrl+C needed.

.DESCRIPTION
    An off switch for Cam Bridge. Finds and stops the running process whether it
    is the built exe (cam-sender.exe / cam-receiver.exe) or a copy launched from
    source (python/pythonw running sender.py / receiver.py). Optionally also
    stops the logon Scheduled Task so it stays off, and restores the virtual
    camera's original OBS name.

.PARAMETER Role
    sender, receiver, or all (default: all).

.PARAMETER Task
    Also stop the matching logon Scheduled Task ("Cam Bridge Sender"/"...Receiver").

.PARAMETER Restore
    Also undo the camera rename (runs disguise_camera.ps1 -Restore).

.EXAMPLE
    .\stop_cam_bridge.ps1
    .\stop_cam_bridge.ps1 -Role receiver -Task -Restore
#>
[CmdletBinding()]
param(
    [Parameter()][ValidateSet("sender", "receiver", "all")][string]$Role = "all",
    [Parameter()][switch]$Task,
    [Parameter()][switch]$Restore
)

$ErrorActionPreference = 'Stop'

$roles = if ($Role -eq 'all') { 'sender', 'receiver' } else { @($Role) }
$stopped = $false

foreach ($r in $roles) {
    $procs = Get-Process -Name "cam-$r" -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host "   stopped cam-$r (pid $(($procs.Id) -join ', '))"
        $stopped = $true
    }
}

# Copies launched from source (python / pythonw running our .py files).
$py = Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'sender\.py|receiver\.py' }
foreach ($p in $py) {
    $which = if ($p.CommandLine -match 'receiver\.py') { 'receiver' } else { 'sender' }
    if ($roles -notcontains $which) { continue }
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "   stopped $which (python pid $($p.ProcessId))"
    $stopped = $true
}

if ($Task) {
    foreach ($r in $roles) {
        $t = "Cam Bridge " + $r.Substring(0, 1).ToUpper() + $r.Substring(1)
        if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            Write-Host "   stopped task '$t'"
        }
    }
}

if ($Restore) {
    & (Join-Path $PSScriptRoot 'disguise_camera.ps1') -Restore
}

if (-not $stopped) { Write-Host '   (nothing was running)' }
Write-Host 'Cam Bridge stopped.'
