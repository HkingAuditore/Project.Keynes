shader_type canvas_item;
render_mode unshaded;

// 古典航海星盘海图背景着色器 (Antique Nautical Sea Chart & Brass Astrolabe)
// 用于主菜单背景、世界加载背景、新游戏舆图预览底板与布局缩略卡

uniform vec2 viewport_size = vec2(1600.0, 900.0);
uniform vec2 compass_uv = vec2(0.68, 0.48);
uniform float compass_scale = 0.28;
uniform vec2 secondary_rose_uv = vec2(0.26, 0.74);
uniform float motion_scale = 1.0;
uniform float compact_mode = 0.0;
uniform float show_neatline = 1.0;
uniform float survey_progress = 1.0;
uniform float seed_offset = 0.0;

float hash21(vec2 p) {
	ivec2 ip = ivec2(floor(p));
	uint ux = uint(ip.x + 32768);
	uint uy = uint(ip.y + 32768);
	uint h = ux * 374761393u + uy * 668265263u;
	h = (h ^ (h >> 13u)) * 1274126177u;
	h ^= (h >> 16u);
	return float(h & 1023u) * 0.0009765625;
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

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	mat2 rot = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
	for (int i = 0; i < 4; i++) {
		v += a * value_noise(p);
		p = rot * p * 2.02;
		a *= 0.5;
	}
	return v;
}

