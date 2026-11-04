extends "res://scripts/game/save_modules/state_adapter.gd"

## Owns simulation_runtime persistence; receives only declared capabilities.

func _can_simulation_runtime_provider(context: Dictionary) -> Dictionary:
	return _result(context.restore_bundle.is_valid(), "ok" \
		if context.restore_bundle.is_valid() else "save_provider_missing",
		"模拟 runtime provider 不可用。")

func _write_simulation_runtime_provider(context: Dictionary) -> Dictionary:
	var native_bundle: PackedByteArray = context.get("native_runtime_bundle", PackedByteArray())
	if not native_bundle.is_empty():
		return {"ok": true, "sections": {"simulation_runtime": native_bundle}}
	var runtime_report: Dictionary = {}
	var report_reader: Callable = context.runtime_report
	if report_reader.is_valid():
		runtime_report = report_reader.call()
	return {"ok": true, "sections": {"simulation_runtime": {
		"schema": "PKSR",
		"version": 2,
		"committed_day": context.clock.day_index() if context.clock != null else 0,
		"paused": bool(context.get("saved_paused", true)),
		"speed_days_per_second": float(context.get("saved_speed", 0.0)),
		"runtime_thread_report": runtime_report,
		"native_save_bundle": false,
	}}}

func _restore_simulation_runtime_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var runtime = sections.get("simulation_runtime", {})
	if runtime is PackedByteArray:
		if not preload("res://scripts/game/pksr_bundle_header.gd").valid(runtime):
			return _result(false, "simulation_runtime_checksum_failed",
				"PKSR runtime bundle 校验失败。")
		if not context.restore_bundle.is_valid():
			return _result(false, "simulation_runtime_restore_missing",
				"地图运行时缺少 PKSR 后台恢复接口。")
		# SaveRepository has already verified both PKSV section SHA-256 hashes.
		# Native restore accepts this duplicate only for the exact legacy 64 MiB truncation.
		var restored: Dictionary = context.restore_bundle.call(runtime,
			sections.get("ecp2", PackedByteArray()))
		if not bool(restored.get("ok", false)):
			return _result(false, String(restored.get("code",
				"simulation_runtime_restore_failed")),
				"PKSR runtime bundle 恢复失败：%s" % String(
					restored.get("code", "unknown")))
		if bool(restored.get("recovered_truncated_ecp2", false)):
			print("[save/restore] recovered legacy 64 MiB ECP2 truncation from verified PKSV section")
		return restored
	if runtime.is_empty():
		return _result(true, "ok", "")
	if String(runtime.get("schema", "PKSR")) != "PKSR" \
			or int(runtime.get("version", 1)) != 2:
		return _result(false, "simulation_runtime_incompatible", "PKSR runtime section 版本不兼容。")
	return _result(true, "ok", "")


func decode_archive(archive: Dictionary) -> Dictionary:
	if not archive.has("simulation_runtime"):
		return _result(false, "save_provider_missing", "存档缺少 simulation_runtime。")
	var bytes: PackedByteArray = archive.simulation_runtime
	var value = bytes
	if bytes.is_empty():
		value = {}
	elif not preload("res://scripts/game/pksr_bundle_header.gd").valid(bytes):
		value = bytes_to_var(bytes)
		if not value is Dictionary:
			return _result(false, "save_section_decode_failed", "无法解析存档 section：simulation_runtime")
	return {"ok": true, "sections": {"simulation_runtime": value}}


func configure_provider(provider: RuntimeStateProvider) -> void:
	provider.configure_decoder(decode_archive)
