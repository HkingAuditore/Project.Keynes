<# Migrates a compatible ABI2/schema53 save into ABI3/schema54/hash-v2.
   Never overwrites the source or an existing destination. #>
param(
    [Parameter(Mandatory=$true)][string]$SavePath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$GodotExe = '',
    [string]$ProjectPath = (Join-Path (Get-Location) 'Project/project-keynes')
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $SavePath).Path
$destination = [System.IO.Path]::GetFullPath($OutputPath)
if ($source -eq $destination -or (Test-Path -LiteralPath $destination)) {
    throw 'Migration requires a new output path; the original and existing files are preserved.'
}
$beforeHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
. (Join-Path $PSScriptRoot 'Resolve-GodotBin.ps1')
$exe = Resolve-GodotBin -GodotExe $GodotExe
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('pk-hash-migration-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $scratch 'autosave.pksv')
$log = Join-Path $scratch 'migration.log'
$settings = @{
    PK_SAVE_DIR = $scratch; PK_SAVE_REPLAY = '1'; PK_SAVE_REPLAY_SLOT = 'autosave';
    PK_SAVE_REPLAY_DAYS = '1'; PK_SAVE_MIGRATE = '1'; PK_ECONOMY_HASH_V2 = '1';
    PK_SAVE_MIGRATE_OUTPUT_SLOT = 'manual_1'
}
$previous = @{}
try {
    foreach ($key in $settings.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $settings[$key], 'Process')
    }
    $ErrorActionPreference = 'Continue'
    & $exe --headless --path $ProjectPath *> $log
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $match = [regex]::Match((Get-Content -LiteralPath $log -Raw), '\[save-replay/result\]\s*(\{.*\})')
    if (-not $match.Success) { throw "Migration result missing; inspect $log" }
    $result = $match.Groups[1].Value | ConvertFrom-Json
    if ($exitCode -ne 0 -or -not $result.ok -or $result.start_day -ne $result.end_day) {
        throw "Migration failed; inspect $log"
    }
    $migrated = Join-Path $scratch 'manual_1.pksv'
    if (-not (Test-Path -LiteralPath $migrated)) { throw "Migrated save missing; inspect $log" }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $beforeHash) {
        throw 'Source save changed during migration; output was not copied.'
    }
    # CreateNew also protects a destination created concurrently.
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    $inputStream = [System.IO.File]::OpenRead($migrated)
    $outputStream = $null
    try {
        $outputStream = [System.IO.File]::Open($destination, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $inputStream.CopyTo($outputStream)
        $outputStream.Flush($true)
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        $inputStream.Dispose()
    }
    Write-Output ([pscustomobject]@{ ok=$true; path=$destination; source_sha256=$beforeHash; day=$result.end_day; log=$log })
} finally {
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process') }
}
