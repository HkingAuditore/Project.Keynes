extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

const CELL_COUNT := 10
const PHASE_COUNT := 5
var failures := 0

func _init() -> void:
	_run()
	print("=== economy rolling runtime %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1

func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	var runtime := _new_runtime(compiled, catalog, profile, 92015)
	if runtime == null:
		return
	var country_summary: Dictionary = runtime.get_country_cell_summary(0)
	_expect("positive income and consumption tax policy commits",
		_set_tax_defaults(runtime, int(country_summary.get("country_handle", 0)),
			10, 12))
	_expect("default profile enables BALANCED ACTIVE approximation",
		String(runtime.get_economy_report().get(
			"economy_approximation_runtime_mode", "")) == "ACTIVE")
	_expect("default profile enables INCREMENTAL closing audit",
		String(runtime.get_economy_report().get(
			"closing_audit_mode", "")) == "INCREMENTAL")
	_expect("rolling inspector trace target registers",
		bool(runtime.set_economy_inspector_trace_cell(1).get("ok", false)))
	var traced_before: Dictionary = runtime.get_population_cell_snapshot(1)
	var traced_handles: PackedInt64Array = traced_before.get("handles", PackedInt64Array())
	_expect("rolling inspector target has a cohort", not traced_handles.is_empty())
	if traced_handles.is_empty():
		return
	_expect("rolling inspector transfer queues", bool(runtime.submit_economy_commands({
		"opcodes": PackedInt32Array([2]),
		"effective_days": PackedInt64Array([1]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([traced_handles[0]]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([123456]),
		"i64_1": PackedInt64Array([0]),
	}).get("ok", false)))
	var traced_epoch := -1
	var traced_sources := PackedInt32Array()
	var traced_income := PackedInt64Array()
	var traced_expense := PackedInt64Array()
	for day in range(8):
		_validate_day(runtime, day)
		var traced: Dictionary = runtime.get_population_cell_snapshot(1)
		if day == 0:
			_expect("non-due trace remains pending before first cell settlement",
				not bool(traced.get("settlement_detail_available", false)) and
				bool(traced.get("settlement_detail_pending", false)))
		elif day == 1:
			traced_epoch = int(traced.get("settlement_epoch_id", -1))
			traced_sources = traced.get(
				"settlement_cashflow_source_indices", PackedInt32Array()).duplicate()
			traced_income = traced.get(
				"settlement_cashflow_income", PackedInt64Array()).duplicate()
			traced_expense = traced.get(
				"settlement_cashflow_expense", PackedInt64Array()).duplicate()
			_expect("due trace exposes the classified transfer",
				bool(traced.get("settlement_detail_available", false)) and
				_cashflow_has_source(traced, "transfer", true) and
				not _cashflow_has_source(traced, "other", true))
			_expect("due trace exposes income and consumption tax expense rows",
				_cashflow_has_source(traced, "income_tax", false) and
				_cashflow_has_source(traced, "consumption_tax", false))
		elif day < 6:
			_expect("non-due day %d preserves the last classified trace" % day,
				int(traced.get("settlement_epoch_id", -1)) == traced_epoch and
				traced.get("settlement_cashflow_source_indices", PackedInt32Array()) == traced_sources and
				traced.get("settlement_cashflow_income", PackedInt64Array()) == traced_income and
				traced.get("settlement_cashflow_expense", PackedInt64Array()) == traced_expense and
				not _cashflow_has_source(traced, "other", true) and
				not _cashflow_has_source(traced, "other", false))
	var fiscal: Dictionary = runtime.get_country_fiscal_snapshot(
		int(country_summary.get("country_handle", 0)))
	_expect("household tax enters country treasury without tariff events",
		bool(fiscal.get("ok", false)) and
		_sum_i64(fiscal.get("cumulative_collected", PackedInt64Array())) > 0 and
		int(fiscal.get("tariff_events", -1)) == 0 and
		not bool(fiscal.get("tariffs_active", true)))
	var saved := _save(runtime)
	var saved_country := _save_country(runtime)
	_expect("PKEC v37 saves at a daily committed boundary",
		bool(saved.get("ok", false)) and int(saved.get("schema", 0)) == 39)
	var restored := _new_ext(compiled)
	_expect("restore country matches", CountryTestHelper.configure_all_technologies(
		restored, catalog, CELL_COUNT, 92015))
	_expect("PKCN v11 tax and treasury restore matches",
		_restore_country(restored, saved_country.get("chunks", [])))
	_expect("restore economy configures", bool(restored.configure_economy(
		catalog, profile, CELL_COUNT, 92015).get("ok", false)))
	var restore_result := _restore(restored, saved.get("chunks", []))
	_expect("rolling save restores exact hash", bool(restore_result.get("ok", false)) and
		int(restored.get_economy_state_hash()) == int(runtime.get_economy_state_hash()))
	for day in range(8, 15):
		_validate_day(runtime, day)
		_validate_day(restored, day)
		_expect("day %d restored replay hash" % day,
			int(restored.get_economy_state_hash()) == int(runtime.get_economy_state_hash()))
	var runtime_handle := int(runtime.get_country_cell_summary(0).country_handle)
	var restored_handle := int(restored.get_country_cell_summary(0).country_handle)
	_expect("negative consumption tax queues symmetrically",
		_set_consumption_tax(runtime, runtime_handle, -50, 15, 20) and
		_set_consumption_tax(restored, restored_handle, -50, 15, 20))
	_validate_day(runtime, 15)
	_validate_day(restored, 15)
	var first_subsidy: Dictionary = runtime.get_country_fiscal_snapshot(runtime_handle)
	_expect("first negative-tax batch establishes budget without payout",
		_sum_i64(first_subsidy.get("subsidy_requested", PackedInt64Array())) > 0 and
		_sum_i64(first_subsidy.get("subsidy_paid", PackedInt64Array())) == 0)
	for day in range(16, 21):
		_validate_day(runtime, day)
		_validate_day(restored, day)
		_expect("subsidy day %d restored replay hash" % day,
			int(restored.get_economy_state_hash()) == int(runtime.get_economy_state_hash()))
	var funded_subsidy: Dictionary = runtime.get_country_fiscal_snapshot(runtime_handle)
	_expect("next matching rolling batch pays treasury-capped subsidy",
		_sum_i64(funded_subsidy.get("cumulative_subsidy_paid",
			PackedInt64Array())) > 0 and
		int(runtime.get_country_treasury_snapshot(runtime_handle).cash) >= 0)
	var floor_runtime := _new_runtime(compiled, catalog, profile, 92016, false)
	if floor_runtime == null:
		return
	var floor_handle := int(floor_runtime.get_country_cell_summary(0).country_handle)
	var floor_population: Dictionary = floor_runtime.get_population_cell_snapshot(0)
	var floor_cohorts: PackedInt64Array = floor_population.get(
		"handles", PackedInt64Array())
	_expect("minimum-living subsidy fixture has a treasury donor",
		not floor_cohorts.is_empty())
	if floor_cohorts.is_empty():
		return
	_expect("minimum-living subsidy fixture funds treasury before activation",
		_transfer_from_cohort(
			floor_runtime, int(floor_cohorts[0]), 500000, 0, 1))
	_validate_day(floor_runtime, 0)
	_expect("negative income tax activates on the next due phase",
		_set_income_tax(floor_runtime, floor_handle, -20, 1, 2))
	_validate_day(floor_runtime, 1)
	var floor_fiscal: Dictionary = floor_runtime.get_country_fiscal_snapshot(
		floor_handle)
	var floor_requested: PackedInt64Array = floor_fiscal.get(
		"subsidy_requested", PackedInt64Array())
	var floor_paid: PackedInt64Array = floor_fiscal.get(
		"subsidy_paid", PackedInt64Array())
	_expect("zero-market-income cohorts receive the funded living-cost floor immediately",
		floor_requested.size() > 0 and floor_paid.size() > 0 and
		int(floor_requested[0]) > 0 and int(floor_paid[0]) > 0 and
		int(floor_paid[0]) <= int(floor_requested[0]) and
		int(floor_runtime.get_country_treasury_snapshot(floor_handle).cash) >= 0)
	var floor_saved := _save(floor_runtime)
	var floor_country_saved := _save_country(floor_runtime)
	var floor_restored := _new_ext(compiled)
	_expect("income-floor restore country configures",
		CountryTestHelper.configure_all_technologies(
			floor_restored, catalog, CELL_COUNT, 92016))
	_expect("income-floor country policy and treasury restore",
		_restore_country(
			floor_restored, floor_country_saved.get("chunks", [])))
	_expect("income-floor economy restore configures",
		bool(floor_restored.configure_economy(
			catalog, profile, CELL_COUNT, 92016).get("ok", false)))
	_expect("income-floor save restores exact hash",
		bool(_restore(
			floor_restored, floor_saved.get("chunks", [])).get("ok", false)) and
		int(floor_restored.get_economy_state_hash()) ==
			int(floor_runtime.get_economy_state_hash()))
	_validate_day(floor_runtime, 2)
	_validate_day(floor_restored, 2)
	_expect("income-floor restored replay remains deterministic",
		int(floor_restored.get_economy_state_hash()) ==
			int(floor_runtime.get_economy_state_hash()))

func _new_runtime(compiled: Dictionary, catalog: Dictionary,
		profile: Dictionary, seed: int, stock_survival: bool = true) -> Object:
	var ext := _new_ext(compiled)
	_expect("country configures", CountryTestHelper.configure_all_technologies(
		ext, catalog, CELL_COUNT, seed))
	_expect("economy configures", bool(ext.configure_economy(
		catalog, profile, CELL_COUNT, seed).get("ok", false)))
	var merchant := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	var cells := PackedInt32Array()
	var signatures := PackedInt32Array()
	var population := PackedInt64Array()
	var funds := PackedInt64Array()
	cells.resize(CELL_COUNT)
	signatures.resize(CELL_COUNT)
	population.resize(CELL_COUNT)
	funds.resize(CELL_COUNT)
	for cell in range(CELL_COUNT):
		cells[cell] = cell
		signatures[cell] = merchant
		population[cell] = 10
		funds[cell] = 1000000
	var goods: int = (compiled.good_ids as PackedStringArray).size()
	var stock := PackedInt64Array()
	var prices := PackedInt32Array()
	stock.resize(CELL_COUNT * goods)
	stock.fill(0)
	var gathered := (compiled.good_ids as PackedStringArray).find("gathered_plants")
	prices.resize(CELL_COUNT * goods)
	for cell in range(CELL_COUNT):
		for good in range(goods):
			prices[cell * goods + good] = int(
				(compiled.good_default_price as PackedInt32Array)[good])
		if stock_survival and gathered >= 0:
			stock[cell * goods + gathered] = 100000000
	_expect("ten local markets bootstrap", bool(ext.bootstrap_economy({
		"cell_indices": cells,
		"signature_ids": signatures,
		"population": population,
		"funds": funds,
	}, {"stock": stock, "price": prices}).get("ok", false)))
	return ext

func _validate_day(ext: Object, day: int) -> void:
	var report: Dictionary = {}
	var slices := 0
	var saw_investment_range := false
	var household_substages: Dictionary = {}
	var household_breakdown_valid := true
	var household_breakdown_seen := false
	var commit_substages: Dictionary = {}
	var commit_breakdown_valid := true
	var investment_prepare_breakdown_seen := false
	var bounded_post_work := true
	var finalize_slices := 0
	var compact_checked := false
	var max_chunks := 0
	var chunk_bounds_valid := true
	while slices < 64:
		var use_compact: bool = day == 0 and slices == 0 and \
			ext.has_method("run_economy_slice_compact")
		report = ext.run_economy_slice_compact({
			"day_index": day,
			"tick_index": day * 1000 + slices,
		}) if use_compact else ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slices,
		})
		if use_compact:
			compact_checked = String(report.get("report_mode", "")) == "compact_slice" and \
				report.has("executed_stage") and report.has("commit_due") and \
				not report.has("memory_bytes")
		var chunks := int(report.get("chunks_completed", 0))
		max_chunks = maxi(max_chunks, chunks)
		chunk_bounds_valid = chunk_bounds_valid and chunks >= 0 and chunks <= 8
		var executed_stage := String(report.get("executed_stage", ""))
		var executed_substage := String(report.get("executed_substage", ""))
		if executed_stage == "household_market":
			household_substages[executed_substage] = true
			var household_breakdown: Dictionary = report.get(
				"household_market_breakdown_ms", {})
			var household_work: Dictionary = report.get(
				"household_market_breakdown_work", {})
			var expected_breakdown := "household_market.%s" % (
				"settle.worker" if executed_substage == "settle"
				else executed_substage)
			household_breakdown_seen = true
			household_breakdown_valid = household_breakdown_valid and \
				household_breakdown.has(expected_breakdown) and \
				household_work.has(expected_breakdown)
			if executed_substage == "reserve_shortfall":
				bounded_post_work = bounded_post_work and \
					int(report.get("work_done", 0)) <= 4096 * maxi(1, chunks)
		if executed_stage == "building_commit":
			commit_substages[executed_substage] = true
			var commit_breakdown: Dictionary = report.get(
				"building_commit_breakdown_ms", {})
			commit_breakdown_valid = commit_breakdown_valid and commit_breakdown.has(
				"building_commit.%s" % executed_substage)
			investment_prepare_breakdown_seen = investment_prepare_breakdown_seen or \
				commit_breakdown.has("building_commit.investment_prepare")
			if executed_substage in ["special_reset", "recovery_review"]:
				bounded_post_work = bounded_post_work and \
					int(report.get("work_done", 0)) <= int(
						report.get("building_review_groups_per_slice", -1)) * \
						maxi(1, chunks)
			if executed_substage == "finalize":
				finalize_slices += 1
				bounded_post_work = bounded_post_work and \
					int(report.get("work_done", 0)) <= int(
						report.get("building_finalize_cells_per_slice", -1)) * \
						maxi(1, chunks)
		if String(report.get("stage", "")) == "building_commit" and \
				int(report.get("building_commit_phase", -1)) >= 1:
			saw_investment_range = true
		slices += 1
		if bool(report.get("done", false)) or bool(report.get("fatal", false)):
			break
	var completed := bool(report.get("done", false))
	if String(report.get("report_mode", "")) == "compact_slice":
		report = ext.get_economy_report()
		report["done"] = completed
	_expect("day %d uses bounded multi-chunk continuation" % day,
		slices >= 1 and slices < 64 and chunk_bounds_valid and max_chunks > 0)
	if day == 0:
		_expect("compact slice keeps scheduler fields without full diagnostics",
			compact_checked)
	_expect("day %d exposes bounded investment continuation" % day,
		saw_investment_range or max_chunks > 1)
	_expect("day %d exposes sliced household finalization" % day,
		completed or (bounded_post_work and household_substages.has("settle")))
	_expect("day %d exposes household slice timing breakdown" % day,
		not household_breakdown_seen or household_breakdown_valid)
	_expect("day %d exposes baked building review phases" % day,
		commit_breakdown_valid and (commit_substages.has("investment") or
		max_chunks > 1))
	_expect("day %d exposes isolated investment prepare timing" % day,
		investment_prepare_breakdown_seen)
	_expect("day %d slices building finalize reconciliation" % day,
		completed or (bounded_post_work and finalize_slices >= 1))
	_expect("day %d commits one rolling phase" % day,
		bool(report.get("done", false)) and not bool(report.get("fatal", false)) and
		int(report.get("settlement_phase", -1)) == day % PHASE_COUNT and
		int(report.get("due_cells", -1)) == CELL_COUNT / PHASE_COUNT and
		int(report.get("processed_due_cells", -1)) == CELL_COUNT / PHASE_COUNT and
		int(report.get("deferred_cells", -1)) == 0)
	_expect("day %d preserves completed-epoch performance diagnostics" % day,
		bool(report.get("last_completed_perf_valid", false)) and
		int(report.get("last_completed_sample_day", -1)) == day and
		int(report.get("last_completed_continuation_slices", -1)) == slices and
		int(report.get("investment_cells_per_slice", -1)) == 96 and
		int(report.get("building_finalize_cells_per_slice", -1)) == 128)
	_expect("day %d conserves all ledgers" % day,
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0 and
		int(report.get("max_state_age_days", 99)) <= 4)
	for cell in range(CELL_COUNT):
		var snapshot: Dictionary = ext.get_market_cell_snapshot(cell)
		var phase := cell % PHASE_COUNT
		var expected_day := phase - PHASE_COUNT
		if day >= phase:
			expected_day = day - ((day - phase) % PHASE_COUNT)
		var expected_generation := 0 if day < phase else (day - phase) / PHASE_COUNT + 1
		_expect("day %d cell %d state date" % [day, cell],
			bool(snapshot.get("ok", false)) and
			int(snapshot.get("state_day", 999)) == expected_day and
			int(snapshot.get("age_days", 99)) <= 4 and
			int(snapshot.get("settlement_generation", -1)) == expected_generation)

func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELL_COUNT)
	var scalar := PackedFloat32Array()
	scalar.resize(CELL_COUNT)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var terrain := PackedByteArray()
	terrain.resize(CELL_COUNT)
	terrain.fill(2)
	var zeros_u8 := PackedByteArray()
	zeros_u8.resize(CELL_COUNT)
	zeros_u8.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, terrain if slot_name == &"cell_terrain" else zeros_u8)
	var zeros := PackedFloat32Array()
	zeros.resize(CELL_COUNT)
	zeros.fill(0.0)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	for i in range(reserve_slots.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, zeros)
		ext.write_f32_range(extra_sid, 0, zeros)
	return ext


