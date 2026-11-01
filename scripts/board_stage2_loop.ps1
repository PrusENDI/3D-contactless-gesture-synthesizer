# Stage-2 loop acceptance: arm the contour, record 32 ticks, commit, play.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_stage2_loop.ps1 -Port COM4
#
# Protocol (see docs/superpowers/specs/2026-11-01-stage2-loop-potts-design.md):
#   0x0C = 0   select the lead track (0x18 prepares whichever track is selected)
#   0x18 = 1   PREPARE_RECORD + arm: the capture waits for the next tick 0
#   poll 0x38  bit4 = contour full
#   0x3C = lam optional, default 21600
#   0x28 = 1   COMMIT: DP -> shadow lead track -> COMMIT_REQUEST
#   poll 0x38  bit0 = done, bit2 = overflow, bit3 = commit timeout
#   0x04 = 4   MODE=PLAY; the swap happens at the first loop boundary
param(
  [string]$Port = 'COM4',
  [int]$Baud = 1000000,
  [int]$Lambda = 21600,
  [int]$WaitSeconds = 30,
  [string]$LogPath = 'artifacts/board/stage2_loop.log',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
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

New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Log ("stage-2 loop on {0} at {1} baud, lambda={2}" -f $Port, $Baud, $Lambda)
if ($DryRun) { Log 'DRY RUN: no serial port opened'; exit 0 }

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
    $sp.Close(); $sp.Dispose(); exit 3
  }
  Log 'bitstream id ok (0x5A5A0003)'

  # A previous failed take can leave the store waiting for a boundary (and the
  # DP stuck in EMIT).  STOP aborts the record plane and the store command, and
  # RESET clears the diagnostics, so every run starts from a known state.
  $pre = X 0x01 0x38 0
  $preStatus = X 0x01 0x00 0
  Log ("before: 0x38=0x{0:X8} STATUS=0x{1:X8}" -f $pre.Val, $preStatus.Val)
  if (-not $pre.Ok -or -not $preStatus.Ok) { Log 'FATAL: the board did not answer the status reads'; exit 13 }
  Log 'resetting the loop plane (STOP then RESET)'
  $stopAck = X 0x02 0x14 1; if (-not $stopAck.Ok) { Log ("FATAL: STOP refused err={0}" -f $stopAck.Err); exit 15 }
  Start-Sleep -Milliseconds 150
  $resetAck = X 0x02 0x2C 1; if (-not $resetAck.Ok) { Log ("FATAL: RESET refused err={0}" -f $resetAck.Err); exit 16 }
  Start-Sleep -Milliseconds 150
  $after = X 0x01 0x38 0
  Log ("after reset 0x38=0x{0:X8}" -f $after.Val)
  if (($after.Val -band 0x02) -ne 0) { Log 'FATAL: the DP is still busy after STOP/RESET'; exit 14 }

  Log 'selecting the lead track and arming the contour'
  [void](X 0x02 0x0C 0)
  $prep = X 0x02 0x18 1
  if (-not $prep.Ok) { Log ("FATAL: PREPARE_RECORD refused err={0}" -f $prep.Err); exit 4 }
  [void](X 0x02 0x3C ([uint32]$Lambda))

  Log 'waiting for 32 ticks of contour (keep the hand in the field)'
  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  $status = 0
  while ((Get-Date) -lt $deadline) {
    $st = X 0x01 0x38 0
    if ($st.Ok) {
      $status = $st.Val
      if (($status -band 0x10) -ne 0) { break }
    }
    Start-Sleep -Milliseconds 100
  }
  if (($status -band 0x10) -eq 0) { Log ("FATAL: contour never filled (0x38=0x{0:X8})" -f $status); exit 5 }
  Log 'contour full'

  Log 'COMMIT'
  $commit = X 0x02 0x28 1
  if (-not $commit.Ok) { Log ("FATAL: COMMIT refused err={0}" -f $commit.Err); exit 6 }
  # Page 1 of the probe shows why the write port would refuse an event:
  # bit0 full, 1 purify, 2 run, 3 done, 4 dp busy, 5 store busy, 6 commit pending,
  # 7 write_ready, 8 write_valid, 9 ctrl pending, [14:10] write slot,
  # [20:15] shadow record count, [26:21] committed event count.
  [void](X 0x02 0x34 1)
  $deadline = (Get-Date).AddSeconds(10)
  $status = 0
  $lastW = 0
  do {
    $w = (X 0x01 0xF8 0).Val
    $lastW = $w
    $status = (X 0x01 0x38 0).Val
    Log ("page1=0x{0:X8} full={1} purify={2} run={3} done={4} dpbusy={5} storebusy={6} pend={7} wrready={8} wrvalid={9} ctrlpend={10} slot={11} rec={12} cnt={13} 0x38=0x{14:X8}" -f `
      $w, ($w -band 1), (($w -shr 1) -band 1), (($w -shr 2) -band 1), (($w -shr 3) -band 1), `
      (($w -shr 4) -band 1), (($w -shr 5) -band 1), (($w -shr 6) -band 1), (($w -shr 7) -band 1), `
      (($w -shr 8) -band 1), (($w -shr 9) -band 1), (($w -shr 10) -band 0x1F), `
      (($w -shr 15) -band 0x3F), (($w -shr 21) -band 0x3F), $status)
    if (($status -band 0x01) -ne 0) { break }
    Start-Sleep -Milliseconds 300
  } while ((Get-Date) -lt $deadline)
  if (($status -band 0x01) -eq 0) {
    Log ("FATAL: DP never finished (0x38=0x{0:X8}, page1=0x{1:X8})" -f $status, $lastW)
    exit 7
  }
  if (($status -band 0x04) -ne 0) { Log 'FATAL: DP overflowed the event buffer'; exit 8 }
  Log 'commit done'

  Log 'reading back the 32 contour samples'
  [void](X 0x02 0x34 0)
  $contour = New-Object 'System.Collections.Generic.List[uint32]'
  for ($i = 0; $i -lt 32; $i++) {
    $s = X 0x01 0x34 0
    if (-not $s.Ok) { Log ("FATAL: contour read {0} failed err={1}" -f $i, $s.Err); exit 9 }
    $contour.Add($s.Val -band 0xFFFF)
  }
  Log ("contour[0..7] = {0}" -f (($contour[0..7] | ForEach-Object { "{0,4}" -f $_ }) -join ''))
  $nonZero = 0
  foreach ($v in $contour) { if ($v -ne 0) { $nonZero++ } }
  if ($nonZero -eq 0) {
    Log 'FAIL: the contour is empty (no hand in the field during the capture); nothing was committed, so there will be no sound'
    exit 12
  }
  Log ("contour has {0}/32 non-zero samples" -f $nonZero)

  Log 'MODE=PLAY (the swap happens at the first loop boundary, up to 8 s at 60 BPM)'
  $play = X 0x02 0x04 4
  if (-not $play.Ok) { Log ("FATAL: MODE=PLAY refused err={0}" -f $play.Err); exit 10 }
  # Watch the voice engine while the loop plays: page 2 of 0xF8 carries the
  # steal counter and the active voice count, so a run that never steals and
  # keeps a handful of voices is healthy.
  [void](X 0x02 0x34 2)
  $maxVoices = 0
  for ($t = 0; $t -lt 20; $t++) {
    $dbg = (X 0x01 0xF8 0).Val
    $voices = ($dbg -shr 17) -band 0x3F
    if ($voices -gt $maxVoices) { $maxVoices = $voices }
    if (($t % 4) -eq 0) {
      Log ("play voices={0} steals={1} overflow={2} voice_busy={3}" -f `
        $voices, ($dbg -band 0xFFFF), (($dbg -shr 16) -band 1), (($dbg -shr 23) -band 3))
    }
    Start-Sleep -Milliseconds 500
  }
  $finalDbg = (X 0x01 0xF8 0).Val
  Log ("play summary: max_voices={0} steals={1}" -f $maxVoices, ($finalDbg -band 0xFFFF))
  if (($finalDbg -band 0xFFFF) -ne 0) {
    Log 'WARN: the voice engine had to steal; that is not expected for a loop this small'
  }

  $st = X 0x01 0x38 0
  if (($st.Val -band 0x08) -ne 0) {
    Log 'FATAL: the store dropped the commit (boundary timeout)'
    exit 11
  }
  Log ("final status 0x{0:X8}" -f $st.Val)

  # Stop the loop and prove it went silent.  The contract needs data=1 for STOP;
  # writing 0 is rejected, which is why earlier attempts kept playing.
  $stop = X 0x02 0x14 1
  if (-not $stop.Ok) { Log ("FATAL: STOP refused err={0}" -f $stop.Err); exit 17 }
  Start-Sleep -Milliseconds 400
  $after = (X 0x01 0xF8 0).Val
  $voicesAfter = ($after -shr 17) -band 0x3F
  Log ("after STOP: voices={0} steals={1}" -f $voicesAfter, ($after -band 0xFFFF))
  if ($voicesAfter -ne 0) {
    Log 'FAIL: a voice is still sounding after STOP'
    exit 18
  }
  Log 'STOPPED cleanly'
  Log 'STAGE2 LOOP RESULT: PASS (loop played, then stopped silently)'
} finally {
  $sp.Close()
  $sp.Dispose()
}
