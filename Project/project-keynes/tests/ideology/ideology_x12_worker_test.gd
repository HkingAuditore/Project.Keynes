extends SceneTree

## X12 acceptance on the production worker path.
##
## The fixture claims a neutral land cell adjacent to both the player and a
## foreign country. That changes the territory hash, which must rebuild metric
## 75 and flip `cell.border`; a canal commit must flip `cell.canal` and grow
## metric 76. Equipping `frontier_garrison` must then write real cell Modifier
## rows, and unequipping must restore them. Once territory and canal topology
## stop changing, 30 unchanged days must not rebuild the derived geography
## columns.
##
## Run:
##   godot --headless --path Project/project-keynes \
##     --script res://tests/ideology/ideology_x12_worker_test.gd

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261023
const WORKER_SPEED := 10.0
const METRIC_GEO_FLAGS := 75
const METRIC_WATERWAY_COMPONENT_SIZE := 76
const GEO_BORDER := 8
const SEL_NEIGHBORS_R1 := 6
const SEL_OWN_TERRITORY := 12
const MODIFIER_DOMAIN_ECONOMY := 2
const AGRICULTURE_STAT := "economy.city.building.agriculture_output_factor"
const BIRTH_STAT := "economy.city.birth_factor"
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const IdeologyDrawGateHelper = preload(
	"res://tests/ideology/ideology_draw_gate_helper.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _generator: MapGenerator
var _handle := 0
var _country_slot := 0
var _border_cell := -1
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _tick := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology x12 worker: %d checks, %d failures ===" % [_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	var fixture := await _build_world()
	if fixture.is_empty():
		return 1
	_host = fixture["host"]
	_clock = fixture["clock"]
	_ext = fixture["ext"]
	_generator = fixture["generator"]
	_handle = int(fixture["handle"])
	_country_slot = int(fixture["country_slot"])
	_tick = int(fixture["tick"])
	if not _test_border_claim():
		_teardown()
		return 1
	_test_direct_canal_geography()
	_test_frontier_garrison_card()
	_test_idle_geo_reuse()
	_teardown()
	return 0


## A neutral cell with both a player and a foreign neighbour becomes a border
## only after the Country claim commits. The tag query is the same predicate the
## card's selector uses.
func _test_border_claim() -> bool:
	var tag := _tag_id("cell.border")
	if not _require("cell.border is in the production Effect catalog", tag >= 0,
			str(tag)):
		return false
	var pair := _border_claim_pair()
	if not _require("an owned land cell has a neutral neighbour", not pair.is_empty(),
			str(pair)):
		return false
	var anchor := int(pair[0])
	var selected := int(pair[1])
	var foreign := _foreign_handle()
	if not _require("a foreign country handle is available", foreign != 0,
			str(foreign)):
		return false
	var before_flags := _metric(METRIC_GEO_FLAGS, anchor)
	if not _require("the chosen player cell is not a border before the transfer",
			(before_flags & GEO_BORDER) == 0, str(before_flags)):
		return false
	var committed := _claim_neutral_cell(selected)
	if not _require("the neutral-cell claim commits", committed, str(selected)):
		return false
	if not _require("the claimed cell transfers to the foreign country",
			_transfer_foreign_cell(selected, foreign), str(selected)):
		return false
	_tick = _drive_days(1)
	var flags := _metric(METRIC_GEO_FLAGS, anchor)
	_expect("metric 75 sets the border bit after the transfer (flags=%d)" % flags,
		(flags & GEO_BORDER) != 0, str(flags))
	var tagged := _tagged_cells(tag)
	_expect("cell.border selector includes the player cell beside the transfer",
		tagged.has(anchor), str(tagged))
	_border_cell = anchor
	return true


## A direct domain fixture proves the canal half deterministically. The
## generated 16x12 seed has no rivers and only one small land body, so deriving
## a freshwater route from it would test the seed rather than X12.
func _test_direct_canal_geography() -> void:
	var canal_tag := _tag_id("cell.canal")
	if not _require("cell.canal is in the production Effect catalog",
			canal_tag >= 0, str(canal_tag)):
		return
	var fixture := _build_canal_world()
	if fixture.is_empty():
		return
	var ext: Object = fixture["ext"]
	var start := int(fixture["start"])
	var end := int(fixture["end"])
	var arrow := int(fixture["direction"])
	var reverse := (arrow + 3) % 6
	var quote: Dictionary = ext.get_canal_route_quote(
		int(fixture["handle"]), start, end, PackedInt32Array())
	if not _require("direct canal quote accepts a coastal land pair",
			bool(quote.get("ok", false)), str(quote)):
		return
	var before_flags := int(ext.sample_effect_metric_probe(
		METRIC_GEO_FLAGS, start, int(fixture["handle"])).get("value", -1))
	var queued: Dictionary = ext.queue_canal_construction(
		int(fixture["handle"]), int(quote["quote_token"]), 1, 17)
	if not _require("direct canal construction queues",
			bool(queued.get("ok", false)), str(queued)):
		return
	var started := _run_direct_day(ext, 1)
	if not _require("direct canal command settles on its effective day",
			bool(started.get("done", false)), str(started)):
		return
	var ready_day := 1 + int(quote["construction_days"])
	var ready := _run_direct_day(ext, ready_day)
	var ready_report: Dictionary = ext.get_economy_report()
	if not _require("direct canal construction finishes and awaits Effect",
			bool(ready.get("done", false))
				and int(ready_report.get(
					"canal_project_awaiting_effect_count", 0)) == 1,
			"ready=%s report=%s" % [str(ready), str(ready_report)]):
		return
	var dispatched: Dictionary = ext.dispatch_effect_native_gameplay()
	var committed: Dictionary = ext.run_gameplay_effects(ready_day)
	var acknowledged: Dictionary = ext.ack_effect_native_gameplay()
	if not _require("direct canal Effect commits and acknowledges",
			int(dispatched.get("submitted_transactions", 0)) == 1
				and int(committed.get("committed", 0)) == 1
				and int(acknowledged.get("acknowledged", 0)) == 1,
			"dispatch=%s commit=%s ack=%s" % [
				str(dispatched), str(committed), str(acknowledged)]):
		return
	_run_direct_day(ext, ready_day + 1)
	var map: MapData = fixture["map"]
	_expect("direct canal writes the reciprocal map mask",
		(int(map.canal_edge_mask_arr[start]) & (1 << arrow)) != 0
			and (int(map.canal_edge_mask_arr[end]) & (1 << reverse)) != 0,
		"start=%d end=%d" % [
			int(map.canal_edge_mask_arr[start]), int(map.canal_edge_mask_arr[end])])
	var after_flags := int(ext.sample_effect_metric_probe(
		METRIC_GEO_FLAGS, start, int(fixture["handle"])).get("value", -1))
	var component_size := int(ext.sample_effect_metric_probe(
		METRIC_WATERWAY_COMPONENT_SIZE, start, int(fixture["handle"])).get(
			"value", -1))
	_expect("direct canal flips metric 75's canal bit (flags %d -> %d)" % [
			before_flags, after_flags], (after_flags & 4) != 0, str(after_flags))
	_expect("direct canal publishes a two-cell waterway (count_q16=%d)" %
			component_size, component_size == 2 * 65536, str(component_size))
	var tagged: PackedInt32Array = ext.query_effect_target_cells(
		start, SEL_OWN_TERRITORY, 32, canal_tag + 1)
	var owned: PackedInt32Array = ext.query_effect_target_cells(
		start, SEL_OWN_TERRITORY, 32, 0)
	_expect("cell.canal selects the committed route",
		tagged.has(start) and tagged.has(end),
		"tag=%d tagged=%s owned=%s flags=%d" % [
			canal_tag, str(tagged), str(owned), after_flags])


## frontier_garrison targets `cell.border` and applies real per-cell Modifier
## rows. L1 is +8% agriculture and +5% birth.
func _test_frontier_garrison_card() -> void:
	if _border_cell < 0:
		return
	var agriculture_before := _factor(_border_cell, AGRICULTURE_STAT)
	var birth_before := _factor(_border_cell, BIRTH_STAT)
	_expect("the border cell starts at the baseline agriculture factor",
		_is_close(agriculture_before, 1.0, 0.0005),
		"%.5f" % agriculture_before)
	_expect("the border cell starts at the baseline birth factor",
		_is_close(birth_before, 1.0, 0.0005), "%.5f" % birth_before)
	if not _equip("frontier_garrison"):
		return
	var agriculture := _wait_factor(_border_cell, AGRICULTURE_STAT, 1.08, 12)
	var birth := _wait_factor(_border_cell, BIRTH_STAT, 1.05, 12)
	_expect("frontier_garrison applies +8%% agriculture on the border cell "
			+ "(got %.5f)" % agriculture, _is_close(agriculture, 1.08, 0.0005),
		"%.5f" % agriculture)
	_expect("frontier_garrison applies +5%% birth on the border cell "
			+ "(got %.5f)" % birth, _is_close(birth, 1.05, 0.0005),
		"%.5f" % birth)
	if not _unequip("frontier_garrison"):
		return
	_expect("unequipping frontier_garrison retires its Effect instances",
		int(_ext.get_ideology_effect_instance_report(_handle).get("count", -1)) == 0,
		str(_ext.get_ideology_effect_instance_report(_handle)))
	var restored_agriculture := _wait_factor(
		_border_cell, AGRICULTURE_STAT, 1.0, 12)
	var restored_birth := _wait_factor(_border_cell, BIRTH_STAT, 1.0, 12)
	_expect("unequipping frontier_garrison restores agriculture "
			+ "(got %.5f)" % restored_agriculture,
		_is_close(restored_agriculture, 1.0, 0.0005),
		"%.5f" % restored_agriculture)
	_expect("unequipping frontier_garrison restores birth (got %.5f)"
			% restored_birth, _is_close(restored_birth, 1.0, 0.0005),
		"%.5f" % restored_birth)
	var unrelated_before := int(_ext.get_ideology_report().get(
		"instance_refresh_visits", -1))
	for _day in range(3):
		_tick = _drive_days(1)
	var unrelated_after := int(_ext.get_ideology_report().get(
		"instance_refresh_visits", -1))
	_expect("an unequipped card leaves no unrelated refresh visits",
		unrelated_after == unrelated_before,
		"%d -> %d" % [unrelated_before, unrelated_after])


## The territory hash and canal topology are both stable here. The geometry
## rebuild counter is the direct, cheap evidence that no day repeated the work;
## the ideology refresh counter is the consumer-side no-op evidence.
func _test_idle_geo_reuse() -> void:
	var economy_before: Dictionary = _ext.get_economy_report()
	var rebuilds_before := int(economy_before.get("geo_flags_rebuilds", -1))
	var geo_revision_before := _metric_revision(METRIC_GEO_FLAGS)
	var ideology_before: Dictionary = _ext.get_ideology_report()
	var visits_before := int(ideology_before.get("instance_refresh_visits", -1))
	for _day in range(30):
		_tick = _drive_days(1)
	var economy_after: Dictionary = _ext.get_economy_report()
	var ideology_after: Dictionary = _ext.get_ideology_report()
	var rebuilds_after := int(economy_after.get("geo_flags_rebuilds", -1))
	var visits_after := int(ideology_after.get("instance_refresh_visits", -1))
	_expect("30 unchanged days rebuild metric 75/76 zero times (%d -> %d)" % [
			rebuilds_before, rebuilds_after], rebuilds_after == rebuilds_before,
		"%d -> %d" % [rebuilds_before, rebuilds_after])
	_expect("metric 75 revision is unchanged across the idle window",
		_metric_revision(METRIC_GEO_FLAGS) == geo_revision_before,
		"%d -> %d" % [geo_revision_before, _metric_revision(METRIC_GEO_FLAGS)])
	_expect("unrelated cards receive zero refresh visits across idle days",
		visits_after == visits_before, "%d -> %d" % [visits_before, visits_after])


func _border_claim_pair() -> PackedInt32Array:
	var current_map: MapData = _host.get_current_map()
	if current_map == null:
		return PackedInt32Array()
	for cell in range(WIDTH * HEIGHT):
		if _cell_handle(cell) == _handle and \
				int(current_map.is_water_arr[cell]) == 0 and \
				(_metric(METRIC_GEO_FLAGS, cell) & GEO_BORDER) == 0:
			for neighbor in _neighbors(cell):
				if _cell_handle(neighbor) != 0 or \
						int(current_map.is_water_arr[neighbor]) != 0:
					continue
				return PackedInt32Array([cell, neighbor])
	_stage("no neutral land cell is adjacent to player territory")
	return PackedInt32Array()


## Direct canal domain fixture: a three-cell land chain beside an ocean cell.
## Cell 0 owns a river, cell 1 supplies the second route endpoint, and cell 2
## is water so the synchronous built-in canal transaction can commit.
func _build_canal_world() -> Dictionary:
	const CELLS := 3
	var map := MapData.new(3, 2)
	for cell_index in CELLS:
		var cell := HexCell.new(cell_index, 0)
		cell.terrain = TerrainType.TERRAIN.PLAIN
		cell.landform = LandformType.LF.PLAIN
		cell.elevation = 0.50
		cell.base_moisture = 0.10
		cell.moisture = 0.10
		if cell_index == 0:
			cell.has_river = true
			cell.river_flow = 1.0
		map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	var neighbors := PackedInt32Array([1, -1, -1, -1, -1, -1,
		-1, 2, -1, 0, -1, -1, -1, -1, -1, -1, 1, -1])
	var terrain := PackedByteArray([2, 2, 0])
	var landform := PackedByteArray([0, 0, 0])
	var river := PackedByteArray([1, 0, 0])
	var water := PackedByteArray([0, 0, 1])
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null or not bool(ext.bind_map_data(map)):
		_stage("direct canal world could not bind its map")
		return {}
	var economy_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(economy_catalog.get("ok", false)):
		return {}
	economy_catalog.erase("ok")
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": economy_catalog.technology_ids,
	}
	if not bool(ext.configure_country(economy_catalog, country_profile, CELLS, SEED).get(
			"ok", false)):
		return {}
	var technology_indices := PackedInt32Array()
	technology_indices.resize(
		(economy_catalog.technology_ids as PackedStringArray).size())
	for index in technology_indices.size():
		technology_indices[index] = index
	var goods: PackedStringArray = economy_catalog.good_ids
	var lumber := goods.find("lumber")
	var bricks := goods.find("bricks")
	if not bool(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.x12_canal_test"]),
		"country_names": PackedStringArray(["X12 Canal"]),
		"country_cash": PackedInt64Array([1000000000]),
		"territory_offsets": PackedInt32Array([0, 2]),
		"territory_cells": PackedInt32Array([0, 1]),
		"technology_offsets": PackedInt32Array([0, technology_indices.size()]),
		"technology_indices": technology_indices,
		"treasury_offsets": PackedInt32Array([0, 2]),
		"treasury_good_indices": PackedInt32Array([lumber, bricks]),
		"treasury_quantities": PackedInt64Array([1000000, 1000000]),
	}, water).get("ok", false)):
		return {}
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.family_runtime_mode = "OFF"
	profile.notable_person_runtime_mode = "OFF"
	profile.market_cycle_days = 1
	if not bool(ext.configure_economy(economy_catalog, profile, CELLS, SEED).get(
			"ok", false)):
		return {}
	var passable := PackedByteArray()
	var costs := PackedInt32Array()
	passable.resize(256)
	costs.resize(256)
	passable[2] = 1
	costs[2] = 1
	if not bool(ext.capture_economy_trade_topology(
			neighbors, terrain, passable, costs, 1, landform, river).get(
				"ok", false)):
		return {}
	var signatures: PackedStringArray = economy_catalog.signature_keys
	var forager := signatures.find("forager|default")
	var stock := PackedInt64Array()
	stock.resize(CELLS * goods.size())
	stock.fill(1000000)
	if not bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([forager]),
		"population": PackedInt64Array([10]),
		"funds": PackedInt64Array([1000000]),
	}, {"stock": stock}).get("ok", false)):
		return {}
	# configure_country() ran before configure_economy(), so the first epoch has
	# no ownership column until one explicit day commits. Tag scans fail closed
	# (empty) on that pre-epoch shape; settle day zero before any query.
	var bootstrap_day := _run_direct_day(ext, 0)
	if not _require("direct canal day zero captures country ownership",
			bool(bootstrap_day.get("done", false))
				and ext.get_economy_report().get("current_day", -1) == 0,
			str(bootstrap_day)):
		return {}
	var domain: Resource = preload(
		"res://scripts/effect/effect_domain_catalog.gd").build()
	var effects: Dictionary = ext.configure_effects(domain.compile_native_catalog())
	if not _require("direct canal Effect catalog configures",
			bool(effects.get("ok", false)), str(effects)):
		return {}
	var day_zero := _run_direct_day(ext, 0)
	if not _require("direct canal day zero captures topology",
			bool(day_zero.get("done", false)), str(day_zero)):
		return {}
	return {"ext": ext, "map": map, "start": 0, "end": 1, "direction": 0,
		"handle": int(ext.get_country_cell_summary(0).get(
			"country_handle", 0))}


