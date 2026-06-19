class_name ShrubLayer
extends Node2D

const _WT_RAIN := 1
const _WT_STORM := 2
const _WT_BLIZZARD := 3
const _WT_DROUGHT := 4
const _WT_HEATWAVE := 6
const _WT_MONSOON := 7
const DEFAULT_PROFILE := preload("res://data/visual/shrub_default.tres")
const DETAIL_SHRUB := 0
const DETAIL_TREE := 1
const DETAIL_GRASS := 2
# vegetation-visual-pcg 阶段 B：扩充 archetype。3..7 = 植被类（走植被 suitability +
# archetype 亲和），8..10 = 点缀/地貌类（走独立 _decoration_suitability，不依赖植被权重）。
const DETAIL_CONIFER := 3
const DETAIL_PALM := 4
const DETAIL_CACTUS := 5
const DETAIL_REED := 6
const DETAIL_ALPINE_FLOWER := 7
const DETAIL_ROCK := 8
const DETAIL_SNOW_MOUND := 9
const DETAIL_DEAD_SNAG := 10

const _SHADER_CODE := """
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D map_index_atlas : filter_nearest, repeat_disable;
uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D eco_lut : filter_nearest, repeat_disable;

uniform vec2 lut_dims = vec2(1.0, 1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);

uniform float world_time = 0.0;
uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float wind_strength = 1.0;
uniform float dry_yellow_strength = 0.82;
uniform float wet_green_strength = 0.48;
uniform float lush_green_strength = 0.72;
uniform float heat_red_strength = 0.55;
uniform float autumn_red_strength = 0.42;
uniform float snow_white_strength = 0.90;
uniform float stress_hide_strength = 0.78;
uniform float snow_hide_strength = 0.62;
uniform float disappear_alpha_threshold = 0.08;
uniform float vitality_dead_threshold = 0.12;
uniform float vitality_healthy_threshold = 0.72;
uniform float vitality_alpha_power = 1.10;
uniform float vitality_size_min = 0.34;
uniform float vitality_size_max = 1.08;
uniform float vitality_low_color_strength = 0.72;
uniform float vitality_high_color_strength = 0.42;
// 0 = 点缀/地貌类 archetype（岩石/雪堆/枯立木），抑制植被气候改色；1 = 植被类。
uniform float veg_response = 1.0;
// 阶段 D 精致化。
uniform vec2 wind_dir = vec2(1.0, 0.18);     // 全局盛行风方向（归一化前可任意）
uniform float weather_wind_boost = 0.0;      // 实时天气（风暴/季风）附加风强
uniform float bloom_strength = 0.0;          // 季节开花强度（花/部分植被 >0）
uniform float snow_burial = 0.55;            // 积雪埋没：下沉+缩矮强度
uniform float toon_shading = 0.30;           // 卡通分层：基部 AO + 轻量色阶量化

varying vec4 shrub_custom;
varying vec4 shrub_dyn;
varying vec4 shrub_eco;
varying float shrub_presence_v;
varying float shrub_dry_v;
varying float shrub_wet_v;
varying float shrub_snow_v;
varying float shrub_vitality_v;

int decode_cell_index(vec2 uv) {
	vec2 gb = texture(map_index_atlas, uv).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

vec2 cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) {
		lw = 1;
	}
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

vec4 sample_dyn_state(vec2 uv) {
	int cid = decode_cell_index(uv);
	return (cid >= 0) ? texture(dyn_lut, cell_lut_uv(cid)) : vec4(0.0);
}

vec4 sample_eco_state(vec2 uv) {
	int cid = decode_cell_index(uv);
	return (cid >= 0) ? texture(eco_lut, cell_lut_uv(cid)) : vec4(0.0);
}

float vitality_norm(float vitality) {
	float dead_t = min(vitality_dead_threshold, vitality_healthy_threshold - 0.001);
	float healthy_t = max(vitality_healthy_threshold, dead_t + 0.001);
	return clamp((clamp(vitality, 0.0, 1.0) - dead_t) / (healthy_t - dead_t), 0.0, 1.0);
}

float compute_presence(vec4 dyn, vec4 eco) {
	float dyn_valid = step(0.02, dyn.r);
	float temp = mix(0.5, dyn.r, dyn_valid);
	float moisture = mix(0.5, dyn.g, dyn_valid);
	float snow = dyn.b * dyn_valid;
	float vitality = mix(0.70, dyn.a, dyn_valid);
	float eco_stress = eco.g;
	float heat = smoothstep(0.74, 0.96, temp);
	float dry = clamp(max(max((0.34 - moisture) * 1.9, heat * 0.78), eco_stress), 0.0, 1.0);
	float cold = 1.0 - smoothstep(0.04, 0.20, temp);
	float snow_hide = clamp(max(snow, cold * 0.55), 0.0, 1.0);
	float presence = pow(vitality_norm(vitality), vitality_alpha_power);
	presence *= 1.0 - dry * stress_hide_strength;
	presence *= 1.0 - snow_hide * snow_hide_strength;
	return clamp(presence, 0.0, 1.0);
}

void vertex() {
	shrub_custom = INSTANCE_CUSTOM;
	vec2 shrub_uv = clamp(INSTANCE_CUSTOM.rg, vec2(0.0), vec2(1.0));
	shrub_dyn = sample_dyn_state(shrub_uv);
	shrub_eco = sample_eco_state(shrub_uv);
	float dyn_valid = step(0.02, shrub_dyn.r);
	float temp = mix(0.5, shrub_dyn.r, dyn_valid);
	float moisture = mix(0.5, shrub_dyn.g, dyn_valid);
	shrub_vitality_v = mix(0.70, shrub_dyn.a, dyn_valid);
	float eco_stress = shrub_eco.g;
	float heat = smoothstep(0.74, 0.96, temp);
	shrub_dry_v = clamp(max(max((0.34 - moisture) * 1.9, heat * 0.78), eco_stress), 0.0, 1.0);
	shrub_wet_v = clamp((moisture - 0.50) * 1.85, 0.0, 1.0) * (1.0 - shrub_dry_v);
	float cold = 1.0 - smoothstep(0.04, 0.20, temp);
	shrub_snow_v = clamp(max(shrub_dyn.b * dyn_valid, cold * 0.45), 0.0, 1.0);
	shrub_presence_v = compute_presence(shrub_dyn, shrub_eco);
	float live_scale = mix(0.20, 1.0, smoothstep(0.0, 0.85, shrub_presence_v));
	live_scale *= mix(vitality_size_min, vitality_size_max, pow(vitality_norm(shrub_vitality_v), 0.85));
	VERTEX *= live_scale;
	float top_weight = clamp(UV.y, 0.0, 1.0);
	float seed = INSTANCE_CUSTOM.b;
	float variant = INSTANCE_CUSTOM.a;
	float sway_amp = mix(0.045, 0.145, fract(seed * 17.13 + variant * 3.71));
	float sway = sin(world_time * (0.75 + variant * 1.65) + seed * 6.2831853);
	sway += 0.45 * sin(world_time * 1.7 + variant * 11.0);
	// 实时天气阵风：风暴/季风时附加更高频更大幅的摆动。
	sway += weather_wind_boost * (0.9 * sin(world_time * 3.4 + seed * 5.13) + 0.5);
	float amp = sway * sway_amp * (wind_strength + weather_wind_boost)
		* top_weight * smoothstep(0.10, 0.75, shrub_presence_v);
	// 方向风：沿全局盛行风方向摆动（而非固定 +x）。
	vec2 wdir = normalize(wind_dir + vec2(0.0001, 0.0));
	VERTEX += wdir * amp;
	// 雪埋：积雪越深，植株下沉（y 正为下）并缩矮，顶部更明显。
	float bury = clamp(shrub_snow_v * snow_burial, 0.0, 0.85);
	VERTEX.y += bury * 0.34 * top_weight;
	VERTEX *= 1.0 - bury * 0.42 * top_weight;
}

void fragment() {
	float sp = mod(season_phase, 4.0);
	float winter = smoothstep(2.65, 3.15, sp) * (1.0 - smoothstep(3.65, 3.98, sp));
	float snow = clamp(shrub_snow_v, 0.0, 1.0);
	float night = clamp(smoothstep(0.72, 0.94, day_phase) + (1.0 - smoothstep(0.05, 0.24, day_phase)), 0.0, 1.0);
	float dyn_valid = step(0.02, shrub_dyn.r);
	float temp = mix(0.5, shrub_dyn.r, dyn_valid);
	float moisture = mix(0.5, shrub_dyn.g, dyn_valid);
	float vitality_n = vitality_norm(shrub_vitality_v);
	float dry_hot = smoothstep(0.78, 0.98, temp) * (1.0 - smoothstep(0.18, 0.44, moisture));
	float autumn = smoothstep(1.45, 2.08, sp) * (1.0 - smoothstep(2.55, 3.05, sp));
	float low_vitality = pow(1.0 - vitality_n, 1.35);
	float yellow_amount = smoothstep(0.18, 0.78, shrub_dry_v) * dry_yellow_strength * (1.0 - dry_hot * 0.42) * veg_response;
	float heat_red_amount = dry_hot * smoothstep(0.35, 0.90, shrub_dry_v) * heat_red_strength * veg_response;
	float autumn_red_amount = autumn * vitality_n * (1.0 - shrub_wet_v * 0.55) * autumn_red_strength * veg_response;
	float lush_amount = shrub_wet_v * vitality_n * lush_green_strength * veg_response;
	float snow_amount = clamp(max(snow, winter * shrub_snow_v) * snow_white_strength, 0.0, 1.0);

	vec3 rgb = COLOR.rgb;
	rgb = mix(rgb, vec3(0.43, 0.34, 0.20), max(low_vitality * vitality_low_color_strength, shrub_dry_v * low_vitality * 0.55) * veg_response);
	rgb = mix(rgb, vec3(0.10, 0.48, 0.16), vitality_n * vitality_high_color_strength * (1.0 - shrub_dry_v) * veg_response);
	rgb = mix(rgb, vec3(0.05, 0.76, 0.22), lush_amount);
	rgb = mix(rgb, vec3(0.94, 0.76, 0.18), yellow_amount);
	rgb = mix(rgb, vec3(0.88, 0.34, 0.10), heat_red_amount);
	rgb = mix(rgb, vec3(0.72, 0.11, 0.08), autumn_red_amount * (1.0 - snow_amount));
	rgb = mix(rgb, vec3(0.08, 0.52, 0.18), shrub_wet_v * wet_green_strength * vitality_n * (1.0 - yellow_amount) * veg_response);
	// 季节开花：春季给开花类一抹亮色（活力越高越盛，积雪覆盖时收敛）。
	float spring = clamp(1.0 - abs(sp - 0.4) / 0.9, 0.0, 1.0);
	float bloom = bloom_strength * spring * vitality_n * (1.0 - snow_amount * 0.85);
	rgb = mix(rgb, rgb * vec3(1.12, 1.0, 1.08) + vec3(0.10, 0.03, 0.08), bloom);
	rgb = mix(rgb, vec3(0.69, 0.72, 0.63), winter * 0.16);
	rgb = mix(rgb, vec3(0.96, 0.98, 1.0), snow_amount);
	rgb *= mix(1.0, 0.68, night);
	// 卡通分层：基部 AO（UV.y 低=近根，压暗）+ 轻量 3 阶色调量化。
	float ao = 1.0 - (1.0 - clamp(UV.y, 0.0, 1.0)) * toon_shading * 0.38;
	rgb *= ao;
	float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
	float ql = floor(luma * 3.0 + 0.5) / 3.0;
	rgb *= (luma > 0.0015) ? mix(1.0, ql / luma, toon_shading * 0.55) : 1.0;
	float alpha = COLOR.a * shrub_presence_v;
	alpha *= 1.0 - snow * 0.32;
	alpha = (alpha < disappear_alpha_threshold) ? 0.0 : alpha;
	COLOR = vec4(rgb, alpha);
}
"""

