extends SceneTree

const ActivityScript = preload("res://scripts/rendering/map_activity_layer.gd")

class HostStub extends Node:
	signal daily_tick_completed(report: Dictionary)
	signal simulation_committed(from_day: int, to_day: int, generation: int)
	var hex_size := 22.0
	var fog := true
	var intel := BuildingVisualIntelCache.new()
	func map_wrap_period_x() -> float: return 0.0
	func player_country_slot() -> int: return 0
	func is_fog_of_war_enabled() -> bool: return fog
	func building_visual_intel_cache() -> BuildingVisualIntelCache: return intel

class PlayerStub extends Node:
	signal command_settled(id: StringName, result: Dictionary)
	var snapshots := 0
	var selection: HexCell
	func selected_cell() -> HexCell: return selection
	func get_family_expeditions(_offset: int, _limit: int) -> Dictionary:
		return {"ok": true, "expedition_handles": PackedInt64Array([42]),
			"states": PackedInt32Array([1])}
	func get_family_expedition_snapshot(_handle: int) -> Dictionary:
		snapshots += 1
		return {"ok": true, "source_cell": 0, "target_cell": 1,
			"route_cells": PackedInt32Array([0, 1]),
			"cumulative_costs": PackedInt32Array([0, 2]),
			"route_cost": 2, "departure_day": 0, "due_day": 2, "state": 1}

class EconomyStub extends RefCounted:
	var queries := 0
	var population := 100
	var pending := false
	func population_cell_summary(_cell: int) -> Dictionary:
		queries += 1
		return {"ok": not pending, "population": population, "read_view_pending": pending}

class VisualSnapshotStub extends RefCounted:
	var cell := 0
	var count := 3
	func get_building_visual_snapshot(_cells: PackedInt32Array) -> Dictionary:
		return {"ok": true, "cell_indices": PackedInt32Array([cell]),
			"country_slots": PackedInt32Array([0]), "era_indices": PackedInt32Array([0]),
			"type_offsets": PackedInt32Array([0, 1]), "type_indices": PackedInt32Array([0]),
			"counts": PackedInt64Array([count])}

var failures := 0
var checks := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1280, 720)
	var holder := Node2D.new()
	root.add_child(holder)
	var map := MapData.new(8, 3)
	for row in 3:
		for col in 8:
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	map.visible_arr.resize(24)
	map.visible_arr.fill(1)
	map.country_slot_arr.resize(24)
	map.country_slot_arr.fill(0)
	var camera := Camera2D.new()
	holder.add_child(camera)
	camera.position = Vector2(130, 33)
	camera.zoom = Vector2(2, 2)
	camera.make_current()
	var host := HostStub.new()
	holder.add_child(host)
	host.intel.configure(24)
	var player := PlayerStub.new()
	holder.add_child(player)
	var economy := EconomyStub.new()
	var clock := WorldClock.new()
	holder.add_child(clock)
	clock.set_process(false)
	var activity := ActivityScript.new()
	holder.add_child(activity)
	activity.configure(map, camera, host, player, economy, clock)
	activity.set_process(false)
	await process_frame
	activity.observe_development(0, 100, 3)
	_expect("首次观察只建立基线", activity._effects.is_empty())
	activity.observe_development(0, 102, 3)
	_expect("真实正增长播放反馈", activity._effects.size() == 1 and activity._effects[0].kind == &"growth")
	activity._effects.clear()
	activity.observe_development(0, 105, 3)
	_expect("增长按墙钟冷却", activity._effects.is_empty())
	activity.observe_development(0, 99, 3)
	_expect("人口下降不误报增长", activity._effects.is_empty())
	activity.observe_development(1, 100, 3)
	activity.observe_development(1, 102, 4)
	_expect("扩建优先于同格增长", activity._effects.size() == 1 and activity._effects[0].kind == &"build")
	activity._effects.clear()
	map.visible_arr[2] = 0
	_expect("当前不可见时不产生反馈", not activity.play_activity(2, &"colony"))
	map.visible_arr[2] = 1
	camera.zoom = Vector2(0.2, 0.2)
	_expect("远景关闭日常反馈", not activity.play_activity(2, &"growth"))
	_expect("远景保留重要开拓反馈", activity.play_activity(2, &"colony"))
	activity._effects.clear()
	camera.zoom = Vector2(2, 2)
	for cell in [3, 4, 5, 6, 7]:
		activity.play_activity(cell, &"growth")
	_expect("日常特效同时播放有硬上限", activity._effects.size() == 3)
	activity._effects.clear()
	activity._on_command_settled(&"family.colonization.start", {
		"code": "CLAIMED", "target_cell": 3, "settled_day": activity._bind_day})
	_expect("读档旧回执不补播", activity._pending_claims.is_empty())
	map.visible_arr[3] = 0
	activity._on_command_settled(&"family.colonization.start", {
		"code": "CLAIMED", "target_cell": 3, "settled_day": activity._bind_day + 1})
	activity._process(0.1)
	_expect("落地等待视野提交", activity._effects.is_empty() and activity._pending_claims.size() == 1)
	map.visible_arr[3] = 1
	activity._process(0.1)
	_expect("视野提交后播放开拓成功", activity._effects.size() == 1 and activity._effects[0].kind == &"colony")
	_expect("扩建不会抢掉同格开拓成功的主反馈", not activity.play_activity(3, &"build")
		and activity._effects[0].kind == &"colony")
	activity._effects.clear()
	economy.queries = 0
	activity._sample_visible_development()
	_expect("每次最多读取十二个摘要", economy.queries > 0 and economy.queries <= 12)
	map.country_slot_arr.fill(1)
	economy.queries = 0
	activity._sample_visible_development()
	_expect("不读取外国人口摘要", economy.queries == 0)
	activity._sync_expeditions()
	_expect("规划面板外仍有行进路线", activity._routes.size() == 1)
	activity._process(5.0)
	_expect("特效按真实时间回收", activity._effects.is_empty())
	activity.configure(map, camera, host, player, economy, clock)
	_expect("重新绑定清理瞬态状态", activity._history.is_empty() and activity._routes.is_empty())
	var discovered := {}
	for i in range(25):
		discovered[activity._spiral_offset(i)] = true
	_expect("背景发现从镜头中心开始并覆盖近邻，无重复格位",
		activity._spiral_offset(0) == Vector2i.ZERO and discovered.size() == 25
		and discovered.has(Vector2i(2, 2)) and discovered.has(Vector2i(-2, -2)))
	await _test_worker_committed_development(holder)
	print("=== map_activity_layer: %s checks=%d failures=%d ===" % [
		"PASS" if failures == 0 else "FAIL", checks, failures])
	holder.queue_free()
	await process_frame
	quit(1 if failures else 0)


