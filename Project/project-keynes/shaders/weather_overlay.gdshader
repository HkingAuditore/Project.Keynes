shader_type canvas_item;
render_mode blend_mix;

uniform sampler2D enum_atlas : filter_nearest, repeat_disable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D weather_field_tex : filter_nearest, repeat_disable;
uniform bool weather_field_enabled = false;
// Phase 1：vector_atlas（与 world_map.gdshader 共用的 RGBA8 纹理）。
//   RG = ocean_current（[-1,1] mapped from [0,1]）—— overlay 不消费
//   BA = wind_field   （[-1,1] mapped from [0,1]）—— 这里读它驱动 per-cell advection
// 仅当 wind_field_enabled = true 时启用真实风场；fallback 走旧的 axis-only 路径。
uniform sampler2D vector_atlas : filter_linear, repeat_disable;
uniform bool wind_field_enabled = false;
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

// ambient-shadow：全图飘移云影开关与强度。enabled=true 时即使 clear 天气也能看到淡淡的
// 飘动云影，给地图加一层"晴天但有云"的氛围。strength 0 = 关闭、1 = 最重。
uniform bool ambient_cloud_shadow_enabled = true;
uniform float ambient_cloud_shadow_strength : hint_range(0.0, 1.0) = 0.65;
// ambient-shadow：独立时钟，与游戏 pause 解耦，让云影即使在暂停时也持续飘动 + 变形。
// 由 weather_layer.gd 在 _process 里无条件推进。单位：秒。
uniform float ambient_shadow_time = 0.0;

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
const int B_HILL = 5;
const int B_MOUNTAIN = 6;
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

// Phase 2：廉价"蓝噪声"jitter —— 用 hash21 + golden ratio 给 FBM 采样坐标
// 加一个高频随机偏移，破除 value_noise 在低频段裸露的双线性网格感。
// 不需要外部蓝噪声纹理（项目里 assets/weather/ 目录尚不存在），
// 这种 hash-based jitter 在视觉上足以让云的边缘"碎"得更自然。
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

vec2 blue_jitter(vec2 wp, float scale) {
	// golden ratio (1.618) 让两个分量去相关，避免 jitter 自身形成条纹。
	float h1 = hash21(floor(wp * scale));
	float h2 = hash21(floor(wp * scale * 1.618 + vec2(13.0, 7.0)));
	return (vec2(h1, h2) - 0.5) * (1.0 / scale);
}

// Phase 2：高云（卷云带）—— 大尺度纤维状云，alpha 弱、覆盖广，
// 主要在 storm/monsoon 系统的"上空"提供一层"高空大气"质感。
// 用拉长的各向异性 fbm 模拟卷云的拉丝形态：水平方向频率 0.0035、
// 垂直方向 0.011，让条带沿主风向延展。
float sample_high_cloud(vec2 wp, vec2 axis, float intensity) {
	// 沿风向拉伸坐标，造成纤维状卷云。
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x);
	float u = dot(wp, dir);
	float v = dot(wp, side);
	// 高云推进慢（0.5×），但 advection 距离大（系数 0.55）。
	vec2 stretched = vec2(u * 0.0035, v * 0.011) + vec2(world_time * 0.55, world_time * 0.18);
	stretched += blue_jitter(wp, 0.04) * 0.6;
	float cirrus = fbm(stretched, 3);
	// 阈值化得到稀疏拉丝带；强度调节阈值高低。
	float band = smoothstep(0.46, 0.74, cirrus);
	// 二次纤维化：再叠一层更高频的拉丝，得到"羽毛"质感。
	float feather = fbm(stretched * 3.7 + vec2(11.0, -23.0), 2);
	band *= 0.65 + 0.55 * smoothstep(0.40, 0.78, feather);
	return clamp(band * intensity, 0.0, 1.0);
}

// Phase 2：低云/山雾 —— 浮在地面、跟随地形堆叠在山地/丘陵上空，
// 推进慢（0.3×）、强 domain warp（让雾团边缘极不规则）。
// biome_weight 在调用方根据 enum_atlas 山地/丘陵 biome 给出（0-1）。
// 当 biome_weight 极低（平原/海洋）时返回 0，避免雾覆盖整张地图。
float sample_low_fog(vec2 wp, vec2 axis, float intensity, float biome_weight) {
	if (biome_weight <= 0.001 || intensity <= 0.001) {
		return 0.0;
	}
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	// 雾不沿风向拉伸（雾贴地、各向同性），但整体缓慢漂移。
	vec2 advected = wp - dir * world_time * 1.4;
	// 强 warp：低频偏移大，让雾团边缘极破碎。
	float w1 = fbm(advected * 0.022 + vec2(world_time * 0.15, -world_time * 0.09), 2) - 0.5;
	float w2 = fbm(advected * 0.022 + vec2(-world_time * 0.11, world_time * 0.13) + vec2(53.0, 17.0), 2) - 0.5;
	vec2 warped = advected + vec2(w1, w2) * 11.0;
	warped += blue_jitter(wp, 0.06) * 0.8;
	float fog_low = fbm(warped * 0.022, 3);
	float fog_breath = sin(world_time * 0.32 + wp.x * 0.0018) * 0.04;
	// dramatic-fx：阈值 0.42 → 0.32、上界 0.78 → 0.70，让雾更早起量、覆盖更广。
	float fog = smoothstep(0.32 + fog_breath, 0.70, fog_low);
	return clamp(fog * intensity * biome_weight, 0.0, 1.0);
}

// Phase 1：采样真实风场（vector_atlas BA 通道）。
// 返回归一化风向 × 风速强度（[0,1]）。当 wind_field_enabled=false 时返回 ZERO，
// 调用方应 fallback 到 axis-only 旧路径。
//   ba ∈ [0,1] 编码了 [-1,1] 风分量；强度 = length，方向 = normalize。
//   分别返回 dir 与 speed，让调用方根据天气类型自行加权 flow_speed。
struct WindSample {
	vec2 dir;
	float speed;
};

