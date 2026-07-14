param([string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path)

$ErrorActionPreference = 'Stop'
$project = Join-Path $RepoRoot 'Project/project-keynes'
$buildingDir = Join-Path $project 'data/economy/buildings'
$goodDir = Join-Path $project 'data/goods'
$professionDir = Join-Path $project 'data/economy/professions'
$planDir = Join-Path $project 'data/economy/consumption_plans'
$resourceDir = Join-Path $project 'data/resources'
$failures = [System.Collections.Generic.List[string]]::new()

function Values([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @([regex]::Matches($Text, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
}
function Numbers([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $inside = [regex]::Match($Text, '\((.*)\)').Groups[1].Value
    return @([regex]::Matches($inside, '-?\d+') | ForEach-Object { [long]$_.Value })
}
function Read-Profile([System.IO.FileInfo]$File) {
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $File.FullName) {
        if ($line -match '^([A-Za-z0-9_]+) = (.*)$') { $values[$matches[1]] = $matches[2] }
    }
    return $values
}

$technologyRank = @{}
@('tech.hunting','tech.gathering','tech.stone_knapping','tech.fire_control') | ForEach-Object { $technologyRank[$_] = 0 }
@('tech.pottery','tech.bronze_casting') | ForEach-Object { $technologyRank[$_] = 1 }
@('tech.writing','tech.masonry') | ForEach-Object { $technologyRank[$_] = 2 }
@('tech.manuscript_culture','tech.guild_organization') | ForEach-Object { $technologyRank[$_] = 3 }
@('tech.oceanic_navigation','tech.printing_press') | ForEach-Object { $technologyRank[$_] = 4 }
@('tech.experimental_science','tech.precision_engineering') | ForEach-Object { $technologyRank[$_] = 5 }
@('tech.coke_smelting','tech.steam_power') | ForEach-Object { $technologyRank[$_] = 6 }
@('tech.electrification','tech.radio','tech.electrochemistry') | ForEach-Object { $technologyRank[$_] = 7 }
@('tech.geological_prospecting','tech.advanced_metallurgy','tech.nuclear_fission') | ForEach-Object { $technologyRank[$_] = 8 }
@('tech.digital_computing','tech.networked_computing','tech.legacy_modern_economy') | ForEach-Object { $technologyRank[$_] = 9 }
@('tech.machine_learning','tech.autonomous_systems') | ForEach-Object { $technologyRank[$_] = 10 }

function Rank([string[]]$Tags, [string]$Label) {
    $rank = -1
    foreach ($tag in $Tags) {
        if (-not $tag.StartsWith('tech.')) { continue }
        if (-not $technologyRank.ContainsKey($tag)) {
            $failures.Add("unknown technology tag: $Label -> $tag")
            continue
        }
        $rank = [Math]::Max($rank, [int]$technologyRank[$tag])
    }
    return $rank
}

$resourceIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)
foreach ($file in Get-ChildItem -LiteralPath $resourceDir -Filter '*.tres') {
    $p = Read-Profile $file
    $id = @(Values $p.id)[0]
    if ([string]::IsNullOrWhiteSpace($id) -or -not $resourceIds.Add($id)) {
        $failures.Add("invalid or duplicate natural resource: $($file.Name)")
    }
}

$goods = @{}
foreach ($file in Get-ChildItem -LiteralPath $goodDir -Filter '*.tres') {
    $p = Read-Profile $file
    $id = @(Values $p.id)[0]
    if ([string]::IsNullOrWhiteSpace($id) -or $goods.ContainsKey($id)) {
        $failures.Add("invalid or duplicate good: $($file.Name)")
        continue
    }
    $rank = Rank @(Values $p.technology_tags) "good:$id"
    if ($rank -lt 0) { $failures.Add("good has no executable technology: $id") }
    $goods[$id] = [pscustomobject]@{
        Id = $id
        Category = @(Values $p.category_id)[0]
        Quality = if ($p.ContainsKey('production_quality_level')) { [int]$p.production_quality_level } else { 0 }
        Rank = $rank
        Producers = [System.Collections.Generic.List[string]]::new()
        Consumers = [System.Collections.Generic.List[string]]::new()
        Demanded = $false
    }
}

$professions = @{}
foreach ($file in Get-ChildItem -LiteralPath $professionDir -Filter '*.tres') {
    $p = Read-Profile $file
    $id = @(Values $p.id)[0]
    $rank = Rank @(Values $p.technology_tags) "profession:$id"
    if ($rank -lt 0) { $failures.Add("profession has no executable technology: $id") }
    $professions[$id] = $rank
}

$buildings = @{}
$recipeSignatures = @{}
$familyTiers = @{}
foreach ($file in Get-ChildItem -LiteralPath $buildingDir -Filter '*.tres') {
    $p = Read-Profile $file
    $id = @(Values $p.id)[0]
    if ([string]::IsNullOrWhiteSpace($id) -or $buildings.ContainsKey($id)) {
        $failures.Add("invalid or duplicate building: $($file.Name)")
        continue
    }
    $inputs = @(Values $p.input_good_ids)
    $categories = @(Values $p.input_category_ids)
    $minLevels = @(Numbers $p.input_min_quality_levels)
    $outputs = @(Values $p.output_good_ids)
    $resources = @(Values $p.resource_ids)
    $resourceModes = @(Values $p.resource_interaction_modes)
    $roles = @(Values $p.employee_profession_ids)
    $rank = Rank @(Values $p.technology_tags) "building:$id"
    if ($rank -lt 0) { $failures.Add("building has no executable technology: $id") }
    $owner = @(Values $p.owner_profession_id)[0]
    $kind = @(Values $p.building_kind)[0]
    $family = @(Values $p.upgrade_family_id)[0]
    $tier = if ($p.ContainsKey('upgrade_tier')) { [int]$p.upgrade_tier } else { 0 }
    $building = [pscustomobject]@{
        Id = $id; Rank = $rank; Kind = $kind; Owner = $owner; Inputs = $inputs; Categories = $categories
        MinLevels = $minLevels; Outputs = $outputs; Resources = $resources
        ResourceModes = $resourceModes; Roles = $roles; Family = $family; Tier = $tier
    }
    $buildings[$id] = $building

    if ($kind -notin @('collector','industrial')) {
        $failures.Add("invalid building kind: $id -> $kind")
    }
    if ($outputs.Count -eq 0) { $failures.Add("building has no physical output: $id") }
    if ($resources.Count -ne $resourceModes.Count) {
        $failures.Add("building resource columns mismatch: $id")
    }
    if ($kind -eq 'collector' -and $resources.Count -eq 0) {
        $failures.Add("collector has no natural resource: $id")
    }
    if ($kind -eq 'industrial' -and $resources.Count -gt 0) {
        $failures.Add("industrial building has natural resource edge: $id")
    }
    for ($i = 0; $i -lt $resources.Count; $i++) {
        if (-not $resourceIds.Contains($resources[$i])) {
            $failures.Add("building natural resource missing: $id -> $($resources[$i])")
        }
        if ($i -ge $resourceModes.Count -or $resourceModes[$i] -notin @('extract','capacity')) {
            $failures.Add("invalid building resource mode: $id -> $($resourceModes[$i])")
        }
    }

    if (-not $professions.ContainsKey($owner)) {
        $failures.Add("building owner missing: $id -> $owner")
    } elseif ([int]$professions[$owner] -gt $rank) {
        $failures.Add("building owner unlocks later: $id -> $owner")
    }
    foreach ($role in $roles) {
        if (-not $professions.ContainsKey($role)) {
            $failures.Add("building role missing: $id -> $role")
        } elseif ([int]$professions[$role] -gt $rank) {
            $failures.Add("building role unlocks later: $id -> $role")
        }
    }
    for ($i = 0; $i -lt $inputs.Count; $i++) {
        $good = $inputs[$i]
        if (-not $goods.ContainsKey($good)) {
            $failures.Add("building input missing: $id -> $good")
            continue
        }
        $goods[$good].Consumers.Add($id)
        $category = if ($i -lt $categories.Count) { $categories[$i] } else { '' }
        $minLevel = if ($i -lt $minLevels.Count) { [int]$minLevels[$i] } else { 0 }
        if ($category -eq '' -and $goods[$good].Rank -gt $rank) {
            $failures.Add("building input unlocks later: $id -> $good")
        }
        if ($category -ne '') {
            $candidateFound = $false
            foreach ($candidate in $goods.Values) {
                if ($candidate.Category -eq $category -and $candidate.Quality -ge $minLevel -and
                    $candidate.Rank -le $rank) {
                    $candidate.Consumers.Add($id)
                    $candidateFound = $true
                }
            }
            if (-not $candidateFound) { $failures.Add("no era-compatible category input: $id -> $category") }
        }
    }
    foreach ($good in @(Values $p.construction_good_ids)) {
        if (-not $goods.ContainsKey($good)) { $failures.Add("construction good missing: $id -> $good") }
        else { $goods[$good].Consumers.Add($id) }
    }
    foreach ($good in $outputs) {
        if (-not $goods.ContainsKey($good)) {
            $failures.Add("building output missing: $id -> $good")
        } else {
            $goods[$good].Producers.Add($id)
            if ($goods[$good].Rank -gt $rank) { $failures.Add("building output unlocks later: $id -> $good") }
        }
    }
    if ($owner -eq 'merchant') {
        $validBullion = $inputs.Count -eq 0 -and $roles.Count -eq 0 -and
            $outputs.Count -eq 1 -and $resources.Count -eq 1 -and
            $resourceModes.Count -eq 1 -and $resourceModes[0] -eq 'extract' -and
            (($outputs[0] -eq 'gold' -and $resources[0] -eq 'gold_ore') -or
             ($outputs[0] -eq 'silver' -and $resources[0] -eq 'silver_ore'))
        if (-not $validBullion) { $failures.Add("invalid merchant-owned building: $id") }
    }
    if ([string]::IsNullOrWhiteSpace($family) -and $tier -ne 0) {
        $failures.Add("upgrade tier without family: $id")
    } elseif (-not [string]::IsNullOrWhiteSpace($family)) {
        if ($tier -le 0) { $failures.Add("upgrade family requires positive tier: $id") }
        $key = "${family}:$tier"
        if ($familyTiers.ContainsKey($key)) { $failures.Add("duplicate upgrade family tier: $key") }
        else { $familyTiers[$key] = $id }
    }
    $signature = @(
        @(Values $p.technology_tags) -join ','
        $owner
        $inputs -join ','
        @(Numbers $p.input_quantities_per_day) -join ','
        $outputs -join ','
        @(Numbers $p.output_quantities_per_day) -join ','
        $resources -join ','
        @(Numbers $p.resource_quantities_per_day) -join ','
        $roles -join ','
        @(Numbers $p.employee_slots_per_building) -join ','
    ) -join '|'
    if ($recipeSignatures.ContainsKey($signature)) {
        $failures.Add("duplicate building recipe: $id and $($recipeSignatures[$signature])")
    } else {
        $recipeSignatures[$signature] = $id
    }
}

foreach ($file in Get-ChildItem -LiteralPath $planDir -Filter '*.tres') {
    $p = Read-Profile $file
    foreach ($good in @(Values $p.component_good_ids)) {
        if (-not $goods.ContainsKey($good)) { $failures.Add("need component missing: $($file.Name) -> $good") }
        else { $goods[$good].Demanded = $true }
        if ($good -eq 'electricity') { $failures.Add("household electricity is not cycle-aligned: $($file.Name)") }
    }
}

# Prove that every production chain is reachable from an external physical source.
# Natural-resource edges and zero-goods-input subsistence buildings are valid roots;
# a closed group of goods-only industries that only consumes each other's outputs is not.
$reachableGoods = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)
$changed = $true
while ($changed) {
    $changed = $false
    foreach ($building in $buildings.Values) {
        $inputsReady = $building.Resources.Count -gt 0
        if ($inputsReady) {
            foreach ($output in $building.Outputs) {
                if ($reachableGoods.Add($output)) { $changed = $true }
            }
            continue
        }
        $inputsReady = $true
        for ($i = 0; $i -lt $building.Inputs.Count; $i++) {
            $input = $building.Inputs[$i]
            $category = if ($i -lt $building.Categories.Count) { $building.Categories[$i] } else { '' }
            $minimum = if ($i -lt $building.MinLevels.Count) { [int]$building.MinLevels[$i] } else { 0 }
            if ($category -eq '') {
                if (-not $reachableGoods.Contains($input)) { $inputsReady = $false; break }
                continue
            }
            $candidateReachable = $false
            foreach ($candidate in $goods.Values) {
                if ($candidate.Category -eq $category -and $candidate.Quality -ge $minimum -and
                    $candidate.Rank -le $building.Rank -and $reachableGoods.Contains($candidate.Id)) {
                    $candidateReachable = $true
                    break
                }
            }
            if (-not $candidateReachable) { $inputsReady = $false; break }
        }
        if (-not $inputsReady) { continue }
        foreach ($output in $building.Outputs) {
            if ($reachableGoods.Add($output)) { $changed = $true }
        }
    }
}

foreach ($good in $goods.Values) {
    if ($good.Producers.Count -eq 0 -and ($good.Consumers.Count -gt 0 -or $good.Demanded)) {
        $failures.Add("good has no producer: $($good.Id)")
    }
    if ($good.Producers.Count -gt 0 -and $good.Consumers.Count -eq 0 -and -not $good.Demanded -and
        $good.Id -notin @('gold','silver')) {
        $failures.Add("produced good has no use: $($good.Id)")
    }
    if ($good.Producers.Count -eq 0 -and $good.Consumers.Count -eq 0 -and -not $good.Demanded) {
        $failures.Add("unreferenced good: $($good.Id)")
    }
    if ($good.Producers.Count -gt 0 -and -not $reachableGoods.Contains($good.Id)) {
        $failures.Add("good is trapped in a source-free production loop: $($good.Id)")
    }
}

$expectedFamilies = @{
    'subsistence_food:1'='gathering_ground'; 'subsistence_food:2'='subsistence_farm'
    'subsistence_food:3'='three_field_smallholding'; 'subsistence_food:4'='improved_smallholding'
    'household_cloth:1'='household_weaving_shelter'; 'household_cloth:2'='household_loom'
    'household_cloth:3'='cottage_weaving'; 'household_cloth:4'='improved_domestic_loom'
}
foreach ($key in $expectedFamilies.Keys) {
    if (-not $familyTiers.ContainsKey($key) -or $familyTiers[$key] -ne $expectedFamilies[$key]) {
        $failures.Add("subsistence upgrade tier mismatch: $key")
    }
}

$retired = @('shell_money_station','software_studio','network_data_center','digital_service_exchange',
    'ai_research_lab','orbital_research_program','orbital_technology_transfer',
    'deep_space_telemetry_program','classical_archive','enlightenment_academy',
    'radio_network_depot','robotics_integration_center','ai_battery_works','ai_motor_works')
foreach ($id in $retired) {
    if ($buildings.ContainsKey($id)) { $failures.Add("retired building remains: $id") }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "ERROR: $failure" }
    throw "economy content audit failed: $($failures.Count) issue(s)"
}
Write-Host "Economy content audit passed: $($goods.Count) goods, $($buildings.Count) buildings."
