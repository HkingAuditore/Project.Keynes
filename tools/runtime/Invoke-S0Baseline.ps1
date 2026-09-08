<#
.SYNOPSIS
Reproduces the runtime evidence baseline in one command.

.DESCRIPTION
Chains DLL hash -> source commit -> test results -> domain coverage so that any
later measurement can be traced back to the exact binary that produced it.

Steps:
  1. optional rebuild of both shipping DLLs (-Rebuild)
  2. build-manifest.json          (which source revision the DLLs contain)
  3. per-test logs + test-summary.json
  4. mask.txt                     (implemented_domain_mask and completion criteria)
  5. baseline-summary.txt         (one-screen verdict)

Exits non-zero if a DLL is stale or a runtime test regressed. The
dots_completion gate is expected to fail today and is reported separately so it
cannot mask a real regression.

.EXAMPLE
    .\tools\runtime\Invoke-S0Baseline.ps1 -Rebuild
#>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$OutDir = '',
    [string]$GodotExe = '',
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $RepoRoot).Path
if ($OutDir -eq '') { $OutDir = Join-Path $root 'artifacts\runtime\s0-baseline' }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

. (Join-Path $root 'tools\runtime\Resolve-GodotBin.ps1')
$godot = Resolve-GodotBin -GodotExe $GodotExe

$stepFailures = @()

if ($Rebuild) {
    Write-Host '=== [1/4] rebuild ===' -ForegroundColor Cyan
    $running = Get-Process -Name 'Godot*' -ErrorAction SilentlyContinue
    if ($running) {
        Write-Warning "Godot is running (pid $($running.Id -join ', ')). It holds the old DLL in memory; restart the editor after this completes."
    }
    foreach ($target in @('template_debug', 'template_release')) {
        $logName = "build-$($target -replace 'template_', '').log"
        Write-Host "  scons target=$target ..."
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            Push-Location (Join-Path $root 'gdext')
            & scons platform=windows target=$target dev_build=no -j8 2>&1 |
                Tee-Object -FilePath (Join-Path $OutDir $logName) | Out-Null
            $code = $LASTEXITCODE
        }
        finally {
            Pop-Location
            $ErrorActionPreference = $previous
        }
        if ($code -ne 0) { $stepFailures += "build:$target(exit=$code)" }
    }
}

Write-Host '=== [2/4] build manifest ===' -ForegroundColor Cyan
& (Join-Path $root 'tools\runtime\New-BuildManifest.ps1') -RepoRoot $root -OutDir $OutDir
if ($LASTEXITCODE -ne 0) { $stepFailures += 'manifest:stale-dll' }

Write-Host '=== [3/4] runtime tests ===' -ForegroundColor Cyan
& (Join-Path $root 'tools\runtime\Invoke-RuntimeTests.ps1') -RepoRoot $root -OutDir $OutDir -GodotExe $godot
$testsExit = $LASTEXITCODE

Write-Host '=== [4/4] domain coverage ===' -ForegroundColor Cyan
$maskPath = Join-Path $OutDir 'mask.txt'
$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $godot --headless --path (Join-Path $root 'Project\project-keynes') `
        --script 'res://tests/runtime_mask_report.gd' --quit 2>&1 |
        Tee-Object -FilePath $maskPath | Out-Null
}
finally { $ErrorActionPreference = $previous }

# Runtime regressions and the known-failing completion gate are different
# signals; conflating them is what let earlier breakpoints go unnoticed.
$summaryPath = Join-Path $OutDir 'test-summary.json'
$runtimeFailures = @()
$gateFailed = $false
if (Test-Path -LiteralPath $summaryPath) {
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    foreach ($result in $summary.results) {
        if ($result.passed) { continue }
        if ($result.name -eq 'dots_completion_gate') { $gateFailed = $true }
        else { $runtimeFailures += $result.name }
    }
}
if ($runtimeFailures.Count -gt 0) { $stepFailures += "tests:$($runtimeFailures -join ',')" }

$manifest = Get-Content -LiteralPath (Join-Path $OutDir 'build-manifest.json') -Raw | ConvertFrom-Json
$maskLine = (Select-String -LiteralPath $maskPath -Pattern 'implemented_domain_mask =' |
    Select-Object -First 1).Line
$criteriaLine = (Select-String -LiteralPath $maskPath -Pattern 'criteria met:' |
    Select-Object -First 1).Line

$lines = @()
$lines += "runtime S0 baseline"
$lines += "generated : $((Get-Date).ToUniversalTime().ToString('o'))"
$lines += "git HEAD  : $($manifest.git.head) ($($manifest.git.branch)), gdext/src dirty=$($manifest.git.gdext_src_dirty)"
$lines += "ABI       : domain v$($manifest.abi.runtime_domain_abi_version) / pod v$($manifest.abi.runtime_domain_pod_abi_version)"
foreach ($dll in $manifest.dlls) {
    if (-not $dll.present) { $lines += "DLL       : MISSING $($dll.name)"; continue }
    $lines += "DLL       : $($dll.name) sha256=$($dll.sha256) stale=$($dll.stale)"
}
if (Test-Path -LiteralPath $summaryPath) {
    $lines += "tests     : $($summary.passed)/$($summary.total) passed"
}
$lines += "coverage  : $($maskLine.Trim())"
$lines += "criteria  : $($criteriaLine.Trim())"
$lines += "gate      : dots_completion_gate $(if ($gateFailed) { 'FAILING (known GDScript debt, not a runtime regression)' } else { 'passing' })"
$lines += "verdict   : $(if ($stepFailures.Count -eq 0) { 'BASELINE OK' } else { "BASELINE BROKEN -> $($stepFailures -join '; ')" })"

$text = $lines -join "`r`n"
Set-Content -LiteralPath (Join-Path $OutDir 'baseline-summary.txt') -Value $text -Encoding UTF8
Write-Host ''
Write-Host $text

if ($stepFailures.Count -gt 0) { exit 1 }
