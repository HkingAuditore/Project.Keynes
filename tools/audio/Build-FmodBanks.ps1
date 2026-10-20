[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
& (Join-Path $PSScriptRoot 'Start-FmodStudio.ps1') -SetupOnly
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Studio setup failed.' }
$cli = Join-Path $repoRoot 'tools\fmod-studio\2.03.15\fmodstudiocl.exe'
$project = Join-Path $repoRoot 'Audio\ProjectKeynes\ProjectKeynes.fspro'
$output = Join-Path $repoRoot 'Project\project-keynes\assets\audio\banks\Desktop'
$diagnostics = & $cli -diagnostic $project 2>&1
if ($LASTEXITCODE -ne 0) {
    $diagnostics | Out-Host
    throw 'FMOD project validation failed; banks were not synchronized.'
}
Write-Host 'FMOD project validation passed.'
& $cli -build -platforms Desktop -export-guids $project
if ($LASTEXITCODE -ne 0) { throw 'FMOD bank build failed.' }
New-Item -ItemType Directory -Force -Path $output | Out-Null
foreach ($name in @('Master.strings.bank','Master.bank','Music.bank','UI.bank')) {
    $source = Join-Path $repoRoot "Audio\ProjectKeynes\Build\Desktop\$name"
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing build output: $name" }
    Copy-Item -LiteralPath $source -Destination (Join-Path $output $name)
}
Write-Host "Banks synchronized: $output"
