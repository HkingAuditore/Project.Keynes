extends Node2D
class_name MilitaryMapLayers

## 军事地图图层管理器：创建并驱动全部 military_* 图层。
##
## 挂载位置：WorldRuntimeHost 在 _bind_renderer_and_camera 的末尾创建它，
## 由宿主脚本 create_child("MilitaryMapLayers") 后 `add_child`；PlayerGame 在
## world_ready 里 configure()（那时 map / world / camera / clock 才都在）。
##
## z 序（设计稿 §14.1，全部低于迷雾层 12）：
##   5  占领斜纹     MilitaryOccupationLayer（DataOverlay 间接寻址，只在控制变化时上传）
##   6  控制区域     MilitaryAreaLayer（国界 ribbon 算法的虚线版）
##   8  战线         MilitaryFrontLayer（增量战线，front_revision 驱动）
##   9  交战环       MilitaryBattleLayer
##   9  军需车队     MilitaryConvoyLayer（TradeActivityLayer 的 MultiMesh 做法）
##   10 部队棋子     MilitaryArmyTokenLayer（纸片贴纸 + 补间 + 聚合）
##   11 行军路线     MilitaryRouteLayer（ colonization route 的折线做法）
##
## 每帧只做一件事：把 feed 的数据推给各层。feed 每次 _process 最多调用一次
## get_military_render_snapshot(revision)（~0.5 ms 预算），各层按 revision /
## control_revision / front_revision / army_signature 决定要不要重建。
##
## 迷雾：外国部队 / 交战 / 敌方车队只在 FOG_VISIBLE 显示，由 feed.apply_fog()
## 与本层下方 `_update_fog_sources()` 统一处理。

const LAYER_NODES := [
	["MilitaryOccupationLayer", "res://scripts/rendering/military_occupation_layer.gd"],
	["MilitaryAreaLayer", "res://scripts/rendering/military_area_layer.gd"],
	["MilitaryFrontLayer", "res://scripts/rendering/military_front_layer.gd"],
	["MilitaryBattleLayer", "res://scripts/rendering/military_battle_layer.gd"],
	["MilitaryConvoyLayer", "res://scripts/rendering/military_convoy_layer.gd"],
	["MilitaryArmyTokenLayer", "res://scripts/rendering/military_army_token_layer.gd"],
	["MilitaryRouteLayer", "res://scripts/rendering/military_route_layer.gd"],
]

## 点击拾取：点到战线中点的容差（占 hex 半径的比例）。必须明显小于半格，
## 否则正常选格会被战线抢走。
const PICK_EDGE_TOLERANCE_RATIO := 0.42
## 战线扇区（军务档案的一页）向上限：BFS 只在这两个预算内展开。
const SECTOR_MAX_EDGES := 96
const SECTOR_MAX_CELLS := 128
## 一侧最多返回多少支部队句柄（对阵表要拿它们去读攻防/士气）。
const SECTOR_MAX_SIDE_ARMIES := 24
const Q16 := 65536.0

var occupation_layer: MilitaryOccupationLayer
var area_layer: MilitaryAreaLayer
var front_layer: MilitaryFrontLayer
var battle_layer: MilitaryBattleLayer
var convoy_layer: MilitaryConvoyLayer
var token_layer: MilitaryArmyTokenLayer
var route_layer: MilitaryRouteLayer

var _feed
var _map
var _world
var _camera: Camera2D
var _clock: WorldClock
var _host
var _ext
var _configured := false
var _enabled := true
var _layers_enabled := true
var _hex_size := 22.0
var _wrap := 0.0
var _last_poll_usec := 0
var _poll_accum_usec := 0
var _poll_frames := 0
var _poll_p95_usec := 0
var _frame := 0
var _wall_time := 0.0
var _player_slot := -1
var _last_control := -1
var _last_front := -1
var _last_army_sig := -1
var _selected_army := 0
var _feed_unavailable := false
## 战线边集合（key -> 在 feed.front_edge_key 里的下标）。只在
## front_snapshot_revision 变化、且军务档案正在看战线时重建。
var _front_edge_set: Dictionary = {}
var _front_set_revision := -1


func _ready() -> void:
	top_level = true
	z_as_relative = false
	set_process(true)


