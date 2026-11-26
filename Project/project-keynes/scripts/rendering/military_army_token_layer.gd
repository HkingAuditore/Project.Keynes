extends Node2D
class_name MilitaryArmyTokenLayer

const FormationMaterials = preload("res://scripts/rendering/military_token_formation_materials.gd")
const TokenBuffers = preload("res://scripts/rendering/military_token_instance_buffers.gd")
const TokenLayout = preload("res://scripts/rendering/military_token_layout.gd")
const MilitaryTokenLod = preload("res://scripts/rendering/military_token_lod.gd")


## z=10 部队棋子层：纸片贴纸棋子 + GPU 插值 + 低缩放按格聚合。
##
## 设计稿 §21.7：每个实例上传 (from_xy, to_xy, t0_day, t1_day, style)，
## 由 visual_day 插值位置与朝向；CPU 只在部队换格或换状态时更新实例。
##
## 本实现把「插值」放在 CPU 的 0.5 ms 预算里做，理由写在下面而不是藏着：
##   - Godot 的 MultiMesh 实例矩阵是**普通 vertex buffer**，没有 per-instance
##     uniform；要在 vertex shader 里按 visual_day 插值，必须每帧用
##     `set_instance_transform_2d` 重写一遍矩阵（或自己维护 RenderingServer
##     buffer）。前者的 CPU 成本与「直接算出插值位置」完全一样，却多一次
##     engine 侧矩阵分解，后者要绕开 MultiMesh 的公开 API。
##   - 因此这里每帧只对**移动中的部队**写实例矩阵（静止部队的矩阵在换格时
##     写一次，之后不动），位置按 (from, to, t0, t1, visual_day) 在 GDScript
##     中用 Vector2.lerp 求得——这就是同一份插值语义，只是执行位置不同。
##   - 纸片自身的高频动画（警示点脉动、纸片呼吸）在 shader 里按 wall_seconds
##     与 visual_day 做，CPU 完全不参与。
##
## 聚合：zoom < AGGREGATE_ZOOM 时按格聚合。同格的部队并成一个棋子，
## 兵种取人数最多的那一类，人数求和，警示点按位或——玩家仍能读出「这一格
## 有多少兵、什么兵种、缺什么」。聚合结果缓存，格子签名不变就不重算。
##
## 迷雾：外国部队只在 FOG_VISIBLE 格显示（feed 已经算好 army_visible）。
## 自己的部队永远显示。

const SHADER_PATH: String = "res://shaders/military_paper_sticker.gdshader"
const PAPER_DECAL_PATH: String = \
	"res://assets/military/map/military_army_banner_token_v1.png"
const FORMATION_SHADER_PATH: String = "res://shaders/military_formation_sprite.gdshader"
const FORMATION_ATLAS_PATH: String = \
	"res://assets/military/formations/prototype/military_formation_prototype_v4.png"
const FORMATION_CATALOG_SCRIPT = preload(
	"res://scripts/rendering/military_formation_catalog.gd")
