@tool
class_name BuildingVisualFamilyTable
extends Resource

## Presentation-only mapping from authored building types to the visual
## families drawn by the native settlement planner. Never part of a catalog
## hash or any simulation rule.

const DEFAULT_PATH := "res://data/rendering/building_visual_families.tres"

## Ordered exactly like the Family enum in gdext/src/world_ext_building_visual.cpp.
## Each entry: {id, archetype, sectors, kinds, climate_profiles, resources, keywords}.
## Resolution order: `visual.family.<id>` tag, sector/kind, production climate
## profile, production resource, then keywords (substrings of the type id,
## industry chain and output goods) in table order.
@export var families: Array[Dictionary] = []
## Construction good id -> build grade (0 primitive, 1 classical, 2 industrial,
## 3 steel frame). A type's grade is the highest grade among its goods.
@export var grade_goods: Dictionary = {}

static var _default: Resource = null


static func load_default() -> Resource:
	if _default == null:
		_default = load(DEFAULT_PATH)
	return _default


func family_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for entry in families:
		out.append(String(entry.get("id", "")))
	return out


func archetype_of(family: int) -> int:
	if family < 0 or family >= families.size():
		return -1
	return int(families[family].get("archetype", -1))


## Returns {family, source}; source is "tag", "sector", "climate", "resource",
## "keyword" or "" when nothing matched.
func resolve(type_id: String, sector: String, kind: int, tags: PackedStringArray,
		climate_profile: String, resources: PackedStringArray, chain_id: String,
		outputs: PackedStringArray) -> Dictionary:
	var ids := family_ids()
	for tag in tags:
		if String(tag).begins_with("visual.family."):
			var tagged := ids.find(String(tag).trim_prefix("visual.family."))
			if tagged >= 0:
				return {"family": tagged, "source": "tag"}
	for i in families.size():
		var entry: Dictionary = families[i]
		if PackedInt32Array(entry.get("kinds", PackedInt32Array())).has(kind) \
				or PackedStringArray(entry.get("sectors", PackedStringArray())).has(sector):
			return {"family": i, "source": "sector"}
	if climate_profile != "":
		for i in families.size():
			if PackedStringArray(families[i].get("climate_profiles", PackedStringArray())) \
					.has(climate_profile):
				return {"family": i, "source": "climate"}
	for resource in resources:
		for i in families.size():
			if PackedStringArray(families[i].get("resources", PackedStringArray())) \
					.has(String(resource)):
				return {"family": i, "source": "resource"}
	var key := " ".join(PackedStringArray([type_id, chain_id, " ".join(outputs)]))
	for i in families.size():
		for keyword in PackedStringArray(families[i].get("keywords", PackedStringArray())):
			if key.contains(String(keyword)):
				return {"family": i, "source": "keyword"}
	return {"family": -1, "source": ""}


func grade_for(construction_goods: PackedStringArray) -> int:
	var grade := 0
	for good in construction_goods:
		grade = maxi(grade, int(grade_goods.get(String(good), 0)))
	return grade
