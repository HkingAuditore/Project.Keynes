shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// ════════════════════════════════════════════════════════════════════════
// military_battle_ring.gdshader — 交战进度环（z=9）
//
// MilitaryBattleLayer 为每个交战段在中点（跨格边的中点）放一个 quad，
// 顶点属性契约：
//   UV       = -1..1 的符号空间（quad 局部）
//   COLOR.r  = 攻方进度 0..1（0.5 = 势均力敌）
//   COLOR.g  = 会战脉冲年龄 0..1（0 = 刚触发，1 = 已消失）
//   COLOR.b  = per-battle 种子
//
// 画法：
//   - 双色圆环：攻方色从顶部顺时针量弧，守方色补足剩余
//   - 环内两把交叉铅笔短剑（会战语感），会战时环外一圈冲击波
//   - 纸圆片底，压在任何地形上都读得出来
//   - 全部形状用 fwidth 反走样；缩小时环退为双色实心点（aggregate_mode）
// ════════════════════════════════════════════════════════════════════════

uniform float battle_radius = 26.0;     // 世界半径（CPU 按 zoom 夹住）
uniform float ring_width_ratio : hint_range(0.05, 0.6) = 0.24;
uniform vec4 attacker_color : source_color = vec4(0.80, 0.24, 0.16, 1.0);
uniform vec4 defender_color : source_color = vec4(0.22, 0.40, 0.72, 1.0);
uniform vec4 paper_color : source_color = vec4(0.975, 0.955, 0.905, 1.0);
uniform vec4 pencil_color : source_color = vec4(0.18, 0.15, 0.11, 1.0);
uniform float wrap_period_x = 0.0;
uniform float wall_seconds = 0.0;
uniform bool reduced_motion = false;
uniform float layer_alpha : hint_range(0.0, 1.0) = 1.0;
uniform bool aggregate_mode = false;    // 缩太小：只画实心进度点
uniform bool fog_enabled = false;
uniform sampler2D battle_decal : filter_linear, repeat_disable;
uniform float battle_decal_strength : hint_range(0.0, 1.0) = 0.38;

varying vec2 v_local;
varying vec2 v_world;
varying vec4 v_style;

#include "res://shaders/include/military_paper_common.gdshaderinc"

void vertex() {
	v_local = VERTEX / max(battle_radius, 0.001);
	v_world = MODEL_MATRIX[3].xy;
	v_style = COLOR;
}

void fragment() {
	float aa = max(max(fwidth(v_local.x), fwidth(v_local.y)), 0.0006);
	vec2 p = v_local;
	float r = length(p);
	float ang = atan(p.x, p.y);                       // 顶部为 0，顺时针为正
	float t = fract(ang / 6.2831853 + 1.0);           // 0..1 顺时针
	float progress = clamp(v_style.r, 0.0, 1.0);
	float seed = v_style.b;
	float pulse = clamp(v_style.g, 0.0, 1.0);

	float blotch = pk_paper_blotch(v_world, aa);
	float disc = 1.0 - smoothstep(0.96 - aa, 0.96 + aa, r + blotch * 0.06);
	float ring_inner = 0.96 * (1.0 - ring_width_ratio);
	float ring_band = smoothstep(ring_inner - aa, ring_inner + aa, r)
		* (1.0 - smoothstep(0.96 - aa, 0.96 + aa, r));

	// 双色弧：分界在 t = progress，边界一像素内软化。
	float at_attacker = step(t, progress);
	float dist_to_edge = min(abs(t - progress), 1.0 - abs(t - progress));
	float edge_mix = 1.0 - smoothstep(0.0, aa * 2.2, dist_to_edge);
	vec3 arc = mix(defender_color.rgb, attacker_color.rgb, at_attacker);
	arc = mix(arc, mix(attacker_color.rgb, defender_color.rgb, 0.5), edge_mix * 0.5);

	vec3 paper = paper_color.rgb * (0.96 + blotch * 0.12);
	vec3 col = paper;
	if (!aggregate_mode) {
		vec2 decal_uv = vec2(0.5) + p * 0.42;
		vec4 decal = texture(battle_decal, decal_uv);
		float decal_mask = decal.a * battle_decal_strength;
		col = mix(col, decal.rgb, decal_mask);
	}
	float ring_ink = max(1.0 - smoothstep(aa, aa * 2.2, abs(r - ring_inner)),
		1.0 - smoothstep(aa, aa * 2.2, abs(r - 0.96)));
	col = mix(col, pencil_color.rgb * 0.85, ring_ink * 0.42 * (1.0 - edge_mix));
	col = mix(col, arc, ring_band * 0.95);

	// 每 25% 一道铅笔刻痕。
	float tick_phase = fract(t * 4.0);
	float tick = (1.0 - smoothstep(0.0, aa * 6.0, min(tick_phase, 1.0 - tick_phase))) * ring_band;
	col = mix(col, pencil_color.rgb, tick * 0.5);

	// 环内交叉短剑，按 LOD 淡出。
	float sword_fade = 1.0 - smoothstep(0.06, 0.22, aa);
	vec2 sp = p * 2.0;
	vec2 rp = vec2(sp.x * 0.7071 + sp.y * 0.7071, -sp.x * 0.7071 + sp.y * 0.7071);
	float blade_a = (1.0 - smoothstep(0.05, 0.09, abs(sp.x))) * step(abs(sp.y), 0.80);
	float blade_b = (1.0 - smoothstep(0.05, 0.09, abs(rp.x))) * step(abs(rp.y), 0.80);
	float cross_a = (1.0 - smoothstep(0.04, 0.08, abs(abs(sp.y) - 0.58))) * step(abs(sp.x), 0.20);
	float cross_b = (1.0 - smoothstep(0.04, 0.08, abs(abs(rp.y) - 0.58))) * step(abs(rp.x), 0.20);
	float swords = clamp(max(max(blade_a, blade_b), max(cross_a, cross_b) * 0.9), 0.0, 1.0)
		* sword_fade;
	col = mix(col, pencil_color.rgb, swords * 0.60);

	// 会战脉冲：环外冲击波 + 整环短暂提亮。
	float wave = 0.0;
	if (pulse < 1.0) {
		float wave_r = 1.0 + pulse * 0.85;
		wave = (1.0 - smoothstep(0.0, 0.09, abs(r - wave_r))) * (1.0 - pulse);
	}
	float flash = (1.0 - pulse) * pulse * 0.5;
	col = mix(col, vec3(1.0, 0.90, 0.66), clamp(wave * 0.6 + flash, 0.0, 1.0));
	float shake = reduced_motion ? 0.0 : sin(wall_seconds * 24.0 + seed * 20.0) * 0.02 * (1.0 - pulse);
	col *= 1.0 + shake;

	if (aggregate_mode) {
		// 缩到 0.35 以下：只留一个双色实心点，读攻守比例即可。
		float dot_r = 0.62;
		float m = 1.0 - smoothstep(dot_r - aa, dot_r + aa, r);
		col = mix(defender_color.rgb, attacker_color.rgb, step(t, progress));
		COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), m * 0.92 * layer_alpha);
	} else {
		float alpha = clamp(disc * 0.95 + wave * 0.5, 0.0, 1.0) * layer_alpha;
		COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), alpha);
	}
}
