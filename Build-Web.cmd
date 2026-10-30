@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ===========================================================================
rem Project.Keynes - one-shot Web export
rem
rem   1. Rebuild the dots_ext wasm32 side module from the current C++ source.
rem
rem      threads= must match the Web preset's variant/thread_support, otherwise
rem      the pthread ABI differs and the side module fails to load. The preset
rem      ships variant/thread_support=true, so this script builds threads=yes by
rem      default: the native runtime drives its daily simulation from a
rem      std::thread worker, and without pthreads that worker never runs, which
rem      freezes the browser at "进入世界" 98%. Set PK_WEB_THREADS=no to build the
rem      nothreads variant anyway (menu/world-gen only, then it hangs).
rem
rem      disable_exceptions=no is required: godot-cpp forces -fno-exceptions by
rem      default, but the native runtime uses C++ exceptions for economy
rem      invariant failures. The Godot 4.6 dlink Web main module ships a wasm
rem      exception tag, so an exceptions-enabled side module links and loads.
rem   2. Export the Godot "Web" preset into WebBuild\.
rem
rem Requirements:
rem   * emsdk checked out at <repo>\emsdk, with 4.0.20 installed + activated
rem     (4.0.20 is the Emscripten release the official Godot 4.6 templates use;
rem      any other version makes the side module fail to load in the browser).
rem   * Godot 4.6.x editor binary (set GODOT_BIN, or installed next to the repo).
rem   * 4.6.2.stable web export templates (%APPDATA%\Godot\export_templates).
rem
rem Usage:
rem   Build-Web.cmd                 rebuild native release + export release
rem   Build-Web.cmd debug           rebuild native debug + export debug
rem   Build-Web.cmd both            rebuild/export both variants
rem   Build-Web.cmd skip-native     reuse the existing wasm side module
rem ===========================================================================

set "ROOT=%~dp0"
set "MODE=%~1"
if "%MODE%"=="" set "MODE=release"

set "JOBS=16"
if defined PK_WEB_JOBS set "JOBS=%PK_WEB_JOBS%"

rem Must match the Web export preset's variant/thread_support. The native daily
rem simulation host runs on a std::thread worker, so threads=no produces a
rem module that freezes the page when a world finishes generating.
set "THREADS=yes"
if defined PK_WEB_THREADS set "THREADS=%PK_WEB_THREADS%"

set "WEB_ROOT=%ROOT%WebBuild"
set "LOG_DIR=%ROOT%tmp"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

rem --- locate the Godot editor binary -----------------------------------------
rem Candidates, in order: GODOT_BIN, the usual Windows zip layout where the
rem downloaded archive was extracted into a folder named like the executable,
rem a plain sibling binary, then anything named godot on PATH.
set "GODOT="
if defined GODOT_BIN set "GODOT=%GODOT_BIN%"
call :find_godot "%ROOT%..\..\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe"
call :find_godot "%ROOT%..\..\Godot_v4.6.2-stable_win64.exe"
call :find_godot "%ROOT%..\Godot_v4.6.2-stable_win64.exe"
if not defined GODOT for %%G in (godot.exe godot4.exe) do (
    if not defined GODOT where %%G >nul 2>nul && set "GODOT=%%G"
)
if not defined GODOT (
    echo === ERROR: Godot editor binary not found ===
    echo Set GODOT_BIN to the Godot 4.6.x executable and retry.
    exit /b 1
)
rem Canonicalise: cmd cannot launch a quoted path that still contains "..\"
rem components (fails with 9009 even though `if exist` reports the file).
for %%F in ("%GODOT%") do set "GODOT=%%~fF"

echo ============================================================
echo  Project.Keynes Web export
echo  Mode:      %MODE%
echo  Godot:     %GODOT%
echo  Output:    %WEB_ROOT%\ProjectKeynes.html
echo  Logs:      %LOG_DIR%\web_export_*.log
echo ============================================================
echo.

