extends "res://tests/runtime/golden_external_advancers_test.gd"

const MAP_WIDTH := 96
const MAP_HEIGHT := 64
const SEED := 20260727
const COUNTRY_COUNT := 4
const WARMUP_DAY := 34
const RELEASE_DAYS := 3
const HOLD_MSEC := 100
const SPEED := 100.0
const CLAIM_DAY := 4
const MILITARY_DAY := 5
const MILITARY_TARGET := 2
const MilitaryScenario = preload("res://tests/runtime/background_daily_military_scenario.gd")
const CountryStateProvider = preload("res://scripts/game/save_modules/country_state.gd")


func _run() -> void:
	OS.set_environment("PK_GOLDEN_DOMAINS", "1")
	var normal := await _run_world(false)
	var stalled := await _run_world(true)
	var days := WARMUP_DAY + RELEASE_DAYS
	var normal_rows: Array = normal.get("rows", [])
	var stalled_rows: Array = stalled.get("rows", [])
	_expect("both executions sampled the full day range",
		normal_rows.size() == days and stalled_rows.size() == days)
	_expect("command log, effective dates and map match", normal.get("commands") == stalled.get("commands"))
	for index in range(mini(normal_rows.size(), stalled_rows.size())):
		_expect("matching full daily summary at day %d" % (index + 1), normal_rows[index] == stalled_rows[index])

	print("BACKGROUND_DAILY_BASELINE=" + JSON.stringify({
		"seed": SEED, "width": MAP_WIDTH, "height": MAP_HEIGHT, "countries": COUNTRY_COUNT,
		"speed": SPEED, "cadence": "production", "commands": normal.get("commands", []),
		"rows": normal_rows,
	}))
	var hold: Dictionary = stalled.get("hold", {})
	if not hold.is_empty():
		_expect("main thread actually stopped between process frames", int(hold.process_frames) == 0)
		_expect("worker stayed ACTIVE and did not fault during hold", bool(hold.worker_healthy))
		_expect("hold started after the warmup boundary", int(hold.start_day) == WARMUP_DAY)
		_expect("current clock path admitted a real next simulation day", int(hold.admitted_through) > WARMUP_DAY)
		print("BACKGROUND_DAILY_HOLD=" + JSON.stringify(hold))
		if _failures == 0:
			_expect_target_failure("A", int(hold.committed_after) == WARMUP_DAY + RELEASE_DAYS,
				"required %d days, committed %d since release (%d during hold)" % [
					RELEASE_DAYS, int(hold.committed_after) - WARMUP_DAY, int(hold.committed_during_hold)])
	else:
		_expect("hold evidence recorded", false)

	var report: Dictionary = normal.get("report", {})
	if _expect_round_trip_report(report):
		_check_removed_round_trips(report, days)
		_check_round_trips(report)
	var stalled_report: Dictionary = stalled.get("report", {})
	if _expect_round_trip_report(stalled_report):
		_check_removed_round_trips(stalled_report, days)
	var military_world := await _run_world(false, true)
	print("BACKGROUND_MILITARY_BASELINE=" + JSON.stringify(military_world))
	await _check_narrative_boundary()
	_finish()


func _background_config() -> NewGameConfig:
	var config := NewGameConfig.create_default()
	config.country.name = "Background Daily Test"
	config.country.foreign_count = COUNTRY_COUNT - 1
	config.base.map_width = MAP_WIDTH
	config.base.map_height = MAP_HEIGHT
	config.base.initial_seed = SEED
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	return config


func _run_world(stall: bool, military_scenario: bool = false) -> Dictionary:
	var config := _background_config()
	var clock := WorldClock.new()
	clock.auto_start = false
	root.add_child(clock)
	clock.set_process(false)
	var host := _create_host()
	host.runtime_economy_auto_pod_active = true
	root.add_child(host)
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var configured := host.configure_session({"kind": "new_game", "config": config.to_dictionary()})
	_expect("formal new game configures", bool(configured.get("ok", false)))
	var result := {}
	if bool(configured.get("ok", false)):
		await host.generate_world()
		if host.is_runtime_ready_for_ticks():
			if military_scenario:
				result = await _sample_military_world(host, clock)
			else:
				result = await _sample_world(host, clock, stall)
		else:
			_expect("formal new game generates", false)
	_expect("formal world closes", bool((await host.close_world()).get("ok", false)))
	host.free()
	clock.free()
	return result


