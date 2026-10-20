shader_type canvas_item;
render_mode unshaded;

// 折痕展开：开场时整张纸沿一条竖折痕从中央向两侧展开。
// 不是缩放（缩放会让纸纹一起放大，像镜头推近），而是把 UV 左右压缩，
// 再在折痕处压一道阴影 —— 纸纹保持原尺寸，只是"还没铺开"。

uniform float open : hint_range(0.001, 1.0) = 1.0;
uniform float crease : hint_range(0.0, 1.0) = 0.5;
uniform float shadow : hint_range(0.0, 1.0) = 0.55;
uniform float crease_width : hint_range(0.005, 0.2) = 0.035;

void fragment() {
	float c = mix(0.002, 1.0, open);
	vec2 uv = UV;
	uv.x = crease + (UV.x - crease) / c;
	float inside = step(0.0, uv.x) * step(uv.x, 1.0);
	float crease_shade = exp(-pow((uv.x - crease) / crease_width, 2.0)) * (1.0 - open) * shadow;
	vec4 src = texture(TEXTURE, clamp(uv, vec2(0.0), vec2(1.0))) * COLOR;
	COLOR = vec4(src.rgb * (1.0 - crease_shade), src.a * inside * COLOR.a);
}
