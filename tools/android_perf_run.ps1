<#
.SYNOPSIS
  Unattended Project.Keynes performance run on a real Android phone.

.DESCRIPTION
  Drives one measurement window end to end:
    1. writes user://pk_debug.cfg ( [autotest] query + [perf] record [+ [render] overrides] ),
    2. clears logcat and streams it to <OutDir>\logcat.txt,
    3. launches the app (autotest opens the game without touching the screen),
    4. samples per-thread CPU / memory / thermal / battery every few seconds,
    5. waits for the in-app PerfRecorder to export its CSV
       (`[perf-record][autotest] done ... path=...`),
    6. pulls the CSV plus dumpsys snapshots into <OutDir>.

  The CSV schema is the same perf_record_*.csv the GM panel and
  tests/game/headless_perf_record.gd produce, so device numbers stay comparable
  with desktop / headless runs.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\android_perf_run.ps1 -Label baseline_1x
#>
[CmdletBinding()]
param(
    [string]$Serial = "",
    [string]$Query = "autotest=1&days=12&speed=1&size=40x28&seed=20260101",
    [string]$PerfMode = "DETAIL",
    [int]$PerfDetailTicks = 15,
    [int]$PerfSampleEvery = 1,
    [double]$PerfDelayS = 0.0,
    [double]$PerfWindowS = 0.0,
    [string]$RenderOverrides = "",
    [string]$Label = "run",
    [int]$TimeoutSeconds = 480,
    [int]$SamplePeriodSeconds = 5,
    [int]$MaxBatteryTempC = 43,
    [switch]$RenderSweep,
    [switch]$FreezeClock,
    [string]$SweepMode = "hide",
    [int]$MaxFps = -1,
    [switch]$NoVsync,
    [double]$SweepStepS = 10,
    [switch]$IgnoreThermalGuard,
    [string]$OutDir = "",
    [switch]$KeepRunning,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Continue"

$repo = Split-Path -Parent $PSScriptRoot
$pkg = "com.projectkeynes.game"
$adb = "D:\adb\adb.exe"
if (-not (Test-Path $adb)) {
    $found = Get-Command adb -ErrorAction SilentlyContinue
    if ($found) { $adb = $found.Source } else { throw "adb not found (checked D:\adb\adb.exe and PATH)" }
}

function Resolve-Serial {
    if ($Serial) { return $Serial }
    if ($env:ANDROID_SERIAL) { return $env:ANDROID_SERIAL }
    $lines = & $adb devices 2>$null | Select-Object -Skip 1
    $ready = @($lines | Where-Object { $_ -match "\s+device$" })
    if ($ready.Count -eq 0) { throw "No ready Android device." }
    if ($ready.Count -gt 1) { throw "More than one device; pass -Serial." }
    return ($ready[0] -split "\s+")[0]
}

function Invoke-Shell {
    param([string]$Command)
    & $adb -s $script:device shell $Command 2>&1
}

$device = Resolve-Serial
Write-Host "adb      : $adb"
Write-Host "device   : $device"

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
if (-not $OutDir) { $OutDir = Join-Path $repo "artifacts\perf_android_${stamp}_$Label" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Write-Host "out dir  : $OutDir"

$logFile = Join-Path $OutDir "logcat.txt"
$samplesFile = Join-Path $OutDir "samples.log"
$metaFile = Join-Path $OutDir "run_meta.json"
$shotDir = Join-Path $OutDir "screenshots"
New-Item -ItemType Directory -Force -Path $shotDir | Out-Null
Set-Content -Path $samplesFile -Value "# samples for $Label" -Encoding utf8

function Add-Sample {
    param([string]$Text)
    Add-Content -Path $samplesFile -Encoding utf8 -Value ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text)
}

function Save-Dump {
    param([string]$Command, [string]$Name)
    $target = Join-Path $OutDir $Name
    & $adb -s $device shell $Command 2>&1 | Set-Content -Path $target -Encoding utf8
}

# ── 1. device prep ─────────────────────────────────────────────────────────
Invoke-Shell "input keyevent KEYCODE_WAKEUP" | Out-Null
Invoke-Shell "wm dismiss-keyguard" | Out-Null
Invoke-Shell "svc power stayon true" | Out-Null
Add-Sample ("screen: " + ((Invoke-Shell "dumpsys power | grep -m1 mWakefulness=") -join ""))

# 热保护：连续满负载跑真机会把电池顶到 50°C+。默认超过 43°C 直接拒绝开跑，
# 让机器先凉下来；真要跑用 -IgnoreThermalGuard 并自己盯温度。
function Get-BatteryTempC {
    $raw = (Invoke-Shell "dumpsys battery | grep -m1 temperature") -join ""
    $match = [regex]::Match($raw, "temperature:\s*(\d+)")
    if ($match.Success) { return [math]::Round([int]$match.Groups[1].Value / 10.0, 1) }
    return $null
}

$tempC = Get-BatteryTempC
Add-Sample "battery temp before run: $tempC C"
if ($null -ne $tempC -and $tempC -gt $MaxBatteryTempC -and -not $IgnoreThermalGuard) {
    throw ("设备电池温度 {0}°C 已超过阈值 {1}°C，拒绝开跑。先让手机冷却（熄屏 5-10 分钟、不要充电），" +
        "或显式传 -IgnoreThermalGuard。") -f $tempC, $MaxBatteryTempC
}

# ── 2. user://pk_debug.cfg ────────────────────────────────────────────────
$cfgLines = @(
    "[autotest]",
    ('query="{0}"' -f $Query),
    "",
    "[perf]",
    "record=1",
    ('mode="{0}"' -f $PerfMode),
    "detail_ticks=$PerfDetailTicks",
    "sample_every=$PerfSampleEvery",
    "delay_s=$($PerfDelayS.ToString([System.Globalization.CultureInfo]::InvariantCulture))",
    "window_s=$($PerfWindowS.ToString([System.Globalization.CultureInfo]::InvariantCulture))",
    "suppress_popups=1",
    "render_trace=1",
    "render_sweep=$([int][bool]$RenderSweep)",
    "freeze_clock=$([int][bool]$FreezeClock)",
    ('sweep_mode="{0}"' -f $SweepMode),
    "max_fps=$MaxFps",
    "vsync=$(if ($NoVsync) { 0 } else { -1 })",
    "sweep_step_s=$($SweepStepS.ToString([System.Globalization.CultureInfo]::InvariantCulture))",
    "sweep_settle_s=2.5",
    ('render_csv="render_trace_{0}.csv"' -f $Label),
    ('csv="perf_{0}.csv"' -f $Label)
)
if ($RenderOverrides) {
    $cfgLines += @("", "[render]")
    foreach ($pair in ($RenderOverrides -split "[;,]")) {
        $kv = $pair.Trim()
        if (-not $kv) { continue }
        $idx = $kv.IndexOf("=")
        if ($idx -lt 0) { $cfgLines += $kv; continue }
        $key = $kv.Substring(0, $idx).Trim()
        $value = $kv.Substring($idx + 1).Trim().Trim('"')
        # ConfigFile 的值按 Variant 解析：数字/布尔直接写，其余必须带引号。
        if ($value -match '^-?\d+(\.\d+)?$' -or $value -match '^(true|false)$') {
            $cfgLines += "$key=$value"
        } else {
            $cfgLines += ('{0}="{1}"' -f $key, $value)
        }
    }
}
$cfgLocal = Join-Path $OutDir "pk_debug.cfg"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($cfgLocal, (($cfgLines -join "`r`n") + "`r`n"), $utf8NoBom)
& $adb -s $device push $cfgLocal "/data/local/tmp/pk_debug.cfg" 2>&1 | Out-Null
Invoke-Shell "run-as $pkg cp /data/local/tmp/pk_debug.cfg files/pk_debug.cfg" | Out-Null
Add-Sample ("cfg: " + ((Invoke-Shell "run-as $pkg cat files/pk_debug.cfg") -join " / "))

# 干净起跑线：先清掉旧 CSV，避免把上一轮产物当本轮。
Invoke-Shell "run-as $pkg rm -rf files/perf" | Out-Null

# ── 3. logcat stream ───────────────────────────────────────────────────────
Invoke-Shell "logcat -c" | Out-Null
$logcatProc = Start-Process -FilePath $adb -ArgumentList @("-s", $device, "logcat", "-v", "time") `
    -RedirectStandardOutput $logFile -NoNewWindow -PassThru
Add-Sample "logcat pid=$($logcatProc.Id) -> $logFile"

function Get-LogText {
    if (-not (Test-Path $logFile)) { return "" }
    try {
        $fs = [System.IO.File]::Open($logFile, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs)
        $text = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        return $text
    } catch { return "" }
}

# ── 4. launch ──────────────────────────────────────────────────────────────
$startedAt = Get-Date
if (-not $NoLaunch) {
    Invoke-Shell "am force-stop $pkg" | Out-Null
    Start-Sleep -Milliseconds 800
    Invoke-Shell "monkey -p $pkg -c android.intent.category.LAUNCHER 1" | Out-Null
}
Add-Sample "launch sent"

# ── 5. sampling loop ───────────────────────────────────────────────────────
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$done = $false
$doneReason = ""
$sampleIdx = 0
$perfDone = $false
$perfDoneAt = $null
$sawReady = $false
$script:readySamples = 0
$shotTaken = @()

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $SamplePeriodSeconds
    $sampleIdx++

    $pidText = (Invoke-Shell "pidof $pkg") -join ""
    $procId = ($pidText -replace "[^0-9]", "")
    if (-not $procId) {
        $done = $true; $doneReason = "process_gone"
        Add-Sample "process gone"
        break
    }

    $log = Get-LogText
    if (-not $sawReady -and $log -match "\[autotest\] autotest_ready") { $sawReady = $true }
    if (-not $perfDone -and $log -match "\[perf-record\]\[autotest\] done") { $perfDone = $true }
    $passed = $log -match "\[autotest\] autotest_pass"
    $failed = $log -match "\[autotest\] autotest_fail"
    $crashed = $log -match "Fatal signal|FATAL EXCEPTION"

    # CPU：process 级 + 线程级各一行，线程名带出 VkThread/WorkerThread。
    $top = (Invoke-Shell "top -H -b -n 1 -p $procId") -join "`n"
    Add-Sample ("cpu sample #$sampleIdx`n" + $top)

    if ($sampleIdx -eq 2 -or $sampleIdx -eq 6 -or $sampleIdx -eq 10) {
        Add-Sample ("mem `n" + (((Invoke-Shell "dumpsys meminfo $pkg") | Select-String "TOTAL|Native Heap|Graphics|Java Heap") -join "`n"))
    }
    if ($sampleIdx -eq 2 -or $sampleIdx -eq 6 -or $sampleIdx -eq 10) {
        Add-Sample ("thermal `n" + (((Invoke-Shell "dumpsys thermalservice") | Select-String "Temperature|mStatus|mThermalStatus|Current temperatures") -join "`n"))
    }
    $readySamples = if ($sawReady) { $script:readySamples = $script:readySamples + 1; $script:readySamples } else { 0 }
    if (($readySamples -eq 2 -or $readySamples -eq 6) -and $shotTaken.Count -lt 2) {
        $shotName = "shot_ready_{0}s.png" -f ($readySamples * $SamplePeriodSeconds)
        $remote = "/sdcard/pk_perf_shot.png"
        Invoke-Shell "screencap -p $remote" | Out-Null
        & $adb -s $device pull $remote (Join-Path $shotDir $shotName) 2>&1 | Out-Null
        Invoke-Shell "rm $remote" | Out-Null
        $shotTaken += $shotName
    }

    $loopTemp = Get-BatteryTempC
    if ($null -ne $loopTemp -and $loopTemp -gt ($MaxBatteryTempC + 2) -and -not $IgnoreThermalGuard) {
        $done = $true; $doneReason = "thermal_guard"
        Add-Sample "thermal guard tripped at $loopTemp C -- stopping load"
        break
    }

    if ($crashed) { $done = $true; $doneReason = "crash_in_log"; Add-Sample "crash marker in log"; break }
    if ($failed) { $done = $true; $doneReason = "autotest_fail"; Add-Sample "autotest_fail"; break }
    if ($perfDone -and $passed) { $done = $true; $doneReason = "pass+perf_export"; break }
    if ($perfDone) {
        if ($null -eq $perfDoneAt) { $perfDoneAt = Get-Date }
        elseif (((Get-Date) - $perfDoneAt).TotalSeconds -gt 5) {
            # CSV 已落盘但 pass 还没到（目标日比录制窗口大）：再等 20s 就收尾。
            $done = $true; $doneReason = "perf_export_grace"; break
        }
    }
}

