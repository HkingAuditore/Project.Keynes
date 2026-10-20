extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

const TARGETS := {
	"wheat_grain": {
		"buildings": ["wheat_farm", "tenant_rainfed_wheat_field", "method_wheat_farm_r3", "method_wheat_farm_r5", "method_wheat_farm_r6", "method_wheat_farm_r8", "method_wheat_farm_r10"],
		"climate": "dryland_crop", "resources": ["arable_land", "fertile_soil"]
	},
	"rice_grain": {
		"buildings": ["rice_collector", "tenant_paddy", "estate_paddy", "method_rice_collector_r3", "method_rice_collector_r5", "method_rice_collector_r6", "method_rice_collector_r8", "method_rice_collector_r10"],
		"climate": "paddy_crop", "resources": ["paddy_land"]
	},
	"corn_grain": {
		"buildings": ["maize_garden", "tenant_rainfed_maize_field", "landed_estate", "method_landed_estate_r6", "method_maize_farm_r8", "method_maize_farm_r10"],
		"climate": "dryland_crop", "resources": ["arable_land", "fertile_soil"]
	},
	"potatoes": {
		"buildings": ["highland_tuber_plot", "potato_collector", "tenant_potato_field", "potato_estate", "method_potato_farm_r5", "method_potato_collector_r6", "method_potato_farm_r8", "method_potato_farm_r10"],
		"climate": "dryland_crop", "resources": ["arable_land", "fertile_soil"]
	},
	"seed_cotton": {
		"buildings": ["cotton_garden", "cotton_collector", "method_cotton_collector_r6", "cotton_smallholding", "method_cotton_collector_r8", "method_cotton_collector_r10"],
		"climates": ["dryland_crop", "plantation_crop"], "resources": ["arable_land", "fertile_soil"]
	},
	"bast_fiber": {
		"buildings": ["flax_collector", "method_flax_collector_r3", "method_flax_collector_r5", "method_flax_collector_r6", "method_flax_collector_r8", "method_flax_collector_r10"],
		"climate": "dryland_crop", "resources": ["arable_land", "fertile_soil"]
	},
	"spices": {
		"buildings": ["spice_shade_garden", "spice_plants_collector", "spice_managed_garden", "spice_commercial_plantation", "method_spice_plants_collector_r6", "method_spice_plants_collector_r8", "method_spice_plants_collector_r10"],
		"climate": "plantation_crop", "resources": ["plantation_land", "fertile_soil"]
	},
	"medicinal_herbs": {
		"buildings": ["medicinal_herbs_collector", "method_medicinal_herbs_collector_r7", "medicinal_herb_garden", "medicinal_herb_estate", "method_medicinal_herbs_collector_r8", "method_medicinal_herbs_collector_r10"],
		"climate": "plantation_crop", "resources": ["plantation_land", "fertile_soil"]
	},
	"latex": {
		"buildings": ["rubber_tapping_camp", "rubber_tree_collector", "method_rubber_tree_collector_r6", "method_rubber_tree_collector_r8", "method_rubber_tree_collector_r10"],
		"climate": "plantation_crop", "resources": ["plantation_land", "fertile_soil"]
	},
}

const STAGE_BUILDINGS := {
	"wheat_grain": {"foundation": ["rainfed_wheat_plot"], "managed": ["method_wheat_farm_r3", "method_wheat_farm_r5"], "industrial": ["method_wheat_farm_r6"], "digital": ["method_wheat_farm_r8", "method_wheat_farm_r10"]},
	"rice_grain": {"foundation": ["upland_rice_plot", "wetland_rice_garden"], "managed": ["method_rice_collector_r3", "method_rice_collector_r5"], "industrial": ["method_rice_collector_r6"], "digital": ["method_rice_collector_r8", "method_rice_collector_r10"]},
	"corn_grain": {"foundation": ["maize_garden", "rainfed_maize_field"], "managed": ["landed_estate"], "industrial": ["method_landed_estate_r6"], "digital": ["method_maize_farm_r8", "method_maize_farm_r10"]},
	"potatoes": {"foundation": ["potato_collector", "highland_tuber_plot"], "managed": ["tenant_potato_field", "potato_estate", "method_potato_farm_r5"], "industrial": ["method_potato_collector_r6"], "digital": ["method_potato_farm_r8", "method_potato_farm_r10"]},
	"seed_cotton": {"foundation": ["cotton_garden"], "managed": ["cotton_smallholding", "cotton_collector"], "industrial": ["method_cotton_collector_r6"], "digital": ["method_cotton_collector_r8", "method_cotton_collector_r10"]},
	"bast_fiber": {"foundation": ["flax_collector"], "managed": ["method_flax_collector_r3", "method_flax_collector_r5"], "industrial": ["method_flax_collector_r6"], "digital": ["method_flax_collector_r8", "method_flax_collector_r10"]},
	"spices": {"foundation": ["spice_shade_garden"], "managed": ["spice_managed_garden", "spice_commercial_plantation"], "industrial": ["method_spice_plants_collector_r6"], "digital": ["method_spice_plants_collector_r8", "method_spice_plants_collector_r10"]},
	"medicinal_herbs": {"foundation": ["medicinal_herb_garden"], "managed": ["medicinal_herb_estate", "medicinal_herbs_collector"], "industrial": ["method_medicinal_herbs_collector_r7"], "digital": ["method_medicinal_herbs_collector_r8", "method_medicinal_herbs_collector_r10"]},
	"latex": {"foundation": ["rubber_tapping_camp"], "managed": ["rubber_tree_collector"], "industrial": ["method_rubber_tree_collector_r6"], "digital": ["method_rubber_tree_collector_r8", "method_rubber_tree_collector_r10"]},
}