func _cashflow_has_source(snapshot: Dictionary, stable_id: String, income: bool) -> bool:
	var source_ids: PackedStringArray = snapshot.get(
		"settlement_cashflow_source_stable_ids", PackedStringArray())
	var source_idx := source_ids.find(stable_id)
	if source_idx < 0:
		return false
	var sources: PackedInt32Array = snapshot.get(
		"settlement_cashflow_source_indices", PackedInt32Array())
	var values: PackedInt64Array = snapshot.get(
		"settlement_cashflow_income" if income else "settlement_cashflow_expense",
		PackedInt64Array())
	for i in range(mini(sources.size(), values.size())):
		if int(sources[i]) == source_idx and int(values[i]) > 0:
			return true
	return false


func _set_tax_defaults(ext: Object, handle: int, income: int,
		consumption: int) -> bool:
	var count := 2
	var batch := {
		"opcodes": PackedInt32Array([11, 11]),
		"effective_days": PackedInt64Array([0, 0]),
		"sequences": PackedInt64Array([1, 2]),
		"target_handles": PackedInt64Array([handle, handle]),
		"cell_indices": PackedInt32Array([-1, -1]),
		"aux_i32": PackedInt32Array([-1, -1]),
		"domain_i32": PackedInt32Array([-1, -1]),
		"position_i32": PackedInt32Array([-1, -1]),
		"weight0_bp": PackedInt32Array([0, 0]),
		"weight1_bp": PackedInt32Array([0, 0]),
		"weight2_bp": PackedInt32Array([0, 0]),
		"weight3_bp": PackedInt32Array([0, 0]),
		"value_i64": PackedInt64Array([0, 0]),
		"tax_kinds": PackedInt32Array([0, 1]),
		"tax_item_indices": PackedInt32Array([-1, -1]),
		"tax_rate_percent": PackedInt32Array([income, consumption]),
		"stable_ids": PackedStringArray(["", ""]),
		"display_names": PackedStringArray(["", ""]),
	}
	return count == batch.opcodes.size() \
		and bool(ext.submit_country_commands(batch).get("ok", false)) \
		and bool(ext.run_country_slice({"day_index": 0}).get("ok", false))


