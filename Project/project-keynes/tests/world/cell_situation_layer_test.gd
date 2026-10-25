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
			"state_days": days}

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
	_expect("八种透明位图均已装载", layer._icons.size() == 8)
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
