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
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Respondus\LockDown Browser\LockDown Browser.exe'),
        (Join-Path $env:ProgramFiles 'Respondus\LockDown Browser\LockDown Browser.exe'),
        (Join-Path $env:LOCALAPPDATA 'Respondus\LockDown Browser\LockDown Browser.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }
    $Path = $candidates | Select-Object -First 1
}
if (-not $Path) {
    Write-Error "LockDown Browser not found. Install it, or pass -Path 'C:\...\LockDown Browser.exe'."
    exit 1
}

$env:SESSIONNAME = 'Console'
$env:CLIENTNAME  = $null

Write-Host "Starting LockDown Browser with SESSIONNAME=Console ..."
Write-Host "  ($Path)"
Start-Process -FilePath $Path
