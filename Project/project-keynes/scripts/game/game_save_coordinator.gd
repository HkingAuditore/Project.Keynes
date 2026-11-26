extends Node

const ArchiveContract = preload("res://scripts/game/save_archive_contract.gd")
const ExecutionContract = preload("res://scripts/game/save_execution_contract.gd")

const SaveSections = preload("res://scripts/game/save_state_sections.gd")

const BoundaryChecks = preload("res://scripts/game/save_boundary_checks.gd")
const NativeWorld = preload("res://scripts/data_core/native_world.gd")
const EconomyDisplay = preload("res://scripts/economy/economy_facade_display.gd")
signal save_completed(slot_id: String, result: Dictionary)
signal load_completed(slot_id: String, result: Dictionary)
signal _slot_verification_completed(slots: Array)

const REQUIRED_SECTIONS := ArchiveContract.REQUIRED_SECTIONS
const PKMI_SCHEMA := ArchiveContract.PKMI_SCHEMA
const SaveRepositoryScript = preload("res://scripts/game/save_repository.gd")
const ModuleRegistry = preload("res://scripts/game/runtime_module_registry.gd")
const WorldStateModules = preload("res://scripts/game/world_state_modules.gd")
const PksrBundleHeaderScript = preload("res://scripts/game/pksr_bundle_header.gd")
## 存档边界超时自己的现场。暂停期间 stall watchdog 不工作
## (WorldRuntimeHost._poll_simulation_stall_watchdog 在 paused 时直接 return)，
## 所以以前"暂停中存档失败"只有一行 warning，没有任何可比对的落盘产物。
const RuntimeForensicsScript = preload("res://scripts/game/runtime_forensics.gd")
## 边界等待期间每隔多少帧留一行活体探针。见 _wait_for_safe_boundary()。
const SAVE_BOUNDARY_PROBE_FRAMES := 30
const TECHNOLOGY_INDUSTRY_PROVIDER_ID := ArchiveContract.TECHNOLOGY_INDUSTRY_PROVIDER_ID
const TECHNOLOGY_INDUSTRY_REVISION := ArchiveContract.TECHNOLOGY_INDUSTRY_REVISION
const EXECUTION_CONTRACT_KEY := ArchiveContract.EXECUTION_CONTRACT_KEY
const EXECUTION_CONTRACT_PROVIDER_ID := ArchiveContract.EXECUTION_CONTRACT_PROVIDER_ID
const EXECUTION_CONTRACT_PAYLOAD_CODE := ArchiveContract.EXECUTION_CONTRACT_PAYLOAD_CODE
const EXECUTION_CONTRACT_MANIFEST_CODE := ArchiveContract.EXECUTION_CONTRACT_MANIFEST_CODE

var _repository = SaveRepositoryScript.new()
var _runtime_host: WorldRuntimeHost
var _world_clock: WorldClock
var _player_controller
var _pending_load: Dictionary = {}
var _pending_view: Dictionary = {}
var _runtime_generation := 0
var _last_autosave_year := -1
var _autosave_enabled := true
var _busy := false
var _slot_verification_active := false
var _providers: Array = []
var _provider_entries: Array = []
var _provider_registration_error: Dictionary = {}
var _economy_format: Dictionary = {}
var _next_runtime_save_request_id: int = 1


func _ready() -> void:
	_register_providers()
	_autosave_enabled = bool(GameSettings.values().get("autosave_enabled", true))
	var settings_callback := Callable(self, "_on_settings_changed")
	if not GameSettings.settings_changed.is_connected(settings_callback):
		GameSettings.settings_changed.connect(settings_callback)


func list_slots() -> Array:
	return _filter_compatible_slots(_repository.list_slots())


