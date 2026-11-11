extends Node

signal save_completed(slot_id: String, result: Dictionary)
signal load_completed(slot_id: String, result: Dictionary)
signal _slot_verification_completed(slots: Array)

const REQUIRED_SECTIONS := [
	"new_game_config", "world_clock", "dynamic_world", "environment",
	"simulation_runtime",
	"pkcm", "pkcn", "ecp2", "pkgp", "pkfg", "journal",
	"player_context", "player_view", "preview", "pktr", "pkef", "pkid", "pkai",
	"pkmi",
]
## Providers that an older save may legitimately lack. They restore from an
## empty section (a fresh runtime) instead of refusing the load.
const PKMI_SCHEMA := 1
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
const TECHNOLOGY_INDUSTRY_PROVIDER_ID := "technology_industry"
const TECHNOLOGY_INDUSTRY_REVISION := 2
## Plan 11.5, the WHOLE-PACKAGE half. The ideology execution-contract identity
## already travels inside the PKID payload (the native reader refuses a payload
## stamped by a different contract with `cell_program_execution_contract_mismatch`).
## It also has to enter the CONTAINER-level compatibility check, so the manifest
## of every provider is asked whether it can certify the same identity.
##
## The refusal code here is deliberately NOT the payload's. The payload code is a
## native verdict reached after restore has begun; this one is a GDScript
## pre-flight reached before any provider has touched the world. Sharing one
## string would make the two layers indistinguishable in a log -- and in a test,
## where an assertion that "the whole-package gate refused" could be satisfied by
## the payload reader instead, passing while the new gate did nothing.
const EXECUTION_CONTRACT_KEY := "execution_contract_hash"
const EXECUTION_CONTRACT_PROVIDER_ID := "pkid"
const EXECUTION_CONTRACT_PAYLOAD_CODE := "cell_program_execution_contract_mismatch"
const EXECUTION_CONTRACT_MANIFEST_CODE := \
	"cell_program_execution_contract_manifest_mismatch"

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
			"存档运行时 provider 缺失或版本不兼容。")
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
		return _result(false, "load_runtime_missing", "地图运行时尚未建立。")
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
			"地图运行时缺少读档收尾接口。")
	var finalized: Dictionary = generator.finalize_save_restore_runtime()
	if not bool(finalized.get("ok", false)):
		return _result(false, "load_runtime_finalize_failed",
			String(finalized.get("reason", "读档后调度器初始化失败。")))
	if not host.has_method("finalize_save_restore_visuals"):
		return _result(false, "load_visual_finalize_missing",
			"地图运行时缺少读档后视野重绑接口。")
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
		return _result(false, "save_runtime_missing", "游戏运行时尚未就绪。")
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
	var collected := _collect_sections(was_paused, previous_speed,
		 runtime_bundle.get("bytes", PackedByteArray()),
		 runtime_bundle.get("country_pkcn", PackedByteArray()),
		 runtime_bundle.get("economy_ecp2", PackedByteArray()), defer_provider_hashes)
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
	# 同一个 blocking code 连续出现的帧/墙钟上限。
	#
	# 冻结时钟后有些边界不可能在暂停期间推进，最典型的是
	# save_requires_idle_effect_country：年度结算奖励的 Effect 命令要等下一个
	# **游戏日** 才会 ACK，而存档已经 pause 了时钟。旧实现会一直等满 1800 帧，
	# 每帧重跑 advance_save_boundary() 里的整条日系统链（trigger/ideology/
	# effect/modifier/gameplay_effect + economy inflight）。实测（desktop headless，
	# 60x40，10x，sync-write 复现 web 路径）这一轮空转把 Godot 静态内存抬高
	# **约 600 MB，而且永不归还**——每次年度自动存档都会再抬一次，web 的 2 GiB
	# wasm 堆因此在第 2–4 个游戏年撞墙，随后控制台就是每次鼠标事件一对
	# "Cannot enlarge memory" + "table index is out of bounds"。
	# 失败路径本来就会 `_last_autosave_year = year - 1`（下一个年份再试），
	# 所以早点放弃没有任何功能损失；web 还顺带避免了主线程被堵几十秒。
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
		# 空转期间不必每帧重跑日系统链；隔帧推进把内存增速再压一半。
		var generator := _runtime_host.generator()
		if generator != null and generator.has_method("advance_save_boundary") \
				and (frame % 2 == 0):
			generator.advance_save_boundary()
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
	var out := {"day": _world_clock.day_index() if _world_clock != null else -1}
	var generator = _runtime_host.generator() if _runtime_host != null else null
	if generator == null:
		return out
	var economy = generator.get_economy_facade()
	if economy != null:
		var report: Dictionary = economy.report()
		out["economy"] = {"busy": report.get("busy", null),
			"epoch_active": report.get("epoch_active", null),
			"committed": report.get("committed", null),
			"last_committed_day": report.get("last_committed_day", null)}
	var country = generator.get_country_facade()
	var country_ext = country.world_ext() if country != null else null
	# 存档边界最常卡的就是 country：把「谁在拥有 country」和「country_should_run
	# 为什么还是 true」一起记下来，否则只有一句 save_requires_idle_country
	# 根本定位不了（web 的 pause 期间没有任何日推进者）。
	if country != null:
		var country_report: Dictionary = country.report()
		out["country_busy"] = bool(country_report.get("busy", false))
		out["country_stage"] = String(country_report.get("stage", ""))
	if generator.has_method("runtime_graph_active"):
		out["runtime_graph_active"] = bool(generator.runtime_graph_active())
	if country_ext != null and country_ext.has_method("get_country_peer_protocol_status"):
		out["country_peer"] = country_ext.get_country_peer_protocol_status()
	if country_ext != null and country_ext.has_method("country_should_run"):
		out["country_should_run"] = bool(country_ext.country_should_run(int(out["day"])))
	if generator.has_method("get_runtime_thread_report"):
		var thread: Dictionary = generator.get_runtime_thread_report()
		for key in ["simulation_host_state", "simulation_committed_day", "environment_ring_pending",
				"worker_day_inflight", "day_stall_reason_mask", "fault_code",
				"country_worker_plan_active", "country_worker_waiting_for_peer"]:
			out[key] = thread.get(key, null)
	var effect = generator.get_effect_facade()
	var effect_ext = effect.world_ext() if effect != null and effect.has_method("world_ext") else null
	if effect_ext != null and effect_ext.has_method("get_effect_native_adapter_report"):
		out["effect_adapters"] = effect_ext.get_effect_native_adapter_report()
	return out


