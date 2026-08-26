param([string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path)

# Stable CI/developer entry point. The audit implementation is edge-based and
# reads technology eras/topology from the authoritative network at runtime.
& (Join-Path $PSScriptRoot 'audit_economy_content_v2.ps1') -RepoRoot $RepoRoot
exit $LASTEXITCODE
