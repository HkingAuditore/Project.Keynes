class_name TechnologyAuthoringModel
extends RefCounted

## Indexed, transactional authoring model over technology_network.json.
##
## The previous authoring prototype scanned the node array linearly for every
## lookup and let callers write `hard_prerequisite_ids` without the equally
## long `prerequisite_rationales`, which produced files the gate always
## rejected. This model removes both failure classes: lookups are O(1) and
## paired arrays can only be written through `set_relation`, which writes both
## sides together.

const ValidatorScript = preload("res://scripts/technology/technology_network_validator.gd")

## Relation field -> paired rationale field. Both sides always move together.
const RELATION_FIELDS := {
	"hard_prerequisite_ids": "prerequisite_rationales",
	"branch_successor_ids": "branch_successor_rationales",
	"application_target_ids": "application_target_rationales",
}

const META_ARRAY_KEYS := [
	"eras", "domains", "backbones", "branch_families", "application_intersections",
]

const UNDO_LIMIT := 128

const DEFAULT_RATIONALE := "作者待补充理由。"

signal model_reset()
## dirty_ids lists the technologies whose content changed in the committed batch.
signal batch_committed(dirty_ids: PackedStringArray, structural: bool)

var _payload: Dictionary = {}
var _index: Dictionary = {}
var _order: Dictionary = {}
var _referents: Dictionary = {}
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var _batch: Dictionary = {}
var _dirty_since_save := false


# --------------------------------------------------------------------------
# Loading and access
# --------------------------------------------------------------------------

func load_payload(payload: Dictionary) -> void:
	_payload = payload
	_undo.clear()
	_redo.clear()
	_batch = {}
	_dirty_since_save = false
	_reindex()
	_rebuild_referents()
	model_reset.emit()


func payload() -> Dictionary:
	return _payload


func nodes() -> Array:
	return _payload.get("nodes", []) as Array


func meta_array(key: String) -> Array:
	return _payload.get(key, []) as Array


func node_count() -> int:
	return nodes().size()


func has_technology(id: String) -> bool:
	return _index.has(id)


func node(id: String) -> Dictionary:
	return _index.get(id, {}) as Dictionary


func node_position(id: String) -> int:
	return int(_order.get(id, -1))


func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for node_value in nodes():
		out.append(String((node_value as Dictionary).get("id", "")))
	return out


func is_dirty() -> bool:
	return _dirty_since_save


func mark_saved() -> void:
	_dirty_since_save = false


func _reindex() -> void:
	_index.clear()
	_order.clear()
	var rows := nodes()
	for cursor in range(rows.size()):
		var row: Dictionary = rows[cursor]
		var id := String(row.get("id", ""))
		if id.is_empty():
			continue
		_index[id] = row
		_order[id] = cursor


# --------------------------------------------------------------------------
# Reverse reference index
# --------------------------------------------------------------------------

## referents(id) -> [{owner_kind, owner_id, field, slot, label}]
## owner_kind is "node", "era" or "application_intersection".
func referents(id: String) -> Array:
	return (_referents.get(id, []) as Array).duplicate()


func reference_count(id: String) -> int:
	return (_referents.get(id, []) as Array).size()


func _rebuild_referents() -> void:
	_referents.clear()
	for node_value in nodes():
		var row: Dictionary = node_value
		var owner := String(row.get("id", ""))
		for field in RELATION_FIELDS:
			var entries: Array = row.get(field, [])
			for slot in range(entries.size()):
				_add_referent(String(entries[slot]), "node", owner, field, slot)
		for route_value in row.get("research_routes", []):
			var route: Dictionary = route_value
			var atoms := PackedStringArray()
			ValidatorScript.collect_technology_atoms(route.get("condition", {}), atoms)
			for atom in atoms:
				_add_referent(String(atom), "node", owner, "research_routes", -1,
					String(route.get("id", "")))
		var basis: Dictionary = row.get("knowledge_basis", {})
		for required in basis.get("required_ids", []):
			_add_referent(String(required), "node", owner, "knowledge_basis", -1, "required_ids")
		for group_value in basis.get("alternative_groups", []):
			for alternative in (group_value as Array):
				_add_referent(String(alternative), "node", owner, "knowledge_basis", -1,
					"alternative_groups")
	for era_value in meta_array("eras"):
		var era: Dictionary = era_value
		var era_id := String(era.get("id", ""))
		_add_referent(String(era.get("milestone_id", "")), "era", era_id, "milestone_id", -1)
		_add_referent(String(era.get("entry_milestone_id", "")), "era", era_id,
			"entry_milestone_id", -1)
		var candidates: Array = era.get("milestone_candidate_ids", [])
		for slot in range(candidates.size()):
			_add_referent(String(candidates[slot]), "era", era_id, "milestone_candidate_ids", slot)
	for row_value in meta_array("application_intersections"):
		var row: Dictionary = row_value
		var app_id := String(row.get("id", ""))
		var required: Array = row.get("required_technology_ids", [])
		for slot in range(required.size()):
			_add_referent(String(required[slot]), "application_intersection", app_id,
				"required_technology_ids", slot)


