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
  $deadline = (Get-Date).AddSeconds(10)
  $status = 0
  while ((Get-Date) -lt $deadline) {
    $st = X 0x01 0x38 0
    if ($st.Ok) {
      $status = $st.Val
      if (($status -band 0x01) -ne 0) { break }
    }
    Start-Sleep -Milliseconds 20
  }
  if (($status -band 0x01) -eq 0) { Log ("FATAL: DP never finished (0x38=0x{0:X8})" -f $status); exit 7 }
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

  Log 'MODE=PLAY (the swap happens at the first loop boundary, up to 8 s at 60 BPM)'
  $play = X 0x02 0x04 4
  if (-not $play.Ok) { Log ("FATAL: MODE=PLAY refused err={0}" -f $play.Err); exit 10 }
  Start-Sleep -Seconds 10

  $st = X 0x01 0x38 0
  if (($st.Val -band 0x08) -ne 0) {
    Log 'FATAL: the store dropped the commit (boundary timeout)'
    exit 11
  }
  Log ("final status 0x{0:X8}" -f $st.Val)
  Log 'STAGE2 LOOP RESULT: PASS (listen for the loop; it should repeat every 32 ticks)'
} finally {
  $sp.Close()
  $sp.Dispose()
}