const Z_INDEX := 10
const INSTANCE_CAP := 2048
const AGGREGATE_ZOOM := 0.35
const AGGREGATE_EXIT_ZOOM = MilitaryTokenLod.AGGREGATE_EXIT_ZOOM
const AGGREGATE_REENTER_ZOOM = MilitaryTokenLod.AGGREGATE_REENTER_ZOOM
const FORMATION_ZOOM := 0.70
const FORMATION_ENTER_EXIT_ZOOM = MilitaryTokenLod.FORMATION_ENTER_EXIT_ZOOM
const FORMATION_EXIT_ZOOM = MilitaryTokenLod.FORMATION_EXIT_ZOOM
const LOD_AGGREGATE = MilitaryTokenLod.LOD_AGGREGATE
const LOD_REPRESENTATIVE = MilitaryTokenLod.LOD_REPRESENTATIVE
const LOD_FORMATION = MilitaryTokenLod.LOD_FORMATION
const ACTION_IDLE := 0
const ACTION_MOVE := 1
const ACTION_ATTACK := 2
const ACTION_HIT := 3
const ONE_SHOT_MEMBER_STAGGER_SECONDS := 0.025
const ONE_SHOT_MEMBER_MAX_STAGGER := 4.0 * ONE_SHOT_MEMBER_STAGGER_SECONDS
const ONE_SHOT_ACTION_SECONDS := 1.0 + ONE_SHOT_MEMBER_MAX_STAGGER
## 棋子世界直径 = 该比例 × hex_size（再按 zoom 夹在屏幕像素上下限内）。
const TOKEN_HEX_RATIO := 1.02
const TOKEN_SCREEN_MIN := 15.0
const TOKEN_SCREEN_MAX := 78.0
const FORMATION_MEMBER_HEX_RATIO := 0.82
const FORMATION_MEMBER_SCREEN_MIN := 10.0
const FORMATION_MEMBER_SCREEN_MAX := 54.0
const FORMATION_LAYOUT_SPACING := 1.45
const FORMATION_SHADOW_STRENGTH := 0.30
const FORMATION_SHADOW_HEIGHT_RATIO := 0.14
const FORMATION_SHADOW_MAX_LENGTH_RATIO := 0.65
const FORMATION_SHADOW_EDGE_SOFTNESS := 0.42
const FORMATION_SHADOW_COLOR := Color(0.11, 0.13, 0.17, 1.0)
const FORMATION_SHADOW_FOOTPRINTS := [
	Vector2(0.72, 0.68),
	Vector2(0.88, 0.66),
	Vector2(0.88, 0.76),
	Vector2(0.84, 0.74),
]
const FORMATION_SHADOW_HEIGHTS := [0.36, 0.48, 0.42, 0.52]
## 换格动画时长（秒，真实时间）：行军一日 = 一次换格，动画只覆盖其中一段。
const MOVE_ANIM_SECONDS := 0.55

var _batch: MultiMeshInstance2D
var _formation_batch: MultiMeshInstance2D
var _formation_shadow_batch: MultiMeshInstance2D
var _selection: Line2D
var _material: ShaderMaterial
var _formation_material: ShaderMaterial
var _formation_shadow_material: ShaderMaterial
var _formation_catalog = FORMATION_CATALOG_SCRIPT.new()
var _has_shader := false
var _has_formation_backend := false
var _enabled := true

var _map
var _camera: Camera2D
var _hex_size := 22.0
var _wrap := 0.0
var _player_slot := -1
var _wall_time := 0.0
var _visual_day := 0.0
var _camera_zoom := 1.0
var _lod_mode := LOD_AGGREGATE
var _dirty := true
var _walls := false
var _lod_override := -1
var _zoom_override := -1.0
var _formation_allow_all_for_tests := false
var _lighting_values: Dictionary = {}
var _formation_parameters: Dictionary = {}
var _formation_shader_tiled := false
var _visual_quality := 2

# 逐部队实例状态（SoA，索引与 feed 的 army 行一致）。
var _ax := PackedFloat32Array()      # 当前显示位置
var _ay := PackedFloat32Array()
var _fx := PackedFloat32Array()      # from
var _fy := PackedFloat32Array()
var _tx := PackedFloat32Array()      # to
var _ty := PackedFloat32Array()
var _t0 := PackedFloat32Array()      # 动画起始 wall time
var _cell := PackedInt32Array()
var _slot := PackedInt32Array()
var _klass := PackedByteArray()
var _heads := PackedInt64Array()
var _flags := PackedInt32Array()
var _vis := PackedByteArray()
var _hidden := PackedByteArray()
var _position_initialized := PackedByteArray()
var _row := PackedInt32Array()       # feed 行 -> 实例槽（-1 = 不画）
var _handle := PackedInt64Array()
var _heading := PackedInt32Array()
var _attack_seq := PackedInt32Array()
var _hit_seq := PackedInt32Array()
var _last_attack_seq := PackedInt32Array()
var _last_hit_seq := PackedInt32Array()
var _attack_started := PackedFloat32Array()
var _hit_started := PackedFloat32Array()
var _cue_initialized := false

## Formation instance ownership per army row. Member arrays are flattened as
## row*5+member so moving one army never rebuilds unrelated formations.
var _formed_start := PackedInt32Array()
var _formed_count := PackedByteArray()
var _formed_proto := PackedByteArray()
var _formed_dx := PackedFloat32Array()
var _formed_dy := PackedFloat32Array()
var _formed_scale := PackedFloat32Array()

# 聚合缓存
var _agg_cell := PackedInt32Array()
var _agg_slot := PackedInt32Array()
var _agg_klass := PackedByteArray()
var _agg_heads := PackedInt64Array()
var _agg_flags := PackedInt32Array()
var _agg_count := 0
var _agg_sig := 0