func _sample_military_world(host: WorldRuntimeHost, clock: WorldClock) -> Dictionary:
	var scenario := MilitaryScenario.new(host, _expect)
	if not scenario.ready():
		return {}
	var rows: Array = []
	clock.set_speed(SPEED)
	for day in range(1, MilitaryScenario.DAYS + 1):
		scenario.issue_for_day(day)
		_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, scenario.economy, day)
		_expect("military scenario settles day %d" % day, settled)
		if not settled:
			print("BACKGROUND_MILITARY_UNSETTLED=" + JSON.stringify(host.get_generator().get_runtime_thread_report()))
			break
		scenario.collect_day(day)
		rows.append(await _summary(host, scenario.ext, day))
	scenario.check_coverage()
	print("BACKGROUND_MILITARY_COVERAGE=" + JSON.stringify(scenario.evidence))
	return {"seed": SEED, "width": MAP_WIDTH, "height": MAP_HEIGHT, "countries": COUNTRY_COUNT,
		"commands": scenario.commands, "rows": rows}


func _sample_world(host: WorldRuntimeHost, clock: WorldClock, stall: bool) -> Dictionary:
	var generator := host.get_generator()
	var map := host.current_map()
	var economy = generator.get_economy_facade()
	var ext: Object = economy.world_ext()
	var military = generator.get_military_facade()
	var start := generator.gameplay_start_report()
	var player_cell := int(start.get("cell", -1))
	var player_handle := int(ext.get_country_cell_summary(player_cell).get("country_handle", 0))
	var claim_cell := _find_hidden_unowned_land(map)
	var opening: Dictionary = generator.get_runtime_thread_report()
	var valid := map.cell_count() == MAP_WIDTH * MAP_HEIGHT and player_handle > 0 and claim_cell >= 0 \
			and int(opening.get("simulation_committed_day", -1)) == 0 \
			and not bool(opening.get("native_daily_inline", true)) \
			and bool(opening.get("whole_graph_requested", false))
	_expect("formal worker world starts at day 0 with a player and hidden land", valid)
	if not valid:
		print("BACKGROUND_DAILY_OPENING=" + JSON.stringify({
			"start": start, "claim_cell": claim_cell,
			"day": opening.get("simulation_committed_day"), "inline": opening.get("native_daily_inline"),
			"whole_graph_requested": opening.get("whole_graph_requested"),
		}))
		return {}
	var economy_report: Dictionary = ext.get_economy_report()
	_expect("uses the production economy cadence", not bool(economy_report.get("cadence_timing_injected", true)))
	clock.set_speed(SPEED)
	var rows: Array = []
	var commands: Array = []
	var hold := {}
	for day in range(1, WARMUP_DAY + RELEASE_DAYS + 1):
		if day == CLAIM_DAY - 1:
			var claim: Dictionary = generator.get_country_facade().transfer_territory(
				claim_cell, player_handle, CLAIM_DAY, 910001, true)
			_expect("territory command admitted on its recorded day",
				bool(claim.get("ok", false)) and int(claim.get("effective_day", -1)) == CLAIM_DAY)
			commands.append({"operation": "transfer_territory", "cell": claim_cell,
				"country": player_handle, "effective_day": CLAIM_DAY, "sequence": 910001})
		if day == MILITARY_DAY - 1:
			var order: Dictionary = military.set_target(player_handle, 0, MILITARY_TARGET)
			_expect("military target admitted on the same day as the legacy settlement",
				bool(order.get("ok", false)) and int(order.get("effective_day", -1)) == MILITARY_DAY)
			commands.append({"operation": "military_target", "country": player_handle,
				"effective_day": MILITARY_DAY, "mode": 0, "value": MILITARY_TARGET})
		if stall and day == WARMUP_DAY + 1:
			hold = _run_hold(host, clock, WARMUP_DAY + RELEASE_DAYS)
		else:
			_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, economy, day)
		_expect("simulation and main tail both settle day %d" % day, settled)
		if not settled:
			print("BACKGROUND_DAILY_UNSETTLED=" + JSON.stringify(generator.get_runtime_thread_report()))
			break
		if day == 1:
			_expect("all 12 domains run on the worker", host.uses_worker_day_commits()
				and int(generator.get_runtime_thread_report().get("authoritative_domain_mask", 0)) == 0xFFF)
			_expect("four countries actually started", int(host._country_worker_read_last_result.get("country_count", 0)) == COUNTRY_COUNT)
		if day == CLAIM_DAY:
			_expect("territory transfer commits and runs background vision",
				map.physical_visible_arr[claim_cell] != 0 and bool(host._runtime_last_commit.get("vision_solved", false)))
		if day == MILITARY_DAY:
			_expect("military target takes effect in the background on the recorded day",
				int(military.country_snapshot(player_handle).get("target_value", -1)) == MILITARY_TARGET
				and int(military.report().get("background_day", -1)) == day)
		rows.append(await _summary(host, ext, day))
	var report := generator.get_runtime_thread_report()
	if not stall and rows.size() == WARMUP_DAY + RELEASE_DAYS:
		await _check_one_speed_military_seal(host, clock, economy, military, player_handle)
	return {"rows": rows, "commands": commands, "hold": hold, "report": report}