func list_slots_verified() -> Array:
	if OS.has_feature("web"):
		# Single-threaded exports verify at load; never decompress the list on UI.
		return list_slots()
	if _slot_verification_active:
		return _filter_compatible_slots(await _slot_verification_completed)
	_slot_verification_active = true
	var completion: Array = []
	var task := WorkerThreadPool.add_task(_repository.verify_slots_background.bind(completion),
		false, "Verify PKSV slots")
	var slots: Array = []
	if task >= 0:
		while not WorkerThreadPool.is_task_completed(task):
			await get_tree().process_frame
		var error := WorkerThreadPool.wait_for_task_completion(task)
		if error == OK and not completion.is_empty():
			slots = completion[0]
	if slots.is_empty():
		slots = _repository.list_slots()
		for slot in slots:
			if bool(slot.get("loadable", false)):
				slot.loadable = false
				slot.reason = "无法完成存档检查，请重新打开此列表。"
	_slot_verification_active = false
	_slot_verification_completed.emit(slots)
	return _filter_compatible_slots(slots)


func _filter_compatible_slots(slots: Array) -> Array:
	var running_contract := _running_execution_contract()
	for slot in slots:
		if not bool(slot.get("loadable", false)):
			continue
		var manifest = slot.get("provider_manifest", [])
		if _manifest_industry_revision(manifest) != TECHNOLOGY_INDUSTRY_REVISION:
			slot.loadable = false
			slot.reason = SaveRepositoryScript.LEGACY_INDUSTRY_REASON
		elif not _manifest_compatible(manifest):
			slot.loadable = false
			slot.reason = "存档需要的游戏系统或数据版本与当前游戏不兼容。"
		else:
			# Plan 11.5. The slot list reads the HEADER only, so `state_present`
			# is unknowable here; it never decides the flag (an unstamped entry is
			# deferred, not refused), only how the deferral is worded. A stamped
			# entry that differs from the live runtime is refused here early, so
			# the pause menu does not offer a load that cannot succeed.
			var contract := _execution_contract_verdict(manifest, running_contract, true)
			if not bool(contract.get("ok", false)):
				slot.loadable = false
				# The tooltip carries the CODE as well as the sentence, so a
				# refusal is greppable from a screenshot of the pause menu.
				slot.reason = "%s: %s" % [String(contract.get("code", "")),
					String(contract.get("message", ""))]
	return slots


func load_preview(slot_id: String) -> Dictionary:
	return _repository.load_preview(slot_id)


func bind_runtime(host: WorldRuntimeHost, clock: WorldClock,
		player_controller) -> void:
	if is_instance_valid(_world_clock) and _runtime_host == host \
			and _world_clock == clock and _player_controller == player_controller:
		return
	_disconnect_runtime_clock()
	_runtime_generation += 1
	_runtime_host = host
	_world_clock = clock
	_player_controller = player_controller
	_pending_view.clear()
	_last_autosave_year = clock.year_index() if is_instance_valid(clock) else -1
	if is_instance_valid(clock):
		clock.year_changed.connect(_on_year_changed.bind(_runtime_generation))
		clock.tree_exiting.connect(_on_runtime_exiting.bind(_runtime_generation))


func _disconnect_runtime_clock() -> void:
	if not is_instance_valid(_world_clock):
		return
	var year_callback := _on_year_changed.bind(_runtime_generation)
	var exit_callback := _on_runtime_exiting.bind(_runtime_generation)
	if _world_clock.year_changed.is_connected(year_callback):
		_world_clock.year_changed.disconnect(year_callback)
	if _world_clock.tree_exiting.is_connected(exit_callback):
		_world_clock.tree_exiting.disconnect(exit_callback)


func _on_runtime_exiting(generation: int) -> void:
	if generation != _runtime_generation:
		return
	_disconnect_runtime_clock()
	_runtime_generation += 1
	_runtime_host = null
	_world_clock = null
	_player_controller = null
	_pending_view.clear()
	_last_autosave_year = -1
	# An already frozen background write still owns _busy until it finishes.


func _session_active(generation: int) -> bool:
	return generation == _runtime_generation and is_instance_valid(_runtime_host) \
		and is_instance_valid(_world_clock) and not _runtime_host.is_session_closing()


func wait_for_pending_io() -> void:
	# Frozen writes belong to the repository, so scene cancellation must not
	# discard them. Application quit waits for their actual write/verify result.
	while _busy or _slot_verification_active:
		await get_tree().process_frame


func _session_cancelled() -> Dictionary:
	return _result(false, "save_session_changed", "游戏已切换，本次存档请求已取消。")


