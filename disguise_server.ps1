<#
.SYNOPSIS
    Makes an AWS/EC2 Windows Server look like an ordinary physical Windows PC.

.DESCRIPTION
    LockDown Browser advertises detecting virtual machines and remote desktops,
    and an EC2 instance tells on itself everywhere: the BIOS strings say
    "Amazon EC2", the computer name is EC2AMAZ-XXXXXX, the OS edition says
    "Windows Server", and Amazon agent services are running. This script
    rewrites the places software actually reads:

      HKLM\HARDWARE\DESCRIPTION\System\BIOS                    (Win32_BIOS, most VM checks)
      HKLM\SYSTEM\CurrentControlSet\Control\SystemInformation  (Win32_ComputerSystem)
      HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation  ("About this PC")
      ProductName                                               (-MaskServerEdition: Server -> Windows 10 Pro)
      computer name EC2AMAZ-* -> DESKTOP-XXXXXXX               (takes effect after a reboot)
      AWS agent services stopped + disabled                     (-HideAwsAgents)

    Everything touched is backed up to disguise_backup.json; -Restore undoes it.
    HKLM\HARDWARE is rebuilt at every boot, so use -InstallStartupTask to keep
    the strings applied across reboots. Needs an elevated shell (except -Status).

    Honest caveats: this covers the COMMON signals - Respondus doesn't publish
    its exact checks, so do a practice exam before the real one. RDP detection
    is separate: use start_lockdown.ps1, or control the box with VNC/Parsec
    instead of RDP.

.PARAMETER Profile
    Which ordinary PC to imitate: dell, hp, or lenovo.

.PARAMETER ComputerName
    Rename the computer to this. Otherwise auto-renames EC2AMAZ-* to
    DESKTOP-XXXXXXX.

.PARAMETER HideAwsAgents
    Stop and disable the Amazon/AWS agent services.

.PARAMETER MaskServerEdition
    Rewrite the ProductName registry value from "Windows Server ..." to
    "Windows 10 Pro". (Cosmetic - the licence/edition itself is untouched.)

.PARAMETER InstallStartupTask
    Register a startup task that re-applies the disguise after every reboot.

.PARAMETER Restore
    Undo everything using disguise_backup.json.

.PARAMETER Status
    Just report what the machine currently looks like.

.EXAMPLE
    .\disguise_server.ps1 -Status
    .\disguise_server.ps1 -Profile dell -HideAwsAgents -MaskServerEdition -InstallStartupTask
    .\disguise_server.ps1 -Restore
