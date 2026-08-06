param([string]$Path)

$bytes = [IO.File]::ReadAllBytes($Path)
$magic = [BitConverter]::ToUInt32($bytes, 0)
if ($magic -ne 0x43504447) { Write-Output "NOT A PCK: magic=0x$($magic.ToString('X8'))"; exit 1 }
$packVer = [BitConverter]::ToUInt32($bytes, 4)
$packFlags = [BitConverter]::ToUInt32($bytes, 20)
$pos = 48
$fileCount = [BitConverter]::ToUInt32($bytes, $pos); $pos += 4
Write-Output "pack_version=$packVer flags=$packFlags files=$fileCount size=$($bytes.Length)"

for ($i = 0; $i -lt $fileCount; $i++) {
    $pathLen = [BitConverter]::ToUInt32($bytes, $pos); $pos += 4
    $name = [Text.Encoding]::UTF8.GetString($bytes, $pos, $pathLen); $pos += $pathLen
    if ($pos % 4 -ne 0) { $pos += 4 - ($pos % 4) }
    $offset = [BitConverter]::ToUInt64($bytes, $pos); $pos += 8
    $fsize = [BitConverter]::ToUInt64($bytes, $pos); $pos += 8
    $md5 = ([BitConverter]::ToString($bytes, $pos, 16)).Replace('-', '').ToLower(); $pos += 16
    $fflags = [BitConverter]::ToUInt32($bytes, $pos); $pos += 4
    if ($name -match 'atlas_encoders|visual_tile_set|feature_flags|hex_renderer|map_baker\.gdc|world_map\.gdshader$|visual_tile_sampling') {
        Write-Output ("{0}  size={1}  md5={2}  flags={3}" -f $name, $fsize, $md5, $fflags)
    }
}
