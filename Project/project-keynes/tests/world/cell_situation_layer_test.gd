extends SceneTree

const Layer = preload("res://scripts/rendering/cell_situation_layer.gd")
const ActivityFixtures = preload("res://tests/world/map_activity_layer_test.gd")

class WeatherStub extends DCViewAdapter:
	var drought := 0
	var flood := 1
	func get_weather_field_init(_cell: int) -> bool: return true
	func get_weather_type(cell: int) -> int:
		return WeatherType.WT.DROUGHT if cell == drought else WeatherType.WT.CLEAR
	func get_weather_intensity(_cell: int) -> float: return 0.8
	func get_cover(cell: int) -> int:
		return CoverType.CV.FLOODING if cell == flood else 0

class EconomyStub extends RefCounted:
	var batches: Array[PackedInt32Array] = []
	var pending := false
	func good_display_name(_good: int) -> String: return "谷物"
	func cell_situation_snapshot(cells: PackedInt32Array) -> Dictionary:
		batches.append(cells.duplicate())
		if pending:
			return {"ok": false, "read_view_pending": true}
		var flags := PackedByteArray()
		var severity := PackedInt32Array()
		var causes := PackedInt32Array()
		var classes := PackedInt32Array()
		var days := PackedInt64Array()
		for cell in cells:
			flags.append(1 | (1 << 3) | (1 << 6) | (1 << 7))
			severity.append_array(PackedInt32Array([50000, 0, 0, 50000, 0, 0, 30000, 40000]))
			causes.append_array(PackedInt32Array([0, -1, -1]))
			classes.append(0)
			days.append(5)
		return {"ok": true, "committed": true, "cell_indices": cells,
			"flags": flags, "severity_q16": severity, "cause_good_ids": causes,
			"worst_class_ids": classes, "class_ids": PackedStringArray(["farmer"]),
			"state_days": days, "economy_generation": 5}

