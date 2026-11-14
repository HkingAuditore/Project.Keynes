extends RefCounted

## Display helpers borrow the host per call; state and signal receivers stay there.


static func _refresh_detail(host, refresh_relations: bool = true) -> void:
	var index = host._selected_technology
	if index < 0:
		index = int(host._available.selected_technology()) if host._available != null else -1
	if index < 0:
		index = int(host._tree.selected_technology()) if host._tree != null else -1
	if index < 0 or index >= host._definitions.size():
		host._detail_signature = ""
		host._detail.show_empty()
		return
	host._selected_technology = index
	var research_states: PackedInt32Array = host._research.get(
		"technology_states", PackedInt32Array()).duplicate()
	if not host._optimistic_queue.is_empty():
		var offsets: PackedInt32Array = host._research.get(
			"queue_offsets", PackedInt32Array()).duplicate()
		var technologies: PackedInt32Array = host._research.get(
			"queue_technology_indices", PackedInt32Array()).duplicate()
		host._overlay_optimistic_into(research_states, offsets, technologies, false)
	var states = host._presentation_states(research_states)
	var state = int(states[index]) if index < states.size() else 0
	var definition: Dictionary = host._definitions[index]
	if host._is_retired(index):
		# Only a legacy queued token can be selected (via its queue row): show
		# it with the remove action and nothing else.
		host._detail_signature = ""
		if state == 3:
			host._detail.show_retired_queued(index, definition)
		else:
			host._selected_technology = -1
			host._detail.show_empty()
		return
	if not TechnologyTreeView.presents_state(state):
		host._detail_signature = ""
		host._detail.show_unknown(host._condition_items(index, states), state)
		return
	var progress: PackedInt64Array = host._research.get(
		"technology_progress", PackedInt64Array())
	# Compare in the runtime's scaled units. cost_points is an integer point
	# count and rounds to 0 for cheap nodes, which pinned their gauge at 0%.
	var cost = maxf(1.0, float(definition.get("cost_points_scaled",
		int(definition.get("cost_points", 1)) * host.POINT_SCALE)))
	var earned = float(progress[index]) if index < progress.size() else 0.0
	host._detail.set_schedule(host._schedule_text(index, state))
	if not refresh_relations and not host._detail_signature.is_empty():
		host._detail.update_progress(state, earned / cost, definition)
		return
	var relations = host._relations_for(index, states)
	# Relation rows are the only part that allocates nodes, so they are rebuilt
	# only when the selection or any related state actually changed.
	var signature = "%d:%d:%s" % [index, state, host._relation_signature(relations)]
	if signature == host._detail_signature:
		host._detail.update_progress(state, earned / cost, definition)
		return
	host._detail_signature = signature
	var domain = host._domain_index_of(definition)
	host._detail.show_technology(index, definition, state, earned / cost,
		host._domain_accent(domain),
		String(host._era_names.get(String(definition.get("era_id", "")),
			String(definition.get("era_id", "")))),
		host._domain_name(domain), relations)


static func _relation_signature(host, relations: Dictionary) -> String:
	var parts = PackedStringArray()
	for group in ["prerequisites", "hard_successors", "branch_successors", "applications"]:
		for entry in relations.get(group, []) as Array:
			parts.append("%d" % int((entry as Dictionary).get("state", 0)))
		parts.append("/")
	for entry in relations.get("condition_items", []) as Array:
		parts.append(String((entry as Dictionary).get("text", "")))
		parts.append("|")
	return "".join(parts)


