<#
.SYNOPSIS
Starts one clean visible Debug client for the Stage C2 manual full-SoA recording SOP.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('ACTIVE','OFF')][string]$Mode,
    [string]$GodotExe = '',
    [string]$RunId = '',
    [string]$OutputRoot = '',
    [int]$Seed = 20260718,
    [int]$Width = 60,
    [int]$Height = 40,
    [int]$ForeignCount = 3,
    [double]$Speed = 50,
    [double]$WarmupSeconds = 5,
    [double]$RecordSeconds = 30,
    [int]$WarmupUntilTick = -1,
    [int]$RecordTicks = 0,
    [switch]$Automated
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$projectPath = Join-Path $repoRoot 'Project\project-keynes'
. (Join-Path $PSScriptRoot 'Resolve-GodotBin.ps1')
$godot = Resolve-GodotBin -GodotExe $GodotExe
if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = 'manual-{0}-{1}' -f $Mode.ToLowerInvariant(), (Get-Date -Format 'yyyyMMdd-HHmmss') }
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $repoRoot 'artifacts\runtime\authority-stage-c' }
$runDir = Join-Path $OutputRoot $RunId
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$arguments = @(
    '--path', $projectPath,
    'res://tests/authority_stage_c_client_runner.tscn', '--',
    "mode=$Mode", 'manual=true', "auto_tile=$($Automated.IsPresent.ToString().ToLowerInvariant())",
    "run_id=$RunId", "output_dir=$runDir", "seed=$Seed",
    "width=$Width", "height=$Height", "foreign_count=$ForeignCount", "speed=$Speed",
    "warmup_seconds=$WarmupSeconds", "record_seconds=$RecordSeconds",
    "warmup_until_tick=$WarmupUntilTick", "record_ticks=$RecordTicks"
)
$process = Start-Process -FilePath $godot -ArgumentList $arguments -PassThru
Write-Host "[stage-c/C2] started pid=$($process.Id) mode=$Mode output=$runDir"
if ($Automated) {
    Write-Host '[stage-c/C2] The visible client will start/stop the full TileDataRecorder automatically after warmup. Do not interact with the window.'
} else {
    Write-Host '[stage-c/C2] After manual_ready: open GM, start full TileDataRecorder, resume x50 for 30 seconds, then stop/export. Do not enable PerfRecorder.'
}
Write-Host '[stage-c/C2] The full recorder now captures country_slot_arr plus Country cash/technology/research/worker-hash/terminal-receipt evidence in its sidecar.'
[pscustomobject]@{ ProcessId = $process.Id; Mode = $Mode; OutputDirectory = $runDir }