func request_manual_save(slot_id: String) -> Dictionary:
	if slot_id not in ["manual_1", "manual_2", "manual_3"]:
		return _result(false, "slot_invalid", "手动存档槽位无效。")
	return await _save(slot_id, "manual")


func request_autosave(reason: String) -> Dictionary:
	return await _save("autosave", reason)


func is_autosave_enabled() -> bool:
	return _autosave_enabled


## 开关经 GameSettings 持久化；settings_changed 信号会回同步 _autosave_enabled，
## 这里直接赋值只是让读写路径不依赖信号时序。
func set_autosave_enabled(enabled: bool) -> Dictionary:
	if enabled == _autosave_enabled:
		return _result(true, "ok", "")
	var updated: Dictionary = GameSettings.update({"autosave_enabled": enabled})
	if not bool(updated.get("ok", false)):
		return updated
	_autosave_enabled = enabled
	return _result(true, "ok", "")


func _on_settings_changed(settings: Dictionary) -> void:
	_autosave_enabled = bool(settings.get("autosave_enabled", true))


func load_slot(slot_id: String) -> Dictionary:
	return prepare_load(slot_id)


func delete_manual_slot(slot_id: String) -> Dictionary:
	if _busy:
		return _result(false, "save_busy", "已有存档请求正在处理。")
	return _repository.delete_manual_slot(slot_id)


func prepare_load(slot_id: String) -> Dictionary:
	if not _provider_registration_error.is_empty():
		return _provider_registration_error
	if _busy:
		return _result(false, "save_busy", "已有存档请求正在处理。")
	var container: Dictionary = _repository.load_slot(slot_id)
	if not bool(container.get("ok", false)):
		return container
	var manifest = container.header.get("provider_manifest", [])
	if _manifest_industry_revision(manifest) != TECHNOLOGY_INDUSTRY_REVISION:
		return _result(false, "technology_industry_revision_incompatible",
			SaveRepositoryScript.LEGACY_INDUSTRY_REASON)
	if not _manifest_compatible(manifest):
		return _result(false, "save_provider_incompatible",
			"存档版本与当前游戏不兼容，无法读取。")
	var bytes_by_id: Dictionary = container.get("section_bytes", {})
	# Plan 11.5. This runs in the session request, before a world exists, so the
	# running contract usually reads 0 here and the verdict defers; the refusal
	# for a certified mismatch is `restore_prepared_game`, which re-decides with
	# the live runtime and still precedes every provider restore.
	var contract := _execution_contract_verdict(manifest, _running_execution_contract(),
		_pkid_state_present(bytes_by_id))
	if not bool(contract.get("ok", false)):
		return _result(false, String(contract.get("code", EXECUTION_CONTRACT_MANIFEST_CODE)),
			String(contract.get("message", "")))
	var decoded := {}
	for provider in _providers:
		var unpacked: Dictionary = provider.decode_sections(bytes_by_id)
		if not bool(unpacked.get("ok", false)):
			return unpacked
		decoded.merge(unpacked.sections)
	_pending_load = {
		"slot_id": slot_id,
		"header": container.header,
		"sections": decoded,
		"execution_contract": contract,
	}
	return {"ok": true, "code": "ok", "message": "", "bundle": _pending_load.duplicate(true),
		"config": decoded.new_game_config}