func _can_save() -> Dictionary:
	if _runtime_host == null or _world_clock == null \
			or not _session_active(_runtime_generation) \
			or _runtime_host.generator() == null:
		return _result(false, "save_runtime_missing", "游戏尚未就绪，请稍后再试。")
	var generator := _runtime_host.generator()
	# 暂停后 worker 仍会排空已经接收的环境输入。必须等它停稳，才可捕获
	# 主线程国家只读副本，避免请求时的 PKCN 与稍后生成的 PKSR 相差数天。
	if generator.has_method("get_runtime_thread_report"):
		var thread: Dictionary = generator.get_runtime_thread_report()
		if String(thread.get("simulation_host_state", "")) == "FAULTED":
			return _blocked_result("worker_faulted", "后台模拟线程发生故障（%s），无法保存。" %
				String(thread.get("fault_code", "unknown")), "worker_faulted")
		# 这三条子条件以前共用一个 code，在日志里完全分不开：state 还停在
		# RUNNING（暂停没送到 worker）、环里还有未来帧没人消费、和"一天正飞"
		# 都会表现为同一个 save_requires_idle_worker。condition 把它们分开。
		var idle_blocker := _worker_idle_blocker(thread)
		if not idle_blocker.is_empty():
			return _blocked_result("save_requires_idle_worker",
				"等待后台 worker 排空已接收的模拟输入。", idle_blocker)
	var country = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	if country == null or economy == null:
		return _result(false, "save_provider_missing", "国家或经济 provider 未注册。")
	var country_report: Dictionary = country.report()
	var economy_report: Dictionary = economy.report()
	var effect = generator.get_effect_facade()
	var effect_ext = effect.world_ext() if effect != null and effect.has_method("world_ext") else null
	# The Effect owner is persisted independently from the domain owners.  Do
	# not capture PKEF/PKCN/PKEC/journal while a native POD request has crossed
	# Effect preflight but has not received the owning domain's durable ACK.
	if effect_ext != null and effect_ext.has_method("get_effect_native_adapter_report"):
		var adapters: Dictionary = effect_ext.get_effect_native_adapter_report()
		if bool(adapters.get("country_pending", false)):
			return _blocked_result("save_requires_idle_effect_country",
				"等待理念/Effect Country 命令提交", "effect_country_pending")
		if bool(adapters.get("economy_pending", false)):
			return _blocked_result("save_requires_idle_effect_economy",
				"等待理念/Effect Economy 命令提交", "effect_economy_pending")
		if bool(adapters.get("gameplay_pending", false)):
			return _blocked_result("save_requires_idle_effect_gameplay",
				"等待理念/Effect Gameplay 事件写入 journal", "effect_gameplay_pending")
	# 已提交账本契约（写档和读档都一样）要求经济至少结算过一次；开局到首次结算
	# 之间没有可恢复的状态。这里不进重试列表：时钟为存档暂停，等下去也不会到。
	if int(economy_report.get("last_committed_day", -1)) < 0:
		return _result(false, "save_requires_first_settlement",
			"经济尚未完成第一次结算，暂时无法存档。请让游戏运行几天后再保存。")
	var economy_busy := bool(economy_report.get("busy",
		economy_report.get("epoch_active", false)))
	if economy_busy or not bool(economy_report.get("committed", true)):
		return _blocked_result("save_requires_committed_boundary",
			"经济尚未到达联合提交边界。",
			"economy_busy" if economy_busy else "economy_not_committed")
	var country_busy := bool(country_report.get("busy", false))
	var country_ext = country.world_ext()
	if country_ext != null and country_ext.has_method("get_country_peer_protocol_status"):
		var peer_status: Dictionary = country_ext.get_country_peer_protocol_status()
		if int(peer_status.get("pending_intents", 0)) > 0 \
			or int(peer_status.get("queued_intents", 0)) > 0 \
			or int(peer_status.get("rejected_intents", 0)) > 0:
			return _blocked_result("save_requires_idle_country_peer",
				"Country peer continuation 尚未到达可保存边界。", "country_peer_intents")
	if country_ext != null and country_ext.has_method("country_should_run"):
		country_busy = country_busy or bool(country_ext.country_should_run(_world_clock.day_index()))
	else:
		country_busy = country_busy or String(country_report.get("stage", "idle")) == "command_preflight"
	if country_busy:
		# 三个来源：report.busy / country_should_run(day) / 无扩展时的
		# command_preflight。日志里必须能分开，否则又是一句"国家没空闲"。
		var country_condition := "country_busy"
		if not bool(country_report.get("busy", false)):
			if country_ext != null and country_ext.has_method("country_should_run"):
				country_condition = "country_should_run"
			else:
				country_condition = "country_command_preflight"
		return _blocked_result("save_requires_idle_country", "国家命令图尚未空闲。",
			country_condition)
	if effect_ext != null and effect_ext.has_method("effect_should_run") \
			and bool(effect_ext.effect_should_run(_world_clock.day_index())):
		return _blocked_result("save_requires_idle_effect",
			"Effect transaction has not reached a safe commit boundary",
			"effect_should_run")
	var ideology = generator.get_ideology_facade() if generator.has_method("get_ideology_facade") else null
	var ideology_ext = ideology.world_ext() if ideology != null and ideology.has_method("world_ext") else null
	if ideology_ext != null and ideology_ext.has_method("ideology_should_run") \
			and bool(ideology_ext.ideology_should_run(_world_clock.day_index())):
		return _blocked_result("save_requires_idle_ideology",
			"Ideology commands have not reached their safe boundary",
			"ideology_should_run")
	return _result(true, "ok", "")


