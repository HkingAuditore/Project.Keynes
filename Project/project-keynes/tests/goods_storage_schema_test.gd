extends SceneTree

# Historical CI file name retained. This is the focused Market V2 test suite.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var _checks := 0
var _failures := 0

func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)

func _run() -> void:
	print("=== native market v2 runtime test ===")
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(catalog.get("ok", false)))
	if not bool(catalog.get("ok", false)):
		print(catalog)
		_finish()
		return
	_expect("modern goods catalog is sorted and retains legacy stable ids",
		(catalog.good_ids as PackedStringArray).size() >= 120 and
		(catalog.good_ids as PackedStringArray).has("cloth") and
		(catalog.good_ids as PackedStringArray).has("coal") and
		(catalog.good_ids as PackedStringArray).has("fur") and
		(catalog.good_ids as PackedStringArray).has("grain") and
		(catalog.good_ids as PackedStringArray).has("mutton"))
	_expect("merchant profession compiles", (catalog.profession_ids as PackedStringArray).has("merchant"))
	_expect("modern household needs compile", (catalog.need_ids as PackedStringArray).size() == 15 and
		(catalog.need_ids as PackedStringArray).has("staple_food") and
		(catalog.need_ids as PackedStringArray).has("healthcare"))
	var living_weights: PackedInt32Array = catalog.need_living_cost_weights_q16
	var need_ids: PackedStringArray = catalog.need_ids
	_expect("living cost weights classify essential consumer and luxury needs",
		int(living_weights[need_ids.find("staple_food")]) == 65536 and
		int(living_weights[need_ids.find("communication")]) == 32768 and
		int(living_weights[need_ids.find("luxury")]) == 0)
	_expect("old fur slot removed", DCComponentSchema.find_by_name(&"cell.goods_fur_qty").is_empty())
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt unavailable")
		_finish()
		return
	_test_default_active_gate(catalog)
	_test_merchant_trade_and_save(catalog)
	_test_economy_event_trace(catalog)
	_test_environment_substitution(catalog)
	_test_demand_preview_query(catalog)
	_test_cycle_approximation(catalog)
	_test_cycle_deadline_catchup(catalog)
	_test_worker_scalar_equivalence(catalog)
	_finish()

func _test_default_active_gate(compiled: Dictionary) -> void:
	var ext: Object = _new_ext(1, 0.5)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile = load("res://data/economy/default_economy.tres")
	_expect("default profile configures as ACTIVE", bool(ext.configure_economy(
		catalog, profile.to_native_profile(), 1, 1).get("ok", false)))
	var boot: Dictionary = ext.bootstrap_economy({}, {})
	_expect("empty ACTIVE bootstrap succeeds", bool(boot.get("ok", false)))
	_expect("default market cycle is five days", int(boot.get("market_cycle_days", 0)) == 5)
	_expect("ACTIVE enters production scheduler", bool(ext.economy_should_run(0)) and
		String(ext.get_economy_report().get("market_runtime_mode", "")) == "ACTIVE")

