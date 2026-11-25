<#
.SYNOPSIS
Replays a player save headlessly for N simulation days and reports the outcome.

.DESCRIPTION
This is the reproduction entry point for player-reported stops and hangs. Give
it a save (a slot id, or any .pksv file) and a day count; it loads through the
production GameFlow restore path, advances the authoritative clock, and fails
on either an economy fatal or a stalled day. Both failure modes write a
forensics JSON under tmp/ so the scene can be inspected without re-running.

A -SavePath file is copied into a scratch directory and reached through the
PK_SAVE_DIR override, so replaying a save never overwrites the player's slots.

Headless speed-up (runtime-fault plan §8.2-A / R5):
  -Release       flips addons/dots_ext/dots_ext.gdextension to the release DLL
                 for this run only and restores the debug mapping in finally.
  -UntilDay N    replays until authoritative day N instead of a fixed -Days.
                 The PKSV header stores the save's day, so the wrapper converts
                 it to PK_SAVE_REPLAY_DAYS and prints the conversion.
  -StopOnFault   exits with code 2 on the first economy fatal (0/1 unchanged).
  -Bundle        picks up the .pkinc incident bundle the fatal path wrote, or
                 prints one line "bundle: unavailable (<reason>)".
  -Json          also prints one [save-replay/summary] line and writes
                 tmp/save_replay_<stamp>.json.

.EXAMPLE
  .\tools\runtime\Invoke-SaveReplay.ps1 -Slot autosave -Days 60

.EXAMPLE
  .\tools\runtime\Invoke-SaveReplay.ps1 -SavePath %TEMP%\day2740.pksv -Days 20 -Speed 10

.EXAMPLE
  .\tools\runtime\Invoke-SaveReplay.ps1 -SavePath %TEMP%\day2740.pksv -UntilDay 2745 -Release -Json
#>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [ValidateSet('manual_1', 'manual_2', 'manual_3', 'autosave')]
    [string]$Slot = 'autosave',
    [string]$SavePath = '',
    [ValidateRange(1, 100000)]
    [int]$Days = 30,
    [ValidateRange(0.1, 1000)]
    [double]$Speed = 20,
    [ValidateRange(1000, 3600000)]
    [int]$DayTimeoutMsec = 60000,
    [string]$GodotExe = '',
    [ValidateRange(60, 86400)]
    [int]$TimeoutSeconds = 3600,

    # Replay until this authoritative day instead of -Days simulation days.
    # -UntilDay wins when both are given.
    [ValidateRange(0, 1000000)]
    [int]$UntilDay = 0,

    # First economy fatal exits with code 2 instead of 1.
    [switch]$StopOnFault,

    # On fatal, report the .pkinc incident bundle produced by the run.
    [switch]$Bundle,

    # Run against the release GDExtension DLL; the debug mapping is restored in
    # finally even when the replay throws.
    [switch]$Release,

    # Machine-readable summary (stdout line + tmp/save_replay_<stamp>.json).
    [switch]$Json,

    # Explicit summary path; defaults to tmp/save_replay_<stamp>.json.
    [string]$JsonPath = ''
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $root 'tools\runtime\Resolve-GodotBin.ps1')
$godot = Resolve-GodotBin -GodotExe $GodotExe
$project = Join-Path $root 'Project\project-keynes'
$useGdextLibrary = Join-Path $root 'tools\runtime\Use-GdextLibrary.ps1'
$startedAt = Get-Date


