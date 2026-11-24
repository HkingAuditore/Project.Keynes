extends RefCounted


const KNOWLEDGE_EXEMPTION_IDS := [
	"tech.dryland_cropland",
	"tech.early_knowledge_institution",
	"tech.highland_crop_archive",
	"tech.highland_plot_yield",
	"tech.hill_stone_quarrying",
	"tech.oasis_craft_guilds",
	"tech.oasis_well_digging",
	"tech.plateau_quarry_commons",
	"tech.polar_crop_acclimatization",
	"tech.reef_fishery",
	"tech.savanna_mixed_farming",
	"tech.slope_terrace_agriculture",
	"tech.taiga_timber_processing",
	"tech.tundra_harvest_economy",
	"tech.xeric_crop_archive",
]


static func _validate_knowledge_basis(row: Dictionary, row_by_id: Dictionary) -> Dictionary:
	var technology_id := String(row.get("id", ""))
	var basis_value: Variant = row.get("knowledge_basis", null)
	if not basis_value is Dictionary:
		return {"ok": false, "reason": "technology_knowledge_basis_missing",
			"id": technology_id}
	var basis: Dictionary = basis_value
	var required_ids: Array = basis.get("required_ids", [])
	var alternative_groups: Array = basis.get("alternative_groups", [])
	var exemption_reason := String(basis.get("exemption_reason", "")).strip_edges()
	if (not required_ids.is_empty() or not alternative_groups.is_empty()) \
			and not exemption_reason.is_empty():
		return {"ok": false, "reason": "technology_knowledge_basis_exemption_conflict",
			"id": technology_id}
	if required_ids.is_empty() and alternative_groups.is_empty() and exemption_reason.is_empty():
		return {"ok": false, "reason": "technology_knowledge_basis_empty",
			"id": technology_id}
	var hard_ancestors := {}
	_collect_authoring_hard_ancestors(technology_id, row_by_id, hard_ancestors)
	hard_ancestors.erase(technology_id)
	var required_seen := {}
	for required_value in required_ids:
		var required_id := String(required_value)
		if required_seen.has(required_id) or not hard_ancestors.has(required_id):
			return {"ok": false, "reason": "technology_knowledge_required_not_hard_ancestor",
				"id": technology_id, "required_id": required_id}
		required_seen[required_id] = true
	var alternative_seen := {}
	for group_value in alternative_groups:
		if not group_value is Array or (group_value as Array).is_empty():
			return {"ok": false, "reason": "technology_knowledge_alternative_group_invalid",
				"id": technology_id}
		for alternative_value in group_value as Array:
			var alternative_id := String(alternative_value)
			if alternative_seen.has(alternative_id) or not row_by_id.has(alternative_id) \
					or not _research_routes_reference_technology(
						row.get("research_routes", []), alternative_id):
				return {"ok": false, "reason": "technology_knowledge_alternative_not_visible",
					"id": technology_id, "alternative_id": alternative_id}
			alternative_seen[alternative_id] = true
	if not exemption_reason.is_empty():
		# The three original roles, plus one narrow shape: a branch-entry node
		# with no hard prerequisite at all whose knowledge really is the reveal
		# gate itself (`reveal_condition` non-empty). Those nodes cannot fill
		# `required_ids` (no hard ancestor exists) nor `alternative_groups`
		# (their `research_routes` are deliberately empty), so without this
		# clause they would be impossible to author -- and the named-exemption
		# idea is already accepted elsewhere in this file for
		# `route_exemption_reason`. The exact id set is pinned by
		# `KNOWLEDGE_EXEMPTION_IDS`; this clause only decides the shape.
		var has_hard_prerequisite := not (row.get("hard_prerequisite_ids", []) as Array).is_empty()
		var reveal_value: Variant = row.get("reveal_condition", {})
		var has_reveal_gate := reveal_value is Dictionary \
			and not (reveal_value as Dictionary).is_empty()
		var exemption_allowed := bool(row.get("is_starter_eligible", false)) \
			or bool(row.get("is_milestone", false)) \
			or String(row.get("node_role", "")) == "identification" \
			or (not has_hard_prerequisite and has_reveal_gate)
		if not exemption_allowed:
			return {"ok": false, "reason": "technology_knowledge_exemption_not_allowed",
				"id": technology_id}
	return {"ok": true}


## Exact-set ratchet for the named knowledge exemption declared above. The shape
## clause in `_validate_knowledge_basis` decides whether a row MAY carry the
## exemption; this decides WHICH rows may. Separate functions on purpose: a new
## branch entry that happens to have no prerequisite and a reveal gate must still
## be added to the const, so "another special case" is a visible diff, not a
## silent pass.
static func _validate_knowledge_exemption_set(rows: Array) -> Dictionary:
	var expected := {}
	for expected_id in KNOWLEDGE_EXEMPTION_IDS:
		expected[String(expected_id)] = true
	var actual := {}
	for row_value in rows:
		if not row_value is Dictionary:
			return {"ok": false, "reason": "technology_knowledge_exemption_row_invalid"}
		var row: Dictionary = row_value
		var basis_value: Variant = row.get("knowledge_basis", null)
		if not basis_value is Dictionary:
			continue
		if String((basis_value as Dictionary).get("exemption_reason", "")).strip_edges().is_empty():
			continue
		actual[String(row.get("id", ""))] = true
	var missing: Array = []
	for expected_id in expected:
		if not actual.has(expected_id):
			missing.append(expected_id)
	var unexpected: Array = []
	for actual_id in actual:
		if not expected.has(actual_id):
			unexpected.append(actual_id)
	if not missing.is_empty() or not unexpected.is_empty():
		missing.sort()
		unexpected.sort()
		return {"ok": false, "reason": "technology_knowledge_exemption_set_drift",
			"missing": missing, "unexpected": unexpected}
	return {"ok": true}


static func _collect_authoring_hard_ancestors(technology_id: String,
		row_by_id: Dictionary, out: Dictionary) -> void:
	if out.has(technology_id) or not row_by_id.has(technology_id):
		return
	out[technology_id] = true
	var row: Dictionary = row_by_id[technology_id]
	for prerequisite_value in row.get("hard_prerequisite_ids", []):
		_collect_authoring_hard_ancestors(String(prerequisite_value), row_by_id, out)


static func _research_routes_reference_technology(routes_value: Variant,
		technology_id: String) -> bool:
	if not routes_value is Array:
		return false
	for route_value in routes_value as Array:
		if route_value is Dictionary and _condition_references_technology(
				(route_value as Dictionary).get("condition", {}), technology_id):
			return true
	return false


static func _condition_references_technology(condition_value: Variant,
		technology_id: String) -> bool:
	if not condition_value is Dictionary:
		return false
	var condition: Dictionary = condition_value
	if int(condition.get("kind", -1)) == 0 \
			and String(condition.get("id", "")) == technology_id:
		return true
	for child_value in condition.get("children", []):
		if _condition_references_technology(child_value, technology_id):
			return true
	if condition.has("child") and _condition_references_technology(
			condition.get("child", {}), technology_id):
		return true
	return false
