<#
.SYNOPSIS
  Replace libgodot_android.so inside an exported APK, re-align and re-sign it.

.DESCRIPTION
  Crash symbolication aid: export a normal debug APK, swap the stripped official
  engine library for a locally built one that keeps debug symbols
  (scons platform=android target=template_debug arch=arm64 strip=no debug_symbols=yes),
  install it, reproduce the crash, then symbolicate the backtrace with
  llvm-addr2line against the SAME .so file.

  Implementation notes:
    * the APK is modified **in place** through ZipArchive Update mode (only the
      engine entry is rewritten) — rebuilding the whole archive by hand produced
      an archive apksigner refused to open ("not a ZIP archive");
    * the .so entry is stored uncompressed (required when extractNativeLibs=false);
    * afterwards zipalign -p 4 and apksigner sign with the local debug keystore.

.PARAMETER Apk
  Source APK (not modified; it is copied first).

.PARAMETER EngineLib
  Replacement libgodot_android.so.

.PARAMETER Abi
  ABI folder inside the APK (default arm64-v8a).

.PARAMETER Out
  Output APK (default: <name>-sym.apk next to the input).

.PARAMETER Keystore
  Debug keystore (default %USERPROFILE%\.android\debug.keystore).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Apk,
    [Parameter(Mandatory = $true)][string]$EngineLib,
    [string]$Abi = "arm64-v8a",
    [string]$Out = "",
    [string]$Keystore = "$env:USERPROFILE\.android\debug.keystore"
)

$ErrorActionPreference = "Stop"
$buildTools = "C:\Users\hkinghuang\AppData\Local\Android\Sdk\build-tools\35.0.0"
$zipalign = Join-Path $buildTools "zipalign.exe"
$apksigner = Join-Path $buildTools "apksigner.bat"

if (-not (Test-Path $Apk)) { throw "APK not found: $Apk" }
if (-not (Test-Path $EngineLib)) { throw "Engine lib not found: $EngineLib" }
if (-not (Test-Path $Keystore)) { throw "Keystore not found: $Keystore" }
if ($Out -eq "") {
    $Out = Join-Path (Split-Path $Apk -Parent) `
        ([System.IO.Path]::GetFileNameWithoutExtension($Apk) + "-sym.apk")
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$entryName = "lib/$Abi/libgodot_android.so"

$work = Join-Path $env:TEMP ("apk_swap_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$dirty = Join-Path $work "dirty.apk"
Copy-Item $Apk $dirty -Force

$zip = [System.IO.Compression.ZipFile]::Open($dirty, [System.IO.Compression.ZipArchiveMode]::Update)
$old = $zip.GetEntry($entryName)
if ($null -eq $old) { $zip.Dispose(); throw "APK has no $entryName" }
$oldSize = $old.Length
$old.Delete()
$newEntry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::NoCompression)
$inStream = [System.IO.File]::OpenRead((Resolve-Path $EngineLib))
$outStream = $newEntry.Open()
$inStream.CopyTo($outStream)
$outStream.Dispose()
$inStream.Dispose()
$zip.Dispose()
Write-Host ("[swap] engine lib {0:N0} -> {1:N0} bytes" -f $oldSize, (Get-Item $EngineLib).Length)

$aligned = Join-Path $work "aligned.apk"
& $zipalign -p -f 4 $dirty $aligned | Out-Null
if ($LASTEXITCODE -ne 0) { throw "zipalign failed ($LASTEXITCODE)" }

if (Test-Path $Out) { Remove-Item $Out -Force }
& $apksigner sign --ks $Keystore --ks-pass pass:android --ks-key-alias androiddebugkey `
    --key-pass pass:android --out $Out $aligned
if ($LASTEXITCODE -ne 0) { throw "apksigner sign failed ($LASTEXITCODE)" }

& $apksigner verify --verbose $Out | Select-String "v2 scheme|v3 scheme"
Write-Host ("[swap] wrote {0} ({1:N0} bytes)" -f $Out, (Get-Item $Out).Length)
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
