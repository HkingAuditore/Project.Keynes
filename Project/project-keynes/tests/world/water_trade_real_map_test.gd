extends SceneTree

const SEED := 20260718
const MAP_WIDTH := 40
const MAP_HEIGHT := 28
const FOREIGN_COUNT := 3
const MAX_DAYS := 80
const WATER_TECHNOLOGIES := [
	"tech.river_transport",
	"tech.celestial_navigation",
	"tech.oceanic_navigation",
	"tech.oceanic_ship_design",
]

var _failures := 0
var _clock: WorldClock
var _host: WorldRuntimeHost
var _generator
var _economy
var _country
var _map: MapData
var _owned_cells := PackedInt32Array()
var _last_day := -1
var _last_report: Dictionary = {}
var _portal_day := -1
var _portal_count := 0
var _portal_edges := 0
var _water_order_id := -1
var _water_order_source := -1
var _water_order_destination := -1
var _water_order_seen_active := false
var _visual_routes := 0
var _visual_water_routes := 0
var _visual_day := -1
var _inflight_day := -1
var _arrival_day := -1
var _arrived_events := 0
var _bad_day := -1
var _fatal_seen := false
var _errors_zero := true
var _grant_failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt is available", false, -1, {})
		await _finish()
		return

	var config := NewGameConfig.create_default()
	config.country.name = "Water Trade Regression"
	config.country.foreign_count = FOREIGN_COUNT
	config.base.map_width = MAP_WIDTH
	config.base.map_height = MAP_HEIGHT
	config.base.initial_seed = SEED
	config.base.map_source = NewGameConfig.MAP_SOURCE_PROCEDURAL
	config.base.pkmap_path = ""
	config.apply_land_layout("two")
	var validation: Dictionary = config.validate()
	if not bool(validation.get("ok", false)):
		_expect("formal regression config validates", false, -1, validation)
		await _finish()
		return

	_clock = WorldClock.new()
	_clock.auto_start = false
	_clock.initial_speed = 50.0
	_clock.debug_step_log = false
	root.add_child(_clock)
	_clock.set_speed(50.0)
	_clock.pause(true)

	_host = WorldRuntimeHost.new()
	_host.map_width = MAP_WIDTH
	_host.map_height = MAP_HEIGHT
	_host.initial_seed = SEED
	_host.runtime_economy_auto_pod_active = true
	_host.fog_of_war_enabled = false
	root.add_child(_host)
	await process_frame
	_host.configure(null, null, _clock)
	var session_result: Dictionary = _host.configure_session({
		"kind": "new_game", "config": config.to_dictionary(),
	})
	if not bool(session_result.get("ok", false)):
		_expect("formal NewGameConfig session starts", false, -1, session_result)
		await _finish()
		return
	await _host.generate_world(SEED)
	_generator = _host.get("_generator")
	_map = _host.current_map()
	if _generator == null or _map == null:
		_expect("formal real map generates", false, -1, {})
		await _finish()
		return
	_economy = _generator.get_economy_facade()
	_country = _generator.get_country_facade()
	_collect_owned_cells()
	var grant_report: Dictionary = _grant_water_technologies()
	var ready_report: Dictionary = _generator.get_economy_report()
	_observe_report(-1, ready_report)
	_expect("normal country commands accept all water technologies",
		_grant_failures == 0 and _owned_cells.size() == FOREIGN_COUNT + 1, -1,
		grant_report)

	var run_ok := true
	for day in range(1, MAX_DAYS + 1):
		var day_result: Dictionary = await _run_day(day)
		if not bool(day_result.get("ok", false)):
			_expect("daily climate and simulation barriers drain", false, day,
				day_result)
			run_ok = false
			break
		_last_day = day
		_last_report = _generator.get_economy_report()
		_observe_report(day, _last_report)
		if _fatal_seen or not _errors_zero:
			run_ok = false
			break
		var active_orders := _active_orders()
		_observe_visual_routes(active_orders, day)
		_observe_water_order(active_orders, day, _last_report)
		if _target_observed():
			run_ok = true
			break

	_expect("water portals exist on the real map", _portal_count > 0, _portal_day,
		_last_report if not _last_report.is_empty() else ready_report)
	_expect("water portal graph has edges on the real map", _portal_edges > 0, _portal_day,
		_last_report if not _last_report.is_empty() else ready_report)
	_expect("a dispatched order uses a water route", _water_order_id >= 0,
		_visual_day, _last_report)
	_expect("the water order is observed in transit with goods and cash escrow",
		_inflight_day >= 0, _inflight_day, _last_report)
	_expect("the water order arrives", _arrival_day >= 0, _arrival_day, _last_report)
	_expect("the visual layer receives at least one water route",
		_visual_routes >= 1 and _visual_water_routes >= 1, _visual_day, _last_report)
	_expect("the full run stays fatal-free and exactly conserved",
		run_ok and not _fatal_seen and _errors_zero, _bad_day if _bad_day >= 0 else _last_day,
		_last_report)
	await _finish()


