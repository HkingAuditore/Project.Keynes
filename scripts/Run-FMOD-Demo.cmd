@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\audio\Run-FmodDemo.ps1" %*
if errorlevel 1 (
    pause
    exit /b 1
)