@export var profile: Resource = DEFAULT_PROFILE:
	set(value):
		profile = value if value != null else DEFAULT_PROFILE
		_apply_profile_uniforms()
		if is_inside_tree() and _map != null:
			_rebuild_instances()

var _map: MapData = null
var _world: WorldData = null
var _bounds: Rect2 = Rect2()
var _hex_size: float = 22.0
var _visual_quality: int = 1
var _mobile_quality_tier: int = 1
# C++ DCWorldExt（由 hex_renderer.set_world_ext 注入）。null 或缺 encode_detail_scatter
# 方法时，散布生成走 GDScript fallback；二者结果是同一确定性 PCG 场的等价实现。
var _world_ext = null
# 上一次 _rebuild_instances 实际走的路径（"gdext" / "gdscript"），供调试/性能日志。
var _last_scatter_path: String = "none"

var _mmi: MultiMeshInstance2D = null
var _multimesh: MultiMesh = null
var _material: ShaderMaterial = null

var _instance_cell_indices: PackedInt32Array = PackedInt32Array()
var _instance_positions: PackedVector2Array = PackedVector2Array()
var _instance_rotations: PackedFloat32Array = PackedFloat32Array()
var _instance_sizes: PackedFloat32Array = PackedFloat32Array()
var _instance_seeds: PackedFloat32Array = PackedFloat32Array()
var _instance_variants: PackedFloat32Array = PackedFloat32Array()
var _instance_scores: PackedFloat32Array = PackedFloat32Array()
var _instance_cells: Array = []
var _instance_count: int = 0


func _ready() -> void:
	z_as_relative = false
	_ensure_resources()


func setup(map: MapData, world: WorldData, bounds: Rect2, hex_size: float, visual_quality: int = 1) -> void:
	_map = map
	_world = world
	_bounds = bounds
	_hex_size = maxf(hex_size, 4.0)
	_visual_quality = clampi(visual_quality, 0, 2)
	_sync_world_material_inputs(false)
	_rebuild_instances()


func clear() -> void:
	_instance_cell_indices = PackedInt32Array()
	_instance_positions = PackedVector2Array()
	_instance_rotations = PackedFloat32Array()
	_instance_sizes = PackedFloat32Array()
	_instance_seeds = PackedFloat32Array()
	_instance_variants = PackedFloat32Array()
	_instance_scores = PackedFloat32Array()
	_instance_cells.clear()
	_instance_count = 0
	if _multimesh != null:
		_multimesh.instance_count = 0
		_multimesh.visible_instance_count = 0
	visible = false


func set_world_time(v: float) -> void:
	if _material != null:
		_material.set_shader_parameter("world_time", v)


func set_season_phase(v: float) -> void:
	if _material != null:
		_material.set_shader_parameter("season_phase", v)


func set_day_phase(v: float) -> void:
	if _material != null:
		_material.set_shader_parameter("day_phase", fposmod(v, 1.0))


func set_world_material_inputs(world: WorldData, bounds: Rect2, _use_cell_indirection: bool) -> void:
	_world = world
	_bounds = bounds
	_sync_world_material_inputs(true)


# 阶段 D：全局盛行风方向 + 实时天气附加风强（风暴/季风）。每帧由 hex_renderer 推送。
func set_wind_field(dir: Vector2, boost: float) -> void:
	if _material == null:
		return
	var d := dir if dir.length() > 0.0001 else Vector2(1.0, 0.18)
	_material.set_shader_parameter("wind_dir", d.normalized())
	_material.set_shader_parameter("weather_wind_boost", maxf(boost, 0.0))


# 注入 C++ DCWorldExt。可传 null 关闭 native 路径（强制 GDScript fallback）。
func set_world_ext(ext) -> void:
	_world_ext = ext


func set_visual_quality(q: int) -> void:
	var next_q := clampi(q, 0, 2)
	if _visual_quality == next_q:
		return
	_visual_quality = next_q
	if _map != null:
		_rebuild_instances()


func set_mobile_quality_tier(q: int) -> void:
	var next_q := clampi(q, 0, 2)
	if _mobile_quality_tier == next_q:
		return
	_mobile_quality_tier = next_q
	if OS.has_feature("mobile") and _map != null:
		_rebuild_instances()


func _ensure_resources() -> void:
	if _mmi == null:
		_mmi = MultiMeshInstance2D.new()
		_mmi.name = "ShrubMultiMesh"
		add_child(_mmi)
	if _material == null:
		var shader := Shader.new()
		shader.code = _SHADER_CODE
		_material = ShaderMaterial.new()
		_material.shader = shader
		_material.set_shader_parameter("world_time", 0.0)
		_material.set_shader_parameter("season_phase", 1.0)
		_material.set_shader_parameter("day_phase", 0.25)
		_mmi.material = _material
	_apply_profile_uniforms()
	_sync_world_material_inputs(false)


func _apply_profile_uniforms() -> void:
	if _material == null:
		return
	var cfg := _profile()
	z_index = int(cfg.render_z_index)
	_material.set_shader_parameter("wind_strength", cfg.wind_strength)
	_material.set_shader_parameter("dry_yellow_strength", cfg.dry_yellow_strength)
	_material.set_shader_parameter("wet_green_strength", cfg.wet_green_strength)
	_material.set_shader_parameter("lush_green_strength", cfg.lush_green_strength)
	_material.set_shader_parameter("heat_red_strength", cfg.heat_red_strength)
	_material.set_shader_parameter("autumn_red_strength", cfg.autumn_red_strength)
	_material.set_shader_parameter("snow_white_strength", cfg.snow_white_strength)
	_material.set_shader_parameter("stress_hide_strength", cfg.stress_hide_strength)
	_material.set_shader_parameter("snow_hide_strength", cfg.snow_hide_strength)
	_material.set_shader_parameter("disappear_alpha_threshold", cfg.disappear_alpha_threshold)
	_material.set_shader_parameter("vitality_dead_threshold", cfg.vitality_dead_threshold)
	_material.set_shader_parameter("vitality_healthy_threshold", cfg.vitality_healthy_threshold)
	_material.set_shader_parameter("vitality_alpha_power", cfg.vitality_alpha_power)
	_material.set_shader_parameter("vitality_size_min", cfg.vitality_size_min)
	_material.set_shader_parameter("vitality_size_max", cfg.vitality_size_max)
	_material.set_shader_parameter("vitality_low_color_strength", cfg.vitality_low_color_strength)
	_material.set_shader_parameter("vitality_high_color_strength", cfg.vitality_high_color_strength)
	# 点缀/地貌类 archetype 抑制植被气候改色（岩石不该变绿/变黄）。
	var arch := _detail_kind()
	var is_deco := _is_decoration_archetype(arch)
	_material.set_shader_parameter("veg_response", 0.0 if is_deco else 1.0)
	# 阶段 D：按 archetype 推送外观 uniform。
	# 开花：高山花最盛，灌木/树轻微，点缀/草不开花。
	var bloom := 0.0
	match arch:
		DETAIL_ALPINE_FLOWER: bloom = 0.85
		DETAIL_SHRUB: bloom = 0.16
		DETAIL_REED: bloom = 0.10
		_: bloom = 0.0
	_material.set_shader_parameter("bloom_strength", bloom)
	# 雪埋：植被会被积雪压伏；雪堆本身就是雪、岩石/枯木不缩。
	_material.set_shader_parameter("snow_burial", 0.0 if is_deco else 0.55)
	# 卡通分层：所有 archetype 都受益于基部 AO，点缀类略弱以保持硬朗轮廓。
	_material.set_shader_parameter("toon_shading", 0.22 if is_deco else 0.32)


func _sync_world_material_inputs(_use_cell_indirection: bool) -> void:
	if _material == null:
		return
	var bounds := _bounds
	_material.set_shader_parameter("world_origin", bounds.position)
	_material.set_shader_parameter("world_size", bounds.size)
	if _world == null:
		_material.set_shader_parameter("lut_dims", Vector2.ONE)
		return
	_material.set_shader_parameter("map_index_atlas", _world.enum_atlas_tex)
	_material.set_shader_parameter("dyn_lut", _world.dyn_lut_tex)
	_material.set_shader_parameter("eco_lut", _world.eco_lut_tex)
	_material.set_shader_parameter("lut_dims", Vector2(_world.lut_dims.x, _world.lut_dims.y))


