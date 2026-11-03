<#
.SYNOPSIS
  Measure the phone's fps at each render quality tier without rebuilding.

.DESCRIPTION
  The quality tier is a persisted setting (user://settings.cfg). This script
  rewrites `render_quality` through `run-as`, restarts the autotest build, waits
  for the world heartbeat, and reports the steady-state fps per tier.

  Requires the autotest APK installed (command_line/extra_args carries
  `--autotest-query=...`), so a game starts with no touch input.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\android_quality_sweep.ps1 -Serial 84948c86
#>
[CmdletBinding()]
param(
    [string]$Serial = "",
    [string]$Package = "com.projectkeynes.game",
    [int]$WarmupSeconds = 25,
    [int]$SampleSeconds = 20,
    [string]$Out = "D:\Godot\ProjectKeynes\Project.Keynes\Build\logs\quality_sweep.log"
)

$ErrorActionPreference = "Continue"
$adbExe = "D:\adb\adb.exe"
function A { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    if ($Serial) { & $adbExe -s $Serial @Args } else { & $adbExe @Args } }

New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
"" | Out-File -FilePath $Out -Encoding utf8

$results = @()
foreach ($tier in @("low", "medium", "high")) {
    Write-Host "[sweep] tier=$tier"
    $cfg = @"
[settings]

window_mode="borderless"
resolution_width=1600
resolution_height=960
vsync=true
render_quality="$tier"
ui_scale_percent=80
reduce_motion=false
master_volume=0.8
master_muted=false
autosave_enabled=true
"@
    $tmp = Join-Path $env:TEMP "pk_sweep_settings.cfg"
    $cfg | Out-File -FilePath $tmp -Encoding ascii
    A push $tmp /data/local/tmp/pk_sweep.cfg 2>&1 | Out-Null
    A shell run-as $Package cp /data/local/tmp/pk_sweep.cfg files/settings.cfg 2>&1 | Out-Null

    # 小米会自己息屏；锁屏时 Godot 拿不到 Vulkan 表面，应用根本起不来。
    # `cmd power wakeup` 是 shell 命令，不受 INJECT_EVENTS 限制（input keyevent 会被拦）。
    A shell cmd power wakeup 2>&1 | Out-Null
    A shell wm dismiss-keyguard 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    A logcat -c 2>$null | Out-Null
    A shell am force-stop $Package 2>$null | Out-Null
    A shell am start -n "$Package/com.godot.game.GodotAppLauncher" 2>&1 | Out-Null
    Start-Sleep -Seconds $WarmupSeconds
    A logcat -d -s godot:* 2>$null | Out-File -FilePath (Join-Path $env:TEMP "pk_sweep_run.log") -Encoding utf8
    $first = (Get-Content (Join-Path $env:TEMP "pk_sweep_run.log") | Select-String 'heartbeat' | Measure-Object).Count
    Start-Sleep -Seconds $SampleSeconds
    A logcat -d -s godot:* 2>$null | Out-File -FilePath (Join-Path $env:TEMP "pk_sweep_run.log") -Encoding utf8

    $fps = @()
    foreach ($line in (Get-Content (Join-Path $env:TEMP "pk_sweep_run.log") | Select-String 'heartbeat' |
            Select-Object -Last 6)) {
        if ($line -match 'fps=([0-9.]+)') { $fps += [double]$Matches[1] }
    }
    $avg = if ($fps.Count -gt 0) { [math]::Round(($fps | Measure-Object -Average).Average, 1) } else { 0 }
    $results += [pscustomobject]@{ tier = $tier; fps_avg = $avg; samples = $fps.Count }
    "[sweep] tier=$tier fps=$avg (n=$($fps.Count))" | Out-File -FilePath $Out -Append -Encoding utf8
    Write-Host "[sweep] tier=$tier fps=$avg"
}

$results | Format-Table -AutoSize
