<#
.SYNOPSIS
One-command runtime verification for a Windows checkout: static gates, native
build, headless suites and (optionally) the long soak.

.DESCRIPTION
Single entry point for the runtime fault infrastructure (docs/plans/
runtime-fault-infrastructure-plan.md section 9). Four stages:

  static   the lexical/contract gates plus the .gdextension debug-mapping guard
           and the staged-blob budget. Target under 2 minutes.
  build    incremental scons template_debug build, then a build-id self check
           on the produced DLL. Target under 6 minutes.
  suites   tools/runtime/Invoke-RuntimeTests.ps1 headless suites. Target under
           15 minutes. Each test is capped by -TestTimeoutSeconds (default 600);
           a test that does not quit is killed, listed as TIMEOUT and fails the
           run instead of hanging it.
  soak     tools/runtime/Invoke-Soak.ps1 (only with -WithSoak). Target under
           10 minutes.

A check that passes is green. A check that fails is red. A check that cannot
run because its script does not exist yet is SKIPPED and listed separately:
skipped is NOT green, so a run with skips never exits 0. Known-red entries are
checks whose failure is already recorded baseline drift in this checkout; they
are printed in red, written to the JSON report under known_red, and do not
affect the exit code unless -Strict is given.

Output: tmp/verify_<timestamp>.json (every check: command, exit code, seconds,
first 40 lines of failure output) and a human summary on stdout.

Exit codes:
  0  every requested check passed (and nothing was skipped)
  1  a check failed, or a check was skipped (not green), or -Strict caught a
     known-red entry
  2  environment problem: python / git / scons / godot missing, wrong directory

The JSON report is written for every non-dry run, including a red one.

.EXAMPLE
  .\tools\ci\verify.ps1 -Quick

.EXAMPLE
  .\tools\ci\verify.ps1 -SkipBuild -Strict

.EXAMPLE
  .\tools\ci\verify.ps1 -WithSoak -GodotExe <GODOT_BIN>

.EXAMPLE
  .\tools\ci\verify.ps1 -DryRun -WithSoak
