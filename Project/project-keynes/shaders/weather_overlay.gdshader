shader_type canvas_item;
render_mode blend_mix;

uniform sampler2D enum_atlas : filter_nearest, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
const float NOISE_TEX_SCALE = 256.0;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float world_time = 0.0;

uniform float day_phase : hint_range(0.0, 1.0) = 0.25;
uniform bool day_night_enabled = true;
uniform vec3 tod_sun_color : source_color = vec3(1.0);
uniform vec3 tod_ambient_color : source_color = vec3(0.65, 0.68, 0.75);
uniform float tod_night_factor : hint_range(0.0, 1.0) = 0.0;
uniform float tod_exposure : hint_range(0.2, 2.5) = 1.0;
uniform bool cloud_tod_tint_enabled = true;

uniform int weather_overlay_quality : hint_range(0, 2) = 2;
uniform bool extreme_weather_ground_effect_enabled = true;
uniform float storm_flash : hint_range(0.0, 1.0) = 0.0;
uniform float heatwave_distortion : hint_range(0.0, 1.0) = 0.6;

const int MAX_WEATHER_FRONTS = 16;
uniform vec4 weather_front_centers[MAX_WEATHER_FRONTS];
uniform vec4 weather_front_shapes[MAX_WEATHER_FRONTS];
uniform vec4 weather_front_visuals[MAX_WEATHER_FRONTS];
uniform float weather_front_types[MAX_WEATHER_FRONTS];
uniform int weather_front_count = 0;
uniform float weather_strength : hint_range(0.0, 1.0) = 1.0;

const int MAX_WEATHER_TYPES = 8;
uniform vec4 weather_profile_colors[MAX_WEATHER_TYPES];
uniform int weather_profile_flags[MAX_WEATHER_TYPES];

const int FLAG_HAS_OVERLAY = 1;
const int FLAG_LIGHTNING = 2;
const int FLAG_SNOW_GRAIN = 4;
const int FLAG_RAIN_STREAK = 8;
const int FLAG_FOG_BREATHE = 16;

const int WT_CLEAR = 0;
const int WT_RAIN = 1;
const int WT_STORM = 2;
const int WT_BLIZZARD = 3;
const int WT_DROUGHT = 4;
const int WT_FOG = 5;
const int WT_HEATWAVE = 6;
const int WT_MONSOON = 7;

const int B_OCEAN = 0;
const int B_COAST = 1;
const int B_LAKE = 18;
const int B_REEF = 19;
const int B_SEA_ICE = 20;
const int B_KELP = 21;

varying vec2 v_world;

float value_noise(vec2 p) {
	return texture(noise_tex, p / NOISE_TEX_SCALE).r;
}

float fbm(vec2 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float freq = 1.0;
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) break;
		sum += value_noise(p * freq) * amp;
		freq *= 2.03;
		amp *= 0.48;
	}
	return sum;
}

// Phase B：风场驱动的 domain warp。
// 1) 沿 flow 方向做 advection（让云真正"飘"，不再原地抖）
// 2) 再用两层错位低频 FBM 抖动坐标，让云团边缘破碎卷曲
// freq 取 0.022 偏低频以适配 0.0085~0.062 多频段云形采样。
vec2 wind_domain_warp(vec2 wp, vec2 flow, float t, float strength) {
	vec2 advected = wp - flow * t;
	float n1 = fbm(advected * 0.022 + vec2( t * 0.020,  t * 0.012), 2) - 0.5;
	float n2 = fbm(advected * 0.022 + vec2(-t * 0.014,  t * 0.018) + vec2(37.0, 13.0), 2) - 0.5;
	return advected + vec2(n1, n2) * strength;
}

vec2 front_axis(vec4 shape) {
	vec2 ax = shape.xy;
	if (dot(ax, ax) <= 0.0001) {
		return vec2(1.0, 0.0);
	}
	return normalize(ax);
}

float front_ellipse_distance(vec2 wp, vec2 center, float radius, vec4 shape) {
	vec2 ax = front_axis(shape);
	vec2 ay = vec2(-ax.y, ax.x);
	vec2 local = wp - center;
	float major = max(radius * max(shape.z, 0.05), 0.001);
	float minor = max(radius * max(shape.w, 0.05), 0.001);
	return length(vec2(dot(local, ax) / major, dot(local, ay) / minor));
}

float visual_weather_intensity(float raw_intensity) {
	float i = clamp(raw_intensity, 0.0, 1.0);
	return clamp(pow(i, 0.55) * smoothstep(0.0, 0.08, i), 0.0, 1.0);
}

struct FrontField {
	vec3 color;
	float alpha;
	float cloud;
	float precip;
	float shadow;
	float core;
	float edge;
	int type;
	vec2 axis;
};

FrontField empty_field() {
	FrontField f;
	f.color = vec3(0.0);
	f.alpha = 0.0;
	f.cloud = 0.0;
	f.precip = 0.0;
	f.shadow = 0.0;
	f.core = 0.0;
	f.edge = 0.0;
	f.type = WT_CLEAR;
	f.axis = vec2(1.0, 0.0);
	return f;
}

