# Upload a 1024-sample wavetable (.bin, int16 little endian) to the board:
# WT_INDEX=0, then 1024 WT_DATA writes, then WT_CRC, WT_VERSION and APPLY.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_wt_upload.ps1 -Bin artifacts/wt/lead.bin
#   ... -DryRun          # no serial traffic; prints the CRC and the APPLY word
#
# The loader advances its index on every WT_DATA write, so one WT_INDEX write is
# enough. Every ACK is checked; a non-zero error stops the upload.
param(
  [string]$Port = 'COM4',
  [int]$Baud = 1000000,
  [Parameter(Mandatory = $true)][string]$Bin,
  [int]$Table = 0,
  [int]$Version = 1,
  [switch]$DryRun,
  [string]$LogPath = 'artifacts/board/wt_upload.log'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
function Log([string]$t) { $l = "{0:HH:mm:ss.fff} {1}" -f (Get-Date), $t; Write-Host $l; Add-Content -Path $LogPath -Value $l -Encoding utf8 }

function Get-Crc16([byte[]]$b) {
  $crc = 0xFFFF
  foreach ($x in $b) {
    $crc = $crc -bxor ([int]$x -shl 8)
    for ($i = 0; $i -lt 8; $i++) {
      if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF } else { $crc = ($crc -shl 1) -band 0xFFFF }
    }
  }
  return $crc
}

# Known vector first: a wrong CRC implementation must fail here, not on the board.
$selftest = Get-Crc16 ([System.Text.Encoding]::ASCII.GetBytes('123456789'))
if ($selftest -ne 0x29B1) { Log ("FATAL: CRC16 self-test = 0x{0:X4}, expected 0x29B1" -f $selftest); exit 1 }
Log 'CRC16 self-test 0x29B1 OK'

if (-not (Test-Path $Bin)) { Log "FATAL: $Bin not found"; exit 1 }
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $Bin).Path)
if ($bytes.Length -ne 2048) { Log ("FATAL: {0} is {1} bytes, expected 2048 (1024 x int16)" -f $Bin, $bytes.Length); exit 1 }

$samples = New-Object 'int[]' 1024
for ($i = 0; $i -lt 1024; $i++) {
  $v = [int][System.BitConverter]::ToInt16($bytes, $i * 2)
  $samples[$i] = $v -band 0xFFFF
}
# The loader feeds each 16-bit sample MSB first, so the CRC must be taken over
# big-endian pairs; hashing the little-endian file bytes gives a table it rejects.
$be = New-Object byte[] 2048
for ($i = 0; $i -lt 1024; $i++) { $be[2 * $i] = [byte](($samples[$i] -shr 8) -band 0xFF); $be[2 * $i + 1] = [byte]($samples[$i] -band 0xFF) }
$tableCrc = Get-Crc16 $be
# The top takes cmd_data[15:0] as the APPLY version and WT_SELECT[1:0] as the table,
# so the version belongs in the LOW half and the table in the HIGH half.
$applyWord = (($Table -band 0x3) -shl 16) -bor ($Version -band 0xFFFF)
Log ("table crc=0x{0:X4} table={1} version={2} apply=0x{3:X8}" -f $tableCrc, $Table, $Version, $applyWord)

if ($DryRun) {
  Log ("DRY RUN: 1 x WT_INDEX + 1024 x WT_DATA + WT_CRC + WT_VERSION + WT_APPLY = 1028 commands")
  Log ("DRY RUN: first sample=0x{0:X4} last sample=0x{1:X4}" -f $samples[0], $samples[1023])
  exit 0
}

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 400; $sp.WriteTimeout = 400
try { $sp.Open() } catch { Log ("FATAL: cannot open {0}: {1}" -f $Port, $_.Exception.Message); exit 2 }
Start-Sleep -Milliseconds 50; $sp.DiscardInBuffer()
$script:seq = 0
function X([int]$Op, [int]$Addr, [uint32]$Data) {
  $script:seq = ($script:seq + 1) -band 0xFF
  $f = New-Object byte[] 11
  $f[0] = 0xA5; $f[1] = 0x02; $f[2] = [byte]$Op; $f[3] = [byte]$Addr; $f[4] = [byte]$script:seq
  $f[5] = [byte](($Data -shr 24) -band 0xFF); $f[6] = [byte](($Data -shr 16) -band 0xFF)
  $f[7] = [byte](($Data -shr 8) -band 0xFF);  $f[8] = [byte]($Data -band 0xFF)
  $c = Get-Crc16 $f[0..8]; $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
  $sp.Write($f, 0, 11)
  $buf = New-Object 'System.Collections.Generic.List[byte]'
  $dl = (Get-Date).AddMilliseconds(400)
  while ((Get-Date) -lt $dl -and $buf.Count -lt 22) { try { $buf.Add([byte]$sp.ReadByte()) } catch { break } }
  if ($buf.Count -ne 22) { Log ("NO REPLY op={0} addr=0x{1:X2} seq={2}" -f $Op, $Addr, $script:seq); return 255 }
  $r = $buf.ToArray()
  # The reply echoes the command sequence; without this check a late reply to the
  # previous command is silently credited to this one.
  if ($r[4] -ne $script:seq) { Log ("SEQ MISMATCH sent={0} got={1} op={2} addr=0x{3:X2}" -f $script:seq, $r[4], $Op, $Addr); return 254 }
  return [int]$r[19]
}

