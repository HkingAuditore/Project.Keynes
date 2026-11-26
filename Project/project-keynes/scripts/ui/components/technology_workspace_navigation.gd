extends RefCounted

## Selects the research view, era, branch, and item to inspect.


static func _ensure_focus_domain(owner: TechnologyWorkspace) -> void:
	if owner._focus_domain.is_empty() and not owner._domains.is_empty():
		owner._focus_domain = String((owner._domains[0] as Dictionary).get("id", ""))



static func _set_mode(owner: TechnologyWorkspace, mode: int) -> void:
	if mode == TechnologyWorkspace.MODE_OVERVIEW:
		owner._mode = TechnologyWorkspace.MODE_OVERVIEW
	elif mode == TechnologyWorkspace.MODE_FOCUS:
		owner._mode = TechnologyWorkspace.MODE_FOCUS
	else:
		owner._mode = TechnologyWorkspace.MODE_AVAILABLE
	if owner._mode_nav.current != TechnologyWorkspace.MODE_IDS[owner._mode]:
		owner._mode_nav.select(TechnologyWorkspace.MODE_IDS[owner._mode])
	owner._available.visible = owner._mode == TechnologyWorkspace.MODE_AVAILABLE
	owner._tree.visible = owner._mode == TechnologyWorkspace.MODE_FOCUS
	owner._overview.visible = owner._mode == TechnologyWorkspace.MODE_OVERVIEW
	owner._era_plate.visible = owner._mode == TechnologyWorkspace.MODE_FOCUS
	owner._prev_era.disabled = owner._mode != TechnologyWorkspace.MODE_FOCUS
	owner._next_era.disabled = owner._mode != TechnologyWorkspace.MODE_FOCUS
	if owner._mode == TechnologyWorkspace.MODE_FOCUS:
		owner._apply_focus(-1 if not owner._manual_focus else (
			owner._tree.selected_technology() if owner._tree.selected_technology() >= 0 else -1))
	elif owner._mode == TechnologyWorkspace.MODE_OVERVIEW:
		owner._overview.patch_states(owner._presentation_states(owner._research.get(
			"technology_states", PackedInt32Array())))
	elif owner._mode == TechnologyWorkspace.MODE_AVAILABLE:
		owner._available.patch_states(
			owner._presentation_states(owner._research.get("technology_states", PackedInt32Array())),
			owner._presentation_progress(owner._research.get("technology_progress", PackedInt64Array())))
	var canvas := owner._available if owner._mode == TechnologyWorkspace.MODE_AVAILABLE \
		else (owner._tree if owner._mode == TechnologyWorkspace.MODE_FOCUS else owner._overview)
	if owner._mode == TechnologyWorkspace.MODE_AVAILABLE:
		var scroll_top := float(owner._available.scroll_vertical)
		UIAnimation.reveal_technology_page(owner._available.list_canvas(), scroll_top, owner._available.size.y)
	else:
		UIAnimation.reveal_technology_page(canvas)



static func _on_mode_chapter_selected(owner: TechnologyWorkspace, chapter_id: String) -> void:
	owner._set_mode(maxi(0, TechnologyWorkspace.MODE_IDS.find(chapter_id)))



static func _shift_era(owner: TechnologyWorkspace, delta: int) -> void:
	var target := clampi(owner._focus_era + delta, 0, maxi(0, owner._deepest_visible_era()))
	if target == owner._focus_era:
		return
	owner._manual_focus = true
	owner._focus_era = target
	owner._apply_focus(-1)



static func _on_overview_cell_activated(owner: TechnologyWorkspace, domain_id: String, era_index: int,
		technology_index: int) -> void:
	owner._focus_domain = domain_id
	owner._focus_era = era_index
	owner._manual_focus = true
	owner._set_mode(TechnologyWorkspace.MODE_FOCUS)
	owner._apply_focus(technology_index)



static func _on_search_submitted(owner: TechnologyWorkspace, query: String) -> void:
	var normalized := query.strip_edges().to_lower()
	if normalized.is_empty():
		return
	var states := owner._presentation_states(owner._research.get(
		"technology_states", PackedInt32Array()))
	var best := -1
	for index in range(owner._definitions.size()):
		if index >= states.size() or not TechnologyTreeView.presents_state(states[index]):
			continue
		if owner._is_retired(index):
			continue
		var name := String((owner._definitions[index] as Dictionary).get("display_name", ""))
		if name.to_lower() == normalized:
			best = index
			break
		if best < 0 and name.to_lower().contains(normalized):
			best = index
	if best >= 0:
		owner._focus_technology(best)
		owner._search.text = String((owner._definitions[best] as Dictionary).get("display_name", ""))
	else:
		owner._search.text = ""
		owner._search.placeholder_text = "未找到可见科技"



static func _focus_technology(owner: TechnologyWorkspace, index: int) -> void:
	if index < 0 or index >= owner._definitions.size():
		return
	var states := owner._presentation_states(owner._research.get(
		"technology_states", PackedInt32Array()))
	var definition: Dictionary = owner._definitions[index]
	if owner._is_retired(index):
		# Retired era tokens have no place on the atlas. A legacy queue entry
		# can still be inspected (and removed) from the detail column.
		owner._selected_technology = index
		owner._manual_focus = true
		owner._refresh_detail()
		return
	if index >= states.size() or not TechnologyTreeView.presents_state(states[index]):
		return
	owner._focus_domain = String(definition.get("domain_id", ""))
	owner._focus_era = owner._era_index(String(definition.get("era_id", "")))
	owner._manual_focus = true
	owner._selected_technology = index
	owner._set_mode(TechnologyWorkspace.MODE_FOCUS)
	owner._apply_focus(index)



