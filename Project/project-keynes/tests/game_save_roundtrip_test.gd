extends Node

var _failures := PackedStringArray()
var _game_flow: Node
var _game_save: Node


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_game_flow = get_tree().root.get_node_or_null("GameFlow")
	_game_save = get_tree().root.get_node_or_null("GameSave")
	_expect("game flow autoload is available", _game_flow != null)
	_expect("game save autoload is available", _game_save != null)
	if _game_flow == null or _game_save == null:
		_finish()
		return
	# 这个测试会写 manual_1/2/3。指向玩家真实存档目录时拒绝运行，否则每跑一次
	# 就把玩家的手动存档轮换进 .bak 再覆盖掉。用 PK_SAVE_DIR 指到临时目录。
	var repository = _game_save.get("_repository")
	var save_dir := String(repository.get("_save_dir")) if repository != null else ""
	if save_dir == SaveRepository.SAVE_DIR:
		_expect("PK_SAVE_DIR points the round-trip away from the player's saves", false)
		_finish()
		return
	var config := NewGameConfig.new()
	config.country.name = "Roundtrip Nation"
	var foreign_count_override := OS.get_environment("PK_GAME_SAVE_FOREIGN_COUNT")
	config.country.foreign_count = (
		int(foreign_count_override)
		if not foreign_count_override.is_empty()
		else 3
	)
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var previous_scene := get_tree().current_scene
	var begin: Dictionary = _game_flow.call("begin_new_game", config)
	_expect("new game request accepted", bool(begin.get("ok", false)))
	var first_host: WorldRuntimeHost = await _wait_for_runtime(previous_scene)
	_expect("new game reached ready runtime", first_host != null)
	if first_host == null:
		_finish()
		return

	var first_scene := first_host.get_parent() as PlayerGame
	var first_clock: WorldClock = first_scene.get_node("WorldClock")
	first_clock.speed_multiplier = 0.0
	first_clock.pause(false)
	_expect("new game binds a valid player country for vision",
		first_host.player_country_slot() >= 0)
	_expect("new game has non-empty explored progress",
		_count_nonzero(first_host.current_map().explored_arr) > 0)
	# 首次结算之前没有可恢复的已提交账本。过去这种存档会在 worker 里 set_fault、
	# 再被状态覆盖藏起来，表现为 1800 帧后 runtime_save_timeout 且 worker 失去全部权威。
	var early: Dictionary = await _game_save.call("request_manual_save", "manual_1")
	_expect("save before first settlement is rejected with its own code",
		String(early.get("code", "")) == "save_requires_first_settlement")
	_expect("rejected early save leaves the worker healthy",
		String(first_host.generator().get_runtime_thread_report().get(
			"simulation_host_state", "")) != "FAULTED")
	_expect("new game reaches its first economy settlement",
		await _advance_to_first_settlement(first_host, first_clock))
	# 多跑一段再存档，让国家状态真的在 worker 上发生变化。只跑到首次结算时
	# 国家与开局一模一样，"worker 上的国家进展在存档时丢失"会原样通过。
	var capital_cell := int(first_host.generator().gameplay_start_report().get("cell", -1))
	var country_facade = first_host.generator().get_country_facade()
	var start_capital: Dictionary = country_facade.cell_summary(capital_cell)
	var player_handle := int(start_capital.get("country_handle", 0))
	# 所得税 10%：改写国家税率状态，此后每个结算周期都有税款入国库。
	var tax_change: Dictionary = country_facade.set_tax_default(
		player_handle, CountryFacade.TaxKind.INCOME, 10, first_clock.day_index() + 1, 1)
	_expect("income tax change is admitted", bool(tax_change.get("ok", false)))
	await _advance_days(first_host, first_clock, 20)
	_expect("country state actually changed on the worker before saving",
		int(country_facade.cell_summary(capital_cell).get("cash", 0)) \
			!= int(start_capital.get("cash", 0)))
	var expected := _capture_hashes(first_host, first_clock)
	var expected_environment: Dictionary = \
		first_host.generator().export_environment_runtime_state()
	var save_result: Dictionary = await _game_save.call("request_manual_save", "manual_3")
	# 存档完成后再取样：speed=0 时 worker 仍会把 ring 里已挂起的输入跑完，
	# 存档前取的值可能比真正写进存档的状态早一次提交。
	var expected_capital: Dictionary = country_facade.cell_summary(capital_cell)
	var expected_tax: Dictionary = country_facade.tax_policy_snapshot(player_handle)
	var saved_environment: Dictionary = \
		first_host.generator().export_environment_runtime_state()
	if _hash_variant(saved_environment) != _hash_variant(expected_environment):
		print("[save-roundtrip] environment drifted during the save call: %s" % [
			_diff_keys(expected_environment, saved_environment)])
	if not bool(save_result.get("ok", false)):
		# 不打出 code/message 的话，一次写档失败在日志里只剩一行 FAIL，
		# 既看不出是边界没停稳还是 provider 缺 section。
		print("[save-roundtrip] manual save rejected: %s" % JSON.stringify(save_result))
	_expect("PKSV manual save completed", bool(save_result.get("ok", false)))
	var save_header: Dictionary = save_result.get("header", {})
	_expect("save header declares technology industry revision 2",
		int(save_header.get("technology_industry_revision", 0)) == 2)
	_expect("provider manifest declares technology industry revision 2",
		_manifest_schema(save_header.get("provider_manifest", []),
			"technology_industry") == 2)
	var slots: Array = _game_save.call("list_slots")
	var slot := _slot(slots, "manual_3")
	_expect("saved slot is visible and loadable",
		bool(slot.get("exists", false)) and bool(slot.get("loadable", false)))
	_expect("save restores request-time pause state",
		not first_clock.paused and is_zero_approx(first_clock.speed_multiplier))
	if not bool(save_result.get("ok", false)):
		_finish()
		return
	await _verify_wiped_fog_is_never_persisted(first_host)

	var load_begin: Dictionary = _game_flow.call("begin_load_game", "manual_3")
	_expect("load request accepted", bool(load_begin.get("ok", false)))
	var loaded_host: WorldRuntimeHost = await _wait_for_runtime(first_scene)
	_expect("load reached ready runtime", loaded_host != null)
	if loaded_host != null:
		var loaded_scene := loaded_host.get_parent() as PlayerGame
		var loaded_clock: WorldClock = loaded_scene.get_node("WorldClock")
		var loaded_generator := loaded_host.generator()
		_expect("load finalized restore-only country/economy bootstrap",
			String(loaded_generator.gameplay_start_report().get(
				"settlement_source", "")) == "save_restore")
		_expect("restored native authorities are bootstrapped",
			bool(loaded_generator.get_country_report().get("bootstrapped", false))
			and bool(loaded_generator.get_economy_report().get("bootstrapped", false)))
		_expect("restored economy trade topology is ready",
			bool(loaded_generator.get_economy_report().get("trade_topology_ready", false)))
		var actual := _capture_hashes(loaded_host, loaded_clock)
		if str(actual.get("environment", "")) != str(expected.get("environment", "")):
			# 整份 hash 只能说"不一样"；逐键给出差异才看得出是哪个字段没进存档。
			print("[save-roundtrip] environment keys differing after load: %s" % [
				_diff_keys(expected_environment,
					loaded_host.generator().export_environment_runtime_state())])
		for key in expected:
			_expect("round-trip hash %s" % key, str(actual.get(key, "")) == str(expected[key]))
		# cell_summary 读的是 worker 已提交状态的查询副本，也就是玩家在 UI 上
		# 看到的国家。存读档前后必须逐字段一致。
		var loaded_capital: Dictionary = loaded_generator.get_country_facade() \
			.cell_summary(capital_cell)
		# 读档后主线程会为下一天重新捕获环境输入，而 worker 从恢复那一刻就拥有
		# 权威，测试读到时它可能已经提交了一天。generation 相同必须逐字段相等；
		# 前进了一次则身份/领地/科技不变，国库只可能因收税而增加。
		var saved_generation := int(expected_capital.get("generation", 0))
		var loaded_generation := int(loaded_capital.get("generation", 0))
		_expect("loaded country starts from the saved generation (%d -> %d)" % [
			saved_generation, loaded_generation],
			loaded_generation == saved_generation or loaded_generation == saved_generation + 1)
		for key in ["country_handle", "technology_count", "territory_count",
				"nonzero_good_count"]:
			_expect("capital country %s survives save/load (%s -> %s)" % [
				key, str(expected_capital.get(key)), str(loaded_capital.get(key))],
				str(loaded_capital.get(key)) == str(expected_capital.get(key)))
		if loaded_generation == saved_generation:
			_expect("capital country cash survives save/load exactly (%s -> %s)" % [
				str(expected_capital.get("cash")), str(loaded_capital.get("cash"))],
				int(loaded_capital.get("cash", -1)) == int(expected_capital.get("cash", -2)))
		else:
			_expect("capital country cash continues from the saved treasury (%s -> %s)" % [
				str(expected_capital.get("cash")), str(loaded_capital.get("cash"))],
				int(loaded_capital.get("cash", -1)) >= int(expected_capital.get("cash", 0)))
		var loaded_tax: Dictionary = loaded_generator.get_country_facade() \
			.tax_policy_snapshot(player_handle)
		_expect("country tax policy survives save/load",
			str(loaded_tax.get("rates", "")) == str(expected_tax.get("rates", "")))
		_expect("load rebinds a valid player country for vision",
			loaded_host.player_country_slot() >= 0)
		_expect("load preserves non-empty explored progress",
			_count_nonzero(loaded_host.current_map().explored_arr) > 0)
		_expect("loaded clock retains unpaused zero-speed mode",
			not loaded_clock.paused and is_zero_approx(loaded_clock.speed_multiplier))
		await _verify_post_restore_cycle(loaded_host, loaded_clock)
	_finish()


