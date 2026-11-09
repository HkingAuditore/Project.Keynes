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
uniform vec2 cloud_shadow_uv_offset = vec2(0.0);
uniform float cloud_shadow_coverage_gain = 1.35;
uniform float cloud_shadow_motion_speed = 0.075;
// UV 平流增益。motion_speed 保留为世界尺度调参，单独的增益避免
// 小地图/大地图在归一化 UV 后看起来像完全不动。
uniform float cloud_shadow_uv_scroll_gain = 8.0;
uniform float cloud_shadow_shape_contrast = 1.0;
uniform float cloud_shadow_noise_warp = 0.28;
uniform float cloud_shadow_dynamic_detail_gain = 0.32;
uniform float cloud_shadow_dynamic_warp_gain = 0.80;
uniform float cloud_shadow_edge_softness = 0.82;
uniform float cloud_shadow_wind_influence = 0.22;
uniform float cloud_shadow_mask_bias = 0.0;
uniform float cloud_shadow_cell_scale = 0.75;
uniform float cloud_shadow_world_scale = 0.0045;
uniform float cloud_shadow_erosion = 0.55;
// 天气 LUT 的连续量空间混合参数保留为材质 ABI；实际权重现在由世界空间
// 六边形中心距离计算，不再把整格邻居平均值铺满当前 cell。
uniform float cloud_shadow_hex_world_diameter = 44.0;
// [cloud-tex 2026-11-07] 离线烘焙的 Perlin-Worley 无缝噪声（tools/prebake_cloud_shadow_noise.gd）：
//   R = 主体形状（低频 Perlin-Worley，蓬松连通）G = 中频 Worley 反相（边缘侵蚀）
//   B = 高频 Worley 反相（细节）        A = 低频 Perlin（域扭曲位移场）
// cloud_shadow_base_tex 是另一张离线底图；它只提供宏观云团覆盖，不在运行时烘焙。
uniform sampler2D cloud_shadow_base_tex : filter_linear_mipmap, repeat_enable;
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

vec2 weather_world_to_uv(vec2 world_pos) {
	if (wrap_period_x > 0.0001) {
		world_pos.x = wrap_origin_x + mod(world_pos.x - wrap_origin_x, wrap_period_x);
	}
	return vec2(
		(world_pos.x - world_origin.x) / max(world_size.x, 0.0001),
		clamp((world_pos.y - world_origin.y) / max(world_size.y, 0.0001), 0.0, 1.0)
	);
}

vec2 weather_hex_center(vec3 cube) {
	float radius = max(cloud_shadow_hex_world_diameter * 0.5, 1.0);
	return vec2(
		sqrt(3.0) * radius * (cube.x + 0.5 * cube.y),
		1.5 * radius * cube.y);
}

vec3 weather_cube_round(vec3 cube) {
	vec3 rounded = floor(cube + 0.5);
	vec3 delta = abs(rounded - cube);
	if (delta.x > delta.y && delta.x > delta.z) {
		rounded.x = -rounded.y - rounded.z;
	} else if (delta.y > delta.z) {
		rounded.y = -rounded.x - rounded.z;
	} else {
		rounded.z = -rounded.x - rounded.y;
	}
	return rounded;
}

vec4 weather_cell_value(int cell_id) {
	if (cell_id < 0 || float(cell_id) >= lut_dims.x * lut_dims.y) {
		return vec4(0.0);
	}
	vec4 current = texture(weather_lut, cell_lut_uv(cell_id));
	if (has_weather_prev) {
		vec4 previous = texture(weather_lut_prev, cell_lut_uv(cell_id));
		current.gba = mix(previous.gba, current.gba, clamp(weather_lerp, 0.0, 1.0));
	}
	return current;
}

