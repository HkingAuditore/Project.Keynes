shader_type canvas_item;
render_mode unshaded;

// 全屏颗粒与暗角：叠在纸场之上、转场之下的一层极薄的"印刷疵点"。
// 默认关闭；只有在截图 QA 达到帧率预算时才由代码打开（见 AnnualReportTokens）。
// 用 FRAGCOORD 取像素坐标，抖动不会随窗口缩放变粗，也不会出现规则摩尔纹。

uniform float grain : hint_range(0.0, 0.1) = 0.028;
uniform float vignette : hint_range(0.0, 0.3) = 0.10;
uniform vec4 shade_color : source_color = vec4(0.30, 0.21, 0.11, 1.0);
uniform float seed = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(233.34, 851.73) + seed);
	p += dot(p, p + 23.45);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 px = floor(FRAGCOORD.xy);
	float n = hash21(px) - 0.5;
	vec2 edge = UV - 0.5;
	float v = smoothstep(0.56, 1.08, length(edge * vec2(1.0, 1.12)));
	float alpha = clamp(abs(n) * grain * 2.0 + v * vignette, 0.0, 0.24);
	COLOR = vec4(shade_color.rgb, alpha * COLOR.a);
}
