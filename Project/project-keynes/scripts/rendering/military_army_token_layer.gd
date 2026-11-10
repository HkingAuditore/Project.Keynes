extends Node2D
class_name MilitaryArmyTokenLayer
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
	if _batch != null and _selection != null:
		return
	if _batch == null:
		var shader := load(SHADER_PATH) as Shader
		if shader == null:
			push_warning("MilitaryArmyTokenLayer: missing shader %s" % SHADER_PATH)
			return
		_material = ShaderMaterial.new()
		_material.shader = shader
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_custom_data = true
		mm.mesh = quad
		mm.instance_count = INSTANCE_CAP
		mm.visible_instance_count = 0
		_batch = MultiMeshInstance2D.new()
		_batch.name = "ArmyTokens"
		_batch.multimesh = mm
		# canvas_item 的 fragment 会乘 TEXTURE 采样：绑一张不透明白贴图，让
		# shader 输出原样到达屏幕（与 CountryBorderLayer 同一处理）。
		_batch.texture = CountryBorderLayer.get_white_texture()
		_batch.material = _material
		add_child(_batch)
	if _formation_batch == null:
		_try_create_formation_batch()
	# 选中部队的朱红圈：一个 Line2D，不在 MultiMesh 里（透明填充会被叠加）。
	if _selection == null:
		_selection = Line2D.new()
		_selection.name = "SelectedArmyRing"
		_selection.width = 2.2
		_selection.default_color = Color(0.72, 0.19, 0.13, 0.95)
		_selection.antialiased = true
		_selection.closed = true
		_selection.z_index = 1
		_selection.points = PackedVector2Array()
		add_child(_selection)
	_has_shader = true


func _try_create_formation_batch() -> void:
	var shader := load(FORMATION_SHADER_PATH) as Shader
	var atlas := load(FORMATION_ATLAS_PATH) as Texture2D
	if shader == null or atlas == null:
		_has_formation_backend = false
		return
	_formation_material = ShaderMaterial.new()
	_formation_material.shader = shader
	_formation_shadow_material = ShaderMaterial.new()
	_formation_shadow_material.shader = shader
	_formation_shadow_material.set_shader_parameter("shadow_pass", true)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_custom_data = true
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = INSTANCE_CAP
	mm.visible_instance_count = 0
	# Formation members are positioned in world space with per-member wrap
	# correction. Keep a world-sized culling box so camera panning never drops
	# the whole batch at map seams or viewport edges.
	mm.custom_aabb = AABB(
		Vector3(-1_000_000.0, -1_000_000.0, -1.0),
		Vector3(2_000_000.0, 2_000_000.0, 2.0)
	)
	_formation_shadow_batch = MultiMeshInstance2D.new()
	_formation_shadow_batch.name = "ArmyFormationShadows"
	_formation_shadow_batch.multimesh = mm
	_formation_shadow_batch.texture = atlas
	_formation_shadow_batch.material = _formation_shadow_material
	_formation_shadow_batch.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_formation_batch = MultiMeshInstance2D.new()
	_formation_batch.name = "ArmyFormationMembers"
	_formation_batch.multimesh = mm
	_formation_batch.texture = atlas
	_formation_batch.material = _formation_material
	# A mip pyramid would blend adjacent atlas cells. The v3 atlas already has
	# transparent frame gutters; linear filtering preserves the cutout safely.
	_formation_batch.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_formation_shadow_batch)
	add_child(_formation_batch)
	_set_formation_parameter("formation_atlas", atlas)
	_set_formation_parameter("visual_seconds", _wall_time)
	_set_formation_parameter("layer_alpha", 1.0)
	_set_formation_parameter("visual_quality", _visual_quality)
	_set_formation_parameter("terrain_instance_lighting_enabled", false)
	_set_formation_parameter("shadow_strength", FORMATION_SHADOW_STRENGTH)
	_set_formation_parameter("shadow_height_ratio", FORMATION_SHADOW_HEIGHT_RATIO)
	_set_formation_parameter(
		"shadow_max_length_ratio", FORMATION_SHADOW_MAX_LENGTH_RATIO)
	_set_formation_parameter(
		"shadow_footprints", PackedVector2Array(FORMATION_SHADOW_FOOTPRINTS))
	_set_formation_parameter(
		"shadow_heights", PackedFloat32Array(FORMATION_SHADOW_HEIGHTS))
	_set_formation_parameter(
		"shadow_edge_softness", FORMATION_SHADOW_EDGE_SOFTNESS)
	_set_formation_parameter("shadow_color", FORMATION_SHADOW_COLOR)
	_has_formation_backend = true


