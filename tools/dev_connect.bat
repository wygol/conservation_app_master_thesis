@echo off
rem Double-click wrapper for dev_connect.ps1 (bypasses PS script-execution policy)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dev_connect.ps1"
pause
