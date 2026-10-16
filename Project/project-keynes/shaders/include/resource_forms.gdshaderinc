// Ground micro-habitats, sedimentary/fluid geology, and shared SDF primitives.
// Paired with resource_solid_forms.gdshaderinc and ResourceVisualAtlas.
#include "res://shaders/include/vegetation_forms.gdshaderinc"

struct RSurf {
	float d;
	float h;
	vec3 n;
	vec3 albedo;
	float ao;
	float floor_a;
	vec3 floor_col;
	float depth;
	float spec;
	float metallic;
	vec3 spec_tint;
	float rim;
	vec3 hit_pos;
	int mat_id;
};

RSurf rs_empty() {
	RSurf s;
	s.d = 10.0;
	s.h = 0.0;
	s.n = vec3(0.0, 0.0, 1.0);
	s.albedo = vec3(0.5);
	s.ao = 1.0;
	s.floor_a = 0.0;
	s.floor_col = vec3(0.14, 0.16, 0.11);
	s.depth = -100.0;
	s.spec = 0.14;
	s.metallic = 0.0;
	s.spec_tint = vec3(1.0);
	s.rim = 0.18;
	s.hit_pos = vec3(0.0);
	s.mat_id = 0;
	return s;
}

float rs_smin(float a, float b, float k) {
	float h = clamp(0.5 + 0.5 * (b - a) / max(k, 0.0001), 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

mat2 rs_rot(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat2(vec2(c, s), vec2(-s, c));
}

float rs_sd_segment(vec2 p, vec2 a, vec2 b, out float t_out) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	t_out = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
	return length(pa - ba * t_out);
}

float rs_sd_capsule_taper(vec2 p, vec2 a, vec2 b, float ra, float rb, out float t_out) {
	float dist = rs_sd_segment(p, a, b, t_out);
	return dist - mix(ra, rb, t_out);
}

void rs_part(inout RSurf s, vec2 p, vec2 center, vec2 radius, vec3 color, float height, float px) {
	vec2 q = (p - center) / max(radius, vec2(0.001));
	float r = length(q);
	float d = (r - 1.0) * min(radius.x, radius.y);
	float z = height * sqrt(max(0.015, 1.0 - r * r));
	s.d = min(s.d, d);
	if (d < px && z >= s.h) {
		s.h = z;
		s.n = normalize(vec3(-q * height / max(radius, vec2(0.01)), max(0.24, sqrt(max(0.0, 1.0 - r * r)))));
		s.albedo = color;
		s.ao = mix(0.76, 1.0, s.n.z);
	}
}

void rs_stroke(inout RSurf s, vec2 p, vec2 a, vec2 b, float width, vec3 color, float height, float px) {
	float t;
	float dist = rs_sd_segment(p, a, b, t);
	float d = dist - width;
	s.d = min(s.d, d);
	if (d < px && height >= s.h) {
		vec2 q = p - mix(a, b, t);
		s.h = height;
		s.n = normalize(vec3(-q / max(width, 0.01) * 0.48, 0.86));
		s.albedo = color;
		s.ao = 0.92;
	}
}

void rs_blade(inout RSurf s, vec2 p, vec2 a, vec2 b, float width, vec3 color, float height, float px) {
	vec2 ab = b - a;
	float len = max(length(ab), 0.0001);
	vec2 dir = ab / len;
	vec2 perp = vec2(-dir.y, dir.x);
	float t = clamp(dot(p - a, dir) / len, 0.0, 1.0);
	float cross_axis = dot(p - a, perp);
	float w = width * pow(max(sin(t * 3.1415927), 0.0), 0.65);
	float d = max(abs(cross_axis) - w, max(-dot(p - a, dir), dot(p - b, dir)));
	s.d = min(s.d, d);
	float z = height * (0.62 + 0.38 * sin(t * 3.1415927));
	if (d < px && z >= s.h) {
		s.h = z;
		vec2 slope = perp * cross_axis / max(w, 0.012);
		s.n = normalize(vec3(-slope * 0.85, 0.82));
		s.albedo = color * (0.88 + 0.16 * (1.0 - smoothstep(0.0, max(w, 0.01), abs(cross_axis))));
		s.ao = 0.94;
	}
}

// Multi-lobed organic ground patch SDF that never looks like a circular sticker or touches quad borders
float rs_organic_patch_sdf(vec2 q, float seed) {
	float d1 = length((q - vec2(-0.08, 0.04)) * vec2(0.95, 1.22)) - 0.50;
	float d2 = length((q - vec2(0.24, -0.08)) * vec2(1.10, 1.30)) - 0.38;
	float d3 = length((q - vec2(-0.24, -0.14)) * vec2(1.15, 1.25)) - 0.35;
	return rs_smin(d1, rs_smin(d2, d3, 0.18), 0.18);
}

// Ground-hugging geological, fluid, trackway, and land-capacity forms:
// form 19 = clay, 20 = silica_sand, 21 = oil seep, 22 = land capacity, 23 = wild_game, 25 = natural_gas.
RSurf rs_geology(vec2 p, int form, int sub_style, float seed, float px, float motion) {
	RSurf s = rs_empty();
	float quad_fade = 1.0 - smoothstep(0.68, 0.94, length(p));
	float rot_angle = (seed - 0.5) * 0.55;
	vec2 q = rs_rot(rot_angle) * p;
	float n1 = vf_vnoise(q * 5.5 + seed * 37.0);

	// Form 21: Land Crude Oil Seep (Natural multi-lobe tar seep pool + branching fissures + iridescent oil sheen)
	if (form == 21) {
		float pool1 = length((q - vec2(-0.06, 0.04)) * vec2(1.0, 1.32)) - 0.44;
		float pool2 = length((q - vec2(0.22, -0.06)) * vec2(1.15, 1.40)) - 0.30;
		float t1;
		float crack1 = rs_sd_capsule_taper(q, vec2(-0.56, -0.12), vec2(0.56, 0.12 + sin(q.x * 5.0) * 0.06), 0.075, 0.035, t1);
		float t2;
		float crack2 = rs_sd_capsule_taper(q, vec2(-0.24, 0.36), vec2(0.28, -0.34), 0.055, 0.030, t2);
		float oil_d = rs_smin(rs_smin(pool1, pool2, 0.14), min(crack1, crack2), 0.10) + (n1 - 0.5) * 0.08;
		s.d = oil_d;

		if (oil_d < px * 1.5) {
			float n2 = vf_vnoise(q * 11.0 + seed * 73.0);
			float film_phase = length(q * 4.2) + n1 * 2.4 + sin(motion * 0.35 + seed * 6.0) * 0.15;
			vec3 film_col = vec3(
				0.06 + 0.08 * (0.5 + 0.5 * sin(film_phase * 6.283)),
				0.09 + 0.13 * (0.5 + 0.5 * sin(film_phase * 6.283 + 2.094)),
				0.12 + 0.15 * (0.5 + 0.5 * sin(film_phase * 6.283 + 4.188))
			);
			float film_mask = smoothstep(-0.03, -0.22, oil_d) * smoothstep(0.28, 0.72, n2);
			float b1 = abs(length(q - vec2(-0.10, 0.04)) - (0.08 + 0.025 * fract(motion * 0.25 + seed))) - 0.014;
			float bubble = 1.0 - smoothstep(-px, px, b1);

			s.albedo = mix(vec3(0.03, 0.028, 0.025), film_col, film_mask);
			s.albedo = mix(s.albedo, vec3(0.24, 0.20, 0.16), bubble * 0.65);
			vec2 rim_grad = normalize(q + vec2(0.001)) * smoothstep(-0.10, 0.0, oil_d) * 0.32;
			s.n = normalize(vec3(-rim_grad, 0.94));
			s.h = 0.05;
			s.spec = 0.94;
			s.metallic = 0.18;
			s.spec_tint = mix(vec3(0.95, 0.90, 0.82), film_col * 5.5, film_mask * 0.75);
			s.ao = 0.94;
		}
		s.floor_col = vec3(0.08, 0.07, 0.055);
		s.floor_a = (1.0 - smoothstep(-0.04, 0.18, oil_d)) * quad_fade * 0.42;
		return s;
	}

	// Form 25: Natural Gas Vent Field (3 mineralized fumarole craters + yellow sulfur rim + rising gas plumes)
	if (form == 25) {
		float d_field = 10.0;
		int winner = 0;
		vec2 win_vp = vec2(0.0);
		float win_vr = 0.25;

		for (int i = 0; i < 3; i++) {
			vec2 vc = i == 0 ? vec2(-0.06, 0.14) : (i == 1 ? vec2(0.24, 0.02) : vec2(-0.26, -0.06));
			float vr = i == 0 ? 0.28 : (i == 1 ? 0.20 : 0.18);
			vec2 vp = (p - vc) * vec2(1.0, 1.32);
			float r = length(vp);
			float mound_d = (r - vr) * 0.85 + (n1 - 0.5) * 0.04;
			if (mound_d < d_field) {
				d_field = mound_d;
				winner = i;
				win_vp = vp;
				win_vr = vr;
			}
		}
		vec2 plume_p = p - vec2(sin(p.y * 6.5 - motion * 1.4 + seed * 5.0) * 0.07, -0.14);
		float plume_d = max(abs(plume_p.x) - (0.18 + (0.28 - p.y) * 0.15), max(p.y - 0.18, -0.68 - p.y)) + (n1 - 0.5) * 0.12;
		bool in_plume = plume_d < d_field && plume_d < 0.0;
		s.d = min(d_field, plume_d);

		if (s.d < px * 1.5) {
			if (in_plume) {
				s.albedo = mix(vec3(0.64, 0.82, 0.86), vec3(0.88, 0.95, 0.98), n1);
				s.h = 0.42;
				s.n = normalize(vec3(-plume_p.x * 0.8, 0.2, 0.9));
				s.spec = 0.45;
			} else {
				float r = length(win_vp);
				float crater = smoothstep(win_vr * 0.40, win_vr * 0.16, r);
				float sulfur_rim = smoothstep(win_vr * 0.74, win_vr * 0.40, r) * (1.0 - crater);
				vec3 host = mix(vec3(0.42, 0.39, 0.34), vec3(0.58, 0.54, 0.46), n1);
				s.albedo = mix(mix(host, vec3(0.90, 0.82, 0.28), sulfur_rim * 0.80), vec3(0.10, 0.15, 0.18), crater * 0.90);
				s.h = (1.0 - r / max(win_vr, 0.01)) * 0.24 * (1.0 - crater * 0.7);
				vec2 g = (win_vp / max(win_vr, 0.01)) * (crater > 0.5 ? -0.65 : 0.65);
				s.n = normalize(vec3(-g, 0.78));
				s.spec = mix(0.24, 0.62, sulfur_rim);
			}
		}
		s.floor_col = vec3(0.24, 0.22, 0.18);
		s.floor_a = (1.0 - smoothstep(-0.02, 0.20, d_field)) * quad_fade * 0.36;
		return s;
	}

	// Form 19: Clay Deposit (Multi-lobed terraced terracotta clay banks + rainwater clay pit)
	if (form == 19) {
		float outer_d = rs_organic_patch_sdf(q, seed) + (n1 - 0.5) * 0.08;
		s.d = outer_d;
		if (outer_d < px * 1.5) {
			float depth_in = clamp(-outer_d / 0.48, 0.0, 1.0);
			float terrace = floor(depth_in * 3.2) / 3.2;
			float riser = smoothstep(0.0, 0.20, fract(depth_in * 3.2)) * (1.0 - smoothstep(0.20, 0.42, fract(depth_in * 3.2)));
			bool in_pool = depth_in > 0.66;
			if (in_pool) {
				s.albedo = mix(vec3(0.28, 0.48, 0.46), vec3(0.48, 0.34, 0.24), smoothstep(0.88, 0.66, depth_in));
				s.n = vec3(0.0, 0.0, 1.0);
				s.h = 0.05;
				s.spec = 0.86;
			} else {
				vec3 terracotta = mix(vec3(0.68, 0.37, 0.23), vec3(0.84, 0.52, 0.34), terrace);
				float crack = pow(abs(sin(q.x * 13.0 + sin(q.y * 9.0))), 18.0);
				s.albedo = terracotta * (1.0 - crack * 0.18) * (0.92 + 0.14 * n1);
				s.n = normalize(vec3(-normalize(q + vec2(0.001)) * (0.28 + riser * 0.55), 0.80));
				s.h = 0.08 + terrace * 0.24;
				s.spec = 0.44;
			}
		}
		s.floor_col = vec3(0.38, 0.22, 0.14);
		s.floor_a = (1.0 - smoothstep(-0.02, 0.18, outer_d)) * quad_fade * 0.38;
		return s;
	}

	// Form 20: Silica Sand Dunes (Double barchan crescent quartz dunes + sharp slipface crest + micro-glitter)
	if (form == 20) {
		float outer_d = rs_organic_patch_sdf(q, seed) + (n1 - 0.5) * 0.06;
		s.d = outer_d;
		if (outer_d < px * 1.5) {
			float crest_x = sin(q.y * 3.8 + seed * 4.0) * 0.14 - 0.03;
			float side = q.x - crest_x;
			float dist_crest = abs(side);
			float h = clamp(-outer_d * 0.85, 0.0, 0.38) * (1.0 - dist_crest * 0.55);
			float ripples = sin((q.y * 24.0 + q.x * 8.0) + sin(q.x * 6.0) * 1.5);
			float ripple_mask = side < 0.0 ? 1.0 : 0.25;
			vec2 slope = vec2(side < 0.0 ? -0.48 : 0.68, cos(q.y * 3.8 + seed * 4.0) * 0.22 + ripples * 0.08 * ripple_mask);

			vec3 sand_light = vec3(0.94, 0.86, 0.66);
			vec3 sand_shadow = vec3(0.76, 0.66, 0.46);
			s.albedo = mix(sand_light, sand_shadow, smoothstep(-0.03, 0.05, side) * 0.46) * (0.95 + 0.05 * ripples * ripple_mask);
			s.albedo = mix(s.albedo, vec3(0.99, 0.95, 0.82), exp(-dist_crest * 18.0) * 0.38);

			float glitter = step(0.80, vf_hash12(floor(q * 28.0 + seed * 19.0)));
			s.n = normalize(vec3(-slope, 0.78));
			s.h = max(h, 0.04);
			s.spec = 0.42 + glitter * 0.52;
			s.spec_tint = vec3(1.0, 0.96, 0.85);
		}
		s.floor_col = vec3(0.54, 0.46, 0.32);
		s.floor_a = (1.0 - smoothstep(-0.02, 0.18, outer_d)) * quad_fade * 0.36;
		return s;
	}

	// Form 23: Wild Game Trail & Sanctuary (Shed ivory antler + grazed bush tufts + cloven-hoof track chain)
	if (form == 23) {
		float base_d = rs_organic_patch_sdf(q, seed) + (n1 - 0.5) * 0.08;
		float hoof_d = 10.0;
		for (int i = 0; i < 3; i++) {
			float fi = float(i) - 1.0;
			vec2 hc = vec2(fi * 0.28, sin(fi * 1.3) * 0.12 + (i % 2 == 0 ? -0.06 : 0.06));
			vec2 hp = rs_rot(-0.35) * (q - hc);
			float lobe_l = length((hp - vec2(0.0, -0.038)) / vec2(0.095, 0.032)) - 1.0;
			float lobe_r = length((hp - vec2(0.0, 0.038)) / vec2(0.095, 0.032)) - 1.0;
			hoof_d = min(hoof_d, min(lobe_l, lobe_r) * 0.045);
		}
		float t_a;
		float beam = rs_sd_capsule_taper(q, vec2(-0.22, -0.18), vec2(0.24, -0.24), 0.032, 0.022, t_a);
		float tine1 = rs_sd_capsule_taper(q, vec2(-0.06, -0.20), vec2(-0.01, -0.38), 0.024, 0.012, t_a);
		float tine2 = rs_sd_capsule_taper(q, vec2(0.08, -0.22), vec2(0.15, -0.40), 0.024, 0.012, t_a);
		float antler_d = rs_smin(beam, min(tine1, tine2), 0.022);
		float shrub_d = min(length(q - vec2(-0.28, 0.18)) - 0.17, length(q - vec2(0.26, 0.16)) - 0.15);

		s.d = min(min(hoof_d, antler_d), min(shrub_d, base_d));
		if (s.d < px * 1.5) {
			if (antler_d < px * 0.8) {
				s.albedo = vec3(0.90, 0.85, 0.72);
				s.h = 0.18;
				s.n = normalize(vec3(0.1, -0.35, 0.92));
				s.spec = 0.38;
			} else if (shrub_d < px * 0.8) {
				s.albedo = mix(vec3(0.26, 0.44, 0.20), vec3(0.42, 0.56, 0.26), n1);
				s.h = 0.18;
				s.n = normalize(vec3(-(q - vec2(0.0, 0.18)) * 0.9, 0.82));
				s.spec = 0.18;
			} else if (hoof_d < px * 0.8) {
				s.albedo = vec3(0.18, 0.14, 0.09);
				s.h = 0.01;
				s.n = vec3(0.0, 0.0, 1.0);
				s.spec = 0.28;
				s.ao = 0.65;
			} else {
				float trail = exp(-pow(q.y * 2.8, 2.0));
				s.albedo = mix(vec3(0.32, 0.40, 0.22), vec3(0.50, 0.40, 0.26), trail) * (0.90 + 0.16 * n1);
				s.h = 0.04;
				s.n = normalize(vec3(0.0, -q.y * 0.25, 0.96));
			}
		}
		s.floor_col = vec3(0.20, 0.16, 0.11);
		s.floor_a = (1.0 - smoothstep(-0.04, 0.18, base_d)) * quad_fade * 0.36;
		return s;
	}

	// Form 22: Land Capacity Micro-Landscapes (Organic multi-lobed terrain patches with 3D micro-features)
	// sub_style: 0=fertile_soil, 1=arable_land, 2=paddy_land, 3=plantation_land, 4=pasture
	if (form == 22) {
		float d = rs_organic_patch_sdf(q, seed) + (n1 - 0.5) * 0.10;
		s.d = d;
		if (d < px * 1.5) {
			s.h = 0.07;
			s.spec = 0.16;
			s.ao = 0.92;
			if (sub_style == 0) {
				// Fertile Soil: Rich dark chernozem humus mounds + vibrant green cotyledon sprouts
				float crumb = 0.5 + 0.5 * sin(q.x * 16.0 + n1 * 3.0) * cos(q.y * 16.0);
				vec3 humus = mix(vec3(0.20, 0.15, 0.10), vec3(0.35, 0.27, 0.18), crumb);
				float sprout = max(
					1.0 - smoothstep(0.04, 0.09, length(q - vec2(-0.12, 0.04))),
					max(1.0 - smoothstep(0.04, 0.09, length(q - vec2(0.14, -0.06))),
						1.0 - smoothstep(0.04, 0.08, length(q - vec2(0.02, 0.16))))
				);
				s.albedo = mix(humus, vec3(0.42, 0.68, 0.26), sprout * 0.88);
				s.h = mix(0.06, 0.14, sprout);
				s.n = normalize(vec3((crumb - 0.5) * 0.35, -0.22, 0.92));
				s.spec = 0.24;
			} else if (sub_style == 1) {
				// Arable Land: Curved contour-plowed golden-loam ridge terraces
				float wave = q.y + sin(q.x * 3.2) * 0.10;
				float furrow = 0.5 + 0.5 * sin(wave * 26.0);
				s.albedo = mix(vec3(0.42, 0.32, 0.20), vec3(0.66, 0.54, 0.34), furrow) * (0.92 + 0.12 * n1);
				s.h = 0.05 + furrow * 0.06;
				s.n = normalize(vec3(0.0, cos(wave * 26.0) * 0.45, 0.89));
			} else if (sub_style == 2) {
				// Paddy Land: Stepped crescent water-mirror rice terraces with green earth bunds
				float r_step = length(q * vec2(0.9, 1.2) + vec2(0.15, 0.10)) * 5.2 + n1 * 0.6;
				float bund = smoothstep(0.32, 0.46, abs(fract(r_step) - 0.5));
				vec3 water_col = mix(vec3(0.30, 0.52, 0.48), vec3(0.48, 0.66, 0.56), n1);
				vec3 bund_col = vec3(0.38, 0.56, 0.28);
				s.albedo = mix(water_col, bund_col, bund);
				s.spec = mix(0.82, 0.18, bund);
				s.h = mix(0.04, 0.11, bund);
				s.n = normalize(vec3(0.0, -bund * 0.35, 0.94));
			} else if (sub_style == 3) {
				// Plantation Land: Reddish laterite estate rows with neat perennial shrub crowns
				float row_w = 0.5 + 0.5 * sin(q.x * 20.0);
				float bush = smoothstep(0.45, 0.75, row_w) * (0.5 + 0.5 * cos(q.y * 20.0));
				s.albedo = mix(vec3(0.56, 0.34, 0.22), vec3(0.28, 0.54, 0.24), smoothstep(0.25, 0.55, bush)) * (0.92 + 0.12 * n1);
				s.h = 0.05 + bush * 0.08;
				s.n = normalize(vec3(sin(q.x * 20.0) * 0.35, 0.0, 0.93));
			} else {
				// Pasture: Lush rolling clover meadow with wildflowers
				vec3 turf = mix(vec3(0.34, 0.54, 0.25), vec3(0.48, 0.66, 0.32), n1);
				vec2 fcell = fract(q * 9.0 + seed * 7.0) - 0.5;
				float flower = step(0.76, vf_hash12(floor(q * 9.0 + seed * 7.0))) * (1.0 - smoothstep(0.12, 0.28, length(fcell)));
				s.albedo = mix(turf, vec3(0.96, 0.90, 0.52), flower * 0.85);
				s.n = normalize(vec3((n1 - 0.5) * 0.28, -0.18, 0.94));
			}
		}
		s.floor_col = s.albedo * 0.52;
		s.floor_a = (1.0 - smoothstep(-0.04, 0.18, d)) * quad_fade * 0.30;
		return s;
	}

	return s;
}
