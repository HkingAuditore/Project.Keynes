shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// ════════════════════════════════════════════════════════════════════════
// military_area_dash.gdshader — 军事控制区域虚线（z=6）
//
// 几何与 CountryBorderLayer 完全同构：每个「在区域内 / 不在」的 hex 边由在
// 区域内的一侧生成一条朝内梯形的 ribbon（顶点属性是世界单位，见
// country_border_layer.gd 的注释）。这里只把「实线 + 国色」换成
// 「虚线 + 铅笔 + 纸边」，以便和真正的国界线区分开。
//
//   UV.x = 沿边距起点的世界距离（虚线相位由它驱动，三份 wrap 副本一致）
//   UV.y = 距区域边界的垂距，外侧为负（抗锯齿余量）
//   COLOR.rgb = 区域所属国的国色
//   COLOR.a   = per-edge 种子
//
// 虚线相位可随 wall_seconds 缓慢流动（reduced_motion 时静止），
// 表达「这块区域是部队的任务区，不是领土」。
// ════════════════════════════════════════════════════════════════════════

uniform float ribbon_world_width = 13.6;
uniform float area_world_width = 3.0;
uniform float wrap_period_x = 0.0;
uniform float wall_seconds = 0.0;
uniform bool reduced_motion = false;
uniform float layer_alpha : hint_range(0.0, 1.0) = 1.0;
uniform vec4 pencil_color : source_color = vec4(0.17, 0.14, 0.11, 1.0);
uniform vec4 paper_color : source_color = vec4(0.98, 0.95, 0.88, 1.0);
uniform vec4 select_color : source_color = vec4(0.72, 0.19, 0.13, 1.0);
uniform float dash_length = 7.5;      // 世界单位
uniform float gap_length = 5.0;
uniform float flow_speed = 0.35;
uniform float noise_amount : hint_range(0.0, 0.5) = 0.14;

varying vec2 v_data;
varying vec4 v_color;

#include "res://shaders/include/military_paper_common.gdshaderinc"

void vertex() {
	v_data = UV;
	v_color = COLOR;
}

void fragment() {
	float seed = v_color.a;
	float w = max(area_world_width, 0.001);
	float d = v_data.y;                       // 世界垂距，外侧 < 0
	float aa = max(fwidth(d), 0.0002);

	// 沿边手绘抖动（边局部坐标，wrap 副本一致）。
	float wobble = (pk_value_noise(vec2(v_data.x * 0.22 + seed * 91.0, seed * 37.0)) - 0.5)
		* 2.0 * noise_amount * w;
	float dn = d + wobble;

	// 虚线相位：沿边距离 + 缓慢流动。
	float flow = reduced_motion ? 0.0 : wall_seconds * flow_speed;
	float period = max(dash_length + gap_length, 1.0);
	float phase = mod(v_data.x + flow + seed * period, period);
	float dash_aa = max(fwidth(v_data.x), 0.0003);
	float dash = 1.0 - smoothstep(dash_length - dash_aa, dash_length + dash_aa, phase);
	// 缩到虚线周期小于 ~3 像素时退为实线，避免闪烁。
	float dash_lod = 1.0 - smoothstep(2.2, 4.0, period / max(dash_aa, 0.0001));
	dash = mix(1.0, dash, dash_lod);

	float outer = smoothstep(-aa, aa, dn);
	float inner = 1.0 - smoothstep(w - aa, w + aa, dn);
	float line = outer * inner * dash;

	float casing = 1.0 - smoothstep(w * 0.42 - aa, w * 0.42 + aa, dn);
	vec3 ink = mix(v_color.rgb, pencil_color.rgb, 0.55);
	vec3 col = mix(ink, pencil_color.rgb * 0.8, casing * 0.7);
	// 虚线尾部压一层淡纸色，让断口看起来像铅笔没画到底。
	float tip = smoothstep(dash_length - dash_aa * 2.0, dash_length, phase);
	col = mix(col, paper_color.rgb, tip * 0.35 * (1.0 - casing));

	float alpha = line * 0.90 * layer_alpha;
	// 选中区域再加一道朱红内描。
	float select_ring = (1.0 - smoothstep(w * 0.18 - aa, w * 0.18 + aa, dn)) * line;
	col = mix(col, select_color.rgb, select_ring * 0.8);

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), clamp(alpha, 0.0, 1.0));
}