## PlayerGame / 宿主在 world_ready 调用。幂等：重复调用只重绑数据。
func configure(map, world, camera: Camera2D, clock: WorldClock, host) -> void:
	_ensure_layers()
	_map = map
	_world = world
	_camera = camera
	_clock = clock
	_host = host
	_hex_size = float(host.hex_size) if host != null and "hex_size" in host else 22.0
	_wrap = float(host.map_wrap_period_x()) if host != null \
		and host.has_method("map_wrap_period_x") else 0.0
	if _wrap <= 0.0 and map != null:
		_wrap = HexUtils.wrap_period_x(int(map.width), _hex_size)
	_ext = _resolve_ext()
	_feed = _feed_for(host)
	player_country_slot()
	_last_control = -1
	_last_front = -1
	_last_army_sig = -1
	_feed_unavailable = false
	_front_edge_set.clear()
	_front_set_revision = -1

	var dims := Vector2i(1, 1)
	var atlas: Texture2D = null
	var bounds := Rect2()
	if world != null:
		dims = world.lut_dims
		atlas = world.enum_atlas_tex
		bounds = world.world_bounds
	if bounds.size.x <= 0.0 and host != null and host.has_method("get_renderer"):
		var renderer = host.get_renderer()
		if renderer != null and renderer.has_method("get_world_bounds"):
			bounds = renderer.get_world_bounds()
	if occupation_layer != null:
		occupation_layer.configure(map, atlas, dims, bounds, _hex_size, _wrap)
		occupation_layer.set_wall_time(_wall_time)
	if area_layer != null:
		area_layer.configure(map, _hex_size, _wrap)
	if front_layer != null:
		front_layer.configure(map, _hex_size, _wrap, _owner_slots())
	if battle_layer != null:
		battle_layer.configure(map, _camera, _hex_size, _wrap)
	if convoy_layer != null:
		convoy_layer.configure(map, _camera, _hex_size, _wrap)
	if token_layer != null:
		token_layer.configure(map, _camera, _hex_size, _wrap)
		_configure_token_formation_visuals()
	if route_layer != null:
		route_layer.configure(map, _clock, _hex_size, _wrap)
	_apply_player_slot()
	_configured = true
	# 首帧立刻拉一次快照，避免进世界后先空一帧。
	_poll()


func is_configured() -> bool:
	return _configured


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	_apply_visibility()


## 地图图层总开关（GM / 设置面板），不影响军事面板里的数据。
func set_layers_enabled(enabled: bool) -> void:
	_layers_enabled = enabled
	_apply_visibility()


func _apply_visibility() -> void:
	var on := _enabled and _layers_enabled \
		and _feed != null and bool(_feed.ok)
	for layer in _all_layers():
		if layer != null and layer.has_method("set_enabled"):
			layer.set_enabled(on)


func _all_layers() -> Array:
	return [occupation_layer, area_layer, front_layer, battle_layer,
		convoy_layer, token_layer, route_layer]


func _ensure_layers() -> void:
	if token_layer != null:
		return
	var parent := self
	for entry in LAYER_NODES:
		var node_name: String = entry[0]
		var existing := parent.get_node_or_null(node_name)
		if existing == null:
			var script := load(entry[1]) as Script
			if script == null:
				push_warning("MilitaryMapLayers: missing script %s" % entry[1])
				continue
			existing = Node2D.new()
			existing.name = node_name
			existing.set_script(script)
			parent.add_child(existing)
		match node_name:
			"MilitaryOccupationLayer":
				occupation_layer = existing as MilitaryOccupationLayer
			"MilitaryAreaLayer":
				area_layer = existing as MilitaryAreaLayer
			"MilitaryFrontLayer":
				front_layer = existing as MilitaryFrontLayer
			"MilitaryBattleLayer":
				battle_layer = existing as MilitaryBattleLayer
			"MilitaryConvoyLayer":
				convoy_layer = existing as MilitaryConvoyLayer
			"MilitaryArmyTokenLayer":
				token_layer = existing as MilitaryArmyTokenLayer
			"MilitaryRouteLayer":
				route_layer = existing as MilitaryRouteLayer


## 全工程唯一的一次快照轮询。宿主脚本（world_runtime_host）在自己的 _process
## 里转调这里，保证图层刷新排在日结算之后、且在 0.5 ms 预算内。
func poll_snapshot() -> void:
	if not _configured or not _enabled:
		return
	_poll()


func player_country_slot() -> int:
	if _host != null and _host.has_method("player_country_slot"):
		_player_slot = int(_host.player_country_slot())
	elif _player_slot < 0 and _map != null:
		# 宿主没有玩家 slot 时（调试 / 沙盒）保持 -1：所有部队都按「自己人」渲染。
		_player_slot = -1
	return _player_slot