func _check_one_speed_military_seal(host: WorldRuntimeHost, clock: WorldClock,
		economy, military, player: int) -> void:
	var settled_day := WARMUP_DAY + RELEASE_DAYS
	var target := MILITARY_TARGET + 1
	clock.set_speed(1.0)
	var admission: Dictionary = military.set_target(player, 0, target)
	_expect("1x military command admitted after day %d" % settled_day, bool(admission.get("ok", false)))
	var actual := -1
	for day in range(settled_day + 1, settled_day + 3):
		_publish_day(host, clock, day)
		if not await _wait_golden_read_boundary(host, economy, day):
			_expect("1x military seal day %d commits" % day, false)
			return
		if int(military.country_snapshot(player).get("target_value", -1)) == target:
			actual = day
			break
	_expect("1x military command settles on its admitted day", actual == int(admission.get("effective_day", -2)))
	_expect_target_failure("military_seal_1x", actual == settled_day + 1,
		"issued after day %d; required day %d; admitted day %d, settled day %d" % [
			settled_day, settled_day + 1, int(admission.get("effective_day", -1)), actual])


func _publish_day(host: WorldRuntimeHost, clock: WorldClock, day: int) -> void:
	clock.current_day = float(day + 1)
	host._on_clock_day_changed(day + 1)


func _run_hold(host: WorldRuntimeHost, clock: WorldClock, target_day: int) -> Dictionary:
	var generator := host.get_generator()
	var ext: Object = generator.get_data_core_world_ext()
	var settled_before := int(ext.runtime_committed_day())
	var tail_before := host._runtime_tail_completed_day
	# Calendar admission no longer carries environment data. The remaining tail
	# acknowledgement still limits this pause to one completed day.
	host._on_clock_day_changed(target_day + 1)
	var admitted_through := host._calendar_admitted_through
	var frames_before := Engine.get_process_frames()
	var committed_before := int(ext.runtime_committed_day())
	var started := Time.get_ticks_usec()
	OS.delay_msec(HOLD_MSEC)
	var elapsed := Time.get_ticks_usec() - started
	var committed_after := int(ext.runtime_committed_day())
	var state := generator.get_runtime_control_state()
	return {
		"requested_through": target_day, "admitted_through": admitted_through,
		"admitted_in_one_request": admitted_through,
		"start_day": settled_before, "committed_before": committed_before,
		"committed_after": committed_after, "committed_during_hold": committed_after - committed_before,
		"tail_before_hold": tail_before, "tail_after_hold": host._runtime_tail_completed_day, "hold_usec": elapsed,
		"process_frames": Engine.get_process_frames() - frames_before,
		"worker_healthy": bool(state.get("authority_ready", false)) and state.get("simulation_host_state") != "FAULTED",
		"post_hold_waits": generator.get_runtime_thread_report().get("worker_main_wait_by_day", {}).get(committed_after, {}),
	}


