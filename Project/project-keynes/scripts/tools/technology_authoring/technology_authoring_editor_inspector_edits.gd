extends RefCounted

## Applies technology field and relationship edits requested by the inspector.

static func technology_row(editor: TechnologyAuthoringEditor, id: String) -> Dictionary:
	return editor._service.model.node(id)


static func technology_display_name(editor: TechnologyAuthoringEditor, id: String) -> String:
	var row := editor._service.model.node(id)
	return String(row.get("display_name", id)) if not row.is_empty() else "（不存在）%s" % id


static func enum_source(editor: TechnologyAuthoringEditor, source: String) -> PackedStringArray:
	var out := PackedStringArray()
	match source:
		"eras":
			for row in editor._service.model.meta_array("eras"):
				out.append(String((row as Dictionary).get("id", "")))
		"domains":
			for row in editor._service.model.meta_array("domains"):
				out.append(String((row as Dictionary).get("id", "")))
		"families":
			for row in editor._service.model.meta_array("backbones"):
				out.append(String((row as Dictionary).get("id", "")))
			for row in editor._service.model.meta_array("branch_families"):
				out.append(String((row as Dictionary).get("id", "")))
		"reveal_categories":
			for value in TechnologyAuthoringEditor.ValidatorScript.ALLOWED_REVEAL_CATEGORIES:
				out.append(String(value))
		"technologies_optional":
			out.append("")
			out.append_array(editor._service.model.ids())
	return out


## Distinct authored values for a free-text field, used by the "…" pickers so
## authors stay consistent without inventing a schema enum.


static func distinct_values(editor: TechnologyAuthoringEditor, key: String) -> PackedStringArray:
	var seen := {}
	for node_value in editor._service.model.nodes():
		var value := String((node_value as Dictionary).get(key, ""))
		if value.is_empty():
			continue
		seen[value] = true
	var out := PackedStringArray()
	for value in seen:
		out.append(String(value))
	out.sort()
	return out


static func distinct_term_values(editor: TechnologyAuthoringEditor, key: String) -> PackedStringArray:
	var seen := {}
	for node_value in editor._service.model.nodes():
		for term_value in (node_value as Dictionary).get("modifier_terms", []):
			var value := String((term_value as Dictionary).get(key, ""))
			if value.is_empty():
				continue
			seen[value] = true
	var out := PackedStringArray()
	for value in seen:
		out.append(String(value))
	out.sort()
	return out


static func commit_field(editor: TechnologyAuthoringEditor, id: String, key: String, value: Variant) -> void:
	editor._service.model.begin_batch("编辑 %s" % key)
	editor._service.model.set_field(id, key, value)
	editor._service.model.commit_batch()


static func relation_entries(editor: TechnologyAuthoringEditor, id: String, field: String) -> Array:
	return editor._service.model.relation(id, field)


static func commit_relation_rationale(editor: TechnologyAuthoringEditor, id: String, field: String, slot: int,
		text: String) -> void:
	var entries := editor._service.model.relation(id, field)
	if slot < 0 or slot >= entries.size():
		return
	(entries[slot] as Dictionary)["rationale"] = text
	editor._service.model.begin_batch("编辑 %s 理由" % field)
	editor._service.model.set_relation(id, field, entries)
	editor._service.model.commit_batch()


static func remove_relation_entry(editor: TechnologyAuthoringEditor, id: String, field: String, target_id: String) -> void:
	editor._service.model.begin_batch("移除 %s" % field)
	editor._service.model.remove_relation_entry(id, field, target_id)
	editor._service.model.commit_batch()
	editor._refresh_inspector()


## Relations always ask for the rationale, because the gate rejects any entry
## without one and the arrays must stay equally long.


static func prompt_relation_entry(editor: TechnologyAuthoringEditor, id: String, field: String, label: String) -> void:
	editor.open_technology_picker("选择%s" % label, func(picked: String) -> void:
		editor._open_text_input("添加%s" % label, "目标科技", picked, "理由（必填）", "",
			"两个输入都会写入配对数组，缺理由会被闸门拒绝。",
			"relation", {"id": id, "field": field}))


