extends RefCounted

static func configure_all_technologies(ext: Object, catalog: Dictionary,
		cell_count: int, seed: int, is_water: PackedByteArray = PackedByteArray(),
		excluded_technology_ids: PackedStringArray = PackedStringArray()) -> bool:
	var water := is_water
	if water.is_empty():
		water.resize(cell_count)
		water.fill(0)
	if water.size() != cell_count:
		return false
	var starting := PackedStringArray()
	for id in catalog.get("technology_ids", PackedStringArray()):
		if not excluded_technology_ids.has(id):
			starting.append(id)
	var profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": starting,
	}
	var configured: Dictionary = ext.configure_country(catalog, profile, cell_count, seed)
	if not bool(configured.get("ok", false)):
		return false
	return bool(ext.bootstrap_country({}, water).get("ok", false))
