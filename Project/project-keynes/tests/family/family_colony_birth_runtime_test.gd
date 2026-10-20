extends "res://tests/family/family_colonization_runtime_test.gd"

## 真实开拓落地后从零匿名人口恢复，复用既有开拓/领土事务测试装配。
func _init() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("colony birth catalog compiles", bool(compiled.get("ok", false)))
	if bool(compiled.get("ok", false)):
		compiled.erase("ok")
		_test_colony_births(compiled)
		_test_colony_births(compiled.duplicate(true), true)
	print("=== family colony birth runtime: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _local_family_people(ext: Object, cell: int) -> int:
	var snapshot: Dictionary = ext.get_family_cell_snapshot(cell, 0, 64)
	var people := 0
	for handle in snapshot.get("family_handles", PackedInt64Array()):
		var branches: Dictionary = ext.get_family_branches(int(handle), 0, 64)
		var cells: PackedInt32Array = branches.get("cell_indices", PackedInt32Array())
		var counts: PackedInt64Array = branches.get("populations", PackedInt64Array())
		for index in cells.size():
			if int(cells[index]) == cell:
				people += int(counts[index])
	return people


func _test_colony_births(catalog: Dictionary, anonymous_industry: bool = false) -> void:
	var birth_rates: PackedInt64Array = catalog.signature_birth_rate_q32
	var death_rates: PackedInt64Array = catalog.signature_death_rate_q32
	# Accelerate the existing birth path, without injecting anonymous people.
	birth_rates.fill(858993460)
	death_rates.fill(0)
	catalog.signature_birth_rate_q32 = birth_rates
	catalog.signature_death_rate_q32 = death_rates
	var gathering := (catalog.building_type_ids as PackedStringArray).find("gathering_ground")
	var output_offsets: PackedInt32Array = catalog.building_output_offsets
	var output_quantities: PackedInt64Array = catalog.building_output_quantities
	output_quantities[int(output_offsets[gathering])] = 7000000000
	catalog.building_output_quantities = output_quantities
	var fixture := _make_fixture(catalog, 261016, 1000000000000, {},
		PackedStringArray(), 1, 1000000000000, {
			"family_milestone_populations": PackedInt64Array([100, 200, 500, 1000]),
			"family_min_founder_people": 30,
			"family_review_days": 1,
			"carrying_k_floor": 100000,
			"employment_mobility_daily_q16": 65536,
		}, true, 200 if anonymous_industry else 0)
	var ext: Object = fixture.ext
	if anonymous_industry:
		for slot_name in catalog.building_resource_reserve_slots:
			var sid: int = ext.register_component(StringName(slot_name), 0, 1, false)
			ext.write_f32_range(sid, 0, PackedFloat32Array([1000000.0, 1000000.0, 1000000.0]))
		for slot_name in [&"cell_temp", &"cell_temp_30d"]:
			var sid: int = ext.register_component(slot_name, 0, 1, false)
			ext.write_f32_range(sid, 0, PackedFloat32Array([20.0, 20.0, 20.0]))
		for slot_name in [&"cell_moisture", &"cell_plant_available_water"]:
			var sid: int = ext.register_component(slot_name, 0, 1, false)
			ext.write_f32_range(sid, 0, PackedFloat32Array([0.8, 0.8, 0.8]))
	var country_handle := int(fixture.country_handle)
	var families: Dictionary = ext.get_family_cell_snapshot(0, 0, 64)
	if int(families.get("total", 0)) != 1:
		_expect("colony birth fixture has one founder", false)
		return
	var family_handle := int((families.family_handles as PackedInt64Array)[0])
	var quotes: Dictionary = ext.get_family_colonization_quotes(
		country_handle, 2, family_handle, 0, 0, 64)
	if int(quotes.get("total", 0)) != 1:
		_expect("colony birth quote exists", false)
		return
	var started: Dictionary = ext.start_family_colonization(country_handle,
		family_handle, 0, 2, 3, int(quotes.quote_tokens[0]),
		_economy_command_day(ext), 601)
	_expect("colony birth expedition starts", bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		print("colony birth start=", started)
		return
	var arrival := int(started.arrival_day)
	_expect("colony birth expedition lands", _settle_unowned_expedition(
		ext, country_handle, int(started.expedition_handle), arrival))
	var landed_population := int(ext.get_population_cell_snapshot(2).population)
	_expect("empty colony initially consists entirely of dispatched family members",
		landed_population == 3 and _local_family_people(ext, 2) == 3)
	var first_anonymous := -1
	var max_anonymous := 0
	var births := 0
	var founded := false
	var ledger_ok := true
	var next_day := maxi(arrival, int(ext.get_economy_report().get("current_day", 0))) + 1
	var last_day := next_day
	for day in range(next_day, next_day + 160):
		var report := _run_day(ext, day)
		last_day = day
		ledger_ok = ledger_ok and bool(report.get("done", false)) \
			and not bool(report.get("fatal", false)) \
			and int(report.get("population_error", -1)) == 0 \
			and int(report.get("money_error", -1)) == 0 \
			and int(report.get("goods_error", -1)) == 0 \
			and int(report.get("family_reconcile_corrections", 0)) == 0
		births += int(report.get("births", 0))
		var population := int(ext.get_population_cell_snapshot(2).population)
		var anonymous := population - _local_family_people(ext, 2)
		max_anonymous = maxi(max_anonymous, anonymous)
		if anonymous > 0 and first_anonymous < 0:
			first_anonymous = day
		founded = int(ext.get_family_cell_snapshot(2, 0, 64).get("total", 0)) >= 2
		if not ledger_ok or founded or population >= 1000:
			break
	_expect("natural births occur after landing", births > 0)
	_expect("a wholly family-owned colony produces anonymous newborns", first_anonymous >= 0)
	_expect("anonymous population can reach the ordinary 30-person founder minimum",
		max_anonymous >= 30)
	_expect("colony growth preserves people, money, goods and membership subsets", ledger_ok)
	if anonymous_industry:
		_expect("anonymous newborns can work anonymous industry and found another family", founded)
	print("colony birth evidence=", {"first_anonymous_day": first_anonymous,
		"max_anonymous": max_anonymous, "births": births,
		"population": ext.get_population_cell_snapshot(2).get("population", 0),
		"local_families": ext.get_family_cell_snapshot(2, 0, 64).get("total", 0),
		"days": last_day - next_day + 1})
	if anonymous_industry and not founded:
		print("colony founding diagnostic=", {"population": ext.get_population_cell_snapshot(2),
			"families": ext.get_family_cell_snapshot(2, 0, 64)})
	if ledger_ok:
		_test_birth_restore_replay(ext, last_day)


func _test_birth_restore_replay(ext: Object, day: int) -> void:
	var captured: Dictionary = ext.capture_economy_ecp2(0)
	_expect("colony with anonymous descendants captures ECP2", bool(captured.get("ok", false)))
	if not bool(captured.get("ok", false)):
		print("colony capture=", captured)
		return
	var source_hash := int(ext.get_economy_state_hash())
	var populations := PackedInt64Array()
	var memberships := PackedInt64Array()
	for next_day in range(day + 1, day + 9):
		_run_day(ext, next_day)
		populations.append(int(ext.get_population_cell_snapshot(2).population))
		memberships.append(_local_family_people(ext, 2))
	var restored: Dictionary = ext.restore_economy_ecp2(captured.bytes)
	_expect("colony family and anonymous population hash survives restore",
		bool(restored.get("ok", false)) and int(ext.get_economy_state_hash()) == source_hash)
	if not bool(restored.get("ok", false)):
		print("colony restore=", restored)
		return
	var replay_ok := true
	for offset in range(8):
		var report := _run_day(ext, day + offset + 1)
		replay_ok = replay_ok \
			and int(ext.get_population_cell_snapshot(2).population) == int(populations[offset]) \
			and _local_family_people(ext, 2) == int(memberships[offset]) \
			and not bool(report.get("fatal", false)) \
			and int(report.get("population_error", -1)) == 0 \
			and int(report.get("money_error", -1)) == 0 \
			and int(report.get("goods_error", -1)) == 0
	_expect("eight post-restore birth allocations replay exactly with zero ledger errors", replay_ok)
