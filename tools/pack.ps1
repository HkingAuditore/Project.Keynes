<#
.SYNOPSIS
One-click build + package for distribution (Project.Keynes).

.DESCRIPTION
Compiles the current working tree, exports the selected platform(s), writes a
build manifest, and produces a single zip you can hand out.

Why this exists: scripts\Build-Windows.cmd / Build-Web.cmd already compile and
export, but they write into a fixed folder, never zip anything, and nothing
records which commit a package came from. Distributing therefore meant a manual
copy-zip-rename round with no traceability.

What it adds:
  * a timestamped folder per run (Build\pack\<stamp>\...), so an older package is
    never overwritten and a failed export cannot leave half a package under a
    name that looks final;
  * every external process runs through Start-Process -Wait, so exit codes are
    real - a crashed export surfaces as a negative code instead of "success";
  * FMOD is registered for the export (see below) and the runtime DLLs land next
    to the exe; without that dance the package is silent;
  * build_info.json next to the artifacts: commit, dirty flag, mode, Godot
    version, per-file size + sha256;
  * the zip is produced here and its sha256 printed, so what you send equals
    what you tested.

Why FMOD needs registering: `addons/FmodGodot/.gdignore` keeps the addon out of
`.godot/extension_list.cfg`, and only extensions listed there are loaded at
startup. Exporting with it hidden produces an exe that never opens FMOD - the
runtime DLLs are not even copied. So the sequence is: drop the flag, reimport,
export, restore the flag and the extension list (import only ever appends).

.PARAMETER Targets
windows (default), web, or all.

.PARAMETER Mode
release (default) or debug.

.PARAMETER Version
Free-form label for the artifact name. Default is <sha>[-dirty] from git.

.PARAMETER NoFmod
Do not register FMOD: the package ships without audio (that is what a plain
export does today).

.EXAMPLE
scripts\Pack.cmd
    Release Windows build, zipped into Build\dist\.

.EXAMPLE
powershell -File tools\pack.ps1 -Targets windows,web -Mode release

.EXAMPLE
powershell -File tools\pack.ps1 -SkipNative -SkipSmoke -NoZip
    Reuse the existing native libs, skip the boot check, keep the folder only.
#>
[CmdletBinding()]
param(
    [ValidateSet('windows', 'web', 'all')]
    [string[]]$Targets = @('windows'),
    [ValidateSet('release', 'debug')]
    [string]$Mode = 'release',
    [string]$Version = '',
    [string]$OutDir = '',
    [switch]$SkipNative,
    [switch]$SkipSmoke,
    [switch]$SkipImport,
    [switch]$NoFmod,
    [switch]$NoZip,
    [switch]$ForceBusy,
    [int]$Jobs = 0
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$projectDir = Join-Path $repoRoot 'Project\project-keynes'
$tmpDir = Join-Path $repoRoot 'tmp'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($Targets -contains 'all') { $Targets = @('windows', 'web') }
$Targets = @($Targets | Select-Object -Unique)

if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'Build\dist' }
elseif (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $repoRoot $OutDir }

if ($Jobs -le 0) { $Jobs = [Math]::Max(1, [Environment]::ProcessorCount) }
if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null }

$fmodFlag = Join-Path $projectDir 'addons\FmodGodot\.gdignore'
$extList = Join-Path $projectDir '.godot\extension_list.cfg'
$extListBackup = Join-Path $tmpDir 'pack_extension_list.bak'
$statePath = Join-Path $tmpDir 'pack_export_state.json'

