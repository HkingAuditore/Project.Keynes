extends SceneTree

# ACTIVE vs production MapData compare, lag-aligned (P3 under ACTIVE / P7 lag).
#
# Two sequential worlds, same seed:
#   production = authority off, snapshot MapData after finishing day N
#   active     = authority on,  snapshot MapData when writeback_last_day == N
#
# That alignment is the one-day lag: worker day N lands on the main thread after
# a later tick. Days 7 / 18 / 28 / 38 are the first-occurrence windows from the
# SHADOW 90-day matrix.
#
# This is not a SHADOW overlay compare. Production still uses
# native_daily_sim_stride=10; the worker commits every day. Large MapData
# deltas here mean cadence, not the day-7 / day-28 constant residuals.
#
# Usage:
#   godot --headless --path Project/project-keynes -s tests/climate_active_parity_probe.gd -- days=40 seed=20260906

const DEFAULT_DAYS := 40
const DEFAULT_SEED := 20260906
const DEFAULT_MAP_WIDTH := 60
const DEFAULT_MAP_HEIGHT := 40
const SNAP_DAYS: Array[int] = [7, 18, 28, 38]
const FIELD_SPECS: Array[Array] = [
	["temperature", "temp_arr"],
	["moisture", "moisture_arr"],
	["vapor", "weather_vapor_arr"],
	["alpha", "weather_transition_alpha_arr"],
	["snowpack", "snowpack_arr"],
	["paw", "plant_available_water_arr"],
]
const TOLERANCE := 1.0e-3
const WORKER_SPEED := 50.0
const WRITEBACK_WAIT_MSEC := 80
const POLL_MSEC := 2


func _init() -> void:
	var code := await _run()
	quit(code)


func _run() -> int:
	var args := _arguments()
	var days := int(args.get("days", DEFAULT_DAYS))
	var seed := int(args.get("seed", DEFAULT_SEED))
	var map_width := int(args.get("width", DEFAULT_MAP_WIDTH))
	var map_height := int(args.get("height", DEFAULT_MAP_HEIGHT))
	var label := str(args.get("label", "active40"))
	var repo_root := ProjectSettings.globalize_path("res://").get_base_dir() \
		.get_base_dir().get_base_dir()
	var out_dir := str(args.get("out", "%s/artifacts/runtime/s4-evidence" % repo_root))
	if days < SNAP_DAYS[0]:
		push_error("[active-parity] days must cover at least day %d" % SNAP_DAYS[0])
		return 2
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[active-parity] DCWorldExt unavailable")
		return 3
	if not DirAccess.dir_exists_absolute(out_dir):
		DirAccess.make_dir_recursive_absolute(out_dir)

	var snap_days: Array[int] = []
	for day in SNAP_DAYS:
		if day <= days:
			snap_days.append(day)
	print("[active-parity] seed=%d days=%d snaps=%s" % [seed, days, str(snap_days)])

	var production: Dictionary = await _run_world(false, seed, map_width, map_height, days, snap_days)
	if not bool(production.get("ok", false)):
		push_error("[active-parity] production world failed: %s" % String(production.get("reason", "")))
		return 4
	var active: Dictionary = await _run_world(true, seed, map_width, map_height, days + 2, snap_days)
	if not bool(active.get("ok", false)):
		push_error("[active-parity] ACTIVE world failed: %s" % String(active.get("reason", "")))
		return 5

	var rows: Array[Dictionary] = []
	var first_occurrence_still_forked := false
	for day in snap_days:
		var prod_snap: Dictionary = production.get("snaps", {}).get(day, {})
		var act_snap: Dictionary = active.get("snaps", {}).get(day, {})
		if prod_snap.is_empty() or act_snap.is_empty():
			push_error("[active-parity] missing snapshot at day %d prod=%s active=%s" % [
				day, str(not prod_snap.is_empty()), str(not act_snap.is_empty())])
			return 6
		for spec in FIELD_SPECS:
			var cmp := _compare_field(day, String(spec[0]),
				prod_snap.get(String(spec[0]), PackedFloat32Array()),
				act_snap.get(String(spec[0]), PackedFloat32Array()))
			rows.append(cmp)
			if day in [7, 28] and int(cmp.get("out_of_band_cells", 0)) > 0:
				first_occurrence_still_forked = true
			print("  day %2d %-12s cells=%d max=%.6f oob=%d first=%d" % [
				day, spec[0], int(cmp.get("cells", 0)),
				float(cmp.get("max_abs", 0.0)),
				int(cmp.get("out_of_band_cells", 0)),
				int(cmp.get("first_cell", -1))])

	var summary := {
		"label": label,
		"seed": seed,
		"days": days,
		"snap_days": snap_days,
		"tolerance": TOLERANCE,
		"production_ticks": int(production.get("ticks", 0)),
		"active_ticks": int(active.get("ticks", 0)),
		"active_writeback_days": int(active.get("writeback_days", 0)),
		"first_occurrence_still_forked": first_occurrence_still_forked,
		"rows": rows,
	}
	var json_path := "%s/active-parity-%s-s%d.json" % [out_dir, label, seed]
	var csv_path := "%s/active-parity-%s-s%d.csv" % [out_dir, label, seed]
	_write_text(json_path, JSON.stringify(summary, "\t"))
	_write_text(csv_path, _csv(rows))
	print("[active-parity/result] first_occurrence_still_forked=%s writeback_days=%d json=%s" % [
		str(first_occurrence_still_forked),
		int(active.get("writeback_days", 0)), json_path])
	return 0


