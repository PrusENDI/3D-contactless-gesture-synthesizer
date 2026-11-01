# Stage-1.5 board acceptance: a committed loop plays through the uploaded table.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_wt_voice_play.ps1 -Port COM4
#
# Three phases, each run as a child process so only one of them owns the port:
#   1. host/wavetable_sine.py writes a 0.9 FS sine to artifacts/wt/voice_sine.bin
#   2. scripts/board_wt_upload.ps1 uploads it as table 0 and leaves WT_SELECT with
#      the voice shift (default 6), which is the PLAY-side scaling
#   3. scripts/board_stage2_loop.ps1 records one take, commits it, publishes it at
#      a loop boundary and plays it  (hand in the field for one take)
#
# Then this script re-opens the port and checks the stage-1.5 contract on the
# published loop: the loop keeps sounding (voices > 0) and WT_DATA reads 0 while
# PLAY owns the read port.  The timbre itself is the listening test: a sine table
# must sound like a sine, not like the internal saw.
#
# The host cannot send NOTE_ON events in PLAY (PLAY events come only from the loop
# scheduler), so the audible path has to be a committed loop.  A GAO spectrum
# comparison against LIVE is not part of this script; it needs its own probe build.
param(
  [string]$Port = 'COM4',
  [int]$Baud = 1000000,
  [string]$Bin = 'artifacts/wt/voice_sine.bin',
  [int]$Table = 0,
  [int]$Shift = 6,
  [int]$WaitSeconds = 40,
  [int]$ListenSeconds = 8,
  [switch]$SkipRecord,
  [string]$LogPath = 'artifacts/board/wt_voice_play.log'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
function Log([string]$t) {
  $l = "{0:HH:mm:ss.fff} {1}" -f (Get-Date), $t
  Write-Output $l
  Add-Content -Path $LogPath -Value $l -Encoding utf8
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

if ($Shift -lt 0 -or $Shift -gt 15) { Log "FATAL: -Shift must be 0..15"; exit 1 }
$select = ((($Shift -band 0xF) -shl 4) -bor ($Table -band 0x3))
$root = Split-Path -Parent $PSScriptRoot
Log ("stage-1.5 PLAY acceptance on {0}: table {1}, shift {2}, WT_SELECT=0x{3:X8}" -f `
     $Port, $Table, $Shift, $select)

# ---- 1. the frame ------------------------------------------------------------
if (-not (Test-Path $Bin)) {
  & python (Join-Path $root 'host/wavetable_sine.py') --out $Bin
  if ($LASTEXITCODE -ne 0) { Log "FATAL: could not generate $Bin"; exit 2 }
}
Log ("frame: {0}" -f $Bin)

# ---- 2. upload ---------------------------------------------------------------
Log 'uploading the table'
$uploadOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'board_wt_upload.ps1') `
  -Port $Port -Baud $Baud -Bin $Bin -Table $Table -Version 1 -PostSelect $select 2>&1
$uploadOut | ForEach-Object { Log ("  upload| {0}" -f $_) }
if (-not ($uploadOut -match 'RESULT: PASS')) { Log 'FATAL: the upload did not pass'; exit 3 }

# ---- 3. one take, committed and played ---------------------------------------
if (-not $SkipRecord) {
  Log 'recording one take (keep the hand in the field)'
  $loopOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'board_stage2_loop.ps1') `
    -Port $Port -Baud $Baud -Tracks 1 -WaitSeconds $WaitSeconds 2>&1
  $loopOut | ForEach-Object { Log ("  loop| {0}" -f $_) }
  if (-not ($loopOut -match 'STAGE2 LOOP RESULT: PASS')) {
    Log 'FATAL: the loop take did not pass; the PLAY check needs a published track'
    exit 4
  }
}

# ---- 4. PLAY the published loop and check the bypass contract ----------------
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 400
$sp.WriteTimeout = 400
try { $sp.Open() } catch { Log ("FATAL: cannot open {0}: {1}" -f $Port, $_.Exception.Message); exit 2 }
Start-Sleep -Milliseconds 30
$sp.DiscardInBuffer()
$seq = 0

function X {
  param([int]$Op, [int]$Addr, [uint32]$Data)
  $script:seq = ($script:seq + 1) -band 0xFF
  $f = New-Object byte[] 11
  $f[0] = 0xA5; $f[1] = 0x02; $f[2] = [byte]$Op; $f[3] = [byte]$Addr; $f[4] = [byte]$script:seq
  $f[5] = [byte](($Data -shr 24) -band 0xFF); $f[6] = [byte](($Data -shr 16) -band 0xFF)
  $f[7] = [byte](($Data -shr 8) -band 0xFF); $f[8] = [byte]($Data -band 0xFF)
  $c = Get-Crc16 $f[0..8]
  $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
  $sp.DiscardInBuffer()
  $sp.Write($f, 0, 11)
  $buf = New-Object 'System.Collections.Generic.List[byte]'
  $dl = (Get-Date).AddMilliseconds(400)
  while ((Get-Date) -lt $dl -and $buf.Count -lt 22) {
    try { $buf.Add([byte]$sp.ReadByte()) } catch { break }
  }
  if ($buf.Count -eq 22) {
    $rx = $buf.ToArray()
    $e = Get-Crc16 $rx[0..19]
    $ok = ($rx[0] -eq 0x5A) -and ($rx[4] -eq $script:seq) -and
          ($rx[20] -eq (($e -shr 8) -band 0xFF)) -and ($rx[21] -eq ($e -band 0xFF))
    return [pscustomobject]@{
      Ok = $ok
      Err = [int]$rx[19]
      Val = [uint32]((([uint64]$rx[14]) -shl 24) -bor (([uint64]$rx[15]) -shl 16) -bor
                     (([uint64]$rx[16]) -shl 8) -bor [uint64]$rx[17])
    }
  }
  return [pscustomobject]@{ Ok = $false; Err = 0xFF; Val = [uint32]::MaxValue }
}

try {
  $id = X 0x01 0xB0 0
  if (-not $id.Ok -or $id.Val -ne 0x5A5A0003) {
    Log ("FATAL: 0xB0=0x{0:X8} err={1}; the board is not running the current bitstream" -f $id.Val, $id.Err)
    exit 5
  }
  Log 'bitstream id ok (0x5A5A0003)'

  $play = X 0x02 0x04 4
  if (-not $play.Ok) { Log ("FATAL: MODE=PLAY refused err={0}" -f $play.Err); exit 6 }
  [void](X 0x02 0x34 2)                 # probe page 2: voice allocation
  $maxVoices = 0
  $deadline = (Get-Date).AddSeconds(6)
  while ((Get-Date) -lt $deadline) {
    $dbg = (X 0x01 0xF8 0).Val
    $voices = ($dbg -shr 17) -band 0x3F
    if ($voices -gt $maxVoices) { $maxVoices = $voices }
    Start-Sleep -Milliseconds 100
  }
  if ($maxVoices -lt 1) {
    Log 'FATAL: the published loop never sounded in PLAY; there is nothing to judge'
    exit 7
  }
  Log ("play voices={0} (the loop is audible now)" -f $maxVoices)

  # Stage-1.5 contract: the read port belongs to the table engine in PLAY.
  $wt = X 0x01 0x68 0
  if (-not $wt.Ok) { Log ("FATAL: WT_DATA read refused err={0}" -f $wt.Err); exit 8 }
  if ($wt.Val -ne 0) {
    Log ("FAIL: PLAY WT_DATA readback 0x{0:X8}; the host must not see table data while the engine owns the port" -f $wt.Val)
    exit 9
  }
  Log 'PLAY WT_DATA reads 0 (read port owned by the table engine)'

  Log ("listening for {0} s" -f $ListenSeconds)
  $listenUntil = (Get-Date).AddSeconds($ListenSeconds)
  while ((Get-Date) -lt $listenUntil) {
    $dbg = (X 0x01 0xF8 0).Val
    $voices = ($dbg -shr 17) -band 0x3F
    if ($voices -gt $maxVoices) { $maxVoices = $voices }
    Start-Sleep -Milliseconds 250
  }
  $steals = $finalDbg = 0
  $finalDbg = (X 0x01 0xF8 0).Val
  $steals = $finalDbg -band 0xFFFF
  Log ("play summary: max_voices={0} steals={1}" -f $maxVoices, $steals)

  $st = X 0x01 0x38 0
  if (($st.Val -band 0x08) -ne 0) { Log 'FATAL: the store dropped a commit (boundary timeout)'; exit 10 }

  $stop = X 0x02 0x14 1
  if (-not $stop.Ok) { Log ("FATAL: STOP refused err={0}" -f $stop.Err); exit 11 }
  Start-Sleep -Milliseconds 400
  $after = (X 0x01 0xF8 0).Val
  $voicesAfter = ($after -shr 17) -band 0x3F
  Log ("after STOP: voices={0}" -f $voicesAfter)
  if ($voicesAfter -ne 0) { Log 'FAIL: a voice is still sounding after STOP'; exit 12 }

  Log ("WT VOICE PLAY RESULT: PASS (table {0} uploaded, loop played it, voices peak {1}, WT_DATA 0 in PLAY, silent after STOP)" -f $Table, $maxVoices)
} finally {
  $sp.Close()
  $sp.Dispose()
}
