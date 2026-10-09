// data_overlay.gdshader
// 数据热力图 overlay shader（独立于 world_map.gdshader）。
// 采样 overlay_tex（RGBA8）：
//   R = 归一化数值（连续通道） / 类别 id（离散通道 CLIMATE_ZONE / WEATHER）
//   G = 天气通道的强度（0..1）；连续通道写 0
//   A = 有效性（255 = 有效，0 = 无效 / 未覆盖像素）
//
// 通过 uniform int overlay_mode 分支走对应的色带/palette，最终 alpha
// = base_alpha × 通道自带强度（WEATHER 强度为 G 通道）× 有效性。
//
// **UV 处理**：MeshInstance2D + ArrayMesh 自定义 UV 在 canvas_item
// 路径下并不总能正确传到 fragment 的 UV（Godot 4 行为依赖 texture
// slot 是否绑定）。这里改为**在 vertex 阶段从 VERTEX（世界坐标）算
// 出归一化 UV**，通过 varying 传给 fragment，彻底独立于 canvas_item
// 的 UV 约定，避免出现"全白/全屏中性灰"。
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform sampler2D overlay_tex : filter_nearest, repeat_disable;
uniform vec2 world_origin = vec2(0.0, 0.0);
uniform vec2 world_size   = vec2(1.0, 1.0);

uniform int overlay_mode = 0;
uniform float base_alpha = 0.7;

varying vec2 v_uv;

// 离散通道颜色表。长度给到 8（WeatherType 有 8 种）；
// CLIMATE_ZONE 只用前 5 个槽位。
const vec3 CLIMATE_COLORS[5] = vec3[5](
	vec3(0.95, 0.42, 0.28),   // 热带   — 橙红
	vec3(0.96, 0.75, 0.30),   // 副热带 — 琥珀
	vec3(0.40, 0.78, 0.45),   // 温带   — 草绿
	vec3(0.45, 0.72, 0.92),   // 副极地 — 浅蓝
	vec3(0.92, 0.95, 1.00)    // 极地   — 雪白
);

// WeatherType.WT：CLEAR, RAIN, STORM, BLIZZARD, DROUGHT, FOG, HEATWAVE, MONSOON
const vec3 WEATHER_COLORS[8] = vec3[8](
	vec3(0.00, 0.00, 0.00),   // CLEAR    — 透明（alpha 为 0，见下）
	vec3(0.25, 0.55, 0.95),   // RAIN     — 蓝
	vec3(0.55, 0.25, 0.85),   // STORM    — 紫
	vec3(0.95, 0.97, 1.00),   // BLIZZARD — 冷白
	vec3(0.82, 0.55, 0.28),   // DROUGHT  — 橙棕
	vec3(0.72, 0.78, 0.82),   // FOG      — 灰蓝
	vec3(0.98, 0.45, 0.20),   // HEATWAVE — 暖橙
	vec3(0.30, 0.35, 0.85)    // MONSOON  — 靛蓝
);

const vec3 NEUTRAL_GRAY = vec3(0.45, 0.45, 0.45);

// 蓝→青→黄→红 冷到暖色带（TEMPERATURE）
vec3 ramp_cold_to_hot(float v) {
	v = clamp(v, 0.0, 1.0);
	vec3 c0 = vec3(0.10, 0.30, 0.80);   // 冷蓝
	vec3 c1 = vec3(0.20, 0.75, 0.85);   // 青
	vec3 c2 = vec3(0.95, 0.90, 0.35);   // 黄
	vec3 c3 = vec3(0.92, 0.25, 0.18);   // 红
	if (v < 0.333) return mix(c0, c1, v / 0.333);
	if (v < 0.666) return mix(c1, c2, (v - 0.333) / 0.333);
	return mix(c2, c3, (v - 0.666) / 0.334);
}

// 橙→白→蓝 干到湿（PRECIPITATION）
vec3 ramp_dry_wet(float v) {
	v = clamp(v, 0.0, 1.0);
	vec3 c0 = vec3(0.78, 0.48, 0.18);
	vec3 c1 = vec3(0.95, 0.95, 0.95);
	vec3 c2 = vec3(0.15, 0.40, 0.85);
	if (v < 0.5) return mix(c0, c1, v / 0.5);
	return mix(c1, c2, (v - 0.5) / 0.5);
}

// 黄→绿→蓝 干燥湿度（HUMIDITY）
vec3 ramp_humidity(float v) {
	v = clamp(v, 0.0, 1.0);
	vec3 c0 = vec3(0.90, 0.82, 0.32);
	vec3 c1 = vec3(0.35, 0.78, 0.45);
	vec3 c2 = vec3(0.18, 0.45, 0.85);
	if (v < 0.5) return mix(c0, c1, v / 0.5);
	return mix(c1, c2, (v - 0.5) / 0.5);
}

