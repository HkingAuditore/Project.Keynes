extends Node

signal save_completed(slot_id: String, result: Dictionary)
signal load_completed(slot_id: String, result: Dictionary)

const REQUIRED_SECTIONS := [
	"new_game_config", "world_clock", "dynamic_world", "environment",
	"pkcm", "pkcn", "pkec", "pkgp", "pkfg", "journal",
	"player_context", "player_view", "preview",
]
const SaveRepositoryScript = preload("res://scripts/game/save_repository.gd")
const RuntimeStateProviderScript = preload("res://scripts/game/runtime_state_provider.gd")

var _repository = SaveRepositoryScript.new()
var _runtime_host: WorldRuntimeHost
var _world_clock: WorldClock
var _camera: MapCamera
var _selection: SelectionController
var _pending_load: Dictionary = {}
var _pending_view: Dictionary = {}
var _last_autosave_year := -1
var _busy := false
var _providers: Array = []


func _ready() -> void:
	_register_providers()


func list_slots() -> Array:
	var slots := _repository.list_slots()
	for slot in slots:
		if bool(slot.get("loadable", false)) and not _manifest_compatible(
				slot.get("provider_manifest", [])):
			slot.loadable = false
			slot.reason = "存档运行时 provider 版本不兼容。"
	return slots


func load_preview(slot_id: String) -> Dictionary:
	return _repository.load_preview(slot_id)


func bind_runtime(host: WorldRuntimeHost, clock: WorldClock, camera: MapCamera,
		selection: SelectionController) -> void:
	_runtime_host = host
	_world_clock = clock
	_camera = camera
	_selection = selection
	if _world_clock != null:
		var callback := Callable(self, "_on_year_changed")
		if not _world_clock.year_changed.is_connected(callback):
			_world_clock.year_changed.connect(callback)


func request_manual_save(slot_id: String) -> Dictionary:
	if slot_id not in ["manual_1", "manual_2", "manual_3"]:
		return _result(false, "slot_invalid", "手动存档槽位无效。")
	return await _save(slot_id, "manual")


func request_autosave(reason: String) -> Dictionary:
	return await _save("autosave", reason)


func load_slot(slot_id: String) -> Dictionary:
	return prepare_load(slot_id)


func delete_manual_slot(slot_id: String) -> Dictionary:
	return _repository.delete_manual_slot(slot_id)


func prepare_load(slot_id: String) -> Dictionary:
	var container: Dictionary = _repository.load_slot(slot_id)
	if not bool(container.get("ok", false)):
		return container
	if not _manifest_compatible(container.header.get("provider_manifest", [])):
		return _result(false, "save_provider_incompatible",
			"存档运行时 provider 缺失或版本不兼容。")
	var bytes_by_id: Dictionary = container.get("section_bytes", {})
	for required in REQUIRED_SECTIONS:
		if not bytes_by_id.has(required):
			if required in ["pkcm", "pkgp"]:
				bytes_by_id[required] = PackedByteArray()
				continue
			return _result(false, "save_provider_missing", "存档缺少必需 section：%s" % required)
	var decoded := {}
	for section_id in ["new_game_config", "world_clock", "dynamic_world", "environment",
			"pkfg", "journal", "player_context", "player_view"]:
		var value = bytes_to_var(bytes_by_id[section_id])
		if value == null:
			return _result(false, "save_section_decode_failed", "无法解析存档 section：%s" % section_id)
		decoded[section_id] = value
	decoded["pkcn"] = bytes_by_id.pkcn
	decoded["pkec"] = bytes_by_id.pkec
	decoded["pkcm"] = bytes_by_id.pkcm
	decoded["pkgp"] = bytes_by_id.pkgp
	decoded["preview"] = bytes_by_id.preview
	_pending_load = {
		"slot_id": slot_id,
		"header": container.header,
		"sections": decoded,
	}
	return {"ok": true, "code": "ok", "message": "", "bundle": _pending_load.duplicate(true),
		"config": decoded.new_game_config}


