extends "res://tests/probes/_tmp_building_art_harness.gd"

const Situations = preload("res://scripts/rendering/cell_situation_layer.gd")
const Fixtures = preload("res://tests/world/cell_situation_layer_test.gd")

func _run(_world: WorldData) -> void:
	_view((_cell_center(2, 1) + _cell_center(7, 4)) * 0.5, 4.0)
	var host := Fixtures.ActivityFixtures.HostStub.new()
	add_child(host)
	host.fog = false
	var economy := Fixtures.EconomyStub.new()
	var weather := Fixtures.WeatherStub.new()
	weather.drought = -1
	weather.flood = -1
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var situations := Situations.new()
	situations.theme = load("res://assets/themes/player_session_theme.tres")
	canvas.add_child(situations)
	situations.size = get_viewport_rect().size
	situations.configure(_map, _camera, host, economy, weather)
	situations.set_process(false)
	await get_tree().process_frame
	situations._process(0.3)
	situations._rows.clear()
	var cells := PackedInt32Array([14, 16, 18, 20, 35, 37, 39, 41, 27])
	var packet := economy.cell_situation_snapshot(cells)
	for index in 8:
		packet.flags[index] = 1 << index
	packet.flags[8] = 255
	situations.apply_snapshot(packet)
	var hud := Label.new()
	hud.position = Vector2(26, 22)
	hud.text = "近景地块告警 · 位图效果测试\n三类短缺 / 阶层不满 / 干旱 / 洪泛 / 失业 / 岗位空缺"
	hud.add_theme_font_size_override("font_size", 20)
	hud.add_theme_color_override("font_color", Color("f2dfb2"))
	hud.add_theme_color_override("font_shadow_color", Color.BLACK)
	hud.add_theme_constant_override("shadow_offset_x", 2)
	hud.add_theme_constant_override("shadow_offset_y", 2)
	canvas.add_child(hud)
	await _shot("situation_near")
	if not situations._hits.is_empty():
		var hit: Dictionary = situations._hits[-1]
		situations._mouse_position = hit.rect.get_center()
		situations._update_tooltip()
	await _shot("situation_tooltip")
	_view(_camera.position, 1.5)
	_camera.force_update_scroll()
	situations._process(0.3)
	await _shot("situation_far")
	print("[situation] ", situations.diagnostics())
	get_tree().quit(0)
