@echo off
rem ---------------------------------------------------------------------------
rem  Project.Keynes web receiver - one-click setup (run ON the Windows/IIS server)
rem
rem  ASCII ONLY on purpose: CJK bytes inside a .cmd break cmd.exe line parsing
rem  when the console code page does not match the file encoding. All messages
rem  come from pk_web_receiver.ps1.
rem
rem  Extra args are forwarded, e.g.:
rem      Setup-Receiver.cmd -Port 8099 -AppName web-debug
rem      Setup-Receiver.cmd -Diagnose -NoProbe
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
title Project.Keynes web receiver setup

set "DIR=%~dp0"
set "PS1=%DIR%pk_web_receiver.ps1"

if not exist "%PS1%" goto :missing

net session >nul 2>&1
if errorlevel 1 goto :elevate
goto :run

:missing
echo [XX] pk_web_receiver.ps1 not found next to this file.
echo      Keep Setup-Receiver.cmd and pk_web_receiver.ps1 in the same folder.
echo.
pause
exit /b 1

:elevate
echo Asking for administrator rights...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
exit /b 0

:run
if "%~1"=="" goto :install
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
goto :done

:install
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Install
set "RC=%ERRORLEVEL%"

:done
echo.
echo ExitCode=%RC%
if not "%RC%"=="0" echo See the log next to the state dir (default: %%ProgramData%%\pk-web-receiver\receiver.log)
echo.
pause
exit /b %RC%
