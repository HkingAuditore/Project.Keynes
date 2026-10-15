shader_type canvas_item;
render_mode unshaded;

// 主界面双层立体剪纸折幅书签按钮着色器 (Sculpted Two-Layer Papercut Ribbon & Wax Medallion)
// 彻底消除平涂白条与死板分割线：
// 1. 双层错位剪纸叠片（底层深赭/暗金衬纸带燕尾斜角，顶层暖琥珀桑皮纸带大幅度手工撕边）
// 2. 左侧立体剪纸火漆圆章（带独立层间落影、描金内环与凹凸火漆光泽，取代生硬竖线方块）
// 3. 强烈的纸面斜射受光渐变、对角折纸切面与粗纤维凹凸浮雕感
// 4. 真实投射在底页上的多层暖黑阴影，悬停时纸条抬升、火漆鎏金增亮

uniform sampler2D paper_grain_tex : filter_linear, repeat_enable;
uniform vec2 button_size = vec2(280.0, 56.0);
uniform float seed_offset = 0.0;
uniform float is_primary : hint_range(0.0, 1.0) = 0.0;
uniform float hover_amount : hint_range(0.0, 1.0) = 0.0;
uniform float press_amount : hint_range(0.0, 1.0) = 0.0;

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
	for (int i = 0; i < 3; i++) {
		v += a * value_noise(p);
		p = rot * p * 2.03;
		a *= 0.5;
	}
	return v;
}

// 计算具有明显手工撕边起伏、右侧燕尾/斜切折角的剪纸条 SDF
float ribbon_sdf(vec2 uv, vec2 center, vec2 half_ext, float tilt, float seed) {
	vec2 p = uv - center;
	p.y += p.x * tilt;
	vec2 d = abs(p) - half_ext;

	// 显著的上下手工剪纸起伏（4~7px 级别，绝非直线！）
	float wave_y = (fbm(vec2(p.x * 5.2 + seed * 3.7, seed * 1.9)) - 0.5) * 0.095;
	float tear_y = (value_noise(vec2(p.x * 24.0 - seed * 7.1, p.y * 6.0)) - 0.5) * 0.038;
	float tear_x = (value_noise(vec2(p.y * 14.0 + seed * 5.3, p.x * 4.0)) - 0.5) * 0.018;

	d.x += tear_x;
	d.y += wave_y + tear_y;

	float box_d = length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);

	// 右侧手工斜切/燕尾切口
	vec2 ur = p - vec2(half_ext.x - 0.055, -half_ext.y + 0.22);
	float clip_ur = ur.x * 0.78 - ur.y * 0.26;
	box_d = max(box_d, clip_ur);

	vec2 lr = p - vec2(half_ext.x - 0.032, half_ext.y - 0.20);
	float clip_lr = lr.x * 0.72 + lr.y * 0.22;
	box_d = max(box_d, clip_lr);

	return box_d;
}

float paper_bump(vec2 px, float seed) {
	vec2 uv_g = fract(px / 150.0 + vec2(seed * 0.19, seed * 0.37));
	float g = texture(paper_grain_tex, uv_g).r - 0.5;
	float m = fbm(px * 0.025 + vec2(seed * 3.0, 1.0)) - 0.5;
	return g * 0.65 + m * 0.55;
}

