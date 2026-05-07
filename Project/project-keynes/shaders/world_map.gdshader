shader_type canvas_item;
render_mode blend_mix;

// world_map.gdshader v5：高分辨率地理仿真渲染
//
// 输入纹理（全部由 MapBaker 烤好）：
//   height_tex   (RG8 16-bit, hm_size 分辨率)：归一化海拔 [0, 1]
//                                              解码：(R*256 + G) / 257
//   biome_tex    (R8, derived_size, NEAREST)：每像素 = TerrainType.TERRAIN id
//   moisture_tex (R8, derived_size, LINEAR)：归一化湿度 [0, 1]
//   flow_tex     (R8, derived_size, LINEAR)：log-scaled 流量累积 [0, 1]
//
// 不再有 hex 逻辑、不再做 domain warp。整张地图就是这 4 张连续纹理的合成。

uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform sampler2D biome_tex : filter_nearest, repeat_disable;
uniform sampler2D moisture_tex : filter_linear, repeat_disable;
uniform sampler2D flow_tex : filter_linear, repeat_disable;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform vec2 hm_resolution = vec2(2048.0, 1536.0);
uniform vec2 derived_resolution = vec2(1024.0, 768.0);

uniform float sea_level : hint_range(0.0, 1.0) = 0.42;

// ─── Hypsometric 色阶（海陆双向，等高线设色） ────────────────────────────
uniform vec3 color_deep_ocean   : source_color = vec3(0.05, 0.10, 0.22);
uniform vec3 color_mid_ocean    : source_color = vec3(0.10, 0.18, 0.34);
uniform vec3 color_shallow      : source_color = vec3(0.22, 0.36, 0.50);
uniform vec3 color_coast_water  : source_color = vec3(0.32, 0.52, 0.62);
uniform vec3 color_beach        : source_color = vec3(0.85, 0.78, 0.55);
uniform vec3 color_lowland      : source_color = vec3(0.62, 0.68, 0.42);
uniform vec3 color_hill         : source_color = vec3(0.66, 0.55, 0.32);
uniform vec3 color_mountain     : source_color = vec3(0.50, 0.42, 0.38);
uniform vec3 color_peak         : source_color = vec3(0.65, 0.62, 0.60);
uniform vec3 color_snow         : source_color = vec3(0.96, 0.96, 0.96);

// ─── 双光源 hillshading ──────────────────────────────────────────────────
uniform float hillshade_strength : hint_range(0.0, 1.0) = 0.45;
uniform float hillshade_slope_gain : hint_range(0.5, 24.0) = 8.0;
uniform vec2  hillshade_dir      = vec2(-0.55, -0.55);
uniform vec2  hillshade_fill_dir = vec2( 0.60,  0.40);

// ─── 河流（从 flow accumulation） ───────────────────────────────────────
uniform float river_strength       : hint_range(0.0, 1.0) = 0.55;
uniform float river_threshold_low  : hint_range(0.0, 1.0) = 0.32;
uniform float river_threshold_high : hint_range(0.0, 1.0) = 0.55;
uniform vec3  river_color          : source_color = vec3(0.30, 0.50, 0.68);
uniform vec3  river_outline_color  : source_color = vec3(0.16, 0.30, 0.45);

// ─── 可选等高线 ──────────────────────────────────────────────────────────
uniform bool  contour_enabled = false;
uniform float contour_step       : hint_range(0.01, 0.20) = 0.05;
uniform float contour_strength   : hint_range(0.0, 0.40) = 0.18;
uniform vec3  contour_color      : source_color = vec3(0.20, 0.16, 0.10);

// ─── 海岸光晕 ─────────────────────────────────────────────────────────────
uniform vec3  coast_halo_color    : source_color = vec3(0.78, 0.86, 0.88);
uniform float coast_halo_strength : hint_range(0.0, 1.0) = 0.22;

// ─── 羊皮纸 ───────────────────────────────────────────────────────────────
uniform vec3  parchment_tint        : source_color = vec3(0.96, 0.88, 0.74);
uniform float parchment_strength    : hint_range(0.0, 0.4) = 0.10;
uniform float paper_grain_strength  : hint_range(0.0, 0.2) = 0.05;

const int B_OCEAN     = 0;
const int B_COAST     = 1;
const int B_PLAIN     = 2;
const int B_GRASSLAND = 3;
const int B_FOREST    = 4;
const int B_HILL      = 5;
const int B_MOUNTAIN  = 6;
const int B_DESERT    = 7;
const int B_TUNDRA    = 8;
const int B_SNOW      = 9;

varying vec2 v_world;

// ─── 噪声 ─────────────────────────────────────────────────────────────────

