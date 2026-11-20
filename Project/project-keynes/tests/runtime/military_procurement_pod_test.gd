extends "res://tests/economy/economy_worker_restart_day_test.gd"

# Exercise opcode 36 through the actual whole-graph ACTIVE plan/apply lane.
func _run() -> int:
	_run_started_ms = Time.get_ticks_msec()
	var world := await _build_world("military-demand")
	if world.is_empty(): return 1
	var ext: Object = world.ext
	for index in range(MAX_PROMOTE_DAYS):
		_drive_day(world)
		if int(_probe(world).granted) == MASK_ALL: break
	if not _require("whole-graph ACTIVE authority is granted", int(_probe(world).granted) == MASK_ALL):
		return 1
	var cell := -1
	var country := 0
	for candidate in range(CELLS):
		var summary: Dictionary = ext.get_country_cell_summary(candidate)
		var handle := int(summary.get("country_handle", 0))
		if handle == 0: continue
		var treasury: Dictionary = ext.get_country_treasury_snapshot(handle)
		var market: Dictionary = ext.get_market_cell_snapshot(candidate)
		if int(treasury.get("cash", 0)) > 0 and bool(market.get("ok", false)):
			cell = candidate
			country = handle
			break
	if not _require("funded country has a live local market", cell >= 0): return 1
	var catalog: Dictionary = preload("res://scripts/economy/economy_catalog.gd").compile_native_catalog()
	var good := (catalog.good_ids as PackedStringArray).find("bows")
	var batch := {
		"request_ids": PackedInt64Array([810001, 810002]),
		"opcodes": PackedInt32Array([36, 36]),
		"target_cells": PackedInt32Array([-1, cell]),
		"target_cohorts": PackedInt64Array([0, country]),
		"target_countries": PackedInt64Array([-1, good]),
		"payload0s": PackedInt64Array([0, 1000]),
		"payload1s": PackedInt64Array([0, 10]),
	}
	var submitted: Dictionary = ext.submit_economy_pod_commands(batch)
	_expect("military demand POD batch admits", bool(submitted.get("ok", false)), str(submitted))
	var committed := false
	var rejected := false
	var saw_demand := false
	for index in range(6):
		_drive_day(world)
		# ACTIVE drains terminal ACKs after commit. Replaying the same identity
		# returns its cached outcome without applying the forecast a second time.
		ext.submit_economy_pod_commands(batch)
		var receipts: Dictionary = ext.poll_economy_pod_receipts(512)
		for row in receipts.get("receipts", []):
			if int(row.get("request_id", 0)) != 810002: continue
			committed = committed or int(row.get("code", 0)) == 3
			rejected = rejected or int(row.get("code", 0)) in [4, 5]
			print("MILITARY_DEMAND_POD_RECEIPT=", row)
		var market: Dictionary = ext.get_market_cell_snapshot(cell)
		var demand: PackedInt64Array = market.get("military_demand_daily", PackedInt64Array())
		saw_demand = saw_demand or (good >= 0 and good < demand.size() and int(demand[good]) > 0)
		if committed and saw_demand: break
	_expect("opcode 36 commits through production POD execution", committed and not rejected)
	_expect("POD forecast reaches frozen market demand", saw_demand)
	_expect("ACTIVE demand processing has no worker fault", String(_probe(world).fault).is_empty(), str(_probe(world)))
	return 0
