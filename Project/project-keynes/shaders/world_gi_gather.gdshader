shader_type canvas_item;
render_mode blend_disabled, unshaded;

// Gather K = 8 precomputed PTT-GI transfer neighbors.
// First bounce reads direct radiance. The second pass reflects the first bounce
// at each source and writes the sum of both bounces in the same radiance scale.

uniform sampler2D source_radiance_tex : filter_nearest, repeat_disable;
#ifdef PK_PTT_SECOND_BOUNCE
uniform sampler2D ptt_albedo_tex : filter_nearest, repeat_disable;
#endif
// 4 layers of RGBA8; each layer stores 2 integer (x, y) texel coordinates:
//   RG = neighbor 2*layer (x, y), BA = neighbor 2*layer+1 (x, y).
uniform sampler2DArray ptt_transfer_idx_tex : filter_nearest, repeat_disable;
// R = coupling factor C_i
uniform sampler2D ptt_coupling_tex : filter_nearest, repeat_disable;
uniform vec2 gi_size = vec2(128.0, 64.0);
uniform bool ptt_gi_ready = false;

vec3 gather_source(ivec2 coord) {
	vec3 radiance = texelFetch(source_radiance_tex, coord, 0).rgb;
#ifdef PK_PTT_SECOND_BOUNCE
	vec4 albedo = texelFetch(ptt_albedo_tex, coord, 0);
	vec3 linear_albedo = mix(albedo.rgb / 12.92,
		pow((albedo.rgb + 0.055) / 1.055, vec3(2.4)), greaterThan(albedo.rgb, vec3(0.04045)));
	radiance *= linear_albedo * (albedo.a / 3.14159265359);
#endif
	return radiance;
}

void fragment() {
	vec3 out_indirect = vec3(0.0);
	if (ptt_gi_ready && gi_size.x >= 1.0 && gi_size.y >= 1.0) {
		ivec2 dims = max(ivec2(floor(gi_size + vec2(0.5))), ivec2(1));
		ivec2 max_coord = dims - ivec2(1);
		ivec2 coord = clamp(ivec2(UV * gi_size), ivec2(0), max_coord);

#ifdef PK_PTT_SECOND_BOUNCE
		out_indirect = texelFetch(source_radiance_tex, coord, 0).rgb;
#endif
		float coupling = texelFetch(ptt_coupling_tex, coord, 0).r;
		if (coupling > 0.001) {
			vec3 acc = vec3(0.0);
			for (int layer = 0; layer < 4; layer++) {
				vec4 idx_px = texelFetch(ptt_transfer_idx_tex, ivec3(coord, layer), 0);
				ivec4 q = ivec4(floor(idx_px * 255.0 + vec4(0.5)));
				ivec2 src0 = clamp(q.rg, ivec2(0), max_coord);
				ivec2 src1 = clamp(q.ba, ivec2(0), max_coord);
				acc += gather_source(src0);
				acc += gather_source(src1);
			}
			out_indirect = clamp(out_indirect + acc * (coupling * 0.125), vec3(0.0), vec3(1.0));
		}
	}
	COLOR = vec4(out_indirect, 1.0);
}