func _test_merchant_trade_and_save(compiled: Dictionary) -> void:
	var ext: Object = _new_ext(1, 0.1)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := _native_profile(true, 1)
	_expect("all-technology market test country bootstraps",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 42))
	var configured: Dictionary = ext.configure_economy(catalog, profile, 1, 42)
	_expect("configure market v2", bool(configured.get("ok", false)))
	var worker_sig: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([worker_sig]),
		"population": PackedInt64Array([100]),
		"funds": PackedInt64Array([10000000]),
	}, {})
	_expect("bootstrap inserts merchant", bool(boot.get("ok", false)) and int(boot.merchant_repairs) == 1)
	var before_pop: Dictionary = ext.get_population_cell_snapshot(0)
	_expect("population conserved while merchant created", int(before_pop.population) == 100)
	_expect("merchant and worker cohorts exist", int(before_pop.cohort_count) == 2)
	var merchant_flags: PackedByteArray = before_pop.merchant_flags
	_expect("exactly one merchant cohort", _sum_u8(merchant_flags) == 1)
	var before_total_funds := _sum_i64(before_pop.funds_by_cohort)
	var merchant_before := _merchant_funds(before_pop)

	var goods: PackedStringArray = compiled.good_ids
	var commands := _stock_commands(0, goods, {
		"grain": 1000000,
		"mutton": 500000,
		"cloth": 250000,
		"fur": 250000,
	}, 0)
	var submitted: Dictionary = ext.submit_economy_commands(commands)
	_expect("explicit stock mint command accepted", bool(submitted.get("ok", false)))
	var before_market: Dictionary = ext.get_market_cell_snapshot(0)
	var report := _run_day(ext, 0)
	_expect("daily market commits", bool(report.get("done", false)) and not bool(report.get("fatal", false)))
	_expect("market population conservation exact", int(report.get("population_error", 1)) == 0)
	_expect("market money conservation exact", int(report.get("money_error", 1)) == 0)
	_expect("market goods conservation exact", int(report.get("goods_error", 1)) == 0)
	var after_pop: Dictionary = ext.get_population_cell_snapshot(0)
	var after_market: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("buyers transfer money without mint", _sum_i64(after_pop.funds_by_cohort) == before_total_funds)
	_expect("merchant receives sales income", _merchant_funds(after_pop) > merchant_before)
	_expect("grain stock consumed", _good_value(after_market, "stock", "grain") < _good_value(before_market, "stock", "grain") + 1000000)
	_expect("demand ema published", _good_value(after_market, "demand_ema", "grain") > 0)
	_expect("next-day price differs", _good_value(after_market, "price", "grain") != _good_value(before_market, "price", "grain"))
	_expect("market has no anonymous cash", not after_market.has("market_cash"))

	var country: Dictionary = ext.get_country_cell_summary(0)
	var cohort_handle := int((after_pop.handles as PackedInt64Array)[0])
	var grain_idx := goods.find("grain")
	ext.submit_economy_commands(_single_command(9, 1, cohort_handle, 0, 0, 10000,
		int(country.country_handle)))
	var cash_in_report := _run_day(ext, 1)
	_expect("cohort cash transfers into its country treasury",
		int(ext.get_country_cell_summary(0).cash) == 10000 and
		int(cash_in_report.get("money_error", 1)) == 0)
	ext.submit_economy_commands(_single_command(1, 2, cohort_handle, 0, 0, 4000,
		int(country.country_handle)))
	var cash_out_report := _run_day(ext, 2)
	_expect("country cash transfer is capped and conservative",
		int(ext.get_country_cell_summary(0).cash) == 6000 and
		int(cash_out_report.get("money_error", 1)) == 0)
	ext.submit_economy_commands(_single_command(13, 3, int(country.country_handle), 0,
		grain_idx, 1000, 0))
	var goods_in_report := _run_day(ext, 3)
	if bool(goods_in_report.get("fatal", false)):
		print("  goods-in fatal report=", goods_in_report)
	_expect("market goods transfer into country treasury conserves goods",
		_good_value(ext.get_country_treasury_snapshot(country.country_handle), "quantities", "grain") == 1000 and
		int(goods_in_report.get("goods_error", 1)) == 0)
	ext.submit_economy_commands(_single_command(12, 4, int(country.country_handle), 0,
		grain_idx, 400, 0))
	var goods_out_report := _run_day(ext, 4)
	if bool(goods_out_report.get("fatal", false)):
		print("  goods-out fatal report=", goods_out_report)
	_expect("country goods transfer back to market conserves goods",
		_good_value(ext.get_country_treasury_snapshot(country.country_handle), "quantities", "grain") == 600 and
		int(goods_out_report.get("goods_error", 1)) == 0)

	var country_save_begin: Dictionary = ext.begin_country_save(4096)
	if not bool(country_save_begin.get("ok", false)):
		print("  PKCN begin failed=", country_save_begin)
	_expect("matching PKCN save begins", bool(country_save_begin.get("ok", false)))
	var country_chunks: Array[PackedByteArray] = []
	while true:
		var country_chunk: PackedByteArray = ext.read_country_save_chunk(4096)
		if country_chunk.is_empty():
			break
		country_chunks.append(country_chunk)
	_expect("matching PKCN save completes", bool(ext.end_country_save().get("ok", false)))

	var save_begin: Dictionary = ext.begin_economy_save(65536)
	if not bool(save_begin.get("ok", false)):
		print("  PKEC begin failed=", save_begin)
	_expect("v11 save begins at committed boundary", bool(save_begin.get("ok", false)) and int(save_begin.schema_version) == 11)
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	_expect("v11 save emits chunks", chunks.size() >= 11)
	_expect("v11 save completes", bool(ext.end_economy_save().get("ok", false)))
	var legacy_target: Object = _new_ext(1, 0.1)
	legacy_target.configure_economy(catalog, profile, 1, 42)
	legacy_target.begin_economy_restore()
	var legacy_header: PackedByteArray = chunks[0].duplicate()
	legacy_header[4] = 9
	legacy_header[5] = 0
	var legacy_result: Dictionary = legacy_target.feed_economy_restore_chunk(legacy_header)
	_expect("countryless PKEC v9 is rejected precisely",
		not bool(legacy_result.get("ok", true)) and
		String(legacy_result.get("reason", "")) == "legacy_countryless_economy_save_unsupported")
	var restored: Object = _new_ext(1, 0.1)
	_expect("restore target configures", bool(restored.configure_economy(catalog, profile, 1, 42).get("ok", false)))
	_expect("PKCN restore begins before PKEC", bool(restored.begin_country_restore().get("ok", false)))
	for chunk in country_chunks:
		_expect("PKCN restore chunk accepted", bool(restored.feed_country_restore_chunk(chunk).get("ok", false)))
	_expect("matching PKCN restores first", bool(restored.end_country_restore().get("ok", false)))
	_expect("restore begins", bool(restored.begin_economy_restore().get("ok", false)))
	for chunk in chunks:
		_expect("restore chunk accepted", bool(restored.feed_economy_restore_chunk(chunk).get("ok", false)))
	_expect("restore completes", bool(restored.end_economy_restore().get("ok", false)))
	_expect("v11 stream restore hash exact", ext.get_economy_state_hash() == restored.get_economy_state_hash())