$finishedAt = Get-Date
if (-not $done) { $doneReason = "timeout" }
Add-Sample "done: $doneReason"

# ── 6. final dumps + CSV pull ─────────────────────────────────────────────
Start-Sleep -Seconds 2
if ($logcatProc -and -not $logcatProc.HasExited) { Stop-Process -Id $logcatProc.Id -Force -ErrorAction SilentlyContinue }

Save-Dump "dumpsys meminfo $pkg" "meminfo_end.txt"
Save-Dump "dumpsys thermalservice" "thermalservice_end.txt"
Save-Dump "dumpsys battery" "battery_end.txt"
Save-Dump "dumpsys gfxinfo $pkg" "gfxinfo_end.txt"
Save-Dump "getprop ro.product.model" "device_model.txt"

# run-as 是应用 UID，写不了 /data/local/tmp，所以不能 cp 出去再 pull。
# 用 exec-out 把 stdout 直接接管成 .NET 进程（按 UTF-8 解码后原样落盘），
# 避免 PowerShell 管道把 CSV 文本重新编码成 UTF-16。
$pulledCsv = @()
$listing = @(Invoke-Shell "run-as $pkg ls files/perf" | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match "\.csv$" })
foreach ($name in $listing) {
    $local = Join-Path $OutDir $name
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $adb
    $psi.Arguments = "-s $device exec-out run-as $pkg cat files/perf/$name"
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $payload = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    [System.IO.File]::WriteAllText($local, $payload, $utf8NoBom)
    if (Test-Path $local) { $pulledCsv += $local }
}
Add-Sample ("csv pulled: " + (($pulledCsv | ForEach-Object { $_ }) -join ", "))