func _set_formation_parameter(name: String, value: Variant) -> void:
	_formation_parameters[name] = value
	if _formation_material != null:
		_formation_material.set_shader_parameter(name, value)
	if _formation_shadow_material != null:
		_formation_shadow_material.set_shader_parameter(name, value)


func _apply_formation_shader_variant(tiled: bool) -> void:
	if tiled == _formation_shader_tiled or _formation_material == null:
		return
	var base := load(FORMATION_SHADER_PATH) as Shader
	if base == null:
		return
	_formation_shader_tiled = tiled
	var variant := Shader.new()
	variant.code = ("#define MAP_VISUAL_TILED\n" if tiled else "") + base.code
	_formation_material.shader = variant
	_formation_shadow_material.shader = variant
	for name in _formation_parameters:
		_formation_material.set_shader_parameter(name, _formation_parameters[name])
		_formation_shadow_material.set_shader_parameter(
			name, _formation_parameters[name])
	_formation_material.set_shader_parameter("shadow_pass", false)
	_formation_shadow_material.set_shader_parameter("shadow_pass", true)


func configure_formation_catalog(units: Array) -> Dictionary:
	_ensure_nodes()
	var loaded: bool = _formation_catalog.load_catalog()
	if not loaded:
		_has_formation_backend = false
		_dirty = true
		return {"ok": false, "reason": "formation_visual_catalog_invalid",
			"mapped": 0, "dense_unit_count": 0}
	_has_formation_backend = _formation_batch != null
	var report: Dictionary = _formation_catalog.bind_dense_units(units)
	if not bool(report.get("ok", false)) or not _has_formation_backend:
		_has_formation_backend = false
		_dirty = true
		return report
	_last_signature = -1
	_last_formation_signature = -1
	_dirty = true
	return report


func configure(map, camera: Camera2D, hex_size: float, wrap_period_x: float) -> void:
	_ensure_nodes()
	_map = map
	_camera = camera
	_hex_size = maxf(4.0, hex_size)
	_wrap = maxf(0.0, wrap_period_x)
	_dirty = true


## HexRenderer owns this state so formations and trade convoys share the exact
## same astronomical phase. Per-vertex work remains on the GPU.
func set_daylight_parameters(values: Dictionary) -> void:
	_ensure_nodes()
	for name in values:
		if _lighting_values.has(name) and _lighting_values[name] == values[name]:
			continue
		_lighting_values[name] = values[name]
		_set_formation_parameter(name, values[name])


