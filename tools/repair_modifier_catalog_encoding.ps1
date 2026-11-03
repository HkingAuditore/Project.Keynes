<#
.SYNOPSIS
  Repair modifier_catalog.gd: truncated closing quotes + GBK/UTF-8 double-encoded literals.

.DESCRIPTION
  The working-tree copy was saved after the Chinese literals had been decoded as
  GBK and re-encoded as UTF-8, and many of them also lost their closing quote
  (the last byte of the literal became '?'). The result does not parse:

      Parse Error: Expected closing "}" after dictionary elements.

  Repair in two deterministic passes:
    1. every '?' in this file is a lost closing quote -> restore it to '"';
    2. decode each quoted literal that still contains non-ASCII bytes by
       GBK(bytes) -> UTF-8 text, which is the exact inverse of the corruption.

  The script prints any line that still has an unbalanced quote count so it can be
  fixed by hand.
#>
[CmdletBinding()]
param(
    [string]$Path = "D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\scripts\modifier\modifier_catalog.gd"
)

$ErrorActionPreference = "Stop"
$gbk = [System.Text.Encoding]::GetEncoding(936)
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Convert-Mojibake([string]$value) {
    $bytes = $gbk.GetBytes($value)
    for ($trim = 0; $trim -le 3; $trim++) {
        $len = $bytes.Length - $trim
        if ($len -le 0) { return $null }
        $candidate = $utf8.GetString($bytes, 0, $len)
        if ($candidate -notmatch [char]0xFFFD) { return $candidate }
    }
    return $null
}

$lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
$quoteFixed = 0
$decoded = 0
$unbalanced = @()

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line.Contains('?')) {
        $line = $line.Replace('?', '"')
        $quoteFixed++
    }
    $matches = [regex]::Matches($line, '"([^"]*)"')
    foreach ($m in $matches) {
        $body = $m.Groups[1].Value
        if ($body -eq "" -or $body -notmatch '[^\x00-\x7F]') { continue }
        $text = Convert-Mojibake $body
        if (-not $text) { continue }
        $line = $line.Replace($m.Value, '"' + $text + '"')
        $decoded++
    }
    $quoteCount = ([regex]::Matches($line, '"')).Count
    if ($quoteCount % 2 -ne 0) { $unbalanced += ($i + 1) }
    $lines[$i] = $line
}

[System.IO.File]::WriteAllLines($Path, $lines, $utf8)
Write-Host "[repair] quote fixes: $quoteFixed, literals decoded: $decoded"
if ($unbalanced.Count -gt 0) {
    Write-Host ("[repair] still unbalanced at lines: " + ($unbalanced -join ', '))
} else {
    Write-Host "[repair] all lines have balanced quotes"
}