$log = Get-LogText
$heartbeats = @($log -split "`r?`n" | Where-Object { $_ -match "\[heartbeat\]" })
$rateLines = @($log -split "`r?`n" | Where-Object { $_ -match "\[clock/rate\]|\[clock/step\]" })
$shaderErrors = @($log -split "`r?`n" | Where-Object { $_ -match "SHADER ERROR" }).Count
$scriptErrors = @($log -split "`r?`n" | Where-Object { $_ -match "SCRIPT ERROR" }).Count

$meta = [ordered]@{
    label = $Label
    query = $Query
    perf_mode = $PerfMode
    perf_detail_ticks = $PerfDetailTicks
    perf_sample_every = $PerfSampleEvery
    perf_delay_s = $PerfDelayS
    perf_window_s = $PerfWindowS
    render_sweep = [bool]$RenderSweep
    sweep_mode = $SweepMode
    max_fps = $MaxFps
    vsync_disabled = [bool]$NoVsync
    sweep_step_s = $SweepStepS
    render_overrides = $RenderOverrides
    device = $device
    started_at = $startedAt.ToString("o")
    finished_at = $finishedAt.ToString("o")
    wall_seconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 2)
    done_reason = $doneReason
    perf_exported = $perfDone
    autotest_ready = $sawReady
    csv_files = $pulledCsv
    logcat = $logFile
    samples = $samplesFile
    screenshots = $shotTaken
    heartbeat_lines = $heartbeats.Count
    heartbeat_tail = @($heartbeats | Select-Object -Last 5)
    rate_tail = @($rateLines | Select-Object -Last 5)
    shader_errors = $shaderErrors
    script_errors = $scriptErrors
}
$meta | ConvertTo-Json -Depth 6 | Set-Content -Path $metaFile -Encoding utf8

Write-Host ""
Write-Host "=== run summary: $Label ==="
Write-Host ("done_reason   : {0}  (wall {1:N1}s)" -f $doneReason, ($finishedAt - $startedAt).TotalSeconds)
Write-Host ("perf exported : {0}" -f $perfDone)
Write-Host ("csv           : {0}" -f (($pulledCsv) -join ", "))
Write-Host ("screenshots   : {0}" -f (($shotTaken) -join ", "))
Write-Host ("shader errors : {0}   script errors: {1}" -f $shaderErrors, $scriptErrors)
Write-Host "heartbeat tail:"
$heartbeats | Select-Object -Last 4 | ForEach-Object { Write-Host ("  " + $_) }
Write-Host "rate tail:"
$rateLines | Select-Object -Last 4 | ForEach-Object { Write-Host ("  " + $_) }
if (-not $KeepRunning) {
    # 收尾必须停应用：跑完还让它满帧跑，手机会一直发热（本轮就是这么把电池顶到 42°C 的）。
    Invoke-Shell "am force-stop $pkg" | Out-Null
    Add-Sample "app force-stopped after run"
    Write-Host "app stopped   : yes (-KeepRunning to skip)"
}
Write-Host ("out dir       : {0}" -f $OutDir)
