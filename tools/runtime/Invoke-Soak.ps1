<#
.SYNOPSIS
Runs the production-path headless soak and archives one summary per run.

.DESCRIPTION
Wraps Project/project-keynes/tests/game/headless_perf_record.gd, the same
WorldRuntimeHost + PerfRecorder path the GM panel uses, so a soak measures the
production daily graph instead of a synthetic benchmark (see the
project-keynes-headless-perf skill).

Every run owns its directory (default tmp/soak_<yyyyMMdd_HHmmss>/):

  soak.log              merged Godot stdout+stderr
  summary.json          machine-readable summary (schema pk-soak/1)
  perf.csv              PerfRecorder samples
  headless_session.json / headless_metrics.csv / country_daily_metrics.csv

Headless speed-up (runtime-fault plan §8.2-A): -Release flips the dots_ext
GDExtension mapping to the release DLL for this run and restores the debug
mapping in finally, even when the run throws.

Parameter passing: headless_perf_record.gd reads only PK_HEADLESS_WATCH_CELLS,
PK_HEADLESS_TECH_EVERY, PK_HEADLESS_WATCH_EVERY, PK_HEADLESS_FAMINE_WATCH and
PK_HEADLESS_CARRYING_DUMP from the environment. Everything else is a
`key=value` CLI argument after `--` (see its _arguments()), which is what this
wrapper passes.

Exit codes: 0 = soak passed, 1 = anything else (fatal, ledger error, CSV row
mismatch, timeout, missing result line). The authoritative-throughput check
(exit 9) is a performance gate, not a stability gate, so it is reported as a
warning rather than a soak failure.

.EXAMPLE
  .\tools\runtime\Invoke-Soak.ps1 -Days 400 -Width 60 -Height 40

.EXAMPLE
  .\tools\runtime\Invoke-Soak.ps1 -Days 3 -Width 20 -Height 20 -Json
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [ValidateRange(1, 100000)]
    [int]$Days = 400,
    [ValidateRange(10, 500)]
    [int]$Width = 60,
    [ValidateRange(8, 400)]
    [int]$Height = 40,

    # Default: tmp/soak_<yyyyMMdd_HHmmss>/
    [string]$OutDir = '',

    # Also print one machine-readable [soak/summary] line on stdout.
    [switch]$Json,

    # 0 waits forever; the default kills a hung soak and fails the run.
    [ValidateRange(0, 86400)]
    [int]$TimeoutSeconds = 1800,

    [ValidateRange(0.001, 10000.0)]
    [double]$Speed = 50.0,
    [int]$Seed = 20260718,
    [ValidateRange(0, 12)]
    [int]$ForeignCount = 3,
    [ValidateSet(0, 1, 10, 100, 1000)]
    [int]$PopulationScale = 0,
    [ValidateRange(0, 1000)]
    [int]$WarmupDays = 5,

    [string]$GodotExe = '',
    [string]$Label = 'soak',

    # Explicit legacy benchmark mode; never report it as formal gameplay start.
    [switch]$SyntheticTestEconomy,

    # Run against the release GDExtension DLL (restored in finally).
    [switch]$Release,

    [string]$SummaryPath = ''
)

$ErrorActionPreference = 'Stop'


## Runs Godot with both streams captured and an optional hard timeout.
## Start-Process -PassThru leaves ExitCode empty under Windows PowerShell 5.1
## (observed on 5.1.22621), so the .NET Process API is used directly. Godot
## writes UTF-8 even on Windows, so both streams are decoded as UTF-8.
function Invoke-CapturedGodot {
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

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = $false
    if ($TimeoutSeconds -gt 0) {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill() } catch { }
            $process.WaitForExit(10000) | Out-Null
        }
    }
    else {
        $process.WaitForExit()
    }
    $exitCode = $process.ExitCode
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($StdoutPath, $stdoutTask.Result, $utf8)
    [System.IO.File]::WriteAllText($StderrPath, $stderrTask.Result, $utf8)
    $process.Dispose()
    return @{ exit_code = $exitCode; timed_out = $timedOut }
}

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $root 'tools\runtime\Resolve-GodotBin.ps1')
$godot = Resolve-GodotBin -GodotExe $GodotExe
$project = Join-Path $root 'Project\project-keynes'
$runner = Join-Path $project 'tests\game\headless_perf_record.gd'
$useGdextLibrary = Join-Path $root 'tools\runtime\Use-GdextLibrary.ps1'

