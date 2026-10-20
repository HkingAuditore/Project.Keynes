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
$project = Join-Path $repoRoot 'Project\project-keynes'
Start-Process -FilePath $GodotExe -ArgumentList @('--path', ('"'+$project+'"'), 'res://tests/fmod_audio_demo.tscn') -WorkingDirectory $project
