@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Project.Keynes Android logcat capture helper.
rem Captures device logcat to Build\logs without building or installing the APK.

cd /d "%~dp0"

set "BUILD_DIR=%~dp0Build"
set "LOG_DIR=%BUILD_DIR%\logs"
set "PACKAGE_NAME=com.projectkeynes.game"
set "PAUSE_ON_EXIT=1"
set "CLEAR_LOGCAT=1"
set "LAUNCH_APP=1"
set "LOGCAT_SECONDS=20"
set "OUTPUT_FILE="

if /I "%~1"=="--help" (
    call :print_usage
    endlocal
    exit /b 0
)
if /I "%~1"=="/?" (
    call :print_usage
    endlocal
    exit /b 0
)

call :parse_args %*
if errorlevel 1 goto fail

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
call :make_stamp
if not defined OUTPUT_FILE set "OUTPUT_FILE=%LOG_DIR%\android_logcat_%RUN_STAMP%.txt"
set "CAPTURE_LOG=%LOG_DIR%\android_logcat_capture_%RUN_STAMP%.log"

echo.
echo === Project.Keynes Android log capture ===
echo Package: "%PACKAGE_NAME%"
echo Output:  "%OUTPUT_FILE%"
echo.

call :find_adb
if errorlevel 1 goto fail
echo [adb]    "%ADB_EXE%"

> "%CAPTURE_LOG%" echo Project.Keynes Android logcat capture
>> "%CAPTURE_LOG%" echo Started: %DATE% %TIME%
>> "%CAPTURE_LOG%" echo Package: "%PACKAGE_NAME%"
>> "%CAPTURE_LOG%" echo Output: "%OUTPUT_FILE%"
>> "%CAPTURE_LOG%" echo Clear logcat: %CLEAR_LOGCAT%
>> "%CAPTURE_LOG%" echo Launch app: %LAUNCH_APP%
>> "%CAPTURE_LOG%" echo Seconds: %LOGCAT_SECONDS%
>> "%CAPTURE_LOG%" echo adb: "%ADB_EXE%"
>> "%CAPTURE_LOG%" echo.

echo.
echo === Find connected Android device ===
call :select_device
if errorlevel 1 goto fail
echo [device] %DEVICE_SERIAL%

if "%CLEAR_LOGCAT%"=="1" (
    echo.
    echo === Clear existing logcat ===
    "%ADB_EXE%" -s "%DEVICE_SERIAL%" logcat -c >> "%CAPTURE_LOG%" 2>&1
    if errorlevel 1 (
        echo [ERROR] Failed to clear logcat.
        echo See log:
        echo   "%CAPTURE_LOG%"
        goto fail
    )
)

if "%LAUNCH_APP%"=="1" (
    echo.
    echo === Launch app ===
    call :run_logged "%ADB_EXE%" -s "%DEVICE_SERIAL%" shell monkey -p "%PACKAGE_NAME%" -c android.intent.category.LAUNCHER 1
    if errorlevel 1 (
        echo [ERROR] Failed to launch app.
        echo See log:
        echo   "%CAPTURE_LOG%"
        goto fail
    )
)

echo.
echo === Wait %LOGCAT_SECONDS% seconds ===
if not "%LOGCAT_SECONDS%"=="0" (
    set /a WAIT_PINGS=%LOGCAT_SECONDS%+1 >nul 2>nul
    if not defined WAIT_PINGS set "WAIT_PINGS=1"
    ping -n !WAIT_PINGS! 127.0.0.1 >nul
)

echo.
echo === Export logcat ===
"%ADB_EXE%" -s "%DEVICE_SERIAL%" logcat -d -v time > "%OUTPUT_FILE%" 2>> "%CAPTURE_LOG%"
if errorlevel 1 (
    echo [ERROR] Failed to export logcat.
    echo See log:
    echo   "%CAPTURE_LOG%"
    goto fail
)

echo.
echo === Done ===
echo Device logcat:
echo   "%OUTPUT_FILE%"
echo Capture log:
echo   "%CAPTURE_LOG%"
call :pause_if_needed
endlocal
exit /b 0

:parse_args
if "%~1"=="" exit /b 0
if /I "%~1"=="--no-pause" (
    set "PAUSE_ON_EXIT=0"
    shift
    goto parse_args
)
if /I "%~1"=="--no-clear" (
    set "CLEAR_LOGCAT=0"
    shift
    goto parse_args
)
if /I "%~1"=="--no-launch" (
    set "LAUNCH_APP=0"
    shift
    goto parse_args
)
if /I "%~1"=="--seconds" (
    if "%~2"=="" (
        echo [ERROR] Missing value for --seconds.
        echo.
        goto usage_error
    )
    set "LOGCAT_SECONDS=%~2"
    shift
    shift
    goto parse_args
)
if /I "%~1"=="--package" (
    if "%~2"=="" (
        echo [ERROR] Missing value for --package.
        echo.
        goto usage_error
    )
    set "PACKAGE_NAME=%~2"
    shift
    shift
    goto parse_args
)
if /I "%~1"=="--output" (
    if "%~2"=="" (
        echo [ERROR] Missing value for --output.
        echo.
        goto usage_error
    )
    set "OUTPUT_FILE=%~2"
    shift
    shift
    goto parse_args
)
echo [ERROR] Unknown argument: %~1
echo.
goto usage_error

