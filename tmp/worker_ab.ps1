$exe = "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"
$proj = "D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
$tmp = "D:\Godot\ProjectKeynes\Project.Keynes\tmp"

function Run-Case([string]$mode, [int]$seed) {
    $tag = "$mode`_$seed"
    $out = Join-Path $tmp "wab_$tag.out"
    $err = Join-Path $tmp "wab_$tag.err"
    $a = @(
        '--headless', '--path', $proj,
        '--script', 'res://tests/headless_perf_record.gd', '--',
        'days=10', 'speed=20', "seed=$seed",
        'width=50', 'height=40',
        'population_scale=0', 'use_saved_setup=false', "label=wab_$tag",
        "worker_mode=$mode"
    )
    $p = Start-Process -FilePath $exe -ArgumentList $a -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    if (-not $p.WaitForExit(300000)) { $p.Kill(); return "TIMEOUT" }
    if (Select-String -LiteralPath $out -Pattern 'headless-perf/result' -Quiet) { return "OK" }
    return "CRASH"
}

$seeds = @(20260719, 20260720, 20260721, 20260722, 20260723, 20260724)

foreach ($mode in @('OFF', 'ON')) {
    $results = @()
    foreach ($s in $seeds) { $results += (Run-Case $mode $s) }
    $crashes = ($results | Where-Object { $_ -ne 'OK' }).Count
    Write-Output "worker_mode=$mode  ->  $($results -join ',')   crashes=$crashes/$($seeds.Count)"
}
