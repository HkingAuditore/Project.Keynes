param([string]$Path, [string]$Filter = '')

$bytes = [IO.File]::ReadAllBytes($Path)
$magic = [BitConverter]::ToUInt32($bytes, 0)
if ($magic -ne 0x43504447) { Write-Output "NOT A PCK: 0x$($magic.ToString('X8'))"; exit 1 }
$packVer = [BitConverter]::ToUInt32($bytes, 4)
if ($packVer -ne 3) { Write-Output "unsupported pack_version=$packVer"; exit 1 }
$dirOffset = [BitConverter]::ToUInt64($bytes, 0x20)
$pos = [int]$dirOffset
$fileCount = [BitConverter]::ToUInt32($bytes, $pos); $pos += 4
Write-Output "pck=$([IO.Path]::GetFileName($Path)) total=$($bytes.Length) dir@$dirOffset files=$fileCount"

$hits = 0
for ($i = 0; $i -lt $fileCount; $i++) {
    $pathLen = [BitConverter]::ToUInt32($bytes, $pos); $pos += 4
    $name = [Text.Encoding]::UTF8.GetString($bytes, $pos, $pathLen); $pos += $pathLen
    if ($pos % 4 -ne 0) { $pos += 4 - ($pos % 4) }
    $offset = [BitConverter]::ToUInt64($bytes, $pos); $pos += 8
    $fsize = [BitConverter]::ToUInt64($bytes, $pos); $pos += 8
    $md5 = ([BitConverter]::ToString($bytes, $pos, 16)).Replace('-', '').ToLower(); $pos += 16
    $fflags = [BitConverter]::ToUInt32($bytes, $pos); $pos += 4
    if ($Filter -eq '' -or $name -match $Filter) {
        Write-Output ("{0}  size={1}  md5={2}  flags={3}" -f $name, $fsize, $md5, $fflags)
        $hits++
        if ($hits -ge 40) { Write-Output '... (truncated)'; break }
    }
}
