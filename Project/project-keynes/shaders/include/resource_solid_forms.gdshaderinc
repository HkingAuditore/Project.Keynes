// 45-degree orthographic solid & cluster forms for animals, crops, trees, and minerals.
// Coordinate system note:
//   Camera looks from +RS_VIEW = (+0.5, +0.5, +0.7071) toward origin.
//   Screen right (+p.x) is RS_RIGHT = (+0.7071, -0.7071, 0.0) -> (+x, -y).
//   Screen down  (+p.y) is RS_DOWN  = (+0.5, +0.5, -0.7071).
//   Therefore:
//     - Upward height is +z.
//     - Foreground (closest to camera) is (+x, +y, +z).
//     - Background (furthest from camera) is (-x, -y).
//     - Left of screen is (-x, +y); Right of screen is (+x, -y).
const vec3 RS_RIGHT = vec3(0.7071068, -0.7071068, 0.0);
const vec3 RS_DOWN = vec3(0.5, 0.5, -0.7071068);
const vec3 RS_VIEW = vec3(0.5, 0.5, 0.7071068);

struct RsRay {
	vec3 o;
	vec3 d;
	float yaw;
};

vec3 rs3_yaw(vec3 p, float a) {
	return vec3(mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * p.xy, p.z);
}

RsRay rs3_ray(vec2 p, float seed) {
	RsRay ray;
	ray.yaw = (seed - 0.5) * 0.42;
	// Scale p by 0.78 to give subjects a fuller, bolder presence inside the quad while keeping clean margins
	vec2 sp = p * 0.78;
	ray.o = rs3_yaw(RS_RIGHT * sp.x + RS_DOWN * (sp.y - 0.24) + RS_VIEW * 2.5, -ray.yaw);
	ray.d = rs3_yaw(-RS_VIEW, -ray.yaw);
	return ray;
}

void rs3_shape_smooth(inout RSurf s, RsRay ray, vec3 center, vec3 radii,
		vec3 bx, vec3 by, vec3 bz, vec3 color, int material, float k_smooth) {
	vec3 offset = ray.o - center;
	vec3 q = vec3(dot(offset, bx), dot(offset, by), dot(offset, bz)) / radii;
	vec3 v = vec3(dot(ray.d, bx), dot(ray.d, by), dot(ray.d, bz)) / radii;
	float a = dot(v, v);
	float b = dot(q, v);
	float disc = b * b - a * (dot(q, q) - 1.0);
	float scale = max(max(radii.x, radii.y), radii.z) * 0.65;
	float d = (sqrt(max(0.0, 1.0 - disc / a)) - 1.0) * scale;
	if (k_smooth > 0.001 && s.d < 5.0) {
		s.d = rs_smin(s.d, d, k_smooth);
	} else {
		s.d = min(s.d, d);
	}
	float t = (-b - sqrt(max(disc, 0.0))) / a;
	bool edge_only = disc < 0.0 && s.depth < -99.0 && d <= s.d + 0.002;
	if (disc >= 0.0 || edge_only) {
		vec3 hit = ray.o + ray.d * t;
		vec3 local_n = (q + v * t) / radii;
		vec3 new_n = normalize(rs3_yaw(bx * local_n.x + by * local_n.y + bz * local_n.z, ray.yaw));
		float new_h = max(hit.z, 0.0);
		float new_ao = 0.82 + 0.18 * smoothstep(0.02, 0.32, hit.z);
		float new_depth = -t;

		if (s.depth < -90.0 || edge_only) {
			s.n = new_n;
			s.albedo = color;
			s.mat_id = material;
			s.hit_pos = hit;
			s.h = new_h;
			s.ao = new_ao;
			if (disc >= 0.0) { s.depth = new_depth; }
		} else if (disc >= 0.0) {
			float blend_z = max(k_smooth * 1.35, 0.004);
			float w = smoothstep(-blend_z, blend_z, new_depth - s.depth);
			if (w > 0.001) {
				s.n = normalize(mix(s.n, new_n, w));
				s.albedo = mix(s.albedo, color, w);
				s.hit_pos = mix(s.hit_pos, hit, w);
				if (w > 0.5) { s.mat_id = material; }
				s.h = mix(s.h, new_h, w);
				s.ao = mix(s.ao, new_ao, w);
				s.depth = max(s.depth, new_depth);
			}
		}
	}
}

void rs3_oval_smooth(inout RSurf s, RsRay ray, vec3 center, vec3 radii, vec3 color, int material, float k_smooth) {
	rs3_shape_smooth(s, ray, center, radii, vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0), color, material, k_smooth);
}

void rs3_oval(inout RSurf s, RsRay ray, vec3 center, vec3 radii, vec3 color, int material, float seed) {
	rs3_oval_smooth(s, ray, center, radii, color, material, 0.0);
}

void rs3_bone_smooth(inout RSurf s, RsRay ray, vec3 a, vec3 b, vec2 width, vec3 color, int material, float k_smooth) {
	vec3 delta = b - a;
	float len = max(length(delta), 0.001);
	vec3 axis = delta / len;
	vec3 side = normalize(cross(axis, abs(axis.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0)));
	vec3 up = cross(axis, side);
	rs3_shape_smooth(s, ray, (a + b) * 0.5, vec3(len * 0.5 + width.x * 0.35, width.x, width.y),
		axis, side, up, color, material, k_smooth);
}

void rs3_bone(inout RSurf s, RsRay ray, vec3 a, vec3 b, vec2 width, vec3 color) {
	rs3_bone_smooth(s, ray, a, b, width, color, 0, 0.0);
}

void rs3_spike(inout RSurf s, RsRay ray, vec3 a, vec3 b, vec3 color) {
	vec3 delta = b - a;
	float len = max(length(delta), 0.001);
	vec3 axis = delta / len;
	vec3 side = normalize(cross(axis, vec3(0.0, 1.0, 0.0)));
	vec3 up = cross(axis, side);
	rs3_shape_smooth(s, ray, (a + b) * 0.5, vec3(len * 0.5, 0.105, 0.085), axis, side, up, color, 4, 0.015);
}

// Multi-lobed blossom / burst cotton boll primitive (replaces plain spheres with petaled/lobed geometry)
void rs3_blossom(inout RSurf s, RsRay ray, vec3 center, vec3 radii, float lobes, float lobe_amp, vec3 petal_col, vec3 core_col) {
	vec3 offset = ray.o - center;
	vec3 q = offset / radii;
	vec3 v = ray.d / radii;
	float a = dot(v, v);
	float b = dot(q, v);
	float t_closest = -b / a;
	vec3 p_closest = q + v * t_closest;
	float ang = atan(p_closest.y, p_closest.x);
	float lobe_mod = 1.0 + lobe_amp * cos(ang * lobes);
	float r_eff = length(p_closest) / max(lobe_mod, 0.5);
	float disc = (1.0 - r_eff * r_eff) * a;
	float scale = max(max(radii.x, radii.y), radii.z) * 0.65;
	float d = (r_eff - 1.0) * scale;
	s.d = min(s.d, d);
	float t = t_closest - sqrt(max(disc, 0.0)) / a;
	bool edge_only = disc < 0.0 && s.depth < -99.0 && d <= s.d + 0.002;
	if ((disc >= 0.0 && -t > s.depth) || edge_only) {
		vec3 hit = ray.o + ray.d * t;
		vec3 local_n = normalize((q + v * t) / radii + vec3(cos(ang * lobes) * lobe_amp * 0.35, sin(ang * lobes) * lobe_amp * 0.35, 0.4));
		s.n = normalize(rs3_yaw(local_n, ray.yaw));
		float center_mask = 1.0 - smoothstep(0.18, 0.38, r_eff);
		float petal_rib = 0.90 + 0.15 * cos(ang * lobes);
		s.albedo = mix(petal_col * petal_rib, core_col, center_mask);
		s.mat_id = 8;
		s.hit_pos = hit;
		s.h = max(hit.z, 0.0);
		if (disc >= 0.0) { s.depth = -t; }
		s.ao = 0.92 + 0.08 * smoothstep(0.0, 0.25, hit.z);
	}
}

