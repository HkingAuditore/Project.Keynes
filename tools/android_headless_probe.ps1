<#
.SYNOPSIS
  Unattended ProjectKeynes run on Android (emulator or a real phone), with logs captured.

.DESCRIPTION
  Loop: (optionally start emulator) -> install APK -> clear logcat -> launch
  -> wait N seconds -> dump logcat -> print key lines.

  Two APK flavours are supported:
    * emulator / logic verification: built with
        --headless --autotest-query=autotest=1&days=20&speed=3&size=40x28&seed=20260101
      --headless avoids creating a Vulkan surface (this emulator's present path is
      broken and stalls the main loop); autotest starts a game with no touch input.
    * real phone / visual verification: a normal APK (no extra args). Start the game
      by hand during the observation window; the script only installs, launches,
      captures and greps.

.EXAMPLE
  # emulator, logic run
  powershell -ExecutionPolicy Bypass -File tools\android_headless_probe.ps1 -Restart -RunSeconds 100

.EXAMPLE
  # real phone (adb devices -> <serial>), normal APK, tap through the menu yourself
  powershell -ExecutionPolicy Bypass -File tools\android_headless_probe.ps1 `
      -Serial R58M12345AB -Apk Build\ProjectKeynes.apk -RunSeconds 150
#>
[CmdletBinding()]
param(
    [string]$Apk = "D:\Godot\ProjectKeynes\Project.Keynes\Build\ProjectKeynes-emulator.apk",
    [int]$RunSeconds = 90,
    [switch]$Restart,
    [string]$Gpu = "swiftshader_indirect",
    [string]$Serial = "",
    [string]$Out = "D:\Godot\ProjectKeynes\Project.Keynes\Build\logs\android_probe.log"
)

$ErrorActionPreference = "Continue"
$adbExe = "D:\adb\adb.exe"
$emu = "$env:LOCALAPPDATA\Android\Sdk\emulator\emulator.exe"
$avd = "Pixel_3a_API_36_extension_level_17_x86_64"
$pkg = "com.projectkeynes.game"

function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    if ($Serial) { & $adbExe -s $Serial @Args } else { & $adbExe @Args }
}

function Test-Device {
    $lines = & $adbExe devices 2>$null
    if ($Serial) { return [bool]($lines | Select-String ([regex]::Escape($Serial) + "\s+device")) }
    return [bool]($lines | Select-String "emulator-\d+\s+device")
}

function Stop-Emulator {
    & $adbExe emu kill 2>$null | Out-Null
    Start-Sleep -Seconds 3
    Get-Process | Where-Object { $_.ProcessName -match "emulator|qemu" } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Get-ChildItem "$env:USERPROFILE\.android\avd\$avd.avd" -Filter "*.lock" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Start-Emulator {
    Stop-Emulator
    Start-Process -FilePath $emu -ArgumentList @(
        "-avd", $avd, "-no-snapshot", "-no-window", "-no-audio", "-no-boot-anim",
        "-gpu", $Gpu, "-memory", "4096", "-cores", "4"
    ) -WindowStyle Minimized
    Write-Host "[probe] waiting for emulator"
    for ($i = 0; $i -lt 60; $i++) {
        if (-not (Get-Process | Where-Object { $_.ProcessName -match "emulator|qemu" })) {
            Write-Host "[probe] emulator process exited during boot"
            return $false
        }
        if (Test-Device) {
            $booted = (Invoke-Adb shell getprop sys.boot_completed 2>$null) -match "1"
            if ($booted) { Write-Host "[probe] booted"; return $true }
        }
        Start-Sleep -Seconds 5
    }
    Write-Host "[probe] boot timeout"
    return $false
}

New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null

if (-not $Serial) {
    if ($Restart) {
        if (-not (Start-Emulator)) { exit 2 }
    } elseif (-not (Test-Device)) {
        if (-not (Start-Emulator)) { exit 2 }
    }
} elseif (-not (Test-Device)) {
    Write-Host "[probe] device '$Serial' is not connected (adb devices)"
    exit 2
}

if (-not (Test-Path $Apk)) {
    Write-Host "[probe] missing APK: $Apk"
    exit 3
}

# Large APKs (300-400 MB) fail intermittently with streaming `adb install`.
# Push to /data/local/tmp and run `pm install` instead: same result, far fewer
# half-written installs. `-r` keeps user data, `-t` allows the debug/test flag.
Write-Host "[probe] installing $Apk"
$remote = "/data/local/tmp/pk_probe.apk"
Invoke-Adb push $Apk $remote 2>&1 | Select-Object -Last 1
Invoke-Adb shell pm install -r -t $remote 2>&1 | Select-Object -Last 2
Invoke-Adb shell rm -f $remote 2>$null | Out-Null
Start-Sleep -Seconds 2

if (-not (Test-Device)) {
    Write-Host "[probe] device lost after install"
    exit 4
}
$updated = (Invoke-Adb shell dumpsys package $pkg 2>$null | Select-String "lastUpdateTime" | Select-Object -First 1)
Write-Host "[probe] $updated"

Write-Host "[probe] launching, observing $RunSeconds s"
Invoke-Adb logcat -c 2>$null | Out-Null
Invoke-Adb shell am force-stop $pkg 2>$null | Out-Null
Invoke-Adb shell am start -n "$pkg/com.godot.game.GodotAppLauncher" 2>&1 | Select-Object -Last 1
Start-Sleep -Seconds $RunSeconds

if (-not (Test-Device)) {
    Write-Host "[probe] device lost while running"
}

Invoke-Adb logcat -d -s godot:* 2>$null | Out-File -FilePath $Out -Encoding utf8
Write-Host "[probe] log: $Out"

$patterns = @(
    "mapgen", "audio", "mobile-ui-scaling", "heartbeat", "economy-stall",
    "graph-barrier", "autotest_pass", "autotest_ready", "SCRIPT ERROR",
    "SHADER ERROR", "FATAL"
)
Get-Content $Out -ErrorAction SilentlyContinue |
    Select-String ($patterns -join "|") |
    Select-Object -Last 40
