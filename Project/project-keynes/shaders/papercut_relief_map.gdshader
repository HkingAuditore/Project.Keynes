shader_type canvas_item;
render_mode unshaded;

// 剪纸等高浮雕舆图着色器 (Papercut Stratified Relief Atlas v2)
// 核心特性：
// 1. 逐层抗锯齿剪纸叠片合成 (Anti-aliased Multi-Layer Paper Stacking)
// 2. 每层独立的多采样柔和投影 (Soft Multi-Tap Drop Shadow) 与立体纸张厚度切边 (Deckle Bevel)
// 3. 宣纸纤维与羊皮纸云斑肌理 (Handmade Xuan/Parchment Fiber Grain)
// 4. 随 TIME 平滑旋转的黄铜星轨罗盘与水波纹

uniform vec2 viewport_size = vec2(1600.0, 960.0);
uniform float seed_val = 29.0;
uniform int num_continents : hint_range(1, 8) = 2;
uniform float continent_size : hint_range(0.2, 0.9) = 0.56;
uniform float sea_level : hint_range(0.1, 0.8) = 0.46;
uniform float continent_spacing : hint_range(0.0, 1.0) = 0.80;
uniform float island_amount : hint_range(0.0, 1.0) = 0.45;
uniform float wetness : hint_range(0.0, 1.0) = 0.58;
uniform float river_density : hint_range(0.0, 1.0) = 0.55;
uniform float lake_density : hint_range(0.0, 1.0) = 0.45;
uniform float reveal_progress : hint_range(0.0, 1.0) = 1.0;
uniform float darken_veil : hint_range(0.0, 1.0) = 0.0;
uniform vec2 parallax_offset = vec2(0.0, 0.0);
uniform vec2 map_center_bias = vec2(0.66, 0.50);
uniform vec2 compass_uv = vec2(0.68, 0.50);
uniform float compass_scale = 0.26;
uniform bool show_outer_frame = true;

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
	mat2 rot = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) break;
		sum += value_noise(p * freq) * amp;
		p = rot * p;
		freq *= 2.03;
		amp *= 0.49;
	}
	return sum;
}

float ridged_fbm(vec2 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float freq = 1.0;
	mat2 rot = mat2(vec2(0.80, -0.60), vec2(0.60, 0.80));
	for (int i = 0; i < 4; i++) {
		if (i >= octaves) break;
		float n = value_noise(p * freq);
		n = 1.0 - abs(n * 2.0 - 1.0);
		sum += n * n * amp;
		p = rot * p;
		freq *= 2.12;
		amp *= 0.47;
	}
	return sum;
}

// 宣纸/羊皮纸物理纤维肌理：云斑 + 交织植物纤维 + 微颗粒
float paper_texture(vec2 frag_px) {
	vec2 p = frag_px * 0.075;
	float mottle = fbm(p * 0.16 + vec2(13.7, 5.3), 3) - 0.5;
	float fib1 = value_noise(vec2(p.x * 3.2 + p.y * 0.7, p.y * 0.38)) - 0.5;
	float fib2 = value_noise(vec2(p.x * 0.6 - p.y * 3.0, p.x * 0.36)) - 0.5;
	float grain = hash21(floor(frag_px * 0.65)) - 0.5;
	return mottle * 0.085 + (fib1 + fib2) * 0.036 + grain * 0.020;
}

