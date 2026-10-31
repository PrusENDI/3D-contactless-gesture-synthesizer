# Coordinate chain probe: read the raw sensor coordinate and the cursor output
# together, so the hand position can be compared against what the display shows.
#
# 0xDC = raw_x (signed), 0xFC = raw_y (signed)
# 0xF0 = cursor_x (0..65535), 0xD8 = cursor_y (0..65535)
param([string]$Port = 'COM4', [int]$Baud = 1000000, [int]$Seconds = 15,
      [string]$LogPath = 'artifacts/board/coord_chain.log')

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
    $sp.DiscardInBuffer(); $sp.Write($f, 0, 11)
    $buf = New-Object 'System.Collections.Generic.List[byte]'
    $dl = (Get-Date).AddMilliseconds(300)
    while ((Get-Date) -lt $dl -and $buf.Count -lt 22) { try { $buf.Add([byte]$sp.ReadByte()) } catch { break } }
    if ($buf.Count -eq 22) { $r = $buf.ToArray(); return [uint32]((([uint64]$r[14]) -shl 24) -bor (([uint64]$r[15]) -shl 16) -bor (([uint64]$r[16]) -shl 8) -bor [uint64]$r[17]) }
    return [uint32]::MaxValue
}
function As-Signed16([uint32]$v) { $x = $v -band 0xFFFF; if ($x -ge 32768) { return $x - 65536 } else { return $x } }

Log ("const=0x{0:X8}" -f (Read-Csr 0xB0))
Log 'time   raw_x  raw_y   cursor_x cursor_y'
for ($i = 0; $i -lt $Seconds; $i++) {
    $rx = (Read-Csr 0xDC) -band 0xFFFF
    $ry = (Read-Csr 0xFC) -band 0xFFFF
    $cx = (Read-Csr 0xF0) -band 0xFFFF
    $cy = (Read-Csr 0xD8) -band 0xFFFF
    Log ("{0,3}s  {1,6} {2,6}   {3,8} {4,8}" -f $i, $rx, $ry, $cx, $cy)
    Start-Sleep -Milliseconds 600
}
$sp.Close(); $sp.Dispose()
Log 'done'
