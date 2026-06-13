@echo off
REM ============================================================================
REM build_android.bat — 在安卓 arm64 上构建 dots_ext GDExtension
REM ============================================================================
REM 使用前提：
REM   1. 已通过 Android Studio → SDK Manager → SDK Tools 安装 NDK (Side by side)
REM      推荐版本 r27c 或更新 (NDK 27.x)。
REM   2. 设置好环境变量（本脚本顶端会做兜底）。
REM
REM 用法：
REM   双击或在 cmd / PowerShell 里执行：
REM       cd D:\Godot\ProjectKeynes\Project.Keynes\gdext
REM       build_android.bat
REM
REM   只构建 release 版（更小更快）：
REM       build_android.bat release
REM
REM   只构建 debug 版：
REM       build_android.bat debug
REM ============================================================================

setlocal ENABLEDELAYEDEXPANSION

REM --- 0. 兜底环境变量 ----------------------------------------------------
if "%ANDROID_HOME%"=="" set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
if "%ANDROID_SDK_ROOT%"=="" set "ANDROID_SDK_ROOT=%ANDROID_HOME%"

REM 自动定位最新的 NDK（Side-by-Side 安装位置：%ANDROID_HOME%\ndk\<version>）
if "%ANDROID_NDK_ROOT%"=="" (
    if exist "%ANDROID_HOME%\ndk" (
        for /f "delims=" %%v in ('dir /b /ad /o-n "%ANDROID_HOME%\ndk" 2^>nul') do (
            set "ANDROID_NDK_ROOT=%ANDROID_HOME%\ndk\%%v"
            goto :ndk_found
        )
    )
)
:ndk_found

if not exist "%ANDROID_NDK_ROOT%\build\cmake\android.toolchain.cmake" (
    echo.
    echo [ERROR] Android NDK not found.
    echo   ANDROID_HOME      = %ANDROID_HOME%
    echo   ANDROID_NDK_ROOT  = %ANDROID_NDK_ROOT%
    echo.
    echo Open Android Studio - SDK Manager - SDK Tools - check "NDK (Side by side)" and install.
    echo Or set ANDROID_NDK_ROOT manually before re-running this script.
    exit /b 1
)

if "%ANDROID_NDK_HOME%"=="" set "ANDROID_NDK_HOME=%ANDROID_NDK_ROOT%"

REM godot-cpp 的 SCons 默认锁定 28.1.13356709，需要把当前实际版本号传给它。
REM 解析 ANDROID_NDK_ROOT 的最后一段目录名作为 ndk_version。
for %%I in ("%ANDROID_NDK_ROOT%") do set "NDK_VER=%%~nxI"

echo.
echo [build_android] ANDROID_HOME      = %ANDROID_HOME%
echo [build_android] ANDROID_NDK_ROOT  = %ANDROID_NDK_ROOT%
echo [build_android] NDK_VER (passed to SCons as ndk_version=) = %NDK_VER%
echo.

REM --- 1. 选择 target ----------------------------------------------------
set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=both"

pushd "%~dp0"

if /i "%TARGET%"=="release" (
    call :build template_release
    goto :done
)
if /i "%TARGET%"=="debug" (
    call :build template_debug
    goto :done
)
if /i "%TARGET%"=="both" (
    call :build template_release || goto :fail
    call :build template_debug   || goto :fail
    goto :done
)

echo [ERROR] Unknown target: %TARGET%   (expected: release / debug / both)
popd
exit /b 1

:build
echo.
echo === scons platform=android target=%~1 arch=arm64 ndk_version=%NDK_VER% ===
scons platform=android target=%~1 arch=arm64 ndk_version=%NDK_VER%
exit /b %ERRORLEVEL%

:fail
echo.
echo [build_android] BUILD FAILED.
popd
exit /b 1

:done
echo.
echo [build_android] OK. Output:
dir /b "..\Project\project-keynes\addons\dots_ext\bin\android\*.so" 2>nul
popd
endlocal