static func _relations_for(host, index: int, states: PackedInt32Array) -> Dictionary:
	var definition: Dictionary = host._definitions[index]
	var hard_ids: PackedStringArray = definition.get(
		"prerequisite_ids", PackedStringArray())
	if host._is_application_definition(definition):
		hard_ids = definition.get("required_technology_ids", definition.get(
			"application_foundation_ids", PackedStringArray()))
	var rationales: PackedStringArray = definition.get(
		"prerequisite_rationales", PackedStringArray())
	var prerequisites: Array = []
	var prerequisite_ids: PackedStringArray = hard_ids
	for prerequisite_cursor in range(prerequisite_ids.size()):
		var prerequisite_id = String(prerequisite_ids[prerequisite_cursor])
		var prerequisite_index = int(host._technology_indices.get(prerequisite_id, -1))
		if prerequisite_index < 0 or host._is_retired(prerequisite_index):
			continue
		var reason = String(rationales[prerequisite_cursor]) \
			if prerequisite_cursor < rationales.size() else ""
		prerequisites.append(host._relation_entry_with_rationale(
			prerequisite_index, states, reason))
	var hard_successors: Array = []
	var selected_id = String(definition.get("id", ""))
	for target_index in range(host._definitions.size()):
		if host._is_retired(target_index):
			continue
		var target: Dictionary = host._definitions[target_index]
		var target_hard_ids: PackedStringArray = target.get(
			"prerequisite_ids", PackedStringArray())
		var rationale_index = target_hard_ids.find(selected_id)
		if rationale_index < 0:
			continue
		var target_rationales: PackedStringArray = target.get(
			"prerequisite_rationales", PackedStringArray())
		var reason = String(target_rationales[rationale_index]) \
			if rationale_index < target_rationales.size() else ""
		hard_successors.append(host._relation_entry_with_rationale(
			target_index, states, reason))
	var branch_successors = host._authored_relation_entries(definition,
		"branch_successor_ids", "branch_successor_rationales", states)
	var applications = host._authored_relation_entries(definition,
		"application_target_ids", "application_target_rationales", states)
	if not host._is_application_definition(definition):
		for target_index in range(host._research_definition_count, host._definitions.size()):
			var application: Dictionary = host._definitions[target_index]
			var required_ids: PackedStringArray = application.get(
				"required_technology_ids", PackedStringArray())
			if required_ids.has(selected_id):
				applications.append(host._relation_entry(target_index, states))
	return {
		"prerequisites": prerequisites,
		"hard_successors": hard_successors,
		"branch_successors": branch_successors,
		"applications": applications,
		"condition_items": host._condition_items(index, states),
	}


static func _authored_relation_entries(host, definition: Dictionary, ids_key: String,
		rationales_key: String, states: PackedInt32Array) -> Array:
	var out: Array = []
	var ids: PackedStringArray = definition.get(ids_key, PackedStringArray())
	var rationales: PackedStringArray = definition.get(rationales_key, PackedStringArray())
	for cursor in range(ids.size()):
		var target_index = int(host._technology_indices.get(String(ids[cursor]), -1))
		if target_index < 0 or host._is_retired(target_index):
			continue
		var rationale = String(rationales[cursor]) if cursor < rationales.size() else ""
		out.append(host._relation_entry_with_rationale(target_index, states, rationale))
	return out


static func _relation_entry_with_rationale(host, index: int, states: PackedInt32Array,
		rationale: String) -> Dictionary:
	var entry = host._relation_entry(index, states)
	if not rationale.is_empty() and int(entry.get("state", 0)) > 0:
		entry["name"] = "%s：%s" % [String(entry.name), rationale]
	return entry


static func _relation_entry(host, index: int, states: PackedInt32Array, prefix: String = "") -> Dictionary:
	var state = int(states[index]) if index < states.size() else 0
	if not TechnologyTreeView.presents_state(state):
		return {"name": "未知科技", "state": 0}
	var name = String((host._definitions[index] as Dictionary).get("display_name", ""))
	return {
		"name": ("%s · %s" % [prefix, name]) if not prefix.is_empty() else name,
		"state": state,
	}


