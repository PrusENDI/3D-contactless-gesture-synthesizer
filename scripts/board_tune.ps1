# Voice presets for the P2a/P2b parameter set, applied as nine register writes.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_tune.ps1 -Preset warm
#   ... -Preset pluck    /  -Preset space    /  -Preset flat   (all defaults, for A/B)
#   ... -NoPlay          (apply only, do not start playback)
#   ... -Live            (start LIVE instead of PLAY, so a hand drives it)
#
# Why the defaults sound thin and clicky, and what each preset changes:
#   the filter ships bypassed (0x40 = 0), so a 32-harmonic table puts all of its
#   energy in, and the default envelope is attack 4096 / release 1024, i.e. 0.3 ms
#   up and 1.3 ms down - a click at every note.  A little low-pass, a longer attack
#   and a real release is what turns it into a voice.
#
# Register fields (docs/host-tools-and-gui-controls.md section 3.7):
#   0x40 FILTER [11:0] ci (fc = 40*2^(ci/48), 4-pole -3 dB ~ 0.43*fc)
#               [19:12] res (K = res*3.75/256, +0..28 dB)   [24] enable
#   0x44 LFO    [15:0] rate mHz  [23:16] depth ci  [24] enable  [25] retrig
#               [26] unipolar    [29:27] waveform (0 tri, 1 sine, 2 saw, 3 square, 4 S&H)
#   0x84 FX_A   [17:0] gain Q16  [19:18] level (0 dry, 1 +LP, 2 +delay, 3 +comb)  [20] enable
#   0x88 FX_B   [9:0] delay samples (actual = value + 1)   [31:16] one-pole coefficient Q16
#   0x8C FX_C   [15:0] feedback Q15   [31:16] comb mix Q15
#   0x90 VOLUME Q1.16, 0x10000 = 1.0, max 0x20000
#   0x94 [31:16] decay step, [15:0] attack step   (bigger step = faster)
#   0x98 [31:16] release step, [15:0] sustain level
#   0x9C [31:16] glide rate, [3:2] detune shift, [1:0] velocity shift
param(
  [string]$Port = 'COM4',
  [int]$Baud = 1000000,
  [ValidateSet('warm', 'pluck', 'space', 'flat')][string]$Preset = 'warm',
  [switch]$NoPlay,
  [switch]$Live
)

$ErrorActionPreference = 'Stop'

# Each preset is the nine words, in the order of the host's upload-on-connect list.
#   name           0x40 filter          0x44 lfo            0x84 fx_a      0x88 fx_b      0x8C fx_c      0x90 vol    0x94 env_ad   0x98 env_sr   0x9C voice
$presets = @{
  warm  = @{ f = 0x01048120; l = 0x030C015E; a = 0x00110000; b = 0x600001FF; c = 0x00003000; v = 0x00018000; e = 0x00400040; s = 0x00108CCD; m = 0x02000000 }
  pluck = @{ f = 0x01060138; l = 0x03080258; a = 0x00190000; b = 0x500000FF; c = 0x00002800; v = 0x00018000; e = 0x00200400; s = 0x00204CCD; m = 0x02000000 }
  space = @{ f = 0x01028114; l = 0x032004C8; a = 0x001C0000; b = 0x700003FF; c = 0x40002E66; v = 0x00014000; e = 0x00200020; s = 0x0008599A; m = 0x02000000 }
  flat  = @{ f = 0x00000000; l = 0x00000000; a = 0x00150000; b = 0xFFFF0000; c = 0x00000000; v = 0x00010000; e = 0x01001000; s = 0x0400C000; m = 0x02000000 }
}
$p = $presets[$Preset]

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

function Apply([int]$addr, [uint32]$data, [string]$name) {
  [void](Cmd 0x02 $addr $data ($name + ' write'))
  $rb = Cmd 0x01 $addr 0 ($name + ' readback')
  if ($rb -ne $data) { throw ("{0}: wrote 0x{1:X8}, read 0x{2:X8}" -f $name, $data, $rb) }
  Write-Host ("  {0,-10} = 0x{1:X8}  (readback ok)" -f $name, $data)
}

try {
  $sp.Open(); Start-Sleep -Milliseconds 60
  $id = Cmd 0x01 0xB0 0 'read 0xB0'
  if ($id -ne 0x5A5A0003) { throw ("0xB0=0x{0:X8}: wrong bitstream" -f $id) }

  Write-Host ''
  Write-Host ("applying preset '{0}'" -f $Preset)
  Apply 0x40 $p.f 'FILTER'
  Apply 0x44 $p.l 'LFO'
  Apply 0x84 $p.a 'FX_A'
  Apply 0x88 $p.b 'FX_B'
  Apply 0x8C $p.c 'FX_C'
  Apply 0x90 $p.v 'VOLUME'
  Apply 0x94 $p.e 'ENV_AD'
  Apply 0x98 $p.s 'ENV_SR'
  Apply 0x9C $p.m 'VOICE_MIX'

  if (-not $NoPlay) {
    if ($Live) {
      [void](Cmd 0x02 0x14 1 'STOP')
      [void](Cmd 0x02 0x04 1 'MODE=LIVE')
      Write-Host ''
      Write-Host 'LIVE: put your hand over the sensor - slow gestures give soft notes, fast ones loud.'
    } else {
      [void](Cmd 0x02 0x14 1 'STOP')
      [void](Cmd 0x02 0x04 4 'MODE=PLAY')
      Start-Sleep -Milliseconds 800
      $s = Cmd 0x01 0x00 0 'STATUS'
      Write-Host ''
      Write-Host ("PLAY: the four-track loop is running (mode={0}, loop_active={1})" -f ($s -band 7), (($s -shr 8) -band 1))
      Write-Host 'Say stop when you have heard enough, or run with -Preset flat / -NoPlay for an A/B.'
    }
  }
} finally {
  if ($sp -and $sp.IsOpen) { $sp.Close(); $sp.Dispose() }
}