## 探索进度是单调的玩家资产。视野解算一旦失效（历史 bug 会把玩家国家绑成 -1），
## 写档必须先自修复，修不好就拒绝落盘，绝不能把全 0 位图盖到上一份存档上。
func _verify_wiped_fog_is_never_persisted(host: WorldRuntimeHost) -> void:
	var wiped := PackedByteArray()
	wiped.resize(host.current_map().cell_count())
	host.current_map().explored_arr = wiped
	var guarded: Dictionary = await _game_save.call("request_manual_save", "manual_2")
	if not bool(guarded.get("ok", false)):
		_expect("wiped fog save is rejected with the vision code",
			String(guarded.get("code", "")) == "pkfg_vision_unsolved")
		return
	var probe: Dictionary = _game_save.call("prepare_load", "manual_2")
	var bundle: Dictionary = probe.get("bundle", {})
	var sections: Dictionary = bundle.get("sections", {})
	var pkfg: Dictionary = sections.get("pkfg", {})
	_expect("save never persists an empty explored bitmap",
		_count_nonzero(PackedByteArray(pkfg.get("explored", PackedByteArray()))) > 0)


func _verify_post_restore_cycle(host: WorldRuntimeHost, clock: WorldClock) -> void:
	var generator := host.generator()
	var start_day := clock.day_index()
	var target_day := start_day + 6
	var start_economy: Dictionary = generator.get_economy_report()
	var start_newest_day := int(start_economy.get("newest_state_day", -1))
	print("[save-roundtrip/post-restore] before cycle clock=%s country=%s economy=%s" % [
		JSON.stringify(clock.export_state()),
		JSON.stringify(generator.get_country_report()),
		JSON.stringify(start_economy),
	])
	clock.set_speed(1.0)
	clock.pause(false)
	for frame in range(1200):
		await get_tree().process_frame
		var economy: Dictionary = generator.get_economy_report()
		if bool(economy.get("fatal", false)):
			break
		if clock.day_index() >= target_day and \
				int(economy.get("newest_state_day", -1)) > start_newest_day:
			print("[save-roundtrip/post-restore] cycle completed day=%d frame=%d economy=%s" % [
				clock.day_index(), frame, JSON.stringify(economy),
			])
			_expect("loaded runtime advances through a full economy settlement cycle", true)
			_expect("loaded economy remains non-fatal after its first settlement cycle",
				not bool(economy.get("fatal", false)))
			clock.set_speed(0.0)
			return
	print("[save-roundtrip/post-restore] timeout clock=%s country=%s economy=%s" % [
		JSON.stringify(clock.export_state()),
		JSON.stringify(generator.get_country_report()),
		JSON.stringify(generator.get_economy_report()),
	])
	_expect("loaded runtime advances through a full economy settlement cycle", false)
	_expect("loaded economy remains non-fatal after its first settlement cycle",
		not bool(generator.get_economy_report().get("fatal", false)))
	clock.set_speed(0.0)


