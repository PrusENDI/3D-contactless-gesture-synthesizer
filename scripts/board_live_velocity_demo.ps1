# LIVE velocity-depth A/B: the one place where 0x9C[1:0] actually matters.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_live_velocity_demo.ps1
#
# LOOP playback carries no per-note velocity (the contour records only cursor_y and
# engaged), so velocity depth cannot be heard there.  LIVE mode derives velocity from
# the gesture, so the same hand motion with velocity_shift 0 then 3 shows the effect.
#
# Keep the SAME motion in all three windows: come in slowly from far to near, then
# back out.  The point is the contrast between strong and soft notes, not the notes.
param(
  [string]$Port = 'COM4',
  [int]$Baud = 1000000,
  [int]$HoldMs = 14000
)

$ErrorActionPreference = 'Stop'

function Get-Crc16([byte[]]$b) {
  $crc = 0xFFFF
  foreach ($x in $b) {
    $crc = $crc -bxor ([int]$x -shl 8)
    for ($i = 0; $i -lt 8; $i++) {
      if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF }
      else { $crc = ($crc -shl 1) -band 0xFFFF }
    }
  }
  return $crc
}

$seq = 0
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 400; $sp.WriteTimeout = 400

function Cmd([int]$Op, [int]$Addr, [uint32]$Data, [string]$What) {
  $script:seq = ($script:seq + 1) -band 0xFF
  $f = New-Object byte[] 11
  $f[0] = 0xA5; $f[1] = 0x02; $f[2] = [byte]$Op; $f[3] = [byte]$Addr; $f[4] = [byte]$script:seq
  $f[5] = [byte](($Data -shr 24) -band 0xFF); $f[6] = [byte](($Data -shr 16) -band 0xFF)
  $f[7] = [byte](($Data -shr 8) -band 0xFF); $f[8] = [byte]($Data -band 0xFF)
  $c = Get-Crc16 $f[0..8]
  $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
  for ($attempt = 1; $attempt -le 8; $attempt++) {
    $sp.DiscardInBuffer()
    $sp.Write($f, 0, 11)
    $buf = New-Object System.Collections.Generic.List[byte]
    $dl = (Get-Date).AddMilliseconds(500)
    while ((Get-Date) -lt $dl -and $buf.Count -lt 22) {
      try { $buf.Add([byte]$sp.ReadByte()) } catch { }
    }
    if ($buf.Count -eq 22 -and $buf[0] -eq 0x5A -and $buf[1] -eq 0x02 -and
        ($buf[2] -eq 0x80 -or $buf[2] -eq 0x81) -and $buf[4] -eq $script:seq) {
      if ($buf[2] -ne 0x80) { throw ("{0}: NACKed err=0x{1:X2}" -f $What, $buf[19]) }
      if ($buf[19] -ne 0) { throw ("{0}: err=0x{1:X2}" -f $What, $buf[19]) }
      return (([uint32]$buf[14] -shl 24) -bor ([uint32]$buf[15] -shl 16) -bor ([uint32]$buf[16] -shl 8) -bor [uint32]$buf[17])
    }
  }
  throw ("{0}: no clean reply after 8 attempts" -f $What)
}

function SetAndListen([int]$addr, [uint32]$data, [string]$label, [string]$expect, [int]$ms) {
  [void](Cmd 0x02 $addr $data $label)
  $rb = Cmd 0x01 $addr 0 ($label + ' readback')
  Write-Host ("{0:HH:mm:ss} {1}" -f (Get-Date), $label)
  Write-Host ("          wrote 0x{0:X8}, read back 0x{1:X8}" -f $data, $rb)
  Write-Host ("          now: {0}" -f $expect)
  if ($rb -ne $data) { throw ("{0}: readback 0x{1:X8} != 0x{2:X8}" -f $label, $rb, $data) }
  Start-Sleep -Milliseconds $ms
}

try {
  $sp.Open(); Start-Sleep -Milliseconds 60
  $id = Cmd 0x01 0xB0 0 'read 0xB0'
  if ($id -ne 0x5A5A0003) { throw ("0xB0=0x{0:X8}: wrong bitstream" -f $id) }
  Write-Host 'bitstream id ok (0x5A5A0003)'

  [void](Cmd 0x02 0x14 1 'STOP')
  [void](Cmd 0x02 0x94 0x01001000 'attack 4096, decay 256')
  [void](Cmd 0x02 0x98 0x0400C000 'release 1024, sustain 49152')
  [void](Cmd 0x02 0x04 1 'MODE=LIVE')
  Write-Host ''
  Write-Host '==== LIVE: sweep the hand slowly from far to near and back, three times ===='
  Write-Host '==== keep the same motion in every window; listen only to the contrast  ===='
  Write-Host ''

  SetAndListen 0x9C 0x02000000 '1/3 velocity_shift=0 (full velocity effect)' 'strong and soft notes should differ a lot' $HoldMs
  SetAndListen 0x9C 0x02000003 '2/3 velocity_shift=3 (1/8 of the effect)' 'the loud and soft notes should sound nearly equal' $HoldMs
  SetAndListen 0x9C 0x02000000 '3/3 back to velocity_shift=0' 'the strong/soft contrast should come back' $HoldMs

  [void](Cmd 0x02 0x14 1 'STOP')
  Write-Host ''
  Write-Host 'STOP sent; the synth is silent now.'
} finally {
  if ($sp -and $sp.IsOpen) { $sp.Close(); $sp.Dispose() }
}
