param([string]$Path, [int]$Count = 128)
$bytes = [IO.File]::ReadAllBytes($Path)
for ($row = 0; $row -lt [math]::Ceiling($Count / 16); $row++) {
    $hex = ''
    $asc = ''
    for ($c = 0; $c -lt 16; $c++) {
        $b = $bytes[$row * 16 + $c]
        $hex += $b.ToString('X2') + ' '
        $ch = [char]$b
        if ([char]::IsLetterOrDigit($ch) -or $ch -eq '.' -or $ch -eq '/' -or $ch -eq '_' -or $ch -eq '-') { $asc += $ch } else { $asc += '.' }
    }
    Write-Output ("{0:X4}: {1} | {2}" -f ($row * 16), $hex, $asc)
}
