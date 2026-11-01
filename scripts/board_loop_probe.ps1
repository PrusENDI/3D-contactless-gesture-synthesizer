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
  $deadline = (Get-Date).AddSeconds(3)
  do {
    $st = (X 0x01 0x38 0).Val
    if (($st -band 0x01) -ne 0) { break }
    Start-Sleep -Milliseconds 50
  } while ((Get-Date) -lt $deadline)
  Log ("0x38 after commit = 0x{0:X8}" -f $st)

  $p = X 0x02 0x04 4
  Log ("MODE=PLAY err={0}" -f $p.Err)
  $end = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $end) {
    $dbg = (X 0x01 0xF8 0).Val
    $status = (X 0x01 0x00 0).Val
    $st38 = (X 0x01 0x38 0).Val
    $sched = ($dbg -shr 2) -band 0xFF
    $voice = $dbg -band 0x3
    Log ("0xF8=0x{0:X4} sched=0x{1:X2} (scan={2} wait={3} ev={4} bstage={5} pass={6} slot0={7}) voice(scan={8} victim={9}) STATUS=0x{10:X8} 0x38=0x{11:X8}" -f `
      $dbg, $sched, (($sched -shr 7) -band 1), (($sched -shr 6) -band 1), (($sched -shr 5) -band 1), `
      (($sched -shr 3) -band 3), (($sched -shr 1) -band 3), ($sched -band 1), `
      (($voice -shr 1) -band 1), ($voice -band 1), $status, $st38)
    Start-Sleep -Milliseconds 250
  }
} finally {
  $sp.Close()
  $sp.Dispose()
}
