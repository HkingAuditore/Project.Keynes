param([string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path)

$ErrorActionPreference = 'Stop'
$project = Join-Path $RepoRoot 'Project/project-keynes'
$goodDir = Join-Path $project 'data/goods'
$buildingDir = Join-Path $project 'data/economy/buildings'
$needDir = Join-Path $project 'data/economy/needs'
$planDir = Join-Path $project 'data/economy/consumption_plans'
$techPath = Join-Path $project 'data/technology/technology_network.json'
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
function Fail([string]$Message) { $failures.Add($Message) }
function Display-Name-OK([hashtable]$Profile, [string]$Label) {
    $name = if ($Profile.ContainsKey('display_name')) { [string](Values $Profile.display_name | Select-Object -First 1) } else { '' }
    if ([string]::IsNullOrWhiteSpace($name) -or $name -notmatch '[\u3400-\u4DBF\u4E00-\u9FFF]') { Fail "invalid Chinese display_name: $Label" }
}
function Tech-Rank([string[]]$Tags, [string]$Label, $TechRank) {
    $rank = -1
    foreach ($tag in $Tags | Where-Object { $_.StartsWith('tech.') }) {
        if (-not $TechRank.ContainsKey($tag)) { Fail "unknown technology tag: $Label -> $tag"; continue }
        $rank = if ($rank -lt 0) { [int]$TechRank[$tag] } else { [Math]::Min($rank, [int]$TechRank[$tag]) }
    }
    return $rank
}
function Add-Unique([System.Collections.Generic.List[string]]$List, [string]$Value) {
    if (-not $List.Contains($Value)) { $List.Add($Value) }
}
function Expected-Component-Quantity([string]$Need, [string]$Good, [string[]]$Components) {
    if ($Need -eq 'staple_food') {
        if ($Good -in @('prepared_staples','bread')) { return 650 }
        if ($Good -in @('grain','wheat_grain','rice_grain','corn_grain','potatoes')) { return 800 }
    }
    if ($Need -eq 'seasoning' -and $Good -eq 'spices') { return 250 }
    if ($Need -eq 'domestic_wares' -and $Good -eq 'glassware') { return 800 }
    if ($Need -eq 'domestic_wares' -and $Good -eq 'metal_housewares') { return 700 }
    if ($Need -eq 'home_energy') {
        switch ($Good) { 'logs' { return 1000 }; 'charcoal' { return 800 }; 'coal' { return 700 }; 'natural_gas' { return 500 }; 'refined_fuel' { return 500 }; 'electricity' { return 300 } }
    }
    if ($Need -eq 'housing') {
        switch ($Good) {
            'reed_bundle' { return 700 }; 'bast_fiber' { return 300 }; 'turf_block' { return 700 }; 'adobe_brick' { return 800 }
            'raw_stone' { return 700 }; 'bricks' { return 700 }; 'cement' { return 500 }; 'concrete' { return 600 }
            'lime' { return 200 }; 'steel' { return 250 }
            'glass' { return $(if ($Components -contains 'cement') { 250 } else { 150 }) }
            'lumber' { return $(if ($Components -contains 'turf_block') { 300 } elseif ($Components -contains 'adobe_brick') { 200 } else { 100 }) }
        }
    }
    if ($Good -eq 'technology_points') { return 100 }
    return 1000
}

if (-not (Test-Path -LiteralPath $techPath)) { throw "authoritative technology network missing: $techPath" }
$network = [System.IO.File]::ReadAllText($techPath) | ConvertFrom-Json
$eraRank = @{}
foreach ($era in @($network.eras)) {
    $id = [string]$era.id
    if ([string]::IsNullOrWhiteSpace($id) -or $eraRank.ContainsKey($id)) { Fail "invalid or duplicate technology era: $id"; continue }
    $eraRank[$id] = [int]$era.sort_order
}
$techRank = @{}
$techBindings = @{}
foreach ($node in @($network.nodes)) {
    $id = [string]$node.id; $era = [string]$node.era_id
    if ([string]::IsNullOrWhiteSpace($id) -or $techRank.ContainsKey($id)) { Fail "invalid or duplicate technology node: $id"; continue }
    if (-not $eraRank.ContainsKey($era)) { Fail "technology node has unknown era: $id -> $era"; continue }
    $techRank[$id] = [int]$eraRank[$era]
    $bindings = [System.Collections.Generic.List[string]]::new()
    foreach ($binding in @($node.expected_bindings)) { $bindings.Add("$([int]$binding.kind):$([string]$binding.id)") }
    $techBindings[$id] = $bindings
}

$goods = @{}
foreach ($file in Get-ChildItem -LiteralPath $goodDir -Filter '*.tres' -File | Sort-Object Name) {
    $p = Read-Profile $file; $id = @(Values $p.id)[0]
    Display-Name-OK $p "good:$id"
    if ([string]::IsNullOrWhiteSpace($id) -or $goods.ContainsKey($id)) { Fail "invalid or duplicate good: $($file.Name)"; continue }
    $tags = @(Values $p.technology_tags); $rank = Tech-Rank $tags "good:$id" $techRank
    $category = @(Values $p.category_id)[0]; $categories = @(Values $p.substitution_category_ids)
    if ($categories.Count -eq 0) { $categories = @($category) }
    if ([string]::IsNullOrWhiteSpace($category) -or $category -notin $categories -or @($categories | Select-Object -Unique).Count -ne $categories.Count) { Fail "invalid substitution category membership: $id" }
    $goods[$id] = [pscustomobject]@{
        Id=$id; Rank=$rank; Categories=$categories; Tags=$tags; Producers=[System.Collections.Generic.List[string]]::new(); Consumers=[System.Collections.Generic.List[string]]::new(); Demanded=$false
        Issue=if ($p.ContainsKey('monetary_issue_value')) {[long]$p.monetary_issue_value} else {0}; Storage=if ($p.ContainsKey('storage_mode')) {[string](Values $p.storage_mode | Select-Object -First 1)} else {'stock'}
    }
    if ($rank -lt 0) { Fail "good has no executable technology: $id" }
    if ($goods[$id].Storage -notin @('stock','cycle_flow')) { Fail "invalid good storage mode: $id" }
}
if ($goods.Count -ne 133) { Fail "expected 133 goods, found $($goods.Count)" }
if ($goods.ContainsKey('electricity') -and $goods['electricity'].Storage -ne 'cycle_flow') { Fail 'electricity must remain cycle_flow' }
foreach ($retired in @('cattle','sheep','pigs','raw_water','clean_water','beef','mutton','pork','sailcloth','navigation_instruments','medical_isotopes','bronze','manganese_alloy')) { if ($goods.ContainsKey($retired)) { Fail "retired good remains: $retired" } }

$expectedNeedNames = @('staple_food','protein','produce','food_fat','seasoning','clothing','housing','household_goods','domestic_wares','hygiene','healthcare','home_energy','transport','communication','education_culture','recreation','durable_goods','work_equipment','luxury','status_goods')
$needs = @{}
foreach ($file in Get-ChildItem -LiteralPath $needDir -Filter '*.tres' -File | Sort-Object Name) {
    $p = Read-Profile $file; $id = @(Values $p.id)[0]; Display-Name-OK $p "need:$id"
    if ([string]::IsNullOrWhiteSpace($id) -or $needs.ContainsKey($id)) { Fail "invalid or duplicate need: $($file.Name)"; continue }
    if ($id -notin $expectedNeedNames) { Fail "need id drift: $id" }
    $needs[$id] = $true
}
if ($needs.Count -ne $expectedNeedNames.Count) { Fail "expected $($expectedNeedNames.Count) household needs, found $($needs.Count)" }

$coreNeeds = @('staple_food','protein','produce','food_fat','seasoning','clothing','housing','household_goods','domestic_wares','hygiene','healthcare','home_energy')
$expectedPlans = @{ plan_unemployed=@('staple_food','protein','produce','food_fat','seasoning'); survival_household=$coreNeeds; hunter_household=@($coreNeeds+'work_equipment'); agrarian_household=@($coreNeeds+'transport'+'work_equipment'+'recreation'); extractive_household=@($coreNeeds+'transport'+'work_equipment'); industrial_worker_household=@($coreNeeds+'transport'+'work_equipment'); artisan_household=@($coreNeeds+'education_culture'+'work_equipment'+'luxury'); scholarly_household=@($coreNeeds+'education_culture'+'work_equipment'+'luxury'); technical_household=@($coreNeeds+'transport'+'communication'+'education_culture'+'recreation'+'durable_goods'+'work_equipment'+'luxury'); merchant_household=@($coreNeeds+'transport'+'communication'+'education_culture'+'recreation'+'durable_goods'+'luxury'+'status_goods'); owner_household=@($coreNeeds+'transport'+'communication'+'education_culture'+'recreation'+'durable_goods'+'luxury'+'status_goods') }
$expectedVariants = @{ staple_food=@('prepared_staples','bread','grain','wheat_grain','rice_grain','corn_grain','potatoes','gathered_plants'); protein=@('game_meat','meat','fish','canned_fish','dairy_products'); produce=@('vegetables','processed_food'); food_fat=@('edible_oil'); seasoning=@('salt','spices'); clothing=@('cloth','fur','clothing','footwear'); housing=@('reed_bundle+bast_fiber','turf_block+lumber','adobe_brick+lumber','raw_stone+lime+lumber','bricks+lime+lumber','cement+glass+steel','concrete+steel+glass','construction_components'); household_goods=@('furniture','leather_goods'); domestic_wares=@('pottery','glassware','metal_housewares'); hygiene=@('soap','detergent'); healthcare=@('medicinal_herbs','pharmaceuticals'); home_energy=@('logs','charcoal','coal','natural_gas','refined_fuel','electricity'); transport=@('horses','automobiles+refined_fuel'); communication=@('radio_equipment','telecom_equipment','radio_equipment+batteries','telecom_equipment+batteries'); education_culture=@('manuscripts','paper','printed_materials','computers'); recreation=@('beverages','computers'); durable_goods=@('household_appliances','autonomous_systems'); work_equipment=@('chipped_stone_tools','bronze_tools','tools','precision_tools'); luxury=@('beverages','fine_clothing','fine_furniture'); status_goods=@('jewelry','fur') }
$demanded = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$plans = @{}
foreach ($file in Get-ChildItem -LiteralPath $planDir -Filter '*.tres' -File | Sort-Object Name) {
    $p=Read-Profile $file; $id=@(Values $p.id)[0]; $planNeeds=@(Values $p.need_ids); $plans[$id]=$true
    if (-not $expectedPlans.ContainsKey($id) -or ($planNeeds -join ',') -ne ($expectedPlans[$id] -join ',')) { Fail "consumption plan need set drift: $id" }
    $variantOffsets=@(Numbers $p.need_variant_offsets); $variantPref=@(Numbers $p.variant_preference_q16); $variantPrice=@(Numbers $p.variant_price_elasticity_q16); $classDelta=@(Numbers $p.variant_class_wealth_elasticity_delta_q16); $classThreshold=@(Numbers $p.variant_class_savings_threshold_factor_q16); $componentOffsets=@(Numbers $p.variant_component_offsets); $componentGoods=@(Values $p.component_good_ids); $componentQty=@(Numbers $p.component_qty_per_need)
    if ($variantOffsets.Count -ne $planNeeds.Count+1 -or $componentOffsets.Count -ne $variantPref.Count+1 -or $variantPref.Count -ne $variantPrice.Count -or $variantPref.Count -ne $classDelta.Count -or $variantPref.Count -ne $classThreshold.Count -or $componentGoods.Count -ne $componentQty.Count) { Fail "consumption plan CSR shape invalid: $id"; continue }
    for ($n=0; $n -lt $planNeeds.Count; $n++) {
        $need=$planNeeds[$n]; $actual=@(); $vb=[int]$variantOffsets[$n]; $ve=[int]$variantOffsets[$n+1]
        for ($v=$vb; $v -lt $ve; $v++) {
            $cb=[int]$componentOffsets[$v]; $ce=[int]$componentOffsets[$v+1]; $parts=@()
            for ($c=$cb; $c -lt $ce; $c++) { $good=[string]$componentGoods[$c]; $parts += $good; [void]$demanded.Add($good); if (-not $goods.ContainsKey($good)) { Fail "need component missing: $id/$need -> $good" }; if ($good -in @('railway_equipment','oceanic_vessels','scientific_instruments')) { Fail "capital good entered household demand: $id -> $good" }; if ([long]$componentQty[$c] -ne (Expected-Component-Quantity $need $good $parts)) { Fail "component quantity drift: $id/$need -> $good" } }
            $actual += ($parts -join '+')
            if ([int]$classDelta[$v] -lt -65536 -or [int]$classDelta[$v] -gt 131072 -or [int]$classThreshold[$v] -lt 0 -or [int]$classThreshold[$v] -gt 131072) { Fail "variant class response out of range: $id/$need" }
        }
        $expected=@($expectedVariants[$need]); if ($id -eq 'technical_household' -and $need -eq 'education_culture') { $expected=@('manuscripts+technology_points','paper+technology_points','printed_materials+technology_points','computers+technology_points') }
        if ((@($actual | Sort-Object) -join ',') -ne (@($expected | Sort-Object) -join ',')) { Fail "household need variant classification drift: $id -> $need" }
    }
}
foreach ($good in $goods.Values) { $good.Demanded = $demanded.Contains($good.Id) }
if ($plans.Count -ne 11) { Fail "expected 11 consumption plans, found $($plans.Count)" }

$buildings=@{}; $categoryConsumers=@{}
foreach ($file in Get-ChildItem -LiteralPath $buildingDir -Filter '*.tres' -File | Sort-Object Name) {
    $p=Read-Profile $file; $id=@(Values $p.id)[0]; Display-Name-OK $p "building:$id"; if ([string]::IsNullOrWhiteSpace($id) -or $buildings.ContainsKey($id)) { Fail "invalid or duplicate building: $($file.Name)"; continue }
    $tags=@(Values $p.technology_tags); $rank=Tech-Rank $tags "building:$id" $techRank; $inputs=@(Values $p.input_good_ids); $categories=@(Values $p.input_category_ids); $outputs=@(Values $p.output_good_ids); $construction=@(Values $p.construction_good_ids); $maintenance=@(Values $p.maintenance_good_ids); $resources=@(Values $p.resource_ids); $modes=@(Values $p.resource_interaction_modes); $candidateOffsets=@(Numbers $p.input_candidate_offsets); $candidateGoods=@(Values $p.input_candidate_good_ids)
    $buildings[$id]=[pscustomobject]@{Id=$id;Rank=$rank;Inputs=$inputs;Categories=$categories;Outputs=$outputs;Construction=$construction;Maintenance=$maintenance;Resources=$resources;Modes=$modes;CandidateOffsets=$candidateOffsets;CandidateGoods=$candidateGoods}
    if ($rank -lt 0 -and $id -notin @('merchant_post','early_merchant_post')) { Fail "building has no executable technology: $id" }; if ($outputs.Count -eq 0 -and $id -notin @('merchant_post','early_merchant_post')) { Fail "building has no physical output: $id" }
    foreach ($good in @($inputs+$outputs+$construction+$maintenance+$candidateGoods)) { if (-not $goods.ContainsKey($good)) { Fail "building references missing good: $id -> $good" } }
    for ($i=0; $i -lt $inputs.Count; $i++) {
        $slot=@(); if ($candidateOffsets.Count -eq $inputs.Count+1) { $cb=[int]$candidateOffsets[$i]; $ce=[int]$candidateOffsets[$i+1]; if ($cb -lt 0 -or $ce -lt $cb -or $ce -gt $candidateGoods.Count) { Fail "invalid candidate offsets: $id" } elseif ($ce -gt $cb) { $slot=@($candidateGoods[$cb..($ce-1)]) } }
        if ($slot.Count -eq 0 -and $i -lt $categories.Count -and -not [string]::IsNullOrWhiteSpace($categories[$i])) { if (-not $categoryConsumers.ContainsKey($categories[$i])) { $categoryConsumers[$categories[$i]]=[System.Collections.Generic.List[string]]::new() }; Add-Unique $categoryConsumers[$categories[$i]] $id }
        elseif ($slot.Count -eq 0 -and $goods.ContainsKey($inputs[$i])) { Add-Unique $goods[$inputs[$i]].Consumers $id }
        foreach ($good in $slot) { if ($goods.ContainsKey($good)) { Add-Unique $goods[$good].Consumers $id } }
    }
    foreach ($good in @($construction+$maintenance)) { if ($goods.ContainsKey($good)) { Add-Unique $goods[$good].Consumers $id } }
    foreach ($good in $outputs) { if ($goods.ContainsKey($good)) { Add-Unique $goods[$good].Producers $id } }
}
if ($buildings.Count -ne 363) { Fail "expected 363 buildings, found $($buildings.Count)" }

$expectedBindings=@{ 'tech.application.glassware_workshop_kingdom'=@('1:glassware','2:glassware_workshop'); 'tech.application.metal_housewares_workshop_kingdom'=@('1:metal_housewares','2:metal_housewares_workshop'); 'tech.application.leather_goods_workshop_kingdom'=@('1:leather_goods','2:leather_goods_workshop') }
foreach ($tech in $expectedBindings.Keys) { if (-not $techBindings.ContainsKey($tech)) { Fail "technology node missing: $tech"; continue }; foreach ($binding in $expectedBindings[$tech]) { if (-not $techBindings[$tech].Contains($binding)) { Fail "technology binding missing: $tech -> $binding" } } }

$terminal=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); foreach ($good in $goods.Values) { if ($good.Demanded -or $good.Issue -gt 0) { [void]$terminal.Add($good.Id) } }
$changed=$true
while ($changed) { $changed=$false; foreach ($good in $goods.Values) { if ($terminal.Contains($good.Id)) { continue }; $consumerIds=@($good.Consumers); foreach ($category in $good.Categories) { if ($categoryConsumers.ContainsKey($category)) { $consumerIds += @($categoryConsumers[$category]) } }; foreach ($consumerId in $consumerIds | Select-Object -Unique) { if ($buildings.ContainsKey($consumerId) -and @($buildings[$consumerId].Outputs | Where-Object { $terminal.Contains($_) }).Count -gt 0) { [void]$terminal.Add($good.Id); $changed=$true; break } } } }
foreach ($good in $goods.Values) { if ($good.Producers.Count -gt 0 -and -not $terminal.Contains($good.Id)) { Fail "produced good has no executable terminal path: $($good.Id)" }; if ($good.Producers.Count -eq 0 -and $good.Consumers.Count -eq 0 -and -not $good.Demanded -and $good.Issue -le 0) { Fail "unreferenced good: $($good.Id)" } }