// Deferred surface detail evaluated ONCE per covered pixel for animals, crops & wood
void rs3_apply_organic_material(inout RSurf s, float seed) {
	vec3 hit = s.hit_pos;
	int mat = s.mat_id;
	if (mat == 1) {
		float patch = vf_vnoise(hit.xy * vec2(5.2, 6.6) + hit.z * 2.5 + seed * 41.0);
		float spot = smoothstep(0.45, 0.55, patch);
		s.albedo = mix(vec3(0.97, 0.95, 0.90), s.albedo, spot);
		s.spec = mix(0.22, 0.32, spot);
	} else if (mat == 2) {
		float curl = vf_vnoise(hit.xy * 16.0 + hit.z * 12.0 + seed * 71.0);
		s.albedo *= 0.90 + 0.20 * curl;
		s.spec = 0.12;
	} else if (mat == 3) {
		float ring = 0.5 + 0.5 * sin(length(hit.yz * 28.0) + seed * 12.0);
		s.albedo *= 0.84 + ring * 0.28;
		s.spec = 0.20;
	} else if (mat == 4) {
		float grains = sin(hit.z * 90.0 + abs(hit.y) * 40.0);
		s.albedo *= 0.80 + smoothstep(-0.45, 0.45, grains) * 0.34;
		s.spec = 0.40;
	} else if (mat == 5) {
		s.spec = 0.48;
	} else if (mat == 6) {
		// Soft natural animal hide / fur grain (matte velvet finish, never plastic)
		float fur_grain = vf_vnoise(hit.xy * vec2(14.0, 8.0) + hit.z * 10.0 + seed * 29.0);
		s.albedo *= 0.91 + 0.16 * fur_grain;
		s.spec = 0.14;
	} else if (mat == 8) {
		// Fluffy snow-white cotton boll / silk cocoon / flower petal warm subsurface boost
		s.ao = max(s.ao, 0.95);
		s.spec = 0.22;
	}
}

void rs3_single_animal(inout RSurf s, RsRay ray, int form, vec3 offset, float scale, float graze_pitch, float seed, float motion, bool detailed) {
	vec3 coat = v_style.rgb;
	vec3 dark = vec3(0.14, 0.12, 0.10);
	bool horse = form == 8;
	bool sheep = form == 9;
	bool goat = form == 10;
	bool cattle = form == 11;
	bool pig = form == 12;
	bool camel = form == 13;
	bool yak = form == 14;

	if (horse) { coat = vec3(0.68, 0.36, 0.19); }
	else if (sheep) { coat = vec3(0.96, 0.93, 0.84); }
	else if (goat) { coat = vec3(0.78, 0.62, 0.44); }
	else if (cattle) { coat = vec3(0.16, 0.13, 0.11); }
	else if (pig) { coat = vec3(0.94, 0.64, 0.56); }
	else if (camel) { coat = vec3(0.86, 0.66, 0.38); }
	else if (yak) { coat = vec3(0.24, 0.18, 0.14); }

	float leg_h = (camel ? 0.44 : (horse ? 0.33 : (goat ? 0.25 : (pig ? 0.10 : (sheep ? 0.15 : 0.22))))) * scale;
	float body_z = offset.z + leg_h + (sheep ? 0.22 : (pig ? 0.17 : 0.24)) * scale;
	float body_w = (cattle || pig || yak ? 0.25 : (sheep ? 0.27 : (goat ? 0.16 : 0.19))) * scale;
	float body_l = (cattle ? 0.47 : (sheep ? 0.37 : (pig ? 0.41 : 0.43))) * scale;
	int fur = cattle ? 1 : (sheep || yak ? 2 : 6);
	float k_body = 0.045 * scale;

	if (!detailed) {
		rs3_oval(s, ray, offset + vec3(0.0, 0.0, body_z), vec3(body_l, body_w, 0.24 * scale), cattle ? vec3(0.55, 0.52, 0.48) : coat, fur, seed);
		vec3 h_pos = offset + vec3(0.42 * scale, 0.0, body_z + (camel || horse ? 0.28 : 0.06) * scale);
		rs3_oval(s, ray, h_pos, vec3(0.18, 0.13, 0.15) * scale, sheep ? dark : coat, 0, seed);
		rs3_bone(s, ray, offset + vec3(-0.24 * scale, body_w * 0.5, body_z), offset + vec3(-0.24 * scale, body_w * 0.5, 0.02), vec2(0.04 * scale), coat * 0.75);
		rs3_bone(s, ray, offset + vec3(0.24 * scale, body_w * 0.5, body_z), offset + vec3(0.24 * scale, body_w * 0.5, 0.02), vec2(0.04 * scale), coat * 0.75);
		return;
	}

	float bob = sin(motion * 0.7 + seed * 11.0) * 0.008 * scale;
	for (int i = 0; i < 4; i++) {
		float lx = (i < 2 ? -0.26 : 0.26) * scale;
		float ly = (i % 2 == 0 ? -body_w * 0.68 : body_w * 0.68);
		float stride = sin(motion * 0.6 + seed * 7.0 + float(i) * 1.57) * 0.024 * scale;
		vec3 hip = offset + vec3(lx, ly, leg_h + 0.16 * scale);
		vec3 hoof = offset + vec3(lx + (i < 2 ? -0.02 : 0.025) * scale + stride, ly, 0.04 * scale);
		vec3 leg_col = sheep ? vec3(0.24, 0.20, 0.17) : (horse ? mix(coat, dark, 0.55) : (cattle ? vec3(0.90, 0.88, 0.82) : coat * (pig ? 0.86 : 0.76)));
		rs3_bone_smooth(s, ray, hip, hoof, vec2(pig ? 0.046 : 0.036) * scale, leg_col, 0, 0.015 * scale);
		rs3_oval(s, ray, hoof - vec3(-0.015 * scale, 0.0, 0.015 * scale), vec3(0.055, 0.042, 0.036) * scale, dark, 0, seed);
	}

	vec3 barrel_c = offset + vec3(-0.03 * scale, 0.0, body_z);
	vec3 chest_c = offset + vec3(0.22 * scale, 0.0, body_z + (cattle || yak ? 0.03 : 0.01) * scale);
	vec3 rump_c = offset + vec3(-0.24 * scale, 0.0, body_z + (horse || cattle ? 0.02 : 0.0) * scale);
	rs3_oval_smooth(s, ray, barrel_c, vec3(body_l * 0.85, body_w, (sheep ? 0.25 : 0.23) * scale), coat, fur, k_body);
	rs3_oval_smooth(s, ray, chest_c, vec3(0.24, body_w * 0.92, (cattle || yak ? 0.26 : 0.22)) * scale, coat, fur, k_body);
	rs3_oval_smooth(s, ray, rump_c, vec3(0.23, body_w * 0.94, 0.23) * scale, coat, fur, k_body);

	if (sheep) {
		for (int i = 0; i < 3; i++) {
			float fx = (float(i) - 1.0) * 0.21 * scale;
			rs3_oval_smooth(s, ray, barrel_c + vec3(fx, 0.0, 0.09 * scale), vec3(0.21, 0.23, 0.19) * scale, coat * 1.02, 2, k_body);
		}
	} else if (camel) {
		for (int i = 0; i < 2; i++) {
			vec3 hump_c = barrel_c + vec3((-0.18 + float(i) * 0.34) * scale, 0.0, 0.22 * scale);
			rs3_oval_smooth(s, ray, hump_c, vec3(0.16, 0.15, 0.24) * scale, coat * 0.92, 5, k_body);
		}
	} else if (yak) {
		rs3_oval_smooth(s, ray, chest_c + vec3(-0.04 * scale, 0.0, 0.11 * scale), vec3(0.26, 0.24, 0.26) * scale, coat, 2, k_body);
		rs3_oval_smooth(s, ray, barrel_c + vec3(0.02 * scale, 0.0, -0.14 * scale), vec3(0.42, 0.26, 0.20) * scale, coat * 0.72, 2, k_body);
	} else if (cattle) {
		rs3_oval_smooth(s, ray, chest_c + vec3(0.08 * scale, 0.0, -0.10 * scale), vec3(0.16, 0.11, 0.14) * scale, vec3(0.92, 0.90, 0.84), 0, k_body);
	}

	vec3 head;
	vec3 head_size;
	float head_drop = graze_pitch * 0.26 * scale;
	if (horse || camel || goat) {
		head = offset + vec3((0.48 + graze_pitch * 0.06) * scale, 0.0, body_z + (camel ? 0.40 : (horse ? 0.34 : 0.24)) * scale - head_drop + bob);
		head_size = vec3(0.19, 0.11, 0.125) * scale;
		rs3_bone_smooth(s, ray, chest_c + vec3(0.02 * scale, 0.0, 0.04 * scale), head - vec3(0.05 * scale, 0.0, 0.015 * scale), vec2(0.105, 0.135) * scale, coat * 0.95, fur, k_body);
		if (horse) {
			rs3_bone_smooth(s, ray, chest_c + vec3(-0.02 * scale, 0.0, 0.18 * scale), head + vec3(-0.08 * scale, 0.0, 0.08 * scale), vec2(0.042, 0.095) * scale, dark, 0, 0.015 * scale);
		}
	} else {
		head = offset + vec3((0.44 + graze_pitch * 0.05) * scale, 0.0, body_z + (sheep ? 0.08 : (pig ? -0.02 : 0.04)) * scale - head_drop + bob);
		head_size = (sheep ? vec3(0.18, 0.11, 0.13) : (pig ? vec3(0.22, 0.18, 0.18) : vec3(0.20, 0.15, 0.18))) * scale;
		rs3_bone_smooth(s, ray, chest_c, head - vec3(0.06 * scale, 0.0, 0.0), vec2(0.13, 0.15) * scale, coat, fur, k_body);
	}

	vec3 face = sheep ? vec3(0.22, 0.19, 0.16) : (yak ? dark : (cattle ? vec3(0.20, 0.16, 0.14) : coat * 0.96));
	rs3_oval_smooth(s, ray, head, head_size, face, 0, 0.025 * scale);

	vec3 muzzle = head + vec3(0.145 * scale, 0.0, (-0.04 - graze_pitch * 0.03) * scale);
	vec3 muzzle_color = pig ? vec3(0.96, 0.66, 0.62) : (cattle ? vec3(0.82, 0.56, 0.50) : (horse ? dark * 1.2 : face * 0.78));
	rs3_oval_smooth(s, ray, muzzle, vec3(pig ? 0.065 : 0.085, pig || cattle ? 0.125 : 0.082, pig ? 0.095 : 0.078) * scale, muzzle_color, 5, 0.015 * scale);

	for (int side = -1; side <= 1; side += 2) {
		float sy = float(side);
		vec3 ear = head + vec3(-0.045 * scale, sy * head_size.y * 0.92, head_size.z * 0.65);
		vec3 ear_tip = ear + vec3((pig ? 0.04 : -0.03) * scale, sy * (pig ? 0.08 : (sheep ? 0.09 : 0.065)) * scale, (horse || goat ? 0.11 : (sheep ? -0.02 : 0.04)) * scale);
		rs3_bone(s, ray, ear, ear_tip, vec2(pig ? 0.065 : 0.034, 0.024) * scale, face * 0.88);
		rs3_oval(s, ray, head + vec3(0.068 * scale, sy * head_size.y * 0.86, 0.042 * scale), vec3(0.020, 0.016, 0.022) * scale, vec3(0.06, 0.05, 0.05), 0, seed);
		if (cattle || yak || goat) {
			vec3 root = head + vec3(-0.06 * scale, sy * 0.085 * scale, 0.11 * scale);
			vec3 bend = root + vec3((goat ? -0.10 : -0.02) * scale, sy * (yak ? 0.21 : (cattle ? 0.16 : 0.08)) * scale, (goat ? 0.16 : 0.09) * scale);
			vec3 tip = bend + vec3((goat ? -0.12 : 0.03) * scale, sy * (yak ? 0.06 : 0.04) * scale, (goat ? 0.09 : 0.13) * scale);
			vec3 horn_col = goat ? vec3(0.38, 0.33, 0.26) : vec3(0.88, 0.82, 0.66);
			rs3_bone(s, ray, root, bend, vec2(0.034 * scale), horn_col);
			rs3_bone(s, ray, bend, tip, vec2(0.022 * scale), horn_col * 0.85);
		}
		if (pig) {
			rs3_oval(s, ray, muzzle + vec3(0.055 * scale, sy * 0.045 * scale, 0.005 * scale), vec3(0.015, 0.022, 0.018) * scale, vec3(0.42, 0.20, 0.18), 0, seed);
		}
	}
	if (goat) {
		rs3_bone(s, ray, head + vec3(0.10 * scale, 0.0, -0.06 * scale), head + vec3(0.08 * scale, 0.0, -0.21 * scale), vec2(0.028, 0.052) * scale, vec3(0.28, 0.22, 0.16));
	}
	if (horse || cattle) {
		rs3_oval(s, ray, head + vec3(0.11 * scale, 0.0, 0.065 * scale), vec3(0.075, 0.038, 0.032) * scale, vec3(0.95, 0.93, 0.88), 0, seed);
	}
	vec3 tail_root = rump_c + vec3(-0.18 * scale, 0.0, 0.05 * scale);
	vec3 tail_tip = tail_root + vec3((-0.14 - (horse ? 0.06 : 0.0)) * scale, sin(motion * 0.5 + seed * 9.0) * 0.07 * scale, (pig ? 0.04 : (goat ? 0.09 : -0.21)) * scale);
	rs3_bone(s, ray, tail_root, tail_tip, vec2(horse || yak ? 0.038 : 0.022) * scale, horse || yak ? dark : coat * 0.78);
	if (horse || yak || cattle) {
		rs3_oval(s, ray, tail_tip, vec3(0.065, 0.050, 0.12) * scale, dark, 0, seed);
	}
}

