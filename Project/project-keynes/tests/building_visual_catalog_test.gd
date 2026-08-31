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
		_expect("all 395 authored building types resolve without id inference",
			bool(audit.get("ok", false)) and int(audit.get("type_count", 0)) == 395
			and (audit.unresolved_ids as PackedStringArray).is_empty())
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