## Static map fields and the terrain-derived light parameters. Called on initial
## registration and whenever the tiled horizon bake finishes.
func set_terrain_lighting(world: WorldData, source: ShaderMaterial) -> void:
	_ensure_nodes()
	if world == null:
		_set_formation_parameter("terrain_instance_lighting_enabled", false)
		for name in [
			"terrain_normal_tex_bound",
			"terrain_horizon_tex_bound",
			"gi_lut_bound",
		]:
			_set_formation_parameter(name, false)
		return
	_set_formation_parameter("world_origin", world.world_bounds.position)
	_set_formation_parameter(
		"world_size", world.world_bounds.size.max(Vector2(0.0001, 0.0001)))
	_set_formation_parameter("wrap_origin_x", 0.0)
	_set_formation_parameter("wrap_period_x", world.wrap_period_x)
	var tiles: Variant = world.visual_tiles
	var tiled := tiles != null and bool(tiles.ready) \
		and String(tiles.layout.mode) == "tiled"
	_apply_formation_shader_variant(tiled)
	if tiled:
		_set_formation_parameter("visual_horizon_tiles", tiles.horizon)
		_set_formation_parameter(
			"visual_terrain_normal_tiles", tiles.terrain_normal)
		var layout: Variant = tiles.layout
		_set_formation_parameter(
			"visual_domain_origin", layout.visual_domain.position)
		_set_formation_parameter(
			"visual_domain_size", layout.visual_domain.size)
		for pair in [
			["visual_grid_size", layout.grid_size],
			["visual_interior_size", layout.interior_size],
			["visual_layer_size", layout.layer_size],
			["visual_logical_resolution", layout.logical_size],
		]:
			_set_formation_parameter(pair[0], Vector2(pair[1]))
		_set_formation_parameter("visual_gutter_px", float(layout.gutter_px))
	else:
		_set_formation_parameter(
			"terrain_horizon_tex", world.terrain_horizon_tex)
		_set_formation_parameter(
			"terrain_normal_tex", world.terrain_normal_tex)
	_set_formation_parameter(
		"terrain_horizon_tex_bound",
		bool(tiles.horizon_ready) if tiled else world.terrain_horizon_tex != null)
	_set_formation_parameter(
		"terrain_normal_tex_bound",
		tiles.terrain_normal != null if tiled else world.terrain_normal_tex != null)
	if source != null:
		for name in [
			"terrain_horizon_strength",
			"terrain_horizon_softness",
			"terrain_horizon_max_angle",
			"terrain_normal_influence",
			"gi_horizon_lut",
			"gi_lut_bound",
			"gi_ao_strength",
			"gi_ao_floor",
			"gi_ao_smoothing",
			"gi_bent_strength",
			"gi_normal_floor",
			"sky_ibl_bound",
			"sky_ambient_strength",
			"sky_day_sh_l1",
			"sky_night_sh_l1",
		]:
			var value: Variant = source.get_shader_parameter(name)
			if value != null:
				_set_formation_parameter(name, value)
	_set_formation_parameter("terrain_instance_lighting_enabled", true)


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
	var cap := maxi(count, INSTANCE_CAP)
	if _ax.size() >= cap:
		return
	_ax.resize(cap)
	_ay.resize(cap)
	_fx.resize(cap)
	_fy.resize(cap)
	_tx.resize(cap)
	_ty.resize(cap)
	_t0.resize(cap)
	_cell.resize(cap)
	_slot.resize(cap)
	_klass.resize(cap)
	_heads.resize(cap)
	_flags.resize(cap)
	_vis.resize(cap)
	_hidden.resize(cap)
	_position_initialized.resize(cap)
	_row.resize(cap)
	_handle.resize(cap)
	_heading.resize(cap)
	_attack_seq.resize(cap)
	_hit_seq.resize(cap)
	_last_attack_seq.resize(cap)
	_last_hit_seq.resize(cap)
	_attack_started.resize(cap)
	_hit_started.resize(cap)
	_formed_start.resize(cap)
	_formed_count.resize(cap)
	_formed_proto.resize(cap * 5)
	_formed_dx.resize(cap * 5)
	_formed_dy.resize(cap * 5)
	_formed_scale.resize(cap * 5)
	for index in range(cap):
		_row[index] = -1
		_formed_start[index] = -1
		_formed_count[index] = 0
		_attack_started[index] = -1.0
		_hit_started[index] = -1.0
	for index in range(cap * 5):
		_formed_proto[index] = 0
		_formed_dx[index] = 0.0
		_formed_dy[index] = 0.0
		_formed_scale[index] = 0.0


