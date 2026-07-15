param([string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path)

$ErrorActionPreference = 'Stop'
$project = Join-Path $RepoRoot 'Project/project-keynes'
$buildingDir = Join-Path $project 'data/economy/buildings'
$goodDir = Join-Path $project 'data/goods'
$professionDir = Join-Path $project 'data/economy/professions'
$needDir = Join-Path $project 'data/economy/needs'
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
    foreach ($line in Get-Content -LiteralPath $File.FullName -Encoding UTF8) {
        if ($line -match '^([A-Za-z0-9_]+) = (.*)$') { $values[$matches[1]] = $matches[2] }
    }
    return $values
}

function Assert-Chinese-DisplayName([hashtable]$Profile, [string]$Label) {
    $displayName = if ($Profile.ContainsKey('display_name')) {
        [string](Values $Profile.display_name | Select-Object -First 1)
    } else {
        ''
    }
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $failures.Add("missing or invalid display_name: $Label")
        return
    }
    if ($displayName -notmatch '[\u3400-\u4DBF\u4E00-\u9FFF]') {
        $failures.Add("display_name lacks Chinese characters: $Label -> $displayName")
    }
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
@('tech.digital_computing','tech.networked_computing') | ForEach-Object { $technologyRank[$_] = 9 }
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

function Expected-Tool-Quality([int]$Rank) {
    if ($Rank -le 0) { return 1 }
    if ($Rank -le 3) { return 2 }
    if ($Rank -le 8) { return 3 }
    return 4
}

$resourceIds = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)
foreach ($file in Get-ChildItem -LiteralPath $resourceDir -Filter '*.tres') {
    $p = Read-Profile $file
    $id = @(Values $p.id)[0]
    Assert-Chinese-DisplayName $p "resource:$id"
    if ([string]::IsNullOrWhiteSpace($id) -or -not $resourceIds.Add($id)) {
        $failures.Add("invalid or duplicate natural resource: $($file.Name)")
    }
}
foreach ($id in @('cattle','sheep','pigs','horses','fresh_water','freshwater_fish',
    'uranium_ore','nickel_ore','platinum_ore','lithium','cobalt_ore','natural_graphite')) {
    if ($resourceIds.Contains($id)) { $failures.Add("retired natural resource remains: $id") }
}

