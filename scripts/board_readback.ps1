# 1024-point readback: upload the pattern, APPLY it, then read every sample back
# through WT_DATA and compare.  This is the hard acceptance test: a CRC match can
# hide a permutation, a point-by-point comparison cannot.
param([string]$Port = 'COM4', [int]$Baud = 1000000, [string]$LogPath = 'artifacts/board/readback.log',
      [string]$CsvPath = 'artifacts/board/readback.csv')

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path $CsvPath) | Out-Null
function Log([string]$t) { $l = "{0:HH:mm:ss.fff} {1}" -f (Get-Date), $t; Write-Output $l; Add-Content -Path $LogPath -Value $l -Encoding utf8 }
function Hex32([string]$h) { return [uint32]::Parse($h, [System.Globalization.NumberStyles]::HexNumber) }
function Get-Crc16([byte[]]$b) { $crc = 0xFFFF; foreach ($x in $b) { $crc = $crc -bxor ([int]$x -shl 8); for ($i = 0; $i -lt 8; $i++) { if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF } else { $crc = ($crc -shl 1) -band 0xFFFF } } }; return $crc }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 400; $sp.WriteTimeout = 400
try { $sp.Open() } catch { Log ("FATAL: cannot open {0}: {1}" -f $Port, $_.Exception.Message); exit 2 }
Start-Sleep -Milliseconds 30; $sp.DiscardInBuffer()
$script:seq = 0; $script:badAcks = 0

function X {
    param([int]$Op, [int]$Addr, [uint32]$Data)
    $script:seq = ($script:seq + 1) -band 0xFF
    $f = New-Object byte[] 11
    $f[0] = 0xA5; $f[1] = 0x02; $f[2] = [byte]$Op; $f[3] = [byte]$Addr; $f[4] = [byte]$script:seq
    $f[5] = [byte](($Data -shr 24) -band 0xFF); $f[6] = [byte](($Data -shr 16) -band 0xFF)
    $f[7] = [byte](($Data -shr 8) -band 0xFF); $f[8] = [byte]($Data -band 0xFF)
    $c = Get-Crc16 $f[0..8]; $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
    $sp.DiscardInBuffer(); $sp.Write($f, 0, 11)
    $buf = New-Object 'System.Collections.Generic.List[byte]'
    $dl = (Get-Date).AddMilliseconds(400)
    while ((Get-Date) -lt $dl -and $buf.Count -lt 22) { try { $buf.Add([byte]$sp.ReadByte()) } catch { break } }
    if ($buf.Count -ne 22) { $script:badAcks++; return [pscustomobject]@{ Ok = $false; Err = 255; Val = [uint32]::MaxValue } }
    $rx = $buf.ToArray()
    $e = Get-Crc16 $rx[0..19]
    $ok = ($rx[0] -eq 0x5A) -and ($rx[1] -eq 0x02) -and ($rx[4] -eq $script:seq) -and ($rx[20] -eq (($e -shr 8) -band 0xFF)) -and ($rx[21] -eq ($e -band 0xFF))
    if (-not $ok) { $script:badAcks++ }
    return [pscustomobject]@{ Ok = $ok; Err = [int]$rx[19]
        Val = [uint32]((([uint64]$rx[14]) -shl 24) -bor (([uint64]$rx[15]) -shl 16) -bor (([uint64]$rx[16]) -shl 8) -bor [uint64]$rx[17]) }
}

$pattern = New-Object 'int[]' 1024
$payload = New-Object 'System.Collections.Generic.List[byte]'
for ($i = 0; $i -lt 1024; $i++) {
    $u = ($i * 37 + 1234) -band 0xFFFF
    $pattern[$i] = $u
    $payload.Add([byte](($u -shr 8) -band 0xFF)); $payload.Add([byte]($u -band 0xFF))
}
$wtCrc = Get-Crc16 $payload.ToArray()
$const = X 0x01 0x80 0
Log ("const=0x{0:X8} (expect 0x5A5A0003); vector crc=0x{1:X4}" -f $const.Val, $wtCrc)
if ($const.Val -ne (Hex32 '5A5A0003')) { Log 'FATAL: constant CSR mismatch, wrong bitstream or read path'; $sp.Close(); exit 1 }

Log 'uploading 1024 samples'
[void](X 0x02 0x60 0)
for ($b = 0; $b -lt 32; $b++) {
    [void](X 0x02 0x64 ([uint32]($b * 32)))
    for ($k = 0; $k -lt 32; $k++) { [void](X 0x02 0x68 ([uint32]$pattern[$b * 32 + $k])) }
}
[void](X 0x02 0x6C ([uint32]1024))
[void](X 0x02 0x70 ([uint32]$wtCrc))
$st = X 0x01 0x7C 0
$ver = [uint32]($st.Val -band 0xFFFF)
Log ("after upload: WT_STATUS=0x{0:X8} shadow_valid={1} version={2}" -f $st.Val, (($st.Val -shr 16) -band 1), $ver)

Log ("APPLY with version {0}" -f $ver)
[void](X 0x02 0x74 $ver)
$ap = X 0x02 0x78 ([uint32]([uint64](Hex32 '80000000') -bor [uint64]$ver))
Start-Sleep -Milliseconds 100
$st2 = X 0x01 0x7C 0
$ver2 = [uint32]($st2.Val -band 0xFFFF)
Log ("after apply: err={0} WT_STATUS=0x{1:X8} version={2} crc_error={3}" -f $ap.Err, $st2.Val, $ver2, (($st2.Val -shr 24) -band 0xFF))
if ($ver2 -ne ($ver + 1)) { Log ("FATAL: version did not advance ({0} -> {1})" -f $ver, $ver2); $sp.Close(); exit 1 }

Log 'reading back 1024 samples'
$mismatch = 0
$csv = New-Object System.Collections.Generic.List[string]
$csv.Add('index,expected,actual,match')
for ($i = 0; $i -lt 1024; $i++) {
    $w = X 0x02 0x64 ([uint32]$i)
    $r = X 0x01 0x68 0
    $actual = [int]($r.Val -band 0xFFFF)
    $match = ($actual -eq $pattern[$i])
    if (-not $match) {
        $mismatch++
        if ($mismatch -le 10) { Log ("  MISMATCH idx={0} expected=0x{1:X4} actual=0x{2:X4}" -f $i, $pattern[$i], $actual) }
    }
    $csv.Add(('{0},0x{1:X4},0x{2:X4},{3}' -f $i, $pattern[$i], $actual, $match))
}
$csv | Set-Content -Path $CsvPath -Encoding utf8

$pass = ($mismatch -eq 0) -and ($script:badAcks -eq 0)
Log ("readback: {0}/1024 match, mismatches={1}, badAcks={2}" -f (1024 - $mismatch), $mismatch, $script:badAcks)
Log ("RESULT: {0}" -f $(if ($pass) { 'PASS' } else { 'FAIL' }))
$sp.Close(); $sp.Dispose()
if (-not $pass) { exit 1 }