var failures := 0

func _init() -> void:
	_run()
	print("crop technology parity: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("native economy catalog compiles with all crop methods", bool(compiled.get("ok", false)))
	var building_by_id := {}
	for file_name in DirAccess.get_files_at("res://data/economy/buildings"):
		if not file_name.ends_with(".tres"):
			continue
		var profile = load("res://data/economy/buildings/%s" % file_name)
		if profile != null:
			building_by_id[String(profile.id)] = profile
	for good_id in TARGETS:
		var spec: Dictionary = TARGETS[good_id]
		var buildings: Array = spec.buildings
		for building_id in buildings:
			_expect("%s has dedicated building %s" % [good_id, building_id], building_by_id.has(building_id))
			if not building_by_id.has(building_id):
				continue
			var profile = building_by_id[building_id]
			var is_wild_collection: bool = building_id == "rubber_tapping_camp"
			_expect("%s/%s is a collector" % [good_id, building_id], String(profile.building_kind) == "collector")
			if not is_wild_collection:
				_expect("%s/%s is agriculture" % [good_id, building_id], String(profile.economic_sector_id) == "agriculture")
			var climates: Array = spec.get("climates", [spec.get("climate", "")])
			_expect("%s/%s has correct climate" % [good_id, building_id],
				climates.has(String(profile.production_climate_profile_id)))
			var actual_resources := Array(profile.resource_ids)
			var required_land := String(spec.resources[0])
			_expect("%s/%s has correct land resources" % [good_id, building_id],
				(is_wild_collection or actual_resources.has(required_land)) and
				(required_land == "paddy_land" or not actual_resources.has("paddy_land")))
			_expect("%s/%s outputs only its dedicated good" % [good_id, building_id],
				Array(profile.output_good_ids) == [good_id])
			_expect("%s/%s does not use generic grain/vegetables outputs" % [good_id, building_id],
				not Array(profile.output_good_ids).has("grain") and not Array(profile.output_good_ids).has("vegetables"))
			var good = load("res://data/goods/%s.tres" % good_id)
			_expect("%s tag binds %s" % [good_id, building_id], Array(good.technology_tags).any(func(tag): return String(tag) == String(profile.technology_tags[-1])))

	for good_id in STAGE_BUILDINGS:
		var stages: Dictionary = STAGE_BUILDINGS[good_id]
		for stage_id in stages:
			var stage_is_covered := false
			for building_id in stages[stage_id]:
				var profile = building_by_id.get(building_id)
				if profile != null and Array(profile.output_good_ids) == [good_id]:
					stage_is_covered = true
					break
			_expect("%s has dedicated %s-stage production" % [good_id, stage_id], stage_is_covered)

	var flax = building_by_id.get("flax_collector")
	var retting = building_by_id.get("flax_retting_pit")
	_expect("flax farm produces bast_fiber", flax != null and Array(flax.output_good_ids) == ["bast_fiber"])
	_expect("retting consumes bast_fiber and produces flax_fiber", retting != null and Array(retting.input_good_ids) == ["bast_fiber"] and Array(retting.output_good_ids) == ["flax_fiber"])
	_expect("retting construction does not consume bast_fiber", retting != null and not Array(retting.construction_good_ids).has("bast_fiber"))
	var flax_good = load("res://data/goods/flax_fiber.tres")
	_expect("flax_fiber is unlocked by retting, not field production", flax_good != null and Array(flax_good.technology_tags).has("tech.flax_retting") and not Array(flax_good.technology_tags).has("tech.wild_flax_collection"))

	var generic_precision = building_by_id.get("precision_farm")
	var generic_automated = building_by_id.get("automated_farm")
	_expect("generic modern farms remain generic only", generic_precision != null and generic_automated != null and Array(generic_precision.output_good_ids).has("grain") and Array(generic_precision.output_good_ids).has("vegetables") and Array(generic_automated.output_good_ids).has("grain") and Array(generic_automated.output_good_ids).has("vegetables"))

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1
