extends RefCounted

## Validates and compiles construction and production technology dependencies.


static func _compile_building_dependency_columns(buildings: Dictionary,
		goods: Dictionary, resource_ids: PackedStringArray,
		resource_tag_offsets: PackedInt32Array, resource_tags: PackedStringArray,
		technology_set: Dictionary, technology_index: Dictionary) -> Dictionary:
	var building_ids: PackedStringArray = buildings.building_type_ids
	var direct_offsets: PackedInt32Array = buildings.building_technology_tag_offsets
	var direct_tags: PackedStringArray = buildings.building_technology_tags
	var required_offsets: PackedInt32Array = \
		buildings.building_required_technology_tag_offsets
	var required_tags: PackedStringArray = buildings.building_required_technology_tags
	var dependency_branch_offsets := PackedInt32Array([0])
	var dependency_branch_technology_offsets := PackedInt32Array([0])
	var dependency_branch_technologies := PackedInt32Array()
	var dependency_branch_group_offsets := PackedInt32Array([0])
	var dependency_kinds := PackedByteArray()
	var dependency_ids := PackedInt32Array()
	var dependency_tag_offsets := PackedInt32Array([0])
	var dependency_tags := PackedInt32Array()
	var good_ids: PackedStringArray = goods.good_ids
	var good_tag_offsets: PackedInt32Array = goods.good_technology_tag_offsets
	var good_technology_tags: PackedStringArray = goods.good_technology_tags
	var construction_offsets: PackedInt32Array = buildings.building_construction_offsets
	var construction_goods: PackedInt32Array = buildings.building_construction_good_ids
	var construction_candidate_offsets: PackedInt32Array = buildings.get(
		"building_construction_candidate_offsets", PackedInt32Array())
	var construction_candidate_goods: PackedInt32Array = buildings.get(
		"building_construction_candidate_good_ids", PackedInt32Array())
	var input_offsets: PackedInt32Array = buildings.building_input_offsets
	var input_goods: PackedInt32Array = buildings.building_input_good_ids
	var input_required: PackedInt32Array = buildings.building_input_required_q16
	var input_candidate_offsets: PackedInt32Array = buildings.building_input_candidate_offsets
	var input_candidate_goods: PackedInt32Array = buildings.building_input_candidate_good_ids
	var output_offsets: PackedInt32Array = buildings.building_output_offsets
	var output_goods: PackedInt32Array = buildings.building_output_good_ids
	var resource_offsets: PackedInt32Array = buildings.building_resource_offsets
	var production_resources: PackedInt32Array = buildings.building_production_resource_ids
	var generation_offsets: PackedInt32Array = buildings.building_resource_generation_offsets
	var generation_resources: PackedInt32Array = buildings.building_resource_generation_ids
	var resource_index := {}
	for resource_index_value in range(resource_ids.size()):
		resource_index[String(resource_ids[resource_index_value])] = resource_index_value
	var append_tags := func(raw_tags: Array, building_id: String,
			dependency_kind: int, dependency_id: int) -> Dictionary:
		var seen := {}
		for raw_tag in raw_tags:
			var tag := String(raw_tag).strip_edges()
			if not tag.begins_with("tech.") or seen.has(tag):
				continue
			seen[tag] = true
			if not technology_set.has(tag):
				return {"ok": false, "reason": "unknown_building_dependency_technology",
					"building_id": building_id, "dependency_kind": dependency_kind,
					"dependency_id": dependency_id, "tag": tag}
			dependency_tags.append(int(technology_index[tag]))
		if seen.is_empty():
			return {"ok": false, "reason": "building_dependency_technology_missing",
				"building_id": building_id, "dependency_kind": dependency_kind,
				"dependency_id": dependency_id}
		dependency_tag_offsets.append(dependency_tags.size())
		return {"ok": true}
	var append_good_group := func(building_id: String, dependency_kind: int,
			good_id: int, candidate_ids: Array = []) -> Dictionary:
		var acceptable := []
		var ids_to_scan := candidate_ids if not candidate_ids.is_empty() else [good_id]
		for candidate_id in ids_to_scan:
			var candidate := int(candidate_id)
			if candidate < 0 or candidate >= good_ids.size():
				return {"ok": false, "reason": "building_dependency_good_invalid",
					"building_id": building_id, "dependency_id": candidate}
			for tag_index in range(good_tag_offsets[candidate], good_tag_offsets[candidate + 1]):
				acceptable.append(String(good_technology_tags[tag_index]))
		dependency_kinds.append(dependency_kind)
		dependency_ids.append(good_id)
		return append_tags.call(acceptable, building_id, dependency_kind, good_id)
	var append_resource_group := func(building_id: String, dependency_kind: int,
			resource_id: int) -> Dictionary:
		if resource_id < 0 or resource_id >= resource_ids.size():
			return {"ok": false, "reason": "building_dependency_resource_invalid",
				"building_id": building_id, "dependency_id": resource_id}
		var acceptable := []
		for tag_index in range(resource_tag_offsets[resource_id], resource_tag_offsets[resource_id + 1]):
			acceptable.append(String(resource_tags[tag_index]))
		dependency_kinds.append(dependency_kind)
		dependency_ids.append(resource_id)
		return append_tags.call(acceptable, building_id, dependency_kind, resource_id)
	for building_index in range(building_ids.size()):
		var building_id := String(building_ids[building_index])
		var building_branch_count := 0
		for direct_index in range(direct_offsets[building_index], direct_offsets[building_index + 1]):
			var direct_tag := String(direct_tags[direct_index]).strip_edges()
			if not direct_tag.begins_with("tech."):
				continue
			dependency_branch_technologies.append(int(technology_index[direct_tag]))
			for required_index in range(required_offsets[building_index], required_offsets[building_index + 1]):
				var required_tag := String(required_tags[required_index]).strip_edges()
				dependency_branch_technologies.append(int(technology_index[required_tag]))
			dependency_branch_technology_offsets.append(dependency_branch_technologies.size())
			building_branch_count += 1
			for edge in range(construction_offsets[building_index], construction_offsets[building_index + 1]):
				var candidates := []
				if edge + 1 < construction_candidate_offsets.size():
					for candidate_edge in range(construction_candidate_offsets[edge],
							construction_candidate_offsets[edge + 1]):
						candidates.append(int(construction_candidate_goods[candidate_edge]))
				var result: Dictionary = append_good_group.call(building_id, 1,
					int(construction_goods[edge]), candidates)
				if not bool(result.get("ok", false)):
					return result
			for edge in range(input_offsets[building_index], input_offsets[building_index + 1]):
				# Soft complements are demand sinks, not operational prerequisites.
				# Compiling them into the technology dependency CSR would make an
				# optional recipe input a hidden hard unlock gate.
				if int(input_required[edge]) < 65536:
					continue
				var candidates := []
				if edge + 1 < input_candidate_offsets.size():
					for candidate_edge in range(input_candidate_offsets[edge], input_candidate_offsets[edge + 1]):
						candidates.append(int(input_candidate_goods[candidate_edge]))
				var result: Dictionary = append_good_group.call(building_id, 2,
					int(input_goods[edge]), candidates)
				if not bool(result.get("ok", false)):
					return result
			for edge in range(output_offsets[building_index], output_offsets[building_index + 1]):
				var result: Dictionary = append_good_group.call(building_id, 3,
					int(output_goods[edge]))
				if not bool(result.get("ok", false)):
					return result
			for edge in range(resource_offsets[building_index], resource_offsets[building_index + 1]):
				var result: Dictionary = append_resource_group.call(building_id, 4,
					int(production_resources[edge]))
				if not bool(result.get("ok", false)):
					return result
			for edge in range(generation_offsets[building_index], generation_offsets[building_index + 1]):
				var result: Dictionary = append_resource_group.call(building_id, 5,
					int(generation_resources[edge]))
				if not bool(result.get("ok", false)):
					return result
			dependency_branch_group_offsets.append(dependency_kinds.size())
		dependency_branch_offsets.append(
			dependency_branch_offsets[-1] + building_branch_count)
		if building_branch_count == 0:
			return {"ok": false, "reason": "building_technology_binding_missing",
				"id": building_id}
	return {"ok": true,
		"building_dependency_branch_offsets": dependency_branch_offsets,
		"building_dependency_branch_technologies": dependency_branch_technologies,
		"building_dependency_branch_technology_offsets": dependency_branch_technology_offsets,
		"building_dependency_branch_group_offsets": dependency_branch_group_offsets,
		"building_dependency_kinds": dependency_kinds,
		"building_dependency_ids": dependency_ids,
		"building_dependency_tag_offsets": dependency_tag_offsets,
		"building_dependency_tags": dependency_tags}

## Construction BOM rows are authoring weights, not independent hard slots.
## Compile every building to one effective-quantity group whose candidates are
## the stable union of every authored row. Any mixture can therefore satisfy
## the total bill, matching household food-basket substitution semantics.
			# A material admitted through several authored roles keeps its most
			# efficient valid conversion into generic construction quantity.


## Zero-bill lots: merchant-style services, or stone-age construction
## collectors tagged `starter.construction` whose daily inputs are empty or
## all-soft complements. Industrial buildings and later collectors still need
## an explicit bill.
