shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// ════════════════════════════════════════════════════════════════════════
// military_occupation_hatch.gdshader — 占领层（z=5）
//
// 复用 DataOverlay 的 cell-index atlas → per-cell LUT 间接寻址：
//   map_index_atlas(R/G = cell index low/high, A = landform)
//   → occupation_lut(RGBA8, 每格一个 texel)：
//        R = occupier 国色 slot（0..254，0 = 无占领）
//        G = 斜纹强度 q8（255 = 满）
//        B = 占领者与所有者不同的程度（用于线宽抖动）
//        A = 有效性（255 = 该格已被控制）
// 只在 control_revision 变化时由 CPU 重传 LUT，其余帧只做一次 atlas 采样。
//
// 图案：45° 斜纹（占领导致的「地图被另一国色划掉」的手绘语感），
// 斜纹边界用铅笔噪声打散，并按屏幕足迹淡出，缩小时退成均匀色块。
// ════════════════════════════════════════════════════════════════════════

uniform sampler2D map_index_atlas : filter_nearest, repeat_disable;
uniform sampler2D occupation_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0, 1.0);
uniform bool has_lut = false;
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
uniform float wall_seconds = 0.0;
uniform float layer_alpha : hint_range(0.0, 1.0) = 1.0;
uniform float hatch_spacing = 9.0;      // 世界单位
uniform float hatch_line_ratio : hint_range(0.05, 0.9) = 0.34;
uniform float hatch_opacity : hint_range(0.0, 1.0) = 0.55;
uniform vec4 paper_tint : source_color = vec4(0.96, 0.93, 0.86, 1.0);
uniform float player_slot = -1.0;
uniform vec4 player_color : source_color = vec4(0.90, 0.73, 0.38, 1.0);

varying vec2 v_uv;

#include "res://shaders/include/military_paper_common.gdshaderinc"

vec2 occ_wrap_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = mod(world_x, wrap_period_x);
	return vec2((wrapped_x - world_origin.x) / world_size.x, clamp(uv.y, 0.0, 1.0));
}

vec4 sample_lut(vec2 uv) {
	vec4 encoded = texture(map_index_atlas, occ_wrap_uv(uv));
	int lo = int(floor(encoded.g * 255.0 + 0.5));
	int hi = int(floor(encoded.b * 255.0 + 0.5));
	int cell_id = lo | (hi << 8);
	int capacity = int(lut_dims.x * lut_dims.y);
	if (cell_id == 65535 || cell_id < 0 || cell_id >= capacity) {
		return vec4(0.0);
	}
	int x = cell_id % int(lut_dims.x);
	int y = cell_id / int(lut_dims.x);
	vec2 lut_uv = (vec2(float(x), float(y)) + vec2(0.5)) / lut_dims;
	return texture(occupation_lut, lut_uv);
}

vec3 hatcher_ink(float slot, float seed) {
	if (abs(slot - player_slot) < 0.5) {
		return player_color.rgb;
	}
	float h = fract(slot * 0.61803398875 + 0.137);
	float s = 0.55;
	float v = 0.84;
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

void vertex() {
	v_uv = (VERTEX - world_origin) / world_size;
}

void fragment() {
	vec4 out_color = vec4(0.0);
	if (has_lut) {
		vec4 lut = sample_lut(v_uv);
		if (lut.a >= 0.5) {
			vec3 ink = hatcher_ink(lut.r * 255.0, 1.0);
			vec2 world = v_uv * world_size + world_origin;
			float lod = fwidth(world.x) * 0.6 + fwidth(world.y) * 0.6;
			// 45° 斜纹：对角坐标 + 铅笔抖动，条纹边界不是直线。
			float jitter = (pk_fbm(world * 0.22, lod) - 0.5) * 2.4;
			float diag = (world.x + world.y) * 0.7071 + jitter;
			float phase = fract(diag / max(hatch_spacing * 0.7071, 0.5));
			float aa = clamp(fwidth(phase), 0.0008, 0.5);
			float band = 1.0 - smoothstep(hatch_line_ratio - aa, hatch_line_ratio + aa, phase);
			// 足迹收细：条纹密到 pixel 以下时退成均匀淡色，避免摩尔纹。
			float fine = 1.0 - smoothstep(0.20, 0.55, aa);
			float blotch = pk_paper_blotch(world, lod);
			float strength = float(lut.g) / 255.0;
			vec3 base = mix(paper_tint.rgb, ink, 0.25 + strength * 0.35);
			vec3 col = mix(base, ink, band * fine);
			float alpha = (0.20 + 0.26 * band * fine + strength * 0.16) * hatch_opacity;
			alpha *= 0.82 + blotch * 0.5;
			alpha += strength * 0.20;
			out_color = vec4(col * (0.94 + blotch * 0.20), clamp(alpha, 0.0, 0.92));
		}
	}
	out_color.a *= layer_alpha;
	COLOR = out_color;
}
