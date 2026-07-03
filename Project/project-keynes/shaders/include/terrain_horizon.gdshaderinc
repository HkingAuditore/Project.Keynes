// terrain_horizon.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 8-direction baked heightfield horizon shadow. The texture is RGBA8, with two
// 4-bit horizon-angle samples packed into each byte: E/NE, N/NW, W/SW, S/SE.
// It returns direct-light visibility only; ambient and emission are not shadowed.

const float TERRAIN_HORIZON_TAU = 6.2831853;
const float TERRAIN_HORIZON_OCTANT = 0.78539816;

float horizon_unpack_byte(vec4 packed, int channel_index) {
	if (channel_index == 0) return floor(packed.r * 255.0 + 0.5);
	if (channel_index == 1) return floor(packed.g * 255.0 + 0.5);
	if (channel_index == 2) return floor(packed.b * 255.0 + 0.5);
	return floor(packed.a * 255.0 + 0.5);
}

float horizon_unpack_nibble(vec4 packed, int dir_index) {
	int ch = dir_index / 2;
	float byte_v = horizon_unpack_byte(packed, ch);
	float hi = floor(byte_v / 16.0);
	float lo = byte_v - hi * 16.0;
	return ((dir_index % 2) == 0) ? hi : lo;
}

float horizon_angle_by_index(vec4 packed, int dir_index) {
	int idx = dir_index;
	if (idx < 0) idx += 8;
	if (idx >= 8) idx -= 8;
	return (horizon_unpack_nibble(packed, idx) / 15.0) * terrain_horizon_max_angle;
}

float horizon_angle_from_packed(vec4 packed, float sector) {
	int i0 = int(floor(sector));
	float t = fract(sector);
	float h0 = horizon_angle_by_index(packed, i0);
	float h1 = horizon_angle_by_index(packed, i0 + 1);
	return mix(h0, h1, t);
}

float sample_terrain_horizon_angle(vec2 uv, vec2 sun_xy) {
	float angle = atan(sun_xy.y, sun_xy.x);
	if (angle < 0.0) {
		angle += TERRAIN_HORIZON_TAU;
	}
	float sector = angle / TERRAIN_HORIZON_OCTANT;

	// Packed nibbles cannot be hardware-linearly filtered: filtering bytes before unpacking
	// creates invalid high/low nibble blends and visible contour/moire artifacts. Use NEAREST
	// sampler and manually bilinear-filter decoded horizon angles instead.
	vec2 dims = vec2(textureSize(terrain_horizon_tex, 0));
	vec2 p = wrap_map_uv(uv) * dims - vec2(0.5);
	vec2 b = floor(p);
	vec2 f = fract(p);
	vec2 inv_dims = 1.0 / max(dims, vec2(1.0));

	vec2 uv00 = wrap_map_uv((b + vec2(0.5, 0.5)) * inv_dims);
	vec2 uv10 = wrap_map_uv((b + vec2(1.5, 0.5)) * inv_dims);
	vec2 uv01 = wrap_map_uv((b + vec2(0.5, 1.5)) * inv_dims);
	vec2 uv11 = wrap_map_uv((b + vec2(1.5, 1.5)) * inv_dims);

	float h00 = horizon_angle_from_packed(texture(terrain_horizon_tex, uv00), sector);
	float h10 = horizon_angle_from_packed(texture(terrain_horizon_tex, uv10), sector);
	float h01 = horizon_angle_from_packed(texture(terrain_horizon_tex, uv01), sector);
	float h11 = horizon_angle_from_packed(texture(terrain_horizon_tex, uv11), sector);
	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

float terrain_horizon_direct_visibility(vec2 uv, vec3 light_dir) {
#if defined(MOBILE_QUALITY_LOW) || defined(MOBILE_QUALITY_MID)
	return 1.0;
#else
	if (!terrain_horizon_tex_bound || visual_quality < 1 || terrain_horizon_strength <= 0.0) {
		return 1.0;
	}
	vec2 sun_xy = light_dir.xy;
	float sun_h_len = length(sun_xy);
	if (sun_h_len <= 1e-4) {
		return 1.0;
	}
	sun_xy /= sun_h_len;
	float horizon_angle = sample_terrain_horizon_angle(uv, sun_xy);
	float sun_elev = atan(max(light_dir.z, 0.0) / max(sun_h_len, 1e-4));
	float shadow = smoothstep(sun_elev - terrain_horizon_softness,
			sun_elev + terrain_horizon_softness, horizon_angle);
	// Do not hard-skip below the horizon: the day/night terminator is soft, so horizon
	// shadow must fade with sun height too. A hard z<=0 return creates a visible seam.
	float horizon_day_w = smoothstep(-0.14, 0.18, light_dir.z);
	return clamp(1.0 - shadow * terrain_horizon_strength * horizon_day_w, 0.0, 1.0);
#endif
}