# Uploading while a table is playing gets NACKed: the loader owns the read port
# and cmd_ready stays low. Force IDLE first; the host re-enters WT_PLAY after.
$null = X 0x02 0x04 0
Start-Sleep -Milliseconds 150
$null = X 0x02 0x60 $Table          # WT_SELECT: table number
$null = X 0x02 0x64 0               # WT_INDEX = 0
for ($i = 0; $i -lt 1024; $i++) {
  # Re-load the pointer every 32 samples, exactly like board_apply_once.ps1.
  if (($i % 32) -eq 0) { $null = X 0x02 0x64 ([uint32]$i) }
  $e = X 0x02 0x68 ([uint32]$samples[$i])
  if ($e -ne 0) { Log ("FATAL: WT_DATA[{0}] ack err={1}" -f $i, $e); $sp.Close(); exit 3 }
}
$null = X 0x02 0x6C 1024               # WT_LENGTH (the working script writes it)
$e = X 0x02 0x70 ([uint32]$tableCrc)   # WT_CRC
# board_apply_once reads WT_STATUS here; without it the loader stays not-ready.
function Read-Val([int]$addr) {
  $script:seq = ($script:seq + 1) -band 0xFF
  $f = New-Object byte[] 11
  $f[0] = 0xA5; $f[1] = 0x02; $f[2] = 0x01; $f[3] = [byte]$addr; $f[4] = [byte]$script:seq
  $c = Get-Crc16 $f[0..8]; $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
  $sp.Write($f, 0, 11)
  $buf = New-Object 'System.Collections.Generic.List[byte]'
  $dl = (Get-Date).AddMilliseconds(400)
  while ((Get-Date) -lt $dl -and $buf.Count -lt 22) { try { $buf.Add([byte]$sp.ReadByte()) } catch { break } }
  if ($buf.Count -ne 22) { return 0 }
  $r = $buf.ToArray()
  return [uint32]((([uint64]$r[14]) -shl 24) -bor (([uint64]$r[15]) -shl 16) -bor (([uint64]$r[16]) -shl 8) -bor [uint64]$r[17])
}
# The loader requires APPLY version == WT_VERSION == active version, so take the
# active version from WT_STATUS instead of inventing a new one.
$Version = (Read-Val 0x7C) -band 0xFFFF
Log ("active version from WT_STATUS: {0}" -f $Version)
if ($e -ne 0) { Log "FATAL: WT_CRC rejected err=$e"; $sp.Close(); exit 4 }
$null = X 0x02 0x74 ([uint32]($Version -band 0xFFFF))
# The loader answers err=7 when APPLY arrives before it is ready, so leave a gap
# and retry; a real rejection (CRC/version) comes back the same way on every try.
Start-Sleep -Milliseconds 10
$e = 255
for ($try = 0; $try -lt 4; $try++) {
  # The APPLY word is 0x80000000 | version: bit 31 is the commit flag, the table
# comes from WT_SELECT. board_apply_once.ps1 uses exactly this form.
$commitBit = [uint32]::Parse('80000000', [System.Globalization.NumberStyles]::HexNumber)
$e = X 0x02 0x78 ($commitBit -bor [uint32]($Version -band 0xFFFF))
  if ($e -eq 0) { break }
  Start-Sleep -Milliseconds 10
}
$status = X 0x01 0x7C 0
$sp.Close(); $sp.Dispose()
Log ("APPLY err={0} WT_STATUS=0x{1:X8}" -f $e, $status)
if ($e -ne 0) { Log 'RESULT: FAIL'; exit 5 }
Log 'RESULT: PASS'
