#Requires -Version 5.1
<#
.SYNOPSIS
    一条命令把克隆下来的仓库构建到可以跑起来的状态。

.DESCRIPTION
    这个仓库不带任何编译产物（dots_ext 的 .dll/.so/.wasm、FmodGodot 的原生库、
    FMOD 的 .bank 全部不进库），所以 clone 下来必须本地构建一次。

    脚本按依赖顺序做六件事，每一步失败都会告诉你怎么修，而不是抛堆栈：

      1. 前置检查       git / python / scons / Godot / Emscripten / FMOD SDK
      2. 子模块         git submodule update --init --recursive（godot-cpp）
      3. dots_ext       scons 编 GDExtension（windows / android / web）
      4. FMOD           web 从源码编；windows/android 检测上游预编译件是否就位
      5. FMOD banks     scripts\Build-FMOD-Banks.cmd（需要本机 FMOD Studio）
      6. 自检 + skill   报告产物是否齐全，铺开 AI skill 链接

    幂等：重复跑不会报错，也不重复下载。已经存在的产物会被跳过并标注。

.PARAMETER Platform
    要构建的平台。all = windows + android + web。

.PARAMETER SkipBanks
    跳过 FMOD bank 生成（没装 FMOD Studio、或只要代码能跑起来时用）。

.PARAMETER SkipSkills
    跳过 AI skill 链接铺开。

.PARAMETER GodotBin
    Godot 4.6.x 可执行文件路径。默认读环境变量 GODOT_BIN。

.PARAMETER FmodSdk
    FMOD HTML5 SDK 根目录（含 api/studio/lib/browser）。默认读环境变量 FMOD_SDK，
    再退回 <仓库>..\sdk\fmod\html5-20400。这个 SDK 带授权，仓库里不会带。

.PARAMETER Jobs
    scons 并行度。0 = CPU 核数。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Platform web -SkipBanks

.NOTES
    所有路径都从脚本自身位置推算或读环境变量，脚本里没有任何写死的盘符或用户目录。
#>
[CmdletBinding()]
param(
    [ValidateSet('windows', 'android', 'web', 'all')]
    [string]$Platform = 'windows',

    [switch]$SkipBanks,
    [switch]$SkipSkills,

    [string]$GodotBin = $env:GODOT_BIN,
    [string]$FmodSdk = $env:FMOD_SDK,

    [int]$Jobs = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------- #
# 基础
# --------------------------------------------------------------------------- #
$Script:RepoRoot = Split-Path -Parent $PSScriptRoot      # scripts\ 的上一级
$Script:Failures = New-Object System.Collections.ArrayList
$Script:Notes = New-Object System.Collections.ArrayList

if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "== $Text" -ForegroundColor Cyan
}
function Write-Ok([string]$Text) { Write-Host "   ok   $Text" -ForegroundColor Green }
function Write-Skip([string]$Text) { Write-Host "   skip $Text" -ForegroundColor DarkGray }
function Write-Warn2([string]$Text) { Write-Host "   warn $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) {
    Write-Host "   FAIL $Text" -ForegroundColor Red
    [void]$Script:Failures.Add($Text)
}

# 失败点必须给可执行的下一步，而不是只留一句错误
function Write-Fix([string[]]$Lines) {
    foreach ($line in $Lines) { Write-Host "        -> $line" -ForegroundColor Yellow }
}

