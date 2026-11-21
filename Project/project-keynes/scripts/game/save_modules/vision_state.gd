extends "res://scripts/game/save_modules/state_adapter.gd"

## Owns vision persistence; receives only declared capabilities.

func _can_vision_provider(context: Dictionary) -> Dictionary:
	var map = context.get("map")
	return _result(map != null and map.cell_count() > 0,
		"ok" if map != null else "save_provider_missing",
		"" if map != null else "视野 provider 不可用。")

func _write_vision_provider(context: Dictionary) -> Dictionary:
	var map: MapData = context.map
	var payload := {"schema": "PKFogOfWar", "version": 4, "cells": map.cell_count()}
	var intel = context.intel
	if intel != null:
		payload.merge(intel.to_pkfg_fields(), true)
	else:
		var empty_intel := BuildingVisualIntelCache.new()
		empty_intel.configure(map.cell_count())
		payload.merge(empty_intel.to_pkfg_fields(), true)
	return {"ok": true, "sections": {"pkfg": payload}}

func _restore_vision_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var payload = sections.get("pkfg")
	if not payload is Dictionary or String(payload.get("schema", "")) != "PKFogOfWar":
		return _result(false, "pkfg_restore_failed", "视野 section 格式不正确。")
	var map: MapData = context.map
	if map == null:
		return _result(false, "pkfg_restore_failed", "视野恢复时地图不可用。")
	var n := map.cell_count()
	if int(payload.get("cells", -1)) != n:
		return _result(false, "pkfg_restore_failed", "视野 section 的格数与当前地图不一致。")
	var intel = context.intel
	if intel != null:
		var type_count := int(context.type_count)
		var intel_restore: Dictionary = intel.restore_pkfg(payload, type_count)
		if not bool(intel_restore.get("ok", false)):
			return _result(false, "pkfg_restore_failed",
				String(intel_restore.get("reason", "建筑情报 CSR 无效。")))
	return _result(true, "ok", "")


func section_codecs(_id: StringName, sections: PackedStringArray) -> Dictionary:
	var codecs := {}
	for section in sections:
		codecs[section] = "bytes" if section == "preview" else "variant"
	return codecs
