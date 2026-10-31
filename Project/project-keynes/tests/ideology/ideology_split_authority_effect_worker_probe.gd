extends SceneTree

## MEASUREMENT PROBE (not a pinned gate): what actually happens to an ideology
## equip when IDEOLOGY stays on the main thread while the worker owns EFFECT.
##
## Mask 0xFEF = 0xFFF with ONLY the ideology bit (0x010) cleared, so the worker owns
## EFFECT (0x020), MODIFIER (0x040) and everything else while the main thread runs
## the ideology day. The brief records that in this configuration the equip is
## accepted and then never completes: `locations=[0]` after 23 days,
## `snapshot.last_error = ideology_effect_transition_rejected`, 13 receipts with
## that reason in B2.
##
## This probe prints, per day:
##   * `run_effect_daily(day)`'s return (suppressed?)
##   * `dispatch_effect_native_modifier` / `ack_effect_native_modifier` returns
##   * the equip transition's transaction ids, statuses and command keys
##   * `poll_effect_transactions` (the legacy lifecycle view)
##   * `transition_pending`, `locations`, `last_error`
##   * derived cell values for the card's stats
##   * the ideology receipt log's reason counts
##
## Run:
##   D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe
##     --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_split_authority_effect_worker_probe.gd

const WIDTH := 16
const HEIGHT := 12
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261029
const WORKER_SPEED := 10.0
const Q16_ONE := 65536

const DOMAIN_IDEOLOGY := 0x010
const DOMAIN_EFFECT := 0x020
const DOMAIN_MODIFIER := 0x040
const MASK_ALL := 0xFFF
const MASK_SPLIT_IDEOLOGY_MAIN := MASK_ALL & ~DOMAIN_IDEOLOGY

const CARD := "idea.fire_keeping"
const STAT_ADD := "economy.city.birth_factor"
const STAT_CUT := "economy.city.need.housing.consumption_factor"
const TAG_A := "cell.settlement"
const TAG_B := "cell.terrain.tundra"
const POPULATION_Q16 := 800 * Q16_ONE

const OP_DISCOVER := 1
const OP_GRANT_POINTS := 2
const OP_EQUIP := 5
const OP_ADD_UNDERSTANDING := 8

const MAX_SLICES_PER_DAY := 256
const POD_WAIT_MS := 8000
const PEER_PASSES := 6
const PEER_BATCH := 96
const TRACE_DAYS := 26