RSurf rs3_animal(vec2 p, int form, float seed, float motion, float px) {
	RSurf s = rs_empty();
	RsRay ray = rs3_ray(p, seed);
	bool detailed = visual_quality > 0 && v_rank.y >= detailed_pixels;

	// Companion juvenile positioned cleanly to the rear-left so the lead adult's silhouette is crisp
	if (detailed) {
		rs3_single_animal(s, ray, form, vec3(-0.26, 0.18, 0.0), 0.56, 0.70, seed + 0.37, motion + 1.4, true);
	}
	rs3_single_animal(s, ray, form, vec3(0.06, -0.04, 0.0), 1.0, 0.0, seed, motion, detailed);

	if (detailed && s.d < px * 1.5) {
		rs3_apply_organic_material(s, seed);
	}
	s.rim = 0.32;
	s.floor_col = vec3(0.14, 0.18, 0.11);
	s.floor_a = exp(-pow(length((p - vec2(0.0, 0.28)) / vec2(0.54, 0.26)), 3.0)) * 0.22;
	return s;
}

RSurf rs3_plants(vec2 p, int form, int sub_style, float seed, float motion, float px) {
	RSurf s = rs_empty();
	RsRay ray = rs3_ray(p, seed);
	bool detailed = visual_quality > 0 && v_rank.y >= detailed_pixels;

	if (!detailed) {
		vec3 base_col = form == 0 ? vec3(0.90, 0.72, 0.24) : (form == 2 ? vec3(0.68, 0.78, 0.28) : vec3(0.28, 0.52, 0.22));
		rs3_oval(s, ray, vec3(0.0, 0.0, 0.26), vec3(0.42, 0.38, 0.28), base_col, 2, seed);
		if (form == 4 || form == 15) {
			rs3_oval(s, ray, vec3(0.14, 0.14, 0.42), vec3(0.24, 0.22, 0.18), vec3(0.98, 0.96, 0.90), 8, seed);
		} else if (form == 5) {
			rs3_oval(s, ray, vec3(0.14, 0.14, 0.42), vec3(0.24, 0.22, 0.16), v_style.rgb, 0, seed);
		}
		return s;
	}

	// Special dedicated composition for Silkworm (form 15): Lush mulberry leaf bed + 3 HUGE luminous silk cocoons!
	if (form == 15) {
		rs3_oval_smooth(s, ray, vec3(-0.10, -0.10, 0.18), vec3(0.44, 0.40, 0.20), vec3(0.22, 0.52, 0.20), 2, 0.05);
		rs3_oval_smooth(s, ray, vec3(0.16, -0.08, 0.16), vec3(0.34, 0.30, 0.18), vec3(0.28, 0.60, 0.24), 2, 0.05);
		rs3_oval_smooth(s, ray, vec3(-0.08, 0.16, 0.16), vec3(0.34, 0.30, 0.18), vec3(0.25, 0.56, 0.22), 2, 0.05);
		// 3 prominent satin-white & imperial-gold oval silk cocoons on top
		rs3_shape_smooth(s, ray, vec3(-0.02, 0.02, 0.38), vec3(0.26, 0.18, 0.19), normalize(vec3(0.8, 0.6, 0.0)), normalize(vec3(-0.6, 0.8, 0.0)), vec3(0.0, 0.0, 1.0), vec3(0.99, 0.98, 0.92), 8, 0.01);
		rs3_shape_smooth(s, ray, vec3(0.24, 0.08, 0.32), vec3(0.23, 0.16, 0.17), normalize(vec3(0.6, -0.8, 0.0)), normalize(vec3(0.8, 0.6, 0.0)), vec3(0.0, 0.0, 1.0), vec3(0.98, 0.86, 0.40), 4, 0.01);
		rs3_shape_smooth(s, ray, vec3(0.06, 0.26, 0.30), vec3(0.22, 0.15, 0.16), normalize(vec3(0.9, 0.4, 0.0)), normalize(vec3(-0.4, 0.9, 0.0)), vec3(0.0, 0.0, 1.0), vec3(0.99, 0.97, 0.90), 8, 0.01);
		if (s.d < px * 1.5) { rs3_apply_organic_material(s, seed); }
		s.rim = 0.28;
		s.floor_col = vec3(0.14, 0.18, 0.11);
		s.floor_a = exp(-pow(length((p - vec2(0.0, 0.28)) / vec2(0.56, 0.26)), 3.0)) * 0.22;
		return s;
	}

	// Dense basal foliage / tiller sheaf cushion for grain & reed stands
	if (form == 0 || form == 2 || form == 7) {
		vec3 sheaf_col = form == 0 ? vec3(0.70, 0.56, 0.22) : (form == 2 ? vec3(0.36, 0.60, 0.22) : vec3(0.34, 0.48, 0.26));
		rs3_oval_smooth(s, ray, vec3(0.0, 0.0, 0.20), vec3(0.34, 0.32, 0.20), sheaf_col, 2, 0.05);
	}

	int count = form == 1 ? 4 : (form == 0 || form == 2 || form == 7 ? 7 : 5);
	for (int i = 0; i < 7; i++) {
		if (i >= count) { break; }
		float fi = float(i);
		float a = fi * 2.39996 + seed * 6.28318;
		float ring_r = i == 0 ? 0.0 : (0.18 + 0.036 * fi);
		vec2 center = vec2(cos(a), sin(a)) * ring_r;
		float sway = sin(motion * 0.65 + fi * 0.9) * 0.032 * wind_strength;

		// Cereals, Rice & Wetland Reeds (form 0 = wheat, 2 = rice, 7 = reed)
		if (form == 0 || form == 2 || form == 7) {
			float height = (form == 7 ? 0.68 : 0.56) + rv_hash(fi + seed * 31.0) * 0.18;
			// Fan outward from a tight sheaf base so stalks never look like separated fence posts!
			vec3 root = vec3(center * 0.36, 0.04);
			vec3 tip = vec3(center * 1.05 + vec2(sway, 0.0), height);
			vec3 stem_col = form == 0 ? vec3(0.84, 0.68, 0.26) : (form == 2 ? vec3(0.48, 0.74, 0.26) : vec3(0.46, 0.62, 0.34));
			rs3_bone_smooth(s, ray, root, tip, vec2(0.038), stem_col, 2, 0.02);
			rs3_bone_smooth(s, ray, root + vec3(0.0, 0.0, 0.12), root + vec3(cos(a) * 0.34, sin(a) * 0.34, 0.42), vec2(0.072, 0.028), stem_col * 0.94, 2, 0.02);

			if (form == 0) {
				vec3 ear_top = tip + vec3(0.06 + sway, 0.02, 0.28);
				rs3_spike(s, ray, tip - vec3(0.0, 0.0, 0.08), ear_top, vec3(0.98, 0.80, 0.22));
				rs3_bone(s, ray, ear_top, ear_top + vec3(0.06, 0.02, 0.14), vec2(0.016), vec3(1.0, 0.92, 0.52));
			} else if (form == 2) {
				vec3 arch = tip + vec3(0.18, (fi - 3.0) * 0.03, -0.04);
				vec3 droop = arch + vec3(0.14, 0.02, -0.22);
				vec3 rice_gold = vec3(0.92, 0.84, 0.28);
				rs3_bone_smooth(s, ray, tip, arch, vec2(0.052, 0.042), rice_gold, 4, 0.02);
				rs3_bone_smooth(s, ray, arch, droop, vec2(0.056, 0.044), rice_gold * 1.06, 4, 0.02);
			} else {
				vec3 plume_top = tip + vec3(0.10 + sway * 1.4, 0.02, 0.28);
				rs3_oval_smooth(s, ray, (tip + plume_top) * 0.5, vec3(0.125, 0.105, 0.20), vec3(0.95, 0.92, 0.82), 8, 0.03);
			}
		}
		// Maize (form 1)
		else if (form == 1) {
			float height = 0.84 + rv_hash(fi + seed * 31.0) * 0.16;
			vec3 root = vec3(center, 0.02);
			vec3 tip = vec3(center + vec2(sway, 0.0), height);
			vec3 stalk_green = vec3(0.28, 0.58, 0.20);
			rs3_bone(s, ray, root, tip + vec3(0.0, 0.0, 0.10), vec2(0.038), stalk_green);
			for (int leaf = 0; leaf < 4; leaf++) {
				float fa = float(leaf) * 2.1 + a;
				vec3 joint = root + vec3(0.0, 0.0, 0.20 + float(leaf) * 0.15);
				vec3 edge = joint + vec3(cos(fa) * 0.44, sin(fa) * 0.44, 0.08);
				rs3_bone(s, ray, joint, edge, vec2(0.085, 0.028), stalk_green * (0.95 + float(leaf) * 0.06));
			}
			vec3 cob_base = tip - vec3(-0.06, -0.06, 0.36);
			vec3 cob_tip = cob_base + vec3(0.16, 0.12, 0.28);
			rs3_bone_smooth(s, ray, cob_base, cob_tip, vec2(0.092, 0.078), vec3(1.0, 0.84, 0.14), 4, 0.015);
			vec3 tassel_col = vec3(0.92, 0.80, 0.36);
			rs3_bone(s, ray, tip + vec3(0.0, 0.0, 0.06), tip + vec3(0.10, 0.03, 0.22), vec2(0.022), tassel_col);
		}
		// Potato & Bast Fiber (form 3)
		else if (form == 3) {
			if (sub_style == 0) {
				vec3 crown = vec3(center * 0.80 - vec2(0.10, 0.10), 0.22);
				rs3_oval_smooth(s, ray, crown, vec3(0.26, 0.24, 0.18), vec3(0.22, 0.50, 0.18), 2, 0.045);
				rs3_oval(s, ray, crown + vec3(0.10, 0.10, 0.17), vec3(0.09, 0.085, 0.05), vec3(0.96, 0.94, 1.0), 8, seed + fi);
				if (i < 3) {
					vec3 tuber_pos = i == 0 ? vec3(0.24, 0.22, 0.14) : (i == 1 ? vec3(0.02, 0.30, 0.12) : vec3(0.30, 0.02, 0.12));
					rs3_oval_smooth(s, ray, tuber_pos, vec3(0.19, 0.15, 0.14), vec3(0.90, 0.68, 0.34), 5, 0.02);
				}
			} else {
				float h_stalk = 0.72 + rv_hash(fi + seed * 17.0) * 0.18;
				vec3 root = vec3(center * 0.75 - vec2(0.12, 0.12), 0.02);
				vec3 top = vec3(root.xy + vec2(sway, 0.0), h_stalk);
				rs3_bone(s, ray, root, top, vec2(0.034), vec3(0.30, 0.58, 0.22));
				rs3_oval_smooth(s, ray, top, vec3(0.23, 0.21, 0.16), vec3(0.26, 0.52, 0.20), 2, 0.04);
				if (i == 0) {
					rs3_bone_smooth(s, ray, vec3(-0.04, 0.30, 0.12), vec3(0.34, 0.04, 0.44), vec2(0.15, 0.13), vec3(0.94, 0.82, 0.46), 4, 0.02);
				}
			}
		}
		// Cotton (form 4): 4-lobed burst snow-white cotton bolls over star calyxes
		else if (form == 4) {
			vec3 crown = vec3(center * 0.88, 0.22);
			rs3_oval_smooth(s, ray, crown, vec3(0.25, 0.23, 0.19), vec3(0.20, 0.44, 0.20), 2, 0.04);
			vec3 front_spot = crown + vec3(0.13, 0.13, 0.18);
			rs3_blossom(s, ray, front_spot, vec3(0.19, 0.18, 0.16), 4.0, 0.22, vec3(1.0, 0.99, 0.96), vec3(0.88, 0.84, 0.72));
		}
		// Flowering / Aromatic / Dye / Medicinal Botanicals (form 5): Petaled blossoms & tapered berry spikes (never spheres!)
		else if (form == 5) {
			vec3 crown = vec3(center * 0.88, 0.19);
			vec3 foliage_col = sub_style == 0 ? vec3(0.26, 0.54, 0.28) : (sub_style == 1 ? vec3(0.18, 0.44, 0.18) : (sub_style == 2 ? vec3(0.22, 0.42, 0.32) : vec3(0.24, 0.50, 0.22)));
			rs3_oval_smooth(s, ray, crown, vec3(0.24, 0.22, 0.16), foliage_col, 2, 0.035);
			vec3 bloom_pos = crown + vec3(0.12, 0.12, 0.17);
			if (sub_style == 0) {
				// Flax: 5-petaled sky-blue flower corolla with bright golden stamen core
				rs3_blossom(s, ray, bloom_pos, vec3(0.19, 0.18, 0.10), 5.0, 0.28, vec3(0.30, 0.70, 1.0), vec3(1.0, 0.88, 0.22));
			} else if (sub_style == 1) {
				// Spice: Tapered crimson pepper/clove spikes + rolled cinnamon bark quills in front
				rs3_spike(s, ray, bloom_pos - vec3(0.02, 0.02, 0.04), bloom_pos + vec3(0.08, 0.06, 0.20), vec3(0.96, 0.22, 0.14));
				if (i == 0) {
					rs3_bone(s, ray, vec3(0.02, 0.30, 0.10), vec3(0.32, 0.06, 0.20), vec2(0.095), vec3(0.80, 0.40, 0.16));
				}
			} else if (sub_style == 2) {
				// Dye Plant: 5-petaled royal-indigo & crimson-madder flower corollas with golden centers
				vec3 dye_col = i % 2 == 0 ? vec3(0.56, 0.28, 0.96) : vec3(0.96, 0.24, 0.52);
				rs3_blossom(s, ray, bloom_pos, vec3(0.19, 0.18, 0.10), 5.0, 0.28, dye_col, vec3(1.0, 0.84, 0.26));
			} else {
				// Medicinal Herb: 6-lobed scarlet ginseng berry umbel + pale bifurcated ginseng root in front
				rs3_blossom(s, ray, bloom_pos, vec3(0.16, 0.15, 0.11), 6.0, 0.24, vec3(0.96, 0.18, 0.16), vec3(0.70, 0.86, 0.28));
				if (i == 0) {
					rs3_bone(s, ray, vec3(0.04, 0.28, 0.09), vec3(0.28, 0.10, 0.18), vec2(0.085, 0.070), vec3(0.94, 0.86, 0.64));
					rs3_bone(s, ray, vec3(0.18, 0.18, 0.12), vec3(0.32, 0.24, 0.06), vec2(0.050, 0.042), vec3(0.92, 0.82, 0.60));
				}
			}
		}
	}

	if (s.d < px * 1.5) {
		rs3_apply_organic_material(s, seed);
	}
	s.rim = 0.26;
	s.floor_col = form == 2 ? vec3(0.24, 0.50, 0.46) : vec3(0.15, 0.18, 0.11);
	s.floor_a = exp(-pow(length((p - vec2(0.0, 0.28)) / vec2(0.58, 0.28)), 3.0)) * (form == 2 ? 0.45 : 0.20);
	return s;
}