## PKSV v2 container: "PKSV" + LE u32 format_version + LE u32 header_length +
## UTF-8 JSON header (scripts/game/save_container_reader.gd). The header carries
## `day`, which is what -UntilDay needs before Godot is even started.
function Read-PksvHeaderDay {
    param([string]$Path)

    if ($Path -eq '' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{ ok = $false; reason = 'no save file to inspect' }
    }
    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($stream.Length -lt 12) {
            return @{ ok = $false; reason = 'save is truncated' }
        }
        $reader = New-Object System.IO.BinaryReader($stream,
            [System.Text.Encoding]::UTF8, $true)
        $magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne 'PKSV') {
            return @{ ok = $false; reason = "unexpected save magic '$magic'" }
        }
        $version = $reader.ReadUInt32()
        if ($version -ne 2) {
            return @{ ok = $false; reason = "unsupported PKSV format version $version" }
        }
        $headerLength = $reader.ReadUInt32()
        if ($headerLength -le 0 -or $headerLength -gt 1048576 `
                -or $headerLength -gt ($stream.Length - 12)) {
            return @{ ok = $false; reason = "invalid PKSV header length $headerLength" }
        }
        $headerJson = [System.Text.Encoding]::UTF8.GetString(
            $reader.ReadBytes([int]$headerLength))
        $header = $headerJson | ConvertFrom-Json
        if ($header.PSObject.Properties.Name -notcontains 'day') {
            return @{ ok = $false; reason = 'PKSV header has no day field' }
        }
        return @{
            ok = $true
            day = [int]$header.day
            country_name = [string]$header.country_name
            width = [int]$header.width
            height = [int]$header.height
            saved_at = [string]$header.saved_at
            reason = ''
        }
    }
    catch {
        return @{ ok = $false; reason = $_.Exception.Message }
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}


## user://saves lives under %APPDATA%\Godot\app_userdata\<project name>.
function Get-SlotSavePath {
    param([string]$ProjectPath, [string]$SlotId)

    $projectName = 'ProjectKeynes'
    $projectFile = Join-Path $ProjectPath 'project.godot'
    if (Test-Path -LiteralPath $projectFile -PathType Leaf) {
        foreach ($line in Get-Content -LiteralPath $projectFile -ErrorAction SilentlyContinue) {
            if ($line -match '^\s*config/name\s*=\s*"([^"]*)"') {
                $projectName = $Matches[1]
                break
            }
        }
    }
    $userDir = Join-Path (Join-Path (Join-Path $env:APPDATA 'Godot\app_userdata') `
        $projectName) 'saves'
    return (Join-Path $userDir "$SlotId.pksv")
}


## Runs Godot with both streams captured and an optional hard timeout.
## Start-Process -PassThru leaves ExitCode empty under Windows PowerShell 5.1
## (observed on 5.1.22621), so the .NET Process API is used directly. Godot
## writes UTF-8 even on Windows, so both streams are decoded as UTF-8.
function Invoke-CapturedGodot {
    param(
        [string]$GodotExe,
        [string[]]$Arguments,
        [string]$StdoutPath,
        [string]$StderrPath,
        [int]$TimeoutSeconds
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $GodotExe
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') { '"' + ($argument -replace '"', '\"') + '"' }
        else { $argument }
    }
    $startInfo.Arguments = ($quoted -join ' ')

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = $false
    if ($TimeoutSeconds -gt 0) {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill() } catch { }
            $process.WaitForExit(10000) | Out-Null
        }
    }
    else {
        $process.WaitForExit()
    }
    $exitCode = $process.ExitCode
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($StdoutPath, $stdoutTask.Result, $utf8)
    [System.IO.File]::WriteAllText($StderrPath, $stderrTask.Result, $utf8)
    $process.Dispose()
    return @{ exit_code = $exitCode; timed_out = $timedOut }
}


$logDir = Join-Path $root 'tmp'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$stamp = $startedAt.ToString('yyyyMMdd_HHmmss')
$logPath = Join-Path $logDir ('save_replay_' + $stamp + '.log')
if ([string]::IsNullOrWhiteSpace($JsonPath)) {
    $JsonPath = Join-Path $logDir ("save_replay_$stamp.json")
}

# The summary exists before any early exit, so a missing save or a rejected
# -UntilDay also produces the machine-readable record -Json promises.
$summary = [ordered]@{
    day = $null
    start_day = $null
    end_day = $null
    fatal = $false
    fatal_reason = ''
    elapsed_seconds = 0.0
    days_per_sec = 0.0
    consecutive_ok_days = 0
    bundle = ''
    ok = $false
    exit_code = 1
    timed_out = $false
    slot = $Slot
    save = $SavePath
    requested_days = $Days
    until_day = 0
    stop_on_fault = [bool]$StopOnFault
    release = [bool]$Release
    log = $logPath
}
$summaryErrors = New-Object System.Collections.Generic.List[string]

