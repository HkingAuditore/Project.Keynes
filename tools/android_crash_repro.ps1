<#
.SYNOPSIS
  Install an APK on the connected Android device, run it until it crashes, and
  capture the debuggerd backtrace ready for symbolisation.

.DESCRIPTION
  Used while chasing the render-thread SIGSEGV:
    1. install <Apk> (push + pm install, verifies lastUpdateTime)
    2. keep the screen awake and launch the app
    3. poll until the process dies or -TimeoutSeconds elapses
    4. pull the godot logcat and the crash backtrace lines
    5. print the "#NN pc 0x..." addresses as one space-separated line, ready for
         llvm-addr2line -f -C -e <libgodot_android.so> <addresses...>

.EXAMPLE
  powershell -File tools\android_crash_repro.ps1 -Apk D:\pk\keynes-sym.apk
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Apk,
    [string]$Serial = "",
    [string]$Package = "com.projectkeynes.game",
    [int]$TimeoutSeconds = 180,
    [string]$Out = "D:\Godot\ProjectKeynes\Project.Keynes\Build\logs\crash_capture"
)

$ErrorActionPreference = "Continue"
$adbExe = "D:\adb\adb.exe"
function A { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    if ($Serial) { & $adbExe -s $Serial @Args } else { & $adbExe @Args } }

New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null

$devices = (& $adbExe devices) -join "`n"
if ($devices -notmatch "\sdevice") { Write-Host "[repro] no device attached"; exit 2 }

Write-Host "[repro] installing $Apk"
A push $Apk /data/local/tmp/repro.apk 2>&1 | Select-Object -Last 1
A shell pm install -r -t /data/local/tmp/repro.apk 2>&1 | Select-Object -Last 1
A push $Apk /data/local/tmp/repro.apk 2>&1 | Out-Null
$updated = A shell dumpsys package $Package 2>$null | Select-String "lastUpdateTime" | Select-Object -First 1
Write-Host "[repro] $updated"

A shell cmd power wakeup 2>&1 | Out-Null
A shell settings put system screen_off_timeout 1800000 2>&1 | Out-Null
A logcat -c 2>$null | Out-Null
A shell am force-stop $Package 2>$null | Out-Null
A shell am start -n "$Package/com.godot.game.GodotAppLauncher" 2>&1 | Select-Object -Last 1

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$crashed = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    A shell cmd power wakeup 2>$null | Out-Null
    $pid = (A shell pidof $Package 2>$null) -join ""
    if ([string]::IsNullOrWhiteSpace($pid)) { $crashed = $true; break }
}

$logPath = "$Out.log"
A logcat -d 2>$null | Out-File -FilePath $logPath -Encoding utf8
$godotPath = "$Out.godot.log"
A logcat -d -s godot:* 2>$null | Out-File -FilePath $godotPath -Encoding utf8

$fatal = (Get-Content $logPath | Select-String "Fatal signal" | Select-Object -First 1)
Write-Host ("[repro] died={0} fatal={1}" -f $crashed, $fatal)

# Backtrace lines look like:  #00 pc 0000000001615ab4  /data/app/.../libgodot_android.so
$addresses = @()
foreach ($line in (Get-Content $logPath | Select-String "#\d+ pc ")) {
    if ($line -match "pc\s+([0-9a-fA-F]+)") { $addresses += "0x$($Matches[1].TrimStart('0'))" }
}
if ($addresses.Count -gt 0) {
    Write-Host "[repro] addresses:"
    $addresses | Select-Object -First 12 | ForEach-Object { Write-Host "  $_" }
    Write-Host "[repro] one-liner:"
    Write-Host ("llvm-addr2line -f -C -e <libgodot_android.so> " + ($addresses -join " "))
} else {
    Write-Host "[repro] no backtrace addresses captured (app may still be running)"
}
Write-Host "[repro] logs: $logPath , $godotPath"