// 采样连续地形高程 [0, 1]
float sample_elevation(vec2 p) {
	float s = mod(seed_val, 997.0) * 0.173 + 1.0;
	vec2 seed_vec = vec2(cos(s) * 17.3 + s * 0.29, sin(s) * 21.1 - s * 0.17);

	// 柔和二阶侵蚀扭曲，形成自然弯曲的剪纸边缘
	vec2 q = vec2(
		fbm(p * 2.1 + seed_vec + vec2(1.7, 9.2), 3),
		fbm(p * 2.1 + seed_vec + vec2(8.3, 2.8), 3)
	) - 0.5;
	vec2 r = vec2(
		fbm(p * 4.2 + q * 1.35 + seed_vec + vec2(13.1, 4.7), 2),
		fbm(p * 4.2 + q * 1.35 + seed_vec + vec2(5.4, 17.3), 2)
	) - 0.5;
	vec2 wp = p + q * 0.22 + r * 0.09;

	int n_cores = clamp(num_continents, 1, 8);
	float spread = mix(0.15, 0.32, clamp(continent_spacing, 0.0, 1.0));
	float core_radius = mix(0.22, 0.44, clamp(continent_size, 0.2, 0.9)) / sqrt(float(n_cores) * 0.65 + 0.35);

	float envelope = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= n_cores) break;
		float fi = float(i);
		vec2 core_pos = map_center_bias;
		if (n_cores == 1) {
			core_pos += vec2(sin(s + 1.2) * 0.03, cos(s + 0.7) * 0.02);
		} else if (n_cores == 2) {
			float side = (i == 0) ? -1.0 : 1.0;
			core_pos += vec2(side * spread * 0.82, side * spread * 0.25 * sin(s * 1.4));
		} else {
			float angle = s * 1.2 + fi * (6.2831853 / float(n_cores));
			float rad_jitter = 0.80 + 0.24 * hash21(vec2(fi + 2.0, s));
			core_pos += vec2(cos(angle), sin(angle) * 0.84) * spread * rad_jitter;
		}
		vec2 d = (wp - core_pos) * vec2(1.0, 1.12);
		float dist = length(d);
		float w = smoothstep(core_radius * 1.45, core_radius * 0.14, dist);
		envelope = max(envelope, w);
	}

	float detail_fbm = fbm(wp * 3.4 + seed_vec * 1.2, 4);
	float archipelago_noise = fbm(wp * 7.6 - seed_vec * 0.8, 3);
	float island_field = smoothstep(0.56 - island_amount * 0.15, 0.80, archipelago_noise) * (0.24 + island_amount * 0.32);
	float ridge = ridged_fbm(wp * 3.6 + seed_vec * 0.6, 3);
	float lake_basin = smoothstep(0.69 - lake_density * 0.16, 0.84, fbm(wp * 5.8 + vec2(31.2, -14.8) + seed_vec, 3));

	// 控制高程分布，使平原、林地、丘陵层次饱满，仅最高脊线露出雪峰
	float h = envelope * 0.50 + detail_fbm * 0.34 + island_field * 0.28 + ridge * envelope * 0.24;
	h -= lake_basin * envelope * 0.20 * lake_density;

	vec2 edge_d = abs(p - vec2(0.5)) * 2.0;
	float border_fade = 1.0 - smoothstep(0.84, 1.02, max(edge_d.x, edge_d.y));
	h *= mix(0.65, 1.0, border_fade);

	float eff_sea = mix(sea_level + 0.24, sea_level, smoothstep(0.0, 1.0, reveal_progress));
	return clamp(h - (eff_sea - 0.46), 0.0, 1.0);
}

// 剪纸各层配色（与局内地图色板严格对齐）
vec3 get_layer_color(int layer_idx, vec2 p) {
	float variation = fbm(p * 3.5 + vec2(float(layer_idx) * 3.7, -9.1), 2) - 0.5;
	float wet = clamp(wetness, 0.0, 1.0);

	vec3 col = vec3(0.140, 0.235, 0.335); // 0: 深海底纸（深青金蓝）
	if (layer_idx == 1) {
		col = vec3(0.195, 0.325, 0.425); // 1: 中海层
	} else if (layer_idx == 2) {
		col = vec3(0.325, 0.485, 0.545); // 2: 浅海大陆架（天青）
	} else if (layer_idx == 3) {
		col = mix(vec3(0.885, 0.820, 0.655), vec3(0.815, 0.795, 0.615), wet); // 3: 海岸暖沙纸
	} else if (layer_idx == 4) {
		col = mix(vec3(0.805, 0.715, 0.505), vec3(0.485, 0.625, 0.425), wet); // 4: 平原与苍翠林原
	} else if (layer_idx == 5) {
		col = mix(vec3(0.735, 0.620, 0.445), vec3(0.610, 0.585, 0.420), wet * 0.5); // 5: 赭石丘陵台地
	} else if (layer_idx == 6) {
		col = vec3(0.575, 0.485, 0.395); // 6: 崇山褐岩层
	} else if (layer_idx >= 7) {
		col = vec3(0.925, 0.895, 0.825); // 7: 峰顶暖白宣纸
	}
	return col * (1.0 + variation * 0.065);
}