func restore_prepared_game(host: WorldRuntimeHost) -> Dictionary:
	if _pending_load.is_empty() or host == null:
		return _result(false, "load_not_prepared", "没有待恢复的存档。")
	var sections: Dictionary = _pending_load.sections
	var generator := host.generator()
	if generator == null:
		return _result(false, "load_runtime_missing", "地图运行时尚未建立。")
	var context := _provider_context(host, generator, false, 0.0)
	for provider in _providers:
		var provider_result: Dictionary = provider.restore_sections(sections, context)
		if not bool(provider_result.get("ok", false)):
			return provider_result
		if String(provider.provider_id()) == "pkcn":
			if not generator.has_method("prepare_economy_save_restore_runtime"):
				return _result(false, "load_economy_prepare_missing",
					"地图运行时缺少经济恢复准备接口。")
			var prepared: Dictionary = generator.prepare_economy_save_restore_runtime()
			if not bool(prepared.get("ok", false)):
				return _result(false, "load_economy_prepare_failed",
					String(prepared.get("reason", "PKCN 后无法准备经济恢复。")))
	if not generator.has_method("finalize_save_restore_runtime"):
		return _result(false, "load_runtime_finalize_missing",
			"地图运行时缺少读档收尾接口。")
	var finalized: Dictionary = generator.finalize_save_restore_runtime()
	if not bool(finalized.get("ok", false)):
		return _result(false, "load_runtime_finalize_failed",
			String(finalized.get("reason", "读档后调度器初始化失败。")))
	var slot_id := String(_pending_load.slot_id)
	_pending_load.clear()
	var result := _result(true, "ok", "")
	load_completed.emit(slot_id, result)
	return result


func apply_pending_view(map: MapData) -> void:
	if _pending_view.is_empty():
		return
	if _camera != null:
		_camera.global_position = _pending_view.get("camera_position", _camera.global_position)
		_camera.zoom = _pending_view.get("camera_zoom", _camera.zoom)
	if _selection != null and map != null:
		var selected := int(_pending_view.get("selected_cell", -1))
		if selected >= 0 and selected < map.cell_count():
			_selection.select_cell(map.cell_at(selected))
	_pending_view.clear()


func _save(slot_id: String, reason: String) -> Dictionary:
	if _busy:
		return _result(false, "save_busy", "已有存档请求正在处理。")
	_busy = true
	var was_paused := _world_clock.paused
	var previous_speed := _world_clock.speed_multiplier
	_world_clock.pause(true)
	var boundary: Dictionary = await _wait_for_safe_boundary()
	if not bool(boundary.get("ok", false)):
		_restore_clock_mode(was_paused, previous_speed)
		_busy = false
		return boundary
	var collected := _collect_sections(was_paused, previous_speed)
	if not bool(collected.get("ok", false)):
		_restore_clock_mode(was_paused, previous_speed)
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
		"provider_manifest": collected.provider_manifest,
	}
	var result: Dictionary = _repository.write_slot(slot_id, header, collected.sections)
	_restore_clock_mode(was_paused, previous_speed)
	_busy = false
	save_completed.emit(slot_id, result)
	return result


func _wait_for_safe_boundary() -> Dictionary:
	const MAX_WAIT_FRAMES := 1800
	for frame in range(MAX_WAIT_FRAMES):
		var boundary := _can_save()
		if bool(boundary.get("ok", false)):
			return boundary
		var code := String(boundary.get("code", ""))
		if code not in ["save_requires_committed_boundary", "save_requires_idle_country"]:
			return boundary
		var generator := _runtime_host.generator()
		if generator != null and generator.has_method("advance_save_boundary"):
			generator.advance_save_boundary()
		await get_tree().process_frame
	return _result(false, "save_boundary_timeout", "等待国家与经济提交边界超时。")


func _can_save() -> Dictionary:
	if _runtime_host == null or _world_clock == null or _runtime_host.generator() == null:
		return _result(false, "save_runtime_missing", "游戏运行时尚未就绪。")
	var generator := _runtime_host.generator()
	var country = generator.get_country_facade()
	var economy = generator.get_economy_facade()
	if country == null or economy == null:
		return _result(false, "save_provider_missing", "国家或经济 provider 未注册。")
	var country_report: Dictionary = country.report()
	var economy_report: Dictionary = economy.report()
	if bool(economy_report.get("busy", economy_report.get("epoch_active", false))) \
			or not bool(economy_report.get("committed", true)):
		return _result(false, "save_requires_committed_boundary", "经济尚未到达联合提交边界。")
	var country_busy := bool(country_report.get("busy", false))
	var country_ext = country.world_ext()
	if country_ext != null and country_ext.has_method("country_should_run"):
		country_busy = country_busy or bool(country_ext.country_should_run(_world_clock.day_index()))
	else:
		country_busy = country_busy or String(country_report.get("stage", "idle")) == "command_preflight"
	if country_busy:
		return _result(false, "save_requires_idle_country", "国家命令图尚未空闲。")
	return _result(true, "ok", "")


