shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// ════════════════════════════════════════════════════════════════════════
// military_paper_sticker.gdshader — 部队棋子（纸片贴纸）
//
// 一个 MultiMesh 实例 = 一张贴纸。位置/朝向由 CPU 每「换格」写一次
// (from_xy, to_xy, t0_day, t1_day)，本 shader 不用 uniform visual_day 插值
// ——插值在 vertex 里做会让整批 MultiMesh transform 每帧失效重建，代价大于
// 收益；真正的每帧动画只有纸片自身的高光/警示点脉动，靠 wall_seconds 推进。
// 视觉日只用于纸片静止时的轻微「落纸」呼吸。
//
// 片元全部程序化生成：
//   1. 纸底：暖米色 + 低频斑块 + 纤维纹理
//   2. 撕裂白边：贴纸外一圈白纸毛边（毛刺是半径方向的噪声）
//   3. 铅笔轮廓：一遍较硬的铅线 + 一遍淡内描，模拟手绘二次描边
//   4. 阵营色徽：上半部披风式色块 + 45° 斜纹压印
//   5. 兵种剪影：步兵交叉长枪 / 机动马蹄铁 / 炮兵炮管炮架
//   6. 兵力读数：七段式手写数字（>=1000 时显示百位口径）
//   7. 警示点：低补给/缺粮/欠饷/低士气，四色小圆点，按 flags bit 亮
//
// 反走样与 LOD：所有形状用 fwidth 归一化；当屏幕足迹大于阈值时纸纹、毛刺、
// 数字、警示点按足迹淡出，缩到 0.35 以下（聚合模式）只剩色块 + 兵种图标。
// 环绕：CPU 只写最近镜像的世界坐标，噪声种子用 v_world，接缝一致。
// ════════════════════════════════════════════════════════════════════════

// 实际 quad mesh 恒为 1x1，实例 transform 才负责世界尺寸；
// shader 的局部坐标不能按世界尺寸再次归一化。
uniform float visual_day = 0.0;
uniform float wall_seconds = 0.0;
uniform bool reduced_motion = false;
uniform float layer_alpha = 1.0;
// 聚合模式：zoom < 0.35 时隐藏数字与警示点。
uniform bool aggregate_mode = false;
// 选中部队的纸片略大、外圈加一道朱红描边。
uniform float selected_boost = 1.0;

uniform vec4 paper_color : source_color = vec4(0.945, 0.910, 0.835, 1.0);
uniform vec4 paper_shadow : source_color = vec4(0.30, 0.24, 0.17, 1.0);
uniform vec4 ink_color : source_color = vec4(0.19, 0.16, 0.12, 1.0);
uniform vec4 tear_color : source_color = vec4(1.0, 0.988, 0.945, 1.0);
uniform vec4 select_color : source_color = vec4(0.72, 0.19, 0.13, 1.0);
uniform float grain_strength : hint_range(0.0, 1.0) = 0.45;
uniform float outline_strength : hint_range(0.0, 1.0) = 0.85;

varying flat vec4 v_style;   // x=owner slot, y=unit class, z=headcount, w=flags
varying vec2 v_world;
varying vec2 v_local;        // -1..1 quad 空间

float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