#>
[CmdletBinding()]
param(
    [Parameter()][ValidateSet('dell','hp','lenovo')][string]$Profile = 'dell',
    [Parameter()][string]$ComputerName,
    [Parameter()][switch]$HideAwsAgents,
    [Parameter()][switch]$MaskServerEdition,
    [Parameter()][switch]$InstallStartupTask,
    [Parameter()][switch]$Restore,
    [Parameter()][switch]$Status
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$backupFile = Join-Path $root 'disguise_backup.json'
$taskName = 'OEM Info Sync'

$biosKey    = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
$sysInfoKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\SystemInformation'
$oemKey     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'
$winNtKey   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

$biosNames    = @('SystemManufacturer','SystemProductName','SystemFamily','SystemSKU',
                  'BaseBoardManufacturer','BaseBoardProduct','BIOSVersion','BIOSReleaseDate')
$sysInfoNames = @('SystemManufacturer','SystemProductName')
$oemNames     = @('Manufacturer','Model')
$agentServices = @('AmazonSSMAgent','AWSLiteAgent','Ec2Config','EC2Launch','AmazonCloudWatchAgent')

$profiles = @{
    dell = @{
        bios    = @{ SystemManufacturer='Dell Inc.'; SystemProductName='Latitude 5420'; SystemFamily='Latitude'; SystemSKU='Latitude 5420'; BaseBoardManufacturer='Dell Inc.'; BaseBoardProduct='0Y3WGG'; BIOSVersion='1.19.0'; BIOSReleaseDate='10/12/2023' }
        sysinfo = @{ SystemManufacturer='Dell Inc.'; SystemProductName='Latitude 5420' }
        oem     = @{ Manufacturer='Dell Inc.'; Model='Latitude 5420' }
    }
    hp = @{
        bios    = @{ SystemManufacturer='HP'; SystemProductName='HP ProBook 450 G8 Notebook PC'; SystemFamily='103C_5336KV HP ProBook'; SystemSKU='2A1E9EA#ABU'; BaseBoardManufacturer='HP'; BaseBoardProduct='87F9'; BIOSVersion='S70 Ver. 01.05.00'; BIOSReleaseDate='05/03/2021' }
        sysinfo = @{ SystemManufacturer='HP'; SystemProductName='HP ProBook 450 G8 Notebook PC' }
        oem     = @{ Manufacturer='HP'; Model='HP ProBook 450 G8' }
    }
    lenovo = @{
        bios    = @{ SystemManufacturer='LENOVO'; SystemProductName='20N2S1X900'; SystemFamily='ThinkPad T490'; SystemSKU='LENOVO_MT_20N2_BU_Think'; BaseBoardManufacturer='LENOVO'; BaseBoardProduct='20N2S1X900'; BIOSVersion='N23ET58W (1.33 )'; BIOSReleaseDate='07/08/2021' }
        sysinfo = @{ SystemManufacturer='LENOVO'; SystemProductName='20N2S1X900' }
        oem     = @{ Manufacturer='LENOVO'; Model='ThinkPad T490' }
    }
}

function Test-Elevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole(
        [System.Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-RegValue($key, $name) {
    try { return (Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name } catch { return $null }
}

# ---------------------------------------------------------------------------
if ($Status) {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    Write-Host "Computer name : $env:COMPUTERNAME"
    Write-Host "Registry now  : '$(Get-RegValue $biosKey 'SystemManufacturer')' / '$(Get-RegValue $biosKey 'SystemProductName')'  (what a fresh reader sees)"
    Write-Host "WMI reports   : Manufacturer='$($cs.Manufacturer)'  Model='$($cs.Model)'  (cached until Winmgmt restarts)"
    Write-Host "BIOS (WMI)    : '$($bios.Manufacturer)' / '$($bios.SMBIOSBIOSVersion)'"
    Write-Host "ProductName   : $(Get-RegValue $winNtKey 'ProductName')"
    Write-Host "SESSIONNAME   : $env:SESSIONNAME"
    $agents = Get-Service -Name $agentServices -ErrorAction SilentlyContinue
    if ($agents) { Write-Host "AWS agents    : $(($agents.Name | Select-Object -Unique) -join ', ')" }
    if (Test-Path $backupFile) { Write-Host "Backup        : $backupFile (can -Restore)" }
    exit 0
}

if (-not (Test-Elevated)) {
    Write-Error 'Run this from an elevated PowerShell (Run as administrator).'
    exit 1
}

# ---------------------------------------------------------------------------
if ($Restore) {
    if (-not (Test-Path $backupFile)) { Write-Error "No backup found at $backupFile."; exit 1 }
    $b = Get-Content $backupFile -Raw | ConvertFrom-Json
    foreach ($n in $biosNames) {
        if ($null -ne $b.bios.$n) { Set-ItemProperty -Path $biosKey -Name $n -Value $b.bios.$n }
        else { Remove-ItemProperty -Path $biosKey -Name $n -ErrorAction SilentlyContinue }
    }
    foreach ($n in $sysInfoNames) {
        if ($null -ne $b.sysinfo.$n) { Set-ItemProperty -Path $sysInfoKey -Name $n -Value $b.sysinfo.$n }
        else { Remove-ItemProperty -Path $sysInfoKey -Name $n -ErrorAction SilentlyContinue }
    }
    if (Test-Path $oemKey) {
        foreach ($n in $oemNames) {
            if ($null -ne $b.oem.$n) { Set-ItemProperty -Path $oemKey -Name $n -Value $b.oem.$n }
            else { Remove-ItemProperty -Path $oemKey -Name $n -ErrorAction SilentlyContinue }
        }
        if ($b.createdOemKey) { Remove-Item -Path $oemKey -Force -ErrorAction SilentlyContinue }
    }
    if ($null -ne $b.productName) { Set-ItemProperty -Path $winNtKey -Name 'ProductName' -Value $b.productName }
    if ($b.services) {
        foreach ($prop in @($b.services.PSObject.Properties)) {
            try { Set-Service -Name $prop.Name -StartupType $prop.Value } catch { }
        }
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if ($b.computerName -and $b.computerName -ne $env:COMPUTERNAME) {
        Rename-Computer -NewName $b.computerName -Force -WarningAction SilentlyContinue
        Write-Host "Computer name reverts to '$($b.computerName)' after the next reboot."
    }
    try { Restart-Service Winmgmt -Force -ErrorAction Stop } catch { }
    Write-Host 'Restored.'
    exit 0
}

# ---------------------------------------------------------------------------
# Back up everything we are about to touch, then apply.
$backup = [ordered]@{
    bios          = @{}
    sysinfo       = @{}
    oem           = @{}
    productName   = Get-RegValue $winNtKey 'ProductName'
    computerName  = $env:COMPUTERNAME
    createdOemKey = -not (Test-Path $oemKey)
    services      = @{}
}
foreach ($n in $biosNames)    { $backup.bios[$n]    = Get-RegValue $biosKey $n }
foreach ($n in $sysInfoNames) { $backup.sysinfo[$n] = Get-RegValue $sysInfoKey $n }
foreach ($n in $oemNames)     { $backup.oem[$n]     = Get-RegValue $oemKey $n }

$p = $profiles[$Profile]
foreach ($n in $biosNames)    { Set-ItemProperty -Path $biosKey    -Name $n -Value $p.bios[$n] }
foreach ($n in $sysInfoNames) { Set-ItemProperty -Path $sysInfoKey -Name $n -Value $p.sysinfo[$n] }
if (-not (Test-Path $oemKey)) { New-Item -Path $oemKey -Force | Out-Null }
foreach ($n in $oemNames)     { Set-ItemProperty -Path $oemKey -Name $n -Value $p.oem[$n] }

if ($MaskServerEdition) {
    Set-ItemProperty -Path $winNtKey -Name 'ProductName' -Value 'Windows 10 Pro'
}

# WMI caches BIOS/system strings - restart it so queries see the new ones now.
try {
    Restart-Service Winmgmt -Force -ErrorAction Stop
    Write-Host 'WMI service restarted (WMI itself may still need a reboot to show the new strings).'
} catch {
    Write-Host 'Could not restart the WMI service - new strings reach WMI after a reboot.'
}

$newName = $ComputerName
if (-not $newName -and $env:COMPUTERNAME -like 'EC2AMAZ-*') {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    $newName = 'DESKTOP-' + (-join (1..7 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] }))
}
if ($newName -and $newName -ne $env:COMPUTERNAME) {
    Rename-Computer -NewName $newName -Force -WarningAction SilentlyContinue
    Write-Host "Computer renamed to '$newName' - takes effect after the next reboot."
}

if ($HideAwsAgents) {
    foreach ($s in $agentServices) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc) {
            $backup.services[$s] = [string]$svc.StartType
            Stop-Service -InputObject $svc -Force -ErrorAction SilentlyContinue
            Set-Service -InputObject $svc -StartupType Disabled
            Write-Host "Stopped + disabled service '$s'."
        }
    }
}

$backup | ConvertTo-Json -Depth 4 | Set-Content -Path $backupFile -Encoding UTF8

if ($InstallStartupTask) {
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$root\disguise_server.ps1`" -Profile $Profile"
    if ($MaskServerEdition) { $arg += ' -MaskServerEdition' }
    if ($HideAwsAgents)    { $arg += ' -HideAwsAgents' }
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trg = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -RunLevel Highest -Force | Out-Null
    Write-Host "Startup task '$taskName' registered - the disguise re-applies after every reboot."
}

Write-Host "Done. The machine now presents as a $Profile PC."
if (-not $InstallStartupTask) {
    Write-Host 'Note: HKLM\HARDWARE resets at every reboot - re-run this, or use -InstallStartupTask.'
}


