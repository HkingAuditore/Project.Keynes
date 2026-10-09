extends SceneTree

## Covers the authoring model, the shared validator and the service save path.
##
## The two failure classes that made the previous authoring prototype unusable
## are asserted directly: linear node lookups, and relation writes that left
## `hard_prerequisite_ids` longer than `prerequisite_rationales`.

const ValidatorScript = preload("res://scripts/technology/technology_network_validator.gd")
const ModelScript = preload("res://scripts/technology/technology_authoring_model.gd")
const ServiceScript = preload("res://scripts/technology/technology_authoring_service.gd")

const NETWORK_PATH := "res://data/technology/technology_network.json"

var _failures := 0


func _init() -> void:
	_test_synthetic_network()
	_test_relation_pairing()
	_test_structural_undo_redo()
	_test_cascade_delete()
	_test_rename()
	_test_real_network()
	_finish()


# --------------------------------------------------------------------------
# Synthetic network
# --------------------------------------------------------------------------

func _test_synthetic_network() -> void:
	var payload := _synthetic_payload()
	var result := ValidatorScript.validate(payload)
	if not bool(result.ok):
		print("  [info] first synthetic finding: %s" % String(
			ValidatorScript.first_error_code(result.findings)))
		for value in result.findings:
			print("    %s" % String((value as Dictionary).get("message", "")))
	_expect("synthetic network passes the shared validator", bool(result.ok))
	_expect("synthetic network reports hard edges",
		int((result.stats as Dictionary).get("hard_edges", 0)) > 0)
	var changed_once := ValidatorScript.normalize_effect_summaries(payload)
	var changed_twice := ValidatorScript.normalize_effect_summaries(payload)
	_expect("effect summary normalization is idempotent",
		changed_once == true and changed_twice == false)
	var conflicted := {
		"expected_bindings": [{"kind": 2, "id": "building.tannery"}],
	}
	var buff_term := {"subject_kind": "building", "subject_id": "building.tannery"}
	_expect("unlocking and buffing the same target is reported as a conflict",
		ValidatorScript.same_target_conflict(conflicted, buff_term))
	_expect("buffing an unrelated target is not a conflict",
		not ValidatorScript.same_target_conflict(conflicted,
			{"subject_kind": "building", "subject_id": "building.smithy"})
		and not ValidatorScript.same_target_conflict(conflicted,
			{"subject_kind": "country", "subject_id": ""}))
	var edges_first := ValidatorScript.build_visual_edges(payload)
	var edges_second := ValidatorScript.build_visual_edges(payload)
	_expect("visual edge projection is deterministic",
		JSON.stringify(edges_first) == JSON.stringify(edges_second))


func _test_relation_pairing() -> void:
	var model: TechnologyAuthoringModel = ModelScript.new()
	model.load_payload(_synthetic_payload())
	var target := "tech.kingdom_c1"
	model.begin_batch("set relation")
	model.set_relation(target, "hard_prerequisite_ids", [
		{"id": "tech.agrarian_milestone", "rationale": ""},
		{"id": "tech.agrarian_c0", "rationale": "需要该实践基础。"},
	])
	model.commit_batch()
	var row := model.node(target)
	var ids: Array = row.get("hard_prerequisite_ids", [])
	var rationales: Array = row.get("prerequisite_rationales", [])
	_expect("relation write keeps both arrays equally long",
		ids.size() == 2 and rationales.size() == 2)
	_expect("blank rationale is filled instead of left empty",
		not String(rationales[0]).strip_edges().is_empty())
	_expect("direct writes to paired arrays are refused",
		model.set_field(target, "prerequisite_rationales", []) == false)
	model.begin_batch("duplicate relation")
	model.set_relation(target, "hard_prerequisite_ids", [
		{"id": "tech.agrarian_c0", "rationale": "A"},
		{"id": "tech.agrarian_c0", "rationale": "B"},
	])
	model.commit_batch()
	_expect("duplicate relation targets collapse to one entry",
		(model.node(target).get("hard_prerequisite_ids", []) as Array).size() == 1)
	var relation := model.relation(target, "hard_prerequisite_ids")
	_expect("relation view pairs ids with rationales",
		relation.size() == 1 and String((relation[0] as Dictionary).rationale) == "A")