func _test_economy_event_trace(compiled: Dictionary) -> void:
	var ext: Object = _new_ext(1, 0.2)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := _native_profile(false, 64)
	_expect("event trace configures", bool(ext.configure_economy(catalog, profile, 1, 4242).get("ok", false)))
	var worker_sig: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	_expect("event trace bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([worker_sig]),
		"population": PackedInt64Array([20]),
		"funds": PackedInt64Array([2000000]),
	}, {}).get("ok", false)))
	_expect("trace filter accepted", bool(ext.set_economy_trace_filter({
		"cells": PackedInt32Array([0])}).get("ok", false)))
	var schema: Dictionary = ext.get_economy_event_schema()
	var kinds: Dictionary = schema.get("kinds", {})
	_expect("economy event schema exposes market and epoch kinds",
		int(kinds.get("MARKET_SETTLED", 0)) > 0 and int(kinds.get("EPOCH_COMMITTED", 0)) > 0)
	var goods: PackedStringArray = compiled.good_ids
	ext.submit_economy_commands(_stock_commands(0, goods, {
		"grain": 100000, "mutton": 50000, "cloth": 50000, "fur": 50000}, 0))
	_expect("in-flight event journal remains private", int(ext.poll_economy_events({
		"consumer_id": &"trace_test", "max_events": 128}).get("count", -1)) == 0)
	var report := _run_day(ext, 0)
	_expect("event epoch commits without changing audits", bool(report.get("done", false)) and
		int(report.get("population_error", 1)) == 0 and int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)
	var batch: Dictionary = ext.poll_economy_events({
		"consumer_id": &"trace_test", "max_events": 128})
	var state_after_commit: int = ext.get_economy_state_hash()
	var event_kinds: PackedInt32Array = batch.get("kind", PackedInt32Array())
	_expect("committed batch contains command market and epoch events",
		event_kinds.has(int(kinds.get("COMMAND_SETTLED", -1))) and
		event_kinds.has(int(kinds.get("MARKET_SETTLED", -1))) and
		event_kinds.has(int(kinds.get("EPOCH_COMMITTED", -1))))
	_expect("selected cell emits exact delta legs",
		(batch.get("leg_field", PackedInt32Array()) as PackedInt32Array).size() > 0)
	var last_event: int = int(batch.get("last_event_id", 0))
	ext.ack_economy_events(&"trace_test", last_event)
	_expect("consumer ack advances independently", int(ext.poll_economy_events({
		"consumer_id": &"trace_test", "max_events": 128}).get("count", -1)) == 0)
	var trace_report: Dictionary = ext.get_economy_trace_report()
	_expect("trace report is bounded and untruncated", int(trace_report.get("memory_bytes", 0)) <=
		int(trace_report.get("memory_budget_bytes", 0)) and
		int(trace_report.get("detail_truncated_count", 1)) == 0 and
		int(trace_report.get("stream_hash", 0)) != 0)
	var archive_begin: Dictionary = ext.begin_economy_event_archive(65536)
	var archive_chunks := 0
	if bool(archive_begin.get("ok", false)):
		while true:
			var archive_chunk: PackedByteArray = ext.read_economy_event_archive_chunk(65536)
			if archive_chunk.is_empty():
				break
			archive_chunks += 1
	_expect("PKEJ archive streams header events and end", bool(archive_begin.get("ok", false)) and
		archive_chunks >= 3 and bool(ext.end_economy_event_archive().get("ok", false)))
	_expect("event queries do not mutate economy state", state_after_commit != 0 and
		ext.get_economy_state_hash() == state_after_commit)

