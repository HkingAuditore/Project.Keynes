param(
    [string]$Fixture = 'tmp\perf_fixtures\late_manual1_18563.pksv',
    [int]$Days = 40,
    [int]$WarmupDays = 10,
    [double]$Speed = 50,
    [string]$OutDir = '',
    [switch]$NoProbes,
    [switch]$FullCostRows,
    [switch]$DayTrace,
    [hashtable]$EnvOverride = @{},
    [string]$GodotExe = '',
    [string]$RepoRoot = (Get-Location).Path
)

# Repeatable late-game replay probe for the economy formula optimization.
# Stages the frozen fixture as slot "autosave" inside a scratch dir (player
# saves are untouched), records waterfall + economy cost probes, then prints
# the analyzer summaries. Probe CSVs land in -OutDir (default under
# tmp/perf_runs/<utc timestamp>).
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
Push-Location $root
try {
    if (-not (Test-Path -LiteralPath $Fixture -PathType Leaf)) {
        throw "Fixture save not found: $Fixture"
    }
    # Resolve the Godot console binary: explicit arg > GODOT_BIN > known local
    # installs on the dev machines this probe runs on.
    if ([string]::IsNullOrWhiteSpace($GodotExe)) {
        $candidates = @(
            $env:GODOT_BIN,
            'F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe',
            'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe'
        )
        foreach ($candidate in $candidates) {
            if (-not [string]::IsNullOrWhiteSpace($candidate) -and
                    (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $GodotExe = (Resolve-Path -LiteralPath $candidate).Path
                break
            }
        }
    }
    $fixturePath = (Resolve-Path -LiteralPath $Fixture).Path
    if ([string]::IsNullOrWhiteSpace($OutDir)) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
        $OutDir = Join-Path $root ("tmp\perf_runs\" + $stamp)
    }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path

    $env:PK_SAVE_REPLAY_WARMUP_DAYS = "$WarmupDays"
    $env:PK_SAVE_REPLAY_DAY_TIMEOUT_MSEC = '120000'
    if ($NoProbes) {
        Remove-Item Env:\PK_RUNTIME_WATERFALL_CSV -ErrorAction SilentlyContinue
        Remove-Item Env:\PK_ECONOMY_COST_CSV -ErrorAction SilentlyContinue
        Remove-Item Env:\PK_ECONOMY_COST_CSV_FULL -ErrorAction SilentlyContinue
    } else {
        $env:PK_RUNTIME_WATERFALL_CSV = Join-Path $OutDir 'waterfall.csv'
        $env:PK_ECONOMY_COST_CSV = Join-Path $OutDir 'economy_cost.csv'
        if ($FullCostRows) {
            $env:PK_ECONOMY_COST_CSV_FULL = '1'
        } else {
            Remove-Item Env:\PK_ECONOMY_COST_CSV_FULL -ErrorAction SilentlyContinue
        }
    }
    # PK_SIM_DAY_TRACE writes two formatted lines plus seven dense vector
    # hashes per committed day inside the worker publish segment; it is a
    # forensics switch, never a throughput switch.
    if ($DayTrace) {
        $env:PK_SIM_DAY_TRACE = Join-Path $OutDir 'sim_day_trace.log'
    } else {
        Remove-Item Env:\PK_SIM_DAY_TRACE -ErrorAction SilentlyContinue
    }
    foreach ($key in $EnvOverride.Keys) {
        $value = [string]$EnvOverride[$key]
        if ([string]::IsNullOrWhiteSpace($value)) {
            Remove-Item ("Env:\" + $key) -ErrorAction SilentlyContinue
        } else {
            Set-Item -LiteralPath ("Env:\" + $key) -Value $value
        }
    }

    $replayLog = Join-Path $OutDir 'replay_console.log'
    $replayArgs = @{
        SavePath = $fixturePath
        Slot = 'autosave'
        Days = $Days
        Speed = $Speed
        RepoRoot = $root
    }
    if (-not [string]::IsNullOrWhiteSpace($GodotExe)) {
        $replayArgs['GodotExe'] = $GodotExe
    }
    Write-Host "replay fixture=$fixturePath days=$Days warmup=$WarmupDays speed=$Speed probes=$(-not $NoProbes)"
    Write-Host "out=$OutDir"
    # Invoke-SaveReplay writes its own tmp/save_replay_*.log; keep a copy of the
    # console transcript next to the probe CSVs as well.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & (Join-Path $root 'tools\runtime\Invoke-SaveReplay.ps1') @replayArgs 2>&1 |
            Tee-Object -FilePath $replayLog | Out-Null
        $replayExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    Write-Host "replay exit=$replayExit log=$replayLog"

    $resultLine = Select-String -Path $replayLog -Pattern '\[save-replay/result\]' |
        Select-Object -Last 1
    if ($null -ne $resultLine) {
        $json = ($resultLine.Line -replace '^.*\[save-replay/result\]\s*', '') | ConvertFrom-Json
        $executeUs = 0.0
        if ($null -ne $json.measurement_worker_time_us) {
            $executeUs = [double]$json.measurement_worker_time_us.execute
        }
        $measuredDays = [Math]::Max(1, $Days)
        Write-Host ('RESULT days_per_sec={0:N3} worker_execute={1:N2} ms/day ok={2} failures={3}' -f `
            [double]$json.days_per_sec, ($executeUs / 1000.0 / $measuredDays), $json.ok, ($json.failures -join '|'))
        $json | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutDir 'result.json')
    } else {
        Write-Host 'RESULT line missing from replay log'
    }
    # Preserve the deterministic end-of-run state hash for A/B comparisons.
    $forensics = Join-Path $root 'tmp\runtime_forensics_save_replay_ok.json'
    if (Test-Path -LiteralPath $forensics) {
        Copy-Item -LiteralPath $forensics -Destination (Join-Path $OutDir 'runtime_forensics.json') -Force
        try {
            $f = Get-Content -LiteralPath (Join-Path $OutDir 'runtime_forensics.json') -Raw | ConvertFrom-Json
            Write-Host ('RESULT committed_day={0} state_hash={1}' -f `
                $f.runtime_thread.simulation_committed_day, $f.runtime_thread.state_hash)
        } catch {
            Write-Host 'RESULT forensics parse failed'
        }
    }

    if (-not $NoProbes) {
        $python = Get-Command python -ErrorAction SilentlyContinue
        if ($null -eq $python) {
            $python = Get-Command py -ErrorAction SilentlyContinue
        }
        if ($null -ne $python) {
            $waterfall = Join-Path $OutDir 'waterfall.csv'
            $cost = Join-Path $OutDir 'economy_cost.csv'
            if (Test-Path -LiteralPath $waterfall) {
                Write-Host ''
                Write-Host '=== waterfall ==='
                & python (Join-Path $root 'tools\perf\analyze_waterfall.py') $waterfall
            }
            if (Test-Path -LiteralPath $cost) {
                Write-Host ''
                Write-Host '=== economy cost ==='
                & python (Join-Path $root 'tools\perf\analyze_economy_cost.py') $cost --top 40
            }
        }
    }
} finally {
    Pop-Location
}