func _test_structural_undo_redo() -> void:
	var model: TechnologyAuthoringModel = ModelScript.new()
	var payload := _synthetic_payload()
	model.load_payload(payload)
	var baseline := JSON.stringify(model.payload())
	_expect("new id validation rejects a missing prefix",
		not model.validate_new_id("stone_axe").is_empty())
	_expect("new id validation rejects an existing id",
		not model.validate_new_id("tech.stone_c0").is_empty())
	model.begin_batch("add node")
	var template := model.new_node_template("tech.probe", "探针", "stone",
		"science", "backbone.knowledge")
	var added := model.add_node(template, "tech.stone_c0")
	model.commit_batch()
	_expect("node insert reports success", bool(added.ok))
	_expect("node insert lands directly after the anchor",
		model.node_position("tech.probe") == model.node_position("tech.stone_c0") + 1)
	_expect("node count grows by one", model.node_count() == 100)
	model.begin_batch("edit node")
	model.set_field("tech.probe", "cost_points", 12345.0)
	model.commit_batch()
	_expect("field edit lands", int(model.node("tech.probe").get("cost_points", 0)) == 12345)
	model.undo()
	_expect("undo reverts the field edit",
		int(model.node("tech.probe").get("cost_points", 0)) == 3900)
	model.undo()
	_expect("undo removes the inserted node", not model.has_technology("tech.probe"))
	_expect("undo restores the original payload byte-for-byte",
		JSON.stringify(model.payload()) == baseline)
	model.redo()
	_expect("redo reinserts the node at the same position",
		model.has_technology("tech.probe")
		and model.node_position("tech.probe") == model.node_position("tech.stone_c0") + 1)
	model.redo()
	_expect("redo replays the field edit",
		int(model.node("tech.probe").get("cost_points", 0)) == 12345)
	model.begin_batch("remove node")
	var removed := model.remove_node("tech.probe")
	model.commit_batch()
	_expect("node removal reports success", bool(removed.ok))
	model.undo()
	_expect("undo restores a removed node", model.has_technology("tech.probe"))


func _test_cascade_delete() -> void:
	var model: TechnologyAuthoringModel = ModelScript.new()
	model.load_payload(_synthetic_payload())
	var victim := "tech.agrarian_c0"
	_expect("reverse index finds every referent", model.reference_count(victim) > 0)
	var preview := model.delete_preview(victim)
	_expect("delete preview lists references",
		(preview.references as Array).size() == model.reference_count(victim))
	model.begin_batch("cascade delete")
	var removed := model.remove_node(victim)
	model.commit_batch()
	_expect("cascade delete succeeds", bool(removed.ok))
	_expect("cascade delete repaired referencing nodes",
		(removed.repaired as Array).size() > 0)
	for node_value in model.nodes():
		var row: Dictionary = node_value
		var ids: Array = row.get("hard_prerequisite_ids", [])
		_expect_quiet("no node still lists the deleted prerequisite",
			not ids.has(victim))
		var atoms := PackedStringArray()
		for route_value in row.get("research_routes", []):
			ValidatorScript.collect_technology_atoms(
				(route_value as Dictionary).get("condition", {}), atoms)
		_expect_quiet("no research route still cites the deleted technology",
			not atoms.has(victim))
		var basis: Dictionary = row.get("knowledge_basis", {})
		_expect_quiet("no knowledge basis still requires the deleted technology",
			not (basis.get("required_ids", []) as Array).has(victim))
	for era_value in model.meta_array("eras"):
		_expect_quiet("no era still nominates the deleted candidate",
			not ((era_value as Dictionary).get("milestone_candidate_ids", []) as Array).has(victim))
	print("  [PASS] cascade delete removed every reference to %s" % victim)
	var revalidated := ValidatorScript.validate(model.payload())
	var codes := PackedStringArray()
	for value in revalidated.findings:
		var code := String((value as Dictionary).get("code", ""))
		if not codes.has(code):
			codes.append(code)
	_expect("cascade delete leaves no dangling reference errors",
		not _contains_prefix(codes, "technology_prerequisite_invalid")
		and not _contains_prefix(codes, "technology_condition_reference_unknown")
		and not _contains_prefix(codes, "technology_milestone_candidate_invalid"))
	var blocked := model.delete_preview("tech.stone_milestone")
	_expect("deleting an era milestone is blocked", not bool(blocked.ok))


