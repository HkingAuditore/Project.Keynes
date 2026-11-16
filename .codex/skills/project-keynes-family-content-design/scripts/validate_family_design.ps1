[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [string]$RepoRoot = "",
    [switch]$RequireFiveTables,
    [switch]$RequireFullProfessionCoverage,
    [switch]$Strict
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Design file not found: $Path"
}

$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$lines = @(Get-Content -LiteralPath $resolvedPath -Encoding UTF8)
$text = $lines -join "`n"
$issues = [System.Collections.Generic.List[object]]::new()

function Add-Issue {
    param(
        [ValidateSet("ERROR", "WARN")]
        [string]$Severity,
        [int]$Line,
        [string]$Message
    )
    $script:issues.Add([pscustomobject]@{
        Severity = $Severity
        Line = $Line
        Message = $Message
    })
}

function Split-MarkdownRow {
    param([string]$Line)
    $body = $Line.Trim()
    if ($body.StartsWith("|")) {
        $body = $body.Substring(1)
    }
    if ($body.EndsWith("|")) {
        $body = $body.Substring(0, $body.Length - 1)
    }
    return @($body.Split("|") | ForEach-Object { $_.Trim() })
}

$preferenceRows = [System.Collections.Generic.List[object]]::new()
$effectRows = [System.Collections.Generic.List[object]]::new()
$allIds = @{}
$complexTriggerPattern = '均价|未来\s*\d+\s*日|最近\s*\d+\s*日|近\s*\d+\s*日|随后|中途|连续|上穿|下穿|先.+(?:再|随后)|升级族.+(?:重置|不中断)'
$undefinedShorthandPattern = '主部门|非主部门|同链|同产业|匹配物资|相关建筑|基准价格|安全产量线|农业气候类型|投入储备目标|盈亏配对|亏损幅度'
$compressedPrestigePattern = '分别|威望\s*[ⅠⅡⅢⅣⅤ]\s*(?:—|－|~|～|至)\s*[ⅠⅡⅢⅣⅤ]'

