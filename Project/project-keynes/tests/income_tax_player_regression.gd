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
	var controller = _player.get_node("PlayerController")
	var accepted: Dictionary = controller.request_command(controller.COMMAND_COUNTRY_TAX_SET_DEFAULT,
		{"kind": 0, "rate_basis_points": 1000 if assessment_mode == 0 else 1,
		"assessment_mode": assessment_mode})
	print("[income-tax-player/admission] %s" % accepted)
	if not bool(accepted.get("ok", false)):
		_fail("income policy rejected: %s" % accepted)
		return
	while int(_runtime_report().get("simulation_committed_day", -1)) < day + 50:
		var report := _runtime_report()
		if int(report.get("worker_fault_count", 0)) > 0 or Time.get_ticks_msec() - started > 60000:
			print("[income-tax-player/economy] %s" % ext.get_economy_report())
			_fail("income policy stopped simulation: %s" % report)
			return
		await get_tree().process_frame
	_clock.pause(true)
	_host.on_clock_running_changed(false)
	var economy: Dictionary = ext.get_economy_report()
	var fiscal: Dictionary = ext.get_country_fiscal_snapshot(handle)
	var policy: Dictionary = country.tax_policy_snapshot(handle)
	print("[income-tax-player/policy] rates=%s modes=%s receipts=%s" % [
		policy.get("default_rates_basis_points", []), policy.get("default_assessment_modes", []), country.poll_worker_command_receipts()])
	var collected: PackedInt64Array = fiscal.get("cumulative_collected", PackedInt64Array())
	if bool(economy.get("fatal", false)) or int(economy.get("money_error", -1)) != 0 or int(economy.get("goods_error", -1)) != 0 or int(economy.get("population_error", -1)) != 0 or collected.is_empty() or collected[0] <= 0:
		_fail("income settlement did not conserve/collect: %s / %s" % [economy, fiscal])
		return
	print("[income-tax-player] PASS 50 committed days after income-only change; income_collected=%d; ledger_errors=0; writer=%s" % [collected[0], _runtime_report().get("economy_production_writer", "unknown")])
	get_tree().quit(0)
