@echo off
setlocal EnableExtensions

rem Serve the Godot Web export in WebBuild/ with the MIME + COOP/COEP headers
rem required by the browser. Plain `python -m http.server` is not enough.
rem
rem Usage:
rem   serve_web.bat
rem   serve_web.bat 8080

cd /d "%~dp0"

set "PORT=8060"
if not "%~1"=="" set "PORT=%~1"

set "WEB_ROOT=%~dp0WebBuild"
set "ENTRY=%WEB_ROOT%\ProjectKeynes.html"
set "URL=http://127.0.0.1:%PORT%/ProjectKeynes.html"

if not exist "%ENTRY%" (
    echo === ERROR: Web export not found ===
    echo Expected: "%ENTRY%"
    echo Export the "Web" preset from Godot first, then retry.
    pause
    exit /b 1
)

where python >nul 2>nul
if errorlevel 1 (
    echo === ERROR: python was not found on PATH ===
    pause
    exit /b 1
)

echo.
echo === Project.Keynes WebBuild ===
echo Root: %WEB_ROOT%
echo URL:  %URL%
echo.
echo Opening browser, then starting server. Ctrl-C to stop.
echo.

start "" "%URL%"
python "%~dp0tools\serve_web.py" --port %PORT% --root "%WEB_ROOT%"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Server exited with code %EXIT_CODE%.
    pause
)

endlocal & exit /b %EXIT_CODE%