func _run_direct_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({
			"day_index": day, "tick_index": day * 1000 + slice,
		})
		if bool(report.get("done", false)):
			break
	return report


func _foreign_handle() -> int:
	for cell in range(WIDTH * HEIGHT):
		var cell_handle := _cell_handle(cell)
		if cell_handle != 0 and cell_handle != _handle:
			return cell_handle
	return 0


func _claim_neutral_cell(cell: int) -> bool:
	if _generator == null:
		return false
	var facade = _generator.get_country_facade()
	if facade == null:
		return false
	var sequence := 820000 + cell
	var rows: Array[Dictionary] = [{
		"opcode": CountryFacadeScript.Opcode.CLAIM_UNOWNED_TERRITORY,
		"target_handle": _handle, "cell": cell,
		"effective_day": _tick + 1, "sequence": sequence,
	}]
	var submitted: Dictionary = facade.submit(rows)
	if not bool(submitted.get("ok", false)):
		_stage("claim rejected: %s" % str(submitted))
		return false
	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline:
		_tick = _drive_days(1)
		if _cell_handle(cell) == _handle:
			return true
		var report: Dictionary = _ext.get_runtime_thread_report()
		if String(report.get("simulation_host_state", "")) in [
				"STOPPED", "FAULTED"]:
			return false
	return false


