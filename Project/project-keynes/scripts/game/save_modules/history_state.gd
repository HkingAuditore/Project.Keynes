extends "res://scripts/game/save_modules/state_adapter.gd"

## Owns journal, annual, narrative persistence; receives only declared capabilities.

func _can_journal_provider(context: Dictionary) -> Dictionary:
	var event_bus = context.get("event_bus")
	return _result(event_bus != null, "ok" if event_bus != null else "save_provider_missing",
		"" if event_bus != null else "事件 journal provider 不可用。")

func _write_journal_provider(context: Dictionary) -> Dictionary:
	var journal: Dictionary = context.event_bus.snapshot_journal()
	if bool(journal.get("fallback", false)):
		return _result(false, "journal_provider_missing", "事件 journal provider 不可用。")
	return {"ok": true, "sections": {"journal": journal}}

func _restore_journal_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var result: Dictionary = context.event_bus.restore_journal(sections.journal)
	if not bool(result.get("ok", false)) and not bool(result.get("fallback", false)):
		return _result(false, "journal_restore_failed",
			"事件 journal 恢复失败：%s" % String(result.get("reason", "unknown")))
	return _result(true, "ok", "")

func _can_annual_provider(context: Dictionary) -> Dictionary:
	var ext = context.get("annual")
	return _result(ext != null,
		"ok" if ext != null else "annual_provider_missing", "")

func _write_annual_provider(context: Dictionary) -> Dictionary:
	var facade = context.annual
	var bytes: PackedByteArray = facade.capture_annual_state()
	if bytes.is_empty() and bool(facade.annual_status().get("ok", false)):
		return _result(false, "annual_capture_failed", "年度报告存档失败。")
	return {"ok": true, "sections": {"pkar": bytes}}

func _restore_annual_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var bytes: PackedByteArray = sections.get("pkar", PackedByteArray())
	if bytes.is_empty():
		return {"ok": true}
	var facade = context.annual
	return facade.restore_annual_state(bytes)

func _can_narrative_provider(_context: Dictionary) -> Dictionary:
	return _result(true, "ok", "")

func _write_narrative_provider(context: Dictionary) -> Dictionary:
	var bus = context.get("event_bus")
	return {"ok": true, "sections": {"pknr": bus.capture_story() if bus != null else {}}}

func _restore_narrative_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var raw_state = sections.get("pknr", {})
	var bus = context.get("event_bus")
	if bus != null and raw_state is Dictionary and not raw_state.is_empty():
		return bus.restore_story(raw_state)
	return _result(true, "ok", "")


func section_codecs(id: StringName, _sections: PackedStringArray) -> Dictionary:
	return {String(id): "variant"} if id in [&"journal", &"pknr"] else {}
