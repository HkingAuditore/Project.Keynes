shader_type canvas_item;

void fragment() {
	// 共用纸徽 alpha 轮廓，柔化范围约 4px，以柔边投影衬起纸张。
	float alpha = 0.0;
	float weight_sum = 0.0;
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			vec2 delta = vec2(float(x), float(y));
			float weight = exp(-dot(delta, delta) / 3.0);
			alpha += texture(TEXTURE, UV + delta * 0.010).a * weight;
			weight_sum += weight;
		}
	}
	COLOR = vec4(0.08, 0.055, 0.035, alpha / weight_sum * 0.32);
}
