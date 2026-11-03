# Web 专用导出路径：让 FMOD 的 HTML5 side module 真正生效。
#
# 为什么 web 要单独一条路：
#   浏览器里运行期 GDExtensionManager.load_extension() 会同步等待异步 fetch，
#   主线程直接死锁（控制台那条 "Blocking on the main thread is very dangerous"）。
#   Web 必须让引擎在启动时自动加载扩展，而 `.godot/extension_list.cfg` 只收录
#   **没有** `.gdignore` 的 .gdextension。因此本脚本：
#     1. 临时移除两个 addon 的 .gdignore
#     2. 让 Godot 重新扫一遍（--import），extension_list 里就会出现
#        addons/0_fmod_bootstrap → addons/dots_ext → addons/FmodGodot（顺序由路径排序决定）
#     3. 导出 Web
#     4. 恢复 .gdignore 并再 import 一次，把工程状态还原（Android/Windows 仍走显式加载）
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\export_web_with_fmod.ps1
#   ... -Out WebBuild\ProjectKeynes.html -SkipImport

param(
    [string]$GodotExe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe',
    [string]$Out = 'WebBuild\ProjectKeynes.html',
    [switch]$SkipImport
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Push-Location $root
$addons = @('Project\project-keynes\addons\FmodGodot')
$saved = @()
try {
    foreach ($addon in $addons) {
        $flag = Join-Path $addon '.gdignore'
        if (Test-Path $flag) {
            $saved += $flag
            Remove-Item -Force $flag
            Write-Host "[web] removed $flag"
        }
    }

    $projectPath = (Resolve-Path 'Project\project-keynes').Path
    if (-not $SkipImport) {
        Write-Host '[web] reimport so extension_list.cfg picks up the addons'
        & $GodotExe --headless --path $projectPath --import 2>&1 |
            Select-String -Pattern 'DONE \] reimport|ERROR: Failed' | Select-Object -Last 3 | ForEach-Object { Write-Host "  $($_.Line)" }
    }

    $listPath = Join-Path $projectPath '.godot\extension_list.cfg'
    Write-Host '[web] extension_list.cfg:'
    Get-Content $listPath | ForEach-Object { Write-Host "  $_" }
    $list = Get-Content $listPath -Raw
    if ($list -notmatch 'FmodGodot\.gdextension') {
        throw 'FmodGodot is missing from extension_list.cfg - the import step did not pick it up'
    }

    Write-Host '[web] exporting'
    $outPath = Join-Path (Resolve-Path .).Path $Out
    & $GodotExe --headless --path $projectPath --export-release 'Web' $outPath 2>&1 |
        Select-String -Pattern 'export\]|failed' | Select-Object -Last 3 | ForEach-Object { Write-Host "  $($_.Line)" }
    if (-not (Test-Path $outPath)) { throw "export produced nothing: $outPath" }

    $wasm = Get-ChildItem (Split-Path $outPath) -Filter 'libFmodGodot*wasm*' -ErrorAction SilentlyContinue
    if (-not $wasm) { Write-Host '[web] WARNING: no libFmodGodot wasm next to the html' }
    else { $wasm | ForEach-Object { Write-Host "[web] side module: $($_.Name) $([math]::Round($_.Length/1MB,2)) MB" } }
    Write-Host "[web] ready: $outPath"
}
finally {
    foreach ($flag in $saved) {
        if (-not (Test-Path $flag)) { New-Item -ItemType File -Force -Path $flag | Out-Null }
    }
    if ($saved.Count -gt 0 -and -not $SkipImport) {
        $projectPath = (Resolve-Path 'Project\project-keynes').Path
        & $GodotExe --headless --path $projectPath --import 2>&1 | Out-Null
        Write-Host '[web] restored .gdignore and reimported'
    }
    Pop-Location
}
