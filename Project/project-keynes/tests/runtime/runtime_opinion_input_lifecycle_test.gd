extends "res://tests/runtime/runtime_world_lifecycle_test.gd"

# Restore an initial committed opinion into a host that cached an absent input
# for day one. Check the actual input consumed by Ideology on both executors.
const FULL_MASK := 0x977
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

func _finish() -> void:
	await _run()
	_expect("both input lifecycle scenarios completed", _checks >= 100)
	print("runtime opinion input lifecycle: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _run() -> int:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("opinion lifecycle catalog compiles", catalog.get("ok", false))
	if not catalog.get("ok", false):
		return 1
	catalog.erase("ok")
	for inline_mode in [false, true]:
		var source: Object = _opinion_world(catalog, true)
		_expect("source world starts with a committed initial opinion", source.start_runtime_worker(
			_opinion_config(inline_mode)).get("ok", false))
		var saved := await _opinion_save(source)
		var restored_opinion: Dictionary = source.get_country_class_opinion_snapshot()
		_expect("saved timeline retains its initial Economy opinion", restored_opinion.get("commit_day", -1) == 0)
		await _stop(source)

		var target: Object = _opinion_world(catalog, false)
		_expect("target world starts with Economy authority", target.start_runtime_worker(
			_opinion_config(inline_mode)).get("ok", false))
		if not await _opinion_day(target, inline_mode, 1):
			await _stop(target)
			continue
		var before: Dictionary = target.get_runtime_thread_report()
		_expect("missing initial opinion does not invent an Ideology commit",
			before.get("ideology_pod_committed_day", -1) < 1)
		await _stop(target)
		if saved.is_empty():
			continue
		var rejected_input: Dictionary = target.capture_runtime_inputs({
			"generation": int(target.get_runtime_thread_report().get("simulation_environment_generation", 0)) + 1,
			"day": 0, "terrain": PackedByteArray([1, 1]), "landform": PackedByteArray([0, 0]),
			"climate_map_width": 2, "climate_map_height": 1, "climate_catalog_hash": 7,
			"cell_temp": PackedFloat32Array([15.0, 15.0]), "cell_moisture": PackedFloat32Array([0.5, 0.5]),
			"has_river": PackedByteArray([0, 0]),
			"neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1])})
		_expect("old environment dates still reject without a prepared restore",
			not rejected_input.get("ok", true) and rejected_input.get("code", "") == "runtime_input_before_committed_day")
		var future_day := 2
		while target.environment_ring_has_capacity():
			var previous_generation: int = target.get_runtime_thread_report().get("simulation_environment_generation", 0)
			_capture_input(target, future_day)
			future_day += 1
			if int(target.get_runtime_thread_report().get("simulation_environment_generation", 0)) <= previous_generation:
				_expect("the old input queue fills through valid future captures", false)
				break
		_expect("the stopped world has a full input queue", not target.environment_ring_has_capacity())
		_expect("complete bundle prepares on the already-used host", target.restore_runtime_bundle(saved.bytes).get("ok", false))
		_expect("the saved Country checkpoint restores before startup", target.restore_country_runtime_checkpoint(saved.country_pkcn).get("ok", false))
		# Environment rows are restored by their owner before the Host starts.
		# The PKSR envelope carries their identity, not the map's row payload.
		_capture_input(target, 1)
		var restarted: Dictionary = target.start_runtime_worker(_opinion_config(inline_mode))
		if not restarted.get("ok", false): print("[opinion-restart] ", restarted)
		_expect("restored target starts", restarted.get("ok", false))
		_expect("restored calendar is day zero", target.get_runtime_thread_report().get("simulation_committed_day", -1) == 0)
		_expect("the restored Ideology date replaces the other timeline's date",
			target.get_runtime_thread_report().get("ideology_pod_committed_day", -1) <= 1)
		if await _opinion_day(target, inline_mode, 1):
			var after: Dictionary = target.get_runtime_thread_report()
			_expect("restored Ideology now commits day one", after.get("ideology_pod_committed_day", -1) == 1)
			_expect("complete restore discards the other timeline's cached daily opinion",
				after.get("ideology_parity_worker_opinion_committed_day", -1) == restored_opinion.get("commit_day", -2))
			_expect("restored Ideology consumes the saved opinion revision",
				after.get("ideology_parity_worker_opinion_revision", -1) == restored_opinion.get("revision", -2))
			var opinion: Dictionary = target.get_country_class_opinion_snapshot()
			var population: PackedInt64Array = opinion.population.duplicate()
			var weighted: PackedInt64Array = opinion.satisfaction_weighted.duplicate()
			for row in population.size():
				population[row] *= 2
				weighted[row] *= 2
			_expect("the controlled opinion source installs at an idle boundary", target.set_class_opinion_source_override_for_test(
				population, opinion.satisfaction_q16, weighted).get("ok", false))
			var published: Dictionary = target.publish_ideology_worker_inputs()
			_expect("the controlled source publishes", published.get("ok", false))
			if await _opinion_day(target, inline_mode, 2):
				var controlled: Dictionary = target.get_runtime_thread_report()
				_expect("the executor preserves the explicit test source date",
					controlled.get("ideology_parity_worker_opinion_committed_day", -1) == published.get("committed_day", -2))
				_expect("the executor preserves the explicit test source revision",
					controlled.get("ideology_parity_worker_opinion_revision", -1) == published.get("revision", -2))
		_expect("the test-only input is removed before another restore", target.clear_class_opinion_source_override_for_test().get("ok", false))
		await _stop(target)
		_expect("the original timeline can be restored again", target.restore_runtime_bundle(saved.bytes).get("ok", false))
		_expect("its Country checkpoint restores again", target.restore_country_runtime_checkpoint(saved.country_pkcn).get("ok", false))
		_capture_input(target, 1)
		_expect("the second restored executor starts", target.start_runtime_worker(_opinion_config(inline_mode)).get("ok", false))
		var unused: Dictionary = target.get_runtime_thread_report()
		_expect("repeated restore reports the restored Ideology date", unused.get("ideology_pod_committed_day", -1) <= 1)
		_expect("restore does not report an opinion consumed on the other timeline",
			(unused.get("ideology_parity_worker_opinion_committed_day", -1) == -1
			and unused.get("ideology_parity_worker_opinion_revision", -1) == 0)
			or (unused.get("ideology_parity_worker_opinion_committed_day", -1) == restored_opinion.get("commit_day", -2)
			and unused.get("ideology_parity_worker_opinion_revision", -1) == restored_opinion.get("revision", -2)))
		if await _opinion_day(target, inline_mode, 1):
			var replayed: Dictionary = target.get_runtime_thread_report()
			_expect("repeated restore consumes its own committed input",
				replayed.get("ideology_parity_worker_opinion_committed_day", -1) == restored_opinion.get("commit_day", -2)
				and replayed.get("ideology_parity_worker_opinion_revision", -1) == restored_opinion.get("revision", -2))
		await _stop(target)
	return 0

func _opinion_config(inline_mode: bool) -> Dictionary:
	var config := _configuration(inline_mode)
	config.authoritative_domain_mask = FULL_MASK
	config.economy_auto_pod_active = true
	config.economy_production_writer = "stage_ops"
	return config

func _opinion_world(catalog: Dictionary, initial_opinion: bool) -> Object:
	var ext := DCWorldExt.new()
	ext.create_entities(2)
	for name in [&"cell_temp", &"cell_temp_30d", &"cell_temp_365d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var slot: int = ext.register_component(name, 0, 1, false)
		ext.write_f32_range(slot, 0, PackedFloat32Array([0.5, 0.5]))
	for name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water",
			&"cell_has_river", &"cell_weather_type", &"cell_cover"]:
		var slot: int = ext.register_component(name, 2, 1, false)
		ext.write_u8_range(slot, 0, PackedByteArray([0, 0]))
	var reserves: PackedStringArray = catalog.building_resource_reserve_slots
	var extras: PackedStringArray = catalog.building_resource_extra_slots
	for index in reserves.size():
		var reserve: int = ext.register_component(StringName(reserves[index]), 0, 1, false)
		var extra: int = ext.register_component(StringName(extras[index]), 0, 1, false)
		ext.write_f32_range(reserve, 0, PackedFloat32Array([1000000.0, 1000000.0]))
		ext.write_f32_range(extra, 0, PackedFloat32Array([0.0, 0.0]))
	_setup_country(ext, catalog, 20261110)
	_expect("initial Country day commits", ext.run_country_slice({"day_index": 0}).get("ok", false))
	_expect("committed initial Country snapshot captures", ext.capture_country_runtime_snapshot().get("ok", false))
	var modifier := ModifierFacadeScript.new()
	_expect("opinion Modifier configures", modifier.configure(ext, 2).get("ok", false))
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 1
	profile.market_max_cycle_days = 1
	profile.economy_cadence_force_market_days = 1
	profile.worker_enabled = false
	profile.starvation_death_rate_q32 = 0
	_expect("opinion Economy configures", ext.configure_economy(catalog, profile, 2, 20261110).get("ok", false))
	var signatures: PackedStringArray = catalog.signature_keys
	_expect("opinion Economy bootstraps", ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([signatures.find("hunter|default")]),
		"population": PackedInt64Array([100]), "funds": PackedInt64Array([100000]),
	}, {}).get("ok", false))
	if initial_opinion:
		var completed := false
		for slice in range(512):
			var report: Dictionary = ext.run_economy_slice({"day_index": 0, "tick_index": slice})
			if report.get("done", false):
				completed = true
				break
		_expect("initial Economy opinion commits", completed and ext.get_country_class_opinion_snapshot().get("revision", 0) > 0)
	_expect("opinion Effect configures", ext.configure_effects(
		preload("res://scripts/effect/effect_domain_catalog.gd").build().compile_native_catalog()).get("ok", false))
	var ideology: Dictionary = preload("res://scripts/ideology/ideology_catalog.gd").load_default().compile_native_catalog(catalog, catalog)
	_expect("opinion Ideology compiles", ideology.get("ok", false))
	ideology.erase("ok")
	_expect("opinion Ideology configures", ext.configure_ideologies(ideology).get("ok", false))
	# The target will advance; the source saves its already committed day zero.
	if not initial_opinion:
		_capture_input(ext, 1)
	return ext

func _opinion_day(ext: Object, inline_mode: bool, day: int) -> bool:
	# Climate authority accepts only the next frame day; a restored or
	# pre-seeded host may already hold this day.
	for input_day in range(int(ext.runtime_next_environment_day()), day + 1):
		_capture_input(ext, input_day)
	if not inline_mode:
		ext.set_runtime_clock(false, 1.0)
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		ext.service_country_worker_peer_adapter(64, true)
		var report: Dictionary = ext.get_runtime_thread_report()
		if int(report.get("economy_input_requested_day", -1)) >= 0:
			ext.capture_economy_day_inputs(-1)
		if inline_mode:
			ext.run_native_daily_inline_day()
		var current: Dictionary = ext.get_runtime_thread_report()
		if int(current.get("simulation_committed_day", -1)) == day and int(current.get("worker_day_inflight", 1)) == 0:
			break
		await process_frame
	if not inline_mode:
		ext.set_runtime_clock(true, 0.0)
	var committed: bool = ext.get_runtime_thread_report().get("simulation_committed_day", -1) == day
	if not committed:
		print("[opinion-lifecycle] ", ext.get_runtime_thread_report())
	_expect("opinion lifecycle day %d commits" % day, committed)
	return committed

func _opinion_save(ext: Object) -> Dictionary:
	_expect("opinion source save is accepted", ext.request_runtime_save(20261110).get("ok", false))
	var deadline := Time.get_ticks_msec() + 5000
	var result := {}
	while Time.get_ticks_msec() < deadline:
		result = ext.poll_runtime_save(20261110)
		if result.get("ready", false) or not result.get("ok", true):
			break
		await process_frame
	_expect("opinion source reaches its committed save boundary", result.get("ready", false))
	if not result.get("ready", false): print("[opinion-save] ", result)
	return result if result.get("ready", false) else {}
