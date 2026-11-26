extends RefCounted

## Indexes, renames and removes references to a technology.

static func _rebuild_referents(model: TechnologyAuthoringModel) -> void:
	model._referents.clear()
	for node_value in model.nodes():
		var row: Dictionary = node_value
		var owner := String(row.get("id", ""))
		for field in TechnologyAuthoringModel.RELATION_FIELDS:
			var entries: Array = row.get(field, [])
			for slot in range(entries.size()):
				model._add_referent(String(entries[slot]), "node", owner, field, slot)
		for route_value in row.get("research_routes", []):
			var route: Dictionary = route_value
			var atoms := PackedStringArray()
			TechnologyAuthoringModel.ValidatorScript.collect_technology_atoms(route.get("condition", {}), atoms)
			for atom in atoms:
				model._add_referent(String(atom), "node", owner, "research_routes", -1,
					String(route.get("id", "")))
		var basis: Dictionary = row.get("knowledge_basis", {})
		for required in basis.get("required_ids", []):
			model._add_referent(String(required), "node", owner, "knowledge_basis", -1, "required_ids")
		for group_value in basis.get("alternative_groups", []):
			for alternative in (group_value as Array):
				model._add_referent(String(alternative), "node", owner, "knowledge_basis", -1,
					"alternative_groups")
	for era_value in model.meta_array("eras"):
		var era: Dictionary = era_value
		var era_id := String(era.get("id", ""))
		model._add_referent(String(era.get("milestone_id", "")), "era", era_id, "milestone_id", -1)
		model._add_referent(String(era.get("entry_milestone_id", "")), "era", era_id,
			"entry_milestone_id", -1)
		var candidates: Array = era.get("milestone_candidate_ids", [])
		for slot in range(candidates.size()):
			model._add_referent(String(candidates[slot]), "era", era_id, "milestone_candidate_ids", slot)
	for row_value in model.meta_array("application_intersections"):
		var row: Dictionary = row_value
		var app_id := String(row.get("id", ""))
		var required: Array = row.get("required_technology_ids", [])
		for slot in range(required.size()):
			model._add_referent(String(required[slot]), "application_intersection", app_id,
				"required_technology_ids", slot)


static func _add_referent(model: TechnologyAuthoringModel, target: String, owner_kind: String, owner_id: String,
		field: String, slot: int, label := "") -> void:
	if target.is_empty():
		return
	var bucket: Array = model._referents.get(target, [])
	bucket.append({
		"owner_kind": owner_kind,
		"owner_id": owner_id,
		"field": field,
		"slot": slot,
		"label": label,
	})
	model._referents[target] = bucket


# --------------------------------------------------------------------------
# Transactions
# --------------------------------------------------------------------------


static func _apply_rename(model: TechnologyAuthoringModel, from_id: String, to_id: String) -> void:
	var target := model.node(from_id)
	if target.is_empty():
		return
	target["id"] = to_id
	for node_value in model.nodes():
		var row: Dictionary = node_value
		for field in TechnologyAuthoringModel.RELATION_FIELDS:
			var entries: Array = row.get(field, [])
			for slot in range(entries.size()):
				if String(entries[slot]) == from_id:
					entries[slot] = to_id
		for route_value in row.get("research_routes", []):
			model._rename_in_condition((route_value as Dictionary).get("condition", {}),
				from_id, to_id)
		var basis: Dictionary = row.get("knowledge_basis", {})
		var required: Array = basis.get("required_ids", [])
		for slot in range(required.size()):
			if String(required[slot]) == from_id:
				required[slot] = to_id
		for group_value in basis.get("alternative_groups", []):
			var group: Array = group_value
			for slot in range(group.size()):
				if String(group[slot]) == from_id:
					group[slot] = to_id
	for era_value in model.meta_array("eras"):
		var era: Dictionary = era_value
		if String(era.get("milestone_id", "")) == from_id:
			era["milestone_id"] = to_id
		if String(era.get("entry_milestone_id", "")) == from_id:
			era["entry_milestone_id"] = to_id
		var candidates: Array = era.get("milestone_candidate_ids", [])
		for slot in range(candidates.size()):
			if String(candidates[slot]) == from_id:
				candidates[slot] = to_id
	for row_value in model.meta_array("application_intersections"):
		var row: Dictionary = row_value
		var required: Array = row.get("required_technology_ids", [])
		for slot in range(required.size()):
			if String(required[slot]) == from_id:
				required[slot] = to_id
	model._reindex()


static func _rename_in_condition(model: TechnologyAuthoringModel, spec: Dictionary, from_id: String, to_id: String) -> void:
	if spec.is_empty():
		return
	if spec.has("kind"):
		if String(spec.get("id", "")) == from_id:
			spec["id"] = to_id
		return
	for child_value in spec.get("children", []):
		if child_value is Dictionary:
			model._rename_in_condition(child_value as Dictionary, from_id, to_id)


