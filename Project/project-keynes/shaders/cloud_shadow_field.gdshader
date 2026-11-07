shader_type canvas_item;
render_mode unshaded;

uniform sampler2D weather_lut : filter_nearest, repeat_disable;
uniform sampler2D weather_lut_prev : filter_nearest, repeat_disable;
uniform bool has_weather_prev = false;
uniform float weather_lerp = 1.0;
uniform vec2 lut_dims = vec2(1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
uniform float world_time = 0.0;
uniform float cloud_shadow_coverage_gain = 1.35;
uniform float cloud_shadow_motion_speed = 0.075;
uniform float cloud_shadow_shape_contrast = 1.0;
uniform float cloud_shadow_noise_warp = 0.28;
uniform float cloud_shadow_mask_bias = 0.0;
uniform float cloud_shadow_cell_scale = 0.75;
uniform float cloud_shadow_world_scale = 0.0045;
uniform vec2 global_wind = vec2(0.35, 0.12);

#ifdef CLOUD_SHADOW_LOCAL_WIND
uniform sampler2D wind_lut : filter_nearest, repeat_disable;
uniform bool has_local_wind = false;
#endif

#define VT_USE_MAP_INDEX
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"

int decode_cell_id(vec2 uv) {
	vec2 id_bytes = visual_sample_map_index(uv).gb;
	int cell_id = int(id_bytes.r * 255.0 + 0.5) + 256 * int(id_bytes.g * 255.0 + 0.5);
	if (cell_id >= 65535 || float(cell_id) >= lut_dims.x * lut_dims.y) {
		return -1;
	}
	return cell_id;
}

vec2 cell_lut_uv(int cell_id) {
	float width = max(lut_dims.x, 1.0);
	return (vec2(mod(float(cell_id), width), floor(float(cell_id) / width)) + 0.5)
		/ max(lut_dims, vec2(1.0));
}

vec4 weather_at(vec2 uv) {
	int cell_id = decode_cell_id(uv);
	if (cell_id < 0) {
		return vec4(0.0);
	}
	vec4 current = texture(weather_lut, cell_lut_uv(cell_id));
	if (!has_weather_prev) {
		return current;
	}
	vec4 previous = texture(weather_lut_prev, cell_lut_uv(cell_id));
	current.gba = mix(previous.gba, current.gba, clamp(weather_lerp, 0.0, 1.0));
	return current;
}

float cloud_hash(vec2 p) {
	float h = fract(dot(p, vec2(0.1031, 0.11369)));
	h *= h + 33.33;
	h *= h + h;
	return fract(h);
}

vec2 cloud_hash22(vec2 p) {
	return vec2(
		cloud_hash(p + vec2(17.13, 3.71)),
		cloud_hash(p + vec2(5.17, 29.41)));
}

// Worley/Cellular 风格的云核。返回当前细胞内距离最近的随机核的反距离，
// 用于把连续 FBM 拆成一朵朵可辨认的独立云块。
float cloud_cellular(vec2 p) {
	vec2 base = floor(p);
	vec2 f = fract(p);
	float min_distance = 4.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 cell = vec2(float(x), float(y));
			vec2 point = cloud_hash22(base + cell);
			vec2 delta = cell + point - f;
			min_distance = min(min_distance, dot(delta, delta));
		}
	}
	return clamp(1.0 - sqrt(min_distance), 0.0, 1.0);
}

float cloud_noise(vec2 p, float period_x) {
	vec2 base = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float x0 = mod(base.x, period_x);
	float x1 = mod(base.x + 1.0, period_x);
	float a = mix(cloud_hash(vec2(x0, base.y)), cloud_hash(vec2(x1, base.y)), f.x);
	float b = mix(cloud_hash(vec2(x0, base.y + 1.0)), cloud_hash(vec2(x1, base.y + 1.0)), f.x);
	return mix(a, b, f.y);
}

vec2 sample_wind(vec2 uv) {
#ifdef CLOUD_SHADOW_LOCAL_WIND
	if (has_local_wind) {
		int cell_id = decode_cell_id(uv);
		if (cell_id >= 0) {
			vec4 encoded = texture(wind_lut, cell_lut_uv(cell_id));
			vec2 direction = encoded.rg * 2.0 - 1.0;
			float speed = encoded.b;
			float direction_length = length(direction);
			if (direction_length > 0.01) {
				return direction / direction_length * (0.25 + speed);
			}
		}
	}
#endif
	return global_wind;
}