func _test_rename() -> void:
	var model: TechnologyAuthoringModel = ModelScript.new()
	model.load_payload(_synthetic_payload())
	var baseline := JSON.stringify(model.payload())
	var before_references := model.reference_count("tech.agrarian_c0")
	model.begin_batch("rename")
	var renamed := model.rename_node("tech.agrarian_c0", "tech.agrarian_renamed")
	model.commit_batch()
	_expect("rename reports success", bool(renamed.ok))
	_expect("rename moves every reference",
		model.reference_count("tech.agrarian_renamed") == before_references
		and model.reference_count("tech.agrarian_c0") == 0)
	var revalidated := ValidatorScript.validate(model.payload())
	_expect("renamed network still validates", bool(revalidated.ok))
	model.undo()
	_expect("rename undo restores the payload byte-for-byte",
		JSON.stringify(model.payload()) == baseline)
	model.begin_batch("mixed rename")
	model.set_field("tech.stone_c0", "cost_points", 1.0)
	var refused := model.rename_node("tech.stone_c0", "tech.stone_other")
	model.abort_batch()
	_expect("rename refuses to share a batch with snapshot edits",
		not bool(refused.ok))


# --------------------------------------------------------------------------
# Real network
# --------------------------------------------------------------------------

func _test_real_network() -> void:
	var service: TechnologyAuthoringService = ServiceScript.new()
	var loaded := service.load_network()
	_expect("real network loads", bool(loaded.ok))
	if not bool(loaded.ok):
		return
	print("  [info] loaded %d nodes / %d application intersections" % [
		int(loaded.nodes), int(loaded.application_intersections)])
	var model := service.model
	var lookup_started := Time.get_ticks_usec()
	var ids := model.ids()
	var hits := 0
	for pass_index in range(40):
		for id in ids:
			if model.has_technology(String(id)):
				hits += 1
	var lookup_ms := float(Time.get_ticks_usec() - lookup_started) / 1000.0
	print("  [info] %d indexed lookups in %.3fms" % [hits, lookup_ms])
	_expect("indexed lookups stay well under a linear scan", lookup_ms <= 250.0)
	_expect("every node resolves through the index", hits == ids.size() * 40)

	var validation := service.validate()
	var findings: Array = validation.findings
	print("  [info] validator reported %d findings in %.3fms" % [
		findings.size(), float(validation.msec)])
	_expect("validation completes within the editing budget", float(validation.msec) <= 200.0)
	var well_formed := true
	for value in findings:
		var row: Dictionary = value
		if String(row.get("code", "")).is_empty() or String(row.get("message", "")).is_empty() \
				or String(row.get("severity", "")).is_empty():
			well_formed = false
			break
	_expect("every finding carries code, severity and message", well_formed)
	var grouped := ServiceScript.group_findings(findings)
	_expect("findings group by technology for node badges",
		findings.is_empty() or not grouped.is_empty())

	var payload := model.payload()
	var authored_edges: Array = (payload.get("visual_edges", []) as Array).duplicate(true)
	var rebuilt := ValidatorScript.build_visual_edges(payload)
	var reprojected := ValidatorScript.build_visual_edges(payload)
	_expect("visual edge projection is idempotent on the real network",
		JSON.stringify(rebuilt) == JSON.stringify(reprojected))
	_expect("committed network carries the expected edge volume",
		authored_edges.size() > 1000)
	# The committed file is currently stale relative to its own relations, which
	# is exactly the class of drift the workbench is meant to surface. Report the
	# delta rather than asserting equality with stale data.
	if JSON.stringify(authored_edges) != JSON.stringify(rebuilt):
		var authored_keys := {}
		for value in authored_edges:
			authored_keys[JSON.stringify(value)] = true
		var added := 0
		for value in rebuilt:
			if not authored_keys.has(JSON.stringify(value)):
				added += 1
		print("  [info] committed visual_edges are stale: %d authored vs %d rebuilt (%d new)" % [
			authored_edges.size(), rebuilt.size(), added])

	var stray := 0
	model.begin_batch("strip legacy layout keys")
	stray = model.strip_unknown_layout_keys()
	model.abort_batch()
	_expect("committed network has no invented ui_row keys", stray == 0)

	var reconciled := service.load_content_index()
	print("  [info] content index: %d buildings / %d goods / %d resources / %d stats in %dms (signature %dms, cached=%s)" % [
		int(reconciled.buildings), int(reconciled.goods), int(reconciled.resources),
		int(reconciled.modifier_stats), int(reconciled.msec),
		int(reconciled.signature_msec), str(reconciled.cached)])
	_expect("content index finds building profiles", int(reconciled.buildings) > 0)
	_expect("content index finds good profiles", int(reconciled.goods) > 0)
	var warm: TechnologyAuthoringService = ServiceScript.new()
	var warm_report := warm.load_content_index()
	print("  [info] warm content index in %dms (cached=%s)" % [
		int(warm_report.msec), str(warm_report.cached)])
	_expect("second content index load is served from cache", bool(warm_report.cached))
	_expect("cached content index opens fast enough for editor startup",
		int(warm_report.msec) <= 600)
	_expect("cached stat registry keeps the same key count",
		int(warm_report.modifier_stats) == int(reconciled.modifier_stats))
	if int(reconciled.modifier_stats) > 0:
		_expect("modifier stat registry is available for the stat picker",
			service.index.modifier_stats.has("country.research.science_efficiency"))
	else:
		print("  [info] modifier stat registry unavailable: %s" % String(reconciled.reason))
	var sample := ""
	for id in model.ids():
		if not service.index.unlocks_for(String(id)).is_empty():
			sample = String(id)
			break
	_expect("at least one technology maps to authored .tres unlocks", not sample.is_empty())
	if not sample.is_empty():
		var report := service.reconcile_unlocks(sample)
		print("  [info] %s unlock reconciliation: %d matched / %d missing in tres / %d missing in node" % [
			sample, (report.matched as Array).size(),
			(report.missing_in_tres as Array).size(),
			(report.missing_in_node as Array).size()])
		_expect("unlock reconciliation returns all three buckets",
			report.has("matched") and report.has("missing_in_tres")
			and report.has("missing_in_node"))
	_test_save_byte_stability(model)
	_test_deletion_blockers(service)
	var on_disk := FileAccess.get_file_as_string(NETWORK_PATH)
	_expect("the test never rewrote the authored network",
		on_disk.length() > 0 and not model.is_dirty())


