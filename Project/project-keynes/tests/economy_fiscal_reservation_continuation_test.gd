extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _checks := 0
var _failures := 0
var _settlement_seen := false
var _settlement_steps := 0
var _settlement_last_cursor := -1
var _settlement_save_checked := false
var _settlement_restore_checked := false


func _init() -> void:
	_run()
	print("=== economy fiscal reservation continuation %s (%d checks, %d failures) ===" % [
		"PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt is available", false)
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog: Dictionary = compiled.duplicate(true)
	catalog.erase("ok")
	var ext: Object = _new_ext(catalog, 3)
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(),
	}
	_expect("three-country Country runtime configures", bool(ext.configure_country(
		catalog, country_profile, 3, 20260909).get("ok", false)))
	var packet := {
		"country_ids": PackedStringArray([
			"country.fiscal_a", "country.fiscal_b", "country.fiscal_c"]),
		"country_names": PackedStringArray(["Fiscal A", "Fiscal B", "Fiscal C"]),
		"country_cash": PackedInt64Array([1000000, 1000000, 1000000]),
		"territory_offsets": PackedInt32Array([0, 1, 2, 3]),
		"territory_cells": PackedInt32Array([0, 1, 2]),
		"technology_offsets": PackedInt32Array([0, 0, 0, 0]),
		"technology_indices": PackedInt32Array(),
		"treasury_offsets": PackedInt32Array([0, 0, 0, 0]),
		"treasury_good_indices": PackedInt32Array(),
		"treasury_quantities": PackedInt64Array(),
	}
	_expect("three countries bootstrap", bool(ext.bootstrap_country(
		packet, PackedByteArray([0, 0, 0])).get("ok", false)))
	var handles := PackedInt64Array()
	for cell in range(3):
		handles.append(int(ext.get_country_cell_summary(cell).get(
			"country_handle", 0)))
	_expect("three distinct Country handles are live",
		handles.size() == 3 and handles[0] > 0 and handles[1] > 0 and
		handles[2] > 0 and handles[0] != handles[1] and handles[1] != handles[2])
	_expect("negative income policy commits", _set_income_tax(ext, handles))
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	_expect("economy configures", bool(ext.configure_economy(
		catalog, profile, 3, 20260909).get("ok", false)))
	var merchant := (compiled.signature_keys as PackedStringArray).find(
		"merchant|default")
	_expect("three population lanes bootstrap", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 1, 2]),
		"signature_ids": PackedInt32Array([merchant, merchant, merchant]),
		"population": PackedInt64Array([20, 20, 20]),
		"funds": PackedInt64Array([100000, 100000, 100000]),
	}, {}).get("ok", false)))
	var cash_before := PackedInt64Array()
	for handle in handles:
		cash_before.append(int(ext.get_country_treasury_snapshot(handle).get("cash", -1)))
	var report: Dictionary = ext.run_economy_slice({
		"day_index": 0, "tick_index": 0, "slice_budget_ms": 8.0})
	var first_pending_save: Dictionary = ext.begin_economy_save(65536)
	_expect("first reserve slice exposes a three-country continuation",
		int(report.get("fiscal_reservation_country_count", 0)) == 3 and
		bool(report.get("fiscal_reservation_continuation_active", false)) and
		bool(report.get("epoch_begin_post_fiscal_pending", false)) and
		not bool(report.get("epoch_active", true)))
	_expect("save rejects while fiscal reserve is pending",
		not bool(first_pending_save.get("ok", true)) and
		String(first_pending_save.get("reason", "")) ==
		"economy_save_fiscal_reservation_pending" and
		int(first_pending_save.get("country_count", 0)) == 3)
	var first_pending_restore: Dictionary = ext.begin_economy_restore()
	_expect("restore rejects while fiscal reserve is pending",
		not bool(first_pending_restore.get("ok", true)) and
		String(first_pending_restore.get("reason", "")) ==
		"restore_fiscal_reservation_pending")
	var previous_cursor := int(report.get("fiscal_reservation_country_cursor", -1))
	var reserve_country_steps := 0
	var reserve_pending_slices := 0
	var last_report := report
	for slice in range(16):
		_observe_settlement(ext, report)
		var cursor := int(report.get("fiscal_reservation_country_cursor", -1))
		var cursor_delta := cursor - previous_cursor
		_expect("fiscal reserve cursor is monotonic and advances by at most one",
			cursor >= previous_cursor and cursor_delta <= 1)
		if cursor_delta == 1:
			reserve_country_steps += 1
			previous_cursor = cursor
		if bool(report.get("fiscal_reservation_continuation_active", false)):
			reserve_pending_slices += 1
			_expect("pending reserve remains outside active Economy epoch",
				not bool(report.get("epoch_active", true)) and
				bool(report.get("epoch_begin_post_fiscal_pending", false)) and
				String(report.get("executed_stage", "")) == "epoch_begin")
		last_report = report
		if bool(report.get("done", false)) or bool(report.get("fatal", false)):
			break
		report = ext.run_economy_slice({
			"day_index": 0, "tick_index": slice + 1, "slice_budget_ms": 8.0})
	_expect("one reserve transaction is executed per Country",
		reserve_country_steps == 3)
	_expect("continuation reports pending intermediate slices",
		reserve_pending_slices >= 2)
	var final_report := _run_until_done(ext, report, 0)
	_expect("fiscal continuation reaches a committed boundary",
		bool(final_report.get("done", false)) and
		not bool(final_report.get("fatal", false)) and
		not bool(final_report.get("epoch_active", true)) and
		int(final_report.get("fiscal_reservation_country_cursor", -1)) == 3 and
		int(final_report.get("fiscal_reservation_continuation_phase", -1)) == 2)
	_expect("country treasury remains nonnegative after reserve",
		int(ext.get_country_treasury_snapshot(handles[0]).get("cash", -1)) >= 0 and
		int(ext.get_country_treasury_snapshot(handles[1]).get("cash", -1)) >= 0 and
		int(ext.get_country_treasury_snapshot(handles[2]).get("cash", -1)) >= 0)
	var cash_changed := false
	for index in range(handles.size()):
		var cash_after := int(ext.get_country_treasury_snapshot(handles[index]).get("cash", -1))
		cash_changed = cash_changed or cash_after < int(cash_before[index])
	_expect("at least one fiscal reserve consumes Country cash",
		cash_changed)
	_expect("final Economy ledger is conserved",
		int(final_report.get("money_error", 1)) == 0 and
		int(final_report.get("goods_error", 1)) == 0)
	_expect("fiscal settlement exposes a per-country continuation when due",
		_settlement_seen and _settlement_steps >= 3)
	_expect("fiscal settlement cursor advances monotonically",
		_settlement_last_cursor >= 3)
	_expect("save is rejected during fiscal settlement continuation",
		_settlement_save_checked)
	_expect("restore is rejected during fiscal settlement continuation",
		_settlement_restore_checked)


