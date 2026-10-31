# LIVE path check: switch to LIVE, then watch events, gate and note while touching.
# 0xD4 = live event count, 0xE8 = {active, gate, note[7:0]}, 0xF8 = cursor points.
param([string]$Port = 'COM4', [int]$Baud = 1000000, [int]$Seconds = 12,
      [int]$Mode = 1, [string]$LogPath = 'artifacts/board/live_path.log')

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
function Log([string]$t) { $l = "{0:HH:mm:ss.fff} {1}" -f (Get-Date), $t; Write-Output $l; Add-Content -Path $LogPath -Value $l -Encoding utf8 }
function Get-Crc16([byte[]]$b) { $crc = 0xFFFF; foreach ($x in $b) { $crc = $crc -bxor ([int]$x -shl 8); for ($i = 0; $i -lt 8; $i++) { if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF } else { $crc = ($crc -shl 1) -band 0xFFFF } } }; return $crc }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.WriteTimeout = 400
$sp.Open(); Start-Sleep -Milliseconds 50; $sp.DiscardInBuffer()
$seq = 0
function X {
    param([int]$Op, [int]$Addr, [uint32]$Data)
    $script:seq = ($script:seq + 1) -band 0xFF
    $f = New-Object byte[] 11
    $f[0] = 0xA5; $f[1] = 0x02; $f[2] = [byte]$Op; $f[3] = [byte]$Addr; $f[4] = [byte]$script:seq
    $f[5] = [byte](($Data -shr 24) -band 0xFF); $f[6] = [byte](($Data -shr 16) -band 0xFF)
    $f[7] = [byte](($Data -shr 8) -band 0xFF); $f[8] = [byte]($Data -band 0xFF)
    $c = Get-Crc16 $f[0..8]; $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
    $sp.DiscardInBuffer(); $sp.Write($f, 0, 11)
    $buf = New-Object 'System.Collections.Generic.List[byte]'
    $dl = (Get-Date).AddMilliseconds(300)
    while ((Get-Date) -lt $dl -and $buf.Count -lt 22) { try { $buf.Add([byte]$sp.ReadByte()) } catch { break } }
    if ($buf.Count -eq 22) {
        $rx = $buf.ToArray()
        return [pscustomobject]@{ Err = [int]$rx[19]; Val = [uint32]((([uint64]$rx[14]) -shl 24) -bor (([uint64]$rx[15]) -shl 16) -bor (([uint64]$rx[16]) -shl 8) -bor [uint64]$rx[17]) }
    }
    return [pscustomobject]@{ Err = 255; Val = [uint32]::MaxValue }
}

Log ("const=0x{0:X8}" -f (X 0x01 0xB0 0).Val)
$m = X 0x02 0x04 ([uint32]$Mode)
Log ("MODE={0} -> err={1}" -f $Mode, $m.Err)
Log 'time  events  active gate note  points'
for ($i = 0; $i -lt $Seconds; $i++) {
    $ev = X 0x01 0xD4 0
    $st = X 0x01 0xE8 0
    $pt = X 0x01 0xF8 0
    $active = ($st.Val -shr 9) -band 1
    $gate = ($st.Val -shr 8) -band 1
    $note = $st.Val -band 0xFF
    Log ("{0,3}s  {1,6}  {2,6} {3,4} {4,4}  {5,5}" -f $i, $ev.Val, $active, $gate, $note, $pt.Val)
    Start-Sleep -Milliseconds 700
}
$sp.Close(); $sp.Dispose()
Log 'done'
