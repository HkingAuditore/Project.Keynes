param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$GodotExe = $(if ($env:GODOT_BIN) { $env:GODOT_BIN } else { 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe' }),
    [ValidateSet('smoke', 'standard', 'full')]
    [string]$Matrix = 'standard',
    [double]$Speed = 50.0,
    [int]$Seed = 20260718,
    [int]$ForeignCount = 3,
    [string]$LabelPrefix = 'phase1'
)

# Phase-1 economy release benchmark matrix (production path).
# Four map tiers used by the Phase-1 gate:
#   smoke     30x20
#   standard  60x40  (Stage C baseline)
#   hotloop   96x64
#   large     150x100
# -Matrix smoke:    smoke only, 10 days
# -Matrix standard: smoke 10d + standard 50d
# -Matrix full:     all four tiers (10/50/30/20 days)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$runner = Join-Path $root '.cursor\skills\project-keynes-headless-perf\scripts\run_headless_perf.ps1'
if (-not (Test-Path -LiteralPath $runner)) {
    $runner = Join-Path $root '.codex\skills\project-keynes-headless-perf\scripts\run_headless_perf.ps1'
}
if (-not (Test-Path -LiteralPath $runner)) {
    throw "run_headless_perf.ps1 not found under .cursor or .codex skills"
}

$tiers = @()
switch ($Matrix) {
    'smoke' {
        $tiers = @(
            @{ Name = 'smoke'; Width = 30; Height = 20; Days = 10 }
        )
    }
    'standard' {
        $tiers = @(
            @{ Name = 'smoke'; Width = 30; Height = 20; Days = 10 },
            @{ Name = 'standard'; Width = 60; Height = 40; Days = 50 }
        )
    }
    'full' {
        $tiers = @(
            @{ Name = 'smoke'; Width = 30; Height = 20; Days = 10 },
            @{ Name = 'standard'; Width = 60; Height = 40; Days = 50 },
            @{ Name = 'hotloop'; Width = 96; Height = 64; Days = 30 },
            @{ Name = 'large'; Width = 150; Height = 100; Days = 20 }
        )
    }
}

$results = @()
foreach ($tier in $tiers) {
    $label = "$LabelPrefix-$($tier.Name)"
    Write-Host "=== Phase-1 bench $($tier.Name) $($tier.Width)x$($tier.Height) days=$($tier.Days) ==="
    & $runner `
        -RepoRoot $root `
        -GodotExe $GodotExe `
        -Days $tier.Days `
        -Speed $Speed `
        -Seed $Seed `
        -Width $tier.Width `
        -Height $tier.Height `
        -ForeignCount $ForeignCount `
        -Label $label
    if ($LASTEXITCODE -ne 0) {
        throw "Phase-1 bench failed for tier $($tier.Name) (exit $LASTEXITCODE)"
    }
    $results += $tier.Name
}

Write-Output ("Phase-1 economy release benchmark passed: " + ($results -join ', '))
