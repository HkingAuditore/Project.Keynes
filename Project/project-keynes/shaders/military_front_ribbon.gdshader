shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// ════════════════════════════════════════════════════════════════════════
// military_front_ribbon.gdshader — 战线（z=8）
//
// 几何来自增量战线（设计稿 §21.5）：MilitaryFrontLayer 为每个接触边
// (cell, dir) 生成一条跨边的 ribbon。顶点属性契约（世界单位）：
//   UV.x  = 沿边距起点的世界距离
//   UV.y  = 距中心线的垂距（正负对称，>0 向外）
//   COLOR = 整条边的进度色（r=进度 0..1），a = per-edge 种子
// 因此同一条边沿方向颜色一致，进度变化只重建该边附近的 mesh。
//
// 「手绘锯齿」表达：
//   - 中心线按沿边距离叠三角波 + 低频漂移，像铅笔来回描了两遍
//   - 线宽沿边起伏并在两端收尖，不是等宽矢量线
//   - 高频锯齿按屏幕足迹淡出，缩小时收敛成柔和分界；不出现摩尔纹
//   - 两侧地面被战火烤成暖色（burn），战线上读到「这里正在被争夺」
// ════════════════════════════════════════════════════════════════════════

uniform float front_world_width = 4.2;
uniform float wrap_period_x = 0.0;
uniform float wall_seconds = 0.0;
uniform bool reduced_motion = false;
uniform float layer_alpha : hint_range(0.0, 1.0) = 1.0;
uniform vec4 hold_color : source_color = vec4(0.20, 0.44, 0.74, 1.0);   // 守方稳
uniform vec4 push_color : source_color = vec4(0.86, 0.25, 0.15, 1.0);   // 攻方稳
uniform vec4 neutral_color : source_color = vec4(0.58, 0.38, 0.22, 1.0);
uniform vec4 pencil_color : source_color = vec4(0.15, 0.12, 0.09, 1.0);
uniform float zigzag_amplitude = 0.42;   // 占线宽比例
uniform float zigzag_frequency = 9.0;    // 每世界单位的三角波数
uniform float bead_speed = 0.55;

varying vec2 v_data;      // x = 沿边世界距离, y = 垂距
varying vec4 v_color;     // rgb = 进度色, a = seed

#include "res://shaders/include/military_paper_common.gdshaderinc"

void vertex() {
	v_data = UV;
	v_color = COLOR;
}

void fragment() {
	float seed = v_color.a;
	float w = max(front_world_width, 0.001);
	float d = v_data.y;
	float aa = max(fwidth(d), 0.0002);
	float lod = fwidth(v_data.x) * 2.0 + aa * 0.5;

	// 手绘锯齿：三角波 + 低频漂移，高频按足迹淡出。
	float jag_fade = 1.0 - smoothstep(0.15, 0.45, lod);
	float tri = abs(fract(v_data.x * zigzag_frequency / 3.14159 + seed) - 0.5) * 2.0;
	float jag = (tri - 0.5) * zigzag_amplitude * w * jag_fade;
	float drift = (pk_fbm(vec2(v_data.x * 1.7 + seed * 13.0, seed * 7.0), lod) - 0.5) * w * 0.30;
	float dn = d - jag - drift;

	// 线宽：三角波驱动的起伏（不是等宽矢量线），两端由 CPU 收尖。
	float half_w = w * (0.42 + 0.30 * (0.5 + 0.5 * sin(v_data.x * 0.9 + seed * 6.0)));

	float body = smoothstep(half_w + aa, half_w - aa, abs(dn));
	float ink_edge = (1.0 - smoothstep(aa * 0.8, aa * 1.8,
		abs(abs(dn) - half_w * 0.88))) * 0.60;
	// 纸边高光：中心线一道浅色，模拟纸被撕开后露出的白纤维。
	float fiber = (1.0 - smoothstep(aa, aa * 2.2, abs(dn) - aa * 0.6)) * 0.35;

	vec3 col = v_color.rgb;
	col = mix(col, pencil_color.rgb, ink_edge);
	col = mix(col, vec3(1.0, 0.95, 0.82), fiber * 0.45);

	// 进度流动珠：沿线方向移动的亮点，直观读出推进方向。
	float flow = reduced_motion ? 0.5 : fract(v_data.x * 0.16 - wall_seconds * bead_speed + seed);
	float bead = smoothstep(0.88, 1.0, flow)
		* (1.0 - smoothstep(0.0, half_w, abs(dn)));
	col = mix(col, vec3(1.0, 0.93, 0.72), bead * 0.38);

	// 战火烤黄：中心线 2 倍宽内的地面轻微暖化。
	float burn = (1.0 - smoothstep(w * 0.4, w * 1.9, abs(dn))) * 0.20;
	col = mix(col, push_color.rgb, burn * 0.6);

	float alpha = clamp(body * 0.94 + ink_edge * 0.45 + burn * 0.32 + fiber * 0.2,
		0.0, 1.0) * layer_alpha;
	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), alpha);
}
