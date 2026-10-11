extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const BuildingVisualLayerScript = preload(
	"res://scripts/rendering/building_visual_layer.gd")

var _failures := 0


func _init() -> void:
	var economy := EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles", bool(economy.get("ok", false)))
	if bool(economy.get("ok", false)):
		var layer: BuildingVisualLayer = BuildingVisualLayerScript.new()
		var audit := layer.configure_catalog(economy)
		var authored := (economy.building_type_ids as PackedStringArray).size()
		_expect("all %d authored building types resolve without id inference" % authored,
			bool(audit.get("ok", false)) and authored > 0
			and int(audit.get("type_count", 0)) == authored
			and (audit.unresolved_ids as PackedStringArray).is_empty())
		var sources: Dictionary = audit.get("family_sources", {})
		print("  family sources: %s" % sources)
		_expect("every authored type matches an explicit family rule (no fallback)",
			int(sources.get("fallback", 0)) == 0)
		var family_counts := PackedInt32Array(audit.get("family_counts", PackedInt32Array()))
		var all_used := family_counts.size() == layer.FAMILY_NAMES.size()
		for family in family_counts.size():
			all_used = all_used and family_counts[family] > 0
		_expect("every visual family draws at least one authored type", all_used)
		var ids := economy.building_type_ids as PackedStringArray
		var spot := {
			"tenant_paddy": "paddy", "wheat_farm": "field", "spice_shade_garden": "plantation",
			"pastoral_camp": "pasture", "wool_shed": "pasture", "gathering_ground": "forage",
			"marine_fish_collector": "fishery", "coal_mine": "mine", "stone_collector": "quarry",
			"timber_collector": "forestry", "lumber_plant": "forestry", "salt_collector": "saltworks",
			"brine_boiling_hearth": "saltworks", "oil_collector": "wells",
			"tannery": "workshop", "bakery": "food", "textile_mill": "textile",
			"household_loom": "textile", "bloomery": "metallurgy", "steel_plant": "metallurgy",
			"fired_brick_kiln": "kiln", "open_pottery_hearth": "kiln", "soap_plant": "chemical",
			"steam_engine_works": "machinery", "computers_plant": "electronics",
			"nuclear_power_plant": "energy", "classical_academy": "knowledge",
			"merchant_post": "service",
		}
		var spot_ok := true
		for type_id in spot:
			var index := ids.find(type_id)
			var got: String = layer.FAMILY_NAMES[layer._type_to_family[index]] \
				if index >= 0 else "<missing>"
			if got != spot[type_id]:
				spot_ok = false
				print("    %s -> %s (want %s)" % [type_id, got, spot[type_id]])
		_expect("family spot checks", spot_ok)
		var textile := ids.find("textile_mill")
		var paddy := ids.find("tenant_paddy")
		var computers := ids.find("computers_plant")
		_expect("workforce drives scale and construction drives grade",
			layer._type_to_scale[textile] > layer._type_to_scale[paddy]
			and layer._type_to_grade[paddy] == 0
			and layer._type_to_grade[textile] > layer._type_to_grade[paddy]
			and layer._type_to_grade[computers] > layer._type_to_grade[textile])
		layer.free()
	var technology := TechnologyCatalogScript.compile_native_catalog()
	_expect("technology catalog compiles", bool(technology.get("ok", false)))
	if bool(technology.get("ok", false)):
		var eras: PackedStringArray = technology.technology_era_ids_ordered
		var milestones: PackedInt32Array = technology.technology_era_milestone_indices
		_expect("visual era source has exactly 11 authoritative ordered eras",
			eras.size() == 11 and milestones.size() == 11)
		var ids: PackedStringArray = technology.technology_ids
		var valid := true
		for milestone in milestones:
			valid = valid and milestone >= 0 and milestone < ids.size()
		_expect("every visual era is backed by a catalog milestone", valid)
	print("building visual catalog: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1
		push_error(label)
