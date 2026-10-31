# Put the board into LIVE with the uploaded wavetable, and enable the telemetry
# stream so host/cursor_view.py can draw the cursor at the same time.
#
# Order matters: the uploader forces IDLE (writes are refused while a table is
# playing), so the mode is set AFTER the upload, never before.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_live_visual.ps1 -Bin artifacts/wt/capture.bin
#   python host\cursor_view.py --port COM4
param(
  [string]$Port = 'COM4',
  [string]$Bin = '',
  [int]$TlmHz = 20
)

$ErrorActionPreference = 'Stop'
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

if ($Bin -ne '') {
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\board_wt_upload.ps1 -Bin $Bin -Port $Port 2>&1 | Select-Object -Last 2
  if ($LASTEXITCODE -ne 0) { "FATAL: upload failed"; exit 1 }
}

$sp = New-Object System.IO.Ports.SerialPort $Port, 1000000, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 400; $sp.WriteTimeout = 400
$sp.Open(); Start-Sleep -Milliseconds 60; $sp.DiscardInBuffer()
$script:seq = 0

function Send([int]$op, [int]$addr, [uint32]$data) {
  $script:seq = ($script:seq + 1) -band 0xFF
  $f = New-Object byte[] 11
  $f[0] = 0xA5; $f[1] = 0x02; $f[2] = [byte]$op; $f[3] = [byte]$addr; $f[4] = [byte]$script:seq
  $f[5] = [byte](($data -shr 24) -band 0xFF); $f[6] = [byte](($data -shr 16) -band 0xFF)
  $f[7] = [byte](($data -shr 8) -band 0xFF);  $f[8] = [byte]($data -band 0xFF)
  $c = Get-Crc16 $f[0..8]; $f[9] = [byte](($c -shr 8) -band 0xFF); $f[10] = [byte]($c -band 0xFF)
  $sp.Write($f, 0, 11)
  $buf = New-Object 'System.Collections.Generic.List[byte]'
  $dl = (Get-Date).AddMilliseconds(400)
  while ((Get-Date) -lt $dl -and $buf.Count -lt 22) { try { $buf.Add([byte]$sp.ReadByte()) } catch { break } }
  if ($buf.Count -ne 22) { return @{ e = 255; d = 0 } }
  $r = $buf.ToArray()
  return @{ e = $r[19]; d = [uint32]((([uint64]$r[14]) -shl 24) -bor (([uint64]$r[15]) -shl 16) -bor (([uint64]$r[16]) -shl 8) -bor [uint64]$r[17]) }
}

# Telemetry: period is in 48 kHz samples; 48000/Hz. 20 Hz -> 2400.
$period = [uint32][math]::Round(48000.0 / [math]::Max(1, $TlmHz))
$tlm = (($period -band 0xFFFF) -shl 16) -bor 1
$null = Send 0x02 0x80 $tlm

$live = Send 0x02 0x04 1
Start-Sleep -Milliseconds 200
$st = Send 0x01 0x00 0
"tlm period = {0} samples ({1} Hz), MODE err={2}, STATUS=0x{3:X8} (1 = LIVE)" -f $period, $TlmHz, $live.e, $st.d
$sp.Close(); $sp.Dispose()
"now run:  python host\cursor_view.py --port $Port"