function Test-Cmd([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-ToolVersion([string]$Exe, [string[]]$ToolArgs) {
    try {
        $out = & $Exe @ToolArgs 2>&1 | Out-String
        return ($out -split "`n")[0].Trim()
    } catch {
        return '(版本未知)'
    }
}

Write-Host ''
Write-Host 'Project.Keynes 一键构建' -ForegroundColor White
Write-Host "仓库根目录 : $Script:RepoRoot"
Write-Host "平台       : $Platform"
Write-Host "并行度     : $Jobs"

# --------------------------------------------------------------------------- #
# 1. 前置检查
# --------------------------------------------------------------------------- #
Write-Step '1/6 前置检查'

$git = $null
$python = $null
$scons = $null

if (Test-Cmd 'git') {
    $git = 'git'
    Write-Ok ("git        " + (Get-ToolVersion git @('--version')))
} else {
    Write-Bad '缺 git'
    Write-Fix @('装 Git for Windows：https://git-scm.com/download/win',
                '装完新开一个终端，让 PATH 生效')
}

$pythonCmd = $null
foreach ($cand in @('python', 'py')) {
    if (Test-Cmd $cand) { $pythonCmd = $cand; break }
}
if ($pythonCmd) {
    $python = $pythonCmd
    Write-Ok ("python     " + (Get-ToolVersion $python @('--version')))
} else {
    Write-Bad '缺 python'
    Write-Fix @('装 Python 3.10+：https://www.python.org/downloads/windows/',
                '安装时勾选 "Add python.exe to PATH"')
}

if (Test-Cmd 'scons') {
    $scons = 'scons'
    Write-Ok ("scons      " + (Get-ToolVersion scons @('--version')))
} else {
    Write-Bad '缺 scons'
    Write-Fix @("$python -m pip install --user scons",
                '装完确认 scons 在 PATH 上（重开终端）')
}

# Godot 只在需要导出/跑 headless 时才是硬需求
if ($GodotBin -and (Test-Path -LiteralPath $GodotBin)) {
    Write-Ok "godot      $GodotBin"
} elseif ($GodotBin) {
    Write-Warn2 "GODOT_BIN 指向的路径不存在：$GodotBin"
    $GodotBin = $null
} else {
    Write-Warn2 '没找到 Godot（GODOT_BIN 未设置）'
    Write-Fix @('编 dots_ext 不需要 Godot；导出 Web/Android 与跑 headless 测试才需要',
                '装 Godot 4.6.x 后设：$env:GODOT_BIN = ''<解压目录>\Godot_v4.6.2-stable_win64_console.exe''')
}

if ($Platform -in @('web', 'all')) {
    if (Test-Cmd 'emcc') {
        $emccVer = Get-ToolVersion emcc @('-dumpversion')
        Write-Ok "emcc       $emccVer"
        if ($emccVer -notmatch '^4\.0\.20') {
            Write-Warn2 "Emscripten 期望 4.0.20，当前 $emccVer —— 编出来的 side module 很可能加载不了"
            Write-Fix @('emsdk install 4.0.20 && emsdk activate 4.0.20 && emsdk_env.bat',
                        '官方 Godot 4.6 的 web 模板就是 4.0.20 编的，版本必须一致')
        }
    } else {
        Write-Bad '缺 emcc（Web 构建必需）'
        Write-Fix @('git clone https://github.com/emscripten-core/emsdk',
                    'cd emsdk && emsdk install 4.0.20 && emsdk activate 4.0.20',
                    '在本终端执行 emsdk_env.bat 后再跑本脚本')
    }
}

# --------------------------------------------------------------------------- #
# 2. 子模块
# --------------------------------------------------------------------------- #
Write-Step '2/6 子模块（godot-cpp）'

$godotCpp = Join-Path $Script:RepoRoot 'gdext\godot-cpp'
$godotCppSConstruct = Join-Path $godotCpp 'SConstruct'
$gitDir = Join-Path $Script:RepoRoot '.git'

if (Test-Path -LiteralPath $godotCppSConstruct) {
    Write-Skip 'gdext\godot-cpp 已就位'
} elseif (-not (Test-Path -LiteralPath $gitDir)) {
    Write-Bad 'gdext\godot-cpp 是空的，而且当前目录不是 git 克隆，没法自动拉子模块'
    Write-Fix @('从 GitHub clone 仓库再跑本脚本；',
                '如果你拿到的是解压包，请手工补 godot-cpp 到 gdext\godot-cpp')
} elseif ($git) {
    Write-Host '   ...  git submodule update --init --recursive'
    Push-Location $Script:RepoRoot
    try {
        & git submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw "git submodule 退出码 $LASTEXITCODE" }
        if (Test-Path -LiteralPath $godotCppSConstruct) {
            Write-Ok 'godot-cpp 拉取完成'
        } else {
            Write-Bad 'submodule 命令成功但 gdext\godot-cpp\SConstruct 仍不存在'
            Write-Fix @('检查 .gitmodules 里 gdext/godot-cpp 的 url',
                        'git submodule status 看它是否 initialized')
        }
    } catch {
        Write-Bad "子模块拉取失败：$($_.Exception.Message)"
        Write-Fix @('确认能访问 github.com（公司网络可能需要代理）',
                    "cd $Script:RepoRoot; git submodule update --init --recursive 单独跑一次看完整输出")
    } finally {
        Pop-Location
    }
}

# --------------------------------------------------------------------------- #
# 3. dots_ext
# --------------------------------------------------------------------------- #
Write-Step "3/6 dots_ext GDExtension（$Platform）"

$gdextDir = Join-Path $Script:RepoRoot 'gdext'
$dotsBin = Join-Path $Script:RepoRoot 'Project\project-keynes\addons\dots_ext\bin'

function Invoke-Scons([string]$WorkDir, [string[]]$SconsArgs, [string]$Label) {
    Push-Location $WorkDir
    try {
        Write-Host "   ...  $Label"
        Write-Host "        scons $($SconsArgs -join ' ')"
        & scons @SconsArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Bad "$Label 失败（scons 退出码 $LASTEXITCODE）"
            Write-Fix @("cd $WorkDir; scons $($SconsArgs -join ' ')  单独跑一遍看完整报错",
                        'Windows 上建议用 "VS 2022 x64 Native Tools" 命令提示符跑',
                        '先关掉 Godot 编辑器：正在加载的 .dll 会被锁住导致链接失败')
            return $false
        }
        return $true
    } catch {
        Write-Bad "$Label 失败：$($_.Exception.Message)"
        return $false
    } finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $gdextDir 'SConstruct'))) {
    Write-Bad 'gdext\SConstruct 不存在，仓库不完整'
} elseif (-not $scons) {
    Write-Bad '没有 scons，跳过 dots_ext 构建'
} else {
    $targets = @()
    if ($Platform -in @('windows', 'all')) { $targets += 'windows' }
    if ($Platform -in @('android', 'all')) { $targets += 'android' }
    if ($Platform -in @('web', 'all')) { $targets += 'web' }

    foreach ($t in $targets) {
        switch ($t) {
            'windows' {
                [void](Invoke-Scons $gdextDir @('platform=windows', 'target=template_debug',
                        'dev_build=no', "-j$Jobs") 'dots_ext windows')
            }
            'android' {
                # SDK/NDK 由 gdext\build_android.bat 自己解析（ANDROID_HOME 优先）
                $bat = Join-Path $gdextDir 'build_android.bat'
                if (-not (Test-Path -LiteralPath $bat)) {
                    Write-Bad 'gdext\build_android.bat 不存在'
                } elseif (-not $env:ANDROID_HOME -and -not $env:ANDROID_SDK_ROOT) {
                    Write-Warn2 'ANDROID_HOME / ANDROID_SDK_ROOT 都没设，android 构建大概率找不到 NDK'
                    Write-Fix @('装 Android Studio 并勾选 NDK (Side by side)',
                                'setx ANDROID_HOME "<你的Android\Sdk>" 然后重开终端')
                } else {
                    Write-Host '   ...  gdext\build_android.bat release'
                    Push-Location $gdextDir
                    try {
                        & cmd /c "build_android.bat release"
                        if ($LASTEXITCODE -ne 0) {
                            Write-Bad "dots_ext android 失败（退出码 $LASTEXITCODE）"
                            Write-Fix @("cd $gdextDir; build_android.bat release 单独跑看完整输出",
                                        'NDK 里必须有 build\cmake\android.toolchain.cmake')
                        }
                    } catch {
                        Write-Bad "dots_ext android 失败：$($_.Exception.Message)"
                    } finally { Pop-Location }
                }
            }
            'web' {
                $bat = Join-Path $gdextDir 'build_web.bat'
                if (-not (Test-Path -LiteralPath $bat)) {
                    Write-Bad 'gdext\build_web.bat 不存在'
                } elseif (-not (Test-Cmd 'emcc')) {
                    Write-Bad '缺 emcc，跳过 web'
                } else {
                    Write-Host '   ...  gdext\build_web.bat'
                    Push-Location $gdextDir
                    try {
                        & cmd /c "build_web.bat"
                        if ($LASTEXITCODE -ne 0) {
                            Write-Bad "dots_ext web 失败（退出码 $LASTEXITCODE）"
                            Write-Fix @("cd $gdextDir; build_web.bat 单独跑看完整输出",
                                        '确认 emsdk_env.bat 在当前终端里执行过')
                        }
                    } catch {
                        Write-Bad "dots_ext web 失败：$($_.Exception.Message)"
                    } finally { Pop-Location }
                }
            }
        }
    }
}

