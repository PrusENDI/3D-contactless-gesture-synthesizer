@echo off
REM Run the cursor telemetry test with the execution policy bypassed.
REM Touch or hover over the sensor pad during the capture window.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\board_cursor.ps1" %*