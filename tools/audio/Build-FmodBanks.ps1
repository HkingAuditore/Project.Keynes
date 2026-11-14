[CmdletBinding()]
param(
    # 默认两边一起编。只编 Desktop 会让 Build\HTML5 悄悄过期 —— 而 web 导出正是
    # 从 Build\HTML5 取 bank（tools\web_bank_downgrade.py）。2026-11-11 实测过一次
    # 代价：Build\HTML5 停在 10-21，Music.bank 只有 12.15 MB，看着像"降质效果极好"，
    # 实际是那之后新增的曲子根本没进去；重编后是 49.49 MB。
    # 只编 web 那套做快速迭代：
    #   powershell -File tools\audio\Build-FmodBanks.ps1 -Platforms HTML5
    [string[]]$Platforms = @('Desktop', 'HTML5')
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
& (Join-Path $PSScriptRoot 'Start-FmodStudio.ps1') -SetupOnly
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Studio setup failed.' }
$cli = Join-Path $repoRoot 'tools\fmod-studio\2.03.15\fmodstudiocl.exe'
$project = Join-Path $repoRoot 'Audio\ProjectKeynes\ProjectKeynes.fspro'
$diagnostics = & $cli -diagnostic $project 2>&1
if ($LASTEXITCODE -ne 0) {
    $diagnostics | Out-Host
    throw 'FMOD project validation failed; banks were not synchronized.'
}
Write-Host 'FMOD project validation passed.'

$platformList = ($Platforms -join ',')
Write-Host "Building banks for: $platformList"
& $cli -build -platforms $platformList -export-guids $project
if ($LASTEXITCODE -ne 0) { throw 'FMOD bank build failed.' }

$names = @('Master.strings.bank', 'Master.bank', 'Music.bank', 'UI.bank') + @(
    'Music_stone.bank', 'Music_agrarian.bank', 'Music_kingdom.bank', 'Music_empire.bank'
)

# Desktop 那套全量进 Godot 工程：桌面/Android 的 pck 没有体积压力，运行期
# `_ensure_era_bank()` 直接 load_bank_file 就位。只有 web 导出会把这些 era bank
# 临时移出工程（tools\web_bank_downgrade.py）。
#
# HTML5 那套**不进** res://：web 的 boot pck 里只要四个核心 bank，era bank 由
# 导出流程拷到站点根目录、运行期按时代 fetch。两套都放进工程会让 Godot 同时导入
# 两份同名 bank。
if ($Platforms -contains 'Desktop') {
    $output = Join-Path $repoRoot 'Project\project-keynes\assets\audio\banks\Desktop'
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    foreach ($name in $names) {
        $source = Join-Path $repoRoot "Audio\ProjectKeynes\Build\Desktop\$name"
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing build output: $name" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $output $name)
    }
    Write-Host "Banks synchronized (Desktop): $output"
}

foreach ($platform in $Platforms) {
    $dir = Join-Path $repoRoot "Audio\ProjectKeynes\Build\$platform"
    $sum = (Get-ChildItem -LiteralPath $dir -Filter '*.bank' -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { $sum = 0 }
    Write-Host ("[fmod] {0,-8} {1,8:N2} MB  {2}" -f $platform, ($sum / 1MB), $dir)
}