const WorkerWaitHelper = preload("res://tests/ideology/ideology_worker_wait_helper.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

var _next_sequence := 1
var _w: Dictionary = {}
var _effect_cursor := 0
var _equip_day := -1
## 0xFEF by default. `PK_SPLIT_MASK=FFF` runs the SAME probe on the reference leg
## (worker owns everything) so the two per-cell dumps can be compared directly.
var _mask := MASK_SPLIT_IDEOLOGY_MAIN


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	await _run()
	print("=== split authority effect-worker probe: done ===")
	quit(0)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[PROBE] DCWorldExt unavailable")
		return
	var mask_override := OS.get_environment("PK_SPLIT_MASK").strip_edges()
	if not mask_override.is_empty():
		_mask = mask_override.hex_to_int() & MASK_ALL
		print("[PROBE] mask override from PK_SPLIT_MASK -> 0x%03X" % _mask)
	print("[PROBE] mask 0x%03X (ideology bit 0x%03X cleared, effect 0x%03X and "
		% [_mask, DOMAIN_IDEOLOGY, DOMAIN_EFFECT]
		+ "modifier 0x%03X stay on the worker)" % DOMAIN_MODIFIER)
	_w = await _build_world()
	if _w.is_empty():
		print("[PROBE] world did not build")
		return
	_zero_support_gates()
	_install_selector_fixture()
	_drive_days(3)
	var report: Dictionary = _w["ext"].get_runtime_thread_report()
	print("[MASK] granted=0x%03X requested=0x%03X ready=%s state=%s fault='%s'"
		% [int(report.get("authoritative_domain_mask", -1)),
			_mask,
			str(report.get("simulation_worker_ready", "?")),
			String(report.get("simulation_host_state", "?")),
			String(report.get("fault_code", ""))])
	print("[PROBE] main-thread ideology suppressed=%s path=%s"
		% [str(_w["last_suppressed"]),
			String((_w["last_ideology"] as Dictionary).get("path", "?"))])

	# ── equip ────────────────────────────────────────────────────────────
	var dense := _dense_id(CARD)
	print("[EQUIP] %s dense=%d" % [CARD, dense])
	var gate: Dictionary = DrawGateHelper.grant_draw_gates(
		_w["host"], CARD, int(_w["handle"]), int(_w["tick"]), _next_sequence)
	_next_sequence = maxi(_next_sequence, int(gate.get(
		"next_sequence", _next_sequence)))
	print("[EQUIP] draw gates=%s" % str(gate))
	_drive_day()
	var preamble: Dictionary = _submit([
		{"op": OP_GRANT_POINTS, "idea": -1, "value": 64 * Q16_ONE},
		{"op": OP_DISCOVER, "idea": dense},
		{"op": OP_ADD_UNDERSTANDING, "idea": dense, "value": 0},
	])
	print("[EQUIP] preamble accepted=%s path=%s"
		% [str(preamble.get("ok", "?")), String(preamble.get("path", "?"))])
	_drive_days(2)
	var accepted: Dictionary = _submit([{"op": OP_EQUIP, "idea": dense}])
	print("[EQUIP] equip submit=%s path=%s" % [str(accepted.get("ok", "?")),
		String(accepted.get("path", "?"))])

	# ── trace ────────────────────────────────────────────────────────────
	for _index in range(TRACE_DAYS):
		_drive_day()
		_trace_day()

	print("[SUMMARY] equip_day=%d final_day=%d" % [_equip_day, int(_w["tick"])])
	var snapshot := _snapshot()
	print("[SUMMARY] locations=%s levels=%s transition_pending=%s"
		% [str(snapshot.get("locations", PackedInt32Array())),
			str(snapshot.get("levels", PackedInt32Array())),
			str(snapshot.get("transition_pending", PackedByteArray()))])
	print("[SUMMARY] last_error='%s'" % String(snapshot.get("last_error", "")))
	print("[SUMMARY] receipt reasons: %s" % str(_receipt_reason_counts()))
	print("[SUMMARY] derived: %s" % str(_derived_report()))
	print("[SUMMARY] settle_last=%s" % str(_w.get("last_settle", {})))
	_dump_parity()

	var stopped: Dictionary = {}
	if _w["ext"].has_method("request_runtime_stop"):
		_w["ext"].request_runtime_stop()
	if is_instance_valid(_w["host"]):
		_w["host"].queue_free()
	if is_instance_valid(_w["clock"]):
		_w["clock"].queue_free()
	stopped["freed"] = true
	print("[SUMMARY] teardown=%s" % str(stopped))


# =========================================================================
# tracing
# =========================================================================
func _trace_day() -> void:
	var day := int(_w["tick"])
	var ext: Object = _w["ext"]
	var snapshot := _snapshot()
	var ids: PackedInt64Array = snapshot.get("transition_transaction_ids",
		PackedInt64Array())
	var statuses: PackedInt32Array = snapshot.get("transition_transaction_statuses",
		PackedInt32Array())
	var pending: PackedByteArray = snapshot.get("transition_pending",
		PackedByteArray())
	var locations: PackedInt32Array = snapshot.get("locations", PackedInt32Array())
	var pending_count := 0
	for value in pending:
		if int(value) != 0:
			pending_count += 1
	var last_effect: Dictionary = _w.get("last_effect", {})
	var effect_row: Dictionary = _w.get("last_effect_row", {})
	print("[D%d] ideology suppressed=%s path=%s | run_effect_daily ok=%s "
		% [day, str(_w["last_suppressed"]),
			String((_w["last_ideology"] as Dictionary).get("path", "?")),
			str(effect_row.get("ok", "?"))]
		+ "suppressed=%s path=%s | dispatch_modifier=%s ack_modifier=%s"
		% [str(effect_row.get("suppressed", "?")),
			String(effect_row.get("path", "?")),
			str(last_effect.get("dispatch_suppressed", "?")),
			str(last_effect.get("ack_suppressed", "?"))])
	print("      pending_transitions=%d pending_bytes=%d locations=%s levels=%s "
		% [pending_count, pending.size(), str(locations),
			str(snapshot.get("levels", PackedInt32Array()))]
		+ "last_error='%s'" % String(snapshot.get("last_error", "")))
	print("      tx_ids=%s tx_statuses=%s (1=PLANNED 2=PREFLIGHTED "
		% [str(ids), str(statuses)]
		+ "3=COMMITTED 4=ACKED 5=REJECTED 6=RESYNC 0=MISSING)")
	var polled := _poll_transactions()
	print("      legacy_poll=%s" % str(polled))
	var derived := _derived_report()
	print("      derived=%s" % str(derived))
	for cell in _sample_cells():
		var probe: Dictionary = ext.get_effective_stat_value(STAT_ADD, cell, 0, 1.0)
		var cut: Dictionary = ext.get_effective_stat_value(STAT_CUT, cell, 0, 1.0)
		print("      cell=%d add_present=%s add=%.10f cut_present=%s cut=%.10f"
			% [cell, str(probe.get("derived_present", "?")),
				float(probe.get("derived_add", 0.0)),
				str(cut.get("derived_present", "?")),
				float(cut.get("derived_add", 0.0))])


## Machine-comparable per-cell dump over EVERY cell of the map, for both stats the
## card writes. Two runs (PK_SPLIT_MASK=0xFEF and PK_SPLIT_MASK=0xFFF) produce two
## `[PARITY]` blocks that are compared cell by cell outside Godot. Every cell is
## dumped, not just the owned ones: the derived term is per-cell, and a reader
## outside Godot cannot re-derive the ownership set.
func _dump_parity() -> void:
	var ext: Object = _w["ext"]
	var map = _w["host"].get_current_map() if _w["host"].has_method(
		"get_current_map") else null
	var cells := PackedInt32Array()
	var owned := 0
	for cell in range(int(_w["cells"])):
		cells.append(cell)
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) == int(_w["handle"]) \
				and not (map != null and bool(map.is_water_arr[cell])):
			owned += 1
	var add_presence := PackedInt32Array()
	var cut_presence := PackedInt32Array()
	var add_values := PackedFloat64Array()
	var cut_values := PackedFloat64Array()
	for cell in cells:
		var probe: Dictionary = ext.get_effective_stat_value(STAT_ADD, int(cell), 0, 1.0)
		var cut: Dictionary = ext.get_effective_stat_value(STAT_CUT, int(cell), 0, 1.0)
		add_presence.append(1 if bool(probe.get("derived_present", false)) else 0)
		cut_presence.append(1 if bool(cut.get("derived_present", false)) else 0)
		add_values.append(float(probe.get("derived_add", 0.0)))
		cut_values.append(float(cut.get("derived_add", 0.0)))
	print("[PARITY] mask=0x%03X cells=%d owned_non_water=%d"
		% [_mask, cells.size(), owned])
	print("[PARITY] cells_list=%s" % _csv_i32(cells))
	print("[PARITY] add_present=%s" % _csv_i32(add_presence))
	print("[PARITY] cut_present=%s" % _csv_i32(cut_presence))
	print("[PARITY] add_values=%s" % _csv_f64(add_values))
	print("[PARITY] cut_values=%s" % _csv_f64(cut_values))


