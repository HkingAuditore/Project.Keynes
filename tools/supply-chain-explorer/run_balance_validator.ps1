param(
    [string]$Scenario = (Join-Path $PSScriptRoot "scenario.stone_age.example.json"),
    [string]$OutputDir = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")) "tmp\economy-balance"),
    [string]$Python = "python",
    [string]$Node = "node",
    [switch]$OpenReport
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& $Python (Join-Path $PSScriptRoot "balance_validator.py") `
    --scenario (Resolve-Path $Scenario).Path `
    --repo-root $RepoRoot `
    --output-dir $OutputDir `
    --node $Node
$ValidatorExitCode = $LASTEXITCODE
$ReportPath = Join-Path $OutputDir "balance_report.html"
if ($OpenReport -and (Test-Path -LiteralPath $ReportPath)) {
    Start-Process -FilePath (Resolve-Path -LiteralPath $ReportPath).Path
}
exit $ValidatorExitCode