## 返回阻塞原因或空串。inline 没有后台循环更新 RUNNING，按真实日边界判断；
## 尚未消费的未来环境帧交给 native 保存服务清空。
func _worker_idle_blocker(thread: Dictionary) -> String:
	var host_state := String(thread.get("simulation_host_state", "STOPPED"))
	if bool(thread.get("native_daily_inline", false)) and host_state in ["RUNNING", "PAUSED"]:
		if int(thread.get("worker_day_inflight", 0)) > 0:
			return "worker_day_inflight"
		return "inline_day_pending" if bool(thread.get("inline_day_pending", false)) else ""
	if host_state in ["STARTING", "RUNNING", "SAVE_PENDING"]:
		return "state_%s" % host_state.to_lower()
	if host_state != "STOPPED" and int(thread.get("environment_ring_pending", 0)) > 0:
		return "environment_ring_pending"
	if int(thread.get("worker_day_inflight", 0)) > 0:
		return "worker_day_inflight"
	return ""


func _collect_sections(saved_paused: bool, saved_speed: float,
		native_runtime_bundle: PackedByteArray = PackedByteArray(),
		native_country_pkcn: PackedByteArray = PackedByteArray(),
		native_economy_ecp2: PackedByteArray = PackedByteArray(),
		defer_provider_hashes: bool = false) -> Dictionary:
	var generator := _runtime_host.generator()
	var context := _provider_context(_runtime_host, generator, saved_paused, saved_speed)
	context["native_runtime_bundle"] = native_runtime_bundle
	context["native_country_pkcn"] = native_country_pkcn
	context["native_economy_ecp2"] = native_economy_ecp2
	var sections := {}
	var provider_manifest: Array = []
	var provider_hash_payloads: Array = []
	var profile_save := OS.get_environment("PK_SAVE_PROFILE") == "1"
	var verify_provider_hashes := OS.get_environment("PK_SAVE_PROVIDER_HASH_VERIFY") == "1"
	for provider in _providers:
		var profile_start := Time.get_ticks_usec() if profile_save else 0
		var available: Dictionary = provider.can_save(context)
		if not bool(available.get("ok", false)):
			return available
		var written: Dictionary = provider.write_sections(context)
		if not bool(written.get("ok", false)):
			return written
		var provider_sections: Dictionary = written.get("sections", {})
		for section_id in provider_sections:
			if sections.has(section_id):
				return _result(false, "save_provider_duplicate_section",
					"多个 provider 写入了 section：%s" % section_id)
			sections[section_id] = provider_sections[section_id]
		context.current_provider_sections = provider_sections
		var profile_hash_start := Time.get_ticks_usec() if profile_save else 0
		var manifest: Dictionary = provider.manifest_entry(context, not defer_provider_hashes)
		if defer_provider_hashes:
			# 在安全边界冻结与原 state_hash 完全相同的 Variant 字节；
			# 后台只读私有字节，不能再访问 provider、Node 或活跃世界。
			var payload := {"manifest_index": provider_manifest.size(),
				"bytes": var_to_bytes(provider_sections)}
			if verify_provider_hashes:
				payload["expected_hash"] = provider.state_hash(context)
			provider_hash_payloads.append(payload)
		provider_manifest.append(manifest)
		if profile_save:
			print("[save-provider-cost] id=%s capture_ms=%.3f manifest_ms=%.3f" % [
				provider.provider_id(), float(profile_hash_start - profile_start) / 1000.0,
				float(Time.get_ticks_usec() - profile_hash_start) / 1000.0])
	provider_manifest.append({
		"provider_id": TECHNOLOGY_INDUSTRY_PROVIDER_ID,
		"schema_version": TECHNOLOGY_INDUSTRY_REVISION,
		"sections": PackedStringArray(),
		"content_hash": "",
	})
	for required in REQUIRED_SECTIONS:
		if not sections.has(required):
			return _result(false, "save_provider_missing", "运行时缺少 provider：%s" % required)
	return {"ok": true, "code": "ok", "message": "", "sections": sections,
		"provider_manifest": provider_manifest, "provider_hash_payloads": provider_hash_payloads}


