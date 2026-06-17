@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Project.Keynes Android test package helper.
rem Builds the Android debug GDExtension, exports a debug APK, then installs it
rem onto the single connected Android device.

cd /d "%~dp0"

set "PROJECT_DIR=%~dp0Project\project-keynes"
set "BUILD_DIR=%~dp0Build"
set "APK_PATH=%BUILD_DIR%\ProjectKeynes-debug.apk"
set "EXPORT_PRESET=Android"
set "PACKAGE_NAME=com.projectkeynes.game"
set "BUILD_GDEXT=1"
set "PAUSE_ON_EXIT=1"
set "CAPTURE_LOGCAT=1"
set "LAUNCH_APP=1"
set "LOGCAT_SECONDS=20"

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

echo.
echo === Project.Keynes Android test deploy ===
echo Project: "%PROJECT_DIR%"
echo APK:     "%APK_PATH%"
echo Preset:  "%EXPORT_PRESET%"
echo.

if not exist "%PROJECT_DIR%\project.godot" (
    echo [ERROR] Godot project was not found:
    echo   "%PROJECT_DIR%\project.godot"
    goto fail
)

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"
set "LOG_DIR=%BUILD_DIR%\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
call :make_stamp
set "LOG_FILE=%LOG_DIR%\android_deploy_%RUN_STAMP%.log"
set "LOGCAT_FILE=%LOG_DIR%\android_logcat_%RUN_STAMP%.txt"

call :find_godot
if errorlevel 1 goto fail
echo [godot] "%GODOT_EXE%"

call :find_adb
if errorlevel 1 goto fail
echo [adb]   "%ADB_EXE%"

call :write_log_header
echo [log]   "%LOG_FILE%"

if "%BUILD_GDEXT%"=="1" (
    echo.
    echo === [1/4] Build Android GDExtension debug library ===
    call :run_logged "%~dp0gdext\build_android.bat" debug
    if errorlevel 1 (
        echo.
        echo [ERROR] Android GDExtension build failed.
        echo See log:
        echo   "%LOG_FILE%"
        goto fail
    )
) else (
    echo.
    echo === [1/4] Skip Android GDExtension build ===
)

echo.
echo === [2/4] Export Android debug APK ===
if exist "%APK_PATH%" del /q "%APK_PATH%" >nul 2>nul
call :run_logged "%GODOT_EXE%" --headless --path "%PROJECT_DIR%" --export-debug "%EXPORT_PRESET%" "%APK_PATH%"
if errorlevel 1 (
    echo.
    echo [ERROR] Godot Android debug export failed.
    echo See log:
    echo   "%LOG_FILE%"
    goto fail
)

if not exist "%APK_PATH%" (
    echo.
    echo [ERROR] Godot finished, but APK was not created:
    echo   "%APK_PATH%"
    goto fail
)

echo.
echo === [3/4] Find connected Android device ===
call :select_device
if errorlevel 1 goto fail
echo [device] %DEVICE_SERIAL%
if "%CAPTURE_LOGCAT%"=="1" (
    "%ADB_EXE%" -s "%DEVICE_SERIAL%" logcat -c >> "%LOG_FILE%" 2>&1
)

echo.
echo === [4/4] Install APK ===
call :run_logged "%ADB_EXE%" -s "%DEVICE_SERIAL%" install -r -d "%APK_PATH%"
if errorlevel 1 (
    echo.
    echo [ERROR] adb install failed.
    echo If the installed app was signed with a different key, uninstall it manually first:
    echo   "%ADB_EXE%" -s "%DEVICE_SERIAL%" uninstall %PACKAGE_NAME%
    echo See log:
    echo   "%LOG_FILE%"
    goto fail
)

if "%CAPTURE_LOGCAT%"=="1" (
    echo.
    echo === Capture device logcat ===
    if "%LAUNCH_APP%"=="1" (
        echo Launching app and collecting %LOGCAT_SECONDS% seconds of device logs...
        call :run_logged "%ADB_EXE%" -s "%DEVICE_SERIAL%" shell monkey -p "%PACKAGE_NAME%" -c android.intent.category.LAUNCHER 1
        if errorlevel 1 (
            echo [WARN] Failed to launch app through monkey. Capturing current device logs anyway.
            >> "%LOG_FILE%" echo [WARN] Failed to launch app through monkey. Capturing current device logs anyway.
        )
        timeout /t %LOGCAT_SECONDS% /nobreak >nul
    )
    "%ADB_EXE%" -s "%DEVICE_SERIAL%" logcat -d -v time > "%LOGCAT_FILE%" 2>> "%LOG_FILE%"
    if errorlevel 1 (
        echo [WARN] Failed to capture device logcat. See deploy log:
        echo   "%LOG_FILE%"
    ) else (
        echo Device logcat:
        echo   "%LOGCAT_FILE%"
    )
)

