# 一次性跑完 Android FMOD 验证：等设备就绪 -> 卸载旧包 -> 安装 -> 启动 -> 抓 logcat。
#
# 为什么要有它：模拟器在高负载下会短暂掉 adb / package 服务，逐条 adb 命令敲很容易
# 撞上 "Can't find service: package"，把失败误读成音频问题。这里统一重试。
#
# 用法：
#   powershell -NoProfile -File tools/android_fmod_probe.ps1 -Apk Build\ProjectKeynes-fmod-jni.apk

param(
    [string]$Apk = 'Build\ProjectKeynes-fmod-jni.apk',
    [string]$Package = 'com.projectkeynes.game',
    [string]$Activity = 'com.projectkeynes.game/com.godot.game.GodotAppLauncher',
    [int]$WaitSeconds = 75,
    [string]$LogPrefix = 'tmp\fmod_multi\probe'
)

$ErrorActionPreference = 'Continue'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { throw "adb not found: $adb" }

function Wait-Services {
    param([int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = (& $adb -s emulator-5554 get-state 2>$null) -join ''
        if ($state.Trim() -ne 'device') { Start-Sleep -Seconds 5; continue }
        $boot = (& $adb -s emulator-5554 shell getprop sys.boot_completed 2>$null) -join ''
        if ($boot.Trim() -ne '1') { Start-Sleep -Seconds 5; continue }
        $pkg = (& $adb -s emulator-5554 shell service check package 2>$null) -join ''
        if ($pkg -notmatch 'found') { Start-Sleep -Seconds 5; continue }
        return $true
    }
    return $false
}

if (-not (Wait-Services)) { throw 'emulator not ready' }
Write-Host '[probe] device ready'

& $adb -s emulator-5554 shell am force-stop $Package | Out-Null
& $adb -s emulator-5554 uninstall $Package 2>&1 | Out-Null

$install = & $adb -s emulator-5554 install -r $Apk 2>&1
$install | Where-Object { $_ -match 'Success|Failure|INSTALL_FAILED' } | ForEach-Object { Write-Host "[probe] $_" }
if (-not ($install -match 'Success')) {
    $install = & $adb -s emulator-5554 install $Apk 2>&1
    $install | Where-Object { $_ -match 'Success|Failure|INSTALL_FAILED' } | ForEach-Object { Write-Host "[probe] retry: $_" }
    if (-not ($install -match 'Success')) { throw 'install failed' }
}

& $adb -s emulator-5554 logcat -c | Out-Null
& $adb -s emulator-5554 shell "am start -n $Activity" | Out-Null
Start-Sleep -Seconds $WaitSeconds

$godot = "$LogPrefix-godot.txt"
$all = "$LogPrefix-all.txt"
& $adb -s emulator-5554 logcat -d -s godot:V > $godot 2>&1
& $adb -s emulator-5554 logcat -d > $all 2>&1

Write-Host '--- audio ---'
Select-String -Path $godot -Pattern '\[audio\]|fmod jni|bank' | Select-Object -First 12 | ForEach-Object { $_.Line }
Write-Host '--- crashes ---'
Select-String -Path $all -Pattern 'Abort message|Fatal signal' | Select-Object -First 3 | ForEach-Object { $_.Line }
Write-Host "--- logs: $godot / $all ---"
