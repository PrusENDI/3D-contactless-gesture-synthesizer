# One-shot APPLY trigger for a GAO capture: upload the 1024-sample table, then send
# APPLY so wt_apply_valid_q rises and the analyzer's trigger fires.
param([string]$Port = 'COM4', [int]$Baud = 1000000, [string]$LogPath = 'artifacts/board/apply_once.log')

$ErrorActionPreference = 'Stop'
function Log([string]$t) { $l = "{0:HH:mm:ss.fff} {1}" -f (Get-Date), $t; Write-Output $l; Add-Content -Path $LogPath -Value $l -Encoding utf8 }
function Hex32([string]$h) { return [uint32]::Parse($h, [System.Globalization.NumberStyles]::HexNumber) }
function Get-Crc16([byte[]]$b) { $crc = 0xFFFF; foreach ($x in $b) { $crc = $crc -bxor ([int]$x -shl 8); for ($i = 0; $i -lt 8; $i++) { if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF } else { $crc = ($crc -shl 1) -band 0xFFFF } } }; return $crc }

New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 400; $sp.WriteTimeout = 400
try { $sp.Open() } catch { Log ("FATAL: cannot open {0}: {1}" -f $Port, $_.Exception.Message); exit 2 }
Start-Sleep -Milliseconds 30; $sp.DiscardInBuffer()
$seq = 0
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
    if ($buf.Count -eq 22) {
        $rx = $buf.ToArray()
        $e = Get-Crc16 $rx[0..19]
        $ok = ($rx[0] -eq 0x5A) -and ($rx[4] -eq $script:seq) -and ($rx[20] -eq (($e -shr 8) -band 0xFF)) -and ($rx[21] -eq ($e -band 0xFF))
        return [pscustomobject]@{ Ok = $ok; Err = [int]$rx[19]; Val = [uint32]((([uint64]$rx[14]) -shl 24) -bor (([uint64]$rx[15]) -shl 16) -bor (([uint64]$rx[16]) -shl 8) -bor [uint64]$rx[17]) }
    }
    return [pscustomobject]@{ Ok = $false; Err = 0xFF; Val = [uint32]::MaxValue }
}

$pattern = New-Object 'int[]' 1024
$payload = New-Object 'System.Collections.Generic.List[byte]'
for ($i = 0; $i -lt 1024; $i++) {
    $u = ($i * 37 + 1234) -band 0xFFFF
    $pattern[$i] = if ($u -ge 32768) { $u - 65536 } else { $u }
    $payload.Add([byte](($u -shr 8) -band 0xFF)); $payload.Add([byte]($u -band 0xFF))
}
$wtCrc = Get-Crc16 $payload.ToArray()
Log ("vector crc = 0x{0:X4}; const read = 0x{1:X8}" -f $wtCrc, (X 0x01 0x80 0).Val)

Log 'uploading 1024 samples...'
[void](X 0x02 0x60 0)
for ($b = 0; $b -lt 32; $b++) {
    [void](X 0x02 0x64 ([uint32]($b * 32)))
    for ($k = 0; $k -lt 32; $k++) { [void](X 0x02 0x68 ([uint32](($pattern[$b * 32 + $k]) -band 0xFFFF))) }
}
[void](X 0x02 0x6C ([uint32]1024))
[void](X 0x02 0x70 ([uint32]$wtCrc))
$st = X 0x01 0x7C 0
$ver = $st.Val -band 0xFFFF
Log ("WT_STATUS=0x{0:X8} shadow_valid={1} version={2}" -f $st.Val, (($st.Val -shr 16) -band 1), $ver)

Log ("writing WT_VERSION={0} then APPLY" -f $ver)
[void](X 0x02 0x74 ([uint32]$ver))
$applyWord = [uint32]([uint64](Hex32 '80000000') -bor [uint64]$ver)
$ap = X 0x02 0x78 $applyWord
Start-Sleep -Milliseconds 120
$st2 = X 0x01 0x7C 0
Log ("APPLY ack err={0}; WT_STATUS=0x{1:X8} version={2} crc_error={3}" -f $ap.Err, $st2.Val, ($st2.Val -band 0xFFFF), (($st2.Val -shr 24) -band 0xFF))
$sp.Close(); $sp.Dispose()
