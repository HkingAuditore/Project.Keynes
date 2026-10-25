extends Node2D
class_name MapActivityLayer

signal activity_started(cell: int, kind: StringName, caption: String)

## 只读、瞬态地图反馈。正式回执驱动开拓；日常发展取有界的已提交摘要。
## 不消费原生 dirty 队列，不写情报、模拟或存档，也不订阅全量经济 trace。
const RouteScript = preload("res://scripts/rendering/colonization_route_layer.gd")
const DUST: Texture2D = preload("res://assets/vfx/settlement_dust.png")
const AMBIENT_CAP := 3
const MAJOR_CAP := 3
const SAMPLE_CAP := 12
const SCAN_CAP := 96
const HISTORY_CAP := 256

var _map: MapData
var _camera: Camera2D
var _host
var _player
var _economy
var _clock: WorldClock
var _hex_size := 22.0
var _wrap := 0.0
var _dirty := true
var _next_sample := 0.0
var _time := 0.0
var _scan_cursor := 0
var _history: Dictionary = {}
var _cooldowns: Dictionary = {}
var _effects: Array[Dictionary] = []
var _routes: Dictionary = {}
var _draw_elapsed := 0.0
var _planning_route: CanvasItem
var _border_layer: Node
var _bind_day := 0
var _pending_claims: Array[Dictionary] = []
var _intel: BuildingVisualIntelCache
var _watch_cursor := 0
var _changed_cells: Dictionary = {}
var _last_view_center := Vector2.INF
var _last_view_zoom := -1.0


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


func configure(map: MapData, camera: Camera2D, host, player, economy,
		clock: WorldClock, planning_route: CanvasItem = null, border_layer: Node = null) -> void:
	_disconnect_context()
	_map = map
	_camera = camera
	_host = host
	_player = player
	_economy = economy
	_clock = clock
	_planning_route = planning_route
	_border_layer = border_layer
	_bind_day = clock.day_index() if clock != null else 0
	_pending_claims.clear()
	_hex_size = float(host.hex_size)
	_wrap = float(host.map_wrap_period_x())
	_history.clear()
	_changed_cells.clear()
	_watch_cursor = 0
	_last_view_center = Vector2.INF
	_last_view_zoom = -1.0
	_cooldowns.clear()
	_effects.clear()
	for route in _routes.values():
		route.queue_free()
	_routes.clear()
	_scan_cursor = 0
	_dirty = true
	_next_sample = _time
	_host.daily_tick_completed.connect(_on_committed_day)
	if _host.has_signal("simulation_committed"):
		_host.simulation_committed.connect(_on_simulation_committed)
	_intel = _host.building_visual_intel_cache()
	if _intel != null:
		_intel.visible_rows_updated.connect(_on_visible_rows_updated)
	_player.command_settled.connect(_on_command_settled)
	set_process(true)
	queue_redraw()


func _disconnect_context() -> void:
	if is_instance_valid(_host) and _host.daily_tick_completed.is_connected(_on_committed_day):
		_host.daily_tick_completed.disconnect(_on_committed_day)
	if is_instance_valid(_host) and _host.has_signal("simulation_committed") \
			and _host.simulation_committed.is_connected(_on_simulation_committed):
		_host.simulation_committed.disconnect(_on_simulation_committed)
	if _intel != null and _intel.visible_rows_updated.is_connected(_on_visible_rows_updated):
		_intel.visible_rows_updated.disconnect(_on_visible_rows_updated)
	if is_instance_valid(_player) and _player.command_settled.is_connected(_on_command_settled):
		_player.command_settled.disconnect(_on_command_settled)


func _exit_tree() -> void:
	_disconnect_context()


func _on_committed_day(_report: Dictionary) -> void:
	_dirty = true


func _on_simulation_committed(_from_day: int, _to_day: int, _generation: int) -> void:
	_dirty = true


func _on_visible_rows_updated(cells: PackedInt32Array) -> void:
	# The existing visual host owns dirty consumption; only observe its published rows.
	for i in range(mini(cells.size(), HISTORY_CAP)):
		var cell := int(cells[i])
		if _owned_visible(cell) and _on_screen(cell) and _changed_cells.size() < HISTORY_CAP:
			_changed_cells[cell] = true
	_dirty = true


