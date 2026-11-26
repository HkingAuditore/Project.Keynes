extends RefCounted

## Reads the committed settlement, family, and expedition data used by the colonization planner.


static func get_family_colonization_quotes(owner: PlayerController, target_cell: int, family_filter: int = 0,
		source_filter: int = -1, offset: int = 0, limit: int = 64) -> Dictionary:
	var ready := owner._resolve_player_country()
	if not bool(ready.get("ok", false)):
		return ready
	if owner._economy_facade == null:
		return PlayerController._result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	return owner._economy_facade.family_colonization_quotes(owner._player_country_handle,
		target_cell, family_filter, source_filter, offset, limit)



static func get_family_colonization_quote_detail(owner: PlayerController, quote_token: int,
		population: int = -1) -> Dictionary:
	var ready := owner._resolve_player_country()
	if not bool(ready.get("ok", false)):
		return ready
	var detail: Dictionary = owner._economy_facade.family_colonization_quote_detail(
		quote_token, population)
	if bool(detail.get("ok", false)) and int(detail.get(
			"country_handle", 0)) != owner._player_country_handle:
		return PlayerController._result(false, "colonization_quote_forbidden", "报价不属于玩家国家。")
	return detail



static func get_family_dispatch_candidates(owner: PlayerController, source_cell: int, offset: int = 0,
		limit: int = 64) -> Dictionary:
	var ready := owner._resolve_player_country()
	if not bool(ready.get("ok", false)):
		return ready
	if not owner.is_player_owned_cell(source_cell):
		return PlayerController._result(false, "territory_not_owned", "只能查看本国地块的开拓候选。")
	if owner._economy_facade == null:
		return PlayerController._result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	return owner._economy_facade.family_cell_snapshot(source_cell, offset, limit)



static func get_family_dispatch_preview(owner: PlayerController, family_handle: int, source_cell: int) -> Dictionary:
	var offset := 0
	var branch := {}
	while true:
		var page := owner.get_family_dispatch_candidates(source_cell, offset, 256)
		if not bool(page.get("ok", false)):
			return page
		var handles: PackedInt64Array = page.get("family_handles", PackedInt64Array())
		var index := handles.find(family_handle)
		if index >= 0:
			for key in ["populations", "cash_claims", "owned_buildings", "prestige_levels", "family_names"]:
				var values: Variant = page.get(key, [])
				if index < values.size():
					branch[key] = values[index]
			break
		if not bool(page.get("has_more", false)) or handles.is_empty():
			return PlayerController._result(false, "colonization_population_insufficient", "该城已没有此家族的分支。")
		offset += handles.size()
	var traits: Dictionary = owner._economy_facade.get_family_traits(family_handle)
	return {"ok": true, "branch": branch,
		"traits": traits,
		"behavior_rows": CellInspectorViewModel.family_behavior_rows_for_cell(
			traits, owner._economy_facade, source_cell),
		"effects": owner._economy_facade.get_family_branch_effects(family_handle, source_cell)}



static func can_family_colonize_from(owner: PlayerController, family_handle: int, source_cell: int) -> bool:
	# 只检查真实当地分支，路线和物资仍由选点后的原生报价决定。
	var offset := 0
	while true:
		var page := owner.get_family_dispatch_candidates(source_cell, offset, 256)
		if not bool(page.get("ok", false)):
			return false
		var handles: PackedInt64Array = page.get("family_handles", PackedInt64Array())
		var people: PackedInt64Array = page.get("populations", PackedInt64Array())
		var index := handles.find(family_handle)
		if index >= 0:
			return index < people.size() and people[index] > 1
		if not bool(page.get("has_more", false)) or handles.is_empty():
			return false
		offset += handles.size()
	return false



static func dispatch_cell_display_name(owner: PlayerController, cell: int) -> String:
	if owner._economy_facade == null or cell < 0:
		return "待选择"
	if not owner.is_player_owned_cell(cell):
		if owner._runtime_host == null or owner._runtime_host.current_map() == null \
				or VisionSolver.fog_state(owner._runtime_host.current_map(), cell) != VisionSolver.FOG_VISIBLE:
			return "待选择"
	return owner._economy_facade.settlement_display_name(cell)



static func get_family_expeditions(owner: PlayerController, offset: int = 0, limit: int = 64) -> Dictionary:
	var ready := owner._resolve_player_country()
	if not bool(ready.get("ok", false)):
		return ready
	if owner._economy_facade == null or not owner._economy_facade.has_method("family_expeditions"):
		return PlayerController._result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	return owner._economy_facade.family_expeditions(owner._player_country_handle,
		offset, limit)



static func get_family_expedition_snapshot(owner: PlayerController, expedition_handle: int) -> Dictionary:
	var ready := owner._resolve_player_country()
	if not bool(ready.get("ok", false)):
		return ready
	if owner._economy_facade == null or not owner._economy_facade.has_method("family_expedition_snapshot"):
		return PlayerController._result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	return owner._economy_facade.family_expedition_snapshot(owner._player_country_handle,
		expedition_handle)



static func good_display_name(owner: PlayerController, good_index: int) -> String:
	if owner._economy_facade != null and owner._economy_facade.has_method("good_display_name"):
		return String(owner._economy_facade.good_display_name(good_index))
	return "物资#%d" % good_index



static func get_family_snapshot(owner: PlayerController, family_handle: int) -> Dictionary:
	if owner._economy_facade == null:
		return PlayerController._result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	return owner._economy_facade.family_snapshot(family_handle)



static func get_family_traits(owner: PlayerController, family_handle: int) -> Dictionary:
	if owner._economy_facade == null:
		return PlayerController._result(false, "runtime_unavailable", "经济系统尚未就绪，请稍后再试。")
	return owner._economy_facade.get_family_traits(family_handle)



static func is_player_owned_cell(owner: PlayerController, cell: int) -> bool:
	if owner._country_facade == null or cell < 0 or owner._player_country_handle == 0:
		return false
	var published: Dictionary = owner._country_facade.cell_summary(cell)
	return int(published.get("country_handle", 0)) == owner._player_country_handle