func _set_income_tax(ext: Object, handles: PackedInt64Array) -> bool:
	var count := handles.size()
	var opcodes := PackedInt32Array()
	var effective_days := PackedInt64Array()
	var sequences := PackedInt64Array()
	var target_handles := PackedInt64Array()
	var cell_indices := PackedInt32Array()
	var aux_i32 := PackedInt32Array()
	var domain_i32 := PackedInt32Array()
	var position_i32 := PackedInt32Array()
	var weight0_bp := PackedInt32Array()
	var weight1_bp := PackedInt32Array()
	var weight2_bp := PackedInt32Array()
	var weight3_bp := PackedInt32Array()
	var value_i64 := PackedInt64Array()
	var tax_kinds := PackedInt32Array()
	var tax_item_indices := PackedInt32Array()
	var tax_rates := PackedInt32Array()
	var tax_modes := PackedInt32Array()
	var stable_ids := PackedStringArray()
	var display_names := PackedStringArray()
	for index in range(count):
		opcodes.append(11)
		effective_days.append(0)
		sequences.append(index + 1)
		target_handles.append(handles[index])
		cell_indices.append(-1)
		aux_i32.append(-1)
		domain_i32.append(-1)
		position_i32.append(-1)
		weight0_bp.append(0)
		weight1_bp.append(0)
		weight2_bp.append(0)
		weight3_bp.append(0)
		value_i64.append(0)
		tax_kinds.append(0)
		tax_item_indices.append(-1)
		tax_rates.append(-1000)
		tax_modes.append(0)
		stable_ids.append("")
		display_names.append("")
	var result: Dictionary = ext.submit_country_commands({
		"opcodes": opcodes,
		"effective_days": effective_days,
		"sequences": sequences,
		"target_handles": target_handles,
		"cell_indices": cell_indices,
		"aux_i32": aux_i32,
		"domain_i32": domain_i32,
		"position_i32": position_i32,
		"weight0_bp": weight0_bp,
		"weight1_bp": weight1_bp,
		"weight2_bp": weight2_bp,
		"weight3_bp": weight3_bp,
		"value_i64": value_i64,
		"tax_kinds": tax_kinds,
		"tax_item_indices": tax_item_indices,
		"tax_rate_basis_points": tax_rates,
		"tax_assessment_modes": tax_modes,
		"stable_ids": stable_ids,
		"display_names": display_names,
	})
	if not bool(result.get("ok", false)):
		return false
	return bool(ext.run_country_slice({"day_index": 0}).get("ok", false))


func _run_until_done(ext: Object, report: Dictionary, day: int) -> Dictionary:
	var current := report
	for slice in range(256):
		_observe_settlement(ext, current)
		if bool(current.get("done", false)) or bool(current.get("fatal", false)):
			return current
		current = ext.run_economy_slice({
			"day_index": day, "tick_index": 100 + slice, "slice_budget_ms": 8.0})
	return current


func _observe_settlement(ext: Object, report: Dictionary) -> void:
	if not bool(report.get("fiscal_settlement_continuation_active", false)):
		return
	_settlement_seen = true
	var cursor := int(report.get("fiscal_settlement_country_cursor", -1))
	if _settlement_last_cursor >= 0:
		_expect("fiscal settlement cursor is monotonic and advances by at most one",
			cursor >= _settlement_last_cursor and cursor - _settlement_last_cursor <= 1)
	if cursor > _settlement_last_cursor:
		_settlement_steps += cursor - maxi(_settlement_last_cursor, 0)
	_settlement_last_cursor = cursor
	if not _settlement_save_checked:
		var blocked: Dictionary = ext.begin_economy_save(65536)
		_settlement_save_checked = not bool(blocked.get("ok", true)) and \
			String(blocked.get("reason", "")) == "economy_save_fiscal_settlement_pending"
	if not _settlement_restore_checked:
		var blocked_restore: Dictionary = ext.begin_economy_restore()
		_settlement_restore_checked = not bool(blocked_restore.get("ok", true)) and \
			String(blocked_restore.get("reason", "")) == "restore_fiscal_settlement_pending"


func _new_ext(catalog: Dictionary, cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var scalar := PackedFloat32Array()
	scalar.resize(cells)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var zeros := PackedByteArray()
	zeros.resize(cells)
	zeros.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zeros)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	var resource_zeros := PackedFloat32Array()
	resource_zeros.resize(cells)
	resource_zeros.fill(0.0)
	for index in range(reserve_slots.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[index]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[index]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, resource_zeros)
		ext.write_f32_range(extra_sid, 0, resource_zeros)
	return ext
