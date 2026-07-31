shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D eco_lut : filter_nearest, repeat_disable;

uniform vec2 lut_dims = vec2(1.0, 1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
#define VT_USE_MAP_INDEX
#define VT_USE_HEIGHT
#define VT_USE_TERRAIN_NORMAL
#define VT_USE_HORIZON
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"

uniform float world_time = 0.0;
uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float wind_strength = 1.0;
uniform float dry_yellow_strength = 0.82;
uniform float wet_green_strength = 0.48;
uniform float lush_green_strength = 0.72;
uniform float heat_red_strength = 0.55;
uniform float autumn_red_strength = 0.42;
uniform float temperature_color_strength = 0.78;
uniform float moisture_color_strength = 0.82;
uniform float snow_white_strength = 0.90;
uniform float stress_hide_strength = 0.78;
uniform float snow_hide_strength = 0.62;
uniform float disappear_alpha_threshold = 0.08;
uniform float lod_alpha = 1.0;
uniform bool lod_debug_view = false;
uniform float vitality_dead_threshold = 0.12;
uniform float vitality_healthy_threshold = 0.72;
uniform float vitality_alpha_power = 1.10;
uniform float vitality_size_min = 0.34;
uniform float vitality_size_max = 1.08;
uniform float vitality_low_color_strength = 0.72;
uniform float vitality_high_color_strength = 0.42;
uniform float vitality_color_contrast = 0.90;
uniform float aquatic_response = 0.0;
// 0 = 点缀/地貌类 archetype（岩石/雪堆/枯立木），抑制植被气候改色；1 = 植被类。
uniform float veg_response = 1.0;
uniform float phenology_response = 1.0;
uniform float phenology_color_dominance = 0.64;
uniform float albedo_light_floor = 0.38;
uniform float color_saturation_gain = 1.0;
uniform float color_value_gain = 1.0;
uniform float snow_body_color_retention = 0.0;
uniform float snow_alpha_loss_strength = 0.32;
uniform float snow_size_floor = 0.0;       // 乔木满雪时的形体下限；草本保持 0
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
uniform bool terrain_normal_tex_bound = false;  // 未烘焙时只用伪法线（退化）
uniform vec2 hm_resolution = vec2(2048.0, 1536.0);
uniform int veg_shade_quality = 2;            // 0/1/2：q2 才采高度图邻域算谷地 AO
// [terrain-horizon 2026-07-03] 与地形同源的 8 方向 horizon shadow。同级性能档位：veg_shade_quality>=1 才采样。
uniform bool terrain_horizon_tex_bound = false;
uniform float terrain_horizon_max_angle = 1.309;
uniform float terrain_horizon_softness = 0.16;
uniform float terrain_horizon_strength = 0.70;
uniform float terrain_horizon_cast_floor = 0.82;
uniform int terrain_horizon_debug_view = 0;
// [terrain-gi 2026-07-31] 与地形共用的天空可见度 GI。植被必须跟地形用同一份 horizon
// 与同一个 LUT，否则谷底灌木会比脚下地面亮一截、"浮"在阴影上。
// gi_horizon_lut[n] = vec3(cos²(h_n), cos(m_n), sin(m_n))，由 HexRenderer 预计算推送。
uniform bool gi_lut_bound = false;
uniform vec3 gi_horizon_lut[16];
uniform float gi_ao_strength : hint_range(0.0, 1.0) = 0.85;
uniform float gi_ao_floor : hint_range(0.0, 1.0) = 0.45;
uniform float gi_bent_strength : hint_range(0.0, 1.0) = 0.35;
uniform float gi_normal_floor : hint_range(0.0, 1.0) = 0.85;
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
	vec2 rg = visual_sample_height(uv).rg;
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
	vec2 dims = visual_static_texture_size();
	vec2 p = shrub_wrap_map_uv(uv) * dims - vec2(0.5);
	vec2 b = floor(p);
	vec2 f = fract(p);
	vec2 inv_dims = 1.0 / max(dims, vec2(1.0));
	vec2 uv00 = shrub_wrap_map_uv((b + vec2(0.5, 0.5)) * inv_dims);
	vec2 uv10 = shrub_wrap_map_uv((b + vec2(1.5, 0.5)) * inv_dims);
	vec2 uv01 = shrub_wrap_map_uv((b + vec2(0.5, 1.5)) * inv_dims);
	vec2 uv11 = shrub_wrap_map_uv((b + vec2(1.5, 1.5)) * inv_dims);
	float h00 = shrub_horizon_angle_from_packed(visual_sample_horizon(uv00), sector);
	float h10 = shrub_horizon_angle_from_packed(visual_sample_horizon(uv10), sector);
	float h01 = shrub_horizon_angle_from_packed(visual_sample_horizon(uv01), sector);
	float h11 = shrub_horizon_angle_from_packed(visual_sample_horizon(uv11), sector);
	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

float shrub_horizon_direct_visibility(vec2 uv, vec3 light_dir) {
#ifdef PK_SKIP_HORIZON_SHADOWS
	return 1.0;
#else
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
#endif
}

// [terrain-gi 2026-07-31] 天空可见度 + bent normal。与地形侧 terrain_horizon.gdshaderinc 同一
// 公式（V_sky = 1/8·Σ cos²h_d），但只取最近的 1 tap 而非 4 tap 双线性：AO 是低频量，而植被是
// 每株成千上万次片元调用，双线性带来的额外 3 次 fetch 在这里换不到可见收益。
const float SHRUB_GI_INV_SQRT2 = 0.70710678;
const vec2 SHRUB_GI_DIRECTIONS[8] = vec2[8](
	vec2(1.0, 0.0), vec2(SHRUB_GI_INV_SQRT2, SHRUB_GI_INV_SQRT2),
	vec2(0.0, 1.0), vec2(-SHRUB_GI_INV_SQRT2, SHRUB_GI_INV_SQRT2),
	vec2(-1.0, 0.0), vec2(-SHRUB_GI_INV_SQRT2, -SHRUB_GI_INV_SQRT2),
	vec2(0.0, -1.0), vec2(SHRUB_GI_INV_SQRT2, -SHRUB_GI_INV_SQRT2)
);

struct ShrubSkySample {
	float visibility;
	vec3 bent_normal;
};

ShrubSkySample shrub_sample_sky(vec2 uv) {
	ShrubSkySample s;
	s.visibility = 1.0;
	s.bent_normal = vec3(0.0, 0.0, 1.0);
#ifdef PK_SKIP_HORIZON_SHADOWS
	return s;
#else
	if (!terrain_horizon_tex_bound || !gi_lut_bound || veg_shade_quality < 1) return s;
	vec4 packed = visual_sample_horizon(shrub_wrap_map_uv(uv));
	vec4 bytes = floor(packed * 255.0 + 0.5);
	vec4 hi = floor(bytes * 0.0625);
	vec4 lo = bytes - hi * 16.0;
	int nibbles[8];
	nibbles[0] = int(hi.r); nibbles[1] = int(lo.r);
	nibbles[2] = int(hi.g); nibbles[3] = int(lo.g);
	nibbles[4] = int(hi.b); nibbles[5] = int(lo.b);
	nibbles[6] = int(hi.a); nibbles[7] = int(lo.a);
	float sum = 0.0;
	vec3 bent = vec3(0.0);
	for (int d = 0; d < 8; d++) {
		vec3 entry = gi_horizon_lut[nibbles[d]];
		sum += entry.x;
		bent += entry.x * vec3(SHRUB_GI_DIRECTIONS[d] * entry.y, entry.z);
	}
	float v_scaled = mix(1.0, clamp(sum * 0.125, 0.0, 1.0), gi_ao_strength);
	s.visibility = clamp(mix(gi_ao_floor, 1.0, v_scaled), 0.0, 1.0);
	float bent_len = length(bent);
	s.bent_normal = (bent_len > 1e-4)
		? normalize(mix(vec3(0.0, 0.0, 1.0), bent / bent_len, gi_bent_strength))
		: vec3(0.0, 0.0, 1.0);
	return s;
#endif
}

int decode_cell_index(vec2 uv) {
	vec2 gb = visual_sample_map_index(uv).gb;
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
#ifdef PK_QUALITY_LOW
	return vec4(0.0);
#else
	int cid = decode_cell_index(uv);
	return (cid >= 0) ? texture(eco_lut, cell_lut_uv(cid)) : vec4(0.0);
#endif
}

float vitality_norm(float vitality) {
	float dead_t = min(vitality_dead_threshold, vitality_healthy_threshold - 0.001);
	float healthy_t = max(vitality_healthy_threshold, dead_t + 0.001);
	return clamp((clamp(vitality, 0.0, 1.0) - dead_t) / (healthy_t - dead_t), 0.0, 1.0);
}

float compute_presence(vec4 dyn, vec4 eco) {
	float dyn_valid = 1.0;
	float temp = mix(0.5, dyn.r, dyn_valid);
	float moisture = mix(0.5, dyn.g, dyn_valid);
	float snow = dyn.b * dyn_valid;
	float vitality = mix(0.70, dyn.a, dyn_valid);
	vitality = mix(vitality, 0.86, aquatic_response);
	float eco_stress = eco.g;
	float heat = smoothstep(0.74, 0.96, temp);
	float dry = clamp(max(max((0.34 - moisture) * 1.9, heat * 0.78), eco_stress), 0.0, 1.0);
	// 叶量直接响应当前气候，不再等待日历季节切换。中度低温开始降低落叶类
	// 植被的可见度；phenology_response 让针叶树/棕榈等常绿类保留更多叶量。
	float cold = 1.0 - smoothstep(0.18, 0.42, temp);
	float snow_hide = clamp(max(snow, cold * 0.72), 0.0, 1.0);
	float presence = pow(vitality_norm(vitality), vitality_alpha_power);
	presence *= 1.0 - dry * stress_hide_strength;
	presence *= 1.0 - snow_hide * snow_hide_strength;
	presence *= 1.0 - cold * stress_hide_strength * 0.42 * phenology_response;
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
	float dyn_valid = 1.0;
	float temp = mix(0.5, shrub_dyn.r, dyn_valid);
	float moisture = mix(0.5, shrub_dyn.g, dyn_valid);
	shrub_vitality_v = mix(0.70, shrub_dyn.a, dyn_valid);
	shrub_vitality_v = mix(shrub_vitality_v, 0.86, aquatic_response);
	float eco_stress = shrub_eco.g;
	float heat = smoothstep(0.74, 0.96, temp);
	shrub_dry_v = clamp(max(max((0.34 - moisture) * 1.9, heat * 0.78), eco_stress), 0.0, 1.0);
	shrub_wet_v = clamp((moisture - 0.50) * 1.85, 0.0, 1.0) * (1.0 - shrub_dry_v);
	float cold = 1.0 - smoothstep(0.18, 0.42, temp);
	shrub_snow_v = clamp(max(shrub_dyn.b * dyn_valid, cold * 0.45), 0.0, 1.0);
	shrub_presence_v = compute_presence(shrub_dyn, shrub_eco);
	float live_scale = mix(0.20, 1.0, smoothstep(0.0, 0.85, shrub_presence_v));
	live_scale *= mix(vitality_size_min, vitality_size_max, pow(vitality_norm(shrub_vitality_v), 0.85));
	// 积雪可降低 alpha 与存在感，但乔木不应因此缩成小点。仅树类由 profile 应用阶段
	// 推送非零下限；灌木和草本的 snow_size_floor=0，保持原有压伏行为。
	float snow_size_restore = smoothstep(0.12, 0.72, shrub_snow_v);
	live_scale = max(live_scale, mix(live_scale, snow_size_floor, snow_size_restore));
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
#ifndef PK_SKIP_VEGETATION_SHADING
	if (terrain_normal_tex_bound) {
		shrub_terrain_n = (visual_sample_terrain_normal(shrub_uv).rg * 2.0 - 1.0) * terrain_normal_influence;
	}
#endif
	// 谷地 AO：仅高画质档用 height_tex 邻域差判断凹陷（中心低于四邻 → 谷/坑 → 压暗）。
	shrub_terrain_ao = 0.0;
#ifndef PK_SKIP_VEGETATION_SHADING
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
#endif
}

void fragment() {
	float snow = clamp(shrub_snow_v, 0.0, 1.0);
	float dyn_valid = 1.0;
	float temp = mix(0.5, shrub_dyn.r, dyn_valid);
	float moisture = mix(0.5, shrub_dyn.g, dyn_valid);
	float vitality_n = vitality_norm(shrub_vitality_v);
	// 颜色使用原始活力的宽动态区间；density vitality_n 仍保留原有阈值，避免实例数量突变。
	float vitality_color_n = smoothstep(0.42, 0.84, shrub_vitality_v);
	float low_vitality = pow(1.0 - smoothstep(0.28, 0.68, shrub_vitality_v), 1.12);
	float heat_visual = smoothstep(0.52, 0.80, temp);
	float cool_visual = 1.0 - smoothstep(0.20, 0.44, temp);
	// 当前运行时湿度约为 0.15..1.0：0.50 为视觉中性点，两端完整展开。
	float dry_visual = 1.0 - smoothstep(0.15, 0.50, moisture);
	float wet_visual = smoothstep(0.50, 0.86, moisture);
	float dry_hot = heat_visual * mix(0.32, 1.0, dry_visual);
	float water_support = clamp(max(wet_visual, shrub_wet_v), 0.0, 1.0);
	float dry_pressure = clamp(max(dry_visual * 0.72, shrub_dry_v), 0.0, 1.0);
	// 高活力只有在水分足够时才解释为绿色；旱生植株保持黄绿/赭褐，而不是
	// 因 vitality 较高就把整片荒漠染绿。
	float green_water_support = smoothstep(0.28, 0.60, moisture)
		* (1.0 - dry_pressure * 0.90);
	// 物候完全由当前温度、湿度与活力驱动；season_phase 只服务太阳高度/昼夜光照。
	// 温暖湿润→萌芽/繁茂；温和降温或水分下降→金黄；严寒、干旱或低活力→凋零。
	// 实例 seed 只打散阈值，避免整格植被同时切色，不改变气候含义。
	float climate_jitter = (fract(shrub_custom.b * 41.3 + shrub_custom.a * 7.17) - 0.5) * 0.08;
	float cool_transition = smoothstep(0.16, 0.34, temp + climate_jitter)
		* (1.0 - smoothstep(0.38, 0.58, temp + climate_jitter));
	float growth_warmth = smoothstep(0.30, 0.56, temp + climate_jitter)
		* (1.0 - smoothstep(0.82, 0.97, temp));
	float growth_moisture = smoothstep(0.30, 0.68, moisture);
	float cold_decline = 1.0 - smoothstep(0.16, 0.38, temp + climate_jitter);
	float sprouting = growth_warmth * growth_moisture
		* (1.0 - smoothstep(0.62, 0.82, temp)) * vitality_color_n;
	float thriving = growth_warmth * mix(0.35, 1.0, growth_moisture)
		* (1.0 - dry_pressure * 0.82) * vitality_color_n;
	float golden = max(cool_transition * mix(0.55, 1.0, growth_moisture),
		dry_pressure * mix(0.42, 0.78, 1.0 - heat_visual));
	float withered = clamp(max(cold_decline, dry_pressure * 0.92)
		+ low_vitality * 0.82, 0.0, 1.0);
	vec4 phenology = vec4(sprouting, thriving, golden, withered);
	phenology /= max(dot(phenology, vec4(1.0)), 0.001);
	sprouting = phenology.x;
	thriving = phenology.y;
	golden = phenology.z;
	withered = phenology.w;
	float climate_wither_support = clamp(max(cold_decline, dry_pressure * 0.88), 0.0, 1.0);
	vec4 stage_w = vec4(
		sprouting * vitality_color_n * smoothstep(0.26, 0.54, temp) * (1.0 - dry_pressure * 0.55),
		thriving * vitality_color_n * mix(0.58, 1.34, water_support),
		golden * mix(0.88, 1.12, dry_yellow_strength) * (1.0 - low_vitality * 0.24)
			+ dry_pressure * (0.08 + heat_visual * 0.14),
		withered * climate_wither_support + low_vitality * 0.92
			+ dry_pressure * (0.18 + dry_hot * 0.30));
	// 收紧物候重叠，并把绿→黄的过渡拆成实例级斑块。过渡期是一部分树仍绿、
	// 一部分树已金黄，而不是所有树都线性混成同一种橄榄黄绿。
	stage_w = pow(max(stage_w, vec4(0.001)), vec4(1.65));
	stage_w /= dot(stage_w, vec4(1.0));
	float green_gold_sum = max(stage_w.y + stage_w.z, 0.001);
	float green_gold_balance = (stage_w.z - stage_w.y) / green_gold_sum;
	float green_gold_seed = (fract(shrub_custom.b * 71.37 + 0.19) - 0.5) * 0.20;
	float gold_side = smoothstep(0.04, 0.20, green_gold_balance + green_gold_seed);
	stage_w.y *= mix(1.0, 0.12, gold_side);
	stage_w.z *= mix(0.12, 1.0, gold_side);
	stage_w /= dot(stage_w, vec4(1.0));
	float golden_commit = smoothstep(0.56, 0.76, stage_w.z);
	float snow_amount = clamp(snow * snow_white_strength, 0.0, 1.0);

	vec3 rgb = COLOR.rgb;
	float source_luma = dot(COLOR.rgb, vec3(0.299, 0.587, 0.114));
	float canopy_detail = mix(0.78, 1.18, smoothstep(0.055, 0.34, source_luma));
	vec3 phenology_color = vec3(0.0);
	phenology_color += vec3(0.30, 0.58, 0.25) * stage_w.x; // 萌芽：明确嫩绿，不经过黄绿中间色
	phenology_color += vec3(0.28, 0.52, 0.24) * stage_w.y; // 繁茂：自然叶绿
	phenology_color += vec3(0.96, 0.72, 0.10) * stage_w.z; // 金黄：明亮金黄
	phenology_color += vec3(0.62, 0.44, 0.16) * stage_w.w; // 凋零：清晰暖褐
	phenology_color *= canopy_detail;
	float phenology_mix = clamp(phenology_color_dominance
		* phenology_response * veg_response, 0.0, 0.94);
	rgb = mix(rgb, phenology_color, phenology_mix);

	// 温度、湿度和活力先归一化为一个目标色，再做一次混合；避免连续乘色压灰。
	float vitality_curve_power = mix(1.10, 0.62, vitality_color_contrast);
	float vitality_high_w = pow(vitality_color_n, vitality_curve_power)
		* vitality_high_color_strength;
	float vitality_low_w = pow(1.0 - vitality_color_n, vitality_curve_power)
		* vitality_low_color_strength;
	float cool_w = cool_visual * temperature_color_strength * 0.58;
	float heat_w = heat_visual * temperature_color_strength * heat_red_strength * 0.54;
	float dry_w = pow(dry_pressure, 1.08) * moisture_color_strength
		* dry_yellow_strength * 0.58;
	float wet_w = pow(water_support, 0.78) * moisture_color_strength
		* mix(wet_green_strength, lush_green_strength, vitality_color_n) * 0.58
		* green_water_support * (1.0 - golden_commit * 0.78);
	float healthy_w = vitality_high_w * (0.34 + water_support * lush_green_strength * 0.46)
		* green_water_support * (1.0 - golden_commit * 0.78);
	float decline_w = vitality_low_w * (0.48 + dry_pressure * 0.52);
	vec3 climate_target =
		vec3(0.48, 0.56, 0.58) * cool_w
		+ vec3(0.66, 0.47, 0.26) * heat_w
		+ vec3(0.78, 0.56, 0.15) * dry_w
		+ vec3(0.22, 0.50, 0.30) * wet_w
		+ vec3(0.22, 0.52, 0.24) * healthy_w
		+ vec3(0.60, 0.43, 0.22) * decline_w;
	float climate_total = cool_w + heat_w + dry_w + wet_w + healthy_w + decline_w;
	if (climate_total > 0.001) {
		climate_target /= climate_total;
		float climate_dominant = max(max(max(cool_w, heat_w), max(dry_w, wet_w)),
			max(healthy_w, decline_w));
		float warm_climate = max(heat_visual, dry_hot);
		float climate_mix_cap = mix(0.82, 0.66, warm_climate);
		float climate_mix = min(clamp(climate_dominant * 0.72 * veg_response, 0.0, 0.82),
			climate_mix_cap);
		rgb = mix(rgb, climate_target, climate_mix);
	}
	// 气候混合后重新锚定金黄相位，避免湿度/活力目标色把秋叶冲回灰绿。
	float golden_guard = golden_commit * phenology_response * veg_response;
	rgb = mix(rgb, vec3(0.94, 0.68, 0.09),
		clamp(golden_guard * (0.30 + dry_yellow_strength * 0.28), 0.0, 0.58));
	// 红叶是温和低温且仍有一定水分时，金黄植被中的实例级斑块；纯干旱黄不触发。
	// 先只计算 mask，实际红色锚定放到气候调色/色度展开/橄榄色修正之后，避免再次被洗回黄色。
	float autumn_red_seed = fract(shrub_custom.b * 43.71 + shrub_custom.a * 11.13 + 0.27);
	float red_climate_support = smoothstep(0.16, 0.62, cool_transition)
		* smoothstep(0.22, 0.62, growth_moisture)
		* (1.0 - smoothstep(0.68, 0.92, dry_pressure));
	float autumn_red_patch = smoothstep(0.44, 0.74, autumn_red_seed);
	float autumn_red_amount = clamp(autumn_red_patch * golden_commit
		* red_climate_support * phenology_response * veg_response
		* autumn_red_strength * 1.12, 0.0, 0.74);
	rgb = mix(rgb, vec3(0.56, 0.45, 0.29),
		dry_hot * heat_red_strength * 0.10 * veg_response);
	// 季节开花：萌芽期给开花类一抹亮色，积雪覆盖时收敛。
	float bloom = bloom_strength * sprouting * vitality_n * (1.0 - snow_amount * 0.85);
	rgb = mix(rgb, rgb * vec3(1.12, 1.0, 1.08) + vec3(0.10, 0.03, 0.08), bloom);
	rgb = mix(rgb, vec3(0.62, 0.45, 0.18),
		withered * climate_wither_support * 0.14 * phenology_response * veg_response);
	// 先展开色度与明度，再覆雪；严寒区收紧色度，避免健康绿色变成荧光色。
	float grade_luma = dot(rgb, vec3(0.299, 0.587, 0.114));
	float warm_grade_mix = max(heat_visual, dry_hot) * 0.82;
	float effective_saturation_gain = mix(color_saturation_gain, 1.12,
		clamp(warm_grade_mix, 0.0, 0.86));
	float cold_grade_mix = cool_visual * temperature_color_strength * 0.90;
	effective_saturation_gain = mix(effective_saturation_gain, 0.76,
		clamp(cold_grade_mix, 0.0, 0.90));
	// 绿色主导的树冠只允许轻度色度展开，防止 Profile、健康色和湿润色叠成荧光绿。
	// 金黄与枯褐不满足 green_axis，因此仍保留清晰的全图区分度。
	float green_axis = max(rgb.g - max(rgb.r, rgb.b), 0.0);
	float green_chroma_w = smoothstep(0.07, 0.26, green_axis)
		* clamp(wet_w + healthy_w + stage_w.y, 0.0, 1.0);
	effective_saturation_gain = mix(effective_saturation_gain,
		min(effective_saturation_gain, 1.06), green_chroma_w * 0.90);
	rgb = mix(vec3(grade_luma), rgb, effective_saturation_gain) * color_value_gain;
	rgb = clamp(rgb, vec3(0.0), vec3(1.0));
	// 风格化调色板禁止大面积橄榄黄绿：它通常来自基础色、物候色和气候色的
	// 二次混合。保持当前明度，将其按生态状态归入明确绿或明确金黄。
	float olive_chroma = smoothstep(0.10, 0.24, min(rgb.r, rgb.g) - rgb.b);
	float olive_rg_close = 1.0 - smoothstep(0.06, 0.18, abs(rgb.r - rgb.g));
	float olive_w = olive_chroma * olive_rg_close * veg_response;
	float gold_or_dry = max(golden_commit, smoothstep(0.56, 0.80, dry_pressure));
	vec3 palette_hue = mix(vec3(0.24, 0.50, 0.25), vec3(0.82, 0.58, 0.12), gold_or_dry);
	float palette_luma = dot(palette_hue, vec3(0.299, 0.587, 0.114));
	palette_hue *= dot(rgb, vec3(0.299, 0.587, 0.114)) / max(palette_luma, 0.001);
	rgb = mix(rgb, clamp(palette_hue, vec3(0.0), vec3(1.0)), olive_w * 0.82);
	// 最终红叶锚定：约一半候选树进入红叶斑块，并按 seed 在朱红/深红之间变化。
	// 放在覆雪之前，因此雪仍能自然覆盖红叶，而后续调色不会再把红色冲淡。
	vec3 autumn_red_color = mix(vec3(0.82, 0.20, 0.055), vec3(0.54, 0.075, 0.035),
		smoothstep(0.52, 0.92, autumn_red_seed));
	rgb = mix(rgb, autumn_red_color, autumn_red_amount);
	float snow_top = smoothstep(0.50, 0.88, UV.y);
	float canopy_edge = abs(UV.x - 0.5) * 2.0;
	float snow_interior = 1.0 - smoothstep(0.72, 0.98, canopy_edge);
	float snow_highlight = smoothstep(0.055, 0.34, source_luma);
	float snow_breakup = smoothstep(0.30, 0.72,
		fract(shrub_custom.b * 37.17 + UV.x * 5.73 + UV.y * 3.19));
	float snow_cap_mask = clamp((snow_top * 0.52 + snow_highlight * 0.34
		+ snow_breakup * 0.08) * snow_interior, 0.0, 1.0);
	float local_snow = snow_amount * mix(1.0, 0.18 + snow_cap_mask * 0.62,
		snow_body_color_retention);
	rgb = mix(rgb, vec3(0.96, 0.98, 1.0), clamp(local_snow, 0.0, 1.0));
	// 卡通分层：基部 AO（UV.y 低=近根，压暗）+ 轻量 3 阶色调量化（在 albedo 空间做）。
	float ao = 1.0 - (1.0 - clamp(UV.y, 0.0, 1.0)) * toon_shading * 0.38;
	rgb *= ao;
	float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
	float ql = floor(luma * 5.0 + 0.5) / 5.0;
	rgb *= (luma > 0.0015) ? mix(1.0, ql / luma, toon_shading * 0.36) : 1.0;
	// [veg-normal-shading] 昼夜 + 法线辅助着色（最后一步）：与地形/水面统一调用 earth_daylight，
	// 按本实例经纬度取昼夜/晨昏 + 同色板；再用「地形宏观法线 + billboard 伪法线」做 NdotL 方向光、
	// 边缘光、接触 AO、谷地 AO，模拟真实场景光照（迎光面亮、背光面暗，随晨昏线/太阳方位变化）。
	vec2 solar_uv = clamp(shrub_custom.rg, vec2(0.0), vec2(1.0));
	float lat_signed = solar_uv.y * 2.0 - 1.0;
	EarthDaylight ed = eval_earth_daylight(solar_uv, lat_signed, day_night_enabled);
	float horizon_vis = shrub_horizon_direct_visibility(solar_uv, ed.sun_dir);
	ShrubSkySample sky = shrub_sample_sky(solar_uv);
	bool horizon_debug_mode = terrain_horizon_debug_view == 1 || terrain_horizon_debug_view == 2;
	vec3 horizon_debug_rgb = (terrain_horizon_debug_view == 1)
		? vec3(clamp((1.0 - horizon_vis) * ed.local_day, 0.0, 1.0))
		: vec3(horizon_vis);
	bool use_expensive_shading = shading_enabled > 0.5;
#ifdef PK_SKIP_VEGETATION_SHADING
	use_expensive_shading = false;
#endif
	if (use_expensive_shading) {
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
		// [terrain-gi] 天光方向偏转到平均可见方向、幅度乘 sky visibility，与地形侧
		// gi_ambient_normal / gi_ambient_occlusion 同式。
		vec3 amb_N = N;
		if (gi_bent_strength > 0.0) {
			vec3 mixed_n = mix(N, sky.bent_normal, gi_bent_strength);
			amb_N = (dot(mixed_n, mixed_n) > 1e-6) ? normalize(mixed_n) : N;
		}
		float gi_align = clamp(dot(N, normalize(sky.bent_normal)), 0.0, 1.0);
		float gi_ao = clamp(sky.visibility * mix(gi_normal_floor, 1.0, gi_align), 0.0, 1.0);
		vec3 light = max(eval_earth_sky_sh(ed, amb_N) * gi_ao, vec3(ambient_floor))
			+ ed.sun_col * (direct + rim);
		vec3 unlit_rgb = rgb;
		rgb *= light;
		// 接触阴影：近根部压暗（UV.y 低=贴地），让植株"扎进"地面而非漂浮。
		float contact = smoothstep(contact_ao_height, 0.0, UV.y) * contact_ao_strength;
		rgb *= 1.0 - contact;
		// 谷地 AO（高画质档）：凹陷处整株压暗。真 AO 可用时退让——两者测的是同一件事
		// （凹陷遮蔽），叠加会把谷底灌木压成死黑；高度图启发式只在 GI 未绑定时兜底。
		float valley_w = gi_lut_bound ? mix(1.0, 0.30, gi_ao_strength) : 1.0;
		rgb *= 1.0 - shrub_terrain_ao * terrain_valley_ao_strength * valley_w
			* mix(0.38, 1.0, veg_response);
		// 保留实例本色的最低可见度；点缀物不再被植被级 AO 压成近黑色。
		rgb = max(rgb, unlit_rgb * mix(0.54, albedo_light_floor, veg_response));
	} else {
		// 退化路径（shading 关）：旧"平直昼夜"着色，保持兼容。
		vec3 light = max(ed.amb_col * sky.visibility, vec3(ambient_floor))
			+ ed.sun_col * (ed.local_day * 0.35 * horizon_vis);
		rgb *= light;
	}
	// 与地形/水面同源的地形投影阴影；植被/点缀比陆地略轻，避免小物件在阴影中过黑。
	// GI 开启时同样按天空可见度收敛投影底限（与 land_pipeline 同策略）：已经被 AO 压暗的
	// 谷底不该再被制图阴影压第二次。
	float horizon_cast = clamp((1.0 - horizon_vis) * ed.local_day, 0.0, 1.0);
	if (horizon_cast > 0.001) {
		float veg_floor = mix(1.0, terrain_horizon_cast_floor, 0.70);
		if (gi_lut_bound) {
			veg_floor = mix(1.0, veg_floor, mix(1.0, sky.visibility, gi_ao_strength));
		}
		rgb *= mix(1.0, veg_floor, horizon_cast);
	}
	rgb *= mix(1.0, mix(0.68, 0.55, veg_response), ed.pixel_night);
	rgb *= tod_exposure;
	if (horizon_debug_mode) {
		rgb = horizon_debug_rgb;
	}
	float alpha = COLOR.a * shrub_presence_v * lod_alpha;
	alpha *= 1.0 - snow * snow_alpha_loss_strength;
	alpha = (alpha < disappear_alpha_threshold) ? 0.0 : alpha;
	if (lod_debug_view) {
		rgb = vec3(lod_alpha);
	}
	COLOR = vec4(rgb, alpha);
}
