# Registers cam-sender.exe (or cam-receiver.exe) to start quietly at logon via Task Scheduler.
# No console window appears (both exes were built with console=False).
# The task is fully visible in Task Scheduler ("Cam Bridge Sender"/"Cam Bridge Receiver")
# and the process is a normal, visible entry in Task Manager - this just avoids a
# console window and a manual double-click each login.

param(
    [ValidateSet("sender","receiver")]
    [string]$Role = "sender",
    [string]$SenderIp,               # required when -Role receiver
    [switch]$Disguise,               # receiver: rename the virtual camera away from "OBS Virtual Camera"
    [string]$CamName = "HD Webcam",  # name to use when -Disguise is set
    [string]$TaskName                # override the Scheduled Task name
)

$exe = Join-Path $PSScriptRoot "dist\cam-$Role.exe"
if (-not (Test-Path $exe)) {
    Write-Error "Not found: $exe  (build it first with: pyinstaller cam-$Role.spec)"
    exit 1
}

$taskName = if ($TaskName) { $TaskName } else { "Cam Bridge $($Role.Substring(0,1).ToUpper() + $Role.Substring(1))" }
$args = ""
if ($Role -eq "receiver") {
    if (-not $SenderIp) { Write-Error "Pass -SenderIp <laptop A's IP> for the receiver role"; exit 1 }
    $args = $SenderIp
    if ($Disguise) {
        & (Join-Path $PSScriptRoot "disguise_camera.ps1") -Name $CamName
    }
}

$action  = New-ScheduledTaskAction -Execute $exe -Argument $args -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -Hidden:$false -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force

Write-Host "Registered task '$taskName' - visible in Task Scheduler, starts at logon, no console window."
Write-Host "To remove: Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
