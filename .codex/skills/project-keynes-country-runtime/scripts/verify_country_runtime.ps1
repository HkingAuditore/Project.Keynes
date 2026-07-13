param(
    [switch]$Build,
    [switch]$Godot
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
Push-Location $root
try {
    $required = @(
        'gdext/src/country_runtime.h',
        'gdext/src/country_runtime.cpp',
        'gdext/src/world_ext_country.cpp',
        'Project/project-keynes/scripts/country/country_facade.gd',
        'Project/project-keynes/scripts/simulation/systems/country_daily_system.gd',
        'docs/cpp-dots-runtime/native-country-runtime.md'
    )
    foreach ($path in $required) {
        if (-not (Test-Path $path)) { throw "Missing required country runtime file: $path" }
    }

    $bindings = rg -n 'configure_country|bootstrap_country|submit_country_commands|run_country_slice|get_country_state_hash' gdext/src/world_ext_bind_methods.cpp
    if (-not $bindings) { throw 'Country DCWorldExt bindings are missing.' }
    $schema = rg -n 'cell\.country_slot|CELL_COUNTRY_SLOT' Project/project-keynes/scripts/data_core gdext/src/component_bind_table.gen.h
    if (-not $schema) { throw 'cell.country_slot schema or generated binding is missing.' }
    $legacy = rg -n '_treasury_cash|_cell_technology_bits|COMMAND_GRANT_TECHNOLOGY' gdext/src/economy_runtime.h gdext/src/economy_runtime.cpp
    if ($legacy) { throw "Legacy economy-owned country state remains:`n$legacy" }
    $save = rg -n 'SCHEMA_VERSION = 11|legacy_countryless_economy_save_unsupported' gdext/src/economy_runtime.h gdext/src/economy_runtime.cpp
    if (-not $save) { throw 'PKEC v11 or precise legacy rejection is missing.' }

    if ($Build) {
        Push-Location gdext
        try {
            scons platform=windows target=template_debug
            scons platform=windows target=template_release
        } finally { Pop-Location }
    }

    if ($Godot) {
        $godotExe = (Get-Command godot4 -ErrorAction SilentlyContinue).Source
        if (-not $godotExe) { $godotExe = (Get-Command godot -ErrorAction SilentlyContinue).Source }
        if (-not $godotExe) { throw 'Godot executable was not found on PATH.' }
        & $godotExe --headless --path Project/project-keynes --quit
        if ($LASTEXITCODE -ne 0) { throw "Godot headless parse failed with exit code $LASTEXITCODE" }
    }

    git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'git diff --check failed.' }
    Write-Host 'Country runtime verification passed.'
} finally {
    Pop-Location
}
