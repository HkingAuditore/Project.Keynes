shader_type canvas_item;
render_mode blend_mix;

// weather_overlay.gdshader v1
// 单独的天气覆盖层 shader，挂在 WeatherLayer 上方的全屏 quad。
//
// 职责：
//   - RAIN     ：冷蓝雨幕（全屏覆盖 + 微量斜纹 fbm）
//   - STORM    ：暗黑雷暴 + 闪电（fbm 触发短暂高光）
//   - MONSOON  ：暗冷雨幕 + 闪电（比 STORM 更暗）
//   - BLIZZARD ：白色雪暴 + 高频雪粒
//   - FOG      ：灰白雾（恒定柔光）
//
// 不处理：DROUGHT / HEATWAVE（仍然在 world_map.gdshader 内 multiplicative 调色，
// 因为它们是"改地表本色"而非"覆盖效果"，留在地形 pass 更对也更便宜）。
//
// 海陆判断：从 enum_atlas.r 取 biome id，雷电只在陆地触发（避免海上闪电过密），
// 其他效果不区分海陆。

uniform sampler2D enum_atlas : filter_nearest, repeat_disable;
// v9.fbm-opt：与 world_map.gdshader 共享同一张 noise_tex，让本层的 fbm 也走 texture 采样
uniform sampler2D noise_tex  : filter_linear_mipmap, repeat_enable;
const float NOISE_TEX_SCALE = 256.0;

uniform vec2  world_origin = vec2(0.0);
uniform vec2  world_size   = vec2(1.0);
uniform float world_time   = 0.0;

// 任务 2：昼夜相位。夜晚时云层底色轻微偏冷，闪电略像月光偏蓝。
uniform float day_phase : hint_range(0.0, 1.0) = 0.25;
uniform bool  day_night_enabled = true;

// ─── Pass 2（任务 2）：TOD 全局光照 uniform（来自 TODProfile） ─────────
// 与 world_map.gdshader 共享同一组含义：云色/闪电/云影必须基于这组参数染色，
// 确保与地表色温一致。由 WeatherLayer.apply_tod 推入。
uniform vec3  tod_sun_color     : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3  tod_ambient_color : source_color = vec3(0.65, 0.68, 0.75);
uniform float tod_night_factor  : hint_range(0.0, 1.0) = 0.0;
uniform float tod_exposure      : hint_range(0.2, 2.5) = 1.0;
// 关闭 TOD 染色（任务 6 开关），保留上一轮 day_phase 逻辑做回退
uniform bool  cloud_tod_tint_enabled = true;

// 任务 1/4：视觉总开关。weather_overlay_quality:
//   0 = 单层圆盘（回退，涵盖延用 gaussian）
//   1 = 单层 fBm（中等质量）
//   2 = 两层 fBm + 形状一致的地面阴影（需求 1.1/1.5）
uniform int   weather_overlay_quality : hint_range(0, 2) = 2;
uniform bool  extreme_weather_ground_effect_enabled = true;

// 任务 5：STORM 闪电亮斑瞬时强度 ∈ [0, 1]，由 WeatherLayer 以 < 1Hz 频率短暂拉高。
// 在 fragment 末尾对 STORM/MONSOON 覆盖区域整体提亮 + 偏黄白。
uniform float storm_flash : hint_range(0.0, 1.0) = 0.0;
// 任务 5：HEATWAVE 热气扭曲占位 uniform（地形 shader 同名 uniform 单独存在；
// 此处保留以便未来"陆地上也渲染 overlay 的扭曲纹路"时复用）
uniform float heatwave_distortion : hint_range(0.0, 1.0) = 0.6;

// MAX_WEATHER_FRONTS 与 hex_renderer.gd / weather_system.gd 严格对齐
const int MAX_WEATHER_FRONTS = 16;
uniform vec4  weather_front_centers[MAX_WEATHER_FRONTS];
uniform float weather_front_types[MAX_WEATHER_FRONTS];
uniform int   weather_front_count = 0;
uniform float weather_strength : hint_range(0.0, 1.0) = 1.0;

// v-data-driven：WeatherProfile 驱动的颜色/标志数组。
// 由 WeatherLayer 在 setup() 里从 WeatherProfileRegistry 一次性推入，每局只推一次。
// colors[wt].rgb = overlay_color, colors[wt].a = overlay_base_alpha。
// flags[wt] = bit码：
//   bit0 = has_overlay
//   bit1 = enables_lightning
//   bit2 = enables_snow_grain
//   bit3 = enables_rain_streak
//   bit4 = enables_fog_breathe
// 当 CPU 未推送（开发期 hot-reload）时，flags=0 且 colors.a=0 使云层不可见、不触发特效。
const int MAX_WEATHER_TYPES = 8;
uniform vec4 weather_profile_colors[MAX_WEATHER_TYPES];
uniform int  weather_profile_flags[MAX_WEATHER_TYPES];