func _economy_checkpoint_format() -> Dictionary:
	if not _economy_format.is_empty():
		return _economy_format
	_economy_format = {"schema_version": 53, "abi_version": 2, "hash_version": 1}
	if ClassDB.class_exists("DCWorldExt"):
		var probe = ClassDB.instantiate("DCWorldExt")
		if probe != null and probe.has_method("get_economy_checkpoint_format"):
			_economy_format = probe.get_economy_checkpoint_format()
	return _economy_format


func _register_providers() -> void:
	var registered := _install_provider_entries(WorldStateModules.builtins(
		int(_economy_checkpoint_format().schema_version), PKMI_SCHEMA))
	if not bool(registered.ok):
		_provider_registration_error = registered
		push_error(String(registered.message))


func _install_provider_entries(entries: Array) -> Dictionary:
	var resolved := ModuleRegistry.resolve(entries)
	if not bool(resolved.ok):
		return resolved
	_provider_entries = entries.duplicate()
	_providers = resolved.modules
	_provider_registration_error.clear()
	return {"ok": true, "code": "ok"}


## Register a new persistent module at composition time, before binding a game.
## The module supplies its own callbacks; the coordinator needs no new branch.
func register_state_module(provider, restore_after: PackedStringArray) -> Dictionary:
	if is_instance_valid(_runtime_host) or _busy or not _pending_load.is_empty():
		return _result(false, "module_registration_session_active", "请在进入游戏前登记模块。")
	var candidate := _provider_entries.duplicate()
	var entry := ModuleRegistry.state_entry(provider, restore_after)
	if entry.is_empty():
		return _result(false, "module_descriptor_invalid", "模块缺少保存接口。")
	# Player presentation is installed after every business module, including
	# extensions unknown to the built-in composition.
	for index in candidate.size():
		if String(candidate[index].id) == "player_session":
			candidate[index] = candidate[index].duplicate(true)
			candidate[index].after.append(String(entry.id))
	candidate.append(entry)
	return _install_provider_entries(candidate)


