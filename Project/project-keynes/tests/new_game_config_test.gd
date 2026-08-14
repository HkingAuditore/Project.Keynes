extends SceneTree

var _checks := 0
var _failures := 0


func _init() -> void:
	var config := NewGameConfig.create_default()
	config.country.name = "  大河联邦  "
	_expect("foreign default", int(config.country.foreign_count) == 5)
	_expect("unicode country accepted", bool(config.validate().ok))
	_expect("country trimmed", String(config.country.name) == "大河联邦")
	var encoded := config.to_dictionary()
	var decoded := NewGameConfig.from_dictionary(encoded)
	_expect("round trip", bool(decoded.ok) and (decoded.config as NewGameConfig).to_dictionary() == encoded)
	var legacy := encoded.duplicate(true)
	legacy.version = 2
	(legacy.country as Dictionary).erase("foreign_count")
	var migrated := NewGameConfig.from_dictionary(legacy)
	_expect("v2 migrates to single-country opening", bool(migrated.ok)
		and int((migrated.config as NewGameConfig).country.foreign_count) == 0
		and int(migrated.migrated_from_version) == 2)
	config.country.foreign_count = 13
	_expect("foreign count rejected",
		String(config.validate().code) == "foreign_count_out_of_range")
	config.country.foreign_count = 5
	config.country.name = "bad\nname"
	_expect("control character rejected", String(config.validate().code) == "country_name_control_character")
	config.country.name = "ok"
	config.base.initial_seed = 0
	_expect("zero seed rejected", String(config.validate().code) == "seed_out_of_range")
	config.base.initial_seed = 1
	config.base.map_width = 501
	_expect("oversized map rejected", String(config.validate().code) == "map_size_out_of_range")
	_expect("main scene is formal menu", String(ProjectSettings.get_setting("application/run/main_scene")) ==
		"res://scenes/main_menu.tscn")
	var name_pack = load("res://data/country/default_country_names.tres")
	var names_a: Dictionary = name_pack.select(42, 12, "罗马帝国")
	var names_b: Dictionary = name_pack.select(42, 12, "罗马帝国")
	_expect("foreign names deterministic", bool(names_a.ok) and names_a == names_b)
	_expect("player name excluded",
		(names_a.display_names as PackedStringArray).find("罗马帝国") < 0)
	_expect("historical name pack has broad capacity",
		int(name_pack.validate(12).available) >= 60)
	_expect("default land layout is two continents",
		String(config.base.land_layout) == "two"
		and int(config.base.num_continents) == 2
		and float(config.base.continent_size) < 0.7)
	_expect("two-continent spacing keeps cores apart",
		float(NewGameConfig.derive_climate(config.world_controls).get("main_separation_factor", 0.0)) > 1.0)
	config.apply_land_layout("archipelago")
	_expect("archipelago uses many small cores",
		String(config.base.land_layout) == "archipelago"
		and int(config.base.num_continents) >= 5
		and float(config.base.continent_size) <= 0.32
		and int(config.world_controls.island_amount) >= 80)
	config.apply_land_layout("single")
	_expect("single continent keeps one large core",
		int(config.base.num_continents) == 1 and float(config.base.continent_size) >= 0.7)
	config.apply_land_layout("multiple")
	_expect("multiple continents stay smaller than pangaea",
		int(config.base.num_continents) >= 3 and float(config.base.continent_size) <= 0.45)
	var unknown := NewGameConfig.new()
	unknown.country.name = "ok"
	unknown.base.initial_seed = 1
	unknown.base.land_layout = "not-a-layout"
	_expect("unknown layout becomes custom",
		bool(unknown.validate().ok) and String(unknown.base.land_layout) == "custom")
	var setup_climate := NewGameConfig.derive_climate({
		"continent_spacing": 55,
		"island_amount": 50,
		"coast_roughness": 50,
		"wetness": 55,
		"lake_density": 45,
		"river_density": 55,
		"volcano_amount": 40,
	})
	_expect("full world controls still derive coast warp",
		setup_climate.has("continent_warp_amp") and setup_climate.has("main_separation_factor"))
	print("new game config: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
