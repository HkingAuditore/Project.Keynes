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
// [cloud-tiling 2026-11-18] 每个世界 wrap 周期里铺几遍噪声纹理，取整生效：
// tile_period = world_wrap / repeat。只有整数除，fold 两侧才会采到同一 texel
// （非整数除会在接缝处错半格 → 一条竖向的错位缝）。
// 1 = 一个周期铺满（云团直径 3~5 格）；2 = 云团减半、数量翻倍。
// 这个值以前是 cloud_shadow_cell_scale，但那个 uniform 在 2026-11-07 重写形状
// 采样时被漏掉、从未被读取过 —— 所以"调 tiling 没反应"是必然的。
uniform float cloud_shadow_tile_repeat = 1.0;
// 云体内部的厚薄调制幅度：0 = 云心是一个常数值（一块铁板），1 = 最强。
uniform float cloud_shadow_interior_detail = 0.45;
// 云形各段的采样 LOD 由"世界 texel 尺寸"解析算出，不能用 texture() 的隐式导数：
// 本 shader 的 UV 是折叠过的，fold 处 d(base_uv)/dpixel 会爆到一整个周期，
// 隐式 LOD 于是在那一两列取到最粗 mip —— 那就是东西接缝的真正来源。
// cloud_noise_texel_world = tile_period / 噪声纹理宽度，由 CPU 侧写入。
uniform float cloud_noise_texel_world = 5.95;
// 云形采样的目标世界 texel（越大越柔）。实际 footprint 取它和场像素世界尺寸
// 的较大者，所以低分辨率场（LOW/MID/移动端）也不会走样。
uniform float cloud_shadow_detail_texel_world = 8.0;
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
uniform sampler2D wind_lut : filter_nearest, repeat_disable;
uniform bool has_local_wind = false;
uniform sampler2D wind_lut_prev : filter_nearest, repeat_disable;
uniform bool has_wind_prev = false;

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

// [cloud-tiling 2026-11-18] 这里原来还留着 value noise / cellular 三个函数，
// 自从 2026-11-07 改成采样预烘 Perlin-Worley 纹理后就再没有调用点。删掉，
// 免得下次又被当成"云形来源"去调参。
vec2 decode_wind(vec4 encoded) {
	vec2 direction = encoded.rg * 2.0 - 1.0;
	float direction_length = length(direction);
	return direction_length > 0.01
		? direction / direction_length * (0.25 + encoded.b) : vec2(0.0);
}

vec2 sample_wind_cell(int cell_id) {
	if (has_local_wind) {
		if (cell_id >= 0) {
			vec2 uv = cell_lut_uv(cell_id);
			vec2 current = decode_wind(texture(wind_lut, uv));
			if (has_wind_prev) {
				vec2 previous = decode_wind(texture(wind_lut_prev, uv));
				return mix(previous, current, clamp(weather_lerp, 0.0, 1.0));
			}
			return current;
		}
	}
	return vec2(0.0);
}