## Removes every reference to `id` while preserving paired-array alignment,
## condition-tree validity and era milestone contracts.


static func _detach_technology(model: TechnologyAuthoringModel, id: String) -> Array[Dictionary]:
	var repaired: Array[Dictionary] = []
	for entry_value in model.referents(id):
		var entry: Dictionary = entry_value
		var owner_id := String(entry.owner_id)
		var field := String(entry.field)
		match String(entry.owner_kind):
			"node":
				if owner_id == id:
					continue
				if TechnologyAuthoringModel.RELATION_FIELDS.has(field):
					if model.remove_relation_entry(owner_id, field, id):
						repaired.append({"owner_id": owner_id, "field": field})
				elif field == "research_routes":
					if model._prune_routes(owner_id, id):
						repaired.append({"owner_id": owner_id, "field": field})
				elif field == "knowledge_basis":
					if model._prune_knowledge_basis(owner_id, id):
						repaired.append({"owner_id": owner_id, "field": field})
			"era":
				model._touch_meta("eras")
				var era := model.meta_row("eras", owner_id)
				if era.is_empty():
					continue
				if field == "milestone_candidate_ids":
					var candidates: Array = era.get("milestone_candidate_ids", [])
					candidates.erase(id)
					era["candidate_required"] = clampi(
						int(era.get("candidate_required", 4)), 4, maxi(4, mini(7, candidates.size())))
					repaired.append({"owner_id": owner_id, "field": field})
				elif field == "entry_milestone_id":
					era["entry_milestone_id"] = ""
					repaired.append({"owner_id": owner_id, "field": field})
			"application_intersection":
				model._touch_meta("application_intersections")
				var row := model.meta_row("application_intersections", owner_id)
				if row.is_empty():
					continue
				var required: Array = row.get("required_technology_ids", [])
				required.erase(id)
				repaired.append({"owner_id": owner_id, "field": field})
	return repaired


static func _prune_routes(model: TechnologyAuthoringModel, owner_id: String, removed_id: String) -> bool:
	if not model._touch(owner_id):
		return false
	var owner := model.node(owner_id)
	var routes: Array = owner.get("research_routes", [])
	var kept: Array = []
	var changed := false
	for route_value in routes:
		var route: Dictionary = route_value
		var condition: Dictionary = route.get("condition", {})
		var atoms := PackedStringArray()
		TechnologyAuthoringModel.ValidatorScript.collect_technology_atoms(condition, atoms)
		if not atoms.has(removed_id):
			kept.append(route)
			continue
		changed = true
		var pruned: Variant = model._prune_condition(condition, removed_id)
		if pruned == null:
			continue
		route["condition"] = pruned
		kept.append(route)
	if changed:
		owner["research_routes"] = kept
		if kept.is_empty() and String(owner.get("route_exemption_reason", "")).strip_edges().is_empty():
			owner["route_exemption_reason"] = "删除 %s 后本节点暂无替代研究路线。" % removed_id
	return changed


## Returns the pruned condition, or null when the whole condition collapses.


static func _prune_condition(model: TechnologyAuthoringModel, spec: Dictionary, removed_id: String) -> Variant:
	if spec.is_empty():
		return spec
	if spec.has("kind"):
		if int(spec.get("kind", -1)) == ResearchPredicate.Kind.TECH_COMPLETED \
				and String(spec.get("id", "")) == removed_id:
			return null
		return spec
	var children: Array = spec.get("children", [])
	var kept: Array = []
	for child_value in children:
		if not child_value is Dictionary:
			continue
		var pruned: Variant = model._prune_condition(child_value as Dictionary, removed_id)
		if pruned == null:
			continue
		kept.append(pruned)
	if kept.is_empty():
		return null
	spec["children"] = kept
	if int(spec.get("operator", -1)) == ResearchCondition.Operator.AT_LEAST:
		spec["required_count"] = float(clampi(int(spec.get("required_count", 1)), 1, kept.size()))
	return spec


static func _prune_knowledge_basis(model: TechnologyAuthoringModel, owner_id: String, removed_id: String) -> bool:
	if not model._touch(owner_id):
		return false
	var owner := model.node(owner_id)
	var basis: Dictionary = owner.get("knowledge_basis", {})
	if basis.is_empty():
		return false
	var changed := false
	var required: Array = basis.get("required_ids", [])
	if required.has(removed_id):
		required.erase(removed_id)
		changed = true
	var groups: Array = basis.get("alternative_groups", [])
	var kept_groups: Array = []
	for group_value in groups:
		var group: Array = (group_value as Array).duplicate()
		if group.has(removed_id):
			group.erase(removed_id)
			changed = true
		if group.is_empty():
			continue
		kept_groups.append(group)
	if changed:
		basis["alternative_groups"] = kept_groups
	return changed


# --------------------------------------------------------------------------
# Layout ordering
# --------------------------------------------------------------------------

## Renumbers `layout_order` inside one era band from the supplied ID order.
