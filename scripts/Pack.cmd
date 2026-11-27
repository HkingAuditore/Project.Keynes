@echo off
rem ===========================================================================
rem Project.Keynes - one-click build + package for distribution.
rem
rem   scripts\Pack.cmd                         Windows release, zipped to Build\dist
rem   scripts\Pack.cmd -Mode debug             Windows debug
rem   scripts\Pack.cmd -Targets web            Web package only
rem   scripts\Pack.cmd -Targets windows,web    both
rem   scripts\Pack.cmd -SkipNative -NoZip      reuse native libs, keep the folder
rem
rem Everything is forwarded to tools\pack.ps1; see that file for the full list.
rem Output: Build\pack\<stamp>\ (artifacts) + Build\dist\*.zip (what you hand out).
rem ===========================================================================
setlocal EnableExtensions
cd /d "%~dp0.."

if not "%~1"=="" goto :forward

echo.
echo   No arguments: building Windows release and zipping it into Build\dist\
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\pack.ps1" -Targets windows -Mode release
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo === PACK FAILED (exit %RC%) - see the log paths printed above ===
echo.
pause
exit /b %RC%

:forward
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\pack.ps1" %*
set "RC=%ERRORLEVEL%"
exit /b %RC%
