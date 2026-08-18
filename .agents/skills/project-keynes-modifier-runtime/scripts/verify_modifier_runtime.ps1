param(
    [switch]$Build,
    [switch]$Godot,
    [string]$GodotPath = "F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Text {
    param([string]$RelativePath, [string[]]$Patterns)
    $path = Join-Path $repoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        $failures.Add("missing file: $RelativePath")
        return
    }
    $content = Get-Content -LiteralPath $path -Raw
    foreach ($pattern in $Patterns) {
        if ($content -notmatch $pattern) {
            $failures.Add("missing pattern '$pattern' in $RelativePath")
        }
    }
}

Assert-Text "gdext/src/modifier_runtime.h" @(
    "class ModifierRuntime", "effective_value", "serialize_domain",
    "restore_domain", "ensure_building_identity", "register_gameplay_object"
)
Assert-Text "gdext/src/modifier_runtime.cpp" @(
    "zero_factor_count", "expiry_heap", "stable_sort", "EVENT_TARGET_CLEANUP",
    "active_instances_by_domain", "snapshot_versions", "bucket_update_ms",
    "estimated_memory_bytes_by_domain", "error_reasons", "journal_version"
)
Assert-Text "gdext/src/world_ext_bind_methods.cpp" @(
    "configure_modifiers", "submit_modifier_commands", "run_modifier_daily",
    "capture_modifier_domain", "restore_modifier_domain", "clear_modifier_domain",
    "ensure_modifier_building_handle"
)
Assert-Text "Project/project-keynes/scripts/modifier/modifier_facade.gd" @(
    "PROTOCOL_VERSION", "queue_apply", "queue_remove", "queue_refresh",
    "queue_set_stacks", "queue_set_magnitude", "explain_stat"
)
Assert-Text "Project/project-keynes/scripts/simulation/systems/modifier_daily_system.gd" @(
    'id = &"modifier_daily"', "priority = 90", "run_modifier_daily",
    "use_job_deadline_critical = true", "is_deadline_critical"
)
Assert-Text "Project/project-keynes/scripts/geography/map_generator.gd" @(
    "ModifierDailySystem", "get_modifier_facade", "modifier_daily"
)
Assert-Text "gdext/src/world_ext_climate.cpp" @(
    "modifier_climate_radiative_target", "radiative_modifier_add",
    "radiative_modifier_factor", "PRAD_FACTOR"
)
Assert-Text "gdext/src/economy_runtime.cpp" @(
    "effective_building_output_quantity", "country_economy_output_factor",
    "ensure_building_identity"
)
Assert-Text "gdext/src/economy_runtime_persistence_codec.h" @("SAVE_SECTION_MODIFIERS")
Assert-Text "gdext/src/country_runtime.h" @("SCHEMA_VERSION = 11")
Assert-Text "gdext/src/economy_runtime.h" @("SCHEMA_VERSION = 33")
Assert-Text "gdext/src/modifier_runtime.h" @(
    "PROTOCOL_VERSION = 2", "SAVE_SCHEMA_VERSION = 2", "COMMAND_SET_MAGNITUDE"
)
Assert-Text "Project/project-keynes/scripts/game/game_save_coordinator.gd" @(
	'"pkcm"', '"pkgp"', '&"pkcn", 10', '&"pkec", 33'
)
Assert-Text "docs/cpp-dots-runtime/native-modifier-runtime.md" @(
	"clamp\(\(base \+ sum\(add\)\)", "PKCM v1", "PKCN v11", "PKEC v33", "PKGP v1"
)
Assert-Text ".codex/skills/project-keynes-modifier-runtime/SKILL.md" @(
    "Non-Negotiable Invariants", "verify_modifier_runtime.ps1",
    "project-keynes-runtime-architecture"
)

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

if ($Build) {
    $scons = Join-Path $env:APPDATA "Python\Python314\Scripts\scons.exe"
    if (-not (Test-Path -LiteralPath $scons)) {
        throw "scons not found: $scons"
    }
    $buildExitCode = 0
    Push-Location (Join-Path $repoRoot "gdext")
    try {
        & $scons platform=windows target=template_debug dev_build=no -j8
        $buildExitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($buildExitCode -ne 0) { exit $buildExitCode }
}

if ($Godot) {
    if (-not (Test-Path -LiteralPath $GodotPath)) {
        throw "Godot not found: $GodotPath"
    }
    $project = Join-Path $repoRoot "Project\project-keynes"
    & $GodotPath --headless --path $project --script res://tests/modifier_runtime_test.gd
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "Modifier runtime verification passed."