if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Headless performance runner not found: $runner"
}

$startedAt = Get-Date
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $root ('tmp\soak_' + $startedAt.ToString('yyyyMMdd_HHmmss'))
}
elseif (-not [System.IO.Path]::IsPathRooted($OutDir)) {
    $OutDir = Join-Path $root $OutDir
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
    $SummaryPath = Join-Path $OutDir 'summary.json'
}
elseif (-not [System.IO.Path]::IsPathRooted($SummaryPath)) {
    $SummaryPath = Join-Path (Get-Location).Path $SummaryPath
}

$logPath = Join-Path $OutDir 'soak.log'
$stdoutPath = Join-Path $OutDir 'soak.stdout.log'
$stderrPath = Join-Path $OutDir 'soak.stderr.log'
$safeLabel = ($Label -replace '[^A-Za-z0-9_.-]', '_')

# Paths handed to Godot must be absolute: Godot changes its CWD to --path.
$godotArgs = @(
    '--headless',
    '--path', $project,
    '--script', 'res://tests/game/headless_perf_record.gd',
    '--',
    "days=$Days",
    "warmup_days=$WarmupDays",
    "speed=$Speed",
    "seed=$Seed",
    "width=$Width",
    "height=$Height",
    "population_scale=$PopulationScale",
    "foreign_count=$ForeignCount",
    "synthetic_test_economy=$($SyntheticTestEconomy.IsPresent.ToString().ToLowerInvariant())",
    "label=$safeLabel",
    "output_dir=$OutDir"
)