// 红→黄→绿 植被健康度（VEGETATION_VITALITY）
vec3 ramp_vitality(float v) {
	v = clamp(v, 0.0, 1.0);
	vec3 c0 = vec3(0.85, 0.22, 0.18);
	vec3 c1 = vec3(0.95, 0.88, 0.30);
	vec3 c2 = vec3(0.25, 0.70, 0.35);
	if (v < 0.5) return mix(c0, c1, v / 0.5);
	return mix(c1, c2, (v - 0.5) / 0.5);
}

// 黑→青→青绿→黄白 洋流强度（OCEAN_CURRENT）：以深海背景为 0，强流亮色。
vec3 ramp_current(float v) {
	v = clamp(v, 0.0, 1.0);
	vec3 c0 = vec3(0.04, 0.08, 0.18);   // 静水：深青黑
	vec3 c1 = vec3(0.12, 0.45, 0.85);   // 中强：海青
	vec3 c2 = vec3(0.30, 0.85, 0.85);   // 较强：青绿
	vec3 c3 = vec3(0.98, 0.95, 0.65);   // 极强：亮黄白
	if (v < 0.333) return mix(c0, c1, v / 0.333);
	if (v < 0.666) return mix(c1, c2, (v - 0.333) / 0.333);
	return mix(c2, c3, (v - 0.666) / 0.334);
}

// 冷蒄→中性灰→暖红 双向量（OCEAN_HEAT_TRANSPORT / UPWELLING）：0.5 = 中性。
vec3 ramp_diverging(float v) {
	v = clamp(v, 0.0, 1.0);
	vec3 cN = vec3(0.10, 0.30, 0.80);   // 负向极值：冷蓝
	vec3 c0 = vec3(0.85, 0.85, 0.85);   // 中性：中性灰
	vec3 cP = vec3(0.92, 0.25, 0.18);   // 正向极值：暖红
	if (v < 0.5) return mix(cN, c0, v / 0.5);
	return mix(c0, cP, (v - 0.5) / 0.5);
}

// 青灰→黄→橙→紫 风速（WIND_SPEED）：弱风冷调，强风热调。
vec3 ramp_wind(float v) {
	v = clamp(v, 0.0, 1.0);
	vec3 c0 = vec3(0.80, 0.85, 0.90);
	vec3 c1 = vec3(0.90, 0.85, 0.40);
	vec3 c2 = vec3(0.95, 0.55, 0.20);
	vec3 c3 = vec3(0.55, 0.20, 0.65);
	if (v < 0.333) return mix(c0, c1, v / 0.333);
	if (v < 0.666) return mix(c1, c2, (v - 0.333) / 0.333);
	return mix(c2, c3, (v - 0.666) / 0.334);
}

// HSV → RGB（标准 6-segment hue wheel；输入 h ∈ [0,1)，s/v ∈ [0,1]）。
// 给方向型通道 WIND_DIR / OCEAN_CURRENT_DIR 用：R=hue、G=value(强度)。
vec3 hsv2rgb_dir(float h, float v) {
	float s = 0.85;
	float vv = mix(0.45, 1.0, v); // 弱风也保留可见亮度，避免变全黑
	float c = vv * s;
	float h6 = fract(h) * 6.0;
	float x = c * (1.0 - abs(mod(h6, 2.0) - 1.0));
	vec3 rgb1;
	if (h6 < 1.0)      rgb1 = vec3(c, x, 0.0);
	else if (h6 < 2.0) rgb1 = vec3(x, c, 0.0);
	else if (h6 < 3.0) rgb1 = vec3(0.0, c, x);
	else if (h6 < 4.0) rgb1 = vec3(0.0, x, c);
	else if (h6 < 5.0) rgb1 = vec3(x, 0.0, c);
	else               rgb1 = vec3(c, 0.0, x);
	float m = vv - c;
	return rgb1 + vec3(m);
}

// BIOME_GROUP 调色板（8 嶌入 + 2 fallback，总 10 档）——与 overlay_mode.gd
// BIOME_GROUP_NAMES 严格同样顺序，修改二者谁都要同步。
const vec3 BIOME_GROUP_COLORS[10] = vec3[10](
	vec3(0.05, 0.18, 0.45),   // 0 深海/远海
	vec3(0.85, 0.92, 0.98),   // 1 海冰
	vec3(0.30, 0.65, 0.85),   // 2 海岸礁滩
	vec3(0.20, 0.55, 0.70),   // 3 内陆水
	vec3(0.65, 0.85, 0.45),   // 4 开阔陆面
	vec3(0.20, 0.55, 0.25),   // 5 林地
	vec3(0.50, 0.45, 0.38),   // 6 高地/山岭
	vec3(0.92, 0.85, 0.45),   // 7 干旱荒漠
	vec3(0.95, 0.97, 1.00),   // 8 寒带/冰雪
	vec3(0.55, 0.55, 0.55)    // 9 未分类 fallback
);

// LANDFORM 调色板（6 档）——红色提高区分度，贯从“深静→亮热”的海拔隔热阶。
const vec3 LANDFORM_COLORS[6] = vec3[6](
	vec3(0.05, 0.18, 0.45),   // 0 深海
	vec3(0.30, 0.65, 0.85),   // 1 沿海/浅水
	vec3(0.65, 0.85, 0.45),   // 2 平原
	vec3(0.78, 0.62, 0.32),   // 3 丘陵
	vec3(0.55, 0.40, 0.30),   // 4 山地
	vec3(0.95, 0.97, 1.00)    // 5 冰雪
);