func _collect_sections(saved_paused: bool, saved_speed: float) -> Dictionary:
	var generator := _runtime_host.generator()
	var context := _provider_context(_runtime_host, generator, saved_paused, saved_speed)
	var sections := {}
	var provider_manifest: Array = []
	for provider in _providers:
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
		provider_manifest.append(provider.manifest_entry(context))
	for required in REQUIRED_SECTIONS:
		if not sections.has(required):
			return _result(false, "save_provider_missing", "运行时缺少 provider：%s" % required)
	return {"ok": true, "code": "ok", "message": "", "sections": sections,
		"provider_manifest": provider_manifest}


func _register_providers() -> void:
	_providers = [
		_make_provider(&"dynamic_world", 1,
			PackedStringArray(["new_game_config", "dynamic_world"]),
			"_can_world_provider", "_write_world_provider", "_restore_world_provider"),
		_make_provider(&"environment", 1, PackedStringArray(["environment"]),
			"_can_environment_provider", "_write_environment_provider",
			"_restore_environment_provider"),
		_make_provider(&"pkcm", 1, PackedStringArray(["pkcm"]),
			"_can_modifier_provider", "_write_climate_modifier_provider",
			"_restore_climate_modifier_provider"),
		_make_provider(&"world_clock", 1, PackedStringArray(["world_clock"]),
			"_can_clock_provider", "_write_clock_provider", "_restore_clock_provider"),
		_make_provider(&"pkcn", 2, PackedStringArray(["pkcn"]),
			"_can_country_provider", "_write_country_provider", "_restore_country_provider"),
		_make_provider(&"pkec", 20, PackedStringArray(["pkec"]),
			"_can_economy_provider", "_write_economy_provider", "_restore_economy_provider"),
		_make_provider(&"pkgp", 1, PackedStringArray(["pkgp"]),
			"_can_modifier_provider", "_write_gameplay_modifier_provider",
			"_restore_gameplay_modifier_provider"),
		# 视野排在 PKCN 之后：恢复时要先有领土才能重解算可见性。
		_make_provider(&"pkfg", 1, PackedStringArray(["pkfg"]),
			"_can_vision_provider", "_write_vision_provider", "_restore_vision_provider"),
		_make_provider(&"journal", 1, PackedStringArray(["journal"]),
			"_can_journal_provider", "_write_journal_provider", "_restore_journal_provider"),
		_make_provider(&"player_session", 1,
			PackedStringArray(["player_context", "player_view", "preview"]),
			"_can_player_provider", "_write_player_provider", "_restore_player_provider"),
	]


func _make_provider(provider_id: StringName, schema: int, section_ids: PackedStringArray,
		can_method: StringName, write_method: StringName,
		restore_method: StringName):
	return RuntimeStateProviderScript.new().configure(provider_id, schema, section_ids,
		Callable(self, can_method), Callable(self, write_method),
		Callable(self, restore_method), Callable(self, "_hash_provider_sections"))


func _provider_context(host: WorldRuntimeHost, generator: MapGenerator,
		saved_paused: bool, saved_speed: float) -> Dictionary:
	return {
		"host": host,
		"generator": generator,
		"world": generator.get_data_core_world() if generator != null else null,
		"event_bus": generator.get_gameplay_event_bus() if generator != null else null,
		"saved_paused": saved_paused,
		"saved_speed": saved_speed,
	}


