<#
.SYNOPSIS
    Starts Respondus LockDown Browser with the remote-session look hidden.

.DESCRIPTION
    A program running inside an RDP session sees SESSIONNAME=RDP-Tcp#N (it is
    "Console" when someone is sitting at the machine). LockDown Browser lists
    remote desktop among the things it blocks, and at least some checks read
    that variable. This launcher sets SESSIONNAME=Console and clears CLIENTNAME
    before starting LockDown Browser, so environment-variable checks see a local
    session.

    It cannot hide the OS-level "this session is remote" flag - for full
    cover, control the machine with VNC or Parsec instead of RDP, or take the
    exam on a physical PC.

.PARAMETER Path
    Full path to LockDown Browser.exe. Auto-detected if omitted.

.EXAMPLE
    .\start_lockdown.ps1
    .\start_lockdown.ps1 -Path "C:\Program Files (x86)\Respondus\LockDown Browser\LockDown Browser.exe"
#>
[CmdletBinding()]
param(
    [Parameter()][string]$Path
)

$ErrorActionPreference = 'Stop'

if (-not $Path) {
    # Respondus has shipped the exe under a few names ("LockDown Browser.exe",
    # "LockDownBrowser.exe", ...) - just take any LockDown exe in the standard
    # install folders.
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Respondus\LockDown Browser'),
        (Join-Path $env:ProgramFiles 'Respondus\LockDown Browser'),
        (Join-Path $env:LOCALAPPDATA 'Respondus\LockDown Browser')
    )
    $candidates = foreach ($r in $roots) {
        if ($r -and (Test-Path $r)) {
            Get-ChildItem -Path $r -Filter '*.exe' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*ockdown*' }
        }
    }
    $Path = ($candidates | Select-Object -First 1).FullName
}
if (-not $Path) {
    Write-Error "LockDown Browser not found. Install it, or pass -Path 'C:\...\LockDownBrowser.exe'."
    exit 1
}

$env:SESSIONNAME = 'Console'
$env:CLIENTNAME  = $null

$spoofHost = 'C:\ProgramData\CamBridge\spoof_host.exe'
if (Test-Path $spoofHost) {
    Write-Host "Starting LockDown Browser (SMBIOS-spoofed) with SESSIONNAME=Console ..."
    Write-Host "  ($Path)"
    Start-Process -FilePath $spoofHost -ArgumentList "`"$Path`""
} else {
    Write-Host "Starting LockDown Browser with SESSIONNAME=Console ..."
    Write-Host "  ($Path)"
    Start-Process -FilePath $Path
}
