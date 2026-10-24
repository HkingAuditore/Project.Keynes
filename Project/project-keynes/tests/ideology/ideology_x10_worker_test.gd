extends SceneTree

## X10 acceptance on the production worker path.
##
## The fixture verifies metrics 79..83 against the frozen Country technology
## bitset, checks the five production metric keys, grants a real technology
## above index 63 through CountryFacade, and drives a test-only local card mapped
## to the generated `v10_technology_gate` program. The fixture installs that card
## in the cached default catalog before world generation, so the production
## worker configures normally. Thirty unchanged days must rebuild the counts zero
## times and leave unrelated ideology cards at zero refresh visits.
##
## Run:
##   godot --headless --path Project/project-keynes \
##     --script res://tests/ideology/ideology_x10_worker_test.gd

const WIDTH := 12
const HEIGHT := 10
const SEED := 20261024
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const MODIFIER_DOMAIN_ECONOMY := 2
const METRIC_COMPLETED_TECH := 79
const METRIC_TECH_DOMAIN_0 := 80
const METRIC_TECH_DOMAIN_1 := 81
const METRIC_TECH_DOMAIN_2 := 82
const METRIC_TECH_DOMAIN_3 := 83
const DOMAIN_AGRICULTURE := 0
const DOMAIN_ENGINEERING := 1
const DOMAIN_SCIENCE := 2
const DOMAIN_SOCIETY := 3
const AGRICULTURE_STAT := "economy.city.building.agriculture_output_factor"
const LOCAL_CARD := "x10_worker_vehicle"
const LOCAL_PROGRAM := "v10_technology_gate"
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyDefinitionScript = preload(
	"res://scripts/ideology/ideology_definition.gd")