func _cell_world(cell: int, ref_x: float) -> Vector2:
	var cell_obj = _map.cell_at(cell) if _map != null else null
	if cell_obj == null:
		return Vector2(NAN, NAN)
	var p := HexUtils.cube_to_world(cell_obj.q, cell_obj.r, _hex_size)
	if _wrap > 0.0001:
		if not is_nan(ref_x):
			p = HexUtils.nearest_display_world(p, ref_x, _wrap)
	return p


func _camera_x() -> float:
	if _camera != null and is_instance_valid(_camera):
		return _camera.global_position.x
	return NAN


func _rebuild(feed, count: int) -> void:
	_ensure_capacity(count)
	_sync_cues(feed, false)
	var ref_x := _camera_x()
	var started := Time.get_ticks_usec()
	for i in count:
		var cell: int = feed.army_cell[i]
		var prev: int = feed.army_prev_cell[i]
		var to := _cell_world(cell, ref_x)
		var from := to
		if prev >= 0 and prev != cell:
			var f := _cell_world(prev, to.x if not is_nan(to.x) else ref_x)
			if not is_nan(f.x):
				from = f
		_cell[i] = cell
		_slot[i] = feed.army_owner[i]
		_klass[i] = feed.army_class[i]
		_heads[i] = feed.army_headcount[i]
		_flags[i] = feed.army_flags[i]
		_vis[i] = feed.army_visible[i]
		_heading[i] = feed.army_heading_for_row(i)
		var is_new := _position_initialized[i] == 0
		if is_new or prev == cell:
			# 新棋子 / 没换格：直接落在目标位置。
			_ax[i] = to.x
			_ay[i] = to.y
			_fx[i] = to.x
			_fy[i] = to.y
			_tx[i] = to.x
			_ty[i] = to.y
			_t0[i] = -100.0
		else:
			# 换格：从上一格出发，MOVE_ANIM_SECONDS 内插值到新格。
			_fx[i] = _ax[i] if _ax[i] != 0.0 else from.x
			_fy[i] = _ay[i] if _ay[i] != 0.0 else from.y
			_tx[i] = to.x
			_ty[i] = to.y
			_t0[i] = _wall_time
		_position_initialized[i] = 1
	_army_count = count
	_dirty = true
	_write_instances()
	_stats["write_usec"] = Time.get_ticks_usec() - started


var _army_count := 0


func _sync_cues(feed, initial: bool) -> PackedInt32Array:
	var changed := PackedInt32Array()
	var count := mini(int(feed.army_count), _handle.size())
	if count == 0:
		_cue_initialized = true
		return changed
	var previous_count := _army_count
	for i in count:
		var new_handle := int(feed.army_handle[i])
		var new_attack := int(feed.army_attack_seq_for_row(i))
		var new_hit := int(feed.army_hit_seq_for_row(i))
		var same_army := _cue_initialized and not initial and i < previous_count \
			and _handle[i] == new_handle
		if same_army and new_attack != int(_last_attack_seq[i]):
			_attack_started[i] = _wall_time
			changed.append(i)
		if same_army and new_hit != int(_last_hit_seq[i]):
			_hit_started[i] = _wall_time
			if changed.is_empty() or changed[changed.size() - 1] != i:
				changed.append(i)
		if not same_army:
			_attack_started[i] = -1.0
			_hit_started[i] = -1.0
			# Native compacts army rows. A new handle in the same row must snap
			# to its own cell instead of inheriting the previous army's tween.
			_position_initialized[i] = 0
		_handle[i] = new_handle
		_last_attack_seq[i] = new_attack
		_last_hit_seq[i] = new_hit
		_attack_seq[i] = new_attack
		_hit_seq[i] = new_hit
	_cue_initialized = true
	return changed


