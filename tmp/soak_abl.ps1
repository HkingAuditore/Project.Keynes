param([string[]]$Variants = @('nocol', 'nores', 'notax'), [int]$Days = 9130, [string]$Prefix = 'abl',
      [string]$Cadence = '', [string[]]$Seeds = @('20260718', '20260719', '3'), [string]$Mode = 'ACTIVE',
      [string]$Suffix = '')
$repo = 'd:\Godot\ProjectKeynes\Project.Keynes'
$script = Join-Path $repo '.cursor\skills\project-keynes-headless-perf\scripts\run_headless_perf.ps1'
foreach ($variant in $Variants) {
    $catalog = if ($variant -eq 'default') { '' } else { Join-Path $repo "tmp\abl_$variant.tres" }
    foreach ($seed in $Seeds) {
        $label = "${Prefix}${variant}_$($Mode.ToLower())_$seed$Suffix"
        $cmd = "Set-Location '$repo'; `$env:PK_COUNTRY_AI_CATALOG='$catalog'; `$env:PK_HEADLESS_CARRYING_DUMP='1'; `$env:PK_ECONOMY_FORCE_CADENCE='$Cadence'; & '$script' -RepoRoot '$repo' -Days $Days -ForeignCount 5 -CountryAi $Mode -Seed $seed -Speed 200 -Label $label *> 'tmp\run_$label.log'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine = "powershell -NoProfile -WindowStyle Hidden -EncodedCommand $encoded" } | Out-Null
    }
}
