extends SceneTree

var _checks := 0
var _failures := 0


func _init() -> void:
	var config := NewGameConfig.create_default()
	config.country.name = "  大河联邦  "
	_expect("unicode country accepted", bool(config.validate().ok))
	_expect("country trimmed", String(config.country.name) == "大河联邦")
	var encoded := config.to_dictionary()
	var decoded := NewGameConfig.from_dictionary(encoded)
	_expect("round trip", bool(decoded.ok) and (decoded.config as NewGameConfig).to_dictionary() == encoded)
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
	print("new game config: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
