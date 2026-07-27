$exe = "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"
$proj = "D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
$tmp = "D:\Godot\ProjectKeynes\Project.Keynes\tmp"

$tests = @(
    'goods_storage_schema_test.gd',
    'building_runtime_test.gd',
    'building_resource_chain_test.gd',
    'economy_trade_runtime_test.gd',
    'economy_birth_runtime_test.gd',
    'modern_economy_runtime_test.gd',
    'economy_test_bootstrap_test.gd',
    'country_runtime_test.gd'
)

foreach ($t in $tests) {
    $name = $t -replace '\.gd$', ''
    $out = Join-Path $tmp "test_$name.out"
    $err = Join-Path $tmp "test_$name.err"
    $p = Start-Process -FilePath $exe `
        -ArgumentList '--headless', '--path', $proj, '--script', "res://tests/$t" `
        -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    if (-not $p.WaitForExit(600000)) { $p.Kill(); Write-Output "$name : TIMEOUT"; continue }
    $code = $p.ExitCode
    $text = Get-Content $out -Raw
    $failLine = ($text -split "`n" | Where-Object { $_ -match 'FAIL|failures=[1-9]|failed=[1-9]' } | Select-Object -First 1)
    if ($failLine) {
        Write-Output "$name : FAIL  exit=$code  :: $($failLine.Trim())"
    }
    else {
        $summary = ($text -split "`n" | Where-Object { $_ -match 'pass|PASS|failures=0|ok=' } | Select-Object -Last 1)
        Write-Output "$name : OK  exit=$code  :: $($summary -replace '\s+$','')"
    }
}
