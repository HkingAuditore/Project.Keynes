class_name ResearchSignalCatalog
extends RefCounted

const ResearchSignalDefinitionScript = preload("res://scripts/research/research_signal_definition.gd")

## The content table remains deliberately small in v1. New signals are data rows;
## no C++ string lookup survives catalog compilation.
const SIGNAL_ROWS := [
	["bio.maize", "玉米", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.cereal"],
		["habitat.warm_crop", "habitat.open_grassland"], ["realm.neotropical"], true],
	["bio.wheat", "小麦", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.cereal"],
		["habitat.cool_season_crop", "habitat.open_grassland"], ["realm.western_eurasian"], true],
	["bio.potato", "马铃薯", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.tuber"],
		["habitat.cool_highland_crop"], ["realm.neotropical"], true],
	["bio.horse", "马匹", ResearchSignalDefinitionScript.Kind.BIO,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.grazer"],
		["habitat.grazer", "habitat.open_grassland"], ["realm.eurasian_steppe"], true],
	["resource.freshwater", "淡水", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.water"], [], [], false],
	["resource.copper_ore", "铜矿", ResearchSignalDefinitionScript.Kind.RESOURCE,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.metal"], [], [], false],
	["landform.river_valley", "河谷", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.river"], [], [], true],
	["landform.volcanic", "火山", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.volcanic"], [], [], true],
	["landform.high_plateau", "高原", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.highland"], [], [], true],
	["landform.coastal_estuary", "海岸河口", ResearchSignalDefinitionScript.Kind.LANDFORM,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.coastal"], [], [], true],
	["weather.typhoon", "台风经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT,
		ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.major_flood", "洪水经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT,
		ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["weather.drought", "干旱经验", ResearchSignalDefinitionScript.Kind.WEATHER_EVENT,
		ResearchSignalDefinitionScript.Persistence.TIME_WINDOW, ["category.weather"], [], [], true],
	["breakthrough.printing", "印刷突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], false],
	["breakthrough.steam_power", "蒸汽突破", ResearchSignalDefinitionScript.Kind.TECH_BREAKTHROUGH,
		ResearchSignalDefinitionScript.Persistence.PERMANENT, ["category.breakthrough"], [], [], false],
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
	for row in SIGNAL_ROWS:
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