var _selected_cell := -1
var _stats := {"instances": 0, "armies": 0, "moving": 0, "aggregate": false,
	"uploads": 0, "write_usec": 0, "lod": "aggregate",
	"paper_instances": 0, "formation_instances": 0, "formation_armies": 0,
	"paper_fallback": 0, "catalog_units": 0, "catalog_mapped": 0}


func _ready() -> void:
	z_index = Z_INDEX
	top_level = true
	visible = false
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_ensure_nodes()
	set_process(true)


func _ensure_nodes() -> void:
	FormationMaterials._ensure_nodes(self)

func _try_create_formation_batch() -> void:
	FormationMaterials._try_create_formation_batch(self)

func _set_formation_parameter(name: String, value: Variant) -> void:
	FormationMaterials._set_formation_parameter(self, name, value)

func _apply_formation_shader_variant(tiled: bool) -> void:
	FormationMaterials._apply_formation_shader_variant(self, tiled)

func configure_formation_catalog(units: Array) -> Dictionary:
	return FormationMaterials.configure_formation_catalog(self, units)

func configure(map, camera: Camera2D, hex_size: float, wrap_period_x: float) -> void:
	FormationMaterials.configure(self, map, camera, hex_size, wrap_period_x)

func set_daylight_parameters(values: Dictionary) -> void:
	FormationMaterials.set_daylight_parameters(self, values)

func set_terrain_lighting(world: WorldData, source: ShaderMaterial) -> void:
	FormationMaterials.set_terrain_lighting(self, world, source)


func set_visual_quality(quality: int) -> void:
	_visual_quality = clampi(quality, 0, 2)
	_set_formation_parameter("visual_quality", _visual_quality)
	_update_visibility()


func set_player_slot(slot: int) -> void:
	if slot == _player_slot:
		return
	_player_slot = slot
	# Formation rollout is player-gated. Re-evaluate now instead of waiting for
	# an unrelated army/LOD signature change.
	_last_signature = -1
	_last_formation_signature = -1
	_dirty = true


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	_update_visibility()


func set_walls_enabled(enabled: bool) -> void:
	_walls = enabled
	if _material != null:
		_material.set_shader_parameter("hex_size", _hex_size)


func set_selected_cell(cell: int) -> void:
	if cell == _selected_cell:
		return
	_selected_cell = cell
	_dirty = true
	_update_selection_ring()


## ── 点击拾取（只在点击时调用，不做逐帧命中测试）──────────────────────────
## 返回最近的可见部队 {handle, cell, row, distance}；空字典 = 未命中。
## 迷雾：`_vis[row] == 0` 的外国部队不参与拾取（与 z10 的显示规则同源）。
## 聚合 LOD 下一枚棋子代表整格，因此退化为「该格兵力最多的那支」。
func pick_army_at(world: Vector2, radius: float = -1.0) -> Dictionary:
	if not _has_shader or _map == null or world.x != world.x:
		return {}
	var limit := radius if radius > 0.0 else _token_world_size() * 0.62
	var best := {}
	var best_distance := limit
	if _lod_mode == LOD_AGGREGATE:
		for i in _agg_count:
			var cell: int = int(_agg_cell[i])
			var pos := _cell_world(cell, world.x)
			if is_nan(pos.x):
				continue
			var distance := pos.distance_to(world)
			if distance > best_distance:
				continue
			var row := _army_row_for_cell(cell)
			if row < 0:
				continue
			best_distance = distance
			best = {"handle": int(_handle[row]), "cell": cell, "row": row,
				"headcount": int(_heads[row]), "distance": distance}
		return best
	for row in _army_count:
		if int(_vis[row]) == 0:
			continue
		var x: float = _ax[row]
		var y: float = _ay[row]
		if is_nan(x) or is_nan(y):
			continue
		var distance := Vector2(x, y).distance_to(world)
		if distance > best_distance:
			continue
		# 同格重叠时（普通 LOD 两支队伍站在同一格）取兵力更大的一支，
		# 这样点击不会被"行号靠前"这种实现细节决定。
		if absf(distance - best_distance) < 0.001 and not best.is_empty() \
				and int(_heads[row]) <= int(best.get("headcount", 0)):
			continue
		best_distance = distance
		best = {"handle": int(_handle[row]), "cell": int(_cell[row]), "row": row,
			"headcount": int(_heads[row]), "distance": distance}
	return best


