# Web 专用导出路径：让 FMOD 的 HTML5 side module 真正生效。
#
# 为什么 web 要单独一条路：
#   浏览器里运行期 GDExtensionManager.load_extension() 会同步等待异步 fetch，
#   主线程直接死锁（控制台那条 "Blocking on the main thread is very dangerous"）。
#   Web 必须让引擎在启动时自动加载扩展，而 `.godot/extension_list.cfg` 只收录
#   **没有** `.gdignore` 的 .gdextension。因此本脚本：
#     1. 临时移除 addon 的 .gdignore
#     2. 让 Godot 重新扫一遍（--import），extension_list 里就会出现
#        addons/0_fmod_bootstrap → addons/dots_ext → addons/FmodGodot（顺序由路径排序决定）
#     3. 导出 Web
#     4. 恢复 .gdignore 并再 import 一次，把工程状态还原（Android/Windows 仍走显式加载）
#
# ⚠️ 本脚本**只**做 import + export，不含任何体积优化。
#   Build-Web.cmd 的六步（字体子集 / 贴图降质 / bank 降质 / 边车预压缩 / manifest /
#   音乐分包）它一步都不跑。同一份代码实测：本路径 345 MB，Build-Web.cmd 88 MB。
#   要出可发布的包请用 `Build-Web.cmd`；本脚本保留给"只想快速看一眼 web 能不能起"。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\export_web_with_fmod.ps1
#   ... -Out WebBuild\ProjectKeynes.html -SkipImport
#
# 拆开的两个阶段（Build-Web.cmd 用，导出命令仍由 cmd 自己掌控）：
#   ... -EnableOnly     只挂 FmodGodot（移 .gdignore + import + 校验），不还原
#   ... -RestoreOnly    只还原 .gdignore（+ import）
#   调用方必须在**成功和失败两条路径**上都跑一次 -RestoreOnly；状态记在
#   tmp\web_fmod_export_state.json 里，重复调用是幂等的。