# --------------------------------------------------------------------------- #
# 4. FMOD
# --------------------------------------------------------------------------- #
Write-Step '4/6 FMOD 插件链'

$addonsDir = Join-Path $Script:RepoRoot 'Project\project-keynes\addons'
$fmodGodotBin = Join-Path $addonsDir 'FmodGodot\bin'
$bootstrapBin = Join-Path $addonsDir '0_fmod_bootstrap\bin'

function Get-Children-Safe([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        return @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)
    }
    return @()
}

# 4a. web：从源码编（用 FMOD HTML5 SDK 的静态库）
if ($Platform -in @('web', 'all')) {
    if (-not $FmodSdk) {
        $FmodSdk = Join-Path (Split-Path -Parent $Script:RepoRoot) 'sdk\fmod\html5-20400'
    }
    $sdkMarker = Join-Path $FmodSdk 'api\studio\lib'
    if (-not (Test-Path -LiteralPath $sdkMarker)) {
        Write-Warn2 "FMOD HTML5 SDK 没找到：$FmodSdk"
        Write-Fix @('到 https://www.fmod.com/download 下载 FMOD Engine（HTML5 平台）',
                    "解压成 <仓库上级>\sdk\fmod\html5-20400，或设 `$env:FMOD_SDK 指向它的根目录",
                    '这个 SDK 带授权，仓库不会自带，脚本也不会替你下载',
                    '先跳过 web 的 FMOD：加 -SkipBanks 不影响其它平台')
    } elseif (-not (Test-Cmd 'scons')) {
        Write-Bad '没有 scons，跳过 FmodGodot web'
    } else {
        $fmodDir = Join-Path $gdextDir 'fmod_godot'
        [void](Invoke-Scons $fmodDir @('platform=web', 'target=template_release', 'arch=wasm32',
                'threads=yes', "fmod_sdk=$FmodSdk", "-j$Jobs") 'FmodGodot web')
    }
}