:print_usage
echo Usage:
echo   capture_android_log.bat [--seconds N] [--no-launch] [--no-clear] [--output PATH] [--no-pause]
echo.
echo Options:
echo   --seconds N    Seconds to wait before exporting logcat. Default: 20.
echo   --no-launch    Do not launch ProjectKeynes before capturing logs.
echo   --no-clear     Do not clear existing logcat before capturing logs.
echo   --output PATH  Write logcat to a custom file path.
echo   --package NAME Android package to launch. Default: com.projectkeynes.game.
echo   --no-pause     Do not pause before exiting.
exit /b 0

:usage_error
call :print_usage
exit /b 1

:make_stamp
for /f "delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss" 2^>nul') do set "RUN_STAMP=%%T"
if not defined RUN_STAMP set "RUN_STAMP=%RANDOM%"
exit /b 0

:run_logged
>> "%CAPTURE_LOG%" echo.
>> "%CAPTURE_LOG%" echo ^> %*
call %* >> "%CAPTURE_LOG%" 2>&1
set "CMD_RC=%ERRORLEVEL%"
>> "%CAPTURE_LOG%" echo [exit_code] %CMD_RC%
exit /b %CMD_RC%

:find_adb
if defined ADB_EXE (
    if exist "%ADB_EXE%" exit /b 0
    echo [WARN] ADB_EXE is set but does not exist:
    echo   "%ADB_EXE%"
)

for /f "delims=" %%A in ('where adb 2^>nul') do (
    if not defined ADB_EXE set "ADB_EXE=%%A"
)
if defined ADB_EXE exit /b 0

if exist "F:\Developent\platform-tools-latest-windows\platform-tools\adb.exe" (
    set "ADB_EXE=F:\Developent\platform-tools-latest-windows\platform-tools\adb.exe"
    exit /b 0
)
if defined ANDROID_HOME if exist "%ANDROID_HOME%\platform-tools\adb.exe" (
    set "ADB_EXE=%ANDROID_HOME%\platform-tools\adb.exe"
    exit /b 0
)
if defined ANDROID_SDK_ROOT if exist "%ANDROID_SDK_ROOT%\platform-tools\adb.exe" (
    set "ADB_EXE=%ANDROID_SDK_ROOT%\platform-tools\adb.exe"
    exit /b 0
)

echo.
echo [ERROR] adb was not found.
echo Install Android platform-tools or set ADB_EXE to adb.exe.
exit /b 1

:select_device
"%ADB_EXE%" start-server >nul 2>> "%CAPTURE_LOG%"

set "DEVICE_SERIAL="
if defined ANDROID_SERIAL (
    set "DEVICE_SERIAL=%ANDROID_SERIAL%"
    "%ADB_EXE%" -s "%DEVICE_SERIAL%" get-state >nul 2>> "%CAPTURE_LOG%"
    if errorlevel 1 (
        echo [ERROR] ANDROID_SERIAL is set, but that device is not ready:
        echo   %DEVICE_SERIAL%
        "%ADB_EXE%" devices
        exit /b 1
    )
    exit /b 0
)

set "DEVICES_FILE=%TEMP%\project_keynes_adb_devices_%RANDOM%.txt"
"%ADB_EXE%" devices > "%DEVICES_FILE%"

set "DEVICE_COUNT=0"
set "DETECTED_SERIAL="
for /f "usebackq skip=1 tokens=1,2" %%A in ("%DEVICES_FILE%") do (
    if /I "%%B"=="device" (
        set /a DEVICE_COUNT+=1
        if not defined DETECTED_SERIAL set "DETECTED_SERIAL=%%A"
    )
)
del /q "%DEVICES_FILE%" >nul 2>nul

if "%DEVICE_COUNT%"=="0" (
    echo [ERROR] No ready Android device found.
    echo Connect a device, enable USB debugging, then check:
    echo   "%ADB_EXE%" devices
    exit /b 1
)

if not "%DEVICE_COUNT%"=="1" (
    echo [ERROR] More than one ready Android device was found.
    echo Set ANDROID_SERIAL to choose one, then run again:
    echo   set ANDROID_SERIAL=your_device_serial
    echo.
    "%ADB_EXE%" devices
    exit /b 1
)

set "DEVICE_SERIAL=%DETECTED_SERIAL%"
exit /b 0

:pause_if_needed
if not "%PAUSE_ON_EXIT%"=="0" (
    echo.
    pause
)
exit /b 0

:fail
echo.
echo === Failed ===
call :pause_if_needed
endlocal
exit /b 1
