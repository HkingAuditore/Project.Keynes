shader_type canvas_item;
render_mode unshaded;

// 封面纸雾：剪纸插画与标题之间的一层"留白托墨"。
// 右缘用噪声做不规则羽化，避免出现一条直边；上下边缘轻微收口，
// 让雾看起来是纸的一部分，而不是盖上去的半透明板。

uniform vec4 paper_color : source_color = vec4(0.965, 0.925, 0.835, 1.0);
uniform float strength : hint_range(0.0, 1.0) = 0.62;
uniform float feather : hint_range(0.02, 0.8) = 0.34;
uniform float edge_taper : hint_range(0.0, 0.4) = 0.08;
uniform float seed = 0.0;
// 0 = 右缘羽化（文字在左，插画在右）；1 = 下缘羽化（插画在上，正文在其下）。
uniform int axis = 0;
// 翻转：让雾"上浓下透"，给版画压一层暖调而不在下沿留一块平斑。
uniform float flip : hint_range(0.0, 1.0) = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(127.11, 311.7) + seed);
	p += dot(p, p + 19.19);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	// GDShader 的 fragment 不允许提前 return，两条分支都在末尾统一写 COLOR。
	float alpha = 0.0;
	if (axis == 1) {
		// 竖向：图版下沿往纸里化开，让插画"压在纸上"而不是"贴了一块矩形"。
		float wobble_y = (value_noise(UV * vec2(2.6, 4.0)) - 0.5) * 0.10;
		float y = UV.y + wobble_y;
		float a_y = smoothstep(1.0 - feather, 1.0, y);
		float taper_x = smoothstep(0.0, edge_taper, UV.x) * (1.0 - smoothstep(1.0 - edge_taper, 1.0, UV.x));
		alpha = a_y * mix(0.55, 1.0, taper_x);
	} else {
		// 不规则右缘：在 UV.x 上叠一层低频扰动，宽度约 12% 画幅。
		float wobble = (value_noise(UV * vec2(4.0, 2.6)) - 0.5) * 0.12;
		float x = UV.x + wobble;
		float a = 1.0 - smoothstep(1.0 - feather, 1.0, x);
		// 顶部与底部收口
		float taper = smoothstep(0.0, edge_taper, UV.y) * (1.0 - smoothstep(1.0 - edge_taper, 1.0, UV.y));
		alpha = a * mix(0.55, 1.0, taper);
	}
	alpha = mix(alpha, 1.0 - alpha, flip);
	COLOR = vec4(paper_color.rgb, paper_color.a * alpha * strength * COLOR.a);
}
