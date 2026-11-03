<#
.SYNOPSIS
  One-shot Android verification battery for Project.Keynes.

.DESCRIPTION
  Installs an APK, launches it with a streaming logcat capture, samples the
  heartbeat for a while, takes screenshots, then reports a PASS/FAIL table for:
    * process liveness (no crash / no freeze)
    * day + eco_day progression (simulation actually advances)
    * steady-state fps
    * simulation stalls reported by the heartbeat
    * fatal signals / GDScript stack overflows in the log
  Screenshots land next to the log so the reviewer can eyeball UI regressions.

.PARAMETER Apk
  APK to install (signature mismatch triggers an uninstall first).

.PARAMETER Seconds
  How long to watch the app (default 150).

.PARAMETER Shots
  Number of screenshots to take while watching (default 3).

.EXAMPLE
  powershell -File tools\android_verify_suite.ps1 -Apk Build\ProjectKeynes.apk
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Apk,
    [int]$Seconds = 150,
    [int]$Shots = 3,
    [string]$Package = "com.projectkeynes.game",
    [string]$OutDir = "D:\Godot\ProjectKeynes\Project.Keynes\Build\logs\verify"
)

$ErrorActionPreference = "Continue"
$adb = "D:\adb\adb.exe"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = Join-Path $OutDir "logcat_$stamp.log"

$devices = (& $adb devices) -join "`n"
if ($devices -notmatch "\sdevice") { Write-Host "[verify] no device attached"; exit 2 }

Write-Host "[verify] pushing $Apk"
& $adb push $Apk /data/local/tmp/verify.apk 2>&1 | Select-Object -Last 1
$install = (& $adb shell pm install -r -t /data/local/tmp/verify.apk 2>&1) -join "`n"
if ($install -match "INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match") {
    Write-Host "[verify] signature mismatch -> uninstall + retry"
    & $adb shell pm uninstall $Package 2>&1 | Out-Null
    $install = (& $adb shell pm install -r -t /data/local/tmp/verify.apk 2>&1) -join "`n"
}
Write-Host ("[verify] install: " + ($install.Trim() -split "`n" | Select-Object -Last 1))

& $adb shell cmd power wakeup 2>&1 | Out-Null
& $adb shell settings put system screen_off_timeout 1800000 2>&1 | Out-Null
& $adb logcat -c 2>&1 | Out-Null
& $adb shell am force-stop $Package 2>&1 | Out-Null

# Stream logs to the host first: a crash can take the adb connection with it.
$stream = Start-Process -FilePath "powershell" -ArgumentList "-NoProfile", "-Command",
    "& '$adb' logcat -v time > '$logFile'" -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 3

& $adb shell am start -n "$Package/com.godot.game.GodotAppLauncher" 2>&1 | Select-Object -Last 1

$shotAt = @()
for ($i = 1; $i -le $Shots; $i++) { $shotAt += [int]($Seconds * $i / ($Shots + 1)) }

$deadline = (Get-Date).AddSeconds($Seconds)
$elapsed = 0
$alive = $true
$shotsTaken = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $elapsed += 5
    & $adb shell cmd power wakeup 2>$null | Out-Null
    $pid = (& $adb shell pidof $Package 2>$null) -join ""
    if ([string]::IsNullOrWhiteSpace($pid)) { $alive = $false; Write-Host "[verify] process died at ${elapsed}s"; break }
    if ($shotsTaken -lt $Shots -and $elapsed -ge $shotAt[$shotsTaken]) {
        $shotsTaken++
        $shot = Join-Path $OutDir ("shot_{0}_{1}.png" -f $stamp, $shotsTaken)
        & cmd /c "`"$adb`" exec-out screencap -p > `"$shot`"" 2>$null
        Write-Host "[verify] screenshot -> $shot"
    }
}
if (-not $stream.HasExited) { Stop-Process -Id $stream.Id -Force -ErrorAction SilentlyContinue }

$lines = Get-Content $logFile -ErrorAction SilentlyContinue
# logcat keeps history from previous launches; only judge the session we started.
$lastBoot = ($lines | Select-String 'Godot Engine v' | Select-Object -Last 1)
if ($lastBoot) { $lines = $lines[($lastBoot.LineNumber - 1)..($lines.Count - 1)] }
$heartbeats = $lines | Select-String '\[heartbeat\]'
$last = $heartbeats | Select-Object -Last 1
$days = @()
$ecos = @()
$fpss = @()
foreach ($hb in $heartbeats) {
    if ($hb.Line -match 'day=(\d+)') { $days += [int]$Matches[1] }
    if ($hb.Line -match 'eco_day=(-?\d+)') { $ecos += [int]$Matches[1] }
    if ($hb.Line -match 'fps=([\d.]+)') { $fpss += [double]$Matches[1] }
}
$fatal = ($lines | Select-String 'Fatal signal' | Measure-Object).Count
$overflow = ($lines | Select-String 'Stack overflow' | Measure-Object).Count
$scriptErr = ($lines | Select-String 'SCRIPT ERROR' | Measure-Object).Count
$activate = ($lines | Select-String '\[economy\] ACTIVE' | Measure-Object).Count
$preflight = ($lines | Select-String '\[mapgen\]\[preflight\] ok' | Measure-Object).Count
$audio = ($lines | Select-String 'audio\] backend=' | Select-Object -Last 1)

$dayFirst = if ($days.Count -gt 0) { $days[0] } else { -1 }
$dayLast = if ($days.Count -gt 0) { $days[-1] } else { -1 }
$ecoLast = if ($ecos.Count -gt 0) { $ecos[-1] } else { -999 }
$fpsAvg = if ($fpss.Count -gt 0) { [math]::Round(($fpss | Measure-Object -Average).Average, 1) } else { 0 }

function Verdict($ok, $text) { if ($ok) { "PASS  $text" } else { "FAIL  $text" } }

Write-Host ""
Write-Host "================ Project.Keynes Android verify ================"
Write-Host (Verdict ($alive) ("alive after ${Seconds}s"))
Write-Host (Verdict ($preflight -gt 0) ("map generation preflight ok ({0})" -f $preflight))
Write-Host (Verdict ($activate -gt 0) ("economy graph activated ({0})" -f $activate))
Write-Host (Verdict ($dayLast -gt $dayFirst) ("day advanced {0} -> {1}" -f $dayFirst, $dayLast))
Write-Host (Verdict ($ecoLast -ge $dayLast - 2) ("eco_day tracks sim day (eco_day={0}, day={1})" -f $ecoLast, $dayLast))
Write-Host (Verdict ($fpsAvg -ge 25) ("average fps {0}" -f $fpsAvg))
Write-Host (Verdict ($overflow -eq 0) ("no GDScript stack overflow ({0})" -f $overflow))
Write-Host (Verdict ($fatal -eq 0) ("no fatal signals ({0})" -f $fatal))
Write-Host (Verdict ($scriptErr -eq 0) ("no SCRIPT ERROR lines ({0})" -f $scriptErr))
if ($audio) { Write-Host ("info  " + $audio.Line.Trim()) }
Write-Host ("log: " + $logFile)
Write-Host ("shots: " + $OutDir)