static func _condition_items(host, index: int, states: PackedInt32Array) -> Array:
	if index < 0 or index >= host._definitions.size():
		return []
	var definition: Dictionary = host._definitions[index]
	if host._is_application_definition(definition):
		return host._application_condition_items(definition, states)
	var items: Array = []
	if host._is_retired(index):
		return items
	var evidence = host._signal_evidence()
	var reveal_spec: Dictionary = definition.get("reveal_condition", {})
	if not reveal_spec.is_empty():
		var reveal_result = host._evaluate_condition(reveal_spec, states, evidence)
		var reveal_met = bool(reveal_result.get("met", false))
		items.append({
			"text": "发现条件 · %s" % ("已满足" if reveal_met else "未满足"),
			"icon": &"technology.state.completed" if reveal_met else &"technology.state.locked",
			"accent": UITokens.GOOD if reveal_met else UITokens.WARN,
			"met": reveal_met,
		})
		for item_value in reveal_result.get("items", []) as Array:
			var item: Dictionary = item_value
			var inspiration = item.duplicate()
			inspiration["text"] = "发现：%s" % String(item.get("text", ""))
			items.append(inspiration)
	var hard_ids: PackedStringArray = definition.get("prerequisite_ids", PackedStringArray())
	for hard_id in hard_ids:
		var hard_index = int(host._technology_indices.get(String(hard_id), -1))
		if host._is_retired(hard_index):
			continue
		var hard_state = int(states[hard_index]) if hard_index >= 0 and hard_index < states.size() else 0
		var hard_name = "未知科技"
		if TechnologyTreeView.presents_state(hard_state) and hard_index >= 0:
			hard_name = String((host._definitions[hard_index] as Dictionary).get("display_name", hard_name))
		var hard_met = hard_state >= 5
		items.append({
			"text": "需要先完成：%s · %s" % [hard_name, "已完成" if hard_met else "未完成"],
			"icon": &"technology.state.completed" if hard_met else &"technology.state.locked",
			"accent": UITokens.GOOD if hard_met else UITokens.WARN,
			"met": hard_met,
		})
	var routes: Array = definition.get("research_routes", [])
	if not routes.is_empty():
		items.append({"text": "研究路线：完成以下任意一条路线", "icon": &"metric.technology"})
	for route_value in routes:
		var route: Dictionary = route_value
		var route_result = host._evaluate_condition(route.get("condition", {}) as Dictionary,
			states, evidence)
		var route_met = bool(route_result.get("met", false))
		var presented = TechnologyTreeView.presents_state(int(states[index]) if index < states.size() else 0)
		var route_name = String(route.get("display_name", "研究条件")) if presented \
			else "路线 %d" % (routes.find(route_value) + 1)
		var route_description = String(route.get("description", "")) if presented else ""
		var route_text = "研究条件 · %s" % route_name
		if not route_description.is_empty():
			route_text += "：%s" % route_description
		items.append({
			"text": "%s · %s" % [route_text, "已满足" if route_met else "未满足"],
			"icon": &"technology.state.completed" if route_met else &"technology.state.locked",
			"accent": UITokens.GOOD if route_met else UITokens.WARN,
			"met": route_met,
		})
		for route_item_value in route_result.get("items", []) as Array:
			var route_item: Dictionary = (route_item_value as Dictionary).duplicate()
			route_item["text"] = "条件 · %s：%s" % [route_name,
				String(route_item.get("text", ""))]
			items.append(route_item)
	return items


static func _signal_evidence(host) -> Dictionary:
	var snapshot: Dictionary = host._research.get("research_signal_snapshot", {})
	var dense_ids: PackedInt32Array = snapshot.get("signal_ids", PackedInt32Array())
	var counts: PackedInt32Array = snapshot.get("counts", PackedInt32Array())
	var first_days: PackedInt64Array = snapshot.get("first_days", PackedInt64Array())
	var first_cells: PackedInt32Array = snapshot.get("first_cells", PackedInt32Array())
	var evidence = {}
	for cursor in range(dense_ids.size()):
		evidence[int(dense_ids[cursor])] = {
			"count": int(counts[cursor]) if cursor < counts.size() else 0,
			"first_day": int(first_days[cursor]) if cursor < first_days.size() else -1,
			"first_cell": int(first_cells[cursor]) if cursor < first_cells.size() else -1,
		}
	var development_progress: Dictionary = host._development.get("progress_by_signal", {})
	for stable_id in development_progress:
		var signal_index = int(host._signal_indices.get(String(stable_id), -1))
		if signal_index < 0:
			continue
		var progress: Dictionary = development_progress[stable_id]
		evidence[signal_index] = {
			"count": 1 if int(progress.get("completed", 0)) > 0 else 0,
			"development": progress,
		}
	return evidence


