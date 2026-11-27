extends RefCounted

## Compiles technologies' authored conditions and modifier terms for native readers.

const ResearchConditionScript = preload("res://scripts/research/research_condition.gd")
const ResearchPredicateScript = preload("res://scripts/research/research_predicate.gd")

const CONDITION_PUSH_TECH_COMPLETED := 1
const CONDITION_PUSH_SIGNAL_PRESENT := 2
const CONDITION_PUSH_SIGNAL_COUNT := 3
const CONDITION_ALL_OF := 10
const CONDITION_ANY_OF := 11
const CONDITION_AT_LEAST := 12
const CONDITION_NOT := 13


static func _compile_explicit_modifier_term_ir(nodes: Array) -> Dictionary:
	var offsets := PackedInt32Array([0])
	var stat_keys := PackedStringArray()
	var operations := PackedInt32Array()
	var values := PackedFloat64Array()
	for node_value in nodes:
		var node: Dictionary = node_value
		var terms: Array = node.get("modifier_terms", [])
		for term_value in terms:
			var term: Dictionary = term_value
			var stat_key := String(term.get("stat", "")).strip_edges()
			var operation := int(term.get("operation", -1))
			var value := float(term.get("value", NAN))
			if stat_key.is_empty() or operation < 0 or operation > 3 or not is_finite(value):
				return {"ok": false, "reason": "technology_modifier_term_invalid",
					"id": String(node.get("id", ""))}
			stat_keys.append(stat_key)
			operations.append(operation)
			values.append(value)
		offsets.append(stat_keys.size())
	return {
		"ok": true,
		"technology_modifier_term_offsets": offsets,
		"technology_modifier_term_stat_keys": stat_keys,
		"technology_modifier_term_operations": operations,
		"technology_modifier_term_values": values,
	}


