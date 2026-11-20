extends "res://tests/family/family_effect_worker_forward_test.gd"

func _run() -> void:
	var authored: Array[Resource] = []
	var definitions := PackedStringArray()
	for suffix in ["a", "b", "c"]:
		var effect := _pool_effect()
		effect.key = StringName("review_" + suffix)
		effect.source_kind = FamilyEffectDefinitionScript.SourceKind.TRAIT
		effect.random_pool_eligible = false
		effect.target_domain = FamilyEffectDefinitionScript.TargetDomain.BRANCH
		authored.append(effect)
		definitions.append(String(effect.key))
	var family_effects := FamilyEffectCatalogScript.new()
	family_effects.effects = authored
	var effect_catalog: Resource = EffectDomainCatalogScript.build(family_effects)
	_expect("native effect catalog compiles", effect_catalog != null)
	if effect_catalog == null:
		return
	var program: Dictionary = effect_catalog.compile_native_catalog()
	program.erase("ok")
	var first := _run_order(family_effects, program, definitions)
	definitions.reverse()
	var second := _run_order(family_effects, program, definitions)
	var first_bytes: PackedByteArray = first.get("effect", [])
	var second_bytes: PackedByteArray = second.get("effect", [])
	print("REVIEW_FAMILY_ORDER first=", first.get("keys"), " second=", second.get("keys"),
		" effect_equal=", first_bytes == second_bytes)
	_expect("permuted insertion produces identical exposed bindings and saved effects",
		first.get("keys", []) == second.get("keys", []) and not first_bytes.is_empty()
		and first_bytes == second_bytes)


func _run_order(family_effects: Resource, program: Dictionary, order: PackedStringArray) -> Dictionary:
	var trait_catalog := FamilyTraitCatalog.new()
	trait_catalog.core_trait_min = 1
	trait_catalog.core_trait_max = 1
	var trait_row := FamilyTraitDefinition.new()
	trait_row.key = &"review_order"
	trait_row.effect_keys = order
	trait_catalog.traits = [trait_row]
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog(family_effects, trait_catalog)
	_expect("economy catalog compiles", catalog.get("ok") == true)
	if not catalog.get("ok", false):
		print("REVIEW_FAMILY_CATALOG ", catalog.get("reason"))
		return {}
	catalog.erase("ok")
	var ext: Object = _new_ext(catalog, LandformTypeScript.LF.PLAIN)
	_expect("real fixture country bootstraps", _configure_country(ext, catalog, 210821))
	_expect("real family effect adapter is configured", ext.configure_effects(program).get("ok") == true)
	_expect("economy configures using permuted authored edges",
		ext.configure_economy(catalog, _active_profile(), 1, 210821).get("ok") == true)
	if not _bootstrap_opening(ext, catalog, "order"):
		return {}
	_expect("native opening economy settles", _run_day(ext, 0).get("done") == true)
	var page: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	if page.get("total") != 1:
		_fail("fixture must found a family")
		return {}
	var family := int(page.family_handles[0])
	var rows: Dictionary = ext.get_family_branch_effects(family, 0)
	var keys: PackedStringArray = rows.get("effect_definition_keys", [])
	_expect("fixture installs every pending effect", keys.size() == order.size())
	return {"keys": keys, "effect": ext.capture_effect_state()}
