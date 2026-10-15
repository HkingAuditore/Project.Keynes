extends "res://tests/economy_performance_parity_test.gd"

## Separate processes avoid sharing retained runtime scratch between fixtures.
## Freeze cadence and compare every committed hash; verify per-actor demand and
## saturation counts against the original formulas inside the optimized run.
func _run() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.has("--preview-child"):
		_run_child(arguments.has("--preview-reference"))
		return
	var hashes: Array = []
	for reference in [true, false]:
		# Set before process creation so native C-runtime getenv sees it too.
		OS.set_environment("PK_ECONOMY_MEMO_VERIFY", "1")
		OS.set_environment("PK_ECONOMY_FAMILY_LOOKUP_VERIFY", "1")
		if reference:
			OS.set_environment("PK_ECONOMY_PREVIEW_BASIS_DISABLE", "1")
			OS.set_environment("PK_ECONOMY_ACTIVE_WORKSET_DISABLE", "1")
			OS.set_environment("PK_ECONOMY_FAMILY_LOOKUP_LINEAR", "1")
			OS.set_environment("PK_ECONOMY_POW_CACHE_DISABLE", "1")
			OS.set_environment("PK_ECONOMY_RESOURCE_WIRE_CACHE_DISABLE", "1")
			OS.set_environment("PK_ECONOMY_STAGE_PLAN_SERIAL", "1")
			OS.set_environment("PK_SAVE_CODEC_SCALAR", "1")
			OS.set_environment("PK_ECONOMY_RETENTION_MEMO_DISABLE", "1")
			OS.set_environment("PK_ECONOMY_VARIANT_WEIGHT_SCALAR", "1")
			OS.set_environment("PK_ECONOMY_ATTRIBUTION_MEMO_DISABLE", "1")
			OS.set_environment("PK_ECONOMY_VARIANT_PRICE_BASIS_DISABLE", "1")
			OS.set_environment("PK_ECONOMY_FAMILY_GOOD_CACHE_DISABLE", "1")
			OS.set_environment("PK_ECONOMY_FOOD_STOCK_SCAN_SCALAR", "1")
			OS.set_environment("PK_ECONOMY_FAMILY_METRIC_MASK_DISABLE", "1")
			OS.set_environment("PK_ECONOMY_RESOURCE_PROJECTION_SCALAR", "1")
			OS.set_environment("PK_ECONOMY_MUL_DIV_SCALAR", "1")
			OS.set_environment("PK_ECONOMY_RESOURCE_WIRE_HASH_SCALAR", "1")
			OS.set_environment("PK_TRIGGER_COMMAND_COPY_SCALAR", "1")
			OS.set_environment("PK_ECONOMY_FOOD_CAPACITY_SERIAL", "1")
		else:
			OS.unset_environment("PK_ECONOMY_PREVIEW_BASIS_DISABLE")
			OS.unset_environment("PK_ECONOMY_ACTIVE_WORKSET_DISABLE")
			OS.unset_environment("PK_ECONOMY_FAMILY_LOOKUP_LINEAR")
			OS.unset_environment("PK_ECONOMY_POW_CACHE_DISABLE")
			OS.unset_environment("PK_ECONOMY_RESOURCE_WIRE_CACHE_DISABLE")
			OS.unset_environment("PK_ECONOMY_STAGE_PLAN_SERIAL")
			OS.unset_environment("PK_SAVE_CODEC_SCALAR")
			OS.unset_environment("PK_ECONOMY_RETENTION_MEMO_DISABLE")
			OS.unset_environment("PK_ECONOMY_VARIANT_WEIGHT_SCALAR")
			OS.unset_environment("PK_ECONOMY_ATTRIBUTION_MEMO_DISABLE")
			OS.unset_environment("PK_ECONOMY_VARIANT_PRICE_BASIS_DISABLE")
			OS.unset_environment("PK_ECONOMY_FAMILY_GOOD_CACHE_DISABLE")
			OS.unset_environment("PK_ECONOMY_FOOD_STOCK_SCAN_SCALAR")
			OS.unset_environment("PK_ECONOMY_FAMILY_METRIC_MASK_DISABLE")
			OS.unset_environment("PK_ECONOMY_RESOURCE_PROJECTION_SCALAR")
			OS.unset_environment("PK_ECONOMY_MUL_DIV_SCALAR")
			OS.unset_environment("PK_ECONOMY_RESOURCE_WIRE_HASH_SCALAR")
			OS.unset_environment("PK_TRIGGER_COMMAND_COPY_SCALAR")
			OS.unset_environment("PK_ECONOMY_FOOD_CAPACITY_SERIAL")
		var output: Array = []
		var args := PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--script",
			get_script().resource_path, "--", "--preview-child"])
		if reference: args.append("--preview-reference")
		var status := OS.execute(OS.get_executable_path(), args, output, true)
		_expect("reference=%s child passes" % reference, status == 0)
		var trace: Array = []
		for line in str(output[0] if not output.is_empty() else "").split("\n"):
			if line.begins_with("[preview-parity/hashes] "):
				var decoded = JSON.parse_string(line.trim_prefix("[preview-parity/hashes] "))
				if decoded is Array: trace = decoded
		if status != 0:
			print(output)
		hashes.append(trace)
	_expect("both traces contain 30 committed days", hashes[0].size() == 30 and hashes[1].size() == 30)
	for day in range(mini(hashes[0].size(), hashes[1].size())):
		_expect("day %d state and welfare hashes match" % day, hashes[0][day] == hashes[1][day])
	_finish()