func _test_environment_substitution(compiled: Dictionary) -> void:
	var cold: Object = _configured_single_worker(compiled, 0.0, 77)
	var warm: Object = _configured_single_worker(compiled, 1.0, 77)
	var goods: PackedStringArray = compiled.good_ids
	var stock := {"grain": 1000000, "mutton": 1000000, "cloth": 1000000, "fur": 1000000}
	_expect("cold stock accepted", bool(cold.submit_economy_commands(_stock_commands(0, goods, stock, 0)).get("ok", false)))
	_expect("warm stock accepted", bool(warm.submit_economy_commands(_stock_commands(0, goods, stock, 0)).get("ok", false)))
	_run_day(cold, 0)
	_run_day(warm, 0)
	var cold_market: Dictionary = cold.get_market_cell_snapshot(0)
	var warm_market: Dictionary = warm.get_market_cell_snapshot(0)
	var cold_fur_used: int = 1000000 - _good_value(cold_market, "stock", "fur")
	var warm_fur_used: int = 1000000 - _good_value(warm_market, "stock", "fur")
	_expect("cold environment increases fur demand", cold_fur_used > warm_fur_used)
	_expect("environment snapshot day published", int(cold.get_economy_report().environment_day) == 0)

func _test_demand_preview_query(compiled: Dictionary) -> void:
	var cold: Object = _configured_single_worker(compiled, 0.0, 1701)
	var warm: Object = _configured_single_worker(compiled, 1.0, 1701)
	var hash_before: int = cold.get_economy_state_hash()
	var cold_snapshot: Dictionary = cold.get_population_cell_snapshot(0)
	var hash_after: int = cold.get_economy_state_hash()
	var warm_snapshot: Dictionary = warm.get_population_cell_snapshot(0)
	var offsets: PackedInt32Array = cold_snapshot.get("demand_good_offsets", PackedInt32Array())
	var indices: PackedInt32Array = cold_snapshot.get("demand_good_indices", PackedInt32Array())
	var quantities: PackedInt64Array = cold_snapshot.get("demand_per_capita_daily", PackedInt64Array())
	_expect("demand preview CSR aligns with cohort handles", offsets.size() == int(cold_snapshot.cohort_count) + 1 and offsets[0] == 0 and offsets[-1] == indices.size())
	_expect("demand preview columns align", indices.size() == quantities.size() and not quantities.is_empty())
	_expect("demand preview uses current environment slots", bool(cold_snapshot.get("demand_preview_environment_ready", false)))
	_expect("demand preview is read-only", hash_before == hash_after)
	_expect("cold preview increases fur demand", _preview_good_total(cold_snapshot, "fur") > _preview_good_total(warm_snapshot, "fur"))