WindSample sample_wind(vec2 uv) {
	WindSample w;
	w.dir = vec2(0.0);
	w.speed = 0.0;
	if (!wind_field_enabled) {
		return w;
	}
	vec2 ba = texture(vector_atlas, uv).ba * 2.0 - 1.0;
	float len = length(ba);
	if (len <= 0.001) {
		return w;
	}
	w.dir = ba / len;
	w.speed = clamp(len, 0.0, 1.0);
	return w;
}

// Phase B：风场驱动的 domain warp。
// 1) 沿 flow 方向做 advection（让云真正"飘"，不再原地抖）
// 2) 再用两层错位低频 FBM 抖动坐标，让云团边缘破碎卷曲
// freq 取 0.022 偏低频以适配 0.0085~0.062 多频段云形采样。
vec2 wind_domain_warp(vec2 wp, vec2 flow, float t, float strength) {
	vec2 advected = wp - flow * t;
	float n1 = fbm(advected * 0.022 + vec2( t * 0.020,  t * 0.012), 2) - 0.5;
	float n2 = fbm(advected * 0.022 + vec2(-t * 0.014,  t * 0.018) + vec2(37.0, 13.0), 2) - 0.5;
	// Phase 2：叠加 blue_jitter 高频偏移，破除 FBM 在低频段的双线性网格感。
	// 系数 0.5 保证只是细微抖动，不会改变云团整体形状。
	vec2 jitter = blue_jitter(wp, 0.05) * 0.5;
	return advected + vec2(n1, n2) * strength + jitter;
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

FrontField sample_weather_field(vec2 wp, vec2 uv) {
	FrontField f = empty_field();
	if (!weather_field_enabled) {
		return f;
	}
	// 2026-05-18 N10：经典 Shader 云做法重写 sample_weather_field。
	// 旧问题（N8 不够）：N8 只是 warp uv 让 hex 边缘抖一抖，但最终 cloud 仍 = fbm_shape *
	//   cloud_amount（hex-constant），把 hex 数据当作"乘性 mask"，相当于在 fbm 云上
	//   贴了一张 hex 像素图——云团整体轮廓就是 hex 几何，玩家能看出地块分界。
	// 经典做法：hex 数据只调制 fbm 阈值（threshold modulator），不做乘性 mask。
	//   ① 多点采样邻域 cloud_amount 做加权平滑 → 得到连续的 cloud_amount_smoothed；
	//   ② threshold = mix(high, low, smoothed)，即"多云区门槛低，更多 fbm 像素过线"；
	//   ③ cloud = smoothstep(threshold, threshold+w, fbm_noise)，完全 fbm 形状；
	//   ④ 不再乘 cloud_amount——晴的区域因为 threshold 高自动没像素过线。
	// 类型/降水仍按主采样点的 wt 决定（wt 是整数编码不能插值）；当主采样点 wt=clear
	// 但邻域有云时通过 smoothed 仍能给出"边缘飘进来的云"——这正是经典做法的精髓。

	// 主采样：决定该像素的天气"种类"（wt/precip/intensity）。
	vec4 wf_center = texture(weather_field_tex, uv);
	int wt = int(wf_center.r * 255.0 + 0.5);
	float intensity = clamp(wf_center.g, 0.0, 1.0);
	float precip_amount = clamp(wf_center.a, 0.0, 1.0);

	// ─── cloud_amount 邻域平滑：在 wp 域用风向 + fbm warp 多点采样后加权平均。
	// 关键：步长要"跨过 hex"——hex 在 atlas 上 ~1 纹素，1024 atlas 上 1/1024≈0.001 uv，
	// 取 0.006~0.014 uv 步长足以跨 1~3 个 hex，让加权值平滑出大尺度云团。
	// 用 6 个采样点（中心 + 5 个 jitter 偏移），权重按距离衰减并叠 fbm 不规则因子，
	// 避免 6 点对称导致的环形伪影。
	// 2026-05-18 N12：cloud_amount **和** intensity **和** precip 三者一起做邻域平滑。
	//   原因：图1 红框纯海面上空的"硬切"分界——不是来自 cloud 主体（N10 已去掉乘性 mask）、
	//   也不是来自 mountain_w（N11 已平滑），而是来自**早退条件本身用了 hex-constant 的 intensity**：
	//     `if (intensity <= 0.015 || wt == CLEAR) return f;`
	//   当某一行 hex 的 intensity 从 0.8 跳到 0.0、或 wt 从 RAIN 跳到 CLEAR，
	//   云值瞬间从 ~0.6 跳到 0 —— 完全沿 hex 边一刀切。
	//   修复：早退判定全部基于 *_smoothed（连续值），且早退用 smoothstep 软淡出，
	//   不再有"过阈值瞬间归零"的硬切。
	// 2026-05-18 N13：彻底解决六边形锯齿——所有"按 hex 取值"的量都改为邻域加权平滑。
	//   N12 残留问题：图1 云团边缘仍是清晰的六边形锯齿、图2 颜色块状。
	//   根因诊断：
	//     a) `cloud_amount = max(主像素 b, smoothed)` —— 主像素 b 是 hex-constant，max
	//        让 hex 中心的 b=0.8 强行覆盖了 smoothed=0.13 → threshold 在 hex 边一格一格阶跃。
	//     b) `type_cloud_bias(wt)` 用 hex-constant wt —— FOG=1.20 vs RAIN=1.0，跨 hex
	//        云强度 ×1.20 突变。
	//     c) `weather_profile_colors[wt]` 颜色 / alpha 都按 hex 取值 —— 图2 颜色块状的根因。
	//   修复方案：在同一组 6 点采样里**同时**累加 cloud_amount、intensity、precip、
	//   type_bias、color、profile_alpha——所有"按 hex 取值"的量都加权平均成连续场。
	//   主像素 wt 只保留用作"分支语义"（如 FOG/BLIZZARD 走不同 shape 路径）。
	float c_acc = 0.0;
	float i_acc = 0.0;
	float p_acc = 0.0;
	float bias_acc = 0.0;      // type_cloud_bias 加权
	vec3 col_acc = vec3(0.0);  // profile_color 加权
	float palpha_acc = 0.0;    // profile_alpha 加权
	float w_acc = 0.0;
	// 6 个采样点（中心 + 5 jitter 偏移）。中心权重适中，避免主像素仍然主导。
	vec2 offs[6] = vec2[6](
		vec2(  0.0000,  0.0000),
		vec2(  0.0090,  0.0050),
		vec2( -0.0080,  0.0085),
		vec2(  0.0040, -0.0095),
		vec2( -0.0110, -0.0035),
		vec2(  0.0125,  0.0010)
	);
	// 中心点权重 0.85（不再独占），偏移点权重 ~0.5 浮动——让"邻域平均"真正起作用。
	for (int i = 0; i < 6; i++) {
		// 每个采样位再叠一层 fbm jitter（约半个 hex），让"邻域圈"形状破碎不规则。
		vec2 j = (i == 0) ? vec2(0.0) : (vec2(
			fbm(wp * 0.18 + vec2(17.0 + float(i) * 13.0, -29.0), 1),
			fbm(wp * 0.18 + vec2(-41.0, 19.0 + float(i) * 7.0), 1)
		) - 0.5);
		vec2 sample_uv = clamp(uv + offs[i] + j * 0.006, vec2(0.0), vec2(1.0));
		vec4 wfn = texture(weather_field_tex, sample_uv);
		float cn = clamp(wfn.b, 0.0, 1.0);
		float in_ = clamp(wfn.g, 0.0, 1.0);
		float pn = clamp(wfn.a, 0.0, 1.0);
		int wtn = int(wfn.r * 255.0 + 0.5);
		// 邻居的 type_bias / color / alpha——CLEAR/DROUGHT/HEATWAVE 视为 bias=1.0、
		// 透明色，避免它们污染"邻域颜色平均"。
		bool wtn_active = (wtn != WT_CLEAR && wtn != WT_DROUGHT && wtn != WT_HEATWAVE);
		float bn = wtn_active ? type_cloud_bias(wtn) : 1.0;
		vec4 prof = (wtn >= 0 && wtn < MAX_WEATHER_TYPES)
			? weather_profile_colors[wtn] : vec4(0.0);
		// 中心点权重 0.85（不让它独占），偏移点权重 0.5 ± fbm 抖动 0.25。
		float wn = (i == 0)
			? 0.85
			: (0.5 + (fbm(wp * 0.21 + vec2(float(i) * 23.0, 7.0), 1) - 0.5) * 0.5);
		c_acc += cn * wn;
		i_acc += in_ * wn;
		p_acc += pn * wn;
		bias_acc += bn * wn;
		// 颜色按"该邻居 cloud_amount × 权重"加权——多云 hex 颜色贡献多、晴空 hex 不贡献。
		// 这样陆海过渡的"风暴蓝 vs 晴空透明"按真实云密度比例混合，不按 hex 几何切。
		float col_w = wn * cn;
		col_acc += prof.rgb * col_w;
		palpha_acc += prof.a * col_w;
		w_acc += wn;
	}
	float inv_w = 1.0 / max(w_acc, 0.001);
	float cloud_amount_smoothed = clamp(c_acc * inv_w, 0.0, 1.0);
	float intensity_smoothed = clamp(i_acc * inv_w, 0.0, 1.0);
	float precip_smoothed = clamp(p_acc * inv_w, 0.0, 1.0);
	float type_bias_smoothed = clamp(bias_acc * inv_w, 0.85, 1.25);
	// 颜色/profile_alpha 用 col_acc 累计的 cloud_amount 总权重归一化（而不是 w_acc），
	// 这样纯晴空 hex 主导的像素颜色 acc≈0、palpha≈0，避免被无效颜色拖低。
	float col_w_sum = max(c_acc, 0.001); // c_acc 即 Σ(cn * wn)，恰好对应颜色权重总和
	vec3 profile_color_smoothed = col_acc / col_w_sum;
	float profile_alpha_smoothed = clamp(palpha_acc / col_w_sum, 0.0, 1.0);

	// N13：cloud_amount / intensity / precip **完全使用平滑值**，不再 max 主像素。
	// 主像素 hex-constant 的高值（0.8）不再覆盖邻域平均（0.13）——彻底脱离 hex 阶跃。
	float cloud_amount = cloud_amount_smoothed;
	intensity = intensity_smoothed;
	precip_amount = precip_smoothed;

	// wt 借用：若主像素是 CLEAR/DROUGHT/HEATWAVE，扫邻居拿一个有效 wt 用于"分支语义"
	// （比如 wt==FOG 走 fog shape 路径）。注意 wt 仅用于分支选择，不再用于 type_bias /
	// color / alpha 计算——那些已经全部 smoothed 了。
	bool main_wt_inactive = (wt == WT_CLEAR || wt == WT_DROUGHT || wt == WT_HEATWAVE);
	if (main_wt_inactive) {
		for (int i = 1; i < 6; i++) {
			vec2 sample_uv = clamp(uv + offs[i], vec2(0.0), vec2(1.0));
			vec4 wfn = texture(weather_field_tex, sample_uv);
			int wtn = int(wfn.r * 255.0 + 0.5);
			if (wtn != WT_CLEAR && wtn != WT_DROUGHT && wtn != WT_HEATWAVE) {
				wt = wtn;
				break;
			}
		}
	}
	// 早退：完全基于平滑值。
	float field_activity = max(intensity_smoothed, cloud_amount_smoothed);
	bool wt_still_inactive = (wt == WT_CLEAR || wt == WT_DROUGHT || wt == WT_HEATWAVE);
	if (wt_still_inactive || field_activity < 0.02) {
		return f;
	}
	float field_fadein = smoothstep(0.02, 0.10, field_activity);

	vec2 axis = normalize(vec2(1.0, 0.22));
	// Phase 1：用真实风场（per-cell）替代全局常量 axis 做 advection。
	// fallback：风场未启用或风极弱时退回旧的全局 axis 路径，保证视觉不退化。
	WindSample wind = sample_wind(uv);
	vec2 advect_dir = (wind.speed > 0.05) ? wind.dir : axis;
	float advect_speed_scale = mix(0.55, 1.35, wind.speed); // 弱风慢漂、强风急流
	float base_speed = mix(4.0, 10.0, max(precip_amount, cloud_amount));
	vec2 advect_flow = advect_dir * base_speed * advect_speed_scale;
	vec2 warped = wind_domain_warp(wp, advect_flow, world_time, 7.0 + wind.speed * 4.0);
	// 风强区高频抖动更剧烈，模拟急流撕扯云团；轴向（axis）也跟着真实风转向，
	// 保证下游 rain_field/snow_field 的方向条纹与 advection 一致。
	axis = advect_dir;
	// 2026-05-18 N10：经典云做法的 domain warp —— 用一层 fbm 去扰动另一层 fbm 的采样点。
	// 给云絮"被风拉扯成不规则形状"的拓扑感，而不是单层 fbm 的圆斑。
	vec2 dw = vec2(
		fbm(warped * 0.013 + vec2(37.0, -19.0), 2),
		fbm(warped * 0.013 + vec2(-23.0, 41.0), 2)
	) - 0.5;
	vec2 warped_dw = warped + dw * 38.0; // 38 wp ≈ 几个 hex 距离，足够形变但不离原位
	int q_oct = (weather_overlay_quality >= 2) ? 3 : 2;
	float low = fbm(warped_dw * 0.009, q_oct);
	float mid = fbm(warped_dw * 0.026 + vec2(41.0, -23.0), 2);
	float edge_break = fbm(warped_dw * 0.045 + vec2(11.0, 29.0), 2);
	float cloud_noise = low * 0.58 + mid * 0.30 + edge_break * 0.12;
	// 2026-05-18 N10：阈值由 cloud_amount_smoothed 调制（连续值），不再用 hex-constant 的
	// b 通道。多云区 threshold 低、更多 fbm 像素过线；晴区 threshold 高、几乎没像素过线。
	// 这才是经典做法——hex 数据决定"这一带云密度"，云形状本身完全 fbm。
	float threshold = mix(0.62, 0.30, cloud_amount);
	// 过渡带 w：决定云边缘的羽化程度。0.20 给出"软边但不糊"的卷云感。
	float cloud_shape = smoothstep(threshold, threshold + 0.20, cloud_noise);
	// 2026-05-18 N10：不再乘 cloud_amount（移除"hex 乘性 mask"）。云强度完全由
	// "fbm 过没过 threshold + 类型 bias + intensity"决定，彻底脱离 hex 几何。
	float cloud = clamp(cloud_shape * type_bias_smoothed * (0.92 + intensity * 0.10), 0.0, 1.0);
	// 2026-05-18 N12：早退淡出系数乘到 cloud 上——field_activity 跨阈值时云从 0 软起步，
	// 而不是过阈值瞬间出现一片 ~0.6 的云。这是消除图1 红框纯海面硬切分界的关键。
	cloud *= field_fadein;
	float precip_gate = clamp((cloud * 0.78 + intensity * 0.18) * precip_amount, 0.0, 1.0);
	if (wt == WT_FOG) {
		precip_gate = 0.0;
		// 雾：threshold 再降一些（雾本身覆盖率高），并叠加 low 做"贴地浓淡"。
		float fog_threshold = mix(0.52, 0.18, cloud_amount);
		float fog_shape = smoothstep(fog_threshold, fog_threshold + 0.22, cloud_noise);
		cloud = clamp(fog_shape * (0.78 + low * 0.22) * max(0.4, intensity) * field_fadein, 0.0, 1.0);
	}

	// 2026-05-18 N13：color / alpha 用邻域加权 smoothed 版，彻底脱离 hex-constant。
	//   旧版：`f.color = weather_profile_colors[wt].rgb`（按主像素 wt 取色） →
	//         相邻 hex wt 不同时颜色一刀切（图2 颜色块状的根因）。
	//   新版：profile_color_smoothed 是 6 个邻居按 cloud_amount 加权混合的颜色——
	//         多云邻居贡献多、晴空邻居不贡献，过渡带颜色平滑变化。
	f.color = profile_color_smoothed;
	f.alpha = profile_alpha_smoothed;
	f.cloud = cloud;
	f.precip = precip_gate;
	f.shadow = clamp(cloud * 0.64 + intensity * 0.16, 0.0, 1.0);
	f.core = clamp(max(precip_gate, intensity * 0.65), 0.0, 1.0);
	f.edge = clamp(edge_break, 0.0, 1.0);
	f.type = wt;
	f.axis = axis;
	return f;
}

FrontField sample_front_field(vec2 wp, vec2 uv) {
	// Phase 0：去掉旧的 early-return，让 field（连续天气场）与 fronts（局部强对流）共存。
	// 大尺度的云带 / 季风走廊由 field 提供底层覆盖；局部的 storm/rain 团块由 fronts
	// 在其上叠加。修复前 field 命中即 return，导致云带与强对流互斥，画面缺乏层次。
	FrontField field_sample = sample_weather_field(wp, uv);
	float field_score = max(field_sample.cloud, field_sample.precip * 1.08);

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
		float d_base = ed / spread;
		// dramatic-fx-fix：用 FBM 抖动 envelope 的有效距离，让椭圆边界本身碎掉。
		// 频率 0.04 大致对应 1/3 ~ 1/2 个 front 半径，给边界 3-5 个大小不一的"凸起/凹陷"，
		// 视觉上是云絮的不规则轮廓。每个 front 用 c.x/c.y 偏移让花纹独立。
		// 同时叠一层稍高频细节让边缘有"絮状"颗粒。
		float boundary_jitter_low = fbm(wp * 0.04 + vec2(c.x * 0.013, c.y * 0.017), 2) - 0.5;
		float boundary_jitter_high = fbm(wp * 0.13 + vec2(c.y * 0.011, c.x * 0.019), 1) - 0.5;
		float d = d_base + boundary_jitter_low * 0.34 + boundary_jitter_high * 0.12;
		if (d > 1.72) continue;

		vec2 ax = front_axis(shape);
		// Phase B：advection 速度提升到原来的 ~2.5×，让云团在 30s 内可见地"漂"过自身直径，
		// 同时用 domain warp 让边缘破碎卷曲，而不是整体平移看起来很僵。
		// FOG 的 flow 减半（雾流动比云慢、更接地）。
		// Phase 1：在 front 主轴 ax 上叠加 30% 的局部风场扰动 —— front 整体仍然
		// 沿 sim 端给的 stable_axis 平移（保留身份与一致性），但 front 内部不同
		// 位置会因为局部风场不同产生差异化卷曲，破除"整团平移"的僵直感。
		WindSample fwind = sample_wind(uv);
		vec2 flow_dir = (fwind.speed > 0.05) ? normalize(ax + fwind.dir * 0.35) : ax;
		float flow_speed = (wt == WT_FOG)
			? mix(3.0, 4.5, cloud_amount)
			: mix(6.0, 13.0, max(precip_amount, cloud_amount));
		flow_speed *= mix(0.9, 1.25, fwind.speed); // 强风区域的 front 漂得更快
		vec2 flow = flow_dir * flow_speed;
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

		// dramatic-fx-fix：阈值 mix(0.54,0.22) → mix(0.48,0.20)。
		// 之前的 mix(0.42,0.10) 把噪声压到几乎全过线，导致 envelope 内部"实心填充"，
		// 椭圆边界直接成了云的轮廓 → 看起来像几何椭圆。回拉阈值后噪声重新主导内部形态。
		// 配合上方 boundary_jitter 把 envelope 边界打碎，整体形状回到"云絮"。
		float threshold = mix(0.48, 0.20, cloud_amount);
		threshold += dissolve * 0.15;
		float cloud_shape = smoothstep(threshold, threshold + 0.24, low * 0.66 + mid * 0.28 + edge_break * 0.06);
		// dramatic-fx-fix：移除 core * 0.28 的常量内部填充——这是椭圆"实心感"的另一来源。
		// 改为只在云形噪声本身就有强度的地方用 core 做轻微强化（保留中心略浓的层次）。
		float cloud = clamp(cloud_shape * envelope * cloud_amount * type_cloud_bias(wt) * (0.92 + core * 0.10), 0.0, 1.0);

		float precip_gate = clamp((envelope * 0.45 + cloud * 0.78) * precip_amount, 0.0, 1.0);
		if (wt == WT_FOG) {
			precip_gate = 0.0;
			// dramatic-fx-fix：FOG 也走"噪声主导"路径，envelope 只做整体衰减，
			// 不再用 envelope * 0.70 这种近常数项把雾铺成实心椭圆。
			float fog_shape = smoothstep(threshold - 0.08, threshold + 0.18, low * 0.72 + mid * 0.22 + edge_break * 0.06);
			cloud = clamp(fog_shape * envelope * cloud_amount * (0.85 + core * 0.15), 0.0, 1.0);
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
			best.axis = flow_dir;
		}
	}

	// Phase 0：field 与 fronts 都跑完后做混合。
	// 规则：
	//  - cloud / precip / shadow 取逐通道 max（让强对流"探出"云带，同时不抹平云带）
	//  - type / color / axis：以 score 较高一方为主；fronts 在并列时优先（视觉重点）
	//  - core / edge：以胜出方为准，避免边缘破碎特征被对方稀释
	if (field_score <= 0.001 && best_score <= 0.001) {
		return empty_field();
	}
	if (best_score <= 0.001) {
		return field_sample;
	}
	if (field_score <= 0.001) {
		return best;
	}

	FrontField merged;
	bool fronts_lead = best_score >= field_score * 0.95; // 并列偏向 fronts
	merged.color = fronts_lead ? best.color : field_sample.color;
	merged.alpha = fronts_lead ? best.alpha : field_sample.alpha;
	merged.cloud = max(best.cloud, field_sample.cloud);
	merged.precip = max(best.precip, field_sample.precip);
	merged.shadow = max(best.shadow, field_sample.shadow);
	merged.core = fronts_lead ? best.core : field_sample.core;
	merged.edge = fronts_lead ? best.edge : field_sample.edge;
	merged.type = fronts_lead ? best.type : field_sample.type;
	merged.axis = fronts_lead ? best.axis : field_sample.axis;
	return merged;
}