vec4 weather_at(vec2 uv) {
	vec2 world_pos = world_origin + uv * world_size;
	float radius = max(cloud_shadow_hex_world_diameter * 0.5, 1.0);
	float qf = (sqrt(3.0) / 3.0 * world_pos.x - world_pos.y / 3.0) / radius;
	float rf = (2.0 / 3.0 * world_pos.y) / radius;
	vec3 center_cube = weather_cube_round(vec3(qf, rf, -qf - rf));
	vec2 center_world = weather_hex_center(center_cube);
	vec2 east = vec2(sqrt(3.0) * radius, 0.0);
	vec2 diag = vec2(sqrt(3.0) * radius * 0.5, 1.5 * radius);
	vec2 candidates[7] = vec2[7](
		center_world,
		center_world + east,
		center_world - east,
		center_world + diag,
		center_world + vec2(-diag.x, diag.y),
		center_world - diag,
		center_world + vec2(diag.x, -diag.y)
	);
	vec3 weather_sum = vec3(0.0);
	float weight_sum = 0.0;
	float support = 1.55 * radius;
	int center_id = decode_cell_id(weather_world_to_uv(center_world));
	for (int i = 0; i < 7; i++) {
		int candidate_id = decode_cell_id(weather_world_to_uv(candidates[i]));
		if (candidate_id < 0) {
			continue;
		}
		float distance_to_sample = length(candidates[i] - world_pos);
		float weight = 1.0 - smoothstep(0.0, support, distance_to_sample);
		if (weight <= 0.0001) {
			continue;
		}
		weather_sum += weather_cell_value(candidate_id).gba * weight;
		weight_sum += weight;
	}
	if (weight_sum <= 0.0001) {
		return weather_cell_value(center_id);
	}
	// 天气类型仍保留中心 cell；云量/水汽则按世界空间中的六边形中心距离
	// 连续混合。这里不再把整格邻居平均值铺满当前 cell。
	vec4 center = weather_cell_value(center_id);
	return vec4(center.r, weather_sum / weight_sum);
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

vec2 sample_wind_cell(int cell_id) {
#ifdef CLOUD_SHADOW_LOCAL_WIND
	if (has_local_wind) {
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
	return vec2(0.0);
}

vec2 sample_wind(vec2 uv) {
#ifdef CLOUD_SHADOW_LOCAL_WIND
	if (has_local_wind) {
		vec2 world_pos = world_origin + uv * world_size;
		float radius = max(cloud_shadow_hex_world_diameter * 0.5, 1.0);
		float qf = (sqrt(3.0) / 3.0 * world_pos.x - world_pos.y / 3.0) / radius;
		float rf = (2.0 / 3.0 * world_pos.y) / radius;
		vec3 center_cube = weather_cube_round(vec3(qf, rf, -qf - rf));
		vec2 center_world = weather_hex_center(center_cube);
		vec2 east = vec2(sqrt(3.0) * radius, 0.0);
		vec2 diag = vec2(sqrt(3.0) * radius * 0.5, 1.5 * radius);
		vec2 candidates[7] = vec2[7](
			center_world,
			center_world + east,
			center_world - east,
			center_world + diag,
			center_world + vec2(-diag.x, diag.y),
			center_world - diag,
			center_world + vec2(diag.x, -diag.y)
		);
		vec2 wind_sum = vec2(0.0);
		float weight_sum = 0.0;
		float support = 1.55 * radius;
		for (int i = 0; i < 7; i++) {
			int candidate_id = decode_cell_id(weather_world_to_uv(candidates[i]));
			vec2 cell_wind = sample_wind_cell(candidate_id);
			float distance_to_sample = length(candidates[i] - world_pos);
			float weight = 1.0 - smoothstep(0.0, support, distance_to_sample);
			if (weight > 0.0001 && dot(cell_wind, cell_wind) > 0.0001) {
				wind_sum += cell_wind * weight;
				weight_sum += weight;
			}
		}
		if (weight_sum > 0.0001 && dot(wind_sum, wind_sum) > 0.0001) {
			return wind_sum / weight_sum;
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
	// UV 只用来定位当前 field texel；所有云形采样统一从世界空间位置派生，
	// 不随 cell mesh 或局部 UV 重置。
	vec2 world_pos = world_origin + mask_uv * world_size;
	vec4 weather = weather_at(mask_uv);
	float coverage = clamp(weather.b + 0.6 * weather.a, 0.0, 1.0);
	float cloud_shadow = 0.0;
	if (coverage > 0.001) {
		// LUT 云量只定义云影可以出现的范围；形状和运动来自独立噪声场。
		float masked_coverage = clamp(coverage * cloud_shadow_coverage_gain, 0.0, 1.0);
		float edge_softness = clamp(cloud_shadow_edge_softness, 0.0, 2.0);
		float mask_softness = clamp(edge_softness, 0.0, 1.0);
		float mask_lo = max(cloud_shadow_mask_bias - 0.06 * mask_softness, 0.0);
		float mask_hi = min(cloud_shadow_mask_bias + 0.80 + 0.16 * mask_softness, 1.0);
		float mask = smoothstep(mask_lo, mask_hi, masked_coverage);
		// 反向追踪采样点：纹理中的云团沿风向前进，而不是反向漂移。
		// [cloud-tex 2026-11-07] 不再逐像素算 value noise —— 它在格点取极值、插值
		// 丢失方向性，阈值化后必然露出格子/枕头伪影（之前那条"接缝"和方块感都是
		// 它）。改为采样离线烘焙的 Perlin-Worley 纹理，四个通道一次拿到完整多尺度
		// 结构；纹理本身无缝，且一个周期正好等于世界 wrap 周期，所以 UV 线性映射
		// 天然连续，连整数周期 floor 对齐都不需要了。
		float world_wrap = max(wrap_period_x, 1.0);
		// X 使用圆柱 wrap 原点；Y 不应使用绝对世界坐标。地图赤道附近
		// world_pos.y 会穿过 0，直接除以 world_wrap 会让 repeat 纹理在赤道
		// 发生一次 UV 折返，形成整条横向断裂。改用相对 world_origin.y 的
		// 非负世界距离，噪声仍是 world-space 且不会在赤道重置。
		vec2 base_uv = vec2(
			(world_pos.x - wrap_origin_x) / world_wrap,
			(world_pos.y - world_origin.y) / world_wrap);
		// 位移由 CPU 按每帧 dt 累积；不能写成 wind * world_time，否则天气
		// tick 更新风场后会把整张噪声历史相位瞬间重算，表现为形状跳变。
		vec2 drift = cloud_shadow_uv_offset;
		// 局地风只做低幅度世界空间方向修正；主位移仍由 CPU 累积，避免
		// cell 风场更新时重新计算历史相位。高画质 field 额外承担这组采样，
		// 地形/水面 shader 不重复执行。
		vec2 local_wind = sample_wind(mask_uv);
		float local_wind_len = length(local_wind);
		float global_wind_len = length(global_wind);
		vec2 global_wind_axis = global_wind_len > 0.001
			? global_wind / global_wind_len : vec2(1.0, 0.0);
		vec2 local_wind_axis = local_wind_len > 0.001
			? local_wind / local_wind_len : global_wind_axis;
		float local_wind_factor = clamp(local_wind_len * 0.45, 0.0, 1.0);
		vec2 wind_flow_warp = local_wind_axis * local_wind_factor
			* cloud_shadow_wind_influence * 0.018;
		// 底图和动态噪声使用同一套 world-space UV，但速度略慢，形成宏观云团
		// 带着中高频结构一起平流、内部细节又有相对变化的效果。
		vec4 base_layer = texture(cloud_shadow_base_tex, base_uv + drift * 0.65);
		float macro_density = smoothstep(0.20, 0.82, base_layer.r);
		float macro_edge = smoothstep(0.24, 0.78, base_layer.g);
		// 域扭曲用 A 通道（低频 Perlin）做两次错位采样，得到两个独立位移分量。
		float warp_x = texture(cloud_noise_tex,
			base_uv + drift * 0.75 + vec2(0.317, 0.113)).a;
		float warp_y = texture(cloud_noise_tex,
			base_uv + drift * 0.75 + vec2(0.731, 0.427)).a;
		vec4 dynamic_warp_n = textureLod(cloud_noise_tex,
			base_uv * 1.35 + drift * 0.85 + vec2(0.217, 0.613), 1.0);
		vec2 dynamic_warp = (dynamic_warp_n.ra - vec2(0.5)) * 2.0
			* cloud_shadow_dynamic_warp_gain * 0.035;
		// 仿洋流的连续剪切：复用动态 warp 的 A 通道作为局部相位，
		// 用 world_time 平滑改变拉伸方向，不重新生成噪声，也不引入 FBM 循环。
		float flow_phase = world_time * 0.055 + dynamic_warp_n.a * 6.2831853;
		vec2 flow_ortho = vec2(-local_wind_axis.y, local_wind_axis.x);
		vec2 flow_shear = (local_wind_axis * 0.006 + flow_ortho * 0.003)
			* sin(flow_phase) * clamp(cloud_shadow_dynamic_warp_gain, 0.0, 2.0);
		vec2 uv_shaped = base_uv + drift
			+ wind_flow_warp + dynamic_warp + flow_shear
			+ (vec2(warp_x, warp_y) - vec2(0.5)) * 2.0
				* cloud_shadow_noise_warp * 0.05;
		vec2 detail_uv = uv_shaped * 1.75 + drift * 0.45 + vec2(0.173, 0.391);
		// [cloud-soft 2026-11-07] 采 mip 0.8 而不是 mip 0：云影的真实观感是
		// "从中心缓慢淡出"，mip0 的高频细节会让边界出现可辨认的硬轮廓（用户反馈
		// "边界太硬"）。抬高 mip 等于一次免费的低通滤波，过渡带宽度翻几倍。
		vec4 n = textureLod(cloud_noise_tex, uv_shaped, 0.8);
		float shape = n.r
			- (n.g - 0.5) * cloud_shadow_erosion
			- (n.b - 0.5) * cloud_shadow_erosion * 0.30;
		vec4 detail_n = textureLod(cloud_noise_tex, detail_uv, 1.15);
		float dynamic_detail = detail_n.g * 0.65 + detail_n.b * 0.35;
		// 底图控制宏观覆盖，运行时细节只在底图内部做连续明暗变化；这样
		// LUT 更新不会重新决定云团轮廓，world_time 也不会重置噪声相位。
		shape = shape * mix(0.62, 1.18, macro_density)
			+ (macro_edge - 0.5) * 0.12
			+ (dynamic_detail - 0.5) * cloud_shadow_dynamic_detail_gain;
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
		float edge_lo = max(0.05, 0.28 - 0.13 * edge_softness);
		float edge_hi = min(1.04, 0.82 + 0.13 * edge_softness);
		float core_gain = max(1.0, 1.70 - 0.48 * edge_softness);
		float density = min(smoothstep(edge_lo, edge_hi, shape) * core_gain, 1.0);
		cloud_shadow = mask * (cloud_floor
			+ (1.0 - cloud_floor) * density);
#ifdef CLOUD_SHADOW_DETAIL_LOW
		cloud_shadow *= 0.92;
#endif
	}
	COLOR = vec4(clamp(cloud_shadow, 0.0, 1.0), 0.0, 0.0, 1.0);
}
