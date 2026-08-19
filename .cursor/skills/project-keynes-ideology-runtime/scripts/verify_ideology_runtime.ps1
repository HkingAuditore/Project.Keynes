param(
    [string]$RepoRoot = '',
    [switch]$Godot,
    [switch]$Build,
    [string]$GodotExe = ''
)

$ErrorActionPreference = 'Stop'

function Find-RepoRoot {
    param([string]$Start)
    $cursor = $Start
    for ($i = 0; $i -lt 10; $i++) {
        $probe = Join-Path $cursor 'gdext\src\ideology_runtime.h'
        if (Test-Path -LiteralPath $probe) { return (Resolve-Path -LiteralPath $cursor).Path }
        $parent = Split-Path $cursor -Parent
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $null
}

$root = $RepoRoot
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = Find-RepoRoot (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = Find-RepoRoot (Get-Location).Path
}
if ([string]::IsNullOrWhiteSpace($root)) {
    throw 'Could not locate repository root containing gdext/src/ideology_runtime.h'
}

$project = Join-Path $root 'Project\project-keynes'
$gdext = Join-Path $root 'gdext'

$required = @(
    'gdext\src\ideology_runtime.h',
    'gdext\src\ideology_runtime.cpp',
    'gdext\src\world_ext_ideology.cpp',
    'Project\project-keynes\scripts\ideology\ideology_catalog.gd',
    'Project\project-keynes\scripts\ideology\ideology_facade.gd',
    'Project\project-keynes\scripts\simulation\systems\ideology_runtime_system.gd',
    'Project\project-keynes\data\ideologies\default_ideology_catalog.tres',
    'Project\project-keynes\tests\ideology_runtime_test.gd',
    'Project\project-keynes\tests\ideology_opinion_synergy_test.gd',
    'Project\project-keynes\tests\ideology_content_test.gd',
    'docs\cpp-dots-runtime\native-ideology-runtime.md'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relative))) {
        throw "Missing ideology runtime file: $relative"
    }
}

Push-Location $root
try {
    Write-Host '[ideology] git diff --check'
    & git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'git diff --check failed' }

    if (Get-Command rg -ErrorAction SilentlyContinue) {
        Write-Host '[ideology] contract symbol check'
        & rg -n 'enqueue_external_effect_batch_pod|CountryClassOpinionSnapshot|SAVE_SCHEMA_VERSION|explain_ideologies|economic_order' `
            'gdext/src/ideology_runtime.cpp' `
            'gdext/src/ideology_runtime.h' `
            'Project/project-keynes/scripts/ideology/ideology_catalog.gd' `
            'docs/cpp-dots-runtime/native-ideology-runtime.md' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Ideology contract symbols not found' }
    }
} finally {
    Pop-Location
}

if ($Build) {
    Write-Host '[ideology] building GDExtension debug/release'
    Push-Location $gdext
    try {
        python -m SCons platform=windows target=template_debug dev_build=no -j6
        if ($LASTEXITCODE -ne 0) { throw 'template_debug build failed' }
        python -m SCons platform=windows target=template_release dev_build=no -j6
        if ($LASTEXITCODE -ne 0) { throw 'template_release build failed' }
    } finally {
        Pop-Location
    }
}

if ($Godot) {
    if ([string]::IsNullOrWhiteSpace($GodotExe)) {
        $GodotExe = $env:GODOT_BIN
    }
    if ([string]::IsNullOrWhiteSpace($GodotExe)) {
        $GodotExe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe'
    }
    if (-not (Test-Path -LiteralPath $GodotExe)) {
        throw "Godot not found: $GodotExe"
    }
    $tests = @(
        'res://tests/ideology_content_test.gd',
        'res://tests/ideology_runtime_test.gd',
        'res://tests/ideology_opinion_synergy_test.gd'
    )
    foreach ($script in $tests) {
        Write-Host "[ideology] $script"
        & $GodotExe --headless --path $project --script $script
        if ($LASTEXITCODE -ne 0) { throw "Headless ideology test failed: $script" }
    }
}

Write-Host '[ideology] verification passed'