func _apply_player_slot() -> void:
	for layer in _all_layers():
		if layer != null and layer.has_method("set_player_slot"):
			layer.set_player_slot(_player_slot)


func _refresh_player_slot_binding() -> bool:
	var previous := _player_slot
	var current := player_country_slot()
	if current == previous:
		return false
	_apply_player_slot()
	return true


func _resolve_ext():
	if _host != null and _host.has_method("generator"):
		var generator = _host.generator()
		if generator != null and generator.has_method("get_data_core_world_ext"):
			return generator.get_data_core_world_ext()
	return null


func _configure_token_formation_visuals() -> void:
	if token_layer == null:
		return
	var view: Dictionary = {}
	if _ext != null:
		var native_view: Variant = _ext.get_military_catalog_view()
		if native_view is Dictionary:
			view = native_view
	if not bool(view.get("ok", false)) and _host != null \
			and _host.has_method("generator"):
		var generator = _host.generator()
		if generator != null and generator.has_method("get_military_facade"):
			var facade = generator.get_military_facade()
			if facade != null and facade.has_method("catalog_view"):
				var facade_view: Variant = facade.catalog_view()
				if facade_view is Dictionary:
					view = facade_view
	var units_value: Variant = view.get("units", [])
	var units: Array = units_value if units_value is Array else []
	var report: Dictionary = token_layer.configure_formation_catalog(units)
	if not bool(report.get("ok", false)):
		return


func _feed_for(host):
	if host != null and "military_render_feed" in host:
		var existing = host.get("military_render_feed")
		if existing != null:
			return existing
	return MilitaryRenderFeed.new()


func _owner_slots() -> PackedInt32Array:
	if _map == null:
		return PackedInt32Array()
	return _map.country_slot_arr


## 交战段进攻方所在格。原生快照的 engagements 若带 attacker_cell 就用它，
## 否则退化为规范化边 (min, max) 的较小端——两条规则都只影响迷雾裁剪，
## 不影响中点位置（中点永远在边的中点）。
func _attacker_cells() -> PackedInt32Array:
	var provided: PackedInt32Array = _feed.attacker_cell_cells
	if provided.size() == _feed.engagement_count:
		return provided
	return _feed.engagement_cell_a


func _poll() -> void:
	var started := Time.get_ticks_usec()
	_feed.set_clock(_clock)
	_refresh_player_slot_binding()
	_feed.poll(_ext, int(_feed.revision), _player_slot)
	_last_poll_usec = Time.get_ticks_usec() - started
	_poll_accum_usec += _last_poll_usec
	_poll_frames += 1
	if _poll_frames >= 60:
		# 粗略的窗口统计（真正的 p95 在诊断面板里由逐帧样本算）。
		var avg := float(_poll_accum_usec) / float(maxi(1, _poll_frames))
		_poll_p95_usec = int(maxf(float(_poll_p95_usec) * 0.7, avg * 1.6))
		_poll_accum_usec = 0
		_poll_frames = 0
	if not _feed.ok:
		# Native snapshot unavailable (old DLL / runtime failure): fail closed.
		# Clear feed-backed geometry once and hide every military layer so stale
		# fronts, battles, convoys or occupation hatches cannot remain on screen.
		if not _feed_unavailable:
			_feed_unavailable = true
			_last_control = -1
			_last_front = -1
			_last_army_sig = -1
			for layer in [occupation_layer, area_layer, front_layer, battle_layer,
					convoy_layer, token_layer]:
				if layer != null and layer.has_method("clear"):
					layer.clear()
			if route_layer != null:
				route_layer.clear_route()
		_apply_visibility()
		return
	_feed_unavailable = false
	_apply_visibility()
	_feed.map_visible_hint = _map.visible_arr if _map != null else PackedByteArray()
	var fog := _fog_enabled()
	_feed.apply_fog(_map, fog)
	_push_layers(fog)
	_apply_visibility()


func _fog_enabled() -> bool:
	if _force_fog_for_tests >= 0:
		return _force_fog_for_tests == 1
	if _host == null:
		return false
	if _host.has_method("is_fog_of_war_enabled"):
		return bool(_host.is_fog_of_war_enabled()) and not _feed.map_visible_hint.is_empty()
	return false


## 测试/工具钩子：强制迷雾开关（-1 = 跟随宿主）。生产代码不调用。
var _force_fog_for_tests := -1


func set_fog_override_for_tests(value: int) -> void:
	_force_fog_for_tests = value