func _add_referent(target: String, owner_kind: String, owner_id: String,
		field: String, slot: int, label := "") -> void:
	if target.is_empty():
		return
	var bucket: Array = _referents.get(target, [])
	bucket.append({
		"owner_kind": owner_kind,
		"owner_id": owner_id,
		"field": field,
		"slot": slot,
		"label": label,
	})
	_referents[target] = bucket


# --------------------------------------------------------------------------
# Transactions
# --------------------------------------------------------------------------

func begin_batch(label: String) -> void:
	if not _batch.is_empty():
		push_warning("technology_authoring_batch_already_open:%s" % label)
		return
	_batch = {
		"label": label,
		"ops": [],
		"touched": {},
		"meta_before": {},
		"structural": false,
	}


func abort_batch() -> void:
	if _batch.is_empty():
		return
	_rollback(_batch)
	_batch = {}
	_reindex()
	_rebuild_referents()


func commit_batch() -> bool:
	if _batch.is_empty():
		return false
	var batch := _batch
	_batch = {}
	var touched: Dictionary = batch.touched
	if touched.is_empty() and (batch.meta_before as Dictionary).is_empty() \
			and (batch.ops as Array).is_empty():
		return false
	for id in touched:
		var op: Dictionary = touched[id]
		if String(op.get("op", "")) == "update":
			op["after"] = node(String(id)).duplicate(true)
		(batch.ops as Array).append(op)
	var meta_after := {}
	for key in batch.meta_before as Dictionary:
		meta_after[key] = (_payload.get(key, []) as Array).duplicate(true)
	batch["meta_after"] = meta_after
	batch.erase("touched")
	_undo.append(batch)
	if _undo.size() > UNDO_LIMIT:
		_undo.remove_at(0)
	_redo.clear()
	_dirty_since_save = true
	_reindex()
	_rebuild_referents()
	var dirty := PackedStringArray()
	for op_value in batch.ops as Array:
		var op: Dictionary = op_value
		var id := String(op.get("id", op.get("to", "")))
		if not id.is_empty() and not dirty.has(id):
			dirty.append(id)
	batch_committed.emit(dirty, bool(batch.structural))
	return true


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo_label() -> String:
	return String((_undo[-1] as Dictionary).get("label", "")) if not _undo.is_empty() else ""


func redo_label() -> String:
	return String((_redo[-1] as Dictionary).get("label", "")) if not _redo.is_empty() else ""


func undo() -> PackedStringArray:
	if _undo.is_empty():
		return PackedStringArray()
	var batch: Dictionary = _undo.pop_back()
	_rollback(batch)
	_redo.append(batch)
	_dirty_since_save = true
	_reindex()
	_rebuild_referents()
	var dirty := _batch_ids(batch)
	batch_committed.emit(dirty, bool(batch.get("structural", false)))
	return dirty


func redo() -> PackedStringArray:
	if _redo.is_empty():
		return PackedStringArray()
	var batch: Dictionary = _redo.pop_back()
	_replay(batch)
	_undo.append(batch)
	_dirty_since_save = true
	_reindex()
	_rebuild_referents()
	var dirty := _batch_ids(batch)
	batch_committed.emit(dirty, bool(batch.get("structural", false)))
	return dirty


func _batch_ids(batch: Dictionary) -> PackedStringArray:
	var dirty := PackedStringArray()
	for op_value in batch.get("ops", []):
		var op: Dictionary = op_value
		var id := String(op.get("id", op.get("to", "")))
		if not id.is_empty() and not dirty.has(id):
			dirty.append(id)
	return dirty


