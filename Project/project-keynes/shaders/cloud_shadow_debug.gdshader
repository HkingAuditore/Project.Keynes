shader_type canvas_item;
render_mode unshaded;

uniform sampler2D cloud_shadow_tex : filter_linear, repeat_disable;
uniform bool wrap_x_enabled = false;
uniform float wrap_origin_uv = 0.0;
uniform float wrap_period_uv = 1.0;

void fragment() {
	vec2 uv = UV;
	if (wrap_x_enabled && wrap_period_uv > 0.0001) {
		uv.x = wrap_origin_uv + mod(uv.x - wrap_origin_uv, wrap_period_uv);
	} else {
		uv.x = clamp(uv.x, 0.0, 1.0);
	}
	uv.y = clamp(uv.y, 0.0, 1.0);
	float mask = texture(cloud_shadow_tex, uv).r;
	COLOR = vec4(vec3(mask), 1.0);
}
