# Runs the climate parity probe headless and leaves the full log on disk.
# Piping Godot's stdout into a filter kills the process early (the pipe closes
# when the filter stops reading), so everything is redirected to a file first.
param(
    [int]$Days = 30,
    [int]$Seed = 20260101,
    [string]$Label = "probe",
    [string]$Out = ""
)

$ErrorActionPreference = "Continue"
$godot = "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"
$project = "D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
$artifacts = "D:\Godot\ProjectKeynes\Project.Keynes\artifacts\runtime\s2-divergence"
if ($Out -eq "") { $Out = Join-Path $artifacts "$Label-d$Days-s$Seed.log" }
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null

$sw = [Diagnostics.Stopwatch]::StartNew()
& $godot --headless --path $project --script res://tests/climate_parity_probe.gd -- `
    "--days=$Days" "--seed=$Seed" "--label=$Label" *> $Out
$code = $LASTEXITCODE
Write-Host "[probe] exit=$code elapsed_s=$([int]$sw.Elapsed.TotalSeconds) log=$Out"
exit $code
