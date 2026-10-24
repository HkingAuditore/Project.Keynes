param(
    [string]$Godot = "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe",
    [int]$MaxParallel = 1,
    [string[]]$Cards = @()
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$project = Join-Path $root "Project/project-keynes"
$script = "res://tests/ideology/ideology_cell_card_worker_test.gd"
$logDir = Join-Path $root "tmp/cell-card-worker"
$defaultCards = @(
    "agrarian_reform", "assembly_line", "automation_line", "carbon_market",
    "colonial_plantation", "financialization", "fire_keeping", "free_trade",
    "gene_editing", "heaven_human", "manufactory_regulation",
    "maritime_insurance", "nuclear_power", "ocean_company", "open_ports",
    "scholar_office", "arcology", "basic_income", "circular_economy",
    "department_store", "gig_economy", "offshore_drilling", "welfare_state",
    "marriage_alliance", "little_ice_age", "refrigeration", "air_conditioning",
    "canal_corvee", "grand_canal", "irrigation_grid", "shell_midden",
    "industrial_lab", "iron_smelting", "terrace_farming"
)
$cards = if ($Cards.Count -gt 0) { $Cards } else { $defaultCards }

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$env:PK_DISABLE_SUPPORT_GATE = "1"
$env:PK_PEER_STALL_TIMEOUT_MS = "60000"
$results = [ordered]@{}
$running = @()
$index = 0
$checks = 0
$failures = 0
$runnerFailures = 0

while ($index -lt $cards.Count -or $running.Count -gt 0) {
    while ($index -lt $cards.Count -and $running.Count -lt $MaxParallel) {
        $card = $cards[$index]
        $index += 1
        $out = Join-Path $logDir "$card.log"
        $err = Join-Path $logDir "$card.err.log"
        $env:CELL_ONLY_CARD = $card
        $process = Start-Process -FilePath $Godot `
            -ArgumentList @("--headless", "--path", $project, "--script", $script) `
            -WorkingDirectory $root -RedirectStandardOutput $out `
            -RedirectStandardError $err -WindowStyle Hidden -PassThru
        $running += [pscustomobject]@{
            Card = $card; Process = $process; Stdout = $out; Stderr = $err
        }
    }
    Start-Sleep -Milliseconds 500
    foreach ($job in @($running)) {
        if (-not $job.Process.HasExited) { continue }
        # Godot's console launcher starts the GUI binary as a child and sometimes
        # leaves its own Process object unpopulated after HasExited becomes true.
        # Drain the handles and refresh before reading ExitCode.
        $job.Process.WaitForExit()
        $exitCode = $job.Process.ExitCode
        $summary = Get-Content $job.Stdout -Tail 200 -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^=== ideology cell card worker:' } |
            Select-Object -Last 1
        $failure = @(Get-Content $job.Stderr -ErrorAction SilentlyContinue |
            Where-Object { $_ -match 'ERROR: \[FAIL\]' } |
            Select-Object -Last 1)
        $failure = if ($failure.Count -gt 0) { [string]$failure[0] } else { "" }
        $summaryText = if ($null -ne $summary) { [string]$summary } else { "" }
        $checkMatch = [regex]::Match($summaryText, '\bchecks=(\d+)')
        $failureMatch = [regex]::Match($summaryText, '\bfailures=(\d+)')
        if ($checkMatch.Success) {
            $checks += [int]$checkMatch.Groups[1].Value
        }
        if ($failureMatch.Success) {
            $failures += [int]$failureMatch.Groups[1].Value
        }
        $summaryValid = $checkMatch.Success -and $failureMatch.Success
        # The Godot console launcher can return before its GUI child finishes and
        # does not expose a reliable ExitCode through Start-Process. The fixture's
        # own summary is authoritative: it calls quit(1) iff failures != 0.
        $green = $summaryValid `
            -and [int]$failureMatch.Groups[1].Value -eq 0
        if (-not $summaryValid) {
            $runnerFailures += 1
        }
        $results[$job.Card] = [pscustomobject]@{
            Pass = $green
            Exit = if ($null -eq $exitCode) { "n/a" } else { $exitCode }
            Summary = if ($summaryText) { $summaryText.Trim() } else { "no summary" }
            Failure = if ($failure) { $failure.Trim() } else { "" }
        }
        $running = @($running | Where-Object { $_.Card -ne $job.Card })
    }
}

$passed = 0
foreach ($card in $cards) {
    $row = $results[$card]
    $status = if ($row.Pass) { "PASS" } else { "FAIL" }
    if ($row.Pass) { $passed += 1 }
    Write-Output ("{0,-24} {1}  exit={2}  {3}" -f $card, $status, $row.Exit, $row.Summary)
    if (-not $row.Pass -and $row.Failure) {
        Write-Output ("  {0}" -f $row.Failure)
    }
}
$failedCards = $cards.Count - $passed
$totalLine = ("TOTAL {0}/{1} passed; checks={2}; failures={3}; logs={4}" -f `
    $passed, $cards.Count, $checks, $failures, $logDir)
$summaryLine = ("=== ideology cell card worker: {0} checks, {1} failures ===" -f `
    $checks, ($failures + $runnerFailures))
Write-Output $totalLine
Write-Output $summaryLine
if ($passed -ne $cards.Count -or $failures -ne 0 -or $runnerFailures -ne 0) {
    exit 1
}