func _write_instances() -> void:
	if _batch == null:
		return
	var mm := _batch.multimesh
	var size := _token_world_size()
	if _material != null:
		_material.set_shader_parameter("aggregate_mode", _lod_mode == LOD_AGGREGATE)
		_material.set_shader_parameter("hex_size", _hex_size)
		_material.set_shader_parameter("layer_alpha", 1.0)
	if _formation_material != null:
		_set_formation_parameter("visual_seconds", _wall_time)
		_set_formation_parameter("layer_alpha", 1.0)
	for row in _row.size():
		_row[row] = -1
		_formed_start[row] = -1
		_formed_count[row] = 0
	_formation_write_count = 0
	var paper_emitted := 0
	var formation_emitted := 0
	var formation_armies := 0
	var paper_fallback := 0
	if _lod_mode == LOD_AGGREGATE:
		paper_emitted = _write_aggregated(mm, size)
	else:
		for row in _priority_army_order():
			if paper_emitted + formation_emitted >= INSTANCE_CAP:
				break
			if _vis[row] == 0 or is_nan(_ax[row]):
				continue
			var pos := Vector2(_ax[row], _ay[row])
			var prototypes := _composition_prototypes(_army_feed, row)
			var wants_formation := _lod_mode == LOD_FORMATION \
				and _has_formation_backend and not prototypes.is_empty()
			if wants_formation:
				var member_protos := _member_prototypes_for_row(_army_feed, row, prototypes)
				if not member_protos.is_empty() \
						and paper_emitted + formation_emitted + member_protos.size() <= INSTANCE_CAP:
					var written := _write_formation_members(row, pos, member_protos)
					if written > 0:
						formation_emitted += written
						formation_armies += 1
						continue
				# Never draw a partial formation. If the five-member layout does
				# not fit, this army falls back to one representative sprite.
				if paper_emitted + formation_emitted + 1 <= INSTANCE_CAP:
					formation_emitted += _write_representative(
						row, pos, int(prototypes[0]))
					formation_armies += 1
					paper_fallback += 1
					continue
			elif _lod_mode == LOD_REPRESENTATIVE \
					and _has_formation_backend and not prototypes.is_empty():
				if paper_emitted + formation_emitted + 1 <= INSTANCE_CAP:
					formation_emitted += _write_representative(
						row, pos, int(prototypes[0]))
					formation_armies += 1
					continue
			if paper_emitted >= INSTANCE_CAP - formation_emitted:
				break
			_write_paper_individual(mm, row, size, paper_emitted)
			paper_emitted += 1
			paper_fallback += 1
	if _formation_batch != null:
		_formation_batch.multimesh.visible_instance_count = formation_emitted
	mm.visible_instance_count = paper_emitted
	_stats["instances"] = paper_emitted + formation_emitted
	_stats["paper_instances"] = paper_emitted
	_stats["formation_instances"] = formation_emitted
	_stats["formation_armies"] = formation_armies
	_stats["paper_fallback"] = paper_fallback
	_stats["catalog_units"] = _formation_catalog.dense_unit_count()
	_stats["catalog_mapped"] = _formation_catalog.mapped_unit_count()
	_stats["armies"] = _army_count
	_stats["aggregate"] = _lod_mode == LOD_AGGREGATE
	_stats["lod"] = _lod_name(_lod_mode)
	_stats["uploads"] = int(_stats["uploads"]) + 1
	_update_selection_ring()
	_update_visibility()
	_dirty = false


func _token_world_size() -> float:
	var world := _hex_size * TOKEN_HEX_RATIO
	if _camera_zoom > 0.0001:
		world = minf(world, TOKEN_SCREEN_MAX / _camera_zoom)
		world = maxf(world, TOKEN_SCREEN_MIN / _camera_zoom)
	return world


func _priority_army_order() -> Array[int]:
	var order: Array[int] = []
	if _selected_cell >= 0:
		for row in _army_count:
			if _vis[row] != 0 and _cell[row] == _selected_cell:
				order.append(row)
	for row in _army_count:
		if _selected_cell >= 0 and _cell[row] == _selected_cell:
			continue
		order.append(row)
	return order


