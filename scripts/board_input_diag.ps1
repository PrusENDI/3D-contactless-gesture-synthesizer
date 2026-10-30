# Input-path liveness probe: read the three counters, wait, read them again.
# A report counter that moves proves the sensor is talking; a cursor counter that
# stays at zero while reports arrive points at the validity/cursor stage instead.
param([string]$Port = 'COM4', [int]$Baud = 1000000, [int]$Seconds = 6,
      [string]$LogPath = 'artifacts/board/input_diag.log')

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
function Log([string]$t) { $l = "{0:HH:mm:ss.fff} {1}" -f (Get-Date), $t; Write-Output $l; Add-Content -Path $LogPath -Value $l -Encoding utf8 }
function Get-Crc16([byte[]]$b) { $crc = 0xFFFF; foreach ($x in $b) { $crc = $crc -bxor ([int]$x -shl 8); for ($i = 0; $i -lt 8; $i++) { if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF } else { $crc = ($crc -shl 1) -band 0xFFFF } } }; return $crc }

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200; $sp.WriteTimeout = 400
$sp.Open(); Start-Sleep -Milliseconds 50; $sp.DiscardInBuffer()
$seq = 0
function Read-Csr([int]$Addr) {
    $script:seq = ($script:seq + 1) -band 0xFF
    $f = New-Object byte[] 11
    $f[0] = 0xA5; $f[1] = 0x02; $f[2] = 0x01; $f[3] = [byte]$Addr; $f[4] = [byte]$script:seq
    $c = Get-Crc16 $f[0..8]; $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
    $sp.Write($f, 0, 11)
    $buf = New-Object 'System.Collections.Generic.List[byte]'
    $dl = (Get-Date).AddMilliseconds(300)
    while ((Get-Date) -lt $dl -and $buf.Count -lt 22) { try { $buf.Add([byte]$sp.ReadByte()) } catch { break } }
    if ($buf.Count -eq 22) { $r = $buf.ToArray(); return [uint32]((([uint64]$r[14]) -shl 24) -bor (([uint64]$r[15]) -shl 16) -bor (([uint64]$r[16]) -shl 8) -bor [uint64]$r[17]) }
    return [uint32]::MaxValue
}

$const = Read-Csr 0xB0
Log ("const=0x{0:X8} (expect 0x5A5A0003)" -f $const)
if ($const -ne 0x5A5A0003) { Log 'FATAL: wrong bitstream'; $sp.Close(); exit 1 }

$a0 = Read-Csr 0xD0; $e0 = Read-Csr 0xD4; $c0 = Read-Csr 0xD8
Log ("t0: reports={0} errors={1} cursor_valid={2}" -f $a0, $e0, $c0)
Log ("watching {0}s - touch or hover over the sensor now" -f $Seconds)
Start-Sleep -Seconds $Seconds
$a1 = Read-Csr 0xD0; $e1 = Read-Csr 0xD4; $c1 = Read-Csr 0xD8
Log ("t1: reports={0} errors={1} cursor_valid={2}" -f $a1, $e1, $c1)
$sp.Close(); $sp.Dispose()

$dr = $a1 - $a0; $de = $e1 - $e0; $dc = $c1 - $c0
Log ("delta: reports={0} errors={1} cursor_valid={2}" -f $dr, $de, $dc)
if ($dr -eq 0 -and $de -eq 0) { Log 'RESULT: SENSOR SILENT - no report and no error in the window (I2C/MCLR/TS or power)' }
elseif ($dr -gt 0 -and $dc -eq 0) { Log 'RESULT: SENSOR REPORTS, CURSOR REJECTS - data arrives but never becomes a valid cursor point' }
elseif ($dc -gt 0) { Log 'RESULT: CURSOR VALID - input chain produces valid points' }
else { Log 'RESULT: ERRORS ONLY - the reader is failing' }