# 4b. android：fmod_bootstrap 从源码编（只要 NDK，不依赖 FMOD 头）
if ($Platform -in @('android', 'all')) {
    if (-not $scons) {
        Write-Bad '没有 scons，跳过 fmod_bootstrap'
    } elseif (-not $env:ANDROID_HOME -and -not $env:ANDROID_SDK_ROOT) {
        Write-Warn2 '没设 ANDROID_HOME，跳过 fmod_bootstrap'
    } else {
        $bootDir = Join-Path $gdextDir 'fmod_bootstrap'
        foreach ($cfg in @(@('arm64', 'template_release'), @('x86_64', 'template_debug'))) {
            [void](Invoke-Scons $bootDir @('platform=android', "target=$($cfg[1])",
                    "arch=$($cfg[0])", "-j$Jobs") "fmod_bootstrap android/$($cfg[0])")
        }
    }
}

# 4c. windows / android 的 FmodGodot 原生库：上游预编译件，仓库不带
foreach ($plat in @('windows', 'android')) {
    if ($Platform -notin @($plat, 'all')) { continue }
    $found = @(Get-Children-Safe (Join-Path $fmodGodotBin $plat) |
               Where-Object { $_.Extension -in @('.dll', '.so') })
    if ($found.Count -gt 0) {
        Write-Ok "FmodGodot/$plat 已就位（$($found.Count) 个文件）"
    } else {
        Write-Warn2 "FmodGodot/$plat 缺原生库"
        Write-Fix @('上游 FMOD-GODOT v1.1.3 的预编译件不进本仓库（FMOD 授权限制）',
                    "把它的 bin\$plat\ 内容放到 Project\project-keynes\addons\FmodGodot\bin\$plat\",
                    '缺这一步不影响画面与逻辑，只是没有声音')
    }
}

# --------------------------------------------------------------------------- #
# 5. FMOD banks
# --------------------------------------------------------------------------- #
Write-Step '5/6 FMOD banks'

