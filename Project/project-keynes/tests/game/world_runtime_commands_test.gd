extends SceneTree

const OldHost = preload("res://tests/game/world_runtime_commands_reference.gd")
const Recorders = preload("res://scripts/game/world_runtime_recorders.gd")
var checks := 0
var failures := 0

class Facade extends RefCounted:
	var calls: Array = []
	var reject := false
	func receipt(values: Array) -> Dictionary:
		calls.append(values)
		return {"ok": not reject, "reason": "probe_rejected" if reject else "accepted", "receipt": values}
	func rename_country(h, n, d, s): return receipt(["rename", h, n, d, s])
	func grant_technology(h, t, d, s): return receipt(["technology", h, t, d, s])
	func reveal_all_technologies(h, d, s): return receipt(["reveal", h, d, s])
	func transfer_territory(c, h, d, s): return receipt(["transfer", c, h, d, s])
	func mint_to_treasury(h, c, q, d, s): return receipt(["treasury", h, c, q, d, s])
	func add_stock(c, g, q, d, s): return receipt(["stock", c, g, q, d, s])
	func mint_to_cohort(h, q, d, s): return receipt(["mint", h, q, d, s])
	func burn_from_cohort(h, q, d, s): return receipt(["burn", h, q, d, s])
	func add_population(h, q, d, s): return receipt(["people", h, q, d, s])
	func build(c, b, q, h, d, s): return receipt(["build", c, b, q, h, d, s])
	func demolish(c, b, q, h, d, s): return receipt(["demolish", c, b, q, h, d, s])

class Generator extends MapGenerator:
	var facade := Facade.new()
	func get_country_facade(): return facade
	func get_economy_facade(): return facade

class Current extends WorldRuntimeHost:
	var resolutions: Array = []
	func get_gm_capabilities() -> Dictionary:
		return {"commands": _gm_command_specs(PackedStringArray(["tech"]), PackedStringArray(["grain"]), PackedStringArray(["hut"]))}
	func _gm_selected_country_handle() -> int:
		resolutions.append("selected")
		return 42
	func _gm_resolve_cell(args: Dictionary) -> int:
		resolutions.append("cell")
		return int(args.get("cell", 7))
	func _resolve_player_country_handle() -> int:
		resolutions.append("player")
		return 42
	func _resolve_player_start_cell() -> int:
		resolutions.append("start")
		return 7
	func on_clock_running_changed(_running: bool) -> void: pass

class Previous extends OldHost:
	var resolutions: Array = []
	func get_gm_capabilities() -> Dictionary:
		return {"commands": _gm_command_specs(PackedStringArray(["tech"]), PackedStringArray(["grain"]), PackedStringArray(["hut"]))}
	func _gm_selected_country_handle() -> int:
		resolutions.append("selected")
		return 42
	func _gm_resolve_cell(args: Dictionary) -> int:
		resolutions.append("cell")
		return int(args.get("cell", 7))
	func _resolve_player_country_handle() -> int:
		resolutions.append("player")
		return 42
	func _resolve_player_start_cell() -> int:
		resolutions.append("start")
		return 7
	func on_clock_running_changed(_running: bool) -> void: pass

