<##
.SYNOPSIS
  Repository-level Economy/authority migration verification entry point.

  This wrapper is intentionally fail-closed: a Godot process that exits zero
  while printing a test failure is still considered a failure.  It reuses the
  focused tests used by the Economy runtime and adds the worker-domain/ECP2
  contract tests so the migration boundary is checked in one command.
##>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$Build,
    [switch]$Godot,
    [string]$GodotExe = ''
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$project = Join-Path $root 'Project\project-keynes'

if ($GodotExe -eq '') {
    $GodotExe = if ($env:GODOT_BIN) { $env:GODOT_BIN } else {
        'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe'
    }
}

$required = @(
    'gdext\src\economy_runtime.h',
    'gdext\src\economy_runtime.cpp',
    'gdext\src\runtime_economy_ecp2.h',
    'gdext\src\runtime_economy_ecp2.cpp',
    'gdext\src\runtime_pod_protocol.h',
    'gdext\src\native_simulation_host.cpp',
    'Project\project-keynes\scripts\simulation\systems\economy_daily_system.gd',
    'Project\project-keynes\tests\economy_cadence_runtime_test.gd'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relative))) {
        throw "Missing economy migration file: $relative"
    }
}

Push-Location $root
try {
    & git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'git diff --check failed' }

    if ($Build) {
        $scons = (Get-Command scons -ErrorAction SilentlyContinue).Source
        if (-not $scons) { throw 'scons is not available on PATH' }
        Push-Location (Join-Path $root 'gdext')
        try {
            & $scons platform=windows target=template_debug dev_build=no -j8
            if ($LASTEXITCODE -ne 0) { throw 'template_debug build failed' }
            & $scons platform=windows target=template_release dev_build=no -j8
            if ($LASTEXITCODE -ne 0) { throw 'template_release build failed' }
        } finally { Pop-Location }
    }

    if ($Godot) {
        if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot not found: $GodotExe" }
        $tests = @(
            'tests/economy_cadence_runtime_test.gd',
            'tests/runtime_economy_pod_test.gd',
            'tests/runtime_economy_parity_test.gd',
            'tests/runtime_events_pod_test.gd',
            'tests/runtime_effect_pod_test.gd',
            'tests/runtime_domain_pod_test.gd',
            'tests/building_runtime_test.gd'
        )
        $failurePattern = 'FAIL\b|FAILED|ASSERT|SCRIPT ERROR|Parse Error|Invalid call|Condition ".*" is (true|false)'
        foreach ($relative in $tests) {
            $lines = @(& $GodotExe --headless --path $project --script "res://$relative" --quit 2>&1)
            $exitCode = $LASTEXITCODE
            $text = $lines -join "`n"
            if ($exitCode -ne 0 -or $text -match $failurePattern) {
                throw "Economy runtime test failed: $relative (exit=$exitCode)"
            }
        }
    }
} finally {
    Pop-Location
}

Write-Output 'Project.Keynes Economy runtime verification passed.'