func _write_paper_individual(mm: MultiMesh, row: int, size: float,
		instance_index: int) -> void:
	var scale := size * (1.12 if _cell[row] == _selected_cell else 1.0)
	var tx := Transform2D(0.0, Vector2(scale, scale), 0.0,
		Vector2(_ax[row], _ay[row]))
	mm.set_instance_transform_2d(instance_index, tx)
	mm.set_instance_custom_data(instance_index, Color(float(_slot[row]),
		float(_klass[row]), float(_heads[row]), float(_flags[row])))
	_row[row] = instance_index


func _write_aggregated(mm: MultiMesh, size: float) -> int:
	# 按格聚合：格子签名不变就复用上一轮的聚合结果，避免每帧 O(n) 重算。
	if _army_count == 0:
		_agg_cell.clear()
		_agg_slot.clear()
		_agg_klass.clear()
		_agg_heads.clear()
		_agg_flags.clear()
		_agg_count = 0
		_agg_sig = -1
		return 0
	var sig := _army_count
	for i in _army_count:
		if _vis[i] != 0:
			sig = _mix_aggregate_signature(sig, int(_handle[i]))
			sig = _mix_aggregate_signature(sig, int(_slot[i]))
			sig = _mix_aggregate_signature(sig, int(_cell[i]))
			sig = _mix_aggregate_signature(sig, int(_klass[i]))
			sig = _mix_aggregate_signature(sig, int(_heads[i]))
			sig = _mix_aggregate_signature(sig, int(_flags[i]))
	if sig != _agg_sig:
		_build_aggregate()
		_agg_sig = sig
	var emitted := 0
	for i in _agg_count:
		if emitted >= INSTANCE_CAP:
			break
		var pos := _cell_world(_agg_cell[i], _camera_x())
		if is_nan(pos.x):
			continue
		var scale := size * (1.10 if _agg_cell[i] == _selected_cell else 1.0)
		var tx := Transform2D(0.0, Vector2(scale, scale), 0.0, pos)
		mm.set_instance_transform_2d(emitted, tx)
		mm.set_instance_custom_data(emitted, Color(float(_agg_slot[i]),
			float(_agg_klass[i]), float(_agg_heads[i]), float(_agg_flags[i])))
		emitted += 1
	return emitted


func _mix_aggregate_signature(seed: int, value: int) -> int:
	return int((seed * 1000003 + value) & 0x7FFFFFFFFFFFFFFF)


func _formation_representative_size(prototype_row: int) -> float:
	var world := _hex_size * 0.94 * _formation_catalog.sprite_scale(prototype_row)
	if _camera_zoom > 0.0001:
		world = minf(world, TOKEN_SCREEN_MAX / _camera_zoom)
		world = maxf(world, TOKEN_SCREEN_MIN / _camera_zoom)
	return world


func _formation_member_size(prototype_row: int) -> float:
	var world := _hex_size * FORMATION_MEMBER_HEX_RATIO \
		* _formation_catalog.sprite_scale(prototype_row)
	if _camera_zoom > 0.0001:
		world = minf(world, FORMATION_MEMBER_SCREEN_MAX / _camera_zoom)
		world = maxf(world, FORMATION_MEMBER_SCREEN_MIN / _camera_zoom)
	return world


func _write_representative(row: int, pos: Vector2, prototype_row: int) -> int:
	var instance_index := _next_formation_instance()
	var scale := _formation_representative_size(prototype_row)
	_store_formation_member(row, 0, prototype_row, 0.0, 0.0, scale)
	_set_formation_instance(instance_index, row, 0, prototype_row, pos,
		0.0, 0.0, scale)
	_formed_start[row] = instance_index
	_formed_count[row] = 1
	_formation_write_count = instance_index + 1
	return 1