func _on_command_settled(id: StringName, result: Dictionary) -> void:
	if id == &"construction.build":
		if bool(result.get("ok", false)) and int(result.get("settled_day", _bind_day + 1)) > _bind_day:
			var cell := int(result.get("cell_idx", -1))
			if _owned_visible(cell):
				play_activity(cell, &"construction_start", "开始建造")
				_changed_cells[cell] = true
				_dirty = true
		return
	if id != &"family.colonization.start" and id != &"family.colonization.cancel":
		return
	_dirty = true
	var code := String(result.get("code", ""))
	var cell := int(result.get("target_cell", -1))
	if int(result.get("settled_day", _bind_day + 1)) <= _bind_day:
		return
	if code == "CLAIMED":
		# Country ownership/vision may publish after the receipt in this frame.
		if _pending_claims.size() < 16:
			_pending_claims.append({"cell": cell, "expires": _time + 1.5})
		_history.erase(cell)
	elif code == "RELOCATED":
		play_activity(cell, &"build", "迁徙抵达")
	elif code == "STARTED":
		var detail: Dictionary = _player.get_family_expedition_snapshot(
			int(result.get("expedition_handle", 0)))
		if bool(detail.get("ok", false)):
			play_activity(int(detail.get("source_cell", -1)), &"departure", "开拓队出发")


func _process(delta: float) -> void:
	_time += delta
	if _map == null or _camera == null:
		return
	if _camera.global_position.distance_squared_to(_last_view_center) > 1.0 \
			or not is_equal_approx(_camera.zoom.x, _last_view_zoom):
		_last_view_center = _camera.global_position
		_last_view_zoom = _camera.zoom.x
		_scan_cursor = 0
		_dirty = true
	for i in range(_pending_claims.size() - 1, -1, -1):
		var pending := _pending_claims[i]
		if _can_show(int(pending.cell)):
			play_activity(int(pending.cell), &"colony", "开拓成功")
			_pending_claims.remove_at(i)
		elif _time >= float(pending.expires):
			_pending_claims.remove_at(i)
	if _dirty and _time >= _next_sample:
		_dirty = false
		_next_sample = _time + UITokens.MAP_ACTIVITY_INTERVAL
		_sync_expeditions()
		_sample_visible_development()
	for route in _routes.values():
		route.visible = not is_instance_valid(_planning_route) or not _planning_route.visible
	for i in range(_effects.size() - 1, -1, -1):
		var effect := _effects[i]
		effect.age = float(effect.age) + delta
		if float(effect.age) >= float(effect.duration) or not _can_show(int(effect.cell)):
			_effects.remove_at(i)
	_draw_elapsed += delta
	if _draw_elapsed >= 1.0 / 30.0:
		_draw_elapsed = 0.0
		# One last redraw clears the final expired effect, then idle costs no drawing.
		if not _effects.is_empty() or bool(get_meta(&"had_effects", false)):
			queue_redraw()
		set_meta(&"had_effects", not _effects.is_empty())


func _sync_expeditions() -> void:
	var page: Dictionary = _player.get_family_expeditions(0, 64)
	if not bool(page.get("ok", false)):
		return
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	var states: PackedInt32Array = page.get("states", PackedInt32Array())
	var keep := {}
	for i in range(handles.size()):
		if keep.size() >= (2 if OS.has_feature("mobile") else 4):
			break
		if i >= states.size() or int(states[i]) not in [1, 3]:
			continue
		var detail: Dictionary = _player.get_family_expedition_snapshot(handles[i])
		if not bool(detail.get("ok", false)):
			continue
		keep[handles[i]] = true
		if not _routes.has(handles[i]):
			var route := RouteScript.new()
			add_child(route)
			route.set_context(_map, _clock, _hex_size, _wrap)
			_routes[handles[i]] = route
		_routes[handles[i]].show_expedition(detail)
	for handle in _routes.keys():
		if not keep.has(handle):
			_routes[handle].queue_free()
			_routes.erase(handle)