float type_cloud_bias(int wt) {
	if (wt == WT_STORM) return 1.18;
	if (wt == WT_MONSOON) return 1.12;
	if (wt == WT_FOG) return 1.20;
	if (wt == WT_BLIZZARD) return 1.06;
	return 1.0;
}

FrontField sample_front_field(vec2 wp) {
	FrontField best = empty_field();
	float best_score = 0.0;

	for (int i = 0; i < MAX_WEATHER_FRONTS; i++) {
		if (i >= weather_front_count) break;
		float wt_f = weather_front_types[i];
		if (wt_f < 0.0) continue;
		int wt = int(wt_f + 0.5);
		if (wt == WT_CLEAR || wt == WT_DROUGHT || wt == WT_HEATWAVE) continue;

		vec4 c = weather_front_centers[i];
		vec4 shape = weather_front_shapes[i];
		vec4 visual = weather_front_visuals[i];
		float radius = c.z;
		if (radius <= 0.001) continue;

		float raw_i = clamp(c.w, 0.0, 1.0);
		float cloud_amount = max(visual.x, visual_weather_intensity(raw_i) * 0.35);
		float precip_amount = visual.y;
		float dissolve = visual.z;

		float ed = front_ellipse_distance(wp, c.xy, radius, shape);
		float spread = mix(1.0, 1.18, dissolve);
		float d = ed / spread;
		if (d > 1.72) continue;

		vec2 ax = front_axis(shape);
		// Phase B：advection 速度提升到原来的 ~2.5×，让云团在 30s 内可见地"漂"过自身直径，
		// 同时用 domain warp 让边缘破碎卷曲，而不是整体平移看起来很僵。
		// FOG 的 flow 减半（雾流动比云慢、更接地）。
		float flow_speed = (wt == WT_FOG)
			? mix(3.0, 4.5, cloud_amount)
			: mix(6.0, 13.0, max(precip_amount, cloud_amount));
		vec2 flow = ax * flow_speed;
		float warp_strength = (wt == WT_FOG) ? 5.0 : 9.0;
		// 把 wp 转到 front 局部坐标（相对 center），然后做 domain warp。
		// 这样 advection 不会让 fbm 采样越过相邻 front 的"势力范围"。
		vec2 wp_local = wp - c.xy;
		vec2 warped = wind_domain_warp(wp_local, flow, world_time, warp_strength);

		float envelope = 1.0 - smoothstep(0.70, 1.38 + dissolve * 0.22, d);
		float core = 1.0 - smoothstep(0.10, 0.58, d);
		float edge = smoothstep(0.58, 1.02, d) * (1.0 - smoothstep(1.06, 1.52, d));

		int q_oct = (weather_overlay_quality >= 2) ? 3 : 2;
		// 三层频率共享同一个 warped 坐标，但乘不同频率：低频负责团块、中频负责轮廓、高频负责颗粒。
		// 由于 warped 已经包含 advection + 抖动，所有频段会随风一起卷动，肉眼上是"自然流动的云"。
		float low = fbm(warped * 0.0085, q_oct);
		float mid = fbm(warped * 0.024 + vec2(41.0, -23.0), 2);
		float high = (weather_overlay_quality >= 2)
			? fbm(warped * 0.062, 1)
			: 0.5;
		float edge_break = fbm((warped + vec2(shape.z * 31.0, shape.w * -47.0)) * 0.017, 2);

		float threshold = mix(0.54, 0.22, cloud_amount);
		threshold += dissolve * 0.15;
		float cloud_shape = smoothstep(threshold, threshold + 0.22, low * 0.66 + mid * 0.28 + edge_break * 0.06);
		float cloud = clamp((cloud_shape * 0.78 + core * 0.24) * envelope * cloud_amount * type_cloud_bias(wt), 0.0, 1.0);

		float precip_gate = clamp((envelope * 0.58 + cloud * 0.64) * precip_amount, 0.0, 1.0);
		if (wt == WT_FOG) {
			precip_gate = 0.0;
			cloud = clamp((envelope * 0.70 + low * 0.30) * cloud_amount, 0.0, 1.0);
		}

		float score = max(cloud, precip_gate * 1.08);
		if (score > best_score) {
			best_score = score;
			best.color = (wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_colors[wt].rgb : vec3(0.0);
			best.alpha = (wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_colors[wt].a : 0.0;
			best.cloud = cloud;
			best.precip = precip_gate;
			best.shadow = clamp((cloud * 0.68 + core * 0.25) * (1.0 - dissolve * 0.45), 0.0, 1.0);
			best.core = core * cloud;
			best.edge = edge * mix(0.75, 1.25, high);
			best.type = wt;
			best.axis = ax;
		}
	}
	return best;
}

float rain_field(vec2 wp, vec2 axis, float precip) {
	vec2 dir = normalize(vec2(axis.x * 0.46, 1.0));
	vec2 side = vec2(-dir.y, dir.x);
	float along = dot(wp, dir);
	float across = dot(wp, side);
	float sheet = fbm(vec2(across * 0.052, along * 0.018 + world_time * 2.8), 2);
	float near_lines = fbm(vec2(across * 0.19, along * 0.060 + world_time * 12.0), 1);
	float curtain = smoothstep(0.40, 0.74, sheet);
	float lines = smoothstep(0.62, 0.92, near_lines);
	return clamp((curtain * 0.62 + lines * 0.54) * precip, 0.0, 1.0);
}

float snow_field(vec2 wp, vec2 axis, float precip) {
	vec2 wind = normalize(axis + vec2(0.12, 0.36));
	vec2 side = vec2(-wind.y, wind.x);
	float along = dot(wp, wind);
	float across = dot(wp, side);
	float band = fbm(vec2(along * 0.036 + world_time * 1.4, across * 0.078), 2);
	float veil = fbm(vec2(along * 0.012 + world_time * 0.45, across * 0.026), 2);
	float flurry = smoothstep(0.45, 0.82, band) * 0.62 + smoothstep(0.30, 0.68, veil) * 0.42;
	return clamp(flurry * precip, 0.0, 1.0);
}

vec3 apply_cloud_tod(vec3 col, int wt) {
	if (cloud_tod_tint_enabled) {
		col = col * tod_sun_color * (1.0 - 0.42 * tod_night_factor) + tod_ambient_color * 0.34;
		col = max(col, vec3(mix(0.15, 0.25, tod_night_factor)));
		if (wt == WT_STORM || wt == WT_MONSOON) {
			col *= 0.74;
		}
		if (wt == WT_BLIZZARD) {
			col = mix(col, vec3(0.86, 0.92, 1.0), 0.22 + tod_night_factor * 0.14);
		}
		col *= tod_exposure;
	}
	return col;
}

void vertex() {
	v_world = VERTEX;
}

void fragment() {
	vec2 wp = v_world;
	vec2 uv = clamp((wp - world_origin) / world_size, vec2(0.0), vec2(1.0));
	FrontField w = sample_front_field(wp);

	if (w.cloud <= 0.001 && w.precip <= 0.001) {
		COLOR = vec4(0.0);
	} else {
		int flags = (w.type >= 0 && w.type < MAX_WEATHER_TYPES) ? weather_profile_flags[w.type] : 0;
		if ((flags & FLAG_HAS_OVERLAY) == 0) {
			COLOR = vec4(0.0);
		} else {
			int biome = int(texture(enum_atlas, uv).r * 255.0 + 0.5);
			bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
					|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);

			vec3 cloud_col = apply_cloud_tod(w.color, w.type);
			vec3 shadow_col = (w.type == WT_BLIZZARD) ? vec3(0.62, 0.68, 0.76) : vec3(0.18, 0.22, 0.28);
			vec3 col = mix(shadow_col, cloud_col, 0.62 + w.edge * 0.20);
			float alpha = clamp(w.alpha * w.cloud * weather_strength, 0.0, 0.82);

			// Ground-projected cloud shadow, drawn by the overlay pass so it stays
			// exactly aligned with the same front field as clouds and rain.
			float shadow_alpha = clamp(w.shadow * weather_strength * 0.26 * (1.0 - tod_night_factor * 0.35), 0.0, 0.36);
			col = mix(vec3(0.06, 0.08, 0.10), col, alpha / max(alpha + shadow_alpha, 0.001));
			alpha = clamp(alpha + shadow_alpha, 0.0, 0.86);

			if ((flags & FLAG_RAIN_STREAK) != 0 && w.precip > 0.001) {
				float rain = rain_field(wp, w.axis, w.precip);
				vec3 rain_col = (w.type == WT_MONSOON) ? vec3(0.48, 0.62, 0.72) : vec3(0.58, 0.66, 0.76);
				col = mix(col, rain_col, rain * 0.52);
				alpha = clamp(alpha + rain * 0.34 * weather_strength, 0.0, 0.92);
			}

			if ((flags & FLAG_SNOW_GRAIN) != 0 && w.precip > 0.001) {
				float snow = snow_field(wp, w.axis, w.precip);
				vec3 snow_col = vec3(0.88, 0.94, 1.0);
				col = mix(col, snow_col, snow * 0.66);
				alpha = clamp(alpha + snow * 0.38 * weather_strength, 0.0, 0.94);
			}

			if ((flags & FLAG_FOG_BREATHE) != 0) {
				float breathe = sin(world_time * 0.55) * 0.035;
				col = mix(col, vec3(0.76, 0.79, 0.78), 0.28);
				alpha = clamp(alpha + (0.10 + breathe) * w.cloud * weather_strength, 0.0, 0.82);
			}

			if ((flags & FLAG_LIGHTNING) != 0 && !is_water) {
				float core_gate = smoothstep(0.34, 0.82, w.core);
				float local_flash = smoothstep(0.90, 0.985, fbm(wp * 0.052 + vec2(world_time * 5.1, -11.0), 2));
				float bolt = max(storm_flash, local_flash * step(0.68, fract(world_time * 1.37))) * core_gate;
				if (bolt > 0.0) {
					col = mix(col, vec3(1.0, 0.98, 0.86), bolt * 0.78);
					alpha = clamp(alpha + bolt * 0.28, 0.0, 0.95);
				}
			}

			COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), alpha);
		}
	}
}