const IdeologyLevelDefinitionScript = preload(
	"res://scripts/ideology/ideology_level_definition.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectDomainCatalogScript = preload(
	"res://scripts/effect/effect_domain_catalog.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _generator: MapGenerator
var _handle := 0
var _country_slot := 0
var _anchor := -1
var _catalog: Dictionary
var _test_ideology_catalog: Resource
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _tick := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology x10 worker: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	_test_ideology_catalog = _install_local_card()
	if _test_ideology_catalog == null:
		return 1
	_catalog = EconomyCatalogScript.compile_native_catalog()
	if not _require("economy catalog compiles", bool(_catalog.get("ok", false)),
			str(_catalog.get("reason", ""))):
		return 1
	_catalog.erase("ok")
	var fixture := await _build_world()
	if fixture.is_empty():
		return 1
	_host = fixture["host"]
	_clock = fixture["clock"]
	_ext = fixture["ext"]
	_generator = fixture["generator"]
	_handle = int(fixture["handle"])
	_country_slot = int(fixture["country_slot"])
	_anchor = int(fixture["anchor"])
	_tick = int(fixture["tick"])
	if not _test_exact_counts_and_real_grant():
		_teardown()
		return 1
	if not _test_program_toggle():
		_teardown()
		return 1
	_test_idle_reuse()
	_ext.clear_country_technology_metric_input_for_test()
	_teardown()
	return 0


## The real Country snapshot and the five derived columns must agree exactly.
## Granting `tech.composite_tools` (dense index 64, engineering) is a real
## Country command and therefore also proves the second 64-bit word is included.
func _test_exact_counts_and_real_grant() -> bool:
	var keys := _metric_keys()
	if not _require("the production metric table has five X10 keys",
			keys.size() > METRIC_TECH_DOMAIN_3,
			"keys=%d" % keys.size()):
		return false
	_expect("metric 79 is country.completed_tech_count",
		String(keys[METRIC_COMPLETED_TECH]) == "country.completed_tech_count",
		String(keys[METRIC_COMPLETED_TECH]))
	for domain in 4:
		_expect("metric %d is the %s domain count" % [
				METRIC_TECH_DOMAIN_0 + domain, keys[METRIC_TECH_DOMAIN_0 + domain]],
			String(keys[METRIC_TECH_DOMAIN_0 + domain])
				== "country.completed_tech_count.%s" % [
					["agriculture", "engineering", "science", "society"][domain]])
	var domain_indices: PackedInt32Array = _catalog.get(
		"technology_domain_indices", PackedInt32Array())
	var technology_ids: PackedStringArray = _catalog.get(
		"technology_ids", PackedStringArray())
	if not _require("the technology catalog spans both 64-bit words",
			domain_indices.size() == technology_ids.size()
				and technology_ids.size() > 64,
			"technologies=%d domains=%d" % [
				technology_ids.size(), domain_indices.size()]):
		return false
	var second_word_technology := "tech.composite_tools"
	var second_word_index := technology_ids.find(second_word_technology)
	if not _require("a real technology index above 63 exists",
			second_word_index >= 64,
			"%s=%d" % [second_word_technology, second_word_index]):
		return false
	if not _require("the second-word technology starts undiscovered",
			not _has_technology(second_word_technology),
			str(_ext.get_country_snapshot(_handle).get(
				"technology_ids", PackedStringArray()))):
		return false
	var before := _counts_from_snapshot()
	if not _require("the metric source starts at the frozen Country count",
			_wait_metric_counts(before, 8), "metric=%s country=%s" % [
				str(_metric_counts()), str(before)]):
		return false

	if not _grant_technology(second_word_technology):
		return false
	# The grant changes the Country snapshot and the next epoch's derived metrics.
	# Compare the metric columns with the expected count; comparing the updated
	# snapshot to itself would not observe whether Economy rebuilt the columns.
	var expected := before.duplicate()
	expected[METRIC_COMPLETED_TECH] += 1
	var granted_domain := int(domain_indices[second_word_index])
	if granted_domain < 0 or granted_domain > 3:
		_fail("the granted technology has no X10 domain")
		return false
	expected[METRIC_TECH_DOMAIN_0 + granted_domain] += 1
	if not _require("the next frozen epoch includes the granted technology",
			_wait_metric_counts(expected, 12), "metric=%s expected=%s" % [
				str(_metric_counts()), str(expected)]):
		return false
	var after := _metric_counts()
	_expect("granting index 64 increments the total count",
		after[METRIC_COMPLETED_TECH] == expected[METRIC_COMPLETED_TECH],
		"%s vs %s" % [str(after), str(expected)])
	_expect("granting index 64 increments only its engineering domain",
		after[METRIC_TECH_DOMAIN_1] == expected[METRIC_TECH_DOMAIN_1]
			and after[METRIC_TECH_DOMAIN_0]
				== expected[METRIC_TECH_DOMAIN_0]
			and after[METRIC_TECH_DOMAIN_2]
				== expected[METRIC_TECH_DOMAIN_2]
			and after[METRIC_TECH_DOMAIN_3]
				== expected[METRIC_TECH_DOMAIN_3],
		"%s vs %s" % [str(after), str(expected)])
	var report: Dictionary = _ext.get_economy_report()
	_expect("the four-domain mask table is copied once from Country",
		int(report.get("technology_metric_domain_count", -1)) == 4
			and int(report.get("technology_metric_domain_mask_count", -1))
				== 4 * _technology_words(),
		str(report))
	_expect("the metrics use a pure popcount from the frozen six words",
		after[METRIC_COMPLETED_TECH]
			== _popcount_snapshot_technologies(),
		"metrics=%s" % str(after))
	return true


## A local one-card catalog points at the production diagnostic program. The
## gate is visible at zero completions, turns on after a synthetic exact input
## update, and turns off when the card is removed.
func _test_program_toggle() -> bool:
	var source: Dictionary = _ext.get_economy_report()
	if not _require("the count source hash is exposed", int(
			source.get("technology_metric_source_hash", 0)) != 0, str(source)):
		return false
	var words := PackedInt64Array()
	words.resize(_technology_words())
	for word in words.size():
		words[word] = int(_current_technology_word(word))
	var zero := PackedInt64Array()
	zero.resize(words.size())
	var zeroed: Dictionary = _ext.set_country_technology_metric_input_for_test(
		_country_slot, zero)
	if not _require("the zero-count technology input applies",
			bool(zeroed.get("ok", false)), str(zeroed)):
		return false
	_expect("the zero-count fixture starts at metric zero",
		_metric(METRIC_COMPLETED_TECH) == 0,
		str(_metric(METRIC_COMPLETED_TECH)))
	var dense := _dense_id(LOCAL_CARD)
	if not _require("the test-only local X10 card is configured", dense >= 0,
			str(dense)):
		return false
	if not _equip(dense):
		return false
	var baseline := _factor()
	_expect("the diagnostic v10 gate is off at zero completed technologies",
		_is_close(baseline, 1.0), "%.5f" % baseline)
	words[0] = 1
	var arm: Dictionary = _ext.set_country_technology_metric_input_for_test(
		_country_slot, words)
	if not _require("the one-technology input applies",
			bool(arm.get("ok", false)), str(arm)):
		return false
	_tick = _drive_days(2)
	var on := _wait_factor(1.01, 12)
	_expect("v10_technology_gate turns on at one completed technology",
		_is_close(on, 1.01), "%.5f" % on)
	var visits_before := _instance_refresh_visits()
	var cleared: Dictionary = _ext.set_country_technology_metric_input_for_test(
		_country_slot, zero)
	if not _require("the gate input clears", bool(cleared.get("ok", false)),
			str(cleared)):
		return false
	_tick = _drive_days(2)
	var off := _wait_factor(1.0, 12)
	_expect("v10_technology_gate turns off at zero completed technologies",
		_is_close(off, 1.0), "%.5f" % off)
	_expect("the gate toggle visits only its own instance",
		_instance_refresh_visits() > visits_before,
		"before=%d after=%d" % [visits_before, _instance_refresh_visits()])
	if not _unequip(dense):
		return false
	_expect("removing the local card restores the baseline",
		_is_close(_factor(), 1.0), "%.5f" % _factor())
	return true


func _test_idle_reuse() -> void:
	var baseline := _idle_baseline()
	var clean_days := 0
	while clean_days < 30:
		var faults_before := _worker_fault_count()
		var recaptures_before := _command_recapture_count()
		_tick = _drive_days(1)
		if _worker_fault_count() != faults_before \
				or _command_recapture_count() != recaptures_before:
			baseline = _idle_baseline()
			clean_days = 0
			continue
		clean_days += 1
	var rebuilds_before := int(baseline["rebuilds"])
	var source_hash_before := int(baseline["source_hash"])
	var revisions_before: PackedInt64Array = baseline["revisions"]
	var visits_before := int(baseline["visits"])
	var report_after: Dictionary = _ext.get_economy_report()
	var rebuilds_after := int(report_after.get(
		"technology_metric_rebuilds", -1))
	var source_hash_after := int(report_after.get(
		"technology_metric_source_hash", 0))
	var revisions_after: PackedInt64Array = _ext.get_effect_input_revisions().get(
		"metrics", PackedInt64Array())
	_expect("30 unchanged days rebuild the technology metrics zero times",
		rebuilds_after == rebuilds_before, "%d -> %d" % [
			rebuilds_before, rebuilds_after])
	_expect("the technology source hash is unchanged across idle days",
		source_hash_after == source_hash_before, "%d -> %d" % [
			source_hash_before, source_hash_after])
	for metric in range(METRIC_COMPLETED_TECH, METRIC_TECH_DOMAIN_3 + 1):
		_expect("metric %d revision is unchanged across idle days" % metric,
			revisions_after[metric] == revisions_before[metric],
			"%d -> %d" % [revisions_before[metric], revisions_after[metric]])
	_expect("unrelated cards receive zero refresh visits across idle days",
		_instance_refresh_visits() == visits_before,
		"%d -> %d" % [visits_before, _instance_refresh_visits()])


func _idle_baseline() -> Dictionary:
	var report: Dictionary = _ext.get_economy_report()
	return {
		"rebuilds": int(report.get("technology_metric_rebuilds", -1)),
		"source_hash": int(report.get("technology_metric_source_hash", 0)),
		"revisions": _ext.get_effect_input_revisions().get(
			"metrics", PackedInt64Array()).duplicate(),
		"visits": _instance_refresh_visits(),
	}


func _counts_from_snapshot() -> Dictionary:
	var counts := {}
	for metric in range(METRIC_COMPLETED_TECH, METRIC_TECH_DOMAIN_3 + 1):
		counts[metric] = 0
	var ids: PackedStringArray = _ext.get_country_snapshot(_handle).get(
		"technology_ids", PackedStringArray())
	var lookup := {}
	var technology_ids: PackedStringArray = _catalog.get(
		"technology_ids", PackedStringArray())
	var domains: PackedInt32Array = _catalog.get(
		"technology_domain_indices", PackedInt32Array())
	for index in technology_ids.size():
		if index < domains.size():
			lookup[String(technology_ids[index])] = int(domains[index])
	for value in ids:
		var technology := String(value)
		if not lookup.has(technology):
			continue
		counts[METRIC_COMPLETED_TECH] += 1
		var offset := int(lookup[technology])
		if offset >= 0 and offset < 4:
			counts[METRIC_TECH_DOMAIN_0 + offset] += 1
	return counts


func _metric_counts() -> Dictionary:
	var counts := {}
	for metric in range(METRIC_COMPLETED_TECH, METRIC_TECH_DOMAIN_3 + 1):
		counts[metric] = _metric(metric) / Q16_ONE
	return counts


func _wait_metric_counts(expected: Dictionary, days: int) -> bool:
	for _day in range(days):
		if _metric_counts() == expected:
			return true
		_tick = _drive_days(1)
	return _metric_counts() == expected


func _popcount_snapshot_technologies() -> int:
	var count := 0
	var ids: PackedStringArray = _ext.get_country_snapshot(_handle).get(
		"technology_ids", PackedStringArray())
	var all_ids: PackedStringArray = _catalog.get(
		"technology_ids", PackedStringArray())
	for technology in ids:
		if all_ids.has(String(technology)):
			count += 1
	return count


func _technology_words() -> int:
	return ceili(float((_catalog.get(
		"technology_ids", PackedStringArray()) as PackedStringArray).size()) / 64.0)


func _current_technology_word(word: int) -> int:
	var snapshot: Dictionary = _ext.get_country_snapshot(_handle)
	var ids: PackedStringArray = snapshot.get(
		"technology_ids", PackedStringArray())
	var all_ids: PackedStringArray = _catalog.get(
		"technology_ids", PackedStringArray())
	var value := 0
	for technology in ids:
		var index := all_ids.find(String(technology))
		if index >= 0 and int(index / 64) == word:
			value |= 1 << (index % 64)
	return value


func _metric(metric_id: int) -> int:
	var result: Dictionary = _ext.sample_effect_metric_probe(
		metric_id, _anchor, _handle)
	if not bool(result.get("ok", false)):
		_fail("metric %d probe failed: %s" % [metric_id,
			str(result.get("reason", "unknown"))])
		return -1
	return int(result.get("value", -1))


func _factor() -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_ECONOMY, 0, _anchor, AGRICULTURE_STAT, 1.0))


