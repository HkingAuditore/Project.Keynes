param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$GodotExe = 'F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe',
    [ValidateRange(1, 100000)]
    [int]$Days = 50,
    [ValidateRange(0.001, 10000.0)]
    [double]$Speed = 50.0,
    [ValidateRange(0, 2147483647)]
    [int]$Seed = 20260718,
    [ValidateRange(10, 500)]
    [int]$Width = 60,
    [ValidateRange(8, 400)]
    [int]$Height = 40,
    [ValidateSet(0, 1, 10, 100, 1000)]
    [int]$PopulationScale = 0,
    [ValidateRange(0, 12)]
    [int]$ForeignCount = 3,
    [ValidateRange(-100, 100)]
    [int]$ImportTariffRate = 0,
    [ValidateRange(-100, 100)]
    [int]$ExportTariffRate = 0,
    [string]$Label = 'headless',
    [ValidateSet('', 'OFF', 'PROBE', 'ACTIVE')]
    [string]$AccuracyMode = '',
    [ValidateSet('', 'EXACT', 'BALANCED', 'FAST', 'CUSTOM')]
    [string]$AccuracyPreset = '',
    [ValidateSet('', 'FULL', 'PROBE', 'INCREMENTAL')]
    [string]$ClosingAuditMode = '',
    [ValidateSet('', 'ON', 'OFF')]
    [string]$WorkerMode = '',
    [ValidateSet('', 'OFF', 'SHADOW', 'ACTIVE')]
    [string]$RuntimeGraphMode = '',
    [switch]$SyntheticTestEconomy,
    [switch]$TradeScenario,
    [switch]$UseSavedSetup
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$project = Join-Path $root 'Project\project-keynes'
$runner = Join-Path $project 'tests\headless_perf_record.gd'
$tmp = Join-Path $root 'tmp'

if (-not (Test-Path -LiteralPath $GodotExe)) {
    throw "Godot executable not found: $GodotExe"
}
if (-not (Test-Path -LiteralPath $runner)) {
    throw "Headless performance runner not found: $runner"
}

New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$started = Get-Date
$stamp = $started.ToString('yyyyMMdd_HHmmss')
$safeLabel = ($Label -replace '[^A-Za-z0-9_.-]', '_')
$logPath = Join-Path $tmp "headless_perf_${stamp}_${safeLabel}.log"
$godotArgs = @(
    '--headless',
    '--path', $project,
    '--script', 'res://tests/headless_perf_record.gd',
    '--',
    "days=$Days",
    "speed=$Speed",
    "seed=$Seed",
    "width=$Width",
    "height=$Height",
    "population_scale=$PopulationScale",
    "foreign_count=$ForeignCount",
    "import_tariff_rate=$ImportTariffRate",
    "export_tariff_rate=$ExportTariffRate",
    "synthetic_test_economy=$($SyntheticTestEconomy.IsPresent.ToString().ToLowerInvariant())",
    "trade_scenario=$($TradeScenario.IsPresent.ToString().ToLowerInvariant())",
    "use_saved_setup=$($UseSavedSetup.IsPresent.ToString().ToLowerInvariant())",
    "label=$safeLabel"
)
if ($AccuracyMode -ne '') { $godotArgs += "accuracy_mode=$AccuracyMode" }
if ($AccuracyPreset -ne '') { $godotArgs += "accuracy_preset=$AccuracyPreset" }
if ($ClosingAuditMode -ne '') {
    $godotArgs += "closing_audit_mode=$ClosingAuditMode"
}
if ($WorkerMode -ne '') { $godotArgs += "worker_mode=$WorkerMode" }
if ($RuntimeGraphMode -ne '') { $godotArgs += "runtime_graph_mode=$RuntimeGraphMode" }

# Godot writes warnings to stderr. Under Stop mode a merged pipeline turns the
# first one into a terminating NativeCommandError and kills the run mid-flight,
# so the child process gets its own Continue scope. Failures are still caught by
# the exit code and result-line checks below.
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $GodotExe @godotArgs 2>&1 | Tee-Object -FilePath $logPath
    $godotExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorAction
}
if ($godotExitCode -ne 0) {
    throw "Godot headless performance run failed with exit code $godotExitCode. Log: $logPath"
}