func _sample_visible_development() -> void:
	# Reserve part of the read budget for discovery, while revisiting selected /
	# already observed settlements regardless of the size of the viewport grid.
	if _camera.zoom.x < UITokens.MAP_ACTIVITY_MIN_ZOOM or _economy == null:
		_history.clear()
		_changed_cells.clear()
		return
	for cell in _history.keys():
		if not _owned_visible(int(cell)) or not _on_screen(int(cell)):
			_history.erase(cell)
	var candidates: Array[int] = []
	var selected := _selected_cell_index()
	_append_candidate(candidates, selected)
	for cell in _changed_cells.keys():
		_append_candidate(candidates, int(cell))
		_changed_cells.erase(cell)
		if candidates.size() >= 4:
			break
	var watched := _history.keys()
	for i in range(watched.size()):
		if candidates.size() >= 8:
			break
		_watch_cursor %= watched.size()
		_append_candidate(candidates, int(watched[_watch_cursor]))
		_watch_cursor += 1
	var corners := get_viewport_rect()
	var inverse := get_viewport().get_canvas_transform().affine_inverse()
	var top := HexUtils.world_to_cube(inverse * corners.position, _hex_size)
	var bottom := HexUtils.world_to_cube(inverse * corners.end, _hex_size)
	var lo := HexUtils.cube_to_offset(top.x, top.y) - Vector2i(1, 1)
	var hi := HexUtils.cube_to_offset(bottom.x, bottom.y) + Vector2i(1, 1)
	var span := Vector2i(maxi(1, hi.x - lo.x + 1), maxi(1, hi.y - lo.y + 1))
	var center_cube := HexUtils.world_to_cube(_camera.global_position, _hex_size)
	var center := HexUtils.cube_to_offset(center_cube.x, center_cube.y)
	var side := maxi(span.x, span.y) + 2
	var total := side * side
	for unused in range(mini(SCAN_CAP, total)):
		if candidates.size() >= SAMPLE_CAP:
			break
		var at := _scan_cursor % total
		_scan_cursor = (_scan_cursor + 1) % total
		var off := center + _spiral_offset(at)
		if off.y < 0 or off.y >= _map.height:
			continue
		var cube := HexUtils.offset_to_cube(posmod(off.x, _map.width), off.y)
		var cell := _map.get_cell_by_cube(cube)
		if cell != null:
			_append_candidate(candidates, int(cell.index))
	for cell in candidates:
		var summary: Dictionary = _economy.population_cell_summary(cell)
		if bool(summary.get("ok", false)):
			var row := _intel.row_for_cell(cell) if _intel != null else {}
			var installed := 0
			for count in row.get("counts", PackedInt64Array()):
				installed += int(count)
			observe_development(cell, int(summary.get("population", 0)), installed)
		elif bool(summary.get("busy", false)) or bool(summary.get("read_view_pending", false)):
			_changed_cells[cell] = true
			_dirty = true


func _append_candidate(cells: Array[int], cell: int) -> void:
	if not cells.has(cell) and _owned_visible(cell) and _on_screen(cell):
		cells.append(cell)


func _spiral_offset(index: int) -> Vector2i:
	# Discover nearby settlements first, rather than spending many pulses in
	# the empty top rows of a wide viewport before reaching the camera center.
	if index == 0:
		return Vector2i.ZERO
	var ring := ceili((sqrt(float(index + 1)) - 1.0) * 0.5)
	var side := ring * 2
	var distance := (side + 1) * (side + 1) - 1 - index
	if distance < side:
		return Vector2i(ring - distance, -ring)
	if distance < side * 2:
		return Vector2i(-ring, -ring + distance - side)
	if distance < side * 3:
		return Vector2i(-ring + distance - side * 2, ring)
	return Vector2i(ring, ring - (distance - side * 3))


func _selected_cell_index() -> int:
	if _player == null or not _player.has_method("selected_cell"):
		return -1
	var cell = _player.selected_cell()
	return int(cell.index) if cell != null else -1


func observe_development(cell: int, population: int, buildings: int) -> void:
	var previous: Dictionary = _history.get(cell, {})
	if not previous.is_empty():
		if buildings > int(previous.buildings):
			play_activity(cell, &"build", "扩建完成")
		elif population > int(previous.population):
			play_activity(cell, &"growth", "+%s 人" % UITokens.format_compact_number_cn(
				float(population - int(previous.population))))
	if _history.size() >= HISTORY_CAP and not _history.has(cell):
		_history.erase(_history.keys()[0])
	_history[cell] = {"population": population, "buildings": buildings, "time": _time}


func _owned_visible(cell: int) -> bool:
	return cell >= 0 and cell < _map.country_slot_arr.size() \
		and int(_map.country_slot_arr[cell]) == int(_host.player_country_slot()) \
		and _host.player_country_slot() >= 0 and _can_show(cell)


func _can_show(cell: int) -> bool:
	return _map != null and cell >= 0 and cell < _map.cell_count() \
		and (not _host.is_fog_of_war_enabled() or (cell < _map.visible_arr.size() \
		and _map.visible_arr[cell] != 0))


