<#
.SYNOPSIS
Runs three clean Stage C3 headless ACTIVE/OFF throughput pairs.
#>
[CmdletBinding()]
param(
    [string]$GodotExe = '',
    [string]$RunId = '',
    [string]$OutputRoot = '',
    [ValidateRange(1, 100)][int]$PairCount = 3,
    [ValidateRange(1, 1000000)][int]$Days = 50,
    [int]$Seed = 20260718,
    [int]$Width = 60,
    [int]$Height = 40,
    [int]$ForeignCount = 3,
    [double]$Speed = 50,
    [switch]$ReuseExistingRuns
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$projectPath = Join-Path $repoRoot 'Project\project-keynes'
. (Join-Path $PSScriptRoot 'Resolve-GodotBin.ps1')
. (Join-Path $PSScriptRoot 'AuthorityStageC.Common.ps1')
$godot = Resolve-GodotBin -GodotExe $GodotExe
if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = 'headless-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
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
    $authority = if ($mode -eq 'ACTIVE') { 'on' } else { 'off' }
    $arguments = @(
        '--headless', '--path', $projectPath, '--script', 'res://tests/headless_perf_record.gd', '--',
        "label=$name", "output_dir=$dir", "climate_authority=$authority", "days=$Days",
        "seed=$Seed", "width=$Width", "height=$Height", "foreign_count=$ForeignCount", "speed=$Speed"
    )
    if (-not ($ReuseExistingRuns -and (Test-Path -LiteralPath (Join-Path $dir 'headless_session.json')) -and (Test-Path -LiteralPath (Join-Path $dir 'headless_metrics.csv')))) {
        Write-Host "[stage-c/C3] $name ($($index + 1)/$($sequence.Count))"
        & $godot @arguments 2>&1 | Tee-Object -LiteralPath $log
        if ($LASTEXITCODE -ne 0) { throw "Godot run failed ($LASTEXITCODE): $name; see $log" }
    } else {
        Write-Host "[stage-c/C3] reuse $name"
    }
    $sessionPath = Join-Path $dir 'headless_session.json'
    $metricsPath = Join-Path $dir 'headless_metrics.csv'
    if (-not (Test-Path -LiteralPath $sessionPath) -or -not (Test-Path -LiteralPath $metricsPath)) { throw "Missing Stage C3 output for $name" }
    $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    $metrics = Import-Csv -LiteralPath $metricsPath | Select-Object -First 1
    $sessionValid = $session.schema -eq 'AuthorityStageCHeadlessSession' -and $session.schema_version -eq 1 `
        -and $session.authority_mode -eq $mode -and $session.build -eq 'Debug' `
        -and $session.seed -eq $Seed -and $session.map_width -eq $Width -and $session.map_height -eq $Height `
        -and $session.foreign_count -eq $ForeignCount -and $session.speed -eq $Speed `
        -and $session.requested_days -eq $Days -and $session.effective_days -eq $Days
    if (-not $sessionValid) { throw "Invalid or incompatible Stage C3 session output for $name" }
    $runs.Add([pscustomobject]@{
        run_index=$index + 1; run_name=$name; mode=$mode; directory=$dir
        run_ms=[double]$metrics.run_ms
        harness_writeback_window_ms=[double]$metrics.harness_writeback_window_ms
        harness_writeback_consume_ms=[double]$metrics.harness_writeback_consume_ms
        harness_idle_wait_ms=[double]$metrics.harness_idle_wait_ms
        harness_adjusted_run_ms=[double]$metrics.harness_adjusted_run_ms
        harness_lower_bound_run_ms=[double]$metrics.harness_lower_bound_run_ms
        raw_days_per_second=[double]$metrics.raw_days_per_second
        adjusted_days_per_second=[double]$metrics.adjusted_days_per_second
        lower_bound_days_per_second=[double]$metrics.lower_bound_days_per_second
        harness_writeback_poll_count=[long]$metrics.harness_writeback_poll_count
		completed_days_delta=[double]$metrics.completed_days_delta
		pulse_count_delta=[double]$metrics.pulse_count_delta
		abi_calls_delta=[double]$metrics.abi_calls_delta
		gdscript_callbacks_delta=[double]$metrics.gdscript_callbacks_delta
		work_done_delta=[double]$metrics.work_done_delta
		budget_yields_delta=[double]$metrics.budget_yields_delta
		day_stage_count_end=[double]$metrics.day_stage_count_end
		day_stage_count_delta=[double]$metrics.day_stage_count_delta
		day_completed_stage_count_end=[double]$metrics.day_completed_stage_count_end
		day_completed_stage_count_delta=[double]$metrics.day_completed_stage_count_delta
		day_work_units_end=[double]$metrics.day_work_units_end
		day_work_units_delta=[double]$metrics.day_work_units_delta
		last_elapsed_us=[double]$metrics.last_elapsed_us_end
		post_pulse_flush_ms=[double]$metrics.post_pulse_flush_ms_end
		flush_slot_count_end=[double]$metrics.flush_slot_count_end
		flush_slot_count_delta=[double]$metrics.flush_slot_count_delta
		worker_fault_count=[long]$metrics.worker_fault_count
		main_wait_on_sim_us=[long]$metrics.main_wait_on_sim_us
		climate_pod_plan_ms=[double]$metrics.climate_pod_plan_ms_end
		climate_pod_replay_ms=[double]$metrics.climate_pod_replay_ms_end
		domain_authority_plan_ms=[double]$metrics.domain_authority_plan_ms_end
		domain_authority_replay_ms=[double]$metrics.domain_authority_replay_ms_end
		active_worker_plan_ms=if($mode -eq 'ACTIVE'){[double]$metrics.climate_pod_plan_ms_end}else{0.0}
		active_worker_replay_ms=if($mode -eq 'ACTIVE'){[double]$metrics.climate_pod_replay_ms_end}else{0.0}
        shadow_diagnostic_plan_ms=if($mode -eq 'OFF'){[double]$metrics.climate_pod_plan_ms_end}else{0.0}
        shadow_diagnostic_replay_ms=if($mode -eq 'OFF'){[double]$metrics.climate_pod_replay_ms_end}else{0.0}
    })
}