const int FLAG_HAS_OVERLAY    = 1;
const int FLAG_LIGHTNING      = 2;
const int FLAG_SNOW_GRAIN     = 4;
const int FLAG_RAIN_STREAK    = 8;
const int FLAG_FOG_BREATHE    = 16;

// WeatherType.WT id（与 weather_type.gd 严格对齐）
const int WT_CLEAR    = 0;
const int WT_RAIN     = 1;
const int WT_STORM    = 2;
const int WT_BLIZZARD = 3;
const int WT_DROUGHT  = 4;
const int WT_FOG      = 5;
const int WT_HEATWAVE = 6;
const int WT_MONSOON  = 7;

// biome id：仅用于"雷电不在洋面"判断
const int B_OCEAN   = 0;
const int B_COAST   = 1;
const int B_LAKE    = 18;
const int B_REEF    = 19;
const int B_SEA_ICE = 20;
const int B_KELP    = 21;

varying vec2 v_world;

// ─── 噪声 ───────────────────────────────────────────────────────────────
// v9.fbm-opt：用预烘的 tileable noise_tex 替换原本的 4× hash21 + smoothstep mix。
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

float visual_weather_intensity(float raw_intensity) {
	float i = clamp(raw_intensity, 0.0, 1.0);
	if (i <= 0.0) return 0.0;
	// 逻辑强度用于天气数值；视觉强度用幂曲线抬高中低段，
	// 让刚生成和衰减期的雨雪雾仍然清晰可见。
	return clamp(pow(i, 0.55) * smoothstep(0.0, 0.08, i), 0.0, 1.0);
}

// ─── 任务 4：云层密度场（不规则软边） ──────────────────────────────────
// 输入：世界坐标 wp、云层中心 cx、半径 r、帺风向 wind（已归一化）、
//        强度 intensity、质量级 quality。
// 输出：密度 ∈ [0, 1]，自然滚动与软边，不绑 front 圆心硬限。
// 关键点：云层位置 ×风向→滚动 UV；radial envelope 让云边界向 front.radius 平滑衰减。
float cloud_density(
		vec2 wp, vec2 cx, float r, vec2 wind, float intensity, int quality) {
	float d = distance(wp, cx);
	// 径向 envelope：内区域保持高密度，边缘向 1.3r 平滑衰减到 0
	float radial = 1.0 - smoothstep(r * 0.6, r * 1.3, d);
	if (radial <= 0.001) return 0.0;

	if (quality <= 0) {
		// 回退模式：原始 gaussian 圆盘，但仍使用视觉强度曲线保证低画质下雨雪雾可读。
		float sigma = r * 0.5;
		float k = d / max(sigma, 0.001);
		return exp(-0.5 * k * k) * visual_weather_intensity(intensity);
	}

	// 驱动 UV：云随风向滚动（世界坐标，不随依于 front 位置，避免突变）
	vec2 flow = wind * world_time * 4.5;
	// Octave 1：低频云团轮廓
	float n1 = fbm((wp - flow) * 0.012, 2);
	// Octave 2（仅 quality==2）：高频细节 / 白花。偏移更慢，遮盖范围更大
	float n2 = (quality >= 2)
		? fbm((wp - flow * 0.6 + vec2(17.0, -11.0)) * 0.028, 2)
		: 0.5;
	// 密度场 = octave 合成，再用 smoothstep 门限塑造不规则软边
	float raw = mix(n1, n2, 0.35);
	// coverage 阈值由视觉强度推进：中低强度也保持可读，强天气云幕更满。
	float visual_i = visual_weather_intensity(intensity);
	float threshold = mix(0.36, 0.12, visual_i);
	float density = smoothstep(threshold, threshold + 0.24, raw);
	return density * radial * visual_i;
}

// 夜晚云色轻微偏冷、闪电偏蓝。仅在 day_night_enabled 为 true 时应用。
float night_tint_factor() {
	if (!day_night_enabled) return 0.0;
	// 夜晚区间 [0.5, 1.0]，午夜 0.75 最暗
	return smoothstep(0.5, 0.75, day_phase) - smoothstep(0.95, 1.05, day_phase);
}

