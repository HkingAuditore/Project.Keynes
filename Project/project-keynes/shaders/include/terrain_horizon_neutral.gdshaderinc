// No baked horizon is available on this platform. Shared neutral fallback.
struct TerrainHorizonSample {
	float direct_visibility;
	float sky_visibility;
	vec3 bent_normal;
	vec4 nearest_packed;
	bool has_data;
};

TerrainHorizonSample terrain_horizon_evaluate(vec2 uv, vec3 light_dir) {
	TerrainHorizonSample neutral;
	neutral.direct_visibility = 1.0;
	neutral.sky_visibility = 1.0;
	neutral.bent_normal = vec3(0.0, 0.0, 1.0);
	neutral.nearest_packed = vec4(0.0);
	neutral.has_data = false;
	return neutral;
}

float terrain_horizon_apply_normal(float sky_visibility, vec3 geometric_normal, vec3 bent_normal) {
	if (gi_normal_floor >= 1.0) {
		return clamp(sky_visibility, 0.0, 1.0);
	}
	float align = clamp(dot(normalize(geometric_normal), normalize(bent_normal)), 0.0, 1.0);
	return clamp(sky_visibility * mix(gi_normal_floor, 1.0, align), 0.0, 1.0);
}