func _set_consumption_tax(ext: Object, handle: int, rate: int,
		day: int, sequence: int) -> bool:
	var batch := {
		"opcodes": PackedInt32Array([11]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([sequence]),
		"target_handles": PackedInt64Array([handle]),
		"cell_indices": PackedInt32Array([-1]),
		"aux_i32": PackedInt32Array([-1]),
		"domain_i32": PackedInt32Array([-1]),
		"position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]),
		"weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]),
		"weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([0]),
		"tax_kinds": PackedInt32Array([1]),
		"tax_item_indices": PackedInt32Array([-1]),
		"tax_rate_percent": PackedInt32Array([rate]),
		"stable_ids": PackedStringArray([""]),
		"display_names": PackedStringArray([""]),
	}
	return bool(ext.submit_country_commands(batch).get("ok", false)) \
		and bool(ext.run_country_slice({"day_index": day}).get("ok", false))


func _set_income_tax(ext: Object, handle: int, rate: int,
		day: int, sequence: int) -> bool:
	var batch := {
		"opcodes": PackedInt32Array([11]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([sequence]),
		"target_handles": PackedInt64Array([handle]),
		"cell_indices": PackedInt32Array([-1]),
		"aux_i32": PackedInt32Array([-1]),
		"domain_i32": PackedInt32Array([-1]),
		"position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]),
		"weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]),
		"weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([0]),
		"tax_kinds": PackedInt32Array([0]),
		"tax_item_indices": PackedInt32Array([-1]),
		"tax_rate_percent": PackedInt32Array([rate]),
		"stable_ids": PackedStringArray([""]),
		"display_names": PackedStringArray([""]),
	}
	return bool(ext.submit_country_commands(batch).get("ok", false)) \
		and bool(ext.run_country_slice({"day_index": day}).get("ok", false))


func _transfer_from_cohort(ext: Object, cohort_handle: int, amount: int,
		day: int, sequence: int) -> bool:
	return bool(ext.submit_economy_commands({
		"opcodes": PackedInt32Array([9]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([sequence]),
		"target_handles": PackedInt64Array([cohort_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([amount]),
		"i64_1": PackedInt64Array([0]),
	}).get("ok", false))


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total

func _save(ext: Object) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_save(65536)
	if not bool(begin.get("ok", false)):
		return begin
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var ended: Dictionary = ext.end_economy_save()
	return {"ok": bool(ended.get("ok", false)),
		"schema": int(begin.get("schema_version", 0)), "chunks": chunks}

func _restore(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for value in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(value as PackedByteArray)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()


func _save_country(ext: Object) -> Dictionary:
	var begin: Dictionary = ext.begin_country_save(65536)
	if not bool(begin.get("ok", false)):
		return begin
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_country_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var ended: Dictionary = ext.end_country_save()
	return {"ok": bool(ended.get("ok", false)), "chunks": chunks}


func _restore_country(ext: Object, chunks: Array) -> bool:
	if not bool(ext.begin_country_restore().get("ok", false)):
		return false
	for value in chunks:
		if not bool(ext.feed_country_restore_chunk(
				value as PackedByteArray).get("ok", false)):
			return false
	return bool(ext.end_country_restore().get("ok", false))
