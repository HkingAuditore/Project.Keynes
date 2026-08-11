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
        'gdext/src/economy_runtime_persistence_read.cpp',
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
    # PKEC schema advances with economy content, so do not pin an exact version
    # here. The previous assertion pinned v11 and failed for everyone once the
    # schema reached v19. Require only that a version exists, that it is at least
    # the first country-aware schema, and that the precise legacy rejection stays.
    # Do not pipe into `Select-Object -First 1`: closing the pipeline early drops
    # native command output under PowerShell 5.1 and the assertion falsely fails.
    $schemaMatches = @(rg --no-filename -o 'SCHEMA_VERSION = \d+' gdext/src/economy_runtime.h)
    if ($schemaMatches.Count -eq 0) { throw 'PKEC SCHEMA_VERSION is missing from economy_runtime.h.' }
    $schemaVersion = [int]($schemaMatches[0] -replace '\D', '')
    if ($schemaVersion -lt 11) { throw "PKEC schema $schemaVersion predates country authority (expected >= 11)." }
    # PKEC v31 and earlier are rejected by the persistence reader. Keep this
    # assertion on the implementation's precise current reason so a stale
    # verifier cannot silently bless an incompatible migration contract.
    $legacyReject = rg -n 'economy_save_v31_or_earlier_unsupported' gdext/src/economy_runtime_persistence_read.cpp
    if (-not $legacyReject) { throw 'Precise legacy PKEC rejection is missing.' }

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