$goods = @{}
foreach ($file in Get-ChildItem -LiteralPath $goodDir -Filter '*.tres') {
    $p = Read-Profile $file
    $id = @(Values $p.id)[0]
    Assert-Chinese-DisplayName $p "good:$id"
    if ([string]::IsNullOrWhiteSpace($id) -or $goods.ContainsKey($id)) {
        $failures.Add("invalid or duplicate good: $($file.Name)")
        continue
    }
    $technologyTags = @(Values $p.technology_tags)
    $rank = Rank $technologyTags "good:$id"
    $category = @(Values $p.category_id)[0]
    $substitutionCategories = @(Values $p.substitution_category_ids)
    if ($substitutionCategories.Count -eq 0) { $substitutionCategories = @($category) }
    if ([string]::IsNullOrWhiteSpace($category) -or $category -notin $substitutionCategories -or
        @($substitutionCategories | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
        @($substitutionCategories | Select-Object -Unique).Count -ne $substitutionCategories.Count) {
        $failures.Add("invalid substitution category membership: $id")
    }
    $industry = @($technologyTags | Where-Object { $_.StartsWith('industry.') } |
        ForEach-Object { $_.Substring('industry.'.Length) } | Select-Object -First 1)
    if ($rank -lt 0) { $failures.Add("good has no executable technology: $id") }
    $goods[$id] = [pscustomobject]@{
        Id = $id
        Category = $category
        Categories = $substitutionCategories
        Industry = $(if ($industry.Count -gt 0) { $industry[0] } else { '' })
        Quality = if ($p.ContainsKey('production_quality_level')) { [int]$p.production_quality_level } else { 0 }
        Efficiency = if ($p.ContainsKey('production_efficiency_q16')) { [int]$p.production_efficiency_q16 } else { 65536 }
        DefaultPrice = if ($p.ContainsKey('default_price')) { [long]$p.default_price } else { 10000 }
        BuyFactor = if ($p.ContainsKey('merchant_buy_price_factor_q16')) { [int]$p.merchant_buy_price_factor_q16 } else { 62259 }
        Rank = $rank
        Producers = [System.Collections.Generic.List[string]]::new()
        Consumers = [System.Collections.Generic.List[string]]::new()
        Demanded = $false
    }
}
foreach ($id in @('cattle','sheep','pigs','raw_water','clean_water','beef','mutton','pork')) {
    if ($goods.ContainsKey($id)) { $failures.Add("retired good remains: $id") }
}
foreach ($id in @('bread','prepared_staples','fish','meat','livestock_products','raw_hide',
    'wool','leather','cloth','clothing','tools')) {
    if (-not $goods.ContainsKey($id)) {
        $failures.Add("basic cross-era good missing: $id")
    } elseif ([int]$goods[$id].Rank -ge 9) {
        $failures.Add("basic cross-era good locked to legacy modern: $id")
    }
}
foreach ($id in @('flour','rice_food','corn_food','potato_food','wood_pulp','pig_iron',
    'flax_yarn','cotton_yarn','textile','cut_stone','dressed_masonry',
    'sailcloth','navigation_instruments','medical_isotopes','bronze','manganese_alloy',
    'papyrus','parchment')) {
    if ($goods.ContainsKey($id)) { $failures.Add("redundant chain good remains: $id") }
}
if ($goods.ContainsKey('codices')) { $failures.Add('redundant hand-copied codices good remains') }

$forbiddenBroadCategories = @('primary','forestry','construction','food','textile','chemicals',
    'metals','machinery','consumer','energy')
$singleProducerExceptions = @{
    chipped_stone_tools='one canonical knapping method; redundant hafted shelter retired'
}
$deferredCapitalGoods = @{
    railway_equipment='awaits railway infrastructure or transport-service demand'
    oceanic_vessels='awaits port, fleet, or transport-service demand'
}
foreach ($good in $goods.Values) {
    foreach ($category in $good.Categories) {
        if ($category -in $forbiddenBroadCategories) {
            $failures.Add("industry bucket reused as substitution category: $($good.Id) -> $category")
        }
    }
}
$expectedSubstitutionGroups = @{
    tools=@('bronze_tools','chipped_stone_tools','precision_tools','tools')
    starchy_staple=@('corn_grain','grain','potatoes','rice_grain','wheat_grain')
    cereal_grain=@('corn_grain','grain','rice_grain','wheat_grain')
    baking_grain=@('corn_grain','grain','wheat_grain')
    brewing_feedstock=@('corn_grain','grain','rice_grain','wheat_grain')
    spinnable_fiber=@('cotton_fiber','flax_fiber','synthetic_fiber','wool')
    natural_spinnable_fiber=@('cotton_fiber','flax_fiber','wool')
    guild_textile_fiber=@('flax_fiber','wool')
    rag_paper_fiber=@('cloth','cotton_fiber','flax_fiber')
    precious_metal=@('gold','silver')
    elastomer=@('latex','synthetic_rubber')
    prime_mover=@('electric_motor','engines','steam_engines')
    industrial_prime_mover=@('electric_motor','steam_engines')
    agricultural_prime_mover=@('engines','steam_engines')
    ferrous_stock=@('stainless_steel','steel')
    structural_metal=@('aluminum','stainless_steel','steel')
    processor_component=@('advanced_chips','semiconductors')
}
foreach ($categoryId in $expectedSubstitutionGroups.Keys) {
    $actual = @($goods.Values | Where-Object { $categoryId -in $_.Categories } |
        ForEach-Object { $_.Id } | Sort-Object)
    $expected = @($expectedSubstitutionGroups[$categoryId] | Sort-Object)
    if (($actual -join ',') -ne ($expected -join ',')) {
        $failures.Add("substitution category membership drift: $categoryId")
    }
}
if ($goods.ContainsKey('footwear') -and $goods.ContainsKey('cloth') -and
    @($goods['footwear'].Categories | Where-Object {
        $_ -in $goods['cloth'].Categories -or $_ -in $goods['clothing'].Categories -or
        $_ -in $goods['raw_hide'].Categories }).Count -gt 0) {
    $failures.Add('footwear is incorrectly grouped with fabric, garments, or raw hide')
}
if ($goods.ContainsKey('edible_oil') -and $goods.ContainsKey('lubricants') -and
    @($goods['edible_oil'].Categories | Where-Object {
        $_ -in $goods['lubricants'].Categories }).Count -gt 0) {
    $failures.Add('food oil is incorrectly grouped with industrial lubricants')
}

$expectedNeedNames = [ordered]@{
    staple_food='食品'; protein='食品'; produce='食品'; clothing='衣着'
    housing='居住维护'; household_goods='家庭用品'; hygiene='清洁卫生'; healthcare='医疗保健'
    home_energy='家庭能源'; transport='个人交通'; communication='通信'
    education_culture='教育与文化'; recreation='休闲娱乐'; durable_goods='耐用消费品'
    work_equipment='职业装备'; luxury='奢侈消费'; status_goods='身份消费'
}
$needs = @{}
foreach ($file in Get-ChildItem -LiteralPath $needDir -Filter '*.tres') {
    $p = Read-Profile $file
    $id = @(Values $p.id)[0]
    Assert-Chinese-DisplayName $p "need:$id"
    if ([string]::IsNullOrWhiteSpace($id) -or $needs.ContainsKey($id)) {
        $failures.Add("invalid or duplicate need: $($file.Name)")
        continue
    }
    $displayName = @(Values $p.display_name)[0]
    if (-not $expectedNeedNames.Contains($id) -or $displayName -ne $expectedNeedNames[$id]) {
        $failures.Add("need display name drift: $id -> $displayName")
    }
    $needs[$id] = $true
}
if ($needs.Count -ne $expectedNeedNames.Count) {
    $failures.Add("expected $($expectedNeedNames.Count) household needs, found $($needs.Count)")
}

$expectedPlanProfessions = @{
    owner_household=@('landlord','industrialist')
    merchant_household=@('merchant')
    survival_household=@('subsistence_farmer','forager','enslaved_laborer','serf','apprentice')
    agrarian_household=@('agricultural_worker','pastoralist','hunter','fisher','forestry_worker',
        'tenant_farmer','indentured_laborer')
    extractive_household=@('miner','petroleum_worker')
    industrial_worker_household=@('worker','construction_worker','industrial_worker','transport_worker')
    artisan_household=@('artisan','metallurgist','guild_master','journeyman')
    technical_household=@('machinist','technician','engineer','chemist','electrician','manager','researcher')
}
$expectedProfessionPlans = @{}
foreach ($planId in $expectedPlanProfessions.Keys) {
    foreach ($professionId in $expectedPlanProfessions[$planId]) {
        $expectedProfessionPlans[$professionId] = $planId
    }
}

$professions = @{}
$professionPlans = @{}
foreach ($file in Get-ChildItem -LiteralPath $professionDir -Filter '*.tres') {
    $p = Read-Profile $file
    $id = @(Values $p.id)[0]
    Assert-Chinese-DisplayName $p "profession:$id"
    $rank = Rank @(Values $p.technology_tags) "profession:$id"
    if ($rank -lt 0) { $failures.Add("profession has no executable technology: $id") }
    $planId = @(Values $p.default_consumption_plan_id)[0]
    if (-not $expectedProfessionPlans.ContainsKey($id) -or
        $expectedProfessionPlans[$id] -ne $planId) {
        $failures.Add("profession consumption plan drift: $id -> $planId")
    }
    $professions[$id] = $rank
    $professionPlans[$id] = $planId
}
if ($professionPlans.Count -ne 32) {
    $failures.Add("expected 32 profession consumption mappings, found $($professionPlans.Count)")
}

$buildings = @{}
$recipeSignatures = @{}
$familyTiers = @{}
$eraBuildingCounts = @{}
foreach ($file in Get-ChildItem -LiteralPath $buildingDir -Filter '*.tres') {
    $p = Read-Profile $file
    $id = @(Values $p.id)[0]
    Assert-Chinese-DisplayName $p "building:$id"
    if ([string]::IsNullOrWhiteSpace($id) -or $buildings.ContainsKey($id)) {
        $failures.Add("invalid or duplicate building: $($file.Name)")
        continue
    }
    $inputs = @(Values $p.input_good_ids)
    $categories = @(Values $p.input_category_ids)
    $minLevels = @(Numbers $p.input_min_quality_levels)
    $candidateOffsets = @(Numbers $p.input_candidate_offsets)
    $candidateGoodIds = @(Values $p.input_candidate_good_ids)
    $candidateEfficiencies = @(Numbers $p.input_candidate_efficiency_q16)
    $outputs = @(Values $p.output_good_ids)
    $inputQuantities = @(Numbers $p.input_quantities_per_day)
    $outputQuantities = @(Numbers $p.output_quantities_per_day)
    $resources = @(Values $p.resource_ids)
    $resourceModes = @(Values $p.resource_interaction_modes)
    $roles = @(Values $p.employee_profession_ids)
    $roleSlots = @(Numbers $p.employee_slots_per_building)
    $roleWages = @(Numbers $p.employee_reference_wages_per_day)
    $rank = Rank @(Values $p.technology_tags) "building:$id"
    if ($rank -lt 0) { $failures.Add("building has no executable technology: $id") }
    if (-not $eraBuildingCounts.ContainsKey($rank)) { $eraBuildingCounts[$rank] = 0 }
    $eraBuildingCounts[$rank] = [int]$eraBuildingCounts[$rank] + 1
    $owner = @(Values $p.owner_profession_id)[0]
    $kind = @(Values $p.building_kind)[0]
    $family = @(Values $p.upgrade_family_id)[0]
    $tier = if ($p.ContainsKey('upgrade_tier')) { [int]$p.upgrade_tier } else { 0 }
    $candidateSlots = @()
    $hasExplicitCandidates = $candidateOffsets.Count -gt 1 -or $candidateGoodIds.Count -gt 0 -or
        $candidateEfficiencies.Count -gt 0
    if ($hasExplicitCandidates -and ($candidateOffsets.Count -ne $inputs.Count + 1 -or
        $candidateOffsets[0] -ne 0 -or $candidateOffsets[-1] -ne $candidateGoodIds.Count -or
        $candidateGoodIds.Count -ne $candidateEfficiencies.Count)) {
        $failures.Add("building explicit candidate columns mismatch: $id")
    }
    for ($inputIndex = 0; $inputIndex -lt $inputs.Count; $inputIndex++) {
        $slot = @()
        if ($hasExplicitCandidates -and $candidateOffsets.Count -eq $inputs.Count + 1) {
            $begin = [int]$candidateOffsets[$inputIndex]; $end = [int]$candidateOffsets[$inputIndex + 1]
            if ($begin -lt 0 -or $end -lt $begin -or $end -gt $candidateGoodIds.Count) {
                $failures.Add("building explicit candidate offsets invalid: $id")
            } else {
                $seen = @{}
                for ($candidateIndex = $begin; $candidateIndex -lt $end; $candidateIndex++) {
                    $candidateId = $candidateGoodIds[$candidateIndex]
                    $efficiency = [long]$candidateEfficiencies[$candidateIndex]
                    if (-not $goods.ContainsKey($candidateId) -or $seen.ContainsKey($candidateId) -or
                        $efficiency -le 0 -or $efficiency -gt 262144) {
                        $failures.Add("invalid explicit input candidate: $id -> $candidateId")
                        continue
                    }
                    $seen[$candidateId] = $true
                    $slot += [pscustomobject]@{ Id=$candidateId; Efficiency=$efficiency }
                }
                if ($slot.Count -gt 0 -and $categories.Count -gt $inputIndex -and
                    -not [string]::IsNullOrWhiteSpace($categories[$inputIndex])) {
                    $failures.Add("explicit candidate and category overlap: $id input $inputIndex")
                }
                if ($slot.Count -gt 0 -and $inputs[$inputIndex] -notin @($slot | ForEach-Object { $_.Id })) {
                    $failures.Add("preferred input missing from explicit candidates: $id -> $($inputs[$inputIndex])")
                }
            }
        }
        $candidateSlots += ,$slot
    }
    $building = [pscustomobject]@{
        Id = $id; Rank = $rank; Kind = $kind; Owner = $owner; Inputs = $inputs; Categories = $categories
        MinLevels = $minLevels; Outputs = $outputs; Resources = $resources
        ResourceModes = $resourceModes; Roles = $roles; Family = $family; Tier = $tier
        CandidateSlots = $candidateSlots; InputQuantities = $inputQuantities
        OutputQuantities = $outputQuantities; RoleSlots = $roleSlots; RoleWages = $roleWages
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
        $slotCandidates = if ($i -lt $candidateSlots.Count) { @($candidateSlots[$i]) } else { @() }
        $category = if ($i -lt $categories.Count) { $categories[$i] } else { '' }
        $minLevel = if ($i -lt $minLevels.Count) { [int]$minLevels[$i] } else { 0 }
        if ($category -eq 'tools' -and $minLevel -ne (Expected-Tool-Quality $rank)) {
            $failures.Add("tool quality gate does not match building era: $id -> $minLevel")
        }
        $exactToolQuality = @{
            chipped_stone_tools=1; bronze_tools=2; tools=3; precision_tools=4
        }
        if ($category -eq '' -and $exactToolQuality.ContainsKey($good) -and
            [int]$exactToolQuality[$good] -lt (Expected-Tool-Quality $rank)) {
            $failures.Add("obsolete exact tool survives into later-era recipe: $id -> $good")
        }
        if ($slotCandidates.Count -gt 0) {
            $eraCandidateFound = $false
            foreach ($candidate in $slotCandidates) {
                $goods[$candidate.Id].Consumers.Add($id)
                if ($goods[$candidate.Id].Rank -le $rank) { $eraCandidateFound = $true }
            }
            if (-not $eraCandidateFound) { $failures.Add("no era-compatible explicit input: $id -> $good") }
        } elseif ($category -eq '' -and $goods[$good].Rank -gt $rank) {
            $failures.Add("building input unlocks later: $id -> $good")
        } elseif ($category -eq '') {
            $goods[$good].Consumers.Add($id)
        } else {
            $candidateFound = $false
            foreach ($candidate in $goods.Values) {
                if ($category -in $candidate.Categories -and $candidate.Quality -ge $minLevel -and
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
        $validBullion = $outputs.Count -eq 1 -and $resources.Count -eq 1 -and
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
    $inputCost = [double]0
    for ($i = 0; $i -lt $inputs.Count; $i++) {
        $quantity = if ($i -lt $inputQuantities.Count) { [double]$inputQuantities[$i] } else { 0.0 }
        $unitCost = [double]::PositiveInfinity
        $slotCandidates = if ($i -lt $candidateSlots.Count) { @($candidateSlots[$i]) } else { @() }
        if ($slotCandidates.Count -gt 0) {
            foreach ($candidate in $slotCandidates) {
                if ($goods[$candidate.Id].Rank -gt $rank) { continue }
                $unitCost = [Math]::Min($unitCost,
                    [double]$goods[$candidate.Id].DefaultPrice * 65536.0 / [double]$candidate.Efficiency)
            }
        } elseif ($i -lt $categories.Count -and -not [string]::IsNullOrWhiteSpace($categories[$i])) {
            $minimum = if ($i -lt $minLevels.Count) { [int]$minLevels[$i] } else { 0 }
            foreach ($candidate in $goods.Values) {
                if ($categories[$i] -in $candidate.Categories -and $candidate.Quality -ge $minimum -and
                    $candidate.Rank -le $rank) {
                    $unitCost = [Math]::Min($unitCost,
                        [double]$candidate.DefaultPrice * 65536.0 / [double]$candidate.Efficiency)
                }
            }
        } else { $unitCost = [double]$goods[$inputs[$i]].DefaultPrice }
        if ([double]::IsPositiveInfinity($unitCost)) { $unitCost = 0 }
        $inputCost += $quantity * $unitCost / 1000.0
    }
    $wageCost = [double]0
    for ($i = 0; $i -lt [Math]::Min($roleSlots.Count, $roleWages.Count); $i++) {
        $wageCost += [double]$roleSlots[$i] * [double]$roleWages[$i]
    }
    $revenue = [double]0
    for ($i = 0; $i -lt [Math]::Min($outputs.Count, $outputQuantities.Count); $i++) {
        if (-not $goods.ContainsKey($outputs[$i])) { continue }
        $revenue += [double]$outputQuantities[$i] * [double]$goods[$outputs[$i]].DefaultPrice / 1000.0 *
            [double]$goods[$outputs[$i]].BuyFactor / 65536.0
    }
    $operatingCost = $inputCost + $wageCost
    if ($operatingCost -gt 0 -and $outputs -notcontains 'gold' -and $outputs -notcontains 'silver') {
        if ($revenue -le $operatingCost) {
            $failures.Add("building loses money at default prices: $id revenue=$([Math]::Round($revenue)) cost=$([Math]::Round($operatingCost))")
        } else {
            $margin = ($revenue - $operatingCost) / $revenue
            $luxuryOutput = @($outputs | Where-Object { $_ -in @('jewelry','fine_clothing','fine_furniture') }).Count -gt 0
            $minimumMargin = if ($luxuryOutput) { 0.15 } else { 0.05 }
            $maximumMargin = if ($luxuryOutput) { 0.30 } else { 0.30 }
            if ($margin -lt $minimumMargin -or $margin -gt $maximumMargin) {
                $failures.Add("building default margin out of band: $id -> $([Math]::Round($margin * 100, 1))%")
            }
        }
    }
    if ($id -in @('cattle_collector','sheep_collector','pigs_collector','horses_collector',
        'fresh_water_collector','freshwater_fish_collector','clean_water_plant',
        'beef_plant','mutton_plant','pork_plant','wild_game_collector')) {
        $failures.Add("retired building remains: $id")
    }
    if ($id -in @('bread_plant','bakery','rice_food_plant','rice_kitchen',
        'corn_food_plant','corn_grinding_house','potato_food_plant','potato_kitchen',
        'beverages_plant')) {
        foreach ($input in $inputs) {
            if ($input -in @('raw_water','clean_water')) {
                $failures.Add("food recipe still depends on water chain: $id -> $input")
            }
        }
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

# Operating structure is part of the production method, not decorative metadata.
# Large factories must show capital equipment and differentiated labor, while
# small workshops and institutional centers may remain intentionally compact.
$stoneOwnerPolicy = @{
    communal_hearth='forager'; flint_quarry='forager'; gathering_ground='forager'
    household_weaving_shelter='artisan'; knapping_workshop='artisan'; lumber_plant='artisan'
    marine_fish_collector='fisher'; placer_gold_working='merchant'
    stone_age_hunting_camp='hunter'; stone_collector='forager'
    surface_silver_working='merchant'; timber_collector='forager'
}
$preindustrialCoercedLabor = @(
    'early_clay_pit','early_copper_mine','early_tin_mine','classical_silica_pit'
)
$mineralResources = @(
    'bauxite','clay','coal','copper_ore','flint','gold_ore','iron_ore','lead_ore',
    'limestone','manganese_ore','phosphate_rock','rare_earth','salt','saltpeter',
    'silica_sand','silver_ore','stone','sulfur','tin_ore','zinc_ore'
)
$smallFacilityExceptions = @('digital_computer_workshop','nuclear_medicine_center')
foreach ($building in $buildings.Values) {
    $employeeTotal = [long](($building.RoleSlots | Measure-Object -Sum).Sum)
    if ($building.Rank -eq 0) {
        if ($building.Roles.Count -ne 0) {
            $failures.Add("stone-age building must be owner-operated: $($building.Id)")
        }
        if (-not $stoneOwnerPolicy.ContainsKey($building.Id)) {
            $failures.Add("stone-age building lacks reviewed owner policy: $($building.Id)")
        } elseif ($building.Owner -ne $stoneOwnerPolicy[$building.Id]) {
            $failures.Add("stone-age building owner mismatch: $($building.Id) -> $($building.Owner)")
        }
    }
    if ($building.Rank -ge 1 -and $building.Rank -lt 6 -and
        $building.Kind -eq 'collector' -and $building.Id -notin $preindustrialCoercedLabor) {
        $expectedOccupation = ''
        if ($building.Id -eq 'method_gathering_ground_r1') { $expectedOccupation = 'forager' }
        elseif ($building.Resources -contains 'wild_game') { $expectedOccupation = 'hunter' }
        elseif ($building.Resources -contains 'marine_fish') { $expectedOccupation = 'fisher' }
        elseif ($building.Resources -contains 'timber') { $expectedOccupation = 'forestry_worker' }
        elseif (@($building.Resources | Where-Object { $_ -in $mineralResources }).Count -gt 0) {
            $expectedOccupation = 'miner'
        }
        if ($expectedOccupation -ne '' -and
            ($building.Owner -ne $expectedOccupation -or
                $building.Roles -notcontains $expectedOccupation)) {
            $failures.Add("preindustrial collector owner/worker mismatch: $($building.Id) expected=$expectedOccupation owner=$($building.Owner) roles=$($building.Roles -join ',')")
        }
    }
    $factoryLike = $building.Kind -eq 'industrial' -and $building.Rank -ge 6 -and
        $building.Id -notin $smallFacilityExceptions
    if ($factoryLike) {
        $minimumEmployees = switch ($building.Rank) {
            6 { 22 } 7 { 35 } 8 { 40 } 9 { 50 } default { 58 }
        }
        if ($employeeTotal -lt $minimumEmployees) {
            $failures.Add("factory employment scale too small: $($building.Id) rank=$($building.Rank) employees=$employeeTotal")
        }
        if ($building.Owner -ne 'industrialist') {
            $failures.Add("factory must be industrialist-owned: $($building.Id) -> $($building.Owner)")
        }
        if ($building.Outputs -notcontains 'tools' -and
            $building.Inputs -notcontains 'tools' -and $building.Inputs -notcontains 'precision_tools') {
            $failures.Add("factory lacks maintenance tooling: $($building.Id)")
        }
        if ($building.Rank -ge 7 -and $building.Outputs -notcontains 'electricity' -and
            $building.Inputs -notcontains 'electricity') {
            $failures.Add("electric-era factory lacks electricity: $($building.Id)")
        }
        if ($building.Rank -ge 7 -and $building.Outputs -notcontains 'electricity' -and
            $building.Outputs -notcontains 'industrial_machinery' -and
            $building.Inputs -notcontains 'industrial_machinery') {
            $failures.Add("mature factory lacks industrial machinery: $($building.Id)")
        }
        if ($building.Rank -ge 9 -and
            ($building.Roles -notcontains 'technician' -or $building.Roles -notcontains 'engineer')) {
            $failures.Add("digital factory lacks technical role differentiation: $($building.Id)")
        }
    }
    $landBasedAgriculture = $building.Kind -eq 'collector' -and
        @($building.Resources | Where-Object { $_ -in @('arable_land','paddy_land','plantation_land','pasture') }).Count -gt 0 -and
        @($building.Outputs | Where-Object { $_ -in @(
            'grain','wheat_grain','rice_grain','corn_grain','potatoes','vegetables',
            'flax_fiber','cotton_fiber','spices','natural_rubber','medicinal_herbs',
            'livestock_products','horses'
        ) }).Count -gt 0
    $commercialAgriculturalMethod = $landBasedAgriculture -and
        ($building.Id -like 'method_*' -or
            $building.Id -in @('mechanized_farm','intensive_farm','ranching_station'))
    if ($landBasedAgriculture -and $building.Owner -eq 'industrialist') {
        $failures.Add("land-based agriculture must not default to industrialist ownership: $($building.Id)")
    }
    if ($commercialAgriculturalMethod -and $building.Rank -lt 6 -and
        ($building.Owner -ne 'landlord' -or $building.Roles -notcontains 'tenant_farmer')) {
        $failures.Add("preindustrial commercial farm has wrong land relation: $($building.Id)")
    }
    if ($commercialAgriculturalMethod -and $building.Rank -ge 6 -and
        ($building.Owner -ne 'landlord' -or $building.Roles -notcontains 'agricultural_worker' -or
            $building.Roles -notcontains 'manager')) {
        $failures.Add("mechanized farm must retain landlord ownership and employ agricultural workers plus management: $($building.Id)")
    }
}

$cabinetmaker = $buildings['cabinetmaker_workshop']
$guildFurniture = $buildings['guild_hall']
if ($null -eq $cabinetmaker -or $cabinetmaker.Owner -ne 'guild_master' -or
    $cabinetmaker.Inputs -notcontains 'tools' -or
    [long](($cabinetmaker.RoleSlots | Measure-Object -Sum).Sum) -le
        [long](($guildFurniture.RoleSlots | Measure-Object -Sum).Sum)) {
    $failures.Add('fine cabinetmaking must use tools and a larger guild workforce than the basic furniture workshop')
}
$computerFactory = $buildings['computers_plant']
$plasticsFactory = $buildings['plastics_plant']
if ($null -eq $computerFactory -or $null -eq $plasticsFactory -or
    ($computerFactory.Roles -join ',') -eq ($plasticsFactory.Roles -join ',') -or
    [long](($computerFactory.RoleSlots | Measure-Object -Sum).Sum) -le
        [long](($plasticsFactory.RoleSlots | Measure-Object -Sum).Sum)) {
    $failures.Add('computer and plastics factories must differ in technical roles and employment scale')
}

# Production-method counts are not a progression target: minimum quotas encouraged
# negligible industries to acquire fake late-era upgrades. Every era must still add
# something, while the generator's lifecycle table decides which chains persist.
for ($eraRank = 0; $eraRank -le 10; $eraRank++) {
    if (-not $eraBuildingCounts.ContainsKey($eraRank) -or [int]$eraBuildingCounts[$eraRank] -le 0) {
        $failures.Add("era has no new production methods: $eraRank")
    }
}
if ($buildings.Count -gt 270) {
    $failures.Add("production-method catalog exceeds complexity budget: $($buildings.Count) > 270")
}
$monasticOutputs = if ($buildings.ContainsKey('monastic_scriptorium')) {
    $buildings['monastic_scriptorium'].Outputs -join ','
} else { '<missing>' }
if ($monasticOutputs -ne 'manuscripts') {
    $failures.Add('monastic scriptorium must deepen the shared manuscripts good')
}
if (-not $buildings.ContainsKey('classical_scriptorium') -or
    ($buildings['classical_scriptorium'].Inputs -join ',') -ne 'gathered_plants') {
    $failures.Add('classical scriptorium must consume gathered plants directly')
}
if (-not $buildings.ContainsKey('monastic_scriptorium') -or
    ($buildings['monastic_scriptorium'].Inputs -join ',') -ne 'raw_hide') {
    $failures.Add('monastic scriptorium must consume raw hide directly')
}
if (-not $buildings.ContainsKey('processed_food_plant') -or
    'edible_oil' -notin $buildings['processed_food_plant'].Inputs) {
    $failures.Add('processed food must provide a material downstream for edible oil')
}
if ($buildings.ContainsKey('footwear_plant')) {
    $upperSlot = @($buildings['footwear_plant'].CandidateSlots[0] |
        ForEach-Object { $_.Id } | Sort-Object)
    $soleSlot = @($buildings['footwear_plant'].CandidateSlots[1] |
        ForEach-Object { $_.Id } | Sort-Object)
    if (($upperSlot -join ',') -ne 'cloth,leather') {
        $failures.Add('footwear upper-material candidates must be cloth or leather')
    }
    if (($soleSlot -join ',') -ne 'latex,synthetic_rubber') {
        $failures.Add('footwear sole-material candidates must be natural or synthetic rubber')
    }
} else {
    $failures.Add('footwear plant missing')
}
foreach ($candidateExpectation in @(
    @('packaging_plant',0,'aluminum,glass,paper,plastics,steel'),
    @('furniture_plant',1,'cloth,leather'),
    @('cabinetmaker_workshop',1,'cloth,leather'),
    @('fine_furniture_plant',1,'cloth,leather'),
    @('soap_plant',0,'edible_oil,livestock_products'),
    @('tools_plant',0,'stainless_steel,steel'),
    @('tools_plant',1,'lumber,plastics'),
    @('machine_parts_plant',0,'aluminum,stainless_steel,steel'),
    @('machine_parts_plant',1,'edible_oil,lubricants'),
    @('wire_plant',0,'aluminum,copper'),
    @('batteries_plant',0,'lead,rare_earth_metals'),
    @('electric_motor_plant',0,'aluminum,copper'),
    @('electric_motor_plant',1,'aluminum,steel'),
    @('construction_components_plant',1,'aluminum,stainless_steel,steel'),
    @('copper_plant',1,'coal,coke'), @('tin_plant',1,'coal,coke'),
    @('lead_plant',1,'coal,coke'), @('zinc_plant',1,'coal,coke'),
    @('lubricants_plant',0,'crude_oil,petrochemicals'),
    @('household_appliances_plant',1,'aluminum,stainless_steel,steel'),
    @('insulated_cable_plant',1,'plastics,synthetic_rubber')
)) {
    $buildingId = $candidateExpectation[0]
    $slotIndex = [int]$candidateExpectation[1]
    $expectedIds = $candidateExpectation[2]
    if (-not $buildings.ContainsKey($buildingId) -or
        $buildings[$buildingId].CandidateSlots.Count -le $slotIndex) {
        $failures.Add("contextual candidate slot missing: ${buildingId}[$slotIndex]")
        continue
    }
    $actualIds = @($buildings[$buildingId].CandidateSlots[$slotIndex] |
        ForEach-Object { $_.Id } | Sort-Object) -join ','
    if ($actualIds -ne $expectedIds) {
        $failures.Add("contextual candidate slot drift: ${buildingId}[$slotIndex] -> $actualIds")
    }
}
if (-not $buildings.ContainsKey('insulated_cable_plant') -or
    $buildings['insulated_cable_plant'].Inputs.Count -lt 2 -or
    ($buildings['insulated_cable_plant'].Inputs[0..1] -join ',') -ne 'wire,plastics') {
    $failures.Add('insulated cable must consume conductor wire plus an insulation material')
}
if ($buildings.ContainsKey('hafted_stone_tool_shelter')) {
    $failures.Add('redundant hafted stone-tool shelter remains')
}
if (-not $buildings.ContainsKey('method_stone_age_hunting_camp_r4') -or
    ($buildings['method_stone_age_hunting_camp_r4'].Inputs -join ',') -ne 'tools' -or
    $buildings['method_stone_age_hunting_camp_r4'].Categories[0] -ne 'tools' -or
    [int]$buildings['method_stone_age_hunting_camp_r4'].MinLevels[0] -ne 3) {
    $failures.Add('commercial hunting must replace stone tools with era-gated metal tools')
}
foreach ($inheritedCandidate in @(
    @('method_packaging_plant_r7',0,'aluminum,glass,paper,plastics,steel'),
    @('method_wire_plant_r10',0,'aluminum,copper'),
    @('method_batteries_plant_r10',0,'lead,rare_earth_metals'),
    @('method_machine_parts_plant_r9',1,'edible_oil,lubricants'),
    @('method_insulated_cable_plant_r10',1,'plastics,synthetic_rubber')
)) {
    $buildingId = $inheritedCandidate[0]; $slotIndex = [int]$inheritedCandidate[1]
    $expectedIds = $inheritedCandidate[2]
    if (-not $buildings.ContainsKey($buildingId) -or
        $buildings[$buildingId].CandidateSlots.Count -le $slotIndex) {
        $failures.Add("upgraded method loses candidate slot: ${buildingId}[$slotIndex]")
        continue
    }
    $actualIds = @($buildings[$buildingId].CandidateSlots[$slotIndex] |
        ForEach-Object { $_.Id } | Sort-Object) -join ','
    if ($actualIds -ne $expectedIds) {
        $failures.Add("upgraded method candidate drift: ${buildingId}[$slotIndex] -> $actualIds")
    }
}
foreach ($progression in @(
    @('early_clay_pit','clay_collector'),
    @('early_copper_mine','copper_ore_collector'),
    @('early_tin_mine','tin_ore_collector'),
    @('classical_silica_pit','silica_sand_collector'),
    @('classical_glass_kiln','glass_plant'),
    @('steam_steel_works','steel_plant'),
    @('steam_rail_works','railway_equipment_plant')
)) {
    $earlierId = $progression[0]; $laterId = $progression[1]
    if (-not $buildings.ContainsKey($earlierId) -or -not $buildings.ContainsKey($laterId) -or
        [int]$buildings[$earlierId].Rank -ge [int]$buildings[$laterId].Rank) {
        $failures.Add("duplicate methods do not form an era progression: $earlierId -> $laterId")
    }
}
foreach ($requiredMethod in @(
    'method_gathering_ground_r1','method_flint_quarry_r1',
    'method_stone_age_hunting_camp_r4','method_pottery_kiln_r3',
    'method_spice_plants_collector_r6','method_medicinal_herbs_collector_r7',
    'method_edible_oil_plant_r6','method_soap_plant_r6',
    'method_packaging_plant_r7','method_printed_materials_plant_r7',
    'method_oceanic_shipyard_r7')) {
    if (-not $buildings.ContainsKey($requiredMethod)) {
        $failures.Add("bounded industry is missing its terminal production method: $requiredMethod")
    }
}
foreach ($forbiddenMethod in @(
    'method_gathering_ground_r8','method_flint_quarry_r8','method_stone_age_hunting_camp_r8',
    'method_pottery_kiln_r8','method_spice_plants_collector_r8',
    'method_medicinal_herbs_collector_r8','method_edible_oil_plant_r8',
    'method_soap_plant_r8','method_packaging_plant_r8','method_printed_materials_plant_r8',
    'method_landed_estate_r8','method_potato_collector_r8','method_cotton_collector_r8',
    'method_rubber_tree_collector_r8','method_oceanic_shipyard_r8',
    'method_bricks_plant_r8','method_lime_plant_r8','method_limestone_collector_r8')) {
    if ($buildings.ContainsKey($forbiddenMethod)) {
        $failures.Add("bounded industry leaks into negligible late-era method: $forbiddenMethod")
    }
}
if ($buildings.ContainsKey('industrial_machinery_plant')) {
    $slot = @($buildings['industrial_machinery_plant'].CandidateSlots[1] |
        ForEach-Object { $_.Id } | Sort-Object)
    if (($slot -join ',') -ne 'electric_motor,steam_engines') {
        $failures.Add('industrial machinery prime-mover subset drift')
    }
}
if ($buildings.ContainsKey('agricultural_machinery_plant')) {
    $slot = @($buildings['agricultural_machinery_plant'].CandidateSlots[1] |
        ForEach-Object { $_.Id } | Sort-Object)
    if (($slot -join ',') -ne 'engines,steam_engines') {
        $failures.Add('agricultural machinery prime-mover subset drift')
    }
}
foreach ($expectation in @(
    @('staple_kitchen', 0, 'starchy_staple'),
    @('staple_food_plant', 0, 'starchy_staple'),
    @('goldsmith_workshop', 0, 'precious_metal'),
    @('guild_weaving_house', 0, 'guild_textile_fiber'),
    @('textile_mill', 0, 'natural_spinnable_fiber'),
    @('cloth_plant', 0, 'natural_spinnable_fiber')
)) {
    $buildingId = $expectation[0]; $slotIndex = [int]$expectation[1]; $categoryId = $expectation[2]
    if (-not $buildings.ContainsKey($buildingId) -or
        $buildings[$buildingId].Categories.Count -le $slotIndex -or
        $buildings[$buildingId].Categories[$slotIndex] -ne $categoryId) {
        $failures.Add("recipe-specific category slot drift: $buildingId -> $categoryId")
    }
}

$coreHouseholdNeeds = @('staple_food','protein','produce','clothing','housing','household_goods',
    'hygiene','healthcare','home_energy')
$expectedPlanNeeds = @{
    survival_household=$coreHouseholdNeeds
    agrarian_household=@($coreHouseholdNeeds + @('transport','work_equipment','recreation'))
    extractive_household=@($coreHouseholdNeeds + @('transport','work_equipment'))
    industrial_worker_household=@($coreHouseholdNeeds + @('transport','work_equipment'))
    artisan_household=@($coreHouseholdNeeds + @('education_culture','work_equipment','luxury'))
    technical_household=@($coreHouseholdNeeds + @('transport','communication','education_culture',
        'recreation','durable_goods','work_equipment','luxury'))
    merchant_household=@($coreHouseholdNeeds + @('transport','communication','education_culture',
        'recreation','durable_goods','luxury','status_goods'))
    owner_household=@($coreHouseholdNeeds + @('transport','communication','education_culture',
        'recreation','durable_goods','luxury','status_goods'))
}
$expectedPlanNames = @{
    survival_household='生存型家庭消费'; agrarian_household='农业型家庭消费'
    extractive_household='采掘型家庭消费'; industrial_worker_household='产业工人家庭消费'
    artisan_household='工匠型家庭消费'; technical_household='技术型家庭消费'
    merchant_household='商人家庭消费'; owner_household='业主家庭消费'
}
$needPolicies = @{
    staple_food=@(550,'essential',4096,49152,81920,98304)
    protein=@(180,'essential',16384,32768,131072,98304)
    produce=@(300,'essential',16384,32768,131072,98304)
    clothing=@(3,'essential',32768,16384,196608,65536)
    housing=@(5,'essential',32768,16384,196608,65536)
    household_goods=@(2,'comfort',49152,8192,262144,49152)
    hygiene=@(10,'essential',32768,16384,196608,65536)
    healthcare=@(3,'essential',32768,16384,196608,32768)
    home_energy=@(80,'essential',32768,16384,196608,65536)
    transport=@(3,'comfort',49152,8192,262144,49152)
    communication=@(1,'comfort',49152,8192,262144,49152)
    education_culture=@(2,'comfort',49152,8192,262144,49152)
    recreation=@(3,'comfort',49152,8192,262144,49152)
    durable_goods=@(1,'luxury',65536,4096,393216,32768)
    work_equipment=@(2,'comfort',49152,8192,262144,49152)
    luxury=@(1,'luxury',98304,1024,524288,32768)
    status_goods=@(1,'luxury',98304,1024,524288,32768)
}
$expectedNeedVariants = @{
    staple_food=@('prepared_staples','bread','grain','gathered_plants')
    protein=@('game_meat','meat','fish','canned_fish','dairy_products')
    produce=@('vegetables','processed_food')
    clothing=@('cloth','fur','clothing','footwear')
    housing=@('construction_components')
    household_goods=@('pottery','furniture')
    hygiene=@('soap','detergent')
    healthcare=@('medicinal_herbs','pharmaceuticals')
    home_energy=@('logs','coal','natural_gas','refined_fuel')
    transport=@('horses','automobiles+refined_fuel')
    communication=@('radio_equipment','telecom_equipment')
    education_culture=@('manuscripts','printed_materials','computers')
    recreation=@('beverages','computers')
    durable_goods=@('household_appliances','autonomous_systems')
    work_equipment=@('chipped_stone_tools','bronze_tools','tools','precision_tools')
    luxury=@('beverages','fine_clothing','fine_furniture')
    status_goods=@('jewelry','fur','spices')
}
$planScales = @{
    survival_household=@(80,35,0); agrarian_household=@(95,75,0)
    extractive_household=@(105,85,0); industrial_worker_household=@(100,85,0)
    artisan_household=@(105,105,80); technical_household=@(110,125,120)
    merchant_household=@(115,150,180); owner_household=@(120,175,240)
}
$allowedCrossNeedUses = @{
    refined_fuel=@('home_energy','transport')
    computers=@('education_culture','recreation')
    beverages=@('recreation','luxury')
    fur=@('clothing','status_goods')
}
$forbiddenHouseholdGoods = @('railway_equipment','oceanic_vessels','scientific_instruments','electricity')
$expectedHouseholdGoods = @(
    'prepared_staples','bread','grain','gathered_plants','game_meat','meat','fish','canned_fish','dairy_products',
    'vegetables','processed_food','cloth','fur','clothing','footwear','construction_components',
    'pottery','furniture','soap','detergent','medicinal_herbs','pharmaceuticals','logs','coal',
    'natural_gas','refined_fuel','horses','automobiles','radio_equipment','telecom_equipment',
    'manuscripts','printed_materials','computers','beverages','household_appliances',
    'autonomous_systems','chipped_stone_tools','bronze_tools','tools','precision_tools',
    'fine_clothing','fine_furniture','jewelry','spices'
)

$planSignatures = @{}
$planCount = 0
foreach ($file in Get-ChildItem -LiteralPath $planDir -Filter '*.tres') {
    $p = Read-Profile $file
    $planCount++
    $planId = @(Values $p.id)[0]
    Assert-Chinese-DisplayName $p "consumption_plan:$planId"
    $displayName = @(Values $p.display_name)[0]
    $planNeeds = @(Values $p.need_ids)
    $priorities = @(Numbers $p.priorities)
    $baseQuantities = @(Numbers $p.base_qty_per_person)
    $wealthElasticities = @(Numbers $p.wealth_elasticity_q16)
    $wealthMinimums = @(Numbers $p.wealth_min_q16)
    $wealthMaximums = @(Numbers $p.wealth_max_q16)
    $variantOffsets = @(Numbers $p.need_variant_offsets)
    $variantPreferences = @(Numbers $p.variant_preference_q16)
    $variantPriceElasticities = @(Numbers $p.variant_price_elasticity_q16)
    $variantComponentOffsets = @(Numbers $p.variant_component_offsets)
    $componentGoodIds = @(Values $p.component_good_ids)
    $componentQuantities = @(Numbers $p.component_qty_per_need)

    if (-not $expectedPlanNeeds.ContainsKey($planId) -or
        ($planNeeds -join ',') -ne ($expectedPlanNeeds[$planId] -join ',')) {
        $failures.Add("consumption plan need set drift: $planId")
    }
    if (-not $expectedPlanNames.ContainsKey($planId) -or $displayName -ne $expectedPlanNames[$planId]) {
        $failures.Add("consumption plan display name drift: $planId -> $displayName")
    }
    if ($planNeeds.Count -gt 16 -or $planNeeds.Count -ne @($planNeeds | Select-Object -Unique).Count -or
        $variantOffsets.Count -ne $planNeeds.Count + 1 -or $priorities.Count -ne $planNeeds.Count -or
        $baseQuantities.Count -ne $planNeeds.Count -or $wealthElasticities.Count -ne $planNeeds.Count -or
        $wealthMinimums.Count -ne $planNeeds.Count -or $wealthMaximums.Count -ne $planNeeds.Count -or
        $variantPreferences.Count -ne $variantPriceElasticities.Count -or
        $variantComponentOffsets.Count -ne $variantPreferences.Count + 1 -or
        $componentGoodIds.Count -ne $componentQuantities.Count) {
        $failures.Add("consumption plan shape invalid: $planId")
        continue
    }

    $goodNeedUses = @{}
    for ($needIndex = 0; $needIndex -lt $planNeeds.Count; $needIndex++) {
        $needId = $planNeeds[$needIndex]
        if ($priorities[$needIndex] -ne $needIndex -or -not $needPolicies.ContainsKey($needId)) {
            $failures.Add("consumption priority or policy invalid: $planId -> $needId")
            continue
        }
        $policy = $needPolicies[$needId]
        $scales = $planScales[$planId]
        $scale = switch ($policy[1]) {
            'essential' { $scales[0] }
            'comfort' { $scales[1] }
            'luxury' { $scales[2] }
        }
        $expectedBase = [Math]::Max(1, [int][Math]::Floor(
            ([int64]$policy[0] * [int]$scale + 50) / 100.0))
        if ($baseQuantities[$needIndex] -ne $expectedBase -or
            $wealthElasticities[$needIndex] -ne $policy[2] -or
            $wealthMinimums[$needIndex] -ne $policy[3] -or
            $wealthMaximums[$needIndex] -ne $policy[4]) {
            $failures.Add("consumption quantity or wealth policy drift: $planId -> $needId")
        }
        $variantBegin = [int]$variantOffsets[$needIndex]
        $variantEnd = [int]$variantOffsets[$needIndex + 1]
        if ($variantEnd -le $variantBegin -or $variantEnd - $variantBegin -gt 8) {
            $failures.Add("need variant count invalid: $planId -> $needId")
            continue
        }
        $variantKeys = @{}
        for ($variantIndex = $variantBegin; $variantIndex -lt $variantEnd; $variantIndex++) {
            if ($variantPriceElasticities[$variantIndex] -ne $policy[5]) {
                $failures.Add("variant price elasticity drift: $planId -> $needId")
            }
            $componentBegin = [int]$variantComponentOffsets[$variantIndex]
            $componentEnd = [int]$variantComponentOffsets[$variantIndex + 1]
            if ($componentBegin -lt 0 -or $componentEnd -le $componentBegin -or
                $componentEnd -gt $componentGoodIds.Count -or $componentEnd - $componentBegin -gt 4) {
                $failures.Add("variant component shape invalid: $planId -> $needId")
                continue
            }
            $components = @($componentGoodIds[$componentBegin..($componentEnd - 1)])
            if (@($components | Select-Object -Unique).Count -ne $components.Count) {
                $failures.Add("duplicate component in need variant: $planId -> $needId")
            }
            $variantKey = $components -join '+'
            if ($variantKeys.ContainsKey($variantKey)) {
                $failures.Add("duplicate need variant: $planId -> $needId -> $variantKey")
            } else { $variantKeys[$variantKey] = $true }
            for ($componentIndex = $componentBegin; $componentIndex -lt $componentEnd; $componentIndex++) {
                $good = $componentGoodIds[$componentIndex]
                if ($componentQuantities[$componentIndex] -ne 1000) {
                    $failures.Add("household component quantity drift: $planId -> $needId -> $good")
                }
                if (-not $goodNeedUses.ContainsKey($good)) { $goodNeedUses[$good] = @() }
                $goodNeedUses[$good] = @($goodNeedUses[$good]) + @($needId)
            }
        }
        $actualVariants = @($variantKeys.Keys | Sort-Object)
        $expectedVariants = @($expectedNeedVariants[$needId] | Sort-Object)
        if (($actualVariants -join ',') -ne ($expectedVariants -join ',')) {
            $failures.Add("household need variant classification drift: $planId -> $needId")
        }
    }
    if ($building.Id -in @('gold_mine','silver_mine') -and
        ($building.Owner -ne 'industrialist' -or
            $building.Roles -notcontains 'miner' -or $building.Roles -notcontains 'manager')) {
        $failures.Add("industrial bullion mine has wrong ownership or staffing: $($building.Id)")
    }

    foreach ($good in $goodNeedUses.Keys) {
        $actualUses = @($goodNeedUses[$good] | Select-Object -Unique | Sort-Object)
        if ($actualUses.Count -le 1) { continue }
        if (-not $allowedCrossNeedUses.ContainsKey($good)) {
            $failures.Add("unapproved cross-need household good: $planId -> $good")
            continue
        }
        $expectedUses = @($allowedCrossNeedUses[$good] | Where-Object { $_ -in $planNeeds } | Sort-Object)
        if (($actualUses -join ',') -ne ($expectedUses -join ',')) {
            $failures.Add("cross-need household use drift: $planId -> $good")
        }
    }
    foreach ($good in $componentGoodIds) {
        if (-not $goods.ContainsKey($good)) { $failures.Add("need component missing: $($file.Name) -> $good") }
        else { $goods[$good].Demanded = $true }
        if ($good -in $forbiddenHouseholdGoods) {
            $failures.Add("capital or cycle-flow good entered household demand: $($file.Name) -> $good")
        }
    }
    $signature = ($planNeeds -join ',') + '|' + ($variantPreferences -join ',') + '|' +
        ($componentGoodIds -join ',')
    if ($planSignatures.ContainsKey($signature)) {
        $failures.Add("duplicate consumption prototype: $planId and $($planSignatures[$signature])")
    } else { $planSignatures[$signature] = $planId }
}
if ($planCount -ne 8) { $failures.Add("expected eight consumption prototypes, found $planCount") }
$actualHouseholdGoods = @($goods.Values | Where-Object { $_.Demanded } |
    ForEach-Object { $_.Id } | Sort-Object)
if (($actualHouseholdGoods -join ',') -ne (($expectedHouseholdGoods | Sort-Object) -join ',')) {
    $failures.Add('household consumer good coverage drift')
}

function Inputs-Ready($Building, $ReachableGoods, [int]$MaxRank) {
    for ($i = 0; $i -lt $Building.Inputs.Count; $i++) {
        $slotCandidates = if ($i -lt $Building.CandidateSlots.Count) { @($Building.CandidateSlots[$i]) } else { @() }
        if ($slotCandidates.Count -gt 0) {
            $ready = $false
            foreach ($candidate in $slotCandidates) {
                if ($goods[$candidate.Id].Rank -le $MaxRank -and $ReachableGoods.Contains($candidate.Id)) {
                    $ready = $true; break
                }
            }
            if (-not $ready) { return $false }
            continue
        }
        $category = if ($i -lt $Building.Categories.Count) { $Building.Categories[$i] } else { '' }
        $minimum = if ($i -lt $Building.MinLevels.Count) { [int]$Building.MinLevels[$i] } else { 0 }
        if ($category -eq '') {
            if (-not $ReachableGoods.Contains($Building.Inputs[$i])) { return $false }
            continue
        }
        $ready = $false
        foreach ($candidate in $goods.Values) {
            if ($category -in $candidate.Categories -and $candidate.Quality -ge $minimum -and
                $candidate.Rank -le $MaxRank -and $ReachableGoods.Contains($candidate.Id)) {
                $ready = $true; break
            }
        }
        if (-not $ready) { return $false }
    }
    return $true
}

# Every cumulatively unlocked era must close from zero goods stock. Natural
# resources provide extraction capacity, but do not waive a collector's goods inputs.
$reachableGoods = $null
for ($eraRank = 0; $eraRank -le 10; $eraRank++) {
    $eraReachable = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $startedBuildings = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($building in $buildings.Values) {
            if ($building.Rank -gt $eraRank -or $startedBuildings.Contains($building.Id) -or
                -not (Inputs-Ready $building $eraReachable $eraRank)) { continue }
            [void]$startedBuildings.Add($building.Id)
            foreach ($output in $building.Outputs) {
                if ($eraReachable.Add($output)) { $changed = $true }
            }
        }
    }
    foreach ($building in $buildings.Values) {
        if ($building.Rank -le $eraRank -and -not $startedBuildings.Contains($building.Id)) {
            $failures.Add("era $eraRank zero-stock closure cannot start building: $($building.Id)")
        }
    }
    $hasStaple = $false
    foreach ($staple in @('gathered_plants','grain','bread','prepared_staples')) {
        if ($eraReachable.Contains($staple)) { $hasStaple = $true; break }
    }
    if (-not $hasStaple) { $failures.Add("era $eraRank has no reachable staple food") }
    if (-not $eraReachable.Contains('cloth')) { $failures.Add("era $eraRank has no reachable cloth") }
    if ($eraRank -eq 10) { $reachableGoods = $eraReachable }
}

foreach ($good in $goods.Values) {
    if ($good.Producers.Count -eq 0 -and ($good.Consumers.Count -gt 0 -or $good.Demanded)) {
        $failures.Add("good has no producer: $($good.Id)")
    }
    if ($good.Producers.Count -gt 0 -and $good.Consumers.Count -eq 0 -and -not $good.Demanded -and
        $good.Id -notin @('gold','silver') -and -not $deferredCapitalGoods.ContainsKey($good.Id)) {
        $failures.Add("produced good has no use: $($good.Id)")
    }
    if ($good.Producers.Count -eq 0 -and $good.Consumers.Count -eq 0 -and -not $good.Demanded) {
        $failures.Add("unreferenced good: $($good.Id)")
    }
    if ($good.Producers.Count -gt 0 -and -not $reachableGoods.Contains($good.Id)) {
        $failures.Add("good is trapped in a source-free production loop: $($good.Id)")
    }
    if ($good.Rank -lt 9 -and $good.Producers.Count -lt 2 -and
        -not $singleProducerExceptions.ContainsKey($good.Id)) {
        $failures.Add("pre-information good has fewer than two production methods: $($good.Id)")
    }
}
foreach ($goodId in @('cotton_fiber','lubricants','horses','rice_grain','stainless_steel',
    'silver','synthetic_rubber','wool')) {
    if (-not $goods.ContainsKey($goodId) -or $goods[$goodId].Producers.Count -eq 0 -or
        ($goods[$goodId].Consumers.Count -eq 0 -and -not $goods[$goodId].Demanded)) {
        $failures.Add("candidate/need-linked good became genuinely orphaned: $goodId")
    }
}

$expectedToolProgression = @{
    chipped_stone_tools=@(0,1); bronze_tools=@(1,2); tools=@(2,3); precision_tools=@(5,4)
}
foreach ($toolId in $expectedToolProgression.Keys) {
    if (-not $goods.ContainsKey($toolId)) {
        $failures.Add("tool progression good missing: $toolId")
        continue
    }
    $expected = $expectedToolProgression[$toolId]
    if ($goods[$toolId].Rank -ne $expected[0] -or $goods[$toolId].Quality -ne $expected[1]) {
        $failures.Add("tool progression rank/quality mismatch: $toolId")
    }
}
if (-not $goods.ContainsKey('canned_fish') -or $goods['canned_fish'].Rank -ne 5) {
    $failures.Add('canned fish must begin in the Enlightenment era')
}

# A single-use intermediate must carry a narrow, explicit strategic reason.
# Keep this map minimal so future downstream loss cannot hide behind a broad
# "advanced material" exemption.
$strategicSingleUse = @{
    flint='geographic stone-age tool material with one canonical knapping method'
    bricks='distinct masonry path into classical construction'
    cement='strategic binder and transportable precursor to concrete'
    concrete='strategic bulk construction process retained by design'
    fertilizer='two production methods create an era and feedstock choice'
    synthetic_fiber='late alternative feedstock for the persistent cloth chain'
    synthetic_rubber='late geographic substitute for natural latex'
    lead='geographic refined-metal bottleneck for battery chemistry'
    zinc='geographic refined-metal bottleneck for electronic components'
}
foreach ($good in $goods.Values) {
    if ($good.Producers.Count -gt 0 -and $good.Consumers.Count -eq 1 -and -not $good.Demanded -and
        $good.Industry -ne 'primary' -and -not $strategicSingleUse.ContainsKey($good.Id)) {
        $failures.Add("unjustified single-use intermediate: $($good.Id) -> $($good.Consumers[0])")
    }
}

$expectedFamilies = @{
    'subsistence_food:1'='gathering_ground'; 'subsistence_food:2'='subsistence_farm'
    'subsistence_food:3'='three_field_smallholding'; 'subsistence_food:4'='improved_smallholding'
    'household_cloth:1'='household_weaving_shelter'; 'household_cloth:2'='household_loom'
    'household_cloth:3'='cottage_weaving'; 'household_cloth:4'='improved_domestic_loom'
    'livestock_husbandry:1'='pastoral_camp'; 'livestock_husbandry:2'='manorial_pasture'
    'livestock_husbandry:3'='ranching_station'; 'horse_breeding:1'='horse_breeding_camp'
    'horse_breeding:2'='horse_breeder'
    'bread_baking:1'='bakery'; 'bread_baking:2'='bread_plant'
    'staple_preparation:1'='staple_kitchen'; 'staple_preparation:2'='staple_food_plant'
    'meat_processing:1'='slaughterhouse'; 'meat_processing:2'='mechanized_slaughterhouse'
    'dairy_processing:1'='creamery'; 'dairy_processing:2'='dairy_products_plant'
    'leather_processing:1'='tannery'; 'leather_processing:2'='leather_plant'
    'cloth_weaving:1'='guild_weaving_house'; 'cloth_weaving:2'='textile_mill'
    'cloth_weaving:3'='cloth_plant'; 'cloth_weaving:4'='synthetic_textile_mill'
    'garment_making:1'='tailor_shop'; 'garment_making:2'='clothing_plant'
    'footwear_making:1'='cobbler_shop'; 'footwear_making:2'='footwear_plant'
    'paper_making:1'='rag_paper_workshop'; 'paper_making:2'='paper_plant'
    'beverage_making:1'='brewery'; 'beverage_making:2'='distillery'; 'beverage_making:3'='beverages_plant'
    'metal_toolmaking:1'='iron_tool_workshop'; 'metal_toolmaking:2'='tools_plant'
    'fish_canning:1'='canning_workshop'; 'fish_canning:2'='canned_fish_plant'
    'fertilizer_making:1'='composting_yard'; 'fertilizer_making:2'='fertilizer_plant'
    'chemical_industry:1'='industrial_chemicals_plant'; 'chemical_industry:2'='electrochemical_works'
    'oil_extraction:1'='early_oil_well'; 'oil_extraction:2'='oil_collector'
    'salt_extraction:1'='salt_collector'; 'salt_extraction:2'='industrial_salt_mine'
    'gold_extraction:1'='placer_gold_working'; 'gold_extraction:2'='gold_mine'
    'silver_extraction:1'='surface_silver_working'; 'silver_extraction:2'='silver_mine'
    'jewelry_making:1'='goldsmith_workshop'; 'jewelry_making:2'='jewelry_plant'
    'fine_clothing_making:1'='court_tailor'; 'fine_clothing_making:2'='fine_clothing_plant'
    'fine_furniture_making:1'='cabinetmaker_workshop'; 'fine_furniture_making:2'='fine_furniture_plant'
    'construction_methods:1'='classical_masonry_yard'; 'construction_methods:2'='classical_public_works'
    'construction_methods:3'='construction_components_plant'
    'field_crop_farming:1'='mechanized_farm'; 'field_crop_farming:2'='intensive_farm'
    'glassmaking:1'='classical_glass_kiln'; 'glassmaking:2'='glass_plant'
    'steelmaking:1'='steam_steel_works'; 'steelmaking:2'='steel_plant'
    'railway_equipment_making:1'='steam_rail_works'
    'railway_equipment_making:2'='railway_equipment_plant'
    'clay_extraction:1'='early_clay_pit'; 'clay_extraction:2'='clay_collector'
    'copper_extraction:1'='early_copper_mine'; 'copper_extraction:2'='copper_ore_collector'
    'tin_extraction:1'='early_tin_mine'; 'tin_extraction:2'='tin_ore_collector'
    'silica_extraction:1'='classical_silica_pit'; 'silica_extraction:2'='silica_sand_collector'
}
foreach ($key in $expectedFamilies.Keys) {
    if (-not $familyTiers.ContainsKey($key) -or $familyTiers[$key] -ne $expectedFamilies[$key]) {
        $failures.Add("subsistence upgrade tier mismatch: $key")
    }
}

foreach ($id in @('beef_plant','mutton_plant','pork_plant')) {
    if ($buildings.ContainsKey($id)) { $failures.Add("homogeneous species meat plant remains: $id") }
}

$retired = @('shell_money_station','software_studio','network_data_center','digital_service_exchange',
    'ai_research_lab','orbital_research_program','orbital_technology_transfer',
    'deep_space_telemetry_program','classical_archive','enlightenment_academy',
    'radio_network_depot','robotics_integration_center','ai_battery_works','ai_motor_works',
    'village_mill','flour_plant','grain_plant','rice_kitchen','rice_food_plant',
    'corn_grinding_house','corn_food_plant','potato_kitchen','potato_food_plant',
    'wood_pulp_plant','pig_iron_plant','flax_spinning_shed','flax_yarn_plant',
    'cotton_yarn_plant','textile_workshop','cut_stone_plant',
    'sail_loft','naval_salvage_yard','navigation_instrument_shop','isotope_reactor',
    'bronze_foundry','manganese_alloy_plant','hafted_stone_tool_shelter')
foreach ($id in $retired) {
    if ($buildings.ContainsKey($id)) { $failures.Add("retired building remains: $id") }
}

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "ERROR: $failure" }
    throw "economy content audit failed: $($failures.Count) issue(s)"
}
Write-Host "Economy content audit passed: $($goods.Count) goods, $($buildings.Count) buildings."
