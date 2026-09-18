<#
.SYNOPSIS
    Runs the M7 authority gate in fail-closed order with per-stage manifests.

.DESCRIPTION
    Fixed stage order (never reorder, never skip evidence):

        PROBE
        → PER_DOMAIN_PARITY
        → FULL_0xFFF_PARITY
        → FULL_0xFFF_ACTIVE
        → PERFORMANCE

    Each stage writes into a unique artifact directory under OutDir and emits a
    complete manifest.json. Missing evidence, failures>0, fallback_count>0, or a
    partial mask presented as full ACTIVE causes an immediate non-zero exit.
    Stages without a wired runner still emit a fail-closed manifest so later
    wiring can replace blocked_reason without changing schema.
#>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$GodotExe = '',
    [string]$OutDir = '',
    [int]$TimeoutSeconds = 900,
    [int]$Seed = 20260718,
    [int]$PerfDays = 50
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
if ($OutDir -eq '') {
    $OutDir = Join-Path $root ("artifacts\runtime\m7-gate\{0}" -f $runId)
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

. (Join-Path $root 'tools\runtime\Resolve-GodotBin.ps1')
$godot = Resolve-GodotBin -GodotExe $GodotExe
$project = Join-Path $root 'Project\project-keynes'
$implementedMask = 0xFFF
$fullMask = 0xFFF

function Get-FileSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-StageManifest {
    param(
        [string]$Stage,
        [string]$StageDir,
        [hashtable]$Fields
    )
    $manifest = [ordered]@{
        stage = $Stage
        seed = $Seed
        config_hash = ''
        catalog_hash = ''
        requested_authority_mask = 0
        granted_authority_mask = 0
        implemented_domain_mask = $implementedMask
        completed_domain_mask = 0
        active_evidence_mask = 0
        generation = 0
        day = 0
        state_hash = 0
        market_hash = 0
        audit_hash = 0
        failures = 0
        fallback_count = 0
        p50_latency_us = 0
        p95_latency_us = 0
        max_latency_us = 0
        blocked_reason = ''
        prior_stage_manifest = ''
        artifact_dir = $StageDir
        generated_utc = (Get-Date).ToUniversalTime().ToString('o')
        run_id = $runId
        accepts_old_artifact = $false
    }
    foreach ($key in $Fields.Keys) {
        $manifest[$key] = $Fields[$key]
    }
    $path = Join-Path $StageDir 'manifest.json'
    ($manifest | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $path -Encoding UTF8
    return $manifest
}

function Assert-ManifestReady {
    param(
        [hashtable]$Manifest,
        [string]$Stage,
        [string]$PriorManifestPath = ''
    )
    $required = @(
        'stage','seed','config_hash','catalog_hash',
        'requested_authority_mask','granted_authority_mask',
        'implemented_domain_mask','completed_domain_mask','active_evidence_mask',
        'generation','day','state_hash','market_hash','audit_hash',
        'failures','fallback_count','p50_latency_us','p95_latency_us','max_latency_us'
    )
    foreach ($key in $required) {
        if (-not $Manifest.Contains($key)) {
            throw "M7 $Stage missing manifest field: $key"
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.config_hash) -or
        [string]::IsNullOrWhiteSpace([string]$Manifest.catalog_hash)) {
        throw "M7 $Stage missing config/catalog hash evidence"
    }
    if ($PriorManifestPath -ne '') {
        if (-not (Test-Path -LiteralPath $PriorManifestPath)) {
            throw "M7 $Stage missing prior-stage manifest: $PriorManifestPath"
        }
        $priorHash = Get-FileSha256 $PriorManifestPath
        if ([string]$Manifest.prior_stage_manifest -ne $priorHash) {
            throw "M7 $Stage prior_stage_manifest hash mismatch"
        }
    }
    if ([int]$Manifest.failures -ne 0) {
        throw "M7 $Stage failures=$($Manifest.failures)"
    }
    if ([int]$Manifest.fallback_count -ne 0) {
        throw "M7 $Stage fallback_count=$($Manifest.fallback_count)"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Manifest.blocked_reason)) {
        throw "M7 $Stage blocked: $($Manifest.blocked_reason)"
    }
}

function Invoke-GodotScript {
    param(
        [string]$Name,
        [string]$Script,
        [string]$StageDir,
        [string[]]$ExtraArgs = @()
    )
    $log = Join-Path $StageDir ($Name + '.log')
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $argList = @('--headless', '--path', $project, '--script', $Script, '--quit') + $ExtraArgs
        & $godot @argList 2>&1 | Tee-Object -FilePath $log | Out-Null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    $text = if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Raw
    } else { '' }
    $failed = $exitCode -ne 0 -or $text -match '\[FAIL\]|SCRIPT ERROR|Parse Error|=== native .* FAIL'
    return [ordered]@{
        name = $Name
        script = $Script
        exit_code = $exitCode
        log = $log
        passed = (-not $failed)
    }
}

