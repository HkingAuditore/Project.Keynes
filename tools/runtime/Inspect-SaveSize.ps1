<#
.SYNOPSIS
Explains where a .pksv save's bytes go: per section, and inside the PKSR runtime bundle.

.DESCRIPTION
Reads the PKSV v2 container without touching the game: 4-byte magic, u32 format
version, u32 header length, a JSON header (provider manifest + section table),
then one zstd blob per section. The header alone already reports every section's
compressed and uncompressed length, so the shallow report needs no decompressor.

-Deep additionally decompresses the simulation_runtime section (the PKSR v5
runtime envelope) and splits it into its internal sub-sections (CLM2 climate,
ECP2 economy, ...). PKSV compresses a whole section at once, so a sub-section's
share of the file cannot be read off the container table; the report therefore
re-compresses each block on its own and says so. The sum of the block costs
matches the section's own compressed length within about 1%, which is enough to
rank causes but is an estimate, not an accounting identity.

Why this tool exists (measured 2026-11-20 on a day-628 100x64 save): 55% of a
9.96 MiB save was the 365-day per-cell temperature ring
(RuntimeClimateAuthority::serialize -> _store.temperature_history), 23% was the
same ECP2 economy checkpoint stored twice (once inside PKSR, once as the
container's own ecp2 section), 9% was a full-window PNG preview, and 3% was the
ECP1 economy encoding that restore explicitly skips. None of that is visible in
the container table, which is why the deep pass exists.

Requires: PowerShell 7 (or 5.1) and a zstd executable on PATH for -Deep/-Verify.
.Set -ZstdPath when it is installed somewhere PATH does not see.

.PARAMETER Slot
Save slot id under user://saves. Ignored when -SavePath is given.

.PARAMETER Deep
Also parse the PKSR bundle: inner sub-section table plus per-block cost.

.PARAMETER Verify
Re-hash every decompressed section and compare it with the header's sha256.
Implies -Deep.

.PARAMETER Json
Print one machine-readable [save-size/summary] line and write a JSON file.

.EXAMPLE
  .\tools\runtime\Inspect-SaveSize.ps1 -Slot manual_1 -Deep

.EXAMPLE
  .\tools\runtime\Inspect-SaveSize.ps1 -Slot autosave

.EXAMPLE
  .\tools\runtime\Inspect-SaveSize.ps1 -SavePath C:\tmp\day628.pksv -Deep -Verify -Json
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [ValidateSet('manual_1', 'manual_2', 'manual_3', 'autosave')]
    [string]$Slot = 'autosave',
    [string]$SavePath = '',
    [string]$SaveDir = '',
    [string]$ProjectPath = '',
    [switch]$Deep,
    [switch]$Verify,
    [string]$ZstdPath = '',
    [ValidateRange(1, 100)]
    [int]$Top = 15,
    [switch]$Json,
    [string]$JsonPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Verify) { $Deep = $true }

$warnings = New-Object System.Collections.Generic.List[string]


## PowerShell unrolls a returned array into the output stream and re-collects it
## as object[], i.e. one boxed object per byte: a 90 MiB bundle then costs GBs of
## memory and minutes of time. The unary comma keeps the value a single byte[].
function Get-Block {
    param([byte[]]$Bytes, [int]$Offset, [int]$Length)
    if ($Length -le 0) { return , ([byte[]]::new(0)) }
    $out = [byte[]]::new($Length)
    [System.Buffer]::BlockCopy($Bytes, $Offset, $out, 0, $Length)
    return , $out
}


function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}


## Latin1 is a 1:1 byte<->char map, so a marker can be located with String.IndexOf
## instead of a per-byte PowerShell loop (which is far too slow over 90 MiB).
function Get-Latin1 {
    param([byte[]]$Bytes)
    try { return [System.Text.Encoding]::Latin1.GetString($Bytes) }
    catch { return [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes) }
}


function Find-Marker {
    param([byte[]]$Bytes, [string]$Marker, [int]$Start = 0, [int]$Limit = 0)
    $end = $Bytes.Length
    if ($Limit -gt 0 -and $Start + $Limit -lt $end) { $end = $Start + $Limit }
    $slice = Get-Block $Bytes $Start ($end - $Start)
    $index = (Get-Latin1 $slice).IndexOf($Marker, [System.StringComparison]::Ordinal)
    if ($index -lt 0) { return -1 }
    return $Start + $index
}