static func _apply_relation_entry(editor: TechnologyAuthoringEditor, payload: Dictionary, target_id: String,
		rationale: String) -> void:
	var id := String(payload.id)
	var field := String(payload.field)
	if not editor._service.model.has_technology(target_id):
		editor._show_message("未知科技", "科技 %s 不存在。" % target_id)
		return
	editor._service.model.begin_batch("添加 %s" % field)
	editor._service.model.add_relation_entry(id, field, target_id, rationale)
	editor._service.model.commit_batch()
	editor._refresh_inspector()


static func open_value_picker(editor: TechnologyAuthoringEditor, title: String, key: String, callback: Callable) -> void:
	editor._open_picker(title, editor.distinct_values(key), PackedStringArray(), callback)


static func open_term_value_picker(editor: TechnologyAuthoringEditor, key: String, callback: Callable) -> void:
	editor._open_picker("已有取值：%s" % key, editor.distinct_term_values(key),
		PackedStringArray(), callback)


static func open_stat_picker(editor: TechnologyAuthoringEditor, callback: Callable) -> void:
	var options := editor._service.index.modifier_stat_keys
	if options.is_empty():
		editor._show_message("Modifier 目录不可用",
			"无法编译 Modifier 目录（%s），stat 选择器为空。" % editor._service.index.stat_registry_reason)
		return
	editor._open_picker("选择 Modifier stat（%d 个合法键）" % options.size(), options,
		PackedStringArray(), callback)


static func open_technology_picker(editor: TechnologyAuthoringEditor, title: String, callback: Callable) -> void:
	var ids := editor._service.model.ids()
	var labels := PackedStringArray()
	for id in ids:
		labels.append("%s  —  %s" % [String(id), editor.technology_display_name(String(id))])
	editor._open_picker(title, ids, labels, callback)


static func stat_hint(editor: TechnologyAuthoringEditor, stat: String) -> String:
	if stat.is_empty():
		return "尚未选择 stat"
	var meta: Dictionary = editor._service.index.modifier_stats.get(stat, {})
	if meta.is_empty():
		return "%s 不在 Modifier 目录中，编译经济目录时会失败。" % stat
	return "%s\n取值范围 %.3f – %.3f" % [stat, float(meta.min), float(meta.max)]


static func term_subject_label(editor: TechnologyAuthoringEditor, term: Dictionary) -> String:
	var subject := String(term.get("subject_display_name", ""))
	if not subject.is_empty():
		return subject
	var stat := String(term.get("stat", ""))
	return String(TechnologyAuthoringEditor.ValidatorScript.MODIFIER_SUBJECT_NAMES.get(stat, stat))


static func commit_term_field(editor: TechnologyAuthoringEditor, id: String, slot: int, key: String, value: Variant) -> void:
	var row := editor._service.model.node(id)
	var terms: Array = (row.get("modifier_terms", []) as Array).duplicate(true)
	if slot < 0 or slot >= terms.size():
		return
	(terms[slot] as Dictionary)[key] = value
	editor._service.model.begin_batch("编辑效果 %s" % key)
	editor._service.model.set_field(id, "modifier_terms", terms)
	editor._service.model.commit_batch()
	if key == "stat" or key == "implementation_status":
		editor._refresh_inspector()


static func add_term(editor: TechnologyAuthoringEditor, id: String) -> void:
	var row := editor._service.model.node(id)
	var terms: Array = (row.get("modifier_terms", []) as Array).duplicate(true)
	terms.append({
		"stat": "",
		"operation": 0.0,
		"value": 0.05,
		"subject_kind": "country",
		"subject_id": "",
		"subject_display_name": "",
		"effect_class": "",
		"effect_rationale": "",
		"implementation_status": "runtime_consumed",
		"runtime_consumer": "",
	})
	editor._service.model.begin_batch("添加效果项")
	editor._service.model.set_field(id, "modifier_terms", terms)
	editor._service.model.commit_batch()
	editor._refresh_inspector()


static func remove_term(editor: TechnologyAuthoringEditor, id: String, slot: int) -> void:
	editor.remove_array_entry(id, "modifier_terms", slot)


