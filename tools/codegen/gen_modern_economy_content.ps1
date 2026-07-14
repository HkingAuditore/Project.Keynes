param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
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

function Write-Utf8([string]$Path, [string]$Content) {
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
    [System.IO.File]::WriteAllText($Path, $expected, $utf8)
}

function Sync-CuratedDirectory([string]$Source, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "curated content directory missing: $Source" }
    foreach ($template in Get-ChildItem -LiteralPath $Source -Filter '*.tres' -File | Sort-Object Name) {
        $content = [System.IO.File]::ReadAllText($template.FullName)
        Write-Utf8 (Join-Path $Target $template.Name) $content
    }
}

function Assert-FullyManaged([string]$Directory) {
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.tres' -File) {
        if (-not $managedPaths.Contains([System.IO.Path]::GetFullPath($file.FullName))) {
            throw "unmanaged economy content file: $($file.FullName)"
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

$resourceRows = @(
    @('timber','木材','logs'), @('stone','石材','raw_stone'),
    @('fertile_soil','肥沃土壤','vegetables'), @('wheat','小麦','wheat_grain'),
    @('rice','水稻','rice_grain'), @('corn','玉米','corn_grain'),
    @('potato','马铃薯','potatoes'), @('coal','煤炭','coal'),
    @('oil','石油','crude_oil'), @('natural_gas','天然气','natural_gas'),
    @('copper_ore','铜矿','copper_ore'), @('iron_ore','铁矿','iron_ore'),
    @('gold_ore','金矿','gold'), @('silver_ore','银矿','silver'),
    @('salt','盐','salt'), @('rubber_tree','橡胶树','latex'),
    @('saltpeter','硝石','saltpeter'), @('rare_earth','战略矿产','rare_earth_ore'),
    @('clay','黏土','clay'), @('horses','马匹','horses'),
    @('wild_game','野生动物','game_meat'), @('spice_plants','香料植物','spices'),
    @('flax','亚麻','flax_fiber'), @('cotton','棉花','cotton_fiber'),
    @('cattle','牛','cattle'), @('sheep','羊','sheep'), @('pigs','猪','pigs'),
    @('medicinal_herbs','药用植物','medicinal_herbs'),
    @('fresh_water','淡水','raw_water'), @('marine_fish','海洋鱼类','fish'),
    @('bauxite','铝土矿','bauxite'), @('limestone','石灰石','limestone'),
    @('silica_sand','硅砂','silica_sand'), @('phosphate_rock','磷矿','phosphate_rock'),
    @('tin_ore','锡矿','tin_ore'), @('lead_ore','铅矿','lead_ore'),
    @('zinc_ore','锌矿','zinc_ore'), @('manganese_ore','锰矿','manganese_ore'),
	@('sulfur','硫磺','sulfur')
)
$cultivatedResourceIds = @('wheat','rice','corn','potato','rubber_tree',
    'spice_plants','flax','cotton','medicinal_herbs')
$naturalResourceRows = @($resourceRows | Where-Object { $_[0] -notin $cultivatedResourceIds })
$naturalResourceRows += @(
    @('arable_land','旱作耕地',''), @('paddy_land','水田容量',''),
    @('plantation_land','种植园容量',''), @('freshwater_fish','淡水鱼类','fish')
)

$processedGroups = [ordered]@{
    forestry = @('lumber','wood_pulp','paper','packaging','printed_materials','furniture')
    construction = @('cut_stone','bricks','lime','cement','concrete','glass','construction_components')
    food = @('grain','flour','bread','rice_food','corn_food','potato_food','edible_oil','processed_food','dairy_products','beef','mutton','pork','canned_fish','beverages')
    textile = @('fur','raw_hide','leather','wool','flax_yarn','cotton_yarn','textile','cloth','synthetic_fiber','clothing','footwear')
    chemicals = @('refined_fuel','lubricants','petrochemicals','plastics','synthetic_rubber','industrial_chemicals','fertilizer','explosives','soap','detergent','pharmaceuticals','nuclear_fuel')
    metals = @('pig_iron','steel','stainless_steel','copper','aluminum','tin','lead','zinc','manganese_alloy','rare_earth_metals','wire')
    machinery = @('tools','machine_parts','industrial_machinery','agricultural_machinery','electric_motor','engines','batteries','electrical_equipment','electronic_components','semiconductors','computers','telecom_equipment','household_appliances','automobiles','railway_equipment')
    consumer = @('jewelry','clean_water')
    energy = @('electricity')
}

$goods = [ordered]@{}
function Add-Good([string]$Id, [string]$Name, [string]$Category) {
    if ($goods.Contains($Id)) { throw "duplicate good id: $Id" }
    $goods[$Id] = @{ name=$Name; category=$Category }
}
$goodNames = @{
    logs='原木'; raw_stone='原石'; vegetables='蔬菜'; wheat_grain='小麦'; rice_grain='稻米'; corn_grain='玉米'; potatoes='马铃薯'; coal='煤炭'; crude_oil='原油'; natural_gas='天然气'; copper_ore='铜矿石'; iron_ore='铁矿石'; gold='黄金'; silver='白银'; salt='食盐'; latex='天然乳胶'; saltpeter='硝石'; rare_earth_ore='战略矿物精矿'; clay='黏土'; horses='马匹'; game_meat='野味'; spices='香料'; flax_fiber='亚麻纤维'; cotton_fiber='棉纤维'; cattle='牛'; sheep='羊'; pigs='猪'; medicinal_herbs='药材'; raw_water='原水'; fish='鱼类'; bauxite='铝土矿'; limestone='石灰石'; silica_sand='硅砂'; phosphate_rock='磷矿石'; tin_ore='锡矿石'; lead_ore='铅矿石'; zinc_ore='锌矿石'; manganese_ore='锰矿石'; sulfur='硫磺';
    lumber='锯材'; wood_pulp='纸浆'; paper='纸张'; packaging='包装材料'; printed_materials='印刷品'; furniture='家具'; cut_stone='石材'; bricks='砖'; lime='石灰'; cement='水泥'; concrete='混凝土'; glass='玻璃'; construction_components='建筑构件'; grain='混合谷物'; flour='面粉'; bread='面包'; rice_food='米制食品'; corn_food='玉米食品'; potato_food='薯类食品'; animal_feed='饲料'; edible_oil='食用油'; processed_food='加工食品'; dairy_products='乳制品'; beef='牛肉'; mutton='羊肉'; pork='猪肉'; canned_fish='水产罐头'; beverages='饮料'; fur='皮毛'; raw_hide='生皮'; leather='皮革'; wool='羊毛'; flax_yarn='亚麻纱'; cotton_yarn='棉纱'; textile='纺织品'; cloth='布料'; synthetic_fiber='合成纤维'; clothing='服装'; footwear='鞋靴'; refined_fuel='成品燃料'; lubricants='润滑油'; petrochemicals='石化原料'; plastics='塑料'; synthetic_rubber='合成橡胶'; industrial_chemicals='工业化学品'; fertilizer='化肥'; explosives='炸药'; soap='肥皂'; detergent='清洁剂'; pharmaceuticals='药品'; nuclear_fuel='核燃料'; pig_iron='生铁'; steel='钢材'; stainless_steel='不锈钢'; copper='铜'; aluminum='铝'; tin='锡'; lead='铅'; zinc='锌'; manganese_alloy='锰合金'; rare_earth_metals='战略矿物材料'; wire='电线'; tools='工具'; machine_parts='机械零件'; industrial_machinery='工业机械'; agricultural_machinery='农业机械'; electric_motor='电动机'; engines='发动机'; batteries='电池'; electrical_equipment='电气设备'; electronic_components='电子元件'; semiconductors='半导体'; computers='计算机'; telecom_equipment='通信设备'; household_appliances='家用电器'; automobiles='汽车'; railway_equipment='铁路设备'; jewelry='珠宝'; clean_water='净水'; electricity='电力'
}
foreach ($row in $resourceRows) { Add-Good $row[2] $goodNames[$row[2]] 'primary' }
foreach ($category in $processedGroups.Keys) {
    foreach ($id in $processedGroups[$category]) {
        if (-not $goods.Contains($id)) { Add-Good $id $goodNames[$id] $(if ($id -eq 'tools') { 'tools' } else { $category }) }
    }
}
if ($goods.Count -lt 110) { throw "generated good baseline unexpectedly small: $($goods.Count)" }

$categoryPrice = @{ primary=10000; forestry=18000; construction=22000; food=16000; textile=24000; chemicals=30000; metals=36000; machinery=52000; tools=52000; consumer=60000; energy=12000 }
function Technology-For-Good([string]$Id) {
    $technologyByGood = @{
        logs='tech.gathering'; lumber='tech.gathering'; game_meat='tech.hunting'; gold='tech.gathering'; silver='tech.gathering'
        fur='tech.hunting'; raw_hide='tech.hunting'; processed_food='tech.fire_control'
        cloth='tech.gathering'; grain='tech.pottery'; vegetables='tech.pottery'
        tools='tech.stone_knapping'; clay='tech.pottery'; furniture='tech.pottery'
        copper_ore='tech.bronze_casting'; copper='tech.bronze_casting'
        tin_ore='tech.bronze_casting'; tin='tech.bronze_casting'
        corn_grain='tech.manuscript_culture'; pigs='tech.manuscript_culture'; horses='tech.manuscript_culture'
        cattle='tech.guild_organization'; sheep='tech.guild_organization'
        flax_fiber='tech.oceanic_navigation'; cotton_fiber='tech.oceanic_navigation'
        spices='tech.oceanic_navigation'; latex='tech.oceanic_navigation'; medicinal_herbs='tech.oceanic_navigation'
        raw_stone='tech.masonry'; silica_sand='tech.masonry'; cut_stone='tech.masonry'
        glass='tech.masonry'; construction_components='tech.masonry'
        printed_materials='tech.printing_press'
        industrial_machinery='tech.precision_engineering'; coal='tech.coke_smelting'
        iron_ore='tech.steam_power'; steel='tech.steam_power'
        railway_equipment='tech.steam_power'; electricity='tech.electrification'
        electrical_equipment='tech.electrification'; electronic_components='tech.radio'
        pharmaceuticals='tech.nuclear_fission'; nuclear_fuel='tech.nuclear_fission'; semiconductors='tech.digital_computing'
        computers='tech.digital_computing'; telecom_equipment='tech.networked_computing'
        batteries='tech.legacy_modern_economy'; electric_motor='tech.legacy_modern_economy'
        rare_earth_ore='tech.geological_prospecting'; rare_earth_metals='tech.advanced_metallurgy'
    }
    if ($technologyByGood.ContainsKey($Id)) { return $technologyByGood[$Id] }
    return 'tech.legacy_modern_economy'
}
foreach ($id in $goods.Keys) {
    $g = $goods[$id]
    $price = [int]$categoryPrice[$g.category]
    $technology = Technology-For-Good $id
	$demandElasticity = switch ($g.category) {
		'primary' { 29491 } 'food' { 22938 } 'forestry' { 49152 }
		'construction' { 49152 } 'textile' { 58982 } 'chemicals' { 52429 }
		'metals' { 45875 } 'machinery' { 75366 } 'consumer' { 85197 }
		'energy' { 19661 } default { 65536 }
	}
	$targetDays = switch ($g.category) {
		'primary' { 458752 } 'food' { 327680 }
		'forestry' { 655360 } 'construction' { 655360 }
		'textile' { 655360 } 'chemicals' { 655360 } 'metals' { 655360 }
		'machinery' { 1310720 } 'consumer' { 983040 } 'energy' { 327680 }
		default { 196608 }
	}
	$priceAdjust = [Math]::Max(512, [int][Math]::Round(2048.0 * $demandElasticity / 65536.0))
    $issue = if ($id -eq 'gold') { 800000 } elseif ($id -eq 'silver') { 10000 } else { 0 }
    $mode = if ($id -eq 'electricity') { 'cycle_flow' } else { 'stock' }
    $content = @"
[gd_resource type="Resource" script_class="GoodProfile" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/data/good_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"$id"
display_name = "$($g.name)"
category_id = &"$($g.category)"
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
target_inventory_days_q16 = $(if ($mode -eq 'cycle_flow') { 0 } else { $targetDays })
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
    Write-Utf8 (Join-Path $goodsDir "$id.tres") $content
}

# Full profession catalog baseline. Keep this list aligned with hand-authored
# cross-era content; generation is intentionally authoritative for all 32 rows.
$professionRows = @(
    @('landlord','地主','landlord_household','tech.bronze_casting'),
    @('merchant','商人','merchant_household','tech.gathering'),
    @('subsistence_farmer','自耕农','subsistence_household','tech.pottery'),
    @('worker','普通工人','worker_household','tech.steam_power'),
    @('industrialist','工业业主','landlord_household','tech.steam_power'),
    @('agricultural_worker','农业工人','worker_household','tech.legacy_modern_economy'),
    @('pastoralist','牧民','worker_household','tech.pottery'),
    @('hunter','猎人','worker_household','tech.hunting'),
    @('fisher','渔民','worker_household','tech.legacy_modern_economy'),
    @('forestry_worker','林业工人','worker_household','tech.gathering'),
    @('miner','矿业工人','worker_household','tech.bronze_casting'),
    @('petroleum_worker','油气工人','skilled_household','tech.legacy_modern_economy'),
    @('construction_worker','建筑工人','worker_household','tech.masonry'),
    @('artisan','工匠','skilled_household','tech.gathering'),
    @('industrial_worker','产业工人','worker_household','tech.steam_power'),
    @('machinist','机械师','skilled_household','tech.precision_engineering'),
    @('technician','技术工人','skilled_household','tech.electrification'),
    @('engineer','工程师','skilled_household','tech.precision_engineering'),
    @('chemist','化学工','skilled_household','tech.experimental_science'),
    @('metallurgist','冶金工','skilled_household','tech.bronze_casting'),
    @('electrician','电工','skilled_household','tech.electrification'),
    @('transport_worker','运输工人','worker_household','tech.oceanic_navigation'),
    @('guild_master','行会师傅','skilled_household','tech.guild_organization'),
    @('forager','采集者','subsistence_household','tech.gathering'),
    @('enslaved_laborer','奴隶劳工','subsistence_household','tech.bronze_casting'),
    @('serf','农奴','subsistence_household','tech.manuscript_culture'),
    @('tenant_farmer','佃农','worker_household','tech.guild_organization'),
    @('indentured_laborer','契约劳工','worker_household','tech.oceanic_navigation'),
    @('apprentice','学徒','subsistence_household','tech.pottery'),
    @('journeyman','帮工','worker_household','tech.writing'),
    @('manager','经营管理者','skilled_household','tech.steam_power'),
    @('researcher','研究人员','skilled_household','tech.experimental_science')
)
if ($professionRows.Count -ne 32) { throw 'profession catalog baseline must be 32' }
foreach ($row in $professionRows) {
    $content = @"
[gd_resource type="Resource" script_class="ProfessionProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/profession_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$($row[0])"
display_name = "$($row[1])"
default_consumption_plan_id = &"$($row[2])"
technology_tags = PackedStringArray("$($row[3])")
"@
    Write-Utf8 (Join-Path $professionsDir "$($row[0]).tres") $content
}

$needRows = @(
    @('staple_food','主食',65536), @('protein','蛋白质',65536), @('produce','蔬果',65536), @('clothing','衣着',65536),
    @('housing','住房维护',65536), @('household_goods','家庭用品',32768), @('hygiene','卫生',65536), @('healthcare','医疗',65536),
    @('home_energy','家庭能源',65536), @('transport','交通',32768), @('communication','通信',32768),
    @('education_culture','教育文化',0), @('recreation','娱乐',0), @('durable_goods','耐用品',0), @('luxury','奢侈品',0)
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
    @{id='staple_food'; variants=@(@('grain'),@('bread'),@('rice_food'),@('potato_food'),@('gathered_plants'))},
    @{id='protein'; variants=@(@('beef'),@('mutton'),@('pork'),@('canned_fish'),@('game_meat'))},
    @{id='produce'; variants=@(@('processed_food'),@('gathered_plants'),@('vegetables'))}, @{id='clothing'; variants=@(@('clothing'),@('cloth'),@('fur'),@('footwear'))},
    @{id='housing'; variants=@(@('construction_components'))}, @{id='household_goods'; variants=@(@('furniture'),@('pottery'))},
    @{id='hygiene'; variants=@(@('soap','detergent'))}, @{id='healthcare'; variants=@(@('pharmaceuticals'))},
    @{id='home_energy'; variants=@(@('refined_fuel'),@('natural_gas'))},
    @{id='transport'; variants=@(@('automobiles','refined_fuel'),@('railway_equipment'))},
    @{id='communication'; variants=@(@('telecom_equipment'),@('radio_equipment'))},
    @{id='education_culture'; variants=@(@('printed_materials'),@('computers'),@('manuscripts'),@('codices'))},
    @{id='recreation'; variants=@(@('computers'),@('horses'))}, @{id='durable_goods'; variants=@(@('household_appliances'),@('autonomous_systems'))},
    @{id='luxury'; variants=@(@('jewelry'),@('beverages'))}
)
function Write-Plan([string]$Id, [string]$Name, [int]$Scale) {
    $needIds = @(); $priorities = @(); $base = @(); $elasticity = @(); $mins = @(); $maxs = @(); $env = @()
    $needOffsets = @(0); $variantIds = @(); $preferences = @(); $variantElasticity = @(); $variantEnv = @()
    $componentOffsets = @(0); $componentIds = @(); $componentQty = @()
    $v = 0; $c = 0
    for ($n=0; $n -lt $needSpecs.Count; $n++) {
        $spec = $needSpecs[$n]; $needIds += $spec.id; $priorities += $n
        $base += [Math]::Max(1, [int](($(if ($n -lt 3) { 500 } else { 20 })) * $Scale / 100))
        $elasticity += $(if ($n -lt 3) { 8192 } else { 65536 }); $mins += 8192; $maxs += 262144
        $env += $(if ($spec.id -eq 'clothing') { 'cold_clothing_quantity' } else { '' })
        foreach ($variant in $spec.variants) {
            $variantIds += "$($spec.id)_$v"; $preferences += 65536; $variantElasticity += 65536
            $variantEnv += $(if ($spec.id -eq 'clothing' -and $variant -contains 'fur') { 'cold_fur_preference' } elseif ($spec.id -eq 'clothing') { 'warm_cloth_preference' } else { '' })
            foreach ($good in $variant) { $componentIds += $good; $componentQty += 1000; $c++ }
            $componentOffsets += $c; $v++
        }
        $needOffsets += $v
    }
    if ($componentIds.Count -gt 64) { throw "plan component limit: $Id" }
    $content = @"
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
    Write-Utf8 (Join-Path $plansDir "$Id.tres") $content
}
Write-Plan 'subsistence_household' '生存家庭消费' 55
Write-Plan 'worker_household' '劳动者家庭消费' 80
Write-Plan 'skilled_household' '技术人员家庭消费' 100
Write-Plan 'landlord_household' '业主家庭消费' 135
Write-Plan 'merchant_household' '商人家庭消费' 120

$deps = @{
    lumber=@('logs'); wood_pulp=@('logs','industrial_chemicals'); paper=@('wood_pulp'); packaging=@('paper','plastics'); printed_materials=@('paper','industrial_chemicals'); furniture=@('lumber','textile');
    cut_stone=@('raw_stone','tools'); bricks=@('clay','coal'); lime=@('limestone','coal'); cement=@('lime','clay'); concrete=@('cement','raw_stone'); glass=@('silica_sand','coal'); construction_components=@('concrete','steel','glass','bricks','cut_stone');
    grain=@('wheat_grain','rice_grain','corn_grain'); flour=@('grain'); bread=@('flour','clean_water'); rice_food=@('rice_grain','clean_water'); corn_food=@('corn_grain','clean_water'); potato_food=@('potatoes','edible_oil'); animal_feed=@('grain'); edible_oil=@('corn_grain'); processed_food=@('vegetables','game_meat','dairy_products','corn_food','spices','salt','packaging'); dairy_products=@('cattle','clean_water'); beef=@('cattle'); mutton=@('sheep'); pork=@('pigs'); canned_fish=@('fish','salt','packaging'); beverages=@('clean_water','sugar_placeholder');
    raw_hide=@('cattle'); leather=@('raw_hide','industrial_chemicals'); wool=@('sheep'); flax_yarn=@('flax_fiber'); cotton_yarn=@('cotton_fiber'); textile=@('flax_yarn','cotton_yarn','wool'); cloth=@('textile'); synthetic_fiber=@('petrochemicals'); clothing=@('cloth','synthetic_fiber','fur'); footwear=@('leather','synthetic_rubber','latex');
    refined_fuel=@('crude_oil'); lubricants=@('crude_oil'); petrochemicals=@('crude_oil','natural_gas'); plastics=@('petrochemicals'); synthetic_rubber=@('petrochemicals','sulfur'); industrial_chemicals=@('sulfur','salt'); fertilizer=@('phosphate_rock','natural_gas'); explosives=@('saltpeter','sulfur'); soap=@('edible_oil','salt'); detergent=@('petrochemicals','industrial_chemicals'); pharmaceuticals=@('medicinal_herbs','industrial_chemicals'); nuclear_fuel=@('rare_earth_metals');
    pig_iron=@('iron_ore','coal'); steel=@('pig_iron','coal'); stainless_steel=@('steel','rare_earth_metals','manganese_alloy'); copper=@('copper_ore','coal'); aluminum=@('bauxite','electricity'); tin=@('tin_ore','coal'); lead=@('lead_ore','coal'); zinc=@('zinc_ore','coal'); manganese_alloy=@('manganese_ore','steel'); rare_earth_metals=@('rare_earth_ore'); wire=@('copper','plastics');
    tools=@('steel','lumber'); machine_parts=@('steel','lubricants'); industrial_machinery=@('machine_parts','electric_motor'); agricultural_machinery=@('industrial_machinery','engines'); electric_motor=@('copper','steel'); engines=@('steel','aluminum','machine_parts'); batteries=@('lead','rare_earth_metals','industrial_chemicals'); electrical_equipment=@('wire','steel','plastics'); electronic_components=@('copper','tin','zinc','plastics','rare_earth_metals'); semiconductors=@('silica_sand','industrial_chemicals','electricity'); computers=@('semiconductors','electronic_components','plastics'); telecom_equipment=@('semiconductors','wire','batteries','plastics'); household_appliances=@('electrical_equipment','stainless_steel','plastics'); automobiles=@('engines','steel','batteries','synthetic_rubber'); railway_equipment=@('stainless_steel','engines','electrical_equipment'); jewelry=@('gold','silver','rare_earth_metals'); clean_water=@('raw_water','industrial_chemicals'); electricity=@('coal')
}
$deps.beverages = @('clean_water','processed_food','packaging')

function Collector-Id([string]$Resource) {
    switch ($Resource) { 'wheat' {'wheat_farm'} 'corn' {'landed_estate'} 'coal' {'coal_mine'} 'gold_ore' {'gold_mine'} 'silver_ore' {'silver_mine'} default {"${Resource}_collector"} }
}
function Collector-Display-Name([string]$Resource,[string]$ResourceName) {
    switch ($Resource) {
        'fertile_soil' {'蔬菜农场'} 'wheat' {'小麦农场'} 'rice' {'水稻农场'}
        'corn' {'玉米农场'} 'potato' {'马铃薯农场'} 'flax' {'亚麻农场'}
        'cotton' {'棉花农场'} 'spice_plants' {'香料种植园'}
        'rubber_tree' {'橡胶种植园'} 'medicinal_herbs' {'药用植物种植园'}
        'marine_fish' {'海洋渔港'} default {"${ResourceName}采集设施"}
    }
}
function Worker-For-Resource([string]$Resource) {
    if ($Resource -in @('wheat','rice','corn','potato','fertile_soil','spice_plants','flax','cotton','medicinal_herbs')) { return 'agricultural_worker' }
    if ($Resource -in @('cattle','sheep','pigs','horses')) { return 'pastoralist' }
    if ($Resource -eq 'wild_game') { return 'hunter' }; if ($Resource -eq 'marine_fish') { return 'fisher' }
    if ($Resource -eq 'timber') { return 'forestry_worker' }
    if ($Resource -in @('oil','natural_gas')) { return 'petroleum_worker' }
    return 'miner'
}
function Technology-For-Building([string]$Id) {
    if ($Id -in @('landed_estate','pigs_collector','horses_collector')) { return 'tech.manuscript_culture' }
    if ($Id -in @('cattle_collector','sheep_collector')) { return 'tech.guild_organization' }
    if ($Id -in @('flax_collector','cotton_collector','spice_plants_collector','rubber_tree_collector','medicinal_herbs_collector')) { return 'tech.oceanic_navigation' }
    if ($Id -eq 'wild_game_collector') { return 'tech.hunting' }
    if ($Id -in @('timber_collector','lumber_plant')) { return 'tech.gathering' }
    if ($Id -eq 'electricity_plant') { return 'tech.electrification' }
    if ($Id -eq 'rare_earth_collector') { return 'tech.geological_prospecting' }
    if ($Id -eq 'rare_earth_metals_plant') { return 'tech.advanced_metallurgy' }
    if ($Id -eq 'nuclear_fuel_plant') { return 'tech.nuclear_fission' }
    if ($Id -eq 'nuclear_power_plant') { return 'tech.nuclear_fission' }
    return 'tech.legacy_modern_economy'
}
function Extraction-Ratio-For-Building([string]$Id) {
    if ($Id -in @('marine_fish_collector','freshwater_fish_collector')) { return 8 }
    if ($Id -in @('cattle_collector','sheep_collector','pigs_collector','horses_collector')) { return 10 }
    if ($Id -in @('clay_collector','limestone_collector','silica_sand_collector','stone_collector','salt_collector')) { return 10 }
    if ($Id -eq 'timber_collector') { return 16 }
    if ($Id -eq 'wild_game_collector') { return 20 }
    if ($Id -in @('fresh_water_collector','oil_collector','natural_gas_collector','rare_earth_collector')) { return 25 }
    return 20
}
function Write-Building([string]$Id,[string]$Name,[string]$Kind,[string]$Owner,[string]$Worker,[string[]]$Inputs,[string[]]$Outputs,[string[]]$Resources,[string[]]$ResourceModes,[string]$Behavior,[string]$Category) {
    # Resource-to-goods conversion is content-level extraction efficiency.
    # It varies by collection method and technology instead of using 1:1 or a global ratio.
    $unitQty = switch ($Id) {
        'marine_fish_collector' { [long]1000 }
        'freshwater_fish_collector' { [long]400 }
        'electricity_plant' { [long]9000 }
        'gas_power_plant' { [long]12000 }
        'oil_power_plant' { [long]10500 }
        'nuclear_power_plant' { [long]18000 }
        default { [long]10000 }
    }
    $inputQty = @($Inputs | ForEach-Object { [long]1000 })
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
    $resourceAccessModes = @($Resources | ForEach-Object {
        if ($_ -in @('fresh_water','marine_fish','freshwater_fish')) { 'local_and_adjacent' } else { 'local' }
    })
    [string[]]$roleIds = @()
    [long[]]$roleSlots = @()
    [string[]]$roleWagePolicies = @()
    [long[]]$roleWages = @()
    if ($Id -in @('rice_collector','potato_collector','fertile_soil_collector')) {
        $Owner = 'subsistence_farmer'
    } elseif ($Id -in @('landed_estate','pigs_collector','horses_collector')) {
        $Owner = 'landlord'; $roleIds = @('serf'); $roleSlots = @(10)
        $roleWagePolicies = @('fixed'); $roleWages = @(1000)
    } elseif ($Id -in @('cattle_collector','sheep_collector')) {
        $Owner = 'landlord'; $roleIds = @('tenant_farmer'); $roleSlots = @(10)
        $roleWagePolicies = @('fixed'); $roleWages = @(2000)
    } elseif ($Id -in @('flax_collector','cotton_collector','spice_plants_collector','rubber_tree_collector','medicinal_herbs_collector')) {
        $Owner = 'landlord'; $roleIds = @('indentured_laborer'); $roleSlots = @(10)
        $roleWagePolicies = @('fixed'); $roleWages = @(1500)
    } elseif ($Id -eq 'wild_game_collector') {
        $Owner = 'hunter'
    } elseif ($Id -eq 'timber_collector') {
        $Owner = 'forager'
    } elseif ($Id -eq 'lumber_plant') {
        $Owner = 'artisan'
    } elseif ($Kind -eq 'collector') {
        $Owner = 'industrialist'; $roleIds = @($Worker, 'manager'); $roleSlots = @(14, 2)
        $roleWagePolicies = @('adaptive', 'adaptive'); $roleWages = @(5000, 9000)
    } else {
        $Owner = 'industrialist'
        if ($Worker -eq 'industrial_worker') {
            $roleIds = @('industrial_worker', 'manager'); $roleSlots = @(16, 2)
            $roleWagePolicies = @('adaptive', 'adaptive'); $roleWages = @(5000, 9000)
        } else {
            $roleIds = @('industrial_worker', $Worker, 'manager'); $roleSlots = @(10, 6, 2)
            $roleWagePolicies = @('adaptive', 'adaptive', 'adaptive'); $roleWages = @(5000, 7000, 9000)
        }
    }
    $technology = Technology-For-Building $Id
    $inputCategories = @($Inputs | ForEach-Object { if ($_ -eq 'tools') { 'tools' } else { '' } })
    $inputMinLevels = @($Inputs | ForEach-Object {
        if ($_ -ne 'tools') { 0 } elseif ($technology -eq 'tech.legacy_modern_economy') { 3 } else { 1 }
    })
    $generationIds = @(); $generationQty = @(); $floor = 0
	$targetMargin = if ($Kind -eq 'collector') { 6554 } else { 9830 }
	$supplyElasticity = if ($Kind -eq 'collector') { 32768 } else { 65536 }
	if ($Outputs -contains 'electricity') { $targetMargin = 5243; $supplyElasticity = 16384 }
    if ($Behavior -eq 'cultivate_local_resources') { $generationIds = $Resources; $generationQty = @($Resources | ForEach-Object { [long]1050 }); $floor = 6554 }
    $content = @"
[gd_resource type="Resource" script_class="BuildingProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$Id"
display_name = "$Name"
building_kind = "$Kind"
technology_tags = PackedStringArray("industry.$Category", "$technology")
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
    Write-Utf8 (Join-Path $buildingsDir "$Id.tres") $content
}

function Write-SelfSufficientBuilding(
    [string]$Id, [string]$Name, [string]$Technology, [string]$Family,
    [int]$Tier, [string]$Owner, [string[]]$Outputs, [long[]]$OutputQty,
    [string[]]$Resources, [long[]]$ResourceQty) {
    $shares = if ($Outputs.Count -eq 2) { @(32768, 32768) } else { @() }
    $content = @"
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
owner_slots_per_building = 1
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
    Write-Utf8 (Join-Path $buildingsDir "$Id.tres") $content
}

$buildingIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($row in $resourceRows) {
    $sourceRid=$row[0]; $rid=$sourceRid; $outputs=@($row[2]); if ($sourceRid -eq 'wild_game') { $outputs += 'fur' }
	$buildingResources = @($rid); $resourceModes = @('extract')
	if ($sourceRid -in @('wheat','corn','potato','flax','cotton','fertile_soil')) {
		$buildingResources = @('arable_land','fertile_soil'); $resourceModes = @('capacity','capacity')
	} elseif ($sourceRid -eq 'rice') {
		$buildingResources = @('paddy_land'); $resourceModes = @('capacity')
	} elseif ($sourceRid -in @('spice_plants','rubber_tree','medicinal_herbs')) {
		$buildingResources = @('plantation_land','fertile_soil'); $resourceModes = @('capacity','capacity')
	}
	$owner = if ($sourceRid -eq 'corn') { 'landlord' } elseif ($sourceRid -in @('rice','potato','fertile_soil')) { 'subsistence_farmer' } elseif ($sourceRid -in @('spice_plants','flax','cotton','cattle','sheep','pigs','horses','medicinal_herbs')) { 'landlord' } else { 'industrialist' }
    $behavior = if ($sourceRid -in $cultivatedResourceIds -or $sourceRid -eq 'fertile_soil') { 'consume_local_resources' } elseif ($sourceRid -in @('cattle','sheep','pigs','horses','wild_game','timber')) { 'cultivate_local_resources' } else { 'consume_local_resources' }
    $id=Collector-Id $sourceRid; [void]$buildingIds.Add($id)
    $collectorInputs = @()
    if ($rid -in @('wheat','rice','potato','fertile_soil')) { $collectorInputs = @('fertilizer','agricultural_machinery') }
    elseif ($rid -in @('coal','copper_ore','iron_ore','gold_ore','silver_ore','saltpeter','rare_earth','clay','bauxite','limestone','silica_sand','phosphate_rock','tin_ore','lead_ore','zinc_ore','manganese_ore','sulfur')) { $collectorInputs = @('tools','explosives','electricity') }
    elseif ($rid -in @('oil','natural_gas')) { $collectorInputs = @('industrial_machinery','electricity') }
    elseif ($rid -eq 'timber') { $collectorInputs = @('tools') }
	if ($rid -in @('corn','coal','cattle','sheep','pigs','horses',
        'spice_plants','flax','cotton','medicinal_herbs')) { $collectorInputs = @() }
	if ($rid -eq 'rare_earth') { $collectorInputs = @('tools') }
	$collectorWorker = if ($sourceRid -eq 'corn') { '' } else { Worker-For-Resource $sourceRid }
    $collectorDisplayName = Collector-Display-Name $sourceRid $row[1]
    Write-Building $id $collectorDisplayName 'collector' $owner $collectorWorker $collectorInputs $outputs $buildingResources $resourceModes $behavior 'primary'
}
if (-not $buildingIds.Add('freshwater_fish_collector')) { throw 'duplicate freshwater fishery id' }
Write-Building 'freshwater_fish_collector' '淡水渔场' 'collector' 'industrialist' 'fisher' @() @('fish') @('freshwater_fish') @('extract') 'consume_local_resources' 'primary'
foreach ($category in $processedGroups.Keys) {
    foreach ($good in $processedGroups[$category]) {
        if ($good -eq 'fur') { continue }
        $id = if ($good -eq 'cloth') { 'textile_workshop' } else { "${good}_plant" }
        if (-not $buildingIds.Add($id)) { throw "duplicate building id: $id" }
        $worker = switch ($category) { 'forestry' {'artisan'} 'construction' {'construction_worker'} 'food' {'industrial_worker'} 'textile' {'artisan'} 'chemicals' {'chemist'} 'metals' {'metallurgist'} 'machinery' {'machinist'} 'consumer' {'artisan'} 'energy' {'electrician'} default {'technician'} }
		$industryOwner = 'industrialist'
		Write-Building $id "$($goodNames[$good])工厂" 'industrial' $industryOwner $worker @($deps[$good]) @($good) @() @() 'none' $category
    }
}
foreach ($power in @(
    @('gas_power_plant','燃气发电厂','natural_gas'),
    @('oil_power_plant','燃油发电厂','refined_fuel'),
    @('nuclear_power_plant','核电站','nuclear_fuel')
)) {
    if (-not $buildingIds.Add($power[0])) { throw "duplicate building id: $($power[0])" }
    Write-Building $power[0] $power[1] 'industrial' 'industrialist' 'electrician' @($power[2]) @('electricity') @() @() 'none' 'energy'
}

# Persistent owner-operated subsistence families. Higher tiers obsolete only
# new construction; lower tiers remain valid production assets.
Write-SelfSufficientBuilding 'gathering_ground' '采集地' 'tech.gathering' `
    'subsistence_food' 1 'forager' @('gathered_plants') @(3000) `
    @('fertile_soil') @(1000)
Write-SelfSufficientBuilding 'subsistence_farm' '早期自耕农田' 'tech.pottery' `
    'subsistence_food' 2 'subsistence_farmer' @('grain','vegetables') @(4000,4000) `
    @('arable_land','fertile_soil') @(10000,10000)
Write-SelfSufficientBuilding 'three_field_smallholding' '轮作自耕农田' 'tech.guild_organization' `
    'subsistence_food' 3 'subsistence_farmer' @('grain','vegetables') @(6000,6000) `
    @('arable_land','fertile_soil') @(8000,8000)
Write-SelfSufficientBuilding 'improved_smallholding' '改良自耕农田' 'tech.steam_power' `
    'subsistence_food' 4 'subsistence_farmer' @('grain','vegetables') @(8000,8000) `
    @('arable_land','fertile_soil') @(6000,6000)
Write-SelfSufficientBuilding 'household_weaving_shelter' '家庭手织棚' 'tech.gathering' `
    'household_cloth' 1 'artisan' @('cloth') @(120) @('fertile_soil') @(1000)
Write-SelfSufficientBuilding 'household_loom' '家庭织机坊' 'tech.pottery' `
    'household_cloth' 2 'artisan' @('cloth') @(220) `
    @('arable_land','fertile_soil') @(10000,10000)
Write-SelfSufficientBuilding 'cottage_weaving' '乡村家庭织坊' 'tech.guild_organization' `
    'household_cloth' 3 'artisan' @('cloth') @(400) `
    @('arable_land','fertile_soil') @(8000,8000)
Write-SelfSufficientBuilding 'improved_domestic_loom' '改良家庭织坊' 'tech.steam_power' `
    'household_cloth' 4 'artisan' @('cloth') @(600) `
    @('arable_land','fertile_soil') @(6000,6000)
foreach ($id in @('gathering_ground','subsistence_farm','three_field_smallholding','improved_smallholding',
    'household_weaving_shelter','household_loom','cottage_weaving','improved_domestic_loom')) {
    if (-not $buildingIds.Add($id)) { throw "duplicate subsistence building id: $id" }
}
if ($buildingIds.Count -lt 90) { throw "building count below target: $($buildingIds.Count)" }

$generatedResourceIds = @('fresh_water','marine_fish','freshwater_fish',
    'arable_land','paddy_land','plantation_land','bauxite','limestone',
    'silica_sand','phosphate_rock','tin_ore','lead_ore',
    'zinc_ore','manganese_ore','sulfur')
$newResources = $naturalResourceRows | Where-Object { $_[0] -in $generatedResourceIds }
foreach ($row in $newResources) {
    $id=$row[0]
    $habitat = if ($id -eq 'marine_fish') { 'marine_water' } elseif ($id -in @('fresh_water','freshwater_fish')) { 'freshwater' } else { 'land' }
    $genBase=0.0; $genSelf=0.0; $decaySelf=0.0
    $initBase=-120000.0; $initTemp=0.0; $initMoisture=0.0; $initElevation=0.0
    $initRiver=0.0; $initVolcano=0.0; $initClimateFit=0.0
    $initNoise=100000.0; $noiseScale=0.07
    $family=''; $province=0.0; $belt=0.0; $provinceScale=0.012; $beltScale=0.035
    $tempOpt=0.5; $tempTol=1.0; $moistureOpt=0.5; $moistureTol=1.0
    $reserveScale = if ($id -in @('fresh_water','marine_fish','freshwater_fish')) { 2.0 } `
        elseif ($id -in @('arable_land','paddy_land','plantation_land')) { 1.0 } else { 8.0 }
    switch ($id) {
        'fresh_water' { $genBase=1.0; $genSelf=0.01; $decaySelf=0.005; $initBase=-60.0; $initMoisture=80.0; $initRiver=400.0; $initNoise=80.0; $noiseScale=0.04 }
        'marine_fish' { $genBase=2.0; $genSelf=0.02; $decaySelf=0.002; $initBase=400.0; $initNoise=1200.0; $noiseScale=0.045 }
        'freshwater_fish' { $genBase=0.8; $genSelf=0.01; $decaySelf=0.004; $initBase=100.0; $initRiver=160.0; $initNoise=300.0; $noiseScale=0.06 }
        'arable_land' { $initBase=-40.0; $initMoisture=25.0; $initElevation=-35.0; $initRiver=30.0; $initClimateFit=140.0; $initNoise=30.0; $tempOpt=0.55; $tempTol=0.42; $moistureOpt=0.55; $moistureTol=0.4 }
        'paddy_land' { $initBase=-90.0; $initMoisture=70.0; $initElevation=-25.0; $initRiver=180.0; $initClimateFit=120.0; $initNoise=20.0; $tempOpt=0.68; $tempTol=0.32; $moistureOpt=0.78; $moistureTol=0.28 }
        'plantation_land' { $initBase=-85.0; $initMoisture=55.0; $initElevation=-20.0; $initClimateFit=150.0; $initNoise=35.0; $tempOpt=0.72; $tempTol=0.3; $moistureOpt=0.7; $moistureTol=0.3 }
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
    $content = @"
[gd_resource type="Resource" script_class="ResourceProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/resource_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"$id"
display_name = "$($row[1])"
reserve_component = &"cell.res_${id}_reserve"
habitat_mode = "$habitat"
init_reserve_scale = $reserveScale
temp_lo = -30.0
temp_hi = 45.0
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
"@
    Write-Utf8 (Join-Path $resourcesDir "$id.tres") $content
}

Sync-CuratedDirectory (Join-Path $curatedContentDir 'goods') $goodsDir
Sync-CuratedDirectory (Join-Path $curatedContentDir 'buildings') $buildingsDir
Sync-CuratedDirectory (Join-Path $curatedContentDir 'resources') $resourcesDir

foreach ($directory in @($goodsDir, $buildingsDir, $professionsDir, $needsDir, $plansDir, $resourcesDir)) {
    Assert-FullyManaged $directory
}

$fullGoodsCount = @(Get-ChildItem -LiteralPath $goodsDir -Filter '*.tres' -File).Count
$fullBuildingCount = @(Get-ChildItem -LiteralPath $buildingsDir -Filter '*.tres' -File).Count
$fullResourceCount = @(Get-ChildItem -LiteralPath $resourcesDir -Filter '*.tres' -File).Count
Write-Host "Generated $fullGoodsCount goods, $fullBuildingCount buildings, $($professionRows.Count) professions, $($needRows.Count) needs, and $fullResourceCount resources."
