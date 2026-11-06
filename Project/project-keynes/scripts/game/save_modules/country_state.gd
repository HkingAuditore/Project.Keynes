extends "res://scripts/game/save_modules/state_adapter.gd"

## Owns country, military, country_ai persistence; receives only declared capabilities.
# Section contract belongs to the module. The coordinator uses the existing registry.
static func archive_contract() -> Dictionary:
	return {"id": &"pkcn", "version": 11, "sections": PackedStringArray(["pkcn"]),
		"restore_after": PackedStringArray(["simulation_runtime"]),
		"can": &"_can_country_provider", "write": &"_write_country_provider",
		"restore": &"_restore_country_provider", "readable_versions": PackedInt32Array([11])}

func _can_country_provider(context: Dictionary) -> Dictionary:
	var facade = context.get("country")
	return _result(facade != null and facade.is_configured(),
		"ok" if facade != null and facade.is_configured() else "save_provider_missing",
		"" if facade != null and facade.is_configured() else "PKCN provider 不可用。")

func _write_country_provider(context: Dictionary) -> Dictionary:
	var shared_pkcn: PackedByteArray = context.get(
		"native_country_pkcn", PackedByteArray())
	if not shared_pkcn.is_empty():
		return {"ok": true, "sections": {"pkcn": shared_pkcn}}
	var captured := _capture_native(context.country, "country")
	return {"ok": true, "sections": {"pkcn": captured.bytes}} \
		if bool(captured.get("ok", false)) else captured

func _restore_country_state(sections: Dictionary, context: Dictionary) -> Dictionary:
	var facade = context.country
	var ext = facade.world_ext() if facade != null else null
	if ext != null and ext.has_method("restore_country_runtime_checkpoint"):
		var checkpoint_result: Dictionary = ext.restore_country_runtime_checkpoint(
			sections.pkcn)
		if bool(checkpoint_result.get("available", false)):
			return checkpoint_result if bool(checkpoint_result.get("ok", false)) else \
				_result(false, String(checkpoint_result.get("code",
					"country_checkpoint_restore_failed")),
					"CPD2/PKCN 国家恢复失败。")
	var result: Dictionary = facade.restore_bytes(sections.pkcn)
	return result if bool(result.get("ok", false)) else _result(false,
		"pkcn_restore_failed", String(result.get("reason", "国家恢复失败。")))

func _can_military_provider(context: Dictionary) -> Dictionary:
	var facade = context.get("military")
	var available: bool = facade != null and facade.is_configured()
	return _result(true, "ok" if available else "save_military_unavailable",
		"" if available else "Military runtime 未配置，写入空 PKMI。")

func _write_military_provider(context: Dictionary) -> Dictionary:
	var facade = context.get("military")
	if facade == null or not facade.is_configured():
		return {"ok": true, "sections": {"pkmi": PackedByteArray()}}
	var bytes: PackedByteArray = facade.encode_state()
	if bytes.is_empty():
		# A configured facade that cannot encode is a real failure: writing an
		# empty section would silently reset every army on the next load.
		return _result(false, "pkmi_save_failed", "Military state serialization failed")
	var job = context.get("military_progress")
	var progress: PackedInt64Array = facade.capture_pending_event_progress() if job == null else PackedInt64Array(job.capture_event_progress())
	var tail := PackedByteArray()
	tail.resize(28)
	tail.encode_u32(0, 0x314a444d) # MDJ1
	for i in range(3): tail.encode_s64(4 + i * 8, progress[i])
	bytes.append_array(tail)
	return {"ok": true, "sections": {"pkmi": bytes}}

