$exe = "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"
$proj = "D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
$tmp = "D:\Godot\ProjectKeynes\Project.Keynes\tmp"

for ($i = 1; $i -le 12; $i++) {
    $out = Join-Path $tmp "hunt_$i.out"
    $err = Join-Path $tmp "hunt_$i.err"
    $a = @(
        '--headless', '--path', $proj,
        '--script', 'res://tests/headless_perf_record.gd', '--',
        'days=10', 'speed=20', "seed=$(20260718 + $i)",
        'width=50', 'height=40',
        'population_scale=0', 'use_saved_setup=false', "label=hunt$i"
    )
    $p = Start-Process -FilePath $exe -ArgumentList $a -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    if (-not $p.WaitForExit(240000)) { $p.Kill(); Write-Output "[$i] TIMEOUT"; continue }

    $ok = Select-String -LiteralPath $out -Pattern 'headless-perf/result' -Quiet
    $hasTrace = Select-String -LiteralPath $err -Pattern 'CRASH|backtrace|Dumping' -Quiet
    if ($ok) {
        Write-Output "[$i] OK"
    }
    else {
        Write-Output "[$i] CRASH  trace_in_stderr=$hasTrace  err=$err"
        if ($hasTrace) {
            Write-Output "=== FOUND BACKTRACE, stopping ==="
            break
        }
    }
}