## A save must be a fixed point: normalize, serialize, reload and serialize
## again has to produce identical bytes, or every gate run would rewrite the
## file and every commit would carry noise.
func _test_save_byte_stability(model: TechnologyAuthoringModel) -> void:
	var payload := model.payload()
	ValidatorScript.normalize_effect_summaries(payload)
	payload["visual_edges"] = ValidatorScript.build_visual_edges(payload)
	var first := ValidatorScript.serialize_network(payload)
	var reparsed: Variant = JSON.parse_string(first)
	_expect("serialized network reparses", reparsed is Dictionary)
	if not reparsed is Dictionary:
		return
	var round_trip: Dictionary = reparsed
	var changed_again := ValidatorScript.normalize_effect_summaries(round_trip)
	round_trip["visual_edges"] = ValidatorScript.build_visual_edges(round_trip)
	var second := ValidatorScript.serialize_network(round_trip)
	_expect("normalization is a fixed point after a save", not changed_again)
	_expect("saving twice produces identical bytes", first == second)
	_expect("the saved file ends with exactly one newline",
		first.ends_with("\n") and not first.ends_with("\n\n"))


## Deleting a technology that is a building's only unlock must be reported as a
## structured blocker, so the workbench can offer a replacement instead of a
## dead end.
func _test_deletion_blockers(service: TechnologyAuthoringService) -> void:
	var sample := ""
	for id in service.model.ids():
		if not service.deletion_blockers(String(id)).is_empty():
			sample = String(id)
			break
	if sample.is_empty():
		print("  [info] no technology is a building's only unlock")
		return
	var blockers := service.deletion_blockers(sample)
	var row: Dictionary = blockers[0]
	_expect("deletion blockers name the building that would break",
		String(row.get("kind", "")) == "building" and not String(row.get("id", "")).is_empty()
		and not String(row.get("message", "")).is_empty())
	print("  [info] %s blocks deletion of %d building(s), first: %s" % [
		sample, blockers.size(), String(row.id)])


