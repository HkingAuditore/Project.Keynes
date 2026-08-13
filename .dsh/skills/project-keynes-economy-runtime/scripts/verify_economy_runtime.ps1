param(
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$Godot,
    [switch]$Build,
    [string]$GodotExe = 'F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$project = Join-Path $root 'Project\project-keynes'
$gdext = Join-Path $root 'gdext'

$required = @(
    'gdext\src\economy_runtime.h',
    'gdext\src\economy_runtime.cpp',
    'gdext\src\world_ext_economy.cpp',
    'Project\project-keynes\scripts\simulation\systems\economy_daily_system.gd',
    'Project\project-keynes\scripts\data\economy_profile.gd',
    'Project\project-keynes\data\economy\default_economy.tres',
    'Project\project-keynes\tests\goods_storage_schema_test.gd'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relative))) {
        throw "Missing economy runtime file: $relative"
    }
}

Push-Location $root
try {
    & git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'git diff --check failed' }

    if (Get-Command rg -ErrorAction SilentlyContinue) {
        & rg -n 'market_cycle_days|WAIT_COMMIT|economy_day_barrier|population_error|money_error|goods_error' `
            'gdext/src/economy_runtime.cpp' `
            'Project/project-keynes/scripts/simulation/systems/economy_daily_system.gd' `
            'Project/project-keynes/scripts/data/economy_profile.gd' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Economy contract symbols not found' }
    }
} finally {
    Pop-Location
}

if ($Build) {
    $scons = Join-Path $env:APPDATA 'Python\Python314\Scripts\scons.exe'
    if (-not (Test-Path -LiteralPath $scons)) { throw "SCons not found: $scons" }
    Push-Location $gdext
    try {
        & $scons platform=windows target=template_debug dev_build=no -j8
        if ($LASTEXITCODE -ne 0) { throw 'template_debug build failed' }
        & $scons platform=windows target=template_release dev_build=no -j8
        if ($LASTEXITCODE -ne 0) { throw 'template_release build failed' }
    } finally {
        Pop-Location
    }
}

if ($Godot) {
    if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot not found: $GodotExe" }
    & $GodotExe --headless --path $project --check-only --script res://scripts/data/economy_profile.gd
    if ($LASTEXITCODE -ne 0) { throw 'EconomyProfile parse failed' }
    & $GodotExe --headless --path $project --check-only --script res://scripts/simulation/systems/economy_daily_system.gd
    if ($LASTEXITCODE -ne 0) { throw 'EconomyDailySystem parse failed' }
    & $GodotExe --headless --path $project --script res://tests/goods_storage_schema_test.gd
    if ($LASTEXITCODE -ne 0) { throw 'Focused economy test failed' }
    & $GodotExe --headless --path $project --script res://tests/building_runtime_test.gd
    if ($LASTEXITCODE -ne 0) { throw 'Building runtime test failed' }
    & $GodotExe --headless --path $project --script res://tests/building_resource_chain_test.gd
    if ($LASTEXITCODE -ne 0) { throw 'Building resource chain test failed' }
	& $GodotExe --headless --path $project --script res://tests/modern_economy_catalog_test.gd
	if ($LASTEXITCODE -ne 0) { throw 'Modern economy catalog test failed' }
	& $GodotExe --headless --path $project --script res://tests/modern_economy_runtime_test.gd
	if ($LASTEXITCODE -ne 0) { throw 'Modern economy runtime test failed' }
	& $GodotExe --headless --path $project --script res://tests/economy_test_bootstrap_test.gd
	if ($LASTEXITCODE -ne 0) { throw 'Economy test bootstrap failed' }
	& $GodotExe --headless --path $project --script res://tests/economy_map_generation_test.gd
	if ($LASTEXITCODE -ne 0) { throw 'Economy map generation test failed' }
	& $GodotExe --headless --path $project --script res://tests/natural_resource_distribution_capacity_test.gd
	if ($LASTEXITCODE -ne 0) { throw 'Natural resource distribution capacity test failed' }
}

Write-Output 'Project.Keynes economy runtime verification passed.'