// ─── max-merge 取覆盖该点的最强 front（仅 overlay 类型，DROUGHT/HEATWAVE 跳过） ──
// 返回：rgb = overlay 基础颜色，a = 已乘 coverage*weather_strength 的 alpha；
//      type 通过 last component（这里 pack 在 .a 高位不方便，用一个额外 out 参数）。
//
// GLSL 没有 out 参数（GDshader 支持 inout），简单做法：用一个 vec4 包：xyz=color, w=alpha；
// 单独再返回一个 float 表示 type 让 fragment 区分 STORM/BLIZZARD 等子效果。

struct WeatherSample {
	vec3 color;
	float alpha;
	int type;
};

WeatherSample sample_weather_at(vec2 wp) {
	WeatherSample r;
	r.color = vec3(0.0);
	r.alpha = 0.0;
	r.type = WT_CLEAR;

	int best_type = WT_CLEAR;
	float best_coverage = 0.0;
	// 任务 4：保留曾用于云轮廓的 wind、intensity，供后续 fBm 采样重用
	vec2 best_wind = vec2(0.0);
	float best_intensity = 0.0;
	float best_radius = 0.0;
	vec2 best_center = vec2(0.0);
	for (int i = 0; i < MAX_WEATHER_FRONTS; i++) {
		if (i >= weather_front_count) break;
		float wt_f = weather_front_types[i];
		if (wt_f < 0.0) continue;
		int wt_i = int(wt_f + 0.5);
		// 跳过 multiplicative 类型（地形 shader 处理）
		if (wt_i == WT_DROUGHT || wt_i == WT_HEATWAVE) continue;
		if (wt_i == WT_CLEAR) continue;
		vec4 c = weather_front_centers[i];
		float radius = c.z;
		if (radius < 0.001) continue;
		float dist = distance(wp, c.xy);
		if (dist > radius * 1.6) continue;
		// 任务 4：用 fBm 云密度场取代纯 gaussian fall-off，在云边界自然产生不规则。
		// 纬度衍生的云风向：用 front 中心位置推算一个稳定的风向（当 CPU 未指定时的回退）
		// 简化：在云层场级别统一用一个略偏东的风向 (1, -0.25)，有正风带 ≫ 失真
		vec2 wind = normalize(vec2(1.0, -0.25));
		float intensity = clamp(c.w, 0.0, 1.0);
		float coverage = cloud_density(
			wp, c.xy, radius, wind, intensity, weather_overlay_quality
		);
		if (coverage > best_coverage) {
			best_coverage = coverage;
			best_type = wt_i;
			best_wind = wind;
			best_intensity = intensity;
			best_radius = radius;
			best_center = c.xy;
		}
	}
	if (best_coverage <= 0.001) return r;

	vec3 col;
	float base_alpha;
	// v-data-driven：从 uniform 数组取云色与基础 alpha，消除 if (best_type == WT_RAIN) ... 分支堆叠。
	// has_overlay=false 的天气在 WeatherLayer 侧已排除（本函数不会到达），
	// 这里再检查一次作为兜底：flags bit0 未置位则不出 overlay。
	int flags = (best_type >= 0 && best_type < MAX_WEATHER_TYPES)
		? weather_profile_flags[best_type] : 0;
	if ((flags & FLAG_HAS_OVERLAY) == 0) {
		return r;
	}
	vec4 cc = (best_type >= 0 && best_type < MAX_WEATHER_TYPES)
		? weather_profile_colors[best_type] : vec4(0.0);
	col = cc.rgb;
	base_alpha = cc.a;
	// Pass 2（任务 6）：云色经 TOD 染色，替代旧的 day_phase 冷蓝偏移。
	// cloud_tod_tint_enabled=false 时回退到上一轮的 day_phase 逻辑（双轨并行）。
	if (cloud_tod_tint_enabled) {
		// 需求 6.1：云色 = cloud_base * tod_sun_color * (1 - 0.6*night_factor) + tod_ambient_color * 0.3
		col = col * tod_sun_color * (1.0 - 0.45 * tod_night_factor) + tod_ambient_color * 0.38;
		// 天气 overlay 是前景提示层，保留最低亮度，避免夜晚或冷色地表上雨雪雾完全糊掉。
		col = max(col, vec3(mix(0.16, 0.26, tod_night_factor)));
		// 需求 6.2：STORM 乌云额外压暗 0.7（闪电亮斑在 fragment 再处理，不乘 TOD）
		if (best_type == WT_STORM) {
			col *= 0.78;
		}
		// 需求 6.3：BLIZZARD 夜晚叠加弱极光提示（night_factor > 0.5 时）
		if (best_type == WT_BLIZZARD && tod_night_factor > 0.5) {
			col += vec3(0.6, 0.9, 0.85) * 0.2 * (tod_night_factor - 0.5) * 2.0;
		}
		col *= tod_exposure;
	} else {
		// 回退：上一轮的 night_tint_factor（仅用 day_phase）
		float night_t = night_tint_factor();
		col = mix(col, col * vec3(0.78, 0.82, 0.95), night_t * 0.65);
	}

	r.color = col;
	// coverage 已受 fBm 门阈调制，在云边界随 intensity 连续变化，不会开关式跳变
	r.alpha = base_alpha * best_coverage * weather_strength;
	r.type = best_type;
	return r;
}