func _rebuild_instances() -> void:
	_ensure_resources()
	clear()
	var cfg := _profile()
	if not cfg.enabled or _map == null or _map.cell_count() <= 0:
		return

	var cells: Array = _map.iter_cells()
	if cells.is_empty():
		cells = _map.all_cells()
	if cells.is_empty():
		return

	var cell_attempts := PackedInt32Array()
	cell_attempts.resize(cells.size())
	var cell_states: Array = []
	cell_states.resize(cells.size())
	var cell_suitabilities := PackedFloat32Array()
	cell_suitabilities.resize(cells.size())
	var total_attempts: int = 0
	for order in range(cells.size()):
		var cell = cells[order]
		if cell == null:
			continue
		var idx := _cell_index(cell, order)
		var key := _cell_hash_key(cell, order)
		var state := _sample_cell_state(idx, cell)
		var suitability := _cell_suitability(cell, idx, key, state)
		if suitability <= 0.0:
			continue
		cell_states[order] = state
		cell_suitabilities[order] = suitability
		var attempts := maxi(1, int(ceil(float(_max_per_cell()) * clampf(suitability, 0.0, 1.0))))
		cell_attempts[order] = attempts
		total_attempts += attempts

	if total_attempts <= 0:
		return

	# C++ 优先：把"每实例候选生成 + 噪声门 + 接受 + cap + MultiMesh buffer 组装"
	# 整段热循环下沉 DCWorldExt.encode_detail_scatter，GDScript 仅做上面这段
	# per-cell（N≤2400）廉价预计算。失败 / 旧 DLL 无该方法时回退到下方 GDScript 路径。
	if _rebuild_via_native(cells, cell_states, cell_suitabilities, cell_attempts):
		_last_scatter_path = "gdext"
		return
	_last_scatter_path = "gdscript"

	for order in range(cells.size()):
		var cell = cells[order]
		if cell == null:
			continue
		var idx := _cell_index(cell, order)
		var key := _cell_hash_key(cell, order)
		var suitability := cell_suitabilities[order]
		if suitability <= 0.0:
			continue
		var state: Dictionary = cell_states[order]
		for attempt in range(cell_attempts[order]):
			_try_append_instance(cell, idx, key, attempt, suitability, state)

	_apply_instance_cap()
	_instance_count = _instance_cell_indices.size()
	if _instance_count <= 0:
		return

	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_multimesh.use_colors = true
	_multimesh.use_custom_data = true
	_multimesh.mesh = _build_shrub_mesh()
	_multimesh.instance_count = _instance_count
	_multimesh.visible_instance_count = _instance_count
	_mmi.multimesh = _multimesh

	for i in range(_instance_count):
		var xf := _instance_transform(i)
		_multimesh.set_instance_transform_2d(i, xf)
		var idx := _instance_cell_indices[i]
		var state := _sample_cell_state(idx, _instance_cells[i])
		_multimesh.set_instance_color(i, _base_color_for_state(state, _instance_variants[i]))
		var uv := _world_uv(_instance_positions[i])
		_multimesh.set_instance_custom_data(i, Color(
			uv.x,
			uv.y,
			_instance_seeds[i],
			_instance_variants[i]
		))
	visible = cfg.enabled and _instance_count > 0


func _rebuild_via_native(
		cells: Array,
		cell_states: Array,
		cell_suitabilities: PackedFloat32Array,
		cell_attempts: PackedInt32Array) -> bool:
	if _world_ext == null or not _world_ext.has_method("encode_detail_scatter"):
		return false
	if _map == null:
		return false
	var grid_w: int = int(_map.width) if "width" in _map else 0
	var grid_h: int = int(_map.height) if "height" in _map else 0
	if grid_w <= 0 or grid_h <= 0:
		return false
	var cfg := _profile()

	# offset 网格 is_water 栅格（odd-r），用于 C++ 端精确复刻 _is_water_position：
	# world_to_cube → cube_to_offset → 越界 / 水域 cell 即拒绝。空位预置 1（拒绝）。
	var offset_is_water := PackedByteArray()
	offset_is_water.resize(grid_w * grid_h)
	offset_is_water.fill(1)

	# 每个"活跃 cell"（suitability>0 且 climate_presence>0.02）的廉价 per-cell 数据。
	var keys := PackedInt32Array()
	var cx := PackedFloat32Array()
	var cy := PackedFloat32Array()
	var suit := PackedFloat32Array()
	var att := PackedInt32Array()
	var vit := PackedFloat32Array()
	var sized := PackedFloat32Array()
	var col_r := PackedFloat32Array()
	var col_g := PackedFloat32Array()
	var col_b := PackedFloat32Array()
	var col_a := PackedFloat32Array()

	for order in range(cells.size()):
		var cell = cells[order]
		if cell == null:
			continue
		var idx := _cell_index(cell, order)
		# 填 is_water 栅格（所有 cell，含水域）。
		var off := HexUtils.cube_to_offset(int(cell.q), int(cell.r))
		if off.x >= 0 and off.x < grid_w and off.y >= 0 and off.y < grid_h:
			offset_is_water[off.y * grid_w + off.x] = (1 if _is_water_cell(cell, idx) else 0)
		var suitability := cell_suitabilities[order]
		if suitability <= 0.0:
			continue
		var state: Dictionary = cell_states[order]
		if not (state is Dictionary):
			continue
		if _climate_presence(state) <= 0.02:
			continue
		var veg := int(state.get("vegetation", VegetationType.VEG.NONE))
		var lf := int(state.get("landform", LandformType.LF.PLAIN))
		var cover := int(state.get("cover", CoverType.CV.NONE))
		var center := _cell_center(cell, idx)
		var base := _base_color_for_vegetation(veg)
		keys.append(_cell_hash_key(cell, order))
		cx.append(center.x)
		cy.append(center.y)
		suit.append(suitability)
		att.append(cell_attempts[order])
		vit.append(clampf(float(state.get("vitality", 0.7)), 0.0, 1.0))
		sized.append(_vegetation_weight(veg) * _landform_weight(lf) * _cover_weight(cover))
		col_r.append(base.r)
		col_g.append(base.g)
		col_b.append(base.b)
		col_a.append(base.a)

	if keys.is_empty():
		return false

	var knobs := {
		"hex_size": _hex_size,
		"origin_x": _bounds.position.x,
		"origin_y": _bounds.position.y,
		"size_x": _bounds.size.x,
		"size_y": _bounds.size.y,
		"grid_w": grid_w,
		"grid_h": grid_h,
		"offset_is_water": offset_is_water,
		"flow_buffer": _world.flow_buffer if _world != null else PackedFloat32Array(),
		"flow_w": int(_world.derived_size.x) if _world != null else 0,
		"flow_h": int(_world.derived_size.y) if _world != null else 0,
		"river_clear_threshold": cfg.river_clear_threshold,
		"spawn_radius_factor": cfg.spawn_radius_factor,
		"world_noise_warp_strength": cfg.world_noise_warp_strength,
		"patch_frequency": cfg.patch_frequency,
		"patch_cutoff": cfg.patch_cutoff,
		"patch_contrast": cfg.patch_contrast,
		"world_noise_mid_mix": cfg.world_noise_mid_mix,
		"world_noise_fine_mix": cfg.world_noise_fine_mix,
		"micro_gap_threshold": cfg.micro_gap_threshold,
		"world_noise_acceptance": cfg.world_noise_acceptance,
		"min_size_factor": minf(cfg.min_size_factor, cfg.max_size_factor),
		"max_size_factor": maxf(cfg.min_size_factor, cfg.max_size_factor),
		"size_scale": _quality_size_scale(),
		"vitality_dead_threshold": cfg.vitality_dead_threshold,
		"vitality_dieback_noise_strength": cfg.vitality_dieback_noise_strength,
		"instance_cap": _instance_cap(),
		"keys": keys,
		"center_x": cx,
		"center_y": cy,
		"suitability": suit,
		"attempts": att,
		"vitality": vit,
		"size_density": sized,
		"color_r": col_r,
		"color_g": col_g,
		"color_b": col_b,
		"color_a": col_a,
	}

	var res = _world_ext.call("encode_detail_scatter", knobs)
	if not (res is Dictionary):
		return false
	if bool(res.get("fallback", true)):
		return false
	var buffer: PackedFloat32Array = res.get("buffer", PackedFloat32Array())
	var inst: int = int(res.get("instance_count", 0))
	# 每实例 stride = transform2d(8) + color(4) + custom(4) = 16 float。
	if inst <= 0 or buffer.size() < inst * 16:
		clear()
		return true

	_instance_count = inst
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_multimesh.use_colors = true
	_multimesh.use_custom_data = true
	_multimesh.mesh = _build_shrub_mesh()
	_multimesh.instance_count = inst
	_multimesh.buffer = buffer
	_multimesh.visible_instance_count = inst
	_mmi.multimesh = _multimesh
	visible = cfg.enabled and inst > 0
	return true


func _cell_suitability(cell, idx: int, _key: int, state: Dictionary) -> float:
	if _is_water_cell(cell, idx):
		return 0.0

	var lf := int(state.get("landform", LandformType.LF.PLAIN))
	var veg := int(state.get("vegetation", VegetationType.VEG.NONE))
	var cover := int(state.get("cover", CoverType.CV.NONE))
	var river := _has_river_cell(cell, idx)
	var arch := _detail_kind()

	# 点缀/地貌类 archetype（岩石/雪堆/枯立木）走独立 suitability：不依赖植被权重，
	# 由地形/覆盖物/气候直接决定，能出现在植被权重为 0 的裸露/雪原/山巅。
	if _is_decoration_archetype(arch):
		return _decoration_suitability(arch, lf, cover, river, state)

	var landform_weight := _landform_weight(lf)
	if landform_weight <= 0.0:
		return 0.0

	var cover_weight := _cover_weight(cover)
	if cover_weight <= 0.0:
		return 0.0

	var temp := float(state.get("temp", 0.5))
	var moisture := float(state.get("moisture", 0.5))
	var vitality := float(state.get("vitality", 0.7))
	var stress := maxf(float(state.get("heat", 0.0)), maxf(float(state.get("drought", 0.0)), float(state.get("cold", 0.0))))
	var compat := VegetationType.climate_compat_score(veg, temp, moisture)
	var vitality_factor := _vitality_density_factor(state)

	var suitability := _vegetation_weight(veg) * landform_weight * cover_weight
	suitability *= vitality_factor
	suitability *= lerpf(0.58, 1.0, clampf(compat, 0.0, 1.0))
	suitability *= 1.0 - clampf(stress, 0.0, 1.0) * 0.38
	suitability *= lerpf(0.08, 1.0, _climate_presence(state))
	suitability *= _cell_ecology_density_bias(state)
	# archetype 生态位亲和（针叶/棕榈/仙人掌/芦苇/高山花）：把通用植被分布收束到各自气候带。
	suitability *= _archetype_affinity(arch, veg, lf, cover, river, state)
	# 阶段 C：海拔林线 + 强风折损。
	suitability *= _elevation_modifier(arch, float(state.get("elevation", 0.4)))
	suitability *= _wind_exposure_modifier(arch, float(state.get("wind_speed", 0.0)))
	var cfg := _profile()
	if river:
		suitability *= cfg.river_edge_density
	suitability *= _quality_density_scale()
	return clampf(suitability, 0.0, 1.25)


# 海拔林线：高海拔抑制乔木/棕榈，偏好高山花/针叶中带；低海拔归一。elevation∈[0,1]。
func _elevation_modifier(arch: int, elev: float) -> float:
	match arch:
		DETAIL_TREE, DETAIL_PALM:
			return smoothstep(0.92, 0.58, elev)
		DETAIL_CONIFER:
			return smoothstep(0.22, 0.55, elev) * smoothstep(0.97, 0.74, elev) + 0.25
		DETAIL_ALPINE_FLOWER:
			return clampf(smoothstep(0.46, 0.82, elev) + 0.12, 0.0, 1.2)
		DETAIL_SHRUB, DETAIL_GRASS, DETAIL_CACTUS, DETAIL_REED:
			return smoothstep(0.97, 0.62, elev)
	return 1.0


