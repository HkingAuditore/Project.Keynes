#requires -Version 5.1
# One-off migration: replace hardcoded Godot paths in skill scripts with the
# repo-wide GODOT_BIN convention. Preserves each file's original encoding.
$ErrorActionPreference = 'Stop'
$root = 'D:\Godot\ProjectKeynes\Project.Keynes'

$deadPath = 'F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe'
$livePath = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe'
$defaultExpr = '$(if ($env:GODOT_BIN) { $env:GODOT_BIN } else { ''' + $livePath + ''' })'

function Get-FileEncoding {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [pscustomobject]@{ Name = 'utf8-bom'; Encoding = (New-Object System.Text.UTF8Encoding($true)) }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [pscustomobject]@{ Name = 'utf16le-bom'; Encoding = (New-Object System.Text.UnicodeEncoding($false, $true)) }
    }
    if ($Bytes.Length -gt 4 -and $Bytes[1] -eq 0 -and $Bytes[3] -eq 0) {
        return [pscustomobject]@{ Name = 'utf16le'; Encoding = (New-Object System.Text.UnicodeEncoding($false, $false)) }
    }
    return [pscustomobject]@{ Name = 'utf8'; Encoding = (New-Object System.Text.UTF8Encoding($false)) }
}

$files = Get-ChildItem -Path $root -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike "$root\tmp\*" } |
    Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'F:\\Developent' }

$patched = 0
foreach ($file in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $enc = Get-FileEncoding -Bytes $bytes
    $text = $enc.Encoding.GetString($bytes)
    if ($enc.Name -like '*bom*') { $text = $text.TrimStart([char]0xFEFF) }
    $original = $text

    # 1) param() default values that point at a drive that no longer exists.
    $text = $text.Replace("'$deadPath'", $defaultExpr)
    $text = $text.Replace("`"$deadPath`"", $defaultExpr)

    # 2) Discovery roots used by the hotloop test runner.
    $text = $text.Replace('"F:\Developent\Godot", "C:\Program Files\Godot"',
                          '"D:\Godot", "C:\Program Files\Godot"')

    # 3) Let that same runner honour GODOT_BIN before falling back to discovery.
    $text = [regex]::Replace(
        $text,
        '(?<lead>\$ErrorActionPreference = ''Continue''\r?\n\r?\n)(?<tail>if \(-not \$GodotExe\) \{)',
        '${lead}# GODOT_BIN is the repo-wide convention for locating Godot.' + "`r`n" +
        'if (-not $GodotExe) { $GodotExe = $env:GODOT_BIN }' + "`r`n" + '${tail}')

    if ($text -ne $original) {
        [System.IO.File]::WriteAllText($file.FullName, $text, $enc.Encoding)
        $patched++
        $rel = $file.FullName.Replace("$root\", '')
        "patched [$($enc.Name)] $rel"
    }
}
""
"files patched: $patched"
$remaining = Get-ChildItem -Path $root -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike "$root\tmp\*" } |
    Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'F:\\Developent' }
"ps1 still referencing dead drive: $(@($remaining).Count)"