#>
param(
    # Only the static stage; the fast loop while editing.
    [switch]$Quick,
    # Also run the long soak stage (soak is a no-op skip when its script is absent).
    [switch]$WithSoak,
    # Skip the scons build stage (C++ already built by another job, or GDScript-only change).
    [switch]$SkipBuild,
    # Print the resolved plan and exit 0 without running anything.
    [switch]$DryRun,
    # Treat known-red entries (and therefore pre-existing baseline drift) as failures.
    [switch]$Strict,
    # Missing PK_BUILD_ID in the built DLL is a WARN; with this it is a failure.
    [switch]$StrictBuildId,
    [string]$GodotExe = '',
    [string]$RepoRoot = (Get-Location).Path,
    [ValidateRange(1, 64)]
    [int]$Jobs = 4,

    # Hard per-test cap handed to tools/runtime/Invoke-RuntimeTests.ps1. One
    # headless fixture that never quits used to hang the whole command (R7-1);
    # a test that exceeds this is killed, reported as TIMEOUT and fails the run.
    [ValidateRange(1, 3600)]
    [int]$TestTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
$tmp = Join-Path $root 'tmp'
if (-not (Test-Path -LiteralPath $tmp -PathType Container)) {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
}
$stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$jsonPath = Join-Path $tmp "verify_$stamp.json"
$artifactDir = Join-Path $tmp "verify_$stamp"

# Known-red: failures already recorded in this checkout, unrelated to the fault
# infrastructure work. Printed loudly, never hidden, never skipped. Keys are the
# script file name so the reason survives a rename of the check entry.
$knownRed = [ordered]@{}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Invoke-NativeCommand {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [string]$WorkingDirectory = $root
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $code = 1
    $captured = @()
    try {
        Push-Location -LiteralPath $WorkingDirectory
        try {
            $captured = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
            if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
        }
        finally { Pop-Location }
    }
    catch {
        $captured += "verify.ps1: could not run '$Exe $($Arguments -join ' ')': $($_.Exception.Message)"
        $code = 1
    }
    finally { $ErrorActionPreference = $previous }
    [pscustomobject]@{ ExitCode = $code; Lines = $captured }
}

function New-CheckResult {
    param(
        [string]$Name,
        [string]$Command,
        [object]$Outcome,
        [double]$Elapsed,
        [bool]$WarnOnly = $false
    )
    $exitCode = $Outcome.ExitCode
    $lines = @($Outcome.Lines)
    $reason = $knownRed[$Name]
    $note = ''

    if ($exitCode -eq 0 -and $WarnOnly) {
        $status = 'warn'
    }
    elseif ($exitCode -eq 0) {
        $status = 'pass'
        if ($reason) {
            $note = 'known-red entry now passes; remove it from $knownRed in tools/ci/verify.ps1'
        }
    }
    elseif ($reason -and -not $Strict) {
        $status = 'known-red'
    }
    else {
        $status = 'fail'
        if ($reason) { $note = 'known-red entry counted as a failure because -Strict was given' }
    }

    # Built outside the hashtable literal: an `if` used as a value inside an
    # ordered dictionary emits an empty object instead of an empty array.
    $failureOutput = @()
    if ($status -eq 'fail' -or $status -eq 'known-red') {
        $failureOutput = @($lines | Select-Object -Last 40)
    }

    [ordered]@{
        name             = $Name
        command          = $Command
        status           = $status
        exit_code        = $exitCode
        elapsed_seconds  = $Elapsed
        known_red        = [bool]$reason
        known_red_reason = $reason
        note             = $note
        failure_output   = $failureOutput
    }
}

function Format-CheckLine {
    param([object]$Item)
    $label = switch ($Item.status) {
        'pass' { 'PASS     ' }
        'warn' { 'WARN     ' }
        'known-red' { 'KNOWN-RED' }
        'fail' { 'FAIL     ' }
        'skipped' { 'SKIP     ' }
        default { 'UNKNOWN  ' }
    }
    $color = switch ($Item.status) {
        'fail' { 'Red' }
        'known-red' { 'Red' }
        'warn' { 'Yellow' }
        'skipped' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ("  {0} {1,-26} {2,7:N2}s" -f $label, $Item.name, $Item.elapsed_seconds) -ForegroundColor $color
    if ($Item.note) { Write-Host ("           note: {0}" -f $Item.note) -ForegroundColor $color }
}

function Test-GdextensionMapping {
    # R6-4: a release mapping left in the debug slot loads the wrong library and
    # every runtime symptom after that is a lie. Fails, never warns.
    $mapping = Join-Path $root 'Project\project-keynes\addons\dots_ext\dots_ext.gdextension'
    if (-not (Test-Path -LiteralPath $mapping -PathType Leaf)) {
        return [pscustomobject]@{ ExitCode = 1; Lines = @("missing mapping file: $mapping") }
    }
    $line = Get-Content -LiteralPath $mapping -Encoding UTF8 |
        Where-Object { $_ -match '^\s*windows\.debug\.x86_64\s*=' } |
        Select-Object -First 1
    if (-not $line) {
        return [pscustomobject]@{
            ExitCode = 1
            Lines    = @("$mapping has no 'windows.debug.x86_64' entry; the Windows debug library is unmapped")
        }
    }
    $value = ($line -split '=', 2)[1].Trim().Trim('"')
    $report = @("windows.debug.x86_64 = $value")
    if ($value -match '\.template_debug\.') {
        $library = Join-Path $root ('Project\project-keynes\' + ($value -replace '^res://', ''))
        if (Test-Path -LiteralPath $library -PathType Leaf) {
            $sizeMb = [math]::Round((Get-Item -LiteralPath $library).Length / 1MB, 1)
            $report += "library present: $library ($sizeMb MB)"
        }
        else {
            $report += "WARN library not built yet: $library (run the build stage)"
        }
        return [pscustomobject]@{ ExitCode = 0; Lines = $report }
    }
    $report += 'FAIL the debug slot does not point at a .template_debug. library'
    if ($value -match '\.template_release\.') {
        $report += 'the release mapping is still in place (a release/debug switch was left behind)'
    }
    $report += 'fix: .\tools\runtime\Use-GdextLibrary.ps1 -Variant debug -Restore'
    [pscustomobject]@{ ExitCode = 1; Lines = $report }
}

function Test-DllBuildId {
    # R6 build self-check: the DLL that Godot loads must carry the build id the
    # reports quote. A missing symbol is a WARN by default (older local builds),
    # a failure under -StrictBuildId.
    $binDir = Join-Path $root 'Project\project-keynes\addons\dots_ext\bin\windows'
    if (-not (Test-Path -LiteralPath $binDir -PathType Container)) {
        return [pscustomobject]@{ ExitCode = 0; Lines = @("no windows binary directory: $binDir") }
    }
    $dlls = @(Get-ChildItem -LiteralPath $binDir -File -Filter '*.template_debug.*.dll' -ErrorAction SilentlyContinue)
    if ($dlls.Count -eq 0) {
        return [pscustomobject]@{ ExitCode = 0; Lines = @("no *.template_debug.*.dll under $binDir") }
    }
    $report = @()
    $missing = @()
    foreach ($dll in $dlls) {
        $bytes = [System.IO.File]::ReadAllBytes($dll.FullName)
        $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
        $hasSymbol = $text.Contains('pk_build_id') -or $text.Contains('PK_BUILD_ID')
        if (-not $hasSymbol) {
            $report += "$($dll.Name): no PK_BUILD_ID / pk_build_id symbol ($([math]::Round($dll.Length / 1MB, 1)) MB)"
            $missing += $dll.Name
            continue
        }
        $value = ''
        $match = [regex]::Match($text, 'PK_BUILD_ID[=\s:"]*([A-Za-z0-9_.:+-]{4,64})')
        if ($match.Success) { $value = $match.Groups[1].Value }
        else {
            $match = [regex]::Match($text, 'pk_build_id[=\s:"]*([A-Za-z0-9_.:+-]{4,64})')
            if ($match.Success) { $value = $match.Groups[1].Value }
        }
        if ($value) { $report += "$($dll.Name): build id '$value'" }
        else { $report += "$($dll.Name): symbol present, build id value not extractable" }
    }
    if ($missing.Count -gt 0) {
        $report += 'WARN build id symbol missing; rebuild with the R1 build-id header in place'
        if ($StrictBuildId) {
            $report += '-StrictBuildId was given: treating the missing symbol as a failure'
            return [pscustomobject]@{ ExitCode = 1; Lines = $report; Warn = $false }
        }
        return [pscustomobject]@{ ExitCode = 0; Lines = $report; Warn = $true }
    }
    [pscustomobject]@{ ExitCode = 0; Lines = $report; Warn = $false }
}

function Resolve-GodotExplicit {
    param([string]$Explicit, [string]$Root)
    $resolver = Join-Path $Root 'tools\runtime\Resolve-GodotBin.ps1'
    if (Test-Path -LiteralPath $resolver -PathType Leaf) {
        . $resolver
        return (Resolve-GodotBin -GodotExe $Explicit)
    }
    if ($Explicit -and (Test-Path -LiteralPath $Explicit -PathType Leaf)) { return $Explicit }
    if ($env:GODOT_BIN -and (Test-Path -LiteralPath $env:GODOT_BIN -PathType Leaf)) { return $env:GODOT_BIN }
    foreach ($name in @('godot_console', 'godot')) {
        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
    }
    return ''
}

# ---------------------------------------------------------------------------
# stage plan
# ---------------------------------------------------------------------------

$runBuild = (-not $Quick) -and (-not $SkipBuild)
$runSuites = -not $Quick
$runSoak = (-not $Quick) -and $WithSoak

$staticChecks = @(
    [pscustomobject]@{ name = 'fault-taxonomy'; file = 'tools/ci/check_fault_taxonomy.py'; args = @('--strict'); note = 'R1 fault taxonomy (--strict)' },
    [pscustomobject]@{ name = 'cpp-deps'; file = 'tools/ci/check_cpp_deps.py'; args = @(); note = 'cross-domain include/type ratchet' },
    [pscustomobject]@{ name = 'size-ratchet'; file = 'tools/ci/check_size_ratchet.py'; args = @(); note = 'file size baseline ratchet' },
    [pscustomobject]@{ name = 'module-map'; file = 'tools/ci/check_module_map.py'; args = @(); note = 'docs/architecture/module-map.md paths exist' },
    [pscustomobject]@{ name = 'module-api'; file = 'tools/ci/check_module_api.py'; args = @(); note = 'module API boundary contract' },
    [pscustomobject]@{ name = 'module-contracts'; file = 'tools/ci/check_module_contracts.py'; args = @(); note = 'module registry + committed reads' },
    [pscustomobject]@{ name = 'script-native-access'; file = 'tools/ci/check_script_native_access.py'; args = @(); note = 'cross-module DCWorldExt access in GDScript' }
)

if ($DryRun) {
    Write-Host "verify.ps1 dry run (nothing is executed)  repo=$root"
    Write-Host ''
    Write-Host '[static]'
    foreach ($check in $staticChecks) {
        $exists = if (Test-Path -LiteralPath (Join-Path $root $check.file) -PathType Leaf) { '' } else { '   <- SKIP (script missing)' }
        Write-Host ("  python {0} {1}{2}" -f $check.file, ($check.args -join ' '), $exists)
    }
    Write-Host '  <inline> .gdextension windows.debug.x86_64 must map to .template_debug.'
    Write-Host '  git diff --check'
    Write-Host '  python tools/ci/check_large_blobs.py'
    if ($runBuild) {
        Write-Host ''
        Write-Host '[build]'
        Write-Host ("  (cd gdext) scons platform=windows target=template_debug -j {0}" -f $Jobs)
        Write-Host '  <inline> dll PK_BUILD_ID / pk_build_id self check (WARN unless -StrictBuildId)'
    }
    else {
        Write-Host ''
        Write-Host '[build] skipped by request (-Quick or -SkipBuild)'
    }
    if ($runSuites) {
        Write-Host ''
        Write-Host '[suites] serial (Invoke-RuntimeTests.ps1 hard-codes its test list; it takes no subset/jobs argument)'
        Write-Host ("  pwsh -File tools/runtime/Invoke-RuntimeTests.ps1 -RepoRoot {0} -OutDir {1}\runtime-tests -TimeoutSeconds {2} [-GodotExe ...]" -f $root, $artifactDir, $TestTimeoutSeconds)
    }
    else {
        Write-Host ''
        Write-Host '[suites] skipped by request (-Quick)'
    }
    if ($runSoak) {
        Write-Host ''
        Write-Host '[soak]'
        $soakScript = Join-Path $root 'tools\runtime\Invoke-Soak.ps1'
        if (Test-Path -LiteralPath $soakScript -PathType Leaf) { Write-Host '  pwsh -File tools/runtime/Invoke-Soak.ps1' }
        else { Write-Host '  SKIP: tools/runtime/Invoke-Soak.ps1 does not exist yet' }
    }
    Write-Host ''
    Write-Host ("report would be written to {0}" -f $jsonPath)
    exit 0
}

# ---------------------------------------------------------------------------
# environment checks (exit 2, never a silent pass)
# ---------------------------------------------------------------------------

$environmentError = ''
$pythonExe = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $pythonExe) { $environmentError = 'python is not on PATH (the static checks are python scripts)' }
if (-not $environmentError) {
    $gitExe = (Get-Command git -ErrorAction SilentlyContinue)
    if (-not $gitExe) { $environmentError = 'git is not on PATH (git diff --check and the blob gate need it)' }
}
$sconsExe = $null
if (-not $environmentError -and $runBuild) {
    $sconsExe = (Get-Command scons -ErrorAction SilentlyContinue)
    if (-not $sconsExe) { $environmentError = 'scons is not on PATH (drop -Quick/-SkipBuild or install scons)' }
}
$godot = ''
if (-not $environmentError -and ($runSuites -or $runSoak)) {
    try { $godot = Resolve-GodotExplicit -Explicit $GodotExe -Root $root }
    catch { $environmentError = $_.Exception.Message }
    if (-not $environmentError -and -not $godot) {
        $environmentError = 'godot not found: pass -GodotExe or set GODOT_BIN'
    }
}
if ($environmentError) {
    Write-Host "ENVIRONMENT ERROR: $environmentError" -ForegroundColor Red
    Write-Host 'verify.ps1 exit code 2 (environment problem, nothing was validated)'
    exit 2
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

$startedAll = Get-Date
$stages = @()

# --- static -----------------------------------------------------------------
$stageStarted = Get-Date
Write-Host '== static =='
$staticItems = @()

foreach ($check in $staticChecks) {
    $path = Join-Path $root $check.file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $item = [ordered]@{
            name             = $check.name
            command          = "python $($check.file) $($check.args -join ' ')".Trim()
            status           = 'skipped'
            exit_code        = $null
            elapsed_seconds  = 0
            known_red        = $false
            known_red_reason = $null
            note             = "$($check.file) does not exist yet"
            failure_output   = @()
        }
        Write-Host ("  {0,-9} {1,-26} {2}" -f 'SKIP', $item.name, $item.note) -ForegroundColor Yellow
        $staticItems += ($item)
        continue
    }
    $commandText = "python $($check.file) $($check.args -join ' ')".Trim()
    $itemStarted = Get-Date
    $outcome = Invoke-NativeCommand -Exe $pythonExe.Source -Arguments (@($check.file) + $check.args) -WorkingDirectory $root
    $elapsed = [math]::Round(((Get-Date) - $itemStarted).TotalSeconds, 2)
    $result = New-CheckResult -Name $check.file.Split('/')[-1] -Command $commandText -Outcome $outcome -Elapsed $elapsed
    Format-CheckLine -Item $result
    $staticItems += ($result)
}

# .gdextension guard (R6-4)
$itemStarted = Get-Date
$outcome = Test-GdextensionMapping
$result = New-CheckResult -Name 'gdextension-mapping' -Command '<inline> .gdextension windows.debug.x86_64 -> .template_debug.' -Outcome $outcome -Elapsed ([math]::Round(((Get-Date) - $itemStarted).TotalSeconds, 2))
Format-CheckLine -Item $result
$staticItems += ($result)

# git diff --check
$itemStarted = Get-Date
$outcome = Invoke-NativeCommand -Exe $gitExe.Source -Arguments @('diff', '--check') -WorkingDirectory $root
$result = New-CheckResult -Name 'git-diff-check' -Command 'git diff --check' -Outcome $outcome -Elapsed ([math]::Round(((Get-Date) - $itemStarted).TotalSeconds, 2))
Format-CheckLine -Item $result
$staticItems += ($result)

# staged blob budget
$blobScript = 'tools/ci/check_large_blobs.py'
if (-not (Test-Path -LiteralPath (Join-Path $root $blobScript) -PathType Leaf)) {
    $item = [ordered]@{
        name             = 'large-blobs'
        command          = "python $blobScript"
        status           = 'skipped'
        exit_code        = $null
        elapsed_seconds  = 0
        known_red        = $false
        known_red_reason = $null
        note             = "$blobScript does not exist yet"
        failure_output   = @()
    }
    Write-Host ("  {0,-9} {1,-26} {2}" -f 'SKIP', $item.name, $item.note) -ForegroundColor Yellow
    $staticItems += ($item)
}
else {
    $itemStarted = Get-Date
    $outcome = Invoke-NativeCommand -Exe $pythonExe.Source -Arguments @($blobScript) -WorkingDirectory $root
    $result = New-CheckResult -Name 'large-blobs' -Command "python $blobScript" -Outcome $outcome -Elapsed ([math]::Round(((Get-Date) - $itemStarted).TotalSeconds, 2))
    Format-CheckLine -Item $result
    $staticItems += ($result)
}

$stages += [ordered]@{
        name            = 'static'
        status          = 'pass'
        elapsed_seconds = [math]::Round(((Get-Date) - $stageStarted).TotalSeconds, 2)
        items           = $staticItems
    }

# --- build ------------------------------------------------------------------
if ($runBuild) {
    $stageStarted = Get-Date
    Write-Host ''
    Write-Host '== build =='
    $buildItems = @()

    $sconsArgs = @('platform=windows', 'target=template_debug', "-j$Jobs")
    $itemStarted = Get-Date
    $outcome = Invoke-NativeCommand -Exe $sconsExe.Source -Arguments $sconsArgs -WorkingDirectory (Join-Path $root 'gdext')
    $result = New-CheckResult -Name 'scons-template-debug' -Command ("(cd gdext) scons " + ($sconsArgs -join ' ')) -Outcome $outcome -Elapsed ([math]::Round(((Get-Date) - $itemStarted).TotalSeconds, 2))
    Format-CheckLine -Item $result
    $buildItems += ($result)

    $itemStarted = Get-Date
    $outcome = Test-DllBuildId
    $result = New-CheckResult -Name 'dll-build-id' -Command '<inline> dll PK_BUILD_ID self check' -Outcome $outcome -Elapsed ([math]::Round(((Get-Date) - $itemStarted).TotalSeconds, 2)) -WarnOnly ([bool]$outcome.Warn)
    # A WARN still has to say why in the summary.
    if ($result.status -eq 'warn') {
        $warnText = @($outcome.Lines) | Where-Object { $_ -match 'WARN' } | Select-Object -First 1
        $result.note = if ($warnText) { $warnText } else { 'build id symbol not found' }
    }
    Format-CheckLine -Item $result
    $buildItems += ($result)

    $stages += [ordered]@{
            name            = 'build'
            status          = 'pass'
            elapsed_seconds = [math]::Round(((Get-Date) - $stageStarted).TotalSeconds, 2)
            items           = $buildItems
    }
}

# --- suites -----------------------------------------------------------------
if ($runSuites) {
    $stageStarted = Get-Date
    Write-Host ''
    Write-Host '== suites (serial) =='
    $suiteItems = @()

    $suiteScript = Join-Path $root 'tools\runtime\Invoke-RuntimeTests.ps1'
    if (-not (Test-Path -LiteralPath $suiteScript -PathType Leaf)) {
        $item = [ordered]@{
            name             = 'runtime-suites'
            command          = 'pwsh -File tools/runtime/Invoke-RuntimeTests.ps1'
            status           = 'skipped'
            exit_code        = $null
            elapsed_seconds  = 0
            known_red        = $false
            known_red_reason = $null
            note             = 'tools/runtime/Invoke-RuntimeTests.ps1 does not exist'
            failure_output   = @()
        }
        Write-Host ("  {0,-9} {1,-26} {2}" -f 'SKIP', $item.name, $item.note) -ForegroundColor Yellow
        $suiteItems += ($item)
    }
    else {
        $suiteOut = Join-Path $artifactDir 'runtime-tests'
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
        $hostExe = (Get-Command pwsh -ErrorAction SilentlyContinue)
        $pwshPath = if ($hostExe) { $hostExe.Source } else { (Get-Process -Id $PID).Path }
        $suiteArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $suiteScript,
            '-RepoRoot', $root, '-OutDir', $suiteOut, '-GodotExe', $godot,
            '-TimeoutSeconds', "$TestTimeoutSeconds")
        $commandText = "pwsh -File tools/runtime/Invoke-RuntimeTests.ps1 -RepoRoot $root -OutDir $suiteOut -GodotExe $godot -TimeoutSeconds $TestTimeoutSeconds"
        $itemStarted = Get-Date
        $outcome = Invoke-NativeCommand -Exe $pwshPath -Arguments $suiteArgs -WorkingDirectory $root
        $elapsed = [math]::Round(((Get-Date) - $itemStarted).TotalSeconds, 2)
        $result = New-CheckResult -Name 'runtime-suites' -Command $commandText -Outcome $outcome -Elapsed $elapsed
        $summaryFile = Join-Path $suiteOut 'test-summary.json'
        $timedOutNames = @()
        if (Test-Path -LiteralPath $summaryFile -PathType Leaf) {
            try {
                $suiteSummary = Get-Content -LiteralPath $summaryFile -Raw | ConvertFrom-Json
                if ($suiteSummary.PSObject.Properties.Name -contains 'timed_out') {
                    $timedOutNames = @($suiteSummary.timed_out)
                }
                $result.note = "total=$($suiteSummary.total) passed=$($suiteSummary.passed) known_red=$($suiteSummary.known_red) failed=$($suiteSummary.failed) timed_out=$($timedOutNames.Count) (per-test timeout ${TestTimeoutSeconds}s); summary=$summaryFile"
            }
            catch { $result.note = "could not read $summaryFile" }
        }
        else {
            $result.note = 'no test-summary.json written'
        }
        # The per-test cap and the timeout list belong in the machine-readable
        # report too, not only on stdout: tmp/verify_*.json is the artifact CI
        # reads when the run is red.
        $result.Add('test_timeout_seconds', $TestTimeoutSeconds)
        $result.Add('timed_out_tests', @($timedOutNames))
        Format-CheckLine -Item $result
        if ($timedOutNames.Count -gt 0) {
            Write-Host ("           timed out (>${TestTimeoutSeconds}s, killed): {0}" -f ($timedOutNames -join ', ')) -ForegroundColor Red
        }
        $suiteItems += ($result)
    }
    $stages += [ordered]@{
            name            = 'suites'
            status          = 'pass'
            elapsed_seconds = [math]::Round(((Get-Date) - $stageStarted).TotalSeconds, 2)
            items           = $suiteItems
    }
}

# --- soak -------------------------------------------------------------------
if ($runSoak) {
    $stageStarted = Get-Date
    Write-Host ''
    Write-Host '== soak =='
    $soakItems = @()
    $soakScript = Join-Path $root 'tools\runtime\Invoke-Soak.ps1'
    if (-not (Test-Path -LiteralPath $soakScript -PathType Leaf)) {
        $item = [ordered]@{
            name             = 'runtime-soak'
            command          = 'pwsh -File tools/runtime/Invoke-Soak.ps1'
            status           = 'skipped'
            exit_code        = $null
            elapsed_seconds  = 0
            known_red        = $false
            known_red_reason = $null
            note             = 'tools/runtime/Invoke-Soak.ps1 does not exist yet'
            failure_output   = @()
        }
        Write-Host ("  {0,-9} {1,-26} {2}" -f 'SKIP', $item.name, $item.note) -ForegroundColor Yellow
        $soakItems += ($item)
    }
    else {
        # Parameter surface unknown: run with defaults so a new -OutDir/-Days
        # argument in that script cannot break this stage.
        $hostExe = (Get-Command pwsh -ErrorAction SilentlyContinue)
        $pwshPath = if ($hostExe) { $hostExe.Source } else { (Get-Process -Id $PID).Path }
        $itemStarted = Get-Date
        $outcome = Invoke-NativeCommand -Exe $pwshPath -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $soakScript) -WorkingDirectory $root
        $result = New-CheckResult -Name 'runtime-soak' -Command 'pwsh -File tools/runtime/Invoke-Soak.ps1' -Outcome $outcome -Elapsed ([math]::Round(((Get-Date) - $itemStarted).TotalSeconds, 2))
        Format-CheckLine -Item $result
        $soakItems += ($result)
    }
    $stages += [ordered]@{
            name            = 'soak'
            status          = 'pass'
            elapsed_seconds = [math]::Round(((Get-Date) - $stageStarted).TotalSeconds, 2)
            items           = $soakItems
    }
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

$allItems = @($stages | ForEach-Object { $_['items'] })
$failures = @($allItems | Where-Object { $_.status -eq 'fail' })
$knownRedItems = @($allItems | Where-Object { $_.status -eq 'known-red' })
$skippedItems = @($allItems | Where-Object { $_.status -eq 'skipped' })
$warnItems = @($allItems | Where-Object { $_.status -eq 'warn' })
$passedItems = @($allItems | Where-Object { $_.status -eq 'pass' })

foreach ($stage in $stages) {
    $stageItems = @($stage['items'])
    if (@($stageItems | Where-Object { $_.status -eq 'fail' }).Count -gt 0) { $stage.status = 'fail' }
    elseif (@($stageItems | Where-Object { $_.status -eq 'known-red' }).Count -gt 0) { $stage.status = 'known-red' }
    elseif (@($stageItems | Where-Object { $_.status -eq 'skipped' }).Count -gt 0) { $stage.status = 'incomplete' }
    elseif (@($stageItems | Where-Object { $_.status -eq 'warn' }).Count -gt 0) { $stage.status = 'warn' }
    else { $stage.status = 'pass' }
}

Write-Host ''
Write-Host '== summary =='
Write-Host ("  stages: " + (($stages | ForEach-Object { "$($_.name)=$($_.status)" }) -join '  '))
Write-Host ("  checks: {0} pass, {1} known-red, {2} skip, {3} warn, {4} fail" -f `
        $passedItems.Count, $knownRedItems.Count, $skippedItems.Count, $warnItems.Count, $failures.Count)

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host '  FAILED (red, must fix):' -ForegroundColor Red
    foreach ($item in $failures) {
        Write-Host ("    {0}  exit={1}  {2}" -f $item.name, $item.exit_code, $item.command) -ForegroundColor Red
        if ($item.known_red -and $item.known_red_reason) {
            Write-Host ("      known-red reason: {0}" -f ($item.known_red_reason -replace "`r?`n", ' ')) -ForegroundColor DarkRed
        }
        foreach ($line in $item.failure_output) { Write-Host ("      | {0}" -f $line) -ForegroundColor DarkRed }
    }
}

if ($knownRedItems.Count -gt 0) {
    Write-Host ''
    $knownRedHeading = if ($Strict) { '  KNOWN-RED (counted as failure because -Strict):' } else { '  KNOWN-RED (pre-existing baseline drift, does not fail this run; -Strict makes it fail):' }
    Write-Host $knownRedHeading -ForegroundColor Red
    foreach ($item in $knownRedItems) {
        Write-Host ("    {0}  exit={1}  {2}" -f $item.name, $item.exit_code, $item.command) -ForegroundColor Red
        Write-Host ("      reason: {0}" -f ($item.known_red_reason -replace "`r?`n", ' ')) -ForegroundColor DarkRed
        foreach ($line in $item.failure_output) { Write-Host ("      | {0}" -f $line) -ForegroundColor DarkRed }
    }
}

if ($skippedItems.Count -gt 0) {
    Write-Host ''
    Write-Host '  SKIPPED (not green: the check could not run):' -ForegroundColor Yellow
    foreach ($item in $skippedItems) {
        Write-Host ("    {0}  {1}" -f $item.name, $item.note) -ForegroundColor Yellow
    }
}

if ($warnItems.Count -gt 0) {
    Write-Host ''
    Write-Host '  WARNINGS:' -ForegroundColor Yellow
    foreach ($item in $warnItems) {
        Write-Host ("    {0}  {1}" -f $item.name, $item.note) -ForegroundColor Yellow
    }
}

$blocking = $failures.Count
if ($Strict) { $blocking += $knownRedItems.Count }
$exitCode = if ($blocking -gt 0) { 1 } elseif ($skippedItems.Count -gt 0) { 1 } else { 0 }
$verdict = switch ($exitCode) {
    0 { 'GREEN' }
    1 { if ($blocking -gt 0) { 'RED (failing checks)' } else { 'RED (nothing failed, but skipped checks are not green)' } }
    default { 'UNKNOWN' }
}

$elapsedTotal = [math]::Round(((Get-Date) - $startedAll).TotalSeconds, 2)
$report = [ordered]@{
    schema          = 1
    generated_utc   = (Get-Date).ToUniversalTime().ToString('o')
    generated_local = (Get-Date).ToString('o')
    repo_root       = $root
    godot           = $godot
    python          = $pythonExe.Source
    modes           = [ordered]@{
        quick          = [bool]$Quick
        with_soak      = [bool]$WithSoak
        skip_build     = [bool]$SkipBuild
        strict         = [bool]$Strict
        strict_build_id = [bool]$StrictBuildId
        jobs           = $Jobs
        test_timeout_seconds = $TestTimeoutSeconds
    }
    suites_mode     = 'serial'
    suites_reason   = 'tools/runtime/Invoke-RuntimeTests.ps1 hard-codes its test list and takes no subset/jobs argument, so the suites stage cannot be split into parallel lanes without changing that script; it runs serially.'
    stages          = @($stages)
    failed          = @($failures | ForEach-Object { $_.name })
    known_red       = @($knownRedItems | ForEach-Object { [ordered]@{ name = $_.name; command = $_.command; exit_code = $_.exit_code; reason = $_.known_red_reason } })
    skipped         = @($skippedItems | ForEach-Object { [ordered]@{ name = $_.name; note = $_.note } })
    summary         = [ordered]@{
        verdict         = $verdict
        total           = $allItems.Count
        passed          = $passedItems.Count
        failed          = $failures.Count
        known_red       = $knownRedItems.Count
        skipped         = $skippedItems.Count
        warned          = $warnItems.Count
        elapsed_seconds = $elapsedTotal
    }
    exit_code       = $exitCode
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

Write-Host ''
Write-Host ("verdict: {0}  exit={1}  ({2:N1}s)" -f $verdict, $exitCode, $elapsedTotal) -ForegroundColor $(if ($exitCode -eq 0) { 'Green' } else { 'Red' })
Write-Host ("report : {0}" -f $jsonPath)
if ($skippedItems.Count -gt 0) {
    Write-Host 'note   : skipped checks never count as green; install the missing script or drop the stage'
}
exit $exitCode