func _push_layers(fog: bool) -> void:
	if occupation_layer != null and _feed.control_revision != _last_control:
		_last_control = _feed.control_revision
		occupation_layer.sync(_feed.control_revision, _feed.controller_cells,
			_feed.controller_slots)
	if front_layer != null and _feed.front_revision != _last_front:
		_last_front = _feed.front_revision
		# 战线只画两端至少一端可见的接触边；战线的位置本身是公开信息（交战线）。
		front_layer.set_front_edges(_feed.front_edge_key, _feed.front_edge_progress)
	if area_layer != null:
		area_layer.set_area(_feed.selected_area_cells)
	if battle_layer != null:
		battle_layer.set_engagements(_feed.engagement_cell_a, _feed.engagement_cell_b,
			_feed.engagement_progress, _feed.engagement_side, _feed.engagement_battle,
			_feed.map_visible_hint, fog, _attacker_cells())
	if convoy_layer != null:
		convoy_layer.set_convoys(_feed.convoy_current, _feed.convoy_dest,
			_feed.convoy_country, _feed.convoy_risk, _feed.map_visible_hint, fog)
	if token_layer != null:
		token_layer.set_armies(_feed)
		token_layer.set_visual_day(_feed.visual_day)
		_last_army_sig = _feed.army_signature


func _process(delta: float) -> void:
	_wall_time += delta
	_frame += 1
	if not _configured or not _enabled:
		return
	if occupation_layer != null:
		occupation_layer.set_wall_time(_wall_time)
	# 宿主没接 poll 时自己做一次（例如调试 main.gd 直接用本管理器）。
	if _host == null or not ("military_map_polled_by_host" in _host):
		poll_snapshot()


## 路径显示入口：军事面板选中部队时调用。
func show_army_route(route_cells: PackedInt32Array, departure_day: int,
		due_day: int) -> void:
	if route_layer != null:
		route_layer.show_route(route_cells, departure_day, due_day)


## 部队指令（移动）的第一段：PlayerController 把 preview_military_path 的路线交给
## z11 路线层画成冷色虚线；第二次点击确认后由 clear_route() 收掉。
func show_military_path_preview(route_cells: PackedInt32Array, travel_days: int) -> void:
	show_path_preview(route_cells, PackedInt32Array(), travel_days)


func show_path_preview(route_cells: PackedInt32Array,
		cumulative_costs: PackedInt32Array, travel_days: int) -> void:
	if route_layer != null:
		route_layer.show_preview(route_cells, cumulative_costs, travel_days)


func clear_route() -> void:
	if route_layer != null:
		route_layer.clear_route()


func set_selected_cell(cell: int) -> void:
	if token_layer != null:
		token_layer.set_selected_cell(cell)


## ── 点击拾取（军务档案入口）──────────────────────────────────────────────
## 优先级：部队棋子 → 战线边 → 空（交回地块选择）。
## 只在点击时调用；迷雾由 token_layer 的 army_visible 把关，战线位置视为公开。
func pick_at_world(world: Vector2) -> Dictionary:
	if not _configured or not _enabled or _map == null or _feed == null \
			or not bool(_feed.ok):
		return {}
	if token_layer != null:
		var army: Dictionary = token_layer.pick_army_at(world)
		var handle := int(army.get("handle", 0))
		if handle != 0:
			return {"kind": "army", "handle": handle,
				"cell": int(army.get("cell", -1)), "row": int(army.get("row", -1))}
	if front_layer != null and int(_feed.front_edge_count) > 0:
		var edge: int = front_layer.pick_edge_at(
			world, _hex_size * PICK_EDGE_TOLERANCE_RATIO)
		if edge >= 0:
			return {"kind": "front", "edge": edge, "cell": int(edge) / 6}
	return {}


func army_anchor_world(handle: int) -> Vector2:
	if token_layer == null:
		return Vector2(NAN, NAN)
	return token_layer.army_world_position(handle)


## 同格部队（军务档案的「同格部队」名录）。只返回当前可见的行。
func armies_at_cell(cell: int) -> Array:
	var out: Array = []
	if _feed == null or not bool(_feed.ok) or cell < 0:
		return out
	for row in _feed.army_count:
		if int(_feed.army_cell[row]) != cell:
			continue
		if int(_feed.army_visible[row]) == 0:
			continue
		out.append({
			"handle": int(_feed.army_handle[row]),
			"owner_slot": int(_feed.army_owner[row]),
			"headcount": int(_feed.army_headcount[row]),
			"cell": int(_feed.army_cell[row]),
		})
	return out


