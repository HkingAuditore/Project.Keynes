shader_type canvas_item;

// 时代晋升大典的整屏底幕：压暗 + 去色（“时间变慢”的观感）+ 暗角，
// 再叠加光柱、放射光芒、冲击波环与爆闪。所有光效都在这一张全屏四边形里完成，
// 只采样一次屏幕纹理，Mobile / Compatibility 渲染器都可用。
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float fade : hint_range(0.0, 1.0) = 0.0;
uniform float dim : hint_range(0.0, 1.0) = 0.72;
uniform float desaturate : hint_range(0.0, 1.0) = 0.85;
uniform vec2 center = vec2(0.5, 0.32);
uniform float aspect = 1.6667;
uniform float pillar = 0.0;
uniform float burst = 0.0;
uniform float ring_radius = 0.0;
uniform float ring_alpha = 0.0;
uniform float flash = 0.0;
uniform float rays_angle = 0.0;
uniform vec4 gold : source_color = vec4(1.0, 0.79, 0.30, 1.0);

float hash11(float n) {
	return fract(sin(n * 12.9898) * 43758.5453);
}

float noise11(float x) {
	float i = floor(x);
	float f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(hash11(i), hash11(i + 1.0), f);
}

void fragment() {
	vec2 p = (UV - center) * vec2(aspect, 1.0);
	float d = length(p);
	vec2 dir = p / max(d, 0.0001);
	// 冲击波环：环上像素轻微折射底图，再叠一道亮边。
	float ring = exp(-pow((d - ring_radius) / 0.020, 2.0)) * ring_alpha;
	vec2 refract_uv = SCREEN_UV - dir * vec2(1.0 / aspect, 1.0) * ring * 0.012;
	vec3 scene = textureLod(screen_tex, refract_uv, 0.0).rgb;
	float luma = dot(scene, vec3(0.299, 0.587, 0.114));
	vec3 graded = mix(scene, vec3(luma) * vec3(1.03, 0.95, 0.82), desaturate);
	float vign = smoothstep(0.30, 1.20, length((UV - vec2(0.5)) * vec2(aspect, 1.0)));
	graded *= (1.0 - dim) * (1.0 - 0.80 * vign);

	vec3 white_gold = vec3(1.0, 0.96, 0.86);
	// 中心暖光池：徽记站在一片暖色里，而不是黑洞里。
	vec3 light = gold.rgb * 0.12 * exp(-d * d * 5.0);

	// 竖直光柱：自屏幕顶端贯下，越过徽记后渐隐；带缓慢的竖向闪烁。
	float dx = abs(p.x);
	float flicker = 0.78 + 0.22 * noise11(UV.y * 11.0 - TIME * 2.3);
	float beam = exp(-pow(dx / 0.045, 2.0)) * 1.15 + 0.50 * exp(-pow(dx / 0.15, 2.0));
	float core = exp(-pow(dx / 0.012, 2.0));
	float vertical = 1.0 - smoothstep(center.y + 0.05, center.y + 0.62, UV.y);
	light += mix(gold.rgb, white_gold, 0.55 + 0.45 * core) * (beam + core) * vertical * flicker * pillar;

	// 放射光芒：两组不同频率的光瓣叠加，缓慢旋转。
	float a = atan(p.y, p.x) + rays_angle;
	float rays = pow(abs(sin(a * 9.0)), 7.0) * 0.65 + pow(abs(sin(a * 5.0 + 1.3)), 12.0) * 0.45;
	float falloff = exp(-d * 2.1) * smoothstep(0.03, 0.14, d);
	light += gold.rgb * rays * falloff * burst * 0.95;

	light += mix(gold.rgb, white_gold, 0.5) * ring * 1.4;
	light += white_gold * flash * (0.35 + exp(-d * d * 2.5));

	COLOR = vec4(mix(scene, graded + light, fade), 1.0);
}
