class_name NarrativeEventRegistry
extends RefCounted

## 内容包注册表：唯一决定"哪些包、按什么顺序"进入默认事件库。
##
## 新增一个包只需三处：
##   1. 上面加一行 preload；
##   2. `packs()` 里加一条 `XXXScript.meta()`；
##   3. `append_all()` 的 match 里加一条分支。
## 顺序即优先级（同权重时的抽样顺序），把"局势类"排在"风物类"前面。

const PackScript = preload("res://scripts/narrative/narrative_event_pack.gd")
const CourtScript = preload("res://scripts/narrative/narrative_event_catalog_court.gd")
const FaithScript = preload("res://scripts/narrative/narrative_event_catalog_faith.gd")
const FiscalScript = preload("res://scripts/narrative/narrative_event_catalog_fiscal.gd")
const LaborScript = preload("res://scripts/narrative/narrative_event_catalog_labor.gd")
const EraScript = preload("res://scripts/narrative/narrative_event_catalog_era.gd")
const FamilyScript = preload("res://scripts/narrative/narrative_event_catalog_family.gd")
const LandScript = preload("res://scripts/narrative/narrative_event_catalog_land.gd")
const FrontierScript = preload("res://scripts/narrative/narrative_event_catalog_frontier.gd")
const AgesScript = preload("res://scripts/narrative/narrative_event_catalog_ages.gd")
const WildsScript = preload("res://scripts/narrative/narrative_event_catalog_wilds.gd")
const TownScript = preload("res://scripts/narrative/narrative_event_catalog_town.gd")
const CityChainScript = preload("res://scripts/narrative/narrative_event_catalog_citychain.gd")
const AtomChainScript = preload("res://scripts/narrative/narrative_event_catalog_atomchain.gd")
const EnvoyScript = preload("res://scripts/narrative/narrative_event_catalog_envoy.gd")
const PlagueScript = preload("res://scripts/narrative/narrative_event_catalog_plague.gd")
const LawScript = preload("res://scripts/narrative/narrative_event_catalog_law.gd")
const DawnScript = preload("res://scripts/narrative/narrative_event_catalog_dawn.gd")
const SeaScript = preload("res://scripts/narrative/narrative_event_catalog_sea.gd")
const RailScript = preload("res://scripts/narrative/narrative_event_catalog_rail.gd")
const AtomScript = preload("res://scripts/narrative/narrative_event_catalog_atom.gd")
const SchoolScript = preload("res://scripts/narrative/narrative_event_catalog_school.gd")
const Family2Script = preload("res://scripts/narrative/narrative_event_catalog_family2.gd")
const Family3Script = preload("res://scripts/narrative/narrative_event_catalog_family3.gd")
const WarScript = preload("res://scripts/narrative/narrative_event_catalog_war.gd")
const TechScript = preload("res://scripts/narrative/narrative_event_catalog_tech.gd")


static func packs() -> Array:
	return [
		CourtScript.meta(),
		FrontierScript.meta(),
		FaithScript.meta(),
		FiscalScript.meta(),
		LaborScript.meta(),
		EraScript.meta(),
		FamilyScript.meta(),
		LandScript.meta(),
		WildsScript.meta(),
		TownScript.meta(),
		AgesScript.meta(),
		CityChainScript.meta(),
		AtomChainScript.meta(),
		EnvoyScript.meta(),
		PlagueScript.meta(),
		LawScript.meta(),
		DawnScript.meta(),
		SeaScript.meta(),
		RailScript.meta(),
		AtomScript.meta(),
		SchoolScript.meta(),
		Family2Script.meta(),
		Family3Script.meta(),
		WarScript.meta(),
		TechScript.meta(),
	]


static func append_all(catalog) -> void:
	if catalog == null:
		return
	for meta in packs():
		match String(meta.get("id", "")):
			"court":
				CourtScript.append(catalog)
			"frontier":
				FrontierScript.append(catalog)
			"faith":
				FaithScript.append(catalog)
			"fiscal":
				FiscalScript.append(catalog)
			"labor":
				LaborScript.append(catalog)
			"era":
				EraScript.append(catalog)
			"family":
				FamilyScript.append(catalog)
			"land":
				LandScript.append(catalog)
			"ages":
				AgesScript.append(catalog)
			"citychain":
				CityChainScript.append(catalog)
			"atomchain":
				AtomChainScript.append(catalog)
			"envoy":
				EnvoyScript.append(catalog)
			"plague":
				PlagueScript.append(catalog)
			"law":
				LawScript.append(catalog)
			"dawn":
				DawnScript.append(catalog)
			"sea":
				SeaScript.append(catalog)
			"rail":
				RailScript.append(catalog)
			"atom":
				AtomScript.append(catalog)
			"school":
				SchoolScript.append(catalog)
			"family2":
				Family2Script.append(catalog)
			"family3":
				Family3Script.append(catalog)
			"war":
				WarScript.append(catalog)
			"tech":
				TechScript.append(catalog)
			"wilds":
				WildsScript.append(catalog)
			"town":
				TownScript.append(catalog)
			_:
				push_warning("unknown narrative pack: %s" % String(meta.get("id", "")))


## 所有包声明的事件 id（按包顺序），供测试与文档使用。
static func all_node_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for meta in packs():
		for node in PackScript.node_ids(meta):
			if not out.has(node):
				out.append(node)
	return out
