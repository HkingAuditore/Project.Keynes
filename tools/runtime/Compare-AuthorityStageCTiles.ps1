<#
.SYNOPSIS
Compares two Stage C2 full-SoA tile recordings and enforces the field policy.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LeftCsv,
    [Parameter(Mandatory)][string]$RightCsv,
    [string]$LeftSidecar = '',
    [string]$RightSidecar = '',
    [string]$Policy = '',
    [string]$OutputDirectory = '',
    [switch]$KeepDatabase
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $LeftSidecar) {
    $resolved = (Resolve-Path $LeftCsv).Path
    $LeftSidecar = Join-Path ([IO.Path]::GetDirectoryName($resolved)) ([IO.Path]::GetFileNameWithoutExtension($resolved) + '.sidecar.json')
}
if (-not $RightSidecar) {
    $resolved = (Resolve-Path $RightCsv).Path
    $RightSidecar = Join-Path ([IO.Path]::GetDirectoryName($resolved)) ([IO.Path]::GetFileNameWithoutExtension($resolved) + '.sidecar.json')
}
if (-not $Policy) { $Policy = Join-Path $PSScriptRoot 'authority-stage-c-field-policy.json' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot ('artifacts\runtime\authority-stage-c\tile-compare-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { throw 'Python 3 is required for the streaming Stage C tile comparison.' }
$args = @(
    (Join-Path $PSScriptRoot 'compare_authority_stage_c_tiles.py'),
    '--left-csv', (Resolve-Path $LeftCsv).Path, '--right-csv', (Resolve-Path $RightCsv).Path,
    '--left-sidecar', (Resolve-Path $LeftSidecar).Path, '--right-sidecar', (Resolve-Path $RightSidecar).Path,
    '--policy', (Resolve-Path $Policy).Path, '--output-dir', (Resolve-Path $OutputDirectory).Path
)
if ($KeepDatabase) { $args += '--keep-database' }
& $python.Source @args
exit $LASTEXITCODE