func _test_cycle_approximation(compiled: Dictionary) -> void:
	const DAYS := 10
	var reference := _configured_cycle_worker(compiled, 1, 301)
	var approximate := _configured_cycle_worker(compiled, DAYS, 301)
	var goods: PackedStringArray = compiled.good_ids
	var stock := {"grain": 10000000, "mutton": 10000000,
		"cloth": 10000000, "fur": 10000000}
	reference.submit_economy_commands(_stock_commands(0, goods, stock, 0))
	approximate.submit_economy_commands(_stock_commands(0, goods, stock, 0))
	var reference_spend := 0
	for day in range(DAYS):
		_run_day(reference, day)
		reference_spend += _sum_i64(reference.get_population_cell_snapshot(0).epoch_expense_by_cohort)
		var result: Dictionary = approximate.run_economy_slice({"day_index": day, "tick_index": day})
		if day == 0:
			_expect("N-day cycle freezes committed visibility", not bool(result.get("done", true)) and
				String(result.get("stage", "")) == "wait_commit")
			var live_hash_before: int = approximate.get_economy_state_hash()
			var live_population: Dictionary = approximate.get_population_cell_snapshot(0)
			var live_market: Dictionary = approximate.get_market_cell_snapshot(0)
			_expect("active cycle exposes latest selected-cell population", \
				String(live_population.get("snapshot_source", "")) == "live_slice" and \
				(live_population.get("populations", PackedInt64Array()) as PackedInt64Array).size() > 0)
			_expect("active cycle exposes latest selected-cell market", \
				String(live_market.get("snapshot_source", "")) == "live_slice" and \
				(live_market.get("good_ids", PackedStringArray()) as PackedStringArray).size() == goods.size())
			_expect("live selected-cell queries are read-only", \
				live_hash_before == approximate.get_economy_state_hash())
	var approx_report: Dictionary = approximate.get_economy_report()
	_expect("N-day cycle settles on deadline", not bool(approx_report.get("epoch_active", true)) and
		int(approx_report.get("commit_day", -1)) == DAYS - 1)
	var reference_market: Dictionary = reference.get_market_cell_snapshot(0)
	var approximate_market: Dictionary = approximate.get_market_cell_snapshot(0)
	var initial_total := 0
	for amount in stock.values():
		initial_total += int(amount)
	var ref_consumed := initial_total - _sum_i64(reference_market.stock)
	var approx_consumed := initial_total - _sum_i64(approximate_market.stock)
	var approx_spend := _sum_i64(approximate.get_population_cell_snapshot(0).epoch_expense_by_cohort)
	var consumption_error_q16 := _relative_error_q16(approx_consumed, ref_consumed)
	var spending_error_q16 := _relative_error_q16(approx_spend, reference_spend)
	print("  [approx] days=%d consumption_error=%.2f%% spending_error=%.2f%%" % [DAYS,
		float(consumption_error_q16) * 100.0 / 65536.0,
		float(spending_error_q16) * 100.0 / 65536.0])
	_expect("N-day consumption error is bounded to 25%", consumption_error_q16 <= 16384)
	_expect("N-day spending error is bounded to 25%", spending_error_q16 <= 16384)
	_expect("N-day approximation still conserves money/goods", int(approx_report.money_error) == 0 and
		int(approx_report.goods_error) == 0)
	for sweep_days in [20, 50, 100, 334]:
		var measured := _measure_cycle_error(compiled, sweep_days)
		print("  [approx] days=%d consumption_error=%.2f%% spending_error=%.2f%%" % [
			sweep_days, float(measured.consumption_error_q16) * 100.0 / 65536.0,
			float(measured.spending_error_q16) * 100.0 / 65536.0])

func _measure_cycle_error(compiled: Dictionary, days: int) -> Dictionary:
	var reference := _configured_cycle_worker(compiled, 1, 700 + days)
	var approximate := _configured_cycle_worker(compiled, days, 700 + days)
	var goods: PackedStringArray = compiled.good_ids
	var stock := {"grain": 100000000, "mutton": 100000000,
		"cloth": 100000000, "fur": 100000000}
	reference.submit_economy_commands(_stock_commands(0, goods, stock, 0))
	approximate.submit_economy_commands(_stock_commands(0, goods, stock, 0))
	var reference_spend := 0
	for day in range(days):
		_run_day(reference, day)
		reference_spend += _sum_i64(reference.get_population_cell_snapshot(0).epoch_expense_by_cohort)
		approximate.run_economy_slice({"day_index": day, "tick_index": day})
	var ref_market: Dictionary = reference.get_market_cell_snapshot(0)
	var approx_market: Dictionary = approximate.get_market_cell_snapshot(0)
	var initial_total := 0
	for amount in stock.values():
		initial_total += int(amount)
	var ref_consumed := initial_total - _sum_i64(ref_market.stock)
	var approx_consumed := initial_total - _sum_i64(approx_market.stock)
	var approx_spend := _sum_i64(approximate.get_population_cell_snapshot(0).epoch_expense_by_cohort)
	return {"consumption_error_q16": _relative_error_q16(approx_consumed, ref_consumed),
		"spending_error_q16": _relative_error_q16(approx_spend, reference_spend)}

