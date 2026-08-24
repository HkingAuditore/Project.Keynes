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
	_expect("default map source is procedural",
		String(config.base.get("map_source", "")) == NewGameConfig.MAP_SOURCE_PROCEDURAL)
	var pkmap_empty := NewGameConfig.new()
	pkmap_empty.country.name = "ok"
	pkmap_empty.base.initial_seed = 1
	pkmap_empty.base.map_source = NewGameConfig.MAP_SOURCE_PKMAP
	pkmap_empty.base.pkmap_path = ""
	_expect("empty pkmap path rejected",
		String(pkmap_empty.validate().code) == "pkmap_path_empty")
	pkmap_empty.base.pkmap_path = "user://missing_authored_map.pkmap"
	_expect("missing pkmap rejected",
		String(pkmap_empty.validate().code) == "pkmap_missing")
	var fixture_path := "user://new_game_config_fixture.pkmap"
	var written: Dictionary = PkmapIO.write_pkmap(fixture_path, {
		"width": 12,
		"height": 10,
		"n_cells": 120,
		"sea_level": 0.44,
		"seed": 42,
	}, {})
	_expect("fixture pkmap written", bool(written.get("ok", false)))
	var pkmap_ok := NewGameConfig.new()
	pkmap_ok.country.name = "ok"
	pkmap_ok.base.initial_seed = 7
	pkmap_ok.base.map_width = 60
	pkmap_ok.base.map_height = 40
	pkmap_ok.base.map_source = NewGameConfig.MAP_SOURCE_PKMAP
	pkmap_ok.base.pkmap_path = ProjectSettings.globalize_path(fixture_path)
	var pkmap_validation := pkmap_ok.validate()
	_expect("valid pkmap accepted", bool(pkmap_validation.get("ok", false)))
	_expect("pkmap stamps width", int(pkmap_ok.base.map_width) == 12)
	_expect("pkmap stamps height", int(pkmap_ok.base.map_height) == 10)
	_expect("pkmap stamps seed", int(pkmap_ok.base.initial_seed) == 42)
	_expect("pkmap stamps sea level", is_equal_approx(float(pkmap_ok.base.sea_level), 0.44))
	var pkmap_encoded := pkmap_ok.to_dictionary()
	var pkmap_decoded := NewGameConfig.from_dictionary(pkmap_encoded)
	_expect("pkmap round trip", bool(pkmap_decoded.ok)
		and String((pkmap_decoded.config as NewGameConfig).base.get("map_source", ""))
			== NewGameConfig.MAP_SOURCE_PKMAP
		and String((pkmap_decoded.config as NewGameConfig).base.get("pkmap_path", ""))
			== String(pkmap_ok.base.pkmap_path)
		and int((pkmap_decoded.config as NewGameConfig).base.map_width) == 12)
	var stale := pkmap_encoded.duplicate(true)
	(stale.base as Dictionary).erase("map_source")
	(stale.base as Dictionary).erase("pkmap_path")
	(stale.base as Dictionary).map_width = 60
	(stale.base as Dictionary).map_height = 40
	(stale.base as Dictionary).initial_seed = 9
	var stale_loaded := NewGameConfig.from_dictionary(stale)
	_expect("legacy v3 without map_source is procedural", bool(stale_loaded.ok)
		and String((stale_loaded.config as NewGameConfig).base.get("map_source", ""))
			== NewGameConfig.MAP_SOURCE_PROCEDURAL
		and String((stale_loaded.config as NewGameConfig).base.get("pkmap_path", "")) == "")
	var bad_header := {
		"width": 12,
		"height": 10,
		"n_cells": 120,
		"sea_level": 0.5,
		"seed": 3,
		"generator_hash": "0".repeat(64),
	}
	var bad_path := "user://new_game_config_incompatible.pkmap"
	var header_bytes := JSON.stringify(bad_header).to_utf8_buffer()
	var bad_file := FileAccess.open(bad_path, FileAccess.WRITE)
	bad_file.store_buffer("PKMP".to_ascii_buffer())
	bad_file.store_32(1)
	bad_file.store_32(header_bytes.size())
	bad_file.store_buffer(header_bytes)
	bad_file.close()
	var pkmap_bad := NewGameConfig.new()
	pkmap_bad.country.name = "ok"
	pkmap_bad.base.initial_seed = 1
	pkmap_bad.base.map_source = NewGameConfig.MAP_SOURCE_PKMAP
	pkmap_bad.base.pkmap_path = ProjectSettings.globalize_path(bad_path)
	_expect("incompatible pkmap rejected",
		String(pkmap_bad.validate().code) == "pkmap_incompatible")
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
