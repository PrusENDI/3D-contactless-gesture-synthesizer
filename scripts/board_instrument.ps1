# Switch the board to one instrument: one table plus the nine preset words.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_instrument.ps1 -Instrument akwf-cello -Live
#
# Two things have to change together, which is why this is one command: the table
# (the timbre) and the nine preset words (the shaping around it). Applying only the
# words is what made the old presets sound alike - they were all the same table.
#
# The body frame (frame1.bin) is uploaded to the table the preset names, and the
# morph set stays in artifacts/wt/instruments/<name>/ for later.
param(
  [Parameter(Mandatory = $true)][string]$Instrument,
  [string]$Port = 'COM4',
  [int]$Baud = 1000000,
  [int]$Shift = -1,
  [switch]$Live,
  [switch]$SkipUpload
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$frame = Join-Path $repo ("artifacts/wt/instruments/{0}/frame1.bin" -f $Instrument)
$preset = Join-Path $repo ("host/presets/{0}.json" -f $Instrument)
if (-not (Test-Path $frame)) { Write-Host ("FATAL: {0} is missing; run python host/instrument_tables.py or host/akwf_tables.py" -f $frame); exit 1 }
if (-not (Test-Path $preset)) { Write-Host ("FATAL: {0} is missing" -f $preset); exit 1 }

# The preset file decides the table slot and the gain shift; -Shift overrides.
$doc = Get-Content $preset -Raw | ConvertFrom-Json
$table = 0
if ($null -ne $doc.wavetable -and $null -ne $doc.wavetable.table) { $table = [int]$doc.wavetable.table }
if ($Shift -lt 0) {
  $Shift = 2
  if ($null -ne $doc.wavetable -and $null -ne $doc.wavetable.voice_shift) {
    $Shift = [int]$doc.wavetable.voice_shift
  }
}

if (-not $SkipUpload) {
  $select = [int]([math]::Pow(2, 4) * $Shift)          # WT_SELECT[7:4] is the voice gain shift
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'board_wt_upload.ps1') `
           -Port $Port -Bin $frame -Table $table -Version 1 -PostSelect $select 2>&1
  if (-not (($out -join "`n") -match 'RESULT: PASS')) { Write-Host ($out -join "`n"); exit 2 }
  Write-Host ("table: {0} -> table {1}, voice shift {2}" -f $Instrument, $table, $Shift)
}

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

try {
  $sp.Open(); Start-Sleep -Milliseconds 60
  $id = Cmd 0x01 0xB0 0 'read 0xB0'
  if ($id -ne 0x5A5A0003) { throw ("0xB0=0x{0:X8}: wrong bitstream" -f $id) }

  # Apply ascending by address, write then read back, exactly like board_tune.ps1.
  foreach ($addr in @(0x40, 0x44, 0x84, 0x88, 0x8C, 0x90, 0x94, 0x98, 0x9C)) {
    $key = "0x{0:X2}" -f $addr
    $word = [uint32]$doc.words.$key
    [void](Cmd 0x02 $addr $word ('write ' + $key))
    $back = Cmd 0x01 $addr 0 ('read ' + $key)
    if ($back -ne $word) { throw ("{0}: wrote 0x{1:X8}, read 0x{2:X8}" -f $key, $word, $back) }
    Write-Host ("  {0} = 0x{1:X8}" -f $key, $word)
  }
  Write-Host ("preset '{0}' applied: {1}" -f $Instrument, $doc.notes)

  if ($Live) {
    [void](Cmd 0x02 0x14 1 'STOP')
    [void](Cmd 0x02 0x04 1 'MODE=LIVE')
    Write-Host 'MODE=LIVE: play it with your hand; the console can keep the port afterwards only if this closes it.'
  }
} finally {
  if ($sp -and $sp.IsOpen) { $sp.Close(); $sp.Dispose() }
}
