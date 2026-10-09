extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const BUILDING_DIR := "res://data/economy/buildings"
const GOOD_DIR := "res://data/goods"
const RESOURCE_DIR := "res://data/resources"


func _init() -> void:
	var catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		push_error(str(catalog))
		quit(1)
		return
	var building_paths := _resource_paths_by_id(BUILDING_DIR)
	var good_paths := _resource_paths_by_id(GOOD_DIR)
	var resource_paths := _resource_paths_by_id(RESOURCE_DIR)
	var technology_ids: PackedStringArray = catalog.technology_ids
	var prerequisite_offsets: PackedInt32Array = catalog.technology_prerequisite_offsets
	var prerequisites: PackedInt32Array = catalog.technology_prerequisites
	var closures: Array = []
	closures.resize(technology_ids.size())
	for technology in range(technology_ids.size()):
		var closure := {technology: true}
		for edge in range(prerequisite_offsets[technology], prerequisite_offsets[technology + 1]):
			for ancestor in closures[int(prerequisites[edge])]:
				closure[ancestor] = true
		closures[technology] = closure
	var building_ids: PackedStringArray = catalog.building_type_ids
	var building_branch_offsets: PackedInt32Array = catalog.building_dependency_branch_offsets
	var branch_technologies: PackedInt32Array = catalog.building_dependency_branch_technologies
	var branch_technology_offsets: PackedInt32Array = catalog.building_dependency_branch_technology_offsets
	var branch_group_offsets: PackedInt32Array = catalog.building_dependency_branch_group_offsets
	var dependency_kinds: PackedByteArray = catalog.building_dependency_kinds
	var dependency_ids: PackedInt32Array = catalog.building_dependency_ids
	var dependency_tag_offsets: PackedInt32Array = catalog.building_dependency_tag_offsets
	var dependency_tags: PackedInt32Array = catalog.building_dependency_tags
	var good_ids: PackedStringArray = catalog.good_ids
	var good_tag_offsets: PackedInt32Array = catalog.good_technology_tag_offsets
	var good_tags: PackedStringArray = catalog.good_technology_tags
	var resource_ids: PackedStringArray = catalog.building_resource_ids
	var touched_buildings := {}
	var touched_goods := {}
	var touched_resources := {}
	var repair_count := 0
	for building in range(building_ids.size()):
		var building_id := String(building_ids[building])
		var building_path := String(building_paths.get(building_id, ""))
		if building_path.is_empty():
			continue
		var profile: Resource = ResourceLoader.load(building_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		for branch in range(building_branch_offsets[building], building_branch_offsets[building + 1]):
			var gate_closure := {}
			var technology_begin := int(branch_technology_offsets[branch])
			var technology_end := int(branch_technology_offsets[branch + 1])
			var primary_technology := int(branch_technologies[technology_begin])
			for edge in range(technology_begin, technology_end):
				var gate_technology := int(branch_technologies[edge])
				if edge == technology_begin:
					for ancestor in closures[gate_technology]:
						gate_closure[ancestor] = true
				else:
					# Direct closure requires every support knowledge item to be
					# named explicitly. Effective closure may still consume its
					# hard ancestors at runtime.
					gate_closure[gate_technology] = true
			for group in range(branch_group_offsets[branch], branch_group_offsets[branch + 1]):
				var satisfied := false
				var alternatives := PackedInt32Array()
				for edge in range(dependency_tag_offsets[group], dependency_tag_offsets[group + 1]):
					var dependency_technology := int(dependency_tags[edge])
					alternatives.append(dependency_technology)
					if gate_closure.has(dependency_technology):
						satisfied = true
				if satisfied or alternatives.is_empty():
					continue
				var kind := int(dependency_kinds[group])
				var dependency_id_index := int(dependency_ids[group])
				if kind == 3:
					var good_id := String(good_ids[dependency_id_index])
					if _append_profile_technology(good_paths, good_id,
							String(technology_ids[primary_technology]), "technology_tags"):
						touched_goods[good_id] = true
						repair_count += 1
				elif kind == 5:
					var resource_id := String(resource_ids[dependency_id_index])
					if _append_profile_technology(resource_paths, resource_id,
							String(technology_ids[primary_technology]), "discovery_technology_tags"):
						touched_resources[resource_id] = true
						repair_count += 1
				else:
					var preferred := PackedInt32Array()
					if kind in [1, 2] and dependency_id_index >= 0 \
							and dependency_id_index + 1 < good_tag_offsets.size():
						for tag_edge in range(good_tag_offsets[dependency_id_index],
								good_tag_offsets[dependency_id_index + 1]):
							var tag_index := technology_ids.find(String(good_tags[tag_edge]))
							if tag_index >= 0 and alternatives.has(tag_index):
								preferred.append(tag_index)
					var selected := _earliest_technology(
						preferred if not preferred.is_empty() else alternatives, catalog)
					var selected_id := String(technology_ids[selected])
					if not profile.required_technology_tags.has(selected_id) \
							and not profile.technology_tags.has(selected_id):
						profile.required_technology_tags.append(selected_id)
						touched_buildings[building_id] = true
						repair_count += 1
		if touched_buildings.has(building_id):
			ResourceSaver.save(profile, building_path)
	print("[PASS] closure gate repairs=%d buildings=%d goods=%d resources=%d" % [
		repair_count, touched_buildings.size(), touched_goods.size(), touched_resources.size()])
	quit(0)


func _earliest_technology(alternatives: PackedInt32Array, catalog: Dictionary) -> int:
	var best := int(alternatives[0])
	for candidate_value in alternatives:
		var candidate := int(candidate_value)
		var candidate_era := int(catalog.technology_era_ids[candidate])
		var best_era := int(catalog.technology_era_ids[best])
		if candidate_era < best_era or (candidate_era == best_era \
				and String(catalog.technology_ids[candidate]) < String(catalog.technology_ids[best])):
			best = candidate
	return best


func _append_profile_technology(paths: Dictionary, id: String, technology_id: String,
		property_name: String) -> bool:
	var path := String(paths.get(id, ""))
	if path.is_empty():
		return false
	var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var tags: PackedStringArray = profile.get(property_name)
	if tags.has(technology_id):
		return false
	tags.append(technology_id)
	profile.set(property_name, tags)
	return ResourceSaver.save(profile, path) == OK


func _resource_paths_by_id(directory_path: String) -> Dictionary:
	var out := {}
	var directory := DirAccess.open(directory_path)
	if directory == null:
		return out
	for file_name in directory.get_files():
		if not file_name.ends_with(".tres"):
			continue
		var path := "%s/%s" % [directory_path, file_name]
		var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if profile != null:
			out[String(profile.id)] = path
	return out
