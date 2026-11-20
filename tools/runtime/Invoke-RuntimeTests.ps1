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
    # Hard per-test cap. A headless fixture that never quits used to hang the
    # whole verification command (R7-1), so it is enforced, not just declared.
    [ValidateRange(1, 3600)]
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
    'tests/runtime/runtime_protocol_guard_test.gd',
    'tests/runtime/runtime_domain_pod_test.gd',
    'tests/runtime/runtime_modifier_pod_test.gd',
    'tests/runtime/runtime_events_pod_test.gd',
    'tests/runtime/runtime_climate_authority_test.gd',
    'tests/runtime/runtime_climate_parity_test.gd',
    'tests/runtime/runtime_climate_stage_order_contract_test.gd',
    'tests/world/weather_worker_input_lifetime_test.gd',
    'tests/runtime/runtime_climate_save_roundtrip_test.gd',
    'tests/runtime/runtime_country_pod_test.gd',
    'tests/runtime/runtime_country_peer_bridge_test.gd',
    'tests/runtime/runtime_country_economy_transaction_test.gd',
    'tests/runtime/runtime_country_host_protocol_test.gd',
    'tests/runtime/runtime_country_parity_test.gd',
    'tests/runtime/runtime_ideology_parity_test.gd',
    'tests/runtime/runtime_ideology_parity_guard_test.gd',
    'tests/runtime/runtime_country_save_roundtrip_test.gd',
    'tests/runtime/runtime_snapshot_ring_test.gd',
    'tests/runtime/runtime_save_domain_section_test.gd',
    'tests/runtime/runtime_worker_source_scan_test.gd',
    'tests/runtime/runtime_thread_isolation_test.gd',
    'tests/runtime/runtime_worker_stop_lifetime_test.gd',
    'tests/runtime/runtime_graph_country_committed_test.gd',
    'tests/runtime/runtime_generation_tick_gate_test.gd',
    'tests/runtime/runtime_trigger_pod_test.gd',
    'tests/runtime/runtime_trigger_parity_test.gd',
    'tests/runtime/runtime_trigger_save_roundtrip_test.gd',
    'tests/runtime/runtime_effect_pod_test.gd',
    'tests/ideology/ideology_effect_worker_forward_test.gd',
    'tests/ideology/ideology_effect_metric_publish_test.gd',
    # The effect-instance report had zero GDScript consumers until the card face
    # read it; this pins the summariser and the badge, both pure functions.
    'tests/ideology/ideology_effect_report_test.gd',
    'tests/effect/metric_mask_capacity_test.gd',
    'tests/effect/target_tag_catalog_test.gd',
    'tests/effect/target_tag_dictionary_test.gd',
    # Tag ids are 1-based dictionary indices, so a card that hardcodes one is
    # one insertion away from silently matching different cells. This pins the
    # name -> id resolution that replaced those hardcoded numbers (L5-14).
    'tests/effect/effect_selector_tag_resolution_test.gd',
    # Orphaned until now: nothing referenced this script, so every target-selector
    # assertion it gates (the native synthetic-grid self check) was invisible to
    # the suite even though it was passing.
    'tests/ideology/ideology_target_selector_test.gd',
    'tests/family/family_effect_worker_forward_test.gd',
    'tests/family/family_effect_restore_forward_test.gd',
    'tests/technology/technology_effect_worker_forward_test.gd',
    'tests/runtime/runtime_authority_m5_m6_gate_test.gd',
    'tests/dots_completion/dots_completion_gate.gd'
)

# Markers that mean the harness itself reported a problem even when Godot exits 0.
$failurePattern = 'FAIL\b|FAILED|ASSERT|assertion failed|Traceback|SCRIPT ERROR|Cannot call method|Invalid call|Parse Error|Condition ".*" is (true|false)'

# Known-red, non-blocking (05 §2.8).
#
# The game now ships on the worker authority only; the main-thread ideology path is
# frozen. This parity gate compares the two, so its remaining divergence is not a
# defect to fix -- it is the divergence the freeze deliberately stopped paying for.
# It stays in the list (deleting it would hide the red), runs as before, and is
# reported separately so it cannot be mistaken for a pass.
$knownRed = @(
    'runtime_ideology_parity_test'
)

