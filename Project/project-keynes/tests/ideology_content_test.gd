extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyFacadeScript = preload("res://scripts/economy/economy_facade.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const WorkspaceScene = preload("res://scenes/ui/ideology_workspace.tscn")

var _checks := 0
var _failures := 0


func _init() -> void:
	var economy_facade := EconomyFacadeScript.new()
	_expect("economy facade exposes its compiled catalog",
		economy_facade.has_method("native_catalog"))
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles for ideology classes",
		bool(economy_ir.get("ok", false)))
	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	_expect("default ideology catalog loads", ideology_catalog != null)
	if ideology_catalog != null and bool(economy_ir.get("ok", false)):
		var ideology_ir: Dictionary = ideology_catalog.compile_native_catalog(
			economy_ir, economy_ir)
		_expect("default ideology catalog compiles",
			bool(ideology_ir.get("ok", false)))
		if bool(ideology_ir.get("ok", false)):
			_expect("minimum playable ideology set exists",
				(ideology_ir.ideology_ids as PackedStringArray).size() >= 4)
			_expect("directional stances compile to sparse rows",
				(ideology_ir.stance_class_indices as PackedInt32Array).size() >= 8)
			_expect("exclusive ideology pair is compiled",
				_count_nonnegative(ideology_ir.exclusion_group_ids) >= 2)
			_expect("two synergies and reverse CSR are compiled",
				(ideology_ir.synergy_ids as PackedStringArray).size() >= 2
				and (ideology_ir.ideology_synergy_ids as PackedInt32Array).size() >= 4)
			_expect("two-level persistent effects are authored",
				(ideology_ir.persistent_actions as PackedInt32Array).size() >= 8)
	var effect_catalog: Resource = EffectDomainCatalogScript.build()
	_expect("shared Effect catalog includes ideology templates",
		effect_catalog != null)
	if effect_catalog != null:
		_expect("shared Effect IR compiles",
			bool(effect_catalog.compile_native_catalog().get("ok", false)))
	var workspace := WorkspaceScene.instantiate()
	root.add_child(workspace)
	workspace.set_model({"country_handle": 0, "current_day": 0,
		"ideology": {"available": false, "reason": "smoke"}})
	_expect("ideology workspace scene instantiates", workspace != null
		and workspace.has_method("set_player_controller"))
	workspace.queue_free()
	print("ideology content: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _count_nonnegative(values: PackedInt32Array) -> int:
	var count := 0
	for value in values:
		if value >= 0:
			count += 1
	return count


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
