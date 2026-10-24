extends SceneTree

## X1-b T9: iron_smelting through the production worker path.
##
## The synthetic selector test owns the per-cell arithmetic. This fixture owns the
## remaining seam: the generated catalog -> POD metadata -> worker EFFECT/Modifier
## stages -> `magnitude_scale_q16` -> the cell Modifier table.

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261023
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const MODIFIER_DOMAIN_ECONOMY := 2
const METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID := 45
const SEL_NEIGHBORS_R1 := 6
const STAT_KEY := "economy.city.building.manufacturing_output_factor"
const SOURCE_TAG := "cell.produces.iron_ore"
const PER_SOURCE := 0.10
const COUNT_CAP := 3

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _handle := 0
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _tick := 0
var _source_cell := -1


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology x1b worker: %d checks, %d failures ===" % [
		_checks, _failures])
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
	_handle = int(fixture["handle"])
	_tick = int(fixture["tick"])
	_test_iron_smelting()
	_teardown()
	return 0


func _test_iron_smelting() -> void:
	var tag_id := _source_tag_id()
	if not _require("T9 the iron-ore output tag is in the production Effect catalog",
			tag_id >= 0, str(tag_id)):
		return
	var packed := _published_iron_smelting_selector()
	if not _require("T9 iron_smelting L1 is published as a kind-16 program",
			not packed.is_empty(), str(packed)):
		return
	var l2_radius := _published_iron_smelting_l2_radius()
	_expect("T9 iron_smelting L2 publishes radius 2 (got %d)" % l2_radius,
		l2_radius == 2, str(l2_radius))
	var sources := _owned_sources(tag_id)
	if not _require("T9 the generated world owns at least one iron-producing source",
			not sources.is_empty(), "tag_id=%d" % tag_id):
		_stage("the starter world has no player-owned cell.produces.iron_ore cell; "
			+ "kind-16 has no production source to scale")
		return
	var target := _best_target(sources)
	if not _require("T9 an iron source reaches a neighbouring target", target >= 0,
			str(target)):
		return
	var expected_count := _source_count(sources, target)
	if not _require("T9 the chosen target has a positive source count",
			expected_count > 0, "target=%d count=%d" % [target, expected_count]):
		return
	var expected := 1.0 + PER_SOURCE * float(mini(expected_count, COUNT_CAP))
	var baseline := _read_cell(target)
	_expect("T9 the target starts at the unmodified cell value (got %.5f)" % baseline,
		_is_close(baseline, 1.0, 0.001), "%.5f" % baseline)
	if not _equip():
		return
	var deadline := Time.get_ticks_msec() + 20000
	var evaluations := 0
	var actual := baseline
	while Time.get_ticks_msec() < deadline:
		evaluations = int(_ext.get_ideology_report().get(
			"source_count_evaluations", 0))
		actual = _read_cell(target)
		if evaluations > 0 and not _is_close(actual, baseline, 0.0001):
			break
		_tick = _drive_days(1)
	_stage("iron_smelting: source_count_evaluations=%d target=%d count=%d "
		% [evaluations, target, expected_count] + "actual=%.5f expected=%.5f"
		% [actual, expected])
	_expect("T9 the worker evaluated kind-16 source counts",
		evaluations > 0, str(evaluations))
	_expect("T9 the target applies per-source stacking (count=%d, got %.5f)"
			% [expected_count, actual], _is_close(actual, expected, 0.001),
		"expected=%.5f actual=%.5f" % [expected, actual])
	if expected_count < 2:
		_stage("the production fixture exposes only one iron source for this target; "
			+ "the synthetic fixture owns the multi-source arithmetic")
	if not _unequip():
		return
	# Unequip settles asynchronously: the managed Effect instance must emit its
	# retirement REMOVE and the Modifier stage must apply it before the cell row
	# disappears. Drive real worker days until that state is reached.
	var restore_deadline := Time.get_ticks_msec() + 20000
	var restored := _read_cell(target)
	while Time.get_ticks_msec() < restore_deadline:
		restored = _read_cell(target)
		if _is_close(restored, 1.0, 0.001):
			break
		_tick = _drive_days(1)
	_expect("T9 unequipping iron_smelting restores the target (got %.5f)" % restored,
		_is_close(restored, 1.0, 0.001), "%.5f" % restored)


func _source_tag_id() -> int:
	var domain: Resource = EffectDomainCatalogScript.build()
	if domain == null:
		return -1
	var tags: Array = domain.target_tags
	for index in tags.size():
		if String((tags[index] as Dictionary).get("name", "")) == SOURCE_TAG:
			return index
	return -1