void vertex() {
	// VERTEX 此时是 mesh 局部坐标 = 世界坐标（quad 顶点在 _build_quad_mesh
	// 中按 bounds.position + bounds.size 给出的世界坐标写入）。
	// 把它归一化到 [0,1] 作为数据纹理的采样 UV，独立于 canvas_item 默认 UV。
	v_uv = (VERTEX - world_origin) / world_size;
}

void fragment() {
	// 注意：Godot 4 的 canvas_item shader **禁止**在 fragment 中使用
	// `return`（编译错误："Using 'return' in the 'fragment' processor
	// function is incorrect."）。所以这里全部用嵌套 if/else 表达，
	// 默认值置 vec4(0.0)，分支命中时再覆写。
	vec4 out_color = vec4(0.0);

	if (overlay_mode != 0) {
		vec2 uv = clamp(v_uv, vec2(0.0), vec2(1.0));
		vec4 sampled = texture(overlay_tex, uv);
		// A < 0.5 → 无效像素，保持 out_color = vec4(0.0)（完全透明）。
		if (sampled.a >= 0.5) {
			float value = sampled.r;
			int   bucket = int(floor(sampled.r * 255.0 + 0.5));
			float intensity = sampled.g;

			vec3 rgb = NEUTRAL_GRAY;
			float alpha_mul = 1.0;

			if (overlay_mode == 1) {         // TEMPERATURE
				rgb = ramp_cold_to_hot(value);
			} else if (overlay_mode == 2) {  // PRECIPITATION
				rgb = ramp_dry_wet(value);
			} else if (overlay_mode == 3) {  // CLIMATE_ZONE
				int z = clamp(bucket, 0, 4);
				rgb = CLIMATE_COLORS[z];
			} else if (overlay_mode == 4) {  // HUMIDITY
				rgb = ramp_humidity(value);
			} else if (overlay_mode == 5) {  // WEATHER
				int w = clamp(bucket, 0, 7);
				rgb = WEATHER_COLORS[w];
				if (w == 0) {
					alpha_mul = 0.0;
				} else {
					alpha_mul = clamp(0.3 + intensity * 0.7, 0.0, 1.0);
				}
			} else if (overlay_mode == 6) {  // VEGETATION_VITALITY
				rgb = ramp_vitality(value);
			} else if (overlay_mode == 7) {  // OCEAN_CURRENT
				rgb = ramp_current(value);
			} else if (overlay_mode == 8) {  // OCEAN_HEAT_TRANSPORT
				rgb = ramp_diverging(value);
			} else if (overlay_mode == 9) {  // UPWELLING
				rgb = ramp_diverging(value);
			} else if (overlay_mode == 10) { // WIND_SPEED
				rgb = ramp_wind(value);
			} else if (overlay_mode == 11) { // BIOME_GROUP
				int b = clamp(bucket, 0, 9);
				rgb = BIOME_GROUP_COLORS[b];
			} else if (overlay_mode == 12) { // LANDFORM
				int l = clamp(bucket, 0, 5);
				rgb = LANDFORM_COLORS[l];
			} else if (overlay_mode == 13) { // WIND_DIR
				// R = hue(归一化角度), G = 强度。强度低 → alpha 衰减。
				rgb = hsv2rgb_dir(value, intensity);
				alpha_mul = clamp(0.35 + intensity * 0.65, 0.0, 1.0);
			} else if (overlay_mode == 14) { // OCEAN_CURRENT_DIR
				rgb = hsv2rgb_dir(value, intensity);
				alpha_mul = clamp(0.35 + intensity * 0.65, 0.0, 1.0);
			} else if (overlay_mode == 15) { // SLP（Physical Circulation 调试）
				// 双向：0=低压冷色 / 0.5=中性 / 1=高压暖色
				rgb = ramp_diverging(value);
			} else if (overlay_mode == 16) { // WIND_STRESS_CURL（Physical Circulation 调试）
				// 双向：0=负涡度 / 0.5=中性 / 1=正涡度
				rgb = ramp_diverging(value);
			} else if (overlay_mode == 17) { // OCEAN_PSI（Physical Circulation 调试）
				// 双向：流函数 ψ 等高线 = 流线；颜色对比度让海盆环流可见
				rgb = ramp_diverging(value);
			} else if (overlay_mode == 18) { // DEMO_THERMAL_GRADIENT（Reference-impl Pass #2）
				// 复用 cold→hot 色带：低梯度=冷色、高梯度=暖色，与 TEMPERATURE 通道
				// 视觉上保持一致风格。这是 demo-only 通道（performance-charter §12.6），
				// 真实游戏机制不应读取该字段。
				rgb = ramp_cold_to_hot(value);
			}

			out_color = vec4(rgb, base_alpha * alpha_mul);
		}
	}

	COLOR = out_color;
}
