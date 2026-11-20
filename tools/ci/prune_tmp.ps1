<#
.SYNOPSIS
Rotates the runtime artifacts under tmp/ so a soak or a crash spree cannot fill the disk.

.DESCRIPTION
Three families, three rules:

  tmp/runtime_snapshots_*      keep the newest -KeepIncidents AND anything newer
                               than -KeepDays; an entry is deleted when it is
                               past the count window OR past the age window.
                               Ordering uses the timestamp in the directory name
                               and falls back to the directory mtime.
  tmp/incidents/*.pkinc        keep the newest -KeepIncidents files.
  tmp/save_replay_*.log        keep -KeepDays worth, same for the
  tmp/verify_*.json            verify.ps1 reports.

-DryRun prints exactly what would be deleted with its size and removes nothing.
Nothing outside tmp/ is ever touched, and the script always exits 0: it is a
maintenance step, not a gate. Hook it after verify.ps1 or run it by hand.

.EXAMPLE
  .\tools\ci\prune_tmp.ps1 -DryRun

.EXAMPLE
  .\tools\ci\prune_tmp.ps1 -KeepIncidents 5 -KeepDays 7
#>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [ValidateRange(1, 100000)]
    [int]$KeepIncidents = 20,
    [ValidateRange(1, 3650)]
    [int]$KeepDays = 30,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$tmp = Join-Path $root 'tmp'
$cutoff = (Get-Date).AddDays(-$KeepDays)

if (-not (Test-Path -LiteralPath $tmp -PathType Container)) {
    Write-Host "prune: no tmp/ directory under $root, nothing to do"
    exit 0
}

function Get-PathSizeBytes {
    param([string]$Path, [bool]$IsDirectory)
    if (-not $IsDirectory) {
        return (Get-Item -LiteralPath $Path -Force).Length
    }
    $total = [long]0
    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue) {
        $total += $file.Length
    }
    return $total
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

# Collected as one list so the dry-run total is one number, not three.
$plan = New-Object System.Collections.Generic.List[object]

function Add-ToPlan {
    param([string]$Path, [bool]$IsDirectory, [string]$Reason)
    $size = Get-PathSizeBytes -Path $Path -IsDirectory $IsDirectory
    $plan.Add([pscustomobject]@{
        Path        = $Path
        IsDirectory = $IsDirectory
        Bytes       = $size
        Reason      = $Reason
    })
}

# --- 1. full runtime snapshots ------------------------------------------------
$snapshots = @(Get-ChildItem -LiteralPath $tmp -Directory -Filter 'runtime_snapshots_*' -Force -ErrorAction SilentlyContinue)
if ($snapshots.Count -gt 0) {
    $stamped = foreach ($dir in $snapshots) {
        $stamp = $null
        $match = [regex]::Matches($dir.Name, '(\d{8})[_-](\d{6})')
        if ($match.Count -gt 0) {
            $last = $match[$match.Count - 1]
            try {
                $stamp = [datetime]::ParseExact($last.Groups[1].Value + $last.Groups[2].Value,
                    'yyyyMMddHHmmss', $null)
            }
            catch { $stamp = $null }
        }
        if ($null -eq $stamp) { $stamp = $dir.LastWriteTime }
        [pscustomobject]@{ Dir = $dir; Stamp = $stamp }
    }
    # Newest first: rank 1 is the newest snapshot on disk.
    $ordered = @($stamped | Sort-Object -Property @{ Expression = 'Stamp'; Descending = $true })
    $rank = 0
    $keptByCount = 0
    foreach ($entry in $ordered) {
        $rank++
        $age = (Get-Date) - $entry.Dir.LastWriteTime
        $withinCount = $rank -le $KeepIncidents
        $withinAge = $entry.Dir.LastWriteTime -ge $cutoff
        if ($withinCount -and $withinAge) {
            $keptByCount++
            continue
        }
        $why = if (-not $withinCount -and -not $withinAge) { "rank $rank > $KeepIncidents, $([int]$age.TotalDays)d > ${KeepDays}d" }
            elseif (-not $withinCount) { "rank $rank > $KeepIncidents" }
            else { "$([int]$age.TotalDays)d > ${KeepDays}d" }
        Add-ToPlan -Path $entry.Dir.FullName -IsDirectory $true -Reason $why
    }
    Write-Host ("snapshots: {0} dir(s), keep newest {1} within {2}d -> {3}, delete {4}" -f
        $snapshots.Count, $KeepIncidents, $KeepDays, $keptByCount, $plan.Count)
}
else {
    Write-Host 'snapshots: none'
}

# --- 2. incident bundles ------------------------------------------------------
$incidentDir = Join-Path $tmp 'incidents'
$incidentCount = $plan.Count
if (Test-Path -LiteralPath $incidentDir -PathType Container) {
    $incidents = @(Get-ChildItem -LiteralPath $incidentDir -File -Filter '*.pkinc' -Force -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)
    $rank = 0
    foreach ($incident in $incidents) {
        $rank++
        if ($rank -le $KeepIncidents) { continue }
        Add-ToPlan -Path $incident.FullName -IsDirectory $false -Reason "rank $rank > $KeepIncidents"
    }
    Write-Host ("incidents: {0} file(s), keep newest {1} -> delete {2}" -f
        $incidents.Count, $KeepIncidents, ($plan.Count - $incidentCount))
}
else {
    Write-Host 'incidents: no tmp/incidents/'
}

# --- 3. logs and verify reports ----------------------------------------------
$logCount = $plan.Count
foreach ($pattern in @('save_replay_*.log', 'verify_*.json')) {
    foreach ($file in @(Get-ChildItem -LiteralPath $tmp -File -Filter $pattern -Force -ErrorAction SilentlyContinue)) {
        if ($file.LastWriteTime -ge $cutoff) { continue }
        Add-ToPlan -Path $file.FullName -IsDirectory $false -Reason "$([int]((Get-Date) - $file.LastWriteTime).TotalDays)d > ${KeepDays}d"
    }
}
Write-Host ("logs: save_replay_*.log + verify_*.json older than {0}d -> delete {1}" -f
    $KeepDays, ($plan.Count - $logCount))

# --- report / act -------------------------------------------------------------
if ($plan.Count -eq 0) {
    Write-Host 'prune: nothing to delete'
    exit 0
}

$totalBytes = ($plan | Measure-Object -Property Bytes -Sum).Sum
Write-Host ''
foreach ($entry in $plan) {
    $kind = if ($entry.IsDirectory) { 'dir ' } else { 'file' }
    Write-Host ("  {0}  {1,10}  {2}  [{3}]" -f $kind, (Format-Size -Bytes $entry.Bytes), $entry.Path, $entry.Reason)
}
Write-Host ''
Write-Host ("total: {0} item(s), {1}" -f $plan.Count, (Format-Size -Bytes $totalBytes))

if ($DryRun) {
    Write-Host 'dry-run: nothing deleted (drop -DryRun to prune)'
    exit 0
}

$deleted = 0
$failed = 0
foreach ($entry in $plan) {
    try {
        if ($entry.IsDirectory) {
            Remove-Item -LiteralPath $entry.Path -Recurse -Force
        }
        else {
            Remove-Item -LiteralPath $entry.Path -Force
        }
        $deleted++
    }
    catch {
        $failed++
        Write-Warning "could not delete $($entry.Path): $($_.Exception.Message)"
    }
}
$failureNote = if ($failed -gt 0) { ", $failed failed" } else { '' }
Write-Host "pruned $deleted item(s) ($(Format-Size -Bytes $totalBytes))$failureNote"
exit 0