static func _evaluate_condition(host, spec: Dictionary, states: PackedInt32Array,
		evidence: Dictionary) -> Dictionary:
	if spec.has("kind"):
		return host._evaluate_condition_atom(spec, states, evidence)
	var children: Array = spec.get("children", [])
	var operator = int(spec.get("operator", host.ResearchConditionScript.Operator.ATOM))
	if operator == host.ResearchConditionScript.Operator.ATOM:
		return host._evaluate_condition_atom(spec.get("atom", {}), states, evidence)
	var child_results: Array = []
	var met_count = 0
	var items: Array = []
	for child in children:
		var result = host._evaluate_condition(child as Dictionary, states, evidence)
		child_results.append(result)
		met_count += 1 if bool(result.get("met", false)) else 0
		items.append_array(result.get("items", []))
	var met = false
	match operator:
		host.ResearchConditionScript.Operator.ALL_OF:
			met = met_count == children.size()
		host.ResearchConditionScript.Operator.ANY_OF:
			met = met_count > 0
		host.ResearchConditionScript.Operator.AT_LEAST:
			met = met_count >= int(spec.get("required_count", 1))
		host.ResearchConditionScript.Operator.NOT:
			met = child_results.size() == 1 and not bool(
				(child_results[0] as Dictionary).get("met", false))
	var rule = ""
	match operator:
		host.ResearchConditionScript.Operator.ALL_OF: rule = "以下条件全部满足"
		host.ResearchConditionScript.Operator.ANY_OF: rule = "以下条件任意满足一项"
		host.ResearchConditionScript.Operator.AT_LEAST:
			rule = "以下条件至少满足 %d 项" % int(spec.get("required_count", 1))
		host.ResearchConditionScript.Operator.NOT: rule = "以下条件不成立"
	if not rule.is_empty():
		items.push_front({"text": "%s（%s）" % [rule, "已满足" if met else "未满足"],
			"met": met, "icon": &"technology.state.completed" if met else &"technology.state.locked",
			"accent": UITokens.GOOD if met else UITokens.WARN})
	return {"met": met, "items": items}


static func _evaluate_condition_atom(host, atom: Dictionary, states: PackedInt32Array,
		evidence: Dictionary) -> Dictionary:
	var kind = int(atom.get("kind", -1))
	var stable_id = String(atom.get("id", atom.get("reference_id", "")))
	var required = maxi(1, int(atom.get("value", 1)))
	if kind == host.ResearchPredicateScript.Kind.TECH_COMPLETED:
		var technology_index = int(host._technology_indices.get(stable_id, -1))
		var technology_state = int(states[technology_index]) \
			if technology_index >= 0 and technology_index < states.size() else 0
		var met = technology_state >= 5
		var technology_name = "未知科技"
		if TechnologyTreeView.presents_state(technology_state) \
				and technology_index < host._definitions.size():
			technology_name = String((host._definitions[technology_index] as Dictionary).get(
				"display_name", technology_name))
		return {
			"met": met,
			"items": [{
				"text": "前置科技：%s（%s）" % [
					technology_name, "已完成" if met else "未完成"],
				"icon": &"technology.state.completed" if met else &"technology.state.locked",
				"accent": UITokens.GOOD if met else UITokens.WARN,
				"source_kind": "technology",
				"met": met,
			}],
		}
	if kind not in [host.ResearchPredicateScript.Kind.SIGNAL_PRESENT,
			host.ResearchPredicateScript.Kind.SIGNAL_COUNT]:
		return {"met": false, "items": []}
	var signal_index = int(host._signal_indices.get(stable_id, -1))
	var row: Dictionary = evidence.get(signal_index, {})
	if stable_id.begins_with("development."):
		var development: Dictionary = row.get("development", {})
		var definition = host._development_definition(stable_id)
		var qualifier = int(development.get("qualifier_threshold",
			definition.get("qualifier_threshold", required)))
		var current = int(development.get("current_value", 0))
		var target_days = maxi(1, int(development.get("target_days",
			definition.get("duration_days", 1))))
		var consecutive = int(development.get("consecutive_days", 0))
		var met = int(row.get("count", 0)) > 0 or int(development.get("completed", 0)) > 0 \
			or (current >= qualifier and consecutive >= target_days)
		var name = String(host._signal_names.get(stable_id, stable_id))
		return {
			"met": met,
			"items": [{
				"text": "%s：%s" % [name, "已达成" if met else host._development_value_text(
					definition, current, qualifier, consecutive, target_days)],
				"icon": &"technology.state.completed" if met else &"technology.state.locked",
				"accent": UITokens.GOOD if met else UITokens.WARN,
				"source_kind": "signal",
				"met": met,
			}],
		}
	var count = int(row.get("count", 0))
	var target = required if kind == host.ResearchPredicateScript.Kind.SIGNAL_COUNT else 1
	var met = count >= target
	var name = String(host._signal_names.get(stable_id, stable_id))
	var source = ""
	if count > 0:
		source = "，首次记录：第 %d 日 / 地块 %d" % [
			int(row.get("first_day", -1)), int(row.get("first_cell", -1))]
	return {
		"met": met,
		"items": [{
			"text": "%s：%s %d/%d%s" % [
				"证据" if met else "阻塞", name, count, target, source],
			"icon": &"technology.state.completed" if met else &"technology.state.locked",
			"accent": UITokens.GOOD if met else UITokens.WARN,
			"source_kind": "signal",
			"met": met,
		}],
	}