float hash21(vec2 p) {
	p = fract(p * vec2(234.34, 435.345));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
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

float voronoi_cell(vec2 p) {
	vec2 ip = floor(p);
	vec2 fp = fract(p);
	float min_d = 8.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 g = vec2(float(i), float(j));
			vec2 ofs = vec2(
				hash21(ip + g + vec2(1.7, 9.2)),
				hash21(ip + g + vec2(7.1, 3.4))
			);
			vec2 r = g + ofs - fp;
			float d = dot(r, r);
			min_d = min(min_d, d);
		}
	}
	return sqrt(min_d);
}

// ─── 高度解码（RG8 16-bit） ──────────────────────────────────────────────

float decode_height_rg8(vec2 uv) {
	vec4 s = texture(height_tex, uv);
	return (s.r * 256.0 + s.g) / 257.0;
}

// ─── 等高线设色（hypsometric tint） ───────────────────────────────────────
// 注意：用 is_water (biome 决定) 而不是 elev 来分支海陆，否则会因为 height_tex
// 的 barycentric 平滑插值在 hex 边界处把"水 hex 但 elev 偶尔越过 sea_level"
// 的像素画成陆地——结果就是海岸完全脱离 hex 形状，永远平滑曲线。

vec3 hypsometric_tint(float elev, bool is_water) {
	if (is_water) {
		// 海下：深海 → 中海 → 浅海 → 海岸水（按 elev/sea_level 比例做深浅梯度）
		float t = clamp(elev / max(sea_level, 0.001), 0.0, 1.0);
		if (t < 0.30) return mix(color_deep_ocean, color_mid_ocean, t / 0.30);
		if (t < 0.70) return mix(color_mid_ocean, color_shallow, (t - 0.30) / 0.40);
		return mix(color_shallow, color_coast_water, (t - 0.70) / 0.30);
	}
	// 海上：从沙滩色起步（不再混 coast_water），保证陆地边缘 ≠ 水域颜色，
	// hex 海岸边界视觉上清晰可见。
	float t = clamp((elev - sea_level) / max(1.0 - sea_level, 0.001), 0.0, 1.0);
	if (t < 0.10) return mix(color_beach, color_lowland, t / 0.10);
	if (t < 0.50) return mix(color_lowland, color_hill, (t - 0.10) / 0.40);
	if (t < 0.75) return mix(color_hill, color_mountain, (t - 0.50) / 0.25);
	if (t < 0.90) return mix(color_mountain, color_peak, (t - 0.75) / 0.15);
	return mix(color_peak, color_snow, (t - 0.90) / 0.10);
}

// ─── biome 色相调制（高度负责亮度，biome 负责色相） ──────────────────────

vec3 biome_hue_modulate(vec3 base, int biome) {
	if (biome == B_FOREST)    return base * vec3(0.70, 1.05, 0.65);
	if (biome == B_GRASSLAND) return base * vec3(0.85, 1.05, 0.78);
	if (biome == B_DESERT)    return base * vec3(1.18, 1.02, 0.72);
	if (biome == B_TUNDRA)    return base * vec3(0.92, 1.00, 1.00);
	if (biome == B_SNOW)      return base * vec3(1.02, 1.02, 1.05);
	if (biome == B_MOUNTAIN)  return base * vec3(1.00, 0.95, 0.95);
	if (biome == B_HILL)      return base * vec3(1.05, 1.00, 0.90);
	return base;
}

// ─── 锐利程序化贴图（不依赖 hex，世界坐标连续） ─────────────────────────

vec3 procedural_biome_detail(int biome, vec2 wp) {
	if (biome == B_FOREST) {
		float vor = voronoi_cell(wp * 0.30);
		float n = fbm(wp * 0.40, 3);
		float modulator = mix(0.78, 1.15, smoothstep(0.05, 0.6, vor));
		modulator *= mix(0.92, 1.05, n);
		return vec3(modulator);
	}
	if (biome == B_GRASSLAND) {
		float n = fbm(wp * 0.18, 3);
		float micro = fbm(wp * 0.45, 2);
		return vec3(mix(0.85, 1.10, n) * mix(0.95, 1.05, micro));
	}
	if (biome == B_DESERT) {
		vec2 dune_dir = vec2(0.85, 0.30);
		float t = dot(wp, dune_dir) * 0.040;
		float waves = sin(t + fbm(wp * 0.06, 2) * 5.0) * 0.5 + 0.5;
		float micro = fbm(wp * 0.30, 2);
		return vec3(mix(0.88, 1.10, waves) * mix(0.95, 1.05, micro));
	}
	if (biome == B_HILL) {
		float n = fbm(wp * 0.20, 3);
		float micro = fbm(wp * 0.45, 2);
		return vec3(mix(0.82, 1.12, n) * mix(0.95, 1.06, micro));
	}
	if (biome == B_MOUNTAIN) {
		float n = fbm(wp * 0.30, 4);
		float vor = voronoi_cell(wp * 0.16);
		return vec3(mix(0.65, 1.20, n) * mix(0.85, 1.10, smoothstep(0.05, 0.5, vor)));
	}
	if (biome == B_PLAIN) {
		float n = fbm(wp * 0.12, 3);
		float micro = fbm(wp * 0.40, 2);
		return vec3(mix(0.92, 1.08, n) * mix(0.97, 1.03, micro));
	}
	if (biome == B_TUNDRA) {
		float n = fbm(wp * 0.16, 3);
		return vec3(mix(0.85, 1.08, n));
	}
	if (biome == B_SNOW) {
		float n = fbm(wp * 0.20, 3);
		float micro = fbm(wp * 0.50, 2);
		return vec3(mix(0.93, 1.04, n) * mix(0.98, 1.02, micro));
	}
	return vec3(1.0);
}

