# Orchestrate Stage C2 OFF -> ACTIVE automated tile recording + compare (F8 Effect).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$outRoot = Join-Path $repoRoot 'artifacts\runtime\authority-stage-c\stage-c2-effect-f8-20260912'
New-Item -ItemType Directory -Path $outRoot -Force | Out-Null

function Invoke-C2Mode([string]$Mode) {
    $runId = if ($Mode -eq 'OFF') { 'off' } else { 'active' }
    Write-Host "[c2] starting $Mode -> $outRoot\$runId"
    $result = & (Join-Path $repoRoot 'tools\runtime\Start-AuthorityStageCManual.ps1') `
        -Mode $Mode -Automated `
        -RunId $runId -OutputRoot $outRoot `
        -Seed 20260718 -Width 60 -Height 40 -ForeignCount 3 -Speed 50 `
        -WarmupUntilTick 121 -RecordTicks 100
    $procId = [int]$result.ProcessId
    if ($procId -le 0) {
        throw "No ProcessId for $Mode : $($result | Format-List | Out-String)"
    }
    Write-Host "[c2] waiting procId=$procId mode=$Mode"
    Wait-Process -Id $procId -ErrorAction SilentlyContinue
    $dir = Join-Path $outRoot $runId
    $csv = Join-Path $dir 'tile_data.csv'
    $side = Join-Path $dir 'tile_data.sidecar.json'
    $session = Join-Path $dir 'session.json'
    if (-not (Test-Path -LiteralPath $csv) -or -not (Test-Path -LiteralPath $side)) {
        $godotLog = Join-Path $dir 'godot.log'
        throw "Missing tile recording for $Mode in $dir (session=$(Test-Path $session) log=$(Test-Path $godotLog))"
    }
    Write-Host ("[c2] {0} done csv={1} sidecar={2}" -f $Mode, (Get-Item $csv).Length, (Get-Item $side).Length)
}

Invoke-C2Mode 'OFF'
Invoke-C2Mode 'ACTIVE'

$compareDir = Join-Path $outRoot 'comparison'
Write-Host '[c2] comparing...'
& (Join-Path $repoRoot 'tools\runtime\Compare-AuthorityStageCTiles.ps1') `
    -LeftCsv (Join-Path $outRoot 'off\tile_data.csv') `
    -RightCsv (Join-Path $outRoot 'active\tile_data.csv') `
    -OutputDirectory $compareDir
Write-Host "[c2] compare exit=$LASTEXITCODE"
if (Test-Path -LiteralPath (Join-Path $compareDir 'comparison.md')) {
    Get-Content -LiteralPath (Join-Path $compareDir 'comparison.md') -TotalCount 40
}
Write-Host "C2_ORCH_DONE output=$outRoot"
