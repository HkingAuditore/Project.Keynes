$exe = "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"
$proj = "D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
$tmp = "D:\Godot\ProjectKeynes\Project.Keynes\tmp"

$cases = @(
    @{w = 60; h = 40 },
    @{w = 100; h = 64 },
    @{w = 50; h = 40 },
    @{w = 60; h = 50 },
    @{w = 80; h = 40 },
    @{w = 60; h = 64 }
)

foreach ($c in $cases) {
    $w = $c.w; $h = $c.h
    $tag = "${w}x${h}"
    $out = Join-Path $tmp "mx_$tag.out"
    $err = Join-Path $tmp "mx_$tag.err"
    $args = @(
        '--headless', '--path', $proj,
        '--script', 'res://tests/headless_perf_record.gd', '--',
        'days=10', 'speed=20', 'seed=20260718',
        "width=$w", "height=$h",
        'population_scale=0', 'use_saved_setup=false', "label=mx_$tag"
    )
    $p = Start-Process -FilePath $exe -ArgumentList $args -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    if ($p.WaitForExit(180000)) {
        $code = $p.ExitCode
        $done = Select-String -LiteralPath $out -Pattern 'headless-perf/result' -Quiet
        $status = if ($done) { "OK" } else { "CRASH" }
        $lastLine = (Get-Content $out -Tail 1)
        Write-Output "[$tag] cells=$($w*$h) status=$status exit=$code last=$lastLine"
    }
    else {
        $p.Kill()
        Write-Output "[$tag] cells=$($w*$h) status=TIMEOUT"
    }
}