func army_cell(handle: int) -> int:
	if _feed == null or not bool(_feed.ok) or handle == 0:
		return -1
	for row in _feed.army_count:
		if int(_feed.army_handle[row]) == handle:
			return int(_feed.army_cell[row])
	return -1


func front_edge_anchor_world(edge_key: int) -> Vector2:
	if front_layer == null:
		return Vector2(NAN, NAN)
	return front_layer.edge_world_midpoint(edge_key)


func set_selected_front_edge(edge_key: int) -> void:
	if front_layer != null:
		front_layer.set_selected_edge(edge_key)


## 战线边集合：key -> feed 下标。12k 边的重建只发生在前线变化时。
func _ensure_front_edge_set() -> bool:
	if _feed == null or _map == null:
		return false
	var revision := int(_feed.front_snapshot_revision)
	if _front_set_revision == revision and not _front_edge_set.is_empty():
		return true
	_front_set_revision = revision
	_front_edge_set.clear()
	var keys: PackedInt32Array = _feed.front_edge_key
	var count := keys.size()
	for i in count:
		_front_edge_set[int(keys[i])] = i
	return not _front_edge_set.is_empty()


## 军务档案的「战线扇区」：从被点击的边出发，沿共享格 BFS 展开一段连续战线。
## 返回按沿带角度排好序的边（≤ max_edges），外加交战段、双方在场兵力与锚点。
func front_sector(edge_key: int, max_edges: int = SECTOR_MAX_EDGES) -> Dictionary:
	if _map == null or _feed == null or not bool(_feed.ok) or edge_key < 0:
		return {}
	if not _ensure_front_edge_set() or not _front_edge_set.has(edge_key):
		return {}
	var neighbors: PackedInt32Array = _map.neighbor_indices_packed()
	if neighbors.is_empty():
		return {}
	var owners: PackedInt32Array = _map.country_slot_arr
	var origin: int = int(edge_key) / 6
	var queue := PackedInt32Array([origin])
	var queue_cursor := 0
	var seen_cells := {origin: true}
	var seen_edges := {}
	var cells := PackedInt32Array()
	var keys := PackedInt32Array()
	var progress := PackedFloat32Array()
	var active := PackedByteArray()
	while queue_cursor < queue.size() and keys.size() < max_edges \
			and cells.size() < SECTOR_MAX_CELLS:
		var cell: int = int(queue[queue_cursor])
		queue_cursor += 1
		cells.append(cell)
		var base := cell * 6
		for dir in 6:
			var index := base + dir
			if index < 0 or index >= neighbors.size():
				break
			var neighbor := int(neighbors[index])
			if neighbor < 0 or neighbor == cell:
				continue
			var key := index
			if neighbor < cell:
				key = _edge_key_between(neighbors, neighbor, cell)
			if key < 0 or not _front_edge_set.has(key) or seen_edges.has(key):
				continue
			seen_edges[key] = true
			var slot := int(_front_edge_set[key])
			var byte := 255
			if slot >= 0 and slot < _feed.front_edge_progress.size():
				byte = int(_feed.front_edge_progress[slot])
			keys.append(key)
			active.append(0 if byte == 255 else 1)
			progress.append(0.0 if byte == 255 else float(byte) / 254.0)
			if not seen_cells.has(neighbor):
				seen_cells[neighbor] = true
				queue.append(neighbor)
			if keys.size() >= max_edges:
				break
	if keys.is_empty():
		return {}
	# 交战段：engagement 的 (cell_a, cell_b) 恰好落在扇区的某条边上。
	var pair_to_key := {}
	for key in keys:
		var a: int = int(key) / 6
		var b := _edge_neighbor(neighbors, a, int(key) % 6)
		if b >= 0:
			pair_to_key[_pair_id(mini(a, b), maxi(a, b))] = int(key)
	var engagements: Array = []
	if int(_feed.engagement_count) > 0:
		for i in _feed.engagement_count:
			var a := int(_feed.engagement_cell_a[i])
			var b := int(_feed.engagement_cell_b[i])
			var pair := _pair_id(mini(a, b), maxi(a, b))
			if not pair_to_key.has(pair):
				continue
			engagements.append({
				"cell_a": a, "cell_b": b,
				"progress": clampf(float(_feed.engagement_progress[i]) / Q16, 0.0, 1.0),
				"attacker": int(_feed.engagement_side[i]),
				"battle": i < _feed.engagement_battle.size() \
					and int(_feed.engagement_battle[i]) != 0,
			})
	# 交战方：扇区格的归属。即使一侧此刻没有部队，界面也要能写出国名。
	var owner_slots := {}
	for cell in cells:
		var owner := _owner_of(owners, int(cell))
		if owner >= 0:
			owner_slots[owner] = true
	var owner_rows := PackedInt32Array()
	var owner_keys: Array = owner_slots.keys()
	owner_keys.sort()
	for slot in owner_keys:
		owner_rows.append(int(slot))
	# 双方在场兵力 + 部队句柄（对阵表按句柄汇总攻防）：扇区格 + 1 环内、当前可见。
	var ring := {}
	for cell in cells:
		ring[int(cell)] = true
	for cell in cells:
		for dir in 6:
			var neighbor := _edge_neighbor(neighbors, int(cell), dir)
			if neighbor >= 0:
				ring[neighbor] = true
	var sides := {}
	for row in _feed.army_count:
		if int(_feed.army_visible[row]) == 0:
			continue
		if not ring.has(int(_feed.army_cell[row])):
			continue
		var slot := int(_feed.army_owner[row])
		var entry: Dictionary = sides.get(slot, {"slot": slot, "heads": 0,
			"armies": 0, "handles": PackedInt64Array()})
		entry["heads"] = int(entry["heads"]) + int(_feed.army_headcount[row])
		entry["armies"] = int(entry["armies"]) + 1
		var handles: PackedInt64Array = entry["handles"]
		if handles.size() < SECTOR_MAX_SIDE_ARMIES:
			handles.append(int(_feed.army_handle[row]))
			entry["handles"] = handles
		sides[slot] = entry
	var side_rows: Array = sides.values()
	side_rows.sort_custom(func(a, b) -> bool: return int(a.heads) > int(b.heads))
	var advance_total := 0.0
	var advance_count := 0
	for i in active.size():
		if int(active[i]) == 0:
			continue
		advance_total += float(progress[i])
		advance_count += 1
	var focus_cell := int(cells[cells.size() / 2])
	return {
		"ok": true,
		"edge_key": int(edge_key),
		"cells": cells,
		"edge_count": keys.size(),
		"active_count": advance_count,
		"advance": (advance_total / float(advance_count)) if advance_count > 0 else -1.0,
		"engagements": engagements,
		"sides": side_rows,
		"owners": owner_rows,
		"player_slot": _player_slot,
		"focus_cell": focus_cell,
		"max_edges": max_edges,
	}