function Write-FailClosedStage {
    param(
        [string]$Stage,
        [string]$StageDir,
        [string]$ConfigHash,
        [string]$CatalogHash,
        [string]$PriorManifestPath,
        [string]$BlockedReason,
        [int]$RequestedMask = 0,
        [int]$ActiveEvidenceMask = 0
    )
    $priorHash = if ($PriorManifestPath -ne '') { Get-FileSha256 $PriorManifestPath } else { '' }
    return New-StageManifest -Stage $Stage -StageDir $StageDir -Fields @{
        config_hash = $ConfigHash
        catalog_hash = $CatalogHash
        requested_authority_mask = $RequestedMask
        granted_authority_mask = 0
        completed_domain_mask = 0
        active_evidence_mask = $ActiveEvidenceMask
        failures = 1
        fallback_count = 0
        blocked_reason = $BlockedReason
        prior_stage_manifest = $priorHash
    }
}

# --- Freeze run hashes (reject reuse of older artifact trees) ---
$protocolHeader = Join-Path $root 'gdext\src\runtime_pod_protocol.h'
$economyCatalog = Join-Path $root 'Project\project-keynes\data\economy\default_economy.tres'
$configHash = Get-FileSha256 $protocolHeader
$catalogHash = Get-FileSha256 $economyCatalog
if ($configHash -eq '' -or $catalogHash -eq '') {
    throw 'M7 unable to hash config/catalog inputs'
}

$gateSummary = [ordered]@{
    gate = 'M7'
    run_id = $runId
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    seed = $Seed
    config_hash = $configHash
    catalog_hash = $catalogHash
    implemented_domain_mask = $implementedMask
    stage_order = @('PROBE','PER_DOMAIN_PARITY','FULL_0xFFF_PARITY','FULL_0xFFF_ACTIVE','PERFORMANCE')
    completed_stages = @()
    blocked_stage = $null
    fatal = $false
    fault = ''
    stages = [System.Collections.Generic.List[object]]::new()
}

$stageOrder = @(
    'PROBE',
    'PER_DOMAIN_PARITY',
    'FULL_0xFFF_PARITY',
    'FULL_0xFFF_ACTIVE',
    'PERFORMANCE'
)
$priorManifestPath = ''