function Write-SaveReplaySummary {
    param([int]$ExitCode)

    $summary['exit_code'] = $ExitCode
    $summary['errors'] = $summaryErrors.ToArray()
    $summaryJson = $summary | ConvertTo-Json -Depth 6 -Compress
    [System.IO.File]::WriteAllText($JsonPath, $summaryJson,
        (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("summary  : {0}" -f $JsonPath)
    Write-Host "[save-replay/summary] $summaryJson"
}


$scratchDir = ''
$releaseSwitched = $false
$restoreFailed = $false
$requestedUntilDay = 0

# The save this run will reach, used only to resolve -UntilDay before launch.
$inspectSave = ''
if ($SavePath -ne '') {
    if (-not (Test-Path -LiteralPath $SavePath -PathType Leaf)) {
        Write-Host "Save file not found: $SavePath" -ForegroundColor Red
        $summaryErrors.Add('save_not_found')
        if ($Json) { Write-SaveReplaySummary -ExitCode 1 }
        exit 1
    }
    $inspectSave = (Resolve-Path -LiteralPath $SavePath).Path
    $summary['save'] = $inspectSave
}
else {
    $candidate = Get-SlotSavePath -ProjectPath $project -SlotId $Slot
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $inspectSave = $candidate
    }
    $summary['save'] = $inspectSave
}

# headless_save_replay.gd only reads PK_SAVE_REPLAY_DAYS, so -UntilDay is
# converted here (target day - save day). PK_SAVE_REPLAY_UNTIL_DAY is exported
# as well so a future harness that understands it can take over.
if ($UntilDay -gt 0) {
    $header = Read-PksvHeaderDay -Path $inspectSave
    if (-not $header.ok) {
        Write-Host "until_day: unresolved ($($header.reason)); keeping -Days $Days"
    }
    else {
        $daysToTarget = $UntilDay - [int]$header.day
        if ($daysToTarget -lt 1) {
            Write-Host "until_day: target $UntilDay is not after the save's day $($header.day)" -ForegroundColor Red
            $summaryErrors.Add("until_day_not_after_save_day:$($header.day)")
            if ($Json) { Write-SaveReplaySummary -ExitCode 1 }
            exit 1
        }
        if ($daysToTarget -gt 100000) {
            Write-Host "until_day: target $UntilDay needs $daysToTarget days (limit 100000)" -ForegroundColor Red
            $summaryErrors.Add("until_day_range:$daysToTarget")
            if ($Json) { Write-SaveReplaySummary -ExitCode 1 }
            exit 1
        }
        $Days = $daysToTarget
        $requestedUntilDay = $UntilDay
        $summary['requested_days'] = $Days
        $summary['until_day'] = $requestedUntilDay
        Write-Host ("until_day: target={0} save_day={1} days={2} (headless_save_replay.gd has no UNTIL_DAY support; converted to PK_SAVE_REPLAY_DAYS)" -f `
            $UntilDay, $header.day, $Days)
    }
}

if ($SavePath -ne '') {
    # The repository only knows four slot ids, so an arbitrary file is staged as
    # one of them inside a throwaway directory rather than into user://saves.
    $scratchDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pk-save-replay-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
    Copy-Item -LiteralPath $SavePath -Destination (Join-Path $scratchDir "$Slot.pksv") -Force
    $env:PK_SAVE_DIR = $scratchDir
    Write-Host "staged $SavePath as slot '$Slot' in $scratchDir"
}

$env:PK_SAVE_REPLAY = '1'
$env:PK_SAVE_REPLAY_SLOT = $Slot
$env:PK_SAVE_REPLAY_DAYS = "$Days"
$env:PK_SAVE_REPLAY_SPEED = "$Speed"
$env:PK_SAVE_REPLAY_DAY_TIMEOUT_MSEC = "$DayTimeoutMsec"
if ($requestedUntilDay -gt 0) {
    $env:PK_SAVE_REPLAY_UNTIL_DAY = "$requestedUntilDay"
}

Write-Host "replaying slot=$Slot days=$Days speed=$Speed ..."

$exitCode = 1
$timedOut = $false
$previousErrorAction = $ErrorActionPreference
try {
    if ($Release) {
        & $useGdextLibrary -Variant release -RepoRoot $root -Quiet
        $releaseSwitched = $true
        Write-Host 'release: windows.debug.x86_64 -> template_release DLL (restored in finally)'
    }
    $ErrorActionPreference = 'Continue'
    # The captured runner also enforces -TimeoutSeconds: a hung replay must not
    # hang CI.
    $stdoutPath = "$logPath.stdout"
    $stderrPath = "$logPath.stderr"
    $run = Invoke-CapturedGodot -GodotExe $godot `
        -Arguments @('--headless', '--path', $project) `
        -StdoutPath $stdoutPath -StderrPath $stderrPath `
        -TimeoutSeconds $TimeoutSeconds
    $exitCode = $run.exit_code
    $timedOut = $run.timed_out
}
finally {
    $ErrorActionPreference = $previousErrorAction
    if ($releaseSwitched) {
        try {
            & $useGdextLibrary -Restore -RepoRoot $root -Quiet
            # Query (not quiet) so the log carries proof the mapping is back.
            & $useGdextLibrary -Query -RepoRoot $root
        }
        catch {
            $restoreFailed = $true
            Write-Host "release: restore FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Remove-Item Env:\PK_SAVE_REPLAY, Env:\PK_SAVE_REPLAY_SLOT, Env:\PK_SAVE_REPLAY_DAYS,
        Env:\PK_SAVE_REPLAY_SPEED, Env:\PK_SAVE_REPLAY_DAY_TIMEOUT_MSEC,
        Env:\PK_SAVE_REPLAY_UNTIL_DAY -ErrorAction SilentlyContinue
    if ($scratchDir -ne '') {
        Remove-Item Env:\PK_SAVE_DIR -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Merge the captured streams into the single log path existing tooling reads,
# then echo them (the captured runner streams to files, not to this console).
$logText = ''
foreach ($streamPath in @("$logPath.stdout", "$logPath.stderr")) {
    if (Test-Path -LiteralPath $streamPath) {
        $logText += [System.IO.File]::ReadAllText($streamPath, [System.Text.Encoding]::UTF8)
    }
}
[System.IO.File]::WriteAllText($logPath, $logText, (New-Object System.Text.UTF8Encoding($false)))
Remove-Item -LiteralPath "$logPath.stdout", "$logPath.stderr" -Force -ErrorAction SilentlyContinue
if ($logText -ne '') { Write-Host $logText.TrimEnd() }
if ($timedOut) {
    Write-Host "timeout: no result after $TimeoutSeconds s (Godot killed)" -ForegroundColor Red
    $summaryErrors.Add('timeout')
}

$summary['elapsed_seconds'] = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 3)
$passed = $false
$fatal = $false
$fatalReason = ''

# The harness prints exactly one machine-readable line; trust it over the exit
# code, because Godot harnesses have historically exited 0 after printing a
# failure. Missing the line at all is itself a failure (the runner never ran).
$match = [regex]::Match($logText, '\[save-replay/result\]\s*(\{.*\})')
if (-not $match.Success) {
    Write-Host "no [save-replay/result] line in $logPath" -ForegroundColor Red
    $summaryErrors.Add('no_result_line')
}
else {
    $result = $match.Groups[1].Value | ConvertFrom-Json
    $failures = @($result.failures)

    foreach ($failure in $failures) {
        $text = [string]$failure
        if ($text.StartsWith('economy_fatal:')) {
            $fatal = $true
            $fatalReason = $text.Substring('economy_fatal:'.Length)
        }
    }
    if (($result.PSObject.Properties.Name -contains 'fatal_day') -and -not $fatal) {
        $fatal = $true
        if ($fatalReason -eq '') { $fatalReason = 'fatal_day_reported' }
    }

    $startDay = if ($result.PSObject.Properties.Name -contains 'start_day') { [int]$result.start_day } else { $null }
    $endDay = if ($result.PSObject.Properties.Name -contains 'end_day') { [int]$result.end_day } else { $null }
    $consecutiveOkDays = 0
    if ($null -ne $startDay -and $null -ne $endDay) {
        $consecutiveOkDays = [int]$endDay - [int]$startDay
    }
    $daysPerSecond = 0.0
    if ($result.PSObject.Properties.Name -contains 'days_per_sec') {
        $daysPerSecond = [double]$result.days_per_sec
    }
    elseif ($summary['elapsed_seconds'] -gt 0) {
        $daysPerSecond = [math]::Round($consecutiveOkDays / $summary['elapsed_seconds'], 3)
    }
    $summary['day'] = $endDay
    $summary['start_day'] = $startDay
    $summary['end_day'] = $endDay
    $summary['fatal'] = $fatal
    $summary['fatal_reason'] = $fatalReason
    $summary['days_per_sec'] = $daysPerSecond
    $summary['consecutive_ok_days'] = $consecutiveOkDays
    $summary['ok'] = [bool]$result.ok
    $summary['failures'] = @($failures)

    Write-Host ''
    Write-Host "log      : $logPath"
    Write-Host "slot     : $($result.slot)"
    Write-Host "days     : $($result.start_day) -> $($result.end_day) (requested $($result.requested_days))"
    if ($result.PSObject.Properties.Name -contains 'days_per_sec') {
        Write-Host ("throughput: {0:N2} authoritative days/s" -f $result.days_per_sec)
    }
    if ($result.PSObject.Properties.Name -contains 'forensics' -and $result.forensics) {
        Write-Host "forensics: $($result.forensics)"
    }

    if ($Bundle) {
        if (-not $fatal) {
            Write-Host 'bundle: skipped (no fatal)'
        }
        else {
            # R2-3 is supposed to leave the bundle next to the forensics dump.
            # Until that lands, report the capability gap instead of failing.
            $incidentDir = Join-Path $logDir 'incidents'
            $candidateBundles = @()
            if (Test-Path -LiteralPath $incidentDir -PathType Container) {
                $candidateBundles = @(Get-ChildItem -LiteralPath $incidentDir -Filter '*.pkinc' `
                    -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -ge $startedAt } |
                    Sort-Object LastWriteTime -Descending)
            }
            if ($candidateBundles.Count -gt 0) {
                $summary['bundle'] = $candidateBundles[0].FullName
                Write-Host "bundle: $($candidateBundles[0].FullName)"
            }
            else {
                $summary['bundle'] = 'unavailable'
                Write-Host 'bundle: unavailable (no .pkinc was written by this run; R2 incident bundler not implemented yet)'
            }
        }
    }

    $passed = [bool]($result.ok -and $exitCode -eq 0)
    if ($passed) {
        Write-Host 'PASS' -ForegroundColor Green
    }
    else {
        Write-Host "FAIL: $($failures -join ' | ')" -ForegroundColor Red
    }
}

if ($restoreFailed) {
    Write-Host 'FAIL: GDExtension mapping was not restored to debug' -ForegroundColor Red
    $summaryErrors.Add('gdext_restore_failed')
    $passed = $false
}

# 0 = PASS, 1 = FAIL, 2 = first fatal under -StopOnFault. -Release restore
# failures and timeouts always win over the PASS/FAIL verdict.
$finalExitCode = 1
if ($timedOut) {
    $finalExitCode = 1
}
elseif ($passed) {
    $finalExitCode = 0
}
elseif ($StopOnFault -and $fatal) {
    $finalExitCode = 2
}
if ($Json) { Write-SaveReplaySummary -ExitCode $finalExitCode }
if ($finalExitCode -eq 2) {
    Write-Host "fault: fatal detected, -StopOnFault exits 2 ($fatalReason)" -ForegroundColor Yellow
}
exit $finalExitCode
