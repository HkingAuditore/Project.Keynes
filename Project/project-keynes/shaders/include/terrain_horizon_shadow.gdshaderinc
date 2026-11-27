#ifndef TERRAIN_HORIZON_SHADOW_INC
#define TERRAIN_HORIZON_SHADOW_INC

const float TERRAIN_HORIZON_TAU = 6.2831853;
const float TERRAIN_HORIZON_OCTANT = 0.78539816;

float terrain_horizon_visibility_at_angle(vec3 light_dir, float sun_h_len, float horizon_angle) {
	float sun_elev = atan(max(light_dir.z, 0.0) / max(sun_h_len, 1e-4));
	float shadow = smoothstep(sun_elev - terrain_horizon_softness,
			sun_elev + terrain_horizon_softness, horizon_angle);
	float horizon_day_w = smoothstep(-0.14, 0.18, light_dir.z);
	return clamp(1.0 - shadow * terrain_horizon_strength * horizon_day_w, 0.0, 1.0);
}

#ifdef PK_HAS_HORIZON_DIR_TEX
float horizon_dir_component(vec4 d0, vec4 d1, int dir_index) {
	int idx = dir_index;
	if (idx < 0) idx += 8;
	if (idx >= 8) idx -= 8;
	if (idx == 0) return d0.r;
	if (idx == 1) return d0.g;
	if (idx == 2) return d0.b;
	if (idx == 3) return d0.a;
	if (idx == 4) return d1.r;
	if (idx == 5) return d1.g;
	if (idx == 6) return d1.b;
	return d1.a;
}

float terrain_horizon_direct_from_dir_tex(vec2 uv, vec3 light_dir) {
	vec2 sun_xy = light_dir.xy;
	float sun_h_len = length(sun_xy);
	if (sun_h_len <= 1e-4) {
		return 1.0;
	}
	sun_xy /= sun_h_len;
	float angle = atan(sun_xy.y, sun_xy.x);
	if (angle < 0.0) {
		angle += TERRAIN_HORIZON_TAU;
	}
	float sector = angle / TERRAIN_HORIZON_OCTANT;
	int i0 = int(floor(sector));
	float t = fract(sector);
	vec4 d0 = visual_sample_horizon_dir0(uv);
	vec4 d1 = visual_sample_horizon_dir1(uv);
	float h0 = horizon_dir_component(d0, d1, i0);
	float h1 = horizon_dir_component(d0, d1, i0 + 1);
	float horizon_angle = mix(h0, h1, t) * terrain_horizon_max_angle;
	return terrain_horizon_visibility_at_angle(light_dir, sun_h_len, horizon_angle);
}
#endif

#ifdef PK_WEB_SURFACE_HORIZON
// Both Web land and water use the surface array already in their sampler budget.
float terrain_horizon_web_visibility(vec2 uv, vec3 light_dir) {
	if (visual_quality <= 0 || terrain_horizon_strength <= 0.0
			|| !horizon_dir_tex_bound || terrain_surface_layer_count < 10) {
		return 1.0;
	}
	return terrain_horizon_direct_from_dir_tex(uv, light_dir);
}
#endif

#endif
