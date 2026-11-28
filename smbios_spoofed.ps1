# Same dump, but launched THROUGH spoof_host.exe so smbspoof.dll is injected.
$out = "$PSScriptRoot\smbios_spoofed.txt"
'--- SPOOFED dump ---' | Out-File $out -Encoding utf8
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FW {
    [DllImport("kernel32.dll")]
    public static extern uint GetSystemFirmwareTable(uint provider, uint tableId, byte[] buffer, uint size);
}
'@
    $size = [FW]::GetSystemFirmwareTable(0x52534D42, 0, $null, 0)
    "table size = $size" | Out-File $out -Append -Encoding utf8
    if ($size -gt 0) {
        $buf = New-Object byte[] $size
        [void][FW]::GetSystemFirmwareTable(0x52534D42, 0, $buf, $size)
        ([System.Text.Encoding]::ASCII.GetString($buf) -split "`0") |
            Where-Object { $_ -match '\S' } | Sort-Object -Unique |
            Out-File $out -Append -Encoding utf8
    }
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File $out -Append -Encoding utf8
}
'--- done ---' | Out-File $out -Append -Encoding utf8
