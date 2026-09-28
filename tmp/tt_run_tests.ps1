param([string]$TestList, [string]$Tag)
$Tests = $TestList.Split(',')
$g = "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"
$root = "d:\Godot\ProjectKeynes\Project.Keynes"
$out = Join-Path $root "tmp\tt_tests2"
New-Item -ItemType Directory -Force $out | Out-Null
Set-Location (Join-Path $root "Project\project-keynes")
foreach ($t in $Tests) {
    $name = $t.Split(' ')[0]
    $args = @('--headless', '--path', '.', '--script', "res://tests/$name.gd")
    if ($t.Contains(' ')) { $args += '--'; $args += $t.Split(' ')[1..9] }
    $log = Join-Path $out "$($t.Replace(' ','_')).log"
    & $g @args *> $log
    "$t exit=$LASTEXITCODE" | Out-File -Append -Encoding utf8 (Join-Path $out "summary_$Tag.txt")
}
"DONE" | Out-File -Append -Encoding utf8 (Join-Path $out "summary_$Tag.txt")