try {
    foreach ($stageName in $stageOrder) {
        $stageDir = Join-Path $OutDir $stageName
        if (Test-Path -LiteralPath $stageDir) {
            throw "M7 refuses to reuse existing stage artifact dir: $stageDir"
        }
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
        Write-Host ("=== M7 {0} ===" -f $stageName) -ForegroundColor Cyan

        $manifest = $null
        switch ($stageName) {
            'PROBE' {
                # Probe evidence runner is not yet a dedicated M7 producer.
                # Emit a complete fail-closed manifest so wiring can replace
                # blocked_reason without schema churn.
                $probeTests = @(
                    @{ name = 'm6-authority-fault-gate'; script = 'res://tests/runtime_authority_m5_m6_gate_test.gd' }
                )
                $probeResults = @()
                foreach ($test in $probeTests) {
                    if (-not (Test-Path -LiteralPath (Join-Path $project ($test.script -replace '^res://','')))) {
                        $probeResults += [ordered]@{
                            name = $test.name
                            script = $test.script
                            exit_code = 2
                            log = ''
                            passed = $false
                            note = 'script_missing'
                        }
                        continue
                    }
                    $probeResults += Invoke-GodotScript -Name $test.name -Script $test.script -StageDir $stageDir
                }
                ($probeResults | ConvertTo-Json -Depth 6) |
                    Set-Content -LiteralPath (Join-Path $stageDir 'probe-results.json') -Encoding UTF8
                $anyFailed = @($probeResults | Where-Object { -not $_.passed }).Count -gt 0
                if ($anyFailed) {
                    $manifest = Write-FailClosedStage -Stage $stageName -StageDir $stageDir `
                        -ConfigHash $configHash -CatalogHash $catalogHash `
                        -PriorManifestPath '' -BlockedReason 'probe_regression_failed' `
                        -RequestedMask 0
                } else {
                    # Still blocked: no dedicated PROBE evidence producer wired
                    # into this gate that proves domain probe hashes.
                    $manifest = Write-FailClosedStage -Stage $stageName -StageDir $stageDir `
                        -ConfigHash $configHash -CatalogHash $catalogHash `
                        -PriorManifestPath '' -BlockedReason 'probe_evidence_runner_not_wired' `
                        -RequestedMask 0
                }
            }
            'PER_DOMAIN_PARITY' {
                $manifest = Write-FailClosedStage -Stage $stageName -StageDir $stageDir `
                    -ConfigHash $configHash -CatalogHash $catalogHash `
                    -PriorManifestPath $priorManifestPath `
                    -BlockedReason 'per_domain_parity_runner_not_wired' `
                    -RequestedMask 0
            }
            'FULL_0xFFF_PARITY' {
                $manifest = Write-FailClosedStage -Stage $stageName -StageDir $stageDir `
                    -ConfigHash $configHash -CatalogHash $catalogHash `
                    -PriorManifestPath $priorManifestPath `
                    -BlockedReason 'full_0xfff_parity_runner_not_wired' `
                    -RequestedMask $fullMask
            }
            'FULL_0xFFF_ACTIVE' {
                # Never rewrite a partial mask as full ACTIVE evidence.
                $manifest = Write-FailClosedStage -Stage $stageName -StageDir $stageDir `
                    -ConfigHash $configHash -CatalogHash $catalogHash `
                    -PriorManifestPath $priorManifestPath `
                    -BlockedReason 'full_0xfff_active_runner_not_wired' `
                    -RequestedMask $fullMask `
                    -ActiveEvidenceMask 0
                if ([int]$manifest.active_evidence_mask -ne 0 -and
                    [int]$manifest.active_evidence_mask -ne $fullMask) {
                    throw 'M7 refuses partial active_evidence_mask as FULL_0xFFF_ACTIVE'
                }
            }
            'PERFORMANCE' {
                $perfScript = 'res://tests/headless_perf_record.gd'
                $perfRel = Join-Path $project 'tests\headless_perf_record.gd'
                if (-not (Test-Path -LiteralPath $perfRel)) {
                    $manifest = Write-FailClosedStage -Stage $stageName -StageDir $stageDir `
                        -ConfigHash $configHash -CatalogHash $catalogHash `
                        -PriorManifestPath $priorManifestPath `
                        -BlockedReason 'performance_runner_missing'
                } else {
                    $perfOut = Join-Path $stageDir 'perf'
                    New-Item -ItemType Directory -Path $perfOut -Force | Out-Null
                    $result = Invoke-GodotScript -Name 'headless-perf' -Script $perfScript `
                        -StageDir $stageDir -ExtraArgs @(
                            '--',
                            ("days={0}" -f $PerfDays),
                            ("seed={0}" -f $Seed),
                            ("output_dir={0}" -f $perfOut),
                            'label=m7-performance'
                        )
                    $sessionPath = Get-ChildItem -LiteralPath $perfOut -Filter '*.json' -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                    $session = $null
                    if ($sessionPath) {
                        $session = Get-Content -LiteralPath $sessionPath.FullName -Raw | ConvertFrom-Json
                    }
                    $failures = if ($result.passed) { 0 } else { 1 }
                    $fallback = 0
                    $mainWait = 0
                    $authDaysPerSec = 0.0
                    $workerFault = 0
                    if ($session -ne $null) {
                        if ($session.PSObject.Properties.Name -contains 'main_wait_on_sim_us') {
                            $mainWait = [int64]$session.main_wait_on_sim_us
                        }
                        if ($session.PSObject.Properties.Name -contains 'authoritative_days_per_second') {
                            $authDaysPerSec = [double]$session.authoritative_days_per_second
                        } elseif ($session.PSObject.Properties.Name -contains 'adjusted_days_per_second') {
                            $authDaysPerSec = [double]$session.adjusted_days_per_second
                        }
                        if ($session.PSObject.Properties.Name -contains 'worker_fault_count') {
                            $workerFault = [int]$session.worker_fault_count
                        }
                        if ($session.PSObject.Properties.Name -contains 'fallback_count') {
                            $fallback = [int]$session.fallback_count
                        }
                    } else {
                        $failures = 1
                    }
                    # Checkpoint: authoritative throughput >= 50 days/s.
                    if ($authDaysPerSec -lt 50.0) { $failures += 1 }
                    if ($mainWait -ne 0) { $failures += 1 }
                    if ($workerFault -ne 0) { $failures += 1 }
                    $blocked = ''
                    if ($failures -ne 0) {
                        $blocked = 'performance_threshold_or_evidence_failed'
                    }
                    $priorHash = Get-FileSha256 $priorManifestPath
                    $manifest = New-StageManifest -Stage $stageName -StageDir $stageDir -Fields @{
                        config_hash = $configHash
                        catalog_hash = $catalogHash
                        requested_authority_mask = $fullMask
                        granted_authority_mask = 0
                        completed_domain_mask = 0
                        active_evidence_mask = 0
                        failures = $failures
                        fallback_count = $fallback
                        blocked_reason = $blocked
                        prior_stage_manifest = $priorHash
                        main_wait_on_sim_us = $mainWait
                        authoritative_days_per_second = $authDaysPerSec
                        worker_fault_count = $workerFault
                        perf_result = $result
                    }
                }
            }
        }

        $manifestPath = Join-Path $stageDir 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "M7 $stageName did not emit manifest.json"
        }
        $gateSummary.stages.Add([ordered]@{
            stage = $stageName
            artifact_dir = $stageDir
            manifest = $manifestPath
            failures = [int]$manifest.failures
            blocked_reason = [string]$manifest.blocked_reason
        })

        # Fail closed: validate and stop before enabling later stages.
        Assert-ManifestReady -Manifest $manifest -Stage $stageName -PriorManifestPath $priorManifestPath
        $gateSummary.completed_stages += $stageName
        $priorManifestPath = $manifestPath
    }
} catch {
    $gateSummary.fatal = $true
    $gateSummary.fault = [string]$_.Exception.Message
    if ($null -eq $gateSummary.blocked_stage) {
        $remaining = $stageOrder | Where-Object { $gateSummary.completed_stages -notcontains $_ }
        $gateSummary.blocked_stage = @($remaining)[0]
    }
    ($gateSummary | ConvertTo-Json -Depth 10) |
        Set-Content -LiteralPath (Join-Path $OutDir 'gate.json') -Encoding UTF8
    Write-Error $gateSummary.fault
    exit 1
}

($gateSummary | ConvertTo-Json -Depth 10) |
    Set-Content -LiteralPath (Join-Path $OutDir 'gate.json') -Encoding UTF8
Write-Host "M7 gate completed under $OutDir" -ForegroundColor Green
exit 0