static func remove_array_entry(editor: TechnologyAuthoringEditor, id: String, key: String, slot: int) -> void:
	var row := editor._service.model.node(id)
	var values: Array = (row.get(key, []) as Array).duplicate(true)
	if slot < 0 or slot >= values.size():
		return
	values.remove_at(slot)
	editor._service.model.begin_batch("移除 %s 条目" % key)
	editor._service.model.set_field(id, key, values)
	editor._service.model.commit_batch()
	editor._refresh_inspector()


static func content_exists(editor: TechnologyAuthoringEditor, kind: String, id: String) -> bool:
	return editor._service.index.has_entry(kind, id)


static func unlock_reconciliation(editor: TechnologyAuthoringEditor, id: String) -> Dictionary:
	return editor._service.reconcile_unlocks(id)


static func sync_unlock_to_tres(editor: TechnologyAuthoringEditor, id: String, kind: String, content_id: String) -> void:
	var result := editor._service.set_content_technology(kind, content_id, id, true)
	if not bool(result.ok):
		editor._show_message("写入 .tres 失败", String(result.reason))
		return
	editor._status.text = "已把 %s 写入 %s" % [id, String(result.path)]
	editor._refresh_inspector()


static func adopt_unlock_from_tres(editor: TechnologyAuthoringEditor, id: String, kind: String, content_id: String,
		display_name: String) -> void:
	var row := editor._service.model.node(id)
	var effects: Array = (row.get("content_effects", []) as Array).duplicate(true)
	effects.append({
		"kind": kind,
		"id": content_id,
		"display_name": display_name,
		"operation": "unlock",
	})
	editor._service.model.begin_batch("补入解锁效果")
	editor._service.model.set_field(id, "content_effects", effects)
	editor._service.model.commit_batch()
	editor._refresh_inspector()


static func prompt_content_effect(editor: TechnologyAuthoringEditor, id: String) -> void:
	editor._open_picker("选择解锁内容类型", PackedStringArray(["building", "good", "resource"]),
		PackedStringArray(["建筑", "物资", "自然资源"]),
		func(kind: String) -> void: editor._prompt_content_id(id, kind))


static func _prompt_content_id(editor: TechnologyAuthoringEditor, id: String, kind: String) -> void:
	var options := editor._service.index.options(kind)
	var ids := PackedStringArray()
	var labels := PackedStringArray()
	for option_value in options:
		var option: Dictionary = option_value
		ids.append(String(option.id))
		labels.append("%s  —  %s" % [String(option.id), String(option.display_name)])
	editor._open_picker("选择%s" % kind, ids, labels, func(picked: String) -> void:
		editor.adopt_unlock_from_tres(id, kind, picked,
			editor._service.index.display_name(kind, picked)))


## expected_bindings is the audited mirror of content_effects, so it is derived
## rather than typed twice.


static func sync_expected_bindings(editor: TechnologyAuthoringEditor, id: String) -> void:
	var row := editor._service.model.node(id)
	var bindings: Array = []
	var seen := {}
	for effect_value in row.get("content_effects", []):
		var effect: Dictionary = effect_value
		if String(effect.get("operation", "")) != "unlock":
			continue
		var kind := int(TechnologyAuthoringEditor.BINDING_KIND_BY_CONTENT.get(String(effect.get("kind", "")), 0))
		var content_id := String(effect.get("id", ""))
		if kind <= 0 or content_id.is_empty():
			continue
		var key := "%d|%s" % [kind, content_id]
		if seen.has(key):
			continue
		seen[key] = true
		bindings.append({"kind": kind, "id": content_id})
	editor._service.model.begin_batch("同步预期绑定")
	editor._service.model.set_field(id, "expected_bindings", bindings)
	editor._service.model.commit_batch()
	editor._refresh_inspector()


static func prompt_support_building(editor: TechnologyAuthoringEditor, id: String) -> void:
	var options := editor._service.index.options("building")
	var ids := PackedStringArray()
	var labels := PackedStringArray()
	for option_value in options:
		var option: Dictionary = option_value
		ids.append(String(option.id))
		labels.append("%s  —  %s" % [String(option.id), String(option.display_name)])
	editor._open_picker("选择支撑建筑", ids, labels, func(picked: String) -> void:
		var row := editor._service.model.node(id)
		var rows: Array = (row.get("support_buildings", []) as Array).duplicate(true)
		rows.append({"id": picked,
			"name": editor._service.index.display_name("building", picked)})
		editor._service.model.begin_batch("添加支撑建筑")
		editor._service.model.set_field(id, "support_buildings", rows)
		editor._service.model.commit_batch()
		editor._refresh_inspector())


