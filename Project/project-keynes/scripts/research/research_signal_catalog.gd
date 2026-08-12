class_name ResearchSignalCatalog
extends RefCounted

const ResearchSignalDefinitionScript = preload("res://scripts/research/research_signal_definition.gd")

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
		ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.major_flood", "洪水经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT,
		ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.drought", "干旱经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT,
		ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
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

	["weather.monsoon", "季风经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.frost", "霜冻经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.freeze_thaw", "冻融经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.heatwave", "热浪经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.prolonged_wet_season", "连续湿季经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.storm_surge", "风暴潮经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.repeated_crop_failure", "连续歉收经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT, ResearchSignalDefinitionScript.Persistence.COUNTER, ["category.weather"], [], [], true],

	["contact.maize", "玉米样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.wheat", "小麦样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.rice", "稻种样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.potato", "块茎样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.cotton", "棉花样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.flax", "亚麻样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.spice", "香料样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.rubber", "橡胶样本接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],
	["contact.tin", "锡矿贸易接触", ResearchSignalDefinitionScript.Kind.CONTACT, ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.contact"], [], [], true],

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
]

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
	var seen := {}
	for row in SIGNAL_ROWS + NETWORK_SIGNAL_ROWS:
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
	}

static func signal_index(compiled: Dictionary, id: StringName) -> int:
	return (compiled.get("research_signal_ids", PackedStringArray()) as PackedStringArray).find(String(id))

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
