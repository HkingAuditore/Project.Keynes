shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// ════════════════════════════════════════════════════════════════════════
// country_border.gdshader — 国界线
//
// 走几何 ribbon 而不是对 map_index_atlas 做屏幕空间 edge detect：atlas 的
// cell index 是无 Dither 的权威硬主格，逐像素
// 反查在 hex 边界会抖 ±1 texel，画出来的线是碎的。
//
// CountryBorderLayer 为每个"归属与邻格不同"的 hex 边生成一条**朝本格内侧**
// 的 ribbon。两个相邻国家各出一条，于是真正的国界线上自然形成
// 「深色分隔线 + 两侧国色带」的 EU4 观感；国家 vs 无主地只出一条。
//
// 顶点属性约定（**世界单位**，不是 0..1）：
//   UV.x    = 沿边距起点角的距离
//   UV.y    = 距国界线的垂距；外侧为负（抗锯齿余量），内侧为正
//   COLOR.rgb = 国色
//   COLOR.a   = per-edge seed（噪声去规则化用，不是透明度）
//
// 用世界单位而非归一化参数：两者都是位置的线性函数，在内缩梯形拆成的两个三角形
// 里插值都精确；归一化后的 UV.x 在梯形里会沿对角线出现折痕。
//
// ribbon 按 ribbon_world_width 烘死；实际线宽由 border_world_width uniform
// 在 shader 内裁出，因此相机缩放只推 uniform，不重建 mesh。
//
// 断面结构（从国界线往本格内侧）：
//   [深色外套 casing] [国色带] [向内柔化收尾]
// 相邻两国各画一条，于是共享边上是「色A | 双份深色 | 色B」——深色外套是这条线
// 能压住任何地形底色的原因，没有它金色线落在黄绿色地表上就糊了。
// ════════════════════════════════════════════════════════════════════════

// mesh 烘焙时 ribbon 的内侧世界宽度（GDScript 与之保持一致）。
uniform float ribbon_world_width = 13.6;
// 当前期望的世界线宽，由 GDScript 每帧按 zoom 推送。
uniform float border_world_width = 3.6;
// 深色外套在总线宽里的占比（靠国界线一侧）。
uniform float outline_ratio : hint_range(0.0, 0.9) = 0.24;
uniform vec4 outline_color : source_color = vec4(0.075, 0.052, 0.029, 1.0);
uniform sampler2D frontier_grain : repeat_enable, filter_linear_mipmap;
uniform vec2 frontier_pulse_center = vec2(-100000.0);
uniform float frontier_pulse_age = 2.0;
uniform float frontier_pulse_radius = 44.0;
uniform float frontier_wrap_period = 0.0;
uniform float overall_alpha : hint_range(0.0, 1.0) = 1.0;
// 国色带向内侧渐隐的残留强度（1 = 不渐隐）。
uniform float inner_fade : hint_range(0.0, 1.0) = 0.0;
// 国色带亮度增益：让色带在深色外套旁边跳出来。
uniform float band_gain : hint_range(0.5, 2.0) = 1.12;
// 边界沿线的噪声起伏幅度（占线宽的比例），避免国界看起来像机械折线。
uniform float noise_amount : hint_range(0.0, 0.6) = 0.10;
// 噪声沿边的空间频率（每世界单位）。
uniform float noise_scale : hint_range(0.005, 0.5) = 0.055;

varying vec2 v_data;
varying vec4 v_color;
varying vec2 v_world;

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

void vertex() {
	v_data = UV;
	v_color = COLOR;
	v_world = VERTEX;
}