func _wait_factor(expected: float, days: int) -> float:
	var value := _factor()
	for _day in range(days):
		if _is_close(value, expected):
			return value
		_tick = _drive_days(1)
		value = _factor()
	return value


func _has_technology(technology_id: String) -> bool:
	var ids: PackedStringArray = _ext.get_country_snapshot(_handle).get(
		"technology_ids", PackedStringArray())
	return ids.has(technology_id)


func _grant_technology(technology_id: String) -> bool:
	var facade = _generator.get_country_facade()
	if facade == null:
		_stage("country facade unavailable")
		return false
	var result: Dictionary = facade.grant_technology(
		_handle, StringName(technology_id), _tick + 1, _next_sequence)
	if not _require("CountryFacade grants %s" % technology_id,
			bool(result.get("ok", false)), str(result)):
		return false
	_next_sequence += 1
	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline:
		_tick = _drive_days(1)
		if _has_technology(technology_id):
			return true
	return _require("%s becomes visible to Economy" % technology_id, false,
		str(_ext.get_country_snapshot(_handle)))


## Test-only catalog mutation. The resource is returned and kept in a member so
## every subsequent `load_default()` sees the cached card before world generation.
## The card points at the generated production diagnostic program; no published
## card or catalog artifact is modified.
func _install_local_card() -> Resource:
	var catalog: Resource = IdeologyCatalogScript.load_default()
	if catalog == null:
		_fail("ideology catalog unavailable")
		return null
	var definition: Resource = IdeologyDefinitionScript.new()
	definition.id = StringName("idea.%s" % LOCAL_CARD)
	definition.rarity_weight = 1
	definition.ideology_slot_cost = 1
	definition.national_spirit_slot_cost = 1
	definition.acquisition_flags = 3
	definition.era_index = 0
	var level: Resource = IdeologyLevelDefinitionScript.new()
	level.understanding_threshold_q16 = 0
	var row: Resource = EffectCommandScript.new()
	row.action = 1
	row.domain = 1
	row.opcode = 1
	row.target_resolver = 1
	row.value_mode = 1
	row.value_q16 = Q16_ONE
	row.duration_days = -1
	row.stacks = 1
	row.command_key = &"ideology.persistent"
	row.definition_key = StringName(LOCAL_PROGRAM)
	var rows: Array[Resource] = [row]
	level.persistent_effects = rows
	var levels: Array[Resource] = [level]
	definition.levels = levels
	var definitions: Array[Resource] = catalog.definitions.duplicate()
	definitions.append(definition)
	catalog.definitions = definitions
	return catalog


