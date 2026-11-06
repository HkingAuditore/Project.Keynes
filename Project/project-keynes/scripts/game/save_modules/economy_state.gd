extends "res://scripts/game/save_modules/state_adapter.gd"

## Owns economy persistence; receives only declared capabilities.
# Section contract belongs to the module. The coordinator uses the existing registry.
static func archive_contract(schema: int) -> Dictionary:
	return {"id": &"ecp2", "version": schema, "sections": PackedStringArray(["ecp2"]),
		"restore_after": PackedStringArray(["pkcn", "pkmi", "pkef"]),
		"can": &"_can_economy_provider", "write": &"_write_economy_provider",
		"restore": &"_restore_economy_provider", "readable_versions": PackedInt32Array([schema])}

func _can_economy_provider(context: Dictionary) -> Dictionary:
	var facade = context.get("economy")
	var available: bool = facade != null and facade.is_configured() \
		and facade.has_method("capture_ecp2") and facade.has_method("restore_ecp2")
	return _result(available,
		"ok" if available else "save_provider_missing",
		"" if available else "ECP2 economy provider 不可用。")

func _write_economy_provider(context: Dictionary) -> Dictionary:
	var shared_ecp2: PackedByteArray = context.get("native_economy_ecp2", PackedByteArray())
	if not shared_ecp2.is_empty() and OS.get_environment("PK_SAVE_ECP2_REUSE_DISABLE") != "1":
		if OS.get_environment("PK_SAVE_ECP2_REUSE_VERIFY") == "1":
			var reference: Dictionary = context.economy.capture_ecp2(0)
			if not bool(reference.get("ok", false)) or reference.get("bytes") != shared_ecp2:
				return _result(false, "ecp2_shared_capture_mismatch",
					"冻结 ECP2 与完整捕获结果不一致。")
			print("[save/ecp2-reuse] full byte comparison passed bytes=%d" % shared_ecp2.size())
		return {"ok": true, "sections": {"ecp2": shared_ecp2}}
	var facade = context.economy
	var captured: Dictionary = facade.capture_ecp2(0)
	if not bool(captured.get("ok", false)):
		return _result(false, "ecp2_save_failed",
			String(captured.get("reason", "无法捕获 ECP2 经济权威。")))
	var bytes: PackedByteArray = captured.get("bytes", PackedByteArray())
	if bytes.is_empty():
		return _result(false, "ecp2_save_empty", "ECP2 捕获结果为空。")
	return {"ok": true, "sections": {"ecp2": bytes}}

func _restore_economy_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	if not sections.has("ecp2"):
		return _result(false, "ecp2_missing",
			"存档缺少 ECP2 经济 section。")
	var bytes: PackedByteArray = sections.ecp2
	if bytes.is_empty():
		return _result(false, "ecp2_missing", "ECP2 section 为空。")
	var facade = context.economy
	var result: Dictionary = facade.restore_ecp2(bytes)
	if not bool(result.get("ok", false)):
		return _result(false, "ecp2_restore_failed",
			String(result.get("restore_rejected_reason",
				result.get("reason", "经济 ECP2 恢复失败。"))))
	# ECP2 owns the authored building catalog. Bind it before PKFG is restored so
	# building intel type indices are checked against the authoritative type count.
	if context.refresh_buildings.is_valid():
		var visual_setup: Dictionary = context.refresh_buildings.call()
		if not bool(visual_setup.get("ok", false)) \
				and not bool(visual_setup.get("deferred", false)):
			push_warning("[building-visual] restore bind disabled: %s" % String(
				visual_setup.get("reason", "catalog audit failed")))
	return result