function Resolve-Zstd {
    if ($ZstdPath) {
        if (-not (Test-Path -LiteralPath $ZstdPath -PathType Leaf)) {
            throw "zstd not found at '$ZstdPath'."
        }
        return (Resolve-Path -LiteralPath $ZstdPath).Path
    }
    $command = Get-Command zstd, zstd.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return $command.Source }
    # Common Windows installs that do not export PATH entries to every shell.
    $candidates = @(
        (Join-Path $env:ProgramData 'anaconda3\Library\bin\zstd.exe'),
        (Join-Path $env:ProgramData 'chocolatey\bin\zstd.exe'),
        (Join-Path $env:USERPROFILE 'scoop\shims\zstd.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}


function Invoke-Zstd {
    param([string]$Zstd, [string[]]$Arguments)
    $stdout = & $Zstd @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "zstd $($Arguments -join ' ') failed (exit $LASTEXITCODE): $stdout"
    }
}


$zstd = ''
if ($Deep) {
    $zstd = Resolve-Zstd
    if (-not $zstd) {
        throw ("-Deep needs a zstd executable. Install one (e.g. 'winget install zstd') " +
            "or pass -ZstdPath <path>\to\zstd.exe.")
    }
}

$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("pk_save_size_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null


function Expand-Zstd {
    param([byte[]]$Blob)
    if ($null -eq $Blob -or $Blob.Length -eq 0) { return , ([byte[]]::new(0)) }
    $in = Join-Path $scratch 'in.zst'
    $out = Join-Path $scratch 'out.bin'
    [System.IO.File]::WriteAllBytes($in, $Blob)
    Invoke-Zstd $zstd @('-d', '-f', '-q', $in, '-o', $out)
    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($out)
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    return , $bytes
}


## Cost of one block inside an already-compressed section: zstd level 3 is what
## PackedByteArray.compress(COMPRESSION_ZSTD) uses, so the number is comparable
## with the container's own compressed lengths.
function Measure-Zstd {
    param([byte[]]$Blob)
    if ($null -eq $Blob -or $Blob.Length -eq 0) { return 0 }
    $in = Join-Path $scratch 'cost.bin'
    $out = Join-Path $scratch 'cost.zst'
    [System.IO.File]::WriteAllBytes($in, $Blob)
    Invoke-Zstd $zstd @('-3', '-f', '-q', $in, '-o', $out)
    $size = (Get-Item -LiteralPath $out).Length
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    return [int]$size
}


function Format-Share {
    param([double]$Bytes, [double]$Total)
    if ($Total -le 0) { return '   -  ' }
    return ('{0,5:N1}%' -f (100.0 * $Bytes / $Total))
}


try {
    # ---------------------------------------------------------------- resolve file
    if (-not $SavePath) {
        $resolvedProject = $ProjectPath
        if (-not $resolvedProject) { $resolvedProject = Join-Path $RepoRoot 'Project\project-keynes' }
        $projectName = 'ProjectKeynes'
        $projectFile = Join-Path $resolvedProject 'project.godot'
        if (Test-Path -LiteralPath $projectFile -PathType Leaf) {
            foreach ($line in Get-Content -LiteralPath $projectFile -ErrorAction SilentlyContinue) {
                if ($line -match '^\s*config/name\s*=\s*"([^"]*)"') { $projectName = $Matches[1]; break }
            }
        }
        $directory = $SaveDir
        if (-not $directory -and $env:PK_SAVE_DIR) { $directory = $env:PK_SAVE_DIR }
        if (-not $directory) {
            $directory = Join-Path (Join-Path (Join-Path $env:APPDATA 'Godot\app_userdata') $projectName) 'saves'
        }
        $SavePath = Join-Path $directory ("$Slot.pksv")
    }
    if (-not (Test-Path -LiteralPath $SavePath -PathType Leaf)) {
        throw "Save not found: $SavePath"
    }
    $SavePath = (Resolve-Path -LiteralPath $SavePath).Path

    # ---------------------------------------------------------------- read header
    $raw = [System.IO.File]::ReadAllBytes($SavePath)
    if ($raw.Length -lt 12) { throw "Not a PKSV container: file is only $($raw.Length) bytes." }
    $magic = [System.Text.Encoding]::ASCII.GetString($raw, 0, 4)
    if ($magic -ne 'PKSV') { throw "Not a PKSV container: magic is '$magic'." }
    $formatVersion = [BitConverter]::ToUInt32($raw, 4)
    $headerLength = [BitConverter]::ToUInt32($raw, 8)
    if (12 + $headerLength -gt $raw.Length) { throw "Header length $headerLength runs past the file." }
    $headerText = [System.Text.Encoding]::UTF8.GetString($raw, 12, $headerLength)
    $header = $headerText | ConvertFrom-Json
    $dataStart = 12 + $headerLength
    $cells = [int]$header.width * [int]$header.height

    $sections = @()
    foreach ($section in $header.sections) {
        $sections += [pscustomobject]@{
            id           = [string]$section.id
            offset       = [int]$section.offset
            length       = [int]$section.length
            raw_length   = [int]$section.uncompressed_length
            sha256       = [string]$section.sha256
            ratio        = if ([int]$section.uncompressed_length -gt 0) {
                [double]$section.length / [double]$section.uncompressed_length
            } else { 0.0 }
        }
    }
    $compressedTotal = ($sections | Measure-Object -Property length -Sum).Sum
    $rawTotal = ($sections | Measure-Object -Property raw_length -Sum).Sum

    # ---------------------------------------------------------------- report head
    Write-Host ''
    Write-Host ("== {0} ==" -f (Split-Path -Leaf $SavePath)) -ForegroundColor Cyan
    Write-Host ("file        {0:N2} MiB ({1:N0} bytes, header {2:N0} B)" -f ($raw.Length / 1MB), $raw.Length, (12 + $headerLength))
    Write-Host ("format      PKSV v{0}   saved {1}   day {2}   reason '{3}'" -f $formatVersion, $header.saved_at, $header.day, $header.reason)
    Write-Host ("world       {0}x{1} = {2:N0} cells   seed {3}   country {4}" -f $header.width, $header.height, $cells, $header.seed, $header.country_name)
    Write-Host ("payload     {0:N2} MiB raw -> {1:N2} MiB zstd (ratio {2:N3}, {3:N1}x)" -f `
        ($rawTotal / 1MB), ($compressedTotal / 1MB), ($compressedTotal / [Math]::Max(1, $rawTotal)), ($rawTotal / [Math]::Max(1, $compressedTotal)))
    Write-Host ''

    # ---------------------------------------------------------------- providers
    Write-Host ("providers ({0})" -f $header.provider_manifest.Count) -ForegroundColor Cyan
    $index = 0
    foreach ($provider in $header.provider_manifest) {
        $sectionList = ($provider.sections | ForEach-Object { [string]$_ }) -join ', '
        if (-not $sectionList) { $sectionList = '(none)' }
        Write-Host ("  {0,2}  {1,-22} schema {2,-4} {3}" -f $index, $provider.provider_id, $provider.schema_version, $sectionList)
        $index++
    }
    Write-Host ''

    # ---------------------------------------------------------------- sections
    Write-Host ("sections ({0}, by compressed size)" -f $sections.Count) -ForegroundColor Cyan
    Write-Host ("  {0,-20} {1,9} {2,9} {3,7} {4,7}" -f 'id', 'comp MiB', 'raw MiB', 'ratio', 'share')
    foreach ($section in ($sections | Sort-Object -Property length -Descending)) {
        Write-Host ("  {0,-20} {1,9:N3} {2,9:N3} {3,7:N3} {4}" -f `
            $section.id, ($section.length / 1MB), ($section.raw_length / 1MB), $section.ratio,
            (Format-Share $section.length $raw.Length))
    }
    Write-Host ''

    # ---------------------------------------------------------------- deep parse
    $inner = @()
    $innerCosts = @{}
    $historyItem = $null
    $duplicateNote = ''
    $simSection = $sections | Where-Object { $_.id -eq 'simulation_runtime' } | Select-Object -First 1

    if ($Deep -and $null -ne $simSection) {
        $blob = Get-Block $raw ($dataStart + $simSection.offset) $simSection.length
        $pksr = Expand-Zstd $blob
        $pksrMagic = [System.Text.Encoding]::ASCII.GetString($pksr, 0, 4)
        if ($pksrMagic -ne 'PKSR') { throw "simulation_runtime is not a PKSR bundle (magic '$pksrMagic')." }
        $pksrVersion = [BitConverter]::ToUInt32($pksr, 4)

        # Sub-section marker families. The trailing character is the section's own
        # ABI (IDP1 -> IDP2, CLM2, ...), so match the family instead of a literal
        # four-character string or an older save ends the walk early.
        $markerPattern = '^(DPD|CLM|CPD|D7T|TPD|MDF|EVT|GMP|EFP|IDP|ECP)[0-9A-Z]$'
        $position = Find-Marker $pksr 'DPD2' 0 1048576
        if ($position -lt 0) { $warnings.Add('PKSR bundle has no DPD2 marker; inner breakdown skipped.') }
        while ($position -ge 0 -and $position + 12 -le $pksr.Length) {
            $marker = [System.Text.Encoding]::ASCII.GetString($pksr, $position, 4)
            if ($marker -notmatch $markerPattern) {
                $warnings.Add("PKSR inner walk stopped at offset $position (marker '$marker').")
                break
            }
            $size = [int][BitConverter]::ToUInt32($pksr, $position + 4)
            if ($position + 8 + $size + 8 -gt $pksr.Length) {
                $warnings.Add("PKSR inner section $marker length $size runs past the bundle.")
                break
            }
            $inner += [pscustomobject]@{
                marker = $marker
                offset = $position + 8
                length = $size
                cost   = $null
            }
            $position = $position + 8 + $size + 8
        }

        $innerRaw = ($inner | Measure-Object -Property length -Sum).Sum
        Write-Host ("-- PKSR v{0} inner bundle ({1:N2} MiB, envelope {2:N0} B) --" -f `
            $pksrVersion, ($pksr.Length / 1MB), ($pksr.Length - $innerRaw)) -ForegroundColor Cyan
        Write-Host ("  {0,-6} {1,10} {2,10} {3,7}" -f 'marker', 'raw MiB', 'cost MiB', 'share')
        foreach ($block in $inner) {
            $bytes = Get-Block $pksr $block.offset $block.length
            $block.cost = Measure-Zstd $bytes
            $innerCosts[$block.marker] = $block.cost
            Write-Host ("  {0,-6} {1,10:N3} {2,10:N3} {3}" -f `
                $block.marker, ($block.length / 1MB), ($block.cost / 1MB), (Format-Share $block.cost $raw.Length))
        }
        Write-Host ''

        # ------------------------------------------------ climate history split
        $climateBlock = $inner | Where-Object { $_.marker -like 'CLM*' } | Select-Object -First 1
        if ($null -ne $climateBlock) {
            $climate = Get-Block $pksr $climateBlock.offset $climateBlock.length
            if ($climate.Length -gt 140) {
                $abi = [BitConverter]::ToUInt32($climate, 4)
                $climateCells = [BitConverter]::ToUInt32($climate, 12)
                # Payload = 80 B section header + 56 B prefix + the ABI's f32 cell
                # lanes, then the rolling 365-day history lane. Lane counts:
                # ABI >= 4 carries 31 lanes (synoptic psi added in 4), ABI 3
                # carries 29. The length check below is what actually decides,
                # so a wrong guess just skips the split instead of mis-slicing.
                # Layout owner: RuntimeClimateAuthority::serialize
                # (gdext/src/runtime_climate_authority.cpp).
                $expectedHistory = [int]$climateCells * 365
                foreach ($laneCount in @(31, 29)) {
                    $cursor = 80 + 56
                    $lanesOk = $true
                    for ($lane = 0; $lane -lt $laneCount -and $lanesOk; $lane++) {
                        if ($cursor + 4 -gt $climate.Length) { $lanesOk = $false; break }
                        $count = [int][BitConverter]::ToUInt32($climate, $cursor)
                        if ($count -lt 0 -or $count -gt $climate.Length) { $lanesOk = $false; break }
                        $cursor += 4 + $count * 4
                    }
                    if (-not $lanesOk -or $cursor + 4 -gt $climate.Length) { continue }
                    $historyFloats = [int][BitConverter]::ToUInt32($climate, $cursor)
                    if ($historyFloats -ne $expectedHistory) { continue }
                    $historyBytes = Get-Block $climate ($cursor + 4) ($historyFloats * 4)
                    $historyCost = Measure-Zstd $historyBytes
                    $historyItem = [pscustomobject]@{
                        id    = 'CLM2 climate / 365d temperature history'
                        raw   = $historyBytes.Length
                        cost  = $historyCost
                        days  = 365
                        cells = $climateCells
                        abi   = $abi
                    }
                    Write-Host ("climate history: ABI {0}, {1:N0} cells x 365 d x f32 = {2:N2} MiB raw -> {3:N2} MiB in file" -f `
                        $abi, $climateCells, ($historyBytes.Length / 1MB), ($historyCost / 1MB))
                    Write-Host ''
                    break
                }
                if ($null -eq $historyItem) {
                    if ($abi -ge 10) {
                        # ABI 10 stopped persisting the ring on purpose; report it
                        # instead of warning so a healthy new save reads clean.
                        Write-Host ("climate history: ABI {0} omits the 365-day ring by design" -f $abi)
                        Write-Host ''
                    }
                    else {
                        $warnings.Add("CLM2 ABI ${abi}: 365-day history lane not located; climate split skipped.")
                    }
                }
            }
        }

        # ------------------------------------------------ duplicated ECP2
        $innerEcp2 = $inner | Where-Object { $_.marker -eq 'ECP2' } | Select-Object -First 1
        $containerEcp2 = $sections | Where-Object { $_.id -eq 'ecp2' } | Select-Object -First 1
        if ($null -ne $innerEcp2 -and $null -ne $containerEcp2) {
            $innerBytes = Get-Block $pksr $innerEcp2.offset $innerEcp2.length
            $containerBytes = Expand-Zstd (Get-Block $raw ($dataStart + $containerEcp2.offset) $containerEcp2.length)
            if ($innerBytes.Length -eq $containerBytes.Length) {
                $same = (Get-Sha256Hex $innerBytes) -eq (Get-Sha256Hex $containerBytes)
                if ($same) {
                    $duplicateNote = 'ecp2 container section is byte-identical to the ECP2 block inside PKSR'
                    Write-Host ("duplicate: the container's ecp2 section ({0:N2} MiB) is byte-identical to PKSR's ECP2 block" -f `
                        ($containerEcp2.length / 1MB)) -ForegroundColor Yellow
                    Write-Host ''
                }
            }
            $containerBytes = $null
            $innerBytes = $null
        }
    }

    # ---------------------------------------------------------------- verify
    $verifyResults = @()
    if ($Verify) {
        Write-Host 'verify: re-hashing decompressed sections' -ForegroundColor Cyan
        $bad = 0
        foreach ($section in $sections) {
            if ($section.length -eq 0) { continue }
            $bytes = Expand-Zstd (Get-Block $raw ($dataStart + $section.offset) $section.length)
            $actual = Get-Sha256Hex $bytes
            $ok = $actual -eq $section.sha256
            if (-not $ok) { $bad++ }
            $verifyResults += [pscustomobject]@{ id = $section.id; ok = $ok; sha256 = $actual }
            if (-not $ok) { Write-Host ("  MISMATCH {0}: header {1} actual {2}" -f $section.id, $section.sha256, $actual) -ForegroundColor Red }
            $bytes = $null
        }
        Write-Host ("  {0} sections checked, {1} mismatch(es)" -f $sections.Count, $bad)
        Write-Host ''
    }

    # ---------------------------------------------------------------- item table
    $items = @()
    foreach ($section in $sections) {
        if ($section.id -eq 'simulation_runtime' -and $Deep -and $inner.Count -gt 0) { continue }
        $items += [pscustomobject]@{
            id     = $section.id
            raw    = $section.raw_length
            cost   = $section.length
            source = 'container'
        }
    }
    if ($Deep -and $inner.Count -gt 0) {
        $innerSum = 0
        foreach ($block in $inner) { $innerSum += [int]$block.cost }
        foreach ($block in $inner) {
            $label = "PKSR $($block.marker)"
            $cost = [int]$block.cost
            if ($block.marker -like 'CLM*' -and $null -ne $historyItem) {
                $items += [pscustomobject]@{
                    id = 'PKSR CLM2 climate / 365d temperature history'
                    raw = $historyItem.raw
                    cost = $historyItem.cost
                    source = 'pksr'
                }
                $label = 'PKSR CLM2 climate / rest'
                $cost = [Math]::Max(0, $cost - [int]$historyItem.cost)
                $blockRaw = [Math]::Max(0, $block.length - [int]$historyItem.raw)
            }
            else {
                $blockRaw = $block.length
            }
            $items += [pscustomobject]@{
                id = $label
                raw = $blockRaw
                cost = $cost
                source = 'pksr'
            }
        }
        $envelope = [Math]::Max(0, $simSection.length - $innerSum)
        $items += [pscustomobject]@{
            id = 'PKSR envelope (header, commands, producer cursors)'
            raw = $simSection.raw_length - ($inner | Measure-Object -Property length -Sum).Sum
            cost = $envelope
            source = 'pksr'
        }
    }

    $ranked = $items | Sort-Object -Property cost -Descending
    # The shallow item table would just repeat the section table above it; the
    # split only earns its keep once -Deep has broken the runtime bundle apart.
    if ($Deep) {
        Write-Host ('where the bytes go (cost = zstd -3 of the block alone; sum {0:N2} MiB of {1:N2} MiB file)' -f `
            ((($items | Measure-Object -Property cost -Sum).Sum + 12 + $headerLength) / 1MB), ($raw.Length / 1MB)) -ForegroundColor Cyan
        Write-Host ("  {0,-52} {1,9} {2,9} {3,7}" -f 'item', 'raw MiB', 'cost MiB', 'share')
        $shown = 0
        foreach ($item in $ranked) {
            if ($shown -ge $Top) {
                $rest = ($ranked | Select-Object -Skip $Top |
                    Measure-Object -Property cost -Sum).Sum
                $restRaw = ($ranked | Select-Object -Skip $Top |
                    Measure-Object -Property raw -Sum).Sum
                Write-Host ("  {0,-52} {1,9:N3} {2,9:N3} {3}" -f `
                    ("(+ {0} smaller)" -f ($ranked.Count - $Top)), ($restRaw / 1MB), ($rest / 1MB), (Format-Share $rest $raw.Length))
                break
            }
            Write-Host ("  {0,-52} {1,9:N3} {2,9:N3} {3}" -f `
                $item.id, ($item.raw / 1MB), ($item.cost / 1MB), (Format-Share $item.cost $raw.Length))
            $shown++
        }
        Write-Host ''
    }

    if ($duplicateNote) { Write-Host ("note: {0}" -f $duplicateNote) -ForegroundColor Yellow }
    if ($warnings.Count -gt 0) {
        Write-Host 'warnings' -ForegroundColor Yellow
        foreach ($warning in $warnings) { Write-Host ("  - {0}" -f $warning) }
    }

    # ---------------------------------------------------------------- json output
    $summary = [ordered]@{
        file                  = $SavePath
        bytes                 = $raw.Length
        format_version        = $formatVersion
        saved_at              = [string]$header.saved_at
        day                   = [int]$header.day
        seed                  = [int64]$header.seed
        width                 = [int]$header.width
        height                = [int]$header.height
        cells                 = $cells
        country               = [string]$header.country_name
        compressed_bytes      = $compressedTotal
        raw_bytes             = $rawTotal
        providers             = @($header.provider_manifest | ForEach-Object {
                [ordered]@{ id = [string]$_.provider_id; schema = [int]$_.schema_version }
            })
        sections              = @($sections | Sort-Object -Property length -Descending | ForEach-Object {
                [ordered]@{
                    id = $_.id; compressed = $_.length; raw = $_.raw_length; ratio = [Math]::Round($_.ratio, 4)
                }
            })
        items                 = @($ranked | ForEach-Object {
                [ordered]@{ id = $_.id; raw = $_.raw; cost = $_.cost; source = $_.source }
            })
        duplicate_ecp2        = [bool]$duplicateNote
        verify                = @($verifyResults)
        warnings              = @($warnings)
    }
    if ($Json) {
        if (-not $JsonPath) {
            $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $JsonPath = Join-Path (Join-Path $RepoRoot 'tmp') ("save_size_{0}.json" -f $stamp)
        }
        $parent = Split-Path -Parent $JsonPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $jsonText = $summary | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($JsonPath, $jsonText, [System.Text.UTF8Encoding]::new($false))
        $headline = [ordered]@{
            file   = (Split-Path -Leaf $SavePath)
            bytes  = $raw.Length
            mib    = [Math]::Round($raw.Length / 1MB, 2)
            top    = if ($ranked.Count -gt 0) { $ranked[0].id } else { '' }
            topMib = if ($ranked.Count -gt 0) { [Math]::Round($ranked[0].cost / 1MB, 2) } else { 0 }
            json   = $JsonPath
        }
        Write-Output ('[save-size/summary] ' + ($headline | ConvertTo-Json -Compress))
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