vec2 wrap_field_uv(vec2 uv) {
	if (wrap_period_x > 0.0001 && world_size.x > 0.0001) {
		float world_x = world_origin.x + uv.x * world_size.x;
		float wrapped_x = wrap_origin_x + mod(world_x - wrap_origin_x, wrap_period_x);
		uv.x = (wrapped_x - world_origin.x) / world_size.x;
	} else {
		uv.x = clamp(uv.x, 0.0, 1.0);
	}
	uv.y = clamp(uv.y, 0.0, 1.0);
	return uv;
}

void fragment() {
	vec2 mask_uv = wrap_field_uv(UV);
	vec2 wind = sample_wind(mask_uv);
#ifdef CLOUD_SHADOW_LOCAL_WIND
	// 两步反向采样局地风场，得到比单点风向更稳定的局部平流方向。
	vec2 wind_probe_uv = wrap_field_uv(mask_uv - wind * (world_time * 0.0015));
	wind = 0.5 * (wind + sample_wind(wind_probe_uv));
#endif
	vec4 weather = weather_at(mask_uv);
	float coverage = clamp(weather.b + 0.6 * weather.a, 0.0, 1.0);
	float cloud_shadow = 0.0;
	if (coverage > 0.001) {
		// LUT 云量只定义云影可以出现的范围；形状和运动来自独立噪声场。
		float masked_coverage = clamp(coverage * cloud_shadow_coverage_gain, 0.0, 1.0);
		float mask = smoothstep(cloud_shadow_mask_bias,
			min(cloud_shadow_mask_bias + 0.66, 1.0), masked_coverage);
		// 反向追踪采样点：纹理中的云团沿风向前进，而不是反向漂移。
		vec2 noise_offset = -wind * world_time * cloud_shadow_motion_speed;
		vec2 world_pos = world_origin + mask_uv * world_size;
		vec2 noise_uv = world_pos * cloud_shadow_world_scale + noise_offset;
		float noise_period_x = max(wrap_period_x * cloud_shadow_world_scale, 4.0);
		// 第二级噪声只负责扭曲主噪声坐标，避免出现两层互相独立的贴图感。
		vec2 warp_uv = noise_uv * 0.42 + vec2(7.1, 3.2);
		float warp_period_x = max(noise_period_x * 0.42, 4.0);
		float warp_x = cloud_noise(warp_uv, warp_period_x);
		float warp_y = cloud_noise(warp_uv + vec2(-4.3, 8.7), warp_period_x);
		vec2 warped_noise_uv = noise_uv
			+ (vec2(warp_x, warp_y) - vec2(0.5)) * cloud_shadow_noise_warp * 2.4;
		float low_frequency = cloud_noise(warped_noise_uv, noise_period_x);
		float cloud_body = smoothstep(0.34, 0.68, low_frequency);
		float cloud_cell = cloud_cellular(warped_noise_uv
			* vec2(cloud_shadow_cell_scale * 0.34, cloud_shadow_cell_scale * 0.26));
		float cell_breakup = smoothstep(0.22, 0.78, cloud_cell);
#ifdef CLOUD_SHADOW_DETAIL_HIGH
		float mid_frequency = cloud_noise(warped_noise_uv * vec2(1.9, 1.7) + vec2(3.0, 9.0), noise_period_x * 1.9);
		float detail_cell = cloud_cellular(warped_noise_uv
			* vec2(cloud_shadow_cell_scale * 0.78, cloud_shadow_cell_scale * 0.60)
			+ vec2(4.0, 7.0));
		float detail_breakup = smoothstep(0.26, 0.78, detail_cell);
		float shape = cloud_body * mix(0.78, 1.0, cell_breakup)
			* mix(0.76, 1.0, mix(low_frequency, mid_frequency, 0.28))
			* mix(0.88, 1.0, detail_breakup * 0.35);
#elif defined(CLOUD_SHADOW_DETAIL_MID)
		float mid_frequency = cloud_noise(warped_noise_uv * vec2(1.55, 1.4) + vec2(3.0, 9.0), noise_period_x * 1.55);
		float shape = cloud_body * mix(0.80, 1.0, cell_breakup)
			* mix(0.78, 1.0, mix(low_frequency, mid_frequency, 0.18));
#else
		float shape = cloud_body * mix(0.82, 1.0, cell_breakup)
			* mix(0.80, 1.0, low_frequency);
#endif
		float cloud_edge = smoothstep(0.34, 0.64, shape);
		float cloud_core = smoothstep(0.56, 0.82, shape);
		float cloud_floor = mix(0.42, 0.06, cloud_shadow_shape_contrast);
		cloud_shadow = mask * (mix(cloud_floor, 0.82, cloud_edge) + cloud_core * 0.24);
#ifdef CLOUD_SHADOW_DETAIL_LOW
		cloud_shadow *= 0.92;
#endif
	}
	COLOR = vec4(clamp(cloud_shadow, 0.0, 1.0), 0.0, 0.0, 1.0);
}
