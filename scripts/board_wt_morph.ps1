# Upload the three morph frames and switch the wavetable to LFO position mode.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/board_wt_morph.ps1 `
#       -Frame0 frames/frame0.bin -Frame1 frames/frame1.bin -Frame2 frames/frame2.bin -Period 20
#   ... -DryRun
#
# Each frame is uploaded by board_wt_upload.ps1 (same verified CRC/APPLY sequence);
# only the last call writes the morph word, because every upload must start from
# WT_SELECT = table.
param(
  [Parameter(Mandatory = $true)][string]$Frame0,
  [Parameter(Mandatory = $true)][string]$Frame1,
  [Parameter(Mandatory = $true)][string]$Frame2,
  [double]$Period = 20,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if ($Period -le 0) { Write-Host 'FATAL: -Period must be > 0'; exit 1 }
$step = [int][math]::Round([math]::Pow(2, 25) / ($Period * 48000))
if ($step -lt 1) { $step = 1 }
if ($step -gt 0x7FFFFF) { $step = 0x7FFFFF }
# {step[22:0], morph_en, 6'b0, table[1:0]} with morph_en=1 and table=2.
$select = ($step -shl 9) -bor 0x100 -bor 2

Write-Host ("MORPH PLAN: 3 tables, step={0}, select=0x{1:X8}" -f $step, $select)
if ($DryRun) { exit 0 }

$upload = Join-Path $PSScriptRoot 'board_wt_upload.ps1'
$tables = @(
  @{ Bin = $Frame0; Table = 0 },
  @{ Bin = $Frame1; Table = 1 },
  @{ Bin = $Frame2; Table = 2 }
)
foreach ($t in $tables) {
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $upload,
            '-Bin', $t.Bin, '-Table', ([string]$t.Table))
  if ($t.Table -eq 2) { $args += @('-PostSelect', ([string]$select)) }
  & powershell @args
  if ($LASTEXITCODE -ne 0) {
    Write-Host ("FATAL: upload of table {0} ({1}) failed with {2}" -f $t.Table, $t.Bin, $LASTEXITCODE)
    exit 1
  }
}
Write-Host 'MORPH RESULT: PASS'