// Phase 3a：雨幕几何升级。
// 旧实现：方向硬偏向 Y、全屏均匀雨线。
// 新实现：
//   1) precip < 0.20 时直接 0：让雨只出现在真有降水的格子上方（mask 化）
//   2) 雨线方向沿 per-cell 风向（axis 已在 Phase 1 升级为真实 per-cell 风），
//      但混入 30% 重力分量（雨永远稍微向下飘）
//   3) curtain（远雨幕）+ near_lines（近景雨线）保留，但频率与轴向重新匹配
//   4) 强降水（precip > 0.55）时叠加 rain shaft 调制：沿主轴 stretched 的稀疏锥体，
//      模拟暴雨中可见的雨柱光带
float rain_field(vec2 wp, vec2 axis, float precip) {
	// dramatic-fx：起跳门 0.20 → 0.10。中等 precip 也能看见雨幕，
	// 不再"明明在下雨但屏幕上空空如也"。
	if (precip < 0.10) return 0.0;
	// 风向（已含 per-cell wind）+ 重力（向 +Y）的合成方向；保证雨永远略向下。
	vec2 wind_dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 dir = normalize(wind_dir * 0.55 + vec2(0.0, 1.0) * 0.45);
	vec2 side = vec2(-dir.y, dir.x);
	float along = dot(wp, dir);
	float across = dot(wp, side);
	float sheet = fbm(vec2(across * 0.052, along * 0.018 + world_time * 2.8), 2);
	float near_lines = fbm(vec2(across * 0.19, along * 0.060 + world_time * 12.0), 1);
	// dramatic-fx：曲线起跳点下移、曲线变陡，让中等 sheet 也能形成可见雨幕。
	float curtain = smoothstep(0.32, 0.68, sheet);
	float lines = smoothstep(0.55, 0.88, near_lines);
	// dramatic-fx：curtain/lines 系数 0.62/0.54 → 0.85/0.72，整体雨幕厚度 +35%。
	float rain = (curtain * 0.85 + lines * 0.72) * precip;
	// Rain shaft（雨脚/雨柱）：触发门 0.55 → 0.35，叠加权 0.45 → 0.65。
	// 中等暴雨也能看到雨柱，重暴雨更夸张。
	if (precip > 0.35) {
		float shaft_band = fbm(vec2(across * 0.014, along * 0.006 - world_time * 0.55), 2);
		float shaft = smoothstep(0.50, 0.80, shaft_band) * smoothstep(0.35, 0.75, precip);
		rain += shaft * 0.65;
	}
	return clamp(rain, 0.0, 1.0);
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

// ambient-shadow：全图飘移云影。
// 双频 FBM：低频 0.013 给大块云团（视觉上 ~3-5 个云块铺满地图），
// 中频 0.038 给细节切口；smoothstep 阈值化让云影是稀疏斑块而不是均匀涂抹。
// 时间源：ambient_shadow_time，与游戏 pause 解耦（云影是装饰、不跟着游戏停）。
//
// 三层动效：
//   1) 整体平移（drift）：方向 (0.62, 0.38) 东北向，速度 6.0 单位/秒，约 8 秒漂过 1 hex
//   2) 内部 domain warp（morph）：用两层独立慢速 FBM 抖动采样坐标，让云形随时间扭曲变形
//      （振幅 14 单位、慢相位 0.05/0.04），不是单纯平移
//   3) 高频细节漂移：mid 频率叠加微小相位偏移让"颗粒"也在动
// 夜间 78% 衰减（夜里没太阳不该有影）；is_water 时再削 55%（海上影子较弱更自然）。
// 返回值范围 [0, ~0.62]，与 weather_strength 联动，便于玩家用统一开关控制。
float compute_ambient_cloud_shadow(vec2 wp, bool is_water) {
	if (!ambient_cloud_shadow_enabled || ambient_cloud_shadow_strength < 0.001) return 0.0;
	float t = ambient_shadow_time;
	vec2 drift = vec2(0.62, 0.38) * t * 6.0;
	vec2 sp = wp - drift;
	// Domain warp：两层独立慢相位 FBM 给云形施加 ±7 单位的扭曲偏移，让形状随时间演化。
	float warp_x = fbm(sp * 0.0318 + vec2(t * 0.25, 0.0), 1) - 0.5;
	float warp_y = fbm(sp * 0.0318 + vec2(0.0, t * 0.21) + vec2(53.0, 17.0), 1) - 0.5;
	vec2 warped = sp + vec2(warp_x, warp_y) * 14.0;
	float low = fbm(warped * 0.0033, 2);
	float mid = fbm(warped * 0.0138 + vec2(31.0 + t * 0.4, -17.0 - t * 0.3), 1);
	float patches = smoothstep(0.38, 0.58, low * 0.70 + mid * 0.30);
	float night_atten = 1.0 - tod_night_factor * 0.78;
	float water_atten = is_water ? 0.45 : 1.0;
	return patches * ambient_cloud_shadow_strength * 0.62 * night_atten * water_atten * weather_strength;
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
	FrontField w = sample_front_field(wp, uv);

	// dramatic-fx：低雾不再仅限山地/丘陵——平原也给基础权重 0.35，让所有陆地
	// 在浓雾天都能看到铺底雾气；山地/丘陵保留更高权重以维持"山雾更厚"的层次。
	int biome = int(texture(enum_atlas, uv).r * 255.0 + 0.5);
	bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);

	// 2026-05-18 N11：陆海过渡处的云"硬切"修复。
	// 旧问题：mountain_w 在 hex 内是常量阶跃（mountain=1.0 / hill=0.65 / plain=0.35 /
	//   water=0.0），且 low_fog 路径有 `!is_water` 硬切——结果：
	//   - 陆地 hex（即使是平原）→ 0.35 系数的 low_fog 厚云堆叠
	//   - 紧邻的水 hex → 完全无 low_fog
	//   云在陆海过渡线上一刀切，呈现出明显的 hex 海岸线分界（图1 红框就是这条）。
	// 修复：邻域多点采样 enum_atlas，对每个采样点用相同的 biome → weight 映射，
	//   加权平均得到**连续的 mountain_w_smoothed**；同时叠 fbm 抖动让等高线破碎。
	//   并且去掉 `!is_water` 硬切——海上邻近陆地处保留少量 low_fog（雾从岸上飘出来）。
	// 注：enum_atlas 是 filter_nearest 整数编码，邻域采样仍是离散的 biome id，
	//   但**加权平均后会产生连续过渡**（一个像素的邻域内陆地像素占比 = 该像素的"陆度"）。
	vec2 land_offs[6] = vec2[6](
		vec2( 0.0,      0.0     ),  // 中心
		vec2( 0.0090,   0.0050  ),
		vec2(-0.0080,   0.0085  ),
		vec2( 0.0040,  -0.0095  ),
		vec2(-0.0110,  -0.0035  ),
		vec2( 0.0125,   0.0010  )
	);
	float land_w_sum = 0.0;
	float land_total_w = 0.0;
	for (int li = 0; li < 6; li++) {
		// 每个偏移再叠 fbm jitter（约半个 hex），让"邻域圈"边缘不规则。
		vec2 jj = vec2(
			fbm(wp * 0.18 + vec2(31.0 + float(li) * 11.0, -47.0), 1),
			fbm(wp * 0.18 + vec2(-19.0, 23.0 + float(li) * 9.0), 1)
		) - 0.5;
		vec2 s_uv = clamp(uv + land_offs[li] + jj * 0.006, vec2(0.0), vec2(1.0));
		int bs = int(texture(enum_atlas, s_uv).r * 255.0 + 0.5);
		bool s_water = (bs == B_OCEAN) || (bs == B_COAST) || (bs == B_LAKE)
				|| (bs == B_REEF) || (bs == B_KELP) || (bs == B_SEA_ICE);
		float bw = (bs == B_MOUNTAIN) ? 1.0
				: ((bs == B_HILL) ? 0.65 : (s_water ? 0.0 : 0.35));
		// 采样权重叠 fbm 抖动 ±0.25，避免 6 点等权产生几何对称感。
		float kw = 0.5 + (fbm(wp * 0.21 + vec2(float(li) * 23.0, 7.0), 1) - 0.5) * 0.5;
		// 中心点稍重一些（×1.4），保留\"主像素是陆是水\"的主导权。
		if (li == 0) kw *= 1.4;
		land_w_sum += bw * kw;
		land_total_w += kw;
	}
	float mountain_w_smoothed = clamp(land_w_sum / max(land_total_w, 0.001), 0.0, 1.0);
	// 在过渡带（mountain_w_smoothed 在 0~0.35 之间）叠一层 fbm 抖动，
	// 让陆海雾分界线破碎成不规则斑驳——配合上面的多点平滑彻底消除 hex 形状的直边。
	float coast_jitter = fbm(wp * 0.085 + vec2(67.0, -31.0), 2) - 0.5;
	float mountain_w = clamp(mountain_w_smoothed + coast_jitter * 0.18, 0.0, 1.0);

	// Phase 2：先计算多层云的"附加贡献"（高云 + 山雾），再与中云合并。
	// dramatic-fx：高云触发条件扩到 WT_RAIN，让大片雨云上方也能看到拉丝卷云；
	// 强度系数 0.55 → 0.70（storm/monsoon 仍优先），层次感更厚。
	float cirrus = 0.0;
	if (weather_overlay_quality >= 1
			&& (w.type == WT_STORM || w.type == WT_MONSOON || w.type == WT_RAIN)
			&& w.cloud > 0.05) {
		float cirrus_intensity = (w.type == WT_RAIN) ? w.cloud * 0.55 : w.cloud * 0.70;
		cirrus = sample_high_cloud(wp, w.axis, cirrus_intensity);
	}
	// 山雾（低云）：在陆地及陆海过渡带上方堆叠；不再用 `!is_water` 硬切，
	// 由 mountain_w（平滑后的连续场）自然决定强度——纯洋深处 ~0、近岸 ~0.1、
	// 平原 ~0.35、丘陵 ~0.65、山地 ~1.0。
	float low_fog = 0.0;
	if (mountain_w > 0.001 && w.cloud > 0.05) {
		float fog_intensity = w.cloud * 0.65;
		// dramatic-fx：FOG 天气直接把局部权重提到 0.85，让浓雾在平原也明显。
		float local_w = mountain_w;
		if (w.type == WT_FOG) {
			fog_intensity = max(fog_intensity, w.cloud * 1.30);
			// FOG 天气下 local_w 抬升上限，但仍受 mountain_w 调制——
			// 纯洋上不会突然出现浓雾（mountain_w≈0 时 local_w 仍≈0）。
			local_w = max(local_w, mountain_w * 1.6);
			local_w = min(local_w, 0.85);
		}
		if (w.type == WT_STORM || w.type == WT_MONSOON) fog_intensity *= 1.10;
		low_fog = sample_low_fog(wp, w.axis, fog_intensity, local_w);
	}

	// ambient-shadow：先算一次全图云影（与是否有天气无关），后面三条路径都会用。
	float ambient_shadow = compute_ambient_cloud_shadow(wp, is_water);

	bool has_layer = (w.cloud > 0.001) || (w.precip > 0.001) || (cirrus > 0.001) || (low_fog > 0.001);
	if (!has_layer) {
		// ambient-shadow：clear 区域只输出云影 alpha，其余通道保持 0（依赖 blend_mix
		// 上层 ambient_color 作为底色，等同于"地面 × (1 - shadow_alpha)"的轻压暗）。
		if (ambient_shadow > 0.001) {
			COLOR = vec4(vec3(0.06, 0.08, 0.10), ambient_shadow);
		} else {
			COLOR = vec4(0.0);
		}
	} else {
		int flags = (w.type >= 0 && w.type < MAX_WEATHER_TYPES) ? weather_profile_flags[w.type] : 0;
		// 2026-05-18 N12：移除 `(flags & FLAG_HAS_OVERLAY) == 0` 的硬切早退。
		//   旧问题：w.type 是 hex-constant，相邻 hex 一个 wt=RAIN（OVERLAY=1）、另一个
		//   wt=CLEAR（OVERLAY=0），后者整段主渲染被跳过——云沿 hex 边一刀切（图1 红框）。
		//   现在依赖 has_layer（实际 cloud/precip/cirrus/low_fog > 0.001）作为唯一渲染门，
		//   彻底脱离 hex-constant 几何。FLAG 仅用于决定下游"雨/雪/雾"特效是否启用。
		{

			vec3 cloud_col = apply_cloud_tod(w.color, w.type);
			vec3 shadow_col = (w.type == WT_BLIZZARD) ? vec3(0.62, 0.68, 0.76) : vec3(0.18, 0.22, 0.28);
			vec3 col = mix(shadow_col, cloud_col, 0.62 + w.edge * 0.20);
			// 2026-05-18 N12：alpha 不再乘 w.alpha（hex-constant 的 profile alpha）——
			// 当相邻 hex wt 不同时 profile alpha 也会跳变（例如 RAIN.a=0.78, CLEAR.a=0.0）
			// 直接导致硬切。改为 w.cloud 主导：cloud 本身已经是 fbm 形状的连续场。
			// 保留少量 profile alpha 影响（×0.30）作为"天气类型对透明度的偏好"。
			float profile_alpha_factor = (w.type >= 0 && w.type < MAX_WEATHER_TYPES)
				? (0.70 + w.alpha * 0.30) : 1.0;
			float alpha = clamp(w.cloud * profile_alpha_factor * weather_strength, 0.0, 0.92);

			// Ground-projected cloud shadow, drawn by the overlay pass so it stays
			// exactly aligned with the same front field as clouds and rain.
			// dramatic-fx：阴影系数 0.26→0.40，上限 0.36→0.55，让雷暴/季风看起来"压在地上"。
			float shadow_alpha = clamp(w.shadow * weather_strength * 0.40 * (1.0 - tod_night_factor * 0.35), 0.0, 0.55);
			// ambient-shadow：与 front shadow 取 max，避免有云区域被双倍压暗。
			shadow_alpha = max(shadow_alpha, ambient_shadow);
			col = mix(vec3(0.06, 0.08, 0.10), col, alpha / max(alpha + shadow_alpha, 0.001));
			alpha = clamp(alpha + shadow_alpha, 0.0, 0.94);

			// Phase 2：山雾在地面层与中云之间，颜色偏冷灰白，alpha 受 weather_strength 调制。
			// dramatic-fx：颜色混合 0.62→0.78，alpha 权 0.42→0.65，让雾真的"挡住"地面色。
			if (low_fog > 0.001) {
				vec3 fog_col = mix(vec3(0.80, 0.84, 0.88), vec3(0.62, 0.68, 0.74), tod_night_factor);
				col = mix(col, fog_col, low_fog * 0.78);
				alpha = clamp(alpha + low_fog * 0.65 * weather_strength, 0.0, 0.96);
			}

			if ((flags & FLAG_RAIN_STREAK) != 0 && w.precip > 0.001) {
				float rain = rain_field(wp, w.axis, w.precip);
				vec3 rain_col = (w.type == WT_MONSOON) ? vec3(0.42, 0.56, 0.68) : vec3(0.52, 0.62, 0.74);
				// dramatic-fx：rain_col 混合 0.52→0.68，alpha 加成 0.34→0.50，
				// 地面 darken 0.78→0.55、rain 系数 0.62→0.85，强降雨地面真的会变暗。
				col = mix(col, rain_col, rain * 0.68);
				alpha = clamp(alpha + rain * 0.50 * weather_strength, 0.0, 0.95);
				col *= mix(1.0, 0.55, rain * 0.85);
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

			// Phase 2：高云（卷云带）在最上层叠加，alpha 较弱，颜色偏白带暖色（受 tod_sun_color 染）。
			// 强度受 storm/monsoon 系统强度限制；夜间稍冷蓝。
			if (cirrus > 0.001) {
				vec3 cirrus_col = mix(vec3(0.92, 0.94, 0.98), tod_sun_color, 0.35);
				cirrus_col = mix(cirrus_col, vec3(0.72, 0.78, 0.88), tod_night_factor);
				col = mix(col, cirrus_col, cirrus * 0.55);
				alpha = clamp(alpha + cirrus * 0.30 * weather_strength, 0.0, 0.90);
			}

			if ((flags & FLAG_LIGHTNING) != 0 && !is_water) {
				// dramatic-fx：core_gate 0.34/0.82 → 0.18/0.65，让中等强度雷暴也常见闪电；
				// local_flash 阈值放宽，节拍 1.37→1.05Hz（频率 +30%），bolt mix 0.78→0.92。
				float core_gate = smoothstep(0.18, 0.65, w.core);
				float local_flash = smoothstep(0.82, 0.97, fbm(wp * 0.052 + vec2(world_time * 5.1, -11.0), 2));
				float bolt = max(storm_flash, local_flash * step(0.55, fract(world_time * 1.05))) * core_gate;
				if (bolt > 0.0) {
					col = mix(col, vec3(1.0, 0.98, 0.86), bolt * 0.92);
					alpha = clamp(alpha + bolt * 0.36, 0.0, 0.97);
				}
			}

			COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), alpha);
		}
	}
}