func _run_world(authority: bool, seed: int, width: int, height: int,
		days: int, snap_days: Array[int]) -> Dictionary:
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = width
	host.map_height = height
	host.initial_seed = seed
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 0
	host.runtime_climate_authority_enabled = authority
	get_root().add_child(host)
	host.configure(null, null, clock)
	await host.generate_world(seed)
	var map: MapData = host.get_current_map()
	var generator: MapGenerator = host.get_generator()
	if map == null or generator == null:
		host.free()
		clock.free()
		return {"ok": false, "reason": "generate_failed"}
	var ext = generator.get_data_core_world_ext()
	if authority:
		if ext == null or not ext.has_method("set_runtime_clock"):
			host.free()
			clock.free()
			return {"ok": false, "reason": "no_clock_api"}
		ext.set_runtime_clock(false, WORKER_SPEED)

	var snaps := {}
	var remaining: Array[int] = snap_days.duplicate()
	var tick := 0
	var budget := days + 8
	while tick < budget and (not remaining.is_empty() or tick < days):
		tick += 1
		clock.current_day = float(tick)
		host.run_daily_tick(tick, clock.season_phase_for_day(tick))
		host.finish_daily_tick(0.0, {})
		if authority:
			var deadline := Time.get_ticks_msec() + WRITEBACK_WAIT_MSEC
			while Time.get_ticks_msec() < deadline:
				host._consume_runtime_commit_if_ready()
				OS.delay_msec(POLL_MSEC)
			var last_day := int(host.climate_authority_diagnostics().get("writeback_last_day", -1))
			var still: Array[int] = []
			for day in remaining:
				if last_day >= day and not snaps.has(day):
					snaps[day] = _snapshot(map)
				else:
					still.append(day)
			remaining = still
		else:
			if remaining.has(tick):
				snaps[tick] = _snapshot(map)
				remaining.erase(tick)

	var writeback_days := int(host.climate_authority_diagnostics().get("writeback_days", 0)) \
		if authority else 0
	host.free()
	clock.free()
	await process_frame
	if authority and snaps.size() < snap_days.size():
		return {
			"ok": false,
			"reason": "writeback_missed_days_%s" % str(remaining),
			"snaps": snaps,
			"ticks": tick,
			"writeback_days": writeback_days,
		}
	return {"ok": true, "snaps": snaps, "ticks": tick, "writeback_days": writeback_days}


func _snapshot(map: MapData) -> Dictionary:
	var out := {}
	for spec in FIELD_SPECS:
		var arr: PackedFloat32Array = map.get(String(spec[1]))
		out[String(spec[0])] = arr.duplicate()
	return out


func _compare_field(day: int, name: String, a: PackedFloat32Array,
		b: PackedFloat32Array) -> Dictionary:
	var n := mini(a.size(), b.size())
	var max_abs := 0.0
	var oob := 0
	var first := -1
	for i in range(n):
		var d: float = absf(a[i] - b[i])
		if d > max_abs:
			max_abs = d
		if d > TOLERANCE:
			oob += 1
			if first < 0:
				first = i
	return {
		"day": day,
		"field": name,
		"cells": n,
		"max_abs": max_abs,
		"out_of_band_cells": oob,
		"first_cell": first,
	}


func _csv(rows: Array[Dictionary]) -> String:
	var lines: PackedStringArray = PackedStringArray([
		"day,field,cells,max_abs,out_of_band_cells,first_cell",
	])
	for row in rows:
		lines.append("%d,%s,%d,%.9f,%d,%d" % [
			int(row.get("day", 0)), String(row.get("field", "")),
			int(row.get("cells", 0)), float(row.get("max_abs", 0.0)),
			int(row.get("out_of_band_cells", 0)), int(row.get("first_cell", -1)),
		])
	return "\n".join(lines) + "\n"


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(text)


func _arguments() -> Dictionary:
	var out := {}
	for arg in OS.get_cmdline_user_args():
		var parts := String(arg).split("=", true, 1)
		if parts.size() == 2:
			out[parts[0]] = parts[1]
	return out
