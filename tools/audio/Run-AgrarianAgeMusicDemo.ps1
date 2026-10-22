[CmdletBinding()]
param([string]$GodotExe)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not $GodotExe) { $GodotExe = $env:GDA_GODOT }
if (-not $GodotExe) {
    $found = Get-Command godot.exe -ErrorAction SilentlyContinue
    if ($found) { $GodotExe = $found.Source }
}
if (-not $GodotExe) {
    $godotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
    $candidate = Join-Path $godotRoot 'Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
    if (Test-Path -LiteralPath $candidate) { $GodotExe = $candidate }
}
if (-not $GodotExe) { throw 'Set GDA_GODOT or supply -GodotExe pointing to Godot 4.6.2.' }
$audDir = Join-Path (Split-Path $repoRoot -Parent) 'tmp\fmod_audition_project'
$audExe = Join-Path $audDir 'PKMusicAudition.exe'
if (Test-Path -LiteralPath $audExe) {
    $srcBanks = Join-Path $repoRoot 'Project\project-keynes\assets\audio\banks\Desktop\*'
    $dstBanks = Join-Path $audDir 'assets\audio\banks\Desktop'
    Copy-Item -Path $srcBanks -Destination $dstBanks -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $audExe -ArgumentList @('--path', $audDir, 'res://tests/audio/agrarian_age_music_demo.tscn') -WorkingDirectory $audDir
    exit 0
}
$project = Join-Path $repoRoot 'Project\project-keynes'
Start-Process -FilePath $GodotExe -ArgumentList @('--path', ('"'+$project+'"'), 'res://tests/audio/agrarian_age_music_demo.tscn') -WorkingDirectory $project