func _run_child(reference: bool) -> void:
	OS.set_environment("PK_ECONOMY_MEMO_VERIFY", "1")
	if reference:
		OS.set_environment("PK_ECONOMY_PREVIEW_BASIS_DISABLE", "1")
	else:
		OS.unset_environment("PK_ECONOMY_PREVIEW_BASIS_DISABLE")
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		_finish()
		return
	var runtime := _boot(compiled, 9, 997)
	_expect("welfare attribution trace activates", bool(
		runtime.set_economy_inspector_trace_cell(0).get("ok", false)))
	runtime.inject_economy_cadence_timing(0.01, 0.01, 0.01)
	var hashes: Array = []
	var complete_welfare_days := 0
	for day in range(_soak_days()):
		var report: Dictionary = _run_compact_day(runtime, day)
		_expect("day %d complete" % day, bool(report.get("done", false)) and not bool(report.get("fatal", false)))
		for key in ["population_error", "money_error", "goods_error"]:
			_expect("day %d %s==0" % [day, key], int(report.get(key, -1)) == 0)
		# JSON numbers cannot retain all 64 hash bits.
		var welfare: Dictionary = runtime.get_population_cell_snapshot(0)
		# Planning can create a cohort after market settlement. Its first detail
		# arrives on the next market day; the traced batch still exists today.
		_expect("day %d traced welfare batch is present" % day,
			bool(welfare.get("settlement_detail_available", false)) and
			welfare.get("welfare_need_ids", PackedInt32Array()).size() > 0)
		if bool(welfare.get("welfare_detail_available", false)):
			complete_welfare_days += 1
		var welfare_columns: Array = [welfare.get("welfare_detail_available")]
		for key in ["handles", "overall_satisfaction_by_cohort_q16",
				"living_standard_level_by_cohort", "welfare_need_offsets",
				"welfare_need_ids", "welfare_need_satisfaction_q16", "welfare_need_weight_q16",
				"demand_wealth_delta_per_capita_daily", "demand_price_delta_per_capita_daily"]:
			welfare_columns.append(welfare.get(key))
		hashes.append([str(runtime.get_economy_state_hash()),
			JSON.stringify(welfare_columns).sha256_text()])
	_expect("complete welfare is exercised on most days", complete_welfare_days >= 20)
	print("[preview-parity/hashes] %s" % JSON.stringify(hashes))
	_finish()


func _finish() -> void:
	print("economy_preview_basis_parity_test checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
