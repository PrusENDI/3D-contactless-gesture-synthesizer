# Stage-2 loop acceptance: record, commit and play one or more tracks.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_stage2_loop.ps1 -Port COM4
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_stage2_loop.ps1 -Port COM4 -Tracks 2
#
# Protocol (see docs/superpowers/specs/2026-11-01-stage2-loop-potts-design.md):
#   0x08 = 120 BPM so one 32-tick loop is 4 s
#   0x14 = 1   STOP: leaves PLAY and aborts a commit left behind by an old run
#   0x24 = 1   CLEAR_ALL: zero the shadow bank, then one PLAY loop publishes it
#   0x0C = n   select the track (the commit latches it at 0x28)
#   0x18 = 1   PREPARE_RECORD + arm: the capture waits for the next tick 0
#   poll 0x38  bit4 = contour full
#   0x3C = lam optional, default 21600
#   0x28 = 1   COMMIT: DP -> shadow track -> COMMIT_REQUEST
#   poll 0x38  bit0 = done, bit1 = busy, bit2 = overflow, bit3 = commit timeout
#   0x04 = 4   MODE=PLAY; the swap happens at the first loop boundary
#   poll page 1 of 0xF8 (page select = 0x34) bit6 = commit pending, which drops
#              when that boundary published the take
#
# The store publishes a whole bank at a loop boundary and PREPARE_RECORD copies
# the active bank into the shadow bank first, so the takes are published one at
# a time: commit, play until the boundary, then the next take.  Every publish
# keeps the tracks committed before it.
param(
  [string]$Port = 'COM4',
  [int]$Baud = 1000000,
  [int]$Lambda = 21600,
  [int]$WaitSeconds = 30,
  [int]$Tracks = 1,
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

if ($Tracks -lt 1 -or $Tracks -gt 6) { Write-Output "FATAL: -Tracks must be 1..6"; exit 1 }

New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Log ("stage-2 loop on {0} at {1} baud, lambda={2}, tracks={3}" -f $Port, $Baud, $Lambda, $Tracks)
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

# Wait for the loop plane to publish: probe page 1 bit6 is the store's
# commit_pending, which only clears when a boundary swaps the banks.
function Wait-Publish([int]$TimeoutSec) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    $w = (X 0x01 0xF8 0).Val
    if (((($w -shr 6) -band 1)) -eq 0) { return $true }
    Start-Sleep -Milliseconds 100
  }
  return $false
}