float sd_rounded_box(vec2 p, vec2 half_extent, float radius) {
	vec2 q = abs(p) - half_extent + radius;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

// 半径方向的撕纸毛刺。输入是局部坐标，频率固定，接缝三份副本一致。
float tear_offset(vec2 p, float seed) {
	float a = atan(p.y, p.x);
	float n1 = value_noise(vec2(a * 7.0 + seed, seed * 3.1));
	float n2 = value_noise(vec2(a * 23.0 + seed * 1.7, 5.0 + seed));
	return (n1 - 0.5) * 0.075 + (n2 - 0.5) * 0.030;
}

vec3 owner_ink(float slot) {
	float h = fract(slot * 0.61803398875 + 0.137);
	float s = 0.60;
	float v = 0.80;
	float c = v * s;
	float h6 = fract(h) * 6.0;
	float x = c * (1.0 - abs(mod(h6, 2.0) - 1.0));
	vec3 rgb = vec3(c, x, 0.0);
	if (h6 >= 1.0 && h6 < 2.0) { rgb = vec3(x, c, 0.0); }
	else if (h6 >= 2.0 && h6 < 3.0) { rgb = vec3(0.0, c, x); }
	else if (h6 >= 3.0 && h6 < 4.0) { rgb = vec3(0.0, x, c); }
	else if (h6 >= 4.0 && h6 < 5.0) { rgb = vec3(x, 0.0, c); }
	else if (h6 >= 5.0) { rgb = vec3(c, 0.0, x); }
	return rgb + vec3(v - c);
}

// --- 七段数字 -------------------------------------------------------------
const int SEG_ON[10] = int[10](
	0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F);

float seg_digit(vec2 uv, int digit, float aa) {
	// uv within [-0.5,0.5] x [-1,1]
	float w = 0.085;
	float hx = 0.235;
	float hy = 0.44;
	float sa = sd_rounded_box(vec2(uv.x, uv.y + hy), vec2(hx, w), w);
	float sb = sd_rounded_box(vec2(uv.x + 0.25, uv.y + 0.22), vec2(w, 0.26), w);
	float sc = sd_rounded_box(vec2(uv.x + 0.25, uv.y - 0.22), vec2(w, 0.26), w);
	float sm = sd_rounded_box(vec2(uv.x, uv.y), vec2(hx, w), w);
	float se = sd_rounded_box(vec2(uv.x - 0.25, uv.y - 0.22), vec2(w, 0.26), w);
	float sf = sd_rounded_box(vec2(uv.x - 0.25, uv.y + 0.22), vec2(w, 0.26), w);
	float sg = sd_rounded_box(vec2(uv.x, uv.y - hy), vec2(hx, w), w);
	int mask = SEG_ON[clamp(digit, 0, 9)];
	float d = 1e3;
	if ((mask & 1) != 0) { d = min(d, sa); }
	if ((mask & 2) != 0) { d = min(d, sb); }
	if ((mask & 4) != 0) { d = min(d, sc); }
	if ((mask & 8) != 0) { d = min(d, sm); }
	if ((mask & 16) != 0) { d = min(d, se); }
	if ((mask & 32) != 0) { d = min(d, sf); }
	if ((mask & 64) != 0) { d = min(d, sg); }
	return smoothstep(aa, -aa, d);
}

float headcount_glyphs(vec2 p, float heads, float aa) {
	float value = clamp(heads, 0.0, 9999.0);
	int digits = 3;
	if (value >= 1000.0) { value = floor(value / 100.0); digits = 2; }
	int v = int(value);
	float adv = 0.30;
	float x0 = -float(digits) * adv * 0.5 + adv * 0.5;
	float acc = 0.0;
	for (int i = 0; i < 3; i++) {
		if (i >= digits) { break; }
		int place = digits - 1 - i;
		int scale = (place == 2) ? 100 : ((place == 1) ? 10 : 1);
		int dv = (v / scale) % 10;
		vec2 duv = (p - vec2(x0 + adv * float(i), 0.0)) / vec2(0.30, 0.30);
		if (abs(duv.x) < 0.5 && abs(duv.y) < 1.0) {
			acc = max(acc, seg_digit(duv, dv, aa / 0.30));
		}
	}
	return acc;
}

// 兵种剪影。
float class_glyph(vec2 p, int klass, float aa) {
	if (klass == 1) {
		float shoe = abs(length(p - vec2(0.0, 0.02)) - 0.32) - 0.075;
		float arch = smoothstep(aa, -aa, shoe) * step(-0.02, p.y);
		float lines = smoothstep(aa, -aa, abs(p.y - 0.20) - 0.032) * step(0.12, p.x);
		lines = max(lines, smoothstep(aa, -aa, abs(p.y + 0.02) - 0.032) * step(0.26, p.x));
		return max(arch, lines);
	}
	if (klass == 2) {
		float barrel = sd_rounded_box(p - vec2(0.10, 0.16), vec2(0.42, 0.075), 0.05);
		float wheel = abs(length(p - vec2(-0.20, -0.20)) - 0.19) - 0.055;
		float trail = sd_rounded_box(p - vec2(-0.02, -0.10), vec2(0.30, 0.045), 0.03);
		return smoothstep(aa, -aa, min(min(barrel, wheel), trail));
	}
	float a = sd_rounded_box(p, vec2(0.055, 0.44), 0.05);
	vec2 r = vec2(p.x * 0.7071 + p.y * 0.7071, -p.x * 0.7071 + p.y * 0.7071);
	float b = sd_rounded_box(r, vec2(0.055, 0.44), 0.05);
	return smoothstep(aa, -aa, min(a, b));
}

vec3 warning_color(int bit) {
	if (bit == 0) { return vec3(0.86, 0.44, 0.14); }   // 低补给
	if (bit == 1) { return vec3(0.76, 0.18, 0.16); }   // 缺粮
	if (bit == 2) { return vec3(0.90, 0.70, 0.16); }   // 欠饷
	return vec3(0.44, 0.28, 0.62);                     // 低士气
}

void vertex() {
	v_style = INSTANCE_CUSTOM;
	v_local = VERTEX * 2.0;
	v_world = MODEL_MATRIX[3].xy;
}

void fragment() {
	float aa = max(max(fwidth(v_local.x), fwidth(v_local.y)), 0.0008);
	// 屏幕足迹 LOD：足迹越大越缩，高频细节线性淡出。
	float detail_lod = 1.0 - smoothstep(0.018, 0.085, aa);

	vec2 p = v_local;
	float seed = hash21(floor(v_world * 0.37) + float(int(v_style.x)) * 3.7);
	float scale = max(selected_boost, 0.5);
	vec2 lp = p / scale;

	float body = sd_rounded_box(lp, vec2(0.78, 0.78), 0.30);
	float tear = tear_offset(lp, seed * 17.0) * detail_lod;
	float tear_edge = body - 0.15 - tear;
	float tear_mask = smoothstep(aa, -aa, tear_edge) * step(abs(p.x), 0.985) * step(abs(p.y), 0.985);

	// 纸纹
	vec2 grain_p = v_world * 0.55 + seed * 31.0;
	float blotch = value_noise(grain_p) * 0.6 + value_noise(grain_p * 3.1) * 0.4;
	float fiber = 0.0;
#ifndef PK_QUALITY_LOW
	fiber = value_noise(vec2(grain_p.x * 6.0, grain_p.y * 0.6)) * detail_lod;
#endif
	vec3 paper = paper_color.rgb * (1.0 - grain_strength * 0.15 * blotch);
	paper -= grain_strength * 0.045 * fiber;

	// 阵营色徽（上半部）+ 斜纹压印
	vec3 owner = owner_ink(v_style.x);
	float crest = smoothstep(aa, -aa, sd_rounded_box(lp - vec2(0.0, 0.40),
		vec2(0.64, 0.27), 0.15) + tear * 0.35);
	float hatch = smoothstep(0.42, 0.58, sin((lp.x + lp.y) * 44.0 - seed * 6.0) * 0.5 + 0.5);
	vec3 crest_col = owner * (0.86 + hatch * 0.22 * detail_lod);
	vec3 col = mix(paper, crest_col, crest * 0.92);

	// 铅笔轮廓
	float pencil = smoothstep(aa, -aa, abs(body) - 0.026);
	float pencil_inner = smoothstep(aa, -aa, abs(body + 0.075) - 0.010) * 0.32;
	float wobble = (value_noise(v_world * 1.7 + seed * 9.0) - 0.5) * 0.35 * detail_lod;
	vec3 ink = ink_color.rgb * (0.78 + wobble);
	col = mix(col, ink, clamp(pencil + pencil_inner, 0.0, 1.0) * outline_strength);

	// 白色撕边（纸片外侧一圈）
	float tear_band = smoothstep(aa, -aa, tear_edge) - smoothstep(aa, -aa, tear_edge - 0.055);
	vec3 tear_col = tear_color.rgb * (0.92 + blotch * 0.10);
	col = mix(col, tear_col, clamp(tear_band, 0.0, 1.0) * (1.0 - crest * 0.35));

	// 兵种图标
	vec2 g = (lp - vec2(0.0, -0.12)) * 2.4;
	float glyph = class_glyph(g, int(v_style.y + 0.5), aa * 2.4);
	col = mix(col, ink * 0.92, glyph * 0.88);

	// 兵力读数
	float digit_on = step(0.5, v_style.z) * detail_lod * (aggregate_mode ? 0.0 : 1.0);
	vec2 hp = (lp - vec2(0.0, -0.48)) * vec2(2.1, 2.1);
	float glyphs = headcount_glyphs(hp, v_style.z, aa * 2.1);
	col = mix(col, ink, glyphs * digit_on * 0.82);

	// 警示点
	int flags = int(v_style.w + 0.5);
	float pip = 0.0;
	vec3 pip_col = vec3(0.0);
	for (int bit = 0; bit < 4; bit++) {
		if ((flags & (1 << bit)) == 0) { continue; }
		vec2 d = lp - vec2(-0.36 + float(bit) * 0.24, -0.74);
		float pulse = reduced_motion ? 0.5 : (sin(wall_seconds * 3.4 + float(bit) * 1.3) * 0.5 + 0.5);
		float m = smoothstep(aa, -aa, length(d) - (0.075 + pulse * 0.012)) * detail_lod;
		if (m > pip) { pip = m; pip_col = warning_color(bit); }
	}
	col = mix(col, pip_col, pip * 0.92);

	// 选中：朱红外描（选中部队另有一圈独立的高亮节点，这里再加一道纸面描边）。
	float select_ring = 0.0;

	// 落纸影：贴纸下缘一条极淡的深色，压住任何地形底色。
	float shade = smoothstep(aa, -aa, tear_edge) * (1.0 - smoothstep(aa, -aa, body)) * 0.0;
	float drop = smoothstep(aa, -aa, sd_rounded_box(p - vec2(0.0, -0.05) * scale,
		vec2(0.80, 0.80) * scale, 0.32 * scale)) * (1.0 - tear_mask);
	col = mix(col, paper_shadow.rgb * 0.55, drop * 0.45);
	col = mix(col, select_color.rgb, select_ring * 0.9);

	float alpha = clamp(tear_mask + drop * 0.45 + select_ring, 0.0, 1.0) * layer_alpha;
	// 纸片静止时极轻的呼吸（视觉日推进），reduced_motion 下关闭。
	float breath = reduced_motion ? 0.0 : sin(visual_day * 6.28318) * 0.012 + 0.012;
	col *= 1.0 + breath;
	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), alpha);
	COLOR.a *= 1.0 - shade;
}
