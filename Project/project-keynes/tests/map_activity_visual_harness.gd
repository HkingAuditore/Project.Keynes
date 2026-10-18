extends "res://tests/_tmp_building_art_harness.gd"

const ActivityScript = preload("res://scripts/rendering/map_activity_layer.gd")
const Fixtures = preload("res://tests/map_activity_layer_test.gd")

func _run(world: WorldData) -> void:
	_view((_cell_center(2, 1) + _cell_center(6, 3)) * 0.5, 4.0)
	var host := Fixtures.HostStub.new()
	add_child(host)
	host.fog = false
	var player := Fixtures.PlayerStub.new()
	add_child(player)
	var clock := WorldClock.new()
	add_child(clock)
	clock.set_process(false)
	var activity := ActivityScript.new()
	add_child(activity)
	activity.z_index = 11
	_map.country_slot_arr.resize(_map.cell_count())
	for cell in _map.cell_count():
		var hex := _map.cell_at(cell)
		var off := HexUtils.cube_to_offset(hex.q, hex.r)
		_map.country_slot_arr[cell] = (0 if off.x <= 5 else 1) if off.y in [1, 2, 3, 4] else -1
	var border := CountryBorderLayer.new()
	add_child(border)
	border.set_hex_size(HEX)
	border.set_player_slot(0)
	border.rebuild(_map)
	activity.configure(_map, _camera, host, player, null, clock, null, border)
	activity.set_process(false)
	var route := ColonizationRouteLayer.new()
	add_child(route)
	route.z_index = 10
	route.set_context(_map, clock, HEX, 0.0)
	route.show_expedition({"route_cells": PackedInt32Array([12, 13, 14, 25, 26]),
		"cumulative_costs": PackedInt32Array([0, 1, 2, 3, 4]), "route_cost": 4,
		"departure_day": 0, "due_day": 4, "state": 1})
	route._display_cost = 1.45
	route.set_process(false)
	_layer.wait_for_layout(10000)
	await _shot("activity_before")
	activity.play_activity(26, &"colony", "开拓成功")
	activity.play_activity(37, &"build", "扩建完成")
	activity.play_activity(39, &"growth", "+12 人")
	for effect in activity._effects:
		effect.age = 0.46
	border._pulse_age = 0.46
	border._shader_mat.set_shader_parameter("frontier_pulse_age", 0.46)
	border.set_process(false)
	activity.queue_redraw()
	await _shot("activity_peak")
	for effect in activity._effects:
		effect.reduced = true
	border._shader_mat.set_shader_parameter("frontier_pulse_age", 2.0)
	activity.queue_redraw()
	await _shot("activity_reduced_motion")
	for effect in activity._effects:
		effect.reduced = false
		effect.age = float(effect.duration) * 0.80
	border._shader_mat.set_shader_parameter("frontier_pulse_age", 1.6)
	activity.queue_redraw()
	await _shot("activity_fade")
	get_tree().quit(0)
