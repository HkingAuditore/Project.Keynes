extends "res://scripts/game/save_modules/state_adapter.gd"

## Owns vision persistence; receives only declared capabilities.

func _can_vision_provider(context: Dictionary) -> Dictionary:
	var map = context.get("map")
	return _result(map != null and map.cell_count() > 0,
		"ok" if map != null else "save_provider_missing",
		"" if map != null else "视野 provider 不可用。")

func _write_vision_provider(context: Dictionary) -> Dictionary:
	var map: MapData = context.map
	var explored := map.explored_arr
	if explored.size() != map.cell_count():
		# 迷雾从未解算过（沙盒 / 迷雾关）。写一份空进度，保持 section 必存。
		explored = PackedByteArray()
		explored.resize(map.cell_count())
	# 迷雾开启且玩家已有领土时 explored 必然非空：首都及其邻格一定被揭开。
	# 全 0 只可能是本局视野没解算成功，落盘会把上一份存档的探索进度永久抹掉。
	# 先重解一次，仍为空就拒绝写档，把旧进度留在磁盘上。
	if bool(context.fog_enabled) and not _has_explored_progress(explored) \
			and _player_territory_cells(int(context.player_slot), map) > 0:
		context.refresh_vision.call("save_capture_vision_repair")
		explored = map.explored_arr
		if explored.size() != map.cell_count() \
				or not _has_explored_progress(explored):
			return _result(false, "pkfg_vision_unsolved",
				"玩家视野尚未解算，写档会清空探索进度。")
	var payload := {
		"schema": "PKFogOfWar",
		"version": 4,
		"cells": map.cell_count(),
		"explored": explored,
	}
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
	var explored := PackedByteArray(payload.get("explored", PackedByteArray()))
	if explored.size() != n:
		return _result(false, "pkfg_restore_failed", "视野 section 已截断。")
	var intel = context.intel
	if intel != null:
		var type_count := int(context.type_count)
		var intel_restore: Dictionary = intel.restore_pkfg(payload, type_count)
		if not bool(intel_restore.get("ok", false)):
			return _result(false, "pkfg_restore_failed",
				String(intel_restore.get("reason", "建筑情报 CSR 无效。")))
	# Commit exploration only after the complete PKFG payload validated. A bad
	# building CSR therefore cannot partially mutate the current fog state.
	map.explored_arr = explored
	# 玩家 session provider 仍在 PKFG 之后。这里只提交单调探索权威；全部
	# provider 恢复完毕后由 finalize_save_restore_visuals 重绑玩家国家，
	# 再依据 PKCN 领土重算 visible/fog 并发布 enum_lut.a。
	return _result(true, "ok", "")

func _has_explored_progress(explored: PackedByteArray) -> bool:
	for value in explored:
		if value != 0:
			return true
	return false

func _player_territory_cells(slot: int, map: MapData) -> int:
	if slot < 0:
		return 0
	var count := 0
	for value in map.country_slot_arr:
		count += 1 if int(value) == slot else 0
	return count


func section_codecs(_id: StringName, sections: PackedStringArray) -> Dictionary:
	var codecs := {}
	for section in sections:
		codecs[section] = "bytes" if section == "preview" else "variant"
	return codecs
