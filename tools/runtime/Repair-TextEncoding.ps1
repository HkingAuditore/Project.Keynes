<#
.SYNOPSIS
Normalises source files to UTF-8 without a BOM.

.DESCRIPTION
Some editors and tools in this repo write UTF-16LE without a BOM. Godot's
GDScript parser only accepts UTF-8, so such a file fails with a misleading
"Unexpected identifier" parse error rather than an encoding error. PowerShell
5.1 fails on it too, for the same reason.

Detects UTF-16 (with or without BOM) and UTF-8-with-BOM, rewrites as UTF-8
without BOM, and leaves already-correct files untouched.
#>
param(
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

foreach ($item in $Path) {
    $resolved = Resolve-Path -LiteralPath $item -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Write-Warning "not found: $item"
        continue
    }
    foreach ($full in @($resolved.Path)) {
        $bytes = [System.IO.File]::ReadAllBytes($full)
        if ($bytes.Length -lt 2) { continue }

        $detected = $null
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $detected = 'utf16le-bom'
            $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        }
        elseif ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $detected = 'utf16be-bom'
            $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
        }
        elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $detected = 'utf8-bom'
            $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        }
        elseif ($bytes.Length -gt 4 -and $bytes[1] -eq 0 -and $bytes[3] -eq 0) {
            $detected = 'utf16le-nobom'
            $text = [System.Text.Encoding]::Unicode.GetString($bytes)
        }

        $name = Split-Path $full -Leaf
        if ($null -eq $detected) {
            Write-Host "utf8 already : $name"
            continue
        }
        [System.IO.File]::WriteAllText($full, $text, $utf8NoBom)
        Write-Host "converted    : $name ($detected -> utf8)"
    }
}
