param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [switch]$Check,
    [ValidateSet('All', 'Consumption')]
    [string]$Scope = 'All'
)

$ErrorActionPreference = 'Stop'
$DesignSellThroughQ16 = 52429 # 80%; leaves room for inventory/discard and price noise.
$project = Join-Path $RepoRoot 'Project/project-keynes'
$goodsDir = Join-Path $project 'data/goods'
$buildingsDir = Join-Path $project 'data/economy/buildings'
$professionsDir = Join-Path $project 'data/economy/professions'
$needsDir = Join-Path $project 'data/economy/needs'
$plansDir = Join-Path $project 'data/economy/consumption_plans'
$resourcesDir = Join-Path $project 'data/resources'
$curatedContentDir = Join-Path $PSScriptRoot 'economy_content'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$managedPaths = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

function Is-Consumption-Path([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    foreach ($directory in @($professionsDir, $needsDir, $plansDir)) {
        $prefix = [System.IO.Path]::GetFullPath($directory).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if ($fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Write-Utf8([string]$Path, [string]$Content) {
    if ($Scope -eq 'Consumption' -and -not (Is-Consumption-Path $Path)) { return }
    [void]$managedPaths.Add([System.IO.Path]::GetFullPath($Path))
    $expected = $Content.TrimEnd() + "`n"
    if ($Check) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "generated file missing: $Path" }
        $actual = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
        if ($actual -ne $expected.Replace("`r`n", "`n")) {
            throw "generated file stale: $Path"
        }
        return
    }
    if (Test-Path -LiteralPath $Path) {
        $actual = [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
        if ($actual -eq $expected.Replace("`r`n", "`n")) { return }
    }
    try {
        [System.IO.File]::WriteAllText($Path, $expected, $utf8)
    } catch {
        throw "failed writing generated file: $Path`n$($_.Exception.Message)"
    }
}

function Sync-CuratedDirectory([string]$Source, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "curated content directory missing: $Source" }
    foreach ($template in Get-ChildItem -LiteralPath $Source -Filter '*.tres' -File | Sort-Object Name) {
        $content = [System.IO.File]::ReadAllText($template.FullName)
        if ((Split-Path -Leaf $Source) -eq 'buildings') {
            $content = Calibrate-CuratedBuilding $content $template.BaseName
        } elseif ((Split-Path -Leaf $Source) -eq 'goods') {
            $content = Normalize-CuratedGood $content $template.BaseName
        }
        Write-Utf8 (Join-Path $Target $template.Name) $content
    }
}

function Assert-FullyManaged([string]$Directory) {
    if ($Scope -eq 'Consumption' -and
        -not (Is-Consumption-Path (Join-Path $Directory '_scope_probe'))) { return }
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.tres' -File) {
        if (-not $managedPaths.Contains([System.IO.Path]::GetFullPath($file.FullName))) {
            if ($Check) { throw "retired generated file remains: $($file.FullName)" }
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
}

function PSArray([string[]]$Values) {
    if ($Values.Count -eq 0) { return 'PackedStringArray()' }
    return 'PackedStringArray(' + (($Values | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ')'
}
function PI64([long[]]$Values) {
    if ($Values.Count -eq 0) { return 'PackedInt64Array()' }
    return 'PackedInt64Array(' + ($Values -join ', ') + ')'
}
function PI32([int[]]$Values) {
    if ($Values.Count -eq 0) { return 'PackedInt32Array()' }
    return 'PackedInt32Array(' + ($Values -join ', ') + ')'
}

# Source rows: natural deposits and cultivated outputs. Species-level livestock
# and freshwater are intentionally absent; pasture and water systems are broader
# capacity/geography concepts, not per-species economic resources.
$resourceRows = @(
    @('timber','林木','logs'), @('stone','石材','raw_stone'),
    @('fertile_soil','肥沃土壤','vegetables'), @('wheat','小麦','wheat_grain'),
    @('rice','水稻','rice_grain'), @('corn','玉米','corn_grain'),
    @('potato','马铃薯','potatoes'), @('coal','煤炭','coal'),
    @('oil','石油','crude_oil'), @('natural_gas','天然气','natural_gas'),
    @('copper_ore','铜矿','copper_ore'), @('iron_ore','铁矿','iron_ore'),
    @('gold_ore','金矿','gold'), @('silver_ore','银矿','silver'),
    @('salt','盐矿','salt'), @('rubber_tree','橡胶林','latex'),
    @('saltpeter','硝石矿','saltpeter'), @('rare_earth','战略矿产','rare_earth_ore'),
    @('clay','黏土','clay'), @('wild_game','野生动物','game_meat'),
    @('spice_plants','香料作物','spices'), @('flax','亚麻','flax_fiber'),
    @('cotton','棉花','cotton_fiber'), @('medicinal_herbs','药用植物','medicinal_herbs'),
    @('marine_fish','海洋鱼类','fish'), @('bauxite','铝土矿','bauxite'),
    @('limestone','石灰岩','limestone'), @('silica_sand','硅砂','silica_sand'),
    @('phosphate_rock','磷矿石','phosphate_rock'), @('tin_ore','锡矿','tin_ore'),
    @('lead_ore','铅矿','lead_ore'), @('zinc_ore','锌矿','zinc_ore'),
    @('manganese_ore','锰矿','manganese_ore'), @('sulfur','硫磺矿','sulfur')
)
$cultivatedResourceIds = @('wheat','rice','corn','potato','rubber_tree',
    'spice_plants','flax','cotton','medicinal_herbs')
$naturalResourceRows = @($resourceRows | Where-Object { $_[0] -notin $cultivatedResourceIds })
$naturalResourceRows += @(
    @('arable_land','旱地承载力',''), @('paddy_land','水田承载力',''),
    @('plantation_land','种植园承载力',''), @('pasture','牧场承载力','')
)

$processedGroups = [ordered]@{
    forestry = @('lumber','paper','packaging','printed_materials','furniture')
    construction = @('bricks','lime','cement','concrete','glass','construction_components')
    food = @('grain','bread','prepared_staples','edible_oil','processed_food',
        'livestock_products','meat','dairy_products','canned_fish','beverages')
    textile = @('fur','raw_hide','leather','wool','cloth','synthetic_fiber','clothing',
        'footwear','fine_clothing')
    chemicals = @('refined_fuel','lubricants','petrochemicals','plastics','synthetic_rubber',
        'industrial_chemicals','fertilizer','explosives','soap','detergent','pharmaceuticals','nuclear_fuel')
    metals = @('steel','stainless_steel','copper','aluminum','tin','lead','zinc',
        'rare_earth_metals','wire')
    machinery = @('tools','machine_parts','industrial_machinery','agricultural_machinery',
        'electric_motor','engines','batteries','electrical_equipment','electronic_components',
        'semiconductors','computers','telecom_equipment','household_appliances','automobiles','railway_equipment')
    consumer = @('jewelry','fine_furniture')
    energy = @('electricity')
}

$goodNames = @{
    logs='原木'; raw_stone='原石'; vegetables='蔬菜'; wheat_grain='小麦';
    rice_grain='稻米'; corn_grain='玉米'; potatoes='马铃薯'; coal='煤炭';
    crude_oil='原油'; natural_gas='天然气'; copper_ore='铜矿石'; iron_ore='铁矿石';
    gold='黄金'; silver='白银'; salt='食盐'; latex='天然乳胶'; saltpeter='硝石';
    rare_earth_ore='战略矿石'; clay='黏土'; horses='马匹'; game_meat='野味';
    spices='香料'; flax_fiber='亚麻纤维'; cotton_fiber='棉纤维'; medicinal_herbs='药材';
    fish='鱼类'; bauxite='铝土矿'; limestone='石灰岩'; silica_sand='硅砂';
    phosphate_rock='磷矿石'; tin_ore='锡矿石'; lead_ore='铅矿石'; zinc_ore='锌矿石';
    manganese_ore='锰矿石'; sulfur='硫磺'; lumber='木材';
    paper='纸张'; packaging='包装材料'; printed_materials='印刷品'; furniture='家具';
    bricks='砖块'; lime='石灰'; cement='水泥'; concrete='混凝土';
    glass='玻璃'; construction_components='建筑构件'; grain='混合谷物';
    bread='面包'; prepared_staples='熟制主食';
    edible_oil='食用油'; processed_food='加工食品'; livestock_products='畜牧产品';
    meat='肉类'; dairy_products='乳制品'; canned_fish='鱼罐头'; beverages='酒饮';
    fur='毛皮'; raw_hide='生皮'; leather='皮革'; wool='羊毛'; cloth='布料';
    synthetic_fiber='合成纤维'; clothing='衣物'; fine_clothing='华服';
    footwear='鞋履'; refined_fuel='精炼燃料'; lubricants='润滑剂';
    petrochemicals='石化产品'; plastics='塑料'; synthetic_rubber='合成橡胶';
    industrial_chemicals='工业化学品'; fertilizer='肥料'; explosives='炸药';
    soap='肥皂'; detergent='洗涤剂'; pharmaceuticals='药品'; nuclear_fuel='核燃料';
    steel='钢材'; stainless_steel='不锈钢'; copper='铜';
    aluminum='铝'; tin='锡'; lead='铅'; zinc='锌';
    rare_earth_metals='战略矿物材料'; wire='金属线材'; tools='金属工具'; machine_parts='机器零件';
    industrial_machinery='工业机械'; agricultural_machinery='农业机械';
    electric_motor='电动机'; engines='发动机'; batteries='电池';
    electrical_equipment='电气设备'; electronic_components='电子元件';
    semiconductors='半导体'; computers='计算机'; telecom_equipment='通信设备';
    household_appliances='家用电器'; automobiles='汽车'; railway_equipment='铁路设备';
    jewelry='珠宝'; fine_furniture='精美家具'; electricity='电力'
}

# Substitution categories describe recipe roles, not industries. A good may
# fulfil several roles; each recipe input slot still opts into one role, an
# explicit weighted candidate list, or one exact good.
$substitutionCategoriesByGood = @{}
function Add-Substitution-Group([string]$CategoryId, [string[]]$GoodIds) {
    foreach ($goodId in $GoodIds) {
        [string[]]$memberships = @()
        if ($substitutionCategoriesByGood.ContainsKey($goodId)) {
            $memberships = [string[]]$substitutionCategoriesByGood[$goodId]
        }
        if ($CategoryId -notin $memberships) {
            $substitutionCategoriesByGood[$goodId] = [string[]]($memberships + @($CategoryId))
        }
    }
}
Add-Substitution-Group 'tools' @('chipped_stone_tools','bronze_tools','tools','precision_tools')
Add-Substitution-Group 'starchy_staple' @('grain','wheat_grain','rice_grain','corn_grain','potatoes')
Add-Substitution-Group 'cereal_grain' @('grain','wheat_grain','rice_grain','corn_grain')
Add-Substitution-Group 'baking_grain' @('grain','wheat_grain','corn_grain')
Add-Substitution-Group 'brewing_feedstock' @('grain','wheat_grain','rice_grain','corn_grain')
Add-Substitution-Group 'spinnable_fiber' @('flax_fiber','cotton_fiber','wool','synthetic_fiber')
Add-Substitution-Group 'natural_spinnable_fiber' @('flax_fiber','cotton_fiber','wool')
Add-Substitution-Group 'guild_textile_fiber' @('flax_fiber','wool')
Add-Substitution-Group 'rag_paper_fiber' @('flax_fiber','cotton_fiber','cloth')
Add-Substitution-Group 'precious_metal' @('gold','silver')
Add-Substitution-Group 'elastomer' @('latex','synthetic_rubber')
Add-Substitution-Group 'prime_mover' @('steam_engines','electric_motor','engines')
Add-Substitution-Group 'industrial_prime_mover' @('steam_engines','electric_motor')
Add-Substitution-Group 'agricultural_prime_mover' @('steam_engines','engines')
Add-Substitution-Group 'ferrous_stock' @('steel','stainless_steel')
Add-Substitution-Group 'structural_metal' @('steel','stainless_steel','aluminum')
Add-Substitution-Group 'processor_component' @('semiconductors','advanced_chips')

function Substitution-Categories-For-Good([string]$GoodId) {
    if ($substitutionCategoriesByGood.ContainsKey($GoodId)) {
        return @($substitutionCategoriesByGood[$GoodId])
    }
    return @($GoodId)
}

function Primary-Substitution-Category-For-Good([string]$GoodId) {
    $categories = @(Substitution-Categories-For-Good $GoodId)
    return $categories[0]
}

function Normalize-CuratedGood([string]$Content, [string]$Id) {
    $categories = @(Substitution-Categories-For-Good $Id)
    $category = $categories[0]
    if (-not [regex]::IsMatch($Content, '(?m)^category_id = &"[^"]+"\r?$')) {
        throw "curated good lacks category_id: $Id"
    }
    $Content = [regex]::Replace($Content, '(?m)^category_id = &"[^"]+"\r?$',
        "category_id = &`"$category`"")
    $membershipLine = 'substitution_category_ids = ' + (PSArray $categories)
    if ([regex]::IsMatch($Content, '(?m)^substitution_category_ids = PackedStringArray\(.*\)\r?$')) {
        return [regex]::Replace($Content,
            '(?m)^substitution_category_ids = PackedStringArray\(.*\)\r?$', $membershipLine)
    }
    return [regex]::Replace($Content, '(?m)^(category_id = &"[^"]+"\r?)$',
        "`$1`n$membershipLine")
}

$goods = [ordered]@{}
function Add-Good([string]$Id, [string]$Name, [string]$Category) {
    if ($goods.Contains($Id)) { throw "duplicate good id: $Id" }
    $goods[$Id] = @{ name=$Name; category=$Category }
}
foreach ($row in $resourceRows) { Add-Good $row[2] $goodNames[$row[2]] 'primary' }
Add-Good 'horses' $goodNames['horses'] 'primary'
foreach ($category in $processedGroups.Keys) {
    foreach ($id in $processedGroups[$category]) {
        if (-not $goods.Contains($id)) {
            Add-Good $id $goodNames[$id] $(if ($id -eq 'tools') { 'tools' } else { $category })
        }
    }
}
if ($goods.Count -lt 100) { throw "generated good baseline unexpectedly small: $($goods.Count)" }

$categoryPrice = @{ primary=10000; forestry=18000; construction=22000; food=16000;
    textile=24000; chemicals=30000; metals=36000; machinery=52000; tools=52000;
    consumer=60000; energy=12000 }
function Technology-For-Good([string]$Id) {
    $technologyByGood = @{
        logs='tech.gathering'; lumber='tech.gathering'; salt='tech.gathering'; gold='tech.gathering'; silver='tech.gathering';
        fish='tech.hunting'; game_meat='tech.hunting'; fur='tech.hunting'; raw_hide='tech.hunting';
        cloth='tech.gathering'; tools='tech.masonry'; clay='tech.pottery';
        raw_stone='tech.stone_knapping'; vegetables='tech.pottery'; wheat_grain='tech.pottery';
        grain='tech.pottery'; bread='tech.pottery'; prepared_staples='tech.pottery';
        rice_grain='tech.pottery'; flax_fiber='tech.pottery';
        livestock_products='tech.pottery'; meat='tech.pottery';
        dairy_products='tech.pottery'; wool='tech.pottery'; leather='tech.pottery';
        processed_food='tech.fire_control'; copper_ore='tech.bronze_casting'; copper='tech.bronze_casting';
        tin_ore='tech.bronze_casting'; tin='tech.bronze_casting'; furniture='tech.pottery';
        bricks='tech.masonry'; lime='tech.masonry'; cement='tech.steam_power'; concrete='tech.steam_power';
        limestone='tech.masonry'; silica_sand='tech.masonry'; glass='tech.masonry'; construction_components='tech.masonry';
        corn_grain='tech.manuscript_culture'; horses='tech.bronze_casting';
        potatoes='tech.guild_organization'; edible_oil='tech.guild_organization';
        clothing='tech.guild_organization'; footwear='tech.guild_organization';
        spices='tech.oceanic_navigation'; latex='tech.oceanic_navigation'; medicinal_herbs='tech.oceanic_navigation';
        cotton_fiber='tech.oceanic_navigation';
        paper='tech.writing'; packaging='tech.printing_press'; printed_materials='tech.printing_press'; canned_fish='tech.precision_engineering';
        beverages='tech.guild_organization'; coal='tech.coke_smelting'; coke='tech.coke_smelting';
        iron_ore='tech.masonry'; agricultural_machinery='tech.steam_power';
        industrial_chemicals='tech.experimental_science'; steel='tech.steam_power';
        industrial_machinery='tech.precision_engineering'; railway_equipment='tech.steam_power';
        electricity='tech.electrification'; electrical_equipment='tech.electrification';
        electric_motor='tech.electrification'; batteries='tech.electrochemistry';
        aluminum='tech.electrochemistry'; automobiles='tech.electrification';
        engines='tech.electrification'; wire='tech.electrification'; refined_fuel='tech.electrification';
        lubricants='tech.steam_power'; natural_gas='tech.electrification'; crude_oil='tech.steam_power';
        petrochemicals='tech.electrochemistry'; plastics='tech.electrochemistry';
        fertilizer='tech.guild_organization'; detergent='tech.electrochemistry';
        household_appliances='tech.electrification'; fine_clothing='tech.guild_organization';
        fine_furniture='tech.guild_organization'; jewelry='tech.bronze_casting';
        electronic_components='tech.radio'; rare_earth_ore='tech.geological_prospecting';
        rare_earth_metals='tech.advanced_metallurgy'; pharmaceuticals='tech.experimental_science';
        nuclear_fuel='tech.nuclear_fission'; semiconductors='tech.digital_computing';
        computers='tech.digital_computing'; telecom_equipment='tech.networked_computing';
        synthetic_fiber='tech.advanced_metallurgy'; synthetic_rubber='tech.advanced_metallurgy';
        stainless_steel='tech.advanced_metallurgy';
        lead_ore='tech.steam_power'; lead='tech.steam_power'; zinc_ore='tech.steam_power';
        zinc='tech.steam_power'; manganese_ore='tech.geological_prospecting';
        bauxite='tech.steam_power'; phosphate_rock='tech.steam_power'; sulfur='tech.experimental_science';
        saltpeter='tech.experimental_science'; explosives='tech.experimental_science';
        soap='tech.guild_organization'; machine_parts='tech.precision_engineering';
        chipped_stone_tools='tech.stone_knapping'; bronze_tools='tech.bronze_casting';
        steam_engines='tech.steam_power'; precision_tools='tech.precision_engineering';
        scientific_instruments='tech.experimental_science';
        advanced_chips='tech.machine_learning'; autonomous_systems='tech.autonomous_systems'
    }
    if ($technologyByGood.ContainsKey($Id)) { return $technologyByGood[$Id] }
    throw "good lacks explicit technology: $Id"
}

function Inventory-Target-Ratio-For-Good([string]$Id) {
    $essential = @('bread','canned_fish','corn_grain','dairy_products','edible_oil','fish',
        'game_meat','grain','livestock_products','meat','potatoes','prepared_staples',
        'processed_food','rice_grain','salt','vegetables','wheat_grain')
    $important = @('clothing','coal','detergent','footwear','medicinal_herbs',
        'natural_gas','pharmaceuticals','refined_fuel','soap')
    $luxury = @('beverages','fine_clothing','fine_furniture','fur','jewelry','spices')
    if ($essential -contains $Id) { return 98304 } # 1.50 x 30 = 45 days.
    if ($important -contains $Id) { return 81920 } # 1.25 x 30 = 37.5 days.
    if ($luxury -contains $Id) { return 43691 } # Approximately 20 days.
    return 65536 # 1.00 x 30 = 30 days.
}

foreach ($id in $goods.Keys) {
    $g = $goods[$id]
    $substitutionCategories = @(Substitution-Categories-For-Good $id)
    $primarySubstitutionCategory = $substitutionCategories[0]
    $substitutionCategoryArray = PSArray $substitutionCategories
    $price = [int]$categoryPrice[$g.category]
    $technology = Technology-For-Good $id
    $demandElasticity = switch ($g.category) {
        'primary' { 29491 } 'food' { 22938 } 'forestry' { 49152 }
        'construction' { 49152 } 'textile' { 58982 } 'chemicals' { 52429 }
        'metals' { 45875 } 'machinery' { 75366 } 'consumer' { 85197 }
        'energy' { 19661 } default { 65536 }
    }
    $inventoryTargetRatio = Inventory-Target-Ratio-For-Good $id
    $priceAdjust = [Math]::Max(512, [int][Math]::Round(2048.0 * $demandElasticity / 65536.0))
    $issue = if ($id -eq 'gold') { 800000 } elseif ($id -eq 'silver') { 50000 } else { 0 }
    $mode = if ($id -eq 'electricity') { 'cycle_flow' } else { 'stock' }
    Write-Utf8 (Join-Path $goodsDir "$id.tres") @"
[gd_resource type="Resource" script_class="GoodProfile" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/data/good_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"$id"
display_name = "$($g.name)"
category_id = &"$primarySubstitutionCategory"
substitution_category_ids = $substitutionCategoryArray
technology_tags = PackedStringArray("industry.$($g.category)", "$technology")
production_quality_level = $(if ($id -eq 'tools') { 3 } else { 0 })
production_efficiency_q16 = 65536
storage_mode = "$mode"
monetary_issue_value = $issue
default_price = $price
initial_stock = 0
min_price = $([Math]::Max(1, [int]($price / 10)))
max_price = $($price * 10)
price_adjust_q16 = $priceAdjust
demand_price_elasticity_q16 = $demandElasticity
demand_ema_alpha_q16 = 16384
inventory_target_ratio_q16 = $(if ($mode -eq 'cycle_flow') { 0 } else { $inventoryTargetRatio })
inventory_weight_q16 = 32768
shortage_weight_q16 = $(if ($mode -eq 'cycle_flow') { 0 } else { 65536 })
excess_demand_weight_q16 = $(if ($mode -eq 'cycle_flow') { 65536 } else { 8192 })
cost_anchor_weight_q16 = $(if ($issue -gt 0) { 0 } else { 16384 })
inactive_reversion_weight_q16 = 512
business_demand_ema_alpha_q16 = $(if ($mode -eq 'cycle_flow') { 16384 } else { 8192 })
supply_ema_alpha_q16 = $(if ($mode -eq 'cycle_flow') { 16384 } else { 8192 })
cost_ema_alpha_q16 = 4096
max_price_rise_q16 = 8192
max_price_fall_q16 = 4096
merchant_buy_price_factor_q16 = 62259
"@
}

$professionRows = @(
    @('landlord','地主','owner_household','tech.bronze_casting'),
    @('merchant','商人','merchant_household','tech.gathering'),
    @('subsistence_farmer','自给农民','survival_household','tech.pottery'),
    @('worker','工人','industrial_worker_household','tech.steam_power'),
    @('industrialist','工业资本家','owner_household','tech.steam_power'),
    @('agricultural_worker','农业工人','agrarian_household','tech.pottery'),
    @('pastoralist','牧民','agrarian_household','tech.pottery'),
    @('hunter','猎人','hunter_household','tech.hunting'),
    @('fisher','渔民','agrarian_household','tech.hunting'),
    @('forestry_worker','林业工人','agrarian_household','tech.gathering'),
    @('miner','矿工','extractive_household','tech.gathering'),
    @('petroleum_worker','石油工人','extractive_household','tech.steam_power'),
    @('construction_worker','建筑工人','industrial_worker_household','tech.masonry'),
    @('artisan','工匠','artisan_household','tech.gathering'),
    @('industrial_worker','产业工人','industrial_worker_household','tech.steam_power'),
    @('machinist','机械师','technical_household','tech.precision_engineering'),
    @('technician','技术员','technical_household','tech.electrification'),
    @('engineer','工程师','technical_household','tech.precision_engineering'),
    @('chemist','化学家','technical_household','tech.experimental_science'),
    @('metallurgist','冶金师','artisan_household','tech.bronze_casting'),
    @('electrician','电工','technical_household','tech.electrification'),
    @('transport_worker','运输工人','industrial_worker_household','tech.oceanic_navigation'),
    @('guild_master','行会师傅','artisan_household','tech.guild_organization'),
    @('forager','采集者','survival_household','tech.gathering'),
    @('enslaved_laborer','奴隶劳工','survival_household','tech.bronze_casting'),
    @('serf','农奴','survival_household','tech.manuscript_culture'),
    @('tenant_farmer','佃农','agrarian_household','tech.guild_organization'),
    @('indentured_laborer','契约劳工','agrarian_household','tech.oceanic_navigation'),
    @('apprentice','学徒','survival_household','tech.pottery'),
    @('journeyman','熟练工','artisan_household','tech.writing'),
    @('manager','经理','technical_household','tech.steam_power'),
    @('researcher','研究员','technical_household','tech.experimental_science'),
    @('unemployed','失业者','plan_unemployed','')
)
if ($professionRows.Count -ne 33) { throw 'profession catalog baseline must be 33' }
foreach ($row in $professionRows) {
    $professionTechnologyTags = if ([string]::IsNullOrWhiteSpace([string]$row[3])) {
        'PackedStringArray()'
    } else {
        'PackedStringArray("' + [string]$row[3] + '")'
    }
    Write-Utf8 (Join-Path $professionsDir "$($row[0]).tres") @"
[gd_resource type="Resource" script_class="ProfessionProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/profession_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$($row[0])"
display_name = "$($row[1])"
default_consumption_plan_id = &"$($row[2])"
technology_tags = $professionTechnologyTags
"@
}

$needRows = @(
    @('staple_food','食品',65536), @('protein','食品',65536),
    @('produce','食品',65536), @('clothing','衣着',65536),
    @('housing','居住维护',65536), @('household_goods','家庭用品',32768),
    @('hygiene','清洁卫生',65536), @('healthcare','医疗保健',65536),
    @('home_energy','家庭能源',65536), @('transport','个人交通',32768),
    @('communication','通信',32768), @('education_culture','教育与文化',0),
    @('recreation','休闲娱乐',0), @('durable_goods','耐用消费品',0),
    @('work_equipment','职业装备',32768), @('luxury','奢侈消费',0),
    @('status_goods','身份消费',0)
)
foreach ($row in $needRows) {
    Write-Utf8 (Join-Path $needsDir "$($row[0]).tres") @"
[gd_resource type="Resource" script_class="NeedProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/need_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$($row[0])"
display_name = "$($row[1])"
living_cost_weight_q16 = $($row[2])
"@
}

$needSpecs = @(
    @{id='staple_food'; tier='essential'; base=550; wealth=4096; min=49152; max=81920; price=98304; quantityPrice=16384; quantityFloor=32768;
        variants=@(@('prepared_staples'),@('bread'),@('grain'),@('gathered_plants'))},
    @{id='protein'; tier='essential'; base=180; wealth=16384; min=32768; max=131072; price=98304; quantityPrice=98304; quantityFloor=9830;
        variants=@(@('game_meat'),@('meat'),@('fish'),@('canned_fish'),@('dairy_products'))},
    @{id='produce'; tier='essential'; base=300; wealth=16384; min=32768; max=131072; price=98304; quantityPrice=65536; quantityFloor=4096;
        variants=@(@('vegetables'),@('processed_food'))},
    @{id='clothing'; tier='essential'; base=3; wealth=32768; min=16384; max=196608; price=65536; quantityPrice=32768; quantityFloor=16384;
        variants=@(@('cloth'),@('fur'),@('clothing'),@('footwear'))},
    @{id='housing'; tier='essential'; base=5; wealth=32768; min=16384; max=196608; price=65536;
        variants=@(@('construction_components'))},
    @{id='household_goods'; tier='comfort'; base=2; wealth=49152; min=8192; max=262144; price=49152;
        variants=@(@('pottery'),@('furniture'))},
    @{id='hygiene'; tier='essential'; base=10; wealth=32768; min=16384; max=196608; price=65536;
        variants=@(@('soap'),@('detergent'))},
    @{id='healthcare'; tier='essential'; base=3; wealth=32768; min=16384; max=196608; price=32768;
        variants=@(@('medicinal_herbs'),@('pharmaceuticals'))},
    @{id='home_energy'; tier='essential'; base=80; wealth=32768; min=16384; max=196608; price=65536;
        variants=@(@('logs'),@('coal'),@('natural_gas'),@('refined_fuel'))},
    @{id='transport'; tier='comfort'; base=3; wealth=49152; min=8192; max=262144; price=49152;
        variants=@(@('horses'),@('automobiles','refined_fuel'))},
    @{id='communication'; tier='comfort'; base=1; wealth=49152; min=8192; max=262144; price=49152;
        variants=@(@('radio_equipment'),@('telecom_equipment'))},
    @{id='education_culture'; tier='comfort'; base=2; wealth=49152; min=8192; max=262144; price=49152;
        variants=@(@('manuscripts'),@('printed_materials'),@('computers'))},
    @{id='recreation'; tier='comfort'; base=3; wealth=49152; min=8192; max=262144; price=49152;
        variants=@(@('beverages'),@('computers'))},
    @{id='durable_goods'; tier='luxury'; base=1; wealth=65536; min=4096; max=393216; price=32768;
        variants=@(@('household_appliances'),@('autonomous_systems'))},
    @{id='work_equipment'; tier='comfort'; base=2; wealth=49152; min=8192; max=262144; price=49152;
        variants=@(@('chipped_stone_tools'),@('bronze_tools'),@('tools'),@('precision_tools'))},
    @{id='luxury'; tier='luxury'; base=1; wealth=98304; min=1024; max=524288; price=32768;
        variants=@(@('beverages'),@('fine_clothing'),@('fine_furniture'))},
    @{id='status_goods'; tier='luxury'; base=1; wealth=98304; min=1024; max=524288; price=32768;
        variants=@(@('jewelry'),@('fur'),@('spices'))}
)

function Write-Plan([string]$Id, [string]$Name, [string[]]$IncludedNeeds,
        [int]$EssentialScale, [int]$ComfortScale, [int]$LuxuryScale,
        [hashtable]$PreferenceOverrides) {
    $needIds = @(); $priorities = @(); $base = @(); $elasticity = @(); $mins = @(); $maxs = @(); $quantityPrice = @(); $quantityFloor = @(); $env = @()
    $needOffsets = @(0); $variantIds = @(); $preferences = @(); $variantElasticity = @(); $variantEnv = @()
    $componentOffsets = @(0); $componentIds = @(); $componentQty = @()
    $v = 0; $c = 0
    foreach ($needId in $IncludedNeeds) {
        $spec = $needSpecs | Where-Object { $_.id -eq $needId } | Select-Object -First 1
        if ($null -eq $spec) { throw "unknown need in plan ${Id}: $needId" }
        $n = $needIds.Count; $needIds += $spec.id; $priorities += $n
        $scale = switch ($spec.tier) {
            'essential' { $EssentialScale }
            'comfort' { $ComfortScale }
            'luxury' { $LuxuryScale }
            default { throw "unknown need tier in plan ${Id}: $($spec.tier)" }
        }
        $scaledBase = [int][Math]::Floor(([int64]$spec.base * $scale + 50) / 100.0)
        $base += [Math]::Max(1, $scaledBase)
        $elasticity += [int]$spec.wealth
        $mins += [int]$spec.min
        $maxs += [int]$spec.max
        $quantityPrice += $(if ($spec.ContainsKey('quantityPrice')) { [int]$spec.quantityPrice } elseif ($spec.tier -eq 'comfort') { 98304 } elseif ($spec.tier -eq 'luxury') { 131072 } else { 65536 })
        $quantityFloor += $(if ($spec.ContainsKey('quantityFloor')) { [int]$spec.quantityFloor } elseif ($spec.tier -eq 'essential') { 4096 } else { 0 })
        $env += $(if ($spec.id -eq 'clothing') { 'cold_clothing_quantity' } else { '' })
        foreach ($variant in $spec.variants) {
            $variantIds += "$($spec.id)_$v"
            $preferenceGood = [string]$variant[0]
            $preferences += $(if ($PreferenceOverrides.ContainsKey($preferenceGood)) {
                [int]$PreferenceOverrides[$preferenceGood]
            } else { 65536 })
            $variantElasticity += [int]$spec.price
            $variantEnv += $(if ($spec.id -eq 'clothing' -and $variant -contains 'fur') { 'cold_fur_preference' } elseif ($spec.id -eq 'clothing') { 'warm_cloth_preference' } else { '' })
            foreach ($good in $variant) { $componentIds += $good; $componentQty += 1000; $c++ }
            $componentOffsets += $c; $v++
        }
        $needOffsets += $v
    }
    if ($componentIds.Count -gt 64) { throw "plan component limit: $Id" }
    Write-Utf8 (Join-Path $plansDir "$Id.tres") @"
[gd_resource type="Resource" script_class="ConsumptionPlanProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/consumption_plan_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$Id"
display_name = "$Name"
need_ids = $(PSArray $needIds)
priorities = $(PI32 $priorities)
base_qty_per_person = $(PI64 $base)
wealth_elasticity_q16 = $(PI32 $elasticity)
wealth_min_q16 = $(PI32 $mins)
wealth_max_q16 = $(PI32 $maxs)
price_quantity_elasticity_q16 = $(PI32 $quantityPrice)
price_quantity_floor_q16 = $(PI32 $quantityFloor)
quantity_env_curve_ids = $(PSArray $env)
need_variant_offsets = $(PI32 $needOffsets)
variant_ids = $(PSArray $variantIds)
variant_preference_q16 = $(PI32 $preferences)
variant_price_elasticity_q16 = $(PI32 $variantElasticity)
variant_preference_env_curve_ids = $(PSArray $variantEnv)
variant_component_offsets = $(PI32 $componentOffsets)
component_good_ids = $(PSArray $componentIds)
component_qty_per_need = $(PI64 $componentQty)
"@
}
$coreNeeds = @('staple_food','protein','produce','clothing','housing','household_goods',
    'hygiene','healthcare','home_energy')
Write-Plan 'plan_unemployed' '失业者生存消费' @('staple_food') 80 0 0 @{
    grain=81920; gathered_plants=98304
}
Write-Plan 'survival_household' '生存型家庭消费' $coreNeeds 80 35 0 @{
    gathered_plants=98304; grain=81920; cloth=81920; fur=73728; logs=98304; medicinal_herbs=81920
}
Write-Plan 'agrarian_household' '农业型家庭消费' `
    ($coreNeeds + @('transport','work_equipment','recreation')) 95 75 0 @{
    prepared_staples=81920; tools=98304; horses=81920; pottery=73728; vegetables=81920
}
Write-Plan 'hunter_household' '狩猎家庭消费' `
    ($coreNeeds + @('work_equipment')) 85 40 0 @{
    gathered_plants=81920; game_meat=98304; fur=81920; logs=81920
    chipped_stone_tools=81920; medicinal_herbs=81920
}
Write-Plan 'extractive_household' '采掘型家庭消费' `
    ($coreNeeds + @('transport','work_equipment')) 105 85 0 @{
    meat=81920; coal=81920; refined_fuel=81920; precision_tools=81920; tools=73728
}
Write-Plan 'industrial_worker_household' '产业工人家庭消费' `
    ($coreNeeds + @('transport','work_equipment')) 100 85 0 @{
    bread=81920; clothing=81920; automobiles=81920; tools=81920
}
Write-Plan 'artisan_household' '工匠型家庭消费' `
    ($coreNeeds + @('education_culture','work_equipment','luxury')) 105 105 80 @{
    clothing=81920; precision_tools=98304; manuscripts=81920; fine_furniture=73728
}
Write-Plan 'technical_household' '技术型家庭消费' `
    ($coreNeeds + @('transport','communication','education_culture','recreation','durable_goods','work_equipment','luxury')) 110 125 120 @{
    precision_tools=81920; computers=98304; telecom_equipment=81920; pharmaceuticals=81920
}
Write-Plan 'merchant_household' '商人家庭消费' `
    ($coreNeeds + @('transport','communication','education_culture','recreation','durable_goods','luxury','status_goods')) 115 150 180 @{
    automobiles=81920; telecom_equipment=81920; beverages=81920; jewelry=98304; spices=81920
}
Write-Plan 'owner_household' '业主家庭消费' `
    ($coreNeeds + @('transport','communication','education_culture','recreation','durable_goods','luxury','status_goods')) 120 175 240 @{
    fine_clothing=98304; fine_furniture=98304; jewelry=98304; fur=81920; automobiles=81920
}

$deps = @{
    lumber=@('logs'); paper=@('logs','industrial_chemicals');
    packaging=@('paper'); printed_materials=@('paper'); furniture=@('lumber','cloth');
    bricks=@('clay'); lime=@('limestone');
    cement=@('lime','clay'); concrete=@('cement','raw_stone'); glass=@('silica_sand');
    construction_components=@('concrete','steel','glass');
    grain=@(); bread=@('wheat_grain'); prepared_staples=@('grain');
    edible_oil=@('corn_grain'); processed_food=@('prepared_staples','meat','vegetables','edible_oil','packaging');
    livestock_products=@(); meat=@('livestock_products'); dairy_products=@('livestock_products');
    canned_fish=@('fish','salt','packaging'); beverages=@('grain','packaging');
    raw_hide=@('livestock_products'); leather=@('raw_hide','industrial_chemicals'); wool=@('livestock_products');
    cloth=@('flax_fiber'); synthetic_fiber=@('petrochemicals'); clothing=@('cloth');
    fine_clothing=@('cloth','fur'); fine_furniture=@('lumber','cloth');
    footwear=@('leather');
    refined_fuel=@('crude_oil'); lubricants=@('crude_oil'); petrochemicals=@('crude_oil','natural_gas');
    plastics=@('petrochemicals'); synthetic_rubber=@('petrochemicals','sulfur');
    industrial_chemicals=@('sulfur','salt'); fertilizer=@('phosphate_rock','natural_gas');
    explosives=@('saltpeter','sulfur'); soap=@('edible_oil','salt'); detergent=@('petrochemicals','industrial_chemicals');
    pharmaceuticals=@('medicinal_herbs','industrial_chemicals'); nuclear_fuel=@('rare_earth_metals');
    steel=@('iron_ore','electricity');
    stainless_steel=@('steel','rare_earth_metals','manganese_ore'); copper=@('copper_ore','coal');
    aluminum=@('bauxite','electricity'); tin=@('tin_ore','coal'); lead=@('lead_ore','coal');
    zinc=@('zinc_ore','coal');
    rare_earth_metals=@('rare_earth_ore'); wire=@('copper');
    tools=@('steel','lumber'); machine_parts=@('steel','lubricants');
    industrial_machinery=@('machine_parts','steam_engines'); agricultural_machinery=@('industrial_machinery','steam_engines');
    electric_motor=@('copper','steel'); engines=@('steel','aluminum','machine_parts','lubricants');
    batteries=@('lead','industrial_chemicals'); electrical_equipment=@('wire','steel','plastics');
    electronic_components=@('copper','tin','zinc','plastics');
    semiconductors=@('silica_sand','industrial_chemicals','electricity');
    computers=@('semiconductors','electronic_components','plastics');
    telecom_equipment=@('semiconductors','electronic_components','wire','batteries','plastics');
    household_appliances=@('electrical_equipment','steel','plastics');
    automobiles=@('engines','steel','batteries','latex');
    railway_equipment=@('steel','electric_motor','tools');
    jewelry=@('gold'); electricity=@('coal')
}

function Collector-Id([string]$Resource) {
    switch ($Resource) {
        'wheat' {'wheat_farm'} 'corn' {'landed_estate'} 'coal' {'coal_mine'}
        'gold_ore' {'gold_mine'} 'silver_ore' {'silver_mine'} default {"${Resource}_collector"}
    }
}
function Collector-Display-Name([string]$Resource,[string]$ResourceName) {
    switch ($Resource) {
        'fertile_soil' {'菜蔬农场'} 'wheat' {'小麦农场'} 'rice' {'稻作农场'}
        'corn' {'玉米庄园'} 'potato' {'马铃薯农场'} 'flax' {'亚麻农场'}
        'cotton' {'棉花农场'} 'spice_plants' {'香料种植园'}
        'rubber_tree' {'橡胶种植园'} 'medicinal_herbs' {'药材种植园'}
        'marine_fish' {'沿岸渔场'} 'timber' {'伐木场'}
        'clay' {'黏土坑'} 'stone' {'采石场'} 'limestone' {'石灰石采石场'}
        'silica_sand' {'硅砂矿'} 'salt' {'盐场'}
        'oil' {'油田'} 'natural_gas' {'天然气田'}
        'coal' {'煤矿'} 'gold_ore' {'金矿'} 'silver_ore' {'银矿'}
        'copper_ore' {'铜矿'} 'iron_ore' {'铁矿'} 'tin_ore' {'锡矿'}
        'lead_ore' {'铅矿'} 'zinc_ore' {'锌矿'} 'manganese_ore' {'锰矿'}
        'bauxite' {'铝土矿'} 'phosphate_rock' {'磷矿'} 'sulfur' {'硫矿'}
        'saltpeter' {'硝石矿'} 'rare_earth' {'战略矿山'}
        default {"${ResourceName}采掘场"}
    }
}
function Worker-For-Resource([string]$Resource) {
    if ($Resource -in @('wheat','rice','corn','potato','fertile_soil','spice_plants','flax','cotton','medicinal_herbs')) { return 'agricultural_worker' }
    if ($Resource -eq 'wild_game') { return 'hunter' }
    if ($Resource -eq 'marine_fish') { return 'fisher' }
    if ($Resource -eq 'stone') { return 'forager' }
    if ($Resource -eq 'timber') { return 'forestry_worker' }
    if ($Resource -in @('oil','natural_gas')) { return 'petroleum_worker' }
    return 'miner'
}
function Worker-For-Output([string]$GoodId,[string]$Category) {
    if ($GoodId -in @('electronic_components','semiconductors','computers','telecom_equipment',
        'advanced_chips','autonomous_systems','radio_equipment','reactor_components')) {
        return 'technician'
    }
    switch ($Category) {
        'construction' { return 'construction_worker' }
        'food' { return 'industrial_worker' }
        'chemicals' { return 'chemist' }
        'metals' { return 'metallurgist' }
        'machinery' { return 'machinist' }
        'energy' { return 'electrician' }
        'forestry' { return 'artisan' }
        'textile' { return 'artisan' }
        'consumer' { return 'artisan' }
        default { return 'technician' }
    }
}
function Technology-For-Building([string]$Id) {
    if ($Id -eq 'marine_fish_collector') { return 'tech.hunting' }
    if ($Id -in @('timber_collector','lumber_plant')) { return 'tech.gathering' }
    if ($Id -in @('stone_collector','flint_quarry')) { return 'tech.stone_knapping' }
    if ($Id -in @('wheat_farm','rice_collector','fertile_soil_collector','flax_collector',
        'pastoral_camp','bakery','staple_kitchen',
        'slaughterhouse','creamery','tannery','wool_shed')) { return 'tech.pottery' }
    if ($Id -in @('early_copper_mine','early_tin_mine','early_copper_smelter','early_tin_smelter')) { return 'tech.bronze_casting' }
    if ($Id -in @('classical_masonry_yard','classical_glass_kiln','classical_silica_pit',
        'early_iron_mine','iron_tool_workshop','clay_collector','copper_ore_collector','tin_ore_collector',
        'bricks_plant','lime_plant','pottery_kiln','salt_collector','limestone_collector')) { return 'tech.masonry' }
    if ($Id -in @('landed_estate','horse_breeder')) { return 'tech.manuscript_culture' }
    if ($Id -in @('potato_collector','manorial_pasture','guild_weaving_house','tailor_shop',
        'cobbler_shop','brewery','composting_yard','court_tailor','cabinetmaker_workshop',
        'soap_plant')) { return 'tech.guild_organization' }
    if ($Id -in @('cotton_collector','spice_plants_collector','rubber_tree_collector','medicinal_herbs_collector')) { return 'tech.oceanic_navigation' }
    if ($Id -in @('packaging_plant','printed_materials_plant',
        'rag_paper_workshop','distillery')) { return 'tech.printing_press' }
    if ($Id -in @('industrial_chemicals_plant','explosives_plant','sulfur_collector',
        'saltpeter_collector','pharmaceuticals_plant','canning_workshop')) { return 'tech.experimental_science' }
    if ($Id -in @('industrial_machinery_plant','machine_parts_plant')) { return 'tech.steam_power' }
    if ($Id -in @('coal_mine','coke_ovens')) { return 'tech.coke_smelting' }
    if ($Id -in @('bread_plant','staple_food_plant','mechanized_farm','mechanized_slaughterhouse',
        'ranching_station','dairy_products_plant','leather_plant','textile_mill','clothing_plant',
        'footwear_plant','steam_coal_mine','steam_iron_mine','steam_steel_works','glass_plant',
        'iron_ore_collector','paper_plant','cement_plant','concrete_plant','construction_components_plant','tools_plant','canned_fish_plant',
        'agricultural_machinery_plant','gold_mine','silver_mine','lubricants_plant','silica_sand_collector',
        'bauxite_collector','lead_ore_collector','lead_plant','zinc_ore_collector','zinc_plant',
        'tin_plant','copper_plant','furniture_plant','early_oil_well','industrial_salt_mine')) { return 'tech.steam_power' }
    if ($Id -in @('electricity_plant','electric_motor_plant','electrical_equipment_plant',
        'engines_plant','automobiles_plant','household_appliances_plant','wire_plant','steel_plant','railway_equipment_plant',
        'oil_collector','natural_gas_collector','refined_fuel_plant',
        'gas_power_plant','oil_power_plant','processed_food_plant','beverages_plant','cloth_plant','intensive_farm',
        'fine_clothing_plant','fine_furniture_plant','jewelry_plant')) { return 'tech.electrification' }
    if ($Id -in @('aluminum_plant','batteries_plant','fertilizer_plant','detergent_plant',
        'petrochemicals_plant','plastics_plant','electrochemical_works')) { return 'tech.electrochemistry' }
    if ($Id -eq 'electronic_components_plant') { return 'tech.radio' }
    if ($Id -eq 'rare_earth_collector') { return 'tech.geological_prospecting' }
    if ($Id -eq 'rare_earth_metals_plant') { return 'tech.advanced_metallurgy' }
    if ($Id -in @('manganese_ore_collector','stainless_steel_plant',
        'synthetic_fiber_plant','synthetic_rubber_plant','synthetic_textile_mill')) { return 'tech.advanced_metallurgy' }
    if ($Id -eq 'nuclear_fuel_plant' -or $Id -eq 'nuclear_power_plant') { return 'tech.nuclear_fission' }
    if ($Id -in @('semiconductors_plant','computers_plant')) { return 'tech.digital_computing' }
    if ($Id -eq 'telecom_equipment_plant') { return 'tech.networked_computing' }
    return ''
}
function Technology-Rank([string]$Technology) {
    $rank = @{
        'tech.hunting'=0; 'tech.gathering'=0; 'tech.stone_knapping'=0; 'tech.fire_control'=0;
        'tech.pottery'=1; 'tech.bronze_casting'=1; 'tech.writing'=2; 'tech.masonry'=2;
        'tech.manuscript_culture'=3; 'tech.guild_organization'=3; 'tech.oceanic_navigation'=4;
        'tech.printing_press'=4; 'tech.experimental_science'=5; 'tech.precision_engineering'=5;
        'tech.coke_smelting'=6; 'tech.steam_power'=6; 'tech.electrification'=7; 'tech.radio'=7;
        'tech.electrochemistry'=7; 'tech.geological_prospecting'=8; 'tech.advanced_metallurgy'=8;
        'tech.nuclear_fission'=8; 'tech.digital_computing'=9; 'tech.networked_computing'=9;
        'tech.machine_learning'=10; 'tech.autonomous_systems'=10
    }
    if ($rank.ContainsKey($Technology)) { return [int]$rank[$Technology] }
    return 99
}

function Tool-Min-Quality-For-Rank([int]$Rank) {
    if ($Rank -le 0) { return 1 }
    if ($Rank -le 3) { return 2 }
    if ($Rank -le 8) { return 3 }
    return 4
}

function Extraction-Ratio-For-Building([string]$Id) {
    if ($Id -eq 'stone_age_hunting_camp') { return 2 }
    if ($Id -in @('early_clay_pit','early_copper_mine','early_tin_mine')) { return 2 }
    if ($Id -eq 'classical_silica_pit') { return 4 }
    if ($Id -in @('steam_coal_mine','steam_iron_mine')) { return 12 }
    if ($Id -eq 'marine_fish_collector') { return 8 }
    if ($Id -in @('clay_collector','limestone_collector','silica_sand_collector','stone_collector','salt_collector')) { return 10 }
    if ($Id -eq 'timber_collector') { return 16 }
    if ($Id -in @('oil_collector','natural_gas_collector','rare_earth_collector')) { return 25 }
    return 20
}

function Default-Price-For-Good([string]$Id) {
    $path = Join-Path $goodsDir "$Id.tres"
    if (-not (Test-Path -LiteralPath $path)) { throw "good price source missing: $Id" }
    $match = [regex]::Match([System.IO.File]::ReadAllText($path), '(?m)^default_price = (\d+)\r?$')
    if (-not $match.Success) { return [long]10000 }
    return [long]$match.Groups[1].Value
}

function Good-Integer-Field([string]$Id, [string]$Field, [int]$DefaultValue) {
    $path = Join-Path $goodsDir "$Id.tres"
    if (-not (Test-Path -LiteralPath $path)) { return $DefaultValue }
    $match = [regex]::Match([System.IO.File]::ReadAllText($path), "(?m)^${Field} = (\d+)\r?$")
    return $(if ($match.Success) { [int]$match.Groups[1].Value } else { $DefaultValue })
}

function Cheapest-Tool-Effective-Price([int]$MaxRank, [int]$MinQuality) {
    $best = [double]::PositiveInfinity
    foreach ($toolId in @('chipped_stone_tools','bronze_tools','tools','precision_tools')) {
        if ((Technology-Rank (Technology-For-Good $toolId)) -gt $MaxRank) { continue }
        $quality = Good-Integer-Field $toolId 'production_quality_level' 0
        if ($quality -lt $MinQuality) { continue }
        $efficiency = Good-Integer-Field $toolId 'production_efficiency_q16' 65536
        $best = [Math]::Min($best,
            [double](Default-Price-For-Good $toolId) * 65536.0 / [Math]::Max(1, $efficiency))
    }
    return $best
}

function Cheapest-Category-Effective-Price([string]$CategoryId, [int]$MaxRank, [int]$MinQuality) {
    $best = [double]::PositiveInfinity
    foreach ($goodId in @($substitutionCategoriesByGood.Keys | Sort-Object)) {
        if ($CategoryId -notin @(Substitution-Categories-For-Good $goodId) -or
            (Technology-Rank (Technology-For-Good $goodId)) -gt $MaxRank) { continue }
        $quality = Good-Integer-Field $goodId 'production_quality_level' 0
        if ($quality -lt $MinQuality) { continue }
        $efficiency = Good-Integer-Field $goodId 'production_efficiency_q16' 65536
        $best = [Math]::Min($best,
            [double](Default-Price-For-Good $goodId) * 65536.0 / [Math]::Max(1, $efficiency))
    }
    if ([double]::IsPositiveInfinity($best)) {
        throw "no era-compatible category candidate during calibration: $CategoryId"
    }
    return $best
}

function Content-Strings([string]$Content, [string]$Field) {
    $match = [regex]::Match($Content, "(?m)^${Field} = PackedStringArray\((.*)\)\r?$")
    if (-not $match.Success) { return @() }
    return @([regex]::Matches($match.Groups[1].Value, '"([^"]*)"') |
        ForEach-Object { $_.Groups[1].Value })
}

function Content-Numbers([string]$Content, [string]$Field) {
    $match = [regex]::Match($Content, "(?m)^${Field} = PackedInt(?:32|64)Array\((.*)\)\r?$")
    if (-not $match.Success) { return @() }
    return @([regex]::Matches($match.Groups[1].Value, '-?\d+') |
        ForEach-Object { [long]$_.Value })
}

function Content-String([string]$Content, [string]$Field, [string]$DefaultValue = '') {
    $pattern = '(?m)^' + [regex]::Escape($Field) + ' = &?"([^"]*)"\r?$'
    $match = [regex]::Match($Content, $pattern)
    return $(if ($match.Success) { $match.Groups[1].Value } else { $DefaultValue })
}

function Content-Integer([string]$Content, [string]$Field, [long]$DefaultValue = 0) {
    $match = [regex]::Match($Content, "(?m)^${Field} = (-?\d+)\r?$")
    return $(if ($match.Success) { [long]$match.Groups[1].Value } else { $DefaultValue })
}

$referenceLivingCostByPlan = @{}
function Reference-Living-Cost-For-Plan([string]$PlanId) {
    if ($referenceLivingCostByPlan.ContainsKey($PlanId)) {
        return [long]$referenceLivingCostByPlan[$PlanId]
    }
    $path = Join-Path $plansDir "$PlanId.tres"
    if (-not (Test-Path -LiteralPath $path)) { throw "living-cost plan missing: $PlanId" }
    $content = [System.IO.File]::ReadAllText($path)
    $needIds = @(Content-Strings $content 'need_ids')
    $baseQty = @(Content-Numbers $content 'base_qty_per_person')
    $variantOffsets = @(Content-Numbers $content 'need_variant_offsets')
    $preferences = @(Content-Numbers $content 'variant_preference_q16')
    $componentOffsets = @(Content-Numbers $content 'variant_component_offsets')
    $componentGoods = @(Content-Strings $content 'component_good_ids')
    $componentQty = @(Content-Numbers $content 'component_qty_per_need')
    if ($needIds.Count -ne $baseQty.Count -or $variantOffsets.Count -ne $needIds.Count + 1) {
        throw "living-cost plan columns mismatch: $PlanId"
    }
    [double]$total = 0
    for ($needIndex = 0; $needIndex -lt $needIds.Count; $needIndex++) {
        $needPath = Join-Path $needsDir "$($needIds[$needIndex]).tres"
        if (-not (Test-Path -LiteralPath $needPath)) {
            throw "living-cost need missing: $($needIds[$needIndex])"
        }
        $needContent = [System.IO.File]::ReadAllText($needPath)
        $livingWeight = Content-Integer $needContent 'living_cost_weight_q16' 0
        if ($livingWeight -le 0) { continue }
        [long]$scoreSum = 0
        [double]$weightedPrice = 0
        for ($variant = [int]$variantOffsets[$needIndex];
                $variant -lt [int]$variantOffsets[$needIndex + 1]; $variant++) {
            [double]$unitPrice = 0
            for ($component = [int]$componentOffsets[$variant];
                    $component -lt [int]$componentOffsets[$variant + 1]; $component++) {
                $unitPrice += [double]$componentQty[$component] *
                    [double](Default-Price-For-Good $componentGoods[$component]) / 1000.0
            }
            $score = [long]$preferences[$variant]
            $scoreSum += $score
            $weightedPrice += $unitPrice * [double]$score
        }
        if ($scoreSum -le 0) { continue }
        $quantity = [double]$baseQty[$needIndex] * [double]$livingWeight / 65536.0
        $total += $quantity * ($weightedPrice / [double]$scoreSum) / 1000.0
    }
    $result = [long][Math]::Ceiling($total)
    $referenceLivingCostByPlan[$PlanId] = $result
    return $result
}

function Reference-Living-Cost-For-Profession([string]$ProfessionId) {
    $path = Join-Path $professionsDir "$ProfessionId.tres"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "living-cost profession missing: $ProfessionId"
    }
    $planId = Content-String ([System.IO.File]::ReadAllText($path)) 'default_consumption_plan_id'
    if ([string]::IsNullOrWhiteSpace($planId)) {
        throw "profession living-cost plan missing: $ProfessionId"
    }
    return Reference-Living-Cost-For-Plan $planId
}

function Calibrate-CuratedBuilding([string]$Content, [string]$Id) {
    $inputs = @(Content-Strings $Content 'input_good_ids')
    $inputQty = @(Content-Numbers $Content 'input_quantities_per_day')
    $inputCategories = @(Content-Strings $Content 'input_category_ids')
    $inputMinLevels = @(Content-Numbers $Content 'input_min_quality_levels')
    $outputs = @(Content-Strings $Content 'output_good_ids')
    $outputQty = @(Content-Numbers $Content 'output_quantities_per_day')
    $roleSlots = @(Content-Numbers $Content 'employee_slots_per_building')
    $roleIds = @(Content-Strings $Content 'employee_profession_ids')
    $roleWages = @(Content-Numbers $Content 'employee_reference_wages_per_day')
    $technologyTags = @(Content-Strings $Content 'technology_tags')
    $ownerSlots = Content-Integer $Content 'owner_slots_per_building' 1
    $jobs = [long]$ownerSlots + [long](($roleSlots | Measure-Object -Sum).Sum)
    $recipeInputOverrides = @{
        # Keep early local chains financeable without inflating their output merely
        # to pay for excessive intermediate consumption.
        bronze_tool_workshop = [long[]]@(1500, 500)
        ore_bronzesmith_camp = [long[]]@(500, 500, 500)
    }
    if ($recipeInputOverrides.ContainsKey($Id)) {
        $inputQty = @($recipeInputOverrides[$Id])
    }
    for ($i = 0; $i -lt [Math]::Min($inputs.Count, $inputQty.Count); $i++) {
        $isTool = $inputs[$i] -in @('chipped_stone_tools','bronze_tools','tools','precision_tools') -or
            ($i -lt $inputCategories.Count -and $inputCategories[$i] -eq 'tools')
        if (-not $isTool) { continue }
        $toolCap = [Math]::Max(1, $jobs * 100)
        $inputQty[$i] = [Math]::Min([long]$inputQty[$i], [long]$toolCap)
    }
    if ($Id -eq 'stone_age_hunting_camp' -and $inputs.Count -eq 1 -and
            $inputs[0] -eq 'chipped_stone_tools') {
        # One local knapping workshop must be able to equip the resource-supported
        # hunting camps created by the mid-stone bootstrap.
        $inputQty[0] = 5
    }
    if ($inputs.Count -gt 0 -and $inputQty.Count -eq $inputs.Count) {
        $Content = [regex]::Replace($Content,
            '(?m)^input_quantities_per_day = PackedInt64Array\(.*\)\r?$',
            'input_quantities_per_day = ' + (PI64 @($inputQty)))
    }
    $buildingRank = -1
    foreach ($technologyTag in $technologyTags) {
        if ($technologyTag.StartsWith('tech.')) {
            $buildingRank = [Math]::Max($buildingRank, (Technology-Rank $technologyTag))
        }
    }
    if ($inputMinLevels.Count -lt $inputs.Count) {
        $inputMinLevels = @(for ($i = 0; $i -lt $inputs.Count; $i++) {
            if ($i -lt $inputMinLevels.Count) { [int]$inputMinLevels[$i] } else { 0 }
        })
    }
    for ($i = 0; $i -lt [Math]::Min($inputs.Count, $inputCategories.Count); $i++) {
        if ($inputCategories[$i] -eq 'tools') {
            $inputMinLevels[$i] = Tool-Min-Quality-For-Rank $buildingRank
        }
    }
    if ($inputs.Count -gt 0) {
        $minimumLine = 'input_min_quality_levels = ' + (PI32 @($inputMinLevels))
        if ([regex]::IsMatch($Content, '(?m)^input_min_quality_levels = PackedInt32Array\(.*\)\r?$')) {
            $Content = [regex]::Replace($Content,
                '(?m)^input_min_quality_levels = PackedInt32Array\(.*\)\r?$', $minimumLine)
        } elseif (@($inputCategories | Where-Object { $_ -eq 'tools' }).Count -gt 0) {
            $Content = [regex]::Replace($Content,
                '(?m)^(input_category_ids = PackedStringArray\(.*\)\r?)$', "`$1`n$minimumLine")
        }
    }
    if ($outputs.Count -eq 0 -or $outputQty.Count -ne $outputs.Count) { return $Content }
    $cost = [double]0
    for ($i = 0; $i -lt [Math]::Min($inputs.Count, $inputQty.Count); $i++) {
        $effectivePrice = [double](Default-Price-For-Good $inputs[$i])
        if ($i -lt $inputCategories.Count -and $inputCategories[$i] -eq 'tools') {
            $minimum = if ($i -lt $inputMinLevels.Count) { [int]$inputMinLevels[$i] } else { 0 }
            $effectivePrice = Cheapest-Tool-Effective-Price $buildingRank $minimum
        }
        $cost += [double]$inputQty[$i] * $effectivePrice / 1000.0
    }
    for ($i = 0; $i -lt [Math]::Min($roleIds.Count, $roleWages.Count); $i++) {
        $roleWages[$i] = [Math]::Max(
            [long]$roleWages[$i], (Reference-Living-Cost-For-Profession $roleIds[$i]))
    }
    if ($roleWages.Count -gt 0) {
        $Content = [regex]::Replace($Content,
            '(?m)^employee_reference_wages_per_day = PackedInt64Array\(.*\)\r?$',
            'employee_reference_wages_per_day = ' + (PI64 @($roleWages)))
        if ($roleWages.Count -eq 1 -and
            [regex]::IsMatch($Content, '(?m)^wage_per_employee_per_day = \d+\r?$')) {
            $Content = [regex]::Replace($Content,
                '(?m)^wage_per_employee_per_day = \d+\r?$',
                "wage_per_employee_per_day = $($roleWages[0])")
        }
    }
    for ($i = 0; $i -lt [Math]::Min($roleSlots.Count, $roleWages.Count); $i++) {
        $cost += [double]$roleSlots[$i] * [double]$roleWages[$i]
    }
    if ($Id -in @('knapping_workshop', 'communal_hearth')) {
        # These Stone Age recipes are physical balance anchors. Price and living-cost
        # calibration must not silently rewrite their audited throughput.
        return $Content
    }
    if ($outputs -contains 'gold' -or $outputs -contains 'silver') { return $Content }
    $ownerId = Content-String $Content 'owner_profession_id'
    $ownerSlots = [Math]::Max(1, (Content-Integer $Content 'owner_slots_per_building' 1))
    $ownerLivingCost = [double](Reference-Living-Cost-For-Profession $ownerId) * $ownerSlots
    $marginMatch = [regex]::Match($Content, '(?m)^target_operating_margin_q16 = (\d+)\r?$')
    $targetMargin = if ($marginMatch.Success) { [int]$marginMatch.Groups[1].Value } else { 9830 }
    if (@($outputs | Where-Object { $_ -in @('jewelry','fine_clothing','fine_furniture') }).Count -gt 0) {
        $targetMargin = 13107
    }
    $marginRevenue = [Math]::Ceiling(
        $cost * 65536.0 / [Math]::Max(1, 65536 - $targetMargin))
    $breakEvenRevenue = [Math]::Max(
        $marginRevenue, [Math]::Ceiling($cost + $ownerLivingCost))
    $requiredRevenue = [Math]::Ceiling(
        $breakEvenRevenue * 65536.0 / $DesignSellThroughQ16)
    [double]$baseRevenue = 0
    for ($i = 0; $i -lt $outputs.Count; $i++) {
        $baseRevenue += [double]$outputQty[$i] *
            [double](Default-Price-For-Good $outputs[$i]) / 1000.0 * 62259.0 / 65536.0
    }
    if ($baseRevenue -le 0) { throw "curated building output value missing: $Id" }
    $scale = [double]$requiredRevenue / $baseRevenue
    $scaledOutputQty = @($outputQty | ForEach-Object {
        [long][Math]::Max(1, [Math]::Ceiling([double]$_ * $scale))
    })
    $Content = [regex]::Replace($Content,
        '(?m)^output_quantities_per_day = PackedInt64Array\(.*\)\r?$',
        'output_quantities_per_day = ' + (PI64 @($scaledOutputQty)))
    $resourceModes = @(Content-Strings $Content 'resource_interaction_modes')
    $resourceQty = @(Content-Numbers $Content 'resource_quantities_per_day')
    $extractCount = @($resourceModes | Where-Object { $_ -eq 'extract' }).Count
    if ($extractCount -gt 0 -and $resourceQty.Count -eq $resourceModes.Count) {
        $outputTotal = [long](($scaledOutputQty | Measure-Object -Sum).Sum)
        $extractQty = if ($Id -eq 'stone_age_hunting_camp') {
            # Wild-game capacity is the binding ecological constraint. Preserve
            # the field-tested depletion rate while shifting the catch away from
            # stockpiling hide and fur.
            [long]715
        } else {
            [long][Math]::Max(1, [Math]::Floor(
                $outputTotal / ((Extraction-Ratio-For-Building $Id) * $extractCount)))
        }
        for ($i = 0; $i -lt $resourceModes.Count; $i++) {
            if ($resourceModes[$i] -eq 'extract') { $resourceQty[$i] = $extractQty }
        }
        $Content = [regex]::Replace($Content,
            '(?m)^resource_quantities_per_day = PackedInt64Array\(.*\)\r?$',
            'resource_quantities_per_day = ' + (PI64 @($resourceQty)))
    }
    return $Content
}

$explicitInputCandidates = @{
    bakery = @(@{ goods=@('wheat_grain','grain','corn_grain'); efficiencies=@(65536,58982,49152) })
    bread_plant = @(@{ goods=@('wheat_grain','grain','corn_grain'); efficiencies=@(65536,58982,49152) }, $null)
    rag_paper_workshop = @(@{ goods=@('flax_fiber','cotton_fiber','cloth'); efficiencies=@(65536,65536,49152) })
    paper_plant = @(@{ goods=@('logs','flax_fiber','cotton_fiber'); efficiencies=@(65536,49152,49152) }, $null)
    brewery = @(@{ goods=@('grain','wheat_grain','rice_grain','corn_grain'); efficiencies=@(65536,65536,58982,58982) })
    distillery = @(@{ goods=@('grain','wheat_grain','rice_grain','corn_grain'); efficiencies=@(65536,65536,58982,58982) }, $null)
    beverages_plant = @(@{ goods=@('grain','wheat_grain','rice_grain','corn_grain'); efficiencies=@(65536,65536,58982,58982) }, $null)
    processed_food_plant = @(
        @{ goods=@('prepared_staples','bread'); efficiencies=@(65536,58982) },
        @{ goods=@('meat','fish','game_meat','dairy_products'); efficiencies=@(65536,65536,58982,58982) },
        $null, $null, $null)
    footwear_plant = @(
        @{ goods=@('leather','cloth'); efficiencies=@(65536,49152) },
        @{ goods=@('latex','synthetic_rubber'); efficiencies=@(49152,65536) })
    insulated_cable_plant = @(
        $null,
        @{ goods=@('plastics','synthetic_rubber'); efficiencies=@(65536,65536) })
    packaging_plant = @(@{ goods=@('paper','glass','steel','aluminum','plastics'); efficiencies=@(65536,49152,58982,78643,78643) })
    furniture_plant = @($null, @{ goods=@('cloth','leather'); efficiencies=@(65536,65536) })
    cabinetmaker_workshop = @($null, @{ goods=@('cloth','leather'); efficiencies=@(65536,65536) })
    fine_furniture_plant = @($null, @{ goods=@('cloth','leather'); efficiencies=@(65536,65536) }, $null)
    soap_plant = @(@{ goods=@('edible_oil','livestock_products'); efficiencies=@(65536,49152) }, $null)
    tools_plant = @(
        @{ goods=@('steel','stainless_steel'); efficiencies=@(65536,78643) },
        @{ goods=@('lumber','plastics'); efficiencies=@(65536,78643) })
    machine_parts_plant = @(
        @{ goods=@('steel','stainless_steel','aluminum'); efficiencies=@(65536,78643,49152) },
        @{ goods=@('lubricants','edible_oil'); efficiencies=@(65536,32768) })
    wire_plant = @(@{ goods=@('copper','aluminum'); efficiencies=@(65536,49152) })
    batteries_plant = @(@{ goods=@('lead','rare_earth_metals'); efficiencies=@(65536,98304) }, $null)
    electric_motor_plant = @(
        @{ goods=@('copper','aluminum'); efficiencies=@(65536,49152) },
        @{ goods=@('steel','aluminum'); efficiencies=@(65536,58982) })
    construction_components_plant = @(
        $null,
        @{ goods=@('steel','stainless_steel','aluminum'); efficiencies=@(65536,65536,58982) },
        $null)
    copper_plant = @($null, @{ goods=@('coal','coke'); efficiencies=@(65536,78643) })
    tin_plant = @($null, @{ goods=@('coal','coke'); efficiencies=@(65536,78643) })
    lead_plant = @($null, @{ goods=@('coal','coke'); efficiencies=@(65536,78643) })
    zinc_plant = @($null, @{ goods=@('coal','coke'); efficiencies=@(65536,78643) })
    lubricants_plant = @(@{ goods=@('crude_oil','petrochemicals'); efficiencies=@(65536,78643) })
    industrial_machinery_plant = @($null, @{ goods=@('steam_engines','electric_motor'); efficiencies=@(49152,65536) })
    agricultural_machinery_plant = @($null, @{ goods=@('steam_engines','engines'); efficiencies=@(49152,65536) })
    automobiles_plant = @(
        $null,
        @{ goods=@('steel','stainless_steel','aluminum'); efficiencies=@(65536,62259,58982) },
        $null,
        @{ goods=@('latex','synthetic_rubber'); efficiencies=@(49152,65536) })
    electrical_equipment_plant = @(
        $null,
        @{ goods=@('steel','aluminum'); efficiencies=@(65536,58982) },
        $null)
    railway_equipment_plant = @(
        @{ goods=@('steel','stainless_steel'); efficiencies=@(65536,62259) },
        $null,
        $null)
    computers_plant = @(
        @{ goods=@('semiconductors','advanced_chips'); efficiencies=@(65536,131072) },
        $null,
        $null)
    telecom_equipment_plant = @(
        @{ goods=@('semiconductors','advanced_chips'); efficiencies=@(65536,131072) },
        $null,
        $null,
        $null,
        $null)
    household_appliances_plant = @($null, @{ goods=@('steel','stainless_steel','aluminum'); efficiencies=@(49152,65536,58982) }, $null)
    jewelry_plant = @(@{ goods=@('gold','silver','rare_earth_metals'); efficiencies=@(65536,65536,49152) })
    synthetic_textile_mill = @(@{ goods=@('synthetic_fiber','cotton_fiber','flax_fiber','wool'); efficiencies=@(65536,49152,49152,49152) }, $null)
}

# Category slots are used only where every member is genuinely equivalent for
# this recipe. Weighted or narrower choices remain explicit candidates above.
$inputCategoryOverrides = @{
    staple_kitchen = @('starchy_staple')
    staple_food_plant = @('starchy_staple', '')
    goldsmith_workshop = @('precious_metal')
    guild_weaving_house = @('guild_textile_fiber')
    textile_mill = @('natural_spinnable_fiber', '')
    cloth_plant = @('natural_spinnable_fiber', '')
}

function Write-Building([string]$Id,[string]$Name,[string]$Kind,[string]$Owner,[string]$Worker,
    [string[]]$Inputs,[string[]]$Outputs,[string[]]$Resources,[string[]]$ResourceModes,
    [string]$Behavior,[string]$Category,[string]$Family = '',[int]$Tier = 0,
    [string]$TechnologyOverride = '',[long[]]$InputQuantityOverride = @(),
    [string]$RecipeSourceId = '') {
    $unitQty = switch ($Id) {
        'marine_fish_collector' { [long]3600 }
        'pastoral_camp' { [long]3000 } 'manorial_pasture' { [long]5000 }
        'ranching_station' { [long]9000 } 'horse_breeding_camp' { [long]700 }
        'horse_breeder' { [long]1200 }
        'mechanized_farm' { [long]9000 }
        'intensive_farm' { [long]12000 }
        'village_mill' { [long]3000 } 'bakery' { [long]2500 } 'rice_kitchen' { [long]2500 }
        'corn_grinding_house' { [long]2500 } 'potato_kitchen' { [long]2500 }
        'slaughterhouse' { [long]5000 } 'creamery' { [long]4000 } 'tannery' { [long]3000 }
        'wool_shed' { [long]2500 } 'flax_spinning_shed' { [long]2500 }
        'flour_plant' { [long]11000 } 'bread_plant' { [long]11000 }
        'rice_food_plant' { [long]10000 } 'corn_food_plant' { [long]10000 }
        'potato_food_plant' { [long]10000 } 'mechanized_slaughterhouse' { [long]12000 }
        'dairy_products_plant' { [long]11000 } 'leather_plant' { [long]10000 }
        'flax_yarn_plant' { [long]10000 } 'textile_mill' { [long]11000 }
        'synthetic_textile_mill' { [long]13000 }
        'cloth_plant' { [long]11000 } 'clothing_plant' { [long]9000 } 'footwear_plant' { [long]9000 }
        'electricity_plant' { [long]9000 } 'gas_power_plant' { [long]12000 }
        'oil_power_plant' { [long]10500 } 'nuclear_power_plant' { [long]18000 }
        default { [long]10000 }
    }
    $technology = $TechnologyOverride
    if ($technology -eq '') { $technology = Technology-For-Building $Id }
    if ($technology -eq '') {
        if ($Outputs.Count -eq 0) { throw "building lacks output technology: $Id" }
        $technology = Technology-For-Good $Outputs[0]
    }
    $rank = Technology-Rank $technology
    [long[]]$inputQtySeed = if ($Inputs.Count -eq 0) {
        @()
    } elseif ($InputQuantityOverride.Count -gt 0) {
        @($InputQuantityOverride | ForEach-Object { [long]$_ })
    } else {
        @($Inputs | ForEach-Object { [long]1000 })
    }
    if ($InputQuantityOverride.Count -gt 0 -and $InputQuantityOverride.Count -ne $Inputs.Count) {
        throw "input quantity override mismatch: $Id"
    }
    $workshopToolUsers = @('guild_weaving_house','tailor_shop','cobbler_shop','brewery','distillery',
        'rag_paper_workshop','goldsmith_workshop','court_tailor','cabinetmaker_workshop',
        'composting_yard','tannery','wool_shed','edible_oil_plant','soap_plant',
        'packaging_plant','printed_materials_plant','industrial_chemicals_plant',
        'explosives_plant','pharmaceuticals_plant')
    if ($Kind -eq 'industrial' -and $Id -in $workshopToolUsers -and
        $Outputs -notcontains 'tools' -and $Inputs -notcontains 'tools') {
        $Inputs += 'tools'; $inputQtySeed += [long]250
    }
    # Factory operating inputs model maintenance/tooling, installed machinery,
    # and electric drive without creating a second production subsystem.
    if ($Kind -eq 'industrial' -and $rank -ge 6 -and
        $Outputs -notcontains 'tools' -and $Inputs -notcontains 'tools') {
        $Inputs += 'tools'; $inputQtySeed += [long]300
    }
    if ($Kind -eq 'industrial' -and $rank -ge 7 -and
        $Outputs -notcontains 'electricity' -and $Inputs -notcontains 'electricity') {
        $Inputs += 'electricity'; $inputQtySeed += [long]600
    }
    if ($Kind -eq 'industrial' -and $rank -ge 7 -and
        $Outputs -notcontains 'electricity' -and $Outputs -notcontains 'industrial_machinery' -and
        $Inputs -notcontains 'industrial_machinery') {
        $Inputs += 'industrial_machinery'; $inputQtySeed += [long]200
    }
    [long[]]$inputQty = $inputQtySeed
    $outputQty = @($Outputs | ForEach-Object { $unitQty })
    $outputTotal = [long](($outputQty | Measure-Object -Sum).Sum)
    $extractCount = @($ResourceModes | Where-Object { $_ -eq 'extract' }).Count
    $extractionRatio = Extraction-Ratio-For-Building $Id
    $extractQty = if ($extractCount -gt 0) {
        [long][Math]::Max(1, [Math]::Floor($outputTotal / ($extractionRatio * $extractCount)))
    } else { [long]0 }
    $resourceQty = @(
        for ($i = 0; $i -lt $Resources.Count; $i++) {
            if ($ResourceModes[$i] -eq 'extract') { $extractQty } else { $unitQty }
        }
    )
    if ($Id -eq 'marine_fish_collector') { $resourceQty = @([long]242) }
    $resourceAccessModes = @($Resources | ForEach-Object { 'local' })
    [string[]]$roleIds = @()
    [long[]]$roleSlots = @()
    [string[]]$roleWagePolicies = @()
    [long[]]$roleWages = @()
    if ($Outputs.Count -eq 1 -and $Outputs[0] -in @('gold','silver') -and
        $Kind -eq 'collector' -and $rank -lt 6) {
        $Owner = 'merchant'
    } elseif ($rank -eq 0) {
        # Stone-age production is owner-operated. Choose the producer cohort
        # that performs the work instead of manufacturing an employer class.
        if ($Kind -eq 'collector') {
            if ($Id -eq 'timber_collector') { $Owner = 'forager' }
            elseif ($Worker -ne '') { $Owner = $Worker }
        } else {
            $Owner = 'artisan'
        }
    } elseif ($Id -in @('rice_collector','potato_collector','fertile_soil_collector','wheat_farm','flax_collector')) {
        $Owner = 'subsistence_farmer'
    } elseif ($Id -in @('landed_estate','manorial_pasture')) {
        $Owner = 'landlord'; $roleIds = @('serf'); $roleSlots = @(10)
        $roleWagePolicies = @('fixed'); $roleWages = @(1000)
    } elseif ($Id -in @('pastoral_camp','horse_breeding_camp')) {
        $Owner = 'pastoralist'
    } elseif ($Id -eq 'horse_breeder') {
        $Owner = 'landlord'; $roleIds = @('pastoralist'); $roleSlots = @(8)
        $roleWagePolicies = @('fixed'); $roleWages = @(2000)
    } elseif ($Id -in @('cotton_collector','spice_plants_collector','rubber_tree_collector','medicinal_herbs_collector')) {
        $Owner = 'landlord'; $roleIds = @('indentured_laborer'); $roleSlots = @(10)
        $roleWagePolicies = @('fixed'); $roleWages = @(1500)
    } elseif ($Id -eq 'flax_collector') {
        $Owner = 'subsistence_farmer'
    } elseif ($Id -eq 'timber_collector') {
        $Owner = 'forager'
    } elseif ($Kind -eq 'collector' -and
        @($Resources | Where-Object { $_ -in @('arable_land','paddy_land','plantation_land','pasture') }).Count -gt 0) {
        # Mechanization changes farm labor and capital inputs, not land ownership.
        # Keep commercial land-based agriculture landlord-owned unless a distinct
        # farm-owner/corporate-agriculture profession is modeled explicitly.
        if ($rank -lt 6) {
            $Owner = 'landlord'; $roleIds = @('tenant_farmer')
            $roleSlots = @((12 + 2 * [Math]::Max(0, $rank - 3)))
            $roleWagePolicies = @('fixed'); $roleWages = @(2200)
        } else {
            $Owner = 'landlord'; $roleIds = @('agricultural_worker','manager')
            $roleSlots = @((24 + 4 * ($rank - 6)), (2 + [Math]::Floor(($rank - 6) / 2)))
            $roleWagePolicies = @('adaptive','adaptive'); $roleWages = @(5000,9000)
        }
    } elseif ($Id -eq 'lumber_plant') {
        $Owner = 'artisan'; $roleIds = @('forestry_worker'); $roleSlots = @(4)
        $roleWagePolicies = @('fixed'); $roleWages = @(1500)
    } elseif ($Id -in @('bakery','staple_kitchen','slaughterhouse','creamery')) {
        $Owner = 'artisan'; $roleIds = @('apprentice'); $roleSlots = @(3)
        $roleWagePolicies = @('fixed'); $roleWages = @(1000)
    } elseif ($Kind -eq 'collector' -and $rank -lt 6) {
        if ($Worker -ne '') { $Owner = $Worker }
        if ($Worker -ne '') {
            $roleIds = @($Worker); $roleSlots = @(8)
            $roleWagePolicies = @('fixed'); $roleWages = @(1500)
        }
    } elseif ($Kind -eq 'collector') {
        $Owner = 'industrialist'; $roleIds = @($Worker, 'manager'); $roleSlots = @(14, 2)
        $roleWagePolicies = @('adaptive', 'adaptive'); $roleWages = @(5000, 9000)
    } else {
        if ($rank -lt 3) {
            $Owner = 'artisan'
        } elseif ($rank -lt 6) {
            $Owner = 'guild_master'; $roleIds = @('apprentice', 'journeyman'); $roleSlots = @(6, 4)
            $roleWagePolicies = @('fixed', 'fixed'); $roleWages = @(1000, 2500)
        } else {
            $Owner = 'industrialist'
        }
        if ($rank -lt 3) {
            if ($Id -notin @('knapping_workshop','communal_hearth','ore_bronzesmith_camp')) {
                $roleIds = @('apprentice'); $roleSlots = @(3)
                $roleWagePolicies = @('fixed'); $roleWages = @(1000)
            }
        } elseif ($rank -lt 6) {
            $roleIds = @('apprentice','journeyman')
            $roleSlots = @((6 + [Math]::Max(0, $rank - 3)), (6 + [Math]::Max(0, $rank - 3)))
            $roleWagePolicies = @('fixed','fixed'); $roleWages = @(1000,2500)
        } elseif ($rank -eq 6 -and $Worker -eq 'industrial_worker') {
            $roleIds = @('industrial_worker', 'manager'); $roleSlots = @(20, 2)
            $roleWagePolicies = @('adaptive', 'adaptive'); $roleWages = @(5000, 9000)
        } elseif ($rank -eq 6) {
            $roleIds = @('industrial_worker', $Worker, 'manager'); $roleSlots = @(16, 6, 2)
            $roleWagePolicies = @('adaptive', 'adaptive', 'adaptive'); $roleWages = @(5000, 7000, 9000)
        } elseif ($rank -le 8) {
            $roleIds = if ($Worker -eq 'technician') {
                @('industrial_worker','technician','engineer','manager')
            } elseif ($Worker -eq 'industrial_worker') {
                @('industrial_worker','technician','manager')
            } else { @('industrial_worker',$Worker,'technician','manager') }
            $roleSlots = if ($Worker -eq 'technician') {
                @((24 + 4 * ($rank - 7)), (8 + 2 * ($rank - 7)), 4, 3)
            } elseif ($Worker -eq 'industrial_worker') {
                @((28 + 4 * ($rank - 7)), (4 + 2 * ($rank - 7)), 3)
            } else { @((24 + 4 * ($rank - 7)), (8 + 2 * ($rank - 7)), 4, 3) }
            $roleWagePolicies = @($roleIds | ForEach-Object { 'adaptive' })
            $roleWages = @($roleIds | ForEach-Object {
                switch ($_) { 'industrial_worker' {5000} 'manager' {9000} default {7000} }
            })
        } else {
            $roleIds = if ($Worker -eq 'technician') {
                @('industrial_worker','technician','engineer','researcher','manager')
            } elseif ($Worker -eq 'industrial_worker') {
                @('industrial_worker','technician','engineer','manager')
            } else { @('industrial_worker',$Worker,'technician','engineer','manager') }
            $roleSlots = if ($rank -eq 9) {
                if ($Worker -eq 'technician') { @(24,12,8,4,4) }
                elseif ($Worker -eq 'industrial_worker') { @(34,8,5,4) }
                else { @(30,10,7,4,4) }
            } else {
                if ($Worker -eq 'technician') { @(26,16,10,6,4) }
                elseif ($Worker -eq 'industrial_worker') { @(36,12,8,4) }
                else { @(32,12,9,6,4) }
            }
            $roleWagePolicies = @($roleIds | ForEach-Object { 'adaptive' })
            $roleWages = @($roleIds | ForEach-Object {
                switch ($_) { 'industrial_worker' {5000} 'manager' {9000} 'researcher' {8500} default {7000} }
            })
        }
    }
    for ($roleIndex = 0; $roleIndex -lt $roleIds.Count; $roleIndex++) {
        $roleWages[$roleIndex] = [Math]::Max(
            [long]$roleWages[$roleIndex],
            (Reference-Living-Cost-For-Profession $roleIds[$roleIndex]))
    }
    $candidateOffsets = @(0); $candidateGoodIds = @(); $candidateEfficiencies = @()
    $candidateSpecs = @()
    $recipeKey = if ([string]::IsNullOrWhiteSpace($RecipeSourceId)) { $Id } else { $RecipeSourceId }
    if ($explicitInputCandidates.ContainsKey($recipeKey)) {
        $rawCandidateSpecs = $explicitInputCandidates[$recipeKey]
        if ($rawCandidateSpecs -is [hashtable]) {
            $candidateSpecs += ,$rawCandidateSpecs
        } else {
            foreach ($candidateSlot in $rawCandidateSpecs) { $candidateSpecs += ,$candidateSlot }
        }
    }
    if ($candidateSpecs.Count -gt $Inputs.Count) {
        throw "explicit input candidate slot mismatch: $Id candidates=$($candidateSpecs.Count) inputs=$($Inputs.Count)"
    }
    while ($candidateSpecs.Count -gt 0 -and $candidateSpecs.Count -lt $Inputs.Count) {
        $candidateSpecs += ,$null
    }
    [string[]]$categoryOverrides = if ($inputCategoryOverrides.ContainsKey($recipeKey)) {
        $inputCategoryOverrides[$recipeKey]
    } else { @() }
    if ($categoryOverrides.Count -gt $Inputs.Count) {
        throw "input category slot mismatch: $Id categories=$($categoryOverrides.Count) inputs=$($Inputs.Count)"
    }
    while ($categoryOverrides.Count -gt 0 -and $categoryOverrides.Count -lt $Inputs.Count) {
        $categoryOverrides += ''
    }
    $inputCategories = @()
    for ($inputIndex = 0; $inputIndex -lt $Inputs.Count; $inputIndex++) {
        $candidateSpec = if ($candidateSpecs.Count -gt 0) { $candidateSpecs[$inputIndex] } else { $null }
        $categoryOverride = if ($categoryOverrides.Count -gt 0) { $categoryOverrides[$inputIndex] } else { '' }
        if ($null -ne $candidateSpec -and @($candidateSpec.goods).Count -gt 0) {
            if (-not [string]::IsNullOrWhiteSpace($categoryOverride)) {
                throw "explicit candidates cannot share an input slot with a category: $Id input $inputIndex"
            }
            $candidateGoods = @($candidateSpec.goods); $candidateEfficiency = @($candidateSpec.efficiencies)
            if ($candidateGoods.Count -ne $candidateEfficiency.Count -or $Inputs[$inputIndex] -notin $candidateGoods) {
                throw "invalid explicit input candidate definition: $Id"
            }
            $candidateGoodIds += $candidateGoods
            $candidateEfficiencies += $candidateEfficiency
            $inputCategories += ''
        } else {
            $inputCategories += $(if (-not [string]::IsNullOrWhiteSpace($categoryOverride)) {
                $categoryOverride
            } elseif ($Inputs[$inputIndex] -eq 'tools') { 'tools' } else { '' })
        }
        $candidateOffsets += $candidateGoodIds.Count
    }
    $inputMinLevels = @($Inputs | ForEach-Object {
        if ($_ -ne 'tools') { 0 } else { Tool-Min-Quality-For-Rank $rank }
    })
    if ($Id -eq 'ore_bronzesmith_camp') {
        $inputQty = [long[]]@(500, 500, 500)
    }
    $jobs = [long]1 + [long](($roleSlots | Measure-Object -Sum).Sum)
    for ($inputIndex = 0; $inputIndex -lt $Inputs.Count; $inputIndex++) {
        $isTool = $Inputs[$inputIndex] -in @(
            'chipped_stone_tools','bronze_tools','tools','precision_tools') -or
            ($inputIndex -lt $inputCategories.Count -and
             $inputCategories[$inputIndex] -eq 'tools')
        if (-not $isTool) { continue }
        $inputQty[$inputIndex] = [Math]::Min(
            [long]$inputQty[$inputIndex], [long][Math]::Max(1, $jobs * 100))
    }
    $generationIds = @(); $generationQty = @(); $floor = 0
    $targetMargin = if ($Kind -eq 'collector') { 6554 } else { 9830 }
    $supplyElasticity = if ($Kind -eq 'collector') { 32768 } else { 65536 }
    if ($Outputs -contains 'electricity') { $targetMargin = 5243; $supplyElasticity = 16384 }
    if ($Outputs | Where-Object { $_ -in @('jewelry','fine_clothing','fine_furniture') }) {
        $targetMargin = 13107
    }
    $dailyInputCost = [long]0
    for ($inputIndex = 0; $inputIndex -lt $Inputs.Count; $inputIndex++) {
        $effectivePrice = [double](Default-Price-For-Good $Inputs[$inputIndex])
        if ($candidateSpecs.Count -gt 0 -and $null -ne $candidateSpecs[$inputIndex] -and
            @($candidateSpecs[$inputIndex].goods).Count -gt 0) {
            $effectivePrice = [double]::PositiveInfinity
            $candidateGoods = @($candidateSpecs[$inputIndex].goods)
            $candidateEfficienciesForCost = @($candidateSpecs[$inputIndex].efficiencies)
            for ($candidateIndex = 0; $candidateIndex -lt $candidateGoods.Count; $candidateIndex++) {
                $candidateTechnology = Technology-For-Good $candidateGoods[$candidateIndex]
                if ((Technology-Rank $candidateTechnology) -gt $rank) { continue }
                $effectivePrice = [Math]::Min($effectivePrice,
                    [double](Default-Price-For-Good $candidateGoods[$candidateIndex]) * 65536.0 /
                    [double]$candidateEfficienciesForCost[$candidateIndex])
            }
            if ([double]::IsPositiveInfinity($effectivePrice)) {
                throw "no era-compatible candidate during calibration: $Id input $inputIndex"
            }
        } elseif ($inputIndex -lt $inputCategories.Count -and
            -not [string]::IsNullOrWhiteSpace($inputCategories[$inputIndex])) {
            $effectivePrice = if ($inputCategories[$inputIndex] -eq 'tools') {
                Cheapest-Tool-Effective-Price $rank $inputMinLevels[$inputIndex]
            } else {
                Cheapest-Category-Effective-Price $inputCategories[$inputIndex] $rank $inputMinLevels[$inputIndex]
            }
        }
        $dailyInputCost += [long][Math]::Ceiling(
            [double]$inputQty[$inputIndex] * $effectivePrice / 1000.0)
    }
    $dailyWageCost = [long]0
    for ($roleIndex = 0; $roleIndex -lt $roleSlots.Count; $roleIndex++) {
        $dailyWageCost += [long]$roleSlots[$roleIndex] * [long]$roleWages[$roleIndex]
    }
    $dailyCost = $dailyInputCost + $dailyWageCost
    $ownerLivingCost = Reference-Living-Cost-For-Profession $Owner
    if (-not ($Outputs | Where-Object { $_ -in @('gold','silver') })) {
        $outputPriceTotal = [long]0
        foreach ($output in $Outputs) { $outputPriceTotal += Default-Price-For-Good $output }
        $marginRevenue = [long][Math]::Ceiling(
            [double]$dailyCost * 65536.0 / [Math]::Max(1, 65536 - $targetMargin))
        $breakEvenRevenue = [long][Math]::Max(
            $marginRevenue, [Math]::Ceiling([double]$dailyCost + $ownerLivingCost))
        $requiredRevenue = [long][Math]::Ceiling(
            [double]$breakEvenRevenue * 65536.0 / $DesignSellThroughQ16)
        $unitQty = [long][Math]::Ceiling(
            [double]$requiredRevenue * 1000.0 * 65536.0 / [Math]::Max(1.0, [double]$outputPriceTotal * 62259.0))
        if ($Id -eq 'marine_fish_collector') {
            # A coastal fishing unit is intentionally a small owner-operated
            # producer. Keep a modest food buffer without the former three-owner
            # cost multiplier or an industrial-scale catch.
            $unitQty = [Math]::Max([long]2000, $unitQty)
        }
        if ($unitQty -lt 1) { $unitQty = 1 }
        if ($unitQty -gt 10000000) { throw "implausible calibrated output quantity: $Id -> $unitQty" }
        $calibratedRevenue = [double]$unitQty * [double]$outputPriceTotal / 1000.0 * 62259.0 / 65536.0
        if ($calibratedRevenue -le $dailyCost) {
            throw "unprofitable generated recipe after calibration: $Id revenue=$calibratedRevenue cost=$dailyCost"
        }
        $outputQty = @($Outputs | ForEach-Object { $unitQty })
        $outputTotal = [long](($outputQty | Measure-Object -Sum).Sum)
        $extractQty = if ($extractCount -gt 0) {
            [long][Math]::Max(1, [Math]::Floor($outputTotal / ($extractionRatio * $extractCount)))
        } else { [long]0 }
        $resourceQty = @(
            for ($i = 0; $i -lt $Resources.Count; $i++) {
                if ($ResourceModes[$i] -eq 'extract') { $extractQty } else { $unitQty }
            }
        )
    }
    if ($Behavior -eq 'cultivate_local_resources') {
        $generationIds = $Resources; $generationQty = @($Resources | ForEach-Object { [long]1050 }); $floor = 6554
    }
    Write-Utf8 (Join-Path $buildingsDir "$Id.tres") @"
[gd_resource type="Resource" script_class="BuildingProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$Id"
display_name = "$Name"
building_kind = "$Kind"
technology_tags = PackedStringArray("industry.$Category", "$technology")
upgrade_family_id = &"$Family"
upgrade_tier = $Tier
construction_days = 0
owner_profession_id = &"$Owner"
owner_slots_per_building = 1
employee_profession_ids = $(PSArray $roleIds)
employee_slots_per_building = $(PI64 $roleSlots)
employee_wage_policy_ids = $(PSArray $roleWagePolicies)
employee_reference_wages_per_day = $(PI64 $roleWages)
input_good_ids = $(PSArray $Inputs)
input_quantities_per_day = $(PI64 $inputQty)
input_category_ids = $(PSArray $inputCategories)
input_min_quality_levels = $(PI32 $inputMinLevels)
input_candidate_offsets = $(PI32 $candidateOffsets)
input_candidate_good_ids = $(PSArray $candidateGoodIds)
input_candidate_efficiency_q16 = $(PI32 $candidateEfficiencies)
output_good_ids = $(PSArray $Outputs)
output_quantities_per_day = $(PI64 $outputQty)
target_operating_margin_q16 = $targetMargin
supply_price_elasticity_q16 = $supplyElasticity
resource_ids = $(PSArray $Resources)
resource_quantities_per_day = $(PI64 $resourceQty)
resource_interaction_modes = $(PSArray $ResourceModes)
resource_access_modes = $(PSArray $resourceAccessModes)
resource_generation_ids = $(PSArray $generationIds)
resource_generation_quantities_per_day = $(PI64 $generationQty)
resource_generation_floor_q16 = $floor
behavior_id = "$Behavior"
"@
}

$buildingIds = [System.Collections.Generic.HashSet[string]]::new()
function Add-Building([string]$Id,[string]$Name,[string]$Kind,[string]$Owner,[string]$Worker,
    [string[]]$Inputs,[string[]]$Outputs,[string[]]$Resources,[string[]]$ResourceModes,
    [string]$Behavior,[string]$Category,[string]$Family = '',[int]$Tier = 0,
    [string]$TechnologyOverride = '',[long[]]$InputQuantityOverride = @(),
    [string]$RecipeSourceId = '') {
    if (-not $buildingIds.Add($Id)) { throw "duplicate building id: $Id" }
    Write-Building $Id $Name $Kind $Owner $Worker $Inputs $Outputs $Resources $ResourceModes $Behavior $Category $Family $Tier $TechnologyOverride $InputQuantityOverride $RecipeSourceId
}

function Write-SelfSufficientBuilding([string]$Id, [string]$Name, [string]$Technology, [string]$Family,
    [int]$Tier, [string]$Owner, [string[]]$Outputs, [long[]]$OutputQty,
    [string[]]$Resources, [long[]]$ResourceQty, [int]$OwnerSlots = 1) {
    [double]$baseRevenue = 0
    for ($i = 0; $i -lt $Outputs.Count; $i++) {
        $buyFactor = Good-Integer-Field $Outputs[$i] 'merchant_buy_price_factor_q16' 62259
        $baseRevenue += [double]$OutputQty[$i] *
            [double](Default-Price-For-Good $Outputs[$i]) / 1000.0 *
            [double]$buyFactor / 65536.0
    }
    $ownerLivingCost = [double](Reference-Living-Cost-For-Profession $Owner) * [Math]::Max(1, $OwnerSlots)
    $requiredRevenue = $ownerLivingCost * 65536.0 / $DesignSellThroughQ16
    if ($baseRevenue -le 0) { throw "self-sufficient output value missing: $Id" }
    if ($baseRevenue -lt $requiredRevenue) {
        $scale = $requiredRevenue / $baseRevenue
        $OutputQty = @($OutputQty | ForEach-Object {
            [long][Math]::Max(1, [Math]::Ceiling([double]$_ * $scale))
        })
    }
    $shares = if ($Outputs.Count -eq 2) { @(32768, 32768) } else { @() }
    Write-Utf8 (Join-Path $buildingsDir "$Id.tres") @"
[gd_resource type="Resource" script_class="BuildingProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$Id"
display_name = "$Name"
building_kind = "collector"
technology_tags = PackedStringArray("$Technology")
upgrade_family_id = &"$Family"
upgrade_tier = $Tier
construction_days = 0
owner_profession_id = &"$Owner"
owner_slots_per_building = $OwnerSlots
employee_profession_ids = PackedStringArray()
employee_slots_per_building = PackedInt64Array()
employee_wage_policy_ids = PackedStringArray()
employee_reference_wages_per_day = PackedInt64Array()
input_good_ids = PackedStringArray()
input_quantities_per_day = PackedInt64Array()
output_good_ids = $(PSArray $Outputs)
output_quantities_per_day = $(PI64 $OutputQty)
output_cost_shares_q16 = $(PI32 $shares)
target_operating_margin_q16 = 6554
supply_price_elasticity_q16 = 32768
resource_ids = $(PSArray $Resources)
resource_quantities_per_day = $(PI64 $ResourceQty)
resource_interaction_modes = $(PSArray @($Resources | ForEach-Object { 'capacity' }))
resource_access_modes = $(PSArray @($Resources | ForEach-Object { 'local' }))
resource_generation_ids = PackedStringArray()
resource_generation_quantities_per_day = PackedInt64Array()
resource_generation_floor_q16 = 0
behavior_id = "consume_local_resources"
wage_policy_id = "none"
wage_per_employee_per_day = 0
"@
}

foreach ($row in $resourceRows) {
    $sourceRid = $row[0]
    if ($sourceRid -eq 'wild_game') { continue }
    $rid = $sourceRid
    $outputs = @($row[2])
    $buildingResources = @($rid); $resourceModes = @('extract')
    if ($sourceRid -in @('wheat','corn','potato','flax','cotton','fertile_soil')) {
        $buildingResources = @('arable_land','fertile_soil'); $resourceModes = @('capacity','capacity')
    } elseif ($sourceRid -eq 'rice') {
        $buildingResources = @('paddy_land'); $resourceModes = @('capacity')
    } elseif ($sourceRid -in @('spice_plants','rubber_tree','medicinal_herbs')) {
        $buildingResources = @('plantation_land','fertile_soil'); $resourceModes = @('capacity','capacity')
    }
    $owner = if ($sourceRid -eq 'corn') { 'landlord' } elseif ($sourceRid -in @('rice','potato','fertile_soil')) { 'subsistence_farmer' } elseif ($sourceRid -in @('spice_plants','flax','cotton','medicinal_herbs')) { 'landlord' } else { 'industrialist' }
    $behavior = if ($sourceRid -in $cultivatedResourceIds -or $sourceRid -eq 'fertile_soil') { 'consume_local_resources' } elseif ($sourceRid -eq 'timber') { 'cultivate_local_resources' } else { 'consume_local_resources' }
    $collectorInputs = @()
    if ($rid -eq 'timber') { $collectorInputs = @('tools') }
    elseif ($rid -in @('oil','natural_gas')) { $collectorInputs = @('industrial_machinery','electricity') }
    elseif ($rid -in @('gold_ore','silver_ore')) { $collectorInputs = @('tools') }
    elseif ($rid -in @('rare_earth','bauxite','phosphate_rock','lead_ore','zinc_ore','manganese_ore')) {
        $collectorInputs = @('tools','explosives')
    }
    elseif ($rid -eq 'sulfur') { $collectorInputs = @('tools') }
    elseif ($rid -in @('copper_ore','iron_ore','tin_ore','coal','clay','silica_sand','saltpeter','stone')) { $collectorInputs = @('tools') }
    $collectorWorker = if ($sourceRid -eq 'corn') { '' } else { Worker-For-Resource $sourceRid }
    $collectorFamily = switch ($rid) {
        'oil' { 'oil_extraction' } 'salt' { 'salt_extraction' }
        'gold_ore' { 'gold_extraction' } 'silver_ore' { 'silver_extraction' }
        'clay' { 'clay_extraction' } 'copper_ore' { 'copper_extraction' }
        'tin_ore' { 'tin_extraction' } 'silica_sand' { 'silica_extraction' }
        default { '' }
    }
    $collectorTier = if ($collectorFamily -eq '') { 0 } elseif ($rid -eq 'salt') { 1 } else { 2 }
    Add-Building (Collector-Id $sourceRid) (Collector-Display-Name $sourceRid $row[1]) 'collector' $owner $collectorWorker `
        $collectorInputs $outputs $buildingResources $resourceModes $behavior 'primary' $collectorFamily $collectorTier
}

# Cross-era hand-authored upgrade families for food, livestock, leather, and textiles.
Add-Building 'pastoral_camp' '游牧营地' 'collector' 'pastoralist' 'pastoralist' @() @('livestock_products') @('pasture') @('capacity') 'consume_local_resources' 'food' 'livestock_husbandry' 1
Add-Building 'manorial_pasture' '庄园牧场' 'collector' 'landlord' 'pastoralist' @() @('livestock_products') @('pasture') @('capacity') 'consume_local_resources' 'food' 'livestock_husbandry' 2
Add-Building 'ranching_station' '机械化牧场' 'collector' 'landlord' 'agricultural_worker' @('agricultural_machinery') @('livestock_products') @('pasture') @('capacity') 'consume_local_resources' 'food' 'livestock_husbandry' 3
Add-Building 'horse_breeding_camp' '马匹繁育营地' 'collector' 'pastoralist' 'pastoralist' @() @('horses') @('pasture') @('capacity') 'consume_local_resources' 'primary' 'horse_breeding' 1 'tech.bronze_casting'
Add-Building 'horse_breeder' '养马场' 'collector' 'landlord' 'pastoralist' @() @('horses') @('pasture') @('capacity') 'consume_local_resources' 'primary' 'horse_breeding' 2
Add-Building 'mechanized_farm' '机械化农场' 'collector' 'landlord' 'agricultural_worker' @('agricultural_machinery') @('grain','vegetables') @('arable_land','fertile_soil') @('capacity','capacity') 'consume_local_resources' 'food' 'field_crop_farming' 1
Add-Building 'intensive_farm' '电气化集约农场' 'collector' 'landlord' 'agricultural_worker' @('fertilizer','agricultural_machinery','electricity') @('grain','vegetables') @('arable_land','fertile_soil') @('capacity','capacity') 'consume_local_resources' 'food' 'field_crop_farming' 2

Add-Building 'bakery' '面包坊' 'industrial' 'artisan' 'artisan' @('wheat_grain') @('bread') @() @() 'none' 'food' 'bread_baking' 1
Add-Building 'bread_plant' '面包厂' 'industrial' 'industrialist' 'industrial_worker' @('wheat_grain','packaging') @('bread') @() @() 'none' 'food' 'bread_baking' 2
Add-Building 'staple_kitchen' '主食厨房' 'industrial' 'artisan' 'artisan' @('grain') @('prepared_staples') @() @() 'none' 'food' 'staple_preparation' 1
Add-Building 'staple_food_plant' '主食加工厂' 'industrial' 'industrialist' 'industrial_worker' @('grain','packaging') @('prepared_staples') @() @() 'none' 'food' 'staple_preparation' 2
Add-Building 'slaughterhouse' '屠宰场' 'industrial' 'artisan' 'artisan' @('livestock_products') @('meat','raw_hide') @() @() 'none' 'food' 'meat_processing' 1
Add-Building 'mechanized_slaughterhouse' '工业屠宰场' 'industrial' 'industrialist' 'industrial_worker' @('livestock_products','industrial_machinery') @('meat','raw_hide') @() @() 'none' 'food' 'meat_processing' 2
Add-Building 'creamery' '乳品工坊' 'industrial' 'artisan' 'artisan' @('livestock_products') @('dairy_products') @() @() 'none' 'food' 'dairy_processing' 1
Add-Building 'dairy_products_plant' '乳制品厂' 'industrial' 'industrialist' 'industrial_worker' @('livestock_products','packaging') @('dairy_products') @() @() 'none' 'food' 'dairy_processing' 2

Add-Building 'wool_shed' '羊毛棚' 'industrial' 'artisan' 'artisan' @('livestock_products') @('wool') @() @() 'none' 'textile' 'wool_processing' 1
Add-Building 'tannery' '制革工坊' 'industrial' 'artisan' 'artisan' @('raw_hide') @('leather') @() @() 'none' 'textile' 'leather_processing' 1
Add-Building 'leather_plant' '制革厂' 'industrial' 'industrialist' 'artisan' @('raw_hide','industrial_chemicals') @('leather') @() @() 'none' 'textile' 'leather_processing' 2
Add-Building 'guild_weaving_house' '行会织造坊' 'industrial' 'artisan' 'artisan' @('flax_fiber') @('cloth') @() @() 'none' 'textile' 'cloth_weaving' 1
Add-Building 'textile_mill' '蒸汽纺织厂' 'industrial' 'industrialist' 'artisan' @('flax_fiber','coal') @('cloth') @() @() 'none' 'textile' 'cloth_weaving' 2
Add-Building 'cloth_plant' '电力纺织厂' 'industrial' 'industrialist' 'artisan' @('flax_fiber','electricity') @('cloth') @() @() 'none' 'textile' 'cloth_weaving' 3
Add-Building 'synthetic_textile_mill' '合成纤维织造厂' 'industrial' 'industrialist' 'industrial_worker' @('synthetic_fiber','electricity') @('cloth') @() @() 'none' 'textile' 'cloth_weaving' 4
Add-Building 'tailor_shop' '裁缝铺' 'industrial' 'artisan' 'artisan' @('cloth') @('clothing') @() @() 'none' 'textile' 'garment_making' 1
Add-Building 'clothing_plant' '制衣厂' 'industrial' 'industrialist' 'artisan' @('cloth') @('clothing') @() @() 'none' 'textile' 'garment_making' 2
Add-Building 'cobbler_shop' '鞋匠铺' 'industrial' 'artisan' 'artisan' @('leather') @('footwear') @() @() 'none' 'textile' 'footwear_making' 1
Add-Building 'footwear_plant' '制鞋厂' 'industrial' 'industrialist' 'artisan' @('leather','latex') @('footwear') @() @() 'none' 'textile' 'footwear_making' 2

Add-Building 'rag_paper_workshop' '碎布造纸工坊' 'industrial' 'guild_master' 'artisan' @('flax_fiber') @('paper') @() @() 'none' 'forestry' 'paper_making' 1
Add-Building 'paper_plant' '造纸厂' 'industrial' 'industrialist' 'artisan' @('logs','industrial_chemicals') @('paper') @() @() 'none' 'forestry' 'paper_making' 2
Add-Building 'brewery' '酿酒坊' 'industrial' 'artisan' 'artisan' @('grain') @('beverages') @() @() 'none' 'food' 'beverage_making' 1
Add-Building 'distillery' '蒸馏酒坊' 'industrial' 'guild_master' 'artisan' @('grain','pottery') @('beverages') @() @() 'none' 'food' 'beverage_making' 2
Add-Building 'beverages_plant' '酿造厂' 'industrial' 'industrialist' 'industrial_worker' @('grain','packaging') @('beverages') @() @() 'none' 'food' 'beverage_making' 3
Add-Building 'composting_yard' '堆肥场' 'industrial' 'artisan' 'agricultural_worker' @('livestock_products') @('fertilizer') @() @() 'none' 'chemicals' 'fertilizer_making' 1
Add-Building 'fertilizer_plant' '化肥厂' 'industrial' 'industrialist' 'chemist' @('phosphate_rock','natural_gas','electricity') @('fertilizer') @() @() 'none' 'chemicals' 'fertilizer_making' 2
Add-Building 'industrial_chemicals_plant' '化学工场' 'industrial' 'guild_master' 'chemist' @('sulfur','salt') @('industrial_chemicals') @() @() 'none' 'chemicals' 'chemical_industry' 1
Add-Building 'electrochemical_works' '电化工厂' 'industrial' 'industrialist' 'chemist' @('salt','electricity') @('industrial_chemicals') @() @() 'none' 'chemicals' 'chemical_industry' 2
Add-Building 'early_oil_well' '蒸汽钻井场' 'collector' 'industrialist' 'petroleum_worker' @('steel','precision_tools','steam_engines') @('crude_oil') @('oil') @('extract') 'consume_local_resources' 'primary' 'oil_extraction' 1
Add-Building 'industrial_salt_mine' '深井盐矿' 'collector' 'industrialist' 'miner' @('tools','explosives') @('salt') @('salt') @('extract') 'consume_local_resources' 'primary' 'salt_extraction' 2
Add-Building 'goldsmith_workshop' '金银器工坊' 'industrial' 'artisan' 'artisan' @('gold') @('jewelry') @() @() 'none' 'consumer' 'jewelry_making' 1
Add-Building 'jewelry_plant' '珠宝厂' 'industrial' 'industrialist' 'artisan' @('gold') @('jewelry') @() @() 'none' 'consumer' 'jewelry_making' 2
Add-Building 'court_tailor' '宫廷裁缝坊' 'industrial' 'guild_master' 'artisan' @('cloth','fur') @('fine_clothing') @() @() 'none' 'textile' 'fine_clothing_making' 1
Add-Building 'fine_clothing_plant' '高级成衣厂' 'industrial' 'industrialist' 'artisan' @('cloth','industrial_chemicals','electricity') @('fine_clothing') @() @() 'none' 'textile' 'fine_clothing_making' 2
Add-Building 'cabinetmaker_workshop' '细木家具工坊' 'industrial' 'guild_master' 'artisan' @('lumber','cloth') @('fine_furniture') @() @() 'none' 'consumer' 'fine_furniture_making' 1
Add-Building 'fine_furniture_plant' '高级家具厂' 'industrial' 'industrialist' 'artisan' @('lumber','cloth','industrial_chemicals') @('fine_furniture') @() @() 'none' 'consumer' 'fine_furniture_making' 2
Add-Building 'construction_components_plant' '建筑构件厂' 'industrial' 'industrialist' 'construction_worker' @('concrete','steel','glass') @('construction_components') @() @() 'none' 'construction' 'construction_methods' 3
Add-Building 'ore_bronzesmith_camp' '露天青铜作坊' 'industrial' 'artisan' 'artisan' @('copper_ore','tin_ore','logs') @('bronze_tools') @() @() 'none' 'tools'
Add-Building 'early_iron_mine' '浅层铁矿' 'collector' 'artisan' 'miner' @('bronze_tools') @('iron_ore') @('iron_ore') @('extract') 'consume_local_resources' 'primary' 'iron_extraction' 1
Add-Building 'iron_tool_workshop' '铁制工具工坊' 'industrial' 'artisan' 'artisan' @('iron_ore','logs') @('tools') @() @() 'none' 'machinery' 'metal_toolmaking' 1
Add-Building 'canning_workshop' '罐头工坊' 'industrial' 'guild_master' 'artisan' @('fish','salt','packaging','tools') @('canned_fish') @() @() 'none' 'food' 'fish_canning' 1

$explicitIndustryGoods = @(
    'grain','bread','prepared_staples','livestock_products','meat','dairy_products','raw_hide',
    'wool','leather','cloth','clothing','footwear','paper','beverages','fertilizer',
    'industrial_chemicals','jewelry','fine_clothing','fine_furniture','construction_components'
)
foreach ($category in $processedGroups.Keys) {
    foreach ($good in $processedGroups[$category]) {
        if ($good -eq 'fur' -or $good -in $explicitIndustryGoods) { continue }
        $id = "${good}_plant"
        $worker = Worker-For-Output $good $category
        $displayName = if ($good -eq 'electricity') { '燃煤发电厂' } elseif ($good -eq 'tools') { '钢制工具厂' } `
            elseif ($good -eq 'steel') { '电弧炉炼钢厂' } elseif ($good -eq 'glass') { '玻璃厂' } `
            elseif ($good -eq 'railway_equipment') { '铁路设备厂' } `
            elseif ($good -eq 'edible_oil') { '榨油坊' } elseif ($good -eq 'soap') { '制皂工坊' } `
            elseif ($good -eq 'aluminum') { '电解铝厂' } elseif ($good -eq 'copper') { '炼铜厂' } `
            elseif ($good -eq 'tin') { '炼锡厂' } elseif ($good -eq 'lead') { '炼铅厂' } `
            elseif ($good -eq 'zinc') { '炼锌厂' } elseif ($good -eq 'coke') { '焦化厂' } `
            elseif ($good -eq 'lubricants') { '润滑油厂' } elseif ($good -eq 'petrochemicals') { '石油化工厂' } `
            elseif ($good -eq 'refined_fuel') { '炼油厂' } elseif ($good -eq 'machine_parts') { '机械零件厂' } `
            elseif ($good -eq 'wire') { '线材厂' } elseif ($good -eq 'processed_food') { '综合食品厂' } `
            elseif ($good -eq 'lumber') { '锯木场' } elseif ($good -eq 'bricks') { '制砖厂' } `
            elseif ($good -eq 'printed_materials') { '印刷厂' } elseif ($good -eq 'canned_fish') { '鱼类罐头厂' } `
            elseif ($good -eq 'pharmaceuticals') { '制药厂' } `
            elseif ($good -eq 'rare_earth_metals') { '战略金属冶炼厂' } `
            else { "$($goodNames[$good])厂" }
        $family = switch ($good) {
            'tools' { 'metal_toolmaking' } 'canned_fish' { 'fish_canning' }
            'glass' { 'glassmaking' } 'steel' { 'steelmaking' }
            'railway_equipment' { 'railway_equipment_making' } default { '' }
        }
        $tier = if ($family -eq '') { 0 } else { 2 }
        Add-Building $id $displayName 'industrial' 'industrialist' $worker @($deps[$good]) @($good) @() @() 'none' $category $family $tier
    }
}
foreach ($power in @(
    @('gas_power_plant','燃气发电厂','natural_gas'),
    @('oil_power_plant','燃油发电厂','refined_fuel'),
    @('nuclear_power_plant','核电站','nuclear_fuel')
)) {
    $powerInputs = if ($power[0] -eq 'nuclear_power_plant') {
        @('nuclear_fuel','reactor_components')
    } else {
        @($power[2])
    }
    Add-Building $power[0] $power[1] 'industrial' 'industrialist' 'electrician' $powerInputs @('electricity') @() @() 'none' 'energy'
}

Write-SelfSufficientBuilding 'gathering_ground' '采集营地' 'tech.gathering' `
    'subsistence_food' 1 'forager' @('gathered_plants') @(7000) @('fertile_soil') @(1000) 2
Write-SelfSufficientBuilding 'subsistence_farm' '自给农庄' 'tech.pottery' `
    'subsistence_food' 2 'subsistence_farmer' @('grain','vegetables') @(4000,4000) @('arable_land','fertile_soil') @(10000,10000)
Write-SelfSufficientBuilding 'three_field_smallholding' '三圃制小农场' 'tech.guild_organization' `
    'subsistence_food' 3 'subsistence_farmer' @('grain','vegetables') @(6000,6000) @('arable_land','fertile_soil') @(8000,8000)
Write-SelfSufficientBuilding 'improved_smallholding' '改良小农场' 'tech.steam_power' `
    'subsistence_food' 4 'subsistence_farmer' @('grain','vegetables') @(8000,8000) @('arable_land','fertile_soil') @(6000,6000)
Write-Utf8 (Join-Path $buildingsDir 'household_weaving_shelter.tres') @"
[gd_resource type="Resource" script_class="BuildingProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"household_weaving_shelter"
display_name = "家庭织造棚"
building_kind = "industrial"
technology_tags = PackedStringArray("tech.gathering")
upgrade_family_id = &"household_cloth"
upgrade_tier = 1
construction_days = 0
construction_good_ids = PackedStringArray("logs", "gathered_plants")
construction_quantities = PackedInt64Array(2000, 4000)
owner_profession_id = &"artisan"
owner_slots_per_building = 1
employee_profession_ids = PackedStringArray()
employee_slots_per_building = PackedInt64Array()
employee_wage_policy_ids = PackedStringArray()
employee_reference_wages_per_day = PackedInt64Array()
input_good_ids = PackedStringArray("gathered_plants")
input_quantities_per_day = PackedInt64Array(120)
output_good_ids = PackedStringArray("cloth")
output_quantities_per_day = PackedInt64Array(110)
output_cost_shares_q16 = PackedInt32Array()
target_operating_margin_q16 = 6554
supply_price_elasticity_q16 = 32768
resource_ids = PackedStringArray()
resource_quantities_per_day = PackedInt64Array()
resource_interaction_modes = PackedStringArray()
resource_access_modes = PackedStringArray()
resource_generation_ids = PackedStringArray()
resource_generation_quantities_per_day = PackedInt64Array()
resource_generation_floor_q16 = 0
behavior_id = "none"
wage_policy_id = "none"
wage_per_employee_per_day = 0
"@
Write-SelfSufficientBuilding 'household_loom' '家用织机' 'tech.pottery' `
    'household_cloth' 2 'artisan' @('cloth') @(1320) @('arable_land','fertile_soil') @(10000,10000)
Write-SelfSufficientBuilding 'cottage_weaving' '家庭纺织坊' 'tech.guild_organization' `
    'household_cloth' 3 'artisan' @('cloth') @(2400) @('arable_land','fertile_soil') @(8000,8000)
Write-SelfSufficientBuilding 'improved_domestic_loom' '改良家用织机' 'tech.steam_power' `
    'household_cloth' 4 'artisan' @('cloth') @(3600) @('arable_land','fertile_soil') @(6000,6000)
foreach ($id in @('gathering_ground','subsistence_farm','three_field_smallholding','improved_smallholding',
    'household_weaving_shelter','household_loom','cottage_weaving','improved_domestic_loom')) {
    if (-not $buildingIds.Add($id)) { throw "duplicate subsistence building id: $id" }
}
if ($buildingIds.Count -lt 90) { throw "building count below target: $($buildingIds.Count)" }

$generatedResourceIds = @('marine_fish','arable_land','paddy_land','plantation_land','pasture',
    'bauxite','limestone','silica_sand','phosphate_rock','tin_ore','lead_ore',
    'zinc_ore','manganese_ore','sulfur')
$newResources = $naturalResourceRows | Where-Object { $_[0] -in $generatedResourceIds }
foreach ($row in $newResources) {
    $id = $row[0]
    $habitat = if ($id -eq 'marine_fish') { 'coastal_land' } else { 'land' }
    $genBase=0.0; $genSelf=0.0; $decaySelf=0.0
    $initBase=-120000.0; $initTemp=0.0; $initMoisture=0.0; $initElevation=0.0
    $initRiver=0.0; $initVolcano=0.0; $initClimateFit=0.0
    $initNoise=100000.0; $noiseScale=0.07
    $family=''; $province=0.0; $belt=0.0; $provinceScale=0.012; $beltScale=0.035
    $tempOpt=0.5; $tempTol=1.0; $moistureOpt=0.5; $moistureTol=1.0
    $minCoverage=0.005; $minReserve=10000.0
    $ecologyCapacity=0.0; $ecologyGrowth=0.0; $ecologyImmigration=0.0; $ecologyStressMortality=0.0
    $reserveScale = if ($id -eq 'marine_fish') { 2.0 } elseif ($id -in @('arable_land','paddy_land','plantation_land','pasture')) { 1.0 } else { 8.0 }
    switch ($id) {
        'marine_fish' { $genBase=0.0; $genSelf=0.0; $decaySelf=0.0; $initBase=400.0; $initNoise=1200.0; $noiseScale=0.045; $minCoverage=1.0; $minReserve=3000.0; $ecologyCapacity=5000.0; $ecologyGrowth=0.02; $ecologyImmigration=0.2; $ecologyStressMortality=0.01 }
        'arable_land' { $initBase=-40.0; $initMoisture=25.0; $initElevation=-35.0; $initRiver=30.0; $initClimateFit=140.0; $initNoise=30.0; $tempOpt=0.55; $tempTol=0.42; $moistureOpt=0.55; $moistureTol=0.4; $minCoverage=0.6; $minReserve=1250.0 }
        'paddy_land' { $initBase=-90.0; $initMoisture=70.0; $initElevation=-25.0; $initRiver=180.0; $initClimateFit=120.0; $initNoise=20.0; $tempOpt=0.68; $tempTol=0.32; $moistureOpt=0.78; $moistureTol=0.28; $minCoverage=0.2; $minReserve=600.0 }
        'plantation_land' { $initBase=-85.0; $initMoisture=55.0; $initElevation=-20.0; $initClimateFit=150.0; $initNoise=35.0; $tempOpt=0.72; $tempTol=0.3; $moistureOpt=0.7; $moistureTol=0.3; $minCoverage=0.2; $minReserve=1400.0 }
        'pasture' { $initBase=-55.0; $initMoisture=15.0; $initElevation=-20.0; $initRiver=20.0; $initClimateFit=150.0; $initNoise=35.0; $tempOpt=0.52; $tempTol=0.45; $moistureOpt=0.48; $moistureTol=0.45; $minCoverage=0.6; $minReserve=1250.0 }
        'bauxite' { $family='laterite'; $initBase=-380000.0; $initMoisture=180000.0; $initElevation=80000.0; $province=220000.0; $belt=100000.0; $initNoise=180000.0 }
        'limestone' { $family='sedimentary'; $initBase=-260000.0; $province=300000.0; $belt=140000.0; $initNoise=180000.0 }
        'silica_sand' { $family='surface'; $initBase=-190000.0; $initRiver=100000.0; $province=120000.0; $belt=80000.0; $initNoise=220000.0 }
        'phosphate_rock' { $family='sedimentary'; $initBase=-330000.0; $province=260000.0; $belt=160000.0; $initNoise=180000.0 }
        'tin_ore' { $family='felsic'; $initBase=-360000.0; $initElevation=90000.0; $initRiver=50000.0; $province=190000.0; $belt=230000.0; $initNoise=160000.0 }
        'lead_ore' { $family='hydrothermal'; $initBase=-350000.0; $initElevation=70000.0; $province=180000.0; $belt=250000.0; $initNoise=160000.0 }
        'zinc_ore' { $family='hydrothermal'; $initBase=-330000.0; $province=190000.0; $belt=240000.0; $initNoise=170000.0 }
        'manganese_ore' { $family='mafic'; $initBase=-340000.0; $province=210000.0; $belt=210000.0; $initNoise=170000.0 }
        'sulfur' { $family='hydrothermal'; $initBase=-300000.0; $initVolcano=180000.0; $province=160000.0; $belt=230000.0; $initNoise=160000.0 }
    }
    Write-Utf8 (Join-Path $resourcesDir "$id.tres") @"
[gd_resource type="Resource" script_class="ResourceProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/resource_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$id"
display_name = "$($row[1])"
reserve_component = &"cell.res_${id}_reserve"
habitat_mode = "$habitat"
init_reserve_scale = $reserveScale
init_min_coverage = $minCoverage
init_min_reserve = $minReserve
    temp_lo = 0.0
    temp_hi = 1.0
gen_base = $genBase
gen_self = $genSelf
decay_self = $decaySelf
init_base = $initBase
init_temp = $initTemp
init_moisture = $initMoisture
init_elevation = $initElevation
init_river = $initRiver
init_volcano = $initVolcano
init_climate_fit = $initClimateFit
init_noise = $initNoise
init_noise_scale = $noiseScale
geology_family_id = &"$family"
init_province = $province
init_province_scale = $provinceScale
init_belt = $belt
init_belt_scale = $beltScale
climate_temp_opt = $tempOpt
climate_temp_tol = $tempTol
climate_moisture_opt = $moistureOpt
climate_moisture_tol = $moistureTol
ecology_capacity = $ecologyCapacity
ecology_growth_rate = $ecologyGrowth
ecology_immigration = $ecologyImmigration
ecology_stress_mortality_rate = $ecologyStressMortality
"@
}

function Content-Scalar-String([string]$Content, [string]$Field) {
    $pattern = '(?m)^{0} = &?"([^"]*)"\r?$' -f [regex]::Escape($Field)
    $match = [regex]::Match($Content, $pattern)
    return $(if ($match.Success) { $match.Groups[1].Value } else { '' })
}

function Rank-From-Profile-Content([string]$Content) {
    $rank = -1
    foreach ($tag in @(Content-Strings $Content 'technology_tags')) {
        if ($tag.StartsWith('tech.')) { $rank = [Math]::Max($rank, (Technology-Rank $tag)) }
    }
    return $rank
}

function Industry-For-Good([string]$GoodId) {
    if ($goods.Contains($GoodId)) { return [string]$goods[$GoodId].category }
    $curatedIndustry = @{
        advanced_chips='machinery'; autonomous_systems='machinery'; bronze_tools='machinery';
        chipped_stone_tools='machinery'; coke='energy'; flint='primary'; gathered_plants='food';
        insulated_cable='machinery'; manuscripts='forestry'; oceanic_vessels='machinery';
        pottery='consumer'; precision_tools='machinery';
        radio_equipment='machinery'; reactor_components='machinery';
        scientific_instruments='machinery'; steam_engines='machinery'
    }
    if ($curatedIndustry.ContainsKey($GoodId)) { return $curatedIndustry[$GoodId] }
    throw "good lacks industry during method generation: $GoodId"
}

function Good-Rank-From-File([string]$GoodId) {
    $content = [System.IO.File]::ReadAllText((Join-Path $goodsDir "$GoodId.tres"))
    $rank = Rank-From-Profile-Content $content
    if ($rank -lt 0 -or $rank -gt 10) { throw "good lacks valid rank during method generation: $GoodId" }
    return $rank
}

function Worker-For-Method([string]$Kind, [string]$Category, [string[]]$Resources) {
    if ($Kind -eq 'collector') {
        if ($Resources -contains 'wild_game') { return 'hunter' }
        if (@($Resources | Where-Object { $_ -in @('arable_land','paddy_land','plantation_land','pasture','fertile_soil') }).Count -gt 0) { return 'agricultural_worker' }
        if ($Resources -contains 'marine_fish') { return 'fisher' }
        if ($Resources -contains 'timber') { return 'forestry_worker' }
        if (@($Resources | Where-Object { $_ -in @('oil','natural_gas') }).Count -gt 0) { return 'petroleum_worker' }
        return 'miner'
    }
    switch ($Category) {
        'construction' { return 'construction_worker' }
        'food' { return 'industrial_worker' }
        'chemicals' { return 'chemist' }
        'metals' { return 'metallurgist' }
        'machinery' { return 'machinist' }
        'energy' { return 'electrician' }
        'forestry' { return 'artisan' }
        'textile' { return 'artisan' }
        'consumer' { return 'artisan' }
        default { return 'technician' }
    }
}

$methodTechnologyByRank = @{
    1='tech.bronze_casting'; 2='tech.masonry'; 3='tech.guild_organization'; 4='tech.printing_press';
    5='tech.precision_engineering'; 6='tech.steam_power'; 7='tech.electrification';
    8='tech.advanced_metallurgy'; 9='tech.networked_computing'; 10='tech.autonomous_systems'
}
$methodEnablerByRank = @{
    1='bronze_tools'; 2='bronze_tools'; 3='bronze_tools'; 4='tools'; 5='tools'; 6='steam_engines';
    7='electricity'; 8='electric_motor'; 9='computers'; 10='autonomous_systems'
}
$methodPrefixByRank = @{
    1='青铜改良'; 2='古典改良'; 3='行会化'; 4='商贸化'; 5='科学化'; 6='蒸汽化';
    7='电气化'; 8='先进化'; 9='数字化'; 10='智能化'
}
$methodEnablersBySource = @{
    landed_estate=@('agricultural_machinery'); potato_collector=@('agricultural_machinery')
    cotton_collector=@('agricultural_machinery'); rubber_tree_collector=@('agricultural_machinery')
    spice_plants_collector=@('agricultural_machinery')
    medicinal_herbs_collector=@('fertilizer','electricity')
    edible_oil_plant=@('industrial_machinery'); soap_plant=@('industrial_machinery')
    bricks_plant=@('industrial_machinery'); lime_plant=@('industrial_machinery')
    limestone_collector=@('industrial_machinery')
}
$methodNameOverrides = @{
    method_gathering_ground_r1='定居采集营地'; method_flint_quarry_r1='改良燧石矿坑'
    method_stone_age_hunting_camp_r4='商业狩猎与毛皮站'; method_pottery_kiln_r3='行会陶窑'
    method_landed_estate_r6='机械化玉米农场'; method_potato_collector_r6='机械化马铃薯农场'
    method_cotton_collector_r6='机械化棉花农场'; method_rubber_tree_collector_r6='机械化橡胶种植园'
    method_spice_plants_collector_r6='机械化香料种植园'
    method_medicinal_herbs_collector_r7='受控环境药材农场'
    method_edible_oil_plant_r6='工业榨油厂'; method_soap_plant_r6='工业制皂厂'
    method_packaging_plant_r7='电气化包装厂'; method_printed_materials_plant_r7='电气印刷厂'
    method_oceanic_shipyard_r7='电气化造船厂'; method_bricks_plant_r6='工业砖厂'
    method_lime_plant_r6='工业石灰厂'; method_limestone_collector_r6='工业石灰岩矿场'
    method_lumber_plant_r2='改良锯木场'; method_lumber_plant_r4='水力锯木场'
    method_timber_collector_r2='组织化伐木场'; method_timber_collector_r4='商营伐木场'
    method_stone_collector_r2='石料场'; method_stone_collector_r4='规模化采石场'
    method_marine_fish_collector_r2='帆船渔场'; method_marine_fish_collector_r4='远洋渔场'
    method_wheat_farm_r3='佃作小麦庄园'; method_wheat_farm_r5='改良轮作小麦庄园'
    method_rice_collector_r3='佃作稻庄'; method_rice_collector_r5='精耕稻庄'
    method_flax_collector_r3='亚麻庄园'; method_flax_collector_r5='改良亚麻庄园'
    method_wool_shed_r3='羊毛行会作坊'; method_wool_shed_r5='精梳羊毛作坊'
    method_bauxite_collector_r9='自动化铝土矿'; method_lead_ore_collector_r9='自动化铅矿'
    method_manganese_ore_collector_r10='智能锰矿'; method_natural_gas_collector_r10='智能天然气田'
    method_phosphate_rock_collector_r9='自动化磷矿'; method_rare_earth_collector_r10='智能战略矿山'
    method_saltpeter_collector_r8='现代硝石矿'; method_saltpeter_collector_r10='智能硝石矿'
    method_sulfur_collector_r8='现代硫矿'; method_sulfur_collector_r10='智能硫矿'
    method_zinc_ore_collector_r9='自动化锌矿'
    method_coke_ovens_r9='自动化焦化厂'; method_cement_plant_r9='自动化水泥厂'
    method_concrete_plant_r9='自动化混凝土厂'; method_lubricants_plant_r9='自动化润滑油厂'
    method_machine_parts_plant_r9='自动化机械零件厂'; method_lead_plant_r9='自动化炼铅厂'
    method_zinc_plant_r9='自动化炼锌厂'; method_steam_engine_works_r9='自动化蒸汽机厂'
    method_explosives_plant_r8='现代炸药厂'; method_explosives_plant_r10='自动化炸药厂'
    method_precision_tool_workshop_r8='精密工具厂'; method_precision_tool_workshop_r10='智能工具厂'
    method_scientific_instrument_works_r8='精密仪器厂'; method_scientific_instrument_works_r10='智能仪器厂'
    method_aluminum_plant_r10='智能冶铝厂'; method_petrochemicals_plant_r10='智能石油化工厂'
    method_refined_fuel_plant_r10='智能炼油厂'; method_rare_earth_metals_plant_r10='智能战略金属冶炼厂'
}

function Add-Production-Method([string]$SourceId, [int]$TargetRank) {
    $sourcePath = Join-Path $buildingsDir "$SourceId.tres"
    $content = [System.IO.File]::ReadAllText($sourcePath)
    $name = Content-Scalar-String $content 'display_name'
    $kind = Content-Scalar-String $content 'building_kind'
    $owner = Content-Scalar-String $content 'owner_profession_id'
    $inputs = @(Content-Strings $content 'input_good_ids')
    [long[]]$inputQuantities = @(Content-Numbers $content 'input_quantities_per_day')
    $outputs = @(Content-Strings $content 'output_good_ids')
    $resources = @(Content-Strings $content 'resource_ids')
    $resourceModes = @(Content-Strings $content 'resource_interaction_modes')
    $behavior = Content-Scalar-String $content 'behavior_id'
    if ($outputs.Count -eq 0) { throw "method source lacks output: $SourceId" }
    $category = Industry-For-Good $outputs[0]
    $enablers = if ($methodEnablersBySource.ContainsKey($SourceId)) {
        @($methodEnablersBySource[$SourceId])
    } else { @($methodEnablerByRank[$TargetRank]) }
    $toolGoods = @('chipped_stone_tools','bronze_tools','tools','precision_tools')
    foreach ($enabler in $enablers) {
        if ($enabler -in $toolGoods) {
            $existingToolIndexes = @(for ($i = 0; $i -lt $inputs.Count; $i++) {
                if ($inputs[$i] -in $toolGoods) { $i }
            })
            if ($existingToolIndexes.Count -gt 0) {
                $firstToolIndex = [int]$existingToolIndexes[0]
                $normalizedInputs = @(); [long[]]$normalizedQuantities = @()
                for ($i = 0; $i -lt $inputs.Count; $i++) {
                    if ($i -eq $firstToolIndex) {
                        $normalizedInputs += 'tools'; $normalizedQuantities += [long]$inputQuantities[$i]
                    } elseif ($i -notin $existingToolIndexes) {
                        $normalizedInputs += $inputs[$i]; $normalizedQuantities += [long]$inputQuantities[$i]
                    }
                }
                $inputs = $normalizedInputs; $inputQuantities = $normalizedQuantities
            } else {
                $inputs += 'tools'; $inputQuantities += [long]500
            }
        } elseif ($enabler -notin $inputs) {
            $inputs += $enabler; $inputQuantities += [long]500
        }
    }
    $worker = if ($kind -eq 'collector') {
        Worker-For-Method $kind $category $resources
    } else {
        Worker-For-Output $outputs[0] $category
    }
    if ($SourceId -eq 'gathering_ground') { $worker = 'forager' }
    $methodId = "method_${SourceId}_r${TargetRank}"
    $methodName = if ($methodNameOverrides.ContainsKey($methodId)) {
        $methodNameOverrides[$methodId]
    } else { "$($methodPrefixByRank[$TargetRank])$name" }
    Add-Building $methodId $methodName $kind $owner $worker $inputs $outputs $resources $resourceModes `
        $behavior $category '' 0 $methodTechnologyByRank[$TargetRank] $inputQuantities $SourceId
}

Sync-CuratedDirectory (Join-Path $curatedContentDir 'goods') $goodsDir
Sync-CuratedDirectory (Join-Path $curatedContentDir 'buildings') $buildingsDir
Sync-CuratedDirectory (Join-Path $curatedContentDir 'resources') $resourcesDir

# Every pre-Information single-route good must declare a lifecycle. Persistent
# macro sectors use the normal cross-era schedule; bounded sectors name their
# exact final methods. Unclassified content fails instead of silently acquiring
# digital or autonomous pseudo-industries.
$baseBuildingIds = [System.Collections.Generic.List[string]]::new()
foreach ($id in @($buildingIds | Sort-Object)) { $baseBuildingIds.Add($id) }
foreach ($template in Get-ChildItem -LiteralPath (Join-Path $curatedContentDir 'buildings') -Filter '*.tres' -File | Sort-Object Name) {
    if (-not $buildingIds.Add($template.BaseName)) { throw "generated/curated building collision: $($template.BaseName)" }
    $baseBuildingIds.Add($template.BaseName)
}
$baseProducers = @{}
$baseProfiles = @{}
foreach ($id in $baseBuildingIds) {
    $content = [System.IO.File]::ReadAllText((Join-Path $buildingsDir "$id.tres"))
    $baseProfiles[$id] = $content
    foreach ($output in @(Content-Strings $content 'output_good_ids')) {
        if (-not $baseProducers.ContainsKey($output)) { $baseProducers[$output] = [System.Collections.Generic.List[string]]::new() }
        $baseProducers[$output].Add($id)
    }
}
$singleMethodSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($goodId in @($baseProducers.Keys | Sort-Object)) {
    if ($baseProducers[$goodId].Count -eq 1 -and (Good-Rank-From-File $goodId) -lt 9) {
        [void]$singleMethodSources.Add($baseProducers[$goodId][0])
    }
}
$boundedMethodTargets = @{
    knapping_workshop=@(); gathering_ground=@(1); flint_quarry=@(1); stone_age_hunting_camp=@(4); pottery_kiln=@(3)
    landed_estate=@(6); potato_collector=@(6); cotton_collector=@(6); rubber_tree_collector=@(6)
    spice_plants_collector=@(6); medicinal_herbs_collector=@(7)
    edible_oil_plant=@(6); soap_plant=@(6); packaging_plant=@(7); printed_materials_plant=@(7)
    oceanic_shipyard=@(7); bricks_plant=@(6); lime_plant=@(6); limestone_collector=@(6)
}
$persistentMethodSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($sourceId in @(
    'agricultural_machinery_plant','aluminum_plant','automobiles_plant','batteries_plant',
    'bauxite_collector','cement_plant','coke_ovens','concrete_plant','detergent_plant',
    'electric_motor_plant','electronic_components_plant','engines_plant','explosives_plant',
    'flax_collector','household_appliances_plant','industrial_machinery_plant',
    'insulated_cable_plant','lead_ore_collector','lead_plant','lubricants_plant','lumber_plant',
    'machine_parts_plant','manganese_ore_collector','marine_fish_collector',
    'natural_gas_collector','nuclear_fuel_plant','petrochemicals_plant',
    'phosphate_rock_collector','plastics_plant','precision_tool_workshop','radio_equipment_works',
    'rare_earth_collector','rare_earth_metals_plant','reactor_component_works',
    'refined_fuel_plant','rice_collector','saltpeter_collector','scientific_instrument_works',
    'stainless_steel_plant','steam_engine_works','stone_collector','sulfur_collector',
    'synthetic_fiber_plant','synthetic_rubber_plant','timber_collector','wheat_farm','wire_plant',
    'wool_shed','zinc_ore_collector','zinc_plant'
)) { [void]$persistentMethodSources.Add($sourceId) }
foreach ($sourceId in @($singleMethodSources | Sort-Object)) {
    $sourceRank = Rank-From-Profile-Content $baseProfiles[$sourceId]
    $targets = if ($boundedMethodTargets.ContainsKey($sourceId)) {
        @($boundedMethodTargets[$sourceId])
    } elseif ($persistentMethodSources.Contains($sourceId)) {
        @(switch ($sourceRank) {
            0 { 2; 4 }
            1 { 3; 5 }
            2 { 4; 5; 8 }
            3 { 5; 8; 9 }
            4 { 7; 8; 9 }
            5 { 8; 10 }
            6 { 9 }
            7 { 10 }
            8 { 10 }
            default { throw "unsupported persistent source rank: $sourceId -> $sourceRank" }
        })
    } else {
        throw "single-method source lacks lifecycle classification: $sourceId"
    }
    foreach ($targetRank in $targets) { Add-Production-Method $sourceId $targetRank }
}

foreach ($directory in @($goodsDir, $buildingsDir, $professionsDir, $needsDir, $plansDir, $resourcesDir)) {
    Assert-FullyManaged $directory
}

$fullGoodsCount = @(Get-ChildItem -LiteralPath $goodsDir -Filter '*.tres' -File).Count
$fullBuildingCount = @(Get-ChildItem -LiteralPath $buildingsDir -Filter '*.tres' -File).Count
$fullResourceCount = @(Get-ChildItem -LiteralPath $resourcesDir -Filter '*.tres' -File).Count
if ($Scope -eq 'Consumption') {
    $planCount = @(Get-ChildItem -LiteralPath $plansDir -Filter '*.tres' -File).Count
    Write-Host "Generated $($professionRows.Count) professions, $($needRows.Count) needs, and $planCount consumption plans."
} else {
    Write-Host "Generated $fullGoodsCount goods, $fullBuildingCount buildings, $($professionRows.Count) professions, $($needRows.Count) needs, and $fullResourceCount resources."
}