static func _compile_research_conditions(nodes: Array, technology_ids: PackedStringArray,
		signal_ids: PackedStringArray, era_index: Dictionary,
		prerequisite_offsets: PackedInt32Array, prerequisites: PackedInt32Array,
		milestone_offsets: PackedInt32Array, milestone_candidates: PackedInt32Array,
		milestone_required: PackedInt32Array,
		technology_entry_milestones: PackedInt32Array) -> Dictionary:
	var technology_route_offsets := PackedInt32Array([0])
	var route_ids := PackedStringArray()
	var route_names := PackedStringArray()
	var route_types := PackedStringArray()
	var route_descriptions := PackedStringArray()
	var route_condition_offsets := PackedInt32Array([0])
	var route_ops := PackedInt32Array()
	var route_refs := PackedInt32Array()
	var route_values := PackedInt64Array()
	var total_offsets := PackedInt32Array([0])
	var total_ops := PackedInt32Array()
	var total_refs := PackedInt32Array()
	var total_values := PackedInt64Array()
	var signal_index := {}
	var technology_index := {}
	var seen_route_ids := {}
	for i in range(signal_ids.size()):
		signal_index[String(signal_ids[i])] = i
	for i in range(technology_ids.size()):
		technology_index[String(technology_ids[i])] = i
	for technology in range(nodes.size()):
		var node: Dictionary = nodes[technology]
		var technology_id := String(node.get("id", ""))
		var routes: Array = node.get("research_routes", [])
		var era := int(era_index.get(String(node.get("era_id", "")), -1))
		if era >= 2 and routes.is_empty() and String(
				node.get("route_exemption_reason", "")).strip_edges().is_empty():
			return {"ok": false, "reason": "technology_route_exemption_reason_missing",
				"technology_id": technology_id}
		var ordinary_node := not bool(node.get("is_milestone", false))
		var route_type_seen := {}
		for route_value in routes:
			if not route_value is Dictionary:
				return {"ok": false, "reason": "technology_research_route_invalid",
					"technology_id": technology_id}
			var route: Dictionary = route_value
			var route_id := String(route.get("id", "")).strip_edges()
			var route_name := String(route.get("display_name", "")).strip_edges()
			var route_type := String(route.get("route_type", "")).strip_edges()
			var route_description := String(route.get("description", "")).strip_edges()
			var condition: Dictionary = route.get("condition", {})
			if not route_id.begins_with("research_route.") or seen_route_ids.has(route_id) \
					or route_name.is_empty() or route_type.is_empty() \
					or route_description.is_empty() or condition.is_empty():
				return {"ok": false, "reason": "technology_research_route_invalid",
					"technology_id": technology_id, "route_id": route_id}
			seen_route_ids[route_id] = true
			route_type_seen[route_type] = true
			var route_begin := route_ops.size()
			var error := _append_condition_postfix(condition, signal_index, technology_index,
				route_ops, route_refs, route_values)
			if not error.is_empty():
				return {"ok": false, "reason": error, "technology_id": technology_id,
					"route_id": route_id}
			for cursor in range(route_begin, route_ops.size()):
				if route_ops[cursor] != CONDITION_PUSH_TECH_COMPLETED:
					continue
				var referenced_technology := int(route_refs[cursor])
				if referenced_technology == technology:
					return {"ok": false,
						"reason": "technology_research_route_self_reference",
						"technology_id": technology_id, "route_id": route_id}
				var referenced_node: Dictionary = nodes[referenced_technology]
				var referenced_era := int(era_index.get(String(
					referenced_node.get("era_id", "")), -1))
				if referenced_era > era:
					return {"ok": false,
						"reason": "technology_research_route_reference_later_era",
						"technology_id": technology_id, "route_id": route_id}
				# Era milestones are internal era tokens (era-advancement-runtime
				# section 0); an ordinary node must never be gated on one.
				if ordinary_node and bool(referenced_node.get("is_milestone", false)):
					return {"ok": false,
						"reason": "technology_research_route_references_milestone",
						"technology_id": technology_id, "route_id": route_id}
			route_condition_offsets.append(route_ops.size())
			route_ids.append(route_id)
			route_names.append(route_name)
			route_types.append(route_type)
			route_descriptions.append(route_description)
			error = _append_condition_postfix(condition, signal_index, technology_index,
				total_ops, total_refs, total_values)
			if not error.is_empty():
				return {"ok": false, "reason": error, "technology_id": technology_id,
					"route_id": route_id}
		if routes.size() > 1:
			total_ops.append(CONDITION_ANY_OF)
			total_refs.append(routes.size())
			total_values.append(0)
		if routes.size() > 1 and route_type_seen.size() < 2:
			return {"ok": false, "reason": "technology_research_route_types_not_distinct",
				"technology_id": technology_id}
		# The executable research condition is one AND tree. Route packages are
		# only one child of that tree; hard prerequisites, milestone-candidate
		# thresholds, and (for milestone nodes only) the previous-era entry
		# milestone are compiled into the same postfix IR.
		var route_child_count := routes.size() if not routes.is_empty() else 0
		var hard_begin := int(prerequisite_offsets[technology])
		var hard_end := int(prerequisite_offsets[technology + 1])
		var milestone_begin := int(milestone_offsets[technology])
		var milestone_end := int(milestone_offsets[technology + 1])
		var child_count := 0
		for edge in range(hard_begin, hard_end):
			if ordinary_node and bool((nodes[int(prerequisites[edge])] as Dictionary).get(
					"is_milestone", false)):
				return {"ok": false,
					"reason": "technology_prerequisite_references_milestone",
					"technology_id": technology_id}
			total_ops.append(CONDITION_PUSH_TECH_COMPLETED)
			total_refs.append(int(prerequisites[edge]))
			total_values.append(1)
			child_count += 1
		if milestone_end > milestone_begin:
			for edge in range(milestone_begin, milestone_end):
				total_ops.append(CONDITION_PUSH_TECH_COMPLETED)
				total_refs.append(int(milestone_candidates[edge]))
				total_values.append(1)
			total_ops.append(CONDITION_AT_LEAST)
			total_refs.append(milestone_end - milestone_begin)
			total_values.append(int(milestone_required[technology]))
			child_count += 1
		var entry_milestone := int(technology_entry_milestones[technology]) \
				if technology < technology_entry_milestones.size() else -1
		if entry_milestone >= 0:
			total_ops.append(CONDITION_PUSH_TECH_COMPLETED)
			total_refs.append(entry_milestone)
			total_values.append(1)
			child_count += 1
		if route_child_count > 0:
			child_count += 1
		if child_count > 1:
			total_ops.append(CONDITION_ALL_OF)
			total_refs.append(child_count)
			total_values.append(0)
		elif child_count == 0:
			# Empty condition means an unconditional starter node.
			pass
		technology_route_offsets.append(route_ids.size())
		total_offsets.append(total_ops.size())
	return {
		"ok": true,
		"technology_research_route_offsets": technology_route_offsets,
		"research_route_ids": route_ids,
		"research_route_display_names": route_names,
		"research_route_types": route_types,
		"research_route_descriptions": route_descriptions,
		"research_route_condition_offsets": route_condition_offsets,
		"research_route_condition_ops": route_ops,
		"research_route_condition_refs": route_refs,
		"research_route_condition_values": route_values,
		"technology_research_condition_offsets": total_offsets,
		"technology_research_condition_ops": total_ops,
		"technology_research_condition_refs": total_refs,
		"technology_research_condition_values": total_values,
	}