## 该格兵力最多的可见行（聚合 LOD 拾取用）。-1 = 该格没有可见部队。
func _army_row_for_cell(cell: int) -> int:
	var best := -1
	for row in _army_count:
		if int(_vis[row]) == 0 or int(_cell[row]) != cell:
			continue
		if best < 0 or int(_heads[row]) > int(_heads[best]):
			best = row
	return best


## 部队当前显示位置（世界坐标，已处理 wrap 镜像）；未知句柄返回 NaN 向量。
func army_world_position(handle: int) -> Vector2:
	for row in _army_count:
		if int(_handle[row]) != handle:
			continue
		var x: float = _ax[row]
		var y: float = _ay[row]
		if is_nan(x) or is_nan(y):
			return _cell_world(int(_cell[row]), _camera_x())
		return Vector2(x, y)
	return Vector2(NAN, NAN)


func set_formation_allow_all_for_tests(enabled: bool) -> void:
	if _formation_allow_all_for_tests == enabled:
		return
	_formation_allow_all_for_tests = enabled
	_last_signature = -1
	_last_formation_signature = -1
	_dirty = true


## 来自 feed。只有 feed 的 army_signature 变化才重写实例属性；
## 换格的部队会单独打上「动画中」标记，由 _process 推进 from→to。
func set_armies(feed) -> void:
	if feed == null or not _has_shader:
		return
	_army_feed = feed
	var count: int = feed.army_count
	var formation_signature := int(feed.army_formation_signature)
	if int(feed.army_signature) != _last_signature \
			or formation_signature != _last_formation_signature:
		_last_signature = int(feed.army_signature)
		_last_formation_signature = formation_signature
		_rebuild(feed, count)
		return
	# 签名相同：cue 只更新 formation custom data，迷雾只刷新可见性。
	var cue_rows := _sync_cues(feed, false)
	for row in cue_rows:
		_update_row_formation_custom(row)
	var changed := false
	for i in _army_count:
		var v: int = feed.army_visible[i]
		if _vis[i] != v:
			_vis[i] = v
			changed = true
	if changed:
		_dirty = true
		_write_instances()


var _last_signature := -1
var _last_formation_signature := -1
var _army_feed


func _ensure_capacity(count: int) -> void:
	TokenBuffers._ensure_capacity(self, count)

func _cell_world(cell: int, ref_x: float) -> Vector2:
	return TokenBuffers._cell_world(self, cell, ref_x)

func _camera_x() -> float:
	return TokenBuffers._camera_x(self)

func _rebuild(feed, count: int) -> void:
	TokenBuffers._rebuild(self, feed, count)

var _army_count := 0

func _sync_cues(feed, initial: bool) -> PackedInt32Array:
	return TokenBuffers._sync_cues(self, feed, initial)


func _write_instances() -> void:
	TokenLayout._write_instances(self)

func _token_world_size() -> float:
	return TokenLayout._token_world_size(self)

func _priority_army_order() -> Array[int]:
	return TokenLayout._priority_army_order(self)

func _write_paper_individual(mm: MultiMesh, row: int, size: float,
		instance_index: int) -> void:
	TokenLayout._write_paper_individual(self, mm, row, size, instance_index)

func _write_aggregated(mm: MultiMesh, size: float) -> int:
	return TokenLayout._write_aggregated(self, mm, size)

func _mix_aggregate_signature(seed: int, value: int) -> int:
	return TokenLayout._mix_aggregate_signature(self, seed, value)

func _formation_representative_size(prototype_row: int) -> float:
	return TokenLayout._formation_representative_size(self, prototype_row)

func _formation_member_size(prototype_row: int) -> float:
	return TokenLayout._formation_member_size(self, prototype_row)

func _write_representative(row: int, pos: Vector2, prototype_row: int) -> int:
	return TokenLayout._write_representative(self, row, pos, prototype_row)

func _write_formation_members(row: int, pos: Vector2,
		prototypes: PackedByteArray) -> int:
	return TokenLayout._write_formation_members(self, row, pos, prototypes)

var _formation_write_count := 0

func _next_formation_instance() -> int:
	return TokenLayout._next_formation_instance(self)

func _store_formation_member(row: int, member: int, prototype_row: int,
		dx: float, dy: float, scale: float) -> void:
	TokenLayout._store_formation_member(self, row, member, prototype_row, dx, dy, scale)