func _advance_days(host: WorldRuntimeHost, clock: WorldClock, days: int) -> void:
	var generator := host.generator()
	var target := clock.day_index() + days
	clock.set_speed(8.0)
	clock.pause(false)
	for _frame in range(4800):
		await get_tree().process_frame
		var economy: Dictionary = generator.get_economy_report()
		if bool(economy.get("fatal", false)):
			break
		if clock.day_index() >= target and not bool(economy.get("epoch_active", false)):
			break
	clock.set_speed(0.0)


func _advance_to_first_settlement(host: WorldRuntimeHost, clock: WorldClock) -> bool:
	var generator := host.generator()
	clock.set_speed(4.0)
	clock.pause(false)
	for _frame in range(2400):
		await get_tree().process_frame
		var economy: Dictionary = generator.get_economy_report()
		if bool(economy.get("fatal", false)):
			break
		if int(economy.get("last_committed_day", -1)) >= 0 \
				and not bool(economy.get("epoch_active", false)):
			clock.set_speed(0.0)
			return true
	clock.set_speed(0.0)
	print("[save-roundtrip] first settlement not reached economy=%s" % JSON.stringify(
		generator.get_economy_report()))
	return false


func _wait_for_runtime(previous_scene) -> WorldRuntimeHost:
	for _frame in range(2400):
		await get_tree().process_frame
		var scene_ref := get_tree().current_scene
		if scene_ref == null or scene_ref == previous_scene or not scene_ref is PlayerGame:
			continue
		var host := scene_ref.get_node_or_null("RuntimeHost") as WorldRuntimeHost
		if host != null and host.current_map() != null and host.generator() != null \
				and bool(host.generator().gameplay_start_report().get("ok", false)):
			await get_tree().process_frame
			return host
	return null