static func _apply_focus(owner: TechnologyWorkspace, preferred_index: int) -> void:
	if owner._eras.is_empty() or owner._tree == null:
		return
	owner._ensure_focus_domain()
	owner._focus_era = clampi(owner._focus_era, 0, maxi(0, owner._deepest_visible_era()))
	owner._tree.set_focus(owner._focus_domain, owner._focus_era, preferred_index)
	owner._era_label.text = String((owner._eras[owner._focus_era] as Dictionary).get("display_name", "—"))
	owner._prev_era.disabled = owner._mode != TechnologyWorkspace.MODE_FOCUS or owner._focus_era <= 0
	owner._next_era.disabled = owner._mode != TechnologyWorkspace.MODE_FOCUS or owner._focus_era >= owner._deepest_visible_era()
	owner._refresh_detail()



static func _apply_default_focus(owner: TechnologyWorkspace) -> void:
	if owner._definitions.is_empty():
		return
	var target := owner._queue_priority_target()
	if target < 0:
		target = owner._frontier_target()
	if target < 0:
		owner._set_mode(TechnologyWorkspace.MODE_AVAILABLE)
		owner._initial_focus_pending = false
		owner._manual_focus = true
		return
	var definition: Dictionary = owner._definitions[target]
	owner._focus_domain = String(definition.get("domain_id", ""))
	owner._focus_era = owner._era_index(String(definition.get("era_id", "")))
	owner._initial_focus_pending = false
	owner._manual_focus = false
	owner._set_mode(TechnologyWorkspace.MODE_AVAILABLE)
	owner._available.select_technology(target)
	owner._on_available_selected(target)



static func _queue_priority_target(owner: TechnologyWorkspace) -> int:
	var offsets: PackedInt32Array = owner._research.get("queue_offsets",
		PackedInt32Array([0, 0, 0, 0, 0]))
	var technologies: PackedInt32Array = owner._research.get("queue_technology_indices",
		PackedInt32Array())
	var weights: PackedInt32Array = owner._research.get("domain_weights_bp",
		PackedInt32Array([2500, 2500, 2500, 2500]))
	var best_domain := -1
	var best_weight := -1
	for domain in range(TechnologyWorkspace.DOMAIN_COUNT):
		if domain + 1 >= offsets.size() or offsets[domain] >= offsets[domain + 1]:
			continue
		var weight := int(weights[domain]) if domain < weights.size() else 0
		if weight > best_weight:
			best_weight = weight
			best_domain = domain
	if best_domain < 0:
		return -1
	var cursor := int(offsets[best_domain])
	return int(technologies[cursor]) if cursor >= 0 and cursor < technologies.size() else -1



static func _frontier_target(owner: TechnologyWorkspace) -> int:
	var states: PackedInt32Array = owner._research.get("technology_states", PackedInt32Array())
	var best := -1
	var best_era := -1
	for index in range(mini(states.size(), owner._definitions.size())):
		if states[index] != 2 or owner._is_retired(index):
			continue
		var era := owner._era_index(String((owner._definitions[index] as Dictionary).get("era_id", "")))
		if era > best_era:
			best = index
			best_era = era
	if best >= 0:
		return best
	for index in range(mini(states.size(), owner._definitions.size())):
		if not TechnologyTreeView.presents_state(states[index]) or owner._is_retired(index):
			continue
		var era := owner._era_index(String((owner._definitions[index] as Dictionary).get("era_id", "")))
		if era > best_era:
			best = index
			best_era = era
	return best



static func _era_index(owner: TechnologyWorkspace, era_id: String) -> int:
	for index in range(owner._eras.size()):
		if String((owner._eras[index] as Dictionary).get("id", "")) == era_id:
			return index
	return 0


## Era milestones are retired from player research: they remain internal era
## tokens granted by era advancement and never appear in research lists, the
## atlas, the overview, search, or relation rows.
static func _is_retired(owner: TechnologyWorkspace, index: int) -> bool:
	return index >= 0 and index < owner._definitions.size() \
		and TechnologyTreeView.is_retired_definition(owner._definitions[index] as Dictionary)



static func _deepest_visible_era(owner: TechnologyWorkspace) -> int:
	var states := owner._presentation_states(owner._research.get(
		"technology_states", PackedInt32Array()))
	var deepest := 0
	var parents: Array = []
	if owner._tree != null:
		parents = owner._tree.topology_report().get("parents", [])
	for index in range(mini(states.size(), owner._definitions.size())):
		if owner._is_retired(index) or not owner._tree_visible_from_states(index, states, parents):
			continue
		deepest = maxi(deepest, owner._era_index(String(
			(owner._definitions[index] as Dictionary).get("era_id", ""))))
	return deepest



static func _tree_visible_from_states(owner: TechnologyWorkspace, index: int, states: PackedInt32Array,
		parents: Array) -> bool:
	if TechnologyTreeView.presents_state(int(states[index]) if index < states.size() else 0):
		return true
	if index < 0 or index >= parents.size():
		return false
	for parent in parents[index]:
		var parent_index := int(parent)
		if TechnologyTreeView.presents_state(
				int(states[parent_index]) if parent_index < states.size() else 0):
			return true
	return false