$pairs = [System.Collections.Generic.List[object]]::new()
for ($pair = 0; $pair -lt $PairCount; $pair++) {
    $first = $runs[$pair * 2]; $second = $runs[$pair * 2 + 1]
    $active = if ($first.mode -eq 'ACTIVE') { $first } else { $second }
    $off = if ($first.mode -eq 'OFF') { $first } else { $second }
    $delta = $active.adjusted_days_per_second - $off.adjusted_days_per_second
    $percent = if ($off.adjusted_days_per_second -ne 0) { $delta / $off.adjusted_days_per_second * 100.0 } else { 0.0 }
    $pairs.Add([pscustomobject]@{pair=$pair+1;direction="$($first.mode)->$($second.mode)";off_adjusted_days_per_second=$off.adjusted_days_per_second;active_adjusted_days_per_second=$active.adjusted_days_per_second;active_minus_off_days_per_second=$delta;active_minus_off_percent=$percent})
}
$pairDeltas = @($pairs | ForEach-Object { [double]$_.active_minus_off_days_per_second })
$pairPercents = @($pairs | ForEach-Object { [double]$_.active_minus_off_percent })
$allPositive = $PairCount -eq 3 -and @($pairDeltas | Where-Object { $_ -le 0.0 }).Count -eq 0
$allNegative = $PairCount -eq 3 -and @($pairDeltas | Where-Object { $_ -ge 0.0 }).Count -eq 0
$medianPercent = Get-StageCPercentile $pairPercents 50
$positive = $allPositive -and $medianPercent -ge 3.0
$negative = $allNegative -and $medianPercent -le -3.0
$verdict = if ($positive) { 'consistent_adjusted_throughput_gain' } elseif ($negative) { 'consistent_adjusted_throughput_regression' } else { 'mixed_or_no_material_throughput_evidence' }
$runs | Export-Csv -LiteralPath (Join-Path $runRoot 'summary.csv') -NoTypeInformation -Encoding utf8NoBOM
Write-StageCJson (Join-Path $runRoot 'summary.json') ([ordered]@{schema='AuthorityStageCHeadlessSummary';schema_version=1;scope='C3 adjusted throughput only; C1 owns frame-latency conclusions';verdict=$verdict;runs=$runs.ToArray();pairs=$pairs.ToArray()})
$md = [System.Collections.Generic.List[string]]::new()
$md.Add('# Authority Stage C3 headless report'); $md.Add('')
$md.Add('C3 measures harness-adjusted throughput only. C1 is the frame-latency authority.'); $md.Add('')
$md.Add("Verdict: **$verdict**"); $md.Add('')
$md.Add('| Pair | Direction | OFF adjusted days/s | ACTIVE adjusted days/s | Delta % |')
$md.Add('|---:|---|---:|---:|---:|')
foreach($pair in $pairs){
    $line = '| {0} | {1} | {2:F3} | {3:F3} | {4:F2}% |' -f @(
        $pair.pair, $pair.direction, $pair.off_adjusted_days_per_second,
        $pair.active_adjusted_days_per_second, $pair.active_minus_off_percent)
    $md.Add($line)
}
$md.Add(''); $md.Add('`summary.csv` separates raw, idle-adjusted, and whole-window lower-bound timings, plus ACTIVE worker and OFF/SHADOW diagnostic timing.')
$md | Set-Content -LiteralPath (Join-Path $runRoot 'summary.md') -Encoding utf8NoBOM
Write-Host "[stage-c/C3] verdict=$verdict output=$runRoot"
