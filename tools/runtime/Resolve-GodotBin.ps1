<#
.SYNOPSIS
Resolves the Godot console executable used by every runtime harness.

.DESCRIPTION
Single source of truth for the Godot binary path. Resolution order:
  1. explicit -GodotExe argument
  2. $env:GODOT_BIN
  3. known local install candidates
  4. godot / godot_console on PATH

The console variant is preferred because headless runs must write to stdout.
Dot-source this file to get Resolve-GodotBin, or run it to print the path.
#>
param(
    [Alias('GodotExe')]
    [string]$ResolvedGodotOverride = ''
)

$ErrorActionPreference = 'Stop'

function Resolve-GodotBin {
    param([string]$GodotExe = '')

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($GodotExe -ne '') { $candidates.Add($GodotExe) }
    if ($env:GODOT_BIN) { $candidates.Add($env:GODOT_BIN) }

    # Known local installs, derived from where this repo actually is: the official
    # zip is often extracted next to the repo, and a directory named *.exe means the
    # binary sits one level deeper (and its console build is the one we want).
    $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $bases = @($repo, (Split-Path -Parent $repo), (Split-Path -Parent (Split-Path -Parent $repo)))
    $zipDir = 'Godot_v4.6.2-stable_win64.exe'
    # Console builds are tried across every base before the GUI ones, because the
    # quiet build is what headless runs need.
    foreach ($name in @('Godot_v4.6.2-stable_win64_console.exe', 'Godot_v4.6.2-stable_win64.exe')) {
        foreach ($base in $bases) {
            $candidates.Add((Join-Path $base $name))
            $candidates.Add((Join-Path (Join-Path $base $zipDir) $name))
        }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    foreach ($name in @('godot_console', 'godot')) {
        $onPath = Get-Command $name -ErrorAction SilentlyContinue
        if ($onPath) { return $onPath.Source }
    }

    throw @"
Godot executable not found. Set GODOT_BIN to the console build, e.g.

    `$env:GODOT_BIN = 'path\to\Godot_v4.6.2-stable_win64_console.exe'

Tried: $($candidates -join '; ')
"@
}

if ($MyInvocation.InvocationName -ne '.') {
    Resolve-GodotBin -GodotExe $ResolvedGodotOverride
}