## Kills a hung test and everything it spawned.
##
## The Godot *_console.exe launcher starts the engine executable as a child, so
## killing the launcher pid alone leaves the engine (and the hang) behind:
## taskkill /T takes the children with it and /F is required because a stuck
## headless engine never answers a polite close request.
function Stop-ProcessTree {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) { return }
    $processId = $Process.Id
    # A refused taskkill writes to stderr; under Stop mode a native command's
    # stderr becomes a terminating NativeCommandError, so this stays local.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & taskkill.exe /PID $processId /T /F *> $null
    }
    catch {
        # taskkill missing or refused: the direct kill below is the fallback.
    }
    finally { $ErrorActionPreference = $previousErrorAction }

    try { $Process.WaitForExit(10000) | Out-Null } catch { }
    if (-not $Process.HasExited) {
        try { $Process.Kill() } catch { }
        try { $Process.WaitForExit(5000) | Out-Null } catch { }
    }
}

## Runs one headless test with both streams captured to their own file and a
## hard timeout.
##
## Start-Process -PassThru leaves ExitCode unset under Windows PowerShell 5.1
## (observed on 5.1.22621), so [System.Diagnostics.Process] is constructed
## directly, as in tools/runtime/Invoke-SaveReplay.ps1. The two streams are read
## asynchronously, so neither can deadlock on a full pipe buffer, and a merged
## `2>&1 | Tee-Object` pipeline (also a Stop-mode NativeCommandError source) is
## not involved any more.
function Invoke-CapturedTest {
    param(
        [string]$GodotExe,
        [string[]]$Arguments,
        [string]$StdoutPath,
        [string]$StderrPath,
        [int]$TimeoutSeconds
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $GodotExe
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') { '"' + ($argument -replace '"', '\"') + '"' }
        else { $argument }
    }
    $startInfo.Arguments = ($quoted -join ' ')

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
    }
    catch {
        $message = "failed to start '$GodotExe': $($_.Exception.Message)"
        [System.IO.File]::WriteAllText($StdoutPath, $message, $utf8)
        [System.IO.File]::WriteAllText($StderrPath, '', $utf8)
        return [pscustomobject]@{ exit_code = -1; timed_out = $false; start_error = $message }
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = $false
    # This wait is the fix: a fixture that never quits must not hang the command.
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        Stop-ProcessTree -Process $process
    }

    $stdoutText = ''
    $stderrText = ''
    if ($stdoutTask.Wait(20000) -and -not $stdoutTask.IsFaulted) { $stdoutText = $stdoutTask.Result }
    if ($stderrTask.Wait(20000) -and -not $stderrTask.IsFaulted) { $stderrText = $stderrTask.Result }
    [System.IO.File]::WriteAllText($StdoutPath, $stdoutText, $utf8)
    [System.IO.File]::WriteAllText($StderrPath, $stderrText, $utf8)

    $exitCode = -1
    if ($process.HasExited) {
        try { $exitCode = $process.ExitCode } catch { $exitCode = -1 }
    }
    $process.Dispose()
    return [pscustomobject]@{ exit_code = $exitCode; timed_out = $timedOut; start_error = '' }
}