func _transfer_foreign_cell(cell: int, foreign_handle: int) -> bool:
	var facade = _generator.get_country_facade()
	if facade == null:
		return false
	var submitted: Dictionary = facade.transfer_territory(
		cell, foreign_handle, _tick + 1, 830000 + cell)
	if not bool(submitted.get("ok", false)):
		_stage("foreign transfer rejected: %s" % str(submitted))
		return false
	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline:
		_tick = _drive_days(1)
		if _cell_handle(cell) == foreign_handle:
			return true
		var report: Dictionary = _ext.get_runtime_thread_report()
		if String(report.get("simulation_host_state", "")) in [
				"STOPPED", "FAULTED"]:
			return false
	return false


func _neighbors(cell: int) -> PackedInt32Array:
	return _ext.query_effect_target_cells(
		cell, SEL_NEIGHBORS_R1, 32, 0)


func _cell_handle(cell: int) -> int:
	return int(_ext.get_country_cell_summary(cell).get("country_handle", 0))


func _tagged_cells(tag: int) -> PackedInt32Array:
	var anchor := int(_ext.query_country_anchor_cell(_country_slot))
	if anchor < 0:
		return PackedInt32Array()
	return _ext.query_effect_target_cells(
		anchor, SEL_OWN_TERRITORY, 32, tag + 1)


