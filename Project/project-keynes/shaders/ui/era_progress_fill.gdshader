shader_type canvas_item;
uniform float progress : hint_range(0.0, 1.0) = 0.0;
// 时代晋升收购进度：收购中金色自上而下漫过徽记，暂停时只留淡金、不再流光。
uniform bool purchasing = false;
uniform bool paused = false;
// 4 选 2 条件已达成、尚未开始晋升：黄铜外缘缓慢呼吸，提醒玩家点开面板。
uniform bool advance_ready = false;
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
	glow = max(glow, advance_ready ? (0.30 + 0.18 * sin(TIME * 1.7)) : 0.0);
	vec3 gold = vec3(1.0, 0.79, 0.30);
	// 原图 alpha 遮罩：上至下覆盖不透明金色；收购中在漫溢前沿加一条缓慢流动的亮线。
	bool filling = purchasing || paused;
	float strength = paused ? 0.28 : 0.5;
	float fill = filling ? step(UV.y, progress) * strength : 0.0;
	vec3 rgb = mix(base.rgb, gold, fill);
	if (purchasing && progress > 0.0) {
		float front = exp(-abs(UV.y - progress) * 38.0) * (0.55 + 0.45 * sin(TIME * 2.2 + UV.x * 6.0));
		rgb += gold * front * 0.45;
	}
	float sweep = max(0.0, 1.0 - abs(UV.x + UV.y - ceremony * 2.8) * 9.0);
	rgb += gold * sweep * sin(ceremony * 3.14159) * 0.7;
	float outside = (1.0 - base.a) * rim * glow;
	float alpha = base.a + outside;
	COLOR = vec4((rgb * base.a + gold * outside) / max(alpha, 0.0001), alpha);
}