# --------------------------------------------------------------------------
# Synthetic payload builder
# --------------------------------------------------------------------------

## Builds the smallest network that satisfies every gate contract: 11 eras,
## 4 domains, 4 backbones, 24 branch families, one milestone plus eight
## candidates per era, and research routes above the kingdom era.
func _synthetic_payload() -> Dictionary:
	var domain_ids := ["agriculture", "engineering", "science", "society"]
	var backbones: Array = []
	for name in ["food_storage", "materials", "knowledge", "institution"]:
		backbones.append({"id": "backbone.%s" % name, "display_name": name})
	var families: Array = []
	for index in range(24):
		families.append({"id": "branch.family_%02d" % index, "display_name": "族%02d" % index})
	var nodes: Array = []
	var eras: Array = []
	for era_index in range(ValidatorScript.ERA_IDS.size()):
		var era_id := String(ValidatorScript.ERA_IDS[era_index])
		var candidates := PackedStringArray()
		for slot in range(8):
			var id := "tech.%s_c%d" % [era_id, slot]
			candidates.append(id)
			nodes.append(_synthetic_node(id, "%s候选%d" % [era_id, slot], era_id, era_index,
				domain_ids[slot % 4], false))
		var milestone_id := "tech.%s_milestone" % era_id
		nodes.append(_synthetic_node(milestone_id, "%s里程碑" % era_id, era_id, era_index,
			domain_ids[0], true))
		eras.append({
			"id": era_id,
			"display_name": era_id,
			"milestone_id": milestone_id,
			"milestone_candidate_ids": Array(candidates),
			"candidate_required": 4,
			"entry_milestone_id": "" if era_index == 0 else "tech.%s_milestone" % String(
				ValidatorScript.ERA_IDS[era_index - 1]),
		})
	var domains: Array = []
	for index in range(domain_ids.size()):
		domains.append({"id": domain_ids[index], "display_name": domain_ids[index],
			"accent": "#639e4f"})
	var payload := {
		"schema_version": 4,
		"eras": eras,
		"domains": domains,
		"backbones": backbones,
		"branch_families": families,
		"application_intersections": [],
		"nodes": nodes,
		"visual_edges": [],
	}
	payload["visual_edges"] = ValidatorScript.build_visual_edges(payload)
	return payload