func _capture_hashes(host: WorldRuntimeHost, clock: WorldClock) -> Dictionary:
	var generator := host.generator()
	var hashes := {}
	hashes.clock = _hash_variant(clock.export_state())
	hashes.dynamic_world = _hash_variant(generator.get_data_core_world().serialize())
	hashes.environment = _hash_variant(generator.export_environment_runtime_state())
	hashes.country = str(generator.get_country_facade().report().get("state_hash", ""))
	hashes.economy = str(generator.get_economy_facade().report().get("state_hash", ""))
	hashes.session = _hash_variant(_game_flow.call("session"))
	# PKFG：cell_explored 是单调累积的玩家进度，重算不回来，必须逐字节对上。
	hashes.explored = _hash_variant(host.current_map().explored_arr)
	return hashes


func _diff_keys(before: Dictionary, after: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var keys := before.keys()
	for key in after.keys():
		if not before.has(key):
			keys.append(key)
	for key in keys:
		if not after.has(key) or not before.has(key):
			out.append("%s(missing)" % str(key))
		elif _hash_variant(before[key]) != _hash_variant(after[key]):
			var detail := ""
			if before[key] is Dictionary and after[key] is Dictionary:
				detail = str(_diff_keys(before[key], after[key]))
			out.append("%s%s" % [str(key), detail])
	return out


func _hash_variant(value) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()


func _count_nonzero(values: PackedByteArray) -> int:
	var count := 0
	for value in values:
		count += 1 if value != 0 else 0
	return count


func _slot(slots: Array, slot_id: String) -> Dictionary:
	for value in slots:
		if String((value as Dictionary).get("slot_id", "")) == slot_id:
			return value
	return {}


func _manifest_schema(manifest, provider_id: String) -> int:
	if not manifest is Array:
		return -1
	for value in manifest:
		if value is Dictionary and String(value.get("provider_id", "")) == provider_id:
			return int(value.get("schema_version", -1))
	return -1


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


func _finish() -> void:
	print("game save round-trip: %d failures" % _failures.size())
	get_tree().quit(0 if _failures.is_empty() else 1)
