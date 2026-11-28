<#
.SYNOPSIS
    Gives the Cam Bridge virtual camera a normal-looking webcam name.

.DESCRIPTION
    Cam Bridge's receiver pipes the remote webcam into the "OBS Virtual Camera"
    (the driver that installing OBS Studio registers). Out of the box every app -
    LockDown Browser, Chrome, Zoom, the Windows Camera app, proctoring tools -
    therefore sees a camera literally called "OBS Virtual Camera", which is the
    classic "this is not a real webcam" tell.

    This script rewrites that camera's DirectShow "Video Capture Sources"
    registration so it shows up under an ordinary name instead (default
    "HD Webcam"). It does NOT touch the driver, and because pyvirtualcam locates
    the camera by its CLSID (not by name) the receiver keeps working unchanged.

    Run it on the RECEIVER laptop. Newly started apps (including a freshly
    launched LockDown Browser) see the new name; apps that are already running
    keep the old name until restarted.

    Scope:
      -Machine  writes HKLM\SOFTWARE\Classes (system-wide, needs an admin shell)
      -User     writes HKCU\SOFTWARE\Classes (this Windows account only, NO admin)
      -Auto     uses -Machine if the shell is elevated, otherwise -User

    Both work, because Windows merges HKCU over HKLM to build HKEY_CLASSES_ROOT,
    which is what every app actually enumerates.

.PARAMETER Name
    Display name to advertise. Default: "HD Webcam".
    Pick something that does NOT clash with the laptop's real camera -
    run -List first to see the existing names.

.PARAMETER Restore
    Put the original "OBS Virtual Camera" name back.

.PARAMETER List
    List every camera currently registered, then exit.

.PARAMETER Status
    Print the current (effective) camera name, then exit.

.PARAMETER Scope
    Auto (default), Machine, or User. See above.

.EXAMPLE
    .\disguise_camera.ps1 -List
    .\disguise_camera.ps1 -Name "Integrated Camera"
    .\disguise_camera.ps1 -Restore
#>
[CmdletBinding()]
param(
    [Parameter()][string]$Name = "HD Webcam",
    [Parameter()][switch]$Restore,
    [Parameter()][switch]$List,
    [Parameter()][switch]$Status,
    [Parameter()][ValidateSet("Auto", "Machine", "User")][string]$Scope = "Auto"
)

$ErrorActionPreference = 'Stop'

# CLSID_VideoInputDeviceCategory - the DirectShow category every app enumerates.
$categoryGuid = '{860BB310-5D01-11d0-BD3B-00A0C911CE86}'
# CLSID_OBS_VirtualVideo - the OBS virtual camera filter (stable across OBS builds).
$filterGuid = '{A3FCE0F5-3493-419F-958A-ABA1250EC20B}'

$classesRel = "CLSID\$categoryGuid\Instance\$filterGuid"
$providerRel = "SOFTWARE\Classes\$classesRel"

function Test-Elevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
        [System.Security.Principal.WindowsBuiltinRole]::Administrator)
}

# The name apps actually see = the merged (HKLM + HKCU) HKEY_CLASSES_ROOT value.
function Get-EffectiveName {
    $key = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey($classesRel)
    if ($key) { return $key.GetValue('FriendlyName') }
    return $null
}

if ($List) {
    Write-Host "Cameras registered on this machine (DirectShow video capture devices):"
    $cat = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("CLSID\$categoryGuid\Instance")
    if ($cat) {
        foreach ($sub in $cat.GetSubKeyNames()) {
            $k = $cat.OpenSubKey($sub)
            $n = $k.GetValue('FriendlyName')
            if ($n) { Write-Host "  - $n" }
        }
    }
    exit 0
}

if (-not ([Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($providerRel))) {
    Write-Error "OBS Virtual Camera is not registered. Install OBS Studio (>= 26.1) on this laptop first."
    exit 1
}

if ($Status) {
    Write-Host "Effective camera name: $(Get-EffectiveName)"
    exit 0
}

if ($Scope -eq "Auto") { $Scope = if (Test-Elevated) { "Machine" } else { "User" } }

if ($Scope -eq "Machine") {
    if (-not (Test-Elevated)) {
        Write-Error "Scope 'Machine' needs an elevated shell. Re-run as administrator, or use -Scope User."
        exit 1
    }
    $hive = 'HKLM:'
} else {
    $hive = 'HKCU:'
}

$instKey = "$hive\$providerRel"
$filtKey = "$hive\SOFTWARE\Classes\CLSID\$filterGuid"
$target = if ($Restore) { 'OBS Virtual Camera' } else { $Name }

try {
    # Merge into any existing key rather than clobbering it.
    New-Item -Path $instKey -Force | Out-Null
    Set-ItemProperty -Path $instKey -Name 'FriendlyName' -Value $target
    New-Item -Path $filtKey -Force | Out-Null
    Set-ItemProperty -Path $filtKey -Name '(default)' -Value $target
} catch [System.Security.SecurityException] {
    Write-Error "Access denied. Re-run from an elevated PowerShell, or use -Scope User (no admin needed)."
    exit 1
} catch [System.UnauthorizedAccessException] {
    Write-Error "Access denied. Re-run from an elevated PowerShell, or use -Scope User (no admin needed)."
    exit 1
}

Write-Host "Virtual camera is now named '$target' ($Scope scope)."
if ($Restore) {
    Write-Host "Restored to the original OBS name."
} else {
    Write-Host "Restart any app that is already open so it picks up the new name."
    Write-Host "To undo:  .\disguise_camera.ps1 -Restore"
}
