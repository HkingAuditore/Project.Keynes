shader_type canvas_item;
render_mode blend_mix;

// Cell 级天气雨幕/雪幕。每个 MultiMesh instance 直接携带 cell_id，
// 避免通过 dither 后的 map_index_atlas 反查而混入邻格天气。

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

const int MAX_WEATHER_TYPES = 8;
const int FLAG_LIGHTNING = 2;
const int FLAG_SNOW_GRAIN = 4;
const int FLAG_RAIN_STREAK = 8;
const int FLAG_FOG_BREATHE = 16;

varying vec4 v_custom;
varying vec2 v_world;

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

float rain_curtain(vec2 uv, vec2 wp, float seed, float depth, float precip, float strength) {
	float scale = max(hex_world_diameter, 1.0);
	vec2 fall_dir = normalize(vec2(-0.22, 1.0));
	vec2 side_dir = vec2(-fall_dir.y, fall_dir.x);
	float across = dot(wp, side_dir) / scale + seed * 11.7;
	float along_static = dot(wp, fall_dir) / scale + seed * 5.3;
	float along = along_static - world_time * 3.2;

	float drop_cols = mix(7.0, 12.0, depth) + float(cell_curtain_quality) * 2.5;
	float drop_rows = mix(2.0, 3.6, depth) + float(cell_curtain_quality) * 0.45;
	vec2 q = vec2(across * drop_cols, along * drop_rows);
	vec2 cell = floor(q);
	vec2 f = fract(q);
	float rnd0 = hash21(cell + seed * 19.0);
	float rnd1 = hash21(cell + vec2(17.0, 3.0) + seed * 31.0);
	float rnd2 = hash21(cell + vec2(5.0, 23.0) + seed * 11.0);

	vec2 noise_domain = vec2(across, along_static);
	float broad_noise = value_noise(noise_domain * 0.72 + seed * 3.1);
	float fine_noise = value_noise(noise_domain * 3.4 + seed * 9.7);
	vec2 center = vec2(0.18 + rnd0 * 0.64, 0.16 + rnd1 * 0.68);
	float width = mix(0.030, 0.016, depth) * mix(0.75, 1.45, rnd2);
	float len = mix(0.28, 0.66, rnd1) * mix(0.82, 1.18, depth);
	float dx = abs(f.x + (fine_noise - 0.5) * 0.10 - center.x);
	float dy = abs(f.y - center.y);
	float line = 1.0 - smoothstep(width * 0.30, width * 3.7, dx);
	float drop = 1.0 - smoothstep(len * 0.32, len, dy);
	float noise_mask = smoothstep(0.22, 0.78, broad_noise) * mix(0.55, 1.18, fine_noise);
	// [rain-uniform] 压缩雨幕动态范围：弱雨别太稀疏(gate 下限抬高)、强雨别冲亮白(strength 上限压低)，
	// 并收窄 per-instance depth 的明暗摆动 → 各格雨幕亮度/可见度趋于一致，不再忽明忽暗。
	float gate = step(mix(0.50, 0.18, strength), rnd0);
	float depth_shade = mix(0.90, 1.10, depth) * mix(0.94, 1.06, uv.y);
	return clamp(line * drop * gate * noise_mask * mix(0.68, 1.08, strength) * depth_shade, 0.0, 1.0);
}

float snow_curtain(vec2 uv, vec2 wp, float seed, float depth, float precip, float strength) {
	float world_scale = max(hex_world_diameter, 1.0);
	float scale = (mix(1.15, 1.95, depth) + float(cell_curtain_quality) * 0.22) * mix(0.90, 1.55, strength);
	vec2 drift = vec2(
		sin(world_time * 0.72 + seed * 6.28) * 0.52,
		-world_time * mix(1.25, 2.05, depth)
	);
	vec2 p = wp * scale / world_scale + drift + vec2(seed * 11.3, seed * 5.7);
	vec2 cell = floor(p);
	vec2 f = fract(p);
	float rnd = hash21(cell);
	vec2 center = vec2(
		0.5 + sin(world_time * 0.9 + rnd * 6.28) * 0.22,
		0.5 + cos(world_time * 0.7 + rnd * 4.13) * 0.18
	);
	vec2 fp = (f - center) * vec2(1.0, 1.65);
	float d = length(fp);
	float radius = mix(0.030, 0.052, depth) * mix(0.65, 1.25, rnd);
	float core = 1.0 - smoothstep(radius * 0.45, radius, d);
	float halo = 1.0 - smoothstep(radius, radius * 3.0, d);
	float flake = core * 0.70 + halo * 0.24;
	float gate = step(mix(0.48, 0.05, strength), rnd);
	return clamp(flake * gate * mix(0.30, 1.36, strength), 0.0, 1.0);
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
	// 闪电"闪光"压暗+降频：提高触发阈值(少而精)，脉冲衰减更快、双闪更弱，
	// 不再是刺眼的满屏亮白；只留偶发的克制微光。
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
		float fog = ((flags & FLAG_FOG_BREATHE) != 0) ? fog_veil(UV, seed, intensity) * 0.45 : 0.0;
		float flash = ((flags & FLAG_LIGHTNING) != 0) ? lightning_flash(seed, max(intensity, precip)) : 0.0;

		// [rain-uniform] wx_strength 对可见度的影响收窄(原 0.42~1.58 差 3.7×)：弱雨抬底、强雨压顶。
		float alpha = (rain * 0.98 + snow * 1.22 + fog * 0.34 + flash * 0.30) * edge * weather_strength * mix(0.72, 1.28, wx_strength);
		if (alpha <= 0.001) {
			COLOR = vec4(0.0);
		} else {
			// 雨幕压暗：原 (0.72,0.82,0.96) 偏亮白，经 depth/wx_strength/曝光提亮后 B 通道冲到近纯白。
			// 改成雾蒙钢灰蓝 → 雷雨雨幕是暗淡的一层斜纱，不再刺眼亮白。
			vec3 rain_col = vec3(0.46, 0.53, 0.64);
			vec3 snow_col = vec3(0.98, 1.00, 1.00);
			vec3 fog_col = vec3(0.62, 0.68, 0.72);
			vec3 flash_col = vec3(0.52, 0.62, 0.80);
			vec3 col = rain_col * rain + snow_col * snow + fog_col * fog + flash_col * flash;
			float weight = max(rain + snow + fog + flash, 0.001);
			col = col / weight;
			// [rain-uniform] 收窄颜色提亮的 per-instance(depth) 与 per-cell(wx_strength) 摆动，避免有的雨幕冲亮白。
			col *= mix(1.0, 1.12, depth) * mix(1.04, 1.10, wx_strength) * tod_exposure;
			COLOR = vec4(col, clamp(alpha, 0.0, 0.98));
		}
	}
}
