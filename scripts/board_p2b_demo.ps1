# Audible acceptance for P2b's voice parameters: record one LOOP take (hand needed),
# then change one parameter at a time while it plays, printing what to listen for.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_p2b_demo.ps1
#   ... -SkipRecord     # a published take already exists
#   ... -HoldMs 7000
#
# Envelope: the four "step" values are PER-SAMPLE increments, so a SMALLER value is a
# SLOWER envelope.  Attack 4096 reaches full scale in 16 samples; 1024 takes 64.
# Velocity depth (0x9C[1:0]) and detune width (0x9C[3:2]) are 2-bit shifts: bigger
# means velocity matters less / the two oscillators sit closer together.
# Glide (0x9C[31:16]) only affects REVOICE, i.e. LIVE re-pitching, so it cannot be
# demonstrated from LOOP playback and is not part of this script.
param(
  [string]$Port = 'COM4',
  [int]$Baud = 1000000,
  [string]$Bin = 'artifacts/wt/voice_sine.bin',
  [int]$HoldMs = 7000,
  [int]$PrepareSeconds = 12,
  [switch]$SkipRecord
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
$sp = $null

if (-not $SkipRecord) {
  Write-Host ''
  Write-Host '==== NOW: put your hand over the sensor and sweep it back and forth ===='
  Write-Host '==== for about ten seconds; the take records itself and stops.      ===='
  Write-Host ''
  Write-Host ("uploading {0}" -f $Bin)
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_wt_upload.ps1 `
           -Port $Port -Bin $Bin -Table 0 -Version 1 -PostSelect 0x00000020 2>&1
  if (-not (($out -join "`n") -match 'RESULT: PASS')) { Write-Host ($out -join "`n"); throw 'the upload did not pass' }
  Write-Host 'upload PASS'
  for ($s = $PrepareSeconds; $s -gt 0; $s--) {
    Write-Host ("  recording starts in {0,2}s - hand over the sensor, keep sweeping" -f $s)
    Start-Sleep -Seconds 1
  }
  Write-Host '  RECORDING NOW'
  & powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_stage2_loop.ps1 -Port $Port -Tracks 1
  if ($LASTEXITCODE -ne 0) {
    throw ('the loop take failed (exit ' + $LASTEXITCODE + '); if the contour was empty, the sensor saw no hand')
  }
  Write-Host 'loop take published'
}

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
      $val = ([uint32]$buf[14] -shl 24) -bor ([uint32]$buf[15] -shl 16) -bor ([uint32]$buf[16] -shl 8) -bor [uint32]$buf[17]
      if ($buf[2] -ne 0x80) { throw ("{0}: NACKed err=0x{1:X2}" -f $What, $buf[19]) }
      if ($buf[19] -ne 0) { throw ("{0}: err=0x{1:X2}" -f $What, $buf[19]) }
      return $val
    }
  }
  throw ("{0}: no clean reply after 8 attempts" -f $What)
}

function SetAndListen([int]$addr, [uint32]$data, [string]$label, [string]$expect, [int]$ms) {
  [void](Cmd 0x02 $addr $data $label)
  $rb = Cmd 0x01 $addr 0 ($label + ' readback')
  Write-Host ("{0:HH:mm:ss} {1}" -f (Get-Date), $label)
  Write-Host ("          wrote 0x{0:X8}, read back 0x{1:X8}" -f $data, $rb)
  Write-Host ("          expect: {0}" -f $expect)
  if ($rb -ne $data) { throw ("{0}: readback 0x{1:X8} != 0x{2:X8}" -f $label, $rb, $data) }
  Start-Sleep -Milliseconds $ms
}

try {
  $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
  $sp.ReadTimeout = 400; $sp.WriteTimeout = 400
  $sp.Open(); Start-Sleep -Milliseconds 60

  $id = Cmd 0x01 0xB0 0 'read 0xB0'
  if ($id -ne 0x5A5A0003) { throw ("0xB0=0x{0:X8}: wrong bitstream" -f $id) }
  Write-Host 'bitstream id ok (0x5A5A0003)'

  # Defaults first, so every step below is a single change from a known state.
  [void](Cmd 0x02 0x94 0x01001000 'attack 4096, decay 256')
  [void](Cmd 0x02 0x98 0x0400C000 'release 1024, sustain 49152')
  [void](Cmd 0x02 0x9C 0x02000000 'glide 512, no shifts')

  [void](Cmd 0x02 0x04 4 'MODE=PLAY')
  Write-Host ''
  Write-Host '==== the take is playing; listen to the attack of each note ===='

  SetAndListen 0x94 0x01001000 '1/6 attack 4096 (default)' 'the note starts quickly, as it always did' $HoldMs
  SetAndListen 0x94 0x01000400 '2/6 attack 1024 (4x slower)' 'each note now fades in noticeably' $HoldMs
  SetAndListen 0x94 0x01001000 '3/6 back to attack 4096' 'the fast attack is back' $HoldMs
  SetAndListen 0x9C 0x02000003 '4/7 velocity_shift=3' 'the loud and soft notes should now sound nearly equal' $HoldMs
  SetAndListen 0x9C 0x02000000 '5/7 velocity back to normal' 'the difference in loudness returns' $HoldMs
  SetAndListen 0x9C 0x0200000C '6/7 detune_shift=3' 'the tone should get thinner, less chorused' $HoldMs
  SetAndListen 0x9C 0x02000000 '7/7 detune back to normal' 'the thickness comes back' $HoldMs

  [void](Cmd 0x02 0x14 1 'STOP')
  Write-Host ''
  Write-Host 'STOP sent; the take must be silent now.'
} finally {
  if ($sp -and $sp.IsOpen) { $sp.Close(); $sp.Dispose() }
}