static func _compile_condition_specs(
		technology_ids: PackedStringArray, signal_ids: PackedStringArray,
		specs: Dictionary, prefix: String) -> Dictionary:
	var offsets := PackedInt32Array([0])
	var ops := PackedInt32Array()
	var refs := PackedInt32Array()
	var values := PackedInt64Array()
	var signal_index := {}
	var technology_index := {}
	for i in range(signal_ids.size()):
		signal_index[String(signal_ids[i])] = i
	for i in range(technology_ids.size()):
		technology_index[String(technology_ids[i])] = i
	for technology_id in technology_ids:
		var spec = specs.get(String(technology_id), null)
		if spec != null:
			var error := _append_condition_postfix(spec, signal_index, technology_index,
				ops, refs, values)
			if error != "":
				return {"ok": false, "reason": error, "technology_id": String(technology_id)}
		offsets.append(ops.size())
	return {
		"ok": true,
		"%s_offsets" % prefix: offsets,
		"%s_ops" % prefix: ops,
		"%s_refs" % prefix: refs,
		"%s_values" % prefix: values,
	}

static func _compile_reveal_reverse_index(
		technology_count: int, signal_count: int, conditions: Dictionary) -> Dictionary:
	var buckets: Array[PackedInt32Array] = []
	for _signal in range(signal_count):
		buckets.append(PackedInt32Array())
	var offsets: PackedInt32Array = conditions.get(
		"technology_reveal_condition_offsets", PackedInt32Array())
	var ops: PackedInt32Array = conditions.get(
		"technology_reveal_condition_ops", PackedInt32Array())
	var refs: PackedInt32Array = conditions.get(
		"technology_reveal_condition_refs", PackedInt32Array())
	for technology in range(technology_count):
		if technology + 1 >= offsets.size():
			continue
		for cursor in range(offsets[technology], offsets[technology + 1]):
			if cursor < 0 or cursor >= ops.size() or cursor >= refs.size():
				continue
			if ops[cursor] != CONDITION_PUSH_SIGNAL_PRESENT and \
					ops[cursor] != CONDITION_PUSH_SIGNAL_COUNT:
				continue
			var signal_index_value := int(refs[cursor])
			if signal_index_value < 0 or signal_index_value >= buckets.size():
				continue
			if not buckets[signal_index_value].has(technology):
				buckets[signal_index_value].append(technology)
	var reverse_offsets := PackedInt32Array([0])
	var reverse_technologies := PackedInt32Array()
	for bucket in buckets:
		var ordered := Array(bucket)
		ordered.sort()
		for technology in ordered:
			reverse_technologies.append(int(technology))
		reverse_offsets.append(reverse_technologies.size())
	return {
		"technology_reveal_signal_offsets": reverse_offsets,
		"technology_reveal_signal_technologies": reverse_technologies,
	}