func _write_formation_members(row: int, pos: Vector2,
		prototypes: PackedByteArray) -> int:
	var dominant := int(prototypes[0])
	var layout := _formation_catalog.layout_for(dominant, prototypes.size())
	if layout.is_empty():
		return 0
	var start := _next_formation_instance()
	for member in prototypes.size():
		var pair := layout[member] as Array
		var scale := _formation_member_size(int(prototypes[member]))
		var offset := Vector2(float(pair[0]), float(pair[1])) \
			* scale * FORMATION_LAYOUT_SPACING
		_store_formation_member(row, member, int(prototypes[member]),
			offset.x, offset.y, scale)
		_set_formation_instance(start + member, row, member,
			int(prototypes[member]), pos, offset.x, offset.y, scale)
	_formed_start[row] = start
	_formed_count[row] = prototypes.size()
	_formation_write_count = start + prototypes.size()
	return prototypes.size()


var _formation_write_count := 0


func _next_formation_instance() -> int:
	return _formation_write_count


func _store_formation_member(row: int, member: int, prototype_row: int,
		dx: float, dy: float, scale: float) -> void:
	var index := row * 5 + member
	_formed_proto[index] = prototype_row
	_formed_dx[index] = dx
	_formed_dy[index] = dy
	_formed_scale[index] = scale


func _set_formation_instance(instance_index: int, row: int, member: int,
		prototype_row: int, pos: Vector2, dx: float, dy: float,
		scale: float) -> void:
	var angle := _heading_radians(row)
	var member_pos := pos + Vector2(dx, dy).rotated(angle)
	var tx := Transform2D(angle, Vector2(scale, scale), 0.0, member_pos)
	var mm := _formation_batch.multimesh
	mm.set_instance_transform_2d(instance_index, tx)
	mm.set_instance_custom_data(instance_index,
		_formation_custom(row, member, prototype_row))
	mm.set_instance_color(instance_index, _owner_tint(_slot[row]))


func _formation_custom(row: int, member: int, prototype_row: int) -> Color:
	var action := _action_for_row(row)
	var phase := 0.0
	if action <= ACTION_MOVE:
		phase = fposmod(float(_handle[row]) * 0.137
			+ float(member) * 0.113, 1.0)
	elif action == ACTION_HIT:
		phase = one_shot_member_start(_hit_started[row], member)
	else:
		phase = one_shot_member_start(_attack_started[row], member)
	return Color(float(prototype_row), float(action), phase, float(member))


static func one_shot_member_start(started: float, member: int) -> float:
	return maxf(0.0, started
		+ float(maxi(0, member)) * ONE_SHOT_MEMBER_STAGGER_SECONDS)


func _action_for_row(row: int) -> int:
	var elapsed := _wall_time
	if _hit_started[row] >= 0.0 \
			and elapsed - _hit_started[row] < ONE_SHOT_ACTION_SECONDS:
		return ACTION_HIT
	if _attack_started[row] >= 0.0 \
			and elapsed - _attack_started[row] < ONE_SHOT_ACTION_SECONDS:
		return ACTION_ATTACK
	return ACTION_MOVE if _is_moving(row) else ACTION_IDLE


func _is_moving(row: int) -> bool:
	return row >= 0 and row < _t0.size() and _t0[row] > -50.0


func _heading_radians(row: int) -> float:
	var q16 := int(_heading[row]) & 0xFFFF if row < _heading.size() else 0
	return TAU * float(q16) / 65536.0


func _owner_tint(slot: int) -> Color:
	var hue := fposmod(float(slot) * 0.61803398875 + 0.04, 1.0)
	return Color.from_hsv(hue, 0.46, 0.82)