func _owner_of(owners: PackedInt32Array, cell: int) -> int:
	if cell < 0 or cell >= owners.size():
		return -1
	return int(owners[cell])


func _edge_neighbor(neighbors: PackedInt32Array, cell: int, dir: int) -> int:
	if cell < 0 or dir < 0 or dir > 5:
		return -1
	var index := cell * 6 + dir
	if index >= neighbors.size():
		return -1
	return int(neighbors[index])


func _edge_key_between(neighbors: PackedInt32Array, a: int, b: int) -> int:
	for dir in 6:
		if _edge_neighbor(neighbors, a, dir) == b:
			return a * 6 + dir
	return -1


func _pair_id(a: int, b: int) -> int:
	return a * 131072 + b


func debug_snapshot() -> Dictionary:
	return {
		"configured": _configured,
		"enabled": _enabled,
		"revision": int(_feed.revision) if _feed != null else -1,
		"armies": int(_feed.army_count) if _feed != null else 0,
		"engagements": int(_feed.engagement_count) if _feed != null else 0,
		"convoys": int(_feed.convoy_count) if _feed != null else 0,
		"feed_ok": bool(_feed.ok) if _feed != null else false,
		"feed_unavailable": _feed_unavailable,
		"control_revision": _last_control,
		"front_revision": _last_front,
		"poll_usec": _last_poll_usec,
		"poll_p95_usec": _poll_p95_usec,
		"occupation": occupation_layer.debug_snapshot() if occupation_layer != null else {},
		"area": area_layer.debug_snapshot() if area_layer != null else {},
		"front": front_layer.debug_snapshot() if front_layer != null else {},
		"battle": battle_layer.debug_snapshot() if battle_layer != null else {},
		"convoy": convoy_layer.debug_snapshot() if convoy_layer != null else {},
		"tokens": token_layer.debug_snapshot() if token_layer != null else {},
		"route": route_layer.debug_snapshot() if route_layer != null else {},
	}