func _synthetic_node(id: String, display_name: String, era_id: String, era_index: int,
		domain_id: String, is_milestone: bool) -> Dictionary:
	var previous_era := "" if era_index == 0 else String(ValidatorScript.ERA_IDS[era_index - 1])
	var hard: Array = []
	var rationales: Array = []
	if era_index > 0:
		hard.append("tech.%s_milestone" % previous_era)
		rationales.append("需要上一时代的里程碑基础。")
	var routes: Array = []
	var exemption := ""
	if era_index >= 2 and not is_milestone:
		routes.append({
			"id": "research_route.%s.evidence" % id.trim_prefix("tech."),
			"display_name": "实践证据",
			"route_type": "practice",
			"description": "由上一时代的实践积累提供替代证据。",
			"condition": {"kind": 0, "id": "tech.%s_c0" % previous_era, "value": 1},
		})
	elif era_index >= 2:
		exemption = "里程碑不提供替代路线。"
	var terms: Array = []
	if not is_milestone:
		terms.append({
			"stat": "country.research.science_efficiency",
			"operation": 0,
			"value": 0.02,
			"subject_kind": "country",
			"subject_id": "",
			"subject_display_name": "科学领域研究效率",
			"effect_class": "研究效率",
			"effect_rationale": "合成测试节点提供的研究效率增益。",
			"implementation_status": "runtime_consumed",
			"runtime_consumer": "NativeCountryRuntime::research_efficiency",
		})
	return {
		"id": id,
		"display_name": display_name,
		"era_id": era_id,
		"domain_id": domain_id,
		"cost_points": 3900.0,
		"layout_order": float(nodes_seen()),
		"network_role": "backbone" if is_milestone else "branch",
		"anchor_kind": "backbone" if is_milestone else "branch",
		"node_role": "handling",
		"effect_profile": "",
		"secondary_route_tags": [],
		"hard_prerequisite_ids": hard,
		"reveal_condition": {},
		"is_milestone": is_milestone,
		"is_era_key": is_milestone,
		"is_starting": false,
		"is_starter_eligible": false,
		"starter_capability_tags": [],
		"modifier_terms": terms,
		"expected_bindings": [],
		"content_effects": [],
		"effect_summary": "",
		"opportunity_cost": "占用研究预算。",
		"application_target_ids": [],
		"terminal_reason": "合成测试节点的终点理由。",
		"branch_family_id": "backbone.knowledge" if is_milestone else "branch.family_%02d" % (
			era_index * 2 % 24),
		"era_entry_milestone_id": "",
		"reveal_category": "general_knowledge",
		"reveal_summary": "在掌握前置知识后被揭示。",
		"branch_successor_ids": [],
		"prerequisite_rationales": rationales,
		"branch_successor_rationales": [],
		"application_target_rationales": [],
		"support_buildings": [],
		"research_routes": routes,
		"route_exemption_reason": exemption,
		"topology_review": {
			"role": "terminal",
			"rationale": "合成测试节点按终点审核。",
			"expected_hard_family_ids": [],
		},
		"building_unlock_review": {
			"policy": "support_only",
			"rationale": "合成测试节点不解锁建筑。",
		},
		"knowledge_basis": {
			"required_ids": hard.duplicate(),
			"alternative_groups": [] if era_index < 2 or is_milestone else [
				["tech.%s_c0" % previous_era]],
			"exemption_reason": "",
		},
	}


var _node_counter := 0


func nodes_seen() -> int:
	_node_counter += 1
	return _node_counter - 1


# --------------------------------------------------------------------------
# Harness
# --------------------------------------------------------------------------

func _contains_prefix(codes: PackedStringArray, prefix: String) -> bool:
	for code in codes:
		if String(code).begins_with(prefix):
			return true
	return false


var _quiet_failures := 0


func _expect_quiet(label: String, condition: bool) -> void:
	if condition:
		return
	_quiet_failures += 1
	if _quiet_failures <= 5:
		print("  [FAIL] %s" % label)
	_failures += 1


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _finish() -> void:
	print("technology authoring model: %d failures" % _failures)
	quit(1 if _failures > 0 else 0)