func _expect(label: String, condition: bool, day: int, report: Dictionary) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if condition:
		return
	_failures += 1
	var summary := {
		"day": day,
		"portal_count": int(report.get("trade_water_portal_count", _portal_count)),
		"portal_edges": int(report.get("trade_water_portal_edges", _portal_edges)),
		"orders_dispatched": int(report.get("trade_orders_dispatched", 0)),
		"orders_arrived": int(report.get("trade_orders_arrived", 0)),
		"transit_goods": int(report.get("trade_transit_goods", 0)),
		"escrow_cash": int(report.get("trade_escrow_cash", 0)),
		"visual_routes": _visual_routes,
		"visual_water_routes": _visual_water_routes,
		"water_order_id": _water_order_id,
		"water_order_source": _water_order_source,
		"water_order_destination": _water_order_destination,
		"fatal": bool(report.get("fatal", _fatal_seen)),
		"population_error": int(report.get("population_error", 0)),
		"money_error": int(report.get("money_error", 0)),
		"goods_error": int(report.get("goods_error", 0)),
	}
	print("[water-trade/failure] ", label, " ", JSON.stringify(summary))


func _collect_owned_cells() -> void:
	for cell in _map.cell_count():
		if int(_country.cell_summary(cell).get("country_handle", 0)) != 0:
			_owned_cells.append(cell)


func _grant_water_technologies() -> Dictionary:
	var handles := {}
	for cell in _owned_cells:
		var handle := int(_country.cell_summary(cell).get("country_handle", 0))
		if handle != 0:
			handles[handle] = true
	var sequence := 100000
	var results := []
	var effective_day := maxi(2, _clock.day_index() + 1)
	for handle_value in handles.keys():
		for technology_id in WATER_TECHNOLOGIES:
			var result: Dictionary = _country.grant_technology(int(handle_value),
				StringName(technology_id), effective_day, sequence)
			sequence += 1
			if not bool(result.get("ok", false)):
				_grant_failures += 1
			results.append({"ok": bool(result.get("ok", false))})
	return {"grant_count": results.size(), "grant_failures": _grant_failures}


func _run_day(day: int) -> Dictionary:
	_host._admit_runtime_calendar(day + 1)
	var deadline := Time.get_ticks_usec() + 60000000
	while Time.get_ticks_usec() < deadline:
		_host._process(0.0)
		if _host._runtime_commit_day == day:
			return {"ok": true}
		if _host.is_runtime_fault_paused():
			break
		await process_frame
	return {"ok": false, "reason": "simulation_commit_not_observed",
		"runtime": _runtime_report_snapshot()}


func _runtime_report_snapshot() -> Dictionary:
	if _generator == null:
		return {}
	var out: Dictionary = _generator.get_runtime_thread_report() \
		if _generator.has_method("get_runtime_thread_report") else {}
	if _generator.has_method("get_runtime_perf_snapshot"):
		var graph: Dictionary = _generator.get_runtime_perf_snapshot(0)
		for key in graph:
			out[key] = graph[key]
	return out


func _drain_hard_barrier(day: int) -> Dictionary:
	var pulses := 0
	while (_clock._simulation_backpressure_sources.has(&"country_day_barrier") \
			or _clock._simulation_backpressure_sources.has(&"economy_day_barrier")) \
			and pulses < 4096:
		_clock.simulation_backpressure_pulse.emit(day)
		pulses += 1
		await process_frame
	return {
		"ok": not (_clock._simulation_backpressure_sources.has(&"country_day_barrier") \
			or _clock._simulation_backpressure_sources.has(&"economy_day_barrier")),
		"pulses": pulses,
		"reason": "hard_barrier_not_drained" if pulses >= 4096 else "",
	}