func _summary(host: WorldRuntimeHost, ext: Object, day: int) -> Dictionary:
	var domains := await _read_domains(ext, day)
	var expected := DOMAINS + ["COUNTRY"]
	_expect("eight populated domain summaries for day %d" % day,
		domains.size() == expected.size() and domains.has_all(expected) and not _whole_economy_hash.is_empty())
	var map := host.current_map()
	_expect("vision and species cover the map on day %d" % day,
		map.physical_visible_arr.size() == map.cell_count() and map.explored_arr.size() == map.cell_count()
		and map.fog_k_arr.size() == map.cell_count() and map.bio_occupancy_bits_arr.size() == map.cell_count())
	var military: Dictionary = ext.get_military_report()
	_expect("military digest is available", int(military.get("state_hash", 0)) != 0)
	return {
		"day": day, "domains": domains, "whole_economy_hash": _whole_economy_hash,
		"military": str(military.get("state_hash", "")),
		"vision": _digest([map.physical_visible_arr.hex_encode(),
			map.explored_arr.hex_encode(), map.fog_k_arr.hex_encode()]),
		"species": _digest(map.bio_occupancy_bits_arr.to_byte_array().hex_encode()),
		"resources": _resource_state(ext, map.cell_count()).hash,
	}


func _military_archive_hash(host: WorldRuntimeHost) -> String:
	var generator := host.get_generator()
	var archive := CountryStateProvider.new()._write_military_provider({
		"military": generator.get_military_facade(),
		"military_progress": generator.get_military_daily_job(),
	})
	var bytes: PackedByteArray = archive.get("sections", {}).get("pkmi", PackedByteArray())
	_expect("complete PKMI including the event cursor is available", not bytes.is_empty())
	var hash_context := HashingContext.new()
	hash_context.start(HashingContext.HASH_SHA256)
	hash_context.update(bytes)
	return hash_context.finish().hex_encode()


func _find_hidden_unowned_land(map: MapData) -> int:
	for cell in range(map.physical_visible_arr.size()):
		if map.is_water_arr[cell] == 0 and map.country_slot_arr[cell] < 0 \
				and map.physical_visible_arr[cell] == 0:
			return cell
	return -1


func _expect_round_trip_report(report: Dictionary) -> bool:
	var present := report.has("worker_main_wait_by_day") and report.has("main_simulation_steps_by_day")
	_expect("both daily diagnostic fields present", present)
	return present


func _check_removed_round_trips(report: Dictionary, days: int) -> void:
	for day in range(1, days + 1):
		var steps: Dictionary = report.main_simulation_steps_by_day.get(day, {})
		var waits: Dictionary = report.worker_main_wait_by_day.get(day, {})
		var slot: Dictionary = waits.get("day_tail_task_slot", {})
		var tasks: Dictionary = slot.get("tasks", {})
		_expect("environment input does not wait for the main thread on day %d" % day,
			int(waits.get("environment_input", {}).get("count", 0)) == 0)
		_expect("seasonal refresh uses no task slot on day %d" % day,
			int(tasks.get("season", {}).get("count", 0)) == 0)
		for step in ["climate_writeback", "environment_capture", "environment_publish_hold",
				"modifier_snapshot_install", "season_freeze", "season_install", "annual_year_boundary_input",
				"narrative_daily", "stratum_unrest_daily", "narrative_choice_resolution",
				"narrative_effect_delivery", "stratum_independence_delivery"]:
			_expect("%s has no main-thread round trip on day %d" % [step, day],
				int(steps.get(step, 0)) == 0)
		for step in steps:
			if step not in ["queue_day_tail", "acknowledge_day_tail"]:
				_expect("only notification queue and tail acknowledgement remain on day %d (%s)" % [day, step],
					int(steps[step]) == 0)
		for reason in waits:
			if reason != "day_tail":
				_expect("only tail acknowledgement can block day %d (%s)" % [day, reason],
					int(waits[reason].get("count", 0)) == 0)
		var named_waits := 0
		for task in tasks.values():
			named_waits += int(task.count)
		_expect("every slot wait has a task name on day %d" % day,
			named_waits == int(slot.get("count", 0)))
		_expect("resource recovery has no main-thread round trip on day %d" % day,
			int(steps.get("resource_recovery_inputs", 0)) == 0
			and int(steps.get("resource_recovery_install", 0)) == 0
			and int(steps.get("economy_resource_writeback", 0)) == 0
			and not tasks.has("natural_resource_recovery"))
		_expect("species computation has no main-thread round trip on day %d" % day,
			int(steps.get("species_freeze", 0)) == 0 and int(steps.get("species_install", 0)) == 0
			and int(steps.get("species_observations", 0)) == 0 and not tasks.has("species"))
		for step in ["military_day_service", "military_install", "military_terrain_install",
				"military_vision_trail", "vision_inputs", "vision_install", "vision_observations",
				"territory_vision_input", "country_view_install"]:
			_expect("%s has no main-thread round trip on day %d" % [step, day],
				int(steps.get(step, 0)) == 0)
		for step in steps:
			if String(step).begins_with("military_") or String(step).begins_with("vision_"):
				_expect("%s is absent from day %d round trips" % [step, day], int(steps[step]) == 0)
		_expect("military and vision use no day-tail task slot on day %d" % day,
			int(tasks.get("military", {}).get("count", 0)) == 0
			and int(tasks.get("vision", {}).get("count", 0)) == 0)
		for step in ["country_peer_service", "country_milestone_delivery", "effect_snapshot_install",
				"effect_worker_ack", "effect_native_adapter", "trigger_snapshot_install", "trigger_worker_ack",
				"trigger_country_delivery", "research_signal_reconcile", "trigger_effect_handoff",
				"ideology_snapshot_install", "ideology_worker_ack", "ideology_instance_service",
				"ideology_projection_service", "ideology_projection_install", "era_advancement_daily"]:
			_expect("%s has no main-thread round trip on day %d" % [step, day],
				int(steps.get(step, 0)) == 0)
		_expect("ideology uses no day-tail task slot on day %d" % day,
			int(tasks.get("ideology_projection", {}).get("count", 0)) == 0)


