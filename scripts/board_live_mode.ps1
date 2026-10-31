# Switch the LIVE rule at run time: frame tracking or the step arpeggiator.
#
# The choice is one bit (THRESHOLDS[23]); the rule engine samples it every frame,
# so a write takes effect on the next tick - no reboot, no re-flash.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_live_mode.ps1 -Mode arp
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_live_mode.ps1 -Mode track -Note 69
#   ... -Live      # also enter LIVE mode afterwards
#
# NOTE: host/cursor_view.py owns COM4 while it runs; close it first.
param(
  [string]$Port = 'COM4',
  [ValidateSet('arp', 'track')][string]$Mode = 'arp',
  [int]$Note = 69,
  [switch]$Live
)

$ErrorActionPreference = 'Stop'
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

# THRESHOLDS requires low half < high half; 0x0180 keeps that true with bit23 set.
$high = if ($Mode -eq 'arp') { 0x0180 } else { 0x0100 }
$value = ([uint32]$high -shl 16) -bor ([uint32]($Note -band 0xFF))

$sp = New-Object System.IO.Ports.SerialPort $Port, 1000000, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 400; $sp.WriteTimeout = 400
try { $sp.Open() } catch { "FATAL: cannot open $Port (is cursor_view.py running?)"; exit 2 }
Start-Sleep -Milliseconds 60; $sp.DiscardInBuffer()
$script:seq = Get-Random -Minimum 0 -Maximum 255   # a stale duplicate reads as V2_ERR_SEQUENCE

function Send([int]$op, [int]$addr, [uint32]$data) {
  $script:seq = ($script:seq + 1) -band 0xFF
  $f = New-Object byte[] 11
  $f[0] = 0xA5; $f[1] = 0x02; $f[2] = [byte]$op; $f[3] = [byte]$addr; $f[4] = [byte]$script:seq
  $f[5] = [byte](($data -shr 24) -band 0xFF); $f[6] = [byte](($data -shr 16) -band 0xFF)
  $f[7] = [byte](($data -shr 8) -band 0xFF);  $f[8] = [byte]($data -band 0xFF)
  $c = Get-Crc16 $f[0..8]; $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
  $sp.Write($f, 0, 11)
  $buf = New-Object 'System.Collections.Generic.List[byte]'
  $dl = (Get-Date).AddMilliseconds(400)
  while ((Get-Date) -lt $dl -and $buf.Count -lt 22) { try { $buf.Add([byte]$sp.ReadByte()) } catch { break } }
  if ($buf.Count -ne 22 -or $buf.ToArray()[4] -ne $script:seq) { return @{ e = 255; d = 0 } }
  $r = $buf.ToArray()
  return @{ e = $r[19]; d = [uint32]((([uint64]$r[14]) -shl 24) -bor (([uint64]$r[15]) -shl 16) -bor (([uint64]$r[16]) -shl 8) -bor [uint64]$r[17]) }
}

$w = Send 0x02 0x30 $value
$rb = Send 0x01 0x30 0
"write THRESHOLDS=0x{0:X8} err={1}; readback=0x{2:X8}; mode={3}" -f $value, $w.e, $rb.d, $Mode
if ($Live) { $null = Send 0x02 0x04 1; Start-Sleep -Milliseconds 200 }
"STATUS=0x{0:X8} (1 = LIVE)" -f (Send 0x01 0x00 0).d
"E8=0x{0:X8}" -f (Send 0x01 0xE8 0).d
$sp.Close(); $sp.Dispose()
