shader_type canvas_item;
render_mode unshaded;

// 主界面左侧立体多层剪纸浮雕与明暗光影卷宗 (Sculpted Multi-Strata Papercut & Chiaroscuro Folio)
// 彻底破除死板方框与平涂浅色：
// 1. 四层大尺度手工裁切错落纸阶（底层深褐卡纸、二层赭石浮雕层、三层暖黄叠页、顶层折纸受光主面）
// 2. 右侧与右下边缘雕刻出与海图岛屿同源的「等高线剪纸阶梯」与卷曲飞边
// 3. 强烈的左上暖阳斜射聚光 + 折纸切面明暗交界线 + 右下深邃暖褐暗部（高达 45% 明暗对比）
// 4. 真实纸张纤维凹凸法线高光与深邃层间落影

uniform sampler2D paper_grain_tex : filter_linear, repeat_enable;
uniform vec2 panel_size = vec2(396.0, 484.0);
uniform float motion_scale : hint_range(0.0, 1.0) = 1.0;

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
		p = rot * p * 2.03;
		a *= 0.5;
	}
	return v;
}

vec2 rotate2d(vec2 p, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// 构造具有大幅度手工剪纸起伏、不规则折角与等高阶梯边缘的纸层掩码
float papercut_sheet_sdf(vec2 uv, vec2 center, vec2 half_ext, float angle, float seed, float waviness, out float curl_out) {
	vec2 p = rotate2d(uv - center, angle);
	vec2 d = abs(p) - half_ext;

	// 大尺度剪纸轮廓起伏（10~22px 级别的有机弯曲，彻底打破笔直方框线）
	float macro_wave = (fbm(p * 3.8 + vec2(seed * 2.7, seed * 5.1)) - 0.5) * 0.036 * waviness;
	float mid_cut = (fbm(p * 11.5 + vec2(-seed * 4.3, seed * 8.9)) - 0.5) * 0.015 * waviness;
	float deckle_fiber = (value_noise(p * 52.0 + vec2(seed * 13.0, seed * 7.0)) - 0.5) * 0.0045;

	// 右侧与底部边缘的不对称手工撕口与阶梯缩进
	float right_step = smoothstep(0.15, 0.65, sin(p.y * 7.5 + seed * 1.9)) * step(0.0, p.x) * 0.018 * waviness;
	float bottom_step = smoothstep(0.20, 0.70, cos(p.x * 8.5 - seed * 2.4)) * step(0.0, p.y) * 0.015 * waviness;

	float box_d = length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);

	// 右上角与左下角不规则手工斜裁角
	vec2 ur = p - vec2(half_ext.x - 0.065, -half_ext.y + 0.055);
	box_d = max(box_d, (ur.x - ur.y * 0.85) * 0.72);
	vec2 ll = p - vec2(-half_ext.x + 0.045, half_ext.y - 0.050);
	box_d = max(box_d, (-ll.x * 0.80 + ll.y) * 0.72);

	// 右下角大幅度向上卷曲折角
	vec2 lr = clamp((p - (half_ext - vec2(0.18, 0.16))) / vec2(0.18, 0.16), vec2(0.0), vec2(1.0));
	curl_out = lr.x * lr.y;
	box_d += pow(curl_out, 1.5) * 0.022;

	return box_d + macro_wave + mid_cut + deckle_fiber + right_step + bottom_step;
}

float mask_from_sdf(float sdf, float aa) {
	return 1.0 - smoothstep(-aa, aa, sdf);
}

// 粗颗粒手工桑皮纸/宣纸三维凹凸高度场
float paper_bump_height(vec2 px) {
	vec2 uv1 = fract(px / 210.0);
	vec2 uv2 = fract(px / 95.0 + vec2(0.37, 0.61));
	float t1 = texture(paper_grain_tex, uv1).r - 0.5;
	float t2 = texture(paper_grain_tex, uv2).g - 0.5;
	float crumple = fbm(px * 0.014 + vec2(4.1, 8.7)) - 0.5;
	float fibers = (value_noise(px * vec2(0.20, 0.05)) - 0.5) * 0.35 + (value_noise(px * vec2(0.05, 0.20)) - 0.5) * 0.35;
	return crumple * 0.65 + t1 * 0.55 + t2 * 0.30 + fibers * 0.40;
}

