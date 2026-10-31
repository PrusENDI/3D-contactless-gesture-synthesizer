# Cursor pipeline trace: one line per second with every stage counter, so a touch
# can be seen moving through report -> xyz -> frame -> point -> cursor.
param([string]$Port = 'COM4', [int]$Baud = 1000000, [int]$Seconds = 12,
      [string]$LogPath = 'artifacts/board/cursor_trace.log')

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
function Log([string]$t) { $l = "{0:HH:mm:ss.fff} {1}" -f (Get-Date), $t; Write-Output $l; Add-Content -Path $LogPath -Value $l -Encoding utf8 }
function Get-Crc16([byte[]]$b) { $crc = 0xFFFF; foreach ($x in $b) { $crc = $crc -bxor ([int]$x -shl 8); for ($i = 0; $i -lt 8; $i++) { if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF } else { $crc = ($crc -shl 1) -band 0xFFFF } } }; return $crc }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.WriteTimeout = 400
$sp.Open(); Start-Sleep -Milliseconds 50; $sp.DiscardInBuffer()
$seq = 0
function Read-Csr([int]$Addr) {
    $script:seq = ($script:seq + 1) -band 0xFF
    $f = New-Object byte[] 11
    $f[0] = 0xA5; $f[1] = 0x02; $f[2] = 0x01; $f[3] = [byte]$Addr; $f[4] = [byte]$script:seq
    $c = Get-Crc16 $f[0..8]; $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
    $sp.Write($f, 0, 11)
    $buf = New-Object 'System.Collections.Generic.List[byte]'
    $dl = (Get-Date).AddMilliseconds(300)
    while ((Get-Date) -lt $dl -and $buf.Count -lt 22) { try { $buf.Add([byte]$sp.ReadByte()) } catch { break } }
    if ($buf.Count -eq 22) { $r = $buf.ToArray(); return [uint32]((([uint64]$r[14]) -shl 24) -bor (([uint64]$r[15]) -shl 16) -bor (([uint64]$r[16]) -shl 8) -bor [uint64]$r[17]) }
    return 0
}

$names = @(0x01,0x02,0x04,0x08,0x10,0x20,0x40)
$labels = @('INVALID','SATURATED','GAP','EPOCH','CLAMP','PROFILE','ARITH')
Log 'CSR map: 0xD0=reports 0xEC=valid_frame 0xE4=cursor_fsm_state 0xE0=frame_cal_z(32) 0xF8=point 0xF0=cursor_x 0xD8=cursor_y 0xFC=reason'
Log 'time  reports frame fsm  z(pointwise) point cursor_x cursor_y reason'
for ($i = 0; $i -lt $Seconds; $i++) {
    $r = Read-Csr 0xFC
    $bits = @()
    for ($k = 0; $k -lt $names.Count; $k++) { if ($r -band $names[$k]) { $bits += $labels[$k] } }
    $why = if ($bits.Count) { $bits -join '+' } else { 'none' }
    Log ("{0,3}s  rep={1,6} frame={2,6} fsm={3,2}  z=0x{4:X8} point={5,5} cx={6,5} cy={7,5}  reason=0x{8:X2} {9}" -f `
        $i, (Read-Csr 0xD0), (Read-Csr 0xEC), (Read-Csr 0xE4), (Read-Csr 0xE0), (Read-Csr 0xF8), (Read-Csr 0xF0), (Read-Csr 0xD8), $r, $why)
    Start-Sleep -Milliseconds 700
}
$sp.Close(); $sp.Dispose()
Log 'done'