func _rollback(batch: Dictionary) -> void:
	var ops: Array = batch.get("ops", [])
	for cursor in range(ops.size() - 1, -1, -1):
		var op: Dictionary = ops[cursor]
		match String(op.get("op", "")):
			"update":
				_write_node_contents(String(op.id), op.get("before", {}) as Dictionary)
			"insert":
				_erase_node_at(String(op.id))
			"remove":
				_insert_node_at(int(op.index), (op.get("node", {}) as Dictionary).duplicate(true))
			"rename":
				_apply_rename(String(op.to), String(op["from"]))
	for key in batch.get("meta_before", {}):
		_payload[key] = ((batch.meta_before as Dictionary)[key] as Array).duplicate(true)


func _replay(batch: Dictionary) -> void:
	for key in batch.get("meta_after", {}):
		_payload[key] = ((batch.meta_after as Dictionary)[key] as Array).duplicate(true)
	for op_value in batch.get("ops", []):
		var op: Dictionary = op_value
		match String(op.get("op", "")):
			"update":
				_write_node_contents(String(op.id), op.get("after", {}) as Dictionary)
			"insert":
				_insert_node_at(int(op.index), (op.get("node", {}) as Dictionary).duplicate(true))
			"remove":
				_erase_node_at(String(op.id))
			"rename":
				_apply_rename(String(op["from"]), String(op.to))


## Replaces a node's contents in place so any held reference stays valid and
## the JSON key order of untouched fields is preserved.
func _write_node_contents(id: String, contents: Dictionary) -> void:
	var target := node(id)
	if target.is_empty():
		var position := int(_order.get(id, -1))
		if position < 0:
			return
		target = nodes()[position] as Dictionary
	target.clear()
	target.merge(contents.duplicate(true))


func _insert_node_at(index: int, row: Dictionary) -> void:
	var rows := nodes()
	var clamped := clampi(index, 0, rows.size())
	rows.insert(clamped, row)
	_reindex()


func _erase_node_at(id: String) -> void:
	var position := int(_order.get(id, -1))
	if position < 0:
		return
	nodes().remove_at(position)
	_reindex()


func _touch(id: String) -> bool:
	if _batch.is_empty():
		push_warning("technology_authoring_edit_outside_batch:%s" % id)
		return false
	var touched: Dictionary = _batch.touched
	if touched.has(id):
		return true
	if not _index.has(id):
		return false
	touched[id] = {"op": "update", "id": id, "before": node(id).duplicate(true)}
	return true


func _touch_meta(key: String) -> void:
	if _batch.is_empty():
		push_warning("technology_authoring_meta_edit_outside_batch:%s" % key)
		return
	var meta_before: Dictionary = _batch.meta_before
	if meta_before.has(key):
		return
	meta_before[key] = (_payload.get(key, []) as Array).duplicate(true)


# --------------------------------------------------------------------------
# Field editing
# --------------------------------------------------------------------------

func set_field(id: String, key: String, value: Variant) -> bool:
	if key == "id":
		push_warning("technology_authoring_use_rename_technology")
		return false
	if RELATION_FIELDS.has(key) or RELATION_FIELDS.values().has(key):
		push_warning("technology_authoring_use_set_relation:%s" % key)
		return false
	if not _touch(id):
		return false
	var target := node(id)
	if target.get(key, null) == value:
		return true
	target[key] = value
	return true


func set_fields(id: String, changes: Dictionary) -> bool:
	var applied := false
	for key in changes:
		applied = set_field(id, String(key), changes[key]) or applied
	return applied


