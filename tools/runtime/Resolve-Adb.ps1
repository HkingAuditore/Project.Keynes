<#
.SYNOPSIS
Resolves the adb executable used by the Android harnesses.

.DESCRIPTION
Single source of truth for the adb path. Resolution order:
  1. explicit -AdbExe argument
  2. $env:ADB
  3. $env:ANDROID_HOME then $env:ANDROID_SDK_ROOT (platform-tools\adb.exe)
  4. the default SDK location under %LOCALAPPDATA%
  5. adb on PATH

Dot-source this file to get Resolve-Adb, or run it to print the path.
#>
param(
    [Alias('AdbExe')]
    [string]$ResolvedAdbOverride = ''
)

$ErrorActionPreference = 'Stop'

function Resolve-Adb {
    param([string]$AdbExe = '')

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($AdbExe -ne '') { $candidates.Add($AdbExe) }
    if ($env:ADB) { $candidates.Add($env:ADB) }

    foreach ($sdk in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) {
        if ($sdk) { $candidates.Add((Join-Path $sdk 'platform-tools\adb.exe')) }
    }
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'))
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $onPath = Get-Command 'adb' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }

    throw @"
adb not found. Put adb on PATH, or set ADB to adb.exe, or set ANDROID_HOME /
ANDROID_SDK_ROOT to the Android SDK directory.

Tried: $($candidates -join '; ')
"@
}

if ($MyInvocation.InvocationName -ne '.') {
    Resolve-Adb -AdbExe $ResolvedAdbOverride
}