# ------------------------------------------------------------------ helpers ---
# `& $exe` is not trustworthy on this box (the exit code can be lost, and a crash
# reports as a huge negative number that `if errorlevel` never sees). Every
# external call goes through Start-Process -Wait with redirected output.
function Invoke-Tool {
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

function Get-GitValue {
    param([string]$Arguments, [string]$Fallback = '')
    try {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if (-not $git) { return $Fallback }
        $run = Invoke-Tool -FilePath $git.Source -Arguments $Arguments -LogStem (Join-Path $tmpDir 'pack-git') -What 'git'
        if ($run.ExitCode -ne 0) { return $Fallback }
        return $run.StdOut.Trim()
    } catch { return $Fallback }
}

function Get-FileDigest {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        name   = $item.Name
        size   = [int64]$item.Length
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Get-DirSize {
    param([string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)
    return ($files | Measure-Object -Property Length -Sum).Sum
}

function Test-BuildBusy {
    $busy = @()
    foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if (-not $proc.CommandLine) { continue }
        if ($proc.ProcessId -eq $PID) { continue }
        if ($proc.Name -eq 'scons.exe' -or $proc.CommandLine -match 'scons\.exe') {
            $busy += ('scons (pid {0})' -f $proc.ProcessId)
        }
        if ($proc.Name -like 'Godot_v*') {
            $busy += ('{0} (pid {1})' -f $proc.Name, $proc.ProcessId)
        }
    }
    return @($busy | Select-Object -Unique)
}

function New-ZipFromDirectory {
    param([string]$SourceDir, [string]$ZipPath, [bool]$EntirePath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    # IncludeBaseDirectory keeps the folder name as the zip root, so extracting
    # gives one self-contained directory instead of loose files.
    [IO.Compression.ZipFile]::CreateFromDirectory($SourceDir, $ZipPath,
        [IO.Compression.CompressionLevel]::Optimal, $EntirePath)
}

function Write-BuildInfo {
    param([string]$Dir, [string]$Platform, [string]$BuildId, [string[]]$SkipNames = @())
    # Enumerate what is actually in the package, by relative path: two DLLs can
    # share a name in different folders and a bare-name list loses that.
    $files = @()
    foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Recurse -File)) {
        $rel = $item.FullName.Substring($Dir.Length).TrimStart('\')
        if ($SkipNames -contains $rel) { continue }
        $files += [pscustomobject]@{
            path   = $rel.Replace('\', '/')
            size   = [int64]$item.Length
            sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $info = [pscustomobject]@{
        schema          = 1
        product         = 'Project.Keynes'
        platform        = $Platform
        mode            = $Mode
        version         = $script:versionLabel
        git_commit      = $script:gitCommit
        git_dirty       = $script:gitDirty
        git_dirty_files = $script:gitDirtyFiles
        build_id        = $BuildId
        built_at        = (Get-Date -Format 'o')
        host            = $env:COMPUTERNAME
        godot           = $script:godotVersion
        native_built    = (-not $SkipNative)
        fmod_registered = $script:fmodRegistered
        artifacts       = $files
    }
    $path = Join-Path $Dir 'build_info.json'
    $info | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

# --------------------------------------------------- FMOD export registration --
# The addon is gitignored out of the extension list; only listed extensions load
# at startup, and only then do the runtime DLLs get copied next to the exe.
function Restore-ExportState {
    if (-not (Test-Path -LiteralPath $statePath)) { return }
    $state = $null
    try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { }
    if ($state -and $state.flags) {
        foreach ($flag in @($state.flags)) {
            if (-not (Test-Path -LiteralPath $flag)) {
                $parent = Split-Path -Parent $flag
                if (Test-Path -LiteralPath $parent) { New-Item -ItemType File -Force -Path $flag | Out-Null }
            }
        }
    }
    if (Test-Path -LiteralPath $extListBackup) {
        # Put the list back before any further import; an import would re-append
        # the addon it no longer should see.
        Copy-Item -LiteralPath $extListBackup -Destination $extList -Force
        Remove-Item -LiteralPath $extListBackup -Force
    }
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    Write-Host '  [fmod] export state restored' -ForegroundColor DarkGray
}

function Enable-FmodForExport {
    if ($NoFmod) {
        Write-Host '  [fmod] -NoFmod: exporting without audio' -ForegroundColor Yellow
        return $false
    }
    $dllDir = Join-Path $projectDir 'addons\FmodGodot\bin\windows\x86_64'
    if (-not (Test-Path -LiteralPath $dllDir)) {
        Write-Host '  [fmod] no Windows FMOD runtime in the tree - exporting without audio' -ForegroundColor Yellow
        return $false
    }
    # Self-heal a previous interrupted run first: .gdignore missing plus a stale
    # extension list is otherwise invisible and would leak into desktop builds.
    if (Test-Path -LiteralPath $statePath) {
        Write-Host '  [fmod] stale state from an interrupted run, restoring first'
        Restore-ExportState
    }
    if (-not (Test-Path -LiteralPath $fmodFlag)) {
        Write-Host '  [fmod] .gdignore already absent (someone else enabled it?) - leaving state alone' -ForegroundColor Yellow
        return $false
    }
    if (Test-Path -LiteralPath $extList) { Copy-Item -LiteralPath $extList -Destination $extListBackup -Force }
    Remove-Item -LiteralPath $fmodFlag -Force
    @{ flags = @($fmodFlag) } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-Host '  [fmod] registered for this export (reimport so extension_list.cfg sees it)'

    $run = Invoke-Tool -FilePath $script:godotExe -What 'godot --import (fmod)' `
        -Arguments ("--headless --path `"{0}`" --import" -f $projectDir) `
        -LogStem (Join-Path $tmpDir 'pack-fmod-import')
    if ($run.ExitCode -ne 0) {
        throw ("reimport with FMOD enabled failed (exit {0}, log {1})" -f $run.ExitCode, $run.ErrLog)
    }
    $list = ''
    if (Test-Path -LiteralPath $extList) { $list = Get-Content -LiteralPath $extList -Raw }
    if ($list -notmatch 'FmodGodot\.gdextension') {
        throw 'FmodGodot is not in .godot/extension_list.cfg after the reimport; the export would ship silent'
    }
    return $true
}

# --------------------------------------------------------------- preflight ----
Write-Host '=== Project.Keynes pack ===' -ForegroundColor Cyan

. (Join-Path $repoRoot 'tools\runtime\Resolve-GodotBin.ps1')
$script:godotExe = Resolve-GodotBin
$godotVersion = 'unknown'
$ver = Invoke-Tool -FilePath $script:godotExe -Arguments '--version' -LogStem (Join-Path $tmpDir 'pack-godot-version') -What 'godot --version'
if ($ver.ExitCode -eq 0 -and $ver.StdOut.Trim()) { $godotVersion = $ver.StdOut.Trim().Split("`n")[0].Trim() }

$script:gitCommit = Get-GitValue -Arguments 'rev-parse --short HEAD' -Fallback 'nogit'
$dirtyList = Get-GitValue -Arguments 'status --porcelain' -Fallback ''
$script:gitDirtyFiles = @($dirtyList -split "`n" | Where-Object { $_.Trim() }).Count
$script:gitDirty = ($script:gitDirtyFiles -gt 0)
$script:versionLabel = $Version
if (-not $script:versionLabel) {
    $script:versionLabel = $script:gitCommit
    if ($script:gitDirty) { $script:versionLabel += '-dirty' }
}
$script:godotVersion = $godotVersion
$script:fmodRegistered = $false

Write-Host ("  repo      : {0}" -f $repoRoot)
Write-Host ("  godot     : {0} ({1})" -f $script:godotExe, $godotVersion)
Write-Host ("  targets   : {0}" -f ($Targets -join ', '))
Write-Host ("  mode      : {0}" -f $Mode)
Write-Host ("  version   : {0}" -f $script:versionLabel)
if ($script:gitDirty) {
    Write-Host ("  working tree is DIRTY ({0} entries): the package is the tree as it is now" -f $script:gitDirtyFiles) -ForegroundColor Yellow
}

$busy = Test-BuildBusy
if ($busy.Count -gt 0) {
    if (-not $ForceBusy) {
        throw ("another build appears to be running ({0}). Wait for it, or pass -ForceBusy to ignore." -f ($busy -join ', '))
    }
    Write-Warning ("ignoring busy processes: {0}" -f ($busy -join ', '))
}

$driveLetter = [IO.Path]::GetPathRoot($repoRoot).TrimEnd(':', '\')
$drive = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
if ($drive -and $drive.Free -lt 8GB) {
    Write-Warning ("free space on {0}: {1:N1} GB - a build plus zip needs about 2-4 GB" -f $driveLetter, ($drive.Free / 1GB))
}

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$packRoot = Join-Path $repoRoot ('Build\pack\' + $stamp)
New-Item -ItemType Directory -Force -Path $packRoot | Out-Null

$results = @()

# ----------------------------------------------------------------- windows ----
if ($Targets -contains 'windows') {
    Write-Host "`n=== [windows] compile + export ===" -ForegroundColor Cyan
    $stage = Join-Path $packRoot 'win64'
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    $script:fmodRegistered = Enable-FmodForExport
    try {
        $builder = Join-Path $repoRoot 'tools\build_windows.ps1'
        & $builder -Mode $Mode -OutputDir $stage -Jobs $Jobs -SkipNative:$SkipNative `
            -SkipSmoke:$SkipSmoke -SkipImport:($SkipImport -or $script:fmodRegistered)
    } finally {
        if ($script:fmodRegistered) { Restore-ExportState }
    }

    $exeName = if ($Mode -eq 'debug') { 'ProjectKeynes-debug.exe' } else { 'ProjectKeynes.exe' }
    $exePath = Join-Path $stage $exeName
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
        throw ("expected executable is missing after export: {0}" -f $exePath)
    }
    $exe = Get-Item -LiteralPath $exePath
    $pck = @(Get-ChildItem -LiteralPath $stage -Filter '*.pck' -File)
    # The Windows template embeds the pck in the exe, so a ~300 MB exe with no
    # separate .pck is normal; a small exe without a pck means the export failed.
    if ($pck.Count -eq 0 -and $exe.Length -lt 50MB) {
        throw ("export produced {0:N1} MB {1} and no .pck - resources were not packed" -f ($exe.Length / 1MB), $exeName)
    }
    $dots = @(Get-ChildItem -LiteralPath $stage -Filter 'dots_ext*.dll' -File)
    if ($dots.Count -eq 0) { throw 'no dots_ext DLL in the export - the native extension is missing' }

    $fmodDlls = @(Get-ChildItem -LiteralPath $stage -Recurse -Filter 'libFmodGodot.template_*.dll' -File -ErrorAction SilentlyContinue)
    if ($script:fmodRegistered -and $fmodDlls.Count -eq 0) {
        throw 'FMOD was registered for the export but no libFmodGodot DLL landed in the package (it would be silent)'
    }

    # Anything that is not part of the shipped payload must not reach the zip.
    foreach ($junk in @(Get-ChildItem -LiteralPath $stage -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $junk.FullName -Force
    }

    $readme = @(
        ('Project.Keynes - {0} build' -f $Mode),
        ('version   : {0}' -f $script:versionLabel),
        ('commit    : {0}{1}' -f $script:gitCommit, $(if ($script:gitDirty) { ' (working tree had uncommitted changes)' } else { '' })),
        ('built at  : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('audio     : {0}' -f $(if ($script:fmodRegistered) { 'FMOD (addons/FmodGodot/... must stay next to the exe)' } else { 'NOT included (exported with -NoFmod)' })),
        '',
        ('Run : {0}' -f $exeName),
        'Keep the whole folder together: the game loads its pck (embedded in the',
        'exe) plus the addons/ tree from the folder it runs from.',
        '',
        'build_info.json next to this file records the exact commit and file hashes.'
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Value $readme -Encoding UTF8

    $infoPath = Write-BuildInfo -Dir $stage -Platform 'windows' -BuildId $script:versionLabel `
        -SkipNames @('build_info.json', 'README.txt')
    Write-Host ("  build_info: {0}" -f $infoPath)

    $bytes = Get-DirSize -Path $stage
    $zipPath = Join-Path $OutDir ('ProjectKeynes-{0}-win64-{1}-{2}.zip' -f $script:versionLabel, $Mode, $stamp)
    if (-not $NoZip) {
        Write-Host ("  zipping {0:N1} MB ..." -f ($bytes / 1MB))
        New-ZipFromDirectory -SourceDir $stage -ZipPath $zipPath -EntirePath $true
    }
    $results += [pscustomobject]@{
        platform = 'windows'
        folder   = $stage
        bytes    = $bytes
        zip      = $(if (Test-Path -LiteralPath $zipPath) { $zipPath } else { '' })
        zipBytes = $(if (Test-Path -LiteralPath $zipPath) { (Get-Item -LiteralPath $zipPath).Length } else { 0 })
        digest   = $(if (Test-Path -LiteralPath $zipPath) { (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' })
        howto    = ('unzip, run {0}' -f $exeName)
    }
}

# --------------------------------------------------------------------- web ----
if ($Targets -contains 'web') {
    Write-Host "`n=== [web] compile + export ===" -ForegroundColor Cyan
    $webRoot = Join-Path $repoRoot 'WebBuild'
    if ($SkipNative) {
        $webArg = if ($Mode -eq 'debug') { 'skip-native-debug' } else { 'skip-native' }
    } else {
        $webArg = if ($Mode -eq 'debug') { 'debug' } else { 'release' }
    }
    $cmd = Join-Path $repoRoot 'scripts\Build-Web.cmd'
    $run = Invoke-Tool -FilePath $cmd -Arguments $webArg -What 'Build-Web.cmd' `
        -LogStem (Join-Path $tmpDir 'pack-web-build')
    if ($run.ExitCode -ne 0) {
        throw ("Build-Web.cmd failed with exit code {0} (log: {1})" -f $run.ExitCode, $run.OutLog)
    }
    $html = Join-Path $webRoot 'ProjectKeynes.html'
    if (-not (Test-Path -LiteralPath $html -PathType Leaf)) { throw ("web export missing: {0}" -f $html) }

    $webBuildId = ''
    $manifest = Join-Path $webRoot 'manifest.json'
    if (Test-Path -LiteralPath $manifest) {
        try { $webBuildId = [string](Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).build_id } catch { }
    }

    $zipPath = Join-Path $OutDir ('ProjectKeynes-{0}-web-{1}-{2}.zip' -f $script:versionLabel, $Mode, $stamp)
    $stage = Join-Path $packRoot 'web'
    if (-not $NoZip) {
        # Payload-only copy: the .br/.gz sidecars are for the local dev server,
        # not for what a recipient unzips behind their own web server.
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        foreach ($file in @(Get-ChildItem -LiteralPath $webRoot -File)) {
            if ($file.Extension -in @('.br', '.gz')) { continue }
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $stage $file.Name) -Force
        }
        $readme = @(
            ('Project.Keynes - web {0} build' -f $Mode),
            ('version   : {0}' -f $script:versionLabel),
            ('commit    : {0}' -f $script:gitCommit),
            ('build id  : {0}' -f $webBuildId),
            '',
            'Serve this folder over HTTP(S) with these response headers:',
            '  Cross-Origin-Opener-Policy: same-origin',
            '  Cross-Origin-Embedder-Policy: require-corp',
            'and map .wasm -> application/wasm, .pck -> application/octet-stream.',
            'The threads build needs a secure context: use https, not http on a bare IP.',
            'Open check.html first; it reports crossOriginIsolated / SharedArrayBuffer.',
            'Entry point: ProjectKeynes.html'
        ) -join "`r`n"
        Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Value $readme -Encoding UTF8
        [void](Write-BuildInfo -Dir $stage -Platform 'web' -BuildId $webBuildId -SkipNames @('build_info.json', 'README.txt'))
        Write-Host ("  zipping {0:N1} MB ..." -f ((Get-DirSize -Path $stage) / 1MB))
        New-ZipFromDirectory -SourceDir $stage -ZipPath $zipPath -EntirePath $true
    }
    $results += [pscustomobject]@{
        platform = 'web'
        folder   = $stage
        bytes    = (Get-DirSize -Path $webRoot)
        zip      = $(if (Test-Path -LiteralPath $zipPath) { $zipPath } else { '' })
        zipBytes = $(if (Test-Path -LiteralPath $zipPath) { (Get-Item -LiteralPath $zipPath).Length } else { 0 })
        digest   = $(if (Test-Path -LiteralPath $zipPath) { (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' })
        howto    = 'unzip into a site root, serve with COOP/COEP headers'
    }
}

# ----------------------------------------------------------------- summary ----
Write-Host "`n=== artifacts ===" -ForegroundColor Cyan
foreach ($r in $results) {
    Write-Host ("  [{0}] folder: {1}" -f $r.platform, $r.folder)
    if ($r.zip) {
        Write-Host ("       zip     : {0}" -f $r.zip) -ForegroundColor Green
        Write-Host ("       size    : {0:N1} MB (source {1:N1} MB)" -f ($r.zipBytes / 1MB), ($r.bytes / 1MB))
        Write-Host ("       sha256  : {0}" -f $r.digest)
        Write-Host ("       how to  : {0}" -f $r.howto)
    } else {
        Write-Host '       (no zip: -NoZip)' -ForegroundColor Yellow
    }
}
$latest = Join-Path $OutDir 'LATEST.txt'
$lines = @(
    ('version: {0}' -f $script:versionLabel),
    ('commit : {0}{1}' -f $script:gitCommit, $(if ($script:gitDirty) { " (dirty, $($script:gitDirtyFiles) entries)" } else { '' })),
    ('built  : {0}' -f (Get-Date -Format 'o')),
    ''
)
foreach ($r in $results) {
    if ($r.zip) { $lines += ('{0}  {1}  {2:N1} MB  {3}' -f $r.platform, $r.digest, ($r.zipBytes / 1MB), $r.zip) }
}
Set-Content -LiteralPath $latest -Value ($lines -join "`r`n") -Encoding UTF8
Write-Host ("`n  latest  : {0}" -f $latest)

Write-Host "`n=== pack DONE ($Mode) ===" -ForegroundColor Green
