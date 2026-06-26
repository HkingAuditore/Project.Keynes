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
	float x = smoothstep(0.00, 0.18, uv.x) * (1.0 - smoothstep(0.82, 1.00, uv.x));
	float y = smoothstep(0.00, 0.12, uv.y) * (1.0 - smoothstep(0.88, 1.00, uv.y));
	return clamp(x * y, 0.0, 1.0);
}

float rain_curtain(vec2 uv, float seed, float depth, float precip) {
	float speed = mix(1.5, 3.4, depth) * (0.65 + precip * 0.70);
	float slant = mix(0.10, 0.26, depth);
	float cols = mix(10.0, 18.0, depth) + float(cell_curtain_quality) * 3.0;
	float rows = mix(4.0, 8.0, depth);
	vec2 p = uv;
	p.x += p.y * slant;
	p.y += world_time * speed + seed * 7.31;
	float col = floor(p.x * cols);
	float row = floor(p.y * rows);
	float rnd = hash21(vec2(col, row) + seed * 19.0);
	float x = fract(p.x * cols);
	float y = fract(p.y * rows);
	float width = mix(0.035, 0.018, depth);
	float line = 1.0 - smoothstep(width, width * 2.7, abs(x - 0.5));
	float drop = smoothstep(0.04, 0.18, y) * (1.0 - smoothstep(0.50, 0.96, y));
	float gate = step(mix(0.62, 0.34, precip), rnd);
	float fine = 0.0;
	if (cell_curtain_quality >= 2) {
		float x2 = fract(p.x * (cols * 2.2) + seed);
		float y2 = fract(p.y * (rows * 1.7) + rnd);
		fine = (1.0 - smoothstep(0.015, 0.05, abs(x2 - 0.5))) * smoothstep(0.08, 0.34, y2);
	}
	return clamp((line * drop * gate + fine * 0.35) * precip, 0.0, 1.0);
}

float snow_curtain(vec2 uv, float seed, float depth, float precip) {
	float scale = mix(8.0, 14.0, depth) + float(cell_curtain_quality) * 2.0;
	vec2 drift = vec2(
		sin(world_time * 0.72 + seed * 6.28) * 0.08,
		world_time * mix(0.18, 0.38, depth)
	);
	vec2 p = uv * scale + drift + vec2(seed * 11.3, seed * 5.7);
	vec2 cell = floor(p);
	vec2 f = fract(p);
	float rnd = hash21(cell);
	vec2 center = vec2(
		0.5 + sin(world_time * 0.9 + rnd * 6.28) * 0.22,
		0.5 + cos(world_time * 0.7 + rnd * 4.13) * 0.18
	);
	float d = length(f - center);
	float radius = mix(0.12, 0.20, depth) * mix(0.7, 1.25, rnd);
	float flake = 1.0 - smoothstep(radius, radius * 1.8, d);
	float gate = step(mix(0.72, 0.28, precip), rnd);
	return clamp(flake * gate * precip, 0.0, 1.0);
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
	float pulse = exp(-local_t * 12.0) + exp(-abs(local_t - 0.12) * 28.0) * 0.45;
	return step(0.965, chance) * pulse * intensity;
}

void fragment() {
	if (lut_dims.x < 1.0 || weather_strength <= 0.001 || cell_curtain_quality <= 0) {
		COLOR = vec4(0.0);
	} else {
		int cid = decode_cell_id(v_custom);
		vec4 wx = sample_weather(cid);
		int wt = int(wx.r * 255.0 + 0.5);
		float intensity = wx.g;
		float precip = clamp(wx.a * 1.35, 0.0, 1.0);
		int flags = (wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_flags[wt] : 0;
		float seed = v_custom.b;
		float depth = v_custom.a;
		float edge = edge_fade(UV);

		float rain = ((flags & FLAG_RAIN_STREAK) != 0) ? rain_curtain(UV, seed, depth, precip) : 0.0;
		float snow = ((flags & FLAG_SNOW_GRAIN) != 0) ? snow_curtain(UV, seed, depth, precip) : 0.0;
		float fog = ((flags & FLAG_FOG_BREATHE) != 0) ? fog_veil(UV, seed, intensity) * 0.45 : 0.0;
		float flash = ((flags & FLAG_LIGHTNING) != 0) ? lightning_flash(seed, max(intensity, precip)) : 0.0;

		float alpha = (rain * 0.32 + snow * 0.54 + fog * 0.22 + flash * 0.42) * edge * weather_strength;
		if (alpha <= 0.001) {
			COLOR = vec4(0.0);
		} else {
			vec3 rain_col = vec3(0.48, 0.58, 0.70);
			vec3 snow_col = vec3(0.88, 0.94, 1.0);
			vec3 fog_col = vec3(0.62, 0.68, 0.72);
			vec3 flash_col = vec3(0.72, 0.84, 1.0);
			vec3 col = rain_col * rain + snow_col * snow + fog_col * fog + flash_col * flash;
			float weight = max(rain + snow + fog + flash, 0.001);
			col = col / weight;
			col *= mix(0.82, 1.16, depth) * tod_exposure;
			COLOR = vec4(col, clamp(alpha, 0.0, 0.86));
		}
	}
}
