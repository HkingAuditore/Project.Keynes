extends "res://scripts/game/save_modules/state_adapter.gd"

## Owns modifier, climate_modifier, gameplay_modifier, trigger, effect, ideology persistence; receives only declared capabilities.

const EXECUTION_CONTRACT_KEY := "execution_contract_hash"

func _can_modifier_provider(context: Dictionary) -> Dictionary:
	var facade = context.get("modifier")
	var ext = facade.world_ext() if facade != null and facade.is_configured() else null
	var available: bool = ext != null

	return _result(available, "ok" if available else "save_provider_missing",
		"" if available else "Modifier provider 不可用。")

func _write_modifier_provider(context: Dictionary, domain: int,
		section_id: String) -> Dictionary:
	var facade = context.modifier
	var bytes: PackedByteArray = facade.world_ext().capture_modifier_domain(domain)
	if bytes.is_empty():
		return _result(false, "%s_save_failed" % section_id,
			"Modifier domain 无法序列化。")
	return {"ok": true, "sections": {section_id: bytes}}

func _restore_modifier_provider(sections: Dictionary, context: Dictionary,
		domain: int, section_id: String) -> Dictionary:
	var ext = context.modifier.world_ext()
	var bytes := PackedByteArray(sections.get(section_id, PackedByteArray()))
	var result: Dictionary
	if bytes.is_empty():
		result = ext.clear_modifier_domain(domain)
	else:
		result = ext.restore_modifier_domain(domain, bytes)
	return result if bool(result.get("ok", false)) else _result(false,
		"%s_restore_failed" % section_id,
		String(result.get("reason", "Modifier domain 恢复失败。")))

func _write_climate_modifier_provider(context: Dictionary) -> Dictionary:
	return _write_modifier_provider(context, 0, "pkcm")

func _restore_climate_modifier_provider(sections: Dictionary,
		context: Dictionary) -> Dictionary:
	return _restore_modifier_provider(sections, context, 0, "pkcm")

func _write_gameplay_modifier_provider(context: Dictionary) -> Dictionary:
	return _write_modifier_provider(context, 3, "pkgp")

func _restore_gameplay_modifier_provider(sections: Dictionary,
		context: Dictionary) -> Dictionary:
	return _restore_modifier_provider(sections, context, 3, "pkgp")

func _can_trigger_provider(context: Dictionary) -> Dictionary:
	var facade = context.get("trigger")
	var ext = facade.world_ext() if facade != null and facade.is_configured() else null
	var available: bool = ext != null
	return _result(available, "ok" if available else "save_provider_missing",
		"Trigger provider unavailable" if not available else "")

func _write_trigger_provider(context: Dictionary) -> Dictionary:
	var facade = context.trigger
	var bytes: PackedByteArray = facade.world_ext().capture_trigger_state()
	if bytes.is_empty():
		return _result(false, "pktr_save_failed", "Trigger state serialization failed")
	return {"ok": true, "sections": {"pktr": bytes}}

func _restore_trigger_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var facade = context.trigger
	var ext = facade.world_ext()
	var bytes := PackedByteArray(sections.get("pktr", PackedByteArray()))
	var result: Dictionary = ext.clear_trigger_state() if bytes.is_empty() else ext.restore_trigger_state(bytes)
	return result if bool(result.get("ok", false)) else _result(false,
		"pktr_restore_failed", String(result.get("reason", "Trigger state restore failed")))

func _can_effect_provider(context: Dictionary) -> Dictionary:
	var facade = context.get("effect")
	var ext = facade.world_ext() if facade != null and facade.is_configured() else null
	var available: bool = ext != null
	return _result(available, "ok" if available else "save_provider_missing",
		"Effect provider unavailable" if not available else "")

func _write_effect_provider(context: Dictionary) -> Dictionary:
	var facade = context.effect
	var bytes: PackedByteArray = facade.world_ext().capture_effect_state()
	if bytes.is_empty():
		return _result(false, "pkef_save_failed", "Effect state serialization failed")
	return {"ok": true, "sections": {"pkef": bytes}}

func _restore_effect_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var facade = context.effect
	var ext = facade.world_ext()
	var bytes := PackedByteArray(sections.get("pkef", PackedByteArray()))
	var result: Dictionary = ext.clear_effect_state() if bytes.is_empty() else ext.restore_effect_state(bytes)
	return result if bool(result.get("ok", false)) else _result(false,
		"pkef_restore_failed", String(result.get("reason", "Effect state restore failed")))

func _can_ideology_provider(context: Dictionary) -> Dictionary:
	var facade = context.get("ideology")
	var ext = facade.world_ext() if facade != null and facade.is_configured() else null
	var available: bool = ext != null
	return _result(available, "ok" if available else "save_provider_missing",
		"Ideology provider unavailable" if not available else "")

func _write_ideology_provider(context: Dictionary) -> Dictionary:
	var facade = context.ideology
	var bytes: PackedByteArray = facade.world_ext().capture_ideology_state()
	if bytes.is_empty():
		return _result(false, "pkid_save_failed", "Ideology state serialization failed")
	return {"ok": true, "sections": {"pkid": bytes}}

func _restore_ideology_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var facade = context.ideology
	var ext = facade.world_ext()
	# PKID is intentionally an empty-state migration for saves made before the
	# ideology runtime. New saves always contain a non-empty native PKID payload.
	var bytes := PackedByteArray(sections.get("pkid", PackedByteArray()))
	var result: Dictionary = ext.clear_ideology_state() if bytes.is_empty() else ext.restore_ideology_state(bytes)
	return result if bool(result.get("ok", false)) else _result(false,
		"pkid_restore_failed", String(result.get("reason", "Ideology state restore failed")))

func _ideology_manifest_identity(context: Dictionary) -> Dictionary:
	var report_reader: Callable = context.ideology_report
	if not report_reader.is_valid():
		return {}
	var contract := _contract_from_report(report_reader.call())
	if contract == 0:
		return {}
	return {EXECUTION_CONTRACT_KEY: str(contract)}

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

func _contract_value(value) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String or value is StringName:
		return String(value).to_int()
	return 0