func _manifest_compatible(raw_manifest) -> bool:
	if not raw_manifest is Array:
		return false
	var by_id := {}
	for raw in raw_manifest:
		if not raw is Dictionary:
			return false
		by_id[String(raw.get("provider_id", ""))] = raw
	for provider in _providers:
		var provider_id := String(provider.provider_id())
		if not by_id.has(provider_id):
			if provider_id in ["pkcm", "pkgp"]:
				continue
			return false
		var entry: Dictionary = by_id[provider_id]
		var saved_schema := int(entry.get("schema_version", -1))
		var schema_compatible: bool = saved_schema == provider.schema_version()
		if provider_id == "pkcn":
			schema_compatible = saved_schema in [1, 2]
		elif provider_id == "pkec":
			schema_compatible = saved_schema in [18, 19, 20]
		if not schema_compatible:
			return false
		var actual := PackedStringArray(entry.get("sections", []))
		var expected: PackedStringArray = provider.section_ids()
		actual.sort()
		expected.sort()
		if actual != expected:
			return false
	return true


func _can_world_provider(context: Dictionary) -> Dictionary:
	var world = context.get("world")
	return _result(world != null and world.has_method("serialize") \
		and world.has_method("deserialize"), "ok" if world != null else "save_provider_missing",
		"" if world != null else "动态世界 provider 不可用。")


func _can_environment_provider(context: Dictionary) -> Dictionary:
	var generator = context.get("generator")
	return _result(generator != null, "ok" if generator != null else "save_provider_missing",
		"" if generator != null else "环境 provider 不可用。")


func _can_clock_provider(_context: Dictionary) -> Dictionary:
	return _result(_world_clock != null, "ok" if _world_clock != null else "save_provider_missing",
		"" if _world_clock != null else "WorldClock provider 不可用。")


func _can_country_provider(context: Dictionary) -> Dictionary:
	var generator = context.get("generator")
	var facade = generator.get_country_facade() if generator != null else null
	return _result(facade != null and facade.is_configured(),
		"ok" if facade != null and facade.is_configured() else "save_provider_missing",
		"" if facade != null and facade.is_configured() else "PKCN provider 不可用。")


func _can_economy_provider(context: Dictionary) -> Dictionary:
	var generator = context.get("generator")
	var facade = generator.get_economy_facade() if generator != null else null
	return _result(facade != null and facade.is_configured(),
		"ok" if facade != null and facade.is_configured() else "save_provider_missing",
		"" if facade != null and facade.is_configured() else "PKEC provider 不可用。")


func _can_modifier_provider(context: Dictionary) -> Dictionary:
	var generator = context.get("generator")
	var facade = generator.get_modifier_facade() if generator != null else null
	var ext = facade.world_ext() if facade != null and facade.is_configured() else null
	var available: bool = ext != null and ext.has_method("capture_modifier_domain") \
		and ext.has_method("restore_modifier_domain") \
		and ext.has_method("clear_modifier_domain")
	return _result(available, "ok" if available else "save_provider_missing",
		"" if available else "Modifier provider 不可用。")


func _can_vision_provider(context: Dictionary) -> Dictionary:
	var host = context.get("host")
	var map = host.current_map() if host != null else null
	return _result(map != null and map.cell_count() > 0,
		"ok" if map != null else "save_provider_missing",
		"" if map != null else "视野 provider 不可用。")


func _can_journal_provider(context: Dictionary) -> Dictionary:
	var event_bus = context.get("event_bus")
	return _result(event_bus != null, "ok" if event_bus != null else "save_provider_missing",
		"" if event_bus != null else "事件 journal provider 不可用。")


func _can_player_provider(_context: Dictionary) -> Dictionary:
	var session := GameFlow.session()
	return _result(not session.is_empty() and session.has("new_game_config"),
		"ok" if not session.is_empty() else "save_provider_missing",
		"" if not session.is_empty() else "玩家会话 provider 不可用。")


func _write_world_provider(context: Dictionary) -> Dictionary:
	return {"ok": true, "sections": {
		"new_game_config": GameFlow.session().get("new_game_config", {}),
		"dynamic_world": context.world.serialize(),
	}}


func _write_environment_provider(context: Dictionary) -> Dictionary:
	var environment: Dictionary = context.generator.export_environment_runtime_state()
	if String(environment.get("schema", "")) != "PKEnvironmentRuntime":
		return _result(false, "environment_provider_incomplete",
			"环境运行时未提供可持久化的完整状态。")
	return {"ok": true, "sections": {"environment": environment}}


func _write_clock_provider(context: Dictionary) -> Dictionary:
	var state: Dictionary = _world_clock.export_state()
	state.paused = bool(context.saved_paused)
	state.speed_multiplier = float(context.saved_speed)
	return {"ok": true, "sections": {"world_clock": state}}


