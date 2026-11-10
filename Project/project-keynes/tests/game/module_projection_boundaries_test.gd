extends SceneTree

const Conditions = preload("res://scripts/era/era_advancement_conditions.gd")
const FamilyProjection = preload("res://scripts/ui/family_workspace_projection.gd")
const Logistics = preload("res://scripts/ui/military_logistics_projection.gd")
const WeatherInputs = preload("res://scripts/rendering/renderer_weather_inputs.gd")

var _checks := 0
var _failures := 0
var _names_requested: Array[int] = []
var _uniforms: Dictionary = {}
var _wind_calls := 0
var _wind_count := -1


class ValidationController:

	extends PlayerController

	var gate_calls: Array = []

	func _state_building_gate(cell: int, building: int,
			demolishing: bool = false) -> Dictionary:
		gate_calls.append([cell, building, demolishing])
		return {"ok": false, "code": "technology_locked", "message": "blocked by owner"}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_conditions()
	_check_validation_ports()
	_check_family_projection()
	_check_logistics_projection()
	_check_weather_projection()
	print("[module-projection-boundaries] %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] " + message)


func _check_conditions() -> void:
	var tech := {"total": 7, "completed": 5}
	var summary := {"population": 1000000, "building_units": 1000000}
	var before := var_to_bytes([tech, summary])
	var locked := Conditions._conditions(tech, summary, 1, 1000000, 0, 1)
	_expect(locked.size() == 4, "advancement retains four independent conditions")
	_expect(locked[0].mandatory and not locked[0].met and locked[0].target == 6,
		"mandatory technology uses the rounded-up 80 percent boundary")
	_expect(locked[1].met and locked[2].met and locked[3].met,
		"optional conditions cannot make unmet technology appear complete")
	_expect(var_to_bytes([tech, summary]) == before, "condition projection leaves input snapshots intact")
	tech.completed = 6
	var ready := Conditions._conditions(tech, summary, 1, 1000000, 0, 1)
	_expect(ready[0].met, "six of seven technologies meets the mandatory boundary")
	var missing := Conditions._conditions({"total": 0, "completed": 0}, summary, 1, 1000000, 0, 1)
	_expect(not missing[0].met, "missing technology catalog does not grant advancement")
	var larger := Conditions._conditions(tech, summary, 2, 1000000, 0, 1)
	_expect(larger[1].target > ready[1].target and larger[2].target > ready[2].target,
		"territory expansion raises both economy requirements")


func _check_validation_ports() -> void:
	var controller := ValidationController.new()
	var other := ValidationController.new()
	var sequence := int(controller._command_sequence)
	var rejected := controller._validate_command_args(
		PlayerController.COMMAND_MILITARY_STATE_BUILD, {"cell": 12, "building": 3})
	_expect(not rejected.ok and rejected.code == "technology_locked",
		"extracted validation respects the controller's actual owner gate")
	_expect(controller.gate_calls == [[12, 3, false]] and other.gate_calls.is_empty(),
		"validation callbacks remain bound to the requesting controller")
	var weights := controller._validate_command_args(
		PlayerController.COMMAND_RESEARCH_SET_WEIGHTS,
		{"weights_bp": PackedInt32Array([2500, 2500, 2500, 2500])})
	_expect(weights.ok and controller.gate_calls.size() == 1,
		"unrelated command validation does not invoke military capabilities")
	controller._era_reward_generation = 7
	var choice := {"offer_generation": 7, "choice_index": 1}
	_expect(controller._validate_command_args(PlayerController.COMMAND_ERA_REWARD_CHOOSE, choice).ok,
		"current reward generation is accepted")
	controller._era_reward_generation = 8
	_expect(not controller._validate_command_args(PlayerController.COMMAND_ERA_REWARD_CHOOSE, choice).ok,
		"a later validation reads the updated generation instead of retaining a copied value")
	_expect(int(controller._command_sequence) == sequence,
		"read-only validation never allocates command sequence numbers")
	controller.free()
	other.free()