func _composition_prototypes(feed, row: int) -> PackedByteArray:
	var out := PackedByteArray()
	if not _has_formation_backend or feed == null:
		return out
	# M2 rollout is player-only. During late binding the production player slot
	# is -1; fail closed to paper rather than treating every country as the player.
	# Explicit harness/debug fixtures may opt into all-row rendering.
	if _player_slot >= 0:
		if _slot[row] != _player_slot:
			return out
	elif not _formation_allow_all_for_tests:
		return out
	var composition: Array[Dictionary] = feed.get_army_top3_composition(row)
	if composition.is_empty():
		return out
	for entry in composition:
		var prototype_row := _formation_catalog.prototype_row_for_unit(
			int(entry.get("unit", -1)))
		if prototype_row < 0:
			out.clear()
			return out
		out.append(prototype_row)
	return out


func _member_prototypes_for_row(feed, row: int,
		composition_prototypes: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	if composition_prototypes.is_empty():
		return out
	var composition: Array[Dictionary] = feed.get_army_top3_composition(row)
	var weights: Array = []
	for entry in composition:
		weights.append(float(entry.get("weight", 0)))
	var member_count := _formation_catalog.member_count_for_headcount(
		int(_heads[row]))
	var buckets := _formation_catalog.allocate_member_buckets(weights, member_count)
	var max_bucket := 0
	for value in buckets:
		max_bucket = maxi(max_bucket, int(value))
	for rank in max_bucket:
		for index in buckets.size():
			if int(buckets[index]) <= rank:
				continue
			out.append(int(composition_prototypes[index]))
	if out.size() != member_count:
		out.clear()
	return out


func _update_row_formation_custom(row: int) -> void:
	if _formation_batch == null or row < 0 or row >= _army_count:
		return
	var start := _formed_start[row]
	var count := int(_formed_count[row])
	if start < 0 or count <= 0:
		return
	var mm := _formation_batch.multimesh
	for member in count:
		var prototype_row := int(_formed_proto[row * 5 + member])
		mm.set_instance_custom_data(start + member,
			_formation_custom(row, member, prototype_row))


func _update_row_instance_transforms(row: int, paper_size: float) -> void:
	if row < 0 or row >= _army_count:
		return
	var pos := Vector2(_ax[row], _ay[row])
	if _row[row] >= 0 and _batch != null:
		var paper_scale := paper_size * (1.12 if _cell[row] == _selected_cell else 1.0)
		_batch.multimesh.set_instance_transform_2d(_row[row],
			Transform2D(0.0, Vector2(paper_scale, paper_scale), 0.0, pos))
	var count := int(_formed_count[row])
	if count <= 0 or _formation_batch == null:
		return
	var start := _formed_start[row]
	var angle := _heading_radians(row)
	for member in count:
		var index := row * 5 + member
		var member_pos := pos + Vector2(_formed_dx[index], _formed_dy[index]).rotated(angle)
		var scale := _formed_scale[index]
		_formation_batch.multimesh.set_instance_transform_2d(start + member,
			Transform2D(angle, Vector2(scale, scale), 0.0, member_pos))


func _build_aggregate() -> void:
	# 稀疏累加（Dictionary 只出现在 zoom<0.35 的聚合分支，且格子签名不变不重跑）。
	var by_cell := {}
	for i in _army_count:
		if _vis[i] == 0:
			continue
		var cell: int = _cell[i]
		if not by_cell.has(cell):
			by_cell[cell] = [i]
		else:
			(by_cell[cell] as Array).append(i)
	_agg_cell.clear()
	_agg_slot.clear()
	_agg_klass.clear()
	_agg_heads.clear()
	_agg_flags.clear()
	for cell in by_cell:
		var rows: Array = by_cell[cell]
		var best := int(rows[0])
		var heads := 0
		var flags := 0
		var slot := _slot[best]
		for row in rows:
			heads += int(_heads[row])
			flags |= _flags[row]
			if _heads[row] > _heads[best]:
				best = row
				slot = _slot[best]
		_agg_cell.append(int(cell))
		_agg_slot.append(slot)
		_agg_klass.append(_klass[best])
		_agg_heads.append(heads)
		_agg_flags.append(flags)
	_agg_count = _agg_cell.size()


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
