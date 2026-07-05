shader_type canvas_item;
render_mode blend_mix;

#include "res://shaders/include/shader_quality.gdshaderinc"

// Cell 级天气雨幕/雪幕。每个 MultiMesh instance 直接携带 cell_id，
// 避免通过 dither 后的 map_index_atlas 反查而混入邻格天气。
//
// [parallax-rain v3] 半俯视投影改造：
//   - camera_pitch 控制俯视角（默认 75°，更贴近实际游戏视角）
//   - rain_curtain(): 雨滴长度按 cos(pitch)^1.5 收缩 + near-layer motion streak
//   - snow_curtain(): 完整同步视差体系（大小/速度/密度/雾化/漂移）
//   - layer_depth 驱动三层差异：近大快清 / 远小慢糊

uniform sampler2D weather_lut : filter_nearest, repeat_disable;
uniform sampler2D weather_lut_prev : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(0.0);
uniform float weather_lerp : hint_range(0.0, 1.0) = 1.0;
uniform float world_time = 0.0;
uniform float weather_strength : hint_range(0.0, 1.0) = 1.0;
uniform int cell_curtain_quality : hint_range(0, 2) = 1;
uniform float hex_world_diameter = 44.0;
uniform float tod_exposure : hint_range(0.2, 2.5) = 1.0;
uniform int weather_profile_flags[8];

// [parallax-rain v3] 半俯视投影与视差分层参数
// camera_pitch: 摄像机俯视角（弧度）。0=正视，π/2=纯俯视。
//   游戏实际俯角约 70-78°，默认设为 75°(1.309)
uniform float camera_pitch : hint_range(0.0, 1.5707) = 1.309;  // 默认 75°
uniform vec2  wind_dir = vec2(0.3, 1.0);
uniform float wind_strength : hint_range(-1.0, 1.0) = 0.15;
uniform float layer_depth : hint_range(0.0, 1.0) = 0.0;        // 0=近景，1=远景

const int MAX_WEATHER_TYPES = 8;
const int FLAG_LIGHTNING = 2;
const int FLAG_SNOW_GRAIN = 4;
const int FLAG_RAIN_STREAK = 8;
const int FLAG_FOG_BREATHE = 16;

varying vec4 v_custom;
varying vec2 v_world;

int effective_cell_curtain_quality() {
#if defined(PK_QUALITY_LOW)
	return 0;
#elif defined(PK_QUALITY_MID)
	return min(cell_curtain_quality, 1);
#else
	return cell_curtain_quality;
#endif
}

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

int decode_cell_id(vec4 custom_data) {
	int lo = int(custom_data.r * 255.0 + 0.5);
	int hi = int(custom_data.g * 255.0 + 0.5);
	return lo + hi * 256;
}