try {
  $id = X 0x01 0xB0 0
  if (-not $id.Ok -or $id.Val -ne 0x5A5A0003) {
    Log ("FATAL: 0xB0=0x{0:X8} err={1}; the board is not running the current bitstream" -f $id.Val, $id.Err)
    $sp.Close(); $sp.Dispose(); exit 3
  }
  Log 'bitstream id ok (0x5A5A0003)'

  # A previous failed take can leave the store waiting for a boundary (and the
  # DP stuck in EMIT).  Every run starts from an empty loop: STOP aborts the
  # commit, CLEAR_ALL empties the shadow bank, and one PLAY loop publishes that
  # empty bank.  RESET (0x2C) is accepted by the contract but does nothing in
  # the top, so it is not used here.
  $pre = X 0x01 0x38 0
  $preStatus = X 0x01 0x00 0
  Log ("before: 0x38=0x{0:X8} STATUS=0x{1:X8}" -f $pre.Val, $preStatus.Val)
  if (-not $pre.Ok -or -not $preStatus.Ok) { Log 'FATAL: the board did not answer the status reads'; exit 13 }
  Log 'clearing the loop plane (STOP, CLEAR_ALL, publish an empty bank)'
  $stopAck = X 0x02 0x14 1; if (-not $stopAck.Ok) { Log ("FATAL: STOP refused err={0}" -f $stopAck.Err); exit 15 }
  Start-Sleep -Milliseconds 150
  $bpmAck = X 0x02 0x08 120; if (-not $bpmAck.Ok) { Log ("FATAL: BPM refused err={0}" -f $bpmAck.Err); exit 15 }
  $clearAck = X 0x02 0x24 1; if (-not $clearAck.Ok) { Log ("FATAL: CLEAR_ALL refused err={0}" -f $clearAck.Err); exit 16 }
  [void](X 0x02 0x04 4)                              # MODE=PLAY: one loop publishes the empty bank
  $clearDeadline = (Get-Date).AddSeconds(15)
  $empty = $false
  while ((Get-Date) -lt $clearDeadline) {
    $st = X 0x01 0x00 0
    # STATUS bit8 = loop_active_valid (no track of the published bank holds an event)
    if ($st.Ok -and ((($st.Val -shr 8) -band 1) -eq 0)) { $empty = $true; break }
    Start-Sleep -Milliseconds 100
  }
  [void](X 0x02 0x14 1)                              # STOP
  if (-not $empty) { Log 'FATAL: the empty bank was never published (no loop boundary?)'; exit 14 }
  $after = X 0x01 0x38 0
  Log ("after clearing 0x38=0x{0:X8}" -f $after.Val)
  if (($after.Val -band 0x02) -ne 0) { Log 'FATAL: the DP is still busy after clearing'; exit 14 }

  $trackNotes = @{}
  for ($track = 0; $track -lt $Tracks; $track++) {
    Log ("track {0}/{1}: selecting and arming the contour" -f $track, ($Tracks - 1))
    $sel = X 0x02 0x0C ([uint32]$track)
    if (-not $sel.Ok) { Log ("FATAL: selecting track {0} refused err={1}" -f $track, $sel.Err); exit 4 }
    $prep = X 0x02 0x18 1
    if (-not $prep.Ok) { Log ("FATAL: PREPARE_RECORD refused err={0}" -f $prep.Err); exit 4 }
    [void](X 0x02 0x3C ([uint32]$Lambda))

    Log ("track {0}: waiting for 32 ticks of contour (keep the hand in the field)" -f $track)
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
    if (($status -band 0x10) -eq 0) {
      Log ("FATAL: track {0} contour never filled (0x38=0x{1:X8})" -f $track, $status)
      exit 5
    }
    Log ("track {0}: contour full" -f $track)

    Log ("track {0}: reading back the 32 contour samples" -f $track)
    [void](X 0x02 0x34 0)
    $contour = New-Object 'System.Collections.Generic.List[uint32]'
    for ($i = 0; $i -lt 32; $i++) {
      $s = X 0x01 0x34 0
      if (-not $s.Ok) { Log ("FATAL: track {0} contour read {1} failed err={2}" -f $track, $i, $s.Err); exit 9 }
      $contour.Add($s.Val -band 0xFFFF)
    }
    Log ("track {0}: contour[0..7] = {1}" -f $track,
         (($contour[0..7] | ForEach-Object { "{0,4}" -f $_ }) -join ''))
    $nonZero = 0
    foreach ($v in $contour) { if ($v -ne 0) { $nonZero++ } }
    Log ("track {0}: contour has {1}/32 non-zero samples" -f $track, $nonZero)
    if ($nonZero -eq 0) {
      Log ("FAIL: track {0} contour is empty; there would be nothing to commit" -f $track)
      exit 12
    }

    Log ("track {0}: COMMIT" -f $track)
    $commit = X 0x02 0x28 1
    if (-not $commit.Ok) { Log ("FATAL: COMMIT refused err={0}" -f $commit.Err); exit 6 }
    # Page 1 of the probe shows why the write port would refuse an event:
    # bit0 full, 1 purify, 2 run, 3 done, 4 dp busy, 5 store busy, 6 commit pending,
    # 7 write_ready, 8 write_valid, 9 ctrl pending, [14:10] write slot,
    # [20:15] shadow count of track 0, [26:21] committed event count.
    [void](X 0x02 0x34 1)
    $deadline = (Get-Date).AddSeconds(15)
    $status = 0
    $lastW = 0
    do {
      $w = (X 0x01 0xF8 0).Val
      $lastW = $w
      $status = (X 0x01 0x38 0).Val
      Log ("track {0}: page1=0x{1:X8} full={2} purify={3} run={4} done={5} dpbusy={6} storebusy={7} pend={8} wrready={9} wrvalid={10} ctrlpend={11} slot={12} rec={13} cnt={14} 0x38=0x{15:X8}" -f `
        $track, $w, ($w -band 1), (($w -shr 1) -band 1), (($w -shr 2) -band 1), (($w -shr 3) -band 1), `
        (($w -shr 4) -band 1), (($w -shr 5) -band 1), (($w -shr 6) -band 1), (($w -shr 7) -band 1), `
        (($w -shr 8) -band 1), (($w -shr 9) -band 1), (($w -shr 10) -band 0x1F), `
        (($w -shr 15) -band 0x3F), (($w -shr 21) -band 0x3F), $status)
      if (($status -band 0x01) -ne 0) { break }
      Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    if (($status -band 0x01) -eq 0) {
      Log ("FATAL: track {0} DP never finished (0x38=0x{1:X8}, page1=0x{2:X8})" -f $track, $status, $lastW)
      exit 7
    }
    if (($status -band 0x04) -ne 0) { Log ("FATAL: track {0} DP overflowed the event buffer" -f $track); exit 8 }
    $committed = ($lastW -shr 21) -band 0x3F
    if ($committed -eq 0) {
      Log ("FAIL: track {0} commit produced no notes (all rest); there would be no sound" -f $track)
      exit 12
    }
    $shadow0 = ($lastW -shr 15) -band 0x3F
    # The shadow count of track 0 is copied from the active bank by
    # PREPARE_RECORD, so on a later take it must still carry the earlier take.
    if ($track -ge 1 -and $shadow0 -ne [int]$trackNotes[0]) {
      Log ("FAIL: track 0 has {0} events in the shadow bank, expected the {1} from take 0" -f $shadow0, $trackNotes[0])
      exit 20
    }
    $trackNotes[$track] = $committed
    Log ("track {0}: commit done, {1} note(s), track 0 shadow count {2}" -f $track, $committed, $shadow0)

    Log ("track {0}: MODE=PLAY until the boundary publishes it" -f $track)
    $play = X 0x02 0x04 4
    if (-not $play.Ok) { Log ("FATAL: MODE=PLAY refused err={0}" -f $play.Err); exit 10 }
    $published = Wait-Publish 15
    $st = X 0x01 0x38 0
    if (($st.Val -band 0x08) -ne 0) {
      Log ("FATAL: track {0} commit timed out waiting for a boundary" -f $track)
      exit 11
    }
    if (-not $published) { Log ("FATAL: track {0} was never published (commit still pending)" -f $track); exit 19 }
    Log ("track {0}: published" -f $track)

    if ($track -lt ($Tracks - 1)) {
      # Leave PLAY before the next take: this releases the voices and keeps the
      # next PREPARE from running against a scheduler that is reading the store.
      $stopp = X 0x02 0x14 1
      if (-not $stopp.Ok) { Log ("FATAL: STOP between takes refused err={0}" -f $stopp.Err); exit 17 }
      Start-Sleep -Milliseconds 300
    }
  }

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
  $steals = $finalDbg -band 0xFFFF
  Log ("play summary: max_voices={0} steals={1}" -f $maxVoices, $steals)

  $st = X 0x01 0x38 0
  if (($st.Val -band 0x08) -ne 0) {
    Log 'FATAL: the store dropped a commit (boundary timeout)'
    exit 11
  }
  Log ("final status 0x{0:X8}" -f $st.Val)
  if ($Tracks -ge 2 -and $maxVoices -lt 2) {
    Log ("FAIL: only {0} voice(s) at once; the tracks never sounded together" -f $maxVoices)
    exit 21
  }
  if ($steals -ne 0) {
    if ($Tracks -ge 2) {
      Log ("FAIL: the voice engine stole {0} voices for {1} tracks" -f $steals, $Tracks)
      exit 22
    }
    Log 'WARN: the voice engine had to steal; that is not expected for a loop this small'
  }

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
  $summary = ($trackNotes.Keys | Sort-Object | ForEach-Object { "track {0}={1} note(s)" -f $_, $trackNotes[$_] }) -join ', '
  Log ("STAGE2 LOOP RESULT: PASS ({0}; max_voices={1}, steals={2}, silent after STOP)" -f $summary, $maxVoices, $steals)
} finally {
  $sp.Close()
  $sp.Dispose()
}