func _write_country_provider(context: Dictionary) -> Dictionary:
	var captured := _capture_native(context.generator.get_country_facade(), "country")
	return {"ok": true, "sections": {"pkcn": captured.bytes}} \
		if bool(captured.get("ok", false)) else captured


func _write_economy_provider(context: Dictionary) -> Dictionary:
	var captured := _capture_native(context.generator.get_economy_facade(), "economy")
	return {"ok": true, "sections": {"pkec": captured.bytes}} \
		if bool(captured.get("ok", false)) else captured


func _write_climate_modifier_provider(context: Dictionary) -> Dictionary:
	return _write_modifier_provider(context, 0, "pkcm")


func _write_gameplay_modifier_provider(context: Dictionary) -> Dictionary:
	return _write_modifier_provider(context, 3, "pkgp")


func _write_modifier_provider(context: Dictionary, domain: int,
		section_id: String) -> Dictionary:
	var facade = context.generator.get_modifier_facade()
	var bytes: PackedByteArray = facade.world_ext().capture_modifier_domain(domain)
	if bytes.is_empty():
		return _result(false, "%s_save_failed" % section_id,
			"Modifier domain 无法序列化。")
	return {"ok": true, "sections": {section_id: bytes}}


## 只存 cell_explored：它是单调累积的玩家进度，重算不回来。cell_visible 与
## fog_k 都是领土 + 地形的纯函数，恢复后由 refresh_country_visuals 重解算。
func _write_vision_provider(context: Dictionary) -> Dictionary:
	var map: MapData = context.host.current_map()
	var explored := map.explored_arr
	if explored.size() != map.cell_count():
		# 迷雾从未解算过（沙盒 / 迷雾关）。写一份空进度，保持 section 必存。
		explored = PackedByteArray()
		explored.resize(map.cell_count())
	return {"ok": true, "sections": {"pkfg": {
		"schema": "PKFogOfWar",
		"cells": map.cell_count(),
		"explored": explored,
	}}}


func _write_journal_provider(context: Dictionary) -> Dictionary:
	var journal: Dictionary = context.event_bus.snapshot_journal()
	if bool(journal.get("fallback", false)):
		return _result(false, "journal_provider_missing", "事件 journal provider 不可用。")
	return {"ok": true, "sections": {"journal": journal}}


func _write_player_provider(_context: Dictionary) -> Dictionary:
	var preview := _capture_preview()
	var selected := _selection.selected_cell() if _selection != null else null
	return {"ok": true, "sections": {
		"player_context": GameFlow.session(),
		"player_view": {
			"selected_cell": int(selected.index) if selected != null else -1,
			"camera_position": _camera.global_position if _camera != null else Vector2.ZERO,
			"camera_zoom": _camera.zoom if _camera != null else Vector2.ONE,
		},
		"preview": preview,
	}}


func _capture_preview() -> PackedByteArray:
	var preview := PackedByteArray()
	var viewport := get_viewport()
	if DisplayServer.get_name() != "headless" and viewport != null \
			and viewport.get_texture() != null:
		var image := viewport.get_texture().get_image()
		if image != null and not image.is_empty():
			preview = image.save_png_to_buffer()
	if preview.is_empty():
		var fallback := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		fallback.fill(Color.TRANSPARENT)
		preview = fallback.save_png_to_buffer()
	return preview


func _restore_world_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	context.world.deserialize(sections.dynamic_world)
	return _result(true, "ok", "")


func _restore_environment_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	return context.generator.restore_environment_runtime_state(sections.environment)


func _restore_clock_provider(sections: Dictionary, _context: Dictionary) -> Dictionary:
	return _world_clock.restore_state(sections.world_clock)


func _restore_country_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var result: Dictionary = context.generator.get_country_facade().restore_bytes(sections.pkcn)
	return result if bool(result.get("ok", false)) else _result(false,
		"pkcn_restore_failed", String(result.get("reason", "国家恢复失败。")))


func _restore_economy_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var result: Dictionary = context.generator.get_economy_facade().restore_bytes(sections.pkec)
	return result if bool(result.get("ok", false)) else _result(false,
		"pkec_restore_failed", String(result.get("reason", "经济恢复失败。")))


