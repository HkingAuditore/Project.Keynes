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
        'gdext/src/country_core.h',
        'gdext/src/country_core.cpp',
        'gdext/src/country_core_apply.h',
        'gdext/src/country_core_apply.cpp',
        'gdext/src/world_ext_country.cpp',
        'gdext/src/native_simulation_host.cpp',
        'gdext/src/economy_runtime_persistence_read.cpp',
        'Project/project-keynes/scripts/country/country_facade.gd',
        'Project/project-keynes/scripts/simulation/systems/country_daily_system.gd',
        'Project/project-keynes/tests/runtime_country_peer_bridge_test.gd',
        'Project/project-keynes/tests/runtime_country_save_roundtrip_test.gd',
        'docs/cpp-dots-runtime/native-country-runtime.md'
    )
    foreach ($path in $required) {
        if (-not (Test-Path $path)) { throw "Missing required country runtime file: $path" }
    }

    $bindings = Select-String -CaseSensitive -Path 'gdext/src/world_ext_bind_methods.cpp' -Pattern 'configure_country|bootstrap_country|submit_country_commands|run_country_slice|get_country_state_hash|restore_country_runtime_checkpoint'
    if (-not $bindings) { throw 'Country DCWorldExt bindings are missing.' }
    $checkpoint = Select-String -CaseSensitive -Path @('gdext/src/country_core.h', 'gdext/src/runtime_pod_protocol.h', 'Project/project-keynes/scripts/game/pksr_bundle_header.gd') -Pattern 'COUNTRY_CHECKPOINT_ABI_VERSION = 2|RUNTIME_SAVE_SECTION_COUNTRY|SECTION_COUNTRY := 8'
    if (-not $checkpoint) { throw 'Country CPD2/PKSR section contract is missing.' }
    $schemaPaths = @(Get-ChildItem 'Project/project-keynes/scripts/data_core' -Recurse -File | Select-Object -ExpandProperty FullName)
    $schemaPaths += (Resolve-Path 'gdext/src/component_bind_table.gen.h').Path
    $schema = Select-String -CaseSensitive -Path $schemaPaths -Pattern 'cell\.country_slot|CELL_COUNTRY_SLOT'
    if (-not $schema) { throw 'cell.country_slot schema or generated binding is missing.' }
    $legacy = Select-String -CaseSensitive -Path @('gdext/src/economy_runtime.h', 'gdext/src/economy_runtime.cpp') -Pattern '_treasury_cash|_cell_technology_bits|COMMAND_GRANT_TECHNOLOGY'
    if ($legacy) { throw "Legacy economy-owned country state remains:`n$legacy" }
    # PKEC schema advances with economy content, so do not pin an exact version
    # here. The previous assertion pinned v11 and failed for everyone once the
    # schema reached v19. Require only that a version exists, that it is at least
    # the first country-aware schema, and that the precise legacy rejection stays.
    # Do not pipe into `Select-Object -First 1`: closing the pipeline early drops
    # native command output under PowerShell 5.1 and the assertion falsely fails.
    $schemaMatches = @((Select-String -CaseSensitive -Path 'gdext/src/economy_runtime.h' -Pattern 'SCHEMA_VERSION = \d+' -AllMatches).Matches | ForEach-Object Value)
    if ($schemaMatches.Count -eq 0) { throw 'PKEC SCHEMA_VERSION is missing from economy_runtime.h.' }
    $schemaVersion = [int]($schemaMatches[0] -replace '\D', '')
    if ($schemaVersion -lt 11) { throw "PKEC schema $schemaVersion predates country authority (expected >= 11)." }
    # The current reader accepts only the exact active schema. Keep this on the
    # implementation's precise reason so verifier text cannot lag the codec.
    $legacyReject = Select-String -CaseSensitive -Path 'gdext/src/economy_runtime_persistence_read.cpp' -Pattern 'economy_save_price_v6_requires_new_game'
    if (-not $legacyReject) { throw 'Precise legacy PKEC rejection is missing.' }

    if ($Build) {
        Push-Location gdext
        try {
            $hadNativeErrorPreference = Test-Path Variable:PSNativeCommandUseErrorActionPreference
            if ($hadNativeErrorPreference) {
                $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
                $PSNativeCommandUseErrorActionPreference = $false
            }
            $sconsExe = (Get-Command scons -ErrorAction Stop).Source
            $debugBuild = Start-Process -FilePath $sconsExe -ArgumentList @(
                'platform=windows', 'target=template_debug') -Wait -PassThru -NoNewWindow
            if ($debugBuild.ExitCode -ne 0) { throw "Debug GDExtension build failed with exit code $($debugBuild.ExitCode)" }
            $releaseBuild = Start-Process -FilePath $sconsExe -ArgumentList @(
                'platform=windows', 'target=template_release') -Wait -PassThru -NoNewWindow
            if ($releaseBuild.ExitCode -ne 0) { throw "Release GDExtension build failed with exit code $($releaseBuild.ExitCode)" }
        } finally {
            if ($hadNativeErrorPreference) {
                $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
            }
            Pop-Location
        }
    }

    if ($Godot) {
        $godotExe = (Get-Command godot4 -ErrorAction SilentlyContinue).Source
        if (-not $godotExe) { $godotExe = (Get-Command godot -ErrorAction SilentlyContinue).Source }
        if (-not $godotExe) {
            $defaultGodot = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe'
            if (Test-Path -LiteralPath $defaultGodot) { $godotExe = $defaultGodot }
        }
        if (-not $godotExe) { throw 'Godot executable was not found on PATH.' }
        $tests = @(
            'country_reference_trace_test.gd',
            'country_runtime_test.gd',
            'runtime_country_pod_test.gd',
            'runtime_country_peer_bridge_test.gd',
            'runtime_country_save_roundtrip_test.gd',
            'runtime_country_host_protocol_test.gd',
            'runtime_country_parity_test.gd',
            'runtime_country_economy_transaction_test.gd',
            'economy_fiscal_reservation_continuation_test.gd'
        )
        foreach ($test in $tests) {
            $testProcess = Start-Process -FilePath $godotExe -ArgumentList @(
                '--headless', '--path', 'Project/project-keynes',
                '--script', "res://tests/$test") -Wait -PassThru -NoNewWindow
            if ($testProcess.ExitCode -ne 0) {
                throw "Godot test $test failed with exit code $($testProcess.ExitCode)"
            }
        }
    }

    git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'git diff --check failed.' }
    Write-Host 'Country runtime verification passed.'
} finally {
    Pop-Location
}