func _configured_cycle_worker(compiled: Dictionary, cycle_days: int, seed: int) -> Object:
	var ext: Object = _new_ext(1, 0.25)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := _native_profile(false, 1)
	profile.auto_slice_by_scale = false
	profile.cells_per_slice = 1
	profile.market_cycle_days = cycle_days
	profile.market_max_cycle_days = cycle_days
	ext.configure_economy(catalog, profile, 1, seed)
	var signature: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	ext.bootstrap_economy({"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([signature]), "population": PackedInt64Array([100]),
		"funds": PackedInt64Array([100000000])}, {})
	return ext

func _test_cycle_deadline_catchup(compiled: Dictionary) -> void:
	var ext: Object = _new_ext(10, 0.5)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := _native_profile(false, 1)
	profile.auto_slice_by_scale = false
	profile.cells_per_slice = 1
	profile.market_cycle_days = 2
	profile.market_max_cycle_days = 2
	ext.configure_economy(catalog, profile, 10, 901)
	var signature: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	var cells := PackedInt32Array()
	var signatures := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in range(10):
		cells.append(cell)
		signatures.append(signature)
		populations.append(10)
		funds.append(1000000)
	ext.bootstrap_economy({"cell_indices": cells, "signature_ids": signatures,
		"population": populations, "funds": funds}, {})
	var day0: Dictionary = ext.run_economy_slice({"day_index": 0, "tick_index": 0})
	_expect("cycle does not block before settlement deadline", not bool(day0.commit_due) and
		int(day0.days_until_commit) == 1)
	var deadline: Dictionary = ext.run_economy_slice({"day_index": 1, "tick_index": 1})
	_expect("unfinished cycle requests deadline catchup", bool(deadline.commit_due) and
		not bool(deadline.done))
	var catchup := 0
	while not bool(deadline.done) and catchup < 32:
		catchup += 1
		deadline = ext.run_economy_slice({"day_index": 1, "tick_index": 100 + catchup})
	_expect("same-day catchup eventually commits", bool(deadline.done) and catchup > 0 and
		int(deadline.commit_day) == 1)

func _test_worker_scalar_equivalence(compiled: Dictionary) -> void:
	var scalar: Object = _configured_many_workers(compiled, false, 96)
	var worker: Object = _configured_many_workers(compiled, true, 96)
	var goods: PackedStringArray = compiled.good_ids
	var stock := {"grain": 1000000, "mutton": 1000000, "cloth": 1000000, "fur": 1000000}
	for cell in range(96):
		scalar.submit_economy_commands(_stock_commands(cell, goods, stock, 0, cell * 10))
		worker.submit_economy_commands(_stock_commands(cell, goods, stock, 0, cell * 10))
	var scalar_report := _run_day(scalar, 0)
	var worker_report := _run_day(worker, 0)
	_expect("worker path dispatches multiple tasks", int(worker_report.get("worker_tasks", 1)) > 1)
	_expect("worker and scalar market v2 hashes match", scalar.get_economy_state_hash() == worker.get_economy_state_hash())
	_expect("worker and scalar economy event hashes match",
		int(scalar.get_economy_trace_report().get("stream_hash", 0)) ==
		int(worker.get_economy_trace_report().get("stream_hash", 1)))

func _configured_single_worker(compiled: Dictionary, temperature: float, seed: int) -> Object:
	var ext: Object = _new_ext(1, temperature)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	ext.configure_economy(catalog, _native_profile(true, 1), 1, seed)
	var signature: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([signature]),
		"population": PackedInt64Array([100]),
		"funds": PackedInt64Array([10000000]),
	}, {})
	return ext

func _configured_many_workers(compiled: Dictionary, workers: bool, cells: int) -> Object:
	var ext: Object = _new_ext(cells, 0.25)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	ext.configure_economy(catalog, _native_profile(workers, 1), cells, 91)
	var signature: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	var cell_indices := PackedInt32Array()
	var signatures := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in range(cells):
		cell_indices.append(cell)
		signatures.append(signature)
		populations.append(10)
		funds.append(1000000)
	ext.bootstrap_economy({"cell_indices": cell_indices, "signature_ids": signatures,
		"population": populations, "funds": funds}, {})
	return ext

