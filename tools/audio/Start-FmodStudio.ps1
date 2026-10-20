[CmdletBinding()]
param(
    [string]$InstallerPath,
    [string]$ProjectPath,
    [string]$CacheDirectory = (Join-Path $env:LOCALAPPDATA 'ProjectKeynes\Tools\FMOD'),
    [switch]$SetupOnly
)

$ErrorActionPreference = 'Stop'
$studioVersion = '2.03.15'
$installerName = 'fmodstudio20315win64-installer.exe'
$installerHash = '5CAE0B04DA481EEB54095F03C231A2A12BE9E46E5EC3CBAB046D5E0FEEE2AB1F'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$toolDirectory = Join-Path $repoRoot "tools\fmod-studio\$studioVersion"
$studioExe = Join-Path $toolDirectory 'FMOD Studio.exe'
$readyFile = Join-Path $toolDirectory '.project-keynes-ready.json'
$cachedInstaller = Join-Path $CacheDirectory $installerName

function Assert-Installer([string]$Path) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $installerHash) {
        throw "Installer hash mismatch: $Path. Expected FMOD Studio $studioVersion."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Firelight Technologies') {
        throw "Installer signature verification failed: $Path"
    }
}

try {
    # Resolve the requested project before starting the interactive application.
    $projectFile = $null
    if ($ProjectPath) {
        $projectFile = (Resolve-Path -LiteralPath $ProjectPath).Path
        if ([IO.Path]::GetExtension($projectFile) -ne '.fspro') {
            throw 'ProjectPath must point to an FMOD .fspro project.'
        }
    } else {
        $defaultProject = Join-Path $repoRoot 'Audio\ProjectKeynes\ProjectKeynes.fspro'
        if (Test-Path -LiteralPath $defaultProject -PathType Leaf) {
            $projectFile = $defaultProject
        }
    }

    $ready = $false
    if ((Test-Path -LiteralPath $readyFile) -and (Test-Path -LiteralPath $studioExe)) {
        $state = Get-Content -LiteralPath $readyFile -Raw | ConvertFrom-Json
        $ready = $state.version -eq $studioVersion -and $state.installer_sha256 -eq $installerHash
    }

    if (-not $ready) {
        $candidate = $null
        if ($InstallerPath) {
            $candidate = (Resolve-Path -LiteralPath $InstallerPath).Path
        } elseif (Test-Path -LiteralPath $cachedInstaller -PathType Leaf) {
            $candidate = $cachedInstaller
        } else {
            $download = Join-Path $env:USERPROFILE "Downloads\$installerName"
            if (Test-Path -LiteralPath $download -PathType Leaf) { $candidate = $download }
        }
        if (-not $candidate) {
            throw "Download Studio $studioVersion from https://www.fmod.com/download and put $installerName in Downloads, or supply -InstallerPath. Official downloads require your account; no credentials are stored by this script."
        }
        Assert-Installer $candidate

        $extractor = $null
        $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
        if ($sevenZip) { $extractor = $sevenZip.Source }
        if (-not $extractor) {
            foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
                if ($base -and (Test-Path -LiteralPath (Join-Path $base '7-Zip\7z.exe'))) {
                    $extractor = Join-Path $base '7-Zip\7z.exe'
                    break
                }
            }
        }
        if (-not $extractor) {
            throw '7-Zip is required for first-time extraction. Install 7-Zip or copy a prepared tools/fmod-studio directory from your own machine.'
        }

        New-Item -ItemType Directory -Force -Path $CacheDirectory | Out-Null
        if ([IO.Path]::GetFullPath($candidate) -ne [IO.Path]::GetFullPath($cachedInstaller)) {
            Copy-Item -LiteralPath $candidate -Destination $cachedInstaller
        }
        New-Item -ItemType Directory -Force -Path $toolDirectory | Out-Null
        Write-Host "Preparing FMOD Studio $studioVersion in $toolDirectory ..."
        # Unpack the application without running the installer or changing file associations.
        & $extractor x $cachedInstaller "-o$toolDirectory" '-y' '-aoa' '-xr!$PLUGINSDIR' '-xr!uninstall.exe.nsis' | Out-Host
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $studioExe -PathType Leaf)) {
            throw 'FMOD Studio extraction failed. No completion marker was written.'
        }
        @{ version = $studioVersion; installer_sha256 = $installerHash } |
            ConvertTo-Json | Set-Content -LiteralPath $readyFile -Encoding UTF8
    }

    Write-Host "FMOD Studio ready: $studioExe"
    if (-not $SetupOnly) {
        $launch = @{ FilePath = $studioExe; WorkingDirectory = $toolDirectory }
        if ($projectFile) { $launch.ArgumentList = '"' + $projectFile + '"' }
        # This is the interactive editor the user explicitly launched.
        Start-Process @launch | Out-Null
    }
} catch {
    Write-Error $_
    exit 1
}
