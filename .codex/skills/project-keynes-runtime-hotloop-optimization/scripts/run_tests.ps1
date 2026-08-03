<#
.SYNOPSIS
    Run the native runtime test suites and report a per-suite [FAIL] count.

.DESCRIPTION
    These suites have a pre-existing failure set, so a non-zero count is not
    itself a regression. Run once with the baseline DLL (git stash) and once
    with the change, then Compare-Object the saved .out files.

.EXAMPLE
    .\run_tests.ps1 -OutDir tmp\base
    .\run_tests.ps1 -OutDir tmp\head
    Compare-Object (Select-String tmp\base\building_runtime_test.out -Pattern '\[FAIL\]').Line `
                   (Select-String tmp\head\building_runtime_test.out -Pattern '\[FAIL\]').Line
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..\..\..").Path,
    [string]$GodotExe,
    [string]$OutDir = "tmp\test_out",
    [string[]]$Suites = @("building_runtime_test", "modern_economy_runtime_test", "family_runtime_test")
)

# Do not stop on stderr: Godot's dummy renderer emits cleanup warnings that are
# not failures, and 'Stop' would abort the run mid-suite.
$ErrorActionPreference = 'Continue'

if (-not $GodotExe) {
    $GodotExe = (Get-ChildItem "F:\Developent\Godot", "C:\Program Files\Godot" -Recurse `
        -Filter "Godot_v*_win64_console.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName)
}
if (-not $GodotExe -or -not (Test-Path $GodotExe)) {
    throw "Godot console executable not found. Pass -GodotExe explicitly."
}

$projectPath = Join-Path $RepoRoot "Project\project-keynes"
$outPath = Join-Path $RepoRoot $OutDir
New-Item -ItemType Directory -Force -Path $outPath | Out-Null

Write-Host "godot   : $GodotExe"
Write-Host "project : $projectPath"
Write-Host "out     : $outPath`n"

$summary = @()
foreach ($suite in $Suites) {
    $log = Join-Path $outPath "$suite.out"
    Write-Host "running $suite ..."
    & $GodotExe --headless --path $projectPath --script "res://tests/$suite.gd" *> $log
    $exit = $LASTEXITCODE
    $fails = @(Select-String -Path $log -Pattern '\[FAIL\]' -ErrorAction SilentlyContinue)
    $summary += [pscustomobject]@{
        Suite = $suite
        Fails = $fails.Count
        Exit  = $exit
        Log   = $log
    }
}

Write-Host ""
$summary | Format-Table -AutoSize
Write-Host "A non-zero Fails count is expected. Compare the [FAIL] lines against a baseline run."
