extends SceneTree

const Catalog = preload("res://scripts/economy/economy_catalog.gd")
const BuildingPlacement = preload("res://scripts/economy/building_placement_catalog.gd")
const Policy = preload("res://scripts/economy/bootstrap/test_start_policy.gd")
var _checks := 0
var _failures := 0

func _init() -> void:
	var catalog: Dictionary = Catalog.compile_native_catalog()
	_expect("catalog compiles", catalog.get("ok", false))
	if not catalog.get("ok", false):
		quit(1)
		return
	for id in Policy.BUILDING_IDS:
		var spec: Dictionary = BuildingPlacement.query(catalog, StringName(id))
		_expect("diagnostic building projects: " + id, spec.get("ok", false))
		_expect("diagnostic building is actually unlocked: " + id, Policy.building_available(spec))
	var weaving: Dictionary = BuildingPlacement.query(catalog, &"household_weaving_shelter")
	_expect("projection preserves all support requirements",
		weaving.get("required_technology_tags", PackedStringArray()).has("tech.hand_spinning"))
	_expect("early merchant fits the diagnostic opening",
		Policy.building_available(BuildingPlacement.query(catalog, &"early_merchant_post")))
	_expect("later merchant is not silently granted",
		not Policy.building_available(BuildingPlacement.query(catalog, &"merchant_post")))
	var alternatives := {"technology_tags": PackedStringArray(["tech.future", "tech.gathering"]),
		"required_technology_tags": PackedStringArray(["tech.hand_spinning"])}
	_expect("one primary alternative and all support gates suffice", Policy.building_available(alternatives))
	alternatives.required_technology_tags.append("tech.future")
	_expect("a missing support gate rejects despite a primary match", not Policy.building_available(alternatives))
	alternatives.required_technology_tags = PackedStringArray(["unknown.support"])
	_expect("an unknown support gate also rejects", not Policy.building_available(alternatives))
	_expect("unknown building rejects", not BuildingPlacement.query(catalog, &"missing.building").get("ok", true))
	var invalid := catalog.duplicate(true)
	invalid.building_required_technology_tag_offsets = PackedInt32Array()
	_expect("missing support offsets reject", not BuildingPlacement.query(invalid, &"early_merchant_post").get("ok", true))
	invalid = catalog.duplicate(true)
	var index: int = catalog.building_type_ids.find("household_weaving_shelter")
	invalid.building_required_technology_tag_offsets[index + 1] = invalid.building_required_technology_tags.size() + 1
	_expect("out-of-range support requirements reject", not BuildingPlacement.query(invalid, &"household_weaving_shelter").get("ok", true))
	_expect("all catalog contract scenarios ran", _checks >= 30)
	print("bootstrap catalog contract: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _expect(label: String, success: bool) -> void:
	_checks += 1
	if not success:
		_failures += 1
		push_error("[FAIL] " + label)