# 强风折损：脆弱高茎（棕榈/芦苇/枯立木/高山花）在大风带略减。wind_speed 物理量（~m/s）。
func _wind_exposure_modifier(arch: int, wind_speed: float) -> float:
	var w: float = clampf(wind_speed / 18.0, 0.0, 1.0)
	match arch:
		DETAIL_PALM, DETAIL_REED, DETAIL_ALPINE_FLOWER:
			return lerpf(1.0, 0.7, w)
		DETAIL_DEAD_SNAG:
			return lerpf(1.0, 0.6, w)
	return 1.0


# 3..7 植被类 archetype 的生态位亲和乘子（legacy 0/1/2 恒返回 1.0）。
func _archetype_affinity(arch: int, veg: int, lf: int, _cover: int, river: bool, state: Dictionary) -> float:
	var temp := float(state.get("temp", 0.5))
	var moisture := float(state.get("moisture", 0.5))
	var soil := float(state.get("soil_moisture", moisture))
	var discharge := float(state.get("river_discharge", 0.0))
	# 实际地表湿润 = 气候湿度与土壤湿度的较强者（土壤更贴近根系可用水）。
	var wet := maxf(moisture, soil)
	var dry := minf(moisture, soil)
	var big_river: float = clampf(discharge / 80.0, 0.0, 1.0)
	match arch:
		DETAIL_CONIFER:
			# 寒带针叶林应成片：把生态位亲和拉高到能让 suitability 在针叶带饱和到 1.0。
			var a := 0.10
			match veg:
				VegetationType.VEG.TAIGA:
					a = 2.6
				VegetationType.VEG.TEMPERATE_CONIFER:
					a = 2.3
				VegetationType.VEG.BOREAL_SHRUB:
					a = 1.3
				VegetationType.VEG.ALPINE_TUNDRA, VegetationType.VEG.TEMPERATE_DECIDUOUS:
					a = 0.8
			a *= smoothstep(0.82, 0.22, temp)  # 偏冷，冷带更宽
			return a
		DETAIL_PALM:
			var a := 0.0
			match veg:
				VegetationType.VEG.TROPICAL_RAINFOREST, VegetationType.VEG.SUBTROPICAL_FOREST:
					a = 1.7
				VegetationType.VEG.TROPICAL_DRY_FOREST, VegetationType.VEG.SAVANNA:
					a = 1.1
				VegetationType.VEG.MANGROVE, VegetationType.VEG.OASIS_VEG:
					a = 1.4
			a *= smoothstep(0.55, 0.85, temp)  # 偏暖
			if lf == LandformType.LF.DELTA or lf == LandformType.LF.LOWLAND or river:
				a *= 1.3
			a *= lerpf(1.0, 1.45, big_river)  # 大河三角洲椰林
			return a
		DETAIL_CACTUS:
			var a := 0.06
			match veg:
				VegetationType.VEG.DESERT_SCRUB:
					a = 1.9
				VegetationType.VEG.XERIC_DESERT:
					a = 1.0
				VegetationType.VEG.MEDITERRANEAN_SHRUB, VegetationType.VEG.SAVANNA:
					a = 0.55
				VegetationType.VEG.OASIS_VEG:
					a = 0.75
			a *= smoothstep(0.5, 0.85, temp) * smoothstep(0.55, 0.16, dry)  # 热且（气候+土壤）双干
			return a
		DETAIL_REED:
			var a := 0.06
			match veg:
				VegetationType.VEG.MARSH:
					a = 1.9
				VegetationType.VEG.SWAMP, VegetationType.VEG.MANGROVE:
					a = 1.6
				VegetationType.VEG.TEMPERATE_GRASSLAND, VegetationType.VEG.SAVANNA:
					a = 0.45
			a *= smoothstep(0.45, 0.85, wet)  # 气候/土壤湿润取强
			if river:
				a *= 1.8
			a *= lerpf(1.0, 1.6, big_river)  # 大河岸芦苇荡
			if lf == LandformType.LF.DELTA:
				a *= 1.4
			return a
		DETAIL_ALPINE_FLOWER:
			var a := 0.06
			match veg:
				VegetationType.VEG.ALPINE_MEADOW:
					a = 2.0
				VegetationType.VEG.ALPINE_TUNDRA, VegetationType.VEG.TUNDRA:
					a = 1.2
				VegetationType.VEG.TEMPERATE_GRASSLAND:
					a = 0.4
			if lf == LandformType.LF.MOUNTAIN or lf == LandformType.LF.HILL:
				a *= 1.25
			a *= smoothstep(0.78, 0.32, temp)  # 偏冷凉
			return a
	return 1.0


func _is_decoration_archetype(arch: int) -> bool:
	return arch == DETAIL_ROCK or arch == DETAIL_SNOW_MOUND or arch == DETAIL_DEAD_SNAG


# 点缀/地貌类 archetype 的独立 suitability（不经植被权重）。
func _decoration_suitability(arch: int, lf: int, cover: int, river: bool, state: Dictionary) -> float:
	if LandformType.is_water(lf):
		return 0.0
	var temp := float(state.get("temp", 0.5))
	var snow := float(state.get("snow", 0.0))
	var vitality := float(state.get("vitality", 0.7))
	var drought := float(state.get("drought", 0.0))
	var cold := float(state.get("cold", 0.0))
	var elev := float(state.get("elevation", 0.4))
	var s := 0.0
	match arch:
		DETAIL_ROCK:
			match lf:
				LandformType.LF.MOUNTAIN, LandformType.LF.PEAK:
					s = 1.1
				LandformType.LF.VOLCANO:
					s = 0.9
				LandformType.LF.BADLANDS:
					s = 0.95
				LandformType.LF.HILL:
					s = 0.5
				LandformType.LF.SALT_FLAT:
					s = 0.35
				_:
					s = 0.12
			# 越裸露（活力低）岩石越显
			s *= lerpf(1.25, 0.55, _vitality_normalized(vitality))
			# 高海拔裸岩更多
			s *= lerpf(0.85, 1.4, smoothstep(0.5, 0.95, elev))
			if river:
				s *= 0.6
		DETAIL_SNOW_MOUND:
			var snowy: float = maxf(snow, 1.0 if cover == CoverType.CV.SNOW or cover == CoverType.CV.PERMAFROST else 0.0)
			if cover == CoverType.CV.GLACIER:
				snowy = maxf(snowy, 0.85)
			s = smoothstep(0.22, 0.7, snowy) * 1.1
			s *= smoothstep(0.62, 0.2, temp)
			# 高海拔雪线以上常年积雪堆增多
			s *= lerpf(0.9, 1.3, smoothstep(0.55, 0.92, elev))
		DETAIL_DEAD_SNAG:
			# 低活力 + 旱/冷胁迫的"曾经有林"区域。枯立木点缀，适度可见即可。
			var stress: float = maxf(drought, cold)
			s = (1.0 - _vitality_normalized(vitality)) * lerpf(0.65, 1.5, clampf(stress, 0.0, 1.0))
			match lf:
				LandformType.LF.PLAIN, LandformType.LF.LOWLAND, LandformType.LF.HILL:
					s *= 1.3
				LandformType.LF.BADLANDS:
					s *= 0.95
				_:
					s *= 0.55
	s *= lerpf(0.18, 1.0, _climate_presence(state))
	s *= _quality_density_scale()
	return clampf(s, 0.0, 1.25)


func _try_append_instance(
		cell,
		idx: int,
		key: int,
		attempt: int,
		cell_suitability: float,
		state: Dictionary) -> void:
	var cfg := _profile()
	var climate_presence := _climate_presence(state)
	if climate_presence <= 0.02:
		return
	var vitality := clampf(float(state.get("vitality", 0.7)), 0.0, 1.0)
	if vitality <= cfg.vitality_dead_threshold:
		var dieback_noise := _hash01(key, 931 + attempt)
		if dieback_noise < 1.0 - cfg.vitality_dieback_noise_strength:
			return
	var center := _cell_center(cell, idx)
	var pos := _candidate_position(center, key, attempt)
	if _is_water_position(pos, cell, idx):
		return
	if _is_river_body_position(pos):
		return
	var world_noise := _world_noise_suitability(pos)
	if world_noise <= 0.001:
		return
	var micro_noise := _world_micro_gap(pos, key, attempt)
	if micro_noise < cfg.micro_gap_threshold:
		return
	var noise_gate := pow(clampf(world_noise, 0.0, 1.0), 1.35)
	var local_acceptance := clampf(cell_suitability * cfg.world_noise_acceptance * noise_gate, 0.0, 1.0)
	if _hash01(key, 9300 + attempt) > clampf(local_acceptance, 0.0, 1.0):
		return
	var variant := _hash01(key, 300 + attempt)
	var min_size: float = minf(cfg.min_size_factor, cfg.max_size_factor)
	var max_size: float = maxf(cfg.min_size_factor, cfg.max_size_factor)
	var size := _hex_size * lerpf(min_size, max_size, _hash01(key, 400 + attempt))
	size *= lerpf(0.85, 1.12, clampf(_sample_density_for_size(idx, cell), 0.0, 1.0))
	size *= _quality_size_scale()

	_instance_cell_indices.append(idx)
	_instance_cells.append(cell)
	_instance_positions.append(pos)
	_instance_rotations.append(_hash01(key, 500 + attempt) * TAU)
	_instance_sizes.append(size)
	_instance_seeds.append(_hash01(key, 600 + attempt))
	_instance_variants.append(variant)
	_instance_scores.append(world_noise * 0.66 + cell_suitability * 0.27 + _hash01(key, 7600 + attempt) * 0.07)


func _apply_instance_cap() -> void:
	var cap := _instance_cap()
	if cap <= 0:
		clear()
		return
	var n := _instance_cell_indices.size()
	if n <= cap:
		return
	var order: Array[int] = []
	order.resize(n)
	for i in range(n):
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool:
		return _instance_scores[a] > _instance_scores[b]
	)
	var keep_lookup := {}
	for i in range(cap):
		keep_lookup[order[i]] = true
	var next_cell_indices := PackedInt32Array()
	var next_positions := PackedVector2Array()
	var next_rotations := PackedFloat32Array()
	var next_sizes := PackedFloat32Array()
	var next_seeds := PackedFloat32Array()
	var next_variants := PackedFloat32Array()
	var next_scores := PackedFloat32Array()
	var next_cells: Array = []
	for i in range(n):
		if not keep_lookup.has(i):
			continue
		next_cell_indices.append(_instance_cell_indices[i])
		next_positions.append(_instance_positions[i])
		next_rotations.append(_instance_rotations[i])
		next_sizes.append(_instance_sizes[i])
		next_seeds.append(_instance_seeds[i])
		next_variants.append(_instance_variants[i])
		next_scores.append(_instance_scores[i])
		next_cells.append(_instance_cells[i])
	_instance_cell_indices = next_cell_indices
	_instance_positions = next_positions
	_instance_rotations = next_rotations
	_instance_sizes = next_sizes
	_instance_seeds = next_seeds
	_instance_variants = next_variants
	_instance_scores = next_scores
	_instance_cells = next_cells