echo.
echo === Done ===
echo Installed:
echo   "%APK_PATH%"
echo Deploy log:
echo   "%LOG_FILE%"
call :pause_if_needed
endlocal
exit /b 0

:parse_args
if "%~1"=="" exit /b 0
if /I "%~1"=="--skip-gdext" (
    set "BUILD_GDEXT=0"
    shift
    goto parse_args
)
if /I "%~1"=="--no-pause" (
    set "PAUSE_ON_EXIT=0"
    shift
    goto parse_args
)
if /I "%~1"=="--no-logcat" (
    set "CAPTURE_LOGCAT=0"
    shift
    goto parse_args
)
if /I "%~1"=="--no-launch" (
    set "LAUNCH_APP=0"
    shift
    goto parse_args
)
if /I "%~1"=="--logcat-seconds" (
    if "%~2"=="" (
        echo [ERROR] Missing value for --logcat-seconds.
        echo.
        goto usage_error
    )
    set "LOGCAT_SECONDS=%~2"
    shift
    shift
    goto parse_args
)
echo [ERROR] Unknown argument: %~1
echo.
goto usage_error

:print_usage
echo Usage:
echo   build_install_android.bat [--skip-gdext] [--no-pause] [--no-logcat] [--no-launch] [--logcat-seconds N]
echo.
echo Options:
echo   --skip-gdext   Do not rebuild gdext Android debug library.
echo   --no-pause     Do not pause before exiting.
echo   --no-logcat    Do not export adb logcat after installing.
echo   --no-launch    Do not launch the app before capturing logcat.
echo   --logcat-seconds N
echo                  Seconds to wait after launch before exporting logcat. Default: 20.
exit /b 0

:usage_error
call :print_usage
exit /b 1

:make_stamp
for /f "delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss" 2^>nul') do set "RUN_STAMP=%%T"
if not defined RUN_STAMP set "RUN_STAMP=%RANDOM%"
exit /b 0

:write_log_header
> "%LOG_FILE%" echo Project.Keynes Android deploy log
>> "%LOG_FILE%" echo Started: %DATE% %TIME%
>> "%LOG_FILE%" echo Project: "%PROJECT_DIR%"
>> "%LOG_FILE%" echo APK: "%APK_PATH%"
>> "%LOG_FILE%" echo Preset: "%EXPORT_PRESET%"
>> "%LOG_FILE%" echo Godot: "%GODOT_EXE%"
>> "%LOG_FILE%" echo adb: "%ADB_EXE%"
>> "%LOG_FILE%" echo Capture logcat: %CAPTURE_LOGCAT%
>> "%LOG_FILE%" echo Launch app: %LAUNCH_APP%
>> "%LOG_FILE%" echo Logcat seconds: %LOGCAT_SECONDS%
>> "%LOG_FILE%" echo.
exit /b 0

:run_logged
>> "%LOG_FILE%" echo.
>> "%LOG_FILE%" echo ^> %*
call %* >> "%LOG_FILE%" 2>&1
set "CMD_RC=%ERRORLEVEL%"
>> "%LOG_FILE%" echo [exit_code] %CMD_RC%
exit /b %CMD_RC%

:find_godot
if defined GODOT_EXE (
    if exist "%GODOT_EXE%" exit /b 0
    echo [WARN] GODOT_EXE is set but does not exist:
    echo   "%GODOT_EXE%"
)

if defined GODOT4 (
    if exist "%GODOT4%" (
        set "GODOT_EXE=%GODOT4%"
        exit /b 0
    )
)

call :first_on_path godot
if defined GODOT_EXE exit /b 0

call :first_on_path godot4
if defined GODOT_EXE exit /b 0

call :try_godot "F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"
if defined GODOT_EXE exit /b 0
call :try_godot "F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe"
if defined GODOT_EXE exit /b 0
call :try_godot "F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe"
if defined GODOT_EXE exit /b 0
call :try_godot "%LOCALAPPDATA%\Programs\Godot\Godot.exe"
if defined GODOT_EXE exit /b 0

echo.
echo [ERROR] Godot executable was not found.
echo Set GODOT_EXE to your Godot 4.6 executable, for example:
echo   set GODOT_EXE=F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe
exit /b 1

:try_godot
if exist "%~1" set "GODOT_EXE=%~1"
exit /b 0

:first_on_path
for /f "delims=" %%G in ('where %~1 2^>nul') do (
    if not defined GODOT_EXE set "GODOT_EXE=%%G"
)
exit /b 0

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
"%ADB_EXE%" start-server >nul 2>> "%LOG_FILE%"

set "DEVICE_SERIAL="
if defined ANDROID_SERIAL (
    set "DEVICE_SERIAL=%ANDROID_SERIAL%"
    "%ADB_EXE%" -s "%DEVICE_SERIAL%" get-state >nul 2>nul
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
