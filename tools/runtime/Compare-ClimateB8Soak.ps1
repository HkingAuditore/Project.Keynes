<#
.SYNOPSIS
Compares two Climate B8 soak summaries (OFF baseline vs ACTIVE) and applies the
per-field tolerance policy.

.DESCRIPTION
Reads <Artifacts>/soak.json from both sides, aligns the 25-day samples by tick,
and reports mean/nz/min/max deltas per contested field. Verdict is one of:
  pass           every field inside its band
  declared_gap   a field exceeds its band but carries a declared reason
  regression     a field exceeds its band with no declaration

A declared gap needs an entry in the policy's declared_gaps:
  "declared_gaps": { "moisture_arr": "B8-3 moisture-magnitude, run-id ..." }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LeftArtifacts,
    [Parameter(Mandatory)][string]$RightArtifacts,
    [string]$Policy = '',
    [string]$OutputDirectory = '',
    [ValidateSet('OFF', 'ACTIVE')][string]$LeftLabel = 'OFF',
    [ValidateSet('OFF', 'ACTIVE')][string]$RightLabel = 'ACTIVE'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Policy)) { $Policy = Join-Path $PSScriptRoot 'climate_b8_soak_policy.json' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $RightArtifacts).Path) ('compare-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

function Read-SoakSummary([string]$root) {
    $path = Join-Path $root 'soak.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "missing soak summary: $path" }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Get-Band($policyFields, [string]$field, [string]$metric, [double]$fallback) {
    if ($policyFields.PSObject.Properties.Name -contains $field) {
        $entry = $policyFields.$field
        if ($entry.PSObject.Properties.Name -contains $metric) { return [double]$entry.$metric }
    }
    return $fallback
}

$left = Read-SoakSummary $LeftArtifacts
$right = Read-SoakSummary $RightArtifacts
$policyJson = Get-Content -LiteralPath $Policy -Raw | ConvertFrom-Json
$policyFields = $policyJson.fields
$default = $policyJson.default
$declared = if ($policyJson.PSObject.Properties.Name -contains 'declared_gaps') { $policyJson.declared_gaps } else { $null }

foreach ($side in @($left, $right)) {
    if ([int]$side.first_bad_tick -ge 0) {
        throw ("soak run has non-finite values: first_bad_tick={0} field={1}" -f $side.first_bad_tick, $side.first_bad_field)
    }
}

$rightSamples = @{}
foreach ($sample in $right.samples) { $rightSamples[[int]$sample.tick] = $sample }

$rows = @()
$regressions = @()
$declaredGaps = @()
$comparedTicks = 0
foreach ($ls in $left.samples) {
    $tick = [int]$ls.tick
    if (-not $rightSamples.ContainsKey($tick)) { continue }
    $comparedTicks++
    $rs = $rightSamples[$tick]
    foreach ($field in $ls.fields.PSObject.Properties.Name) {
        $lf = $ls.fields.$field
        $rf = $rs.fields.$field
        if (-not $lf.present -or -not $rf.present) { continue }
        $deltas = [ordered]@{
            field        = $field
            tick         = $tick
            nz_delta     = [math]::Abs([double]$rf.nz - [double]$lf.nz)
            mean_delta   = [math]::Abs([double]$rf.mean - [double]$lf.mean)
            min_delta    = [math]::Abs([double]$rf.min - [double]$lf.min)
            max_delta    = [math]::Abs([double]$rf.max - [double]$lf.max)
        }
        $rows += [pscustomobject]$deltas
    }
}

$worst = @{}
foreach ($row in $rows) {
    if (-not $worst.ContainsKey($row.field)) { $worst[$row.field] = $row; continue }
    $current = $worst[$row.field]
    if ($row.mean_delta -gt $current.mean_delta) { $worst[$row.field] = $row }
}

foreach ($field in $worst.Keys) {
    $row = $worst[$field]
    $bandMean = Get-Band $policyFields $field 'mean_abs' ([double]$default.mean_abs)
    $bandNz = Get-Band $policyFields $field 'nz_abs' ([double]$default.nz_abs)
    $bandMin = Get-Band $policyFields $field 'min_abs' ([double]$default.min_abs)
    $bandMax = Get-Band $policyFields $field 'max_abs' ([double]$default.max_abs)
    $violations = @()
    if ($row.mean_delta -gt $bandMean) { $violations += ("mean {0:F5} > {1:F5}" -f $row.mean_delta, $bandMean) }
    if ($row.nz_delta -gt $bandNz) { $violations += ("nz {0} > {1}" -f $row.nz_delta, $bandNz) }
    if ($row.min_delta -gt $bandMin) { $violations += ("min {0:F5} > {1:F5}" -f $row.min_delta, $bandMin) }
    if ($row.max_delta -gt $bandMax) { $violations += ("max {0:F5} > {1:F5}" -f $row.max_delta, $bandMax) }
    if ($violations.Count -eq 0) { continue }
    $reason = $null
    if ($null -ne $declared -and ($declared.PSObject.Properties.Name -contains $field)) {
        $reason = [string]$declared.$field
    }
    if ($null -ne $reason) {
        $declaredGaps += [pscustomobject]@{ field = $field; tick = $row.tick; reason = $reason; violations = ($violations -join '; ') }
    } else {
        $regressions += [pscustomobject]@{ field = $field; tick = $row.tick; violations = ($violations -join '; ') }
    }
}

$verdict = if ($regressions.Count -gt 0) { 'regression' } elseif ($declaredGaps.Count -gt 0) { 'declared_gap' } else { 'pass' }
$report = [ordered]@{
    schema            = 'ClimateB8SoakCompare'
    schema_version    = 1
    generated_utc     = (Get-Date).ToUniversalTime().ToString('o')
    left              = @{ label = $LeftLabel; artifacts = (Resolve-Path -LiteralPath $LeftArtifacts).Path; days = [int]$left.days; authority = [bool]$left.authority }
    right             = @{ label = $RightLabel; artifacts = (Resolve-Path -LiteralPath $RightArtifacts).Path; days = [int]$right.days; authority = [bool]$right.authority }
    compared_ticks    = $comparedTicks
    field_count       = $worst.Count
    verdict           = $verdict
    regressions       = $regressions
    declared_gaps     = $declaredGaps
    worst_deltas      = $worst.Values
}
$reportPath = Join-Path $OutputDirectory 'soak-compare.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host "[b8-soak-compare] verdict=$verdict ticks=$comparedTicks fields=$($worst.Count) regressions=$($regressions.Count) declared=$($declaredGaps.Count)"
Write-Host "[b8-soak-compare] report=$reportPath"
if ($verdict -eq 'regression') {
    foreach ($r in $regressions) { Write-Host ("  REGRESSION {0}@{1}: {2}" -f $r.field, $r.tick, $r.violations) }
    exit 1
}