Write-Host ("soak     : days={0} map={1}x{2} speed={3} seed={4} release={5}" -f `
    $Days, $Width, $Height, $Speed, $Seed, $Release.IsPresent)
Write-Host "out      : $OutDir"

$exitCode = -1
$timedOut = $false
$releaseSwitched = $false
$restoreFailed = $false
$previousErrorAction = $ErrorActionPreference
try {
    if ($Release) {
        & $useGdextLibrary -Variant release -RepoRoot $root -Quiet
        $releaseSwitched = $true
        Write-Host 'release  : windows.debug.x86_64 -> template_release DLL (restored in finally)'
    }
    $ErrorActionPreference = 'Continue'
    $run = Invoke-CapturedGodot -GodotExe $godot -Arguments $godotArgs `
        -StdoutPath $stdoutPath -StderrPath $stderrPath `
        -TimeoutSeconds $TimeoutSeconds
    $exitCode = $run.exit_code
    $timedOut = $run.timed_out
}
finally {
    $ErrorActionPreference = $previousErrorAction
    if ($releaseSwitched) {
        try {
            & $useGdextLibrary -Restore -RepoRoot $root -Quiet
            & $useGdextLibrary -Query -RepoRoot $root
        }
        catch {
            $restoreFailed = $true
            Write-Host "release: restore FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

$logText = ''
foreach ($streamPath in @($stdoutPath, $stderrPath)) {
    if (Test-Path -LiteralPath $streamPath) {
        $logText += [System.IO.File]::ReadAllText($streamPath, [System.Text.Encoding]::UTF8)
    }
}
[System.IO.File]::WriteAllText($logPath, $logText, (New-Object System.Text.UTF8Encoding($false)))
Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

$wallSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 3)

# The recorder prints one line per run:
#   [headless-perf/result] label=... days=... run_ms=... rows=<n> expected_rows=<m> path=...
$resultLine = [regex]::Match($logText, '(?m)^\[headless-perf/result\].*$')
$authLine = [regex]::Match($logText, '(?m)^\[headless-perf/auth\].*$')

$summary = [ordered]@{
    schema = 'pk-soak/1'
    ok = $false
    days_requested = $Days
    days_measured = $null
    committed_days = $null
    rows = $null
    expected_rows = $null
    warmup_days = $WarmupDays
    map = "${Width}x${Height}"
    seed = $Seed
    speed = $Speed
    population_scale = $PopulationScale
    foreign_count = $ForeignCount
    synthetic_test_economy = [bool]$SyntheticTestEconomy
    formal_start = -not $SyntheticTestEconomy.IsPresent
    fatal = $null
    ledger_failures = $null
    barrier_pulses = $null
    generation_ms = $null
    run_ms = $null
    wall_seconds = $wallSeconds
    days_per_second = 0.0
    authoritative_days_per_second = $null
    throughput_checkpoint_ok = $null
    godot_exit_code = $exitCode
    timed_out = $timedOut
    release = [bool]$Release
    errors = @()
    csv = ''
    log = $logPath
    out_dir = $OutDir
    summary = $SummaryPath
}

$errors = New-Object System.Collections.Generic.List[string]
$observations = $null
$fatal = $null
$ledgerFailures = $null

if ($timedOut) {
    $errors.Add("timeout after $TimeoutSeconds s")
}
if (-not $resultLine.Success) {
    $errors.Add('no [headless-perf/result] line (runner never finished)')
}
else {
    $resultText = $resultLine.Value
    if ($resultText -match 'days=(\d+)') { $summary.days_requested = [int]$Matches[1] }
    if ($resultText -match 'rows=(\d+)') { $summary.rows = [int]$Matches[1] }
    if ($resultText -match 'expected_rows=(\d+)') { $summary.expected_rows = [int]$Matches[1] }
    if ($resultText -match 'fatal=(true|false)') { $fatal = $Matches[1] -eq 'true' }
    if ($resultText -match 'ledger_failures=(\d+)') { $ledgerFailures = [int]$Matches[1] }
    if ($resultText -match 'barrier_pulses=(\d+)') { $summary.barrier_pulses = [int]$Matches[1] }
    if ($resultText -match 'generation_ms=([\d.]+)') { $summary.generation_ms = [double]$Matches[1] }
    if ($resultText -match 'run_ms=([\d.]+)') {
        $summary.run_ms = [double]$Matches[1]
        if ($summary.run_ms -gt 0) {
            # Harness window only: excludes world generation, unlike the wall
            # number below.
            $summary['run_days_per_second'] = [math]::Round(
                $Days * 1000.0 / $summary.run_ms, 3)
        }
    }
    if ($resultText -match 'map=(\d+x\d+)') { $summary.map = $Matches[1] }
    if ($resultText -match 'seed=(-?\d+)') { $summary.seed = [int]$Matches[1] }
    if ($resultText -match ' population_error=(\d+)' -and [int]$Matches[1] -ne 0) {
        $errors.Add("population_error=$($Matches[1])")
    }
    if ($resultText -match ' money_error=(\d+)' -and [int]$Matches[1] -ne 0) {
        $errors.Add("money_error=$($Matches[1])")
    }
    if ($resultText -match ' goods_error=(\d+)' -and [int]$Matches[1] -ne 0) {
        $errors.Add("goods_error=$($Matches[1])")
    }
    if ($resultText -match ' path=(.+)$') { $summary.csv = $Matches[1].Trim() }
    $summary.fatal = $fatal
    $summary.ledger_failures = $ledgerFailures
    if ($null -ne $summary.rows -and $null -ne $summary.expected_rows `
            -and $summary.rows -ne $summary.expected_rows) {
        $errors.Add("csv_rows=$($summary.rows) expected=$($summary.expected_rows)")
    }
    if ($fatal -eq $true) {
        $fatalDay = ''
        $fatalReason = ''
        if ($logText -match 'fatal economy report at day (\d+) reason=(\S+)') {
            $fatalDay = $Matches[1]
            $fatalReason = $Matches[2]
        }
        $summary['fatal_day'] = $fatalDay
        $summary['fatal_reason'] = $fatalReason
        $errors.Add("fatal=true day=$fatalDay reason=$fatalReason")
    }
    if ($null -ne $ledgerFailures -and $ledgerFailures -gt 0) {
        $errors.Add("ledger_failures=$ledgerFailures")
    }
}

