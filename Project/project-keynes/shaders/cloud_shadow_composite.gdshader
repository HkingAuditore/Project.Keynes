shader_type canvas_item;
render_mode unshaded, blend_mul;

uniform sampler2D cloud_shadow_tex : filter_linear, repeat_disable;
uniform float cloud_shadow_strength = 0.34;
uniform float night_visibility = 1.0;
uniform vec2 drift_uv = vec2(0.0);
uniform bool wrap_x_enabled = false;
uniform float wrap_origin_uv = 0.0;
uniform float wrap_period_uv = 1.0;

void fragment() {
	vec2 uv = UV + drift_uv;
	if (wrap_x_enabled && wrap_period_uv > 0.0001) {
		uv.x = wrap_origin_uv + mod(uv.x - wrap_origin_uv, wrap_period_uv);
	} else {
		uv.x = clamp(uv.x, 0.0, 1.0);
	}
	uv.y = clamp(uv.y, 0.0, 1.0);
	float cloud = texture(cloud_shadow_tex, uv).r;
	float shade = clamp(cloud * cloud_shadow_strength * night_visibility, 0.0, 0.42);
	COLOR = vec4(vec3(1.0 - shade), 1.0);
}