func _position_for(cell: int) -> Vector2:
	var hex := _map.cell_at(cell)
	return HexUtils.nearest_display_world(HexUtils.cube_to_world(hex.q, hex.r, _hex_size),
		_camera.global_position.x, _wrap)


func _on_screen(cell: int) -> bool:
	return get_viewport_rect().grow(24.0).has_point(
		get_viewport().get_canvas_transform() * _position_for(cell))


## GameAudio 缓存：活动检测每秒最多 ~1.5 次，实测开销可忽略，
## 但没必要每次都做一次 `/root/GameAudio` 的节点查找。
var _audio_cache: Node = null

## 视觉与听觉共用同一套过滤（视野 + 屏幕内 + 缩放 + 每格冷却），
## 所以玩家看不到的活动也不会响，省掉了音频层再做一次节流。
## 人口的增量检测目前只有这里有（引擎侧没有人口变化事件），
## 代价是只覆盖采样到的可见格 —— 对音效来说正好。
func _play_activity_audio(kind: StringName, cell: int) -> void:
	var cue: StringName = {
		&"build": &"building_complete",
	# growth（人口增长）不在这里发声：已改由原生市场级人口事件驱动，
	# 两处都接会对同一次增长响两声。飘字仍然保留。
		&"colony": &"territory_expand",
		&"departure": &"territory_expand",
	}.get(kind, &"")
	if cue.is_empty():
		return
	if _audio_cache == null or not is_instance_valid(_audio_cache):
		_audio_cache = get_node_or_null("/root/GameAudio")
	# 传地块世界坐标 —— GameAudio 开了空间化时按这个位置做 3D 衰减，
	# 没开则是普通 2D 播放，坐标被忽略。
	if _audio_cache != null and _audio_cache.has_method("play_event_cue"):
		_audio_cache.play_event_cue(cue, _position_for(cell))

func play_activity(cell: int, kind: StringName, caption: String = "") -> bool:
	if not _can_show(cell) or not _on_screen(cell):
		return false
	var major := kind == &"colony" or kind == &"departure"
	if not major and _camera.zoom.x < UITokens.MAP_ACTIVITY_MIN_ZOOM:
		return false
	var key := "%d:%s" % [cell, kind]
	if _time < float(_cooldowns.get(key, -1.0)):
		return false
	_play_activity_audio(kind, cell)
	var count := 0
	var replace_index := -1
	var selected := _selected_cell_index()
	for i in range(_effects.size()):
		var effect := _effects[i]
		if int(effect.cell) == cell:
			if not major:
				if bool(effect.major):
					return false
				# A committed build must remain visible when growth/start feedback
				# already occupies this cell. Growth never displaces construction.
				if kind == &"growth" or (kind == &"construction_start" and effect.kind == &"build"):
					return false
				replace_index = i
		if bool(effect.major) == major:
			count += 1
	var cap := MAJOR_CAP if major else (1 if OS.has_feature("mobile") else AMBIENT_CAP)
	if count >= cap and replace_index < 0:
		if not major and cell == selected:
			for i in range(_effects.size()):
				if not bool(_effects[i].major) and int(_effects[i].cell) != selected:
					replace_index = i
					break
		if replace_index < 0:
			return false
	if replace_index >= 0:
		_effects.remove_at(replace_index)
	if major:
		for i in range(_effects.size() - 1, -1, -1):
			if int(_effects[i].cell) == cell:
				_effects.remove_at(i)
	var building := kind == &"build" or kind == &"construction_start"
	var duration := UITokens.MAP_COLONY_DURATION if major else (
		UITokens.MAP_BUILD_DURATION if building else UITokens.MAP_GROWTH_DURATION)
	var cooldown := 2.0 if major else (UITokens.MAP_BUILD_COOLDOWN if building
		else UITokens.MAP_GROWTH_COOLDOWN)
	if _cooldowns.size() >= HISTORY_CAP:
		_cooldowns.clear()
	_cooldowns[key] = _time + cooldown
	_effects.append({"cell": cell, "kind": kind, "caption": caption,
		"major": major, "age": 0.0, "duration": duration,
		"reduced": UIAnimation.reduced_motion()})
	if kind == &"colony" and is_instance_valid(_border_layer):
		_border_layer.celebrate_cell(_position_for(cell))
	activity_started.emit(cell, kind, caption)
	queue_redraw()
	return true


