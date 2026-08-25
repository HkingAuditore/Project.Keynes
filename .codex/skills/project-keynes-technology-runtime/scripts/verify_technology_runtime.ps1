[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$GodotExe = "",
    [switch]$Build
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Get-Location).Path
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "gdext")) -and
    (Test-Path -LiteralPath (Join-Path $RepoRoot "Project.Keynes\gdext"))) {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $RepoRoot "Project.Keynes")).Path
}

$required = @(
    "gdext\src\country_runtime.cpp",
    "gdext\src\economy_runtime.cpp",
    "gdext\src\modifier_runtime.cpp",
    "Project\project-keynes\scripts\economy\technology_catalog.gd",
    "Project\project-keynes\data\technology\technology_network.json",
    "Project\project-keynes\scripts\ui\components\technology_workspace.gd",
    "Project\project-keynes\tests\technology_catalog_test.gd",
    "docs\cpp-dots-runtime\technology-tree-runtime.md"
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $relative))) {
        throw "Missing technology runtime file: $relative"
    }
}

Write-Host "[technology-runtime] repository contract files present"

if ($Build) {
    Push-Location (Join-Path $RepoRoot "gdext")
    try {
        & scons platform=windows target=template_debug -j4
        if ($LASTEXITCODE -ne 0) {
            throw "Debug GDExtension build failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

if ([string]::IsNullOrWhiteSpace($GodotExe)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GODOT4_BIN)) {
        $GodotExe = $env:GODOT4_BIN
    }
}

if (-not [string]::IsNullOrWhiteSpace($GodotExe)) {
    $GodotExe = (Resolve-Path -LiteralPath $GodotExe).Path
    $projectRoot = Join-Path $RepoRoot "Project\project-keynes"
    $tests = @(
        "technology_catalog_test.gd",
        "technology_network_design_test.gd",
        "technology_content_binding_audit_test.gd",
        "technology_unlock_closure_audit_test.gd",
        "technology_industry_chain_balance_test.gd",
        "technology_research_runtime_test.gd",
        "technology_breakthrough_trigger_test.gd",
        "technology_procurement_runtime_test.gd",
        "technology_modifier_activation_test.gd",
        "technology_pending_activation_scheduler_test.gd",
        "technology_workspace_smoke_test.gd"
    )
    foreach ($test in $tests) {
        Write-Host "[technology-runtime] running $test"
        & $GodotExe --headless --path $projectRoot --script "res://tests/$test"
        if ($LASTEXITCODE -ne 0) {
            throw "$test failed with exit code $LASTEXITCODE"
        }
    }
    Write-Host "[technology-runtime] running technology_unlock_closure_audit_test.gd --construction"
    & $GodotExe --headless --path $projectRoot --script "res://tests/technology_unlock_closure_audit_test.gd" -- --construction
    if ($LASTEXITCODE -ne 0) {
        throw "technology_unlock_closure_audit_test.gd --construction failed with exit code $LASTEXITCODE"
    }
}
else {
    Write-Host "[technology-runtime] Godot tests skipped; pass -GodotExe or set GODOT4_BIN"
}

Push-Location $RepoRoot
try {
    & git diff --check
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --check failed"
    }
}
finally {
    Pop-Location
}

Write-Host "[technology-runtime] verification complete"