func restore_prepared_game(host: WorldRuntimeHost) -> Dictionary:
	if not _provider_registration_error.is_empty():
		return _provider_registration_error
	if _pending_load.is_empty() or host == null:
		return _result(false, "load_not_prepared", "没有待恢复的存档。")
	var sections: Dictionary = _pending_load.sections
	var generator := host.generator()
	if generator == null:
		return _result(false, "load_runtime_missing", "地图尚未载入。")
	# Plan 11.5, the authoritative whole-package gate: the world now exists, so
	# the running contract is a real number and this refusal still precedes every
	# `provider.restore_sections` call, i.e. it refuses before anything mutates.
	var header: Dictionary = _pending_load.get("header", {})
	var contract := _execution_contract_verdict(header.get("provider_manifest", []),
		_running_execution_contract(host), _pkid_state_present(sections))
	if not bool(contract.get("ok", false)):
		push_warning("[save/restore] execution contract refused code=%s detail=%s saved=%d running=%d"
			% [String(contract.get("code", "")), String(contract.get("detail", "")),
				int(contract.get("saved", 0)), int(contract.get("running", 0))])
		return _result(false, String(contract.get("code", EXECUTION_CONTRACT_MANIFEST_CODE)),
			String(contract.get("message", "")))
	if bool(contract.get("deferred", false)):
		# NOT silent: the manifest could not certify the identity, so the PKID
		# payload is the authority for it. Recorded here so a load log always says
		# which layer made the call.
		push_warning("[save/restore] execution contract deferred to the PKID payload detail=%s"
			% String(contract.get("detail", "")))
	var context := _provider_context(host, generator, false, 0.0)
	for provider in _providers:
		var provider_result: Dictionary = provider.restore_sections(sections, context)
		if not bool(provider_result.get("ok", false)):
			return provider_result
	if not generator.has_method("finalize_save_restore_runtime"):
		return _result(false, "load_runtime_finalize_missing",
			"地图未能完成读档，请重试。")
	var finalized: Dictionary = generator.finalize_save_restore_runtime()
	if not bool(finalized.get("ok", false)):
		return _result(false, "load_runtime_finalize_failed",
			String(finalized.get("reason", "读档后调度器初始化失败。")))
	if not host.has_method("finalize_save_restore_visuals"):
		return _result(false, "load_visual_finalize_missing",
			"地图未能完成读档，请重试。")
	var visual_finalized: Dictionary = host.finalize_save_restore_visuals()
	var vision: Dictionary = visual_finalized.get("vision", {})
	if not bool(vision.get("ok", false)):
		# The visual finalize knows WHY it refused (e.g. `start_cell_drift`: the
		# regenerated world is not the saved world). Propagate that code and the
		# numeric detail so the load-failure report says what is actually wrong
		# instead of the generic "player country could not be bound".
		var vision_code := String(vision.get("code", ""))
		if vision_code.is_empty():
			vision_code = "load_visual_finalize_failed"
		var vision_failure := _result(false, vision_code,
			String(vision.get("reason", "读档后视野重建失败。")))
		var vision_detail := String(vision.get("detail", ""))
		if not vision_detail.is_empty():
			vision_failure["detail"] = vision_detail
		return vision_failure
	var slot_id := String(_pending_load.slot_id)
	_pending_load.clear()
	var result := _result(true, "ok", "")
	load_completed.emit(slot_id, result)
	return result


func pending_era_advancement() -> Dictionary:
	var state: Variant = _pending_view.get("era_advancement", {})
	return state if state is Dictionary else {}


func apply_pending_view(map: MapData) -> void:
	if _pending_view.is_empty():
		return
	if _player_controller != null:
		_player_controller.restore_view_state(map, _pending_view)
	_pending_view.clear()