func _csv_i32(values: PackedInt32Array) -> String:
	var parts := PackedStringArray()
	for value in values:
		parts.append(str(int(value)))
	return ",".join(parts)


func _csv_f64(values: PackedFloat64Array) -> String:
	var parts := PackedStringArray()
	for value in values:
		parts.append("%.10f" % float(value))
	return ",".join(parts)


func _poll_transactions() -> Dictionary:
	var ext: Object = _w["ext"]
	var out := {"count": 0, "rows": []}
	if not ext.has_method("poll_effect_transactions"):
		return out
	var polled: Dictionary = ext.poll_effect_transactions(0, 64)
	var ids: PackedInt64Array = polled.get("transaction_ids", PackedInt64Array())
	var statuses: PackedInt32Array = polled.get("statuses", PackedInt32Array())
	var masks: PackedInt32Array = polled.get("required_ack_masks",
		PackedInt32Array())
	var received: PackedInt32Array = polled.get("received_ack_masks",
		PackedInt32Array())
	var programs: PackedInt32Array = polled.get("program_ids", PackedInt32Array())
	var days: PackedInt64Array = polled.get("effective_days", PackedInt64Array())
	var offsets: PackedInt32Array = polled.get("command_offsets",
		PackedInt32Array())
	var keys: PackedStringArray = polled.get("command_keys", PackedStringArray())
	var actions: PackedInt32Array = polled.get("command_actions", PackedInt32Array())
	var domains: PackedInt32Array = polled.get("command_domains", PackedInt32Array())
	var rows: Array = []
	for index in range(ids.size()):
		var row := {
			"id": int(ids[index]),
			"status": int(statuses[index]) if index < statuses.size() else -1,
			"mask": int(masks[index]) if index < masks.size() else -1,
			"recv": int(received[index]) if index < received.size() else -1,
			"program": int(programs[index]) if index < programs.size() else -1,
			"day": int(days[index]) if index < days.size() else -1,
		}
		var commands := PackedStringArray()
		if index + 1 < offsets.size():
			for ordinal in range(int(offsets[index]), int(offsets[index + 1])):
				if ordinal < keys.size():
					commands.append("%s(a=%d d=%d)" % [String(keys[ordinal]),
						int(actions[ordinal]) if ordinal < actions.size() else -1,
						int(domains[ordinal]) if ordinal < domains.size() else -1])
		row["commands"] = commands
		rows.append(row)
	out["count"] = ids.size()
	out["rows"] = rows
	return out


