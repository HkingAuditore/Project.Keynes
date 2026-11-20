<#
.SYNOPSIS
Points the dots_ext Windows GDExtension mapping at the debug or release DLL.

.DESCRIPTION
Godot's editor/console binary loads the `windows.debug.x86_64` entry of
addons/dots_ext/dots_ext.gdextension, so a headless run against the release DLL
is one line away (plan §8.2-A). This script flips exactly that line to the
`...template_release.x86_64.dll` that sits next to the debug DLL, and flips it
back with -Restore / -Variant debug.

Only that one mapping line is touched. dots_ext.gdextension carries GBK bytes in
its comments, so the file is never re-encoded: it is decoded as Latin-1 (a
bijective byte <-> char mapping), spliced, and encoded back as Latin-1. Every
byte outside the DLL name therefore stays identical, which is checked against a
line diff before writing.

The variant is derived from the DLL name suffix itself, so switching is
idempotent (repeated -Variant release writes nothing) and -Restore is
byte-identical by construction. A byte-exact copy of the pre-switch file is also
kept under tmp/gdext_library_backup/ for manual recovery, and -Restore reports
whether the restored file matches it.

Pair every switch with try/finally so a crash cannot leave the release mapping
behind for the next person:

    .\tools\runtime\Use-GdextLibrary.ps1 -Variant release -Quiet
    try {
        # ... headless replay / soak ...
    }
    finally {
        .\tools\runtime\Use-GdextLibrary.ps1 -Restore -Quiet
    }

.EXAMPLE
  .\tools\runtime\Use-GdextLibrary.ps1 -Variant release

.EXAMPLE
  .\tools\runtime\Use-GdextLibrary.ps1 -Restore

.EXAMPLE
  .\tools\runtime\Use-GdextLibrary.ps1 -Query
#>
[CmdletBinding(DefaultParameterSetName = 'Variant')]
param(
    [Parameter(ParameterSetName = 'Variant', Position = 0)]
    [ValidateSet('release', 'debug')]
    [string]$Variant = 'debug',

    # Switch back to the debug mapping. Same operation as -Variant debug.
    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [switch]$Restore,

    # Print the current mapping variant; changes nothing.
    [Parameter(ParameterSetName = 'Query', Mandatory = $true)]
    [switch]$Query,

    [string]$RepoRoot = (Get-Location).Path,
    [string]$LibraryPath = '',

    # No stdout. Used when another script wraps the switch in try/finally.
    [switch]$Quiet,

    # Switch even when the target DLL has not been built yet.
    [switch]$AllowMissingDll
)

$ErrorActionPreference = 'Stop'

$repository = (Resolve-Path -LiteralPath $RepoRoot).Path
$projectRoot = Join-Path $repository 'Project\project-keynes'
if ([string]::IsNullOrWhiteSpace($LibraryPath)) {
    $LibraryPath = Join-Path $projectRoot 'addons\dots_ext\dots_ext.gdextension'
}
if (-not (Test-Path -LiteralPath $LibraryPath -PathType Leaf)) {
    throw "GDExtension descriptor not found: $LibraryPath"
}
$LibraryPath = (Resolve-Path -LiteralPath $LibraryPath).Path

$debugToken = 'template_debug'
$releaseToken = 'template_release'
$targetVariant = if ($Query) { '' } elseif ($Restore) { 'debug' } else { $Variant.ToLowerInvariant() }

# Latin-1 maps every byte 0x00-0xFF to exactly one char and back, so a
# GetString/GetBytes round trip cannot touch the GBK comment bytes the file
# contains. UTF-8 (or Set-Content) would silently replace them.
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$originalBytes = [System.IO.File]::ReadAllBytes($LibraryPath)
$originalText = $latin1.GetString($originalBytes)

# Windows only: Godot resolves `windows.debug.x86_64` for the editor/console
# binary. Anchor on that key so windows.release and the other platform rows can
# never match.
$pattern = '(?m)^(?<lead>[ \t]*windows\.debug\.x86_64[ \t]*=[ \t]*")(?<path>[^"\r\n]*)(?<trail>")'
$lineMatches = [regex]::Matches($originalText, $pattern)
if ($lineMatches.Count -ne 1) {
    throw "Expected exactly one windows.debug.x86_64 mapping line in $LibraryPath, found $($lineMatches.Count)"
}
$lineMatch = $lineMatches[0]
$currentValue = $lineMatch.Groups['path'].Value

$currentVariant = ''
if ($currentValue.Contains($releaseToken)) {
    $currentVariant = 'release'
} elseif ($currentValue.Contains($debugToken)) {
    $currentVariant = 'debug'
} else {
    throw "Cannot derive the current variant from '$currentValue'; expected $debugToken or $releaseToken"
}

$newValue = $currentValue
if ($Query) {
    if (-not $Quiet) {
        Write-Host "[gdext-library] variant : $currentVariant"
        Write-Host "[gdext-library] dll     : $currentValue"
        Write-Host "[gdext-library] path    : $LibraryPath"
    }
    exit 0
}

