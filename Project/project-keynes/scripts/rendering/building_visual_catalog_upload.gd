extends RefCounted

## Prepares visual family catalog inputs for the settlement cache.

static func configure_catalog(layer: BuildingVisualLayer, catalog: Dictionary) -> Dictionary:
	var ids := PackedStringArray(catalog.get("building_type_ids", PackedStringArray()))
	var kinds := PackedInt32Array(catalog.get("building_kinds", PackedInt32Array()))
	var sectors := PackedInt32Array(catalog.get(
		"building_economic_sectors", PackedInt32Array()))
	var offsets := PackedInt32Array(catalog.get(
		"building_semantic_tag_offsets", PackedInt32Array()))
	var tags := PackedStringArray(catalog.get(
		"building_semantic_tags", PackedStringArray()))
	var table: BuildingVisualLayer.FamilyTableScript = BuildingVisualLayer.FamilyTableScript.load_default()
	layer._type_to_archetype.resize(ids.size())
	layer._type_to_family.resize(ids.size())
	layer._type_to_scale.resize(ids.size())
	layer._type_to_grade.resize(ids.size())
	var unresolved := PackedStringArray()
	if kinds.size() != ids.size() or sectors.size() != ids.size() \
			or offsets.size() != ids.size() + 1 or offsets.is_empty() \
			or offsets[0] != 0 or offsets[-1] != tags.size():
		layer._catalog_ready = false
		return {"ok": false, "reason": "building_visual_catalog_shape_invalid"}
	if table == null or table.family_ids() != PackedStringArray(BuildingVisualLayer.FAMILY_NAMES):
		layer._catalog_ready = false
		return {"ok": false, "reason": "building_visual_family_table_invalid"}
	var climate_idx := PackedInt32Array(catalog.get(
		"building_production_climate_profile_indices", PackedInt32Array()))
	var climate_ids := PackedStringArray(catalog.get(
		"production_climate_profile_ids", PackedStringArray()))
	var resource_offsets := PackedInt32Array(catalog.get(
		"building_resource_offsets", PackedInt32Array()))
	var resource_refs := PackedInt32Array(catalog.get(
		"building_production_resource_ids", PackedInt32Array()))
	var resource_names := PackedStringArray(catalog.get(
		"building_resource_ids", PackedStringArray()))
	var chains := PackedStringArray(catalog.get(
		"building_industry_chain_ids", PackedStringArray()))
	var output_offsets := PackedInt32Array(catalog.get(
		"building_output_offsets", PackedInt32Array()))
	var output_goods := PackedInt32Array(catalog.get(
		"building_output_good_ids", PackedInt32Array()))
	var good_names := PackedStringArray(catalog.get("good_ids", PackedStringArray()))
	var owner_slots := PackedInt64Array(catalog.get("building_owner_slots", PackedInt64Array()))
	var employee_offsets := PackedInt32Array(catalog.get(
		"building_employee_offsets", PackedInt32Array()))
	var employee_slots := PackedInt64Array(catalog.get(
		"building_employee_slots", PackedInt64Array()))
	var construction_offsets := PackedInt32Array(catalog.get(
		"building_construction_offsets", PackedInt32Array()))
	var construction_goods := PackedInt32Array(catalog.get(
		"building_construction_good_ids", PackedInt32Array()))
	var sector_names := ["agriculture", "extractive", "manufacturing", "energy", "knowledge", "service"]
	var sources := {}
	var family_counts := PackedInt32Array()
	family_counts.resize(BuildingVisualLayer.FAMILY_NAMES.size())
	family_counts.fill(0)
	for i in ids.size():
		var type_tags := tags.slice(offsets[i], offsets[i + 1])
		var climate := ""
		if i < climate_idx.size() and climate_idx[i] >= 0 and climate_idx[i] < climate_ids.size():
			climate = climate_ids[climate_idx[i]]
		var resources := PackedStringArray()
		if resource_offsets.size() == ids.size() + 1:
			for edge in range(resource_offsets[i], resource_offsets[i + 1]):
				var ref := resource_refs[edge] if edge < resource_refs.size() else -1
				if ref >= 0 and ref < resource_names.size():
					resources.append(resource_names[ref])
		var outputs := BuildingVisualLayer._csr_names(output_offsets, output_goods, good_names, i, ids.size())
		var sector: String = sector_names[sectors[i]] \
			if sectors[i] >= 0 and sectors[i] < sector_names.size() else ""
		var resolved := table.resolve(ids[i], sector, kinds[i], type_tags, climate,
			resources, chains[i] if i < chains.size() else "", outputs)
		var family := int(resolved.family)
		var source := String(resolved.source)
		if family < 0:
			# Unmatched types fall back to their sector's generic family.
			family = BuildingVisualLayer.FALLBACK_FAMILY_BY_ARCHETYPE[5 if kinds[i] == 2 else clampi(sectors[i], 0, 4)]
			source = "fallback"
		sources[source] = int(sources.get(source, 0)) + 1
		family_counts[family] += 1
		layer._type_to_family[i] = family
		layer._type_to_archetype[i] = table.archetype_of(family)
		var slots := int(owner_slots[i]) if i < owner_slots.size() else 1
		if employee_offsets.size() == ids.size() + 1:
			for edge in range(employee_offsets[i], employee_offsets[i + 1]):
				slots += int(employee_slots[edge]) if edge < employee_slots.size() else 0
		layer._type_to_scale[i] = clampi(roundi(8.0 * sqrt(float(maxi(1, slots)))), 8, 255)
		layer._type_to_grade[i] = table.grade_for(BuildingVisualLayer._csr_names(
			construction_offsets, construction_goods, good_names, i, ids.size()).slice(0, 1)) \
			if construction_offsets.size() == ids.size() + 1 else 255
		if layer._type_to_archetype[i] < 0 or layer._type_to_archetype[i] >= BuildingVisualLayer.ARCHETYPE_COUNT:
			unresolved.append(ids[i])
	layer._catalog_ready = unresolved.is_empty()
	layer._diagnostics.catalog_types = ids.size()
	layer._diagnostics.catalog_unresolved = unresolved.size()
	layer._diagnostics.family_sources = sources
	return {"ok": layer._catalog_ready,
		"reason": "" if layer._catalog_ready else "building_visual_catalog_unresolved",
		"type_count": ids.size(), "unresolved_ids": unresolved,
		"family_sources": sources, "family_counts": family_counts}