void fragment() {
	vec2 aspect = vec2(viewport_size.x / max(viewport_size.y, 1.0), 1.0);
	vec2 px = UV * viewport_size;
	vec2 p = (UV - 0.5) * aspect + 0.5 + parallax_offset * 0.016;
	vec2 texel = aspect / max(viewport_size, vec2(1.0));

	float sl = sea_level;
	float h_c = sample_elevation(p);

	// 沿西北光源方向采样多级偏移，用于合成真实的剪纸层叠投影与切边厚度高光
	vec2 sun_dir = normalize(vec2(-0.75, -0.66));
	float h_bevel = sample_elevation(p + sun_dir * texel * 2.4);
	float h_sh1 = sample_elevation(p - sun_dir * texel * 5.0);
	float h_sh2 = sample_elevation(p - sun_dir * texel * 11.0);
	float h_sh3 = sample_elevation(p - sun_dir * texel * 18.0);

	// 预计算紙张肌理
	float fiber = paper_texture(px);

	// 底层：深海宣纸底板 + 古籍水波暗纹
	vec3 col = get_layer_color(0, p) + vec3(fiber * 0.75);
	float wave_pat = sin((p.x * 38.0 + sin(p.y * 24.0 + TIME * 0.42) * 0.75) * 3.14159);
	col += vec3(0.75, 0.84, 0.88) * smoothstep(0.90, 0.99, wave_pat) * 0.045;

	// 7 层剪纸高程阈值
	float span = max(1.0 - sl, 0.15);
	float thresholds[7] = float[7](
		sl - 0.14,
		sl - 0.05,
		sl,
		sl + span * 0.11,
		sl + span * 0.30,
		sl + span * 0.52,
		sl + span * 0.76
	);

	// 逐层向上叠贴剪纸：先投射本层在底层的柔和阴影，再铺设本层纸面与切边高光
	float aa = max(fwidth(h_c) * 1.35, 0.0045);
	for (int k = 0; k < 7; k++) {
		float th = thresholds[k];
		float mask_c = smoothstep(th - aa, th + aa, h_c);
		float mask_b = smoothstep(th - aa, th + aa, h_bevel);
		float sh1 = smoothstep(th - 0.012, th + 0.012, h_sh1);
		float sh2 = smoothstep(th - 0.018, th + 0.018, h_sh2);
		float sh3 = smoothstep(th - 0.024, th + 0.024, h_sh3);

		// 1. 本层投射在下层纸面上的三阶柔和阴影（海岸层 k==2 阴影更深，强化海陆分离感）
		float shadow_weight = (sh1 * 0.48 + sh2 * 0.32 + sh3 * 0.20) * (1.0 - mask_c);
		float shadow_darkness = (k == 2) ? 0.38 : ((k >= 3) ? 0.26 : 0.16);
		col *= 1.0 - shadow_weight * shadow_darkness;

		// 2. 本层纸张本体色 + 纸面微浮雕明暗
		vec3 paper_col = get_layer_color(k + 1, p) + vec3(fiber);
		float local_slope = clamp((h_bevel - h_c) * 16.0, -0.12, 0.12);
		paper_col *= 1.0 - local_slope * 0.45;

		// 3. 纸张切口厚度：向阳侧露出暖白/描金纸芯切边，背阴侧压印细墨线
		float sun_rim = clamp(mask_c - mask_b, 0.0, 1.0);
		float shade_rim = clamp(mask_b - mask_c, 0.0, 1.0);
		vec3 rim_col = (k == 2) ? vec3(0.99, 0.95, 0.82) : vec3(0.96, 0.92, 0.80);
		paper_col = mix(paper_col, rim_col, sun_rim * 0.82);

		col = mix(col, paper_col, mask_c);
		col = mix(col, vec3(0.12, 0.09, 0.06), shade_rim * 0.32);
	}

	// 内陆剪纸河网（在陆地平原与丘陵层切出蜿蜒青蓝河槽与浅沙河岸）
	if (h_c > sl + 0.01 && h_c < sl + span * 0.62 && river_density > 0.08) {
		float s = mod(seed_val, 997.0) * 0.173;
		float rv_field = abs(fbm(p * 4.8 + vec2(s, -s * 0.7), 3) - 0.5);
		float rv_w = mix(0.0035, 0.0095, river_density) * (1.25 - (h_c - sl) / span);
		float rv_mask = 1.0 - smoothstep(rv_w * 0.4, rv_w, rv_field);
		float rv_bank = (1.0 - smoothstep(rv_w, rv_w * 1.85, rv_field)) * (1.0 - rv_mask);
		col = mix(col, vec3(0.95, 0.90, 0.76), rv_bank * 0.55);
		col = mix(col, vec3(0.22, 0.39, 0.48) + vec3(fiber * 0.5), rv_mask * 0.88);
	}

	// 经纬测绘细线与动态旋转黄铜星轨罗盘
	vec2 grid_uv = fract(p * 8.0);
	float grid_line = (1.0 - smoothstep(0.0, 0.010, min(grid_uv.x, grid_uv.y))) * 0.065;
	col = mix(col, vec3(0.86, 0.74, 0.48), grid_line);

	vec2 comp_center = (compass_uv - 0.5) * aspect + 0.5;
	vec2 cp = p - comp_center;
	float cr = length(cp);
	float c_rad = compass_scale;
	if (cr < c_rad * 1.32 && c_rad > 0.02) {
		float ca = atan(cp.y, cp.x);
		float ring_outer = 1.0 - smoothstep(0.0010, 0.0028, abs(cr - c_rad));
		float ring_mid = 1.0 - smoothstep(0.0009, 0.0024, abs(cr - c_rad * 0.76));
		float ring_inner = 1.0 - smoothstep(0.0009, 0.0024, abs(cr - c_rad * 0.42));

		float ticks_1 = smoothstep(0.93, 0.995, cos((ca + TIME * 0.09) * 24.0))
			* step(c_rad * 0.93, cr) * step(cr, c_rad);
		float ticks_2 = smoothstep(0.94, 0.995, cos((ca - TIME * 0.14) * 36.0))
			* step(c_rad * 0.71, cr) * step(cr, c_rad * 0.76);

		float cross_line = (1.0 - smoothstep(0.0007, 0.0022, min(abs(cp.x), abs(cp.y))))
			* step(cr, c_rad * 1.10) * 0.42;
		vec2 rot_cp = mat2(vec2(cos(0.40), -sin(0.40)), vec2(sin(0.40), cos(0.40))) * cp;
		float ecliptic = (1.0 - smoothstep(0.0007, 0.0022, abs(rot_cp.y)))
			* step(cr, c_rad * 1.18) * 0.40;

		float brass_m = clamp(ring_outer * 0.65 + ring_mid * 0.45 + ring_inner * 0.38 + ticks_1 * 0.52 + ticks_2 * 0.38 + cross_line, 0.0, 1.0);
		col = mix(col, vec3(0.92, 0.77, 0.44), brass_m * 0.68);
		col = mix(col, vec3(0.68, 0.24, 0.16), ecliptic * 0.62);
	}

	// 温润古籍暗角
	vec2 vig_uv = UV * (1.0 - UV.yx);
	float vig = clamp(pow(vig_uv.x * vig_uv.y * 15.0, 0.20), 0.74, 1.0);
	col *= vig;

	if (darken_veil > 0.001) {
		col = mix(col, vec3(0.08, 0.06, 0.045), darken_veil * 0.44);
	}

	if (show_outer_frame) {
		vec2 d_px = min(px, viewport_size - px);
		float border_dist = min(d_px.x, d_px.y);
		float outer_b = 1.0 - smoothstep(0.0, 1.5, abs(border_dist - 10.0));
		float inner_b = 1.0 - smoothstep(0.0, 1.2, abs(border_dist - 15.0));
		col = mix(col, vec3(0.84, 0.67, 0.36), outer_b * 0.62);
		col = mix(col, vec3(0.58, 0.22, 0.15), inner_b * 0.46);
	}

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