func _check_family_projection() -> void:
	var detail := {"kind": "family", "name": "Example", "row": {
		"effect_rows": [
			{"id": "shared", "cell": 4, "kind": "effect", "title": "Same", "detail": ""},
			{"id": "shared", "cell": 4, "kind": "effect", "title": "Same", "detail": ""},
			{"id": "shared", "cell": 9, "kind": "effect", "title": "Same", "detail": ""},
		],
		"trait_rows": [{"id": "trait", "name": "Trait", "detail": ""}],
	}}
	var before := var_to_bytes(detail)
	var result := FamilyProjection.family_workspace_model(detail)
	_expect(result.kind == "family_workspace", "family projection retains its public result kind")
	var effects: Array = result.pages.effects
	_expect(effects.size() == 2 and effects[0].cell == 4 and effects[1].cell == 9,
		"duplicate display rows collapse without merging effects from different branches")
	_expect(var_to_bytes(detail) == before, "family presentation does not mutate borrowed native rows")
	result.pages.traits[0]["name"] = "Edited display"
	_expect(detail.row.trait_rows[0].name == "Trait", "display edits cannot modify the source snapshot")


func _check_logistics_projection() -> void:
	var convoys := [
		{"id": 1, "current_cell": 2, "dest_cell": 3, "risk_q16": 0, "eta_day": 9},
		{"id": 2, "current_cell": 4, "dest_cell": 5, "risk_q16": 65536, "eta_day": 15},
	]
	var before := var_to_bytes(convoys)
	var rows := Logistics.convoy_rows(10, {}, _cell_name, convoys)
	_expect(rows.size() == 2 and rows[0].id == 2 and rows[1].id == 1,
		"convoy display sorts by risk without changing native convoy order")
	_expect(rows[0].eta == 5 and rows[1].eta == 0, "ETA uses the supplied committed day")
	_expect(rows[0].route == "Cell 4 → Cell 5" and _names_requested == [2, 3, 4, 5],
		"logistics resolves route names through the caller's bound capability")
	_expect(var_to_bytes(convoys) == before, "logistics presentation leaves its input untouched")


func _cell_name(cell: int) -> String:
	_names_requested.append(cell)
	return "Cell %d" % cell


func _check_weather_projection() -> void:
	var material := ShaderMaterial.new()
	var fronts: Array = []
	for i in range(WeatherInputs.MAX_WEATHER_FRONTS + 2):
		fronts.append({"center": Vector2(i, 2), "radius": 3.0, "intensity": 0.5})
	WeatherInputs._push_weather_fronts_to_shader(material, _capture_uniform, _capture_wind, fronts)
	_expect(_uniforms.size() == 5 and _wind_calls == 1,
		"weather publishes one coherent uniform set before one wind refresh")
	_expect(_uniforms.weather_front_count == WeatherInputs.MAX_WEATHER_FRONTS
		and _wind_count == WeatherInputs.MAX_WEATHER_FRONTS,
		"shader and vegetation wind consume the same bounded front count")
	_expect(_uniforms.weather_front_centers[0] == Vector4(0, 2, 3, 0.5),
		"weather packing retains center, radius and intensity")
	_uniforms.clear()
	WeatherInputs._push_weather_fronts_to_shader(material, _capture_uniform, _capture_wind, [])
	_expect(_uniforms.weather_front_count == 0 and _wind_count == 0,
		"an empty weather publication clears a previous nonempty set")
	_expect(_uniforms.weather_front_centers[0] == Vector4.ZERO
		and _uniforms.weather_front_types[0] == -1.0,
		"unused weather entries receive neutral values instead of retaining old fronts")


func _capture_uniform(key: String, value) -> void:
	_uniforms[key] = value


func _capture_wind(_fronts: Array, count: int) -> void:
	_expect(_uniforms.has("weather_front_count"), "wind refresh observes the completed uniform publication")
	_wind_calls += 1
	_wind_count = count