// Fast convex polyhedron / crystal prism / cubic block / slab ledge primitive with 3D ridge bevel detection
void rs3_polyhedron(inout RSurf s, RsRay ray, vec3 center, vec3 size, float tilt_x, float tilt_y, int shape_kind, vec3 color, int mat_id, float seed) {
	vec3 o = (ray.o - center);
	o = vec3(o.x - o.z * tilt_x, o.y - o.z * tilt_y, o.z) / size;
	vec3 d = vec3(ray.d.x - ray.d.z * tilt_x, ray.d.y - ray.d.z * tilt_y, ray.d.z) / size;
	float enter = -100.0;
	float enter2 = -100.0;
	float leave = 100.0;
	vec3 face = vec3(0.0, 0.0, 1.0);

	int plane_count = shape_kind == 2 ? 6 : 8;
	for (int i = 0; i < 8; i++) {
		if (i >= plane_count) { break; }
		vec3 n;
		float limit;
		if (shape_kind == 2) {
			n = i == 0 ? vec3(1.0, 0.08, 0.10) : (i == 1 ? vec3(-1.0, -0.08, 0.10) :
				(i == 2 ? vec3(0.08, 1.0, 0.10) : (i == 3 ? vec3(-0.08, -1.0, 0.10) :
				(i == 4 ? vec3(0.05, 0.05, 1.0) : vec3(0.0, 0.0, -1.0)))));
			n = normalize(n);
			limit = i == 5 ? 0.02 : 0.68;
		} else if (shape_kind == 1) {
			float angle = float(i) * 1.0471975 + seed * 0.8;
			n = i < 6 ? normalize(vec3(cos(angle), sin(angle), 0.15))
				: (i == 6 ? normalize(vec3(0.22, 0.22, 0.95)) : vec3(0.0, 0.0, -1.0));
			limit = i == 7 ? 0.02 : (i == 6 ? 0.88 : 0.55);
		} else {
			float angle = float(i) * 1.0471975 + seed;
			n = i < 6 ? normalize(vec3(cos(angle), sin(angle), 0.36 + rv_hash(float(i) + seed * 19.0) * 0.34))
				: (i == 6 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 0.0, -1.0));
			limit = i == 7 ? 0.02 : (0.68 + rv_hash(float(i) + seed * 37.0) * 0.15);
		}
		float denom = dot(n, d);
		float t = (limit - dot(n, o)) / (abs(denom) > 0.00001 ? denom : 0.00001);
		if (denom < 0.0) {
			if (t > enter) {
				enter2 = enter;
				enter = t;
				face = n;
			} else if (t > enter2) {
				enter2 = t;
			}
		} else {
			leave = min(leave, t);
		}
	}
	float coverage = clamp((leave - enter) * 14.0, -1.0, 1.0);
	s.d = min(s.d, -coverage * 0.08);

	if (enter <= leave && -enter > s.depth) {
		vec3 hit = ray.o + ray.d * enter;
		float ridge = 1.0 - smoothstep(0.0, 0.06, enter - enter2);
		float facet_shade = (face.z > 0.75) ? 1.24 : ((face.x + face.y > 0.0) ? 1.05 : 0.76);
		s.hit_pos = vec3((hit - center).xy / size.xy, ridge);
		s.albedo = color * facet_shade + vec3(ridge * 0.20);
		s.n = normalize(rs3_yaw(face / size, ray.yaw));
		s.h = max(hit.z, 0.0);
		s.depth = -enter;
		s.mat_id = mat_id;
		s.ao = 0.80 + 0.20 * smoothstep(0.0, 0.26, hit.z);
	}
}