param(
    [string]$GodotExe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe',
    [string]$Out = 'WebBuild\ProjectKeynes.html',
    [switch]$SkipImport,
    [switch]$EnableOnly,
    [switch]$RestoreOnly
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Push-Location $root

$projectPath = (Resolve-Path 'Project\project-keynes').Path
$stateDir = Join-Path $root 'tmp'
$statePath = Join-Path $stateDir 'web_fmod_export_state.json'
# extension_list.cfg 必须一起备份：`godot --import` 只会往里**追加**条目，不会因为
# .gdignore 回来了就把它们删掉。不还原的话，桌面/编辑器下次启动会去加载只有 web
# 才需要的 0_fmod_bootstrap（它在 Windows 上根本没有库文件），每次启动刷一串 ERROR。
$listPath = Join-Path $projectPath '.godot\extension_list.cfg'
$listBackup = Join-Path $stateDir 'web_fmod_extension_list.bak'
# 默认清单：EnableOnly 找不到状态文件时用它兜底（顺序无关，只用来重建 .gdignore）。
$defaultAddons = @(
    'Project\project-keynes\addons\FmodGodot',
    'Project\project-keynes\addons\0_fmod_bootstrap'
)

function Read-State {
    if (-not (Test-Path $statePath)) { return $null }
    try { return (Get-Content $statePath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-State([string[]]$removed) {
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    @{ removed = @($removed) } | ConvertTo-Json -Depth 3 | Set-Content -Path $statePath -Encoding utf8
}

function Invoke-Import {
    if ($SkipImport) {
        Write-Host '[web] (skip import)'
        return
    }
    Write-Host '[web] reimport so extension_list.cfg picks up the addons'
    & $GodotExe --headless --path $projectPath --import 2>&1 |
        Select-String -Pattern 'DONE \] reimport|ERROR: Failed' | Select-Object -Last 3 |
        ForEach-Object { Write-Host "  $($_.Line)" }
}

function Enable-FmodForWeb {
    $removed = @()
    foreach ($addon in $defaultAddons) {
        $flag = Join-Path $addon '.gdignore'
        if (Test-Path $flag) {
            Remove-Item -Force $flag
            $removed += $flag
            Write-Host "[web] removed $flag"
        }
    }
    Write-State $removed
    if (Test-Path $listPath) {
        Copy-Item -LiteralPath $listPath -Destination $listBackup -Force
    }

    Invoke-Import

    $listPath = Join-Path $projectPath '.godot\extension_list.cfg'
    if (-not (Test-Path $listPath)) {
        throw "extension_list.cfg missing at $listPath"
    }
    Write-Host '[web] extension_list.cfg:'
    Get-Content $listPath | ForEach-Object { Write-Host "  $_" }
    $list = Get-Content $listPath -Raw
    if ($list -notmatch 'FmodGodot\.gdextension') {
        throw 'FmodGodot is missing from extension_list.cfg - the import step did not pick it up'
    }
}

function Restore-FmodState {
    $state = Read-State
    $flags = @()
    if ($state -and $state.removed) { $flags = @($state.removed) }
    else {
        # 没有状态文件：说明从没 EnableOnly 过，或者状态被删了。
        # 兜底把清单里的 .gdignore 补回来（它们本来就是零字节标记文件）。
        $flags = @($defaultAddons | ForEach-Object { Join-Path $_ '.gdignore' })
        Write-Host '[web] no state file; falling back to the default .gdignore set'
    }
    $touched = 0
    foreach ($flag in $flags) {
        if (-not (Test-Path $flag)) {
            $parent = Split-Path $flag -Parent
            if (Test-Path $parent) {
                New-Item -ItemType File -Force -Path $flag | Out-Null
                $touched++
            }
        }
    }

    # 先把 extension_list 换回导出前的样子**再** import，否则这次 import 又会把
    # 刚摘掉的扩展写回去。
    $listRestored = $false
    if (Test-Path $listBackup) {
        Copy-Item -LiteralPath $listBackup -Destination $listPath -Force
        Remove-Item -Force $listBackup
        $listRestored = $true
        Write-Host '[web] extension_list.cfg restored'
    }

    if (Test-Path $statePath) { Remove-Item -Force $statePath }
    if ($touched -gt 0) {
        if ($listRestored) {
            # 清单已经是导出前那份了，再 import 一次反而会把它写回去。
            Write-Host '[web] .gdignore restored; extension_list.cfg pinned, skipping import'
        }
        else {
            Invoke-Import
        }
    }
    Write-Host "[web] restored $touched .gdignore flag(s)"
}

try {
    if ($RestoreOnly) {
        # 只还原，不碰导出；finally 里不再重复还原一次。
        $script:enabledHere = $false
        Restore-FmodState
        Write-Host '[web] FmodGodot unregistered (restore-only)'
        return
    }

    # 先置位再 Enable：万一 Enable 中途抛错（.gdignore 已删、import 失败），
    # finally 仍然会走还原，不会把工程留在"扩展已挂但没导出"的状态。
    $script:enabledHere = $true
    Enable-FmodForWeb

    if ($EnableOnly) {
        Write-Host '[web] FmodGodot registered. Caller must run -RestoreOnly when done.'
        return
    }

    Write-Host ''
    Write-Host '[web] ============================================================'
    Write-Host '[web] NOTE: this path does NO size optimization.'
    Write-Host '[web]   missing: font subset / texture downgrade / bank downgrade /'
    Write-Host '[web]            precompressed sidecars / manifest / music split'
    Write-Host '[web]   measured: this path 345 MB, Build-Web.cmd 88 MB (same code)'
    Write-Host '[web]   for a shippable package use: Build-Web.cmd'
    Write-Host '[web] ============================================================'
    Write-Host ''

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
    if ($script:enabledHere -and -not $EnableOnly) {
        Restore-FmodState
    }
    Pop-Location
}
