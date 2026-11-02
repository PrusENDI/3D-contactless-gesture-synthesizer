# Audible A/B for the P2a filter, LFO and master volume — no hand required.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_filter_demo.ps1
#
# Why WT_PLAY: it plays one uploaded table at a fixed note with no gesture, so the
# filter can be demonstrated repeatedly without waving at the sensor.  The loop
# take would give a richer sound but needs a hand.
#
# The tone is the uploaded table at the WT_PLAY test note (THRESHOLDS[7:0], 72 is
# C5 ~523 Hz), so a cutoff under 523 Hz audibly attenuates it and the LFO sweep is
# heard as a level/timbre movement.  Each step prints what to listen for and how
# long it lasts.
param(
  [string]$Port = 'COM4',
  [int]$Baud = 1000000,
  [string]$Bin = 'artifacts/wt/voice_sine.bin',
  [int]$Note = 72,
  [int]$HoldMs = 6000,
  [switch]$SkipUpload
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

# The port must NOT be open while board_wt_upload.ps1 runs (it takes COM4 itself),
# so the upload happens before this script grabs the port.
$seq = 0

# One command, one well-formed reply.  The link carries one outstanding frame,
# and a telemetry stream (if somebody left it on) interleaves 22-byte frames, so
# validate the header instead of trusting the first 22 bytes.
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
      if ($buf[19] -ne 0) { throw ("{0}: err=0x{1:X2} (value 0x{2:X8})" -f $What, $buf[19], $val) }
      return $val
    }
  }
  throw ("{0}: no clean reply after 8 attempts" -f $What)
}

# Write, read back, and only then let the operator listen: the log then proves the
# register held the written value while the audio was running.
function WriteAndStep([int]$addr, [uint32]$data, [string]$label, [string]$expect, [int]$ms) {
  [void](Cmd 0x02 $addr $data $label)
  $rb = Cmd 0x01 $addr 0 ($label + ' readback')
  Write-Host ("          readback 0x{0:X8} (wrote 0x{1:X8})" -f $rb, $data)
  if ($rb -ne $data) { throw ("{0}: wrote 0x{1:X8} but read 0x{2:X8}" -f $label, $data, $rb) }
  Step $label $expect $ms
}

function Step([string]$label, [string]$expect, [int]$ms) {
  Write-Host ("{0:HH:mm:ss} {1}" -f (Get-Date), $label)
  Write-Host ("          expect: {0}" -f $expect)
  Start-Sleep -Milliseconds $ms
}

try {
  if (-not $SkipUpload) {
    Write-Host ("uploading {0}" -f $Bin)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_wt_upload.ps1 `
             -Port $Port -Bin $Bin -Table 0 -Version 1 -PostSelect 0x00000020 2>&1
    if (-not (($out -join "`n") -match 'RESULT: PASS')) { throw 'the upload did not pass' }
    Write-Host 'upload PASS (table 0, WT_SELECT shift 2)'
  }
  $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
  $sp.ReadTimeout = 400; $sp.WriteTimeout = 400
  $sp.Open(); Start-Sleep -Milliseconds 60
  $id = Cmd 0x01 0xB0 0 'read 0xB0'
  if ($id -ne 0x5A5A0003) { throw ("0xB0=0x{0:X8}, the board is not running the P2a bitstream" -f $id) }
  Write-Host 'bitstream id ok (0x5A5A0003)'

  # WT_PLAY test note: THRESHOLDS[7:0] = note (0 would keep the 46.875 Hz walk).
  # PowerShell parses 0xFFFF0000 as a negative Int32, so build the word in decimal.
  $thr = [uint32](4294901760 + ($Note -band 0xFF))
  [void](Cmd 0x02 0x30 $thr 'write THRESHOLDS')
  [void](Cmd 0x02 0x04 6 'MODE=WT_PLAY')
  $mild   = [uint32](0x01000000 -bor 288)   # enable, ci=288 (~2.5 kHz one-pole)
  $strong = [uint32](0x01000000 -bor 144)   # enable, ci=144 (~320 Hz one-pole)
  $lfo    = [uint32](0x01800500)            # enable, 1280 mHz, depth 128
  $loud   = [uint32](131072)                # master volume 2.0

  Write-Host ''
  Write-Host '==== listening test: nothing to touch ===='
  Step '1/5 WT_PLAY, everything bypassed' 'a steady tone, no filtering, normal volume' $HoldMs
  WriteAndStep 0x40 $mild   '2/5 0x40 = 0x01000120 (enable, ci=288)' 'slightly duller' $HoldMs
  WriteAndStep 0x40 $strong '3/5 0x40 = 0x01000090 (enable, ci=144)' 'clearly darker and quieter' $HoldMs
  WriteAndStep 0x44 $lfo    '4/5 0x44 = 0x01800500 (LFO on, 1.28 Hz, depth 128)' 'the level sweeps up and down about once per second' ($HoldMs * 2)
  [void](Cmd 0x02 0x44 0 'LFO off')
  [void](Cmd 0x02 0x40 0 'filter bypass')
  Start-Sleep -Seconds 2
  WriteAndStep 0x90 $loud   '5/5 0x90 = 0x00020000 (master volume 2.0)' 'back to the raw tone, then twice as loud' $HoldMs
  [void](Cmd 0x02 0x90 65536 'volume back to 1.0')
  [void](Cmd 0x02 0x14 1 'STOP')
  Write-Host ''
  Write-Host 'STOP sent; the tone must be silent now.'
} finally {
  if ($sp -and $sp.IsOpen) { $sp.Close(); $sp.Dispose() }
}