func _tag_id(tag_name: String) -> int:
	var domain: Resource = preload(
		"res://scripts/effect/effect_domain_catalog.gd").build()
	if domain == null:
		return -1
	var tags: Array = domain.target_tags
	for index in tags.size():
		if String((tags[index] as Dictionary).get("name", "")) == tag_name:
			return index
	return -1


func _metric(metric_id: int, cell: int) -> int:
	var result: Dictionary = _ext.sample_effect_metric_probe(
		metric_id, cell, _handle)
	if not bool(result.get("ok", false)):
		_fail("metric %d probe failed: %s" % [metric_id,
			str(result.get("reason", "unknown"))])
		return -1
	return int(result.get("value", -1))


func _metric_revision(metric_id: int) -> int:
	var values: PackedInt64Array = _ext.get_effect_input_revisions().get(
		"metrics", PackedInt64Array())
	return int(values[metric_id]) if metric_id < values.size() else -1


func _factor(cell: int, stat_key: String) -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_ECONOMY, 0, cell, stat_key, 1.0))


func _wait_factor(cell: int, stat_key: String, expected: float,
		days: int) -> float:
	var value := _factor(cell, stat_key)
	for _day in range(days):
		_tick = _drive_days(1)
		value = _factor(cell, stat_key)
		if _is_close(value, expected, 0.0005):
			return value
	return value


