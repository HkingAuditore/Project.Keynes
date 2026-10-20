@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\audio\Start-FmodStudio.ps1" %*
if errorlevel 1 (
    echo.
    pause
    exit /b 1
)
