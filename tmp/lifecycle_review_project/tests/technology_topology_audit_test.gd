extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const NETWORK_PATH := "res://data/technology/technology_network.json"
const TOPOLOGY_ROLES := ["origin", "continuation", "convergence", "branch", "terminal"]
const BUILDING_POLICIES := ["single", "paired", "shared", "support_only", "none"]
const SUPPORT_ONLY_DIRECT_BINDING_EXCEPTIONS := [
	"tech.crop_domestication", "tech.potato_propagation",
	"tech.wild_cotton_collection", "tech.tin_identification",
]


func _init() -> void:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	assert(file != null, "technology network is readable")
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	assert(parsed is Dictionary, "technology network is JSON object")
	var payload: Dictionary = parsed
	var nodes: Array = payload.get("nodes", [])
	assert(nodes.size() >= 361)
	var node_by_id := {}
	var family_ids := {}
	for family_value in payload.get("backbones", []) + payload.get("branch_families", []):
		var family: Dictionary = family_value
		family_ids[String(family.get("id", ""))] = true
	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.get("id", ""))
		assert(id.begins_with("tech.") and not node_by_id.has(id), id)
		node_by_id[id] = node

	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	assert(bool(catalog.get("ok", false)), str(catalog))
	var technology_ids: PackedStringArray = catalog.technology_ids
	var direct_building_counts := {}
	var building_ids: PackedStringArray = catalog.building_type_ids
	var building_offsets: PackedInt32Array = catalog.building_technology_tag_offsets
	var building_tags: PackedStringArray = catalog.building_technology_tags
	for building_index in range(building_ids.size()):
		for edge in range(building_offsets[building_index], building_offsets[building_index + 1]):
			var technology_id := String(building_tags[edge])
			if technology_id.begins_with("tech."):
				direct_building_counts[technology_id] = int(
					direct_building_counts.get(technology_id, 0)) + 1

	var missing_topology := 0
	var reviewed_topology := 0
	var missing_building_review := 0
	var over_limit := 0
	var authored_branch_edges := 0
	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.id)
		var topology: Dictionary = node.get("topology_review", {})
		if topology.is_empty():
			missing_topology += 1
		else:
			reviewed_topology += 1
			assert(TOPOLOGY_ROLES.has(String(topology.get("role", ""))), id)
			assert(not String(topology.get("rationale", "")).strip_edges().is_empty(), id)
			var expected_families: Array = topology.get("expected_hard_family_ids", [])
			assert(expected_families is Array, id)
			for family_id in expected_families:
				assert(family_ids.has(String(family_id)), "%s -> %s" % [id, family_id])
			if String(topology.get("role", "")) == "convergence":
				assert(not expected_families.is_empty(), id)

		var branch_ids: Array = node.get("branch_successor_ids", [])
		var branch_rationales: Array = node.get("branch_successor_rationales", [])
		assert(branch_ids.size() == branch_rationales.size(), id)
		for branch_id in branch_ids:
			assert(node_by_id.has(String(branch_id)), "%s -> %s" % [id, branch_id])
			authored_branch_edges += 1

		var building_count := int(direct_building_counts.get(id, 0))
		var building_review: Dictionary = node.get("building_unlock_review", {})
		if building_count > 2:
			over_limit += 1
		if building_count > 0 and building_review.is_empty():
			missing_building_review += 1
		if not building_review.is_empty():
			var policy := String(building_review.get("policy", ""))
			assert(BUILDING_POLICIES.has(policy), id)
			assert(not String(building_review.get("rationale", "")).strip_edges().is_empty(), id)
			if policy == "support_only":
				assert(building_count == 0 or SUPPORT_ONLY_DIRECT_BINDING_EXCEPTIONS.has(id),
					"%s support_only has direct bindings" % id)

	# The catalog has already validated all stable technology references. This
	# extra check keeps the test useful if a hand-edited branch bypasses the
	# compiler's visual-edge normalization.
	var visual_branch_edges := 0
	for edge_value in payload.get("visual_edges", []):
		var edge: Dictionary = edge_value
		if String(edge.get("kind", "")) != "branch":
			continue
		visual_branch_edges += 1
		var source: Dictionary = node_by_id.get(String(edge.get("from", "")), {})
		assert((source.get("branch_successor_ids", []) as Array).has(String(edge.get("to", ""))))
	assert(visual_branch_edges == authored_branch_edges)

	# Upgrade tiers are runtime content, not technology edges. Keep the tier
	# sequence positive and unique inside every family while the topology review
	# warning remains non-blocking until a content wave is promoted.
	var family_tiers := {}
	var family_indices: PackedInt32Array = catalog.building_upgrade_family_indices
	var family_names: PackedStringArray = catalog.building_upgrade_family_ids
	var tiers: PackedInt32Array = catalog.building_upgrade_tiers
	for building_index in range(building_ids.size()):
		var family_index := int(family_indices[building_index])
		if family_index < 0:
			continue
		var family_name := String(family_names[family_index])
		var tier := int(tiers[building_index])
		assert(tier > 0, "%s tier=%d" % [family_name, tier])
		var seen: Dictionary = family_tiers.get(family_name, {})
		assert(not seen.has(tier), "%s duplicate tier %d" % [family_name, tier])
		seen[tier] = true
		family_tiers[family_name] = seen

	print("[PASS] technology topology audit test: %d nodes / %d branch edges / %d reviewed topology nodes" % [
		nodes.size(), visual_branch_edges, reviewed_topology])
	if missing_topology > 0 or missing_building_review > 0 or over_limit > 0:
		print("[WARN] governance wave pending: topology_review=%d, building_unlock_review=%d, over_limit=%d" % [
			missing_topology, missing_building_review, over_limit])
	quit(0)