## The generated .tres is the publication truth. The definition is authored in the
## generator, but this fixture must prove that the artifact the worker loads carries
## kind 16 (rather than the old kind-14 row).
func _published_iron_smelting_selector() -> PackedInt32Array:
	var catalog: Resource = load("res://data/ideologies/default_ideology_effects.tres")
	if catalog == null:
		return PackedInt32Array()
	for definition in catalog.effects:
		if definition == null:
			continue
		var program_key := String(definition.program_key())
		if program_key != "iron_smelting_l1" \
				and String(definition.definition_key) != "iron_smelting_l1":
			continue
		if int(definition.get("target_selector_kind")) != 16:
			return PackedInt32Array()
		return PackedInt32Array(definition.get("target_selector_param"))
	return PackedInt32Array()


## Kind 16 packs target_cap, radius and source cap into operand 0. Decode with
## the authoring definition's own mask/shift contract instead of assuming byte
## order. Read the L2 row independently of L1 so an L1-only regression fails.
func _published_iron_smelting_l2_radius() -> int:
	var catalog: Resource = load("res://data/ideologies/default_ideology_effects.tres")
	if catalog == null:
		return -1
	for definition in catalog.effects:
		if definition == null:
			continue
		var program_key := String(definition.program_key())
		if program_key != "iron_smelting_l2" \
				and String(definition.definition_key) != "iron_smelting_l2":
			continue
		if int(definition.get("target_selector_kind")) != 16:
			return -1
		var decoded: Dictionary = definition.unpack_source_count(
			PackedInt32Array(definition.get("target_selector_param")))
		return int(decoded.get("radius", -1))
	return -1


func _owned_sources(tag_id: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var anchor := int(_ext.query_country_anchor_cell(_country_slot()))
	if anchor < 0:
		return out
	for cell in _ext.query_effect_target_cells(anchor, 12, 32, tag_id + 1):
		var summary: Dictionary = _ext.get_country_cell_summary(int(cell))
		if int(summary.get("country_handle", 0)) == _handle:
			out.append(int(cell))
	return out


func _country_slot() -> int:
	for cell in range(WIDTH * HEIGHT):
		var summary: Dictionary = _ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) == _handle:
			return int(summary.get("country_slot", 0))
	return 0


func _source_count(sources: PackedInt32Array, target: int) -> int:
	var count := 0
	for source in sources:
		if int(source) == target:
			continue
		var ring: PackedInt32Array = _ext.query_effect_target_cells(
			int(source), SEL_NEIGHBORS_R1, 32, 0)
		if ring.has(target):
			count += 1
	return count