func _save(slot_id: String, reason: String) -> Dictionary:
	if not _provider_registration_error.is_empty():
		return _provider_registration_error
	if _busy:
		return _result(false, "save_busy", "已有存档请求正在处理。")
	var generation := _runtime_generation
	if not _session_active(generation):
		return _result(false, "save_runtime_missing", "游戏尚未就绪。")
	var capture: Dictionary = _runtime_host.begin_state_capture()
	if not bool(capture.get("ok", false)):
		return _result(false, "save_runtime_not_ready", "游戏仍在准备或关闭中，暂时无法保存。")
	_busy = true
	var was_paused := _world_clock.paused
	var previous_speed := _world_clock.speed_multiplier
	var background_write := not OS.has_feature("web") \
		and OS.get_environment("PK_SAVE_SYNC_WRITE") != "1"
	var defer_provider_hashes := background_write \
		and OS.get_environment("PK_SAVE_PROVIDER_HASH_SYNC") != "1"
	_profile_save_window(true)
	_world_clock.pause(true)
	_runtime_host._sync_runtime_worker_clock()
	var boundary: Dictionary = await _wait_for_safe_boundary(generation)
	if not bool(boundary.get("ok", false)):
		_restore_clock_mode(was_paused, previous_speed, generation)
		_busy = false
		return boundary
	var runtime_bundle := await _capture_native_runtime_bundle(generation)
	if not bool(runtime_bundle.get("ok", false)):
		_restore_clock_mode(was_paused, previous_speed, generation)
		_busy = false
		return runtime_bundle
	_runtime_host._consume_runtime_commit_if_ready()
	if not _runtime_host.synchronize_environment_display_for_save():
		_restore_clock_mode(was_paused, previous_speed, generation)
		_busy = false
		return _result(false, "save_environment_display_failed", "未能同步已结算的地图环境，已取消保存。")
	var ext = _runtime_host.generator().get_data_core_world_ext()
	if ext != null:
		var resources := EconomyDisplay.apply_published_resources(ext)
		var species := BioOccupancyDailySystem.apply_published_occupancy(ext)
		var vision := _runtime_host.synchronize_vision_display_for_save()
		if not bool(vision.get("ok", false)):
			_restore_clock_mode(was_paused, previous_speed, generation)
			_busy = false
			return _result(false, "save_vision_writeback_failed", "视野未能写入地图，已取消保存。")
		if not bool(resources.get("ok", false)) or not bool(species.get("ok", false)):
			_restore_clock_mode(was_paused, previous_speed, generation)
			_busy = false
			return _result(false, "save_ecology_writeback_failed", "资源或物种未能写入地图，已取消保存。")
	var collected := _collect_sections(was_paused, previous_speed, runtime_bundle, defer_provider_hashes)
	if not bool(collected.get("ok", false)):
		_restore_clock_mode(was_paused, previous_speed, generation)
		_busy = false
		return collected
	var session := GameFlow.session()
	var config: Dictionary = session.get("new_game_config", {})
	var base: Dictionary = config.get("base", {})
	var country: Dictionary = config.get("country", {})
	var header := {
		"country_name": String(country.get("name", "未知国家")),
		"day": _world_clock.day_index(),
		"seed": int(base.get("initial_seed", _runtime_host.last_seed())),
		"width": int(base.get("map_width", 0)),
		"height": int(base.get("map_height", 0)),
		"saved_at": Time.get_datetime_string_from_system(true),
		"reason": reason,
		"technology_industry_revision": TECHNOLOGY_INDUSTRY_REVISION,
		"provider_manifest": collected.provider_manifest,
	}
	# provider 可能返回含运行时 PackedArray 的 Dictionary；在恢复时钟之前
	# 序列化成私有字节，后台任务不能再读 Node、facade 或活跃的世界容器。
	var frozen_sections := {}
	for section_id in collected.sections:
		var section = collected.sections[section_id]
		frozen_sections[section_id] = section if section is PackedByteArray else var_to_bytes(section)
	var result: Dictionary
	if not background_write:
		result = _repository.write_slot(slot_id, header, frozen_sections)
		_restore_clock_mode(was_paused, previous_speed, generation)
	else:
		# 捕获已经完成；恢复模拟后，压缩/SHA/回读验证/原子替换仍走原仓库路径。
		# _busy 保持到真正落盘完成，禁止另一个写入、删除或加载与它交叉。
		_restore_clock_mode(was_paused, previous_speed, generation)
		var completion: Array[Dictionary] = []
		var task := WorkerThreadPool.add_task(_repository.write_slot_background.bind(
			slot_id, header, frozen_sections, completion,
			collected.get("provider_hash_payloads", [])), false, "Write PKSV save")
		if task < 0:
			result = _result(false, "save_writer_failed", "无法启动后台存档写入。")
		else:
			while not WorkerThreadPool.is_task_completed(task):
				await get_tree().process_frame
			var task_error := WorkerThreadPool.wait_for_task_completion(task)
			result = completion[0] if task_error == OK and not completion.is_empty() \
				else _result(false, "save_writer_failed", "后台存档写入未完成。")
	_busy = false
	save_completed.emit(slot_id, result)
	return result