func _draw() -> void:
	if _camera == null:
		return
	for effect in _effects:
		var cell := int(effect.cell)
		if not _can_show(cell) or not _on_screen(cell):
			continue
		_draw_effect(_position_for(cell), effect)


func _draw_effect(center: Vector2, effect: Dictionary) -> void:
	var t := clampf(float(effect.age) / float(effect.duration), 0.0, 1.0)
	var reduced := bool(effect.reduced)
	var major := bool(effect.major)
	var growth: bool = effect.kind == &"growth"
	var scale_inv := 1.0 / maxf(_camera.zoom.x, 0.01)
	var fade := smoothstep(0.0, 0.10, t) * (1.0 - smoothstep(0.55, 1.0, t))
	var gold := UITokens.MAP_ACTIVITY_GOLD
	var ink := UITokens.INK_DEEP
	var color := UITokens.MAP_ACTIVITY_GREEN if growth else gold
	var spread := 1.0 - pow(1.0 - minf(1.0, t * 1.8), 3.0)
	if major:
		var hex := PackedVector2Array()
		for i in range(7):
			hex.append(center + Vector2.from_angle(PI / 6.0 + i * TAU / 6.0) * _hex_size * 0.93)
		draw_colored_polygon(hex.slice(0, 6), Color(gold, fade * 0.13))
		draw_polyline(hex, Color(ink, fade * 0.85), 3.6 * scale_inv, true)
		draw_polyline(hex, Color(gold, fade), 1.7 * scale_inv, true)
	if not reduced:
		if not growth:
			var dust_size := _hex_size * (3.5 if major else 1.5) * lerpf(0.35, 1.0, spread)
			draw_texture_rect(DUST, Rect2(center - Vector2.ONE * dust_size * 0.5,
				Vector2.ONE * dust_size), false, Color(1.0, 0.95, 0.83, fade * (0.48 if major else 0.25)))
		var radius := _hex_size * lerpf(0.25, 1.6 if major else 0.55, spread)
		draw_arc(center, radius, 0.0, TAU, 48, Color(color, fade * (0.75 if major else 0.45)),
			1.3 * scale_inv, true)
		if major:
			draw_arc(center, radius * 0.80, 0.0, TAU, 48, Color(gold, fade * 0.28), 2.0 * scale_inv, true)
		for i in range(16 if major else 5):
			var angle := float(i) * 2.39996 + float(int(effect.cell) % 11)
			var distance := _hex_size * (0.2 + spread * (1.7 if major else 0.65))
			var mote := center + Vector2.from_angle(angle) * distance * (0.55 + fmod(i * 0.37, 0.45))
			mote.y -= t * _hex_size * (0.8 if growth else 0.25)
			draw_circle(mote, (1.8 if major else 1.0) * scale_inv, Color(color, fade * 0.8))
	var icon := &"map.expedition" if major else (&"map.population" if growth else &"map.construction")
	var rise := 0.0 if reduced else spread * (14.0 if major else 7.0) * scale_inv
	var badge_center := center - Vector2(0.0, _hex_size * 0.70 + rise)
	var badge_r := (12.0 if major else 10.0) * scale_inv
	# Atlas seal: a stable ink backing makes the feedback readable on snow and sand.
	draw_circle(badge_center, badge_r + scale_inv, Color(color, fade))
	draw_circle(badge_center, badge_r, Color(ink, fade * 0.96))
	IconCatalog.draw_icon(self, icon, Rect2(badge_center - Vector2.ONE * badge_r * 0.85,
		Vector2.ONE * badge_r * 1.7), fade)
	if major or _camera.zoom.x >= UITokens.MAP_ACTIVITY_TEXT_ZOOM \
			or int(effect.cell) == _selected_cell_index():
		draw_set_transform(badge_center + Vector2(0, -badge_r - 7.0 * scale_inv),
			0.0, Vector2.ONE * scale_inv)
		var caption := String(effect.caption)
		var font_size := 15 if major else 12
		var width := UITokens.UI_FONT.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		draw_rect(Rect2(-width * 0.5 - 7.0, -font_size - 4.0, width + 14.0, font_size + 10.0),
			Color(UITokens.INK_DEEP, fade * 0.9))
		draw_string(UITokens.UI_FONT, Vector2(-width * 0.5, 0), caption,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(UITokens.TEXT_MAIN, fade))
		draw_set_transform(Vector2.ZERO)
