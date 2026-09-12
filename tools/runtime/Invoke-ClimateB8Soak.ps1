<#
.SYNOPSIS
Runs one Climate B8 soak pass (ACTIVE or OFF) and archives its JSON summary.

.DESCRIPTION
Wraps tests/climate_authority_soak_probe.gd with the PK_SOAK_* environment the
B8 plan specifies. Output is written to <OutDir>/soak.log and <OutDir>/soak.json.

`-Drive serial_wait` is the production hand-off (host.wait_for_climate_consumed
plus the delivery cursors) and is the mode the B8 acceptance numbers come from.
`serial` keeps the legacy 24ms poll loop as an A/B control.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunId,
    [ValidateSet('1', '0')][string]$Authority = '1',
    [ValidateSet('serial', 'serial_wait', 'frames')][string]$Drive = 'serial_wait',
    [int]$Width = 50,
    [int]$Height = 48,
    [int]$Days = 300,
    [int]$Speed = 50,
    [int]$Seed = 20260907,
    [int]$ForeignCount = 3,
    [int]$Population = 100,
    [string]$Scenario = '',
    [string]$GodotExe = '',
    [string]$OutputRoot = '',
    [switch]$TraceDays,
    [switch]$DumpReport
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$projectPath = Join-Path $repoRoot 'Project\project-keynes'
. (Join-Path $PSScriptRoot 'Resolve-GodotBin.ps1')
$godot = Resolve-GodotBin -GodotExe $GodotExe
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot 'artifacts\runtime\climate-b8\soak'
}
if (-not [System.IO.Path]::IsPathRooted($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot $OutputRoot
}
$outDir = Join-Path $OutputRoot $RunId
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
# Godot changes its CWD to the --path project directory, so every path handed to
# the probe must be absolute. A relative OutputRoot is joined onto repoRoot above.
$summaryPath = [System.IO.Path]::Combine($outDir, 'soak.json')
$soakLogPath = [System.IO.Path]::Combine($outDir, 'soak.log')

Write-Host "[b8-soak] $RunId authority=$Authority drive=$Drive ${Width}x${Height} days=$Days speed=$Speed"
Write-Host "[b8-soak] out=$outDir"
# Pass parameters on the command line (after `--`) instead of via $env:. Windows
# PowerShell 5.1 loses $env: assignments across this child-process boundary
# (observed: child received an empty string), while argv is passed verbatim.
# The probe accepts both; CLI wins when present.
$godotArgs = @(
    '--headless', '--path', $projectPath,
    '--script', 'res://tests/climate_authority_soak_probe.gd', '--',
    "--days=$Days", "--seed=$Seed", "--width=$Width", "--height=$Height",
    "--authority=$Authority", "--drive=$Drive", "--speed=$Speed",
    "--foreign=$ForeignCount", "--pop=$Population",
    "--summary=$summaryPath"
)
if ($TraceDays) { $godotArgs += '--trace_days=1' }
if ($DumpReport) { $godotArgs += '--dump_report=1' }
if (-not [string]::IsNullOrWhiteSpace($Scenario)) { $godotArgs += "--scenario=$Scenario" }
# Same pattern as Invoke-RuntimeTests.ps1: Godot writes WARNINGs to stderr, which
# becomes a terminating error under ErrorActionPreference=Stop. The child call
# needs its own Continue scope and both streams must be drained (Tee writes them
# to disk; closing the pipe early would kill the process).
$ErrorActionPreference = 'Continue'
$exitCode = -1
try {
    & $godot @godotArgs 2>&1 | Tee-Object -FilePath $soakLogPath | Out-Null
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = 'Stop'
}

if (-not (Test-Path -LiteralPath $summaryPath)) {
    throw "[b8-soak] $RunId produced no summary; see $soakLogPath (exit=$exitCode)"
}
$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
$fail = [int]$summary.first_bad_tick -ge 0
$ok = ($exitCode -eq 0) -and (-not $fail)
Write-Host ("[b8-soak] {0} days={1} writeback_days={2} drops={3} first_bad_tick={4}" -f `
    $RunId, $summary.days, $summary.writeback_days, $summary.writeback_drop_count, $summary.first_bad_tick)
Write-Host "[b8-soak] summary=$summaryPath log=$soakLogPath"
if (-not $ok) { exit 1 }