func _wait_for_safe_boundary(generation: int = -1) -> Dictionary:
	if generation < 0:
		generation = _runtime_generation
	const MAX_WAIT_FRAMES := 1800
	# 某些回执要到次日才会产生。时钟暂停后，避免持续重跑等待中的旧日系统。
	const MAX_STALL_FRAMES := 240
	const MAX_STALL_FRAMES_WEB := 90
	const MAX_WAIT_MSEC := 8000
	const MAX_WAIT_MSEC_WEB := 3000
	var is_web := OS.has_feature("web")
	var stall_cap := MAX_STALL_FRAMES_WEB if is_web else MAX_STALL_FRAMES
	var deadline_msec := Time.get_ticks_msec() + (MAX_WAIT_MSEC_WEB if is_web else MAX_WAIT_MSEC)
	var last_boundary := {}
	var last_code := ""
	var stall_frames := 0
	for frame in range(MAX_WAIT_FRAMES):
		if not _session_active(generation):
			return _session_cancelled()
		var boundary := _can_save()
		if bool(boundary.get("ok", false)):
			return boundary
		last_boundary = boundary
		var code := String(boundary.get("code", ""))
		if code not in ["save_requires_committed_boundary", "save_requires_idle_worker", "save_requires_idle_country", \
			"save_requires_idle_country_peer", \
			"save_requires_idle_effect", "save_requires_idle_ideology", \
			"save_requires_idle_effect_country", "save_requires_idle_effect_economy", \
			"save_requires_idle_effect_gameplay"]:
			return boundary
		if code == last_code:
			stall_frames += 1
		else:
			last_code = code
			stall_frames = 0
		if stall_frames >= stall_cap or Time.get_ticks_msec() >= deadline_msec:
			break
		# 暂停期间这个项目里没有别的活体探针：WorldClock._process 在 paused 时首行
		# 就 return（[clock/rate] / [clock/step] 全静音），
		# WorldRuntimeHost._poll_simulation_stall_watchdog 也直接 return，于是
		# "到底卡在哪一条边界"以前只有超时之后那一行 warning 才看得到。
		# 等待过程中按固定间隔留痕，超时之前就能判断方向。
		if frame % SAVE_BOUNDARY_PROBE_FRAMES == 0:
			# frame 0 只留一行短的：正常的存档经常就在这里等一两帧，不该每次都
			# 刷一坨 JSON。真正的现场按间隔展开，只有卡住时才会出现。
			if frame == 0:
				print("[save] boundary wait begin code=%s condition=%s" % [
					code, String(boundary.get("blocking_condition", ""))])
			else:
				print("[save] boundary wait frame=%d code=%s condition=%s detail=%s" % [
					frame, code, String(boundary.get("blocking_condition", "")),
					JSON.stringify(_boundary_diagnostics())])
		await get_tree().process_frame
	if not _session_active(generation):
		return _session_cancelled()
	var blocking_code := String(last_boundary.get("code", ""))
	var blocking_condition := String(last_boundary.get("blocking_condition", ""))
	var diagnostics := _boundary_diagnostics()
	push_warning("[save] boundary timeout blocking=%s condition=%s stalled_frames=%d detail=%s" % [
		blocking_code, blocking_condition, stall_frames, JSON.stringify(diagnostics)])
	# 把这次失败的现场落盘，和 economy_fatal / stall 走同一条取证通道。
	# 只写文件、不改状态：恢复时钟与 _busy 复位仍由 _save() 的失败分支负责。
	RuntimeForensicsScript.capture_and_dump("save_boundary_timeout",
		_runtime_host.generator() if _runtime_host != null else null,
		_world_clock, "save_boundary_timeout", {
			"blocking_code": blocking_code,
			"blocking_condition": blocking_condition,
			"stalled_frames": stall_frames,
			"is_web": is_web,
			"boundary_detail": diagnostics,
		})
	# 让玩家贴出来的那一行截图自带方向：code 之外再带 condition。
	var blocking_text := blocking_code if blocking_condition.is_empty() \
		else "%s / %s" % [blocking_code, blocking_condition]
	var timeout := _result(false, "save_boundary_timeout",
		"等待国家与经济提交边界超时（阻塞：%s）。" % blocking_text)
	timeout["blocking_code"] = blocking_code
	timeout["blocking_condition"] = blocking_condition
	return timeout


func _boundary_diagnostics() -> Dictionary:
	return BoundaryChecks._boundary_diagnostics(self)


func _can_save() -> Dictionary:
	return BoundaryChecks._can_save(self)


func _worker_idle_blocker(thread: Dictionary) -> String:
	return BoundaryChecks._worker_idle_blocker(thread)