// Deferred geological material shading: evaluated ONCE per covered pixel!
void rs3_apply_geology_material(inout RSurf s, int form, int sub_style, float seed) {
	vec2 local = s.hit_pos.xy;
	float ridge = s.hit_pos.z;
	float n_low = vf_vnoise(local * 4.5 + s.h * 4.0 + seed * 31.0);
	float n_high = vf_vnoise(local * 10.0 + s.h * 8.0 + seed * 73.0);
	vec3 alb = s.albedo;
	float spec = 0.32 + ridge * 0.38;
	float metal = 0.0;
	vec3 s_tint = vec3(1.0);

	if (form == 16) {
		if (sub_style == 0) {
			alb = mix(vec3(0.46, 0.48, 0.45), vec3(0.80, 0.79, 0.74), smoothstep(0.25, 0.75, n_low)) + vec3(ridge * 0.16);
			spec = 0.38;
		} else if (sub_style == 1) {
			vec2 cell_p = fract(local * 3.8 + s.h * 2.5) - 0.5;
			float ooid = 1.0 - smoothstep(0.15, 0.38, length(cell_p));
			alb = mix(vec3(0.68, 0.28, 0.15), vec3(0.96, 0.68, 0.34), ooid);
			spec = 0.34;
		} else if (sub_style == 2) {
			float strata = 0.5 + 0.5 * sin(s.h * 32.0 + n_low * 1.5);
			alb = mix(vec3(0.68, 0.65, 0.56), vec3(0.95, 0.93, 0.85), strata) + vec3(ridge * 0.14);
			spec = 0.32;
		} else if (sub_style == 3) {
			float strata = 0.5 + 0.5 * sin(s.h * 24.0 + local.x * 5.0);
			float nodule = smoothstep(0.52, 0.70, n_high);
			alb = mix(mix(vec3(0.50, 0.56, 0.38), vec3(0.86, 0.84, 0.68), strata), vec3(0.26, 0.20, 0.12), nodule);
			spec = mix(0.30, 0.76, nodule);
		} else {
			float core = smoothstep(0.22, 0.46, n_low + (0.32 - length(local) * 0.30));
			alb = mix(vec3(0.95, 0.93, 0.88), vec3(0.28, 0.34, 0.42), core) + vec3(ridge * 0.26);
			spec = mix(0.26, 0.92, core);
		}
	} else if (form == 17) {
		float vein_wave = abs(sin((local.x * 4.5 + local.y * 3.5 + s.h * 5.0) + n_low * 2.6));
		float vein = smoothstep(0.38, 0.08, vein_wave);
		float ore_mask = clamp(vein * 0.90 + ridge * 0.55, 0.0, 1.0);

		if (sub_style == 0) {
			// Coal: Warm grey-brown shale matrix in rear (mat 6) + glossy gunmetal-black anthracite seam with bright silver-grey bevels in front (never a flat black blob!)
			if (s.mat_id == 6) {
				alb = mix(vec3(0.44, 0.40, 0.35), vec3(0.58, 0.53, 0.46), n_low) + vec3(ridge * 0.15);
				spec = 0.28;
				metal = 0.0;
			} else {
				float cleat = 0.5 + 0.5 * sin(s.h * 34.0 + local.x * 10.0);
				alb = mix(vec3(0.14, 0.15, 0.17), vec3(0.52, 0.55, 0.60), cleat * 0.45 + ridge * 0.72);
				spec = 0.96;
				metal = 0.55;
				s_tint = vec3(0.92, 0.95, 1.0);
			}
		} else if (sub_style == 1) {
			vec3 malachite = mix(vec3(0.08, 0.64, 0.40), vec3(0.26, 0.92, 0.62), 0.5 + 0.5 * sin(n_low * 14.0));
			vec3 azurite = vec3(0.16, 0.44, 0.88);
			vec3 native_cu = vec3(0.98, 0.54, 0.24);
			alb = mix(malachite, azurite, smoothstep(0.55, 0.75, n_high) * 0.70);
			alb = mix(alb, native_cu, (s.mat_id == 7 ? 0.70 : 0.0) + vein * 0.85);
			spec = 0.90;
			metal = 0.80;
			s_tint = mix(vec3(0.9, 1.0, 0.95), vec3(1.0, 0.64, 0.36), vein);
		} else if (sub_style == 2) {
			float bif = 0.5 + 0.5 * sin(s.h * 28.0 + local.x * 6.0 + n_low * 2.2);
			alb = mix(vec3(0.86, 0.26, 0.16), vec3(0.54, 0.58, 0.66), smoothstep(0.35, 0.65, bif)) + vec3(ridge * 0.22);
			spec = 0.90;
			metal = 0.85;
			s_tint = vec3(0.96, 0.88, 0.84);
		} else if (sub_style == 3) {
			vec3 quartz = mix(vec3(0.84, 0.82, 0.76), vec3(0.98, 0.96, 0.92), n_low);
			vec3 gold_col = vec3(1.0, 0.80, 0.10);
			float gold_zone = s.mat_id == 7 ? 0.98 : vein * 0.88;
			alb = mix(quartz, gold_col, gold_zone) + vec3(ridge * 0.22);
			spec = mix(0.42, 0.99, gold_zone);
			metal = gold_zone * 0.98;
			s_tint = mix(vec3(1.0), vec3(1.0, 0.86, 0.28), gold_zone);
		} else if (sub_style == 4) {
			vec3 host = mix(vec3(0.24, 0.28, 0.34), vec3(0.38, 0.42, 0.50), n_low);
			vec3 silver_col = vec3(0.96, 0.98, 1.0);
			float silver_zone = s.mat_id == 7 ? 0.98 : ore_mask * 0.80;
			alb = mix(host, silver_col, silver_zone) + vec3(ridge * 0.24);
			spec = mix(0.35, 0.99, silver_zone);
			metal = silver_zone * 0.96;
			s_tint = vec3(0.95, 0.98, 1.0);
		} else if (sub_style == 5) {
			vec3 bastnasite = vec3(0.94, 0.62, 0.22);
			vec3 monazite = vec3(0.84, 0.36, 0.76);
			alb = mix(bastnasite, monazite, (s.mat_id == 7 ? 0.78 : smoothstep(0.35, 0.65, n_high))) + vec3(ridge * 0.20);
			spec = 0.86;
			metal = 0.45;
			s_tint = vec3(1.0, 0.85, 0.92);
		} else if (sub_style == 6) {
			float cass = s.mat_id == 7 ? 0.94 : smoothstep(0.32, 0.62, n_low + ore_mask * 0.4);
			alb = mix(vec3(0.86, 0.78, 0.68), vec3(0.46, 0.32, 0.20), cass) + vec3(ridge * 0.26);
			spec = 0.92;
			metal = 0.72;
			s_tint = vec3(0.98, 0.88, 0.74);
		} else if (sub_style == 7) {
			alb = mix(vec3(0.36, 0.42, 0.52), vec3(0.76, 0.82, 0.92), ridge * 0.78 + n_low * 0.35);
			spec = 0.95;
			metal = 0.92;
			s_tint = vec3(0.84, 0.90, 1.0);
		} else if (sub_style == 8) {
			// Zinc Ore: Fiery honey-amber & ruby-orange resinous sphalerite crystals on dark matrix
			vec3 matrix_col = vec3(0.24, 0.20, 0.18);
			vec3 sphalerite = mix(vec3(0.96, 0.46, 0.10), vec3(1.0, 0.72, 0.20), n_high);
			alb = mix(matrix_col, sphalerite, s.mat_id == 7 ? 0.94 : vein * 0.75) + vec3(ridge * 0.22);
			spec = 0.92;
			metal = 0.55;
			s_tint = vec3(1.0, 0.82, 0.45);
		} else {
			vec3 black_mn = vec3(0.14, 0.13, 0.16);
			vec3 rhodochrosite = vec3(0.98, 0.42, 0.58);
			float band = s.mat_id == 7 ? 0.90 : vein;
			alb = mix(black_mn, rhodochrosite, band * 0.94) + vec3(ridge * 0.16);
			spec = 0.88;
			metal = 0.45;
			s_tint = vec3(1.0, 0.75, 0.82);
		}
	} else {
		if (sub_style == 0) {
			alb = mix(vec3(0.98, 0.96, 0.94), vec3(0.96, 0.72, 0.68), (1.0 - s.h) * 0.50) + vec3(ridge * 0.24);
			s.ao = max(s.ao, 0.94);
			spec = 0.94;
			s_tint = vec3(1.0, 0.96, 0.94);
		} else if (sub_style == 1) {
			float frost = s.mat_id == 7 ? 0.96 : smoothstep(0.15, 0.48, s.h + n_high * 0.35);
			alb = mix(vec3(0.26, 0.28, 0.27), vec3(0.97, 0.99, 0.97), frost) + vec3(ridge * 0.22);
			s.ao = max(s.ao, 0.92);
			spec = mix(0.28, 0.90, frost);
		} else {
			float crystal = s.mat_id == 7 ? 0.96 : smoothstep(0.08, 0.35, s.h + n_low * 0.25);
			alb = mix(vec3(0.18, 0.17, 0.16), vec3(1.0, 0.92, 0.12), crystal) + vec3(ridge * 0.22);
			spec = mix(0.25, 0.94, crystal);
			s_tint = vec3(1.0, 0.95, 0.45);
		}
	}

	s.albedo = alb;
	s.spec = spec;
	s.metallic = metal;
	s.spec_tint = s_tint;
}