if ($authLine.Success) {
    $authText = $authLine.Value
    # `measured_days` in the auth line counts main-loop observations; one
    # observation can cover several pipelined commits, so it is not the number
    # of measured days. Keep it as `observations` for diagnosis only.
    if ($authText -match 'measured_days=(\d+)') { $observations = [int]$Matches[1] }
    if ($authText -match 'committed_days=(\d+)') { $summary.committed_days = [int]$Matches[1] }
    if ($authText -match 'authoritative_days_per_second=([\d.]+)') {
        $summary.authoritative_days_per_second = [double]$Matches[1]
    }
    if ($authText -match 'checkpoint_ok=(true|false)') {
        $summary.throughput_checkpoint_ok = $Matches[1] -eq 'true'
    }
}
$summary['observations'] = $observations
# Measured days = CSV sample rows, which is what the soak actually measured.
$summary.days_measured = if ($null -ne $summary.rows) { $summary.rows } else { $observations }
if ($wallSeconds -gt 0) {
    $summary.days_per_second = [math]::Round($Days / $wallSeconds, 3)
}

# Exit 9 is the authoritative-throughput gate (a performance checkpoint), not a
# stability verdict; 6/7/8 and helper codes are real failures.
if ($exitCode -eq 9) {
    Write-Host 'checkpoint: authoritative throughput gate failed (reported, not a soak failure)'
}
elseif ($exitCode -ne 0 -and $exitCode -ne -1) {
    $errors.Add("godot_exit_code=$exitCode")
}
if ($exitCode -eq -1 -and -not $timedOut) {
    # A Windows process killed by a crash can surface -1 here; the missing result
    # line above is the actionable error.
    $errors.Add('godot_terminated_without_exit_code')
}

$summary.errors = $errors.ToArray()
$summary.ok = ($errors.Count -eq 0)
$summaryJson = $summary | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($SummaryPath, $summaryJson, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ("days     : {0} requested, {1} measured, {2} committed" -f `
    $Days, $summary.days_measured, $summary.committed_days)
Write-Host ("elapsed  : {0:N1} s ({1:N2} days/s wall)" -f `
    $wallSeconds, $summary.days_per_second)
if ($summary.Contains('run_days_per_second')) {
    Write-Host ("run      : {0:N1} s harness window ({1:N2} days/s)" -f `
        ($summary.run_ms / 1000.0), $summary.run_days_per_second)
}
Write-Host ("rows     : {0} (expected {1})" -f $summary.rows, $summary.expected_rows)
Write-Host ("fatal    : {0}" -f $fatal)
Write-Host ("ledger   : {0}" -f $ledgerFailures)
if ($null -ne $summary.throughput_checkpoint_ok) {
    Write-Host ("checkpoint: ok={0} authoritative_days_per_second={1}" -f `
        $summary.throughput_checkpoint_ok, $summary.authoritative_days_per_second)
}
Write-Host "csv      : $($summary.csv)"
Write-Host "log      : $logPath"
Write-Host "summary  : $SummaryPath"
if ($Json) {
    Write-Host "[soak/summary] $(($summary | ConvertTo-Json -Depth 6 -Compress))"
}

if ($restoreFailed) {
    Write-Host 'FAIL: GDExtension mapping was not restored to debug' -ForegroundColor Red
    exit 1
}
if ($summary.ok) {
    Write-Host 'PASS' -ForegroundColor Green
    exit 0
}
Write-Host ("FAIL: {0}" -f ($errors -join ' | ')) -ForegroundColor Red
exit 1