func _candidate_position(center: Vector2, key: int, attempt: int) -> Vector2:
	var cfg := _profile()
	var angle: float = fposmod(_hash01(key, 101) + float(attempt) * 0.61803398875, 1.0) * TAU
	var radius: float = sqrt(_hash01(key, 200 + attempt * 37)) * _hex_size * cfg.spawn_radius_factor
	var jitter: Vector2 = Vector2(cos(angle), sin(angle)) * radius
	var base_pos: Vector2 = center + jitter
	var warp: Vector2 = Vector2(
		_value_noise2(base_pos.x * 0.033, base_pos.y * 0.033, 911) - 0.5,
		_value_noise2(base_pos.x * 0.033, base_pos.y * 0.033, 977) - 0.5
	) * (_hex_size * cfg.world_noise_warp_strength)
	return base_pos + warp


func _world_noise_suitability(world_pos: Vector2) -> float:
	var cfg := _profile()
	var p := world_pos / maxf(_hex_size, 1.0)
	var warp := Vector2(
		_value_noise2(p.x * cfg.patch_frequency * 0.55, p.y * cfg.patch_frequency * 0.55, 313) - 0.5,
		_value_noise2(p.x * cfg.patch_frequency * 0.55, p.y * cfg.patch_frequency * 0.55, 719) - 0.5
	) * 7.0
	var coarse := _value_noise2((p.x + warp.x) * cfg.patch_frequency, (p.y + warp.y) * cfg.patch_frequency, 17)
	var mid := _value_noise2(p.x * cfg.patch_frequency * 3.1 + 19.0, p.y * cfg.patch_frequency * 3.1 - 11.0, 41)
	var fine := _value_noise2(p.x * cfg.patch_frequency * 8.5 - 37.0, p.y * cfg.patch_frequency * 8.5 + 23.0, 83)
	var patch := smoothstep(cfg.patch_cutoff, 1.0, coarse)
	patch = pow(patch, cfg.patch_contrast)
	patch *= lerpf(1.0, lerpf(0.55, 1.35, mid), cfg.world_noise_mid_mix)
	patch *= lerpf(1.0, lerpf(0.82, 1.18, fine), cfg.world_noise_fine_mix)
	return clampf(patch, 0.0, 1.0)


func _world_micro_gap(world_pos: Vector2, key: int, attempt: int) -> float:
	var p := world_pos / maxf(_hex_size, 1.0)
	var continuous := _value_noise2(p.x * 0.82 + 23.0, p.y * 0.82 - 17.0, 131)
	var dither := _hash01(key, 9900 + attempt * 19)
	return clampf(continuous * 0.72 + dither * 0.28, 0.0, 1.0)


func _instance_transform(i: int) -> Transform2D:
	var rot := _instance_rotations[i]
	var size := _instance_sizes[i]
	var x_axis := Vector2(cos(rot), sin(rot)) * size
	var y_axis := Vector2(-sin(rot), cos(rot)) * size
	return Transform2D(x_axis, y_axis, _instance_positions[i])