static func commit_route_field(editor: TechnologyAuthoringEditor, id: String, slot: int, key: String, value: Variant) -> void:
	var row := editor._service.model.node(id)
	var routes: Array = (row.get("research_routes", []) as Array).duplicate(true)
	if slot < 0 or slot >= routes.size():
		return
	(routes[slot] as Dictionary)[key] = value
	editor._service.model.begin_batch("编辑研究路线 %s" % key)
	editor._service.model.set_field(id, "research_routes", routes)
	editor._service.model.commit_batch()


static func add_route(editor: TechnologyAuthoringEditor, id: String) -> void:
	var row := editor._service.model.node(id)
	var routes: Array = (row.get("research_routes", []) as Array).duplicate(true)
	routes.append({
		"id": "research_route.%s.route_%d" % [id.trim_prefix("tech."), routes.size() + 1],
		"display_name": "",
		"route_type": "",
		"description": "",
		"condition": {},
	})
	editor._service.model.begin_batch("添加研究路线")
	editor._service.model.set_field(id, "research_routes", routes)
	editor._service.model.commit_batch()
	editor._refresh_inspector()


## Route evidence must be defined earlier in the node array, so the picker only
## offers technologies that already satisfy that ordering rule.


static func prompt_route_condition(editor: TechnologyAuthoringEditor, id: String, slot: int) -> void:
	var position := editor._service.model.node_position(id)
	var ids := PackedStringArray()
	var labels := PackedStringArray()
	var hard: Array = editor._service.model.node(id).get("hard_prerequisite_ids", [])
	for candidate in editor._service.model.ids():
		var candidate_id := String(candidate)
		if editor._service.model.node_position(candidate_id) >= position:
			continue
		if hard.has(candidate_id):
			continue
		ids.append(candidate_id)
		labels.append("%s  —  %s" % [candidate_id, editor.technology_display_name(candidate_id)])
	editor._open_picker("选择路线证据科技（须先于本节点且不与硬前置重复）", ids, labels,
		func(picked: String) -> void:
			editor.commit_route_field(id, slot, "condition",
				{"operator": 0.0, "kind": 0.0, "id": picked, "value": 1.0})
			editor._refresh_inspector())


static func rebuild_knowledge_basis(editor: TechnologyAuthoringEditor, id: String) -> void:
	var row := editor._service.model.node(id)
	var required: Array = (row.get("hard_prerequisite_ids", []) as Array).duplicate()
	var groups: Array = []
	for route_value in row.get("research_routes", []):
		var atoms := PackedStringArray()
		TechnologyAuthoringEditor.ValidatorScript.collect_technology_atoms(
			(route_value as Dictionary).get("condition", {}), atoms)
		if atoms.is_empty():
			continue
		groups.append(Array(atoms))
	var basis: Dictionary = (row.get("knowledge_basis", {}) as Dictionary).duplicate(true)
	basis["required_ids"] = required
	basis["alternative_groups"] = groups
	editor._service.model.begin_batch("重建知识基础")
	editor._service.model.set_field(id, "knowledge_basis", basis)
	editor._service.model.commit_batch()
	editor._refresh_inspector()


static func commit_basis_exemption(editor: TechnologyAuthoringEditor, id: String, text: String) -> void:
	var row := editor._service.model.node(id)
	var basis: Dictionary = (row.get("knowledge_basis", {}) as Dictionary).duplicate(true)
	basis["exemption_reason"] = text
	editor.commit_field(id, "knowledge_basis", basis)


static func commit_review_field(editor: TechnologyAuthoringEditor, id: String, key: String, sub_key: String,
		value: Variant) -> void:
	var row := editor._service.model.node(id)
	var review: Dictionary = (row.get(key, {}) as Dictionary).duplicate(true)
	review[sub_key] = value
	editor.commit_field(id, key, review)


# --------------------------------------------------------------------------
# Canvas interactions
# --------------------------------------------------------------------------