func _collect_sections(saved_paused: bool, saved_speed: float,
		native_bundle: Dictionary, defer_provider_hashes: bool = false) -> Dictionary:
	return SaveSections._collect_sections(self, saved_paused, saved_speed, native_bundle, defer_provider_hashes)


func _economy_checkpoint_format() -> Dictionary:
	return SaveSections._economy_checkpoint_format(self)


func _register_providers() -> void:
	SaveSections._register_providers(self)


func _install_provider_entries(entries: Array) -> Dictionary:
	return SaveSections._install_provider_entries(self, entries)


func register_state_module(provider, restore_after: PackedStringArray) -> Dictionary:
	return SaveSections.register_state_module(self, provider, restore_after)


func _provider_context(host: WorldRuntimeHost, generator: MapGenerator,
		saved_paused: bool, saved_speed: float) -> Dictionary:
	return SaveSections._provider_context(self, host, generator, saved_paused, saved_speed)


func _manifest_compatible(raw_manifest) -> bool:
	return ExecutionContract._manifest_compatible(self, raw_manifest)


func _manifest_industry_revision(raw_manifest) -> int:
	return ExecutionContract._manifest_industry_revision(raw_manifest)


func _running_execution_contract(host = null) -> int:
	return ExecutionContract._running_execution_contract(self, host)


func _contract_from_report(report) -> int:
	return ExecutionContract._contract_from_report(self, report)


func _contract_value(value) -> int:
	return ExecutionContract._contract_value(value)


static func _manifest_entry_for(raw_manifest, provider_id: String) -> Dictionary:
	return ExecutionContract._manifest_entry_for(raw_manifest, provider_id)


static func _pkid_state_present(sections) -> bool:
	return ExecutionContract._pkid_state_present(sections)


func _execution_contract_verdict(raw_manifest, running: int,
		state_present: bool) -> Dictionary:
	return ExecutionContract._execution_contract_verdict(self, raw_manifest, running, state_present)


func _contract_verdict(ok: bool, detail: String, running: int, saved: int,
		deferred: bool) -> Dictionary:
	return ExecutionContract._contract_verdict(self, ok, detail, running, saved, deferred)


func _contract_verdict_message(detail: String, running: int, saved: int) -> String:
	return ExecutionContract._contract_verdict_message(detail, running, saved)


func _capture_native_runtime_bundle(generation: int = -1) -> Dictionary:
	if generation < 0:
		generation = _runtime_generation
	if not _session_active(generation):
		return _session_cancelled()
	if _runtime_host == null or _runtime_host.generator() == null:
		return {"ok": true, "bytes": PackedByteArray(),
			"country_pkcn": PackedByteArray()}
	var generator := _runtime_host.generator()
	if not generator.has_method("get_runtime_thread_report") \
			or not generator.has_method("request_runtime_save") \
			or not generator.has_method("poll_runtime_save"):
		return {"ok": true, "bytes": PackedByteArray(),
			"country_pkcn": PackedByteArray()}
	var report: Dictionary = generator.get_runtime_thread_report()
	var mode := String(report.get("requested_simulation_thread_mode", "OFF"))
	if mode == "OFF":
		return {"ok": true, "bytes": PackedByteArray(),
			"country_pkcn": PackedByteArray()}
	var request_id := _next_runtime_save_request_id
	_next_runtime_save_request_id += 1
	if _next_runtime_save_request_id <= 0:
		_next_runtime_save_request_id = 1
	var requested: Dictionary = generator.request_runtime_save(request_id)
	if not bool(requested.get("ok", false)):
		return _result(false, String(requested.get("code", "runtime_save_request_failed")),
			"后台 runtime 保存请求失败。")
	const MAX_POLL_FRAMES := 1800
	for _frame in MAX_POLL_FRAMES:
		if not _session_active(generation):
			return _session_cancelled()
		var polled: Dictionary = generator.poll_runtime_save(request_id)
		if not bool(polled.get("ok", true)) and not bool(polled.get("pending", false)):
			var failed := _result(false, String(polled.get("code", "runtime_save_failed")),
				"后台 runtime 保存失败：%s" % String(polled.get("reason", "")))
			failed["reason"] = String(polled.get("reason", ""))
			push_warning("[save] runtime bundle failed: %s" % JSON.stringify(polled))
			return failed
		if bool(polled.get("ready", false)):
			var bytes: PackedByteArray = polled.get("bytes", PackedByteArray())
			if not _valid_native_runtime_bundle(bytes, polled):
				return _result(false, "simulation_runtime_checksum_failed",
					"后台 runtime bundle 校验失败。")
			return {"ok": true, "bytes": bytes,
				"country_pkcn": polled.get("country_pkcn", PackedByteArray()),
				"economy_ecp2": polled.get("economy_ecp2", PackedByteArray()),
				"pkmi": polled.get("pkmi", PackedByteArray()),
				"pknr": polled.get("pknr", PackedByteArray())}
		var state := String(generator.get_runtime_thread_report().get(
			"simulation_host_state", ""))
		if state == "FAULTED":
			return _result(false, "worker_faulted", "后台模拟线程发生故障，无法保存。")
		await get_tree().process_frame
	# 超时时 worker 停在哪一步只有 thread report 知道；不带上它，这条失败在日志里
	# 只剩一行 code，无法区分"准入条件不满足"和"worker 卡在某个 stage"。
	if not _session_active(generation):
		return _session_cancelled()
	var timeout := _result(false, "runtime_save_timeout", "等待后台 runtime 保存超时。")
	timeout["runtime_thread"] = generator.get_runtime_thread_report()
	push_warning("[save] runtime_save_timeout thread=%s" % JSON.stringify(
		timeout["runtime_thread"]))
	return timeout