RSurf rs3_geology(vec2 p, int form, int sub_style, float seed, float px) {
	RSurf s = rs_empty();
	RsRay ray = rs3_ray(p, seed);
	bool detailed = visual_quality > 0 && v_rank.y >= detailed_pixels;

	if (!detailed) {
		rs3_polyhedron(s, ray, vec3(0.0, 0.0, 0.0), vec3(0.74, 0.58, 0.52), 0.0, 0.0, 0, v_style.rgb, 7, seed);
		return s;
	}

	// 1. Prismatic Crystal Outcrops: gold_ore (17,3), silver_ore (17,4), rare_earth (17,5), tin_ore (17,6), zinc_ore (17,8), salt (18,0), saltpeter (18,1), sulfur (18,2)
	bool is_crystal_outcrop = (form == 17 && (sub_style >= 3 && sub_style <= 6 || sub_style == 8)) || (form == 18);
	// 2. Botryoidal / Nodular Vein Crags: copper_ore (17,1), manganese_ore (17,9), bauxite (16,1)
	bool is_botryoidal = (form == 17 && (sub_style == 1 || sub_style == 9)) || (form == 16 && sub_style == 1);

	if (is_crystal_outcrop) {
		// Grounded natural host rock crag in rear + 3 splayed hexagonal crystal points in foreground
		vec3 host_col = (form == 17 && sub_style == 3) ? vec3(0.84, 0.82, 0.76) :
			((form == 17 && sub_style == 4) ? vec3(0.32, 0.35, 0.40) :
			((form == 18 && sub_style == 0) ? vec3(0.88, 0.84, 0.80) : vec3(0.46, 0.44, 0.40)));
		rs3_polyhedron(s, ray, vec3(-0.14, -0.14, 0.0), vec3(0.70, 0.58, 0.46), 0.0, 0.0, 0, host_col, 6, seed);
		rs3_polyhedron(s, ray, vec3(-0.02, -0.02, 0.08), vec3(0.32, 0.30, 0.74), 0.14, 0.14, 1, v_style.rgb, 7, seed + 0.1);
		rs3_polyhedron(s, ray, vec3(0.26, -0.04, 0.04), vec3(0.28, 0.26, 0.58), 0.34, -0.18, 1, v_style.rgb * 1.05, 7, seed + 0.3);
		rs3_polyhedron(s, ray, vec3(-0.04, 0.26, 0.04), vec3(0.26, 0.26, 0.52), -0.18, 0.34, 1, v_style.rgb * 0.95, 7, seed + 0.5);
		rs3_polyhedron(s, ray, vec3(0.20, 0.20, 0.02), vec3(0.26, 0.24, 0.36), 0.22, 0.22, 1, v_style.rgb * 1.08, 7, seed + 0.7);
	} else if (is_botryoidal) {
		// Rugged natural crag in rear + rounded botryoidal mineral domes in foreground
		rs3_polyhedron(s, ray, vec3(-0.14, -0.14, 0.04), vec3(0.68, 0.56, 0.54), 0.0, 0.0, 0, v_style.rgb * 0.80, 6, seed);
		rs3_oval_smooth(s, ray, vec3(0.18, 0.06, 0.24), vec3(0.30, 0.28, 0.26), v_style.rgb, 7, 0.05);
		rs3_oval_smooth(s, ray, vec3(0.02, 0.22, 0.20), vec3(0.26, 0.24, 0.22), v_style.rgb * 1.06, 7, 0.05);
		rs3_oval_smooth(s, ray, vec3(0.26, 0.24, 0.14), vec3(0.22, 0.20, 0.18), v_style.rgb * 0.94, 7, 0.04);
	} else {
		// Natural Multi-Peak Crag Outcrops (coal, iron_ore, lead_ore, stone, limestone, phosphate_rock, flint) — irregular 8-plane rock crags, never rectangular crates!
		rs3_polyhedron(s, ray, vec3(-0.14, -0.14, 0.04), vec3(0.70, 0.58, 0.62), 0.10, 0.06, 0, v_style.rgb * 0.92, 6, seed);
		rs3_polyhedron(s, ray, vec3(0.24, 0.02, 0.0), vec3(0.46, 0.40, 0.44), -0.14, 0.10, 0, v_style.rgb * 1.05, 7, seed + 0.25);
		rs3_polyhedron(s, ray, vec3(0.02, 0.24, 0.0), vec3(0.42, 0.38, 0.38), 0.10, -0.14, 0, v_style.rgb * 0.96, 7, seed + 0.50);
		rs3_polyhedron(s, ray, vec3(0.20, 0.20, 0.0), vec3(0.32, 0.30, 0.28), 0.08, 0.08, 0, v_style.rgb * 1.08, 7, seed + 0.75);
	}

	if (s.d < px * 1.5) {
		rs3_apply_geology_material(s, form, sub_style, seed);
	}
	s.rim = 0.24;
	s.floor_col = vec3(0.14, 0.15, 0.12);
	s.floor_a = exp(-pow(length((p - vec2(0.0, 0.28)) / vec2(0.58, 0.28)), 3.0)) * 0.22;
	return s;
}