// ─── 任务 4：云影（与云层同形状，用同一张 noise_tex） ─────────────────────
// 间接实现：在云层同一个 fragment 的略偏 shadow_offset（风下游）位置重新采样
// 一次密度，输出较低 alpha 的暗灰色作为地面阴影。这不是独立 pass，而是"云本身
// 染色"混入暗基调，满足需求 1.5 的"形状一致且不再是完美圆盘"。
// 输入 _center/_radius/_wind/_intensity 由 sample_weather_at 将 best_* 回传
// （这里直接在 fragment 里重算，避免结构体更复杂）。

void vertex() {
	v_world = VERTEX;
}

void fragment() {
	vec2 wp = v_world;
	vec2 uv = clamp((wp - world_origin) / world_size, vec2(0.0), vec2(1.0));

	WeatherSample w = sample_weather_at(wp);
	// Godot 4 的 fragment 函数禁止 return，所以用一个总分支包住后续所有逻辑。
	if (w.alpha <= 0.001) {
		COLOR = vec4(0.0);
	} else {
		vec3 col = w.color;
		float a = clamp(w.alpha, 0.0, 0.85);

		// v-data-driven：各特效的触发条件由 profile.flags 位运算决定，消除硬编码类型列举。
		int w_flags = (w.type >= 0 && w.type < MAX_WEATHER_TYPES)
			? weather_profile_flags[w.type] : 0;

		// 海陆判断：仅闪电用到（其他效果不分海陆，全屏可见）
		int biome = int(texture(enum_atlas, uv).r * 255.0 + 0.5);
		bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
				|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);

		// enables_lightning：随机短脉冲，only on land
		if ((w_flags & FLAG_LIGHTNING) != 0 && !is_water) {
			float lightning_seed = fbm(wp * 0.05 + vec2(world_time * 4.7, 0.0), 2);
			float bolt = step(0.92, lightning_seed) * step(0.5, fract(world_time * 1.7));
			// 任务 5：额外叠加 WeatherLayer 推进的 storm_flash 全局亮斑
			bolt = max(bolt, storm_flash);
			if (bolt > 0.0) {
				// Pass 2（任务 6）：闪电高光作为"发光源"——不乘 TOD，
				// 即使在午夜也保持明亮，贴合真实雷电观感。
				vec3 flash_color = vec3(1.0, 1.0, 0.95);
				col = mix(col, flash_color, 0.85 * bolt);
				a = max(a, 0.55 * w.alpha);
				a = clamp(a + 0.30 * bolt, 0.0, 0.92);
			}
		}

		// enables_snow_grain：高频白点叠加（不分海陆）
		if ((w_flags & FLAG_SNOW_GRAIN) != 0) {
			float flake = fbm(wp * 0.65 + vec2(0.0, world_time * 2.0), 1);
			float flake_factor = smoothstep(0.46, 0.78, flake);
			col = mix(col, vec3(1.0), flake_factor * 0.78);
			a = clamp(a + flake_factor * 0.32 * w.alpha, 0.0, 0.94);
		}

		// enables_rain_streak：沿 (-0.5, 1.0) 方向的轻微条纹，让"雨在动"更可信
		if ((w_flags & FLAG_RAIN_STREAK) != 0) {
			vec2 rain_dir = vec2(-0.45, 1.0);
			float along = dot(wp, rain_dir) * 0.40 + world_time * 18.0;
			float rain_streak = fbm(vec2(along, dot(wp, vec2(1.0, 0.45)) * 0.18), 2);
			float streak_factor = smoothstep(0.48, 0.82, rain_streak);
			col = mix(col, col * 1.24 + vec3(0.04, 0.05, 0.06), streak_factor * 0.55);
			a = clamp(a + streak_factor * 0.12 * w.alpha, 0.0, 0.92);
		}

		// enables_fog_breathe：微微呼吸（避免完全静态）
		if ((w_flags & FLAG_FOG_BREATHE) != 0) {
			float breathe = sin(world_time * 0.6) * 0.04;
			a = clamp(a + (0.08 + breathe) * w.alpha, 0.0, 0.88);
		}

		COLOR = vec4(col, a);
	}
}