$results = @()
foreach ($relative in $tests) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($relative)
    $logPath = Join-Path $logDir "$name.log"
    # stderr has its own file until the run is over; both are merged below.
    $stderrPath = "$logPath.err"
    Write-Host "running $name ..." -NoNewline

    $started = Get-Date
    # Every fixture quits itself after its assertions. --quit would terminate
    # coroutine fixtures on the first frame and incorrectly report a pass.
    $godotArgs = @(
        '--headless',
        '--path', $project,
        '--script', "res://$relative"
    )
    $run = Invoke-CapturedTest -GodotExe $godot -Arguments $godotArgs `
        -StdoutPath $logPath -StderrPath $stderrPath -TimeoutSeconds $TimeoutSeconds
    $elapsed = ((Get-Date) - $started).TotalSeconds
    $exitCode = $run.exit_code

    # Godot writes warnings and the RID-leak notice to stderr, so both captured
    # files are merged into the single log path the marker scan and the archive
    # read. A timed-out test keeps whatever it printed before the kill.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $logText = ''
    foreach ($streamPath in @($logPath, $stderrPath)) {
        if (Test-Path -LiteralPath $streamPath) {
            $logText += [System.IO.File]::ReadAllText($streamPath, [System.Text.Encoding]::UTF8)
        }
    }
    if ($run.timed_out) {
        $logText += "[runtime-tests] TIMEOUT after ${TimeoutSeconds}s: the fixture did not quit, process tree killed`r`n"
    }
    [System.IO.File]::WriteAllText($logPath, $logText, $utf8)
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue

    $markers = [regex]::Matches($logText, $failurePattern) | ForEach-Object { $_.Value } | Select-Object -Unique
    # A timeout is never a pass, whatever the killed process reported as exit code.
    $passed = ($exitCode -eq 0) -and ($markers.Count -eq 0) -and (-not $run.timed_out)

    $results += [ordered]@{
        name            = $name
        script          = $relative
        exit_code       = $exitCode
        elapsed_seconds = [math]::Round($elapsed, 2)
        log             = "tests/$name.log"
        log_bytes       = $logText.Length
        failure_markers = @($markers)
        passed          = $passed
        known_red       = ($knownRed -contains $name)
        timed_out       = [bool]$run.timed_out
        timeout_seconds = $TimeoutSeconds
    }

    $verdict = if ($run.timed_out) { "TIMEOUT ($($TimeoutSeconds)s, killed)" }
        elseif ($passed) { 'PASS' }
        elseif ($knownRed -contains $name) { "KNOWN-RED (exit=$exitCode markers=$($markers -join ','))" }
        else { "FAIL (exit=$exitCode markers=$($markers -join ','))" }
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
    if ($result.timed_out) {
        [void]$builder.AppendLine("TIMEOUT: killed after $($result.timeout_seconds)s without an exit")
    }
    [void]$builder.AppendLine('=' * 78)
    $individual = Join-Path $logDir "$($result.name).log"
    if (Test-Path -LiteralPath $individual) {
        [void]$builder.AppendLine([System.IO.File]::ReadAllText($individual, [System.Text.Encoding]::UTF8))
    }
    [void]$builder.AppendLine()
}
Set-Content -LiteralPath $combined -Value $builder.ToString() -Encoding UTF8

# The source scan test is the 搂26 source-scan artifact; surface it separately.
$scanLog = Join-Path $logDir 'runtime_worker_source_scan_test.log'
if (Test-Path -LiteralPath $scanLog) {
    Copy-Item -LiteralPath $scanLog -Destination (Join-Path $OutDir 'source-scan.log') -Force
}

$passCount = @($results | Where-Object { $_.passed }).Count
$knownRedResults = @($results | Where-Object { (-not $_.passed) -and $_.known_red })
$timeoutResults = @($results | Where-Object { $_.timed_out })
# A timeout is already reported as its own blocking category, so it is excluded
# here instead of being double counted.
$blockingFailures = @($results | Where-Object { (-not $_.passed) -and (-not $_.known_red) -and (-not $_.timed_out) })
$summary = [ordered]@{
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    godot         = $godot
    timeout_seconds = $TimeoutSeconds
    total         = $results.Count
    passed        = $passCount
    known_red     = $knownRedResults.Count
    failed        = $blockingFailures.Count
    timed_out     = @($timeoutResults | ForEach-Object { $_.name })
    known_red_tests = @($knownRedResults | ForEach-Object { $_.name })
    results       = $results
}
$summary | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $OutDir 'test-summary.json') -Encoding UTF8

Write-Host ''
Write-Host "$passCount/$($results.Count) passed, $($knownRedResults.Count) known-red, $($timeoutResults.Count) timed out (${TimeoutSeconds}s limit), $($blockingFailures.Count) failed -> $OutDir"
if ($knownRedResults.Count -gt 0) {
    Write-Host 'known-red (non-blocking, 05 §2.8):' -ForegroundColor Yellow
    foreach ($result in $knownRedResults) {
        Write-Host "  $($result.name)  exit=$($result.exit_code)  $($result.failure_markers -join ' | ')"
    }
}
if ($timeoutResults.Count -gt 0) {
    Write-Host "timed out (no exit within ${TimeoutSeconds}s, process tree killed):" -ForegroundColor Yellow
    foreach ($result in $timeoutResults) {
        Write-Host "  $($result.name)  TIMEOUT ($($result.timeout_seconds)s, killed)  [$($result.elapsed_seconds)s]  $($result.log)"
    }
}
if ($blockingFailures.Count -gt 0 -or $timeoutResults.Count -gt 0) {
    Write-Host 'failed:' -ForegroundColor Yellow
    foreach ($result in $blockingFailures) {
        Write-Host "  $($result.name)  exit=$($result.exit_code)  $($result.failure_markers -join ' | ')"
    }
    foreach ($result in $timeoutResults) {
        Write-Host "  $($result.name)  TIMEOUT ($($result.timeout_seconds)s, killed)  exit=$($result.exit_code)"
    }
    exit 1
}