vec2 sample_wind(vec2 uv) {
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
	return vec2(0.0);
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

// [cloud-tiling 2026-11-18] 每段的采样 LOD 都从"采样 footprint 的世界尺寸"解析
// 算出来，绝不依赖 texture() 的隐式导数：本 shader 的世界 UV 在 fold 处会从
// 一整周期跳到 0，导数随之爆炸，隐式 LOD 会在那一两列直接取到最粗 mip —— 一条
// 竖向硬缝就是这么来的（用探针在恒定天气下量到的 fold 列梯度是平均列的 4.7 倍）。
float cloud_band_lod(float footprint_world, float freq) {
	float texel_world = max(cloud_noise_texel_world, 0.0001);
	return log2(max(footprint_world * freq / texel_world, 1.0));
}

float cloud_flow_shape(vec2 base_uv, vec2 drift, vec2 local_wind,
		float footprint_world, out float puff) {
	float local_wind_len = length(local_wind);
	vec2 local_wind_axis = local_wind_len > 0.001
		? local_wind / local_wind_len : vec2(1.0, 0.0);
	float local_wind_factor = clamp(local_wind_len * 0.45, 0.0, 1.0);
	vec2 wind_flow_warp = local_wind_axis * local_wind_factor
		* cloud_shadow_wind_influence * 0.018;
	float lod_base = cloud_band_lod(footprint_world, 1.0);
	// 底图和动态噪声使用同一套 world-space UV，但速度略慢，形成宏观云团
	// 带着中高频结构一起平流、内部细节又有相对变化的效果。
	vec4 base_layer = textureLod(cloud_shadow_base_tex,
		base_uv + drift * 0.65, lod_base);
	float macro_density = smoothstep(0.20, 0.82, base_layer.r);
	float macro_edge = smoothstep(0.24, 0.78, base_layer.g);
	vec2 uv_shaped = base_uv + drift + wind_flow_warp;
	float dynamic_detail = 0.5;
#ifndef CLOUD_SHADOW_DETAIL_LOW
	// [cloud-tiling 2026-11-18] 倍频必须是**整数**。噪声纹理一个周期正好等于世界
	// wrap 周期，采样频率 f 意味着纹理周期变成 1/f 个世界周期；f 不是整数时，
	// 跨过东西 wrap（base_uv 从 1 跳到 0）采样相位会跳 (f - floor(f)) 个纹理周期
	// ——1.35 就是跳 0.35 周期（约 1067 世界单位），detail 的 1.75 跳 0.75。
	// 表现就是接缝两侧云纹错位、并多出一条硬边。实测：把 base_uv.x 换成原始 UV
	// 接缝立刻消失（最大列梯度 0.027，中位 0.017）；tile_repeat=2 时接缝仍只在
	// 世界 wrap 出现、不在噪声自己的 wrap 出现 —— 都指向倍频相位，不是贴图或 LOD。
	vec4 dynamic_warp_n = textureLod(cloud_noise_tex,
		base_uv * 2.0 + drift * 0.85 + vec2(0.217, 0.613),
		cloud_band_lod(footprint_world, 2.0));
	uv_shaped += (dynamic_warp_n.ra - vec2(0.5)) * 2.0
		* cloud_shadow_dynamic_warp_gain * 0.035;
	vec4 detail_n = textureLod(cloud_noise_tex,
		uv_shaped * 2.0 + drift * 0.45 + vec2(0.173, 0.391),
		cloud_band_lod(footprint_world, 2.0));
	dynamic_detail = detail_n.g * 0.65 + detail_n.b * 0.35;
#ifdef CLOUD_SHADOW_DETAIL_HIGH
	// 高档额外域扭曲和风向剪切；低/中档不编译这些采样。
	float warp_x = textureLod(cloud_noise_tex,
		base_uv + drift * 0.75 + vec2(0.317, 0.113), lod_base).a;
	float warp_y = textureLod(cloud_noise_tex,
		base_uv + drift * 0.75 + vec2(0.731, 0.427), lod_base).a;
	uv_shaped += (vec2(warp_x, warp_y) - vec2(0.5)) * 2.0 * cloud_shadow_noise_warp * 0.05;
	float flow_phase = world_time * 0.055 + dynamic_warp_n.a * 6.2831853;
	vec2 flow_ortho = vec2(-local_wind_axis.y, local_wind_axis.x);
	uv_shaped += (local_wind_axis * 0.006 + flow_ortho * 0.003)
		* sin(flow_phase) * clamp(cloud_shadow_dynamic_warp_gain, 0.0, 2.0);
#endif
#endif
	vec4 n = textureLod(cloud_noise_tex, uv_shaped, lod_base);
	// puff：云胞内部高、胞界低。它不是云形，而是"这块云有多厚"—— 乘在最终
	// 密度上，给云心做出起伏。以前 n.g 只以 erosion 的身份参与 shape，云心
	// 一旦越过阈值就被抹成常数，所以单块云影内部是一块铁板。
	puff = clamp(n.g, 0.0, 1.0);
	float shape = n.r
		- (n.g - 0.5) * cloud_shadow_erosion
		- (n.b - 0.5) * cloud_shadow_erosion * 0.30;
	// 底图和细节在同一平流相位中合成，然后由两相位交替混合。
	shape = shape * mix(0.62, 1.18, macro_density)
		+ (macro_edge - 0.5) * 0.12
		+ (dynamic_detail - 0.5) * cloud_shadow_dynamic_detail_gain;
	return shape;
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
		// [cloud-tiling 2026-11-18] 平铺次数取整后除周期：只有整数除，fold 两侧
		// 才会落在同一 texel 上（非整数除 = 接缝错半格）。
		float tile_repeat = max(1.0, floor(cloud_shadow_tile_repeat + 0.5));
		float tile_period = world_wrap / tile_repeat;
		// X 使用圆柱 wrap 原点；Y 不应使用绝对世界坐标。地图赤道附近
		// world_pos.y 会穿过 0，直接除以世界周期会让 repeat 纹理在赤道
		// 发生一次 UV 折返，形成整条横向断裂。改用相对 world_origin.y 的
		// 非负世界距离，噪声仍是 world-space 且不会在赤道重置。
		vec2 base_uv = vec2(
			(world_pos.x - wrap_origin_x) / tile_period,
			(world_pos.y - world_origin.y) / tile_period);
		// 采样 footprint 用**未折叠**的 UV 求导：UV 是场 quad 上的线性参数，
		// 这里的 fwidth 恒定，不会被 fold 污染。取 x/y 较大者（纵向 texel
		// 通常更粗）。再和"目标柔化 texel"取大者，低分辨率场也不会走样。
		float footprint_world = max(
			fwidth(UV.x) * world_size.x,
			fwidth(UV.y) * world_size.y);
		footprint_world = max(footprint_world, cloud_shadow_detail_texel_world);
		vec2 local_wind = sample_wind(mask_uv);
		float drift_scale = cloud_shadow_motion_speed * cloud_shadow_uv_scroll_gain
			/ max(world_wrap * cloud_shadow_world_scale, 1.0);
		// 与 water_hash_ripple_flow 相同：双相位错开半周期，重置时权重为零。
		// 风只乘当前周期的有界时长，避免换风造成与总运行时间成正比的跳变。
		float cycle_seconds = 24.0;
		float phase0 = fract(world_time / cycle_seconds);
		float phase1 = fract(phase0 + 0.5);
		float weight0 = 1.0 - abs(1.0 - 2.0 * phase0);
		vec2 adv = -local_wind * drift_scale * cycle_seconds;
		float puff0 = 0.5;
		float puff1 = 0.5;
		float shape0 = cloud_flow_shape(base_uv, adv * phase0, local_wind,
			footprint_world, puff0);
		float shape1 = cloud_flow_shape(base_uv, adv * phase1, local_wind,
			footprint_world, puff1);
		float shape = mix(shape1, shape0, weight0);
		float puff = mix(puff1, puff0, weight0);
		// [cloud-shape 2026-11-07] 原来是 edge/core 两级 smoothstep 相加，云内部会
		// 叠出两三档"台阶"，放大后就是一块块灰斑。改成单条连续密度曲线：shape
		// 从 0.30 升到 0.78 的过程本身就是云的厚薄，边缘自然羽化、中心连续加深。
		// 阈值区间按烘焙纹理的实际分布标定：Perlin-Worley 的均值约 0.55，
		// 取 0.52~0.88 才能让"云体中部"落在曲线上升段，否则整屏都是云。
		// 区间从 0.44~0.72 拉到 0.28~0.82：过渡带完全展开，云影从中心到边缘
		// 是一条长坡而不是一道台阶。同时不再乘 1.55（原来是把曲线抬陡，正好
		// 与"要软"相反）。
		float cloud_floor = mix(0.24, 0.02, cloud_shadow_shape_contrast);
		float edge_lo = max(0.05, 0.28 - 0.13 * edge_softness);
		float edge_hi = min(1.04, 0.82 + 0.13 * edge_softness);
		// [cloud-tiling 2026-11-18] 不再乘 core_gain：原来 1.70 把云心直接顶到
		// 1.0 并截断，于是 field 里有 6~8% 的 texel 恰好等于 1.0 —— 那就是
		// "单块云影像一块脏污"的数值来源（一整片像素完全同色，边界还是硬的）。
		// 现在云心的浓淡由 shape 本身决定，上限交给合成侧的软压缩。
		float density = smoothstep(edge_lo, edge_hi, shape);
		// 云体内部厚薄：胞内厚、胞界薄。乘在密度上而不是加进 shape，
		// 才不会被阈值和后续压缩抹平。
		density = clamp(density * mix(1.0, 0.42 + 0.66 * puff,
			clamp(cloud_shadow_interior_detail, 0.0, 1.0)), 0.0, 1.0);
		cloud_shadow = mask * (cloud_floor
			+ (1.0 - cloud_floor) * density);
#ifdef CLOUD_SHADOW_DETAIL_LOW
		cloud_shadow *= 0.92;
#endif
	}
	COLOR = vec4(clamp(cloud_shadow, 0.0, 1.0), 0.0, 0.0, 1.0);
}