void fragment() {
	float seed = v_color.a;
	float w = max(border_world_width, 0.001);
	// 距国界线的世界垂距。负值 = 国界线外侧的抗锯齿余量。
	float d = v_data.y;

	// 沿边低频起伏：输入是**边局部**的世界距离，因此圆柱地图 -period/0/+period
	// 三份副本拿到同一个值，接缝处不会错位。
	float wobble = 0.0;
#ifndef PK_QUALITY_LOW
	if (noise_amount > 0.001) {
		float n = value_noise(vec2(v_data.x * noise_scale + seed * 91.0, seed * 37.0));
		wobble = (n - 0.5) * 2.0 * noise_amount * w;
	}
#endif
	float dn = d + wobble;

	// 屏幕空间抗锯齿宽度（世界单位）。ribbon 是世界几何，缩放时 fwidth 自动跟随。
	float aa = max(fwidth(d), 0.0001);
	float casing_w = w * clamp(outline_ratio, 0.02, 0.9);

	// 外缘与内缘都做抗锯齿：外缘靠 mesh 的 bleed 余量，内缘靠线宽裁切。
	float outer = smoothstep(-aa, aa, dn);
	float inner = 1.0 - smoothstep(w - aa, w + aa, dn);
	float inside = outer * inner;
	float is_casing = 1.0 - smoothstep(casing_w - aa, casing_w + aa, dn);

	// Material extends inland as a dry pigment wash; the true boundary stays
	// a precise ink seam. Texture coordinates are edge local, so wrapped copies
	// use identical grain and do not shimmer when the camera crosses the seam.
	float grain = 0.5;
#ifndef PK_QUALITY_LOW
	grain = texture(frontier_grain, vec2(v_data.x * 0.045 + seed * 13.0,
		v_data.y * 0.11 + seed * 7.0)).r;
#endif
	float profile = clamp((dn - casing_w) / max(w - casing_w, 0.0001), 0.0, 1.0);
	float ridge = exp(-pow((profile - 0.26) * 7.0, 2.0));
	float bevel = 0.72 + ridge * 0.42 + (grain - 0.5) * 0.45;
	vec3 pigment = v_color.rgb * band_gain * bevel;
	vec3 col = mix(pigment, outline_color.rgb, is_casing);
	// A fine warm crest and a darker inner groove make this read as an atlas
	// inlay instead of an unlit geometric stroke, on both snow and green terrain.
	col = mix(col, mix(v_color.rgb, vec3(1.0, 0.94, 0.76), 0.48), ridge * (1.0 - is_casing) * 0.5);
	float band = mix(1.0, inner_fade, smoothstep(0.65, 1.0, profile));
	float alpha = inside * mix(band, outline_color.a, is_casing);
	float wash_width = min(ribbon_world_width * 0.94, w * 3.2);
	float wash_distance = dn + (grain - 0.5) * w * 1.4;
	float wash = outer * (1.0 - smoothstep(w * 0.6, wash_width, wash_distance));
	float wash_alpha = wash * (0.09 + grain * 0.16);
	float material_mix = alpha / max(alpha + wash_alpha * (1.0 - alpha), 0.001);
	col = mix(v_color.rgb * (0.65 + grain * 0.3), col, material_mix);
	alpha = alpha + wash_alpha * (1.0 - alpha);
	// Sparse cartographer's inner hatching, worn into the pigment rather than
	// a second luminous outline. Derivatives keep it quiet at distant zoom.
	float detail_lod = 1.0 - smoothstep(w * 0.20, w * 0.45, aa);
	float hatch = 1.0 - smoothstep(w * 0.09, w * 0.09 + aa, abs(dn - w * 1.9));
	float dash = smoothstep(0.35, 0.65, sin(v_data.x / w * 1.8 + seed * 6.0));
	float hatch_alpha = hatch * dash * detail_lod * 0.34 * (0.6 + grain * 0.4);
	col = mix(col, v_color.rgb * 0.70, hatch_alpha / max(alpha + hatch_alpha, 0.001));
	alpha = max(alpha, hatch_alpha);

	// One short, local frontier catch-light after an authoritative landing.
	vec2 delta = v_world - frontier_pulse_center;
	if (frontier_wrap_period > 0.001) {
		delta.x = mod(delta.x + frontier_wrap_period * 0.5, frontier_wrap_period) - frontier_wrap_period * 0.5;
	}
	float pulse_time = clamp(frontier_pulse_age / 1.8, 0.0, 1.0);
	float local_mask = 1.0 - smoothstep(frontier_pulse_radius * 0.3, frontier_pulse_radius, length(delta));
	float catchlight = sin(pulse_time * 3.14159265) * local_mask;
	col = mix(col, vec3(1.0, 0.91, 0.60), catchlight * 0.72);
	alpha *= overall_alpha;

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), clamp(alpha, 0.0, 1.0));
}