$banksDir = Join-Path $Script:RepoRoot 'Project\project-keynes\assets\audio\banks'
if ($SkipBanks) {
    Write-Skip '-SkipBanks 已指定'
} else {
    # 脚本归入 scripts\ 之后基准目录下移一层，两种位置都兼容
    $bankScript = Join-Path $Script:RepoRoot 'scripts\Build-FMOD-Banks.cmd'
    if (-not (Test-Path -LiteralPath $bankScript)) {
        $bankScript = Join-Path $Script:RepoRoot 'Build-FMOD-Banks.cmd'
    }
    if (-not (Test-Path -LiteralPath $bankScript)) {
        Write-Bad 'Build-FMOD-Banks.cmd 找不到（scripts\ 和根目录都试过了）'
        Write-Fix @('用 -SkipBanks 跳过这一步')
    } else {
        $existing = @(Get-Children-Safe $banksDir | Where-Object { $_.Extension -eq '.bank' })
        if ($existing.Count -gt 0) {
            Write-Skip "已有 $($existing.Count) 个 .bank，跳过（要重出请先删掉它们）"
        } else {
            Write-Host "   ...  $bankScript"
            Push-Location (Split-Path -Parent $bankScript)
            try {
                & cmd /c "`"$bankScript`""
                if ($LASTEXITCODE -ne 0) {
                    Write-Bad "bank 生成失败（退出码 $LASTEXITCODE）"
                    Write-Fix @('需要本机装 FMOD Studio（不是 FMOD Engine）',
                                '工程文件在 Audio\ProjectKeynes\ProjectKeynes.fspro',
                                '没有 FMOD Studio 就加 -SkipBanks，先保证代码能跑')
                }
            } catch {
                Write-Bad "bank 生成失败：$($_.Exception.Message)"
            } finally { Pop-Location }
        }
    }
}

# --------------------------------------------------------------------------- #
# 6. AI skill + 自检
# --------------------------------------------------------------------------- #
Write-Step '6/6 AI skill 与自检'

if ($SkipSkills) {
    Write-Skip '-SkipSkills 已指定'
} else {
    $sync = Join-Path $Script:RepoRoot 'tools\sync_skills.py'
    if (-not (Test-Path -LiteralPath $sync)) {
        Write-Warn2 'tools\sync_skills.py 不存在，跳过 skill 铺开'
    } elseif (-not $python) {
        Write-Warn2 '没有 python，跳过 skill 铺开'
    } else {
        Push-Location $Script:RepoRoot
        try {
            & $python $sync link
            if ($LASTEXITCODE -ne 0) {
                Write-Warn2 'sync_skills.py link 有问题（可能某个工具目录被占用）'
                Write-Fix @("$python tools\sync_skills.py check  看哪个工具缺 skill",
                            "某个 .<工具>\skills 已存在且指向别处时不会覆盖，先手工处理")
            } else {
                Write-Ok 'skill 链接已铺开'
            }
        } catch {
            Write-Warn2 "skill 铺开失败：$($_.Exception.Message)"
        } finally { Pop-Location }
    }
}

Write-Step '产物自检'

function Report-Artifact([string]$Label, [string]$Path, [string[]]$Patterns, [bool]$Required) {
    $items = @(Get-Children-Safe $Path | Where-Object { $n = $_.Name; $Patterns | Where-Object { $n -like $_ } })
    if ($items.Count -gt 0) {
        $mb = [math]::Round(($items | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
        Write-Ok ("{0,-22} {1,3} 个文件  {2,7} MB" -f $Label, $items.Count, $mb)
        return $true
    }
    if ($Required) { Write-Bad "$Label 缺失（$Path）" } else { Write-Warn2 "$Label 缺失（$Path）" }
    return $false
}

$haveDots = Report-Artifact 'dots_ext' $dotsBin @('*.dll', '*.so', '*.wasm') $true
$haveFmod = Report-Artifact 'FmodGodot 原生库' $fmodGodotBin @('*.dll', '*.so', '*.wasm') $false
$haveBoot = Report-Artifact 'fmod_bootstrap' $bootstrapBin @('*.so') $false
$haveBank = Report-Artifact 'FMOD banks' $banksDir @('*.bank') $false

if ($GodotBin -and (Test-Path -LiteralPath $GodotBin)) {
    Write-Ok "Godot 可执行      $GodotBin"
} else {
    Write-Warn2 'Godot 可执行：未配置（GODOT_BIN）'
}

# --------------------------------------------------------------------------- #
Write-Step '结论'

if ($Script:Failures.Count -eq 0) {
    Write-Host '   构建通过，可以开 Godot 了。' -ForegroundColor Green
    if ($haveDots) {
        Write-Host ("   Godot 打开：Project\project-keynes\project.godot")
    }
    if ($Platform -in @('web', 'all')) {
        Write-Host '   Web 导出：scripts\Build-Web.cmd（构建后脚本自动铺 sidecar）'
    }
    if (-not $haveBank) {
        Write-Host '   注意：没有 .bank，游戏能跑但没有声音 —— 装 FMOD Studio 后去掉 -SkipBanks 再跑一次。' -ForegroundColor Yellow
    }
    exit 0
}

Write-Host "   $($Script:Failures.Count) 个阻塞项，按上面的 -> 提示逐条处理后重跑本脚本。" -ForegroundColor Red
foreach ($f in $Script:Failures) { Write-Host "   - $f" }
exit 1
