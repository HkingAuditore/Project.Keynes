@echo off
setlocal EnableExtensions

rem ===========================================================================
rem Project.Keynes - one-shot Windows Desktop PC build & export
rem
rem Usage:
rem   scripts\Build-Windows.cmd                 build native debug + export debug
rem   scripts\Build-Windows.cmd debug           same as above
rem   scripts\Build-Windows.cmd release         build native release + export release
rem   scripts\Build-Windows.cmd skip-native     export debug, reuse existing DLL
rem   scripts\Build-Windows.cmd skip-native-release  export release, reuse DLL
rem ===========================================================================

set "REPO_ROOT=%~dp0.."
set "ARG=%~1"
set "MODE=debug"
set "EXTRA="

if /i "%ARG%"=="release" set "MODE=release"
if /i "%ARG%"=="debug" set "MODE=debug"
if /i "%ARG%"=="skip-native" (
    set "MODE=debug"
    set "EXTRA=-SkipNative"
)
if /i "%ARG%"=="skip-native-debug" (
    set "MODE=debug"
    set "EXTRA=-SkipNative"
)
if /i "%ARG%"=="skip-native-release" (
    set "MODE=release"
    set "EXTRA=-SkipNative"
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\tools\build_windows.ps1" -Mode %MODE% %EXTRA%
exit /b %ERRORLEVEL%
