shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// ════════════════════════════════════════════════════════════════════════
// military_convoy.gdshader — 军需车队（z=9）
//
// 复用 TradeActivityLayer 的做法：一个 MultiMesh，每辆车一条实例，
// 位置由 CPU 按「当日走过的车队」写进实例矩阵，路径与进度写在实例自定义
// 数据里；本地推进（轮子/扬尘）由 wall_seconds 推进，不做每帧 CPU 动画。
//
//   INSTANCE_CUSTOM = (country slot, risk_q16/65535, kind, seed)
//   quad 局部坐标 = -1..1 符号空间
//
// 画法：一辆盖着帆布的马车（俯视），帆布线用铅笔横纹；被截风险越高，
// 车顶的路线色越偏橙红，并在车后拉出一道扬尘。缩小时收敛成一个小四方形
// （aggregate 由足迹 LOD 自动决定，不需要额外 uniform）。
// ════════════════════════════════════════════════════════════════════════

uniform float vehicle_world_size = 15.0;
uniform float wrap_period_x = 0.0;
uniform float wall_seconds = 0.0;
uniform bool reduced_motion = false;
uniform float layer_alpha : hint_range(0.0, 1.0) = 1.0;
uniform vec4 canvas_color : source_color = vec4(0.93, 0.90, 0.82, 1.0);
uniform vec4 wood_color : source_color = vec4(0.44, 0.31, 0.19, 1.0);
uniform vec4 pencil_color : source_color = vec4(0.16, 0.13, 0.10, 1.0);
uniform vec4 supply_color : source_color = vec4(0.42, 0.55, 0.28, 1.0);
uniform vec4 risk_color : source_color = vec4(0.82, 0.30, 0.14, 1.0);
uniform float travel_speed = 0.9;

varying flat vec4 v_style;
varying vec2 v_local;

#include "res://shaders/include/military_paper_common.gdshaderinc"

float sd_round_box(vec2 p, vec2 h, float r) {
	vec2 q = abs(p) - h + r;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void vertex() {
	v_style = INSTANCE_CUSTOM;
	v_local = VERTEX / max(vehicle_world_size * 0.5, 0.001);
}

void fragment() {
	float aa = max(max(fwidth(v_local.x), fwidth(v_local.y)), 0.0008);
	float lod = 1.0 - smoothstep(0.05, 0.18, aa);
	vec2 p = v_local;

	float risk = clamp(v_style.y, 0.0, 1.0);
	vec3 route = mix(supply_color.rgb, risk_color.rgb, risk);

	// 车身：横向短圆角矩形（行驶方向为 +x，与路径纹理约定一致）。
	float body = sd_round_box(p, vec2(0.82, 0.46), 0.18);
	float body_alpha = 1.0 - smoothstep(-aa, aa, body);
	// 帆布篷：车身中段两条圆弧。
	float cover = 1.0 - smoothstep(-aa, aa,
		abs(length(vec2((p.x + 0.06) * 0.9, p.y * 1.6)) - 0.72) - 0.06);
	cover *= step(abs(p.y), 0.48) * step(abs(p.x + 0.06), 0.62);
	// 车轮：两个深色小圆（俯视只露一点）。
	float wheel = max(1.0 - smoothstep(0.10 - aa, 0.10 + aa, length(p - vec2(-0.22, 0.44))),
		1.0 - smoothstep(0.10 - aa, 0.10 + aa, length(p - vec2(-0.22, -0.44))));

	vec3 col = mix(canvas_color.rgb, route, 0.22);
	col = mix(col, wood_color.rgb, cover * 0.55);
	// 帆布横纹：铅笔线，按足迹淡出。
	float rib_phase = fract((p.x + 1.0) * 7.0 + (reduced_motion ? 0.0 : wall_seconds * 0.0));
	float rib = (1.0 - smoothstep(0.0, 0.16, abs(rib_phase - 0.5))) * cover * lod;
	col = mix(col, pencil_color.rgb, rib * 0.28);
	col = mix(col, pencil_color.rgb * 0.7, wheel * 0.65);
	// 阵营色条：车尾一道细色带（谁的补给）。
	float band = step(0.52, p.x) * step(p.x, 0.62) * step(abs(p.y), 0.42);
	col = mix(col, route, band * 0.7);

	// 铅笔轮廓
	float outline = 1.0 - smoothstep(-aa, aa, abs(body) - 0.05);
	col = mix(col, pencil_color.rgb, outline * 0.75);

	// 扬尘：车后（-x）逐渐淡出的淡黄色拖尾。
	float dust_len = 1.6 + (reduced_motion ? 0.0 : sin(wall_seconds * 3.0 + v_style.w * 7.0) * 0.2);
	float dust = step(p.x, -0.5) * (1.0 - smoothstep(0.0, dust_len, -0.5 - p.x))
		* (1.0 - smoothstep(0.05, 0.55, abs(p.y))) * 0.30 * lod;
	col = mix(col, canvas_color.rgb, dust);

	float alpha = clamp(body_alpha * 0.96 + dust * 0.6, 0.0, 1.0) * layer_alpha;
	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), alpha);
}