static func _development_definition(host, signal_id: String) -> Dictionary:
	for definition in host.DevelopmentAchievementCatalogScript.definitions():
		if String((definition as Dictionary).get("signal_id", "")) == signal_id:
			return definition as Dictionary
	return {}


static func _application_state(host, definition: Dictionary,
		research_states: PackedInt32Array) -> int:
	if not host._is_application_definition(definition):
		return 0
	var required: PackedStringArray = definition.get(
		"required_technology_ids", definition.get(
			"application_foundation_ids", PackedStringArray()))
	if required.is_empty():
		return 0
	var all_completed = true
	for technology_id in required:
		var index = int(host._technology_indices.get(String(technology_id), -1))
		var state = int(research_states[index]) \
			if index >= 0 and index < research_states.size() else 0
		if not TechnologyTreeView.presents_state(state):
			return 0
		if state < 5:
			all_completed = false
	return 5 if all_completed else 2


static func _application_condition_items(host, definition: Dictionary,
		states: PackedInt32Array) -> Array:
	var items: Array = []
	var required: PackedStringArray = definition.get(
		"required_technology_ids", definition.get(
			"application_foundation_ids", PackedStringArray()))
	var primary_id = String(definition.get("primary_technology_id",
		String(required[0]) if not required.is_empty() else ""))
	for technology_id_value in required:
		var technology_id = String(technology_id_value)
		var index = int(host._technology_indices.get(technology_id, -1))
		var state = int(states[index]) if index >= 0 and index < states.size() else 0
		var met = state >= 5
		var name = "未知科技"
		if index >= 0 and TechnologyTreeView.presents_state(state):
			name = String((host._definitions[index] as Dictionary).get(
				"display_name", technology_id))
		items.append({
			"text": "%s：%s · %s" % [
				"主科技" if technology_id == primary_id else "支撑科技",
				name, "已完成" if met else "未完成"],
			"icon": &"technology.state.completed" if met else &"technology.state.locked",
			"accent": UITokens.GOOD if met else UITokens.WARN,
			"met": met,
		})
	host._append_application_constraints(items, definition,
		"required_input_good_ids", "投入商品", "投产时核验")
	host._append_application_constraints(items, definition,
		"required_resource_ids", "自然资源", "建设地点核验")
	host._append_application_constraints(items, definition,
		"required_tile_condition_ids", "地块条件", "建设地点核验")
	host._append_application_constraints(items, definition,
		"required_terrain_ids", "地块条件", "建设地点核验")
	host._append_application_constraints(items, definition,
		"required_landform_ids", "地块条件", "建设地点核验")
	return items


static func _append_application_constraints(host, items: Array, definition: Dictionary,
		field: String, category: String, verification: String) -> void:
	for value in definition.get(field, []):
		var label = ""
		if value is Dictionary:
			label = String((value as Dictionary).get("display_name",
				(value as Dictionary).get("id", "")))
		else:
			label = str(value)
		if label.is_empty():
			continue
		items.append({
			"text": "%s：%s · %s" % [category, label, verification],
			"icon": &"technology.state.locked",
			"accent": UITokens.WARN,
			"met": false,
		})


static func _is_application_definition(host, definition: Dictionary) -> bool:
	return bool(definition.get("is_application", false)) \
		or String(definition.get("anchor_kind", "")) == "application" \
		or String(definition.get("id", "")).begins_with("app.")