$resultLine = Select-String -LiteralPath $logPath -Pattern '^\[headless-perf/result\]' |
    Select-Object -Last 1
if ($null -eq $resultLine) {
    throw "Headless result line missing. Log: $logPath"
}
$resultText = $resultLine.Line
if ($resultText -notmatch 'ledger_failures=0' -or $resultText -notmatch 'fatal=false') {
    throw "Headless run reported an economy validation failure: $resultText"
}
if ($resultText -notmatch 'economy_configured=true') {
    throw "Headless run did not start an economy: $resultText"
}
if (-not $SyntheticTestEconomy.IsPresent) {
    if ($resultText -notmatch 'formal_start=true') {
        throw "Headless run did not use the formal new-game path: $resultText"
    }
    if ($resultText -notmatch 'country_count=(\d+)') {
        throw "Headless result omitted country_count: $resultText"
    }
    $countryCount = [int]$Matches[1]
    if ($countryCount -lt ($ForeignCount + 1)) {
        throw "Formal headless run created $countryCount countries; expected at least $($ForeignCount + 1)."
    }
    if ($resultText -notmatch 'population=(\d+)' -or [int]$Matches[1] -le 0) {
        throw "Formal headless run has no opening population: $resultText"
    }
}
if ($TradeScenario.IsPresent) {
    if ($resultText -notmatch 'trade_scenario=true') {
        throw "Headless run did not enable the requested trade scenario: $resultText"
    }
    if ($resultText -notmatch 'trade_orders_cumulative=(\d+)' -or [int]$Matches[1] -le 0) {
        throw "Trade scenario completed no foreign orders: $resultText"
    }
    if ($resultText -notmatch 'trade_route_expansions=(\d+)' -or [int]$Matches[1] -le 0) {
        throw "Trade scenario performed no route search: $resultText"
    }
    if ($resultText -notmatch 'trade_country_partners=(\d+)' -or [int]$Matches[1] -le 0) {
        throw "Trade scenario produced no country-partner aggregate: $resultText"
    }
}

$csvPath = ''
if ($resultText -match ' path=(.+)$') {
    $csvPath = $Matches[1].Trim()
}
if ($csvPath -eq '' -or -not (Test-Path -LiteralPath $csvPath)) {
    $latest = Get-ChildItem -LiteralPath $tmp -Filter 'perf_record_*.csv' |
        Where-Object { $_.LastWriteTime -ge $started } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latest) {
        throw "No performance CSV was created. Log: $logPath"
    }
    $csvPath = $latest.FullName
}

$reader = [System.IO.StreamReader]::new($csvPath)
try {
    $header = $reader.ReadLine()
    $rows = 0
    while ($null -ne $reader.ReadLine()) {
        $rows++
    }
} finally {
    $reader.Dispose()
}

if ($rows -ne $Days) {
    throw "Performance CSV row mismatch: got $rows, expected $Days. CSV: $csvPath"
}
foreach ($requiredColumn in @('tick_idx', 'speed_multiplier', 't_sus_ms')) {
    if ($header -notmatch "(^|,)$requiredColumn(,|$)") {
        throw "Required column '$requiredColumn' missing. CSV: $csvPath"
    }
}

$actualSeed = $Seed
if ($resultText -match ' seed=(\d+)') {
    $actualSeed = [int]$Matches[1]
}
$actualMap = "${Width}x${Height}"
if ($resultText -match ' map=(\d+x\d+)') {
    $actualMap = $Matches[1]
}
Write-Output "[headless-perf/verified] rows=$rows days=$Days speed=$Speed seed=$actualSeed map=$actualMap formal_start=$((-not $SyntheticTestEconomy.IsPresent).ToString().ToLowerInvariant()) trade_scenario=$($TradeScenario.IsPresent.ToString().ToLowerInvariant()) foreign_count=$ForeignCount import_tariff_rate=$ImportTariffRate export_tariff_rate=$ExportTariffRate saved_setup=$($UseSavedSetup.IsPresent.ToString().ToLowerInvariant()) csv=$csvPath log=$logPath"
