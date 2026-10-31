# Capture the cursor trajectory to JSONL at the sensor rate.
#
# The two debug CSRs are polled back to back with no sleep, so the sample rate is
# set by the UART round trip (~400-500 Hz measured) rather than by the sensor's
# 138 Hz. Oversampling is harmless: arc length has a 40-count deadzone, and
# duplicate points add no distance.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_capture_xy.ps1 -Seconds 8
param(
  [string]$Port = 'COM4',
  [int]$Baud = 1000000,
  [int]$Seconds = 8,
  [string]$Out = 'artifacts/board/xy.jsonl'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null

function Get-Crc16([byte[]]$b) {
  $crc = 0xFFFF
  foreach ($x in $b) {
    $crc = $crc -bxor ([int]$x -shl 8)
    for ($i = 0; $i -lt 8; $i++) {
      if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF } else { $crc = ($crc -shl 1) -band 0xFFFF }
    }
  }
  return $crc
}

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.WriteTimeout = 400
$sp.Open(); Start-Sleep -Milliseconds 60; $sp.DiscardInBuffer()
$script:seq = 0

function Read-Val([int]$addr) {
  $script:seq = ($script:seq + 1) -band 0xFF
  $f = New-Object byte[] 11
  $f[0] = 0xA5; $f[1] = 0x02; $f[2] = 0x01; $f[3] = [byte]$addr; $f[4] = [byte]$script:seq
  $c = Get-Crc16 $f[0..8]; $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
  $sp.Write($f, 0, 11)
  $buf = New-Object 'System.Collections.Generic.List[byte]'
  $dl = (Get-Date).AddMilliseconds(200)
  while ((Get-Date) -lt $dl -and $buf.Count -lt 22) { try { $buf.Add([byte]$sp.ReadByte()) } catch { break } }
  if ($buf.Count -ne 22) { return $null }
  $r = $buf.ToArray()
  if ($r[4] -ne $script:seq) { return $null }
  return [uint32]((([uint64]$r[14]) -shl 24) -bor (([uint64]$r[15]) -shl 16) -bor (([uint64]$r[16]) -shl 8) -bor [uint64]$r[17])
}

$lines = New-Object 'System.Collections.Generic.List[string]'
$t0 = Get-Date
$deadline = $t0.AddSeconds($Seconds)
$n = 0; $skipped = 0
while ((Get-Date) -lt $deadline) {
  $x = Read-Val 0xF0
  $y = Read-Val 0xD8
  if ($null -eq $x -or $null -eq $y) { $skipped++; continue }
  $lines.Add(('{{"seq":{0},"x":{1},"y":{2}}}' -f $n, ($x -band 0xFFFF), ($y -band 0xFFFF)))
  $n++
}
$sp.Close(); $sp.Dispose()

[System.IO.File]::WriteAllLines((Join-Path (Get-Location) $Out), $lines, (New-Object System.Text.UTF8Encoding($false)))
$dt = ((Get-Date) - $t0).TotalSeconds
"captured {0} samples in {1:N1} s ({2:N0} Hz), skipped {3} bad frames -> {4}" -f $n, $dt, ($n / $dt), $skipped, $Out
if ($n -lt 50) { "WARNING: too few samples; was the hand moving?"; exit 1 }
