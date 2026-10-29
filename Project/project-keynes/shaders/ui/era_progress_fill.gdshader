shader_type canvas_item;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform bool researching = false;
uniform bool reward_available = false;
uniform bool highlighted = false;
uniform float ceremony = 0.0;
void fragment() {
	vec4 base = texture(TEXTURE, UV);
	float rim = 0.0;
	for (int i = 0; i < 8; i++) {
		float angle = float(i) * 0.785398;
		rim = max(rim, texture(TEXTURE, UV + vec2(cos(angle), sin(angle)) * 0.014).a);
	}
	float glow = reward_available ? (0.70 + 0.25 * sin(TIME * 3.0)) : 0.0;
	glow = max(glow, highlighted ? 0.5 : 0.0);
	vec3 gold = vec3(1.0, 0.79, 0.30);
	// 原图 alpha 遮罩：上至下覆盖 50% 不透明金色。
	float fill = researching ? step(UV.y, progress) * 0.5 : 0.0;
	vec3 rgb = mix(base.rgb, gold, fill);
	float sweep = max(0.0, 1.0 - abs(UV.x + UV.y - ceremony * 2.8) * 9.0);
	rgb += gold * sweep * sin(ceremony * 3.14159) * 0.7;
	float outside = (1.0 - base.a) * rim * glow;
	float alpha = base.a + outside;
	COLOR = vec4((rgb * base.a + gold * outside) / max(alpha, 0.0001), alpha);
}