for ($index = 0; $index -lt $lines.Count; $index++) {
    $lineNumber = $index + 1
    $line = $lines[$index]
    $idMatch = [regex]::Match($line, '^\|\s*([CIJE]\d{3})\s*\|')
    if (-not $idMatch.Success) {
        continue
    }

    $id = $idMatch.Groups[1].Value
    $cells = @(Split-MarkdownRow -Line $line)
    if ($allIds.ContainsKey($id)) {
        Add-Issue -Severity ERROR -Line $lineNumber -Message "Duplicate ID $id; first seen on line $($allIds[$id])."
    } else {
        $allIds[$id] = $lineNumber
    }

    if ($id.StartsWith("E")) {
        if ($cells.Count -ne 10) {
            Add-Issue -Severity ERROR -Line $lineNumber -Message "Effect row $id has $($cells.Count) cells; expected 10."
            continue
        }
        $effectRows.Add([pscustomobject]@{ Id = $id; Line = $lineNumber; Cells = $cells })
        if (($cells -join ' ') -match $undefinedShorthandPattern) {
            Add-Issue -Severity WARN -Line $lineNumber -Message "Effect $id contains undefined shorthand or an internal metric; spell out the referent in the row."
        }
        for ($tier = 4; $tier -le 8; $tier++) {
            if ([string]::IsNullOrWhiteSpace($cells[$tier])) {
                Add-Issue -Severity ERROR -Line $lineNumber -Message "Effect $id has an empty prestige result."
            }
        }
        if ([string]::IsNullOrWhiteSpace($cells[2]) -or [string]::IsNullOrWhiteSpace($cells[3])) {
            Add-Issue -Severity ERROR -Line $lineNumber -Message "Effect $id must define both condition and target."
        }
        if ($cells[2] -match $complexTriggerPattern) {
            Add-Issue -Severity WARN -Line $lineNumber -Message "Effect $id uses a history/sequence-dependent trigger; prefer one visible event or current state."
        }
        if ([string]::IsNullOrWhiteSpace($cells[9]) -or $cells[9] -notmatch '。$') {
            Add-Issue -Severity ERROR -Line $lineNumber -Message "Effect $id needs complete Chinese prestige statements ending in '。'."
        }
        if ($cells[9] -match $compressedPrestigePattern) {
            Add-Issue -Severity ERROR -Line $lineNumber -Message "Effect $id compresses multiple prestige tiers into a range or positional list; write each tier independently."
        }
        $prestigeStatementPattern = '^威望Ⅰ：.+。<br>威望Ⅱ：.+。<br>威望Ⅲ：.+。<br>威望Ⅳ：.+。<br>威望Ⅴ：.+。$'
        if ($cells[9] -notmatch $prestigeStatementPattern) {
            Add-Issue -Severity ERROR -Line $lineNumber -Message "Effect $id must contain five ordered, independently labeled prestige statements separated by <br>."
        }
        $duplicateTierText = @($cells[4..8] | Group-Object | Where-Object { $_.Count -gt 1 })
        if ($duplicateTierText.Count -gt 0) {
            Add-Issue -Severity WARN -Line $lineNumber -Message "Effect $id repeats identical prestige result text."
        }
    } else {
        if ($cells.Count -ne 5) {
            Add-Issue -Severity ERROR -Line $lineNumber -Message "Preference row $id has $($cells.Count) cells; expected 5."
            continue
        }
        $preferenceRows.Add([pscustomobject]@{ Id = $id; Line = $lineNumber; Cells = $cells })
        if (($cells -join ' ') -match $undefinedShorthandPattern) {
            Add-Issue -Severity WARN -Line $lineNumber -Message "Preference $id contains undefined shorthand or an internal metric; spell out the referent in the row."
        }
        if ([string]::IsNullOrWhiteSpace($cells[1]) -or
                [string]::IsNullOrWhiteSpace($cells[2]) -or
                [string]::IsNullOrWhiteSpace($cells[3]) -or
                [string]::IsNullOrWhiteSpace($cells[4])) {
            Add-Issue -Severity ERROR -Line $lineNumber -Message "Preference $id has an empty required field."
        }
        if ($cells[2] -eq "-") {
            Add-Issue -Severity WARN -Line $lineNumber -Message "Preference $id should use an em dash '—' for no random condition."
        }
        if (("$($cells[2]) $($cells[3])") -match $complexTriggerPattern) {
            Add-Issue -Severity WARN -Line $lineNumber -Message "Preference $id uses history/sequence-dependent activation; prefer one visible event or current state."
        }
        $variables = @([regex]::Matches($cells[3], '(?<![A-Z])[A-Z](?![A-Z])') |
            ForEach-Object { $_.Value } | Sort-Object -Unique)
        foreach ($variable in $variables) {
            if ($cells[4] -notmatch ([regex]::Escape($variable) + '\s*∈')) {
                Add-Issue -Severity ERROR -Line $lineNumber -Message "Preference $id uses $variable but does not define its range."
            }
        }
    }
}

foreach ($prefix in @("C", "I", "J", "E")) {
    $numbers = @($allIds.Keys |
        Where-Object { $_.StartsWith($prefix) } |
        ForEach-Object { [int]$_.Substring(1) } |
        Sort-Object)
    if ($numbers.Count -eq 0) {
        continue
    }
    for ($position = 0; $position -lt $numbers.Count; $position++) {
        $expected = $position + 1
        if ($numbers[$position] -ne $expected) {
            Add-Issue -Severity WARN -Line 0 -Message "$prefix IDs are not a continuous sequence from ${prefix}001."
            break
        }
    }
}

$forbiddenPatterns = @(
    '\|\s*当前\s*Trait\s*\|',
    '\|\s*核心作用\s*\|',
    '\|\s*互斥建议\s*\|',
    '\|\s*状态\s*\|',
    '\|\s*实现边界\s*\|',
    '\b(?:WORKTREE|CONFIGURABLE|LIVE|EXTENSION|DEFER)\b'
)
foreach ($pattern in $forbiddenPatterns) {
    $match = [regex]::Match($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        $lineNumber = 1 + ($text.Substring(0, $match.Index).Split("`n").Count - 1)
        Add-Issue -Severity ERROR -Line $lineNumber -Message "Found implementation/audit metadata that does not belong in the content tables."
    }
}

