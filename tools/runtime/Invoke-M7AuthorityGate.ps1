<#
.SYNOPSIS
    Runs the M7 authority gate in its required fail-closed order.

.DESCRIPTION
    The gate deliberately stops after preflight when the building or runtime
    regression suites report a failure. Later stages must only be enabled by
    explicit callers once the corresponding evidence producers are available;
    this prevents a partial run from being reported as 0xFFF ACTIVE evidence.
##>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$GodotExe = '',
    [string]$OutDir = '',
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
if ($OutDir -eq '') { $OutDir = Join-Path $root 'artifacts\runtime\m7-gate' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

. (Join-Path $root 'tools\runtime\Resolve-GodotBin.ps1')
$godot = Resolve-GodotBin -GodotExe $GodotExe
$project = Join-Path $root 'Project\project-keynes'

function Invoke-GodotTest([string]$Name, [string]$Script) {
    $log = Join-Path $OutDir ($Name + '.log')
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $godot --headless --path $project --script $Script --quit 2>&1 |
            Tee-Object -FilePath $log | Out-Null
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    $text = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
    $failed = $exitCode -ne 0 -or $text -match '\[FAIL\]|SCRIPT ERROR|Parse Error|=== native .* FAIL'
    return [ordered]@{ name = $Name; script = $Script; exit_code = $exitCode; log = $log; passed = (-not $failed) }
}

$stages = [System.Collections.Generic.List[object]]::new()
$specialized = @(
    @{ name = 'm1-d7-gate'; script = 'res://tests/runtime_economy_d7_gate_test.gd' },
    @{ name = 'm1-opcode-ack'; script = 'res://tests/runtime_economy_opcode_ack_test.gd' },
    @{ name = 'm2-economy-soak'; script = 'res://tests/runtime_economy_authority_soak_test.gd' },
    @{ name = 'm2-stage-ops-parity'; script = 'res://tests/runtime_economy_stage_ops_soak_parity_test.gd' },
    @{ name = 'm3-effect-pod'; script = 'res://tests/runtime_effect_pod_test.gd' },
    @{ name = 'm3-events-pod'; script = 'res://tests/runtime_events_pod_test.gd' },
    @{ name = 'm3-effect-transaction'; script = 'res://tests/effect_native_multidomain_transaction_test.gd' },
    @{ name = 'm6-authority-fault-gate'; script = 'res://tests/runtime_authority_m5_m6_gate_test.gd' }
)
$preflight = Invoke-GodotTest 'preflight-building' 'res://tests/building_runtime_test.gd'
$stages.Add($preflight)
$runtime = Invoke-GodotTest 'preflight-runtime-parity' 'res://tests/runtime_economy_parity_test.gd'
$stages.Add($runtime)
foreach ($test in $specialized) {
    $stage = Invoke-GodotTest $test.name $test.script
    $stages.Add($stage)
}

$result = [ordered]@{
    gate = 'M7'
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    implemented_domain_mask = 0xFFF
    requested_domain_mask = 0
    authoritative_domain_mask = 0
    completed_domain_mask = 0
    stage_order = @('PROBE','PER_DOMAIN_PARITY','FULL_PARITY','FULL_ACTIVE','PERFORMANCE')
    completed_stages = @('PREFLIGHT')
    blocked_stage = $null
    stages = $stages
    fatal = $false
    fault = ''
}
$specialized_failed = @($stages | Where-Object { -not $_.passed }).Count -gt 0
if (-not $preflight.passed -or -not $runtime.passed -or $specialized_failed) {
    $result.fatal = $true
    $result.blocked_stage = 'PROBE'
    $result.fault = 'preflight_or_specialized_regression_failed'
} else {
    # No probe/parity/ACTIVE evidence producer is wired into this entry point yet.
    $result.blocked_stage = 'PROBE'
    $result.fault = 'probe_evidence_not_available'
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'gate.json') -Encoding UTF8
if ($result.fatal) { exit 1 }
exit 2

