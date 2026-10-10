@echo off
rem Double-click wrapper for measure_model.ps1 (bypasses the PS script-execution policy).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0measure_model.ps1" %*
pause