void fragment() {
	vec2 px = UV * panel_size;
	vec2 px_step = 1.0 / max(panel_size, vec2(1.0));
	float aa = 1.6 / max(min(panel_size.x, panel_size.y), 1.0);
	float t = TIME * motion_scale;

	vec2 sun_dir = normalize(vec2(-0.78, -0.62));
	vec2 bev_ofs = sun_dir * px_step * 2.8;

	// --- 第 0 层：底层深古铜褐厚衬板（大角度倾斜 -3.8°，投射深海浓影） ---
	float c0_curl = 0.0, dummy = 0.0;
	vec2 c0 = vec2(0.512, 0.515);
	vec2 ext0 = vec2(0.435, 0.448);
	float sdf0 = papercut_sheet_sdf(UV, c0, ext0, -0.066, 1.1, 1.25, c0_curl);
	float m0 = mask_from_sdf(sdf0, aa);
	float m0_bev = mask_from_sdf(papercut_sheet_sdf(UV + bev_ofs, c0, ext0, -0.066, 1.1, 1.25, dummy), aa);
	float m0_sh = mask_from_sdf(papercut_sheet_sdf(UV - vec2(0.026, 0.036), c0, ext0, -0.066, 1.1, 1.25, dummy), aa * 8.0);

	// --- 第 1 层：中下层赭石暖褐剪纸层（反向倾斜 +2.8°，右侧与下侧露出宽阔剪纸阶梯） ---
	float c1_curl = 0.0;
	vec2 c1 = vec2(0.502, 0.504);
	vec2 ext1 = vec2(0.425, 0.438);
	float sdf1 = papercut_sheet_sdf(UV, c1, ext1, 0.048, 3.7, 1.15, c1_curl);
	float m1 = mask_from_sdf(sdf1, aa);
	float m1_bev = mask_from_sdf(papercut_sheet_sdf(UV + bev_ofs, c1, ext1, 0.048, 3.7, 1.15, dummy), aa);
	float m1_sh1 = mask_from_sdf(papercut_sheet_sdf(UV - vec2(0.014, 0.020), c1, ext1, 0.048, 3.7, 1.15, dummy), aa * 3.5);
	float m1_sh2 = mask_from_sdf(papercut_sheet_sdf(UV - vec2(0.028, 0.038), c1, ext1, 0.048, 3.7, 1.15, dummy), aa * 7.0);

	// --- 第 2 层：中上层暖黄古旧桑皮纸（微倾 -1.5°） ---
	float c2_curl = 0.0;
	vec2 c2 = vec2(0.492, 0.494);
	vec2 ext2 = vec2(0.412, 0.426);
	float sdf2 = papercut_sheet_sdf(UV, c2, ext2, -0.026, 7.3, 1.05, c2_curl);
	float m2 = mask_from_sdf(sdf2, aa);
	float m2_bev = mask_from_sdf(papercut_sheet_sdf(UV + bev_ofs, c2, ext2, -0.026, 7.3, 1.05, dummy), aa);
	float m2_sh1 = mask_from_sdf(papercut_sheet_sdf(UV - vec2(0.011, 0.016), c2, ext2, -0.026, 7.3, 1.05, dummy), aa * 3.0);
	float m2_sh2 = mask_from_sdf(papercut_sheet_sdf(UV - vec2(0.024, 0.032), c2, ext2, -0.026, 7.3, 1.05, dummy), aa * 6.0);

	// --- 第 3 层：顶层受光主扉页（带右下等高剪纸缺口与折纸光影面） ---
	float c3_curl = 0.0;
	vec2 c3 = vec2(0.482, 0.484);
	vec2 ext3 = vec2(0.398, 0.414);
	float sdf3 = papercut_sheet_sdf(UV, c3, ext3, 0.008, 12.9, 0.95, c3_curl);
	// 在顶层右下角与右上角切出如同岛屿等高线般的阶梯缩进，露出下层剪纸
	float topo_carve = smoothstep(0.62, 0.92, UV.x + UV.y * 0.65 + (fbm(UV * 6.0 + vec2(1.7, 3.2)) - 0.5) * 0.22) * 0.022;
	sdf3 += topo_carve;
	float m3 = mask_from_sdf(sdf3, aa);
	float m3_bev = mask_from_sdf(papercut_sheet_sdf(UV + bev_ofs, c3, ext3, 0.008, 12.9, 0.95, dummy) + topo_carve, aa);
	vec2 sh3_ofs = vec2(0.010, 0.015) * (1.0 + c3_curl * 1.4);
	float m3_sh1 = mask_from_sdf(sdf3 - (sh3_ofs.x * 0.7 + sh3_ofs.y * 0.7), aa * 3.2);
	float m3_sh2 = mask_from_sdf(sdf3 - (sh3_ofs.x * 1.5 + sh3_ofs.y * 1.5), aa * 7.5);

	// 计算三维纸张纤维与折痕凹凸法线（Raking-Light 3D Normal Mapping）
	float h0 = paper_bump_height(px);
	float hx = paper_bump_height(px + vec2(1.8, 0.0));
	float hy = paper_bump_height(px + vec2(0.0, 1.8));

	// 叠加折纸波浪起伏（让整张纸面像真实厚手工纸一样有轻微的凹凸起伏，斜射光下明暗层次丰富）
	float sheet_wave = sin(UV.x * 5.8 - UV.y * 4.2 + 0.7) * 0.14 + cos(UV.x * 3.4 + UV.y * 6.5 - 1.2) * 0.11;
	float wave_dx = cos(UV.x * 5.8 - UV.y * 4.2 + 0.7) * 0.81 - sin(UV.x * 3.4 + UV.y * 6.5 - 1.2) * 0.37;
	float wave_dy = -cos(UV.x * 5.8 - UV.y * 4.2 + 0.7) * 0.59 - sin(UV.x * 3.4 + UV.y * 6.5 - 1.2) * 0.72;

	vec3 paper_N = normalize(vec3(
		(h0 - hx) * 2.6 - wave_dx * 0.38,
		(h0 - hy) * 2.6 - wave_dy * 0.38,
		0.48
	));
	// 与大陆日照呼应的左上暖金斜射光源（低仰角 raking light 最能凸显纸张肌理凹凸）
	float lamp_angle = t * 0.22 + 0.55;
	vec3 paper_L = normalize(vec3(-0.68 + cos(lamp_angle) * 0.22, -0.52 + sin(lamp_angle) * 0.18, 0.52));
	float raking_diff = clamp(dot(paper_N, paper_L), 0.0, 1.0);
	float bump = (raking_diff - 0.52) * 0.65;

	// 折纸对角微折痕（Paper Crease Ridges）：产生真实的纸面受光切面与背光切面对比
	float fold1 = tanh((UV.x * 0.75 + UV.y * 0.55 - 0.52 + (fbm(UV * 3.5) - 0.5) * 0.08) * 14.0);
	float fold1_ridge = 1.0 - abs(fold1);
	float fold2 = tanh((UV.x * -0.45 + UV.y * 0.85 - 0.28 + (fbm(UV * 4.2 + 5.0) - 0.5) * 0.08) * 16.0);
	float fold2_ridge = 1.0 - abs(fold2);
	float facet_shade = fold1 * 0.095 + fold2 * 0.075 - (fold1_ridge + fold2_ridge) * 0.055;

	// 左上暖阳斜射聚光 + 缓慢呼吸的烛光暖晕
	vec2 light_origin = vec2(0.16 + sin(t * 0.4) * 0.03, 0.14 + cos(t * 0.3) * 0.03);
	float light_dist = length((UV - light_origin) * vec2(0.95, 1.12));
	float chiaroscuro = smoothstep(0.04, 0.96, light_dist);

	// 初始为海图上的深邃落影
	float any_paper = max(max(m0, m1), max(m2, m3));
	float outer_shadow = m0_sh * (1.0 - any_paper);
	vec3 col = vec3(0.015, 0.035, 0.045);
	float alpha = outer_shadow * 0.82;

	// 合成第 0 层：深古铜褐厚底纸
	if (m0 > 0.001) {
		vec3 col0 = mix(vec3(0.54, 0.41, 0.27), vec3(0.36, 0.26, 0.16), chiaroscuro);
		col0 += vec3(h0 * 0.05 + bump * 0.09);
		float rim0 = clamp(m0 - m0_bev, 0.0, 1.0);
		col0 = mix(col0, vec3(0.86, 0.72, 0.48), rim0 * 0.75);
		col = mix(col, col0, m0);
		alpha = max(alpha, m0);
	}

	// 第 1 层投射在第 0 层上的浓重层间落影
	float sh1 = (m1_sh1 * 0.62 + m1_sh2 * 0.38) * (1.0 - m1);
	col *= 1.0 - sh1 * 0.58 * m0;
	alpha = clamp(alpha + sh1 * 0.45 * (1.0 - alpha), 0.0, 1.0);

	// 合成第 1 层：赭石暖金剪纸浮雕层
	if (m1 > 0.001) {
		vec3 col1 = mix(vec3(0.74, 0.59, 0.40), vec3(0.50, 0.38, 0.24), chiaroscuro);
		col1 += vec3(h0 * 0.055 + bump * 0.10);
		float rim1 = clamp(m1 - m1_bev, 0.0, 1.0);
		float shade_rim1 = clamp(m1_bev - m1, 0.0, 1.0);
		col1 = mix(col1, vec3(0.95, 0.84, 0.62), rim1 * 0.85);
		col1 = mix(col1, vec3(0.24, 0.16, 0.09), shade_rim1 * 0.55);
		col = mix(col, col1, m1);
		alpha = max(alpha, m1);
	}

	// 第 2 层投射在下层上的层间落影
	float sh2 = (m2_sh1 * 0.64 + m2_sh2 * 0.36) * (1.0 - m2);
	col *= 1.0 - sh2 * 0.56 * max(m0, m1);
	alpha = clamp(alpha + sh2 * 0.45 * (1.0 - alpha), 0.0, 1.0);

	// 合成第 2 层：古旧暖麦桑皮纸
	if (m2 > 0.001) {
		vec3 col2 = mix(vec3(0.88, 0.78, 0.58), vec3(0.64, 0.52, 0.36), chiaroscuro);
		col2 += vec3(h0 * 0.06 + bump * 0.11);
		float rim2 = clamp(m2 - m2_bev, 0.0, 1.0);
		float shade_rim2 = clamp(m2_bev - m2, 0.0, 1.0);
		col2 = mix(col2, vec3(0.98, 0.91, 0.74), rim2 * 0.88);
		col2 = mix(col2, vec3(0.30, 0.20, 0.12), shade_rim2 * 0.52);
		col = mix(col, col2, m2);
		alpha = max(alpha, m2);
	}

	// 第 3 层投射在下层上的深邃立体阴影（卷角处尤为深邃）
	float sh3 = (m3_sh1 * 0.65 + m3_sh2 * 0.35) * (1.0 - m3);
	col *= 1.0 - sh3 * (0.58 + c3_curl * 0.26) * max(m0, max(m1, m2));
	alpha = clamp(alpha + sh3 * 0.48 * (1.0 - alpha), 0.0, 1.0);

	// 合成第 3 层：顶层主扉页（戏剧性左上暖阳受光 + 折纸切面 + 四周茶褐陈化包浆）
	if (m3 > 0.001) {
		vec3 sunlit_gold_ivory = vec3(0.98, 0.92, 0.78);
		vec3 warm_parchment = vec3(0.87, 0.77, 0.59);
		vec3 deep_umber_shade = vec3(0.66, 0.53, 0.37);

		vec3 col3 = mix(sunlit_gold_ivory, warm_parchment, smoothstep(0.0, 0.55, chiaroscuro));
		col3 = mix(col3, deep_umber_shade, smoothstep(0.42, 1.0, chiaroscuro));

		// 叠加折纸明暗切面、云斑包浆与粗纤维斜射浮雕
		float mottle = fbm(UV * 5.2 + vec2(3.1, 6.4)) - 0.5;
		col3 += vec3(mottle * 0.085 + h0 * 0.065 + bump * 0.135 - facet_shade);

		// 纸张边缘茶褐陈化晕染（Edge AO & Foxing Patina），让纸面绝不发白发平
		float edge_dist = clamp(-sdf3 * 12.0, 0.0, 1.0);
		float edge_patina = 1.0 - smoothstep(0.0, 0.85, edge_dist);
		col3 = mix(col3, col3 * vec3(0.76, 0.68, 0.56), edge_patina * 0.55);

		// 左侧古籍线装深压槽与朱砂丝线装订结
		float crease_x = (UV.x - 0.118) / 0.020;
		float crease = exp(-crease_x * crease_x * 2.2);
		float crease_slope = -2.0 * crease_x * crease;
		col3 *= 1.0 - crease * 0.22 + crease_slope * 0.11;

		for (int k = 0; k < 3; k++) {
			float ky = 0.23 + float(k) * 0.27;
			vec2 kp = UV - vec2(0.098, ky);
			float hole = 1.0 - smoothstep(0.005, 0.010, length(kp - vec2(0.018, 0.0)));
			float cord = (1.0 - smoothstep(0.0025, 0.006, abs(kp.y))) * step(-0.025, kp.x) * step(kp.x, 0.019);
			float cord_sh = (1.0 - smoothstep(0.003, 0.008, abs(kp.y - 0.005))) * step(-0.025, kp.x) * step(kp.x, 0.019);
			col3 *= 1.0 - hole * 0.65 - cord_sh * 0.35;
			col3 = mix(col3, vec3(0.68, 0.20, 0.13), cord * 0.92);
		}

		// 右下卷角高光脊与背阴暗部
		float curl_ridge = sin(clamp(c3_curl * 3.14159, 0.0, 3.14159));
		col3 += vec3(0.14, 0.11, 0.06) * curl_ridge * 0.85;
		col3 *= 1.0 - pow(c3_curl, 1.4) * 0.28;

		// 顶层剪纸向阳切边厚白金芯与背阴深褐切口
		float rim3 = clamp(m3 - m3_bev, 0.0, 1.0);
		float shade_rim3 = clamp(m3_bev - m3, 0.0, 1.0);
		col3 = mix(col3, vec3(1.0, 0.96, 0.84), rim3 * 0.92);
		col3 = mix(col3, vec3(0.32, 0.21, 0.12), shade_rim3 * 0.62);

		col = mix(col, col3, m3);
		alpha = max(alpha, m3);
	}

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), clamp(alpha, 0.0, 1.0));
}
