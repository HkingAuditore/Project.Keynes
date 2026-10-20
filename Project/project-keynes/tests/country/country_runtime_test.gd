extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _checks := 0
var _failures := 0

func _init() -> void:
	_run()
	print("country runtime: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var technologies: PackedStringArray = compiled.technology_ids
	var goods: PackedStringArray = compiled.good_ids
	var grain := goods.find("grain")
	var hunting := technologies.find("tech.hunting")
	var autonomous_systems := technologies.find("tech.autonomous_systems")
	var profile := {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"])}
	var default_ext := _new_ext(3)
	_expect("default country configures", bool(default_ext.configure_country(catalog, profile, 3, 7).get("ok", false)))
	_expect("default country owns every land cell",
		bool(default_ext.bootstrap_country({}, PackedByteArray([0, 1, 0])).get("ok", false)) and
		String(default_ext.get_country_cell_summary(0).country_id) == "country.default" and
		int(default_ext.get_country_cell_summary(1).country_slot) == -1 and
		String(default_ext.get_country_cell_summary(2).country_id) == "country.default")
	var water_ext := _new_ext(2)
	water_ext.configure_country(catalog, profile, 2, 8)
	_expect("all-water default bootstrap is rejected precisely",
		String(water_ext.bootstrap_country({}, PackedByteArray([1, 1])).get("reason", "")) ==
		"country_bootstrap_no_land")
	var water := PackedByteArray([0, 0, 0, 1])
	var packet := {
		"country_ids": PackedStringArray(["country.alpha"]),
		"country_names": PackedStringArray(["阿尔法"]),
		"country_cash": PackedInt64Array([100000]),
		"territory_offsets": PackedInt32Array([0, 2]),
		"territory_cells": PackedInt32Array([0, 1]),
		"technology_offsets": PackedInt32Array([0, 1]),
		"technology_indices": PackedInt32Array([hunting]),
		"treasury_offsets": PackedInt32Array([0, 1]),
		"treasury_good_indices": PackedInt32Array([grain]),
		"treasury_quantities": PackedInt64Array([5000]),
	}
	var duplicate_packet := packet.duplicate(true)
	duplicate_packet.country_ids = PackedStringArray(["country.alpha", "country.beta"])
	duplicate_packet.country_names = PackedStringArray(["Alpha", "Beta"])
	duplicate_packet.country_cash = PackedInt64Array([0, 0])
	duplicate_packet.territory_offsets = PackedInt32Array([0, 1, 2])
	duplicate_packet.territory_cells = PackedInt32Array([0, 0])
	duplicate_packet.technology_offsets = PackedInt32Array([0, 0, 0])
	duplicate_packet.technology_indices = PackedInt32Array()
	duplicate_packet.treasury_offsets = PackedInt32Array([0, 0, 0])
	duplicate_packet.treasury_good_indices = PackedInt32Array()
	duplicate_packet.treasury_quantities = PackedInt64Array()
	var duplicate_ext := _new_ext(4)
	duplicate_ext.configure_country(catalog, profile, 4, 99)
	_expect("duplicate territory bootstrap is rejected precisely",
		String(duplicate_ext.bootstrap_country(duplicate_packet, water).get("reason", "")) ==
		"country_bootstrap_duplicate_territory")
	var water_packet := packet.duplicate(true)
	water_packet.territory_cells = PackedInt32Array([0, 3])
	var owned_water_ext := _new_ext(4)
	owned_water_ext.configure_country(catalog, profile, 4, 99)
	_expect("water territory bootstrap is rejected precisely",
		String(owned_water_ext.bootstrap_country(water_packet, water).get("reason", "")) ==
		"country_bootstrap_water_owned")
	var ext := _new_ext(4)
	_expect("country configures", bool(ext.configure_country(catalog, profile, 4, 99).get("ok", false)))
	_expect("explicit country bootstraps", bool(ext.bootstrap_country(packet, water).get("ok", false)))
	var alpha: Dictionary = ext.get_country_cell_summary(0)
	_expect("single owner and neutral land are represented",
		String(alpha.country_id) == "country.alpha" and
		int(ext.get_country_cell_summary(2).country_slot) == -1 and
		int(ext.get_country_cell_summary(3).country_slot) == -1)
	_expect("unowned land displays as 无主之地",
		String(ext.get_country_cell_summary(2).country_name) == "无主之地" and
		String(ext.get_country_cell_summary(3).country_name) == "无主之地")
	_expect("country treasury is sparse and scaled",
		int(ext.get_country_treasury_snapshot(alpha.country_handle).quantities[0]) == 5000)
	var ui_snapshot: Dictionary = ext.get_country_ui_snapshot(
		alpha.country_handle, 1)
	_expect("country UI bridge returns compact revisioned technology section",
		bool(ui_snapshot.get("ok", false))
		and int(ui_snapshot.get("section", 0)) == 1
		and not (ui_snapshot.summary as Dictionary).has("territory_cells")
		and not (ui_snapshot.summary as Dictionary).has("technology_ids")
		and (ui_snapshot.get("revision_components", {}) as Dictionary).has(
			"country_state_version")
		and ui_snapshot.has("research")
		and ui_snapshot.has("research_signals"))
	var oral := technologies.find("tech.oral_memory_practice")
	var points := goods.find("technology_points")
	var discover_ext := _new_ext(4)
	discover_ext.configure_country(catalog, profile, 4, 99)
	var discover_packet := packet.duplicate(true)
	discover_packet["discovered_technology_offsets"] = PackedInt32Array([0, 1])
	discover_packet["discovered_technology_indices"] = PackedInt32Array([oral])
	discover_packet["treasury_offsets"] = PackedInt32Array([0, 1])
	discover_packet["treasury_good_indices"] = PackedInt32Array([points])
	discover_packet["treasury_quantities"] = PackedInt64Array([10000000])
	_expect("discovered-but-not-completed bootstrap succeeds",
		oral >= 0 and points >= 0
		and bool(discover_ext.bootstrap_country(discover_packet, water).get("ok", false)))
	var discover_country: Dictionary = discover_ext.get_country_cell_summary(0)
	var discover_research: Dictionary = discover_ext.get_country_research_snapshot(
		discover_country.country_handle)
	_expect("bootstrap can reveal a knowledge practice while its institution prerequisite is incomplete",
		int(discover_research.technology_states[oral]) == 1
		and not (discover_ext.get_country_snapshot(discover_country.country_handle)
			.technology_ids as PackedStringArray).has("tech.oral_memory_practice")
		and int(discover_research.technology_points_stock) == 10000000)
	var claim_ext := _new_ext(4)
	claim_ext.configure_country(catalog, profile, 4, 1001)
	claim_ext.bootstrap_country(packet, water)
	var claim_country: Dictionary = claim_ext.get_country_cell_summary(0)
	var claim_unowned := _commands([{
		"opcode": 20, "day": 0, "sequence": 90, "handle": claim_country.country_handle,
		"cell": 2, "aux": -1, "stable_id": "", "name": "",
	}])
	_expect("CLAIM_UNOWNED_TERRITORY queues through the country authority",
		bool(claim_ext.submit_country_commands(claim_unowned).get("ok", false)))
	_expect("claim commits only the neutral target",
		bool(claim_ext.run_country_slice({"day_index": 0}).get("ok", false))
		and int(claim_ext.get_country_cell_summary(2).country_handle) ==
			int(claim_country.country_handle))

	var create := _commands([{
		"opcode": 1, "day": 0, "sequence": 1, "handle": 0,
		"cell": 1, "aux": -1, "stable_id": "country.beta", "name": "贝塔",
	}])
	_expect("create command queues", bool(ext.submit_country_commands(create).get("ok", false)))
	var create_report: Dictionary = ext.run_country_slice({"day_index": 0})
	_expect("create atomically transfers first territory",
		bool(create_report.get("ok", false)) and int(create_report.changed_cells) == 1)
	var beta: Dictionary = ext.get_country_cell_summary(1)
	_expect("new country inherits source technology",
		(ext.get_country_snapshot(beta.country_handle).technology_ids as PackedStringArray).has("tech.hunting"))

	var last_land := _commands([{
		"opcode": 3, "day": 1, "sequence": 1, "handle": 0,
		"cell": 0, "aux": -1, "stable_id": "", "name": "",
	}])
	ext.submit_country_commands(last_land)
	var rejected: Dictionary = ext.run_country_slice({"day_index": 1})
	_expect("last territory is protected", not bool(rejected.get("ok", true)) and
		String(rejected.get("fatal_reason", "")) == "country_last_territory_protected")

	var rename_and_tech := _commands([
		{"opcode": 2, "day": 2, "sequence": 1, "handle": beta.country_handle,
			"cell": -1, "aux": -1, "stable_id": "", "name": "贝塔共和国"},
		{"opcode": 4, "day": 2, "sequence": 2, "handle": beta.country_handle,
			"cell": -1, "aux": autonomous_systems, "stable_id": "", "name": ""},
	])
	ext.submit_country_commands(rename_and_tech)
	_expect("rename and country technology commit", bool(ext.run_country_slice({"day_index": 2}).get("ok", false)))
	var beta_after: Dictionary = ext.get_country_snapshot(beta.country_handle)
	var beta_research: Dictionary = ext.get_country_research_snapshot(beta.country_handle)
	_expect("country-wide metadata query reflects ACK-gated commit",
		String(beta_after.country_name) == "贝塔共和国" and
		int((beta_research.technology_states as PackedInt32Array)[autonomous_systems]) == 4)
	var artisan := (compiled.profession_ids as PackedStringArray).find("artisan")
	var tax_commands := _commands([
		{"opcode": 11, "day": 3, "sequence": 1, "handle": beta.country_handle,
			"cell": -1, "aux": -1, "stable_id": "", "name": "",
			"tax_kind": 0, "tax_rate": 10},
		{"opcode": 12, "day": 3, "sequence": 2, "handle": beta.country_handle,
			"cell": -1, "aux": -1, "stable_id": "", "name": "",
			"tax_kind": 0, "tax_item": artisan, "tax_rate": -25},
		{"opcode": 11, "day": 3, "sequence": 3, "handle": beta.country_handle,
			"cell": -1, "aux": -1, "stable_id": "", "name": "",
			"tax_kind": 3, "tax_rate": 20},
	])
	_expect("tax defaults and sparse override queue",
		bool(ext.submit_country_commands(tax_commands).get("ok", false)))
	_expect("tax policy commits at country day boundary",
		bool(ext.run_country_slice({"day_index": 3}).get("ok", false)))
	var tax_policy: Dictionary = ext.get_country_tax_policy_snapshot(beta.country_handle)
	_expect("income profession override and tariff placeholder resolve",
		int(tax_policy.default_rates[0]) == 10 and
		int(tax_policy.income.rates[artisan]) == -25 and
		int(tax_policy.income.has_override[artisan]) == 1 and
		int(tax_policy.default_rates[3]) == 20 and
		not bool(tax_policy.tariffs_active))
	var clear_tax := _commands([{
		"opcode": 13, "day": 4, "sequence": 1, "handle": beta.country_handle,
		"cell": -1, "aux": -1, "stable_id": "", "name": "",
		"tax_kind": 0, "tax_item": artisan,
	}])
	ext.submit_country_commands(clear_tax)
	ext.run_country_slice({"day_index": 4})
	tax_policy = ext.get_country_tax_policy_snapshot(beta.country_handle)
	_expect("cleared override inherits current default",
		int(tax_policy.income.rates[artisan]) == 10 and
		int(tax_policy.income.has_override[artisan]) == 0)
	var absolute_tax := _commands([{
		"opcode": 11, "day": 5, "sequence": 1, "handle": beta.country_handle,
		"cell": -1, "aux": -1, "stable_id": "", "name": "",
		"tax_kind": 0, "tax_rate_bp": 2500, "tax_mode": 1,
	}, {
		"opcode": 12, "day": 5, "sequence": 2, "handle": beta.country_handle,
		"cell": -1, "aux": -1, "stable_id": "", "name": "",
		"tax_kind": 0, "tax_item": artisan, "tax_rate_bp": -100,
		"tax_mode": 1,
	}])
	_expect("absolute tax defaults and overrides queue",
		bool(ext.submit_country_commands(absolute_tax).get("ok", false)))
	_expect("absolute tax policy commits",
		bool(ext.run_country_slice({"day_index": 5}).get("ok", false)))
	tax_policy = ext.get_country_tax_policy_snapshot(beta.country_handle)
	_expect("absolute assessment modes round-trip",
		int(tax_policy.default_assessment_modes[0]) == 1 and
		int(tax_policy.income.assessment_modes[artisan]) == 1 and
		int(tax_policy.income.absolute_amounts[artisan]) == -100 and
		int(tax_policy.income.has_override[artisan]) == 1)
	var tax_matrix_ext := _new_ext(4)
	tax_matrix_ext.configure_country(catalog, profile, 4, 100)
	tax_matrix_ext.bootstrap_country(packet, water)
	var tax_matrix_handle := int(
		tax_matrix_ext.get_country_cell_summary(0).country_handle)
	var building_item := 0
	var tax_items := [artisan, grain, building_item, grain, grain]
	var tax_defaults := [-100, -50, 0, 50, 100]
	var tax_overrides := [100, 50, 0, -50, -100]
	var tax_rows: Array[Dictionary] = []
	for kind in range(5):
		tax_rows.append({
			"opcode": 11, "day": 0, "sequence": kind * 2 + 1,
			"handle": tax_matrix_handle, "cell": -1, "aux": -1,
			"stable_id": "", "name": "", "tax_kind": kind,
			"tax_rate": tax_defaults[kind],
		})
		tax_rows.append({
			"opcode": 12, "day": 0, "sequence": kind * 2 + 2,
			"handle": tax_matrix_handle, "cell": -1, "aux": -1,
			"stable_id": "", "name": "", "tax_kind": kind,
			"tax_item": tax_items[kind], "tax_rate": tax_overrides[kind],
		})
	_expect("all five tax defaults and overrides queue",
		bool(tax_matrix_ext.submit_country_commands(
			_commands(tax_rows)).get("ok", false)))
	_expect("all five tax defaults and overrides commit",
		bool(tax_matrix_ext.run_country_slice(
			{"day_index": 0}).get("ok", false)))
	var matrix_policy: Dictionary = tax_matrix_ext.get_country_tax_policy_snapshot(
		tax_matrix_handle)
	var matrix_groups := ["income", "consumption", "business", "import", "export"]
	var matrix_valid := int(matrix_policy.get("catalog_hash", 0)) != 0
	for kind in range(5):
		var group: Dictionary = matrix_policy[matrix_groups[kind]]
		matrix_valid = matrix_valid and \
			int(matrix_policy.default_rates[kind]) == tax_defaults[kind] and \
			int(group.rates[tax_items[kind]]) == tax_overrides[kind] and \
			int(group.effective_rates[tax_items[kind]]) == tax_overrides[kind] and \
			int(group.has_override[tax_items[kind]]) == 1
	_expect("five tax kinds route to profession/good/building lanes", matrix_valid)
	var clear_rows: Array[Dictionary] = []
	for kind in range(5):
		clear_rows.append({
			"opcode": 13, "day": 1, "sequence": kind + 1,
			"handle": tax_matrix_handle, "cell": -1, "aux": -1,
			"stable_id": "", "name": "", "tax_kind": kind,
			"tax_item": tax_items[kind],
		})
	tax_matrix_ext.submit_country_commands(_commands(clear_rows))
	tax_matrix_ext.run_country_slice({"day_index": 1})
	matrix_policy = tax_matrix_ext.get_country_tax_policy_snapshot(tax_matrix_handle)
	var inheritance_valid := true
	for kind in range(5):
		var group: Dictionary = matrix_policy[matrix_groups[kind]]
		inheritance_valid = inheritance_valid and \
			int(group.rates[tax_items[kind]]) == tax_defaults[kind] and \
			int(group.has_override[tax_items[kind]]) == 0
	_expect("all five cleared overrides inherit current defaults",
		inheritance_valid)
	var invalid_rate := _commands([{
		"opcode": 11, "day": 2, "sequence": 1,
		"handle": tax_matrix_handle, "cell": -1, "aux": -1,
		"stable_id": "", "name": "", "tax_kind": 0, "tax_rate_bp": 10001,
	}])
	var invalid_item := _commands([{
		"opcode": 12, "day": 2, "sequence": 2,
		"handle": tax_matrix_handle, "cell": -1, "aux": -1,
		"stable_id": "", "name": "", "tax_kind": 2,
		"tax_item": -1, "tax_rate": 10,
	}])
	_expect("illegal tax rates and dense ids reject at command boundary",
		String(tax_matrix_ext.submit_country_commands(invalid_rate).get(
			"reason", "")) == "country_tax_command_invalid" and
		String(tax_matrix_ext.submit_country_commands(invalid_item).get(
			"reason", "")) == "country_tax_command_invalid")
	var farmer := (compiled.profession_ids as PackedStringArray).find("farmer")
	if farmer < 0 or farmer == artisan:
		farmer = 0 if artisan != 0 else 1
	var cell_policy_rows: Array[Dictionary] = [
		{"opcode": 11, "day": 2, "sequence": 10, "handle": tax_matrix_handle,
			"cell": -1, "aux": -1, "stable_id": "", "name": "",
			"tax_kind": 0, "tax_rate": 10},
		{"opcode": 12, "day": 2, "sequence": 11, "handle": tax_matrix_handle,
			"cell": -1, "aux": -1, "stable_id": "artisan", "name": "",
			"tax_kind": 0, "tax_item": artisan, "tax_rate": 15},
		{"opcode": 15, "day": 2, "sequence": 12, "handle": tax_matrix_handle,
			"cell": 0, "aux": -1, "stable_id": "", "name": "",
			"tax_kind": 0, "tax_rate": 20},
		{"opcode": 17, "day": 2, "sequence": 13, "handle": tax_matrix_handle,
			"cell": 0, "aux": -1, "stable_id": "artisan", "name": "",
			"tax_kind": 0, "tax_item": artisan, "tax_rate": 25},
	]
	_expect("cell defaults and item overrides queue",
		bool(tax_matrix_ext.submit_country_commands(
			_commands(cell_policy_rows)).get("ok", false)))
	_expect("cell tax policy commits atomically",
		bool(tax_matrix_ext.run_country_slice({"day_index": 2}).get("ok", false)))
	var cell0_policy: Dictionary = tax_matrix_ext.get_country_cell_tax_policy_snapshot(0)
	var cell1_policy: Dictionary = tax_matrix_ext.get_country_cell_tax_policy_snapshot(1)
	_expect("four-level inheritance resolves cell item and cell default first",
		int(cell0_policy.income.final_base_rates[artisan]) == 25 and
		int(cell0_policy.income.final_base_rates[farmer]) == 20 and
		String(cell0_policy.income.source_scopes[artisan]) == "cell_item" and
		String(cell0_policy.income.source_scopes[farmer]) == "cell_default")
	_expect("cells without local policy resolve national item then national default",
		int(cell1_policy.income.final_base_rates[artisan]) == 15 and
		int(cell1_policy.income.final_base_rates[farmer]) == 10 and
		String(cell1_policy.income.source_scopes[artisan]) == "country_item" and
		String(cell1_policy.income.source_scopes[farmer]) == "country_default")
	var explicit_same := _commands([{
		"opcode": 17, "day": 3, "sequence": 1, "handle": tax_matrix_handle,
		"cell": 1, "aux": -1, "stable_id": "artisan", "name": "",
		"tax_kind": 0, "tax_item": artisan, "tax_rate": 15,
	}])
	tax_matrix_ext.submit_country_commands(explicit_same)
	tax_matrix_ext.run_country_slice({"day_index": 3})
	cell1_policy = tax_matrix_ext.get_country_cell_tax_policy_snapshot(1)
	_expect("explicit local value equal to parent remains explicit",
		int(cell1_policy.income.has_local_item[artisan]) == 1 and
		String(cell1_policy.income.source_scopes[artisan]) == "cell_item")
	var clear_local := _commands([{
		"opcode": 18, "day": 4, "sequence": 1, "handle": tax_matrix_handle,
		"cell": 1, "aux": -1, "stable_id": "artisan", "name": "",
		"tax_kind": 0, "tax_item": artisan,
	}])
	tax_matrix_ext.submit_country_commands(clear_local)
	tax_matrix_ext.run_country_slice({"day_index": 4})
	cell1_policy = tax_matrix_ext.get_country_cell_tax_policy_snapshot(1)
	_expect("clearing local item restores national item inheritance",
		int(cell1_policy.income.has_local_item[artisan]) == 0 and
		String(cell1_policy.income.source_scopes[artisan]) == "country_item")
	var hash_before_invalid_cell_batch := int(tax_matrix_ext.get_country_state_hash())
	var invalid_cell_batch := _commands([
		{"opcode": 15, "day": 5, "sequence": 1, "handle": tax_matrix_handle,
			"cell": 0, "aux": -1, "stable_id": "", "name": "",
			"tax_kind": 1, "tax_rate": -100},
		{"opcode": 15, "day": 5, "sequence": 2, "handle": tax_matrix_handle,
			"cell": 2, "aux": -1, "stable_id": "", "name": "",
			"tax_kind": 1, "tax_rate": 100},
	])
	tax_matrix_ext.submit_country_commands(invalid_cell_batch)
	var invalid_cell_result: Dictionary = tax_matrix_ext.run_country_slice({"day_index": 5})
	_expect("mixed valid and invalid cell tax commands reject atomically",
		not bool(invalid_cell_result.get("ok", true)) and
		int(tax_matrix_ext.get_country_state_hash()) == hash_before_invalid_cell_batch)
	var shared_rows := _commands([
		{"opcode": 19, "day": 6, "sequence": 1, "handle": tax_matrix_handle,
			"cell": 0, "aux": -1, "stable_id": "", "name": ""},
		{"opcode": 19, "day": 6, "sequence": 2, "handle": tax_matrix_handle,
			"cell": 1, "aux": -1, "stable_id": "", "name": ""},
		{"opcode": 15, "day": 6, "sequence": 3, "handle": tax_matrix_handle,
			"cell": 0, "aux": -1, "stable_id": "", "name": "",
			"tax_kind": 1, "tax_rate": -100},
		{"opcode": 15, "day": 6, "sequence": 4, "handle": tax_matrix_handle,
			"cell": 1, "aux": -1, "stable_id": "", "name": "",
			"tax_kind": 1, "tax_rate": -100},
	])
	tax_matrix_ext.submit_country_commands(shared_rows)
	tax_matrix_ext.run_country_slice({"day_index": 6})
	_expect("identical cell policies are interned and diagnostics expose sharing",
		int(tax_matrix_ext.get_country_report().get(
			"cell_tax_shared_policy_count", 0)) >= 1)
	var create_cell_owner := _commands([{
		"opcode": 1, "day": 7, "sequence": 1, "handle": 0,
		"cell": 2, "aux": -1, "stable_id": "country.cell.beta",
		"name": "Cell Beta",
	}])
	tax_matrix_ext.submit_country_commands(create_cell_owner)
	tax_matrix_ext.run_country_slice({"day_index": 7})
	var cell_beta: Dictionary = tax_matrix_ext.get_country_cell_summary(2)
	var transfer_local_cell := _commands([{
		"opcode": 3, "day": 8, "sequence": 1,
		"handle": int(cell_beta.country_handle), "cell": 0, "aux": -1,
		"stable_id": "", "name": "",
	}])
	tax_matrix_ext.submit_country_commands(transfer_local_cell)
	tax_matrix_ext.run_country_slice({"day_index": 8})
	cell0_policy = tax_matrix_ext.get_country_cell_tax_policy_snapshot(0)
	_expect("territory transfer clears the old owner's local tax policy",
		int(cell0_policy.country_handle) == int(cell_beta.country_handle) and
		int(cell0_policy.has_local_default[1]) == 0 and
		String(cell0_policy.consumption.source_scopes[grain]) == "country_default")
	var cell_save_begin: Dictionary = tax_matrix_ext.begin_country_save(4096)
	var cell_save_chunks: Array[PackedByteArray] = []
	while bool(cell_save_begin.get("ok", false)):
		var cell_chunk: PackedByteArray = tax_matrix_ext.read_country_save_chunk(4096)
		if cell_chunk.is_empty():
			break
		cell_save_chunks.append(cell_chunk)
	tax_matrix_ext.end_country_save()
	var cell_restored := _new_ext(4)
	cell_restored.configure_country(catalog, profile, 4, 100)
	cell_restored.bootstrap_country(packet, water)
	cell_restored.begin_country_restore()
	for cell_chunk in cell_save_chunks:
		cell_restored.feed_country_restore_chunk(cell_chunk)
	var cell_restore_result: Dictionary = cell_restored.end_country_restore()
	_expect("PKCN sparse cell policies round-trip with exact replay hash",
		bool(cell_restore_result.get("ok", false)) and
		int(cell_restored.get_country_state_hash()) ==
			int(tax_matrix_ext.get_country_state_hash()) and
		int(cell_restored.get_country_cell_tax_policy_snapshot(1).
			has_local_default[1]) == 1)
	var river_valley := (compiled.research_signal_ids as PackedStringArray).find(
		"landform.river_valley")
	var signal_commands := _commands([
		{"opcode": 14, "day": 5, "sequence": 1, "handle": beta.country_handle,
			"cell": 0, "aux": river_valley, "value": 1, "stable_id": "", "name": ""},
		{"opcode": 14, "day": 5, "sequence": 2, "handle": beta.country_handle,
			"cell": 0, "aux": river_valley, "value": 1, "stable_id": "", "name": ""},
		{"opcode": 14, "day": 5, "sequence": 3, "handle": beta.country_handle,
			"cell": 1, "aux": river_valley, "value": 1, "stable_id": "", "name": ""},
	])
	_expect("research signal commands queue", river_valley >= 0 and
		bool(ext.submit_country_commands(signal_commands).get("ok", false)))
	_expect("research signal discovery commits once per cell",
		bool(ext.run_country_slice({"day_index": 5}).get("ok", false)))
	var signal_snapshot: Dictionary = ext.get_country_research_signal_snapshot(beta.country_handle)
	_expect("research signal evidence keeps distinct count and provenance",
		signal_snapshot.signal_ids.size() == 1 and
		int(signal_snapshot.signal_ids[0]) == river_valley and
		int(signal_snapshot.counts[0]) == 2 and
		int(signal_snapshot.first_cells[0]) == 0 and
		int(signal_snapshot.first_days[0]) == 5 and
		int(signal_snapshot.last_days[0]) == 5)
	_test_dense_observation_batch(catalog, profile, river_valley)

	var continuation_profile := profile.duplicate(true)
	continuation_profile.country_max_commands_per_slice = 1
	var continuation_packet := packet.duplicate(true)
	continuation_packet.territory_offsets = PackedInt32Array([0, 4])
	continuation_packet.territory_cells = PackedInt32Array([0, 1, 2, 3])
	var continuation_ext := _new_ext(4)
	continuation_ext.configure_country(catalog, continuation_profile, 4, 123)
	continuation_ext.bootstrap_country(continuation_packet, PackedByteArray([0, 0, 0, 0]))
	var continuation_alpha: Dictionary = continuation_ext.get_country_cell_summary(0)
	continuation_ext.submit_country_commands(_commands([{
		"opcode": 1, "day": 0, "sequence": 1, "handle": 0,
		"cell": 3, "aux": -1, "stable_id": "country.beta", "name": "Beta",
	}]))
	continuation_ext.run_country_slice({"day_index": 0})
	var continuation_beta: Dictionary = continuation_ext.get_country_cell_summary(3)
	var hash_before_continuation := int(continuation_ext.get_country_state_hash())
	continuation_ext.submit_country_commands(_commands([
		{"opcode": 3, "day": 1, "sequence": 1, "handle": continuation_beta.country_handle,
			"cell": 0, "aux": -1, "stable_id": "", "name": ""},
		{"opcode": 3, "day": 1, "sequence": 2, "handle": continuation_beta.country_handle,
			"cell": 1, "aux": -1, "stable_id": "", "name": ""},
	]))
	var continuation_first: Dictionary = continuation_ext.run_country_slice({"day_index": 1})
	_expect("cross-slice country batch keeps committed state private",
		not bool(continuation_first.get("done", true)) and
		bool(continuation_first.get("country_day_barrier", false)) and
		int(continuation_ext.get_country_state_hash()) == hash_before_continuation and
		int(continuation_ext.get_country_cell_summary(0).country_handle) == int(continuation_alpha.country_handle))
	var continuation_second: Dictionary = continuation_ext.run_country_slice({"day_index": 1})
	_expect("cross-slice country batch publishes atomically on final slice",
		bool(continuation_second.get("done", false)) and
		int(continuation_ext.get_country_cell_summary(0).country_handle) == int(continuation_beta.country_handle) and
		int(continuation_ext.get_country_cell_summary(1).country_handle) == int(continuation_beta.country_handle))

	var pending_signal_commands := _commands([
		{"opcode": 14, "day": 6, "sequence": 1, "handle": beta.country_handle,
			"cell": 2, "aux": river_valley, "value": 1, "stable_id": "", "name": ""},
	])
	_expect("pending research signal command queues before PKCN capture",
		bool(ext.submit_country_commands(pending_signal_commands).get("ok", false)))
	var save_begin: Dictionary = ext.begin_country_save(4096)
	_expect("PKCN v13 begins", bool(save_begin.get("ok", false)) and int(save_begin.schema_version) == 13)
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_country_save_chunk(4096)
		if chunk.is_empty(): break
		chunks.append(chunk)
	_expect("PKCN stream ends", bool(ext.end_country_save().get("ok", false)))
	var restored := _new_ext(4)
	restored.configure_country(catalog, profile, 4, 99)
	restored.bootstrap_country(packet, water)
	restored.begin_country_restore()
	for chunk in chunks: restored.feed_country_restore_chunk(chunk)
	_expect("PKCN round-trip hash exact", bool(restored.end_country_restore().get("ok", false)) and
		ext.get_country_state_hash() == restored.get_country_state_hash())
	if not chunks.is_empty():
		var truncated := _new_ext(4)
		truncated.configure_country(catalog, profile, 4, 99)
		truncated.bootstrap_country(packet, water)
		truncated.begin_country_restore()
		var partial: PackedByteArray = chunks[0].slice(0, maxi(1, chunks[0].size() / 2))
		truncated.feed_country_restore_chunk(partial)
		_expect("truncated PKCN stream is rejected",
			not bool(truncated.end_country_restore().get("ok", true)))
	var mismatched_catalog := catalog.duplicate(true)
	var changed_costs: PackedInt64Array = mismatched_catalog.technology_costs.duplicate()
	changed_costs[changed_costs.size() - 1] += 1000
	mismatched_catalog.technology_costs = changed_costs
	var mismatched := _new_ext(4)
	mismatched.configure_country(mismatched_catalog, profile, 4, 99)
	mismatched.bootstrap_country(packet, water)
	mismatched.begin_country_restore()
	for chunk in chunks: mismatched.feed_country_restore_chunk(chunk)
	_expect("PKCN catalog mismatch is rejected precisely",
		String(mismatched.end_country_restore().get("reason", "")) ==
		"catalog_hash_mismatch")


func _test_dense_observation_batch(catalog: Dictionary, profile: Dictionary,
		signal_id: int) -> void:
	const CELL_COUNT := 4096
	var ext := _new_ext(CELL_COUNT)
	var configured: Dictionary = ext.configure_country(catalog, profile, CELL_COUNT, 991)
	var packet := {
		"country_ids": PackedStringArray(["country.batch"]),
		"country_names": PackedStringArray(["Batch"]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
	}
	var water := PackedByteArray()
	water.resize(CELL_COUNT)
	var boot: Dictionary = ext.bootstrap_country(packet, water)
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	var rows: Array[Dictionary] = []
	rows.resize(CELL_COUNT)
	for cell in CELL_COUNT:
		rows[cell] = {"opcode": 14, "day": 1, "sequence": cell,
			"handle": handle, "cell": cell, "aux": signal_id, "value": 1,
			"stable_id": "", "name": ""}
	var submit: Dictionary = ext.submit_country_commands(_commands(rows))
	var committed: Dictionary = ext.run_country_slice({"day_index": 1})
	var snapshot: Dictionary = ext.get_country_research_signal_snapshot(handle)
	var events: Dictionary = ext.poll_country_events(0, 32)
	var deltas: PackedInt32Array = events.get("evidence_deltas", PackedInt32Array())
	_expect("dense observation batch configures", bool(configured.get("ok", false)) and
		bool(boot.get("ok", false)) and bool(submit.get("ok", false)))
	_expect("dense observation batch sort/unique merges linearly",
		bool(committed.get("ok", false)) and
		int(committed.get("observation_batch_input", 0)) == CELL_COUNT and
		int(committed.get("observation_batch_added", 0)) == CELL_COUNT and
		int(snapshot.counts[0]) == CELL_COUNT)
	_expect("dense observation batch emits one aggregate signal event",
		deltas.size() == 1 and int(deltas[0]) == CELL_COUNT)

func _new_ext(cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	return ext

func _commands(rows: Array[Dictionary]) -> Dictionary:
	var out := {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(), "target_handles": PackedInt64Array(),
		"cell_indices": PackedInt32Array(), "aux_i32": PackedInt32Array(),
		"domain_i32": PackedInt32Array(), "position_i32": PackedInt32Array(),
		"weight0_bp": PackedInt32Array(), "weight1_bp": PackedInt32Array(),
		"weight2_bp": PackedInt32Array(), "weight3_bp": PackedInt32Array(),
		"value_i64": PackedInt64Array(),
		"tax_kinds": PackedInt32Array(),
		"tax_item_indices": PackedInt32Array(),
		"tax_rate_basis_points": PackedInt32Array(),
		"tax_assessment_modes": PackedInt32Array(),
		"tax_rate_percent": PackedInt32Array(),
		"stable_ids": PackedStringArray(), "display_names": PackedStringArray()}
	for row in rows:
		out.opcodes.append(int(row.opcode))
		out.effective_days.append(int(row.day))
		out.sequences.append(int(row.sequence))
		out.target_handles.append(int(row.handle))
		out.cell_indices.append(int(row.cell))
		out.aux_i32.append(int(row.aux))
		out.domain_i32.append(int(row.get("domain", -1)))
		out.position_i32.append(int(row.get("position", -1)))
		var weights: PackedInt32Array = row.get("weights", PackedInt32Array([0, 0, 0, 0]))
		out.weight0_bp.append(weights[0])
		out.weight1_bp.append(weights[1])
		out.weight2_bp.append(weights[2])
		out.weight3_bp.append(weights[3])
		out.value_i64.append(int(row.get("value", 0)))
		out.tax_kinds.append(int(row.get("tax_kind", -1)))
		out.tax_item_indices.append(int(row.get("tax_item", -1)))
		out.tax_rate_basis_points.append(int(row.get("tax_rate_bp",
			int(row.get("tax_rate", 0)) * 100)))
		out.tax_assessment_modes.append(int(row.get("tax_mode", 0)))
		out.tax_rate_percent.append(int(row.get("tax_rate", 0)))
		out.stable_ids.append(String(row.stable_id))
		out.display_names.append(String(row.name))
	return out

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
