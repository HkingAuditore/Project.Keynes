<#
.SYNOPSIS
Runs the runtime headless test suite and archives per-test logs.

.DESCRIPTION
Executes the runtime_*.gd SceneTree tests plus the dots_completion static gate,
writing one log per test into the artifacts directory along with a combined
unit-test.log and a machine-readable test-summary.json.

Godot's exit code alone is not trustworthy for these harnesses: several print
failures and still quit cleanly. Each log is therefore also scanned for
failure markers, and a test counts as passed only if both signals agree.
#>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$OutDir = '',
    [string]$GodotExe = '',
    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $root 'tools\runtime\Resolve-GodotBin.ps1')
$godot = Resolve-GodotBin -GodotExe $GodotExe
$project = Join-Path $root 'Project\project-keynes'

if ($OutDir -eq '') { $OutDir = Join-Path $root 'artifacts\runtime\s0-baseline' }
$logDir = Join-Path $OutDir 'tests'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

$tests = @(
    'tests/runtime_protocol_guard_test.gd',
    'tests/runtime_domain_pod_test.gd',
    'tests/runtime_modifier_pod_test.gd',
    'tests/runtime_events_pod_test.gd',
    'tests/runtime_climate_authority_test.gd',
    'tests/runtime_climate_parity_test.gd',
    'tests/runtime_climate_stage_order_contract_test.gd',
    'tests/runtime_climate_save_roundtrip_test.gd',
    'tests/runtime_country_pod_test.gd',
    'tests/runtime_country_peer_bridge_test.gd',
    'tests/runtime_country_economy_transaction_test.gd',
    'tests/runtime_country_host_protocol_test.gd',
    'tests/runtime_country_parity_test.gd',
    'tests/runtime_country_save_roundtrip_test.gd',
    'tests/runtime_snapshot_ring_test.gd',
    'tests/runtime_save_domain_section_test.gd',
    'tests/runtime_worker_source_scan_test.gd',
    'tests/runtime_thread_isolation_test.gd',
    'tests/runtime_graph_country_committed_test.gd',
    'tests/runtime_generation_tick_gate_test.gd',
    'tests/runtime_trigger_pod_test.gd',
    'tests/runtime_trigger_parity_test.gd',
    'tests/runtime_trigger_save_roundtrip_test.gd',
    'tests/runtime_effect_pod_test.gd',
    'tests/dots_completion/dots_completion_gate.gd'
)

# Markers that mean the harness itself reported a problem even when Godot exits 0.
$failurePattern = 'FAIL\b|FAILED|ASSERT|assertion failed|Traceback|SCRIPT ERROR|Cannot call method|Invalid call|Parse Error|Condition ".*" is (true|false)'

$results = @()
foreach ($relative in $tests) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($relative)
    $logPath = Join-Path $logDir "$name.log"
    Write-Host "running $name ..." -NoNewline

    $started = Get-Date
    $godotArgs = @(
        '--headless',
        '--path', $project,
        '--script', "res://$relative",
        '--quit'
    )
    # Godot writes warnings and the RID-leak notice to stderr. Under Stop mode a
    # merged pipeline turns the first one into a terminating NativeCommandError,
    # so the child process gets its own Continue scope.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $godot @godotArgs 2>&1 | Tee-Object -FilePath $logPath | Out-Null
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorAction }
    $elapsed = ((Get-Date) - $started).TotalSeconds

    $logText = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
    if ($null -eq $logText) { $logText = '' }
    $markers = [regex]::Matches($logText, $failurePattern) | ForEach-Object { $_.Value } | Select-Object -Unique
    $passed = ($exitCode -eq 0) -and ($markers.Count -eq 0)

    $results += [ordered]@{
        name            = $name
        script          = $relative
        exit_code       = $exitCode
        elapsed_seconds = [math]::Round($elapsed, 2)
        log             = "tests/$name.log"
        log_bytes       = $logText.Length
        failure_markers = @($markers)
        passed          = $passed
    }

    $verdict = if ($passed) { 'PASS' } else { "FAIL (exit=$exitCode markers=$($markers -join ','))" }
    Write-Host " $verdict  [$([math]::Round($elapsed,1))s]"
}

# Combined log so a single file can be attached as evidence.
$combined = Join-Path $OutDir 'unit-test.log'
$builder = New-Object System.Text.StringBuilder
foreach ($result in $results) {
    [void]$builder.AppendLine('=' * 78)
    [void]$builder.AppendLine("TEST   : $($result.name)")
    [void]$builder.AppendLine("SCRIPT : $($result.script)")
    [void]$builder.AppendLine("EXIT   : $($result.exit_code)   PASSED: $($result.passed)   $($result.elapsed_seconds)s")
    [void]$builder.AppendLine('=' * 78)
    $individual = Join-Path $logDir "$($result.name).log"
    if (Test-Path -LiteralPath $individual) {
        [void]$builder.AppendLine((Get-Content -LiteralPath $individual -Raw))
    }
    [void]$builder.AppendLine()
}
Set-Content -LiteralPath $combined -Value $builder.ToString() -Encoding UTF8

# The source scan test is the §26 source-scan artifact; surface it separately.
$scanLog = Join-Path $logDir 'runtime_worker_source_scan_test.log'
if (Test-Path -LiteralPath $scanLog) {
    Copy-Item -LiteralPath $scanLog -Destination (Join-Path $OutDir 'source-scan.log') -Force
}

$passCount = @($results | Where-Object { $_.passed }).Count
$summary = [ordered]@{
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    godot         = $godot
    total         = $results.Count
    passed        = $passCount
    failed        = $results.Count - $passCount
    results       = $results
}
$summary | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $OutDir 'test-summary.json') -Encoding UTF8

Write-Host ''
Write-Host "$passCount/$($results.Count) passed -> $OutDir"
if ($passCount -ne $results.Count) {
    Write-Host 'failed:' -ForegroundColor Yellow
    foreach ($result in $results | Where-Object { -not $_.passed }) {
        Write-Host "  $($result.name)  exit=$($result.exit_code)  $($result.failure_markers -join ' | ')"
    }
    exit 1
}
