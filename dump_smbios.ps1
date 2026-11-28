<#
.SYNOPSIS
    Dumps the strings in this machine's raw SMBIOS table.

.DESCRIPTION
    Two uses:
      1. Find which VM-identifying strings a machine exposes (feed them to
         smbspoof.txt as old=>new pairs).
      2. Verify spoofing: run it directly (real strings) and through
         spoof_host.exe (spoofed strings) and compare.
#>
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FW {
    [DllImport("kernel32.dll")]
    public static extern uint GetSystemFirmwareTable(uint provider, uint tableId, byte[] buffer, uint size);
}
'@

$size = [FW]::GetSystemFirmwareTable(0x52534D42, 0, $null, 0)   # 0x52534D42 = 'RSMB'
if ($size -eq 0) { Write-Error 'No SMBIOS table found.'; exit 1 }

$buf = New-Object byte[] $size
[void][FW]::GetSystemFirmwareTable(0x52534D42, 0, $buf, $size)
Write-Host "SMBIOS table: $size bytes. Distinct strings:"
([System.Text.Encoding]::ASCII.GetString($buf) -split "`0") |
    Where-Object { $_ -match '\S' } | Sort-Object -Unique
