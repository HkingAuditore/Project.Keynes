extends RefCounted

const Policy = preload("res://scripts/economy/bootstrap/test_start_policy.gd")
const BRIDGE_GOODS = ["logs", "gathered_plants", "flint"]

var count: int
var terrain_arr := PackedByteArray()
var neighbors := PackedInt32Array()
var temp_arr := PackedFloat32Array()
var moisture_arr := PackedFloat32Array()
var snow_cover_arr := PackedFloat32Array()
var weather_intensity_arr := PackedFloat32Array()
var passable_cells := PackedInt32Array()
var resources: Dictionary = {}
var resource_rules: Dictionary = {}
var profession_ids := PackedStringArray()
var signatures: Dictionary = {}
var building_ids := PackedStringArray()
var building_specs: Dictionary = {}
var eligible_building_ids := PackedStringArray()
var finance: Dictionary = {}
var cycle_days: int

func cell_count() -> int:
	return count

func neighbor_index(cell: int, direction: int) -> int:
	return neighbors[cell * 6 + direction]

static func capture(map: MapData, facade: EconomyFacade) -> Dictionary:
	if map == null or facade == null or not facade.is_configured():
		return {"ok": false, "reason": "test_bootstrap_runtime_unavailable"}
	var snapshot = load("res://scripts/economy/bootstrap/test_start_inputs.gd").new()
	snapshot.profession_ids = facade.profession_ids()
	var profession_ids: PackedStringArray = snapshot.profession_ids
	snapshot.signatures = {}
	var signatures: Dictionary = snapshot.signatures
	for profession_id in profession_ids:
		var signature := facade.signature_id(StringName(profession_id), &"default")
		if signature < 0:
			return {
				"ok": false,
				"reason": "test_bootstrap_catalog_incomplete",
				"missing_signature": "%s|default" % String(profession_id),
			}
		signatures[StringName(profession_id)] = signature
	snapshot.building_ids = facade.building_type_ids()
	var building_ids: PackedStringArray = snapshot.building_ids
	snapshot.finance = facade.bootstrap_finance_columns().duplicate(true)
	var finance: Dictionary = snapshot.finance
	var finance_good_ids: PackedStringArray = finance.get("good_ids", PackedStringArray())
	for bridge_good in BRIDGE_GOODS:
		if finance_good_ids.find(String(bridge_good)) < 0:
			return {
				"ok": false,
				"reason": "test_bootstrap_bridge_good_missing",
				"good_id": String(bridge_good),
			}
	if building_ids.is_empty():
		return {"ok": false, "reason": "test_bootstrap_building_catalog_empty"}
	snapshot.building_specs = {}
	var building_specs: Dictionary = snapshot.building_specs
	var eligible_building_ids := PackedStringArray()
	for building_id in building_ids:
		var job_spec: Dictionary = facade.building_job_spec(StringName(building_id))
		var placement_spec: Dictionary = facade.building_placement_spec(StringName(building_id))
		if not bool(job_spec.get("ok", false)) or not bool(placement_spec.get("ok", false)):
			return {
				"ok": false,
				"reason": "test_bootstrap_building_catalog_incomplete",
				"missing_building": String(building_id),
			}
		for key in placement_spec:
			job_spec[key] = placement_spec[key]
		building_specs[StringName(building_id)] = job_spec.duplicate(true)
		if String(building_id) in Policy.BUILDING_IDS and Policy.technology_available(placement_spec.technology_tags):
			eligible_building_ids.append(building_id)
	for required in Policy.BUILDING_IDS:
		if not building_ids.has(required):
			return {"ok": false, "reason": "test_bootstrap_building_catalog_incomplete", "missing_building": required}
	snapshot.eligible_building_ids = eligible_building_ids
	snapshot.count = map.cell_count()
	snapshot.cycle_days = facade.bootstrap_cycle_days(0)
	snapshot.terrain_arr.resize(snapshot.count)
	snapshot.neighbors.resize(snapshot.count * 6)
	for cell in range(snapshot.count):
		var terrain: int = TerrainType.TERRAIN.OCEAN
		if cell < map.terrain_arr.size():
			terrain = int(map.terrain_arr[cell])
		elif map.cell_at(cell) != null:
			terrain = int(map.cell_at(cell).terrain)
		snapshot.terrain_arr[cell] = terrain
		if not MapData.terrain_is_water(terrain) and TerrainType.is_passable_land(terrain):
			snapshot.passable_cells.append(cell)
		for direction in range(6):
			snapshot.neighbors[cell * 6 + direction] = map.neighbor_index(cell, direction)
	snapshot.temp_arr = map.temp_arr.duplicate()
	snapshot.moisture_arr = map.moisture_arr.duplicate()
	snapshot.snow_cover_arr = map.snow_cover_arr.duplicate()
	snapshot.weather_intensity_arr = map.weather_intensity_arr.duplicate()
	ResourceProfileRegistry.ensure_loaded()
	for profile in ResourceProfileRegistry.ordered():
		snapshot.resource_rules[StringName(profile.id)] = {
			"capacity": maxf(0.0, float(profile.ecology_capacity)) * ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE,
			"growth": maxf(0.0, float(profile.ecology_growth_rate)),
		}
		if not ResourceProfileRegistry.discovery_visible(profile, PackedStringArray(Policy.TECHNOLOGY_IDS)):
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field == "":
			continue
		var values: PackedFloat32Array = map.get(field)
		if values.size() >= snapshot.count:
			snapshot.resources[StringName(profile.id)] = values.duplicate()
	return {"ok": true, "inputs": snapshot}
