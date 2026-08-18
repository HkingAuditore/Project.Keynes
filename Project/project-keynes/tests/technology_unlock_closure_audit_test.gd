extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

const DEPENDENCY_KIND_NAMES := {
	1: "construction_good",
	2: "input_good",
	3: "output_good",
	4: "natural_resource",
	5: "generated_resource",
}


func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		push_error(str(catalog))
		quit(1)
		return
	var effective := OS.get_cmdline_user_args().has("--effective")
	var include_construction := OS.get_cmdline_user_args().has("--construction")
	var failures := audit(catalog, effective, include_construction)
	if OS.get_cmdline_user_args().has("--candidates"):
		_print_candidate_summary(catalog, failures)
		quit(0)
		return
	for failure in failures:
		push_error(JSON.stringify(failure))
	if not failures.is_empty():
		push_error("%d building unlock branches are not immediately usable (%s closure)" % [
			failures.size(), "effective" if effective else "direct"])
		quit(1)
		return
	print("[PASS] all %d building unlock branches satisfy their production closure" %
		int(catalog.building_dependency_branch_technologies.size()))
	quit(0)


static func _print_candidate_summary(catalog: Dictionary, failures: Array) -> void:
	var ids: PackedStringArray = catalog.technology_ids
	var prerequisite_offsets: PackedInt32Array = catalog.technology_prerequisite_offsets
	var prerequisites: PackedInt32Array = catalog.technology_prerequisites
	var era_ids: PackedStringArray = catalog.technology_era_ids
	var closures: Array = []
	closures.resize(ids.size())
	for technology in range(ids.size()):
		var closure := {technology: true}
		for edge in range(prerequisite_offsets[technology],
				prerequisite_offsets[technology + 1]):
			for ancestor in closures[int(prerequisites[edge])]:
				closure[ancestor] = true
		closures[technology] = closure
	var with_candidate := 0
	var without_candidate := 0
	for failure in failures:
		var required_ids := PackedStringArray(failure.missing_required)
		for dependency in failure.missing_dependencies:
			var alternatives: PackedStringArray = dependency.technology_alternatives
			if alternatives.size() == 1:
				required_ids.append(alternatives[0])
		var candidates := PackedStringArray()
		for technology in range(ids.size()):
			var closure: Dictionary = closures[technology]
			var covers := true
			for required_id in required_ids:
				if not closure.has(ids.find(required_id)):
					covers = false
					break
			if not covers:
				continue
			for dependency in failure.missing_dependencies:
				var dependency_covered := false
				for alternative_id in dependency.technology_alternatives:
					if closure.has(ids.find(alternative_id)):
						dependency_covered = true
						break
				if not dependency_covered:
					covers = false
					break
			if covers:
				candidates.append(String(ids[technology]))
		if candidates.is_empty():
			without_candidate += 1
			print(JSON.stringify({"building": failure.building,
				"technology": failure.technology, "candidate": ""}))
		else:
			with_candidate += 1
			var candidate_id := String(candidates[0])
			print(JSON.stringify({"building": failure.building,
				"technology": failure.technology, "candidate": candidate_id,
				"candidate_era": String(era_ids[ids.find(candidate_id)])}))
	print("CANDIDATES existing=%d missing=%d total=%d" % [
		with_candidate, without_candidate, failures.size()])


static func audit(catalog: Dictionary, effective: bool = false,
		include_construction: bool = false) -> Array:
	var technology_ids: PackedStringArray = catalog.technology_ids
	var prerequisite_offsets: PackedInt32Array = catalog.technology_prerequisite_offsets
	var prerequisites: PackedInt32Array = catalog.technology_prerequisites
	var building_ids: PackedStringArray = catalog.building_type_ids
	var building_branch_offsets: PackedInt32Array = catalog.building_dependency_branch_offsets
	var branch_technologies: PackedInt32Array = \
		catalog.building_dependency_branch_technologies
	var branch_technology_offsets: PackedInt32Array = \
		catalog.building_dependency_branch_technology_offsets
	var branch_group_offsets: PackedInt32Array = \
		catalog.building_dependency_branch_group_offsets
	var dependency_kinds: PackedByteArray = catalog.building_dependency_kinds
	var dependency_ids: PackedInt32Array = catalog.building_dependency_ids
	var dependency_tag_offsets: PackedInt32Array = catalog.building_dependency_tag_offsets
	var dependency_tags: PackedInt32Array = catalog.building_dependency_tags
	var good_ids: PackedStringArray = catalog.good_ids
	var resource_ids: PackedStringArray = catalog.building_resource_ids
	var closures: Array = []
	closures.resize(technology_ids.size())
	for technology in range(technology_ids.size()):
		var closure := {technology: true}
		for edge in range(prerequisite_offsets[technology],
				prerequisite_offsets[technology + 1]):
			for ancestor in closures[int(prerequisites[edge])]:
				closure[ancestor] = true
		closures[technology] = closure
	var failures := []
	for building in range(building_ids.size()):
		for branch in range(building_branch_offsets[building],
				building_branch_offsets[building + 1]):
			var technology_begin := branch_technology_offsets[branch]
			var direct_technology := int(branch_technologies[technology_begin])
			var closure: Dictionary = closures[direct_technology].duplicate()
			var missing_required := PackedStringArray()
			for edge in range(technology_begin + 1,
					branch_technology_offsets[branch + 1]):
				var required := int(branch_technologies[edge])
				if effective:
					for ancestor in closures[required]:
						closure[ancestor] = true
				elif not closure.has(required):
					missing_required.append(String(technology_ids[required]))
			var missing_dependencies := []
			for group in range(branch_group_offsets[branch],
					branch_group_offsets[branch + 1]):
				var satisfied := false
				var alternatives := PackedStringArray()
				for edge in range(dependency_tag_offsets[group],
						dependency_tag_offsets[group + 1]):
					var dependency_technology := int(dependency_tags[edge])
					alternatives.append(String(technology_ids[dependency_technology]))
					if closure.has(dependency_technology):
						satisfied = true
				if satisfied:
					continue
				var kind := int(dependency_kinds[group])
				if kind == 1 and not include_construction:
					continue
				var dependency_id := int(dependency_ids[group])
				var ids := resource_ids if kind in [4, 5] else good_ids
				missing_dependencies.append({
					"kind": DEPENDENCY_KIND_NAMES.get(kind, "unknown"),
					"id": String(ids[dependency_id]),
					"technology_alternatives": alternatives,
				})
			if not missing_required.is_empty() or not missing_dependencies.is_empty():
				failures.append({
					"building": String(building_ids[building]),
					"technology": String(technology_ids[direct_technology]),
					"missing_required": missing_required,
					"missing_dependencies": missing_dependencies,
				})
	return failures