vec2 cell_lut_uv(int cid) {
	int lw = max(int(lut_dims.x), 1);
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

vec4 sample_weather(int cid) {
	vec4 cur = texture(weather_lut, cell_lut_uv(cid));
	if (weather_lerp < 0.999) {
		vec4 prev = texture(weather_lut_prev, cell_lut_uv(cid));
		cur.gba = mix(prev.gba, cur.gba, weather_lerp);
	}
	return cur;
}

float edge_fade(vec2 uv) {
	vec2 p = uv * 2.0 - 1.0;
	float hexish = max(abs(p.y), abs(p.x) * 0.86 + abs(p.y) * 0.28);
	float feather = 1.0 - smoothstep(0.48, 1.10, hexish);
	return clamp(feather, 0.0, 1.0);
}

// ════════════════════════════════════════════════════════════
// rain_curtain — 半俯视雨幕（v3：强投影校正 + motion streak）
//
// 几何模型：
//   雨滴在 3D 空间中垂直下落（略偏风向）。
//   俯视角 pitch 越大，雨滴的"侧投影"在屏幕上越短。
//   公式：screen_length = world_length × cos(pitch)^streak_power
//   其中 streak_power > 1 让收缩更非线性（近正视时仍可见长度）。
//
// 视差分层：
//   layer_depth=0(近景): 大颗粒、快下落、低密度、motion streak、清晰
//   layer_depth=1(远景): 小颗粒、慢下落、高密度、大气雾化、模糊
// ════════════════════════════════════════════════════════════
float rain_curtain(vec2 uv, vec2 wp, float seed, float depth, float precip, float strength) {
	float scale = max(hex_world_diameter, 1.0);
	int quality_tier = effective_cell_curtain_quality();

	// ── 风向量 ──
	vec2 wind_n = normalize(wind_dir + vec2(0.0001));
	// fall_dir: 主要向下，风产生水平偏移。wind_strength=0 时近乎垂直
	vec2 fall_dir = normalize(vec2(wind_n.x * wind_strength * 2.5, 1.0));
	vec2 side_dir = vec2(-fall_dir.y, fall_dir.x);

	// ── 俯视投影收缩（核心）──
	// cos(pitch): 0°→1.0(全长), 60°→0.50, 75°→0.259, 85°→0.087
	// 用 pow(cos, 1.6) 做非线性压缩：中等角度保留一定斜线感，大角度急剧缩短
	float pitch_cos = cos(camera_pitch);
	float vertical_compress = pow(max(pitch_cos, 0.04), 1.6);  // 75°→0.18, 60°→0.40

	// ── 视差分层参数 ──
	// 密度：远层稍密但不至于铺满。反差控制在 2× 以内
	float depth_density = mix(1.0, 2.0, layer_depth);     // 近稀远密（温和）
	// 粒子尺寸：近层略大、远层小（透视近大远小）
	float drop_scale    = mix(1.5, 0.55, layer_depth);      // 近×1.5 远×0.55
	// 下落速度：近层快（穿过视野快）、远层慢
	float fall_speed    = mix(4.5, 1.5, layer_depth);       // 近快远慢
	// 雾化：远层融入背景色
	float haze_factor   = mix(0.0, 0.40, layer_depth);
	// motion streak：仅近层有速度拖尾（模拟高速运动的视觉残留）
	float streak_factor = mix(0.55, 0.05, layer_depth);

	// ── 网格空间坐标 ──
	float across = dot(wp, side_dir) / scale * depth_density + seed * 11.7;
	float along_static = dot(wp, fall_dir) / scale * depth_density + seed * 5.3;
	float along = along_static - world_time * fall_speed;

	float drop_cols = (mix(6.0, 14.0, depth) + float(quality_tier) * 2.5) * depth_density;
	// 行数被俯视压缩：pitch 越大行数越少（每根雨线越短）
	float drop_rows = (mix(1.8, 3.2, depth) + float(quality_tier) * 0.40) * vertical_compress;

	vec2 q = vec2(across * drop_cols, along * drop_rows);
	vec2 cell = floor(q);
	vec2 f = fract(q);

	float rnd0 = hash21(cell + seed * 19.0);
	float rnd1 = hash21(cell + vec2(17.0, 3.0) + seed * 31.0);
	float rnd2 = hash21(cell + vec2(5.0, 23.0) + seed * 11.0);

	// ── 噪声遮罩 ──
	vec2 noise_domain = vec2(across, along_static);
	float broad_noise = 1.0;
	float fine_noise = 0.5;
#ifndef PK_QUALITY_LOW
	broad_noise = value_noise(noise_domain * 0.72 + seed * 3.1);
	fine_noise = value_noise(noise_domain * 3.4 + seed * 9.7);
#endif

	// ── 单根雨线形状 ──
	vec2 center = vec2(0.18 + rnd0 * 0.64, 0.16 + rnd1 * 0.68);

	// 宽度：近层粗、远层细
	float width = mix(0.038, 0.014, depth) * mix(0.70, 1.50, rnd2) / drop_scale;
	// 长度 = 基础长 × 俯视压缩 × 层缩放
	// 近层额外加 streak_factor 延长（motion blur 效果）
	float base_len = mix(0.26, 0.62, rnd1) * mix(0.80, 1.20, depth);
	float len = base_len * vertical_compress / drop_scale;
	len *= (1.0 + streak_factor * 0.8);  // 近层拖尾延长

	float dx = abs(f.x + (fine_noise - 0.5) * 0.10 - center.x);
	float dy = abs(f.y - center.y);

	// 雨线形状：椭圆（宽窄长）
	float line = 1.0 - smoothstep(width * 0.28, width * 4.0, dx);
	float drop = 1.0 - smoothstep(len * 0.28, len, dy);

	// noise_mask：让雨分布不均匀（自然感）
#ifdef PK_QUALITY_LOW
	float noise_mask = 1.0;
#else
	float noise_mask = smoothstep(0.22, 0.78, broad_noise) * mix(0.55, 1.20, fine_noise);
#endif

	// gate：随机决定某些格子没有雨（控制密度下限）
	float gate = step(mix(0.52, 0.15, strength), rnd0);

	// depth_shade：per-instance 微调
	float depth_shade = mix(0.88, 1.12, depth) * mix(0.94, 1.06, uv.y);

	// ── 合成 alpha ──
	float alpha = clamp(line * drop * gate * noise_mask
						* mix(0.65, 1.10, strength) * depth_shade, 0.0, 1.0);
	// 远层雾化衰减
	alpha *= mix(1.0, 0.48, haze_factor);
	return alpha;
}

// ════════════════════════════════════════════════════════════
// snow_curtain — 半俯视雪花（v3：完整视差同步）
//
// 与 rain_curtain 共用同一套 parallax 参数体系：
//   - layer_depth 控制 size/speed/density/haze
//   - camera_pitch 控制飘落轨迹的透视收缩
//   - 近层大而清晰、远层小而模糊
// ════════════════════════════════════════════════════════════
float snow_curtain(vec2 uv, vec2 wp, float seed, float depth, float precip, float strength) {
	float scale = max(hex_world_diameter, 1.0);

	// ── 视差分层 ──
	float flake_scale   = mix(2.0, 0.6, layer_depth);
	float drift_speed   = mix(0.85, 0.28, layer_depth);
	float fall_speed    = mix(4.5, 1.5, layer_depth);
	float density_mult  = mix(5.0, 12.0, layer_depth);
	float sway_amp      = mix(0.20, 0.08, layer_depth);
	float haze_factor   = mix(0.0, 0.35, layer_depth);

	// 俯视投影：放宽指数让俯视时下落仍可见
	float pitch_cos = cos(camera_pitch);
	float fall_visibility = pow(max(pitch_cos, 0.05), 0.7);

	// ── 雪花位置：密集网格 + 域扭曲（打破规律性）──
	vec2 wind_n = normalize(wind_dir + vec2(0.0001));
	float t = world_time;
	vec2 drift = vec2(
		sin(t * 0.35 + seed * 6.28) * sway_amp
			+ wind_n.x * wind_strength * t * 0.3,
		-t * fall_speed * fall_visibility
			+ wind_n.y * wind_strength * t * 0.12
	);

	vec2 p_raw = wp * density_mult / scale + drift + vec2(seed * 11.3, seed * 5.7);

	// [去规律化] 域扭曲：用低频噪声偏移网格坐标，打破均匀排列
	vec2 warp = vec2(0.0);
#ifndef PK_QUALITY_LOW
	warp = vec2(
		value_noise(p_raw * 0.42 + seed * 3.1) * 0.55,
		value_noise(p_raw * 0.38 - seed * 5.7) * 0.55
	);
#endif
	vec2 p = p_raw + warp;

	vec2 cell_id = floor(p);
	vec2 f = fract(p);

	// 每个格子独立的多组随机数（位置/门控/半径各用不同种子）
	float rnd_pos  = hash21(cell_id);              // 位置随机
	float rnd_gate = hash21(cell_id + 7.3);         // 门控随机
	float rnd_r    = hash21(cell_id + 13.1);        // 半径随机
	float rnd_tilt = hash21(cell_id + 19.7);        // 子格倾斜

	// [去规律化] 子格随机偏移：每个格子内的 flake 不在中心，
	// 而是在格子内随机分布（打破"每个格子正中间一颗"的棋盘感）
	vec2 sub_jitter = vec2(0.0);
#ifndef PK_QUALITY_LOW
	sub_jitter = vec2(rnd_tilt * 0.37, hash21(cell_id + 31.3) * 0.37);
#endif

	// 雪花中心：微颤 + 子格偏移
	vec2 center = vec2(
		0.5 + sin(t * 0.7 + rnd_pos * 6.28) * 0.10,
		0.5 + cos(t * 0.55 + hash21(cell_id + 4.13) * 4.13) * 0.08
	) + sub_jitter * 0.45;  // 子格偏移量

	vec2 fp = f - center;

	// 形状：椭圆
	vec2 stretch = vec2(1.0, mix(1.65, 0.85, layer_depth) * (0.6 + fall_visibility * 0.8));
	fp = fp * stretch;
	float d = length(fp);

	// 半径：用独立的 rnd_r 打破与位置的相关性
	float radius = mix(0.07, 0.04, depth) * mix(0.72, 1.28, rnd_r) * flake_scale;

	// 亮核 + 淡晕
	float core  = 1.0 - smoothstep(radius * 0.36, radius, d);
	float halo  = 1.0 - smoothstep(radius * 0.85, radius * 2.4, d);
	float flake = core * 0.62 + halo * 0.12;

	// 门控：用独立 rnd_gate，避免与位置相关联导致成片空白
	float gate = step(mix(0.40, 0.06, strength), rnd_gate);

	// alpha：整体压暗
	float alpha = clamp(flake * gate * mix(0.45, 1.15, strength), 0.0, 1.0);
	alpha *= mix(1.0, 0.55, haze_factor);
	return alpha;
}

float fog_veil(vec2 uv, float seed, float intensity) {
	vec2 p = uv * vec2(3.5, 1.6) + vec2(world_time * 0.05, sin(world_time * 0.17 + seed) * 0.12);
	float a = hash21(floor(p));
	float b = hash21(floor(p) + vec2(1.0, 0.0));
	float c = hash21(floor(p) + vec2(0.0, 1.0));
	float d = hash21(floor(p) + vec2(1.0, 1.0));
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float n = mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
	return smoothstep(0.32, 0.78, n) * intensity;
}

float lightning_flash(float seed, float intensity) {
	float slot = floor(world_time * 2.2 + seed * 17.0);
	float local_t = fract(world_time * 2.2 + seed * 17.0);
	float chance = hash21(vec2(slot, seed * 91.7));
	float pulse = exp(-local_t * 18.0) + exp(-abs(local_t - 0.12) * 40.0) * 0.28;
	return step(0.984, chance) * pulse * intensity;
}

void fragment() {
	if (lut_dims.x < 1.0 || weather_strength <= 0.001) {
		COLOR = vec4(0.0);
	} else {
		int cid = decode_cell_id(v_custom);
		vec4 wx = sample_weather(cid);
		int wt = int(wx.r * 255.0 + 0.5);
		float intensity = wx.g;
		float precip = clamp(smoothstep(0.010, 0.48, wx.g) * 1.38, 0.0, 1.0);
		float wx_strength = clamp(max(precip, intensity * 0.82) * mix(0.68, 1.48, intensity), 0.0, 1.0);
		int flags = (wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_flags[wt] : 0;
		float seed = v_custom.b;
		float depth = v_custom.a;
		float edge = edge_fade(UV);

		float rain = ((flags & FLAG_RAIN_STREAK) != 0) ? rain_curtain(UV, v_world, seed, depth, precip, wx_strength) : 0.0;
		float snow = ((flags & FLAG_SNOW_GRAIN) != 0) ? snow_curtain(UV, v_world, seed, depth, precip, wx_strength) : 0.0;
		float fog = 0.0;
		float flash = 0.0;
#ifndef PK_QUALITY_LOW
		fog = ((flags & FLAG_FOG_BREATHE) != 0) ? fog_veil(UV, seed, intensity) * 0.45 : 0.0;
		flash = ((flags & FLAG_LIGHTNING) != 0) ? lightning_flash(seed, max(intensity, precip)) : 0.0;
#endif

		// alpha 合成：雪权重适中，不过曝
		float alpha = (rain * 0.98 + snow * 1.30 + fog * 0.34 + flash * 0.30) * edge * weather_strength * mix(0.72, 1.28, wx_strength);
		if (alpha <= 0.001) {
			COLOR = vec4(0.0);
		} else {
			// ── 颜色：带大气透视 ──
			// 雨：冷灰蓝 → 远景偏雾色
			vec3 rain_col = vec3(0.46, 0.53, 0.64);
			vec3 rain_haze = vec3(0.60, 0.66, 0.74);
			rain_col = mix(rain_col, rain_haze, layer_depth * 0.50);

			// 雪：近景纯白带微蓝、远景偏灰（大气散射）
			vec3 snow_col_near = vec3(0.96, 0.98, 1.00);
			vec3 snow_col_far  = vec3(0.78, 0.82, 0.88);
			vec3 snow_col = mix(snow_col_near, snow_col_far, layer_depth * 0.60);

			vec3 fog_col = vec3(0.62, 0.68, 0.72);
			vec3 flash_col = vec3(0.52, 0.62, 0.80);

			vec3 col = rain_col * rain + snow_col * snow + fog_col * fog + flash_col * flash;
			float weight = max(rain + snow + fog + flash, 0.001);
			col = col / weight;

			// 近景提亮、远景压暗（空间深度感）
			col *= mix(1.08, 0.94, layer_depth) * mix(1.04, 1.10, wx_strength) * tod_exposure;
			COLOR = vec4(col, clamp(alpha, 0.0, 0.98));
		}
	}
}
