@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem build_android.bat - build ProjectKeynes dots_ext for Android arm64.
rem
rem Usage:
rem   build_android.bat          build release, then debug
rem   build_android.bat release  build template_release only
rem   build_android.bat debug    build template_debug only
rem
rem Requirements:
rem   Android Studio SDK with "NDK (Side by side)" installed.
rem   SCons available on PATH.

set "ANDROID_HOME_DEFAULT=%LOCALAPPDATA%\Android\Sdk"
set "ANDROID_HOME_PROJECT_DEFAULT=F:\Developent\AndroidSDK"
if "%ANDROID_HOME%"=="" if exist "%ANDROID_HOME_PROJECT_DEFAULT%" set "ANDROID_HOME=%ANDROID_HOME_PROJECT_DEFAULT%"
if "%ANDROID_HOME%"=="" set "ANDROID_HOME=%ANDROID_HOME_DEFAULT%"
if "%ANDROID_SDK_ROOT%"=="" set "ANDROID_SDK_ROOT=%ANDROID_HOME%"

if "%ANDROID_NDK_ROOT%"=="" if exist "%ANDROID_HOME%\build\cmake\android.toolchain.cmake" set "ANDROID_NDK_ROOT=%ANDROID_HOME%"
if "%ANDROID_NDK_ROOT%"=="" call :find_latest_ndk
if "%ANDROID_NDK_ROOT%"=="" goto ndk_missing
if not exist "%ANDROID_NDK_ROOT%\build\cmake\android.toolchain.cmake" goto ndk_missing

if "%ANDROID_NDK_HOME%"=="" set "ANDROID_NDK_HOME=%ANDROID_NDK_ROOT%"
for %%I in ("%ANDROID_NDK_ROOT%") do set "NDK_VER=%%~nxI"
if "%NDK_VER%"=="" goto ndk_missing

echo.
echo [build_android] ANDROID_HOME     = %ANDROID_HOME%
echo [build_android] ANDROID_NDK_ROOT = %ANDROID_NDK_ROOT%
echo [build_android] ndk_version      = %NDK_VER%
echo.

call :find_scons
if "%SCONS_CMD%"=="" goto scons_missing

set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=both"

pushd "%~dp0"
set "RC=0"

if /I "%TARGET%"=="release" goto build_release
if /I "%TARGET%"=="debug" goto build_debug
if /I "%TARGET%"=="both" goto build_both

echo [ERROR] Unknown target: %TARGET%  (expected: release / debug / both)
set "RC=1"
goto finish

:build_release
call :build template_release
set "RC=%ERRORLEVEL%"
goto finish

:build_debug
call :build template_debug
set "RC=%ERRORLEVEL%"
goto finish

:build_both
call :build template_release
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto finish
call :build template_debug
set "RC=%ERRORLEVEL%"
goto finish

:build
echo.
echo === %SCONS_CMD% platform=android target=%~1 arch=arm64 ndk_version=%NDK_VER% ===
%SCONS_CMD% platform=android target=%~1 arch=arm64 ndk_version=%NDK_VER% -j8
exit /b %ERRORLEVEL%

:finish
if not "%RC%"=="0" goto fail
echo.
echo [build_android] OK. Output:
dir /b "..\Project\project-keynes\addons\dots_ext\bin\android\*.so" 2>nul
popd
endlocal
exit /b 0

:fail
echo.
echo [build_android] BUILD FAILED. exit_code=%RC%
popd
endlocal
exit /b %RC%

:find_latest_ndk
if exist "%ANDROID_HOME%\ndk" (
    for /f "delims=" %%V in ('dir /b /ad /o-n "%ANDROID_HOME%\ndk" 2^>nul') do (
        if exist "%ANDROID_HOME%\ndk\%%V\build\cmake\android.toolchain.cmake" (
            set "ANDROID_NDK_ROOT=%ANDROID_HOME%\ndk\%%V"
            exit /b 0
        )
    )
)
if exist "%ANDROID_HOME%\ndk-bundle\build\cmake\android.toolchain.cmake" (
    set "ANDROID_NDK_ROOT=%ANDROID_HOME%\ndk-bundle"
    exit /b 0
)
exit /b 0

:find_scons
where scons >nul 2>nul
if not errorlevel 1 (
    set "SCONS_CMD=scons"
    exit /b 0
)
if exist "%APPDATA%\Python\Python314\Scripts\scons.exe" (
    set "SCONS_CMD="%APPDATA%\Python\Python314\Scripts\scons.exe""
    exit /b 0
)
if exist "%USERPROFILE%\AppData\Roaming\Python\Python314\Scripts\scons.exe" (
    set "SCONS_CMD="%USERPROFILE%\AppData\Roaming\Python\Python314\Scripts\scons.exe""
    exit /b 0
)
exit /b 0

:ndk_missing
echo.
echo [ERROR] Android NDK not found.
echo   ANDROID_HOME     = %ANDROID_HOME%
echo   ANDROID_NDK_ROOT = %ANDROID_NDK_ROOT%
echo.
echo Install Android Studio SDK Tools: NDK (Side by side).
echo Expected example:
echo   %ANDROID_HOME%\ndk\26.3.11579264\build\cmake\android.toolchain.cmake
echo Or set ANDROID_NDK_ROOT to the installed NDK directory.
endlocal
exit /b 1

:scons_missing
echo.
echo [ERROR] SCons was not found on PATH.
echo Install with: python -m pip install scons
endlocal
exit /b 1