func _observe_report(day: int, report: Dictionary) -> void:
	var portals := int(report.get("trade_water_portal_count", 0))
	var edges := int(report.get("trade_water_portal_edges", 0))
	if portals > 0 and _portal_day < 0:
		_portal_day = day
	if edges > 0 and _portal_day < 0:
		_portal_day = day
	_portal_count = maxi(_portal_count, portals)
	_arrived_events = maxi(_arrived_events, int(report.get("trade_orders_arrived", 0)))
	_portal_edges = maxi(_portal_edges, edges)
	if bool(report.get("fatal", false)):
		_fatal_seen = true
		if _bad_day < 0:
			_bad_day = day
	for key in ["population_error", "money_error", "goods_error"]:
		if int(report.get(key, 0)) != 0:
			_errors_zero = false
			if _bad_day < 0:
				_bad_day = day


func _active_orders() -> Dictionary:
	var rows := {}
	for cell in _owned_cells:
		var page: Dictionary = _economy.trade_orders_for_cell(cell, 0, 256, -1)
		if not bool(page.get("ok", false)):
			continue
		var ids: PackedInt64Array = page.get("order_ids", PackedInt64Array())
		var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
		var destinations: PackedInt32Array = page.get("destination_cells", PackedInt32Array())
		var departures: PackedInt64Array = page.get("departure_days", PackedInt64Array())
		var arrivals: PackedInt64Array = page.get("arrival_days", PackedInt64Array())
		for index in ids.size():
			var order_id := int(ids[index])
			rows[order_id] = {
				"source": int(sources[index]) if index < sources.size() else -1,
				"destination": int(destinations[index]) if index < destinations.size() else -1,
				"departure": int(departures[index]) if index < departures.size() else -1,
				"arrival": int(arrivals[index]) if index < arrivals.size() else -1,
			}
	return rows


func _observe_visual_routes(active_orders: Dictionary, day: int) -> void:
	if active_orders.is_empty():
		return
	var interest := PackedInt32Array()
	for row_value in active_orders.values():
		var row: Dictionary = row_value
		for endpoint in [int(row.get("source", -1)), int(row.get("destination", -1))]:
			if endpoint >= 0 and not interest.has(endpoint):
				interest.append(endpoint)
	if interest.is_empty():
		return
	var snapshot: Dictionary = _economy.trade_visual_snapshot(interest,
		PackedByteArray(), _map.vision_revision * 2, -1, true)
	if not bool(snapshot.get("ok", false)):
		return
	var sources: PackedInt32Array = snapshot.get("source_cells", PackedInt32Array())
	var destinations: PackedInt32Array = snapshot.get("destination_cells", PackedInt32Array())
	var offsets: PackedInt32Array = snapshot.get("route_offsets", PackedInt32Array())
	var modes: PackedByteArray = snapshot.get("edge_modes", PackedByteArray())
	_visual_routes = maxi(_visual_routes, sources.size())
	var water_routes := 0
	for index in sources.size():
		if index + 1 >= offsets.size():
			continue
		var begin := maxi(0, int(offsets[index]))
		var end := int(offsets[index + 1])
		var has_water := false
		for edge in range(begin, maxi(begin, end - 1)):
			if edge < modes.size() and int(modes[edge]) == 1:
				has_water = true
				break
		if not has_water:
			continue
		water_routes += 1
		var pair := "%d:%d" % [int(sources[index]), int(destinations[index])]
		for order_id in active_orders.keys():
			var row: Dictionary = active_orders[order_id]
			if "%d:%d" % [int(row.get("source", -1)), int(row.get("destination", -1))] == pair:
				if _water_order_id < 0:
					_water_order_id = int(order_id)
					_water_order_source = int(row.get("source", -1))
					_water_order_destination = int(row.get("destination", -1))
				break
	_visual_water_routes = maxi(_visual_water_routes, water_routes)
	if water_routes > 0 and _visual_day < 0:
		_visual_day = day


func _observe_water_order(active_orders: Dictionary, day: int, report: Dictionary) -> void:
	if _water_order_id < 0:
		return
	if active_orders.has(_water_order_id):
		_water_order_seen_active = true
		if int(report.get("trade_transit_goods", 0)) > 0 \
				and int(report.get("trade_escrow_cash", 0)) > 0:
			if _inflight_day < 0:
				_inflight_day = day
	elif _water_order_seen_active and _arrival_day < 0 and _arrived_events > 0:
		_arrival_day = day


func _target_observed() -> bool:
	return _portal_count > 0 and _portal_edges > 0 and _water_order_id >= 0 \
		and _inflight_day >= 0 and _arrival_day >= 0 \
		and _visual_routes >= 1 and _visual_water_routes >= 1


func _finish() -> void:
	if _clock != null:
		_clock.pause(true)
	if _host != null:
		_host.queue_free()
	if _clock != null:
		_clock.queue_free()
	await process_frame
	print("=== water trade real map: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)