rem --- 1. native wasm side module ---------------------------------------------
if /i not "%MODE%"=="skip-native" (
    if not exist "%ROOT%emsdk\emsdk_env.bat" (
        echo === ERROR: emsdk not found at "%ROOT%emsdk" ===
        echo Install emsdk 4.0.20 and activate it first.
        exit /b 1
    )
    call "%ROOT%emsdk\emsdk_env.bat" >nul
    if errorlevel 1 (
        echo === ERROR: failed to activate emsdk ===
        exit /b 1
    )

    for /f "tokens=*" %%V in ('emcc -dumpversion 2^>nul') do set "EM_ACTUAL=%%V"
    if not "!EM_ACTUAL!"=="4.0.20" (
        echo === WARNING: Emscripten "%EM_ACTUAL%" ^(expected 4.0.20^) ===
        echo The side module will most likely fail to load in the browser.
        echo.
    )

    pushd "%ROOT%gdext"
    set "PUSHED=1"
    if /i "%MODE%"=="debug" (
        call :build_native template_debug
        if errorlevel 1 goto :fail
    ) else if /i "%MODE%"=="both" (
        call :build_native template_release
        if errorlevel 1 goto :fail
        call :build_native template_debug
        if errorlevel 1 goto :fail
    ) else (
        call :build_native template_release
        if errorlevel 1 goto :fail
    )
    popd
    set "PUSHED="
    echo.
)

rem --- 2. Godot Web export ----------------------------------------------------
if /i "%MODE%"=="debug" (
    call :export_web debug
) else if /i "%MODE%"=="both" (
    call :export_web release
    if errorlevel 1 goto :fail
    call :export_web debug
) else (
    call :export_web release
)
if errorlevel 1 goto :fail

echo.
echo === Web export finished ===
dir /b "%WEB_ROOT%"
echo.
echo Serve it with:  serve_web.bat
exit /b 0

:fail
if defined PUSHED popd
echo.
echo === Web export FAILED ===
exit /b 1

rem ---------------------------------------------------------------------------
:build_native
echo [native] scons platform=web target=%1 threads=%THREADS% ...
scons platform=web arch=wasm32 threads=%THREADS% lto=none disable_exceptions=no -j%JOBS% target=%1 dev_build=no ^
    >"%LOG_DIR%\web_native_%1.log" 2>&1
if errorlevel 1 (
    echo === ERROR: native %1 build FAILED ^(see "%LOG_DIR%\web_native_%1.log"^) ===
    exit /b 1
)
echo [native] %1 ok
exit /b 0

rem ---------------------------------------------------------------------------
:export_web
set "EXPORT_MODE=%1"
if not exist "%WEB_ROOT%" mkdir "%WEB_ROOT%"
rem Drop the previous artifacts first: Godot only writes the files the current
rem preset references, so a stale side module from an earlier run (e.g. the
rem template_debug wasm after a release export) would otherwise linger in the
rem served folder.
for %%X in (html js pck wasm png) do del /q "%WEB_ROOT%\*.%%X" 2>nul
del /q "%WEB_ROOT%\*.worklet.js" 2>nul
echo [export] Godot export-release Web preset ^(%EXPORT_MODE%^) ...
"%GODOT%" --headless --path "%ROOT%Project\project-keynes" --export-release "Web" ^
    "%WEB_ROOT%\ProjectKeynes.html" >"%LOG_DIR%\web_export_release.log" 2>&1
if errorlevel 1 (
    echo === ERROR: Godot Web export FAILED ^(see "%LOG_DIR%\web_export_release.log"^) ===
    exit /b 1
)
echo [export] ok
exit /b 0

rem ---------------------------------------------------------------------------
:find_godot
rem %1 = candidate path. Accepts it only when it names an existing regular file
rem (a bare `if exist` also matches a directory with that exact name, which is
rem how a Godot zip extracted into "Godot_vX.y.z.exe\" traps this script).
if defined GODOT exit /b 0
if not exist "%~1" exit /b 0
if exist "%~1\" exit /b 0
set "GODOT=%~1"
exit /b 0