if ($currentVariant -ne $targetVariant) {
    $newValue = if ($targetVariant -eq 'release') {
        $currentValue.Replace($debugToken, $releaseToken)
    } else {
        $currentValue.Replace($releaseToken, $debugToken)
    }
}

# Resolve the mapped DLL so a typo or a not-yet-built release target fails here
# with a readable message instead of as a GDExtension load error inside Godot.
$dllPath = $newValue
if ($dllPath.StartsWith('res://')) {
    $dllPath = Join-Path $projectRoot ($dllPath.Substring('res://'.Length).Replace('/', '\'))
}
$dllExists = Test-Path -LiteralPath $dllPath -PathType Leaf
if (-not $dllExists -and -not $AllowMissingDll) {
    throw "Target DLL is not built: $dllPath (run gdext\rebuild.bat or pass -AllowMissingDll)"
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

$backupDir = Join-Path $repository 'tmp\gdext_library_backup'
$backupPath = Join-Path $backupDir 'dots_ext.gdextension.debug.bak'

if ($currentVariant -eq $targetVariant) {
    if (-not $Quiet) {
        Write-Host "[gdext-library] variant : $targetVariant (already; no write)"
        Write-Host "[gdext-library] path    : $LibraryPath"
        Write-Host "[gdext-library] sha256  : $(Get-Sha256 $LibraryPath)"
    }
    exit 0
}

# Splice only the mapped path; the lead/trail bytes of the line and every other
# line stay byte-identical.
$valueGroup = $lineMatch.Groups['path']
$newText = $originalText.Substring(0, $valueGroup.Index) + $newValue + `
    $originalText.Substring($valueGroup.Index + $valueGroup.Length)

# Guard: exactly one line may differ, so a regex that accidentally spans rows
# can never rewrite the file.
$oldLines = $originalText -split "`n"
$newLines = $newText -split "`n"
if ($oldLines.Count -ne $newLines.Count) {
    throw "Refusing to write: line count would change ($($oldLines.Count) -> $($newLines.Count))"
}
$changedLines = 0
for ($index = 0; $index -lt $oldLines.Count; $index++) {
    if ($oldLines[$index] -cne $newLines[$index]) { $changedLines++ }
}
if ($changedLines -ne 1) {
    throw "Refusing to write: $changedLines lines would change, expected exactly 1"
}

# Keep a recovery copy of the pristine debug-mapped file before the first
# switch. It is evidence only; -Restore reverses the patch itself.
if ($targetVariant -eq 'release') {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    [System.IO.File]::WriteAllBytes($backupPath, $originalBytes)
}

$newBytes = $latin1.GetBytes($newText)
[System.IO.File]::WriteAllBytes($LibraryPath, $newBytes)

# Read back through the filesystem so the printed hash is the one on disk.
$writtenBytes = [System.IO.File]::ReadAllBytes($LibraryPath)
$prefixLength = $valueGroup.Index
$suffixOffset = $valueGroup.Index + $valueGroup.Length
$prefixKept = 0
while ($prefixKept -lt $prefixLength -and
        $writtenBytes[$prefixKept] -eq $originalBytes[$prefixKept]) {
    $prefixKept++
}
$suffixLength = $originalBytes.Length - $suffixOffset
$suffixKept = 0
while ($suffixKept -lt $suffixLength -and
        $writtenBytes[$writtenBytes.Length - 1 - $suffixKept] -eq
        $originalBytes[$originalBytes.Length - 1 - $suffixKept]) {
    $suffixKept++
}
if ($prefixKept -ne $prefixLength -or $suffixKept -ne $suffixLength) {
    throw "Byte-preservation check failed: prefix $prefixKept/$prefixLength suffix $suffixKept/$suffixLength"
}

# A successful restore proves the reversible patch, so the recovery copy is only
# kept while it still differs from the file on disk.
$backupMatch = 'no-backup'
if ($targetVariant -eq 'debug' -and (Test-Path -LiteralPath $backupPath)) {
    $backupMatch = (Get-Sha256 $LibraryPath) -eq (Get-Sha256 $backupPath)
    if ($backupMatch) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

if (-not $Quiet) {
    Write-Host "[gdext-library] variant : $currentVariant -> $targetVariant"
    Write-Host "[gdext-library] line    : windows.debug.x86_64 = `"$newValue`""
    Write-Host "[gdext-library] dll     : $dllPath (exists=$dllExists)"
    Write-Host ("[gdext-library] bytes   : {0} -> {1} (untouched prefix+suffix verified)" -f `
        $originalBytes.Length, $writtenBytes.Length)
    Write-Host "[gdext-library] sha256  : $(Get-Sha256 $LibraryPath)"
    if ($targetVariant -eq 'debug') {
        Write-Host "[gdext-library] backup  : $backupPath match=$backupMatch"
    }
}
