extends "res://tests/authority_stage_c_client_runner.gd"


func _on_world_ready(_map, _world_data, _generator, _view_adapter) -> void:
	if _world_ready:
		return
	_world_ready = true
	_apply_fixed_client_settings()
	var generator := _host.get_generator()
	var country = generator.get_country_facade()
	var ext = generator.get_data_core_world_ext()
	var handle := int(ext.get_country_cell_summary(_host._resolve_player_start_cell()).country_handle)
	var started := Time.get_ticks_msec()
	# Let the production worker establish its writer before the UI-equivalent command.
	while int(_runtime_report().get("simulation_committed_day", -1)) < 5:
		if Time.get_ticks_msec() - started > 30000:
			_fail("income test worker did not start")
			return
		await get_tree().process_frame
	var day := int(_runtime_report().get("simulation_committed_day", -1))
	var assessment_mode := int(_args.get("assessment_mode", 0))
	var income_rate := int(_args.get("income_rate", 1000 if assessment_mode == 0 else 1))
	var consumption_mode := int(_args.get("consumption_mode", 0))
	var consumption_rate := int(_args.get("consumption_rate", -10000))
	var subsidy_kind := int(_args.get("subsidy_kind", 1))
	var measurement_started := Time.get_ticks_usec()
	var controller = _player.get_node("PlayerController")
	var mixed_fiscal := _enabled(_args.get("mixed_fiscal", "false"))
	var subsidy_index := subsidy_kind
	if mixed_fiscal:
		var subsidy: Dictionary = controller.request_command(controller.COMMAND_COUNTRY_TAX_SET_DEFAULT,
			{"kind": subsidy_kind, "rate_basis_points": consumption_rate, "assessment_mode": consumption_mode})
		if not bool(subsidy.get("ok", false)):
			_fail("consumption subsidy rejected: %s" % subsidy)
			return
	var accepted: Dictionary = controller.request_command(controller.COMMAND_COUNTRY_TAX_SET_DEFAULT,
		{"kind": 0, "rate_basis_points": income_rate,
		"assessment_mode": assessment_mode})
	print("[income-tax-player/admission] %s" % accepted)
	if not bool(accepted.get("ok", false)):
		_fail("income policy rejected: %s" % accepted)
		return
	var mixed_seen := false
	var last_observed_day := -1
	while int(_runtime_report().get("simulation_committed_day", -1)) < day + 50:
		var report := _runtime_report()
		if int(report.get("worker_fault_count", 0)) > 0 or Time.get_ticks_msec() - started > 60000:
			print("[income-tax-player/economy] %s" % ext.get_economy_report())
			_fail("income policy stopped simulation: %s" % report)
			return
		var committed_day := int(report.get("simulation_committed_day", -1))
		if mixed_fiscal and committed_day != last_observed_day:
			last_observed_day = committed_day
			var snapshot: Dictionary = ext.get_country_fiscal_snapshot(handle)
			var reserved: PackedInt64Array = snapshot.get("subsidy_reserved", PackedInt64Array())
			var paid: PackedInt64Array = snapshot.get("subsidy_paid", PackedInt64Array())
			var taxes: PackedInt64Array = snapshot.get("collected", PackedInt64Array())
			if reserved.size() == 5 and paid.size() == 5 and taxes.size() == 5 \
					and reserved[subsidy_index] > paid[subsidy_index] and taxes[0] > 0:
				mixed_seen = true
		await get_tree().process_frame
	if mixed_fiscal and not mixed_seen:
		_fail("mixed fiscal fixture never returned unused subsidy and collected income tax together")
		return
	_clock.pause(true)
	_host.on_clock_running_changed(false)
	var economy: Dictionary = ext.get_economy_report()
	var fiscal: Dictionary = ext.get_country_fiscal_snapshot(handle)
	var policy: Dictionary = country.tax_policy_snapshot(handle)
	print("[income-tax-player/policy] rates=%s modes=%s receipts=%s" % [
		policy.get("default_rates_basis_points", []), policy.get("default_assessment_modes", []), country.poll_worker_command_receipts()])
	var collected: PackedInt64Array = fiscal.get("cumulative_collected", PackedInt64Array())
	if mixed_fiscal:
		print("[income-tax-player/mixed-fiscal] current collected=%s requested=%s reserved=%s paid=%s unmet=%s cumulative_subsidy_paid=%s" % [
			fiscal.get("collected", PackedInt64Array()),
			fiscal.get("subsidy_requested", PackedInt64Array()),
			fiscal.get("subsidy_reserved", PackedInt64Array()),
			fiscal.get("subsidy_paid", PackedInt64Array()),
			fiscal.get("subsidy_unmet", PackedInt64Array()),
			fiscal.get("cumulative_subsidy_paid", PackedInt64Array())])
	var subsidy_paid: PackedInt64Array = fiscal.get("cumulative_subsidy_paid", PackedInt64Array())
	if income_rate < 0 and (subsidy_paid.size() != 5 or subsidy_paid[0] <= 0):
		_fail("income subsidy was not paid: %s" % fiscal)
		return
	if income_rate < 0:
		var player_cell := _host._resolve_player_start_cell()
		var population: Dictionary = ext.get_population_cell_snapshot(player_cell)
		var cohort_subsidies: PackedInt64Array = population.get(
			"epoch_subsidy_received_by_cohort", PackedInt64Array())
		var cohort_subsidy_total := 0
		for amount in cohort_subsidies:
			cohort_subsidy_total += int(amount)
		if cohort_subsidy_total <= 0:
			_fail("income subsidy was not credited to a cohort account: %s" % population)
			return
	if mixed_fiscal and (subsidy_paid.size() != 5 or subsidy_paid[subsidy_index] <= 0):
		_fail("consumption subsidy was not paid: %s" % fiscal)
		return
	if bool(economy.get("fatal", false)) or int(economy.get("money_error", -1)) != 0 or int(economy.get("goods_error", -1)) != 0 or int(economy.get("population_error", -1)) != 0 or collected.is_empty() or (income_rate > 0 and collected[0] <= 0):
		_fail("income settlement did not conserve/collect: %s / %s" % [economy, fiscal])
		return
	var elapsed_ms := float(Time.get_ticks_usec() - measurement_started) / 1000.0
	print("[income-tax-player/timing] income_rate=%d mixed=%s run_ms=%.1f days_per_second=%.2f cumulative_subsidy_paid=%s" % [income_rate, mixed_fiscal, elapsed_ms, 50000.0 / elapsed_ms, subsidy_paid])
	print("[income-tax-player] PASS 50 committed days after income change; mixed_fiscal=%s; income_collected=%d; ledger_errors=0; writer=%s" % [mixed_seen, collected[0], _runtime_report().get("economy_production_writer", "unknown")])
	get_tree().quit(0)
