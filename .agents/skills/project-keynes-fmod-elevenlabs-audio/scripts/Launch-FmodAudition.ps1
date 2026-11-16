[CmdletBinding()]
param(
    [string]$Scene = "res://tests/audio/stone_age_music_demo.tscn"
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent
$audDir = Join-Path (Split-Path $repoRoot -Parent) 'tmp\fmod_audition_project'
$audExe = Join-Path $audDir 'PKMusicAudition.exe'
$srcProj = Join-Path $repoRoot 'Project\project-keynes'

New-Item -ItemType Directory -Force -Path $audDir | Out-Null

if (-not (Test-Path -LiteralPath $audExe)) {
    $godotRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
    $godotSrc = Join-Path $godotRoot 'Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
    Copy-Item -LiteralPath $godotSrc -Destination $audExe -Force
}

Stop-Process -Name "PKMusicAudition" -Force -ErrorAction SilentlyContinue

foreach ($rel in @("addons\FmodGodot", "assets\audio\banks\Desktop", "scripts\audio", "scripts\ui", "tests\audio")) {
    $dst = Join-Path $audDir $rel
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -Path (Join-Path $srcProj "$rel\*") -Destination $dst -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($relFile in @("scripts\game\game_settings_service.gd", "scripts\ui\ui_audio_feedback.gd")) {
    $dstFile = Join-Path $audDir $relFile
    New-Item -ItemType Directory -Force -Path (Split-Path $dstFile -Parent) | Out-Null
    Copy-Item -LiteralPath (Join-Path $srcProj $relFile) -Destination $dstFile -Force
}

$schedLog = Join-Path (Split-Path $repoRoot -Parent) 'tmp\sched_aud.log'
Remove-Item $schedLog -Force -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute $audExe -Argument "--path `"$audDir`" --log-file `"$schedLog`" $Scene" -WorkingDirectory $audDir
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
Register-ScheduledTask -TaskName "PKMusicAuditionTask" -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName "PKMusicAuditionTask"
Start-Sleep -Seconds 3
Get-Process -Name "PKMusicAudition" -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, SI, Responding
