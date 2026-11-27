<#
.SYNOPSIS
One-shot Windows PC build & export helper for Project.Keynes.

.DESCRIPTION
Builds the matching Windows dots_ext native library (unless -SkipNative is set),
checks FMOD runtime libraries and Desktop soundbanks so silent exports are
explicitly flagged, exports the "Windows Desktop" preset into a clean folder
under Build/, and runs a headless startup smoke check on the exported binary.
#>
[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'debug',
    [switch]$SkipNative,
    [switch]$SkipImport,
    [switch]$SkipSmoke,
    [string]$GodotBin = '',
    [string]$OutputDir = '',
    [int]$Jobs = 0
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$projectDir = Join-Path $repoRoot 'Project\project-keynes'
$gdextDir = Join-Path $repoRoot 'gdext'

if ($Jobs -le 0) {
    $Jobs = [Math]::Max(1, [Environment]::ProcessorCount)
}

if (-not $OutputDir) {
    $OutputDir = Join-Path $repoRoot ("Build\ProjectKeynes-{0}" -f $Mode)
}

$exeName = if ($Mode -eq 'debug') { 'ProjectKeynes-debug.exe' } else { 'ProjectKeynes.exe' }
$consoleName = if ($Mode -eq 'debug') { 'ProjectKeynes-debug.console.exe' } else { 'ProjectKeynes.console.exe' }
$outputExe = Join-Path $OutputDir $exeName
$outputConsole = Join-Path $OutputDir $consoleName

. (Join-Path $repoRoot 'tools\runtime\Resolve-GodotBin.ps1')
$resolvedGodot = Resolve-GodotBin -GodotExe $GodotBin

# On this machine `& $exe` does not reliably surface an exit code (and sometimes
# does not run at all), and a crashed process lands as a large negative code that
# `if errorlevel` cannot see. Everything here goes through Start-Process -Wait so
# the code is always real, with stdout/stderr kept for the report.
function Invoke-BuildExe {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [string]$LogStem,
        [string]$What = '',
        [int]$TimeoutSec = 3600
    )
    $outLog = "$LogStem.out.log"
    $errLog = "$LogStem.err.log"
    $rcLog  = "$LogStem.rc"
    $runner = "$LogStem.run.cmd"
    $parent = Split-Path -Parent $LogStem
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Remove-Item -LiteralPath $rcLog -Force -ErrorAction SilentlyContinue
    if (-not $What) { $What = Split-Path -Leaf $FilePath }

    # A generated runner file instead of a long /c string: quoting survives any
    # path, and completion is signalled by a file. Waiting on the process itself
    # is not an option here - scons is a shim whose process tree can outlive the
    # build, and Start-Process -Wait then never returns even though the work is
    # long finished.
    $lines = @(
        '@echo off',
        ('"{0}" {1} 1> "{2}" 2> "{3}"' -f $FilePath, $Arguments, $outLog, $errLog),
        ('> "{0}" echo %ERRORLEVEL%' -f $rcLog)
    )
    Set-Content -LiteralPath $runner -Value ($lines -join "`r`n") -Encoding ASCII

    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c "' + $runner + '"') -WindowStyle Hidden -PassThru

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Test-Path -LiteralPath $rcLog)) {
        if ((Get-Date) -gt $deadline) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { }
            throw ("{0} did not finish within {1}s (log: {2})" -f $What, $TimeoutSec, $outLog)
        }
        Start-Sleep -Milliseconds 400
    }
    Start-Sleep -Milliseconds 120

    $code = -1
    $rcText = ''
    if (Test-Path -LiteralPath $rcLog) { $rcText = (Get-Content -LiteralPath $rcLog -Raw -ErrorAction SilentlyContinue) }
    if ($rcText) {
        $trimmed = $rcText.Trim()
        if ($trimmed -match '^-?\d+$') { $code = [int]$trimmed }
    }
    $stdout = ''
    if (Test-Path -LiteralPath $outLog) { $stdout = (Get-Content -LiteralPath $outLog -Raw -ErrorAction SilentlyContinue) }

    return [pscustomobject]@{
        ExitCode = [int]$code
        StdOut   = [string]$stdout
        OutLog   = $outLog
        ErrLog   = $errLog
        RcLog    = $rcLog
        Runner   = $runner
        What     = $What
    }
}