func _build_shrub_mesh() -> ArrayMesh:
	match _detail_kind():
		DETAIL_TREE:
			return _build_tree_mesh()
		DETAIL_GRASS:
			return _build_grass_mesh()
		DETAIL_CONIFER:
			return _build_conifer_mesh()
		DETAIL_PALM:
			return _build_palm_mesh()
		DETAIL_CACTUS:
			return _build_cactus_mesh()
		DETAIL_REED:
			return _build_reed_mesh()
		DETAIL_ALPINE_FLOWER:
			return _build_alpine_flower_mesh()
		DETAIL_ROCK:
			return _build_rock_mesh()
		DETAIL_SNOW_MOUND:
			return _build_snow_mound_mesh()
		DETAIL_DEAD_SNAG:
			return _build_dead_snag_mesh()
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	var lobes := [
		[Vector2(-0.34, 0.02), 0.58, 0.72, Color(0.88, 0.95, 0.82, 1.0)],
		[Vector2(0.34, 0.00), 0.58, 0.70, Color(0.78, 0.88, 0.72, 1.0)],
		[Vector2(0.02, -0.28), 0.64, 0.78, Color(0.95, 1.0, 0.88, 1.0)],
		[Vector2(0.02, 0.30), 0.50, 0.55, Color(0.68, 0.78, 0.62, 1.0)],
		[Vector2(-0.18, -0.46), 0.38, 0.48, Color(0.80, 0.91, 0.70, 0.95)],
		[Vector2(0.22, 0.42), 0.34, 0.42, Color(0.58, 0.72, 0.52, 0.95)],
		[Vector2(-0.46, 0.30), 0.32, 0.38, Color(0.62, 0.78, 0.54, 0.95)],
		[Vector2(0.48, -0.34), 0.30, 0.36, Color(0.84, 0.94, 0.74, 0.95)],
	]
	var lobe_count := mini(_quality_lobe_count(), lobes.size())
	for i in range(lobe_count):
		var lobe: Array = lobes[i]
		_add_lobe(verts, uvs, colors, indices, lobe[0], lobe[1], lobe[2], lobe[3])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_tree_mesh() -> ArrayMesh:
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	_add_lobe(verts, uvs, colors, indices, Vector2(0.0, 0.18), 0.18, 0.34, Color(0.42, 0.27, 0.13, 1.0))
	var lobes := [
		[Vector2(0.0, -0.34), 0.58, 0.72, Color(0.56, 0.78, 0.42, 1.0)],
		[Vector2(-0.30, -0.10), 0.48, 0.58, Color(0.40, 0.66, 0.34, 0.98)],
		[Vector2(0.32, -0.12), 0.46, 0.56, Color(0.32, 0.57, 0.30, 0.98)],
		[Vector2(0.02, -0.66), 0.38, 0.48, Color(0.66, 0.84, 0.48, 0.96)],
		[Vector2(-0.02, 0.14), 0.34, 0.36, Color(0.24, 0.47, 0.24, 0.94)],
	]
	var lobe_count := mini(_quality_lobe_count(), lobes.size())
	for i in range(lobe_count):
		var lobe: Array = lobes[i]
		_add_lobe(verts, uvs, colors, indices, lobe[0], lobe[1], lobe[2], lobe[3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _build_grass_mesh() -> ArrayMesh:
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var blades := [
		[Vector2(-0.38, 0.24), 0.10, 0.72, Color(0.58, 0.80, 0.34, 0.82)],
		[Vector2(-0.18, 0.18), 0.09, 0.62, Color(0.38, 0.72, 0.28, 0.78)],
		[Vector2(0.00, 0.22), 0.11, 0.78, Color(0.66, 0.86, 0.38, 0.78)],
		[Vector2(0.20, 0.16), 0.08, 0.58, Color(0.34, 0.66, 0.25, 0.76)],
		[Vector2(0.38, 0.25), 0.10, 0.70, Color(0.52, 0.76, 0.32, 0.76)],
	]
	var blade_count := mini(_quality_lobe_count(), blades.size())
	for i in range(blade_count):
		var blade: Array = blades[i]
		_add_blade(verts, uvs, colors, indices, blade[0], blade[1], blade[2], blade[3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# ─── 阶段 B 新增 archetype 造型（程序化、风格化平面）───────────────────────
# 约定：归一化空间，y 负为上（与 _add_lobe 一致）；mesh 顶点色作"明暗分层"，
# 真正色相由每实例 instance color（_base_color_for_vegetation 派发）相乘决定。

func _finish_mesh(
		verts: PackedVector2Array,
		uvs: PackedVector2Array,
		colors: PackedColorArray,
		indices: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _add_tri(
		verts: PackedVector2Array, uvs: PackedVector2Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		a: Vector2, b: Vector2, c: Vector2, tint: Color) -> void:
	var base := verts.size()
	for p in [a, b, c]:
		verts.append(p)
		uvs.append(Vector2(p.x * 0.5 + 0.5, 1.0 - (p.y * 0.5 + 0.5)))
		colors.append(tint)
	indices.append(base); indices.append(base + 1); indices.append(base + 2)


func _add_poly(
		verts: PackedVector2Array, uvs: PackedVector2Array,
		colors: PackedColorArray, indices: PackedInt32Array,
		pts: Array, tint: Color) -> void:
	if pts.size() < 3:
		return
	var base := verts.size()
	var centroid := Vector2.ZERO
	for p in pts:
		centroid += p
	centroid /= float(pts.size())
	verts.append(centroid)
	uvs.append(Vector2(0.5, 0.5))
	colors.append(tint)
	for p in pts:
		verts.append(p)
		uvs.append(Vector2(p.x * 0.5 + 0.5, 1.0 - (p.y * 0.5 + 0.5)))
		colors.append(tint)
	var n := pts.size()
	for i in range(n):
		indices.append(base)
		indices.append(base + 1 + i)
		indices.append(base + 1 + ((i + 1) % n))


func _build_conifer_mesh() -> ArrayMesh:
	var v := PackedVector2Array(); var u := PackedVector2Array()
	var c := PackedColorArray(); var idx := PackedInt32Array()
	_add_lobe(v, u, c, idx, Vector2(0.0, 0.46), 0.075, 0.30, Color(0.52, 0.38, 0.24, 1.0))
	_add_tri(v, u, c, idx, Vector2(0.0, -0.08), Vector2(-0.46, 0.36), Vector2(0.46, 0.36), Color(0.80, 0.92, 0.80, 1.0))
	_add_tri(v, u, c, idx, Vector2(0.0, -0.44), Vector2(-0.36, 0.04), Vector2(0.36, 0.04), Color(0.90, 0.98, 0.88, 1.0))
	_add_tri(v, u, c, idx, Vector2(0.0, -0.82), Vector2(-0.24, -0.30), Vector2(0.24, -0.30), Color(1.0, 1.0, 0.94, 1.0))
	return _finish_mesh(v, u, c, idx)


func _build_palm_mesh() -> ArrayMesh:
	var v := PackedVector2Array(); var u := PackedVector2Array()
	var c := PackedColorArray(); var idx := PackedInt32Array()
	_add_lobe(v, u, c, idx, Vector2(0.05, 0.24), 0.065, 0.52, Color(0.56, 0.42, 0.26, 1.0))
	var top := Vector2(0.0, -0.30)
	var fronds := [
		[Vector2(-0.62, -0.36), Color(0.74, 0.90, 0.62, 0.98)],
		[Vector2(-0.40, -0.62), Color(0.84, 0.96, 0.70, 0.98)],
		[Vector2(0.04, -0.74), Color(0.92, 1.0, 0.78, 1.0)],
		[Vector2(0.46, -0.58), Color(0.80, 0.94, 0.66, 0.98)],
		[Vector2(0.64, -0.30), Color(0.70, 0.88, 0.58, 0.96)],
	]
	for f in fronds:
		var tip: Vector2 = f[0]
		var perp := Vector2(-(tip.y - top.y), tip.x - top.x).normalized() * 0.07
		_add_tri(v, u, c, idx, top + perp, top - perp, tip, f[1])
	return _finish_mesh(v, u, c, idx)


func _build_cactus_mesh() -> ArrayMesh:
	var v := PackedVector2Array(); var u := PackedVector2Array()
	var c := PackedColorArray(); var idx := PackedInt32Array()
	_add_lobe(v, u, c, idx, Vector2(0.0, 0.02), 0.18, 0.60, Color(0.78, 0.92, 0.72, 1.0))
	_add_lobe(v, u, c, idx, Vector2(-0.30, 0.12), 0.11, 0.22, Color(0.70, 0.88, 0.64, 1.0))
	_add_lobe(v, u, c, idx, Vector2(-0.30, -0.06), 0.095, 0.20, Color(0.74, 0.90, 0.66, 1.0))
	_add_lobe(v, u, c, idx, Vector2(0.30, 0.04), 0.10, 0.20, Color(0.70, 0.88, 0.64, 1.0))
	_add_lobe(v, u, c, idx, Vector2(0.30, -0.14), 0.085, 0.16, Color(0.74, 0.90, 0.66, 1.0))
	return _finish_mesh(v, u, c, idx)


func _build_reed_mesh() -> ArrayMesh:
	var v := PackedVector2Array(); var u := PackedVector2Array()
	var c := PackedColorArray(); var idx := PackedInt32Array()
	var blades := [
		[Vector2(-0.30, 0.34), 0.045, 0.92, Color(0.74, 0.86, 0.46, 0.92)],
		[Vector2(-0.12, 0.30), 0.05, 1.08, Color(0.86, 0.94, 0.54, 0.94)],
		[Vector2(0.06, 0.34), 0.045, 0.98, Color(0.80, 0.90, 0.50, 0.92)],
		[Vector2(0.24, 0.30), 0.05, 1.04, Color(0.88, 0.96, 0.56, 0.94)],
		[Vector2(0.38, 0.36), 0.04, 0.84, Color(0.72, 0.84, 0.44, 0.90)],
	]
	for b in blades:
		_add_blade(v, u, c, idx, b[0], b[1], b[2], b[3])
	return _finish_mesh(v, u, c, idx)


func _build_alpine_flower_mesh() -> ArrayMesh:
	var v := PackedVector2Array(); var u := PackedVector2Array()
	var c := PackedColorArray(); var idx := PackedInt32Array()
	_add_blade(v, u, c, idx, Vector2(-0.10, 0.36), 0.05, 0.42, Color(0.46, 0.70, 0.36, 0.9))
	_add_blade(v, u, c, idx, Vector2(0.12, 0.36), 0.05, 0.38, Color(0.40, 0.64, 0.32, 0.9))
	var petals := [
		[Vector2(0.0, -0.34), Color(1.0, 0.62, 0.78, 1.0)],
		[Vector2(-0.20, -0.12), Color(1.0, 0.80, 0.40, 1.0)],
		[Vector2(0.20, -0.12), Color(0.78, 0.72, 1.0, 1.0)],
		[Vector2(0.0, 0.04), Color(1.0, 0.94, 0.70, 1.0)],
	]
	for p in petals:
		_add_lobe(v, u, c, idx, p[0], 0.13, 0.16, p[1])
	_add_lobe(v, u, c, idx, Vector2(0.0, -0.12), 0.07, 0.08, Color(1.0, 0.90, 0.40, 1.0))
	return _finish_mesh(v, u, c, idx)


func _build_rock_mesh() -> ArrayMesh:
	var v := PackedVector2Array(); var u := PackedVector2Array()
	var c := PackedColorArray(); var idx := PackedInt32Array()
	_add_poly(v, u, c, idx, [
		Vector2(-0.52, 0.34), Vector2(-0.40, -0.10), Vector2(-0.10, -0.34),
		Vector2(0.28, -0.26), Vector2(0.52, 0.06), Vector2(0.44, 0.36),
	], Color(0.72, 0.73, 0.76, 1.0))
	_add_poly(v, u, c, idx, [
		Vector2(-0.20, -0.18), Vector2(0.10, -0.30), Vector2(0.30, -0.08), Vector2(0.04, 0.04),
	], Color(0.92, 0.93, 0.96, 1.0))
	return _finish_mesh(v, u, c, idx)


func _build_snow_mound_mesh() -> ArrayMesh:
	var v := PackedVector2Array(); var u := PackedVector2Array()
	var c := PackedColorArray(); var idx := PackedInt32Array()
	var pts: Array = []
	var seg := 9
	for i in range(seg + 1):
		var a := PI * (1.0 - float(i) / float(seg))
		pts.append(Vector2(cos(a) * 0.56, 0.22 - sin(a) * 0.40))
	pts.append(Vector2(0.56, 0.30))
	pts.append(Vector2(-0.56, 0.30))
	_add_poly(v, u, c, idx, pts, Color(0.97, 0.98, 1.0, 1.0))
	return _finish_mesh(v, u, c, idx)


func _build_dead_snag_mesh() -> ArrayMesh:
	var v := PackedVector2Array(); var u := PackedVector2Array()
	var c := PackedColorArray(); var idx := PackedInt32Array()
	_add_lobe(v, u, c, idx, Vector2(0.0, 0.20), 0.07, 0.56, Color(0.80, 0.74, 0.66, 1.0))
	_add_tri(v, u, c, idx, Vector2(0.0, -0.10), Vector2(-0.04, -0.06), Vector2(-0.40, -0.42), Color(0.86, 0.80, 0.72, 1.0))
	_add_tri(v, u, c, idx, Vector2(0.02, -0.24), Vector2(-0.02, -0.20), Vector2(0.34, -0.40), Color(0.84, 0.78, 0.70, 1.0))
	_add_tri(v, u, c, idx, Vector2(0.0, -0.36), Vector2(-0.03, -0.32), Vector2(-0.18, -0.66), Color(0.88, 0.82, 0.74, 1.0))
	return _finish_mesh(v, u, c, idx)


func _add_lobe(
		verts: PackedVector2Array,
		uvs: PackedVector2Array,
		colors: PackedColorArray,
		indices: PackedInt32Array,
		center: Vector2,
		rx: float,
		ry: float,
		tint: Color) -> void:
	var base := verts.size()
	var points := [
		center,
		center + Vector2(0.0, -ry),
		center + Vector2(rx, -ry * 0.18),
		center + Vector2(rx * 0.42, ry),
		center + Vector2(-rx * 0.42, ry),
		center + Vector2(-rx, -ry * 0.18),
	]
	for p in points:
		verts.append(p)
		uvs.append(Vector2(p.x * 0.5 + 0.5, 1.0 - (p.y * 0.5 + 0.5)))
		colors.append(tint)
	for tri in [[0, 1, 2], [0, 2, 3], [0, 3, 4], [0, 4, 5], [0, 5, 1]]:
		indices.append(base + int(tri[0]))
		indices.append(base + int(tri[1]))
		indices.append(base + int(tri[2]))


func _add_blade(
		verts: PackedVector2Array,
		uvs: PackedVector2Array,
		colors: PackedColorArray,
		indices: PackedInt32Array,
		base_pos: Vector2,
		width: float,
		height: float,
		tint: Color) -> void:
	var base := verts.size()
	var lean := width * 1.6
	var points := [
		base_pos + Vector2(-width, 0.0),
		base_pos + Vector2(width, 0.0),
		base_pos + Vector2(lean, -height * 0.55),
		base_pos + Vector2(0.0, -height),
	]
	for p in points:
		verts.append(p)
		uvs.append(Vector2(p.x * 0.5 + 0.5, 1.0 - (p.y * 0.5 + 0.5)))
		colors.append(tint)
	for tri in [[0, 1, 2], [0, 2, 3]]:
		indices.append(base + int(tri[0]))
		indices.append(base + int(tri[1]))
		indices.append(base + int(tri[2]))


func _sample_cell_state(idx: int, cell = null) -> Dictionary:
	return {
		"temp": _f32(_map.temp_arr, idx, cell.temperature if cell != null else 0.5),
		"moisture": _f32(_map.moisture_arr, idx, cell.moisture if cell != null else 0.5),
		"snow": _f32(_map.snow_cover_arr, idx, cell.snow_cover if cell != null else 0.0),
		"weather_intensity": _f32(_map.weather_intensity_arr, idx, cell.weather_intensity if cell != null else 0.0),
		"vitality": _f32(_map.vegetation_vitality_arr, idx, cell.vegetation_vitality if cell != null else 0.7),
		"heat": _f32(_map.vegetation_heat_stress_arr, idx, cell.vegetation_heat_stress if cell != null else 0.0),
		"drought": _f32(_map.vegetation_drought_stress_arr, idx, cell.vegetation_drought_stress if cell != null else 0.0),
		"cold": _f32(_map.vegetation_cold_stress_arr, idx, cell.vegetation_cold_stress if cell != null else 0.0),
		"landform": _u8(_map.landform_arr, idx, cell.landform if cell != null else LandformType.LF.PLAIN),
		"vegetation": _u8(_map.vegetation_arr, idx, cell.vegetation if cell != null else VegetationType.VEG.NONE),
		"cover": _u8(_map.cover_arr, idx, cell.cover if cell != null else CoverType.CV.NONE),
		"weather_type": _u8(_map.weather_type_arr, idx, cell.weather_type if cell != null else 0),
		# 阶段 C：放置侧全量参数（归一化 / 物理量），喂入 archetype 亲和 + 林线 + 地貌 suitability。
		"elevation": _f32(_map.elevation_arr, idx, cell.elevation if cell != null else 0.40),
		"soil_moisture": _f32(_map.soil_moisture_arr, idx, cell.soil_moisture if cell != null else 0.40),
		"river_discharge": _f32(_map.river_discharge_arr, idx, 0.0),
		"wind_speed": _f32(_map.wind_speed_arr, idx, cell.wind_speed if cell != null else 0.0),
		"snow_visual": 0.0,
	}


func _base_color_for_state(state: Dictionary, variant: float) -> Color:
	var veg := int(state.get("vegetation", VegetationType.VEG.NONE))
	var base := _base_color_for_vegetation(veg)
	var shade := (variant - 0.5) * 0.16
	if shade >= 0.0:
		base = base.lightened(shade)
	else:
		base = base.darkened(-shade)
	return base


func _base_color_for_vegetation(veg: int) -> Color:
	match _detail_kind():
		DETAIL_TREE:
			return _tree_base_color_for_vegetation(veg)
		DETAIL_GRASS:
			return _grass_base_color_for_vegetation(veg)
		DETAIL_CONIFER:
			return Color(0.10, 0.28, 0.18, 0.96)
		DETAIL_PALM:
			return Color(0.16, 0.40, 0.20, 0.96)
		DETAIL_CACTUS:
			return Color(0.30, 0.48, 0.32, 0.96)
		DETAIL_REED:
			return Color(0.42, 0.52, 0.24, 0.92)
		DETAIL_ALPINE_FLOWER:
			return Color(0.64, 0.68, 0.52, 0.98)
		DETAIL_ROCK:
			return Color(0.54, 0.54, 0.57, 1.0)
		DETAIL_SNOW_MOUND:
			return Color(0.95, 0.97, 1.0, 1.0)
		DETAIL_DEAD_SNAG:
			return Color(0.42, 0.36, 0.30, 0.98)
	match veg:
		VegetationType.VEG.BOREAL_SHRUB:
			return Color(0.16, 0.33, 0.20, 0.90)
		VegetationType.VEG.MEDITERRANEAN_SHRUB:
			return Color(0.34, 0.42, 0.22, 0.90)
		VegetationType.VEG.DESERT_SCRUB:
			return Color(0.42, 0.38, 0.22, 0.88)
		VegetationType.VEG.TUNDRA, VegetationType.VEG.ALPINE_TUNDRA:
			return Color(0.31, 0.38, 0.25, 0.86)
		VegetationType.VEG.SWAMP, VegetationType.VEG.MARSH:
			return Color(0.13, 0.32, 0.20, 0.88)
		VegetationType.VEG.SAVANNA, VegetationType.VEG.TEMPERATE_STEPPE:
			return Color(0.32, 0.43, 0.21, 0.88)
		_:
			return Color(0.18, 0.39, 0.19, 0.88)


func _tree_base_color_for_vegetation(veg: int) -> Color:
	match veg:
		VegetationType.VEG.TAIGA, VegetationType.VEG.TEMPERATE_CONIFER:
			return Color(0.10, 0.30, 0.17, 0.94)
		VegetationType.VEG.TEMPERATE_DECIDUOUS:
			return Color(0.16, 0.42, 0.20, 0.94)
		VegetationType.VEG.TROPICAL_RAINFOREST, VegetationType.VEG.SUBTROPICAL_FOREST:
			return Color(0.07, 0.34, 0.18, 0.96)
		VegetationType.VEG.TROPICAL_DRY_FOREST:
			return Color(0.24, 0.40, 0.18, 0.92)
		VegetationType.VEG.SWAMP, VegetationType.VEG.MANGROVE:
			return Color(0.08, 0.28, 0.18, 0.92)
		VegetationType.VEG.SAVANNA:
			return Color(0.28, 0.39, 0.18, 0.88)
		_:
			return Color(0.14, 0.36, 0.18, 0.90)


func _grass_base_color_for_vegetation(veg: int) -> Color:
	match veg:
		VegetationType.VEG.TEMPERATE_GRASSLAND, VegetationType.VEG.ALPINE_MEADOW:
			return Color(0.34, 0.58, 0.22, 0.72)
		VegetationType.VEG.TEMPERATE_STEPPE, VegetationType.VEG.SAVANNA:
			return Color(0.48, 0.54, 0.22, 0.70)
		VegetationType.VEG.MARSH, VegetationType.VEG.SWAMP:
			return Color(0.20, 0.48, 0.25, 0.74)
		VegetationType.VEG.TUNDRA, VegetationType.VEG.ALPINE_TUNDRA:
			return Color(0.38, 0.44, 0.26, 0.66)
		VegetationType.VEG.DESERT_SCRUB:
			return Color(0.46, 0.42, 0.22, 0.60)
		_:
			return Color(0.30, 0.52, 0.22, 0.68)


func _vegetation_weight(veg: int) -> float:
	match _detail_kind():
		DETAIL_TREE:
			return _tree_vegetation_weight(veg)
		DETAIL_GRASS:
			return _grass_vegetation_weight(veg)
	match veg:
		VegetationType.VEG.BOREAL_SHRUB, VegetationType.VEG.MEDITERRANEAN_SHRUB:
			return 1.15
		VegetationType.VEG.DESERT_SCRUB:
			return 0.78
		VegetationType.VEG.TAIGA, VegetationType.VEG.TROPICAL_DRY_FOREST:
			return 0.92
		VegetationType.VEG.TEMPERATE_DECIDUOUS, VegetationType.VEG.TEMPERATE_CONIFER:
			return 0.84
		VegetationType.VEG.TROPICAL_RAINFOREST, VegetationType.VEG.SUBTROPICAL_FOREST:
			return 0.70
		VegetationType.VEG.TUNDRA, VegetationType.VEG.ALPINE_TUNDRA:
			return 0.42
		VegetationType.VEG.SAVANNA:
			return 0.62
		VegetationType.VEG.TEMPERATE_STEPPE:
			return 0.46
		VegetationType.VEG.SWAMP:
			return 0.56
		VegetationType.VEG.MARSH:
			return 0.34
		VegetationType.VEG.TEMPERATE_GRASSLAND:
			return 0.36
		VegetationType.VEG.OASIS_VEG:
			return 0.58
		VegetationType.VEG.XERIC_DESERT, VegetationType.VEG.POLAR_DESERT:
			return 0.02
		VegetationType.VEG.NONE, VegetationType.VEG.KELP_FOREST, VegetationType.VEG.CORAL_REEF:
			return 0.0
		_:
			return 0.10


func _tree_vegetation_weight(veg: int) -> float:
	match veg:
		VegetationType.VEG.TROPICAL_RAINFOREST, VegetationType.VEG.SUBTROPICAL_FOREST:
			return 1.22
		VegetationType.VEG.TEMPERATE_DECIDUOUS, VegetationType.VEG.TEMPERATE_CONIFER:
			return 1.08
		VegetationType.VEG.TAIGA:
			return 0.98
		VegetationType.VEG.TROPICAL_DRY_FOREST:
			return 0.82
		VegetationType.VEG.SWAMP, VegetationType.VEG.MANGROVE:
			return 0.64
		VegetationType.VEG.SAVANNA:
			return 0.28
		VegetationType.VEG.BOREAL_SHRUB, VegetationType.VEG.MEDITERRANEAN_SHRUB:
			return 0.12
		VegetationType.VEG.TEMPERATE_GRASSLAND, VegetationType.VEG.TEMPERATE_STEPPE:
			return 0.05
		VegetationType.VEG.DESERT_SCRUB, VegetationType.VEG.XERIC_DESERT:
			return 0.0
		VegetationType.VEG.NONE, VegetationType.VEG.KELP_FOREST, VegetationType.VEG.CORAL_REEF:
			return 0.0
		_:
			return 0.04


func _grass_vegetation_weight(veg: int) -> float:
	match veg:
		VegetationType.VEG.TEMPERATE_GRASSLAND, VegetationType.VEG.ALPINE_MEADOW:
			return 1.22
		VegetationType.VEG.TEMPERATE_STEPPE:
			return 0.98
		VegetationType.VEG.SAVANNA:
			return 0.84
		VegetationType.VEG.MARSH:
			return 0.78
		VegetationType.VEG.TUNDRA, VegetationType.VEG.ALPINE_TUNDRA:
			return 0.62
		VegetationType.VEG.DESERT_SCRUB:
			return 0.32
		VegetationType.VEG.BOREAL_SHRUB, VegetationType.VEG.MEDITERRANEAN_SHRUB:
			return 0.44
		VegetationType.VEG.TROPICAL_RAINFOREST, VegetationType.VEG.SUBTROPICAL_FOREST:
			return 0.24
		VegetationType.VEG.TAIGA, VegetationType.VEG.TEMPERATE_DECIDUOUS, VegetationType.VEG.TEMPERATE_CONIFER:
			return 0.30
		VegetationType.VEG.XERIC_DESERT, VegetationType.VEG.POLAR_DESERT:
			return 0.02
		VegetationType.VEG.NONE, VegetationType.VEG.KELP_FOREST, VegetationType.VEG.CORAL_REEF:
			return 0.0
		_:
			return 0.18


func _landform_weight(lf: int) -> float:
	match _detail_kind():
		DETAIL_TREE:
			return _tree_landform_weight(lf)
		DETAIL_GRASS:
			return _grass_landform_weight(lf)
	match lf:
		LandformType.LF.PLAIN, LandformType.LF.LOWLAND:
			return 1.0
		LandformType.LF.HILL:
			return 0.84
		LandformType.LF.DELTA:
			return 0.64
		LandformType.LF.BADLANDS:
			return 0.42
		LandformType.LF.SALT_FLAT:
			return 0.06
		LandformType.LF.MOUNTAIN:
			return 0.14
		LandformType.LF.PEAK, LandformType.LF.VOLCANO:
			return 0.0
		_:
			return 0.0 if LandformType.is_water(lf) else 0.55


func _tree_landform_weight(lf: int) -> float:
	match lf:
		LandformType.LF.PLAIN, LandformType.LF.LOWLAND:
			return 1.0
		LandformType.LF.HILL:
			return 0.74
		LandformType.LF.DELTA:
			return 0.46
		LandformType.LF.MOUNTAIN:
			return 0.16
		LandformType.LF.BADLANDS, LandformType.LF.SALT_FLAT:
			return 0.0
		LandformType.LF.PEAK, LandformType.LF.VOLCANO:
			return 0.0
		_:
			return 0.0 if LandformType.is_water(lf) else 0.38


func _grass_landform_weight(lf: int) -> float:
	match lf:
		LandformType.LF.PLAIN, LandformType.LF.LOWLAND:
			return 1.0
		LandformType.LF.HILL:
			return 0.82
		LandformType.LF.DELTA:
			return 0.72
		LandformType.LF.BADLANDS:
			return 0.26
		LandformType.LF.SALT_FLAT:
			return 0.04
		LandformType.LF.MOUNTAIN:
			return 0.32
		LandformType.LF.PEAK, LandformType.LF.VOLCANO:
			return 0.0
		_:
			return 0.0 if LandformType.is_water(lf) else 0.58


func _cover_weight(cover: int) -> float:
	match cover:
		CoverType.CV.GLACIER, CoverType.CV.SEA_ICE, CoverType.CV.PELAGIC_BLOOM:
			return 0.0
		CoverType.CV.FLOODING:
			return 0.18
		CoverType.CV.SNOW:
			return 0.48
		CoverType.CV.PERMAFROST:
			return 0.62
		_:
			return 1.0


func _sample_density_for_size(idx: int, cell = null) -> float:
	var state := _sample_cell_state(idx, cell)
	var veg := int(state.get("vegetation", VegetationType.VEG.NONE))
	var lf := int(state.get("landform", LandformType.LF.PLAIN))
	var cover := int(state.get("cover", CoverType.CV.NONE))
	return _vegetation_weight(veg) * _landform_weight(lf) * _cover_weight(cover)


func _cell_ecology_density_bias(state: Dictionary) -> float:
	var cfg := _profile()
	var moisture := float(state.get("moisture", 0.5))
	var vitality := float(state.get("vitality", 0.7))
	var wet_corridor: float = smoothstep(0.46, 0.82, moisture) * cfg.moisture_corridor_boost
	var vitality_boost: float = _vitality_normalized(vitality) * cfg.vitality_patch_boost
	return clampf(0.68 + wet_corridor * 0.26 + vitality_boost * 0.30, 0.28, 1.35)


func _climate_presence(state: Dictionary) -> float:
	var cfg := _profile()
	var moisture := float(state.get("moisture", 0.5))
	var snow := float(state.get("snow", 0.0))
	var vitality := float(state.get("vitality", 0.7))
	var heat := float(state.get("heat", 0.0))
	var drought := float(state.get("drought", 0.0))
	var cold := float(state.get("cold", 0.0))
	var wt := int(state.get("weather_type", 0))
	var wi := float(state.get("weather_intensity", 0.0))
	if wt == _WT_DROUGHT or wt == _WT_HEATWAVE:
		drought = maxf(drought, wi * 0.65)
		heat = maxf(heat, wi * 0.52)
	elif wt == _WT_BLIZZARD:
		snow = maxf(snow, wi * 0.85)
		cold = maxf(cold, wi * 0.62)
	elif wt == _WT_RAIN or wt == _WT_STORM or wt == _WT_MONSOON:
		moisture = clampf(moisture + wi * 0.20, 0.0, 1.0)

	var dry := clampf(maxf(drought, maxf(heat * 0.78, (0.34 - moisture) * 1.9)), 0.0, 1.0)
	var snow_hide := clampf(maxf(snow, cold * 0.55), 0.0, 1.0)
	var presence := pow(_vitality_normalized(vitality), cfg.vitality_alpha_power)
	presence *= 1.0 - dry * cfg.stress_hide_strength
	presence *= 1.0 - snow_hide * cfg.snow_hide_strength
	return clampf(presence, 0.0, 1.0)


func _vitality_normalized(vitality: float) -> float:
	var cfg := _profile()
	var dead: float = minf(cfg.vitality_dead_threshold, cfg.vitality_healthy_threshold - 0.001)
	var healthy: float = maxf(cfg.vitality_healthy_threshold, dead + 0.001)
	return clampf((clampf(vitality, 0.0, 1.0) - dead) / (healthy - dead), 0.0, 1.0)


func _vitality_density_factor(state: Dictionary) -> float:
	var cfg := _profile()
	var vitality := clampf(float(state.get("vitality", 0.7)), 0.0, 1.0)
	if vitality <= cfg.vitality_dead_threshold:
		return 0.0
	var normalized := _vitality_normalized(vitality)
	var sparse_factor := lerpf(0.10, 0.62, smoothstep(
		cfg.vitality_dead_threshold,
		maxf(cfg.vitality_sparse_threshold, cfg.vitality_dead_threshold + 0.001),
		vitality
	))
	var healthy_factor := lerpf(0.62, 1.20, pow(normalized, cfg.vitality_density_power))
	return minf(sparse_factor, healthy_factor) if vitality < cfg.vitality_sparse_threshold else healthy_factor


func _vitality_size_scale(state: Dictionary) -> float:
	var cfg := _profile()
	var vitality := clampf(float(state.get("vitality", 0.7)), 0.0, 1.0)
	var normalized := _vitality_normalized(vitality)
	return lerpf(cfg.vitality_size_min, cfg.vitality_size_max, pow(normalized, 0.85))


func _is_water_cell(cell, idx: int) -> bool:
	if idx >= 0 and idx < _map.is_water_arr.size() and _map.is_water_arr[idx] > 0:
		return true
	var lf := _u8(_map.landform_arr, idx, cell.landform if cell != null else LandformType.LF.OCEAN)
	if LandformType.is_water(lf):
		return true
	if cell != null and LandformType.is_water(cell.landform):
		return true
	return false


func _has_river_cell(cell, idx: int) -> bool:
	if idx >= 0 and idx < _map.has_river_arr.size():
		return _map.has_river_arr[idx] > 0
	return bool(cell.has_river) if cell != null else false


func _is_water_position(world_pos: Vector2, _fallback_cell, fallback_idx: int) -> bool:
	if _map == null:
		return false
	var cube := HexUtils.world_to_cube(world_pos, _hex_size)
	var cell = _map.get_cell_by_cube(cube)
	if cell == null:
		return true
	var idx := _cell_index(cell, fallback_idx)
	return _is_water_cell(cell, idx)


func _is_river_body_position(world_pos: Vector2) -> bool:
	if _world == null or _world.flow_buffer.is_empty():
		return false
	return _world.sample_flow(world_pos) >= _profile().river_clear_threshold


func _cell_center(cell, idx: int) -> Vector2:
	if idx >= 0 and idx < _map.cell_pos_x_arr.size() and idx < _map.cell_pos_y_arr.size():
		return Vector2(_map.cell_pos_x_arr[idx], _map.cell_pos_y_arr[idx]) * _hex_size
	return HexUtils.cube_to_world(int(cell.q), int(cell.r), _hex_size)


func _cell_index(cell, fallback: int) -> int:
	var idx := int(cell.index)
	return idx if idx >= 0 else -1


func _cell_hash_key(cell, fallback: int) -> int:
	if cell != null:
		var idx := int(cell.index)
		if idx >= 0:
			return idx
		return int(cell.q) * 4099 + int(cell.r) * 9176 + fallback
	return fallback


func _max_per_cell() -> int:
	var cfg := _profile()
	if OS.has_feature("mobile"):
		match _active_quality_tier():
			0:
				return maxi(0, cfg.mobile_max_per_cell_quality0)
			1:
				return maxi(0, cfg.mobile_max_per_cell_quality1)
			_:
				return maxi(0, cfg.mobile_max_per_cell_quality2)
	match _active_quality_tier():
		0:
			return maxi(0, cfg.desktop_max_per_cell_quality0)
		1:
			return maxi(0, cfg.desktop_max_per_cell_quality1)
		_:
			return maxi(0, cfg.desktop_max_per_cell_quality2)


func _instance_cap() -> int:
	var cfg := _profile()
	if OS.has_feature("mobile"):
		match _active_quality_tier():
			0:
				return maxi(0, cfg.mobile_max_instances_quality0)
			1:
				return maxi(0, cfg.mobile_max_instances_quality1)
			_:
				return maxi(0, cfg.mobile_max_instances_quality2)
	match _active_quality_tier():
		0:
			return maxi(0, cfg.desktop_max_instances_quality0)
		1:
			return maxi(0, cfg.desktop_max_instances_quality1)
		_:
			return maxi(0, cfg.desktop_max_instances_quality2)


func _quality_lobe_count() -> int:
	var cfg := _profile()
	if OS.has_feature("mobile"):
		match _active_quality_tier():
			0:
				return clampi(cfg.mobile_lobes_quality0, 2, 8)
			1:
				return clampi(cfg.mobile_lobes_quality1, 2, 8)
			_:
				return clampi(cfg.mobile_lobes_quality2, 2, 8)
	match _active_quality_tier():
		0:
			return clampi(cfg.desktop_lobes_quality0, 2, 8)
		1:
			return clampi(cfg.desktop_lobes_quality1, 2, 8)
		_:
			return clampi(cfg.desktop_lobes_quality2, 2, 8)


func _quality_density_scale() -> float:
	var cfg := _profile()
	if OS.has_feature("mobile"):
		match _active_quality_tier():
			0:
				return maxf(0.0, cfg.density_scale * cfg.mobile_density_multiplier_quality0)
			1:
				return maxf(0.0, cfg.density_scale * cfg.mobile_density_multiplier_quality1)
			_:
				return maxf(0.0, cfg.density_scale * cfg.mobile_density_multiplier_quality2)
	match _active_quality_tier():
		0:
			return maxf(0.0, cfg.density_scale * cfg.desktop_density_multiplier_quality0)
		1:
			return maxf(0.0, cfg.density_scale * cfg.desktop_density_multiplier_quality1)
		_:
			return maxf(0.0, cfg.density_scale * cfg.desktop_density_multiplier_quality2)


func _quality_size_scale() -> float:
	var cfg := _profile()
	if OS.has_feature("mobile"):
		match _active_quality_tier():
			0:
				return maxf(0.0, cfg.mobile_size_scale_quality0)
			1:
				return maxf(0.0, cfg.mobile_size_scale_quality1)
			_:
				return maxf(0.0, cfg.mobile_size_scale_quality2)
	match _active_quality_tier():
		0:
			return maxf(0.0, cfg.desktop_size_scale_quality0)
		1:
			return maxf(0.0, cfg.desktop_size_scale_quality1)
		_:
			return maxf(0.0, cfg.desktop_size_scale_quality2)


func _active_quality_tier() -> int:
	return clampi(_mobile_quality_tier if OS.has_feature("mobile") else _visual_quality, 0, 2)


func _detail_kind() -> int:
	var cfg := _profile()
	return clampi(int(cfg.detail_kind), DETAIL_SHRUB, DETAIL_DEAD_SNAG)


func _profile() -> Resource:
	return profile if profile != null else DEFAULT_PROFILE


func _world_uv(world_pos: Vector2) -> Vector2:
	var size := _bounds.size
	if size.x <= 0.001 or size.y <= 0.001:
		return Vector2.ZERO
	return Vector2(
		clampf((world_pos.x - _bounds.position.x) / size.x, 0.0, 1.0),
		clampf((world_pos.y - _bounds.position.y) / size.y, 0.0, 1.0)
	)


func _f32(arr: PackedFloat32Array, idx: int, fallback: float) -> float:
	if idx >= 0 and idx < arr.size():
		return float(arr[idx])
	return fallback


func _u8(arr: PackedByteArray, idx: int, fallback: int) -> int:
	if idx >= 0 and idx < arr.size():
		return int(arr[idx])
	return fallback


func _hash01(idx: int, salt: int) -> float:
	var x := sin(float(idx * 127 + salt * 311) * 12.9898) * 43758.5453123
	return x - floor(x)


func _value_noise2(x: float, y: float, salt: int) -> float:
	var ix := floori(x)
	var iy := floori(y)
	var fx := x - float(ix)
	var fy := y - float(iy)
	var sx := fx * fx * (3.0 - 2.0 * fx)
	var sy := fy * fy * (3.0 - 2.0 * fy)
	var a := _hash2i(ix, iy, salt)
	var b := _hash2i(ix + 1, iy, salt)
	var c := _hash2i(ix, iy + 1, salt)
	var d := _hash2i(ix + 1, iy + 1, salt)
	return lerpf(lerpf(a, b, sx), lerpf(c, d, sx), sy)


func _hash2i(x: int, y: int, salt: int) -> float:
	var n := x * 374761393 + y * 668265263 + salt * 1442695041
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x00ffffff) / float(0x01000000)