$reachable=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); foreach ($bootstrap in @('logs','gathered_plants','flint')) { if ($goods.ContainsKey($bootstrap)) { [void]$reachable.Add($bootstrap) } }
$progress=$true
while ($progress) { $progress=$false; foreach ($building in $buildings.Values) { $ready=$true; foreach ($good in $building.Construction) { if (-not $reachable.Contains($good)) { $ready=$false } }; for ($i=0; $i -lt $building.Inputs.Count; $i++) { $slot=@(); if ($building.CandidateOffsets.Count -eq $building.Inputs.Count+1) { $cb=[int]$building.CandidateOffsets[$i]; $ce=[int]$building.CandidateOffsets[$i+1]; if ($ce -gt $cb) { $slot=@($building.CandidateGoods[$cb..($ce-1)]) } }; if ($slot.Count -gt 0) { if (@($slot | Where-Object { $reachable.Contains($_) }).Count -eq 0) { $ready=$false } } elseif ($i -lt $building.Categories.Count -and -not [string]::IsNullOrWhiteSpace($building.Categories[$i])) { if (@($goods.Values | Where-Object { $_.Categories -contains $building.Categories[$i] -and $reachable.Contains($_.Id) }).Count -eq 0) { $ready=$false } } elseif (-not $reachable.Contains($building.Inputs[$i])) { $ready=$false } }; if ($building.Resources.Count -gt 0 -and -not $ready) { continue }; if ($building.Resources.Count -eq 0 -and $building.Id -ne 'merchant_post' -and -not $ready) { continue }; foreach ($output in $building.Outputs) { if ($reachable.Add($output)) { $progress=$true } } } }
foreach ($good in $goods.Values) { if ($good.Producers.Count -gt 0 -and -not $reachable.Contains($good.Id)) { Fail "good cannot start from external resources: $($good.Id)" } }

if ($failures.Count -gt 0) { foreach ($failure in $failures) { Write-Host "ERROR: $failure" }; throw "economy content audit failed: $($failures.Count) issue(s)" }
Write-Host "Economy content audit passed: $($goods.Count) goods, $($buildings.Count) buildings, $($needs.Count) needs, $($plans.Count) plans; terminal and source reachability are edge-complete."
