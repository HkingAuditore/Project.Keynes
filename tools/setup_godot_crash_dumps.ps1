[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdministrator = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdministrator) {
    $quotedScriptPath = '"' + $PSCommandPath.Replace('"', '""') + '"'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath"
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs `
        -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

$dumpFolder = Join-Path $env:LOCALAPPDATA 'ProjectKeynes\CrashDumps'
New-Item -ItemType Directory -Path $dumpFolder -Force | Out-Null

$godotExecutableNames = @(
    'Godot.exe',
    'Godot_v4.6.2-stable_win64.exe',
    'Godot_v4.6.2-stable_win64_console.exe'
)

$werRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
foreach ($executableName in $godotExecutableNames) {
    $key = Join-Path $werRoot $executableName
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -Path $key -Name DumpFolder -Value $dumpFolder `
        -PropertyType ExpandString -Force | Out-Null
    New-ItemProperty -Path $key -Name DumpType -Value 2 `
        -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name DumpCount -Value 10 `
        -PropertyType DWord -Force | Out-Null
}

Write-Host 'ProjectKeynes native crash capture is enabled.' -ForegroundColor Green
Write-Host "Dump folder: $dumpFolder"
Write-Host 'Registered executables:'
$godotExecutableNames | ForEach-Object { Write-Host "  $_" }