func _new_ext(cells: int, temperature: float) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var values := PackedFloat32Array()
	values.resize(cells)
	values.fill(temperature)
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover", &"cell_weather_intensity"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, values)
	return ext

func _native_profile(workers: bool, threshold: int) -> Dictionary:
	var profile = load("res://data/economy/default_economy.tres")
	var out: Dictionary = profile.to_native_profile()
	out.worker_enabled = workers
	out.worker_market_threshold = threshold
	out.worker_tasks_hint = 4 if workers else 0
	out.market_runtime_mode = "ACTIVE"
	# Focused functional tests use the exact daily reference unless a test
	# explicitly overrides market_cycle_days.
	out.market_cycle_days = 1
	return out

func _stock_commands(cell: int, goods: PackedStringArray, amounts: Dictionary,
		effective_day: int, sequence_base: int = 0) -> Dictionary:
	var count := amounts.size()
	var batch := {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(), "target_handles": PackedInt64Array(),
		"i32_0": PackedInt32Array(), "i32_1": PackedInt32Array(),
		"i64_0": PackedInt64Array(), "i64_1": PackedInt64Array()}
	var keys := amounts.keys()
	keys.sort()
	for i in range(count):
		var good_id: String = String(keys[i])
		batch.opcodes.append(4)
		batch.effective_days.append(effective_day)
		batch.sequences.append(sequence_base + i)
		batch.target_handles.append(0)
		batch.i32_0.append(cell)
		batch.i32_1.append(goods.find(good_id))
		batch.i64_0.append(int(amounts[good_id]))
		batch.i64_1.append(0)
	return batch

func _single_command(opcode: int, day: int, target_handle: int, i32_0: int,
		i32_1: int, i64_0: int, i64_1: int) -> Dictionary:
	return {
		"opcodes": PackedInt32Array([opcode]),
		"effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([target_handle]),
		"i32_0": PackedInt32Array([i32_0]),
		"i32_1": PackedInt32Array([i32_1]),
		"i64_0": PackedInt64Array([i64_0]),
		"i64_1": PackedInt64Array([i64_1]),
	}

func _run_day(ext: Object, day: int) -> Dictionary:
	var report: Dictionary = {}
	for slice in range(128):
		report = ext.run_economy_slice({"day_index": day, "tick_index": slice})
		if bool(report.get("done", false)):
			return report
	return report

func _good_value(snapshot: Dictionary, column: String, good_id: String) -> int:
	var ids: PackedStringArray = snapshot.good_ids
	var idx: int = ids.find(good_id)
	var values = snapshot.get(column, [])
	return int(values[idx]) if idx >= 0 else -1

func _preview_good_total(snapshot: Dictionary, good_id: String) -> int:
	var good_ids: PackedStringArray = snapshot.get("demand_good_stable_ids", PackedStringArray())
	var target := good_ids.find(good_id)
	if target < 0:
		return 0
	var offsets: PackedInt32Array = snapshot.get("demand_good_offsets", PackedInt32Array())
	var indices: PackedInt32Array = snapshot.get("demand_good_indices", PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("demand_per_capita_daily", PackedInt64Array())
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var total := 0
	for cohort in range(populations.size()):
		if cohort + 1 >= offsets.size():
			break
		for cursor in range(int(offsets[cohort]), int(offsets[cohort + 1])):
			if cursor < indices.size() and cursor < quantities.size() and indices[cursor] == target:
				total += int(quantities[cursor]) * int(populations[cohort])
	return total

func _merchant_funds(snapshot: Dictionary) -> int:
	var flags: PackedByteArray = snapshot.merchant_flags
	var funds: PackedInt64Array = snapshot.funds_by_cohort
	var total := 0
	for i in range(flags.size()):
		if flags[i] != 0:
			total += funds[i]
	return total

func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += value
	return total

func _sum_u8(values: PackedByteArray) -> int:
	var total := 0
	for value in values:
		total += value
	return total

func _relative_error_q16(value: int, reference: int) -> int:
	return int(abs(value - reference) * 65536 / maxi(1, abs(reference)))

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [PASS] ", label)
	else:
		_failures += 1
		printerr("  [FAIL] ", label)

func _finish() -> void:
	print("  -> checks=%d failures=%d" % [_checks, _failures])
	print("=== native market v2 runtime %s ===" % ("PASS" if _failures == 0 else "FAIL"))