func _provider_context(host: WorldRuntimeHost, generator: MapGenerator,
		saved_paused: bool, saved_speed: float) -> Dictionary:
	return {
		"host": host,
		"generator": generator,
		"world": generator.get_data_core_world() if generator != null else null,
		"event_bus": generator.get_gameplay_event_bus() if generator != null else null,
		"saved_paused": saved_paused,
		"saved_speed": saved_speed,
		"clock": _world_clock,
		"session": GameFlow.session(),
		"set_session": GameFlow.set_session,
		"player": _player_controller,
		"viewport": get_viewport(),
		"clock_restored": Callable(self, "_clock_restored"),
		"set_pending_view": Callable(self, "_set_pending_view"),
	}


func _manifest_compatible(raw_manifest) -> bool:
	if not _provider_registration_error.is_empty():
		return false
	if not raw_manifest is Array:
		return false
	var by_id := {}
	for raw in raw_manifest:
		if not raw is Dictionary:
			return false
		by_id[String(raw.get("provider_id", ""))] = raw
	var industry_entry: Dictionary = by_id.get(TECHNOLOGY_INDUSTRY_PROVIDER_ID, {})
	if int(industry_entry.get("schema_version", 1)) != TECHNOLOGY_INDUSTRY_REVISION:
		return false
	var expected_ids := {TECHNOLOGY_INDUSTRY_PROVIDER_ID: true}
	for provider in _providers:
		var provider_id := String(provider.provider_id())
		expected_ids[provider_id] = true
		if not by_id.has(provider_id):
			if provider.allows_missing_archive():
				continue
			return false
		if not provider.accepts_manifest(by_id[provider_id]):
			return false
	# A missing optional system must not silently erase that system's save data.
	for provider_id in by_id:
		if not expected_ids.has(provider_id):
			return false
	return true


