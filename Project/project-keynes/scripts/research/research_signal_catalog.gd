class_name ResearchSignalCatalog
extends RefCounted

const ResearchSignalDefinitionScript = preload("res://scripts/research/research_signal_definition.gd")
const DevelopmentAchievementCatalogScript = preload(
	"res://scripts/research/development_achievement_catalog.gd")

## Authoritative discovery vocabulary. The row order is stable save/catalog data;
## no C++ string lookup survives catalog compilation.
const SIGNAL_ROWS := [
	["bio.maize", "玉米", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.cereal"],
		["habitat.warm_crop", "habitat.open_grassland"], ["realm.neotropical"], true],
	["bio.wheat", "小麦", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.cereal"],
		["habitat.cool_season_crop", "habitat.open_grassland"], ["realm.western_eurasian"], true],
	["bio.rice", "稻", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.cereal"],
		["habitat.warm_crop", "habitat.wetland_crop"], ["realm.east_asian"], true],
	["bio.potato", "马铃薯", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.tuber"],
		["habitat.cool_highland_crop"], ["realm.neotropical"], true],
	["bio.horse", "马匹", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.grazer"],
		["habitat.grazer", "habitat.open_grassland"], ["realm.eurasian_steppe"], true],
	["bio.cotton", "棉花", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.fiber_crop"],
		["habitat.warm_crop"], ["realm.tropical_subtropical"], true],
	["bio.flax", "亚麻", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.fiber_crop"],
		["habitat.cool_season_crop"], ["realm.western_eurasian"], true],
	["bio.spice", "香料作物", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.cash_crop"],
		["habitat.tropical_crop"], ["realm.tropical"], true],
	["bio.rubber", "橡胶树", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.industrial_crop"],
		["habitat.tropical_forest"], ["realm.tropical"], true],

	["landform.freshwater_access", "河湖水系", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.water"], [], [], true],
	["resource.timber", "木材", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.biological"], [], [], true],
	["resource.stone", "石料", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.mineral"], [], [], true],
	["resource.fertile_soil", "肥沃土壤", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.land"], [], [], true],
	["resource.arable_land", "旱地承载力", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.land"], [], [], true],
	["resource.paddy_land", "水田承载力", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.land"], [], [], true],
	["resource.plantation_land", "种植园承载力", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.land"], [], [], true],
	["resource.pasture", "牧场承载力", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.land"], [], [], true],
	["resource.coal", "煤炭", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.fuel"], [], [], true],
	["resource.oil", "石油", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.fuel"], [], [], true],
	["resource.natural_gas", "天然气", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.fuel"], [], [], true],
	["resource.copper_ore", "铜矿", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.metal"], [], [], true],
	["resource.iron_ore", "铁矿", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.metal"], [], [], true],
	["resource.gold_ore", "金矿", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.metal"], [], [], true],
	["resource.silver_ore", "银矿", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.metal"], [], [], true],
	["resource.salt", "盐", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.mineral"], [], [], true],
	["resource.saltpeter", "硝石", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.mineral"], [], [], true],
	["resource.rare_earth", "稀土", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.metal"], [], [], true],
	["resource.clay", "黏土", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.mineral"], [], [], true],
	["resource.wild_game", "野生动物", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.biological"], [], [], true],
	["resource.marine_fish", "海洋鱼类", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.biological"], [], [], true],
	["resource.bauxite", "铝土矿", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.metal"], [], [], true],
	["resource.limestone", "石灰岩", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.mineral"], [], [], true],
	["resource.silica_sand", "硅砂", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.mineral"], [], [], true],
	["resource.phosphate_rock", "磷矿石", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.mineral"], [], [], true],
	["resource.tin_ore", "锡矿", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.metal"], [], [], true],
	["resource.lead_ore", "铅矿", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.metal"], [], [], true],
	["resource.zinc_ore", "锌矿", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.metal"], [], [], true],
	["resource.manganese_ore", "锰矿", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.metal"], [], [], true],
	["resource.sulfur", "硫磺", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.mineral"], [], [], true],
	["resource.flint", "燧石", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.mineral"], [], [], true],
	["resource.freshwater_fish", "淡水鱼群", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.biological"], [], [], true],

	["landform.river_valley", "河谷", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.river"], [], [], true],
	["landform.volcanic", "火山", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.volcanic"], [], [], true],
	["landform.high_plateau", "高原", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.highland"], [], [], true],
	["landform.coastal_estuary", "海岸河口", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.coastal"], [], [], true],
	["landform.coast", "海岸", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.coastal"], [], [], true],
	["landform.arid_basin", "干旱盆地", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.arid"], [], [], true],
	["landform.marsh", "沼泽", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.wetland"], [], [], true],
	["landform.forest", "森林", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.forest"], [], [], true],
	["landform.grassland", "草原", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.grassland"], [], [], true],
	["landform.mountain", "山地", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.highland"], [], [], true],

	["weather.typhoon", "台风经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.weather"], [], [], true],
	["weather.major_flood", "洪水经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.weather"], [], [], true],
	["weather.drought", "干旱经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.weather"], [], [], true],
	["breakthrough.maize_selection", "玉米选育突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.dryland_adaptation", "旱作适应突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.hydraulic_engineering", "水利工程突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.metalworking", "金属加工突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.printing", "印刷突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.steam_power", "蒸汽动力突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.electrification", "电气化突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.industrial_organization", "工业组织突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.automation", "自动化突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.climate_modeling", "气候建模突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
]

## Fine-grained geographic, contact, climate-experience and practice vocabulary
## used by the network technology tree. Contact signals always require runtime
## provenance from an imported sample, trade route or territorial acquisition.
const NETWORK_SIGNAL_ROWS := [
	["bio.sheep", "羊", ResearchSignalDefinitionScript.Kind.BIO, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.grazer"], ["habitat.grazer"], [], true],
	["bio.goat", "山羊", ResearchSignalDefinitionScript.Kind.BIO, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.grazer"], ["habitat.dry_grazer"], [], true],
	["bio.cattle", "牛", ResearchSignalDefinitionScript.Kind.BIO, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.grazer"], ["habitat.grazer"], [], true],
	["bio.pig", "猪", ResearchSignalDefinitionScript.Kind.BIO, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.livestock"], ["habitat.forest_edge"], [], true],
	["bio.camel", "骆驼", ResearchSignalDefinitionScript.Kind.BIO, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.dry_grazer"], ["habitat.arid"], [], true],
	["bio.yak", "牦牛", ResearchSignalDefinitionScript.Kind.BIO, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.cold_grazer"], ["habitat.cool_highland"], [], true],
	["bio.silkworm", "蚕", ResearchSignalDefinitionScript.Kind.BIO, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.fiber_animal"], ["habitat.warm_forest"], [], true],
	["bio.reed", "芦苇", ResearchSignalDefinitionScript.Kind.BIO, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.construction_plant"], ["habitat.wetland"], [], true],
	["bio.bast_fiber", "韧皮纤维植物", ResearchSignalDefinitionScript.Kind.BIO, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.fiber_crop"], ["habitat.forest_edge"], [], true],
	["bio.dye_plant", "染料植物", ResearchSignalDefinitionScript.Kind.BIO, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.dye_crop"], ["habitat.warm_crop"], [], true],
	["bio.medicinal_herb", "野生药草", ResearchSignalDefinitionScript.Kind.BIO, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.medicinal_crop"], ["habitat.forest_edge", "habitat.open_grassland"], [], true],

	["landform.delta", "三角洲", ResearchSignalDefinitionScript.Kind.LANDFORM, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.river"], [], [], true],
	["landform.floodplain", "洪泛平原", ResearchSignalDefinitionScript.Kind.LANDFORM, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.river"], [], [], true],
	["landform.monsoon_basin", "季风盆地", ResearchSignalDefinitionScript.Kind.LANDFORM, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.monsoon"], [], [], true],
	["landform.loess_plain", "黄土平原", ResearchSignalDefinitionScript.Kind.LANDFORM, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.dryland"], [], [], true],
	["landform.steppe_plain", "草原平原", ResearchSignalDefinitionScript.Kind.LANDFORM, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.grassland"], [], [], true],
	["landform.tundra", "苔原", ResearchSignalDefinitionScript.Kind.LANDFORM, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.cold"], [], [], true],
	["landform.conifer_forest", "针叶林", ResearchSignalDefinitionScript.Kind.LANDFORM, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.forest"], [], [], true],
	["landform.oasis", "绿洲", ResearchSignalDefinitionScript.Kind.LANDFORM, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.arid"], [], [], true],
	["landform.steep_slope", "陡坡", ResearchSignalDefinitionScript.Kind.LANDFORM, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.highland"], [], [], true],
	["landform.stable_wind_corridor", "稳定风廊", ResearchSignalDefinitionScript.Kind.LANDFORM, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.wind"], [], [], true],

	["weather.monsoon", "季风经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.weather"], [], [], true],
	["weather.frost", "霜冻经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.weather"], [], [], true],
	["weather.freeze_thaw", "冻融经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.heatwave", "热浪经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.prolonged_wet_season", "连续湿季经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.storm_surge", "风暴潮经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.weather"], [], [], true],
	["weather.repeated_crop_failure", "连续歉收经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.weather"], [], [], true],

	["contact.maize", "玉米样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.wheat", "小麦样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.rice", "稻种样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.potato", "块茎样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.cotton", "棉花样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.flax", "亚麻样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.spice", "香料样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.rubber", "橡胶样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.medicinal_herb", "药草样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.tin", "锡矿贸易接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.maritime_vessel", "外国舰船或远洋船体接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact", "category.maritime"], [], [], true],
	["contact.bast_fiber", "韧皮纤维实物接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact", "category.fiber_crop"], [], [], true],

	["breakthrough.seed_saving", "留种实践突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.rainfed_adaptation", "雨养适应突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.paddy_control", "水田控制突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.terrace_maintenance", "梯田维护突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.mine_support", "矿井支护突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.mine_drainage", "矿井排水突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.kiln_temperature", "炉温控制突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.print_calibration", "印刷校准突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.steam_sealing", "蒸汽密封突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.motor_winding", "电机绕组突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.assembly_line", "流水线组织突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.digital_control", "数字控制突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.maritime_operations", "航运运营突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.watershed_management", "流域治理突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.forest_management", "林业经营突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.chemical_process_control", "化工过程控制突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.energy_control", "能源控制突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], true],
	["breakthrough.hide_working", "生皮处理实践", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough", "category.hunting"], [], [], true],
]

## Occupancy bit 0..31. Envelope/carrier/origin are generation+runtime inputs;
## `realm.*` tags on SIGNAL_ROWS remain presentation metadata and are not read
## by seeding. Generation occupancy ⊆ envelope ∩ assigned landmasses
## ∩ carrier>ε. UNIQUE_HEARTH species fill 100% of habitat on one origin
## landmass; vacant habitat_class niches on other continent-scale landmasses
## get a secondary fill. Cosmopolitan reed covers continent wetlands.
## Runtime neighbor diffusion stays inside a province; local farming can introduce.
const OCCUPANCY_FLAG_NEED_WETLAND_OR_RIVER := 1
const OCCUPANCY_FLAG_NEED_WETLAND := 256
const OCCUPANCY_FLAG_NEED_HIGHLAND := 2
const OCCUPANCY_FLAG_FORBID_TROPICAL_FOREST := 4
const OCCUPANCY_FLAG_NEED_ARID := 8
const OCCUPANCY_FLAG_NEED_DRY_OR_HIGHLAND := 16
const OCCUPANCY_FLAG_FORBID_ARID := 32
const OCCUPANCY_FLAG_FORBID_WARM := 64
const OCCUPANCY_FLAG_FORBID_COLD := 128
const OCCUPANCY_ORIGIN_UNIQUE_HEARTH := 0
const OCCUPANCY_ORIGIN_COSMOPOLITAN := 1
const OCCUPANCY_ORIGIN_UNIQUE_LANDMASS := 0
const OCCUPANCY_GUILD_NONE := 0
const OCCUPANCY_GUILD_FOOD := 1
const OCCUPANCY_GUILD_GRAZER := 2
const OCCUPANCY_GUILD_FIBER := 3
const OCCUPANCY_GUILD_SPECIALTY := 4
const OCCUPANCY_HABITAT_NONE := 0
const OCCUPANCY_HABITAT_OPEN_FOOD := 1
const OCCUPANCY_HABITAT_WETLAND_FOOD := 2
const OCCUPANCY_HABITAT_HIGHLAND_FOOD := 3
const OCCUPANCY_HABITAT_OPEN_GRAZER := 4
const OCCUPANCY_HABITAT_FOREST_GRAZER := 5
const OCCUPANCY_HABITAT_DRY_GRAZER := 6
const OCCUPANCY_HABITAT_COLD_GRAZER := 7
const OCCUPANCY_HABITAT_TROPICAL := 8
const OCCUPANCY_HABITAT_FIBER_OPEN := 9
const OCCUPANCY_HABITAT_FIBER_WET := 10
const OCCUPANCY_HABITAT_FIBER_FOREST := 11
const OCCUPANCY_HABITAT_CLASS_MAX := 11
const OCCUPANCY_MAX_SPECIES := 32

const _VEG_GRASS := [4, 9, 10, 11, 13]
const _VEG_FOREST := [5, 7, 8, 12, 14, 15, 24, 25]
const _VEG_TROPICAL_FOREST := [12, 14, 15, 24, 25]
const _VEG_WETLAND := [19, 20, 21, 27]
const _VEG_COOL_GRASS := [4, 6, 7, 9, 10, 11]
const _VEG_COLD_HIGHLAND := [1, 2, 3, 4, 5, 6]
const _VEG_DRY := [10, 16, 17]
const _VEG_WARM_CROP := [4, 9, 10, 13, 12, 14, 15]
const _VEG_FLAX := [4, 6, 7, 9, 10, 11]
const _VEG_POTATO := [3, 4, 6, 7, 9, 10, 11]
const _VEG_RUBBER := [14, 24, 12, 15]

## carrier empty = envelope only. introduce_goods drive agricultural occupancy.
const BIO_OCCUPANCY_BY_ID := {
	"bio.maize": {
		"carrier": "arable_land", "carrier_alt": "",
		"temp_lo": 0.42, "temp_hi": 0.92, "moist_lo": 0.32, "moist_hi": 1.0,
		"elev_lo": 0.0, "elev_hi": 0.78, "veg": _VEG_GRASS, "flags": 0,
		"max_cost": 16, "fill_keep": 0.58, "guild": OCCUPANCY_GUILD_FOOD,
		"habitat_class": OCCUPANCY_HABITAT_OPEN_FOOD,
		"introduce_goods": ["corn_grain"],
	},
	"bio.wheat": {
		"carrier": "arable_land", "carrier_alt": "",
		"temp_lo": 0.22, "temp_hi": 0.70, "moist_lo": 0.24, "moist_hi": 0.90,
		"elev_lo": 0.0, "elev_hi": 0.82, "veg": _VEG_COOL_GRASS, "flags": 0,
		"max_cost": 16, "fill_keep": 0.58, "guild": OCCUPANCY_GUILD_FOOD,
		"habitat_class": OCCUPANCY_HABITAT_OPEN_FOOD,
		"introduce_goods": ["wheat_grain"],
	},
	"bio.rice": {
		"carrier": "arable_land", "carrier_alt": "paddy_land",
		"temp_lo": 0.48, "temp_hi": 0.95, "moist_lo": 0.48, "moist_hi": 1.0,
		"elev_lo": 0.0, "elev_hi": 0.55, "veg": [],
		"flags": OCCUPANCY_FLAG_NEED_WETLAND,
		"max_cost": 14, "fill_keep": 0.58, "guild": OCCUPANCY_GUILD_FOOD,
		"habitat_class": OCCUPANCY_HABITAT_WETLAND_FOOD,
		"introduce_goods": ["rice_grain"],
	},
	"bio.potato": {
		"carrier": "", "carrier_alt": "",
		"temp_lo": 0.22, "temp_hi": 0.58, "moist_lo": 0.24, "moist_hi": 0.88,
		"elev_lo": 0.30, "elev_hi": 1.0, "veg": _VEG_POTATO,
		"flags": OCCUPANCY_FLAG_NEED_HIGHLAND,
		"max_cost": 12, "fill_keep": 0.52, "guild": OCCUPANCY_GUILD_FOOD,
		"habitat_class": OCCUPANCY_HABITAT_HIGHLAND_FOOD,
		"introduce_goods": ["potatoes"],
	},
	"bio.horse": {
		"carrier": "pasture", "carrier_alt": "",
		"temp_lo": 0.22, "temp_hi": 0.70, "moist_lo": 0.18, "moist_hi": 0.78,
		"elev_lo": 0.0, "elev_hi": 0.84, "veg": _VEG_COOL_GRASS, "flags": 0,
		"max_cost": 18, "fill_keep": 0.52, "guild": OCCUPANCY_GUILD_GRAZER,
		"habitat_class": OCCUPANCY_HABITAT_OPEN_GRAZER,
		"introduce_goods": [],
	},
	"bio.cotton": {
		"carrier": "arable_land", "carrier_alt": "",
		"temp_lo": 0.52, "temp_hi": 0.95, "moist_lo": 0.32, "moist_hi": 0.90,
		"elev_lo": 0.0, "elev_hi": 0.72, "veg": _VEG_WARM_CROP, "flags": 0,
		"max_cost": 14, "fill_keep": 0.55, "guild": OCCUPANCY_GUILD_FIBER,
		"habitat_class": OCCUPANCY_HABITAT_FIBER_OPEN,
		"introduce_goods": ["seed_cotton", "cotton_fiber"],
	},
	"bio.flax": {
		"carrier": "arable_land", "carrier_alt": "",
		"temp_lo": 0.22, "temp_hi": 0.68, "moist_lo": 0.26, "moist_hi": 0.84,
		"elev_lo": 0.0, "elev_hi": 0.82, "veg": _VEG_FLAX, "flags": 0,
		"max_cost": 14, "fill_keep": 0.55, "guild": OCCUPANCY_GUILD_FIBER,
		"habitat_class": OCCUPANCY_HABITAT_FIBER_OPEN,
		"introduce_goods": ["flax_fiber"],
	},
	"bio.spice": {
		"carrier": "arable_land", "carrier_alt": "",
		"temp_lo": 0.60, "temp_hi": 1.0, "moist_lo": 0.45, "moist_hi": 1.0,
		"elev_lo": 0.0, "elev_hi": 0.70, "veg": _VEG_TROPICAL_FOREST, "flags": 0,
		"max_cost": 12, "fill_keep": 0.50, "guild": OCCUPANCY_GUILD_SPECIALTY,
		"habitat_class": OCCUPANCY_HABITAT_TROPICAL,
		"introduce_goods": ["spices"],
	},
	"bio.rubber": {
		"carrier": "plantation_land", "carrier_alt": "",
		"temp_lo": 0.60, "temp_hi": 1.0, "moist_lo": 0.52, "moist_hi": 1.0,
		"elev_lo": 0.0, "elev_hi": 0.68, "veg": _VEG_RUBBER, "flags": 0,
		"max_cost": 12, "fill_keep": 0.48, "guild": OCCUPANCY_GUILD_SPECIALTY,
		"habitat_class": OCCUPANCY_HABITAT_TROPICAL,
		"introduce_goods": ["latex"],
	},
	"bio.sheep": {
		"carrier": "pasture", "carrier_alt": "",
		"temp_lo": 0.16, "temp_hi": 0.62, "moist_lo": 0.18, "moist_hi": 0.80,
		"elev_lo": 0.0, "elev_hi": 0.88, "veg": _VEG_GRASS,
		"flags": OCCUPANCY_FLAG_FORBID_WARM,
		"max_cost": 16, "fill_keep": 0.55, "guild": OCCUPANCY_GUILD_GRAZER,
		"habitat_class": OCCUPANCY_HABITAT_OPEN_GRAZER,
		"introduce_goods": ["wool", "livestock_products"],
	},
	"bio.goat": {
		"carrier": "pasture", "carrier_alt": "",
		"temp_lo": 0.20, "temp_hi": 0.88, "moist_lo": 0.0, "moist_hi": 1.0,
		"elev_lo": 0.0, "elev_hi": 1.0, "veg": [],
		"flags": OCCUPANCY_FLAG_NEED_DRY_OR_HIGHLAND | OCCUPANCY_FLAG_FORBID_TROPICAL_FOREST,
		"max_cost": 14, "fill_keep": 0.50, "guild": OCCUPANCY_GUILD_GRAZER,
		"habitat_class": OCCUPANCY_HABITAT_DRY_GRAZER,
		"introduce_goods": [],
	},
	"bio.cattle": {
		"carrier": "pasture", "carrier_alt": "",
		"temp_lo": 0.34, "temp_hi": 0.82, "moist_lo": 0.56, "moist_hi": 1.0,
		"elev_lo": 0.0, "elev_hi": 0.78, "veg": _VEG_GRASS,
		"flags": OCCUPANCY_FLAG_FORBID_COLD,
		"max_cost": 16, "fill_keep": 0.52, "guild": OCCUPANCY_GUILD_GRAZER,
		"habitat_class": OCCUPANCY_HABITAT_OPEN_GRAZER,
		"introduce_goods": ["dairy_products", "livestock_products"],
	},
	"bio.pig": {
		"carrier": "wild_game", "carrier_alt": "",
		"temp_lo": 0.34, "temp_hi": 0.88, "moist_lo": 0.32, "moist_hi": 1.0,
		"elev_lo": 0.0, "elev_hi": 0.80, "veg": _VEG_FOREST,
		"flags": OCCUPANCY_FLAG_FORBID_COLD,
		"max_cost": 14, "fill_keep": 0.50, "guild": OCCUPANCY_GUILD_GRAZER,
		"habitat_class": OCCUPANCY_HABITAT_FOREST_GRAZER,
		"introduce_goods": [],
	},
	"bio.camel": {
		"carrier": "", "carrier_alt": "",
		"temp_lo": 0.40, "temp_hi": 1.0, "moist_lo": 0.0, "moist_hi": 0.34,
		"elev_lo": 0.0, "elev_hi": 0.88, "veg": _VEG_DRY, "flags": 0,
		"max_cost": 14, "fill_keep": 0.48, "guild": OCCUPANCY_GUILD_GRAZER,
		"habitat_class": OCCUPANCY_HABITAT_DRY_GRAZER,
		"introduce_goods": [],
	},
	"bio.yak": {
		"carrier": "", "carrier_alt": "",
		"temp_lo": 0.0, "temp_hi": 0.32, "moist_lo": 0.12, "moist_hi": 0.80,
		"elev_lo": 0.42, "elev_hi": 1.0, "veg": _VEG_COLD_HIGHLAND, "flags": 0,
		"max_cost": 12, "fill_keep": 0.50, "guild": OCCUPANCY_GUILD_GRAZER,
		"habitat_class": OCCUPANCY_HABITAT_COLD_GRAZER,
		"introduce_goods": [],
	},
	"bio.silkworm": {
		"carrier": "", "carrier_alt": "",
		"temp_lo": 0.55, "temp_hi": 0.92, "moist_lo": 0.56, "moist_hi": 1.0,
		"elev_lo": 0.0, "elev_hi": 0.72, "veg": _VEG_FOREST, "flags": 0,
		"max_cost": 12, "fill_keep": 0.45, "guild": OCCUPANCY_GUILD_SPECIALTY,
		"habitat_class": OCCUPANCY_HABITAT_TROPICAL,
		"introduce_goods": [],
	},
	"bio.reed": {
		"carrier": "", "carrier_alt": "",
		"temp_lo": 0.20, "temp_hi": 0.90, "moist_lo": 0.22, "moist_hi": 1.0,
		"elev_lo": 0.0, "elev_hi": 0.80, "veg": [],
		"flags": OCCUPANCY_FLAG_NEED_WETLAND_OR_RIVER,
		"max_cost": 10, "fill_keep": 0.60, "guild": OCCUPANCY_GUILD_FIBER,
		"habitat_class": OCCUPANCY_HABITAT_FIBER_WET,
		"origin_policy": OCCUPANCY_ORIGIN_COSMOPOLITAN,
		"introduce_goods": ["reed_bundle"],
	},
	"bio.bast_fiber": {
		"carrier": "", "carrier_alt": "",
		"temp_lo": 0.28, "temp_hi": 0.78, "moist_lo": 0.32, "moist_hi": 0.90,
		"elev_lo": 0.0, "elev_hi": 0.80, "veg": _VEG_FOREST,
		"flags": OCCUPANCY_FLAG_FORBID_ARID,
		"max_cost": 12, "fill_keep": 0.50, "guild": OCCUPANCY_GUILD_FIBER,
		"habitat_class": OCCUPANCY_HABITAT_FIBER_FOREST,
		"introduce_goods": ["bast_fiber"],
	},
	"bio.dye_plant": {
		"carrier": "arable_land", "carrier_alt": "",
		"temp_lo": 0.52, "temp_hi": 0.95, "moist_lo": 0.28, "moist_hi": 0.90,
		"elev_lo": 0.0, "elev_hi": 0.75, "veg": _VEG_WARM_CROP, "flags": 0,
		"max_cost": 14, "fill_keep": 0.50, "guild": OCCUPANCY_GUILD_FIBER,
		"habitat_class": OCCUPANCY_HABITAT_FIBER_OPEN,
		"introduce_goods": [],
	},
	"bio.medicinal_herb": {
		"carrier": "", "carrier_alt": "",
		"temp_lo": 0.20, "temp_hi": 0.88, "moist_lo": 0.24, "moist_hi": 0.96,
		"elev_lo": 0.0, "elev_hi": 0.88, "veg": _VEG_FOREST, "flags": 0,
		"max_cost": 14, "fill_keep": 0.50, "guild": OCCUPANCY_GUILD_SPECIALTY,
		"habitat_class": OCCUPANCY_HABITAT_FIBER_FOREST,
		"origin_policy": OCCUPANCY_ORIGIN_COSMOPOLITAN,
		"introduce_goods": ["medicinal_herbs"],
	},
}

const OVERLAY_ICON_BY_ID := {
	"bio.maize": &"economy.crop",
	"bio.wheat": &"economy.crop",
	"bio.rice": &"economy.crop",
	"bio.potato": &"economy.crop",
	"bio.cotton": &"economy.crop",
	"bio.flax": &"economy.crop",
	"bio.spice": &"economy.crop",
	"bio.dye_plant": &"economy.crop",
	"bio.medicinal_herb": &"economy.crop",
	"bio.bast_fiber": &"economy.crop",
	"bio.horse": &"good.horses",
	"bio.sheep": &"good.wool",
	"bio.goat": &"economy.livestock",
	"bio.cattle": &"economy.livestock",
	"bio.camel": &"economy.livestock",
	"bio.yak": &"economy.livestock",
	"bio.pig": &"good.game_meat",
	"bio.rubber": &"ecology.vegetation",
	"bio.reed": &"ecology.vegetation",
	"bio.silkworm": &"ecology.vegetation",
}


static func _veg_masks(veg_ids: Array) -> PackedInt32Array:
	var mask0 := 0
	var mask1 := 0
	for raw in veg_ids:
		var veg_id := int(raw)
		if veg_id >= 0 and veg_id < 32:
			mask0 |= 1 << veg_id
		elif veg_id >= 32 and veg_id < 64:
			mask1 |= 1 << (veg_id - 32)
	return PackedInt32Array([mask0, mask1])


static func compile_native_catalog() -> Dictionary:
	var ids := PackedStringArray()
	var names := PackedStringArray()
	var kinds := PackedInt32Array()
	var persistence := PackedInt32Array()
	var provenance := PackedByteArray()
	var category_offsets := PackedInt32Array([0])
	var category_tags := PackedStringArray()
	var habitat_offsets := PackedInt32Array([0])
	var habitat_tags := PackedStringArray()
	var realm_offsets := PackedInt32Array([0])
	var realm_ids := PackedStringArray()
	var occupancy_bit := PackedInt32Array()
	var bio_signal_ids := PackedInt32Array()
	var bio_occupancy_bits := PackedInt32Array()
	var bio_carrier_ids := PackedStringArray()
	var bio_carrier_alt_ids := PackedStringArray()
	var bio_temp_lo := PackedFloat32Array()
	var bio_temp_hi := PackedFloat32Array()
	var bio_moist_lo := PackedFloat32Array()
	var bio_moist_hi := PackedFloat32Array()
	var bio_elev_lo := PackedFloat32Array()
	var bio_elev_hi := PackedFloat32Array()
	var bio_veg_mask0 := PackedInt32Array()
	var bio_veg_mask1 := PackedInt32Array()
	var bio_flags := PackedInt32Array()
	var bio_max_cost := PackedInt32Array()
	var bio_fill_keep := PackedFloat32Array()
	var bio_origin_policy := PackedInt32Array()
	var bio_guild := PackedInt32Array()
	var bio_habitat_class := PackedInt32Array()
	var bio_introduce_good_ids := PackedStringArray()
	var bio_introduce_occupancy_bits := PackedInt32Array()
	var next_occupancy_bit := 0
	var seen := {}
	# Build a fresh row list on every compile. Array constants are shared by
	# reference in GDScript; mutating a concatenated view would duplicate the
	# development rows on the next catalog compile.
	var authored_rows: Array = []
	authored_rows.append_array((SIGNAL_ROWS as Array).duplicate(true))
	authored_rows.append_array((NETWORK_SIGNAL_ROWS as Array).duplicate(true))
	authored_rows.append_array(DevelopmentAchievementCatalogScript.signal_rows())
	for row in authored_rows:
		var id := String(row[0])
		if not id.contains(".") or seen.has(id):
			return {"ok": false, "reason": "research_signal_id_invalid_or_duplicate", "id": id}
		seen[id] = true
		ids.append(id)
		names.append(String(row[1]))
		kinds.append(int(row[2]))
		persistence.append(int(row[3]))
		provenance.append(1 if bool(row[7]) else 0)
		for tag in row[4]:
			category_tags.append(String(tag))
		category_offsets.append(category_tags.size())
		for tag in row[5]:
			habitat_tags.append(String(tag))
		habitat_offsets.append(habitat_tags.size())
		for realm in row[6]:
			realm_ids.append(String(realm))
		realm_offsets.append(realm_ids.size())
		var kind := int(row[2])
		if kind != ResearchSignalDefinitionScript.Kind.BIO:
			occupancy_bit.append(-1)
			continue
		if next_occupancy_bit >= OCCUPANCY_MAX_SPECIES:
			return {"ok": false, "reason": "research_bio_occupancy_bit_overflow", "id": id}
		if not BIO_OCCUPANCY_BY_ID.has(id):
			return {"ok": false, "reason": "research_bio_occupancy_spec_missing", "id": id}
		var spec: Dictionary = BIO_OCCUPANCY_BY_ID[id]
		var bit := next_occupancy_bit
		next_occupancy_bit += 1
		occupancy_bit.append(bit)
		bio_signal_ids.append(ids.size() - 1)
		bio_occupancy_bits.append(bit)
		bio_carrier_ids.append(String(spec.get("carrier", "")))
		bio_carrier_alt_ids.append(String(spec.get("carrier_alt", "")))
		bio_temp_lo.append(float(spec.get("temp_lo", 0.0)))
		bio_temp_hi.append(float(spec.get("temp_hi", 1.0)))
		bio_moist_lo.append(float(spec.get("moist_lo", 0.0)))
		bio_moist_hi.append(float(spec.get("moist_hi", 1.0)))
		bio_elev_lo.append(float(spec.get("elev_lo", 0.0)))
		bio_elev_hi.append(float(spec.get("elev_hi", 1.0)))
		var masks := _veg_masks(spec.get("veg", []))
		bio_veg_mask0.append(int(masks[0]))
		bio_veg_mask1.append(int(masks[1]))
		bio_flags.append(int(spec.get("flags", 0)))
		bio_max_cost.append(maxi(1, int(spec.get("max_cost", 16))))
		bio_fill_keep.append(clampf(float(spec.get("fill_keep", 0.55)), 0.0, 1.0))
		bio_origin_policy.append(int(spec.get("origin_policy", OCCUPANCY_ORIGIN_UNIQUE_HEARTH)))
		bio_guild.append(int(spec.get("guild", OCCUPANCY_GUILD_NONE)))
		bio_habitat_class.append(int(spec.get("habitat_class", OCCUPANCY_HABITAT_NONE)))
		for good_id in spec.get("introduce_goods", []):
			bio_introduce_good_ids.append(String(good_id))
			bio_introduce_occupancy_bits.append(bit)
	return {
		"ok": true,
		"research_signal_ids": ids,
		"research_signal_display_names": names,
		"research_signal_kinds": kinds,
		"research_signal_persistence": persistence,
		"research_signal_requires_provenance": provenance,
		"research_signal_category_offsets": category_offsets,
		"research_signal_category_tags": category_tags,
		"research_signal_habitat_offsets": habitat_offsets,
		"research_signal_habitat_tags": habitat_tags,
		"research_signal_realm_offsets": realm_offsets,
		"research_signal_realm_ids": realm_ids,
		"research_signal_occupancy_bit": occupancy_bit,
		"research_bio_species_count": next_occupancy_bit,
		"research_bio_signal_ids": bio_signal_ids,
		"research_bio_occupancy_bits": bio_occupancy_bits,
		"research_bio_carrier_ids": bio_carrier_ids,
		"research_bio_carrier_alt_ids": bio_carrier_alt_ids,
		"research_bio_temp_lo": bio_temp_lo,
		"research_bio_temp_hi": bio_temp_hi,
		"research_bio_moist_lo": bio_moist_lo,
		"research_bio_moist_hi": bio_moist_hi,
		"research_bio_elev_lo": bio_elev_lo,
		"research_bio_elev_hi": bio_elev_hi,
		"research_bio_veg_mask0": bio_veg_mask0,
		"research_bio_veg_mask1": bio_veg_mask1,
		"research_bio_flags": bio_flags,
		"research_bio_max_cost": bio_max_cost,
		"research_bio_fill_keep": bio_fill_keep,
		"research_bio_origin_policy": bio_origin_policy,
		"research_bio_guild": bio_guild,
		"research_bio_habitat_class": bio_habitat_class,
		"research_bio_introduce_good_ids": bio_introduce_good_ids,
		"research_bio_introduce_occupancy_bits": bio_introduce_occupancy_bits,
	}

static func signal_index(compiled: Dictionary, id: StringName) -> int:
	return (compiled.get("research_signal_ids", PackedStringArray()) as PackedStringArray).find(String(id))

static func occupancy_bit_for_signal(compiled: Dictionary, id: StringName) -> int:
	var index := signal_index(compiled, id)
	var bits: PackedInt32Array = compiled.get("research_signal_occupancy_bit", PackedInt32Array())
	if index < 0 or index >= bits.size():
		return -1
	return int(bits[index])


static func overlay_icon_key(id: String) -> StringName:
	return OVERLAY_ICON_BY_ID.get(id, &"ecology.growth") as StringName


static func occupancy_overlay_entries() -> Array[Dictionary]:
	var compiled := compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return []
	var out: Array[Dictionary] = []
	var ids: PackedStringArray = compiled.get("research_signal_ids", PackedStringArray())
	var names: PackedStringArray = compiled.get("research_signal_display_names", PackedStringArray())
	var kinds: PackedInt32Array = compiled.get("research_signal_kinds", PackedInt32Array())
	var bits: PackedInt32Array = compiled.get("research_signal_occupancy_bit", PackedInt32Array())
	var bio_kind := ResearchSignalDefinitionScript.Kind.BIO
	for i in range(ids.size()):
		if i >= kinds.size() or int(kinds[i]) != bio_kind:
			continue
		var bit := int(bits[i]) if i < bits.size() else -1
		if bit < 0:
			continue
		out.append({
			"id": StringName(ids[i]),
			"display_name": String(names[i]) if i < names.size() else String(ids[i]),
			"occupancy_bit": bit,
			"icon_key": overlay_icon_key(String(ids[i])),
		})
	return out


static func occupancy_signal_indices(compiled: Dictionary, bits: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if bits == 0:
		return out
	var signal_ids: PackedInt32Array = compiled.get("research_bio_signal_ids", PackedInt32Array())
	var occupancy_bits: PackedInt32Array = compiled.get("research_bio_occupancy_bits", PackedInt32Array())
	for i in range(mini(signal_ids.size(), occupancy_bits.size())):
		var bit := int(occupancy_bits[i])
		if bit >= 0 and bit < 32 and (bits & (1 << bit)) != 0:
			out.append(int(signal_ids[i]))
	return out


static func public_metadata() -> Array[Dictionary]:
	var compiled := compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return []
	var out: Array[Dictionary] = []
	for index in range(compiled.research_signal_ids.size()):
		out.append({
			"id": String(compiled.research_signal_ids[index]),
			"display_name": String(compiled.research_signal_display_names[index]),
			"kind": int(compiled.research_signal_kinds[index]),
			"persistence": int(compiled.research_signal_persistence[index]),
		})
	return out
