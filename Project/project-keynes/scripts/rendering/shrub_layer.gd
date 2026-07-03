class_name ShrubLayer
extends Node2D

const _WT_RAIN := 1
const _WT_STORM := 2
const _WT_BLIZZARD := 3
const _WT_DROUGHT := 4
const _WT_HEATWAVE := 6
const _WT_MONSOON := 7
const DEFAULT_PROFILE := preload("res://data/visual/shrub_default.tres")
const VegetationProfileRegistryScript := preload("res://scripts/data/vegetation_profile_registry.gd")
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
const ROT_RANDOM_FULL := 0
const ROT_UPRIGHT := 1
const ROT_UPRIGHT_JITTER := 2
const SPAWN_LAND := 0
const SPAWN_WATER := 1
const SPAWN_ANY := 2

static var _mesh_cache: Dictionary = {}
static var _shared_offset_is_water_cache: Dictionary = {}

const _SHADER_CODE := """
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D map_index_atlas : filter_nearest, repeat_disable;
uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D eco_lut : filter_nearest, repeat_disable;

uniform vec2 lut_dims = vec2(1.0, 1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;

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
uniform float aquatic_response = 0.0;
// 0 = 点缀/地貌类 archetype（岩石/雪堆/枯立木），抑制植被气候改色；1 = 植被类。
uniform float veg_response = 1.0;
// 阶段 D 精致化。
uniform vec2 wind_dir = vec2(1.0, 0.18);     // 全局盛行风方向（归一化前可任意）
uniform float weather_wind_boost = 0.0;      // 实时天气（风暴/季风）附加风强
uniform float bloom_strength = 0.0;          // 季节开花强度（花/部分植被 >0）
uniform float snow_burial = 0.55;            // 积雪埋没：下沉+缩矮强度
uniform float toon_shading = 0.30;           // 卡通分层：基部 AO + 轻量色阶量化
// [cylindrical-earth-daylight] 昼夜光照：与地形 brdf.make_lighting_context 完全同源。
// 不用"全图统一昼夜系数"，而是按本实例所在经纬度算太阳高度角 → 逐像素昼夜/晨昏，
// 让晨昏线扫过时植被随之明暗（地球式光照），而非全图同步开关常亮。
uniform float axial_tilt_rad = 0.41;     // 地轴倾角(rad)，与地形 axial_tilt_rad 同源
uniform bool day_night_enabled = true;   // 关闭时退化为永昼
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);
uniform float tod_exposure = 1.0;        // 全局曝光（TODProfile.exposure）

// [veg-normal-shading] 法线辅助着色：复用地形烘焙宏观法线 + 高度图（与地形 brdf 同源数据），
// 配合 billboard UV 伪法线做 NdotL 方向光 / 边缘光 / 接触 AO / 谷地 AO。
// terrain_normal_tex / height_tex 与地形主 shader 同一套 [0,1] 世界 UV（solar_uv=本实例 cell uv）。
uniform sampler2D terrain_normal_tex : filter_linear, repeat_disable;
uniform bool terrain_normal_tex_bound = false;  // 未烘焙时只用伪法线（退化）
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform vec2 hm_resolution = vec2(2048.0, 1536.0);
uniform int veg_shade_quality = 2;            // 0/1/2：q2 才采高度图邻域算谷地 AO
// [terrain-horizon 2026-07-03] 与地形同源的 8 方向 horizon shadow。同级性能档位：veg_shade_quality>=1 才采样。
uniform sampler2D terrain_horizon_tex : filter_nearest, repeat_disable;
uniform bool terrain_horizon_tex_bound = false;
uniform float terrain_horizon_max_angle = 1.309;
uniform float terrain_horizon_softness = 0.16;
uniform float terrain_horizon_strength = 0.70;
uniform float terrain_horizon_cast_floor = 0.82;
uniform int terrain_horizon_debug_view = 0;
uniform float shading_enabled = 1.0;          // 0=退化回旧"平直昼夜"着色
uniform float terrain_normal_influence = 0.65;
uniform float pseudo_normal_strength = 0.85;
uniform float sun_shade_strength = 0.55;
uniform float ambient_floor = 0.18;
uniform float rim_light_strength = 0.12;
uniform float contact_ao_strength = 0.42;
uniform float contact_ao_height = 0.32;
uniform float terrain_valley_ao_strength = 0.40;
uniform float terrain_valley_ao_gain = 6.0;

// [cylindrical-earth-daylight] 昼夜（晨昏线）核心与地形/水面同源：统一调用此 include。
// 必须放在 season_phase / day_phase / axial_tilt_rad 三个 uniform 声明之后——其内函数
// 引用这些全局量，GLSL 要求先声明后引用（名字须与 uniforms.gdshaderinc 一致）。
#include \"res://shaders/include/earth_daylight.gdshaderinc\"

varying vec4 shrub_custom;
varying vec4 shrub_dyn;
varying vec4 shrub_eco;
varying float shrub_presence_v;
varying float shrub_dry_v;
varying float shrub_wet_v;
varying float shrub_snow_v;
varying float shrub_vitality_v;
// [veg-normal-shading] 地形宏观法线 xy（已含 influence 缩放）与谷地 AO 因子，逐顶点采样一次，
// 整株近似常量（避免逐片元纹理 fetch）。伪法线由片元 UV 现算，叠加后求 NdotL。
varying vec2 shrub_terrain_n;
varying float shrub_terrain_ao;
// [veg-instance-rotation 修正] 每实例世界正交基（MODEL_MATRIX 列向量去缩放）。植被放置带随机自旋转，
// 伪法线必须按本实例旋转从局部 UV 帧转到世界帧，否则每株光影方向各异（不在同一光照方向上）。
varying vec2 shrub_basis_x;
varying vec2 shrub_basis_y;

// height_tex：RG8 16-bit 归一化海拔，解码 (R*256+G)/257（与 height.gdshaderinc 同式）。
float shrub_decode_height(vec2 uv) {
	vec2 rg = texture(height_tex, uv).rg;
	return (rg.r * 256.0 + rg.g) / 257.0;
}

vec2 shrub_wrap_map_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = wrap_origin_x + mod(world_x - wrap_origin_x, wrap_period_x);
	float ux = (wrapped_x - world_origin.x) / max(world_size.x, 1e-5);
	return vec2(ux, clamp(uv.y, 0.0, 1.0));
}

float shrub_horizon_unpack_byte(vec4 packed, int channel_index) {
	if (channel_index == 0) return floor(packed.r * 255.0 + 0.5);
	if (channel_index == 1) return floor(packed.g * 255.0 + 0.5);
	if (channel_index == 2) return floor(packed.b * 255.0 + 0.5);
	return floor(packed.a * 255.0 + 0.5);
}

float shrub_horizon_unpack_nibble(vec4 packed, int dir_index) {
	int ch = dir_index / 2;
	float byte_v = shrub_horizon_unpack_byte(packed, ch);
	float hi = floor(byte_v / 16.0);
	float lo = byte_v - hi * 16.0;
	return ((dir_index % 2) == 0) ? hi : lo;
}

float shrub_horizon_angle_by_index(vec4 packed, int dir_index) {
	int idx = dir_index;
	if (idx < 0) idx += 8;
	if (idx >= 8) idx -= 8;
	return (shrub_horizon_unpack_nibble(packed, idx) / 15.0) * terrain_horizon_max_angle;
}

float shrub_horizon_angle_from_packed(vec4 packed, float sector) {
	int i0 = int(floor(sector));
	float t = fract(sector);
	return mix(shrub_horizon_angle_by_index(packed, i0), shrub_horizon_angle_by_index(packed, i0 + 1), t);
}

float shrub_sample_horizon_angle(vec2 uv, vec2 sun_xy) {
	float angle = atan(sun_xy.y, sun_xy.x);
	if (angle < 0.0) angle += 6.2831853;
	float sector = angle / 0.78539816;
	vec2 dims = vec2(textureSize(terrain_horizon_tex, 0));
	vec2 p = shrub_wrap_map_uv(uv) * dims - vec2(0.5);
	vec2 b = floor(p);
	vec2 f = fract(p);
	vec2 inv_dims = 1.0 / max(dims, vec2(1.0));
	vec2 uv00 = shrub_wrap_map_uv((b + vec2(0.5, 0.5)) * inv_dims);
	vec2 uv10 = shrub_wrap_map_uv((b + vec2(1.5, 0.5)) * inv_dims);
	vec2 uv01 = shrub_wrap_map_uv((b + vec2(0.5, 1.5)) * inv_dims);
	vec2 uv11 = shrub_wrap_map_uv((b + vec2(1.5, 1.5)) * inv_dims);
	float h00 = shrub_horizon_angle_from_packed(texture(terrain_horizon_tex, uv00), sector);
	float h10 = shrub_horizon_angle_from_packed(texture(terrain_horizon_tex, uv10), sector);
	float h01 = shrub_horizon_angle_from_packed(texture(terrain_horizon_tex, uv01), sector);
	float h11 = shrub_horizon_angle_from_packed(texture(terrain_horizon_tex, uv11), sector);
	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

float shrub_horizon_direct_visibility(vec2 uv, vec3 light_dir) {
	if (!terrain_horizon_tex_bound || veg_shade_quality < 1 || terrain_horizon_strength <= 0.0) {
		return 1.0;
	}
	vec2 sun_xy = light_dir.xy;
	float sun_h_len = length(sun_xy);
	if (sun_h_len <= 1e-4) return 1.0;
	sun_xy /= sun_h_len;
	float horizon_angle = shrub_sample_horizon_angle(uv, sun_xy);
	float sun_elev = atan(max(light_dir.z, 0.0) / max(sun_h_len, 1e-4));
	float shadow = smoothstep(sun_elev - terrain_horizon_softness,
		sun_elev + terrain_horizon_softness, horizon_angle);
	float horizon_day_w = smoothstep(-0.14, 0.18, light_dir.z);
	return clamp(1.0 - shadow * terrain_horizon_strength * horizon_day_w, 0.0, 1.0);
}

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
	vitality = mix(vitality, 0.86, aquatic_response);
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
	// [veg-instance-rotation 修正] 取本实例世界正交基：MODEL_MATRIX 列向量 = 该实例 transform 后的
	// 局部 x/y 轴（含随机旋转+缩放），去缩放归一化 → 纯旋转基。供伪法线/风摆/投影把局部帧量转到世界帧。
	vec2 inst_ax = vec2(MODEL_MATRIX[0].x, MODEL_MATRIX[0].y);
	vec2 inst_ay = vec2(MODEL_MATRIX[1].x, MODEL_MATRIX[1].y);
	float inst_axl = length(inst_ax);
	float inst_ayl = length(inst_ay);
	shrub_basis_x = (inst_axl > 1e-5) ? inst_ax / inst_axl : vec2(1.0, 0.0);
	shrub_basis_y = (inst_ayl > 1e-5) ? inst_ay / inst_ayl : vec2(0.0, 1.0);
	vec2 shrub_uv = clamp(INSTANCE_CUSTOM.rg, vec2(0.0), vec2(1.0));
	shrub_dyn = sample_dyn_state(shrub_uv);
	shrub_eco = sample_eco_state(shrub_uv);
	float dyn_valid = step(0.02, shrub_dyn.r);
	float temp = mix(0.5, shrub_dyn.r, dyn_valid);
	float moisture = mix(0.5, shrub_dyn.g, dyn_valid);
	shrub_vitality_v = mix(0.70, shrub_dyn.a, dyn_valid);
	shrub_vitality_v = mix(shrub_vitality_v, 0.86, aquatic_response);
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
	// 方向风：沿全局盛行风方向摆动（而非固定 +x）。把世界风向转到本实例局部帧，
	// 否则随机自旋转的植株会朝各自局部 +x 乱摆，而非统一盛行风方向。
	vec2 wdir = normalize(wind_dir + vec2(0.0001, 0.0));
	vec2 wdir_local = vec2(dot(wdir, shrub_basis_x), dot(wdir, shrub_basis_y));
	VERTEX += wdir_local * amp;
	// 雪埋：积雪越深，植株下沉（y 正为下）并缩矮，顶部更明显。
	float bury = clamp(shrub_snow_v * snow_burial, 0.0, 0.85);
	VERTEX.y += bury * 0.34 * top_weight;
	VERTEX *= 1.0 - bury * 0.42 * top_weight;

	// [veg-normal-shading] 地形宏观法线（整株站立坡面）：与地形 brdf 同源烘焙法线，1 次采样。
	shrub_terrain_n = vec2(0.0);
	if (terrain_normal_tex_bound) {
		shrub_terrain_n = (texture(terrain_normal_tex, shrub_uv).rg * 2.0 - 1.0) * terrain_normal_influence;
	}
	// 谷地 AO：仅高画质档用 height_tex 邻域差判断凹陷（中心低于四邻 → 谷/坑 → 压暗）。
	shrub_terrain_ao = 0.0;
	if (veg_shade_quality >= 2 && terrain_valley_ao_strength > 0.0) {
		vec2 texel = 1.0 / hm_resolution;
		float r = 3.0;
		float hc = shrub_decode_height(shrub_uv);
		float hn = (shrub_decode_height(shrub_uv + vec2(texel.x * r, 0.0))
			+ shrub_decode_height(shrub_uv - vec2(texel.x * r, 0.0))
			+ shrub_decode_height(shrub_uv + vec2(0.0, texel.y * r))
			+ shrub_decode_height(shrub_uv - vec2(0.0, texel.y * r))) * 0.25;
		shrub_terrain_ao = clamp((hn - hc) * terrain_valley_ao_gain, 0.0, 1.0);
	}
}

// [veg-hemisphere-season] 半球季节相位 → (autumn, winter, spring) 三个季节量。fragment 会对
// 本实例所在半球各算一次后软混合，修复"全图同步变红"（北半球秋红时南半球应为春绿）。
vec3 shrub_season_amounts(float sp) {
	float autumn = smoothstep(1.45, 2.08, sp) * (1.0 - smoothstep(2.55, 3.05, sp));
	float winter = smoothstep(2.65, 3.15, sp) * (1.0 - smoothstep(3.65, 3.98, sp));
	float spring = clamp(1.0 - abs(sp - 0.4) / 0.9, 0.0, 1.0);
	return vec3(autumn, winter, spring);
}

void fragment() {
	// [veg-hemisphere-season] 季节相位按本实例纬度做半球翻转，修复全图植被同步变红：北/南各算
	// 一组季节量(相差半年)再用纬度 smoothstep 软混合(+seed 抖动破碎赤道带)。相位映射与地形
	// land_pipeline N7 同源(north=mod(p+3,4)/south=mod(p+1,4))，保证同格植被与地形季节同向。
	float season_lat = clamp(shrub_custom.g, 0.0, 1.0) * 2.0 - 1.0;
	float north_phase = mod(season_phase + 3.0, 4.0);
	float south_phase = mod(season_phase + 1.0, 4.0);
	float north_w = clamp(smoothstep(-0.30, 0.30, season_lat)
		+ (fract(shrub_custom.b * 41.3) - 0.5) * 0.45, 0.0, 1.0);
	vec3 season_amt = mix(shrub_season_amounts(south_phase),
		shrub_season_amounts(north_phase), north_w);
	float autumn = season_amt.x;
	float winter = season_amt.y;
	float spring = season_amt.z;
	float snow = clamp(shrub_snow_v, 0.0, 1.0);
	float dyn_valid = step(0.02, shrub_dyn.r);
	float temp = mix(0.5, shrub_dyn.r, dyn_valid);
	float moisture = mix(0.5, shrub_dyn.g, dyn_valid);
	float vitality_n = vitality_norm(shrub_vitality_v);
	float dry_hot = smoothstep(0.78, 0.98, temp) * (1.0 - smoothstep(0.18, 0.44, moisture));
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
	// 季节开花：春季给开花类一抹亮色（活力越高越盛，积雪覆盖时收敛）。spring 已按半球软混合算好。
	float bloom = bloom_strength * spring * vitality_n * (1.0 - snow_amount * 0.85);
	rgb = mix(rgb, rgb * vec3(1.12, 1.0, 1.08) + vec3(0.10, 0.03, 0.08), bloom);
	rgb = mix(rgb, vec3(0.69, 0.72, 0.63), winter * 0.16);
	rgb = mix(rgb, vec3(0.96, 0.98, 1.0), snow_amount);
	// 卡通分层：基部 AO（UV.y 低=近根，压暗）+ 轻量 3 阶色调量化（在 albedo 空间做）。
	float ao = 1.0 - (1.0 - clamp(UV.y, 0.0, 1.0)) * toon_shading * 0.38;
	rgb *= ao;
	float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
	float ql = floor(luma * 3.0 + 0.5) / 3.0;
	rgb *= (luma > 0.0015) ? mix(1.0, ql / luma, toon_shading * 0.55) : 1.0;
	// [veg-normal-shading] 昼夜 + 法线辅助着色（最后一步）：与地形/水面统一调用 earth_daylight，
	// 按本实例经纬度取昼夜/晨昏 + 同色板；再用「地形宏观法线 + billboard 伪法线」做 NdotL 方向光、
	// 边缘光、接触 AO、谷地 AO，模拟真实场景光照（迎光面亮、背光面暗，随晨昏线/太阳方位变化）。
	vec2 solar_uv = clamp(shrub_custom.rg, vec2(0.0), vec2(1.0));
	float lat_signed = solar_uv.y * 2.0 - 1.0;
	EarthDaylight ed = eval_earth_daylight(solar_uv, lat_signed, day_night_enabled);
	float horizon_vis = shrub_horizon_direct_visibility(solar_uv, ed.sun_dir);
	bool horizon_debug_mode = terrain_horizon_debug_view == 1 || terrain_horizon_debug_view == 2;
	vec3 horizon_debug_rgb = (terrain_horizon_debug_view == 1)
		? vec3(clamp((1.0 - horizon_vis) * ed.local_day, 0.0, 1.0))
		: vec3(horizon_vis);
	if (shading_enabled > 0.5) {
		// 伪法线：billboard UV → 局部体积法线（径向 dome，各向同性）。各向同性保证旋转不变：
		// 旋转一个径向对称 dome 不改变其世界法线集合，叠加实例旋转后全图光照方向才真正一致。
		// [veg-instance-rotation 修正] 按本实例旋转把局部法线 xy 转到世界帧，再叠加世界帧地形宏观法线，
		// 否则随机自旋转的每株会得到各自旋转过的光照梯度 → 全图光影方向不一致。
		vec2 pn_local = vec2((UV.x - 0.5) * 2.0, (0.5 - UV.y) * 2.0) * pseudo_normal_strength;
		vec2 pn_world = pn_local.x * shrub_basis_x + pn_local.y * shrub_basis_y;
		vec3 N = normalize(vec3(pn_world + shrub_terrain_n, 1.0));
		vec3 L = ed.sun_dir;                       // 逐实例太阳方向（含纬度/时角，单位向量）
		float ndotl = max(dot(N, L), 0.0);
		float direct = ndotl * sun_shade_strength * ed.local_day * horizon_vis;
		float rim = pow(1.0 - clamp(N.z, 0.0, 1.0), 3.0) * rim_light_strength * ed.local_day * horizon_vis;
		// [sky-sh-ambient] 方向化天光（L1 球谐）替换平铺 amb_col：用植株法线 N 取天光 →
		// 迎天顶/迎太阳方位面更亮、背向面更暗，弱直射(晨昏/夜)时也有体积感。与地形/水面同源。
		vec3 light = max(eval_earth_sky_sh(ed, N), vec3(ambient_floor)) + ed.sun_col * (direct + rim);
		rgb *= light;
		// 接触阴影：近根部压暗（UV.y 低=贴地），让植株"扎进"地面而非漂浮。
		float contact = smoothstep(contact_ao_height, 0.0, UV.y) * contact_ao_strength;
		rgb *= 1.0 - contact;
		// 谷地 AO（高画质档）：凹陷处整株压暗。
		rgb *= 1.0 - shrub_terrain_ao * terrain_valley_ao_strength;
	} else {
		// 退化路径（shading 关）：旧"平直昼夜"着色，保持兼容。
		vec3 light = max(ed.amb_col, vec3(ambient_floor)) + ed.sun_col * (ed.local_day * 0.35 * horizon_vis);
		rgb *= light;
	}
	// 与地形/水面同源的地形投影阴影；植被/点缀比陆地略轻，避免小物件在阴影中过黑。
	float horizon_cast = clamp((1.0 - horizon_vis) * ed.local_day, 0.0, 1.0);
	if (horizon_cast > 0.001) {
		float veg_floor = mix(1.0, terrain_horizon_cast_floor, 0.70);
		rgb *= mix(1.0, veg_floor, horizon_cast);
	}
	rgb *= mix(1.0, 0.55, ed.pixel_night);
	rgb *= tod_exposure;
	if (horizon_debug_mode) {
		rgb = horizon_debug_rgb;
	}
	float alpha = COLOR.a * shrub_presence_v;
	alpha *= 1.0 - snow * 0.32;
	alpha = (alpha < disappear_alpha_threshold) ? 0.0 : alpha;
	COLOR = vec4(rgb, alpha);
}
"""