func _build_world() -> Dictionary:
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
	host.runtime_economy_auto_pod_active = true
	# GAMEPLAY_EFFECT's ACTIVE worker only admits event-publish packets. Keep
	# Economy/Effect/Modifier/Country worker-owned while the built-in canal
	# action uses its existing synchronous commit seam.
	host.runtime_authority_domain_mask = 0xF7F
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "C0 X12"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("x12 session configures", bool(session.get("ok", false)),
			str(session)):
		return {}
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("production world generation succeeded", generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("production DCWorldExt is bound", ext != null):
		return {}
	_host = host
	_clock = clock
	_ext = ext
	_generator = generator
	ext.set_runtime_ideology_parity_enabled(true)
	ext.set_runtime_clock(true, WORKER_SPEED)
	if not _require("worker reaches a paused boundary",
			_wait_worker_paused(ext)):
		return {}
	var handle := 0
	var country_slot := 0
	for cell in range(WIDTH * HEIGHT):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) != 0:
			handle = int(summary.get("country_handle", 0))
			country_slot = int(summary.get("country_slot", 0))
			break
	if not _require("worker path resolves the player country", handle != 0):
		return {}
	_tick = _world_day(ext)
	_tick = _drive_days(3)
	return {"host": host, "clock": clock, "ext": ext, "generator": generator,
		"handle": handle, "country_slot": country_slot, "tick": _tick}