## relation(id, field) -> [{id, rationale}] built from the paired arrays.
func relation(id: String, field: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not RELATION_FIELDS.has(field):
		return out
	var target := node(id)
	if target.is_empty():
		return out
	var entries: Array = target.get(field, [])
	var rationales: Array = target.get(String(RELATION_FIELDS[field]), [])
	for slot in range(entries.size()):
		out.append({
			"id": String(entries[slot]),
			"rationale": String(rationales[slot]) if slot < rationales.size() else "",
		})
	return out


## Writes both the relation and its rationale array, so the two can never drift.
func set_relation(id: String, field: String, entries: Array) -> bool:
	if not RELATION_FIELDS.has(field):
		push_warning("technology_authoring_unknown_relation:%s" % field)
		return false
	if not _touch(id):
		return false
	var target := node(id)
	var ids: Array = []
	var rationales: Array = []
	var seen := {}
	for entry_value in entries:
		var entry: Dictionary = entry_value
		var entry_id := String(entry.get("id", "")).strip_edges()
		if entry_id.is_empty() or seen.has(entry_id):
			continue
		seen[entry_id] = true
		ids.append(entry_id)
		var rationale := String(entry.get("rationale", "")).strip_edges()
		rationales.append(rationale if not rationale.is_empty() else DEFAULT_RATIONALE)
	target[field] = ids
	target[String(RELATION_FIELDS[field])] = rationales
	return true


func add_relation_entry(id: String, field: String, target_id: String,
		rationale := "") -> bool:
	var entries := relation(id, field)
	for entry in entries:
		if String(entry.id) == target_id:
			return false
	entries.append({"id": target_id, "rationale": rationale})
	return set_relation(id, field, entries)


func remove_relation_entry(id: String, field: String, target_id: String) -> bool:
	var entries := relation(id, field)
	var kept: Array[Dictionary] = []
	var removed := false
	for entry in entries:
		if String(entry.id) == target_id:
			removed = true
			continue
		kept.append(entry)
	if not removed:
		return false
	return set_relation(id, field, kept)


# --------------------------------------------------------------------------
# Meta arrays
# --------------------------------------------------------------------------

func meta_row(key: String, id: String) -> Dictionary:
	for row_value in meta_array(key):
		var row: Dictionary = row_value
		if String(row.get("id", "")) == id:
			return row
	return {}


func set_meta_field(key: String, id: String, field: String, value: Variant) -> bool:
	var row := meta_row(key, id)
	if row.is_empty():
		return false
	_touch_meta(key)
	row = meta_row(key, id)
	if row.get(field, null) == value:
		return true
	row[field] = value
	return true


## Keeps every era's entry_milestone_id equal to the previous era's milestone_id,
## which the gate enforces as a hard chain.
func repair_era_entry_chain() -> void:
	var eras := meta_array("eras")
	if eras.is_empty():
		return
	_touch_meta("eras")
	eras = meta_array("eras")
	for index in range(eras.size()):
		var era: Dictionary = eras[index]
		era["entry_milestone_id"] = "" if index == 0 else String(
			(eras[index - 1] as Dictionary).get("milestone_id", ""))


# --------------------------------------------------------------------------
# Structural operations
# --------------------------------------------------------------------------

func new_node_template(id: String, display_name: String, era_id: String,
		domain_id: String, branch_family_id: String) -> Dictionary:
	return {
		"id": id,
		"display_name": display_name,
		"era_id": era_id,
		"domain_id": domain_id,
		"cost_points": 3900.0,
		"layout_order": float(node_count()),
		"network_role": "branch",
		"anchor_kind": "branch",
		"node_role": "handling",
		"effect_profile": "",
		"secondary_route_tags": [],
		"hard_prerequisite_ids": [],
		"reveal_condition": {},
		"is_milestone": false,
		"is_era_key": false,
		"is_starting": false,
		"is_starter_eligible": false,
		"starter_capability_tags": [],
		"modifier_terms": [],
		"expected_bindings": [],
		"content_effects": [],
		"effect_summary": "",
		"opportunity_cost": "占用通用研究预算。",
		"application_target_ids": [],
		"terminal_reason": "新建节点尚未接入后继或效果，暂记为终点。",
		"branch_family_id": branch_family_id,
		"era_entry_milestone_id": "",
		"reveal_category": "general_knowledge",
		"reveal_summary": "在掌握前置知识后，该科技作为后续问题被揭示。",
		"branch_successor_ids": [],
		"prerequisite_rationales": [],
		"branch_successor_rationales": [],
		"application_target_rationales": [],
		"effect_design_review": {
			"status": "reviewed",
			"numeric_effect_policy": "explicit_only",
			"non_numeric_consumers_allowed": true,
		},
		"support_buildings": [],
		"research_routes": [],
		"route_exemption_reason": "新建节点尚未编写替代研究路线。",
		"reveal_template_reason": "新建节点的揭示理由待作者补充。",
		"topology_review": {
			"role": "terminal",
			"rationale": "新建节点暂无后继，按终点审核。",
			"expected_hard_family_ids": [],
		},
		"building_unlock_review": {
			"policy": "support_only",
			"rationale": "新建节点暂不直接解锁建筑。",
		},
		"knowledge_basis": {
			"required_ids": [],
			"alternative_groups": [],
			"exemption_reason": "",
		},
	}


func validate_new_id(id: String) -> String:
	var trimmed := id.strip_edges()
	if not trimmed.begins_with("tech."):
		return "ID 必须以 tech. 开头。"
	if trimmed.length() <= 5:
		return "ID 缺少名称部分。"
	if _index.has(trimmed):
		return "ID 已存在：%s" % trimmed
	return ""


## Inserts a node directly after `after_id` so the gate's
## "route evidence must be defined earlier" ordering stays workable.
func add_node(row: Dictionary, after_id := "") -> Dictionary:
	var id := String(row.get("id", ""))
	var reason := validate_new_id(id)
	if not reason.is_empty():
		return {"ok": false, "reason": reason}
	if _batch.is_empty():
		return {"ok": false, "reason": "technology_authoring_edit_outside_batch"}
	var index := nodes().size()
	if not after_id.is_empty() and _order.has(after_id):
		index = int(_order[after_id]) + 1
	_insert_node_at(index, row.duplicate(true))
	_batch.structural = true
	(_batch.ops as Array).append({"op": "insert", "id": id, "index": index,
		"node": row.duplicate(true)})
	_dirty_since_save = true
	return {"ok": true, "id": id, "index": index}


## Lists everything that would change if `id` were deleted.
func delete_preview(id: String) -> Dictionary:
	var rows: Array[Dictionary] = []
	for entry_value in referents(id):
		var entry: Dictionary = entry_value
		rows.append({
			"owner_kind": String(entry.owner_kind),
			"owner_id": String(entry.owner_id),
			"field": String(entry.field),
			"label": String(entry.label),
		})
	var blocking := PackedStringArray()
	for era_value in meta_array("eras"):
		var era: Dictionary = era_value
		if String(era.get("milestone_id", "")) == id:
			blocking.append("时代 %s 以该科技为里程碑，删除前需要改指其他节点。" % String(era.get("id", "")))
	return {"ok": blocking.is_empty(), "references": rows, "blocking": blocking}


## Removes a node and repairs every reference to it in the same batch.
func remove_node(id: String) -> Dictionary:
	if not _index.has(id):
		return {"ok": false, "reason": "technology_unknown:%s" % id}
	if _batch.is_empty():
		return {"ok": false, "reason": "technology_authoring_edit_outside_batch"}
	var preview := delete_preview(id)
	if not bool(preview.ok):
		return {"ok": false, "reason": String((preview.blocking as PackedStringArray)[0])}
	var repaired := _detach_technology(id)
	var index := int(_order[id])
	var snapshot := node(id).duplicate(true)
	_erase_node_at(id)
	_batch.structural = true
	(_batch.ops as Array).append({"op": "remove", "id": id, "index": index,
		"node": snapshot})
	_dirty_since_save = true
	return {"ok": true, "repaired": repaired}


## Rewrites the ID and every reference to it atomically.
##
## A rename must own its batch: `_apply_rename` is its own inverse, so it needs
## no per-node snapshots, and mixing it with snapshot-based edits would leave
## those snapshots keyed by an ID that no longer resolves.
func rename_node(from_id: String, to_id: String) -> Dictionary:
	if not _index.has(from_id):
		return {"ok": false, "reason": "technology_unknown:%s" % from_id}
	var reason := validate_new_id(to_id)
	if not reason.is_empty():
		return {"ok": false, "reason": reason}
	if _batch.is_empty():
		return {"ok": false, "reason": "technology_authoring_edit_outside_batch"}
	if not (_batch.touched as Dictionary).is_empty() or not (_batch.ops as Array).is_empty() \
			or not (_batch.meta_before as Dictionary).is_empty():
		return {"ok": false, "reason": "technology_authoring_rename_requires_own_batch"}
	_apply_rename(from_id, to_id)
	_batch.structural = true
	(_batch.ops as Array).append({"op": "rename", "from": from_id, "to": to_id})
	_dirty_since_save = true
	return {"ok": true}


func _apply_rename(from_id: String, to_id: String) -> void:
	var target := node(from_id)
	if target.is_empty():
		return
	target["id"] = to_id
	for node_value in nodes():
		var row: Dictionary = node_value
		for field in RELATION_FIELDS:
			var entries: Array = row.get(field, [])
			for slot in range(entries.size()):
				if String(entries[slot]) == from_id:
					entries[slot] = to_id
		for route_value in row.get("research_routes", []):
			_rename_in_condition((route_value as Dictionary).get("condition", {}),
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
	for era_value in meta_array("eras"):
		var era: Dictionary = era_value
		if String(era.get("milestone_id", "")) == from_id:
			era["milestone_id"] = to_id
		if String(era.get("entry_milestone_id", "")) == from_id:
			era["entry_milestone_id"] = to_id
		var candidates: Array = era.get("milestone_candidate_ids", [])
		for slot in range(candidates.size()):
			if String(candidates[slot]) == from_id:
				candidates[slot] = to_id
	for row_value in meta_array("application_intersections"):
		var row: Dictionary = row_value
		var required: Array = row.get("required_technology_ids", [])
		for slot in range(required.size()):
			if String(required[slot]) == from_id:
				required[slot] = to_id
	_reindex()


func _rename_in_condition(spec: Dictionary, from_id: String, to_id: String) -> void:
	if spec.is_empty():
		return
	if spec.has("kind"):
		if String(spec.get("id", "")) == from_id:
			spec["id"] = to_id
		return
	for child_value in spec.get("children", []):
		if child_value is Dictionary:
			_rename_in_condition(child_value as Dictionary, from_id, to_id)


## Removes every reference to `id` while preserving paired-array alignment,
## condition-tree validity and era milestone contracts.
func _detach_technology(id: String) -> Array[Dictionary]:
	var repaired: Array[Dictionary] = []
	for entry_value in referents(id):
		var entry: Dictionary = entry_value
		var owner_id := String(entry.owner_id)
		var field := String(entry.field)
		match String(entry.owner_kind):
			"node":
				if owner_id == id:
					continue
				if RELATION_FIELDS.has(field):
					if remove_relation_entry(owner_id, field, id):
						repaired.append({"owner_id": owner_id, "field": field})
				elif field == "research_routes":
					if _prune_routes(owner_id, id):
						repaired.append({"owner_id": owner_id, "field": field})
				elif field == "knowledge_basis":
					if _prune_knowledge_basis(owner_id, id):
						repaired.append({"owner_id": owner_id, "field": field})
			"era":
				_touch_meta("eras")
				var era := meta_row("eras", owner_id)
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
				_touch_meta("application_intersections")
				var row := meta_row("application_intersections", owner_id)
				if row.is_empty():
					continue
				var required: Array = row.get("required_technology_ids", [])
				required.erase(id)
				repaired.append({"owner_id": owner_id, "field": field})
	return repaired


func _prune_routes(owner_id: String, removed_id: String) -> bool:
	if not _touch(owner_id):
		return false
	var owner := node(owner_id)
	var routes: Array = owner.get("research_routes", [])
	var kept: Array = []
	var changed := false
	for route_value in routes:
		var route: Dictionary = route_value
		var condition: Dictionary = route.get("condition", {})
		var atoms := PackedStringArray()
		ValidatorScript.collect_technology_atoms(condition, atoms)
		if not atoms.has(removed_id):
			kept.append(route)
			continue
		changed = true
		var pruned: Variant = _prune_condition(condition, removed_id)
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
func _prune_condition(spec: Dictionary, removed_id: String) -> Variant:
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
		var pruned: Variant = _prune_condition(child_value as Dictionary, removed_id)
		if pruned == null:
			continue
		kept.append(pruned)
	if kept.is_empty():
		return null
	spec["children"] = kept
	if int(spec.get("operator", -1)) == ResearchCondition.Operator.AT_LEAST:
		spec["required_count"] = float(clampi(int(spec.get("required_count", 1)), 1, kept.size()))
	return spec


func _prune_knowledge_basis(owner_id: String, removed_id: String) -> bool:
	if not _touch(owner_id):
		return false
	var owner := node(owner_id)
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
func reorder_layout(era_id: String, ordered_ids: PackedStringArray) -> bool:
	var applied := false
	for slot in range(ordered_ids.size()):
		var id := String(ordered_ids[slot])
		var row := node(id)
		if row.is_empty() or String(row.get("era_id", "")) != era_id:
			continue
		if not _touch(id):
			continue
		node(id)["layout_order"] = float(slot)
		applied = true
	return applied


## Drops keys the previous prototype invented but the schema never defined.
func strip_unknown_layout_keys() -> int:
	var removed := 0
	for node_value in nodes():
		var row: Dictionary = node_value
		if not row.has("ui_row"):
			continue
		var id := String(row.get("id", ""))
		if not _touch(id):
			continue
		node(id).erase("ui_row")
		removed += 1
	return removed
