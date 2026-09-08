<#
.SYNOPSIS
Records which source revision produced the currently installed GDExtension DLLs.

.DESCRIPTION
Emits build-manifest.json containing, for each installed DLL, its SHA-256,
size and mtime, plus the git HEAD, the working-tree cleanliness of gdext/src,
the runtime ABI constants and the newest source mtime.

The newest-source comparison is the point of this script: if any file under
gdext/src is newer than a DLL, measurements taken against that DLL describe
code that is no longer in the tree. That condition is reported as stale.
#>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$binDir = Join-Path $root 'Project\project-keynes\addons\dots_ext\bin\windows'
$srcDir = Join-Path $root 'gdext\src'
$protocolHeader = Join-Path $srcDir 'runtime_pod_protocol.h'

if ($OutDir -eq '') { $OutDir = Join-Path $root 'artifacts\runtime\s0-baseline' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

function Get-AbiConstant {
    param([string]$Name)
    $line = Select-String -Path $protocolHeader -Pattern "constexpr uint32_t $Name\s*=" |
        Select-Object -First 1
    if (-not $line) { return $null }
    if ($line.Line -match '=\s*(\d+)u?') { return [int]$Matches[1] }
    return $null
}

# Only the two shipping DLLs matter for traceability. Probe builds produced via
# DOTS_EXT_OUTPUT_BASENAME are deliberately excluded.
$shipping = @(
    'dots_ext.windows.template_debug.x86_64.dll',
    'dots_ext.windows.template_release.x86_64.dll'
)

$newestSource = Get-ChildItem -Path $srcDir -Recurse -Include *.cpp, *.h |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

$dllRecords = @()
$staleDlls = @()
foreach ($name in $shipping) {
    $path = Join-Path $binDir $name
    if (-not (Test-Path -LiteralPath $path)) {
        $dllRecords += [ordered]@{ name = $name; present = $false }
        continue
    }
    $item = Get-Item -LiteralPath $path
    $isStale = $newestSource -and ($newestSource.LastWriteTime -gt $item.LastWriteTime)
    if ($isStale) { $staleDlls += $name }
    $dllRecords += [ordered]@{
        name           = $name
        present        = $true
        sha256         = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        size_bytes     = $item.Length
        last_write_utc = $item.LastWriteTimeUtc.ToString('o')
        stale          = [bool]$isStale
    }
}

Push-Location $root
try {
    $head = (git rev-parse HEAD).Trim()
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    $dirtySrc = @(git status --porcelain -- gdext/src)
}
finally { Pop-Location }

$manifest = [ordered]@{
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    repo_root     = $root
    git           = [ordered]@{
        head              = $head
        branch            = $branch
        gdext_src_dirty   = $dirtySrc.Count
    }
    abi           = [ordered]@{
        runtime_domain_abi_version     = Get-AbiConstant 'RUNTIME_DOMAIN_ABI_VERSION'
        runtime_domain_pod_abi_version = Get-AbiConstant 'RUNTIME_DOMAIN_POD_ABI_VERSION'
    }
    newest_source = if ($newestSource) {
        [ordered]@{
            path           = $newestSource.FullName.Replace("$root\", '')
            last_write_utc = $newestSource.LastWriteTimeUtc.ToString('o')
        }
    } else { $null }
    dlls          = $dllRecords
    stale         = [ordered]@{
        any  = ($staleDlls.Count -gt 0)
        dlls = $staleDlls
    }
}

$outFile = Join-Path $OutDir 'build-manifest.json'
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outFile -Encoding UTF8

Write-Host "build manifest -> $outFile"
Write-Host "  git HEAD          : $head ($branch), gdext/src dirty: $($dirtySrc.Count)"
Write-Host "  domain ABI        : v$($manifest.abi.runtime_domain_abi_version)"
Write-Host "  domain POD ABI    : v$($manifest.abi.runtime_domain_pod_abi_version)"
foreach ($record in $dllRecords) {
    if (-not $record.present) {
        Write-Host "  MISSING           : $($record.name)"
        continue
    }
    $flag = if ($record.stale) { 'STALE' } else { 'fresh' }
    Write-Host "  $flag             : $($record.name) $($record.sha256.Substring(0,16))... $($record.size_bytes) bytes"
}
if ($staleDlls.Count -gt 0) {
    Write-Warning "DLLs older than newest source in gdext/src. Rebuild before measuring."
    exit 2
}