// 3D Terraced Micro-Landscapes for Land Capacity (form 22: fertile_soil, arable_land, paddy_land, plantation_land, pasture)
RSurf rs3_land_capacity(vec2 p, int sub_style, float seed, float px) {
	RSurf s = rs_empty();
	RsRay ray = rs3_ray(p, seed);
	bool detailed = visual_quality > 0 && v_rank.y >= detailed_pixels;

	if (sub_style == 0) {
		// Fertile Soil: Rich dark chernozem humus mounds + 3 vibrant green seedling shoots!
		rs3_oval_smooth(s, ray, vec3(-0.06, 0.04, 0.06), vec3(0.54, 0.44, 0.12), vec3(0.26, 0.19, 0.13), 2, 0.06);
		rs3_oval_smooth(s, ray, vec3(0.22, -0.06, 0.05), vec3(0.38, 0.34, 0.10), vec3(0.32, 0.24, 0.16), 2, 0.06);
		if (detailed) {
			for (int i = 0; i < 3; i++) {
				vec3 sp = i == 0 ? vec3(-0.08, 0.02, 0.14) : (i == 1 ? vec3(0.18, -0.04, 0.12) : vec3(0.04, 0.20, 0.12));
				rs3_bone(s, ray, sp, sp + vec3(0.0, 0.0, 0.18), vec2(0.028), vec3(0.38, 0.68, 0.24));
				rs3_oval(s, ray, sp + vec3(0.05, 0.02, 0.18), vec3(0.09, 0.06, 0.04), vec3(0.46, 0.78, 0.28), 0, seed);
				rs3_oval(s, ray, sp + vec3(-0.05, -0.02, 0.17), vec3(0.08, 0.05, 0.04), vec3(0.40, 0.72, 0.26), 0, seed);
			}
		}
	} else if (sub_style == 1) {
		// Arable Land: Golden-ochre terraced field bed topped with neat green-gold seedling rows (distinct from timber logs!)
		rs3_oval_smooth(s, ray, vec3(0.0, 0.02, 0.05), vec3(0.58, 0.48, 0.09), vec3(0.56, 0.43, 0.25), 2, 0.04);
		for (int r = -1; r <= 1; r++) {
			float ry = float(r) * 0.18;
			rs3_bone_smooth(s, ray, vec3(-0.36, ry, 0.11), vec3(0.36, ry, 0.11), vec2(0.065, 0.055), vec3(0.70, 0.56, 0.32), 2, 0.02);
			if (detailed) {
				rs3_oval(s, ray, vec3(float(r) * 0.16, ry, 0.18), vec3(0.09, 0.07, 0.07), vec3(0.52, 0.74, 0.28), 0, seed);
			}
		}
	} else if (sub_style == 2) {
		// Paddy Land: Stepped flooded aqua water-mirror terraces framed by green earth bunds
		rs3_oval_smooth(s, ray, vec3(-0.08, -0.08, 0.08), vec3(0.52, 0.44, 0.10), vec3(0.36, 0.56, 0.26), 0, 0.04);
		rs3_oval(s, ray, vec3(-0.06, -0.06, 0.14), vec3(0.40, 0.32, 0.05), vec3(0.34, 0.66, 0.64), 5, seed);
		rs3_oval_smooth(s, ray, vec3(0.18, 0.16, 0.04), vec3(0.44, 0.36, 0.08), vec3(0.40, 0.60, 0.28), 0, 0.04);
		rs3_oval(s, ray, vec3(0.20, 0.18, 0.09), vec3(0.32, 0.25, 0.04), vec3(0.38, 0.72, 0.68), 5, seed);
	} else if (sub_style == 3) {
		// Plantation Land: Terraced red-laterite slope with 3 neat perennial estate shrub rows
		rs3_oval_smooth(s, ray, vec3(0.0, 0.0, 0.05), vec3(0.58, 0.48, 0.09), vec3(0.62, 0.36, 0.22), 2, 0.04);
		for (int r = -1; r <= 1; r++) {
			float rx = float(r) * 0.22;
			rs3_bone_smooth(s, ray, vec3(rx, -0.32, 0.15), vec3(rx, 0.32, 0.15), vec2(0.085, 0.095), vec3(0.26, 0.54, 0.24), 2, 0.02);
		}
	} else {
		// Pasture: Lush green clover meadow mound + rustic wooden fence corner & wildflowers
		rs3_oval_smooth(s, ray, vec3(0.0, 0.04, 0.06), vec3(0.58, 0.48, 0.11), vec3(0.38, 0.60, 0.26), 2, 0.05);
		if (detailed) {
			vec3 wood = vec3(0.58, 0.42, 0.24);
			rs3_bone(s, ray, vec3(-0.34, -0.18, 0.06), vec3(-0.34, -0.18, 0.34), vec2(0.032), wood);
			rs3_bone(s, ray, vec3(0.18, -0.28, 0.06), vec3(0.18, -0.28, 0.34), vec2(0.032), wood);
			rs3_bone(s, ray, vec3(-0.34, -0.18, 0.26), vec3(0.18, -0.28, 0.26), vec2(0.022), wood * 1.08);
			rs3_bone(s, ray, vec3(-0.34, -0.18, 0.16), vec3(0.18, -0.28, 0.16), vec2(0.022), wood * 0.96);
			rs3_oval(s, ray, vec3(0.16, 0.16, 0.14), vec3(0.09, 0.08, 0.05), vec3(0.98, 0.88, 0.32), 8, seed);
		}
	}

	if (detailed && s.d < px * 1.5) {
		rs3_apply_organic_material(s, seed);
	}
	s.rim = 0.20;
	s.floor_col = vec3(0.14, 0.16, 0.11);
	s.floor_a = 0.0;
	return s;
}