func _receipt_reason_counts() -> Dictionary:
	var ext: Object = _w["ext"]
	var counts := {}
	if not ext.has_method("poll_ideology_receipts"):
		return counts
	var receipts: Dictionary = ext.poll_ideology_receipts(0, 8192)
	var statuses: PackedInt32Array = receipts.get("statuses", PackedInt32Array())
	var reasons: PackedStringArray = receipts.get("reasons", PackedStringArray())
	for index in range(reasons.size()):
		var text := String(reasons[index])
		if text.is_empty():
			continue
		var key := "%s[status=%d]" % [text,
			int(statuses[index]) if index < statuses.size() else -1]
		counts[key] = int(counts.get(key, 0)) + 1
	return counts


func _derived_report() -> Dictionary:
	var ext: Object = _w["ext"]
	var layer: Dictionary = ext.get_derived_cell_layer_report()
	var ideology: Dictionary = ext.get_ideology_report()
	return {
		"installed": bool(layer.get("installed", false)),
		"cells": int(layer.get("cell_count", -1)),
		"contributions": int(layer.get("contribution_count", -1)),
		"generation": int(layer.get("layer_generation", -1)),
		"sample_day": int(layer.get("sample_day", -1)),
		"rebuild_visits": int(ideology.get("cell_layer_rebuild_visits", -1)),
		"confirmed": int(ideology.get("derived_basis_confirmed_day", -1)),
		"eligible": int(ideology.get("derived_basis_eligible_day", -1)),
	}


