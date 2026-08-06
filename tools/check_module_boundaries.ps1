param(
    [string[]]$Paths,
    [switch]$Strict
)

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$limits = @{
    ".gd" = 1200
    ".cpp" = 2000
    ".h" = 1000
}
$excluded = @("emsdk", "godot-cpp", "tmp", "WebBuild", ".git")

if (-not $Paths -or $Paths.Count -eq 0) {
    $Paths = Get-ChildItem -Path $root -Recurse -File |
        Where-Object { $_.Extension -in $limits.Keys }
} else {
    $Paths = $Paths | ForEach-Object {
        if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $root $_ }
    }
}

$violations = @()
foreach ($path in $Paths) {
    $resolved = Resolve-Path $path -ErrorAction SilentlyContinue
    if (-not $resolved) { continue }
    $relative = $resolved.Path.Substring($root.Path.Length).TrimStart('\')
    if ($excluded | Where-Object { $relative -like "$_\*" }) { continue }
    $ext = [IO.Path]::GetExtension($resolved.Path)
    $lines = (Get-Content $resolved.Path | Measure-Object -Line).Lines
    if ($lines -gt $limits[$ext]) {
        $violations += [PSCustomObject]@{ Path = $relative; Lines = $lines; Limit = $limits[$ext] }
    }
}

$violations | Sort-Object Lines -Descending | Format-Table -AutoSize
if ($Strict -and $violations.Count -gt 0) {
    exit 1
}
exit 0