RSurf rs3_tree(vec2 p, float seed, float px) {
	RSurf s = rs_empty();
	RsRay ray = rs3_ray(p, seed);
	vec3 bark = vec3(0.46, 0.42, 0.36);
	rs3_bone(s, ray, vec3(0.0, 0.0, 0.0), vec3(0.0, 0.0, 0.62), vec2(0.075), bark);
	rs3_bone(s, ray, vec3(0.02, 0.08, 0.36), vec3(0.08, 0.02, 0.20), vec2(0.028), vec3(0.98, 0.97, 0.92));
	rs3_oval(s, ray, vec3(0.09, 0.02, 0.16), vec3(0.055, 0.050, 0.055), vec3(0.82, 0.46, 0.28), 0, seed);
	for (int i = 0; i < 4; i++) {
		float angle = float(i) * 2.39996 + seed * 6.28318;
		vec3 center = vec3(cos(angle) * 0.21, sin(angle) * 0.21, 0.64 + float(i) * 0.06);
		vec3 crown_col = mix(vec3(0.18, 0.46, 0.24), vec3(0.32, 0.64, 0.34), float(i) * 0.28);
		rs3_oval_smooth(s, ray, center, vec3(0.30, 0.28, 0.27), crown_col, 2, 0.05);
	}
	if (visual_quality > 0 && v_rank.y >= detailed_pixels && s.d < px * 1.5) {
		rs3_apply_organic_material(s, seed);
	}
	s.rim = 0.26;
	s.floor_col = vec3(0.14, 0.18, 0.11);
	s.floor_a = exp(-pow(length((p - vec2(0.0, 0.28)) / vec2(0.52, 0.24)), 3.0)) * 0.22;
	return s;
}

RSurf rs3_deadwood(vec2 p, float seed, float px) {
	RSurf s = rs_empty();
	RsRay ray = rs3_ray(p, seed);
	vec3 bark = vec3(0.34, 0.23, 0.15);
	vec3 heartwood = vec3(0.88, 0.70, 0.38);

	rs3_bone(s, ray, vec3(-0.46, 0.14, 0.12), vec3(0.42, 0.06, 0.12), vec2(0.125), bark);
	rs3_oval(s, ray, vec3(0.43, 0.06, 0.12), vec3(0.028, 0.12, 0.12), heartwood, 3, seed);

	rs3_bone(s, ray, vec3(-0.38, -0.14, 0.10), vec3(0.36, -0.20, 0.10), vec2(0.11), bark * 0.88);
	rs3_oval(s, ray, vec3(0.37, -0.20, 0.10), vec3(0.026, 0.105, 0.105), heartwood * 0.94, 3, seed + 0.2);

	rs3_bone(s, ray, vec3(-0.34, 0.00, 0.28), vec3(0.32, -0.06, 0.28), vec2(0.11), bark * 1.05);
	rs3_oval(s, ray, vec3(0.33, -0.06, 0.28), vec3(0.026, 0.105, 0.105), heartwood * 1.06, 3, seed + 0.3);

	if (visual_quality > 0 && v_rank.y >= detailed_pixels && s.d < px * 1.5) {
		rs3_apply_organic_material(s, seed);
	}
	s.rim = 0.20;
	s.floor_col = vec3(0.16, 0.14, 0.10);
	s.floor_a = exp(-pow(length((p - vec2(0.0, 0.28)) / vec2(0.56, 0.24)), 3.0)) * 0.20;
	return s;
}
