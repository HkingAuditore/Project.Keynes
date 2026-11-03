<#
.SYNOPSIS
  Remove unused entries from an exported APK, then re-align and re-sign it.

.DESCRIPTION
  Godot's `exclude_filter` does not stop resources that are pulled in as
  dependencies (the FMOD content banks are referenced from the project, so the
  exporter ships ~91 MB of desktop FMOD audio inside the Android package even
  though Android uses the portable audio backend).

  This tool deletes the given entries, keeps the archive otherwise untouched
  (ZipArchive Update mode), then zipalign + apksigner with the debug keystore.

.PARAMETER Apk
  Source APK (copied first; the input file is not modified).

.PARAMETER RemovePattern
  Entry-name pattern(s) to delete, e.g. 'assets/assets/audio/banks/*'.

.PARAMETER Out
  Output APK (default: <name>-trim.apk).

.EXAMPLE
  powershell -File tools\android_trim_apk.ps1 -Apk Build\ProjectKeynes.apk `
      -RemovePattern 'assets/assets/audio/banks/*' -Out Build\ProjectKeynes-trim.apk
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Apk,
    [Parameter(Mandatory = $true)][string[]]$RemovePattern,
    [string]$Out = "",
    [string]$Keystore = "$env:USERPROFILE\.android\debug.keystore"
)

$ErrorActionPreference = "Stop"
$buildTools = "C:\Users\hkinghuang\AppData\Local\Android\Sdk\build-tools\35.0.0"
$zipalign = Join-Path $buildTools "zipalign.exe"
$apksigner = Join-Path $buildTools "apksigner.bat"

if (-not (Test-Path $Apk)) { throw "APK not found: $Apk" }
if ($Out -eq "") {
    $Out = Join-Path (Split-Path $Apk -Parent) `
        ([System.IO.Path]::GetFileNameWithoutExtension($Apk) + "-trim.apk")
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$work = Join-Path $env:TEMP ("apk_trim_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$dirty = Join-Path $work "dirty.apk"
Copy-Item $Apk $dirty -Force

$zip = [System.IO.Compression.ZipFile]::Open($dirty, [System.IO.Compression.ZipArchiveMode]::Update)
$removed = 0
$removedBytes = 0
$victims = @()
foreach ($entry in $zip.Entries) {
    foreach ($p in $RemovePattern) {
        if ($entry.FullName -like $p) { $victims += $entry; break }
    }
}
foreach ($v in $victims) {
    $removed++
    $removedBytes += $v.Length
    $v.Delete()
}
$zip.Dispose()
Write-Host ("[trim] removed {0} entries ({1:N1} MB)" -f $removed, ($removedBytes / 1MB))
if ($removed -eq 0) { Write-Host "[trim] nothing matched; aborting"; Remove-Item $work -Recurse -Force; exit 1 }

$aligned = Join-Path $work "aligned.apk"
& $zipalign -p -f 4 $dirty $aligned | Out-Null
if ($LASTEXITCODE -ne 0) { throw "zipalign failed ($LASTEXITCODE)" }

if (Test-Path $Out) { Remove-Item $Out -Force }
& $apksigner sign --ks $Keystore --ks-pass pass:android --ks-key-alias androiddebugkey `
    --key-pass pass:android --out $Out $aligned
if ($LASTEXITCODE -ne 0) { throw "apksigner sign failed ($LASTEXITCODE)" }

& $apksigner verify --verbose $Out | Select-String "v2 scheme|v3 scheme"
Write-Host ("[trim] wrote {0} ({1:N1} MB)" -f $Out, ((Get-Item $Out).Length / 1MB))
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
