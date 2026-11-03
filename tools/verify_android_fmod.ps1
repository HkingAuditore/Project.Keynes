# One-command Android FMOD verification for Project.Keynes.
#
# What it does (no manual steps):
#   1. exports the isolated probe project (tmp/fmod_android_probe) as a debug APK
#   2. injects the org.fmod.* Java stub as a secondary dex and re-signs it
#   3. installs it on the given device and starts it
#   4. captures logcat and decides PASS / NEEDS-MORE-STUBS / FAIL
#
# PASS            -> logcat has "[probe] PROBE_DONE ok=true": FMOD initialised on the
#                    device, banks loaded from the PCK and an event actually started.
# NEEDS-MORE-STUBS-> FMOD reported a missing org.fmod.* member; the script prints the
#                    exact list and the command that adds it. Re-run afterwards.
# FAIL            -> anything else; the captured log file is printed.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify_android_fmod.ps1
#   ... -Serial 1234567890 -SkipExport     (use an already exported probe.apk)
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 as ANSI unless
# the file has a BOM, which would corrupt non-ASCII text in the script.

param(
    [string]$Serial = 'emulator-5554',
    [string]$GodotExe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe',
    [string]$ProbeDir = 'tmp\fmod_android_probe',
    [string]$Package = 'com.projectkeynes.fmodprobe',
    [string]$Activity = 'com.projectkeynes.fmodprobe/com.godot.game.GodotAppLauncher',
    [int]$RunSeconds = 40,
    [switch]$SkipExport,
    [switch]$KeepLog
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Push-Location $root
try {
    $adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    $env:ANDROID_HOME = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logDir = 'tmp\fmod_multi'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $log = Join-Path $logDir "verify_android_fmod_$stamp.log"

    Write-Host "[verify] device check: $Serial"
    $state = ((& $adb -s $Serial get-state 2>$null) -join '').Trim()
    if ($state -ne 'device') {
        Write-Host "[verify] FAIL: device '$Serial' state=$state (start an emulator or plug a phone)"
        exit 1
    }

    $apk = Join-Path $ProbeDir 'probe.apk'
    $jniApk = Join-Path $ProbeDir 'probe-jni.apk'

    if (-not $SkipExport) {
        Write-Host "[verify] exporting probe project"
        $preset = Join-Path $ProbeDir 'export_presets.cfg'
        if (-not (Test-Path $preset)) { python tools/make_fmod_probe_preset.py | Out-Null }
        & $GodotExe --headless --path (Resolve-Path $ProbeDir).Path --export-debug 'Android' ((Resolve-Path $ProbeDir).Path + '\probe.apk') 2>&1 |
            Select-String -Pattern 'DONE \] export|failed' | ForEach-Object { Write-Host "  $($_.Line)" }
        if (-not (Test-Path $apk)) { Write-Host '[verify] FAIL: export produced no apk'; exit 1 }
    }

    Write-Host "[verify] injecting org.fmod stubs"
    python tools/inject_fmod_java_stub.py $apk -o $jniApk 2>&1 |
        Select-String -Pattern 'signed apk|failed|error' | ForEach-Object { Write-Host "  $($_.Line)" }
    if (-not (Test-Path $jniApk)) { Write-Host '[verify] FAIL: stub injection failed'; exit 1 }

    Write-Host "[verify] installing"
    & $adb -s $Serial uninstall $Package 2>&1 | Out-Null
    $install = & $adb -s $Serial install -r $jniApk 2>&1
    if (-not ($install -match 'Success')) {
        $install | ForEach-Object { Write-Host "  $_" }
        Write-Host '[verify] FAIL: install failed'
        exit 1
    }

    & $adb -s $Serial logcat -c 2>&1 | Out-Null
    Write-Host "[verify] starting probe"
    & $adb -s $Serial shell "am start -n $Activity" 2>&1 | Out-Null

    # Stream logcat into the log file so a dying device still leaves evidence.
    $stream = Start-Process -FilePath $adb -ArgumentList @('-s', $Serial, 'logcat', '-v', 'time') `
        -NoNewWindow -RedirectStandardOutput $log -PassThru
    Start-Sleep -Seconds $RunSeconds
    if ($stream -and -not $stream.HasExited) { $stream.Kill() }

    $text = Get-Content $log -Raw -ErrorAction SilentlyContinue
    if (-not $text) { Write-Host '[verify] FAIL: empty logcat (device died?)'; exit 1 }

    if ($text -match '\[probe\] PROBE_DONE ok=true') {
        Write-Host '[verify] PASS: FMOD initialised, banks loaded, event started'
        Select-String -Path $log -Pattern '\[probe\]' | ForEach-Object { Write-Host "  $($_.Line)" }
        exit 0
    }

    $missing = Select-String -Path $log -Pattern 'NoSuchMethodError|NoSuchFieldError|Failed to register native'
    if ($missing) {
        Write-Host '[verify] NEEDS-MORE-STUBS: FMOD asked for Java members that do not exist yet'
        python tools/fmod_java_stub_sync.py $log | ForEach-Object { Write-Host "  $_" }
        Write-Host "[verify] add them with:  python tools/fmod_java_stub_sync.py $log --write"
        exit 2
    }

    Write-Host '[verify] FAIL: probe did not finish (see log)'
    Select-String -Path $log -Pattern '\[probe\]|Abort message|Fatal signal|godot.*ERROR' |
        Select-Object -Last 15 | ForEach-Object { Write-Host "  $($_.Line)" }
    exit 1
}
finally {
    if (-not $KeepLog) { }
    Pop-Location
}