func _check_narrative_boundary() -> void:
	var clock := WorldClock.new()
	clock.auto_start = false
	root.add_child(clock)
	clock.set_process(false)
	var host := _create_host()
	host.runtime_economy_auto_pod_active = true
	root.add_child(host)
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var controller := PlayerController.new()
	root.add_child(controller)
	controller.configure(null, null, host, clock, null)
	controller.restore_narrative_state({
		"last_popup_day": 0,
		"next_offer_id": 2,
		"ready_queue": [{"offer_id": 1, "cell_idx": -1, "bypass_pacing": false}],
		"scheduled_events": [
			{"due_day": 2, "event_id": "evt.ages.first_seed", "chain_id": "scheduled_first"},
			{"due_day": 2, "event_id": "evt.ages.first_grave", "chain_id": "scheduled_second"},
		],
	})
	var configured := host.configure_session({
		"kind": "new_game", "config": _background_config().to_dictionary()})
	_expect("formal narrative session configures", bool(configured.get("ok", false)))
	if bool(configured.get("ok", false)):
		await host.generate_world()
		var generator := host.get_generator()
		if host.is_runtime_ready_for_ticks() and generator != null:
			await _check_narrative_commit(host, clock, controller, generator)
		else:
			_expect("formal narrative session starts", false)
	_expect("formal narrative session closes", bool((await host.close_world()).get("ok", false)))
	controller.free()
	host.free()
	clock.free()