func _restore_military_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var facade = context.get("military")
	if facade == null or not facade.is_configured():
		# The save carries military state but this runtime has none (DLL without
		# the military API, or the catalog failed to compile). Refusing is the
		# only honest answer: silently dropping armies and wars would corrupt the
		# session state the player is reloading.
		var bytes := PackedByteArray(sections.get("pkmi", PackedByteArray()))
		if bytes.is_empty():
			return {"ok": true}
		return _result(false, "pkmi_runtime_unavailable",
			"存档含军事状态，但当前运行时没有 Military API。")
	var bytes := PackedByteArray(sections.get("pkmi", PackedByteArray()))
	if bytes.is_empty():
		# Save written before the military runtime: start from an empty military
		# store rather than refusing the load.
		return {"ok": true, "restored": false, "reason": "pkmi_absent_migration"}
	if bytes.size() < 28 or bytes.decode_u32(bytes.size() - 28) != 0x314a444d:
		return _result(false, "military_forwarder_version_mismatch", "军事事件保存游标版本不匹配，需要 MDJ1。")
	var progress := PackedInt64Array()
	for i in range(3): progress.append(bytes.decode_s64(bytes.size() - 24 + i * 8))
	if progress[0] < 0 or progress[1] < -1 or progress[2] < 0:
		return _result(false, "military_forwarder_invalid", "军事事件保存游标无效。")
	var result: Dictionary = facade.restore_state(bytes.slice(0, bytes.size() - 28))
	if not bool(result.get("ok", false)):
		return _result(false, "pkmi_restore_failed",
			String(result.get("reason", "Military PKMI restore failed")))
	var job = context.get("military_progress")
	if job == null and not facade.restore_pending_event_progress(progress):
		return _result(false, "military_forwarder_invalid", "军事事件保存游标无效。")
	if job != null and not job.restore_event_progress(progress):
		return _result(false, "military_forwarder_invalid", "军事事件保存游标无效。")
	# AI arming is part of the military store's meaning: after a restore, every
	# non-player country must be AI again or the armed forces stop planning.
	var player_handles: PackedInt64Array = facade.ai_player_handles()
	if player_handles.is_empty():
		var player_context = sections.get("player_context", {})
		var start_cell := int(player_context.get("start_cell", -1)) \
			if player_context is Dictionary else -1
		var country = context.country
		var handle := int(country.cell_summary(start_cell).get("country_handle", 0)) \
			if country != null and start_cell >= 0 else 0
		if handle != 0:
			player_handles = PackedInt64Array([handle])
	facade.arm_ai(player_handles)
	return result

func _can_country_ai_provider(context: Dictionary) -> Dictionary:
	# A world without Country AI still writes an empty pkai section.
	var available: bool = context.has("country_ai")
	return _result(available, "ok" if available else "save_provider_missing",
		"Country AI provider unavailable" if not available else "")

func _write_country_ai_provider(context: Dictionary) -> Dictionary:
	var facade = context.country_ai
	if facade == null or not facade.is_configured():
		return {"ok": true, "sections": {"pkai": PackedByteArray()}}
	var bytes: PackedByteArray = facade.encode_state()
	if bytes.is_empty():
		return _result(false, "pkai_save_failed", "Country AI state serialization failed")
	return {"ok": true, "sections": {"pkai": bytes}}

func _restore_country_ai_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var facade = context.country_ai
	if facade == null or not facade.is_configured():
		return {"ok": true}
	var bytes := PackedByteArray(sections.get("pkai", PackedByteArray()))
	if not bytes.is_empty():
		var restored: Dictionary = facade.restore_state(bytes)
		return restored if bool(restored.get("ok", false)) else _result(false,
			"pkai_restore_failed", String(restored.get("reason", "Country AI state restore failed")))
	# Saves made before Country AI: exclude the player country found at the
	# saved start cell, then let the AI start fresh for every foreign country.
	var player_context = sections.get("player_context", {})
	var start_cell := int(player_context.get("start_cell", -1)) if player_context is Dictionary else -1
	var country = context.country
	var handle := int(country.cell_summary(start_cell).get("country_handle", 0)) \
		if country != null and start_cell >= 0 else 0
	if handle == 0:
		return {"ok": true}
	return facade.set_player_handles(PackedInt64Array([handle]))


func _restore_country_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var restored := _restore_country_state(sections, context)
	if not bool(restored.get("ok", false)):
		return restored
	if not context.prepare_economy.is_valid():
		return _result(false, "load_economy_prepare_missing", "地图运行时缺少经济恢复准备接口。")
	var prepared: Dictionary = context.prepare_economy.call()
	return restored if bool(prepared.get("ok", false)) else _result(false,
		"load_economy_prepare_failed", String(prepared.get("reason", "PKCN 后无法准备经济恢复。")))
