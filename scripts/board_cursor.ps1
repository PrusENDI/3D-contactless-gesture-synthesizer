# Read the cursor telemetry stream and print what the sensor reports.
#
# TLM_CONTROL (0x80) bit0 enables the snapshot stream and bits 31:16 set the
# capture period in audio samples; 2400 gives about 20 frames per second, which
# is what a 1 Mbaud link can carry.
param([string]$Port = 'COM4', [int]$Baud = 1000000, [int]$Seconds = 8, [int]$Period = 2400,
      [string]$LogPath = 'artifacts/board/cursor.log')

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
function Log([string]$t) { $l = "{0:HH:mm:ss.fff} {1}" -f (Get-Date), $t; Write-Output $l; Add-Content -Path $LogPath -Value $l -Encoding utf8 }
function Get-Crc16([byte[]]$b) { $crc = 0xFFFF; foreach ($x in $b) { $crc = $crc -bxor ([int]$x -shl 8); for ($i = 0; $i -lt 8; $i++) { if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF } else { $crc = ($crc -shl 1) -band 0xFFFF } } }; return $crc }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.WriteTimeout = 400
$sp.Open(); Start-Sleep -Milliseconds 50; $sp.DiscardInBuffer()
$seq = 0
function Cmd([int]$Op, [int]$Addr, [uint32]$Data) {
    $script:seq = ($script:seq + 1) -band 0xFF
    $f = New-Object byte[] 11
    $f[0] = 0xA5; $f[1] = 0x02; $f[2] = [byte]$Op; $f[3] = [byte]$Addr; $f[4] = [byte]$script:seq
    $f[5] = [byte](($Data -shr 24) -band 0xFF); $f[6] = [byte](($Data -shr 16) -band 0xFF)
    $f[7] = [byte](($Data -shr 8) -band 0xFF); $f[8] = [byte]($Data -band 0xFF)
    $c = Get-Crc16 $f[0..8]; $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
    $sp.Write($f, 0, 11); Start-Sleep -Milliseconds 15
    $buf = New-Object 'System.Collections.Generic.List[byte]'
    $dl = (Get-Date).AddMilliseconds(300)
    while ((Get-Date) -lt $dl -and $buf.Count -lt 22) { try { $buf.Add([byte]$sp.ReadByte()) } catch { break } }
    if ($buf.Count -eq 22) { $r = $buf.ToArray(); return [pscustomobject]@{ Err = [int]$r[19]; Val = [uint32]((([uint64]$r[14]) -shl 24) -bor (([uint64]$r[15]) -shl 16) -bor (([uint64]$r[16]) -shl 8) -bor [uint64]$r[17]) } }
    return [pscustomobject]@{ Err = 255; Val = [uint32]::MaxValue }
}

$word = [uint32]((([uint64]$Period -shl 16) -bor 1))
$r = Cmd 0x02 0x80 $word
Log ("TLM_CONTROL write = 0x{0:X8} -> err={1}; readback=0x{2:X8}" -f $word, $r.Err, (Cmd 0x01 0x80 0).Val)

Log ("reading telemetry for {0}s - touch the pad now" -f $Seconds)
$deadline = (Get-Date).AddSeconds($Seconds)
$raw = New-Object 'System.Collections.Generic.List[byte]'
while ((Get-Date) -lt $deadline) {
    if ($sp.BytesToRead -gt 0) {
        $n = $sp.BytesToRead
        $tmp = New-Object byte[] $n
        [void]$sp.Read($tmp, 0, $n)
        $raw.AddRange($tmp)
    }
    Start-Sleep -Milliseconds 10
}
$sp.Close(); $sp.Dispose()

$buf = $raw.ToArray()
$frames = 0; $xs = @(); $ys = @(); $zs = @(); $seqs = @()
for ($i = 0; $i + 21 -lt $buf.Length; ) {
    if ($buf[$i] -eq 0x5A -and $buf[$i+1] -eq 0x02 -and $buf[$i+2] -eq 0x01) {
        $x = [int16](($buf[$i+5] -shl 8) -bor $buf[$i+6])
        $y = [int16](($buf[$i+7] -shl 8) -bor $buf[$i+8])
        $z = [int16](($buf[$i+9] -shl 8) -bor $buf[$i+10])
        $frames++
        if ($xs.Count -lt 20) { $xs += $x; $ys += $y; $zs += $z; $seqs += (($buf[$i+3] -shl 8) -bor $buf[$i+4]) }
        $i += 22
    } else { $i++ }
}
Log ("bytes={0} snapshot_frames={1}" -f $buf.Length, $frames)
for ($k = 0; $k -lt $xs.Count; $k++) { Log ("  seq={0} x={1} y={2} z={3}" -f $seqs[$k], $xs[$k], $ys[$k], $zs[$k]) }
if ($frames -eq 0) { Log 'RESULT: NO TELEMETRY - cursor never valid (no touch) or stream not enabled'; exit 1 }
$distinct = ($xs | Select-Object -Unique).Count
Log ("RESULT: {0} frames, {1} distinct x values" -f $frames, $distinct)
