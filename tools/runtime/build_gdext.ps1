# 构建 dots_ext，并先清掉会锁住 DLL 的探针残留进程。
#
# 为什么需要这个：headless 探针跑完偶尔留下 Godot 进程持有 DLL 句柄，链接就报
# "拒绝访问"（编译已经过了，只是 link 失败），git status 里那堆 .locked / .bak
# DLL 就是历史上手动绕这个问题留下的。这里只杀今天启动的进程，长期开着的编辑器
# 不动 —— 编辑器要是也锁着，会明确报出来而不是悄悄杀掉它。
param(
    [string]$Target = "template_debug",
    [switch]$KeepStrays
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not $KeepStrays) {
    $cutoff = (Get-Date).Date
    $strays = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like '*Godot*' -and $_.StartTime -gt $cutoff }
    foreach ($p in $strays) {
        Write-Host "[build] killing stray Godot pid=$($p.Id) started=$($p.StartTime)"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    if ($strays) { Start-Sleep -Seconds 2 }
}

Push-Location (Join-Path $repo "gdext")
try {
    # MSVC 把"正在创建库 …lib 和对象 …exp"写到 stderr，这是链接成功的正常输出。
    # 在 ErrorActionPreference=Stop 下它会被当成异常抛出，所以这一段必须放行，
    # 由下面的模式匹配来判定成败。
    $ErrorActionPreference = "Continue"
    $out = & scons platform=windows target=$Target -j8 2>&1
    $ErrorActionPreference = "Stop"

    $out | Out-String | Write-Host
    $failed = $out | Select-String -Pattern 'error C\d|error LNK|fatal error|拒绝访问|Access is denied'
    if ($failed) {
        Write-Host "[build] FAILED"
        exit 1
    }
    Write-Host "[build] OK"
} finally {
    Pop-Location
}
