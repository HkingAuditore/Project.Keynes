Set-StrictMode -Version Latest

function Get-StageCPercentile {
    param([double[]]$Values, [double]$Percentile)
    if (-not $Values -or $Values.Count -eq 0) { return 0.0 }
    $sorted = @($Values | Sort-Object)
    $rank = [Math]::Ceiling(([Math]::Max(0.0, [Math]::Min(100.0, $Percentile)) / 100.0) * $sorted.Count) - 1
    return [double]$sorted[[Math]::Max(0, [Math]::Min($sorted.Count - 1, $rank))]
}

function Get-StageCDistribution {
    param([double[]]$Values)
    $clean = @($Values | Where-Object { -not [double]::IsNaN($_) -and -not [double]::IsInfinity($_) })
    if ($clean.Count -eq 0) {
        return [ordered]@{ count = 0; mean = 0.0; p50 = 0.0; p95 = 0.0; p99 = 0.0; max = 0.0; ge_16_67_ms_ratio = 0.0; ge_33_33_ms_ratio = 0.0 }
    }
    $sum = 0.0
    $ge16 = 0
    $ge33 = 0
    foreach ($value in $clean) {
        $sum += $value
        if ($value -ge 16.67) { $ge16++ }
        if ($value -ge 33.33) { $ge33++ }
    }
    return [ordered]@{
        count = $clean.Count
        mean = $sum / $clean.Count
        p50 = Get-StageCPercentile $clean 50
        p95 = Get-StageCPercentile $clean 95
        p99 = Get-StageCPercentile $clean 99
        max = Get-StageCPercentile $clean 100
        ge_16_67_ms_ratio = [double]$ge16 / $clean.Count
        ge_33_33_ms_ratio = [double]$ge33 / $clean.Count
    }
}

function Get-StageCProperty {
    param($Object, [string]$Name, $Default = 0)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Get-StageCPairedVerdict {
	param([object[]]$Pairs, [double]$MinMs = 0.25, [double]$MinPercent = 3.0)
	if ($Pairs.Count -ne 3) { return 'mixed_or_no_material_evidence' }
	$deltas = @($Pairs | ForEach-Object { [double]$_.active_minus_off_ms })
	$percentages = @($Pairs | ForEach-Object { [double]$_.active_minus_off_percent })
	$allImproved = @($deltas | Where-Object { $_ -ge 0.0 }).Count -eq 0
	$allRegressed = @($deltas | Where-Object { $_ -le 0.0 }).Count -eq 0
	$medianMs = Get-StageCPercentile $deltas 50
	$medianPercent = Get-StageCPercentile $percentages 50
	$improvement = $allImproved -and $medianMs -le (-[Math]::Abs($MinMs)) -and $medianPercent -le (-[Math]::Abs($MinPercent))
	$regression = $allRegressed -and $medianMs -ge [Math]::Abs($MinMs) -and $medianPercent -ge [Math]::Abs($MinPercent)
    if ($improvement) { return 'stable_improvement' }
    if ($regression) { return 'stable_regression' }
    return 'mixed_or_no_material_evidence'
}

function ConvertTo-StageCInvariantDouble {
    param($Value)
    $number = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }
    return [double]::NaN
}

function Write-StageCJson {
    param([string]$Path, $Value)
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}