func _restore_climate_modifier_provider(sections: Dictionary,
		context: Dictionary) -> Dictionary:
	return _restore_modifier_provider(sections, context, 0, "pkcm")


func _restore_gameplay_modifier_provider(sections: Dictionary,
		context: Dictionary) -> Dictionary:
	return _restore_modifier_provider(sections, context, 3, "pkgp")


func _restore_modifier_provider(sections: Dictionary, context: Dictionary,
		domain: int, section_id: String) -> Dictionary:
	var ext = context.generator.get_modifier_facade().world_ext()
	var bytes := PackedByteArray(sections.get(section_id, PackedByteArray()))
	var result: Dictionary
	if bytes.is_empty():
		result = ext.clear_modifier_domain(domain)
	else:
		result = ext.restore_modifier_domain(domain, bytes)
	return result if bool(result.get("ok", false)) else _result(false,
		"%s_restore_failed" % section_id,
		String(result.get("reason", "Modifier domain 恢复失败。")))


func _restore_vision_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var payload = sections.get("pkfg")
	if not payload is Dictionary or String(payload.get("schema", "")) != "PKFogOfWar":
		return _result(false, "pkfg_restore_failed", "视野 section 格式不正确。")
	var host: WorldRuntimeHost = context.host
	var map: MapData = host.current_map()
	if map == null:
		return _result(false, "pkfg_restore_failed", "视野恢复时地图不可用。")
	var n := map.cell_count()
	if int(payload.get("cells", -1)) != n:
		return _result(false, "pkfg_restore_failed", "视野 section 的格数与当前地图不一致。")
	var explored := PackedByteArray(payload.get("explored", PackedByteArray()))
	if explored.size() != n:
		return _result(false, "pkfg_restore_failed", "视野 section 已截断。")
	map.explored_arr = explored
	# 领土此刻已由 PKCN 恢复，可以直接重解算可见性并把 k 推进 enum_lut.a。
	host.refresh_country_visuals("save_restore")
	return _result(true, "ok", "")


func _restore_journal_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var result: Dictionary = context.event_bus.restore_journal(sections.journal)
	if not bool(result.get("ok", false)) and not bool(result.get("fallback", false)):
		return _result(false, "journal_restore_failed", "事件 journal 恢复失败。")
	return _result(true, "ok", "")


func _restore_player_provider(sections: Dictionary, _context: Dictionary) -> Dictionary:
	GameFlow.set_session(sections.player_context)
	_pending_view = sections.player_view.duplicate(true)
	return _result(true, "ok", "")


func _hash_provider_sections(context: Dictionary) -> String:
	var bytes := var_to_bytes(context.get("current_provider_sections", {}))
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		hashing.update(bytes)
	return hashing.finish().hex_encode()


func _capture_native(facade, provider_name: String) -> Dictionary:
	var begun: Dictionary = facade.begin_save()
	if not bool(begun.get("ok", false)):
		return _result(false, "%s_save_begin_failed" % provider_name,
			String(begun.get("reason", "无法开始 native 存档。")))
	var bytes := PackedByteArray()
	while true:
		var chunk: PackedByteArray = facade.read_save_chunk()
		if chunk.is_empty(): break
		bytes.append_array(chunk)
	var ended: Dictionary = facade.end_save()
	if not bool(ended.get("ok", false)):
		return _result(false, "%s_save_end_failed" % provider_name,
			String(ended.get("reason", "无法结束 native 存档。")))
	return {"ok": true, "code": "ok", "message": "", "bytes": bytes}


func _restore_clock_mode(was_paused: bool, previous_speed: float) -> void:
	_world_clock.speed_multiplier = previous_speed
	_world_clock.pause(was_paused)


func _on_year_changed(year: int) -> void:
	# Year 0 is the clock's initial publication, not a completed game year.
	if year <= 0 or year <= _last_autosave_year:
		return
	_last_autosave_year = year
	call_deferred("_autosave_year", year)


func _autosave_year(year: int) -> void:
	var result := await request_autosave("year_%d" % year)
	if not bool(result.get("ok", false)):
		# A busy boundary is retried on the next committed day through the player
		# host; the year marker prevents duplicate completed writes.
		_last_autosave_year = year - 1


static func _result(ok: bool, code: String, message: String) -> Dictionary:
	return {"ok": ok, "code": code, "message": message}