func _check_narrative_commit(host: WorldRuntimeHost, clock: WorldClock,
		controller: PlayerController, generator: MapGenerator) -> void:
	# Leave the real clock and release path running. Omit only the player's
	# display consumer so its modal cannot pause the worker for this test.
	host.simulation_committed.disconnect(controller._on_simulation_committed)
	var service: NarrativeEventService = controller.narrative_service()
	service.offer_ready.disconnect(controller.narrative_flow()._on_service_offer_ready)
	var economy: EconomyFacade = generator.get_economy_facade()
	var ext: Object = economy.world_ext()
	clock.set_speed(SPEED)
	for day in range(1, 3):
		_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, economy, day)
		_expect("narrative day %d settles with display disconnected" % day, settled)
		if not settled:
			return
	var first: Dictionary = ext.get_gameplay_narrative_view().get("active_offer", {})
	_expect("background publishes the first scheduled event",
		first.get("chain_id") == "scheduled_first" and int(first.get("day", -1)) == 2)
	_expect("remaining events stay queued", ext.get_gameplay_narrative_view().get("ready_queue", []).size() == 2)
	_publish_day(host, clock, 3)
	var frame := Engine.get_process_frames()
	OS.delay_msec(HOLD_MSEC)
	var committed := int(ext.runtime_committed_day())
	var state := generator.get_runtime_control_state()
	_expect("background awaits the player's choice after admission and without foreground frames",
		committed == 2 and host._calendar_admitted_through == 3
		and state.get("simulation_host_state") == "PAUSED"
		and not clock.paused and Engine.get_process_frames() == frame)
	print("NARRATIVE_BLOCK day=2 after=%d admitted=%d frames=%d state=%s" % [
		committed, host._calendar_admitted_through, Engine.get_process_frames() - frame,
		state.get("simulation_host_state", "")])
	for effective_day in [3, 4]:
		var chain := "scheduled_first" if effective_day == 3 else "scheduled_second"
		var offer: Dictionary = ext.get_gameplay_narrative_view().get("active_offer", {})
		_expect("background promotes %s before proceeding" % chain, offer.get("chain_id") == chain)
		if offer.is_empty():
			return
		var args := {"offer_id": int(offer.offer_id), "offer_generation": int(offer.offer_generation),
			"option_index": 0}
		var selected := controller.request_command(&"narrative.choose", args)
		_expect("choice is pending on the next day",
			bool(selected.get("ok", false)) and bool(selected.get("pending", false))
			and int(selected.get("effective_day", -1)) == effective_day
			and not selected.has("record"))
		var duplicate := controller.request_command(&"narrative.choose", args)
		_expect("the same choice cannot be accepted twice", not bool(duplicate.get("ok", false)))
		_publish_day(host, clock, effective_day)
		var continued := await _wait_golden_read_boundary(host, economy, effective_day)
		_expect("background commits the dated choice", continued)
		if not continued:
			return
		var last: Array = ext.get_gameplay_narrative_view().get("chronicle", [])
		_expect("chronicle confirms the option on its effective day", not last.is_empty()
			and last[0].get("chain_id") == chain and int(last[0].get("resolved_day", -1)) == effective_day)
		if effective_day == 3:
			var modifiers: Dictionary = ext.list_modifiers(2, 0, "")
			var keys: PackedStringArray = modifiers.get("definition_keys", PackedStringArray())
			_expect("first seed's actual modifiers are published on day 3",
				keys.has("economy.city.building.agriculture_output_factor")
				and keys.has("economy.city.need.staple_food.consumption_factor"))
	_expect("unpromoted queue entries cannot stop the executor",
		ext.get_gameplay_narrative_view().get("ready_queue", []).size() == 1)
	var report := generator.get_runtime_thread_report()
	if _expect_round_trip_report(report):
		_check_removed_round_trips(report, 4)


func _check_round_trips(report: Dictionary) -> void:
	var rows: Array = []
	var total_waits := 0
	var total_steps := 0
	var zero_every_day := true
	for day in range(1, WARMUP_DAY + 1):
		var waits: Dictionary = report.worker_main_wait_by_day.get(day, {})
		var steps: Dictionary = report.main_simulation_steps_by_day.get(day, {})
		var wait_count := 0
		var step_count := 0
		for reason in waits.values():
			wait_count += int(reason.count)
		for count in steps.values():
			step_count += int(count)
		total_waits += wait_count
		total_steps += step_count
		zero_every_day = zero_every_day and wait_count == 0 and step_count == 0
		rows.append({"day": day, "wait_count": wait_count, "main_step_count": step_count,
			"waits": waits, "main_steps": steps})
	print("BACKGROUND_DAILY_ROUND_TRIPS=" + JSON.stringify(rows))
	if _failures == 0:
		_expect_target_failure("B", zero_every_day,
			"required zero every day, counted %d waits and %d main steps across %d days" % [
				total_waits, total_steps, WARMUP_DAY])


func _expect_target_failure(case_id: String, target_met: bool, evidence: String) -> void:
	_checks += 1
	print("  [%s] %s %s" % ["XPASS" if target_met else "XFAIL", case_id, evidence])
	if target_met:
		_failures += 1


func _finish() -> void:
	print("background daily self-sufficiency: %d checks, %d unexpected failures" % [_checks, _failures])
	call_deferred("quit", 0 if _failures == 0 else 1)