func _best_target(sources: PackedInt32Array) -> int:
	var best := -1
	var best_count := 0
	for source in sources:
		var ring: PackedInt32Array = _ext.query_effect_target_cells(
			int(source), SEL_NEIGHBORS_R1, 32, 0)
		for cell in ring:
			var candidate := int(cell)
			var summary: Dictionary = _ext.get_country_cell_summary(candidate)
			if int(summary.get("country_handle", 0)) != _handle:
				continue
			var count := _source_count(sources, candidate)
			if count > best_count:
				best = candidate
				best_count = count
	return best


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
	host.runtime_authority_domain_mask = 0xFFF
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "C0 X1b"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("T9 session configures", bool(session.get("ok", false)),
			str(session)):
		return {}
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("T9 production world generation succeeded", generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("T9 production DCWorldExt is bound", ext != null):
		return {}
	_host = host
	_clock = clock
	_ext = ext
	var handle := 0
	var country_slot := 0
	for cell in range(WIDTH * HEIGHT):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		handle = int(summary.get("country_handle", 0))
		if handle != 0:
			country_slot = int(summary.get("country_slot", 0))
			break
	if not _require("T9 worker path resolves the player country", handle != 0):
		return {}
	_handle = handle
	ext.set_runtime_clock(true, WORKER_SPEED)
	_wait_worker_paused(ext)
	_tick = _world_day(ext)
	_tick = _drive_days(3)
	if not _require("T9 fixture owns a neighbouring source and target",
			_claim_neighboring_cell(generator, ext, handle, country_slot)):
		return {}
	_source_cell = _find_owned_land_source(ext)
	if not _require("T9 fixture has an owned source cell for the iron-output tag",
			_source_cell >= 0, str(_source_cell)):
		return {}
	if not _require("T9 fixture exposes the iron-output tag at the source cell",
			_set_iron_output_tag(ext), "cell=%d iron_ore" % _source_cell):
		return {}
	# The override is sampled by Economy when it commits an epoch. Drive one day
	# before querying the published tag bitset; otherwise the query still sees the
	# pre-override snapshot even though the test override was accepted.
	_tick = _drive_days(1)
	return {"host": host, "clock": clock, "ext": ext, "handle": handle,
		"tick": _tick}


## T9 needs an economy-owned tag without manufacturing a building output in the
## fixture. The test-only metric override is applied at sample_effect_metrics(),
## which is the same point the epoch tag bitset reads.
func _set_iron_output_tag(ext: Object) -> bool:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		return false
	var goods: PackedStringArray = catalog.get(
		"good_ids", PackedStringArray())
	var iron := goods.find("iron_ore")
	if iron < 0:
		return false
	var applied: Dictionary = ext.set_effect_metric_override_for_test(
		METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID, iron * Q16_ONE, true)
	return bool(applied.get("ok", false))


func _find_owned_land_source(ext: Object) -> int:
	var current_map: MapData = _host.get_current_map()
	if current_map == null:
		return -1
	for cell in range(WIDTH * HEIGHT):
		if int(current_map.is_water_arr[cell]) != 0:
			continue
		if int(ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) == _handle:
			return cell
	return -1


## The starter world founds the player on one cell. Claim an adjacent neutral
## cell (or transfer an adjacent foreign starter cell) so the source does not
## count itself and there is a distinct own-country target.
func _claim_neighboring_cell(generator: MapGenerator, ext: Object,
		handle: int, country_slot: int) -> bool:
	var owned_cells := PackedInt32Array()
	for cell in range(WIDTH * HEIGHT):
		if int(ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) == handle:
			owned_cells.append(cell)
	var current_map: MapData = _host.get_current_map()
	if current_map == null:
		return false
	var neutral_cells := PackedInt32Array()
	var foreign_cells := PackedInt32Array()
	for source in owned_cells:
		for cell in ext.query_effect_target_cells(
				int(source), SEL_NEIGHBORS_R1, 32, 0):
			var candidate := int(cell)
			if owned_cells.has(candidate) \
					or int(current_map.is_water_arr[candidate]) != 0:
				continue
			var candidate_handle := int(ext.get_country_cell_summary(
				candidate).get("country_handle", 0))
			if candidate_handle == 0:
				if not neutral_cells.has(candidate):
					neutral_cells.append(candidate)
			elif candidate_handle != handle \
					and not foreign_cells.has(candidate):
				foreign_cells.append(candidate)
	var facade = generator.get_country_facade()
	if facade == null:
		return false
	for cell in neutral_cells:
		var sequence := 800000 + cell
		var rows: Array[Dictionary] = [{
				"opcode": CountryFacadeScript.Opcode.CLAIM_UNOWNED_TERRITORY,
				"target_handle": handle, "cell": cell,
				"effective_day": _tick + 1, "sequence": sequence,
			}]
		var submitted: Dictionary = facade.submit(rows)
		if not bool(submitted.get("ok", false)):
			continue
		if _wait_for_country_commit(ext, cell, handle):
			return true
	for cell in foreign_cells:
		var sequence := 810000 + cell
		var submitted: Dictionary = facade.transfer_territory(
			cell, handle, _tick + 1, sequence)
		if not bool(submitted.get("ok", false)):
			continue
		if _wait_for_country_commit(ext, cell, handle):
			return true
	_stage("no adjacent land claim or transfer committed "
		+ "(country_slot=%d neutral=%d foreign=%d)" % [
			country_slot, neutral_cells.size(), foreign_cells.size()])
	return false


func _wait_for_country_commit(ext: Object, cell: int, handle: int) -> bool:
	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline:
		_tick += 1
		_clock.current_day = float(_tick)
		_host.run_daily_tick(_tick, _clock.season_phase_for_day(_tick))
		_host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier() and pulses < 400:
			_clock.simulation_backpressure_pulse.emit(_tick)
			pulses += 1
		if ext.has_method("service_country_worker_peer_adapter"):
			ext.service_country_worker_peer_adapter(64, true)
		if int(ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) == handle:
			return true
		var report: Dictionary = ext.get_runtime_thread_report()
		if String(report.get("simulation_host_state", "")) in [
				"STOPPED", "FAULTED"]:
			return false
		OS.delay_msec(2)
	return false


func _teardown() -> void:
	if _ext != null and _ext.has_method("request_runtime_stop"):
		_ext.request_runtime_stop()


func _equip() -> bool:
	var dense := _dense_id("iron_smelting")
	if dense < 0:
		_fail("T9 iron_smelting is absent from the compiled catalog")
		return false
	_grant_draw_gates("iron_smelting", _tick)
	var discovered: Dictionary = _submit([{"op": 1, "day": _tick, "handle": _handle,
		"idea": dense}])
	if not _require("T9 worker accepts discover", bool(discovered.get("ok", false)),
			str(discovered)):
		return false
	_tick = _drive_days(2)
	var equipped: Dictionary = _submit([{"op": 5, "day": _tick, "handle": _handle,
		"idea": dense}])
	if not _require("T9 worker accepts equip", bool(equipped.get("ok", false)),
			str(equipped)):
		return false
	_tick = _drive_days(3)
	var deadline := Time.get_ticks_msec() + 20000
	var slots := -1
	while Time.get_ticks_msec() < deadline:
		slots = int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1))
		if slots >= 1:
			return true
		_tick = _drive_days(1)
	if _ext.has_method("poll_ideology_receipts"):
		printerr("[x1b-equip] receipts=%s" % str(
			_ext.poll_ideology_receipts(0, 32)))
	_fail("T9 iron_smelting did not occupy a slot (slots=%d)" % slots)
	return false


