@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"

rem Project.Keynes gdext web (wasm32) build helper.
rem
rem Emscripten MUST be 4.0.20 — that is the version the official Godot 4.6
rem export templates were built with (see build-containers/4.6/Dockerfile.web).
rem A side module produced by any other Emscripten version fails to load at
rem runtime, usually as a bare "failed to load dynamic library" in the console.
rem
rem Activate the SDK before running this script:
rem   git clone https://github.com/emscripten-core/emsdk
rem   cd emsdk
rem   emsdk install 4.0.20
rem   emsdk activate 4.0.20
rem   emsdk_env.bat
rem
rem threads=no matches variant/thread_support=false in the Web export preset,
rem which is what lets the build run without cross-origin isolation headers.
rem Both sides must agree or the pthread ABI mismatches.
rem
rem lto=none keeps link times sane during bring-up; web.py defaults lto to
rem "full", which on this codebase costs many minutes per link. Drop the
rem override once the build is known good.

set "EM_EXPECTED=4.0.20"

where emcc >nul 2>nul
if errorlevel 1 (
    echo === ERROR: emcc was not found on PATH ===
    echo Activate the Emscripten SDK first, e.g.:
    echo   path\to\emsdk\emsdk_env.bat
    pause
    exit /b 1
)

for /f "tokens=*" %%V in ('emcc -dumpversion 2^>nul') do set "EM_ACTUAL=%%V"
echo Emscripten: !EM_ACTUAL!  (expected !EM_EXPECTED!)
if not "!EM_ACTUAL!"=="!EM_EXPECTED!" (
    echo.
    echo === WARNING: Emscripten version mismatch ===
    echo Godot 4.6 official templates were built with !EM_EXPECTED!.
    echo Continuing, but the side module will most likely fail to load.
    echo.
)

set "SCONS_CMD="
where scons >nul 2>nul
if not errorlevel 1 set "SCONS_CMD=scons"
if not defined SCONS_CMD set "SCONS_CMD=python -m SCons"

set "COMMON_FLAGS=platform=web arch=wasm32 threads=no lto=none -j8"

echo.
echo === [1/2] Building target=template_debug ===
%SCONS_CMD% %COMMON_FLAGS% target=template_debug dev_build=no
if errorlevel 1 (
    echo.
    echo === ERROR: template_debug build FAILED ===
    pause
    exit /b 1
)

echo.
echo === [2/2] Building target=template_release ===
%SCONS_CMD% %COMMON_FLAGS% target=template_release dev_build=no
if errorlevel 1 (
    echo.
    echo === ERROR: template_release build FAILED ===
    pause
    exit /b 1
)

echo.
echo === Build done. Produced side modules: ===
for %%F in ("..\Project\project-keynes\addons\dots_ext\bin\web\*.wasm") do (
    echo %%~nxF  %%~zF bytes
)

echo.
echo === Next: export the "Web" preset from Godot, then serve WebBuild/ ===
echo ===       with tools\serve_web.py (see that file for why).        ===
pause
endlocal