# =========================================================================
# world construction
# =========================================================================
func _build_world() -> Dictionary:
	var started := Time.get_ticks_msec()
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)
	var host := WorldRuntimeHost.new()
	host.map_width = WIDTH
	host.map_height = HEIGHT
	host.initial_seed = SEED
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 100
	host.runtime_climate_authority_enabled = true
	host.runtime_shadow_on_generate = true
	host.runtime_economy_auto_pod_active = true
	host.runtime_authority_domain_mask = _mask
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "W split-probe"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	print("[BUILD] session ok=%s" % str(session.get("ok", false)))
	if not bool(session.get("ok", false)):
		return {}
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if generator == null:
		print("[BUILD] no generator")
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if ext == null:
		print("[BUILD] no DCWorldExt")
		return {}
	ext.set_runtime_ideology_parity_enabled(false)
	ext.set_runtime_clock(true, WORKER_SPEED)
	var w := {
		"host": host, "clock": clock, "ext": ext, "generator": generator,
		"tick": 0, "cells": CELLS, "handle": 0,
		"started_ms": Time.get_ticks_msec(), "last_ideology": {},
		"last_suppressed": false, "slices": 0, "faulted": false,
		"seed": SEED, "last_effect": {}, "last_effect_row": {},
	}
	var handles := _country_handles(w)
	if handles.is_empty():
		print("[BUILD] no country")
		return {}
	w["handle"] = int(handles[0])
	w["tick"] = maxi(0, _world_day(ext))
	print("[BUILD] ready in %d ms: countries=%d handle=%d day=%d" % [
		Time.get_ticks_msec() - started, handles.size(), int(w["handle"]),
		int(w["tick"])])
	return w


func _country_handles(w: Dictionary) -> PackedInt64Array:
	var ext: Object = w["ext"]
	var seen := {}
	var out := PackedInt64Array()
	for cell in range(int(w["cells"])):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		var handle := int(summary.get("country_handle", 0))
		if handle == 0 or seen.has(handle):
			continue
		seen[handle] = true
		out.append(handle)
	return out


func _world_day(ext: Object) -> int:
	var report: Dictionary = ext.get_runtime_thread_report()
	for key in ["world_day", "ideology_pod_committed_day", "day"]:
		if report.has(key):
			return int(report[key])
	return 0


# =========================================================================
# day driving
# =========================================================================
func _service_peers(ext: Object, passes: int = PEER_PASSES) -> void:
	if not ext.has_method("service_country_worker_peer_adapter"):
		return
	for _pass in range(passes):
		ext.service_country_worker_peer_adapter(PEER_BATCH, true)


func _drive_days(days: int) -> void:
	for _index in range(days):
		_drive_day()