func _dense_id(card: String) -> int:
	if _test_ideology_catalog == null:
		return -1
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = _test_ideology_catalog.compile_native_catalog(
		country_ir, country_ir)
	if not bool(native.get("ok", false)):
		_fail("test ideology catalog compile failed: %s" % String(
			native.get("reason", "unknown")))
		return -1
	var ids := PackedStringArray(native.get("ideology_ids", PackedStringArray()))
	return ids.find("idea.%s" % card)


func _metric_keys() -> PackedStringArray:
	var domain: Resource = EffectDomainCatalogScript.build()
	return domain.metric_keys if domain != null else PackedStringArray()


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
	host.runtime_authority_domain_mask = 0xF7F
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "C0 X10"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("x10 session configures", bool(session.get("ok", false)),
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
	var anchor := int(ext.query_country_anchor_cell(country_slot))
	if not _require("worker path resolves the country anchor", anchor >= 0,
			str(anchor)):
		return {}
	_tick = _world_day(ext)
	_tick = _drive_days(3)
	return {"host": host, "clock": clock, "ext": ext,
		"generator": generator, "handle": handle,
		"country_slot": country_slot, "anchor": anchor, "tick": _tick}


func _equip(dense: int) -> bool:
	_tick = _drive_days(1)
	var discovered: Dictionary = _submit([{
		"op": 1, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("worker accepts local-card discover",
			bool(discovered.get("ok", false)), str(discovered)):
		return false
	_tick = _drive_days(2)
	var equipped: Dictionary = _submit([{
		"op": 5, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("worker accepts local-card equip",
			bool(equipped.get("ok", false)), str(equipped)):
		return false
	_tick = _drive_days(6)
	for _day in range(4):
		if int(_ext.get_ideology_snapshot(_handle).get(
				"ideology_slots_used", -1)) >= 1:
			return true
		_tick = _drive_days(1)
	return _require("the local card occupies a slot", false,
		str(_ext.get_ideology_snapshot(_handle)))


func _unequip(dense: int) -> bool:
	var result: Dictionary = _submit([{
		"op": 6, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("worker accepts local-card unequip",
			bool(result.get("ok", false)), str(result)):
		return false
	_tick = _drive_days(3)
	for _day in range(4):
		if int(_ext.get_ideology_snapshot(_handle).get(
				"ideology_slots_used", -1)) == 0:
			return true
		_tick = _drive_days(1)
	return _require("the local card releases its slot", false,
		str(_ext.get_ideology_snapshot(_handle)))


func _instance_refresh_visits() -> int:
	return int(_ext.get_ideology_report().get(
		"instance_refresh_visits", 0))


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
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"source_priorities": priorities, "offer_generations": generations,
		"choice_indices": choices, "gate_ids": gates,
	}


func _drive_days(days: int) -> int:
	for _day in range(days):
		var fault := _worker_fault()
		if not fault.is_empty():
			_require("worker stays healthy before day %d" % (_tick + 1),
				false, fault)
			break
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


func _wait_pod_day(before: int, timeout_ms: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(2)
		if int(_ext.get_runtime_thread_report().get(
				"ideology_pod_committed_day", -1)) > before:
			return


func _has_hard_barrier() -> bool:
	return bool(_clock.has_hard_barrier()) if _clock.has_method(
		"has_hard_barrier") else false


func _worker_fault() -> String:
	if _ext == null:
		return ""
	return String(_ext.get_runtime_thread_report().get("fault_code", ""))


func _worker_fault_count() -> int:
	if _ext == null:
		return 0
	return int(_ext.get_runtime_thread_report().get("worker_fault_count", 0))


func _command_recapture_count() -> int:
	if _ext == null:
		return 0
	return int(_ext.get_runtime_thread_report().get(
		"economy_pod_command_recapture_count", 0))


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


func _teardown() -> void:
	if _ext != null and _ext.has_method("request_runtime_stop"):
		_ext.request_runtime_stop()


func _is_close(actual: float, expected: float) -> bool:
	return is_finite(actual) and absf(actual - expected) <= 0.0005


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
