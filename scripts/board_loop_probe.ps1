# Loop-plane probe: why does PLAY never produce a loop boundary?
#
#   0xF8 = {scheduler[7:0], voice[1:0]}
#     scheduler[7] scan_active, [6] waiting, [5] event_valid, [4:3] boundary_stage,
#     [2:1] pass, [0] slot[0]
#     voice[1] scan_busy, [0] victim_scan_active
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_loop_probe.ps1 -Port COM4
param(
  [string]$Port = 'COM4',
  [int]$Baud = 1000000,
  [int]$Seconds = 8,
  [string]$LogPath = 'artifacts/board/loop_probe.log'
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
  [void](X 0x02 0x14 0); Start-Sleep -Milliseconds 100
  [void](X 0x02 0x2C 0); Start-Sleep -Milliseconds 100
  Log ("0x38 after reset = 0x{0:X8}" -f (X 0x01 0x38 0).Val)

  [void](X 0x02 0x0C 0)
  [void](X 0x02 0x18 1)
  Start-Sleep -Seconds 5
  Log ("0x38 after 5 s of capture = 0x{0:X8}" -f (X 0x01 0x38 0).Val)

  $c = X 0x02 0x28 1
  Log ("COMMIT err={0}" -f $c.Err)
  # Page 1 is the commit/write-port/store word: bits [0] full, [1] purify_done,
  # [2] commit_run, [3] commit_done, [4] dp_busy, [5] store_busy,
  # [6] commit_pending, [7] write_ready, [8] write_valid, [9] ctrl_pending,
  # [14:10] write_slot, [20:15] record_count, [26:21] commit_count.
  [void](X 0x02 0x34 1)
  $deadline = (Get-Date).AddSeconds(4)
  do {
    $w = (X 0x01 0xF8 0).Val
    $st = (X 0x01 0x38 0).Val
    Log ("page1=0x{0:X8} full={1} purify={2} run={3} done={4} dpbusy={5} storebusy={6} pend={7} wrready={8} wrvalid={9} ctrlpend={10} slot={11} rec={12} cnt={13} 0x38=0x{14:X8}" -f `
      $w, ($w -band 1), (($w -shr 1) -band 1), (($w -shr 2) -band 1), (($w -shr 3) -band 1), `
      (($w -shr 4) -band 1), (($w -shr 5) -band 1), (($w -shr 6) -band 1), (($w -shr 7) -band 1), `
      (($w -shr 8) -band 1), (($w -shr 9) -band 1), (($w -shr 10) -band 0x1F), `
      (($w -shr 15) -band 0x3F), (($w -shr 21) -band 0x3F), $st)
    if (($st -band 1) -ne 0) { break }
    Start-Sleep -Milliseconds 100
  } while ((Get-Date) -lt $deadline)
  Log ("0x38 after commit = 0x{0:X8}" -f $st)

  $p = X 0x02 0x04 4
  Log ("MODE=PLAY err={0}" -f $p.Err)
  # Page 2: {voice busies, active count, overflow, steal count}.
  [void](X 0x02 0x34 2)
  $first_steal = -1
  $end = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $end) {
    $dbg = (X 0x01 0xF8 0).Val
    $status = (X 0x01 0x00 0).Val
    $st38 = (X 0x01 0x38 0).Val
    $steals = $dbg -band 0xFFFF
    if ($first_steal -lt 0) { $first_steal = $steals }
    Log ("page2=0x{0:X8} steals={1} overflow={2} voices={3} voice_busy={4} STATUS=0x{5:X8} 0x38=0x{6:X8}" -f `
      $dbg, $steals, (($dbg -shr 16) -band 1), (($dbg -shr 17) -band 0x3F), (($dbg -shr 23) -band 3), `
      $status, $st38)
    Start-Sleep -Milliseconds 250
  }
  Log ("steal count over the run: {0} -> {1}" -f $first_steal, ((X 0x01 0xF8 0).Val -band 0xFFFF))
} finally {
  $sp.Close()
  $sp.Dispose()
}