class AnnualFeed extends RefCounted:
	var presented: Array = []
	func get_annual_report_status() -> Dictionary: return {"ok": true, "last_day": 24, "ready_report_id": 1}
	func get_annual_report_snapshot(id: int) -> Dictionary: return {"ok": true, "id": id, "totals": {"gdp": 130, "revenue": 150, "input_cost": 20}, "complete": true}
	func get_annual_report_history(offset: int, limit: int) -> Dictionary: return {"ok": true, "reports": [get_annual_report_snapshot(1)], "offset": offset, "limit": limit}
	func mark_annual_report_presented(id: int) -> void: presented.append(id)

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var old := Previous.new()
	var current := Current.new()
	for host in [old, current]:
		host._generator = Generator.new()
		host._world_clock = WorldClock.new()
		host._world_clock.auto_start = false
		host._gm_sequence = 100
	_check("specifications identical", old.get_gm_capabilities() == current.get_gm_capabilities())
	var commands: Array = [
		["country.rename", {"name": "Name"}], ["country.grant_technology", {"technology_id": "tech"}],
		["country.reveal_all_technologies", {"country_handle": 23}],
		["country.transfer_territory", {"country_handle": 43, "cell": 8}],
		["economy.mint_to_treasury", {"amount": 1.2345}],
		["economy.add_stock", {"good_id": "grain", "quantity": 1.234}],
		["economy.mint_to_cohort", {"cohort_handle": 10, "amount": 2.5}],
		["economy.burn_from_cohort", {"cohort_handle": 10, "amount": 2.5}],
		["economy.add_population", {"cohort_handle": 10, "amount": 4}],
		["economy.build", {"building_id": "hut", "count": 1, "owner_handle": 10}],
		["economy.demolish", {"building_id": "hut", "count": 1, "owner_handle": 10}],
		["country.rename", {}], ["country.rename", {"name": "x", "unknown": 0}],
		["country.grant_technology", {"technology_id": "absent"}],
		["economy.add_population", {"cohort_handle": "bad", "amount": 1}],
		["economy.mint_to_treasury", {"amount": -1}],
		["economy.mint_to_treasury", {"amount": 1e20}],
		["country.rename", {"name": "x", "day": 0}], ["absent", {}],
		["time.pause", {}], ["time.speed", {"value": 5}],
	]
	for rejected in [false, true]:
		old._generator.facade.reject = rejected
		current._generator.facade.reject = rejected
		for entry in commands:
			for explicit_day in [false, true]:
				var args: Dictionary = entry[1].duplicate(true)
				if explicit_day and not String(entry[0]).begins_with("time."): args["day"] = 5
				_check("response " + entry[0], old.execute_gm_command(entry[0], args) == current.execute_gm_command(entry[0], args))
				_check("sequence", old._gm_sequence == current._gm_sequence)
				_check("exact request day/sequence/amount", old._generator.facade.calls == current._generator.facade.calls)
				_check("lazy resolver order", old.resolutions == current.resolutions)
	for host in [old, current]:
		host._runtime_worker_fault_paused = true
		host._runtime_last_fault_diagnostics = {"fault_code": "fixture"}
	for entry in [["time.pause", {"state": "off"}], ["time.speed", {"value": 5}]]:
		_check("fault refusal", old.execute_gm_command(entry[0], entry[1]) == current.execute_gm_command(entry[0], entry[1]))
	_check("no fault sequence increment", old._gm_sequence == current._gm_sequence)
	for host in [old, current]:
		host._generator = null
	_check("unready refusal", old.execute_gm_command("country.rename", {"name": "x"}) == current.execute_gm_command("country.rename", {"name": "x"}))
	_compare_recorders(old, current)
	for host in [old, current]:
		host._annual_reports._configured = true
		host._annual_reports._ext = AnnualFeed.new()
		host._annual_reports._clock = host._world_clock
	_check("annual status", old.annual_report_status() == current.annual_report_status())
	_check("annual report", old.annual_report_snapshot(1) == current.annual_report_snapshot(1))
	_check("annual history", old.annual_report_history(0, 3) == current.annual_report_history(0, 3))
	_check("annual waiting", old.annual_reports_waiting_for_year(1) == current.annual_reports_waiting_for_year(1))
	old.mark_annual_report_presented(1)
	current.mark_annual_report_presented(1)
	_check("annual presented", old._annual_reports._ext.presented == current._annual_reports._ext.presented)
	for host in [old, current]:
		host._world_clock.free()
		host._world_clock = null
		host.free()
	print("host command/recorder: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _compare_recorders(old: WorldRuntimeHost, current: WorldRuntimeHost) -> void:
	var previous := PerfRecorder.new()
	var next := PerfRecorder.new()
	_check("null recorder state", old._gm_one_recorder_state(null) == current._gm_one_recorder_state(null))
	_check("null recorder ready", old._recorder_ready(null) == current._recorder_ready(null))
	_check("not recording", old._recorder_ready(previous) == current._recorder_ready(next))
	previous.start()
	next.start()
	for sample in [{"tick_idx": 1, "timestamp_ms": 100, "fast_ms": 1.25},
			{"tick_idx": 2, "timestamp_ms": 200, "was_skipped_day": true, "label": "a,\"b\""}]:
		previous.call("on_fast_tick", sample)
		Recorders.record(next, sample)
		_check("recorder rows", previous._rows == next._rows)
		_check("recorder snapshot", old._gm_one_recorder_state(previous) == current._gm_one_recorder_state(next))
		_check("recorder ready", old._recorder_ready(previous) == current._recorder_ready(next))
	var columns := PerfRecorder._collect_columns(previous._rows)
	_check("CSV columns", columns == PerfRecorder._collect_columns(next._rows))
	for i in previous._rows.size():
		_check("CSV bytes", PerfRecorder._format_row_line(previous._rows[i], columns) == PerfRecorder._format_row_line(next._rows[i], columns))
	for result in [null, {}, {"recorded": true, "rows": 2, "reason": "ok", "epoch_id": 4, "format_ms": 1.5, "encoder_path": "native"}]:
		for kind in ["tile", "economy"]:
			var expected: Dictionary = {}
			var actual: Dictionary = {}
			# Frozen result formatting from the old publish body lives in the reference.
			old.call("_reference_" + kind + "_result", result, expected)
			if kind == "tile":
				Recorders.apply_tile_result(result, actual)
			else:
				Recorders.apply_economy_result(result, actual)
			_check("recorder result " + kind, expected == actual)

func _check(label: String, passed: bool) -> void:
	checks += 1
	if not passed:
		failures += 1
		print("[FAIL] " + label)
