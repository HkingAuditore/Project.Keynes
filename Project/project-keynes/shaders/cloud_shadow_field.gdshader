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
uniform float cloud_shadow_erosion = 0.55;
// [cloud-tex 2026-11-07] 离线烘焙的 Perlin-Worley 无缝噪声（tools/prebake_cloud_shadow_noise.gd）：
//   R = 主体形状（低频 Perlin-Worley，蓬松连通）G = 中频 Worley 反相（边缘侵蚀）
//   B = 高频 Worley 反相（细节）        A = 低频 Perlin（域扭曲位移场）
uniform sampler2D cloud_noise_tex : filter_linear_mipmap, repeat_enable;
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
			min(cloud_shadow_mask_bias + 0.80, 1.0), masked_coverage);
		// 反向追踪采样点：纹理中的云团沿风向前进，而不是反向漂移。
		// [cloud-tex 2026-11-07] 不再逐像素算 value noise —— 它在格点取极值、插值
		// 丢失方向性，阈值化后必然露出格子/枕头伪影（之前那条"接缝"和方块感都是
		// 它）。改为采样离线烘焙的 Perlin-Worley 纹理，四个通道一次拿到完整多尺度
		// 结构；纹理本身无缝，且一个周期正好等于世界 wrap 周期，所以 UV 线性映射
		// 天然连续，连整数周期 floor 对齐都不需要了。
		float world_wrap = max(wrap_period_x, 1.0);
		vec2 world_pos = world_origin + mask_uv * world_size;
		vec2 base_uv = vec2(world_pos.x / world_wrap, world_pos.y / world_wrap);
		float drift_scale = 1.0 / max(world_wrap * cloud_shadow_world_scale, 1.0);
		vec2 drift = -wind * world_time * cloud_shadow_motion_speed * drift_scale;
		// 域扭曲用 A 通道（低频 Perlin）做两次错位采样，得到两个独立位移分量。
		float warp_x = texture(cloud_noise_tex, base_uv + vec2(0.317, 0.113)).a;
		float warp_y = texture(cloud_noise_tex, base_uv + vec2(0.731, 0.427)).a;
		vec2 uv_shaped = base_uv + drift
			+ (vec2(warp_x, warp_y) - vec2(0.5)) * 2.0
				* cloud_shadow_noise_warp * 0.05;
		// [cloud-soft 2026-11-07] 采 mip 0.8 而不是 mip 0：云影的真实观感是
		// "从中心缓慢淡出"，mip0 的高频细节会让边界出现可辨认的硬轮廓（用户反馈
		// "边界太硬"）。抬高 mip 等于一次免费的低通滤波，过渡带宽度翻几倍。
		vec4 n = textureLod(cloud_noise_tex, uv_shaped, 0.8);
		float shape = n.r
			- (n.g - 0.5) * cloud_shadow_erosion
			- (n.b - 0.5) * cloud_shadow_erosion * 0.30;
		// [cloud-shape 2026-11-07] 原来是 edge/core 两级 smoothstep 相加，云内部会
		// 叠出两三档"台阶"，放大后就是一块块灰斑。改成单条连续密度曲线：shape
		// 从 0.30 升到 0.78 的过程本身就是云的厚薄，边缘自然羽化、中心连续加深。
		// 阈值区间按烘焙纹理的实际分布标定：Perlin-Worley 的均值约 0.55，
		// 取 0.52~0.88 才能让"云体中部"落在曲线上升段，否则整屏都是云。
		// 区间从 0.44~0.72 拉到 0.28~0.82：过渡带完全展开，云影从中心到边缘
		// 是一条长坡而不是一道台阶。同时不再乘 1.55（原来是把曲线抬陡，正好
		// 与"要软"相反）。
		float cloud_floor = mix(0.24, 0.02, cloud_shadow_shape_contrast);
		// 乘 1.7 让云心达到满值、形成一段"平台"，但**不缩窄区间** —— 边缘仍走
		// 0.28~0.82 的长坡。缩窄区间才是"硬边"，抬幅度只是"更浓"。
		float density = min(smoothstep(0.28, 0.82, shape) * 1.7, 1.0);
		cloud_shadow = mask * (cloud_floor
			+ (1.0 - cloud_floor) * density);
#ifdef CLOUD_SHADOW_DETAIL_LOW
		cloud_shadow *= 0.92;
#endif
	}
	COLOR = vec4(clamp(cloud_shadow, 0.0, 1.0), 0.0, 0.0, 1.0);
}
