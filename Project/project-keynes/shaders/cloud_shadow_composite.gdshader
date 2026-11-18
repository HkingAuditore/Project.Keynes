shader_type canvas_item;
render_mode unshaded, blend_mul;

uniform sampler2D cloud_shadow_tex : filter_linear, repeat_disable;
uniform float cloud_shadow_strength = 0.55;
uniform float night_visibility = 1.0;
uniform vec2 drift_uv = vec2(0.0);
uniform bool wrap_x_enabled = false;
uniform float wrap_origin_uv = 0.0;
uniform float wrap_period_uv = 1.0;

// 整屏乘法路径的软压缩上限：blend_mul 会连环境光/天光一起乘，所以比直射路径
// （0.85）低。它只是曲线尺度，不是硬上限 —— 值永远取不到它。
const float CLOUD_SHADOW_COMPOSITE_MAX = 0.40;

void fragment() {
	vec2 uv = UV + drift_uv;
	if (wrap_x_enabled && wrap_period_uv > 0.0001) {
		uv.x = wrap_origin_uv + mod(uv.x - wrap_origin_uv, wrap_period_uv);
	} else {
		uv.x = clamp(uv.x, 0.0, 1.0);
	}
	uv.y = clamp(uv.y, 0.0, 1.0);
	float cloud = texture(cloud_shadow_tex, uv).r;
	// 上限 0.42：深海本来就只有 ~0.12 亮度，压 60% 会直接压成黑斑。
	// 云影应当读作"光线被挡了一层"，不是"贴了块黑纸"。
	// [cloud-tiling 2026-11-18] 与直射路径同样改成软膝：原来 clamp(…, 0.32)
	// 会把 field 0.67 以上的云心压成同一个常数，一块云影内部因此没有任何层次。
	float raw = cloud * cloud_shadow_strength * night_visibility;
	float shade = CLOUD_SHADOW_COMPOSITE_MAX
		* (1.0 - exp(-raw / CLOUD_SHADOW_COMPOSITE_MAX));
	COLOR = vec4(vec3(1.0 - shade), 1.0);
}