// ─── 双光源 hillshading（key + fill，软阴影） ───────────────────────────

float hillshading_two_lights(vec2 uv) {
	vec2 texel = 1.0 / hm_resolution;
	float l = decode_height_rg8(uv - vec2(texel.x, 0.0));
	float r = decode_height_rg8(uv + vec2(texel.x, 0.0));
	float u = decode_height_rg8(uv - vec2(0.0, texel.y));
	float d = decode_height_rg8(uv + vec2(0.0, texel.y));
	float dx = (r - l) * hillshade_slope_gain;
	float dy = (d - u) * hillshade_slope_gain;
	vec3 normal = normalize(vec3(-dx, -dy, 1.0));

	vec3 key_dir  = normalize(vec3(hillshade_dir.x,      hillshade_dir.y,      0.65));
	vec3 fill_dir = normalize(vec3(hillshade_fill_dir.x, hillshade_fill_dir.y, 0.50));

	float key  = max(dot(normal, key_dir),  0.0);
	float fill = max(dot(normal, fill_dir), 0.0) * 0.40;
	return key + fill;
}

void vertex() {
	v_world = VERTEX;
}

void fragment() {
	vec2 wp = v_world;
	vec2 uv = clamp((wp - world_origin) / world_size, vec2(0.0), vec2(1.0));

	float elev = decode_height_rg8(uv);
	int biome = int(texture(biome_tex, uv).r * 255.0 + 0.5);
	float moist = texture(moisture_tex, uv).r;
	// B：sample flow_tex 时给 uv 加细高频扰动，让河岸边缘有"被流水冲蚀过"的不规则
	vec2 river_edge_warp = vec2(
		fbm(wp * 0.14 + vec2(7.0, -3.0), 2),
		fbm(wp * 0.14 + vec2(-11.0, 5.0), 2)
	) - 0.5;
	float flow = texture(flow_tex, uv + river_edge_warp * 0.0035).r;

	// is_water 由 biome 决定（hex 真理来源），不是 elev 平滑插值
	bool is_water = (biome == B_OCEAN) || (biome == B_COAST);

	// 1. Hypsometric base（海陆双向等高线设色）
	vec3 col = hypsometric_tint(elev, is_water);

	if (!is_water) {
		// 2. biome 色相调制
		col = biome_hue_modulate(col, biome);
		// 3. 锐利程序化贴图（同一 biome 在不同位置看起来不同）
		col *= procedural_biome_detail(biome, wp);
	}

	// 4. Hillshading（陆地强阴影；海面用低频纹理代替）
	if (!is_water) {
		float light = hillshading_two_lights(uv);
		col *= mix(1.0 - hillshade_strength, 1.0 + hillshade_strength, light);
	} else {
		float current = fbm(wp * 0.014 + vec2(31.0, 7.0), 3);
		col *= 1.0 + (current - 0.5) * 0.10;
		float ripple = fbm(wp * 0.05 + vec2(-15.0, 41.0), 2);
		col *= 1.0 + (ripple - 0.5) * 0.05;
	}

	// 5. 河流（仅陆地；流量驱动宽度）
	if (!is_water) {
		float river_t = smoothstep(river_threshold_low, river_threshold_high, flow);
		float outline_t = smoothstep(river_threshold_low * 0.85, river_threshold_low, flow);
		col = mix(col, river_outline_color, outline_t * 0.70 * river_strength);
		col = mix(col, river_color, river_t * river_strength);
	}

	// 6. 海岸光晕（海平面交界细线）
	float coast_t = 1.0 - clamp(abs(elev - sea_level) * 60.0, 0.0, 1.0);
	col = mix(col, coast_halo_color, coast_t * coast_halo_strength * 0.5);

	// 7. 可选等高线（陆地）
	if (contour_enabled && !is_water) {
		float contour_phase = fract(elev / max(contour_step, 0.001));
		float dist = abs(contour_phase - 0.5);
		float contour_t = smoothstep(0.50, 0.42, dist);
		col = mix(col, contour_color, contour_t * contour_strength);
	}

	// 8. 羊皮纸 + paper grain
	col = mix(col, col * parchment_tint, parchment_strength);
	float grain = fbm(wp * 0.45 + vec2(91.0, -7.0), 2);
	col *= mix(1.0 - paper_grain_strength, 1.0 + paper_grain_strength, grain);

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