func _unequip() -> bool:
	var dense := _dense_id("iron_smelting")
	if dense < 0:
		return false
	var result: Dictionary = _submit([{"op": 6, "day": _tick, "handle": _handle,
		"idea": dense}])
	if not _require("T9 worker accepts unequip", bool(result.get("ok", false)),
			str(result)):
		return false
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
		if int(snapshot.get("ideology_slots_used", -1)) == 0:
			_tick = _drive_days(1)
			return true
		_tick = _drive_days(1)
	if _ext.has_method("poll_ideology_receipts"):
		printerr("[x1b-unequip] receipts=%s" % str(
			_ext.poll_ideology_receipts(0, 32)))
	return _require("T9 iron_smelting releases its slot", false,
		str(_ext.get_ideology_snapshot(_handle)))


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
		var deadline := Time.get_ticks_msec() + 2000
		while Time.get_ticks_msec() < deadline:
			if _ext.has_method("service_country_worker_peer_adapter"):
				_ext.service_country_worker_peer_adapter(64, true)
			OS.delay_msec(2)
			if int(_ext.get_runtime_thread_report().get(
					"ideology_pod_committed_day", -1)) > before:
				break
		_ext.set_runtime_clock(true, WORKER_SPEED)
		_wait_worker_paused(_ext)
	return _tick


func _submit(rows: Array) -> Dictionary:
	return _ext.submit_ideology_commands(_commands(rows))


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
		_fail("T9 ideology catalog compile failed: %s" % String(
			native.get("reason", "unknown")))
		return -1
	var ids := PackedStringArray(native.get("ideology_ids", PackedStringArray()))
	return ids.find("idea.%s" % card)


func _grant_draw_gates(card_id: String, day: int) -> void:
	var catalog: Resource = load("res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return
	var definition: Resource = null
	for row in catalog.definitions:
		if row == null:
			continue
		var row_id := String(row.id)
		if row_id == card_id or row_id == "idea.%s" % card_id:
			definition = row
			break
	if definition == null:
		return
	var generator: MapGenerator = _host.get_generator() \
		if _host.has_method("get_generator") else null
	if generator == null or not generator.has_method("get_country_facade"):
		return
	var facade = generator.get_country_facade()
	if facade == null:
		return
	var sequence := 900000
	for requirement in definition.draw_requirements:
		if requirement == null:
			continue
		var key := String(requirement.key)
		if int(requirement.kind) == 1:
			facade.grant_technology(_handle, StringName(key), day, sequence)
			sequence += 1
		elif int(requirement.kind) == 2:
			facade.discover_research_signal(
				_handle, StringName(key), 0, 0, day, sequence)
			sequence += 1


func _read_cell(cell: int) -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_ECONOMY, 0, cell, STAT_KEY, 1.0))


func _has_hard_barrier() -> bool:
	return bool(_clock.has_hard_barrier()) if _clock.has_method("has_hard_barrier") \
		else false


func _wait_worker_paused(ext: Object) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var state := String(ext.get_runtime_thread_report().get(
			"simulation_host_state", ""))
		if state == "PAUSED" or state == "STOPPED":
			return
		OS.delay_msec(2)


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