func _set_formation_instance(instance_index: int, row: int, member: int,
		prototype_row: int, pos: Vector2, dx: float, dy: float,
		scale: float) -> void:
	TokenLayout._set_formation_instance(self, instance_index, row, member, prototype_row, pos, dx, dy, scale)

func _formation_custom(row: int, member: int, prototype_row: int) -> Color:
	return TokenLayout._formation_custom(self, row, member, prototype_row)

static func one_shot_member_start(started: float, member: int) -> float:
	return TokenLayout.one_shot_member_start(started, member)

func _action_for_row(row: int) -> int:
	return TokenLayout._action_for_row(self, row)

func _is_moving(row: int) -> bool:
	return TokenLayout._is_moving(self, row)

func _heading_radians(row: int) -> float:
	return TokenLayout._heading_radians(self, row)

func _owner_tint(slot: int) -> Color:
	return TokenLayout._owner_tint(self, slot)

func _composition_prototypes(feed, row: int) -> PackedByteArray:
	return TokenLayout._composition_prototypes(self, feed, row)

func _member_prototypes_for_row(feed, row: int,
		composition_prototypes: PackedByteArray) -> PackedByteArray:
	return TokenLayout._member_prototypes_for_row(self, feed, row, composition_prototypes)

func _update_row_formation_custom(row: int) -> void:
	TokenLayout._update_row_formation_custom(self, row)

func _update_row_instance_transforms(row: int, paper_size: float) -> void:
	TokenLayout._update_row_instance_transforms(self, row, paper_size)

func _build_aggregate() -> void:
	TokenLayout._build_aggregate(self)


func _update_selection_ring() -> void:
	if _selection == null:
		return
	if _selected_cell < 0 or not _has_shader:
		_selection.points = PackedVector2Array()
		return
	var pos := _cell_world(_selected_cell, _camera_x())
	if is_nan(pos.x):
		_selection.points = PackedVector2Array()
		return
	var r := _selected_visual_radius()
	var pts := PackedVector2Array()
	pts.resize(25)
	for k in 25:
		var ang := TAU * float(k) / 24.0
		pts[k] = pos + Vector2(cos(ang), sin(ang)) * r
	_selection.points = pts


func _selected_visual_radius() -> float:
	var paper_radius := _token_world_size() \
		* (0.62 if _lod_mode == LOD_AGGREGATE else 0.76)
	if _lod_mode != LOD_FORMATION:
		return paper_radius
	var radius := paper_radius
	for row in _army_count:
		if _cell[row] != _selected_cell or int(_formed_count[row]) <= 0:
			continue
		for member in int(_formed_count[row]):
			var index := row * 5 + member
			var center_radius := Vector2(
				_formed_dx[index], _formed_dy[index]).length()
			radius = maxf(radius, center_radius + _formed_scale[index] * 0.5 + 2.0)
	return radius


func _update_visibility() -> void:
	var paper_visible := _batch != null \
		and _batch.multimesh.visible_instance_count > 0
	var formation_visible := _formation_batch != null \
		and _formation_batch.multimesh.visible_instance_count > 0
	if _formation_shadow_batch != null:
		_formation_shadow_batch.visible = formation_visible \
			and _visual_quality >= 2 and not OS.has_feature("web")
	visible = _enabled and _has_shader and (paper_visible or formation_visible)