func _teardown() -> void:
	if _ext != null and _ext.has_method("request_runtime_stop"):
		_ext.request_runtime_stop()


func _drive_days(days: int) -> int:
	for _day in range(days):
		_tick += 1
		_clock.current_day = float(_tick)
		_host.run_daily_tick(_tick, _clock.season_phase_for_day(_tick))
		_host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier() and pulses < 400:
			_clock.simulation_backpressure_pulse.emit(_tick)
			pulses += 1
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		if _ext.has_method("publish_ideology_worker_inputs"):
			_ext.publish_ideology_worker_inputs()
		_ext.set_runtime_clock(false, WORKER_SPEED)
		var before := int(_ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		_wait_pod_day(before, 2000)
		_ext.set_runtime_clock(true, WORKER_SPEED)
	return _tick


func _equip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		_fail("%s absent from the compiled catalog" % card)
		return false
	var gates: Dictionary = IdeologyDrawGateHelper.grant_draw_gates(
		_host, card, _handle, _tick, _next_sequence)
	if not _require("%s: worker grants its draw gates" % card,
			bool(gates.get("ok", false)), str(gates)):
		return false
	_next_sequence = maxi(_next_sequence, int(gates.get(
		"next_sequence", _next_sequence)))
	_tick = _drive_days(1)
	var discovered: Dictionary = _submit([{
		"op": 1, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts discover" % card,
			bool(discovered.get("ok", false)), str(discovered)):
		return false
	_tick = _drive_days(3)
	var equipped: Dictionary = _submit([{
		"op": 5, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts equip" % card,
			bool(equipped.get("ok", false)), str(equipped)):
		return false
	_tick = _drive_days(8)
	var slots := 0
	for _day in range(12):
		slots = int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1))
		if slots >= 1:
			break
		_tick = _drive_days(1)
	return _require("%s: the card occupies a slot (slots=%d)" % [card, slots],
		slots >= 1, str(slots))


func _unequip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		return false
	var result: Dictionary = _submit([{
		"op": 6, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts unequip" % card,
			bool(result.get("ok", false)), str(result)):
		return false
	_tick = _drive_days(3)
	for _day in range(12):
		if int(_ext.get_ideology_snapshot(_handle).get(
				"ideology_slots_used", -1)) == 0:
			return true
		_tick = _drive_days(1)
	return _require("%s: unequip releases the slot" % card, false,
		str(_ext.get_ideology_snapshot(_handle)))


func _submit(rows: Array) -> Dictionary:
	return _ext.submit_ideology_commands(_commands(rows))


func _has_technology(technology_id: String) -> bool:
	var snapshot: Dictionary = _ext.get_country_snapshot(_handle)
	return (snapshot.get("technology_ids", PackedStringArray()) as PackedStringArray
		).has(technology_id)


func _grant_technology(technology_id: String) -> bool:
	var facade = _generator.get_country_facade()
	if facade == null:
		_stage("country facade unavailable for canal technology")
		return false
	var result: Dictionary = facade.grant_technology(
		_handle, StringName(technology_id), _tick + 1, _next_sequence)
	if not _require("canal fixture grants %s" % technology_id,
			bool(result.get("ok", false)), str(result)):
		return false
	_next_sequence += 1
	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline:
		_tick = _drive_days(1)
		if _has_technology(technology_id):
			return true
	return _require("canal technology becomes visible to Economy", false,
		str(_ext.get_country_snapshot(_handle)))


func _commands(rows: Array) -> Dictionary:
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var producer := PackedInt32Array()
	var sequences := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	for row in rows:
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", 0)))
		producer.append(1)
		sequences.append(_next_sequence)
		_next_sequence += 1
		handles.append(int(row.get("handle", 0)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return {
		"opcodes": opcodes, "effective_days": days, "producer_ids": producer,
		"sequences": sequences, "country_handles": handles, "ideology_ids": ideas,
		"values_q16": values, "source_priorities": priorities,
		"offer_generations": generations, "choice_indices": choices,
		"gate_ids": gates,
	}


func _dense_id(card: String) -> int:
	var catalog: Resource = load("res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return -1
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	if not bool(native.get("ok", false)):
		_fail("ideology catalog compile failed: %s" % String(
			native.get("reason", "unknown")))
		return -1
	var ids := PackedStringArray(native.get("ideology_ids", PackedStringArray()))
	return ids.find("idea.%s" % card)


func _has_hard_barrier() -> bool:
	return bool(_clock.has_hard_barrier()) if _clock.has_method("has_hard_barrier") \
		else false


func _wait_pod_day(baseline: int, timeout_msec: int) -> int:
	var deadline := Time.get_ticks_msec() + timeout_msec
	var reached := baseline
	while Time.get_ticks_msec() < deadline:
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(2)
		var report: Dictionary = _ext.get_runtime_thread_report()
		reached = int(report.get("ideology_pod_committed_day", -1))
		if reached > baseline:
			return reached
		if String(report.get("simulation_host_state", "")) in [
				"STOPPED", "FAULTED"]:
			return reached
	return reached


func _wait_worker_paused(ext: Object) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var state := String(ext.get_runtime_thread_report().get(
			"simulation_host_state", ""))
		if state == "PAUSED":
			return true
		if state in ["STOPPED", "FAULTED"]:
			return false
		OS.delay_msec(2)
	return false


func _world_day(ext: Object) -> int:
	if ext == null or not ext.has_method("get_economy_report"):
		return 0
	return int(ext.get_economy_report().get("current_day", 0))


func _is_close(a: float, b: float, tolerance: float) -> bool:
	return absf(a - b) <= tolerance


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	printerr("ERROR: [FAIL] %s%s" % [label,
		(" (%s)" % detail) if not detail.is_empty() else ""])


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _stage(text: String) -> void:
	print("[stage] %s" % text)


func _fail(reason: String) -> void:
	_failures += 1
	printerr("ERROR: [FAIL] %s" % reason)
