<#
.SYNOPSIS
Runs the Stage C visible Debug client ACTIVE/OFF frame-latency pairs.
#>
[CmdletBinding()]
param(
    [string]$GodotExe = '',
    [string]$RunId = '',
    [string]$OutputRoot = '',
    [ValidateRange(1, 100)][int]$PairCount = 3,
    [int]$Seed = 20260718,
    [int]$Width = 60,
    [int]$Height = 40,
    [int]$ForeignCount = 3,
    [double]$Speed = 50,
    [double]$WarmupSeconds = 5,
    [double]$RecordSeconds = 30,
    [switch]$ReuseExistingRuns
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$projectPath = Join-Path $repoRoot 'Project\project-keynes'
. (Join-Path $PSScriptRoot 'Resolve-GodotBin.ps1')
. (Join-Path $PSScriptRoot 'AuthorityStageC.Common.ps1')
$godot = Resolve-GodotBin -GodotExe $GodotExe

if ($PairCount -ne 3) { Write-Warning 'The acceptance verdict requires exactly 3 pairs; this run will remain non-acceptance evidence.' }
if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = 'client-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $repoRoot 'artifacts\runtime\authority-stage-c' }
$runRoot = Join-Path $OutputRoot $RunId
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

$sequence = [System.Collections.Generic.List[string]]::new()
for ($pair = 0; $pair -lt $PairCount; $pair++) {
    if (($pair % 2) -eq 0) { $sequence.Add('OFF'); $sequence.Add('ACTIVE') }
    else { $sequence.Add('ACTIVE'); $sequence.Add('OFF') }
}

$runs = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $sequence.Count; $index++) {
    $mode = $sequence[$index]
    $name = 'run-{0:d2}-{1}' -f ($index + 1), $mode.ToLowerInvariant()
    $dir = Join-Path $runRoot $name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $log = Join-Path $dir 'godot.log'
    $arguments = @(
        '--path', $projectPath,
        'res://tests/authority_stage_c_client_runner.tscn', '--',
        "mode=$mode", "run_id=$name", "output_dir=$dir", "seed=$Seed",
        "width=$Width", "height=$Height", "foreign_count=$ForeignCount", "speed=$Speed",
        "warmup_seconds=$WarmupSeconds", "record_seconds=$RecordSeconds"
    )
    if (-not ($ReuseExistingRuns -and (Test-Path -LiteralPath (Join-Path $dir 'session.json')) -and (Test-Path -LiteralPath (Join-Path $dir 'frame_samples.csv')))) {
        Write-Host "[stage-c/C1] $name ($($index + 1)/$($sequence.Count))"
        & $godot @arguments 2>&1 | Tee-Object -LiteralPath $log
        if ($LASTEXITCODE -ne 0) { throw "Godot run failed ($LASTEXITCODE): $name; see $log" }
    } else {
        Write-Host "[stage-c/C1] reuse $name"
    }

    $sessionPath = Join-Path $dir 'session.json'
    $framePath = Join-Path $dir 'frame_samples.csv'
    if (-not (Test-Path -LiteralPath $sessionPath) -or -not (Test-Path -LiteralPath $framePath)) {
        throw "Missing Stage C output for $name"
    }
    $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    $sessionValid = $session.schema -eq 'AuthorityStageCClientSession' -and $session.schema_version -eq 1 `
        -and $session.state -eq 'complete' -and $session.authority_mode -eq $mode -and $session.build -eq 'Debug' `
        -and $session.seed -eq $Seed -and $session.map_width -eq $Width -and $session.map_height -eq $Height `
        -and $session.foreign_count -eq $ForeignCount -and $session.speed -eq $Speed `
        -and $session.warmup_seconds -eq $WarmupSeconds -and $session.record_seconds -eq $RecordSeconds `
        -and $session.actual_window_width -eq 1600 -and $session.actual_window_height -eq 960 `
        -and $session.graphics_profile -eq 'high' -and $session.day_night -eq $true `
        -and $session.overlay -eq $false -and $session.actual_vsync_mode -eq 0 -and $session.actual_max_fps -eq 0
    if (-not $sessionValid) { throw "Invalid or incompatible session output for $name" }
    $all = [System.Collections.Generic.List[double]]::new()
    $fast = [System.Collections.Generic.List[double]]::new()
    $nonFast = [System.Collections.Generic.List[double]]::new()
    Import-Csv -LiteralPath $framePath | ForEach-Object {
        $value = ConvertTo-StageCInvariantDouble $_.frame_wall_ms
        if ([double]::IsNaN($value)) { return }
        $all.Add($value)
        if ([string]$_.fast_tick_occurred -eq 'true') { $fast.Add($value) } else { $nonFast.Add($value) }
    }
    $end = $session.runtime_report_end
    $start = Get-StageCProperty $session 'runtime_report_record_start' $session.runtime_report_start
    $runs.Add([pscustomobject]@{
        run_index = $index + 1; run_name = $name; mode = $mode; directory = $dir
        all_frames = Get-StageCDistribution $all.ToArray()
        fast_tick_frames = Get-StageCDistribution $fast.ToArray()
        non_fast_tick_frames = Get-StageCDistribution $nonFast.ToArray()
        effective_days_per_second = [double](Get-StageCProperty $session 'effective_days_per_second' 0)
        writeback_lag_days = [int](Get-StageCProperty $session 'writeback_lag_days' -1)
        main_wait_on_sim_us = [long](Get-StageCProperty $end 'main_wait_on_sim_us' 0)
        worker_fault_count = [long](Get-StageCProperty $end 'worker_fault_count' 0)
        completed_days_delta = [long](Get-StageCProperty $end 'completed_days' 0) - [long](Get-StageCProperty $start 'completed_days' 0)
        pulse_count_delta = [long](Get-StageCProperty $end 'pulse_count' 0) - [long](Get-StageCProperty $start 'pulse_count' 0)
        abi_calls_delta = [long](Get-StageCProperty $end 'abi_calls' 0) - [long](Get-StageCProperty $start 'abi_calls' 0)
        work_done_delta = [long](Get-StageCProperty $end 'work_done' 0) - [long](Get-StageCProperty $start 'work_done' 0)
        budget_yields_delta = [long](Get-StageCProperty $end 'budget_yields' 0) - [long](Get-StageCProperty $start 'budget_yields' 0)
        runtime_graph_last_elapsed_us = [long](Get-StageCProperty $end 'last_elapsed_us' 0)
        post_pulse_flush_ms = [double](Get-StageCProperty $end 'post_pulse_flush_ms' 0)
        climate_pod_plan_ms = [double](Get-StageCProperty $end 'climate_pod_plan_ms' 0)
        climate_pod_replay_ms = [double](Get-StageCProperty $end 'climate_pod_replay_ms' 0)
        domain_authority_plan_ms = [double](Get-StageCProperty $end 'domain_authority_plan_ms' 0)
        domain_authority_replay_ms = [double](Get-StageCProperty $end 'domain_authority_replay_ms' 0)
        active_worker_plan_ms = if ($mode -eq 'ACTIVE') { [double](Get-StageCProperty $end 'climate_pod_plan_ms' 0) } else { 0.0 }
        active_worker_replay_ms = if ($mode -eq 'ACTIVE') { [double](Get-StageCProperty $end 'climate_pod_replay_ms' 0) } else { 0.0 }
        shadow_diagnostic_plan_ms = if ($mode -eq 'OFF') { [double](Get-StageCProperty $end 'climate_pod_plan_ms' 0) } else { 0.0 }
        shadow_diagnostic_replay_ms = if ($mode -eq 'OFF') { [double](Get-StageCProperty $end 'climate_pod_replay_ms' 0) } else { 0.0 }
    })
}

$pairs = [System.Collections.Generic.List[object]]::new()
for ($pair = 0; $pair -lt $PairCount; $pair++) {
    $first = $runs[$pair * 2]
    $second = $runs[$pair * 2 + 1]
    $active = if ($first.mode -eq 'ACTIVE') { $first } else { $second }
    $off = if ($first.mode -eq 'OFF') { $first } else { $second }
    $delta = [double]$active.all_frames.p50 - [double]$off.all_frames.p50
    $percent = if ([double]$off.all_frames.p50 -ne 0) { $delta / [double]$off.all_frames.p50 * 100.0 } else { 0.0 }
    $pairs.Add([pscustomobject]@{
        pair = $pair + 1; direction = "$($first.mode)->$($second.mode)"
        off_run = $off.run_name; active_run = $active.run_name
        off_p50_ms = [double]$off.all_frames.p50; active_p50_ms = [double]$active.all_frames.p50
        active_minus_off_ms = $delta; active_minus_off_percent = $percent
    })
}
$verdict = Get-StageCPairedVerdict $pairs.ToArray()

$csvRows = foreach ($run in $runs) {
    foreach ($category in @('all_frames', 'fast_tick_frames', 'non_fast_tick_frames')) {
        $stats = $run.$category
        [pscustomobject]@{
            run_index=$run.run_index; run_name=$run.run_name; mode=$run.mode; category=$category
            count=$stats.count; mean_ms=$stats.mean; p50_ms=$stats.p50; p95_ms=$stats.p95
            p99_ms=$stats.p99; max_ms=$stats.max; ge_16_67_ms_ratio=$stats.ge_16_67_ms_ratio
            ge_33_33_ms_ratio=$stats.ge_33_33_ms_ratio
            effective_days_per_second=$run.effective_days_per_second; writeback_lag_days=$run.writeback_lag_days
            main_wait_on_sim_us=$run.main_wait_on_sim_us; worker_fault_count=$run.worker_fault_count
            completed_days_delta=$run.completed_days_delta; pulse_count_delta=$run.pulse_count_delta
            abi_calls_delta=$run.abi_calls_delta; work_done_delta=$run.work_done_delta
            budget_yields_delta=$run.budget_yields_delta
            runtime_graph_last_elapsed_us=$run.runtime_graph_last_elapsed_us; post_pulse_flush_ms=$run.post_pulse_flush_ms
            climate_pod_plan_ms=$run.climate_pod_plan_ms; climate_pod_replay_ms=$run.climate_pod_replay_ms
            domain_authority_plan_ms=$run.domain_authority_plan_ms; domain_authority_replay_ms=$run.domain_authority_replay_ms
            active_worker_plan_ms=$run.active_worker_plan_ms; active_worker_replay_ms=$run.active_worker_replay_ms
            shadow_diagnostic_plan_ms=$run.shadow_diagnostic_plan_ms; shadow_diagnostic_replay_ms=$run.shadow_diagnostic_replay_ms
        }
    }
}
$csvRows | Export-Csv -LiteralPath (Join-Path $runRoot 'summary.csv') -NoTypeInformation -Encoding utf8NoBOM
Write-StageCJson (Join-Path $runRoot 'summary.json') ([ordered]@{
    schema='AuthorityStageCClientSummary'; schema_version=1; classification='Debug development profile only'
    baseline=[ordered]@{seed=$Seed; map="$Width`x$Height"; continents=2; foreign_count=$ForeignCount; speed=$Speed; warmup_seconds=$WarmupSeconds; record_seconds=$RecordSeconds; window='1600x960'; graphics='high'; day_night=$true; overlay=$false; vsync=$false; max_fps=0}
    verdict=$verdict; threshold=[ordered]@{median_ms=0.25; median_percent=3.0; required_pairs=3}
    runs=$runs.ToArray(); pairs=$pairs.ToArray()
})

$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# Authority Stage C1 client report')
$md.Add('')
$md.Add('Debug development profile only. This is not Release acceptance evidence.')
$md.Add('')
$md.Add("Verdict: **$verdict** (all three directions must agree, and the median difference must reach both 0.25 ms and 3%).")
$md.Add('')
$md.Add('| Pair | Direction | OFF p50 ms | ACTIVE p50 ms | Delta ms | Delta % |')
$md.Add('|---:|---|---:|---:|---:|---:|')
foreach ($pair in $pairs) {
    $line = '| {0} | {1} | {2:F3} | {3:F3} | {4:F3} | {5:F2}% |' -f @(
        $pair.pair, $pair.direction, $pair.off_p50_ms, $pair.active_p50_ms,
        $pair.active_minus_off_ms, $pair.active_minus_off_percent)
    $md.Add($line)
}
$md.Add('')
$md.Add('Frame distributions for all, fast-tick, and non-fast-tick frames are in `summary.csv`; worker ACTIVE and SHADOW diagnostic timings are separate columns.')
$md | Set-Content -LiteralPath (Join-Path $runRoot 'summary.md') -Encoding utf8NoBOM
Write-Host "[stage-c/C1] verdict=$verdict output=$runRoot"
