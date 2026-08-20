param(
    [switch]$Build,
    [switch]$Godot,
    [string]$GodotPath = "F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\")).Path
$project = Join-Path $repo "Project\project-keynes"

Write-Host "[effect] checking required files"
$required = @(
    "gdext\src\effect_runtime.h",
    "gdext\src\effect_runtime.cpp",
    "gdext\src\world_ext_effect.cpp",
    "Project\project-keynes\scripts\effect\effect_catalog.gd",
    "Project\project-keynes\scripts\effect\effect_facade.gd",
    "Project\project-keynes\scripts\simulation\systems\effect_runtime_system.gd",
    "docs\cpp-dots-runtime\native-effect-runtime.md"
)
foreach ($relative in $required) {
    if (-not (Test-Path (Join-Path $repo $relative))) {
        throw "missing required Effect Runtime file: $relative"
    }
}

git -C $repo diff --check

if ($Build) {
    Push-Location (Join-Path $repo "gdext")
    try { scons platform=windows target=template_debug -j2 }
    finally { Pop-Location }
}

if ($Godot) {
    if (-not [string]::IsNullOrWhiteSpace($env:GODOT_BIN)) {
        $GodotPath = $env:GODOT_BIN
    }
    if (-not (Test-Path -LiteralPath $GodotPath)) {
        throw "Godot not found: $GodotPath"
    }
    & $GodotPath --headless --path $project --script res://tests/effect_runtime_test.gd
    if ($LASTEXITCODE -ne 0) { throw "Effect Runtime headless test failed" }
}

Write-Host "[effect] verification passed"