func _test_worker_committed_development(holder: Node2D) -> void:
	# A large viewport and a sparse player settlement reproduce the production
	# ACTIVE path: no daily_tick_completed is emitted at any point in this test.
	var map := MapData.new(60, 40)
	for row in 40:
		for col in 60:
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	map.country_slot_arr.resize(map.cell_count())
	map.country_slot_arr.fill(-1)
	map.visible_arr.resize(map.cell_count())
	map.visible_arr.fill(1)
	var selected := map.get_cell_by_cube(HexUtils.offset_to_cube(30, 20))
	map.country_slot_arr[selected.index] = 0
	var camera := Camera2D.new()
	holder.add_child(camera)
	camera.position = HexUtils.cube_to_world(selected.q, selected.r, 22.0)
	camera.zoom = Vector2(0.6, 0.6)
	camera.make_current()
	var host := HostStub.new()
	holder.add_child(host)
	host.intel.configure(map.cell_count())
	var player := PlayerStub.new()
	player.selection = selected
	holder.add_child(player)
	var economy := EconomyStub.new()
	var activity := ActivityScript.new()
	holder.add_child(activity)
	activity.configure(map, camera, host, player, economy, null)
	activity.set_process(false)
	await process_frame
	activity._process(0.01)
	_expect("普通缩放下优先建立选中格基线，无建筑情报也可观察人口",
		activity._history.has(selected.index) and activity._effects.is_empty())
	activity._time += 6.0
	economy.population = 108
	host.simulation_committed.emit(1, 2, 1)
	activity._process(0.02)
	_expect("仅后台正式提交即可在普通缩放触发人口增长，大视窗不丢基线",
		activity._effects.size() == 1 and activity._effects[0].kind == &"growth"
		and activity._effects[0].caption == "+8 人")
	activity._effects.clear()
	var native := VisualSnapshotStub.new()
	native.cell = selected.index
	host.intel.refresh_visible_cells(native, PackedInt32Array([selected.index]), map.visible_arr)
	activity._time += 0.7
	activity._process(0.02)
	_expect("原生可见建筑行发布能触发完工反馈，无需旧日更信号",
		activity._effects.size() == 1 and activity._effects[0].kind == &"build")
	activity._effects.clear()
	activity._cooldowns.clear()
	player.command_settled.emit(&"construction.build", {"ok": false, "cell_idx": selected.index})
	_expect("拒绝的建造命令不显示开工", activity._effects.is_empty())
	player.command_settled.emit(&"construction.build", {"ok": true, "cell_idx": selected.index})
	_expect("正式建造回执立即显示开工", activity._effects.size() == 1
		and activity._effects[0].kind == &"construction_start")
	activity._effects.clear()
	activity._cooldowns.clear()
	economy.pending = true
	host.simulation_committed.emit(2, 3, 2)
	activity._time += 0.7
	activity._process(0.02)
	_expect("后台摘要未就绪时保留重试，不丢弃提交唤醒", activity._dirty)
	economy.pending = false
	economy.population = 111
	activity._time += 0.7
	activity._process(0.02)
	_expect("摘要稍后到达仍能触发真实增长", activity._effects.size() == 1
		and activity._effects[0].caption == "+3 人")
	activity.configure(map, camera, host, player, economy, null)
	_expect("重绑只保留一个后台提交订阅", host.simulation_committed.get_connections().size() == 1)
	activity._effects.clear()
	activity.observe_development(selected.index, 111, 3)
	activity.play_activity(selected.index, &"growth", "+1 人")
	activity.observe_development(selected.index, 111, 4)
	_expect("完工会替换同格增长提示", activity._effects.size() == 1
		and activity._effects[0].kind == &"build")
	activity._effects.clear()
	map.visible_arr[selected.index] = 0
	activity._sample_visible_development()
	_expect("失去当前视野即删除观察基线", not activity._history.has(selected.index))

func _expect(label: String, passed: bool) -> void:
	checks += 1
	if not passed: failures += 1
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