vec2 rotate2d(vec2 p, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

void fragment() {
	float aspect_ratio = max(viewport_size.x / max(viewport_size.y, 1.0), 0.25);
	vec2 aspect = vec2(aspect_ratio, 1.0);
	vec2 px = UV * viewport_size;
	vec2 p = (UV - 0.5) * aspect;
	float t = TIME * motion_scale;

	// 1. 深海宣纸底色与多尺度云斑纤维肌理（完全消除纯色条带感）
	vec2 seed_shift = vec2(mod(seed_offset, 97.0) * 0.13, mod(seed_offset, 53.0) * 0.19);
	float mottle = fbm(p * 2.6 + seed_shift);
	float fine_fiber = value_noise(px * vec2(0.18, 0.045)) * 0.5 + value_noise(px * vec2(0.045, 0.18)) * 0.5 - 0.5;
	float micro_grain = hash21(floor(px * 0.5)) - 0.5;

	vec3 sea_abyss = vec3(0.055, 0.135, 0.165);
	vec3 sea_mid = vec3(0.088, 0.205, 0.238);
	vec3 sea_shimmer = vec3(0.135, 0.285, 0.315);

	float radial_warmth = 1.0 - smoothstep(0.0, 0.95, length(p - (compass_uv - 0.5) * aspect));
	vec3 col = mix(sea_abyss, sea_mid, clamp(mottle * 0.85 + radial_warmth * 0.35, 0.0, 1.0));
	col = mix(col, sea_shimmer, smoothstep(0.55, 0.88, mottle) * 0.32);

	// 与岛屿同步的昼夜日照氛围与海面波光反射（晨曦金波、正午清澈、暮霭晚霞、星夜深海）
	float day_angle = t * 0.22 + 0.55;
	float sun_elev = sin(day_angle);
	float twilight = exp(-pow(sun_elev / 0.26, 2.0));
	float night = smoothstep(0.10, -0.32, sun_elev);
	vec2 sun_pos_uv = (compass_uv - 0.5) * aspect + vec2(cos(day_angle), sin(day_angle)) * 0.38;
	float sun_sea_glint = exp(-length(p - sun_pos_uv) * 2.6);
	col += vec3(0.45, 0.24, 0.10) * sun_sea_glint * twilight * 0.28;
	col += vec3(0.18, 0.28, 0.28) * sun_sea_glint * smoothstep(0.0, 0.5, sun_elev) * 0.18;
	col = mix(col, col * vec3(0.68, 0.78, 0.94), night * 0.32);

	col += vec3(fine_fiber * 0.018 + micro_grain * 0.010);

	// 2. 海底等深线（Bathymetric Isobaths）与动态古典水波版画线
	float bathy_field = fbm(p * 3.8 + seed_shift + vec2(t * 0.008, -t * 0.006));
	float isobath = abs(fract(bathy_field * 7.0) - 0.5);
	float isobath_line = 1.0 - smoothstep(0.015, 0.045, isobath);
	col = mix(col, vec3(0.42, 0.58, 0.56), isobath_line * 0.08 * (1.0 - compact_mode * 0.5));

	vec2 wave_uv = p * vec2(26.0, 42.0) + vec2(sin(p.y * 14.0 + t * 0.45) * 0.65, t * 0.18);
	float wave_crest = sin(wave_uv.x + sin(wave_uv.y * 0.7) * 1.4);
	float wave_line = smoothstep(0.92, 0.995, wave_crest) * (0.5 + 0.5 * sin(p.x * 9.0 - p.y * 7.0 + t * 0.3));
	col += vec3(0.62, 0.74, 0.72) * wave_line * (0.042 * (1.0 - compact_mode * 0.4));

	// 3. 古籍经纬网格（Graticule）与波托兰航海方位放射线（Portolan Rhumb Network）
	vec3 brass_ink = vec3(0.83, 0.71, 0.45);
	vec3 oxblood_ink = vec3(0.64, 0.25, 0.17);

	float grid_freq = mix(7.0, 4.0, compact_mode);
	vec2 curved_p = p + vec2(p.y * p.y * 0.06 * sign(p.x), -p.x * p.x * 0.04);
	vec2 g_uv = fract(curved_p * grid_freq);
	vec2 g_dist = min(g_uv, 1.0 - g_uv) / grid_freq;
	float px_scale = 1.0 / max(viewport_size.y, 1.0);
	float graticule = (1.0 - smoothstep(px_scale * 0.6, px_scale * 1.8, min(g_dist.x, g_dist.y)));
	float dash_mask = 0.65 + 0.35 * step(0.0, sin(max(curved_p.x, curved_p.y) * grid_freq * 31.4159));
	col = mix(col, brass_ink, graticule * dash_mask * 0.09);

	// 主星盘与副测绘点的16向方位放射线
	vec2 comp_c = (compass_uv - 0.5) * aspect;
	vec2 cp = p - comp_c;
	float cr = length(cp);
	float ca = atan(cp.y, cp.x);

	if (compact_mode < 0.5) {
		float rhumb_16 = abs(sin(ca * 8.0));
		float rhumb_w = max(cr * 0.012, px_scale * 0.9);
		float rhumb_line = (1.0 - smoothstep(0.0, rhumb_w, rhumb_16)) * smoothstep(compass_scale * 0.18, compass_scale * 0.38, cr) * (1.0 - smoothstep(0.45, 1.35, cr));
		col = mix(col, brass_ink, rhumb_line * 0.085);

		vec2 sec_c = (secondary_rose_uv - 0.5) * aspect;
		vec2 sp = p - sec_c;
		float sr = length(sp);
		float sa = atan(sp.y, sp.x);
		float sec_rhumb = (1.0 - smoothstep(0.0, max(sr * 0.016, px_scale), abs(sin(sa * 4.0)))) * smoothstep(0.03, 0.08, sr) * (1.0 - smoothstep(0.25, 0.85, sr));
		float sec_ring = 1.0 - smoothstep(px_scale * 0.8, px_scale * 2.0, abs(sr - 0.055));
		col = mix(col, brass_ink, (sec_rhumb * 0.06 + sec_ring * 0.14));
	}

	// 4. 多层动态旋转黄铜星盘罗盘 (Multi-Ring Brass Astrolabe & Wind Rose)
	float c_rad = compass_scale;
	if (c_rad > 0.02 && cr < c_rad * 1.38) {
		float aa = px_scale * 1.35;

		// 星盘底盘微暗与铜质柔光光晕
		float disc_fill = 1.0 - smoothstep(c_rad * 0.98, c_rad * 1.02, cr);
		float inner_glow = (1.0 - smoothstep(0.0, c_rad * 1.15, cr)) * 0.12;
		col += brass_ink * inner_glow;
		col = mix(col, vec3(0.045, 0.115, 0.140), disc_fill * 0.25);

		// 外圈双黄铜环 + 72分度尺（顺时针慢转）
		float a_outer = ca - t * 0.045;
		float r_outer1 = 1.0 - smoothstep(aa * 0.7, aa * 1.9, abs(cr - c_rad));
		float r_outer2 = 1.0 - smoothstep(aa * 0.6, aa * 1.7, abs(cr - c_rad * 0.91));
		float band_outer = step(c_rad * 0.91, cr) * step(cr, c_rad);
		float ticks_72 = smoothstep(0.88, 0.99, cos(a_outer * 72.0)) * step(c_rad * 0.94, cr) * step(cr, c_rad);
		float ticks_12 = smoothstep(0.95, 0.998, cos(a_outer * 12.0)) * band_outer;

		// 中圈36刻度逆时针游标环 + 偏心黄道环（逆时针慢转）
		float a_mid = ca + t * 0.072;
		float r_mid1 = 1.0 - smoothstep(aa * 0.6, aa * 1.7, abs(cr - c_rad * 0.74));
		float r_mid2 = 1.0 - smoothstep(aa * 0.6, aa * 1.6, abs(cr - c_rad * 0.67));
		float ticks_36 = smoothstep(0.90, 0.992, cos(a_mid * 36.0)) * step(c_rad * 0.67, cr) * step(cr, c_rad * 0.74);

		vec2 ecl_offset = vec2(cos(t * 0.06), sin(t * 0.06)) * (c_rad * 0.15);
		float ecl_dist = abs(length(cp - ecl_offset) - c_rad * 0.56);
		float ecl_ring = (1.0 - smoothstep(aa * 0.6, aa * 1.8, ecl_dist)) * disc_fill;

		// 内圈八风玫瑰星芒（8主芒 + 8副芒阴阳切面）
		float r_inner = 1.0 - smoothstep(aa * 0.6, aa * 1.6, abs(cr - c_rad * 0.36));
		float star_a = ca - t * 0.018;
		float star8_cos = cos(star_a * 4.0);
		float star8_sin = sin(star_a * 4.0);
		float main_ray_len = c_rad * (0.10 + 0.25 * pow(abs(star8_cos), 3.2) + 0.25 * pow(abs(star8_sin), 3.2));
		float sub_ray_len = c_rad * (0.08 + 0.16 * pow(abs(sin(star_a * 4.0)), 2.4));
		float star_mask = (1.0 - smoothstep(main_ray_len - aa * 2.0, main_ray_len + aa * 2.0, cr)) * step(c_rad * 0.045, cr);
		float facet_shade = step(0.0, sin(star_a * 8.0));

		// 动态测绘照准游标指针（Alidade Needle）
		vec2 needle_p = rotate2d(cp, -t * 0.16 - 0.55);
		float needle_bar = (1.0 - smoothstep(aa * 0.7, aa * 1.9, abs(needle_p.y))) * step(abs(needle_p.x), c_rad * 0.88);
		float needle_sight = (1.0 - smoothstep(aa * 0.8, aa * 2.0, abs(length(vec2(abs(needle_p.x) - c_rad * 0.62, needle_p.y)) - c_rad * 0.045)));
		float pivot_cap = 1.0 - smoothstep(c_rad * 0.032 - aa, c_rad * 0.032 + aa, cr);

		// 测绘进度高光弧（加载时随 survey_progress 亮起）
		float prog_angle = mod(ca + 1.5707963 + 6.2831853, 6.2831853) / 6.2831853;
		float prog_arc = step(prog_angle, clamp(survey_progress, 0.0, 1.0)) * (1.0 - smoothstep(aa * 1.0, aa * 2.8, abs(cr - c_rad * 0.825)));

		float brass_lines = clamp(
			r_outer1 * 0.85 + r_outer2 * 0.55 + ticks_72 * 0.48 + ticks_12 * 0.75 +
			r_mid1 * 0.65 + r_mid2 * 0.42 + ticks_36 * 0.42 + r_inner * 0.55 +
			needle_bar * 0.62 + needle_sight * 0.70 + pivot_cap * 0.95,
			0.0, 1.0
		);

		vec3 star_col = mix(vec3(0.62, 0.48, 0.26), vec3(0.95, 0.83, 0.52), facet_shade);
		float rose_opacity = mix(0.28, 0.42, compact_mode);
		col = mix(col, star_col, star_mask * rose_opacity);
		col = mix(col, oxblood_ink, ecl_ring * 0.34);
		col = mix(col, vec3(0.95, 0.82, 0.50), brass_lines * mix(0.38, 0.52, compact_mode));
		if (survey_progress < 0.995) {
			col = mix(col, vec3(0.98, 0.86, 0.54), prog_arc * 0.65);
		}
	}

	// 5. 古籍暗角与图廓经纬分度边框（Cartographic Neatline）
	vec2 vig_uv = UV * (1.0 - UV.yx);
	float vig = clamp(pow(max(vig_uv.x * vig_uv.y * 16.0, 0.0), 0.22), 0.68, 1.0);
	col *= vig;

	if (show_neatline > 0.5) {
		vec2 d_px = min(px, viewport_size - px);
		float edge_d = min(d_px.x, d_px.y);
		float outer_line = 1.0 - smoothstep(0.0, 1.4, abs(edge_d - 6.0));
		float inner_line = 1.0 - smoothstep(0.0, 1.4, abs(edge_d - 11.0));
		float tick_band = step(6.0, edge_d) * step(edge_d, 11.0);
		float checker = step(0.0, sin(px.x * 0.09) * sin(px.y * 0.09));
		col = mix(col, brass_ink * 0.85, (outer_line * 0.55 + inner_line * 0.40));
		col = mix(col, brass_ink * 0.70, tick_band * checker * 0.16);
	}

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