var failures := 0
var checks := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1280, 720)
	var holder := Node2D.new()
	root.add_child(holder)
	var map := MapData.new(60, 40)
	for row in 40:
		for col in 60:
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	map.visible_arr.resize(map.cell_count())
	map.visible_arr.fill(1)
	var camera := Camera2D.new()
	holder.add_child(camera)
	camera.position = Vector2(600, 400)
	camera.zoom = Vector2.ONE
	camera.make_current()
	var host := ActivityFixtures.HostStub.new()
	holder.add_child(host)
	var economy := EconomyStub.new()
	var weather := WeatherStub.new()
	var canvas := CanvasLayer.new()
	holder.add_child(canvas)
	var layer := Layer.new()
	canvas.add_child(layer)
	layer.size = Vector2(1280, 720)
	layer.configure(map, camera, host, economy, weather)
	layer.set_process(false)
	await process_frame
	layer._process(0.3)
	_expect("远景不读经济、不显示图标", economy.batches.is_empty() and not layer._near)
	camera.zoom = Vector2.ONE * 2.2
	camera.force_update_scroll()
	layer._process(0.3)
	_expect("近景自动读取有界批次", layer._near and economy.batches.size() == 1
		and economy.batches[0].size() <= 128 and not economy.batches[0].is_empty())
	_expect("候选只覆盖视窗而不是全图", layer._scan_count < map.cell_count()
		and layer._candidates.size() < map.cell_count())
	var first: PackedInt32Array = economy.batches[0]
	host.simulation_committed.emit(5, 6, 1)
	layer._process(0.3)
	_expect("后台提交不让分页反复停在第一页", economy.batches.size() == 2
		and economy.batches[1] != first)
	var target: int = first[0]
	weather.drought = target
	layer._update_weather(target)
	_expect("经济和干旱告警同格并存", int(layer._rows[target].flags) == (1 | 8 | 16 | 64 | 128))
	weather.flood = target
	layer._update_weather(target)
	_expect("洪泛与其他状态独立", int(layer._rows[target].flags) & 32 != 0)
	var description: String = layer.tooltip_for(target, 0)
	_expect("悬停包含具体商品和结算时间", description.contains("谷物") and description.contains("第 5 天"))
	_expect("悬停指出不满阶层", layer.tooltip_for(target, 3).contains("农民"))
	var older := economy.cell_situation_snapshot(PackedInt32Array([target]))
	older.economy_generation = 4
	older.flags[0] = 0
	layer.apply_snapshot(older)
	_expect("较旧地图批次不能覆盖新批次", layer.tooltip_for(target, 3).contains("农民"))
	var panel := (load("res://scenes/ui/inspector_panel.tscn") as PackedScene).instantiate() as InspectorPanel
	canvas.add_child(panel)
	panel.show()
	panel.population_discontent_changed.connect(layer.set_population_discontent)
	var recovered := {"class_discontent": {"active": false, "state_day": 6, "economy_generation": 6}}
	panel.set_model_for_selection({"cell_index": target,
		"tabs": [{"id": "geography"}, {"id": "population"}],
		"categories": {"population": recovered}})
	panel.select_tab("population")
	_expect("人口页已恢复时隐藏旧的本格不满告警",
		layer.tooltip_for(target, 3).is_empty() and not layer.tooltip_for(target, 0).is_empty())
	layer.apply_snapshot(economy.cell_situation_snapshot(PackedInt32Array([target])))
	_expect("地图批次返回时沿用面板正在显示的同格数据", layer.tooltip_for(target, 3).is_empty())
	panel.apply_live_patch({"tab_id": "population", "category": {"class_discontent": {
		"active": true, "class_id": "worker", "severity_q16": 42598,
		"state_day": 7, "economy_generation": 7}}})
	var current: String = layer.tooltip_for(target, 3)
	_expect("本格不满告警显示人口页同批阶层和值",
		current.contains("工人") and current.contains("35%") and current.contains("第 7 天"))
	panel.hide()
	_expect("关闭人口页后不会退回旧告警", layer.tooltip_for(target, 3) == current)
	var newer := economy.cell_situation_snapshot(PackedInt32Array([target]))
	newer.economy_generation = 8
	newer.state_days[0] = 8
	layer.apply_snapshot(newer)
	_expect("更新的地图批次接管已关闭人口页的告警", layer.tooltip_for(target, 3).contains("农民"))
	panel.free()
	layer.position = Vector2(27, 13)
	var hit_rect := Rect2(100, 80, 25, 25)
	layer._hits.assign([{"rect": hit_rect, "cell": target, "kind": 3}])
	var screen: Vector2 = layer.get_global_transform_with_canvas() * hit_rect.get_center()
	_expect("告警命中使用浮标所属地块并适配界面偏移", layer.pick_cell_at_screen(screen) == target)
	layer.set_population_discontent(target, {"active": false, "state_day": 8})
	_expect("本次绘制前已隐藏的旧告警不能接收点击", layer.pick_cell_at_screen(screen) == -1)
	layer.set_population_discontent(-1, {})
	layer.position = Vector2.ZERO
	weather.drought = target
	layer._update_weather(target)
	var before := layer._rows.duplicate(true)
	layer.apply_snapshot({"ok": false, "read_view_pending": true})
	_expect("后台读视图等待时保留已提交结果", before == layer._rows)
	layer.apply_snapshot({"ok": true, "committed": false})
	_expect("拒绝未提交数据", before == layer._rows)
	map.visible_arr[target] = 0
	_expect("当前迷雾立即禁止显示和悬停", not layer._can_show(target))
	host.simulation_committed.emit(6, 7, 2)
	layer._process(0.3)
	_expect("重建剔除不可见缓存", not layer._rows.has(target)
		and not layer._candidates.has(target))
	map.visible_arr[target] = 1
	host.simulation_committed.emit(7, 8, 3)
	layer._process(0.3)
	_expect("新视野无需移动相机即可加入", layer._candidates.has(target))
	camera.zoom = Vector2.ONE * 2.0
	camera.force_update_scroll()
	layer._process(0.3)
	_expect("阈值附近保留近景避免闪烁", layer._near)
	camera.zoom = Vector2.ONE * 1.8
	camera.force_update_scroll()
	var queries := economy.batches.size()
	layer._process(0.3)
	_expect("缩远停止查询且清空显示", not layer._near and layer._rows.is_empty()
		and layer._hits.is_empty() and economy.batches.size() == queries)
	_expect("各告警有实际加载的位图", layer._icons.size() == Layer.TITLES.size()
		and not layer._icons.has(null))
	layer.configure(map, camera, host, economy, weather)
	_expect("重绑不残留旧地图状态", layer._rows.is_empty() and layer._candidates.is_empty())
	var scene: PackedScene = load("res://scenes/player_game.tscn")
	var game := scene.instantiate()
	_expect("正式玩家场景已挂载自动告警层", game.has_node("UI/UIRoot/HUDLayer/CellSituationLayer"))
	game.free()
	holder.queue_free()
	await process_frame
	print("=== cell_situation_layer: checks=%d failures=%d ===" % [checks, failures])
	quit(1 if failures else 0)

func _expect(label: String, passed: bool) -> void:
	checks += 1
	if not passed: failures += 1
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
