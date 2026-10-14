param([string]$Prefix = 'bl', [int]$Days = 9130, [string[]]$Modes = @('PROBE', 'ACTIVE'))
$repo = 'd:\Godot\ProjectKeynes\Project.Keynes'
$script = Join-Path $repo '.cursor\skills\project-keynes-headless-perf\scripts\run_headless_perf.ps1'
foreach ($seed in 20260718, 20260719, 3) {
    foreach ($mode in $Modes) {
        $label = "${Prefix}_$($mode.ToLower())_$seed"
        $cmd = "Set-Location '$repo'; & '$script' -RepoRoot '$repo' -Days $Days -ForeignCount 5 -CountryAi $mode -Seed $seed -Speed 200 -Label $label *> 'tmp\run_$label.log'"
        Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $cmd
    }
}