if ($RequireFiveTables) {
    $requiredHeadings = @("## 消费偏好", "## 投资偏好", "## 就业偏好", "## 携带效果", "## 独立效果")
    foreach ($heading in $requiredHeadings) {
        if (@($lines | Where-Object { $_ -eq $heading }).Count -ne 1) {
            Add-Issue -Severity ERROR -Line 0 -Message "Expected exactly one heading: $heading"
        }
    }

    $preferenceHeader = "ID|偏好名称|随机出现条件|偏好效果|取值范围"
    $effectHeader = "ID|效果名称|条件|对象|威望Ⅰ结果|威望Ⅱ结果|威望Ⅲ结果|威望Ⅳ结果|威望Ⅴ结果|完整表述"
    $preferenceHeaderCount = 0
    $effectHeaderCount = 0
    foreach ($line in $lines) {
        if (-not $line.Trim().StartsWith("|")) {
            continue
        }
        $normalized = (Split-MarkdownRow -Line $line) -join "|"
        if ($normalized -eq $preferenceHeader) {
            $preferenceHeaderCount++
        }
        if ($normalized -eq $effectHeader) {
            $effectHeaderCount++
        }
    }
    if ($preferenceHeaderCount -ne 3) {
        Add-Issue -Severity ERROR -Line 0 -Message "Expected the standard preference header three times; found $preferenceHeaderCount."
    }
    if ($effectHeaderCount -ne 2) {
        Add-Issue -Severity ERROR -Line 0 -Message "Expected the standard effect header twice; found $effectHeaderCount."
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..\..\..")).Path
}

$technologyPath = Join-Path $RepoRoot "Project\project-keynes\data\technology\technology_network.json"
if (Test-Path -LiteralPath $technologyPath -PathType Leaf) {
    $technology = Get-Content -LiteralPath $technologyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $knownTechnologyNames = @{}
    foreach ($node in $technology.nodes) {
        $knownTechnologyNames[[string]$node.display_name] = $true
    }
    foreach ($row in $preferenceRows) {
        $condition = [string]$row.Cells[2]
        if ($condition -notmatch '已解锁') {
            continue
        }
        $quotedNames = @([regex]::Matches($condition, '“([^”]+)”') |
            ForEach-Object { $_.Groups[1].Value })
        foreach ($name in $quotedNames) {
            if (-not $knownTechnologyNames.ContainsKey($name)) {
                Add-Issue -Severity ERROR -Line $row.Line -Message "Unknown quoted technology display name: $name"
            }
        }
    }
} else {
    Add-Issue -Severity WARN -Line 0 -Message "Technology catalog not found; skipped technology-name validation."
}

if ($RequireFullProfessionCoverage) {
    $professionPath = Join-Path $RepoRoot "Project\project-keynes\data\economy\professions"
    if (Test-Path -LiteralPath $professionPath -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $professionPath -File -Filter "*.tres") {
            $displayLine = Get-Content -LiteralPath $file.FullName -Encoding UTF8 |
                Select-String '^display_name\s*=\s*"(.*)"' |
                Select-Object -First 1
            if ($null -eq $displayLine) {
                continue
            }
            $displayName = $displayLine.Matches[0].Groups[1].Value
            if ($text -notmatch [regex]::Escape($displayName)) {
                Add-Issue -Severity ERROR -Line 0 -Message "Profession is not covered by display name: $displayName ($($file.BaseName))"
            }
        }
    } else {
        Add-Issue -Severity WARN -Line 0 -Message "Profession catalog not found; skipped full profession coverage."
    }
}

$orderedIssues = @($issues | Sort-Object @{Expression = { if ($_.Severity -eq "ERROR") { 0 } else { 1 } }}, Line, Message)
foreach ($issue in $orderedIssues) {
    $location = if ($issue.Line -gt 0) { "$resolvedPath`:$($issue.Line)" } else { $resolvedPath }
    Write-Output "$($issue.Severity) $location $($issue.Message)"
}

$errorCount = @($issues | Where-Object { $_.Severity -eq "ERROR" }).Count
$warningCount = @($issues | Where-Object { $_.Severity -eq "WARN" }).Count
Write-Output "SUMMARY preferences=$($preferenceRows.Count) effects=$($effectRows.Count) errors=$errorCount warnings=$warningCount"

if ($errorCount -gt 0 -or ($Strict -and $warningCount -gt 0)) {
    exit 1
}

exit 0