func _valid_native_runtime_bundle(bytes: PackedByteArray,
		polled: Dictionary = {}) -> bool:
	# PKSR v4 contains the immutable runtime envelope. The container section hash
	# is checked by SaveRepository; the header contract lives in PksrBundleHeader
	# so it stays next to the offsets it depends on.
	return PksrBundleHeaderScript.valid(bytes, polled)


func _profile_save_window(active: bool) -> void:
	if _runtime_host == null or _runtime_host.generator() == null:
		return
	var ext = _runtime_host.generator().get_data_core_world_ext()
	if ext != null:
		ext.profile_runtime_save_window(active)


func _restore_clock_mode(was_paused: bool, previous_speed: float, generation: int) -> void:
	if not _session_active(generation):
		return
	_profile_save_window(false)
	_runtime_host.end_state_capture()
	_world_clock.speed_multiplier = previous_speed
	_world_clock.pause(was_paused)


func _on_year_changed(year: int, generation: int = -1) -> void:
	if generation < 0:
		generation = _runtime_generation
	if not _session_active(generation):
		return
	# Year 0 is the clock's initial publication, not a completed game year.
	if year <= 0 or year <= _last_autosave_year:
		return
	_last_autosave_year = year
	if not _autosave_enabled:
		# 禁用期间仍推进年份标记：重新启用后从下一个完整年份开始存档，
		# 而不是在开关切回的那一刻立刻补写一次。
		return
	call_deferred("_autosave_year", year, generation)


func _autosave_year(year: int, generation: int) -> void:
	if not _session_active(generation):
		return
	# The annual grant is part of this checkpoint, including an unread report.
	var deadline: int = Time.get_ticks_msec() + 30000
	while _session_active(generation) and _runtime_host.annual_reports_waiting_for_year(year):
		if Time.get_ticks_msec() >= deadline or _runtime_host.is_runtime_fault_paused():
			_last_autosave_year = year - 1
			return
		await get_tree().process_frame
	if not _session_active(generation):
		return
	var result := await request_autosave("year_%d" % year)
	if _session_active(generation) and not bool(result.get("ok", false)):
		# A busy boundary is retried on the next committed day through the player
		# host; the year marker prevents duplicate completed writes.
		_last_autosave_year = year - 1


static func _result(ok: bool, code: String, message: String) -> Dictionary:
	return ArchiveContract.result(ok, code, message)


func _clock_restored(year: int) -> void:
	_last_autosave_year = year

## Preserve the precise save-boundary condition for failure diagnostics.
static func _blocked_result(code: String, message: String, condition: String) -> Dictionary:
	return ArchiveContract.blocked_result(code, message, condition)

func _set_pending_view(view: Dictionary) -> void:
	_pending_view = view
