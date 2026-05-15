@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"
set "VSLANG=1033"

rem Project.Keynes gdext rebuild helper.
rem Run this from a VS 2022 x64 Native Tools Command Prompt when possible.
rem Close Godot before rebuilding because loaded DLLs can be locked.

set "SCONS_CMD="

where scons >nul 2>nul
if not errorlevel 1 (
    set "SCONS_CMD=scons"
)

if not defined SCONS_CMD (
    if exist "%APPDATA%\Python\Python314\Scripts\scons.exe" (
        set "SCONS_CMD=%APPDATA%\Python\Python314\Scripts\scons.exe"
    )
)

if not defined SCONS_CMD (
    if exist "%LOCALAPPDATA%\Programs\Python\Python314\Scripts\scons.exe" (
        set "SCONS_CMD=%LOCALAPPDATA%\Programs\Python\Python314\Scripts\scons.exe"
    )
)

if not defined SCONS_CMD (
    echo === ERROR: SCons was not found ===
    echo Install it with:
    echo   python -m pip install scons
    echo.
    echo Or add the Python Scripts directory containing scons.exe to PATH.
    pause
    exit /b 1
)

echo Using SCons: "%SCONS_CMD%"
echo.

echo === [1/3] Building target=template_debug ===
"%SCONS_CMD%" platform=windows target=template_debug dev_build=no -j8
if errorlevel 1 (
    echo.
    echo === ERROR: template_debug build FAILED ===
    pause
    exit /b 1
)

echo.
echo === [2/3] Building target=template_release ===
"%SCONS_CMD%" platform=windows target=template_release dev_build=no -j8
if errorlevel 1 (
    echo.
    echo === ERROR: template_release build FAILED ===
    pause
    exit /b 1
)

echo.
echo === [3/3] Build done. Updated DLLs: ===
for %%F in ("..\Project\project-keynes\addons\dots_ext\bin\windows\*.dll") do (
    echo %%~nxF  %%~zF bytes
)

echo.
echo === Both debug and release DLLs updated. Restart Godot completely. ===
echo === The editor must be closed before rebuild because it locks loaded DLLs. ===
pause
endlocal