func _manifest_industry_revision(raw_manifest) -> int:
	if not raw_manifest is Array:
		return 1
	for raw in raw_manifest:
		if raw is Dictionary and String(raw.get("provider_id", "")) \
				== TECHNOLOGY_INDUSTRY_PROVIDER_ID:
			return int(raw.get("schema_version", 1))
	return 1


# --- Plan 11.5, the WHOLE-PACKAGE half ---------------------------------------
#
# `_manifest_compatible` answers "are these providers the ones this build can
# restore?". It cannot answer "is the stored cell-program EXECUTION CONTRACT
# this build's?" -- that identity now lives in the pkid manifest entry, and the
# decision needs a fact the manifest does not contain: what the running runtime
# is configured with. That fact only exists once a world has been built, so the
# decision is a separate, PURE function (`running` and `state_present` are
# inputs) called from three places that do not share a runtime:
#
#   * `list_slots()`            -- the pause menu. The runtime IS live, so a
#                                  certified mismatch greys the slot out early.
#   * `prepare_load()`          -- the session request, which runs BEFORE a world
#                                  exists (`world_runtime_host.gd:527`), so
#                                  `running` is normally 0 and the verdict
#                                  defers instead of guessing.
#   * `restore_prepared_game()` -- after the world was built, BEFORE the first
#                                  provider restores anything. This is the
#                                  authoritative gate: it is the last moment a
#                                  refusal can still leave the world untouched.

## The identity the LIVE runtime is running, or 0 when it cannot be stated
## (no world yet, or ideology unconfigured). 0 is "unknown", never "matches":
## the contract itself is a hash, so a zero value is not a contract.
func _running_execution_contract(host = null) -> int:
	var target = host if host != null else _runtime_host
	if target == null or not target.has_method("generator"):
		return 0
	var generator = target.generator()
	if generator == null or not generator.has_method("get_ideology_report"):
		return 0
	return _contract_from_report(generator.get_ideology_report())


func _contract_from_report(report) -> int:
	# The report is IdeologyFacade.report() -> DCWorldExt.get_ideology_report().
	# `{"configured": false}` means the owner is unconfigured (the facade says so
	# itself; the native report says so through the same key), and an older
	# extension build has no identity field at all. All three mean 0 = unknown,
	# never "matches": a hash of rule versions with no catalog attached is not
	# this world's contract.
	if not report is Dictionary:
		return 0
	var configured = report.get("configured", true)
	if configured is bool and not bool(configured):
		return 0
	return _contract_value(report.get(EXECUTION_CONTRACT_KEY, 0))


## Normalizes an identity read from a dictionary or from the save header.
## The header is JSON, and JSON hands a number back as int or float depending on
## how it was written, so a raw `int(...)` is not enough to compare identities.
func _contract_value(value) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String or value is StringName:
		return String(value).to_int()
	return 0


static func _manifest_entry_for(raw_manifest, provider_id: String) -> Dictionary:
	if not raw_manifest is Array:
		return {}
	for raw in raw_manifest:
		if raw is Dictionary and String(raw.get("provider_id", "")) == provider_id:
			return raw
	return {}


## Whether the archive actually carries ideology state. Needed because the
## contract's absence only matters when there is contract-governed state that
## could be reinterpreted: an archive with no PKID payload restores to the empty
## ideology state, which cannot be governed by any contract.
static func _pkid_state_present(sections) -> bool:
	if not sections is Dictionary:
		return false
	return not PackedByteArray(sections.get("pkid", PackedByteArray())).is_empty()


