<#
.SYNOPSIS
Replays a player save headlessly for N simulation days and reports the outcome.

.DESCRIPTION
This is the reproduction entry point for player-reported stops and hangs. Give
it a save (a slot id, or any .pksv file) and a day count; it loads through the
production GameFlow restore path, advances the authoritative clock, and fails
on either an economy fatal or a stalled day. Both failure modes write a
forensics JSON under tmp/ so the scene can be inspected without re-running.

A -SavePath file is copied into a scratch directory and reached through the
PK_SAVE_DIR override, so replaying a save never overwrites the player's slots.

.EXAMPLE
  .\tools\runtime\Invoke-SaveReplay.ps1 -Slot autosave -Days 60

.EXAMPLE
  .\tools\runtime\Invoke-SaveReplay.ps1 -SavePath C:\tmp\day2740.pksv -Days 20 -Speed 10
#>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [ValidateSet('manual_1', 'manual_2', 'manual_3', 'autosave')]
    [string]$Slot = 'autosave',
    [string]$SavePath = '',
    [ValidateRange(1, 100000)]
    [int]$Days = 30,
    [ValidateRange(0.1, 1000)]
    [double]$Speed = 20,
    [ValidateRange(1000, 3600000)]
    [int]$DayTimeoutMsec = 60000,
    [string]$GodotExe = '',
    [ValidateRange(60, 86400)]
    [int]$TimeoutSeconds = 3600
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $root 'tools\runtime\Resolve-GodotBin.ps1')
$godot = Resolve-GodotBin -GodotExe $GodotExe
$project = Join-Path $root 'Project\project-keynes'

$scratchDir = ''
if ($SavePath -ne '') {
    if (-not (Test-Path -LiteralPath $SavePath -PathType Leaf)) {
        throw "Save file not found: $SavePath"
    }
    # The repository only knows four slot ids, so an arbitrary file is staged as
    # one of them inside a throwaway directory rather than into user://saves.
    $scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pk-save-replay-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
    Copy-Item -LiteralPath $SavePath -Destination (Join-Path $scratchDir "$Slot.pksv") -Force
    $env:PK_SAVE_DIR = $scratchDir
    Write-Host "staged $SavePath as slot '$Slot' in $scratchDir"
}

$env:PK_SAVE_REPLAY = '1'
$env:PK_SAVE_REPLAY_SLOT = $Slot
$env:PK_SAVE_REPLAY_DAYS = "$Days"
$env:PK_SAVE_REPLAY_SPEED = "$Speed"
$env:PK_SAVE_REPLAY_DAY_TIMEOUT_MSEC = "$DayTimeoutMsec"

$logDir = Join-Path $root 'tmp'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logPath = Join-Path $logDir ("save_replay_" + (Get-Date).ToString('yyyyMMdd_HHmmss') + '.log')

Write-Host "replaying slot=$Slot days=$Days speed=$Speed ..."
$exitCode = 1
$previousErrorAction = $ErrorActionPreference
try {
    # Godot prints warnings and the shutdown RID notice to stderr; a merged
    # pipeline under Stop mode would turn the first one into a terminating error.
    $ErrorActionPreference = 'Continue'
    & $godot '--headless' '--path' $project 2>&1 | Tee-Object -FilePath $logPath
    $exitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorAction
    Remove-Item Env:\PK_SAVE_REPLAY, Env:\PK_SAVE_REPLAY_SLOT, Env:\PK_SAVE_REPLAY_DAYS,
        Env:\PK_SAVE_REPLAY_SPEED, Env:\PK_SAVE_REPLAY_DAY_TIMEOUT_MSEC -ErrorAction SilentlyContinue
    if ($scratchDir -ne '') {
        Remove-Item Env:\PK_SAVE_DIR -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$logText = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
if ($null -eq $logText) { $logText = '' }

# The harness prints exactly one machine-readable line; trust it over the exit
# code, because Godot harnesses have historically exited 0 after printing a
# failure. Missing the line at all is itself a failure (the runner never ran).
$match = [regex]::Match($logText, '\[save-replay/result\]\s*(\{.*\})')
if (-not $match.Success) {
    Write-Host "no [save-replay/result] line in $logPath" -ForegroundColor Red
    exit 1
}
$result = $match.Groups[1].Value | ConvertFrom-Json

Write-Host ''
Write-Host "log      : $logPath"
Write-Host "slot     : $($result.slot)"
Write-Host "days     : $($result.start_day) -> $($result.end_day) (requested $($result.requested_days))"
if ($result.PSObject.Properties.Name -contains 'days_per_sec') {
    Write-Host ("throughput: {0:N2} authoritative days/s" -f $result.days_per_sec)
}
if ($result.PSObject.Properties.Name -contains 'forensics' -and $result.forensics) {
    Write-Host "forensics: $($result.forensics)"
}

if ($result.ok -and $exitCode -eq 0) {
    Write-Host 'PASS' -ForegroundColor Green
    exit 0
}
Write-Host "FAIL: $($result.failures -join ' | ')" -ForegroundColor Red
exit 1