# [veg-cast-shadow] 投影 pass（软边椭圆 blob）：网格是单位圆盘（VERTEX=单位圆坐标, UV 径向）。
# 顶点把单位圆映射为「沿世界太阳背光方向拉伸的椭圆」——足部半径 shadow_foot_radius、随太阳低
# 度数(sun 水平/竖直比)拉长 proj。片元用径向距离 shadow_r 做平滑 alpha → 柔边，无多边形硬边。
# 实例 transform 自带随机自旋转，故把世界 sdir 先转到局部帧（乘回 MODEL_MATRIX 后方向统一）。
# 夜侧(local_day=0)/枯死/积雪自动淡出。
const _SHADOW_SHADER_CODE := """
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D map_index_atlas : filter_nearest, repeat_disable;
uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0, 1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;

uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.41;
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);

uniform float vitality_dead_threshold = 0.12;
uniform float vitality_healthy_threshold = 0.72;
uniform float vitality_alpha_power = 1.10;
uniform float snow_hide_strength = 0.62;
uniform float aquatic_response = 0.0;

uniform vec4 shadow_color = vec4(0.05, 0.06, 0.08, 1.0);
uniform float shadow_strength = 0.28;
uniform float shadow_length_scale = 1.0;
uniform float shadow_max_len = 1.4;
uniform float shadow_min_sun_elevation = 0.16;
uniform float shadow_foot_radius = 0.55;   // 足部半径(局部单位; ×实例 size = 世界足印)
uniform float shadow_edge_softness = 0.25;  // 0..1 软边起点(越小越柔; r<此值为实心核心)

#include \"res://shaders/include/earth_daylight.gdshaderinc\"

varying float shadow_alpha_v;
varying float shadow_r;   // 单位径向 0(心)..1(缘)，用于柔边

int sh_decode_cell_index(vec2 uv) {
	vec2 gb = texture(map_index_atlas, uv).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

vec2 sh_cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) { lw = 1; }
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

float sh_vitality_norm(float vitality) {
	float dead_t = min(vitality_dead_threshold, vitality_healthy_threshold - 0.001);
	float healthy_t = max(vitality_healthy_threshold, dead_t + 0.001);
	return clamp((clamp(vitality, 0.0, 1.0) - dead_t) / (healthy_t - dead_t), 0.0, 1.0);
}

void vertex() {
	vec2 uv = clamp(INSTANCE_CUSTOM.rg, vec2(0.0), vec2(1.0));
	float lat_signed = uv.y * 2.0 - 1.0;
	EarthDaylight ed = eval_earth_daylight(uv, lat_signed, day_night_enabled);

	// presence-lite：枯死 / 积雪覆盖时阴影一并消失（与植株 compute_presence 同向，省去 eco fetch）。
	int cid = sh_decode_cell_index(uv);
	vec4 dyn = (cid >= 0) ? texture(dyn_lut, sh_cell_lut_uv(cid)) : vec4(0.0);
	float dyn_valid = step(0.02, dyn.r);
	float vitality = mix(0.70, dyn.a, dyn_valid);
	vitality = mix(vitality, 0.86, aquatic_response);
	float snow = dyn.b * dyn_valid;
	float presence = pow(sh_vitality_norm(vitality), vitality_alpha_power);
	presence *= 1.0 - clamp(snow, 0.0, 1.0) * snow_hide_strength;

	// 太阳水平分量 → 背光方向 sdir（世界帧）；低太阳(竖直分量小)→ proj 拉长。
	vec2 sun_h = ed.sun_dir.xy;
	float sun_len = length(sun_h);
	float sun_up = max(ed.sun_dir.z, 0.0);
	vec2 sdir = (sun_len > 1e-4) ? -sun_h / sun_len : vec2(0.0, 1.0);
	float proj = clamp(sun_len / max(sun_up, shadow_min_sun_elevation), 0.0, shadow_max_len) * shadow_length_scale;

	// 本实例正交基（去缩放归一化）：把世界 sdir 转到局部帧，乘回 MODEL_MATRIX(含随机旋转) 后方向统一。
	vec2 inst_ax = vec2(MODEL_MATRIX[0].x, MODEL_MATRIX[0].y);
	vec2 inst_ay = vec2(MODEL_MATRIX[1].x, MODEL_MATRIX[1].y);
	float inst_axl = length(inst_ax);
	float inst_ayl = length(inst_ay);
	vec2 nax = (inst_axl > 1e-5) ? inst_ax / inst_axl : vec2(1.0, 0.0);
	vec2 nay = (inst_ayl > 1e-5) ? inst_ay / inst_ayl : vec2(0.0, 1.0);
	vec2 sdl = vec2(dot(sdir, nax), dot(sdir, nay));     // 局部帧背光方向
	vec2 perp = vec2(-sdl.y, sdl.x);                      // 垂直方向(椭圆次轴)

	// 单位圆 VERTEX → 椭圆：主轴沿 sdl(足印半径 + 投影一半)，中心前移 proj/2；次轴沿 perp(足印半径)。
	// proj=0(太阳当顶) → 退化为足部圆盘(接触阴影)；proj 大(低太阳) → 长椭圆。
	vec2 p = VERTEX;
	float half_major = shadow_foot_radius + proj * 0.5;
	float center_along = proj * 0.5;
	VERTEX = sdl * (center_along + p.x * half_major) + perp * (p.y * shadow_foot_radius);

	shadow_r = length(p);   // 网格本身 |p|<=1，传给片元做径向柔边
	shadow_alpha_v = shadow_strength * ed.local_day * clamp(presence, 0.0, 1.0);
}

void fragment() {
	// 径向平滑：核心(r<softness)实心，向边缘平滑淡出至 0 → 柔边、无多边形轮廓。
	float edge = 1.0 - smoothstep(shadow_edge_softness, 1.0, shadow_r);
	float a = shadow_alpha_v * edge;
	a = (a < 0.003) ? 0.0 : a;
	COLOR = vec4(shadow_color.rgb, a);
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
var _last_rebuild_ms: float = 0.0
var _last_candidate_count: int = 0
var _last_wrap_edge_copy_count: int = 0
var _last_rebuild_reason: String = ""
var _last_incremental_cells: int = 0
var _last_incremental_missing_slots: int = 0
var _last_incremental_dropped_instances: int = 0
var _last_dirty_chunks: int = 0
var _last_native_sampled_cells: int = 0
var _last_native_active_cells: int = 0
var _last_native_water_cache_ms: float = 0.0
var _last_native_context_ms: float = 0.0
var _last_native_knobs_ms: float = 0.0
var _last_native_call_ms: float = 0.0
var _last_native_apply_ms: float = 0.0
var _cell_instance_lookup: Dictionary = {}
var _native_offset_is_water_cache: PackedByteArray = PackedByteArray()
var _native_offset_cache_dims: Vector2i = Vector2i.ZERO
var _native_veg_climate_tables: Dictionary = {}
var _native_delta_common_knobs: Dictionary = {}
var _chunked_multimesh_enabled: bool = true
var _chunk_size_cells: int = 8
var _chunk_nodes: Dictionary = {}
var _chunk_instance_counts: Dictionary = {}

var _mmi: MultiMeshInstance2D = null
var _multimesh: MultiMesh = null
var _material: ShaderMaterial = null

# [veg-cast-shadow] 投影 pass：专用「软边椭圆 blob」网格（不复用植株多裂片网格——复用会按各裂片
# 高度剪切拉开 → 形状怪 + 硬边）。顶点把单位圆映射为沿太阳背光方向拉伸的椭圆，片元用径向 alpha
# 柔边。分块模式用 _shadow_chunk_nodes 逐 chunk 镜像（见下）；单节点回退用下面这组。
var _shadow_material: ShaderMaterial = null
var _shadow_mmi: MultiMeshInstance2D = null
var _shadow_multimesh: MultiMesh = null
var _shadow_blob_mesh: ArrayMesh = null
# [veg-cast-shadow perf] 投影与植株「逐 chunk 镜像」：每个植株 chunk 配一个 shadow chunk 节点
# （blob 网格 + 低 z + shadow 材质），buffer 直接镜像对应植株 chunk。演替只重写「脏 chunk」的
# buffer → 投影同步成本 = O(该 chunk)，与植株自身更新同阶（不再全图 O(total) 重传）。方向/长度/
# 强度/尺寸全部在顶点着色器里按 TOD 太阳方位实时计算（GPU），CPU 不写这些量；太阳移动零 CPU 开销。
# _shadow_multimesh/_shadow_mmi 仅用于「单节点(非分块)回退模式」。
var _shadow_chunk_nodes: Dictionary = {}
var _shadow_built_total: int = 0   # 单节点回退模式：上次镜像的实例数（用于按需重建）
var _shadow_fraction: float = 1.0

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
	_native_offset_is_water_cache = PackedByteArray()
	_native_offset_cache_dims = Vector2i.ZERO
	_native_delta_common_knobs = {}
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
	_cell_instance_lookup.clear()
	_clear_chunk_nodes()
	if _multimesh != null:
		_multimesh.instance_count = 0
		_multimesh.visible_instance_count = 0
	if _shadow_multimesh != null:
		_shadow_multimesh.instance_count = 0
		_shadow_multimesh.visible_instance_count = 0
	_shadow_built_total = 0
	# _shadow_chunk_nodes 已由 _clear_chunk_nodes() 释放
	if _shadow_mmi != null:
		_shadow_mmi.visible = false
	visible = false


func set_world_time(v: float) -> void:
	if _material != null:
		_material.set_shader_parameter("world_time", v)


func set_season_phase(v: float) -> void:
	if _material != null:
		_material.set_shader_parameter("season_phase", v)
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("season_phase", v)


func set_day_phase(v: float) -> void:
	var p := fposmod(v, 1.0)
	if _material != null:
		_material.set_shader_parameter("day_phase", p)
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("day_phase", p)


func set_world_material_inputs(world: WorldData, bounds: Rect2, _use_cell_indirection: bool) -> void:
	_world = world
	_bounds = bounds
	_native_delta_common_knobs = {}
	_sync_world_material_inputs(true)


# [cylindrical-earth-daylight] 昼夜光照与地形同源（逐像素经纬度晨昏线）。
# 昼夜色/昼夜系数已在 shader 内按本实例经纬度逐像素求解，这里只需同步全局曝光；
# sun/ambient/night_factor 形参保留仅为调用方兼容，不再消费。
func set_tod(_sun_color: Color, _ambient_color: Color, _night_factor: float, exposure: float) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("tod_exposure", exposure)


func set_tod_sun_dir(dir: Vector3) -> void:
	var d := dir.normalized()
	if d.length_squared() <= 0.000001:
		d = Vector3(0.4, -0.7, 0.6).normalized()
	if _material != null:
		_material.set_shader_parameter("tod_sun_dir", d)
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("tod_sun_dir", d)


func set_tod_debug_sun_position(enabled: bool, uv: Vector2) -> void:
	var p := Vector2(fposmod(uv.x, 1.0), clampf(uv.y, 0.0, 1.0))
	if _material != null:
		_material.set_shader_parameter("tod_debug_sun_position_enabled", enabled)
		_material.set_shader_parameter("tod_debug_sun_uv", p)
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("tod_debug_sun_position_enabled", enabled)
		_shadow_material.set_shader_parameter("tod_debug_sun_uv", p)


func set_tod_debug_sun_height_scale(v: float) -> void:
	var scale := clampf(v, 0.2, 1.5)
	if _material != null:
		_material.set_shader_parameter("tod_debug_sun_height_scale", scale)
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("tod_debug_sun_height_scale", scale)


# 地轴倾角(rad)：与地形 axial_tilt_rad 同源，驱动晨昏线的季节赤纬。
func set_axial_tilt_rad(v: float) -> void:
	if _material != null:
		_material.set_shader_parameter("axial_tilt_rad", v)
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("axial_tilt_rad", v)


# 昼夜总开关：关闭时植被退化为永昼（与地形 day_night_enabled 一致）。
func set_day_night_enabled(v: bool) -> void:
	if _material != null:
		_material.set_shader_parameter("day_night_enabled", v)
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("day_night_enabled", v)


# 阶段 D：全局盛行风方向 + 实时天气附加风强（风暴/季风）。每帧由 hex_renderer 推送。
func set_wind_field(dir: Vector2, boost: float) -> void:
	if _material == null:
		return
	var d := dir if dir.length() > 0.0001 else Vector2(1.0, 0.18)
	_material.set_shader_parameter("wind_dir", d.normalized())
	_material.set_shader_parameter("weather_wind_boost", maxf(boost, 0.0))


func set_terrain_horizon_inputs(tex: Texture2D, bound: bool, strength: float, softness: float,
		max_angle: float, cast_floor: float, debug_view: int) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("terrain_horizon_tex", tex)
	_material.set_shader_parameter("terrain_horizon_tex_bound", bound)
	_material.set_shader_parameter("terrain_horizon_strength", clampf(strength, 0.0, 1.0))
	_material.set_shader_parameter("terrain_horizon_softness", clampf(softness, 0.01, 1.0))
	_material.set_shader_parameter("terrain_horizon_max_angle", clampf(max_angle, 0.30, 1.5708))
	_material.set_shader_parameter("terrain_horizon_cast_floor", clampf(cast_floor, 0.35, 1.0))
	_material.set_shader_parameter("terrain_horizon_debug_view", clampi(debug_view, 0, 2))


# 注入 C++ DCWorldExt。可传 null 关闭 native 路径（强制 GDScript fallback）。
func set_world_ext(ext) -> void:
	_world_ext = ext


func set_chunked_multimesh_enabled(enabled: bool, chunk_size_cells: int = 8) -> void:
	var next_size := maxi(2, chunk_size_cells)
	if _chunked_multimesh_enabled == enabled and _chunk_size_cells == next_size:
		return
	_chunked_multimesh_enabled = enabled
	_chunk_size_cells = next_size
	if _map != null:
		_rebuild_instances()


func set_visual_quality(q: int) -> void:
	var next_q := clampi(q, 0, 2)
	if _visual_quality == next_q:
		return
	_visual_quality = next_q
	_native_delta_common_knobs = {}
	if _map != null:
		_rebuild_instances()


func refresh_for_succession(_indices: PackedInt32Array) -> void:
	if _map == null or _indices.is_empty():
		return
	if _chunked_multimesh_enabled and _refresh_chunked_for_succession(_indices):
		return  # 分块：shadow chunk 已在 _apply_chunk_payload 内逐 chunk 镜像（O(脏chunk)）
	_ensure_incremental_multimesh()
	if _multimesh == null:
		return
	if _refresh_for_succession_native(_indices):
		_sync_single_shadow()
		return
	var t0_us := Time.get_ticks_usec()
	var cells_done := 0
	var missing_slots := 0
	var dropped := 0
	var generated := 0
	for ci in _indices:
		var idx := int(ci)
		var cell := _map.cell_at(idx)
		if cell == null:
			missing_slots += 1
			continue
		var payload := _generate_cell_instance_payload(cell, idx)
		var transforms: Array = payload.get("transforms", [])
		var colors: Array = payload.get("colors", [])
		var customs: Array = payload.get("customs", [])
		var next_count := transforms.size()
		generated += next_count
		var slots: Array = _cell_instance_lookup.get(idx, [])
		if slots.size() < next_count:
			var new_slots := _append_instance_slots(idx, next_count - slots.size())
			for slot in new_slots:
				slots.append(slot)
			_cell_instance_lookup[idx] = slots
		var write_count := mini(slots.size(), next_count)
		for j in range(write_count):
			var slot := int(slots[j])
			_multimesh.set_instance_transform_2d(slot, transforms[j])
			_multimesh.set_instance_color(slot, colors[j])
			_multimesh.set_instance_custom_data(slot, customs[j])
		for j in range(write_count, slots.size()):
			var slot := int(slots[j])
			_multimesh.set_instance_color(slot, Color(0, 0, 0, 0))
		if next_count > slots.size():
			dropped += next_count - slots.size()
		cells_done += 1
	_last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	_last_candidate_count = generated
	_last_rebuild_reason = "incremental_cell_update"
	_last_incremental_cells = cells_done
	_last_incremental_missing_slots = missing_slots
	_last_incremental_dropped_instances = dropped
	visible = _profile().enabled and _instance_count > 0
	_sync_single_shadow()


func _refresh_for_succession_native(indices: PackedInt32Array) -> bool:
	if _world_ext == null or not _world_ext.has_method("encode_detail_scatter_delta"):
		return false
	if _map == null or _multimesh == null:
		return false
	var t0_us := Time.get_ticks_usec()
	var grid_w: int = int(_map.width) if "width" in _map else 0
	var grid_h: int = int(_map.height) if "height" in _map else 0
	if grid_w <= 0 or grid_h <= 0:
		return false

	var valid_indices := PackedInt32Array()
	var keys := PackedInt32Array()
	var native_cell_indices := PackedInt32Array()
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

	for raw_idx in indices:
		var idx := int(raw_idx)
		var cell := _map.cell_at(idx)
		if cell == null:
			continue
		valid_indices.append(idx)
		var state := _sample_cell_state(idx, cell)
		var key := _cell_hash_key(cell, idx)
		var suitability := _cell_suitability(cell, idx, key, state)
		if suitability <= 0.0:
			continue
		if _scatter_presence(state) <= 0.02:
			continue
		var veg := int(state.get("vegetation", VegetationType.VEG.NONE))
		var lf := int(state.get("landform", LandformType.LF.PLAIN))
		var cover := int(state.get("cover", CoverType.CV.NONE))
		var center := _cell_center(cell, idx)
		var base := _base_color_for_vegetation(veg)
		keys.append(key)
		native_cell_indices.append(idx)
		cx.append(center.x)
		cy.append(center.y)
		suit.append(suitability)
		att.append(maxi(1, int(ceil(float(_max_per_cell()) * clampf(suitability, 0.0, 1.0)))))
		vit.append(clampf(float(state.get("vitality", 0.7)), 0.0, 1.0))
		sized.append(_vegetation_weight(veg) * _landform_weight(lf) * _cover_weight(cover))
		col_r.append(base.r)
		col_g.append(base.g)
		col_b.append(base.b)
		col_a.append(base.a)

	if valid_indices.is_empty():
		return false
	if keys.is_empty():
		_apply_native_delta_payload(valid_indices, PackedFloat32Array(), PackedInt32Array(), 0, 0, 0, t0_us)
		return true

	var cfg := _profile()
	var knobs := {
		"hex_size": _hex_size,
		"origin_x": _bounds.position.x,
		"origin_y": _bounds.position.y,
		"size_x": _bounds.size.x,
		"size_y": _bounds.size.y,
		"wrap_period_x": HexUtils.wrap_period_x(grid_w, _hex_size),
		"wrap_edge_margin": _hex_size * 4.0,
		"grid_w": grid_w,
		"grid_h": grid_h,
		"offset_is_water": _native_offset_is_water(grid_w, grid_h),
		"flow_buffer": _world.flow_buffer if _world != null else PackedFloat32Array(),
		"flow_w": int(_world.derived_size.x) if _world != null else 0,
		"flow_h": int(_world.derived_size.y) if _world != null else 0,
		"river_clear_threshold": cfg.river_clear_threshold,
		"spawn_domain": _spawn_domain(),
		"rotation_mode": _rotation_mode(),
		"random_rotation_strength": _random_rotation_strength(),
		"upright_jitter_radians": deg_to_rad(_upright_jitter_degrees()),
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
		"instance_cap": maxi(_instance_cap(), keys.size() * maxi(_max_per_cell(), 1) * 3),
		"keys": keys,
		"cell_indices": native_cell_indices,
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

	var res = _world_ext.call("encode_detail_scatter_delta", knobs)
	if not (res is Dictionary):
		return false
	if bool(res.get("fallback", true)):
		_last_rebuild_reason = str(res.get("reason", "native_delta_fallback"))
		return false
	var inst := int(res.get("instance_count", 0))
	var buffer: PackedFloat32Array = res.get("buffer", PackedFloat32Array())
	var cell_indices: PackedInt32Array = res.get("cell_indices", PackedInt32Array())
	if inst > 0 and (buffer.size() < inst * 16 or cell_indices.size() < inst):
		_last_rebuild_reason = "native_delta_bad_payload"
		return false
	_apply_native_delta_payload(
		valid_indices,
		buffer,
		cell_indices,
		inst,
		int(res.get("candidate_count", 0)),
		int(res.get("wrap_edge_copy_count", 0)),
		t0_us
	)
	return true


func _apply_native_delta_payload(
		valid_indices: PackedInt32Array,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int,
		candidate_count: int,
		wrap_count: int,
		t0_us: int) -> void:
	var by_cell := {}
	for i in range(inst):
		var ci := int(cell_indices[i])
		var srcs: Array = by_cell.get(ci, [])
		srcs.append(i)
		by_cell[ci] = srcs

	var cells_done := 0
	var missing_slots := 0
	var dropped := 0
	var generated := 0
	for raw_idx in valid_indices:
		var idx := int(raw_idx)
		var src_indices: Array = by_cell.get(idx, [])
		var slots: Array = _cell_instance_lookup.get(idx, [])
		generated += src_indices.size()
		if slots.size() < src_indices.size():
			var new_slots := _append_instance_slots(idx, src_indices.size() - slots.size())
			for slot in new_slots:
				slots.append(slot)
			_cell_instance_lookup[idx] = slots
		var write_count := mini(slots.size(), src_indices.size())
		for j in range(write_count):
			_set_slot_from_native_buffer(int(slots[j]), buffer, int(src_indices[j]))
		for j in range(write_count, slots.size()):
			_multimesh.set_instance_color(int(slots[j]), Color(0, 0, 0, 0))
		if src_indices.size() > slots.size():
			dropped += src_indices.size() - slots.size()
		if slots.is_empty() and src_indices.is_empty():
			missing_slots += 1
		cells_done += 1

	_last_scatter_path = "gdext_delta"
	_last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	_last_candidate_count = maxi(candidate_count, generated)
	_last_wrap_edge_copy_count = wrap_count
	_last_rebuild_reason = "incremental_cell_update"
	_last_incremental_cells = cells_done
	_last_incremental_missing_slots = missing_slots
	_last_incremental_dropped_instances = dropped
	visible = _profile().enabled and _instance_count > 0
	_sync_single_shadow()


func _set_slot_from_native_buffer(slot: int, buffer: PackedFloat32Array, src: int) -> void:
	var b := src * 16
	var xf := Transform2D(
		Vector2(buffer[b + 0], buffer[b + 4]),
		Vector2(buffer[b + 1], buffer[b + 5]),
		Vector2(buffer[b + 3], buffer[b + 7])
	)
	_multimesh.set_instance_transform_2d(slot, xf)
	_multimesh.set_instance_color(slot, Color(buffer[b + 8], buffer[b + 9], buffer[b + 10], buffer[b + 11]))
	_multimesh.set_instance_custom_data(slot, Color(buffer[b + 12], buffer[b + 13], buffer[b + 14], buffer[b + 15]))


func _native_offset_is_water(grid_w: int, grid_h: int) -> PackedByteArray:
	if _native_offset_cache_dims == Vector2i(grid_w, grid_h) and _native_offset_is_water_cache.size() == grid_w * grid_h:
		_last_native_water_cache_ms = 0.0
		return _native_offset_is_water_cache
	var t0_us := Time.get_ticks_usec()
	var map_id := _map.get_instance_id() if _map != null else 0
	var cache_key := "%d:%d:%d" % [map_id, grid_w, grid_h]
	var shared: PackedByteArray = _shared_offset_is_water_cache.get(cache_key, PackedByteArray())
	if shared.size() == grid_w * grid_h:
		_native_offset_is_water_cache = shared
		_native_offset_cache_dims = Vector2i(grid_w, grid_h)
		_last_native_water_cache_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		return _native_offset_is_water_cache
	_native_offset_is_water_cache = PackedByteArray()
	_native_offset_is_water_cache.resize(grid_w * grid_h)
	_native_offset_is_water_cache.fill(1)
	if _map == null:
		_last_native_water_cache_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		return _native_offset_is_water_cache
	var cells: Array = _map.iter_cells()
	for order in range(cells.size()):
		var cell = cells[order]
		if cell == null:
			continue
		var idx := _cell_index(cell, order)
		var off := HexUtils.cube_to_offset(int(cell.q), int(cell.r))
		if off.x >= 0 and off.x < grid_w and off.y >= 0 and off.y < grid_h:
			_native_offset_is_water_cache[off.y * grid_w + off.x] = (1 if _is_water_cell(cell, idx) else 0)
	_native_offset_cache_dims = Vector2i(grid_w, grid_h)
	_shared_offset_is_water_cache[cache_key] = _native_offset_is_water_cache
	_last_native_water_cache_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	return _native_offset_is_water_cache


func _vegetation_climate_tables() -> Dictionary:
	if not _native_veg_climate_tables.is_empty():
		return _native_veg_climate_tables
	var n_veg: int = VegetationType.VEG.size()
	var ideal_temp := PackedFloat32Array()
	var ideal_moist := PackedFloat32Array()
	var temp_tol := PackedFloat32Array()
	var moist_tol := PackedFloat32Array()
	ideal_temp.resize(n_veg)
	ideal_moist.resize(n_veg)
	temp_tol.resize(n_veg)
	moist_tol.resize(n_veg)
	for v in range(n_veg):
		var p = VegetationProfileRegistryScript.get_profile(v)
		ideal_temp[v] = float(p.ideal_temp) if p != null else 0.5
		ideal_moist[v] = float(p.ideal_moist) if p != null else 0.5
		temp_tol[v] = maxf(float(p.temp_tolerance), 0.01) if p != null else 0.28
		moist_tol[v] = maxf(float(p.moist_tolerance), 0.01) if p != null else 0.28
	_native_veg_climate_tables = {
		"ideal_temp": ideal_temp,
		"ideal_moist": ideal_moist,
		"temp_tol": temp_tol,
		"moist_tol": moist_tol,
	}
	return _native_veg_climate_tables


func begin_detail_chunk_refresh() -> void:
	_last_native_water_cache_ms = 0.0
	_last_native_context_ms = 0.0
	_last_native_knobs_ms = 0.0
	_last_native_call_ms = 0.0
	_last_native_apply_ms = 0.0
	_native_delta_common_knobs = {}


func _build_native_delta_common_knobs() -> Dictionary:
	var t0_us := Time.get_ticks_usec()
	if _map == null:
		_last_native_context_ms = 0.0
		return {}
	var grid_w: int = int(_map.width) if "width" in _map else 0
	var grid_h: int = int(_map.height) if "height" in _map else 0
	if grid_w <= 0 or grid_h <= 0:
		_last_native_context_ms = 0.0
		return {}
	var cfg := _profile()
	var veg_tables := _vegetation_climate_tables()
	var override_color: Color = cfg.base_color_override
	var common := {
		"cell_pos_x": _map.cell_pos_x_arr,
		"cell_pos_y": _map.cell_pos_y_arr,
		"temp_arr": _map.temp_arr,
		"moisture_arr": _map.moisture_arr,
		"snow_cover_arr": _map.snow_cover_arr,
		"weather_intensity_arr": _map.weather_intensity_arr,
		"vegetation_vitality_arr": _map.vegetation_vitality_arr,
		"vegetation_heat_stress_arr": _map.vegetation_heat_stress_arr,
		"vegetation_drought_stress_arr": _map.vegetation_drought_stress_arr,
		"vegetation_cold_stress_arr": _map.vegetation_cold_stress_arr,
		"landform_arr": _map.landform_arr,
		"vegetation_arr": _map.vegetation_arr,
		"cover_arr": _map.cover_arr,
		"weather_type_arr": _map.weather_type_arr,
		"elevation_arr": _map.elevation_arr,
		"soil_moisture_arr": _map.soil_moisture_arr,
		"river_discharge_arr": _map.river_discharge_arr,
		"wind_speed_arr": _map.wind_speed_arr,
		"is_water_arr": _map.is_water_arr,
		"has_river_arr": _map.has_river_arr,
		"veg_ideal_temp": veg_tables.get("ideal_temp", PackedFloat32Array()),
		"veg_ideal_moist": veg_tables.get("ideal_moist", PackedFloat32Array()),
		"veg_temp_tol": veg_tables.get("temp_tol", PackedFloat32Array()),
		"veg_moist_tol": veg_tables.get("moist_tol", PackedFloat32Array()),
		"hex_size": _hex_size,
		"origin_x": _bounds.position.x,
		"origin_y": _bounds.position.y,
		"size_x": _bounds.size.x,
		"size_y": _bounds.size.y,
		"wrap_period_x": HexUtils.wrap_period_x(grid_w, _hex_size),
		"wrap_edge_margin": _hex_size * 4.0,
		"grid_w": grid_w,
		"grid_h": grid_h,
		"offset_is_water": _native_offset_is_water(grid_w, grid_h),
		"flow_buffer": _world.flow_buffer if _world != null else PackedFloat32Array(),
		"flow_w": int(_world.derived_size.x) if _world != null else 0,
		"flow_h": int(_world.derived_size.y) if _world != null else 0,
		"detail_kind": _detail_kind(),
		"max_per_cell": _max_per_cell(),
		"quality_density_scale": _quality_density_scale(),
		"river_clear_threshold": cfg.river_clear_threshold,
		"river_edge_density": cfg.river_edge_density,
		"spawn_domain": _spawn_domain(),
		"rotation_mode": _rotation_mode(),
		"random_rotation_strength": _random_rotation_strength(),
		"upright_jitter_radians": deg_to_rad(_upright_jitter_degrees()),
		"base_color_override_enabled": bool(cfg.base_color_override_enabled),
		"base_color_r": override_color.r,
		"base_color_g": override_color.g,
		"base_color_b": override_color.b,
		"base_color_a": override_color.a,
		"vegetation_weight_overrides": cfg.vegetation_weight_overrides,
		"landform_weight_overrides": cfg.landform_weight_overrides,
		"cover_weight_overrides": cfg.cover_weight_overrides,
		"spawn_radius_factor": cfg.spawn_radius_factor,
		"world_noise_warp_strength": cfg.world_noise_warp_strength,
		"patch_frequency": cfg.patch_frequency,
		"patch_cutoff": cfg.patch_cutoff,
		"patch_contrast": cfg.patch_contrast,
		"world_noise_mid_mix": cfg.world_noise_mid_mix,
		"world_noise_fine_mix": cfg.world_noise_fine_mix,
		"micro_gap_threshold": cfg.micro_gap_threshold,
		"world_noise_acceptance": cfg.world_noise_acceptance,
		"moisture_corridor_boost": cfg.moisture_corridor_boost,
		"vitality_patch_boost": cfg.vitality_patch_boost,
		"stress_hide_strength": cfg.stress_hide_strength,
		"snow_hide_strength": cfg.snow_hide_strength,
		"min_size_factor": minf(cfg.min_size_factor, cfg.max_size_factor),
		"max_size_factor": maxf(cfg.min_size_factor, cfg.max_size_factor),
		"size_scale": _quality_size_scale(),
		"vitality_dead_threshold": cfg.vitality_dead_threshold,
		"vitality_sparse_threshold": cfg.vitality_sparse_threshold,
		"vitality_healthy_threshold": cfg.vitality_healthy_threshold,
		"vitality_density_power": cfg.vitality_density_power,
		"vitality_alpha_power": cfg.vitality_alpha_power,
		"vitality_dieback_noise_strength": cfg.vitality_dieback_noise_strength,
	}
	_last_native_context_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	return common


func _ensure_incremental_multimesh() -> void:
	_ensure_resources()
	if _multimesh != null:
		return
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_multimesh.use_colors = true
	_multimesh.use_custom_data = true
	_multimesh.mesh = _cached_detail_mesh()
	_multimesh.instance_count = 0
	_multimesh.visible_instance_count = 0
	_mmi.multimesh = _multimesh


func _rebuild_cell_instance_lookup() -> void:
	_cell_instance_lookup.clear()
	for i in range(_instance_cell_indices.size()):
		var ci := int(_instance_cell_indices[i])
		if ci < 0:
			continue
		var slots: Array = _cell_instance_lookup.get(ci, [])
		slots.append(i)
		_cell_instance_lookup[ci] = slots


func _append_instance_slots(cell_idx: int, count: int) -> Array:
	var slots: Array = []
	if count <= 0 or _multimesh == null:
		return slots
	var old_count := _instance_count
	var next_count := old_count + count
	var buffer := _multimesh.buffer
	buffer.resize(next_count * 16)
	_multimesh.instance_count = next_count
	_multimesh.buffer = buffer
	_multimesh.visible_instance_count = next_count
	_instance_count = next_count
	for i in range(old_count, next_count):
		slots.append(i)
		_instance_cell_indices.append(cell_idx)
	return slots


func _generate_cell_instance_payload(cell, idx: int) -> Dictionary:
	var state := _sample_cell_state(idx, cell)
	var key := _cell_hash_key(cell, idx)
	var suitability := _cell_suitability(cell, idx, key, state)
	var transforms: Array = []
	var colors: Array = []
	var customs: Array = []
	if suitability <= 0.0:
		return {"transforms": transforms, "colors": colors, "customs": customs}
	var attempts := maxi(1, int(ceil(float(_max_per_cell()) * clampf(suitability, 0.0, 1.0))))

	var saved_cell_indices := _instance_cell_indices
	var saved_positions := _instance_positions
	var saved_rotations := _instance_rotations
	var saved_sizes := _instance_sizes
	var saved_seeds := _instance_seeds
	var saved_variants := _instance_variants
	var saved_scores := _instance_scores
	var saved_cells := _instance_cells.duplicate()

	_instance_cell_indices = PackedInt32Array()
	_instance_positions = PackedVector2Array()
	_instance_rotations = PackedFloat32Array()
	_instance_sizes = PackedFloat32Array()
	_instance_seeds = PackedFloat32Array()
	_instance_variants = PackedFloat32Array()
	_instance_scores = PackedFloat32Array()
	_instance_cells = []

	for attempt in range(attempts):
		_try_append_instance(cell, idx, key, attempt, suitability, state)
	_append_wrap_edge_instances()

	for i in range(_instance_cell_indices.size()):
		var inst_idx := int(_instance_cell_indices[i])
		var inst_cell = _instance_cells[i]
		var inst_state := _sample_cell_state(inst_idx, inst_cell)
		transforms.append(_instance_transform(i))
		colors.append(_base_color_for_state(inst_state, _instance_variants[i]))
		var uv := _world_uv(_instance_positions[i])
		customs.append(Color(uv.x, uv.y, _instance_seeds[i], _instance_variants[i]))

	_instance_cell_indices = saved_cell_indices
	_instance_positions = saved_positions
	_instance_rotations = saved_rotations
	_instance_sizes = saved_sizes
	_instance_seeds = saved_seeds
	_instance_variants = saved_variants
	_instance_scores = saved_scores
	_instance_cells = saved_cells

	return {"transforms": transforms, "colors": colors, "customs": customs}


func instance_count() -> int:
	return _instance_count


func apply_visible_instance_fraction(fraction: float) -> void:
	var f := clampf(fraction, 0.0, 1.0)
	_shadow_fraction = f
	if _chunked_multimesh_enabled and not _chunk_nodes.is_empty():
		var any_visible := false
		var show_shadow := _shadow_should_render()
		for chunk_id in _chunk_nodes.keys():
			var node: MultiMeshInstance2D = _chunk_nodes[chunk_id]
			if node == null or not is_instance_valid(node) or node.multimesh == null:
				continue
			var count := int(_chunk_instance_counts.get(chunk_id, 0))
			var next_visible := clampi(int(floor(float(count) * f)), 0, count)
			node.multimesh.visible_instance_count = next_visible
			node.visible = _profile().enabled and next_visible > 0
			any_visible = any_visible or next_visible > 0
			# 逐帧 LOD 内联同步对应 shadow chunk 的可见数（仅 visible_instance_count，无 buffer 操作）
			var snode: MultiMeshInstance2D = _shadow_chunk_nodes.get(chunk_id, null)
			if snode != null and is_instance_valid(snode) and snode.multimesh != null:
				snode.multimesh.visible_instance_count = clampi(next_visible, 0, snode.multimesh.instance_count)
				snode.visible = show_shadow and node.visible and next_visible > 0
		visible = _profile().enabled and any_visible
		if _shadow_mmi != null:
			_shadow_mmi.visible = false
		return
	if _multimesh == null:
		visible = false
		_sync_single_shadow()
		return
	var next_visible := clampi(int(floor(float(_instance_count) * f)), 0, _instance_count)
	_multimesh.visible_instance_count = next_visible
	visible = _profile().enabled and next_visible > 0
	_sync_single_shadow()


func set_mobile_quality_tier(q: int) -> void:
	var next_q := clampi(q, 0, 2)
	if _mobile_quality_tier == next_q:
		return
	_mobile_quality_tier = next_q
	_native_delta_common_knobs = {}
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
		_material.set_shader_parameter("axial_tilt_rad", 0.41)
		_material.set_shader_parameter("day_night_enabled", true)
		_mmi.material = _material
	if _shadow_material == null:
		var shadow_shader := Shader.new()
		shadow_shader.code = _SHADOW_SHADER_CODE
		_shadow_material = ShaderMaterial.new()
		_shadow_material.shader = shadow_shader
		_shadow_material.set_shader_parameter("season_phase", 1.0)
		_shadow_material.set_shader_parameter("day_phase", 0.25)
		_shadow_material.set_shader_parameter("axial_tilt_rad", 0.41)
		_shadow_material.set_shader_parameter("day_night_enabled", true)
	if _shadow_blob_mesh == null:
		_shadow_blob_mesh = _build_shadow_blob_mesh()
	if _shadow_multimesh == null:
		_shadow_multimesh = MultiMesh.new()
		_shadow_multimesh.transform_format = MultiMesh.TRANSFORM_2D
		_shadow_multimesh.use_colors = true
		_shadow_multimesh.use_custom_data = true
		_shadow_multimesh.mesh = _shadow_blob_mesh
		_shadow_multimesh.instance_count = 0
		_shadow_multimesh.visible_instance_count = 0
	if _shadow_mmi == null:
		_shadow_mmi = MultiMeshInstance2D.new()
		_shadow_mmi.name = "ShrubShadowMultiMesh"
		# 低 z（相对层 z 减 1）：渲染在地形之上、植株之下。
		_shadow_mmi.z_index = -1
		_shadow_mmi.material = _shadow_material
		_shadow_mmi.multimesh = _shadow_multimesh
		_shadow_mmi.visible = false
		add_child(_shadow_mmi)
	_apply_profile_uniforms()
	_sync_world_material_inputs(false)


func _clear_chunk_nodes() -> void:
	for node in _chunk_nodes.values():
		if node != null and is_instance_valid(node):
			node.queue_free()
	_chunk_nodes.clear()
	_chunk_instance_counts.clear()
	for snode in _shadow_chunk_nodes.values():
		if snode != null and is_instance_valid(snode):
			snode.queue_free()
	_shadow_chunk_nodes.clear()


# 为某植株 chunk 准备/复用对应的 shadow chunk 节点（blob 网格 + shadow 材质 + 低 z）。
func _ensure_shadow_chunk_node(chunk_id: int) -> MultiMeshInstance2D:
	var snode: MultiMeshInstance2D = _shadow_chunk_nodes.get(chunk_id, null)
	if snode != null and is_instance_valid(snode):
		return snode
	if _shadow_material == null or _shadow_blob_mesh == null:
		_ensure_resources()
	snode = MultiMeshInstance2D.new()
	snode.name = "DetailShadowChunk_%d" % chunk_id
	snode.material = _shadow_material
	snode.z_index = -1  # 地形之上、植株(z=0)之下
	var smm := MultiMesh.new()
	smm.transform_format = MultiMesh.TRANSFORM_2D
	smm.use_colors = true
	smm.use_custom_data = true
	smm.mesh = _shadow_blob_mesh
	smm.instance_count = 0
	smm.visible_instance_count = 0
	snode.multimesh = smm
	snode.visible = false
	add_child(snode)
	_shadow_chunk_nodes[chunk_id] = snode
	return snode


# 把某植株 chunk 的 buffer/count 镜像到对应 shadow chunk（仅该 chunk，O(chunk)）。
# 投影方向/长度/强度/尺寸由 shadow 顶点着色器按 TOD 太阳方位实时算，故这里只需共享 transform+uv。
func _mirror_shadow_chunk(chunk_id: int, buffer: PackedFloat32Array, inst: int) -> void:
	if not _shadow_should_render():
		var ex: MultiMeshInstance2D = _shadow_chunk_nodes.get(chunk_id, null)
		if ex != null and is_instance_valid(ex):
			ex.visible = false
		return
	var snode := _ensure_shadow_chunk_node(chunk_id)
	var smm := snode.multimesh
	smm.instance_count = inst
	if inst > 0:
		smm.buffer = buffer
		smm.visible_instance_count = inst
	else:
		smm.visible_instance_count = 0
	snode.visible = visible and inst > 0


# 门控/全量重建时：把所有植株 chunk 重新镜像到 shadow chunk；门控关则全部隐藏。
func _refresh_all_shadow_chunks() -> void:
	if _shadow_should_render():
		for cid in _shadow_chunk_nodes.keys():
			if not _chunk_nodes.has(cid):
				var orphan: MultiMeshInstance2D = _shadow_chunk_nodes[cid]
				if orphan != null and is_instance_valid(orphan):
					orphan.queue_free()
				_shadow_chunk_nodes.erase(cid)
		for cid in _chunk_nodes.keys():
			var pnode: MultiMeshInstance2D = _chunk_nodes[cid]
			if pnode != null and is_instance_valid(pnode) and pnode.multimesh != null:
				_mirror_shadow_chunk(int(cid), pnode.multimesh.buffer, pnode.multimesh.instance_count)
	else:
		for snode in _shadow_chunk_nodes.values():
			if snode != null and is_instance_valid(snode):
				snode.visible = false


# 单节点(非分块)回退模式的投影同步：仅在实例数变化(或强制)时复制 _multimesh.buffer。
func _sync_single_shadow(force_rebuild: bool = false) -> void:
	if _shadow_mmi == null or _shadow_multimesh == null:
		return
	if not _shadow_should_render() or not visible:
		_shadow_multimesh.visible_instance_count = 0
		_shadow_mmi.visible = false
		return
	var total := (_multimesh.instance_count if _multimesh != null else 0)
	if force_rebuild or total != _shadow_built_total:
		if _multimesh != null and total > 0:
			_shadow_multimesh.instance_count = total
			_shadow_multimesh.buffer = _multimesh.buffer
		else:
			_shadow_multimesh.instance_count = 0
		_shadow_built_total = total
	if _shadow_built_total <= 0:
		_shadow_multimesh.visible_instance_count = 0
		_shadow_mmi.visible = false
		return
	var vis := clampi(int(floor(float(_shadow_built_total) * _shadow_fraction)), 0, _shadow_built_total)
	_shadow_multimesh.visible_instance_count = vis
	_shadow_mmi.visible = vis > 0


# ─── [veg-cast-shadow] 投影 pass：blob 网格 + 单节点 buffer 复制 + 门控 ───────────
# 单位圆盘扇形：中心顶点(0,0, UV 中心) + 边缘顶点(cos,sin, UV 在半径 0.5 圆上)。
# VERTEX 直接是单位圆坐标(供 shader 拉成椭圆)；UV 仅备用。三角扇连接。
func _build_shadow_blob_mesh() -> ArrayMesh:
	var seg := 20
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	verts.append(Vector2.ZERO)
	uvs.append(Vector2(0.5, 0.5))
	cols.append(Color(1.0, 1.0, 1.0, 1.0))
	for i in range(seg):
		var a := TAU * float(i) / float(seg)
		var p := Vector2(cos(a), sin(a))
		verts.append(p)
		uvs.append(Vector2(p.x * 0.5 + 0.5, p.y * 0.5 + 0.5))
		cols.append(Color(1.0, 1.0, 1.0, 1.0))
	for i in range(seg):
		idx.append(0)
		idx.append(1 + i)
		idx.append(1 + ((i + 1) % seg))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _archetype_casts_shadow() -> bool:
	# 仅直立类 archetype 投影；随机旋转的点缀（岩石/草/雪堆）方向不稳、收益低，跳过。
	match _detail_kind():
		DETAIL_TREE, DETAIL_SHRUB, DETAIL_CONIFER, DETAIL_PALM, DETAIL_CACTUS, DETAIL_REED, DETAIL_DEAD_SNAG, DETAIL_ALPINE_FLOWER:
			return true
		_:
			return false


func _shadow_should_render() -> bool:
	var cfg := _profile()
	if not cfg.enabled:
		return false
	var on = cfg.get("cast_shadow_enabled")
	if on != null and not bool(on):
		return false
	# 性能分档：桌面 q>=1 开启；移动端默认关（除非 profile 显式允许且 tier>=2）。
	if OS.has_feature("mobile"):
		var mob = cfg.get("cast_shadow_on_mobile")
		if mob == null or not bool(mob):
			return false
		if _active_quality_tier() < 2:
			return false
	elif _active_quality_tier() < 1:
		return false
	return _archetype_casts_shadow()


const _SHADOW_BUFFER_STRIDE := 16  # 2D transform(8) + color(4) + custom(4)


# 投影层同步分发：分块模式下 buffer 已在 _apply_chunk_payload* 逐 chunk 镜像，这里只在 force
# （门控/全量重建）时整体重镜像；单节点回退模式走 _sync_single_shadow。逐帧 LOD 在
# apply_visible_instance_fraction 内联同步 shadow chunk 的 visible_instance_count（无 buffer 操作）。
func _sync_shadow_layer(force_rebuild: bool = false) -> void:
	if not _chunk_nodes.is_empty():
		if _shadow_mmi != null:
			_shadow_mmi.visible = false  # 分块模式不使用单节点投影
		if force_rebuild:
			_refresh_all_shadow_chunks()
		return
	_sync_single_shadow(force_rebuild)


func _chunk_id_for_cell_idx(cell_idx: int) -> int:
	if _map == null or cell_idx < 0:
		return -1
	var cell = _map.cell_at(cell_idx)
	if cell == null:
		return -1
	var off := HexUtils.cube_to_offset(int(cell.q), int(cell.r))
	var cx := int(floor(float(off.x) / float(maxi(1, _chunk_size_cells))))
	var cy := int(floor(float(off.y) / float(maxi(1, _chunk_size_cells))))
	return cy * 100000 + cx


func _cell_indices_for_chunk(chunk_id: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if _map == null or chunk_id < 0:
		return out
	var chunk_x := chunk_id % 100000
	var chunk_y := int(floor(float(chunk_id) / 100000.0))
	var x0 := chunk_x * _chunk_size_cells
	var y0 := chunk_y * _chunk_size_cells
	var x1 := mini(int(_map.width), x0 + _chunk_size_cells)
	var y1 := mini(int(_map.height), y0 + _chunk_size_cells)
	for row in range(y0, y1):
		for col in range(x0, x1):
			var cube := HexUtils.offset_to_cube(col, row)
			var cell = _map.get_cell(cube.x, cube.y)
			if cell != null:
				out.append(int(cell.index))
	return out


func _ensure_chunk_node(chunk_id: int) -> MultiMeshInstance2D:
	var node: MultiMeshInstance2D = _chunk_nodes.get(chunk_id, null)
	if node != null and is_instance_valid(node):
		return node
	node = MultiMeshInstance2D.new()
	node.name = "DetailChunk_%d" % chunk_id
	node.material = _material
	add_child(node)
	_chunk_nodes[chunk_id] = node
	return node


func _prepare_chunk_multimesh(chunk_id: int, inst: int) -> MultiMesh:
	var node := _ensure_chunk_node(chunk_id)
	var mm := node.multimesh
	if mm == null:
		mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true
		mm.use_custom_data = true
		node.multimesh = mm
	mm.mesh = _cached_detail_mesh()
	mm.instance_count = inst
	mm.visible_instance_count = inst
	node.visible = _profile().enabled and inst > 0
	_chunk_instance_counts[chunk_id] = inst
	return mm


func _apply_chunk_payload(chunk_id: int, buffer: PackedFloat32Array, src_indices: Array, inst: int) -> void:
	var mm := _prepare_chunk_multimesh(chunk_id, inst)
	if inst > 0:
		var chunk_buffer := PackedFloat32Array()
		chunk_buffer.resize(inst * 16)
		for dst in range(inst):
			var src := int(src_indices[dst])
			var src_b := src * 16
			var dst_b := dst * 16
			for k in range(16):
				chunk_buffer[dst_b + k] = buffer[src_b + k]
		mm.buffer = chunk_buffer
		_mirror_shadow_chunk(chunk_id, chunk_buffer, inst)
	else:
		mm.buffer = PackedFloat32Array()
		_mirror_shadow_chunk(chunk_id, PackedFloat32Array(), 0)


func _apply_chunk_payload_direct(chunk_id: int, buffer: PackedFloat32Array, inst: int) -> void:
	var mm := _prepare_chunk_multimesh(chunk_id, inst)
	if inst > 0:
		mm.buffer = buffer
		_mirror_shadow_chunk(chunk_id, buffer, inst)
	else:
		mm.buffer = PackedFloat32Array()
		_mirror_shadow_chunk(chunk_id, PackedFloat32Array(), 0)


func _apply_chunked_native_full(buffer: PackedFloat32Array, cell_indices: PackedInt32Array, inst: int) -> void:
	_clear_chunk_nodes()
	_mmi.multimesh = null
	_multimesh = null
	var by_chunk := {}
	for i in range(inst):
		var chunk_id := _chunk_id_for_cell_idx(int(cell_indices[i]))
		if chunk_id < 0:
			continue
		var srcs: Array = by_chunk.get(chunk_id, [])
		srcs.append(i)
		by_chunk[chunk_id] = srcs
	for chunk_id in by_chunk.keys():
		var src_indices: Array = by_chunk[chunk_id]
		_apply_chunk_payload(int(chunk_id), buffer, src_indices, src_indices.size())
	_last_dirty_chunks = by_chunk.size()


func detail_chunk_plan_for_indices(indices: PackedInt32Array) -> Array:
	var dirty_chunks := {}
	for raw_idx in indices:
		var chunk_id := _chunk_id_for_cell_idx(int(raw_idx))
		if chunk_id < 0:
			continue
		dirty_chunks[chunk_id] = int(dirty_chunks.get(chunk_id, 0)) + 1
	var keys: Array = dirty_chunks.keys()
	keys.sort()
	var out: Array = []
	for chunk_id in keys:
		out.append({
			"chunk_id": int(chunk_id),
			"cell_indices": _cell_indices_for_chunk(int(chunk_id)),
			"dirty_cells": int(dirty_chunks[chunk_id]),
		})
	return out


func refresh_chunk_for_succession(chunk_id: int, chunk_cells: PackedInt32Array, dirty_cell_count: int = 0) -> bool:
	if _map == null or chunk_id < 0:
		return false
	if chunk_cells.is_empty():
		chunk_cells = _cell_indices_for_chunk(chunk_id)
	var t0_us := Time.get_ticks_usec()
	var payload := _encode_native_payload_for_indices(chunk_cells, 0)
	if not bool(payload.get("ok", false)):
		_last_rebuild_reason = str(payload.get("reason", "chunk_native_failed"))
		return false
	var res: Dictionary = payload.get("res", {})
	var inst := int(res.get("instance_count", 0))
	var buffer: PackedFloat32Array = res.get("buffer", PackedFloat32Array())
	var cell_indices: PackedInt32Array = res.get("cell_indices", PackedInt32Array())
	if inst > 0 and (buffer.size() < inst * 16 or cell_indices.size() < inst):
		_last_rebuild_reason = "chunk_native_bad_payload"
		return false
	var old_count := int(_chunk_instance_counts.get(chunk_id, 0))
	var apply_t0_us := Time.get_ticks_usec()
	_apply_chunk_payload_direct(chunk_id, buffer, inst)
	_last_native_apply_ms = float(Time.get_ticks_usec() - apply_t0_us) / 1000.0
	_instance_count = maxi(0, _instance_count - old_count + inst)
	_last_scatter_path = "gdext_event_chunk"
	_last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	_last_candidate_count = int(res.get("candidate_count", 0))
	_last_wrap_edge_copy_count = int(res.get("wrap_edge_copy_count", 0))
	_last_native_sampled_cells = int(res.get("sampled_cell_count", chunk_cells.size()))
	_last_native_active_cells = int(res.get("active_cell_count", 0))
	_last_rebuild_reason = "chunked_event_update"
	_last_incremental_cells = dirty_cell_count if dirty_cell_count > 0 else chunk_cells.size()
	_last_dirty_chunks = 1
	visible = _profile().enabled and _instance_count > 0
	# 分块：shadow chunk 已在 _apply_chunk_payload_direct 内镜像（O(该chunk)）
	return true


func _encode_native_payload_for_indices(indices: PackedInt32Array, instance_cap: int = 0) -> Dictionary:
	var t0_us := Time.get_ticks_usec()
	var out := {"ok": false, "valid_indices": PackedInt32Array(), "res": {}}
	if _world_ext == null or not _world_ext.has_method("encode_detail_scatter_delta"):
		out["reason"] = "missing_encode_detail_scatter_delta"
		return out
	if _map == null:
		out["reason"] = "map_null"
		return out
	if _native_delta_common_knobs.is_empty():
		_native_delta_common_knobs = _build_native_delta_common_knobs()
	if _native_delta_common_knobs.is_empty():
		out["reason"] = "bad_native_common_knobs"
		return out
	var knobs := _native_delta_common_knobs.duplicate(false)
	knobs["sample_cell_indices"] = indices
	knobs["instance_cap"] = instance_cap
	_last_native_knobs_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	var native_t0_us := Time.get_ticks_usec()
	var res = _world_ext.call("encode_detail_scatter_delta", knobs)
	_last_native_call_ms = float(Time.get_ticks_usec() - native_t0_us) / 1000.0
	if not (res is Dictionary):
		out["reason"] = "bad_native_result"
		return out
	if bool(res.get("fallback", true)):
		out["reason"] = str(res.get("reason", "native_delta_fallback"))
		out["res"] = res
		return out
	out["ok"] = true
	out["valid_indices"] = res.get("valid_indices", indices)
	out["res"] = res
	return out


func _refresh_chunked_for_succession(indices: PackedInt32Array) -> bool:
	if _map == null or indices.is_empty():
		return false
	var dirty_chunks := {}
	for raw_idx in indices:
		var chunk_id := _chunk_id_for_cell_idx(int(raw_idx))
		if chunk_id >= 0:
			dirty_chunks[chunk_id] = true
	if dirty_chunks.is_empty():
		return false
	var t0_us := Time.get_ticks_usec()
	var chunk_count := 0
	var total_inst := 0
	var total_candidates := 0
	var total_wrap := 0
	var total_sampled := 0
	var total_active := 0
	for chunk_id in dirty_chunks.keys():
		var chunk_cells := _cell_indices_for_chunk(int(chunk_id))
		var payload := _encode_native_payload_for_indices(chunk_cells, 0)
		if not bool(payload.get("ok", false)):
			_last_rebuild_reason = str(payload.get("reason", "chunk_native_failed"))
			return false
		var res: Dictionary = payload.get("res", {})
		var inst := int(res.get("instance_count", 0))
		var buffer: PackedFloat32Array = res.get("buffer", PackedFloat32Array())
		var cell_indices: PackedInt32Array = res.get("cell_indices", PackedInt32Array())
		if inst > 0 and (buffer.size() < inst * 16 or cell_indices.size() < inst):
			_last_rebuild_reason = "chunk_native_bad_payload"
			return false
		var srcs: Array = []
		for i in range(inst):
			srcs.append(i)
		_apply_chunk_payload(int(chunk_id), buffer, srcs, inst)
		total_inst += inst
		total_candidates += int(res.get("candidate_count", 0))
		total_wrap += int(res.get("wrap_edge_copy_count", 0))
		total_sampled += int(res.get("sampled_cell_count", chunk_cells.size()))
		total_active += int(res.get("active_cell_count", 0))
		chunk_count += 1
	_instance_count = 0
	for v in _chunk_instance_counts.values():
		_instance_count += int(v)
	_last_scatter_path = "gdext_event_chunk"
	_last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	_last_candidate_count = total_candidates
	_last_wrap_edge_copy_count = total_wrap
	_last_native_sampled_cells = total_sampled
	_last_native_active_cells = total_active
	_last_rebuild_reason = "chunked_event_update"
	_last_incremental_cells = indices.size()
	_last_dirty_chunks = chunk_count
	visible = _profile().enabled and _instance_count > 0
	# 分块：各脏 chunk 的 shadow 已在 _apply_chunk_payload 内镜像（O(脏chunk)）
	return true


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
	_material.set_shader_parameter("aquatic_response", 1.0 if _spawn_domain() == SPAWN_WATER else 0.0)
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

	# [veg-normal-shading] 法线辅助着色 uniform + 性能分档（q2 才采高度图邻域算谷地 AO）。
	var tier := _active_quality_tier()
	var shading_on: bool = bool(cfg.get("shading_enabled")) if cfg.get("shading_enabled") != null else true
	_material.set_shader_parameter("shading_enabled", 1.0 if shading_on else 0.0)
	_material.set_shader_parameter("veg_shade_quality", tier)
	_material.set_shader_parameter("terrain_normal_influence", _profile_float(&"terrain_normal_influence", 0.65))
	_material.set_shader_parameter("pseudo_normal_strength", _profile_float(&"pseudo_normal_strength", 0.85))
	_material.set_shader_parameter("sun_shade_strength", _profile_float(&"sun_shade_strength", 0.55))
	_material.set_shader_parameter("ambient_floor", _profile_float(&"ambient_floor", 0.18))
	_material.set_shader_parameter("rim_light_strength", _profile_float(&"rim_light_strength", 0.12))
	_material.set_shader_parameter("contact_ao_strength", _profile_float(&"contact_ao_strength", 0.42))
	_material.set_shader_parameter("contact_ao_height", _profile_float(&"contact_ao_height", 0.32))
	_material.set_shader_parameter("terrain_valley_ao_strength", _profile_float(&"terrain_valley_ao_strength", 0.40))
	_material.set_shader_parameter("terrain_valley_ao_gain", _profile_float(&"terrain_valley_ao_gain", 6.0))

	# [veg-cast-shadow] 投影 pass 外观/淡出 uniform（与植株共享活力/积雪阈值，保证一致淡出）。
	if _shadow_material != null:
		var sc = cfg.get("shadow_color")
		_shadow_material.set_shader_parameter("shadow_color", sc if sc is Color else Color(0.05, 0.06, 0.08, 1.0))
		_shadow_material.set_shader_parameter("shadow_strength", _profile_float(&"shadow_strength", 0.28))
		_shadow_material.set_shader_parameter("shadow_length_scale", _profile_float(&"shadow_length_scale", 1.0))
		_shadow_material.set_shader_parameter("shadow_max_len", _profile_float(&"shadow_max_length", 1.4))
		_shadow_material.set_shader_parameter("shadow_min_sun_elevation", _profile_float(&"shadow_min_sun_elevation", 0.16))
		_shadow_material.set_shader_parameter("shadow_foot_radius", _profile_float(&"shadow_foot_radius", 0.55))
		_shadow_material.set_shader_parameter("shadow_edge_softness", _profile_float(&"shadow_edge_softness", 0.25))
		_shadow_material.set_shader_parameter("vitality_dead_threshold", cfg.vitality_dead_threshold)
		_shadow_material.set_shader_parameter("vitality_healthy_threshold", cfg.vitality_healthy_threshold)
		_shadow_material.set_shader_parameter("vitality_alpha_power", cfg.vitality_alpha_power)
		_shadow_material.set_shader_parameter("snow_hide_strength", cfg.snow_hide_strength)
		_shadow_material.set_shader_parameter("aquatic_response", 1.0 if _spawn_domain() == SPAWN_WATER else 0.0)
	_sync_shadow_layer(true)


func _sync_world_material_inputs(_use_cell_indirection: bool) -> void:
	if _material == null:
		return
	var bounds := _bounds
	var wrap_period := HexUtils.wrap_period_x(_map.width, _hex_size) if _map != null else 0.0
	_material.set_shader_parameter("world_origin", bounds.position)
	_material.set_shader_parameter("world_size", bounds.size)
	_material.set_shader_parameter("wrap_origin_x", 0.0)
	_material.set_shader_parameter("wrap_period_x", wrap_period)
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("world_origin", bounds.position)
		_shadow_material.set_shader_parameter("world_size", bounds.size)
		_shadow_material.set_shader_parameter("wrap_origin_x", 0.0)
		_shadow_material.set_shader_parameter("wrap_period_x", wrap_period)
	if _world == null:
		_material.set_shader_parameter("lut_dims", Vector2.ONE)
		if _shadow_material != null:
			_shadow_material.set_shader_parameter("lut_dims", Vector2.ONE)
		return
	_material.set_shader_parameter("map_index_atlas", _world.enum_atlas_tex)
	_material.set_shader_parameter("dyn_lut", _world.dyn_lut_tex)
	_material.set_shader_parameter("eco_lut", _world.eco_lut_tex)
	_material.set_shader_parameter("lut_dims", Vector2(_world.lut_dims.x, _world.lut_dims.y))
	# [veg-normal-shading] 地形宏观法线 + 高度图（与地形 brdf 同源数据），植被 shader 用于 NdotL/谷地 AO。
	_material.set_shader_parameter("terrain_normal_tex", _world.terrain_normal_tex)
	_material.set_shader_parameter("terrain_normal_tex_bound", _world.terrain_normal_tex != null)
	_material.set_shader_parameter("height_tex", _world.height_tex)
	_material.set_shader_parameter("hm_resolution", Vector2(_world.hm_size.x, _world.hm_size.y))
	_material.set_shader_parameter("terrain_horizon_tex", _world.terrain_horizon_tex)
	_material.set_shader_parameter("terrain_horizon_tex_bound", _world.terrain_horizon_tex != null)
	# [veg-cast-shadow] 投影 pass 需要 cell 索引/动态态做夜侧与枯死/积雪淡出。
	if _shadow_material != null:
		_shadow_material.set_shader_parameter("map_index_atlas", _world.enum_atlas_tex)
		_shadow_material.set_shader_parameter("dyn_lut", _world.dyn_lut_tex)
		_shadow_material.set_shader_parameter("lut_dims", Vector2(_world.lut_dims.x, _world.lut_dims.y))


func _rebuild_instances() -> void:
	_ensure_resources()
	var t0_us := Time.get_ticks_usec()
	_last_candidate_count = 0
	_last_wrap_edge_copy_count = 0
	_last_rebuild_reason = ""
	_last_incremental_cells = 0
	_last_incremental_missing_slots = 0
	_last_incremental_dropped_instances = 0
	_last_dirty_chunks = 0
	_last_native_sampled_cells = 0
	_last_native_active_cells = 0
	clear()
	var cfg := _profile()
	if not cfg.enabled or _map == null or _map.cell_count() <= 0:
		_last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		return

	var cells: Array = _map.iter_cells()
	if cells.is_empty():
		cells = _map.all_cells()
	if cells.is_empty():
		_last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		_last_rebuild_reason = "no_cells"
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
		_last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		_last_rebuild_reason = "no_attempts"
		return

	# C++ 优先：把"每实例候选生成 + 噪声门 + 接受 + cap + MultiMesh buffer 组装"
	# 整段热循环下沉 DCWorldExt.encode_detail_scatter，GDScript 仅做上面这段
	# per-cell（N≤2400）廉价预计算。失败 / 旧 DLL 无该方法时回退到下方 GDScript 路径。
	if _rebuild_via_native(cells, cell_states, cell_suitabilities, cell_attempts):
		if _last_scatter_path.is_empty():
			_last_scatter_path = "gdext"
		_last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		_rebuild_cell_instance_lookup()
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
	_append_wrap_edge_instances()
	_instance_count = _instance_cell_indices.size()
	_rebuild_cell_instance_lookup()
	if _instance_count <= 0:
		_last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		_last_rebuild_reason = "no_instances"
		return

	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_multimesh.use_colors = true
	_multimesh.use_custom_data = true
	_multimesh.mesh = _cached_detail_mesh()
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
	_sync_shadow_layer(true)
	_last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	_last_candidate_count = _instance_scores.size()


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
	var native_cell_indices := PackedInt32Array()
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
		if _scatter_presence(state) <= 0.02:
			continue
		var veg := int(state.get("vegetation", VegetationType.VEG.NONE))
		var lf := int(state.get("landform", LandformType.LF.PLAIN))
		var cover := int(state.get("cover", CoverType.CV.NONE))
		var center := _cell_center(cell, idx)
		var base := _base_color_for_vegetation(veg)
		keys.append(_cell_hash_key(cell, order))
		native_cell_indices.append(idx)
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
		"wrap_period_x": HexUtils.wrap_period_x(grid_w, _hex_size),
		"wrap_edge_margin": _hex_size * 4.0,
		"grid_w": grid_w,
		"grid_h": grid_h,
		"offset_is_water": offset_is_water,
		"flow_buffer": _world.flow_buffer if _world != null else PackedFloat32Array(),
		"flow_w": int(_world.derived_size.x) if _world != null else 0,
		"flow_h": int(_world.derived_size.y) if _world != null else 0,
		"river_clear_threshold": cfg.river_clear_threshold,
		"spawn_domain": _spawn_domain(),
		"rotation_mode": _rotation_mode(),
		"random_rotation_strength": _random_rotation_strength(),
		"upright_jitter_radians": deg_to_rad(_upright_jitter_degrees()),
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
		"cell_indices": native_cell_indices,
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
		_last_rebuild_reason = str(res.get("reason", "native_fallback"))
		return false
	_last_candidate_count = int(res.get("candidate_count", 0))
	_last_wrap_edge_copy_count = int(res.get("wrap_edge_copy_count", 0))
	var buffer: PackedFloat32Array = res.get("buffer", PackedFloat32Array())
	var inst: int = int(res.get("instance_count", 0))
	var cell_indices: PackedInt32Array = res.get("cell_indices", PackedInt32Array())
	# 每实例 stride = transform2d(8) + color(4) + custom(4) = 16 float。
	if inst <= 0 or buffer.size() < inst * 16:
		clear()
		_last_rebuild_reason = "native_empty"
		return true
	if cell_indices.size() < inst:
		_last_rebuild_reason = "native_missing_cell_indices"
		return false

	if _chunked_multimesh_enabled:
		_instance_count = inst
		_instance_cell_indices = cell_indices
		visible = cfg.enabled and inst > 0  # 先定 visible，使 _apply_chunk_payload 内的 shadow 镜像取到正确可见性
		_apply_chunked_native_full(buffer, cell_indices, inst)
		# shadow chunk 已随每个 _apply_chunk_payload 镜像完成（_clear_chunk_nodes 已清旧，无孤儿）
		_last_scatter_path = "gdext_chunked"
		return true

	_instance_count = inst
	_instance_cell_indices = cell_indices
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_2D
	_multimesh.use_colors = true
	_multimesh.use_custom_data = true
	_multimesh.mesh = _cached_detail_mesh()
	_multimesh.instance_count = inst
	_multimesh.buffer = buffer
	_multimesh.visible_instance_count = inst
	_mmi.multimesh = _multimesh
	visible = cfg.enabled and inst > 0
	_sync_shadow_layer(true)
	return true


func _cell_suitability(cell, idx: int, _key: int, state: Dictionary) -> float:
	var cell_is_water := _is_water_cell(cell, idx)
	var domain := _spawn_domain()
	if domain == SPAWN_LAND and cell_is_water:
		return 0.0
	if domain == SPAWN_WATER and not cell_is_water:
		return 0.0

	var lf := int(state.get("landform", LandformType.LF.PLAIN))
	var veg := int(state.get("vegetation", VegetationType.VEG.NONE))
	var cover := int(state.get("cover", CoverType.CV.NONE))
	var river := _has_river_cell(cell, idx)
	var arch := _detail_kind()

	if cell_is_water:
		return _aquatic_suitability(arch, lf, veg, cover, state)

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
	suitability *= lerpf(0.08, 1.0, _scatter_presence(state))
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


func _aquatic_suitability(_arch: int, lf: int, veg: int, cover: int, state: Dictionary) -> float:
	if _spawn_domain() != SPAWN_WATER:
		return 0.0
	if cover == CoverType.CV.SEA_ICE or cover == CoverType.CV.GLACIER:
		return 0.0
	var landform_weight := _landform_weight(lf)
	var vegetation_weight := _vegetation_weight(veg)
	var cover_weight := _cover_weight(cover)
	if landform_weight <= 0.0 or vegetation_weight <= 0.0 or cover_weight <= 0.0:
		return 0.0
	var temp := float(state.get("temp", 0.5))
	var moisture := float(state.get("moisture", 0.5))
	var suitability := vegetation_weight * landform_weight * cover_weight
	# 水域生态不使用陆地 vegetation_vitality 做密度闸门；由温度/水体类型和 profile 权重决定。
	suitability *= lerpf(0.74, 1.15, clampf(moisture, 0.0, 1.0))
	suitability *= lerpf(0.70, 1.05, VegetationType.climate_compat_score(veg, temp, moisture))
	suitability *= _quality_density_scale()
	return clampf(suitability, 0.0, 1.25)


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
	var climate_presence := _scatter_presence(state)
	if climate_presence <= 0.02:
		return
	var vitality := clampf(float(state.get("vitality", 0.7)), 0.0, 1.0)
	if vitality <= cfg.vitality_dead_threshold:
		var dieback_noise := _hash01(key, 931 + attempt)
		if dieback_noise < 1.0 - cfg.vitality_dieback_noise_strength:
			return
	var center := _cell_center(cell, idx)
	var pos := _candidate_position(center, key, attempt)
	var domain := _spawn_domain()
	var candidate_is_water := _is_water_position(pos, cell, idx)
	if domain == SPAWN_LAND and candidate_is_water:
		return
	if domain == SPAWN_WATER and not candidate_is_water:
		return
	if domain != SPAWN_WATER and _is_river_body_position(pos):
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
	_instance_rotations.append(_instance_rotation(key, attempt))
	_instance_sizes.append(size)
	_instance_seeds.append(_hash01(key, 600 + attempt))
	_instance_variants.append(variant)
	_instance_scores.append(world_noise * 0.66 + cell_suitability * 0.27 + _hash01(key, 7600 + attempt) * 0.07)


func _append_wrap_edge_instances() -> void:
	if _map == null:
		return
	var period_x := HexUtils.wrap_period_x(_map.width, _hex_size)
	if period_x <= 0.0001:
		return
	var margin := _hex_size * 4.0
	var original_count := _instance_positions.size()
	for i in range(original_count):
		var pos := _instance_positions[i]
		var offsets := PackedFloat32Array()
		if pos.x <= margin:
			offsets.append(period_x)
		if pos.x >= period_x - margin:
			offsets.append(-period_x)
		for ox in offsets:
			_instance_cell_indices.append(_instance_cell_indices[i])
			_instance_cells.append(_instance_cells[i])
			_instance_positions.append(pos + Vector2(float(ox), 0.0))
			_instance_rotations.append(_instance_rotations[i])
			_instance_sizes.append(_instance_sizes[i])
			_instance_seeds.append(_instance_seeds[i])
			_instance_variants.append(_instance_variants[i])
			_instance_scores.append(_instance_scores[i])


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


func _instance_rotation(key: int, attempt: int) -> float:
	var full := _hash01(key, 500 + attempt) * TAU
	match _rotation_mode():
		ROT_UPRIGHT:
			return 0.0
		ROT_UPRIGHT_JITTER:
			return (_hash01(key, 501 + attempt) * 2.0 - 1.0) * deg_to_rad(_upright_jitter_degrees())
	var strength := _random_rotation_strength()
	if strength >= 0.999:
		return full
	return (_hash01(key, 501 + attempt) * 2.0 - 1.0) * PI * strength


func _cached_detail_mesh() -> ArrayMesh:
	var key := "%d:%d" % [_detail_kind(), _quality_lobe_count()]
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var mesh := _build_shrub_mesh()
	_mesh_cache[key] = mesh
	return mesh


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
	_add_lobe(verts, uvs, colors, indices, Vector2(0.0, 0.22), 0.62, 0.18, Color(0.18, 0.30, 0.16, 0.62))
	var lobes := [
		[Vector2(-0.36, -0.04), 0.34, 0.30, Color(0.38, 0.62, 0.34, 0.96)],
		[Vector2(0.00, -0.18), 0.40, 0.34, Color(0.52, 0.76, 0.42, 1.0)],
		[Vector2(0.38, -0.04), 0.34, 0.30, Color(0.32, 0.55, 0.30, 0.96)],
		[Vector2(-0.10, 0.12), 0.38, 0.24, Color(0.24, 0.44, 0.24, 0.92)],
		[Vector2(-0.52, -0.22), 0.24, 0.22, Color(0.56, 0.78, 0.44, 0.94)],
		[Vector2(0.52, -0.22), 0.24, 0.22, Color(0.46, 0.70, 0.38, 0.94)],
		[Vector2(0.18, 0.14), 0.28, 0.20, Color(0.20, 0.38, 0.22, 0.88)],
		[Vector2(0.00, -0.42), 0.26, 0.20, Color(0.66, 0.84, 0.50, 0.92)],
	]
	var lobe_count := mini(_quality_lobe_count(), lobes.size())
	for i in range(lobe_count):
		var lobe: Array = lobes[i]
		_add_lobe(verts, uvs, colors, indices, lobe[0], lobe[1], lobe[2], lobe[3])
	return _finish_mesh(verts, uvs, colors, indices)


func _build_grass_mesh() -> ArrayMesh:
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var mats := [
		[Vector2(-0.24, 0.18), 0.38, 0.16, Color(0.44, 0.70, 0.30, 0.78)],
		[Vector2(0.18, 0.12), 0.42, 0.18, Color(0.58, 0.82, 0.36, 0.78)],
		[Vector2(0.02, -0.04), 0.34, 0.15, Color(0.36, 0.64, 0.28, 0.72)],
	]
	for mat in mats:
		var mat_data: Array = mat
		_add_lobe(verts, uvs, colors, indices, mat_data[0], mat_data[1], mat_data[2], mat_data[3])
	var blades := [
		[Vector2(-0.44, 0.26), 0.06, 0.38, Color(0.62, 0.84, 0.38, 0.80)],
		[Vector2(-0.22, 0.20), 0.055, 0.34, Color(0.42, 0.72, 0.30, 0.76)],
		[Vector2(0.00, 0.24), 0.065, 0.42, Color(0.70, 0.88, 0.42, 0.78)],
		[Vector2(0.22, 0.18), 0.052, 0.32, Color(0.36, 0.66, 0.26, 0.74)],
		[Vector2(0.44, 0.25), 0.06, 0.36, Color(0.56, 0.78, 0.34, 0.74)],
	]
	var blade_count := mini(_quality_lobe_count(), blades.size())
	for i in range(blade_count):
		var blade: Array = blades[i]
		_add_blade(verts, uvs, colors, indices, blade[0], blade[1], blade[2], blade[3])
	return _finish_mesh(verts, uvs, colors, indices)


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
	_add_lobe(v, u, c, idx, Vector2(0.0, 0.28), 0.56, 0.14, Color(0.12, 0.24, 0.18, 0.60))
	var trees := [
		[Vector2(-0.34, 0.24), 0.34, 0.44, Color(0.56, 0.78, 0.58, 0.96)],
		[Vector2(0.00, 0.18), 0.42, 0.58, Color(0.72, 0.90, 0.70, 1.0)],
		[Vector2(0.34, 0.26), 0.32, 0.42, Color(0.44, 0.66, 0.48, 0.94)],
		[Vector2(-0.16, -0.06), 0.28, 0.40, Color(0.82, 0.96, 0.78, 0.96)],
		[Vector2(0.22, -0.08), 0.26, 0.36, Color(0.64, 0.84, 0.62, 0.94)],
	]
	var tree_count := mini(_quality_lobe_count(), trees.size())
	for i in range(tree_count):
		var tree: Array = trees[i]
		var base: Vector2 = tree[0]
		var half_w := float(tree[1])
		var height := float(tree[2])
		var tint: Color = tree[3]
		_add_tri(v, u, c, idx, base + Vector2(0.0, -height), base + Vector2(-half_w, 0.0), base + Vector2(half_w, 0.0), tint)
		_add_tri(v, u, c, idx, base + Vector2(0.0, -height * 0.70), base + Vector2(-half_w * 0.72, height * 0.18), base + Vector2(half_w * 0.72, height * 0.18), tint.lightened(0.08))
	return _finish_mesh(v, u, c, idx)


func _build_palm_mesh() -> ArrayMesh:
	var v := PackedVector2Array(); var u := PackedVector2Array()
	var c := PackedColorArray(); var idx := PackedInt32Array()
	_add_lobe(v, u, c, idx, Vector2(0.0, 0.24), 0.58, 0.14, Color(0.18, 0.30, 0.14, 0.54))
	var palms := [
		[Vector2(-0.32, 0.20), 0.44, Color(0.74, 0.90, 0.56, 0.96)],
		[Vector2(0.04, 0.12), 0.52, Color(0.88, 0.98, 0.66, 1.0)],
		[Vector2(0.34, 0.24), 0.40, Color(0.64, 0.82, 0.50, 0.94)],
	]
	for palm in palms:
		var palm_data: Array = palm
		var base: Vector2 = palm_data[0]
		var height := float(palm_data[1])
		var tint: Color = palm_data[2]
		var top := base + Vector2(0.0, -height)
		_add_lobe(v, u, c, idx, base + Vector2(0.02, -height * 0.35), 0.045, height * 0.42, Color(0.46, 0.34, 0.22, 0.92))
		var fronds := [
			Vector2(-0.24, -0.02),
			Vector2(-0.12, -0.20),
			Vector2(0.10, -0.22),
			Vector2(0.26, -0.04),
		]
		for tip_offset in fronds:
			var tip_offset_vec: Vector2 = tip_offset
			var tip := top + tip_offset_vec
			var perp := Vector2(-(tip.y - top.y), tip.x - top.x).normalized() * 0.045
			_add_tri(v, u, c, idx, top + perp, top - perp, tip, tint)
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
	var cfg := _profile()
	if bool(cfg.get("base_color_override_enabled")):
		return cfg.get("base_color_override")
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


func _profile_weight_override(prop: StringName, key: int, fallback: float) -> float:
	var cfg := _profile()
	var raw = cfg.get(prop)
	if not (raw is Dictionary):
		return fallback
	var dict: Dictionary = raw
	if dict.has(key):
		return float(dict[key])
	var key_str := str(key)
	if dict.has(key_str):
		return float(dict[key_str])
	return fallback


func _vegetation_weight(veg: int) -> float:
	var base := 0.0
	match _detail_kind():
		DETAIL_TREE:
			base = _tree_vegetation_weight(veg)
			return _profile_weight_override(&"vegetation_weight_overrides", veg, base)
		DETAIL_GRASS:
			base = _grass_vegetation_weight(veg)
			return _profile_weight_override(&"vegetation_weight_overrides", veg, base)
	match veg:
		VegetationType.VEG.BOREAL_SHRUB, VegetationType.VEG.MEDITERRANEAN_SHRUB:
			base = 1.15
		VegetationType.VEG.DESERT_SCRUB:
			base = 0.78
		VegetationType.VEG.TAIGA, VegetationType.VEG.TROPICAL_DRY_FOREST:
			base = 0.92
		VegetationType.VEG.TEMPERATE_DECIDUOUS, VegetationType.VEG.TEMPERATE_CONIFER:
			base = 0.84
		VegetationType.VEG.TROPICAL_RAINFOREST, VegetationType.VEG.SUBTROPICAL_FOREST:
			base = 0.70
		VegetationType.VEG.TUNDRA, VegetationType.VEG.ALPINE_TUNDRA:
			base = 0.42
		VegetationType.VEG.SAVANNA:
			base = 0.62
		VegetationType.VEG.TEMPERATE_STEPPE:
			base = 0.46
		VegetationType.VEG.SWAMP:
			base = 0.56
		VegetationType.VEG.MARSH:
			base = 0.34
		VegetationType.VEG.TEMPERATE_GRASSLAND:
			base = 0.36
		VegetationType.VEG.OASIS_VEG:
			base = 0.58
		VegetationType.VEG.XERIC_DESERT, VegetationType.VEG.POLAR_DESERT:
			base = 0.02
		VegetationType.VEG.NONE, VegetationType.VEG.KELP_FOREST, VegetationType.VEG.CORAL_REEF:
			base = 0.0
		_:
			base = 0.10
	return _profile_weight_override(&"vegetation_weight_overrides", veg, base)


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
	var base := 0.0
	match _detail_kind():
		DETAIL_TREE:
			base = _tree_landform_weight(lf)
			return _profile_weight_override(&"landform_weight_overrides", lf, base)
		DETAIL_GRASS:
			base = _grass_landform_weight(lf)
			return _profile_weight_override(&"landform_weight_overrides", lf, base)
	match lf:
		LandformType.LF.PLAIN, LandformType.LF.LOWLAND:
			base = 1.0
		LandformType.LF.HILL:
			base = 0.84
		LandformType.LF.DELTA:
			base = 0.64
		LandformType.LF.BADLANDS:
			base = 0.42
		LandformType.LF.SALT_FLAT:
			base = 0.06
		LandformType.LF.MOUNTAIN:
			base = 0.14
		LandformType.LF.PEAK, LandformType.LF.VOLCANO:
			base = 0.0
		_:
			base = 0.0 if LandformType.is_water(lf) else 0.55
	return _profile_weight_override(&"landform_weight_overrides", lf, base)


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
	var base := 1.0
	match cover:
		CoverType.CV.GLACIER, CoverType.CV.SEA_ICE, CoverType.CV.PELAGIC_BLOOM:
			base = 0.0
		CoverType.CV.FLOODING:
			base = 0.18
		CoverType.CV.SNOW:
			base = 0.48
		CoverType.CV.PERMAFROST:
			base = 0.62
		_:
			base = 1.0
	return _profile_weight_override(&"cover_weight_overrides", cover, base)


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


func _scatter_presence(state: Dictionary) -> float:
	if _spawn_domain() == SPAWN_WATER:
		var cover := int(state.get("cover", CoverType.CV.NONE))
		if cover == CoverType.CV.SEA_ICE or cover == CoverType.CV.GLACIER:
			return 0.0
		return 1.0
	return _climate_presence(state)


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
	var cell = HexUtils.world_to_wrapped_cell(_map, world_pos, _hex_size)
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


func _profile_int(prop: StringName, fallback: int) -> int:
	var v = _profile().get(prop)
	return fallback if v == null else int(v)


func _profile_float(prop: StringName, fallback: float) -> float:
	var v = _profile().get(prop)
	return fallback if v == null else float(v)


func _spawn_domain() -> int:
	return clampi(_profile_int(&"spawn_domain", SPAWN_LAND), SPAWN_LAND, SPAWN_ANY)


func _rotation_mode() -> int:
	return clampi(_profile_int(&"rotation_mode", ROT_RANDOM_FULL), ROT_RANDOM_FULL, ROT_UPRIGHT_JITTER)


func _random_rotation_strength() -> float:
	return clampf(_profile_float(&"random_rotation_strength", 1.0), 0.0, 1.0)


func _upright_jitter_degrees() -> float:
	return clampf(_profile_float(&"upright_jitter_degrees", 6.0), 0.0, 35.0)


func get_scatter_diagnostics() -> Dictionary:
	return {
		"name": name,
		"path": _last_scatter_path,
		"instances": _instance_count,
		"candidates": _last_candidate_count,
		"wrap_edge_copies": _last_wrap_edge_copy_count,
		"rebuild_ms": _last_rebuild_ms,
		"reason": _last_rebuild_reason,
		"incremental_cells": _last_incremental_cells,
		"dirty_chunks": _last_dirty_chunks,
		"native_sampled_cells": _last_native_sampled_cells,
		"native_active_cells": _last_native_active_cells,
		"native_water_cache_ms": _last_native_water_cache_ms,
		"native_context_ms": _last_native_context_ms,
		"native_knobs_ms": _last_native_knobs_ms,
		"native_call_ms": _last_native_call_ms,
		"native_apply_ms": _last_native_apply_ms,
		"chunked": _chunked_multimesh_enabled,
		"chunk_size_cells": _chunk_size_cells,
		"missing_slots": _last_incremental_missing_slots,
		"dropped_instances": _last_incremental_dropped_instances,
		"spawn_domain": _spawn_domain(),
		"detail_kind": _detail_kind(),
	}


func _world_uv(world_pos: Vector2) -> Vector2:
	var size := _bounds.size
	if size.x <= 0.001 or size.y <= 0.001:
		return Vector2.ZERO
	var period_x := HexUtils.wrap_period_x(_map.width, _hex_size) if _map != null else 0.0
	var sample_x := world_pos.x
	if period_x > 0.0001:
		sample_x = fposmod(sample_x, period_x)
	return Vector2(
		clampf((sample_x - _bounds.position.x) / size.x, 0.0, 1.0),
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