func _drive_day() -> Dictionary:
	if bool(_w.get("faulted", false)):
		return {"ok": false, "faulted": true}
	var ext: Object = _w["ext"]
	var clock: WorldClock = _w["clock"]
	var host: WorldRuntimeHost = _w["host"]
	var fault := String(ext.get_runtime_thread_report().get("fault_code", ""))
	if not fault.is_empty():
		_w["faulted"] = true
		print("[FAULT] worker faulted with '%s' at day %d"
			% [fault, int(_w["tick"])])
		return {"ok": false, "fault": fault}
	_w["tick"] = int(_w["tick"]) + 1
	var day := int(_w["tick"])
	clock.current_day = float(day)
	_service_peers(ext)
	if ext.has_method("publish_ideology_worker_inputs"):
		ext.publish_ideology_worker_inputs()
	host.run_daily_tick(day, clock.season_phase_for_day(day))
	host.finish_daily_tick(0.0, {})
	var pulses := 0
	while _has_hard_barrier(clock) and pulses < 400:
		clock.simulation_backpressure_pulse.emit(day)
		pulses += 1
	_micro_trace(day, "after_run_daily_tick")
	var ideology: Dictionary = {}
	var slices := 0
	for _slice in range(MAX_SLICES_PER_DAY):
		slices += 1
		ideology = ext.run_ideology_daily(day)
		if not bool(ideology.get("ok", true)):
			break
		if bool(ideology.get("suppressed", false)):
			break
		if bool(ideology.get("done", false)):
			break
	_w["last_ideology"] = ideology
	_w["last_suppressed"] = bool(ideology.get("suppressed", false))
	_w["slices"] = int(_w.get("slices", 0)) + slices
	_micro_trace(day, "after_ideology_day")
	var effect_row: Dictionary = {}
	var settle := {}
	if not bool(ideology.get("suppressed", false)):
		for _slice in range(16):
			effect_row = ext.run_effect_daily(day)
			if not bool(effect_row.get("ok", true)):
				break
			if bool(effect_row.get("done", true)):
				break
		settle["dispatch"] = ext.dispatch_effect_native_modifier()
		settle["modifier"] = ext.run_modifier_daily(day)
		settle["ack"] = ext.ack_effect_native_modifier()
	_w["last_effect_row"] = effect_row
	_w["last_settle"] = {
		"effect_daily": (effect_row as Dictionary).get("split_settle", {}),
		"dispatch": (settle.get("dispatch", {}) as Dictionary).get(
			"split_settle", {}),
	}
	_w["last_effect"] = {
		"dispatch_suppressed": str((settle.get("dispatch", {}) as Dictionary).get(
			"suppressed", "-")),
		"ack_suppressed": str((settle.get("ack", {}) as Dictionary).get(
			"suppressed", "-")),
		"dispatch": settle.get("dispatch", {}),
		"ack": settle.get("ack", {}),
	}
	if _equip_day < 0 and _transition_pending():
		_equip_day = day
		print("[EQUIP] transition became pending on day %d" % day)
	if bool(ideology.get("suppressed", false)):
		var before := int(ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		_wait_pod_day(before, POD_WAIT_MS)
	ext.drain_derived_cell_layer(day)
	return {"ok": true, "day": day}


func _has_hard_barrier(clock: Object) -> bool:
	return bool(clock.has_hard_barrier()) if clock.has_method(
		"has_hard_barrier") else false


## The transition's own view of its Effect transactions, sampled at several points
## inside one day. This is what says WHICH status the ACK path rejects on, instead
## of inferring it from the reason string alone.
func _micro_trace(day: int, phase: String) -> void:
	var snapshot := _snapshot()
	var ids: PackedInt64Array = snapshot.get("transition_transaction_ids",
		PackedInt64Array())
	var statuses: PackedInt32Array = snapshot.get("transition_transaction_statuses",
		PackedInt32Array())
	var pending: PackedByteArray = snapshot.get("transition_pending",
		PackedByteArray())
	var pending_count := 0
	for value in pending:
		if int(value) != 0:
			pending_count += 1
	if ids.is_empty() and pending_count == 0:
		return
	print("[MICRO d%d/%s] pending=%d locations=%s tx_ids=%s tx_statuses=%s "
		% [day, phase, pending_count,
			str(snapshot.get("locations", PackedInt32Array())), str(ids),
			str(statuses)]
		+ "last_error='%s'" % String(snapshot.get("last_error", "")))


func _wait_pod_day(before: int, timeout_ms: int) -> void:
	var ext: Object = _w["ext"]
	if ext.has_method("set_runtime_clock"):
		ext.set_runtime_clock(false, WORKER_SPEED)
	WorkerWaitHelper.wait_until(
		func() -> bool:
			var report: Dictionary = ext.get_runtime_thread_report()
			return int(report.get("ideology_pod_committed_day", -1)) > before \
				or String(report.get("simulation_host_state", "")) in [
					"STOPPED", "FAULTED"],
		timeout_ms,
		func() -> void:
			_service_peers(ext, 1))
	if ext.has_method("set_runtime_clock"):
		ext.set_runtime_clock(true, WORKER_SPEED)


func _transition_pending() -> bool:
	var snapshot := _snapshot()
	var pending: PackedByteArray = snapshot.get("transition_pending",
		PackedByteArray())
	for value in pending:
		if int(value) != 0:
			return true
	return false


# =========================================================================
# ideology commands / readers
# =========================================================================
func _submit(rows: Array) -> Dictionary:
	var ext: Object = _w["ext"]
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var producers := PackedInt32Array()
	var sequences := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	var tick := int(_w["tick"])
	for row_value in rows:
		var row: Dictionary = row_value
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", tick)))
		producers.append(1)
		sequences.append(_next_sequence)
		_next_sequence += 1
		handles.append(int(row.get("handle", _w["handle"])))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return ext.submit_ideology_commands({
		"opcodes": opcodes, "effective_days": days, "producer_ids": producers,
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"source_priorities": priorities, "offer_generations": generations,
		"choice_indices": choices, "gate_ids": gates,
	})


func _snapshot() -> Dictionary:
	return _w["ext"].get_ideology_snapshot(int(_w["handle"]))


func _dense_id(card: String) -> int:
	var catalog: Resource = load(
		"res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return -1
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	if not bool(native.get("ok", false)):
		print("[CATALOG] compile failed: %s" % String(native.get("reason", "?")))
		return -1
	var wanted := card if card.begins_with("idea.") else "idea.%s" % card
	return PackedStringArray(native.get("ideology_ids",
		PackedStringArray())).find(wanted)


func _sample_cells() -> PackedInt32Array:
	var ext: Object = _w["ext"]
	var out := PackedInt32Array()
	var map = _w["host"].get_current_map() if _w["host"].has_method(
		"get_current_map") else null
	for cell in range(int(_w["cells"])):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) != int(_w["handle"]):
			continue
		if map != null and bool(map.is_water_arr[cell]):
			continue
		out.append(cell)
		if out.size() >= 4:
			break
	return out


func _install_selector_fixture() -> void:
	var ext: Object = _w["ext"]
	if not ext.has_method("set_cell_tag_override_for_test"):
		return
	ext.clear_cell_tag_overrides_for_test()
	var catalog: Resource = load("res://data/effects/default_effect_catalog.tres")
	if catalog != null:
		var compiled: Dictionary = catalog.compile_native_catalog()
		if bool(compiled.get("ok", false)):
			var metric := PackedStringArray(compiled.get("metric_keys",
				PackedStringArray())).find("cell.population")
			if metric >= 0:
				ext.set_effect_metric_override_for_test(metric, POPULATION_Q16, true)
	var tagged := 0
	for cell in _sample_cells():
		for tag in [TAG_A, TAG_B]:
			if bool(ext.set_cell_tag_override_for_test(String(tag), int(cell),
					true).get("ok", false)):
				tagged += 1
	print("[SETUP] selector fixture tags_set=%d" % tagged)
	ext.refresh_effect_input_digest_for_test()


## Zero the authored stance table through the production `configure_ideologies` API,
## exactly as `ideology_worker_authority_parity_test.gd` does for main-thread legs.
## The main-thread support gate needs a class-opinion snapshot that only the worker
## path publishes in this build, so a main-thread leg cannot pass it otherwise
## (measured: `ideology_class_opinion_unavailable`).
func _zero_support_gates() -> void:
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var country_ir: Dictionary = economy_ir.duplicate(false)
	var compiled: Dictionary = IdeologyCatalogScript.load_default(
		).compile_native_catalog(country_ir, economy_ir)
	if not bool(compiled.get("ok", false)):
		print("[SETUP] ideology catalog compile failed")
		return
	var native := compiled.duplicate(false)
	native.erase("ok")
	var count := (native["ideology_ids"] as PackedStringArray).size()
	var zeros := PackedInt32Array()
	zeros.resize(count + 1)
	native["stance_offsets"] = zeros
	native["stance_class_indices"] = PackedInt32Array()
	native["stance_adopt_q16"] = PackedInt32Array()
	native["stance_repeal_q16"] = PackedInt32Array()
	native["stance_promote_q16"] = PackedInt32Array()
	native["stance_adopt_min_q16"] = PackedInt32Array()
	native["stance_repeal_min_q16"] = PackedInt32Array()
	native["stance_promote_min_q16"] = PackedInt32Array()
	var thresholds := PackedInt32Array()
	thresholds.resize(count)
	native["adopt_thresholds_q16"] = thresholds
	native["repeal_thresholds_q16"] = thresholds.duplicate()
	native["promote_thresholds_q16"] = thresholds.duplicate()
	native["world_seed"] = SEED
	var applied: Dictionary = _w["ext"].configure_ideologies(native)
	print("[SETUP] support gates zeroed: cards=%d applied=%s"
		% [count, str(applied.get("ok", "?"))])