## The whole-package execution-contract verdict.
##
## Returns {ok, code, detail, saved, running, deferred, message}.
##   ok=false  ONLY when the archive certified a contract that differs from the
##             running one (`detail == "contract_differs"`).
##   deferred  the archive did not certify the identity, so this gate did NOT
##             verify it. The PKID payload owns the same identity and compares it
##             exactly (`cell_program_execution_contract_mismatch`), so the load
##             is neither refused nor whitewashed: the deferral is recorded and
##             logged by the caller.
##
## LEGACY ARCHIVES (the backward-honest half). An archive written before this
## field existed has no key. That fact means UNSTATED -- never "matches" (which
## would be silent acceptance of an identity nobody checked) and never "differs"
## (which would refuse every archive on disk today, including ones whose PKID
## payload already carries the identical identity and will be compared exactly a
## few frames later). Plan 11.5's old-archive rule -- an older save must NOT be
## read under an unproven contract, and the refusal it names is
## `cell_program_execution_contract_mismatch` -- is therefore honoured by the
## layer that owns the identity, and this gate says out loud that it did not
## check instead of pretending it did.
func _execution_contract_verdict(raw_manifest, running: int,
		state_present: bool) -> Dictionary:
	var entry := _manifest_entry_for(raw_manifest, EXECUTION_CONTRACT_PROVIDER_ID)
	if entry.is_empty():
		# Pre-ideology archive: no pkid provider, so no contract-governed state.
		return _contract_verdict(true, "contract_no_provider", 0, 0, false)
	var saved := _contract_value(entry.get(EXECUTION_CONTRACT_KEY, 0))
	if running == 0:
		return _contract_verdict(true, "contract_unverifiable", 0, saved, saved != 0)
	if saved == 0:
		return _contract_verdict(true,
			"contract_unstated" if state_present else "contract_unstated_no_state",
			running, 0, state_present)
	if saved != running:
		return _contract_verdict(false, "contract_differs", running, saved, false)
	return _contract_verdict(true, "contract_matches", running, saved, false)


func _contract_verdict(ok: bool, detail: String, running: int, saved: int,
		deferred: bool) -> Dictionary:
	return {
		"ok": ok,
		"code": "" if ok else EXECUTION_CONTRACT_MANIFEST_CODE,
		"detail": detail,
		"saved": saved,
		"running": running,
		"deferred": deferred,
		"message": _contract_verdict_message(detail, running, saved),
	}


func _contract_verdict_message(detail: String, running: int, saved: int) -> String:
	match detail:
		"contract_differs":
			return ("Save was written under a different cell-program execution "
				+ "contract (saved=%d running=%d); refused before any provider "
				+ "restored state.") % [saved, running]
		"contract_unstated":
			return ("Save predates the pkid execution-contract manifest identity; "
				+ "the PKID payload remains the authority (%s).") \
				% EXECUTION_CONTRACT_PAYLOAD_CODE
		"contract_unstated_no_state":
			return ("Save carries no ideology state and no execution-contract "
				+ "identity; nothing can be reinterpreted.")
		"contract_unverifiable":
			return ("The running execution contract is not available yet; the "
				+ "whole-package comparison is deferred to the PKID payload.")
		"contract_no_provider":
			return "Save predates the ideology provider."
	return ""


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
				"economy_ecp2": polled.get("economy_ecp2", PackedByteArray())}
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
	if ext != null and ext.has_method("profile_runtime_save_window"):
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
	return {"ok": ok, "code": code, "message": message}


func _clock_restored(year: int) -> void:
	_last_autosave_year = year

## Preserve the precise save-boundary condition for failure diagnostics.
static func _blocked_result(code: String, message: String, condition: String) -> Dictionary:
	var blocked := _result(false, code, message)
	blocked["blocking_condition"] = condition
	return blocked

func _set_pending_view(view: Dictionary) -> void:
	_pending_view = view
