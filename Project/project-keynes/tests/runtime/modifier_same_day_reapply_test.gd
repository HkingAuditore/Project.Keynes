extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"

const TECH_ID := &"tech.herd_management"
const TECH_STAT := "country.output.terrain.grassland.agriculture_factor"
const TECH_DELTA := 0.061
const CLIMATE_DEF := "climate.radiative_warming"
const CLIMATE_STAT := "climate.cell.radiative_target"
const CLIMATE_DELTA := 0.05
const GAMEPLAY_DEF := "gameplay.generic.bonus"
const GAMEPLAY_STAT := "gameplay.generic.value"
const GAMEPLAY_DELTA := 1.0
const GAMEPLAY_ENTITY := 999901


func _run() -> void:
	await _run_world(false, true)
	_finish()


func _sample_military_world(host: WorldRuntimeHost, clock: WorldClock) -> Dictionary:
	var generator := host.get_generator()
	var country: CountryFacade = generator.get_country_facade()
	var economy: EconomyFacade = generator.get_economy_facade()
	var ext: DCWorldExt = economy.world_ext()
	var capital := int(generator.gameplay_start_report().get("cell", -1))
	var player_handle := int(ext.get_country_cell_summary(capital).get("country_handle", 0))
	var tech_ids: PackedStringArray = country.get("_catalog").technology_ids
	var tech_index := tech_ids.find(String(TECH_ID))
	_expect("world opens with player country and target effect technology",
		capital >= 0 and player_handle > 0 and tech_index >= 0)
	if capital < 0 or player_handle <= 0 or tech_index < 0:
		return {}

	var self_test: Dictionary = ext.runtime_modifier_pod_self_test()
	_expect("Modifier POD C++ self-test passes (includes same-identity idempotency)",
		bool(self_test.get("ok", false)))

	var base_climate := float(ext.evaluate_modifier_stat(0, capital, 0, CLIMATE_STAT, 0.0))
	var base_gameplay := float(ext.evaluate_modifier_stat(3, GAMEPLAY_ENTITY, 0, GAMEPLAY_STAT, 0.0))
	var base_tech_stat := float(ext.evaluate_modifier_stat(1, player_handle, 0, TECH_STAT, 1.0))

	clock.set_speed(SPEED)
	var generations: Array[int] = []

	# Day 1: settle cleanly and verify baseline generation == 1.
	_publish_day(host, clock, 1)
	if not await _wait_golden_read_boundary(host, economy, 1):
		_expect("day 1 settles", false)
		return {}
	var report_d1: Dictionary = generator.get_runtime_thread_report()
	var gen_d1 := int(report_d1.get("modifier_pod_snapshot_generation", -1))
	var peer_resolved_d1 := int(ext.get_runtime_perf_snapshot(0).get("country_peer_resolved_in_worker", 0))
	generations.append(gen_d1)
	_expect("day 1 Modifier snapshot generation is 1 (got %d)" % gen_d1, gen_d1 == 1)

	# Queue Day 2 inputs:
	# 1) Grant a technology with a modifier effect (triggers Day 2 same-day revisit).
	var grant: Dictionary = country.grant_technology(player_handle, TECH_ID, 2, 950001, true)
	_expect("day 2 technology grant is admitted",
		bool(grant.get("ok", false)) and int(grant.get("effective_day", -1)) == 2)

	# 2) Submit stackable Modifier commands for Day 2 (both POLICY_STACK_REFRESH and POLICY_INDEPENDENT).
	var d2_submit: Dictionary = ext.submit_modifier_commands({
		"protocol_version": 2,
		"unbound_input_generation": true,
		"opcodes": PackedInt32Array([1, 1]),
		"producer_ids": PackedInt32Array([77, 77]),
		"sequences": PackedInt64Array([950101, 950102]),
		"effective_days": PackedInt64Array([2, 2]),
		"definition_keys": PackedStringArray([CLIMATE_DEF, GAMEPLAY_DEF]),
		"domains": PackedInt32Array([0, 3]),
		"scopes": PackedInt32Array([2, 2]),
		"entity_handles": PackedInt64Array([capital, GAMEPLAY_ENTITY]),
		"group_handles": PackedInt64Array([0, 0]),
		"source_types": PackedInt64Array([91, 92]),
		"source_ids": PackedInt64Array([9501, 9502]),
		"duration_days": PackedInt32Array([30, -1]),
		"stacks": PackedInt32Array([1, 1]),
		"magnitude_q16": PackedInt32Array([65536, 65536]),
		"modifier_handles": PackedInt64Array([0, 0]),
	})
	_expect("day 2 stackable modifier commands are enqueued",
		bool(d2_submit.get("ok", false)) and int(d2_submit.get("modifier_host_enqueued", 0)) == 2)

	# Day 2: settle and verify single application + generation == 2 + tech effect active.
	_publish_day(host, clock, 2)
	if not await _wait_golden_read_boundary(host, economy, 2):
		_expect("day 2 settles", false)
		return {}

	var report_d2: Dictionary = generator.get_runtime_thread_report()
	var gen_d2 := int(report_d2.get("modifier_pod_snapshot_generation", -1))
	var peer_resolved_d2 := int(ext.get_runtime_perf_snapshot(0).get("country_peer_resolved_in_worker", 0))
	generations.append(gen_d2)
	_expect("day 2 technology grant triggered worker peer resolution / same-day revisit (%d -> %d)" % [peer_resolved_d1, peer_resolved_d2],
		peer_resolved_d2 > peer_resolved_d1)

	var d2_climate := float(ext.evaluate_modifier_stat(0, capital, 0, CLIMATE_STAT, 0.0))
	var d2_gameplay := float(ext.evaluate_modifier_stat(3, GAMEPLAY_ENTITY, 0, GAMEPLAY_STAT, 0.0))
	var d2_climate_list: Dictionary = ext.list_modifiers(0, capital, CLIMATE_STAT)
	var d2_gameplay_list: Dictionary = ext.list_modifiers(3, GAMEPLAY_ENTITY, GAMEPLAY_STAT)
	var d2_climate_stacks: PackedInt32Array = d2_climate_list.get("stacks", PackedInt32Array())
	var d2_gameplay_handles: PackedInt64Array = d2_gameplay_list.get("handles", PackedInt64Array())
	var d2_snap: Dictionary = ext.get_runtime_modifier_snapshot(-1)

	print("MODIFIER_REAPPLY_D2 gen=%d snap_gen=%d climate=%.4f (expected %.4f) stacks=%s gameplay=%.4f (expected %.4f) count=%d" % [
		gen_d2, int(d2_snap.get("generation", -1)),
		d2_climate, base_climate + CLIMATE_DELTA, str(d2_climate_stacks),
		d2_gameplay, base_gameplay + GAMEPLAY_DELTA, d2_gameplay_handles.size(),
	])

	_expect("day 2 POLICY_STACK_REFRESH applied once (got %.4f, expected %.4f)" % [d2_climate, base_climate + CLIMATE_DELTA],
		is_equal_approx(d2_climate, base_climate + CLIMATE_DELTA)
		and d2_climate_stacks.size() == 1 and int(d2_climate_stacks[0]) == 1)
	_expect("day 2 POLICY_INDEPENDENT applied once (got %.4f, expected %.4f)" % [d2_gameplay, base_gameplay + GAMEPLAY_DELTA],
		is_equal_approx(d2_gameplay, base_gameplay + GAMEPLAY_DELTA)
		and d2_gameplay_handles.size() == 1)
	_expect("day 2 published snapshot generation matches thread report (%d == %d)" % [int(d2_snap.get("generation", -1)), gen_d2],
		int(d2_snap.get("generation", -1)) == gen_d2 and int(d2_snap.get("committed_day", -1)) == 2)
	_expect("day 2 Modifier snapshot generation is 2 (got %d)" % gen_d2, gen_d2 == 2)

	var d2_research := country.research_snapshot(player_handle)
	var d2_tech_state := int((d2_research.technology_states as PackedInt32Array)[tech_index])
	var d2_tech_stat := float(ext.evaluate_modifier_stat(1, player_handle, 0, TECH_STAT, 1.0))
	_expect("day 2 granted technology is completed and its modifier effect is active (state=%d stat=%.4f)" % [d2_tech_state, d2_tech_stat],
		d2_tech_state == 5 and is_equal_approx(d2_tech_stat, base_tech_stat + TECH_DELTA))

	# Day 3: submit new-day commands and verify they apply normally and generation == 3.
	var d3_submit: Dictionary = ext.submit_modifier_commands({
		"protocol_version": 2,
		"unbound_input_generation": true,
		"opcodes": PackedInt32Array([1, 1]),
		"producer_ids": PackedInt32Array([77, 77]),
		"sequences": PackedInt64Array([950201, 950202]),
		"effective_days": PackedInt64Array([3, 3]),
		"definition_keys": PackedStringArray([CLIMATE_DEF, GAMEPLAY_DEF]),
		"domains": PackedInt32Array([0, 3]),
		"scopes": PackedInt32Array([2, 2]),
		"entity_handles": PackedInt64Array([capital, GAMEPLAY_ENTITY]),
		"group_handles": PackedInt64Array([0, 0]),
		"source_types": PackedInt64Array([91, 92]),
		"source_ids": PackedInt64Array([9501, 9503]),
		"duration_days": PackedInt32Array([30, -1]),
		"stacks": PackedInt32Array([1, 1]),
		"magnitude_q16": PackedInt32Array([65536, 65536]),
		"modifier_handles": PackedInt64Array([0, 0]),
	})
	_expect("day 3 stackable modifier commands are enqueued",
		bool(d3_submit.get("ok", false)) and int(d3_submit.get("modifier_host_enqueued", 0)) == 2)

	_publish_day(host, clock, 3)
	if not await _wait_golden_read_boundary(host, economy, 3):
		_expect("day 3 settles", false)
		return {}

	var gen_d3 := int(generator.get_runtime_thread_report().get("modifier_pod_snapshot_generation", -1))
	generations.append(gen_d3)
	var d3_climate := float(ext.evaluate_modifier_stat(0, capital, 0, CLIMATE_STAT, 0.0))
	var d3_gameplay := float(ext.evaluate_modifier_stat(3, GAMEPLAY_ENTITY, 0, GAMEPLAY_STAT, 0.0))
	var d3_tech_stat := float(ext.evaluate_modifier_stat(1, player_handle, 0, TECH_STAT, 1.0))

	print("MODIFIER_REAPPLY_D3 generations=%s climate=%.4f gameplay=%.4f tech_stat=%.4f" % [
		str(generations), d3_climate, d3_gameplay, d3_tech_stat,
	])

	_expect("D1-D3 Modifier generations are strictly [1, 2, 3] (got %s)" % str(generations),
		generations == [1, 2, 3])
	_expect("day 3 POLICY_STACK_REFRESH stacks to 2x (got %.4f, expected %.4f)" % [d3_climate, base_climate + 2.0 * CLIMATE_DELTA],
		is_equal_approx(d3_climate, base_climate + 2.0 * CLIMATE_DELTA))
	_expect("day 3 POLICY_INDEPENDENT stacks to 2x (got %.4f, expected %.4f)" % [d3_gameplay, base_gameplay + 2.0 * GAMEPLAY_DELTA],
		is_equal_approx(d3_gameplay, base_gameplay + 2.0 * GAMEPLAY_DELTA))
	_expect("day 3 technology modifier remains active (got %.4f, expected %.4f)" % [d3_tech_stat, base_tech_stat + TECH_DELTA],
		is_equal_approx(d3_tech_stat, base_tech_stat + TECH_DELTA))
	return {}


func _finish() -> void:
	print("modifier same-day reapply: %d checks, %d unexpected failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)
