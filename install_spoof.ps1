<#
.SYNOPSIS
    Installs the SMBIOS spoofer so WMI - and anything else reading the firmware
    table - reports a fake PC identity instead of the Amazon EC2 one.

.DESCRIPTION
    Copies spoof_watch.exe / smbspoof.dll / smbspoof.txt to C:\ProgramData\CamBridge
    and registers spoof_watch.exe to run as SYSTEM at startup and at logon. The
    watcher injects smbspoof.dll into every WmiPrvSE.exe (the WMI provider host);
    the DLL rewrites the SMBIOS strings returned by NtQuerySystemInformation,
    using the old=>new pairs in smbspoof.txt.

    A watcher is used instead of an IFEO "Debugger" because IFEO breaks WMI's
    COM activation of its own provider host.

    Run elevated. Undo with -Remove.

.EXAMPLE
    .\install_spoof.ps1
    .\install_spoof.ps1 -Remove
#>
[CmdletBinding()]
param(
    [Parameter()][switch]$Remove
)

$ErrorActionPreference = 'Stop'
$dest = 'C:\ProgramData\CamBridge'
$taskName = 'WmiPrvSe Spoof'
$ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\WmiPrvSE.exe'

$id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$elev = (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
    [System.Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $elev) { Write-Error 'Run this from an elevated PowerShell.'; exit 1 }

if ($Remove) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    Get-Process spoof_watch -ErrorAction SilentlyContinue | Stop-Process -Force
    Remove-Item $ifeo -Recurse -ErrorAction SilentlyContinue   # clean up an old IFEO install
    Write-Host 'Removed. Restart WmiPrvSE (or reboot) to fully un-spoof.'
    exit 0
}

# stop anything that currently holds the files (watcher + provider hosts)
Get-Process spoof_watch, WmiPrvSE -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600

New-Item -ItemType Directory -Force -Path $dest | Out-Null
# let the watcher / injected DLL (runs as NETWORK SERVICE) read the config and write logs
icacls $dest /grant '*S-1-5-11:(OI)(CI)M' /T | Out-Null
foreach ($f in 'spoof_watch.exe', 'smbspoof.dll', 'smbspoof.txt') {
    $srcF = Join-Path $PSScriptRoot $f
    $dstF = Join-Path $dest $f
    for ($i = 0; $i -lt 6; $i++) {
        try { Copy-Item $srcF $dstF -Force -ErrorAction Stop; break }
        catch {
            # the DLL/EXE may be mapped by a still-running process - move it aside and retry
            try { Move-Item $dstF "$dstF.old" -Force -ErrorAction SilentlyContinue } catch { }
            Start-Sleep -Milliseconds 400
        }
    }
}

# a previous install may have used the IFEO approach - drop its value
if (Test-Path $ifeo) { Remove-ItemProperty -Path $ifeo -Name 'Debugger' -ErrorAction SilentlyContinue }
$act  = New-ScheduledTaskAction -Execute "$dest\spoof_watch.exe" -WorkingDirectory $dest
$trg  = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn))
$set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Settings $set -Principal $prin -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 3

Write-Host "Installed. Watcher is running and injecting WmiPrvSE hosts."
Write-Host 'Verify:  .\disguise_server.ps1 -Status    (WMI line should now say Dell)'
Write-Host 'Undo:    .\install_spoof.ps1 -Remove'