static func _append_condition_postfix(spec, signal_index: Dictionary, technology_index: Dictionary,
		ops: PackedInt32Array, refs: PackedInt32Array, values: PackedInt64Array) -> String:
	if spec is ResearchPredicateScript:
		return _append_predicate(spec, signal_index, technology_index, ops, refs, values)
	if spec is Dictionary and spec.has("kind"):
		return _append_predicate_dict(spec, signal_index, technology_index, ops, refs, values)
	var operator_value := -1
	var children: Array = []
	var required_count := 0
	if spec is ResearchConditionScript:
		operator_value = int(spec.operator)
		children = spec.children
		required_count = int(spec.required_count)
	elif spec is Dictionary:
		operator_value = int(spec.get("operator", -1))
		children = spec.get("children", [])
		required_count = int(spec.get("required_count", 0))
	else:
		return "technology_condition_invalid_node"
	if operator_value == ResearchConditionScript.Operator.ATOM:
		if spec is ResearchConditionScript:
			return _append_condition_postfix(spec.atom, signal_index, technology_index, ops, refs, values)
		return _append_condition_postfix((spec as Dictionary).get("atom", null), signal_index, technology_index, ops, refs, values)
	if children.is_empty():
		return "technology_condition_empty_composite"
	for child in children:
		var error := _append_condition_postfix(child, signal_index, technology_index, ops, refs, values)
		if error != "":
			return error
	match operator_value:
		ResearchConditionScript.Operator.ALL_OF:
			ops.append(CONDITION_ALL_OF); refs.append(children.size()); values.append(0)
		ResearchConditionScript.Operator.ANY_OF:
			ops.append(CONDITION_ANY_OF); refs.append(children.size()); values.append(0)
		ResearchConditionScript.Operator.AT_LEAST:
			if required_count <= 0 or required_count > children.size():
				return "technology_condition_at_least_invalid"
			ops.append(CONDITION_AT_LEAST); refs.append(children.size()); values.append(required_count)
		ResearchConditionScript.Operator.NOT:
			if children.size() != 1:
				return "technology_condition_not_arity_invalid"
			ops.append(CONDITION_NOT); refs.append(1); values.append(0)
		_:
			return "technology_condition_operator_unsupported"
	return ""

static func _append_predicate(predicate: Resource, signal_index: Dictionary,
		technology_index: Dictionary, ops: PackedInt32Array, refs: PackedInt32Array,
		values: PackedInt64Array) -> String:
	return _append_predicate_dict({
		"kind": int(predicate.kind), "id": String(predicate.reference_id),
		"value": int(predicate.value), "comparator": int(predicate.comparator),
	}, signal_index, technology_index, ops, refs, values)

static func _append_predicate_dict(predicate: Dictionary, signal_index: Dictionary,
		technology_index: Dictionary, ops: PackedInt32Array, refs: PackedInt32Array,
		values: PackedInt64Array) -> String:
	var kind := int(predicate.get("kind", -1))
	var id := String(predicate.get("id", predicate.get("reference_id", "")))
	var value := int(predicate.get("value", 1))
	if kind == ResearchPredicateScript.Kind.TECH_COMPLETED:
		if not technology_index.has(id):
			return "technology_condition_technology_reference_unknown"
		ops.append(CONDITION_PUSH_TECH_COMPLETED); refs.append(int(technology_index[id])); values.append(1)
		return ""
	if kind == ResearchPredicateScript.Kind.SIGNAL_PRESENT:
		if not signal_index.has(id):
			return "technology_condition_signal_reference_unknown"
		ops.append(CONDITION_PUSH_SIGNAL_PRESENT); refs.append(int(signal_index[id])); values.append(1)
		return ""
	if kind == ResearchPredicateScript.Kind.SIGNAL_COUNT:
		if not signal_index.has(id) or value <= 0:
			return "technology_condition_signal_count_invalid"
		ops.append(CONDITION_PUSH_SIGNAL_COUNT); refs.append(int(signal_index[id])); values.append(value)
		return ""
	return "technology_condition_predicate_unsupported"
