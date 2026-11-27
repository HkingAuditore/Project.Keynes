// Shared world-space dynamic lighting field (RGBA8 LINEAR):
//   RGB = indirect bounce radiance / world_lighting_radiance_scale
//   A   = direct sun/moon visibility [0, 1]
// Only variants that define PK_WORLD_LIGHTING_FIELD declare the sampler and
// uniforms; all other variants compile to neutral no-op helpers so Web 8/6
// sampler budgets remain untouched.
#ifndef WORLD_LIGHTING_FIELD_INC
#define WORLD_LIGHTING_FIELD_INC

#ifdef PK_WORLD_LIGHTING_FIELD
uniform sampler2D world_lighting_tex : filter_linear, repeat_disable;
uniform bool world_lighting_tex_bound = false;
uniform float world_lighting_radiance_scale = 2.0;

bool world_lighting_active() {
	return world_lighting_tex_bound;
}

vec2 world_lighting_wrap_map_uv(vec2 map_uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(map_uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + map_uv.x * world_size.x;
	float wrapped_x = wrap_origin_x + mod(world_x - wrap_origin_x, wrap_period_x);
	return vec2(
		(wrapped_x - world_origin.x) / max(world_size.x, 1e-5),
		clamp(map_uv.y, 0.0, 1.0)
	);
}

vec4 sample_world_lighting(vec2 map_uv) {
	if (!world_lighting_tex_bound) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	return texture(world_lighting_tex, world_lighting_wrap_map_uv(map_uv));
}
#else
const float world_lighting_radiance_scale = 2.0;

bool world_lighting_active() {
	return false;
}

vec4 sample_world_lighting(vec2 map_uv) {
	return vec4(0.0, 0.0, 0.0, 1.0);
}
#endif

#endif