func _process(delta: float) -> void:
	_wall_time += delta
	if _material == null or _batch == null:
		return
	if _zoom_override >= 0.0:
		_camera_zoom = _zoom_override
	else:
		var vp := get_viewport()
		if vp != null:
			_camera_zoom = maxf(0.0001, vp.get_canvas_transform().get_scale().x)
	var next_lod := _lod_mode
	if _lod_override >= 0:
		next_lod = _lod_override
	else:
		next_lod = lod_for_zoom_with_hysteresis(_camera_zoom, _lod_mode)
	if next_lod != _lod_mode:
		_lod_mode = next_lod
		_dirty = true
		_agg_sig = -1
	# 只推进移动中的部队：静止部队的实例矩阵不动。
	var moving := 0
	var paper_size := _token_world_size()
	for i in _army_count:
		var cue_expired := false
		if _hit_started[i] >= 0.0 \
				and _wall_time - _hit_started[i] >= ONE_SHOT_ACTION_SECONDS:
			_hit_started[i] = -1.0
			cue_expired = true
		if _attack_started[i] >= 0.0 \
				and _wall_time - _attack_started[i] >= ONE_SHOT_ACTION_SECONDS:
			_attack_started[i] = -1.0
			cue_expired = true
		if cue_expired and _lod_mode != LOD_AGGREGATE:
			_update_row_formation_custom(i)
		if _t0[i] <= -50.0:
			continue
		var t := (_wall_time - _t0[i]) / MOVE_ANIM_SECONDS
		if t >= 1.0:
			_ax[i] = _tx[i]
			_ay[i] = _ty[i]
			_t0[i] = -100.0
			if _lod_mode != LOD_AGGREGATE:
				_update_row_instance_transforms(i, paper_size)
				_update_row_formation_custom(i)
			continue
		if t < 0.0:
			t = 0.0
		moving += 1
		# ease-out：行军起步慢、到位稳，像棋子被推过去。
		var e := 1.0 - (1.0 - t) * (1.0 - t)
		_ax[i] = lerpf(_fx[i], _tx[i], e)
		_ay[i] = lerpf(_fy[i], _ty[i], e)
		if _lod_mode != LOD_AGGREGATE:
			_update_row_instance_transforms(i, paper_size)
	if _dirty:
		_write_instances()
	elif moving > 0 and _lod_mode != LOD_AGGREGATE:
		_update_selection_ring()
	_stats["moving"] = moving
	_material.set_shader_parameter("wall_seconds", _wall_time)
	_material.set_shader_parameter("visual_day", _visual_day)
	_material.set_shader_parameter("reduced_motion", UIAnimation.reduced_motion())
	_material.set_shader_parameter("layer_alpha", 1.0)
	if _formation_material != null:
		_set_formation_parameter("visual_seconds", _wall_time)
		_set_formation_parameter(
			"reduced_motion", UIAnimation.reduced_motion())
		_set_formation_parameter("layer_alpha", 1.0)


static func lod_for_zoom_with_hysteresis(zoom: float, current: int) -> int:
	return MilitaryTokenLod.lod_for_zoom_with_hysteresis(zoom, current)


static func _lod_name(mode: int) -> String:
	return MilitaryTokenLod._lod_name(mode)


func set_lod_override_for_tests(mode: int) -> void:
	_lod_override = clampi(mode, -1, LOD_FORMATION)
	if _lod_override >= 0:
		_lod_mode = _lod_override
		_agg_sig = -1
		_dirty = true


func set_zoom_override_for_tests(zoom: float) -> void:
	_zoom_override = zoom


func formation_catalog_ready() -> bool:
	return _has_formation_backend and _formation_catalog.is_bound()


func debug_army_action(row: int) -> String:
	if row < 0 or row >= _army_count:
		return ""
	match _action_for_row(row):
		ACTION_MOVE:
			return "move"
		ACTION_ATTACK:
			return "attack"
		ACTION_HIT:
			return "hit"
	return "idle"


func set_visual_day(value: float) -> void:
	_visual_day = value


func clear() -> void:
	_army_count = 0
	_last_signature = -1
	_last_formation_signature = -1
	_army_feed = null
	_cue_initialized = false
	_position_initialized.fill(0)
	_agg_sig = -1
	_agg_count = 0
	if _batch != null:
		_batch.multimesh.visible_instance_count = 0
	if _formation_batch != null:
		_formation_batch.multimesh.visible_instance_count = 0
	if _formation_shadow_batch != null:
		_formation_shadow_batch.visible = false
	if _selection != null:
		_selection.points = PackedVector2Array()
	_stats["instances"] = 0
	_stats["paper_instances"] = 0
	_stats["formation_instances"] = 0
	_stats["formation_armies"] = 0
	_stats["paper_fallback"] = 0
	_stats["moving"] = 0
	_update_visibility()


func debug_snapshot() -> Dictionary:
	var out := _stats.duplicate()
	out["visible_layer"] = visible
	out["camera_zoom"] = _camera_zoom
	out["aggregate_cells"] = _agg_count
	out["formation_catalog_ready"] = formation_catalog_ready()
	out["formation_shadow_visible"] = _formation_shadow_batch != null \
		and _formation_shadow_batch.visible
	out["formation_shadow_shared_multimesh"] = _formation_batch != null \
		and _formation_shadow_batch != null \
		and _formation_batch.multimesh == _formation_shadow_batch.multimesh
	out["formation_shader_tiled"] = _formation_shader_tiled
	out["formation_terrain_lighting_bound"] = bool(
		_formation_parameters.get("terrain_instance_lighting_enabled", false))
	return out