function Resolve-SconsBin {
    $cmd = Get-Command scons -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @(
        (Join-Path $env:APPDATA 'Python\Python314\Scripts\scons.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python314\Scripts\scons.exe')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    throw 'SCons was not found. Install it with: python -m pip install scons'
}

Write-Host "=== Project.Keynes Windows PC Build ($Mode) ==="
Write-Host "Repo   : $repoRoot"
Write-Host "Godot  : $resolvedGodot"
Write-Host "Output : $outputExe"

# 1. Native extension
$sconsTarget = if ($Mode -eq 'debug') { 'template_debug' } else { 'template_release' }
if (-not $SkipNative) {
    if (-not (Test-Path -LiteralPath (Join-Path $gdextDir 'godot-cpp\SConstruct') -PathType Leaf)) {
        throw 'Missing gdext/godot-cpp submodule. Run: git submodule update --init --recursive'
    }
    $scons = Resolve-SconsBin
    Write-Host "`n[1/4] Building dots_ext ($sconsTarget, -j$Jobs) ..."
    Push-Location $gdextDir
    try {
        $run = Invoke-BuildExe -FilePath $scons -What 'scons' `
            -Arguments ("platform=windows target={0} dev_build=no -j{1}" -f $sconsTarget, $Jobs) `
            -LogStem (Join-Path $repoRoot ("tmp\pack-win-{0}-scons" -f $Mode))
        if ($run.ExitCode -ne 0) {
            throw ("SCons build failed with exit code {0} (log: {1})" -f $run.ExitCode, $run.ErrLog)
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "`n[1/4] Skipping native build (-SkipNative)."
}

# 2. Check optional FMOD audio assets (public repo omits licensed DLLs and .bank binaries)
Write-Host "`n[2/4] Checking FMOD Windows runtime & Desktop banks ..."
$fmodBinDir = Join-Path $projectDir 'addons\FmodGodot\bin\windows\x86_64'
$fmodBankDir = Join-Path $projectDir 'assets\audio\banks\Desktop'
$fmodLibName = if ($Mode -eq 'debug') { 'libFmodGodot.template_debug.dll' } else { 'libFmodGodot.template_release.dll' }
$hasFmodDll = Test-Path -LiteralPath (Join-Path $fmodBinDir $fmodLibName) -PathType Leaf
$bankFiles = @(Get-ChildItem -LiteralPath $fmodBankDir -Filter '*.bank' -ErrorAction SilentlyContinue)
$hasBanks = $bankFiles.Count -gt 0

if ($hasFmodDll -and $hasBanks) {
    Write-Host ("  [ok] FMOD DLLs present and {0} Desktop .bank files found." -f $bankFiles.Count)
} else {
    if (-not $hasFmodDll) {
        Write-Warning ("Missing Windows FMOD runtime library: {0}" -f (Join-Path $fmodBinDir $fmodLibName))
    }
    if (-not $hasBanks) {
        Write-Warning ("Missing Desktop FMOD soundbanks in: {0}" -f $fmodBankDir)
    }
    Write-Warning 'Continuing export WITHOUT audio. See docs/bootstrap.md to restore FMOD DLLs and Desktop .bank files.'
}

# 3. Import & export
if (-not $SkipImport) {
    Write-Host "`n[3/4] Refreshing Godot resource import cache ..."
    $run = Invoke-BuildExe -FilePath $resolvedGodot -What 'godot --import' `
        -Arguments ("--headless --path `"{0}`" --import" -f $projectDir) `
        -LogStem (Join-Path $repoRoot ("tmp\pack-win-{0}-import" -f $Mode))
    if ($run.ExitCode -ne 0) {
        throw ("Godot --import failed with exit code {0} (log: {1})" -f $run.ExitCode, $run.ErrLog)
    }
} else {
    Write-Host "`n[3/4] Skipping Godot --import (-SkipImport)."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# Fail fast if the target executable is currently running/locked (avoids wasting
# 30+ seconds packing PCK only to fail at the final rename step).
if (Test-Path -LiteralPath $outputExe -PathType Leaf) {
    try {
        $fs = [System.IO.File]::Open($outputExe, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $fs.Close()
    } catch {
        throw "Output executable is locked (close running $exeName first): $outputExe"
    }
}

$exportFlag = if ($Mode -eq 'debug') { '--export-debug' } else { '--export-release' }
Write-Host "`n[4/4] Exporting Windows Desktop ($Mode) -> $outputExe ..."
$run = Invoke-BuildExe -FilePath $resolvedGodot -What ('godot ' + $exportFlag) `
    -Arguments ("--headless --path `"{0}`" {1} `"Windows Desktop`" `"{2}`"" -f $projectDir, $exportFlag, $outputExe) `
    -LogStem (Join-Path $repoRoot ("tmp\pack-win-{0}-export" -f $Mode))
if ($run.ExitCode -ne 0) {
    throw ("Godot {0} failed with exit code {1} (log: {2})" -f $exportFlag, $run.ExitCode, $run.ErrLog)
}

if (-not (Test-Path -LiteralPath $outputExe -PathType Leaf)) {
    throw "Expected output executable not found: $outputExe"
}

$exportedDotsDlls = @(Get-ChildItem -LiteralPath $OutputDir -Filter "dots_ext*.$sconsTarget.*.dll" -ErrorAction SilentlyContinue)
if ($exportedDotsDlls.Count -eq 0) {
    throw "No dots_ext $sconsTarget DLL was exported into $OutputDir"
}

Write-Host "`nExported artifacts in ${OutputDir}:"
Get-ChildItem -LiteralPath $OutputDir -File | Format-Table Name, Length, LastWriteTime -AutoSize

# Optional headless startup smoke test (catches template logger / extension crashes immediately)
if (-not $SkipSmoke) {
    $smokeBin = if (Test-Path -LiteralPath $outputConsole -PathType Leaf) { $outputConsole } else { $outputExe }
    Write-Host "Running headless startup smoke check: $smokeBin --headless --quit"
    $run = Invoke-BuildExe -FilePath $smokeBin -What 'smoke' -Arguments '--headless --quit' `
        -LogStem (Join-Path $repoRoot ("tmp\pack-win-{0}-smoke" -f $Mode))
    if ($run.ExitCode -ne 0) {
        throw ("Smoke check failed with exit code {0} (log: {1})" -f $run.ExitCode, $run.ErrLog)
    }
    Write-Host 'Smoke check passed (exit code 0).'
}

Write-Host "`n=== Windows PC Build ($Mode) DONE ==="