void fragment() {
	vec2 px = UV * button_size;
	vec2 px_step = 1.0 / max(button_size, vec2(1.0));
	float aa = 1.5 / max(button_size.y, 1.0);

	float lift = hover_amount * (1.0 - press_amount * 0.85);
	vec2 lift_ofs = vec2(-0.006, -0.028) * lift + vec2(0.004, 0.020) * press_amount;

	// 1. 底层错位衬纸条 (Under-Ribbon：深赭石/暗红卡纸，向右下微倾露出叠边)
	vec2 c_sub = vec2(0.496, 0.495) + lift_ofs * 0.5;
	vec2 ext_sub = vec2(0.462, 0.355);
	float sdf_sub = ribbon_sdf(UV, c_sub, ext_sub, -0.022, seed_offset + 4.2);
	float m_sub = 1.0 - smoothstep(-aa, aa, sdf_sub);
	float m_sub_bev = 1.0 - smoothstep(-aa, aa, ribbon_sdf(UV + vec2(-1.8, -1.8) * px_step, c_sub, ext_sub, -0.022, seed_offset + 4.2));

	// 2. 顶层主剪纸书签条 (Top Ribbon)
	vec2 c_top = vec2(0.486, 0.455) + lift_ofs;
	vec2 ext_top = vec2(0.460, 0.365);
	float sdf_top = ribbon_sdf(UV, c_top, ext_top, 0.012, seed_offset);
	float m_top = 1.0 - smoothstep(-aa, aa, sdf_top);
	float m_top_bev = 1.0 - smoothstep(-aa, aa, ribbon_sdf(UV + vec2(-2.0, -2.0) * px_step, c_top, ext_top, 0.012, seed_offset));

	// 3. 投射在扉页上的深邃暖褐落影（并非生硬黑边，而是双层柔和纸影）
	vec2 sh_ofs1 = vec2(0.012, 0.068) * (1.0 + lift * 0.55 - press_amount * 0.5);
	vec2 sh_ofs2 = vec2(0.024, 0.135) * (1.0 + lift * 0.70 - press_amount * 0.6);
	float sh1 = 1.0 - smoothstep(-aa * 2.5, aa * 2.5, ribbon_sdf(UV - sh_ofs1, c_sub, ext_sub, -0.022, seed_offset + 4.2));
	float sh2 = 1.0 - smoothstep(-aa * 5.0, aa * 5.0, ribbon_sdf(UV - sh_ofs2, c_top, ext_top, 0.012, seed_offset));
	float union_paper = max(m_sub, m_top);
	float page_shadow = (sh1 * 0.58 + sh2 * 0.42) * (1.0 - union_paper);

	vec3 col = vec3(0.18, 0.10, 0.05);
	float alpha = page_shadow * (0.54 + lift * 0.16);

	// 纸张凹凸微法线光照
	float h0 = paper_bump(px, seed_offset);
	float hx = paper_bump(px + vec2(1.8, 0.0), seed_offset);
	float hy = paper_bump(px + vec2(0.0, 1.8), seed_offset);
	float bump = (h0 - hx) * 0.85 + (h0 - hy) * 0.75;

	// 渲染底层衬纸条（主按钮为暗红描金衬底，次按钮为古铜赭石衬底）
	if (m_sub > 0.001) {
		vec3 sub_base = mix(vec3(0.55, 0.39, 0.24), vec3(0.56, 0.18, 0.12), is_primary * 0.75);
		sub_base += vec3(h0 * 0.05 + bump * 0.08);
		float rim_sub = clamp(m_sub - m_sub_bev, 0.0, 1.0);
		sub_base = mix(sub_base, vec3(0.92, 0.76, 0.46), rim_sub * 0.75);
		col = mix(col, sub_base, m_sub);
		alpha = max(alpha, m_sub);
	}

	// 顶层主纸条在底层衬纸上的接触阴影
	float top_on_sub_sh = (1.0 - smoothstep(-aa * 2.0, aa * 2.0, sdf_top - 0.025)) * (1.0 - m_top);
	col *= 1.0 - top_on_sub_sh * 0.52 * m_sub;

	// 渲染顶层主剪纸条
	if (m_top > 0.001) {
		// 显著的左上暖阳受光至右下琥珀暗部过渡 + 折纸对角切面
		float light_grad = clamp((UV.x - 0.12) * 0.62 + (UV.y - 0.18) * 0.48, 0.0, 1.0);
		float fold_crease = tanh((UV.x * 1.4 - UV.y * 0.45 - 0.58) * 8.0) * 0.045;

		vec3 lit_tone = mix(vec3(0.95, 0.87, 0.70), vec3(0.99, 0.93, 0.79), max(is_primary * 0.5, lift * 0.8));
		vec3 shd_tone = mix(vec3(0.75, 0.63, 0.45), vec3(0.84, 0.72, 0.53), lift * 0.7);
		vec3 slip_col = mix(lit_tone, shd_tone, light_grad) + vec3(h0 * 0.07 + bump * 0.14 - fold_crease);

		// 四周剪纸切口陈化茶色包浆（避免死白，强化手工古纸立体感）
		float edge_in = clamp(-sdf_top * 9.0, 0.0, 1.0);
		slip_col = mix(slip_col * vec3(0.78, 0.67, 0.52), slip_col, smoothstep(0.0, 0.85, edge_in));

		// 左侧立体手工剪纸火漆印章圆牌（像素级锚定 x=27px，与图标中心严丝合缝）
		vec2 seal_center_px = vec2(27.0, (c_top.y) * button_size.y);
		vec2 seal_c = (seal_center_px - px) / max(button_size.y, 1.0);
		float seal_r = length(seal_c);
		float seal_ang = atan(seal_c.y, seal_c.x);
		float seal_wobble = (value_noise(vec2(seal_ang * 3.5 + seed_offset, seed_offset * 2.0)) - 0.5) * 0.032
			+ cos(seal_ang * 8.0) * 0.012;
		float seal_rad = mix(0.285, 0.315, is_primary) + seal_wobble;

		float seal_mask = 1.0 - smoothstep(seal_rad - 0.02, seal_rad + 0.02, seal_r);
		vec2 seal_sh_c = (seal_center_px + vec2(2.0, 2.8) - px) / max(button_size.y, 1.0);
		float seal_sh = (1.0 - smoothstep(seal_rad - 0.01, seal_rad + 0.04, length(seal_sh_c))) * (1.0 - seal_mask);

		// 火漆章投射在纸条上的立体接触阴影
		slip_col *= 1.0 - seal_sh * 0.45;

		if (seal_mask > 0.001) {
			float seal_light = clamp((seal_c.x + seal_c.y) * 1.8, -1.0, 1.0);
			vec3 wax_bright = mix(vec3(0.68, 0.21, 0.14), vec3(0.78, 0.25, 0.16), lift);
			vec3 wax_dark = vec3(0.36, 0.09, 0.06);
			vec3 wax_col = mix(wax_dark, wax_bright, seal_light * 0.5 + 0.5) + vec3(bump * 0.10);

			// 火漆内圈凹陷压印环与描金凸起环
			float inner_ring = 1.0 - smoothstep(0.012, 0.028, abs(seal_r - seal_rad * 0.72));
			float rim_wax = smoothstep(seal_rad * 0.82, seal_rad, seal_r) * clamp(seal_light, 0.0, 1.0);
			wax_col = mix(wax_col, vec3(0.95, 0.80, 0.46), inner_ring * (0.65 + is_primary * 0.25));
			wax_col += vec3(0.25, 0.18, 0.08) * rim_wax;
			slip_col = mix(slip_col, wax_col, seal_mask);
		}

		// 主按钮右侧暖金压印装饰细线
		if (is_primary > 0.5) {
			float gold_rule = (1.0 - smoothstep(0.0, px_step.y * 1.5, abs(abs(UV.y - c_top.y) - (ext_top.y - 0.09))))
				* step(0.19, UV.x) * step(UV.x, 0.90);
			slip_col = mix(slip_col, vec3(0.78, 0.56, 0.24), gold_rule * 0.48);
		}

		// 向阳侧立体切边白金纸芯高光与背阴侧厚纸暗边
		float sun_rim = clamp(m_top - m_top_bev, 0.0, 1.0);
		float shade_rim = clamp(m_top_bev - m_top, 0.0, 1.0);
		slip_col = mix(slip_col, vec3(1.0, 0.96, 0.84), sun_rim * 0.92);
		slip_col = mix(slip_col, vec3(0.28, 0.18, 0.10), shade_rim * 0.60);

		if (press_amount > 0.01) {
			slip_col *= 1.0 - press_amount * 0.08;
		}

		col = mix(col, slip_col, m_top);
		alpha = max(alpha, m_top);
	}

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), clamp(alpha, 0.0, 1.0));
}
