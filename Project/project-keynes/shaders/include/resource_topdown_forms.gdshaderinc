// Top-down procedural resource forms (replaces the upright "sticker" look).
// The map is viewed straight down, so every resource is drawn as something that
// belongs on the ground: crop fields, herds, crowns, outcrops, ore piles.
// Requires resource_forms.gdshaderinc (RSurf, rs_* primitives, vf_* noise).
// Every function returns an RSurf whose `d` is the signed distance to the
// union of its parts (px-accurate silhouette) so the caller can add outlines
// and a silhouette-derived cast shadow.

float rt_fade(vec2 p) {
	return 1.0 - smoothstep(0.70, 0.96, length(p));
}

vec2 rt_jit(float i, float seed, float spread) {
	return (vf_hash22(vec2(i * 7.13 + seed * 31.7, i * 3.71 + seed * 11.3)) - 0.5) * 2.0 * spread;
}

float rt_h(float i, float seed) {
	return vf_hash12(vec2(i * 5.31 + seed * 17.9, seed * 3.3 + i));
}

float rt_field_d(vec2 q) {
	return rs_organic_patch_sdf(q * 0.62, 0.0) / 0.62;
}

// Rotated, bevel-shaded box (crystals, coal lumps, galena cubes, flint shards).
void rt_box(inout RSurf s, vec2 p, vec2 c, float ang, vec2 half_size, vec3 col, float h, float px) {
	vec2 q = rs_rot(ang) * (p - c);
	vec2 a = abs(q) - half_size;
	float d = length(max(a, vec2(0.0))) + min(max(a.x, a.y), 0.0);
	s.d = min(s.d, d);
	if (d < px && h >= s.h) {
		vec2 g = clamp(q / max(half_size, vec2(0.001)), vec2(-1.0), vec2(1.0));
		float edge = smoothstep(0.50, 1.0, max(abs(g.x), abs(g.y)));
		vec2 nxy = rs_rot(-ang) * (g * edge * 0.85);
		s.h = h;
		s.n = normalize(vec3(nxy, 0.78));
		s.albedo = col * (0.92 + 0.18 * (1.0 - edge));
		s.ao = 0.92;
	}
}

// Irregular boulder: world-space warp turns the dome ellipse into a rock.
void rt_boulder(inout RSurf s, vec2 p, vec2 c, vec2 r, vec3 col, float h, float seed, float px) {
	vec2 w = vec2(vf_vnoise(p * 5.0 + seed * 13.0), vf_vnoise(p * 5.0 + seed * 29.0 + 7.0)) - 0.5;
	rs_part(s, p + w * 0.15, c, r, col, h, px);
}

// ---------------------------------------------------------------- crops

// Small irregular tufts; only the recognition badge retains the old field picture.
RSurf rt_cereal(vec2 p, vec3 tint, float seed, float px, float motion, bool scenery) {
	RSurf s = rs_empty();
	vec2 q = rs_rot((seed - 0.5) * 1.6) * p;
	if (scenery) {
		for (int i = 0; i < 7; i++) {
			float fi = float(i);
			vec2 c = vec2(cos(fi * 2.4 + seed * 6.0), sin(fi * 2.4 + seed * 6.0))
				* 0.57 * sqrt((fi + 0.5) / 7.0) + rt_jit(fi, seed, 0.07);
			for (int j = 0; j < 4; j++) {
				float fj = float(j);
				float phase = seed * 21.0 + fi * 2.1 + fj * 0.6;
				float ang = fj * 1.65 + fi + sin(motion * 1.5 + phase) * 0.13;
				vec2 e = c + vec2(cos(ang), sin(ang)) * (0.12 + rt_h(fi * 4.0 + fj, seed) * 0.12);
				rs_stroke(s, q, c, e, 0.012, tint * 0.72, 0.10, px);
				rs_part(s, q, e, vec2(0.025, 0.045), tint * (0.9 + 0.18 * rt_h(fi + fj, seed)), 0.18, px);
			}
		}
		s.spec = 0.06;
		return s;
	}
	float d = rt_field_d(q) + (vf_vnoise(q * 6.0 + seed * 9.0) - 0.5) * 0.10;
	s.d = d;
	if (d < px * 1.5) {
		float row = q.x * 26.0 + sin(q.y * 3.5 + seed * 6.0) * 1.1;
		float rf = fract(row);
		float band = smoothstep(0.05, 0.40, rf) * (1.0 - smoothstep(0.60, 0.95, rf));
		float tex = vf_vnoise(q * vec2(50.0, 18.0) + seed * 5.0);
		s.albedo = mix(vec3(0.27, 0.21, 0.13), tint * (0.80 + tex * 0.32), band);
		s.h = 0.04 + band * 0.05;
		s.n = normalize(vec3((rf - 0.5) * 0.45 * band, 0.0, 1.0));
		s.spec = 0.06;
	}
	return s;
}

// Planted fields: maize(1) rice(2) potato/bast(3) cotton(4) flowers(5) mulberry+cocoons(15).
RSurf rt_crops(vec2 p, int form, int sub, vec3 tint, float seed, float px, float motion, bool scenery) {
	RSurf s = rs_empty();
	vec2 q = rs_rot((seed - 0.5) * 1.2) * p;
	float d = rt_field_d(q) + (vf_vnoise(q * 6.0 + seed * 9.0) - 0.5) * 0.10;
	s.d = d;
	float inner = smoothstep(0.0, 0.10, -d);
	vec3 base = mix(vec3(0.25, 0.19, 0.12), vec3(0.36, 0.28, 0.18), vf_vnoise(q * 14.0 + seed));
	float cells = 4.6;
	float rad = 0.32;
	float lobes = 5.0;
	if (form == 1) {
		cells = 4.0; rad = 0.44; lobes = 6.0;
	} else if (form == 2) {
		cells = 8.0; rad = 0.36; lobes = 5.0;
		base = mix(vec3(0.27, 0.41, 0.38), vec3(0.40, 0.55, 0.49), vf_vnoise(q * 9.0 + seed));
		s.spec = 0.7;
	} else if (form == 3) {
		cells = 4.2; rad = 0.44; lobes = 4.0;
	} else if (form == 4) {
		cells = 4.0; rad = 0.44; lobes = 7.0;
	} else if (form == 15) {
		cells = 4.2; rad = 0.44; lobes = 3.0;
	} else {
		cells = sub == 0 ? 11.0 : (sub == 1 ? 5.2 : (sub == 2 ? 7.0 : 4.6));
		rad = sub == 0 ? 0.34 : 0.42;
		lobes = sub == 3 ? 8.0 : 4.0;
		base = mix(vec3(0.20, 0.32, 0.16), vec3(0.30, 0.44, 0.22), vf_vnoise(q * 10.0 + seed));
	}
	cells *= scenery ? plant_cluster_density : 1.0;
	vec2 g = q * cells;
	vec2 id = floor(g);
	vec2 f = fract(g) - 0.5;
	float hh = vf_hash12(id + seed * 13.0);
	vec2 v = f - (vf_hash22(id + seed * 7.0) - 0.5) * 0.58;
	v -= vec2(sin(motion * 1.4 + hh * 17.0), cos(motion * 1.1 + hh * 13.0)) * 0.045;
	float r = length(v);
	float a = atan(v.y, v.x);
	float lobe_mod = 0.5 + 0.5 * cos(lobes * 0.5 * a + hh * 3.0 + sin(motion * 0.8 + hh * 6.0) * 0.08);
	float R = rad * (0.70 + 0.30 * lobe_mod);
	float d_crown = (r - R) / cells;
	bool present = form == 5 ? hh > 0.24 : hh > 0.18;
	if (scenery) {
		s.d = max(d, present ? d_crown : 10.0);
	}
	vec3 col = mix(vec3(0.32, 0.25, 0.16), base, inner);
	vec3 n = vec3(0.0, 0.0, 1.0);
	float h = 0.03;
	if (form == 2) {
		col = mix(col, base, inner);
		h = 0.02;
	}
	if (present) {
		float rn = r / max(R, 0.01);
		vec3 crown = tint * (0.78 + 0.32 * hh) * (0.82 + 0.22 * lobe_mod);
		if (form == 5 || form == 3) {
			crown = mix(vec3(0.20, 0.33, 0.16), vec3(0.34, 0.50, 0.24), hh) * (0.82 + 0.22 * lobe_mod);
		}
		if (form == 15) {
			crown = mix(vec3(0.30, 0.45, 0.20), vec3(0.44, 0.58, 0.28), hh) * (0.84 + 0.20 * lobe_mod);
		}
		crown = mix(crown * 0.68, crown, smoothstep(0.05, 0.40, rn));
		float cm = 1.0 - smoothstep(-px, px, d_crown);
		col = mix(col, crown, cm * inner);
		if (cm > 0.5) {
			h = 0.16 * (1.0 - rn) + 0.04;
			n = normalize(vec3(-v / max(R, 0.01) * 0.65, 1.0));
		}
		// blossoms / bolls / cocoons sit on top of the crowns
		if (form == 4) {
			for (int k = 0; k < 3; k++) {
				float ka = float(k) * 2.094 + hh * 6.28;
				vec2 bp = vec2(cos(ka), sin(ka)) * R * 0.46;
				float bm = 1.0 - smoothstep(0.055, 0.095, length(v - bp));
				col = mix(col, vec3(0.93, 0.92, 0.85), bm * cm * inner);
				h = mix(h, 0.24, bm * cm);
			}
		} else if (form == 5) {
			float bm = 0.0;
			vec3 bc = tint * (0.90 + 0.25 * hh);
			if (sub == 0) {
				bm = 1.0 - smoothstep(0.20, 0.30, length(v - vec2(0.05, -0.04)));
			} else if (sub == 1) {
				vec2 pv = rs_rot(hh * 6.28) * (v - vec2(0.0, 0.02));
				bm = 1.0 - smoothstep(0.85, 1.05, length(pv / vec2(0.40, 0.15)));
			} else if (sub == 2) {
				float b0 = length(v - vec2(0.12, 0.0));
				float b1 = length(v - vec2(-0.08, 0.11));
				float b2 = length(v - vec2(-0.06, -0.12));
				bm = 1.0 - smoothstep(0.12, 0.18, min(b0, min(b1, b2)));
			} else {
				float fr = length(v);
				bm = 1.0 - smoothstep(0.17, 0.23, fr);
				bc = mix(bc, vec3(0.95, 0.85, 0.40), 1.0 - smoothstep(0.03, 0.07, fr));
			}
			col = mix(col, bc, bm * inner);
			h = mix(h, 0.22, bm);
		} else if (form == 15) {
			vec2 cv = rs_rot(hh * 6.28) * (v - vec2(0.08, 0.02));
			float cm2 = 1.0 - smoothstep(0.85, 1.05, length(cv / vec2(0.17, 0.10)));
			col = mix(col, tint * (0.95 + 0.1 * hh), cm2 * inner);
			h = mix(h, 0.22, cm2);
		}
	}
	s.albedo = col;
	s.n = n;
	s.h = h;
	s.spec = form == 2 ? 0.55 : 0.10;
	s.ao = 0.94;
	s.floor_col = vec3(0.20, 0.16, 0.10);
	s.floor_a = scenery ? 0.0 : (1.0 - smoothstep(-0.02, 0.16, d)) * rt_fade(p) * 0.20;
	return s;
}

// ---------------------------------------------------------------- trees / reeds / logs

RSurf rt_tree(vec2 p, vec3 tint, float seed, float px) {
	RSurf s = rs_empty();
	for (int i = 0; i < 3; i++) {
		float fi = float(i);
		vec2 c = i == 0 ? vec2(-0.04, 0.04) : (i == 1 ? vec2(0.42, -0.32) : vec2(-0.42, -0.36));
		c += rt_jit(fi, seed, 0.05);
		float rr = i == 0 ? 0.50 : 0.32;
		if (length(p - c) > rr * 1.5 + 0.32) {
			continue;
		}
		for (int k = 0; k < 5; k++) {
			float ka = float(k) * 1.2566 + fi + seed * 6.0;
			vec2 lc = c + vec2(cos(ka), sin(ka)) * rr * 0.46;
			vec3 col = tint * (0.80 + 0.36 * rt_h(fi * 5.0 + float(k), seed));
			rs_part(s, p, lc, vec2(rr * 0.60), col, 0.30, px);
		}
		rs_part(s, p, c, vec2(rr * 0.66), tint * 1.04, 0.38, px);
	}
	if (s.d < px) {
		s.albedo *= 0.84 + 0.30 * vf_vnoise(p * 16.0 + seed * 9.0);
	}
	s.floor_col = vec3(0.07, 0.11, 0.06);
	s.floor_a = (1.0 - smoothstep(0.0, 0.18, s.d)) * rt_fade(p) * 0.26;
	return s;
}

RSurf rt_reed(vec2 p, vec3 tint, float seed, float px, float motion) {
	RSurf s = rs_empty();
	for (int i = 0; i < 3; i++) {
		float fi = float(i);
		vec2 c = (i == 0 ? vec2(-0.05, 0.05) : (i == 1 ? vec2(0.40, -0.26) : vec2(-0.38, -0.30))) + rt_jit(fi, seed, 0.05);
		if (length(p - c) > 0.74) {
			continue;
		}
		for (int k = 0; k < 7; k++) {
			float hk = rt_h(fi * 9.0 + float(k), seed);
			float ka = float(k) * 0.9 + hk * 0.6 + sin(motion * 0.8 + fi + float(k)) * 0.05;
			vec2 e = c + vec2(cos(ka), sin(ka)) * (0.30 + 0.12 * hk);
			rs_stroke(s, p, c, e, 0.024, tint * (0.80 + 0.35 * hk), 0.10 + 0.05 * hk, px);
			rs_part(s, p, e, vec2(0.034), mix(tint, vec3(0.62, 0.50, 0.34), 0.5) * (0.9 + 0.2 * hk), 0.16, px);
		}
	}
	s.floor_col = vec3(0.12, 0.17, 0.10);
	s.floor_a = (1.0 - smoothstep(0.0, 0.16, s.d)) * rt_fade(p) * 0.18;
	return s;
}

RSurf rt_timber(vec2 p, vec3 tint, float seed, float px) {
	RSurf s = rs_empty();
	for (int i = 0; i < 3; i++) {
		float fi = float(i);
		float ang = rt_h(fi, seed) * 1.2 - 0.6 + fi * 0.15;
		vec2 dir = vec2(cos(ang), sin(ang));
		vec2 c = vec2(-0.08 + fi * 0.04, 0.30 - fi * 0.30) + rt_jit(fi + 4.0, seed, 0.05);
		vec2 a = c - dir * 0.50;
		vec2 b = c + dir * 0.50;
		rs_stroke(s, p, a, b, 0.105, tint * (0.82 + 0.3 * rt_h(fi + 2.0, seed)), 0.20, px);
		rs_part(s, p, b, vec2(0.105), vec3(0.78, 0.62, 0.42), 0.23, px);
		rs_part(s, p, b, vec2(0.055), vec3(0.64, 0.47, 0.30), 0.24, px);
		rs_part(s, p, b, vec2(0.020), vec3(0.50, 0.36, 0.22), 0.25, px);
	}
	if (s.d < px) {
		float grain = vf_vnoise(p * vec2(34.0, 9.0) + seed * 5.0);
		s.albedo *= 0.86 + 0.26 * grain;
	}
	s.floor_col = vec3(0.30, 0.22, 0.13);
	s.floor_a = (1.0 - smoothstep(0.0, 0.16, s.d)) * rt_fade(p) * 0.22;
	return s;
}

// ---------------------------------------------------------------- animals (seen from above)

void rt_merge(inout RSurf s, RSurf a, float k, float ang, float px) {
	float dd = a.d * k;
	s.d = min(s.d, dd);
	if (dd < px && a.h > s.h) {
		s.h = a.h;
		s.albedo = a.albedo;
		s.ao = a.ao;
		s.spec = a.spec;
		s.rim = a.rim;
		s.n = normalize(vec3(rs_rot(ang) * a.n.xy, a.n.z));
	}
}

// Local frame: +x is the head direction, body ~0.4 long.
void rt_animal_local(inout RSurf a, vec2 q, int form, vec3 col, float hs, float pxk) {
	vec3 dark = col * 0.40;
	if (form == 8) { // horse
		rs_part(a, q, vec2(-0.02, 0.0), vec2(0.20, 0.085), col, 0.20, pxk);
		rs_part(a, q, vec2(-0.12, 0.0), vec2(0.10, 0.088), col * 1.05, 0.22, pxk);
		rs_part(a, q, vec2(0.20, 0.0), vec2(0.12, 0.046), col * 0.97, 0.18, pxk);
		rs_part(a, q, vec2(0.33, 0.01), vec2(0.075, 0.036), col * 0.93, 0.17, pxk);
		rs_stroke(a, q, vec2(0.12, 0.0), vec2(0.27, 0.005), 0.018, dark, 0.25, pxk);
		rs_stroke(a, q, vec2(-0.20, 0.0), vec2(-0.34, -0.045), 0.026, dark, 0.19, pxk);
	} else if (form == 9) { // sheep: scalloped fleece + dark head
		rs_part(a, q, vec2(-0.07, 0.04), vec2(0.095), col, 0.20, pxk);
		rs_part(a, q, vec2(0.04, -0.04), vec2(0.095), col * 0.97, 0.21, pxk);
		rs_part(a, q, vec2(-0.11, -0.05), vec2(0.085), col * 0.95, 0.20, pxk);
		rs_part(a, q, vec2(0.07, 0.05), vec2(0.088), col * 1.03, 0.22, pxk);
		rs_part(a, q, vec2(-0.01, 0.0), vec2(0.10), col * 1.02, 0.24, pxk);
		rs_part(a, q, vec2(0.17, 0.0), vec2(0.048, 0.042), vec3(0.26, 0.22, 0.19), 0.17, pxk);
	} else if (form == 10) { // goat
		rs_part(a, q, vec2(0.0, 0.0), vec2(0.15, 0.065), col, 0.17, pxk);
		rs_part(a, q, vec2(0.20, 0.0), vec2(0.056, 0.036), col * 0.92, 0.16, pxk);
		rs_stroke(a, q, vec2(0.21, 0.022), vec2(0.15, 0.085), 0.012, vec3(0.86, 0.82, 0.70), 0.22, pxk);
		rs_stroke(a, q, vec2(0.21, -0.022), vec2(0.15, -0.085), 0.012, vec3(0.86, 0.82, 0.70), 0.22, pxk);
		rs_stroke(a, q, vec2(-0.14, 0.0), vec2(-0.20, 0.02), 0.014, dark, 0.18, pxk);
	} else if (form == 11) { // cattle: broad body, piebald patches, pale horns
		rs_part(a, q, vec2(0.0, 0.0), vec2(0.22, 0.105), col, 0.22, pxk);
		rs_part(a, q, vec2(-0.12, 0.0), vec2(0.12, 0.10), col * 0.98, 0.23, pxk);
		rs_part(a, q, vec2(0.29, 0.0), vec2(0.07, 0.052), col * 0.94, 0.18, pxk);
		vec3 patch_col = vec3(0.15, 0.13, 0.12);
		rs_part(a, q, vec2(-0.04 + hs * 0.06, 0.035), vec2(0.075, 0.05), patch_col, 0.245, pxk);
		rs_part(a, q, vec2(0.09, -0.04), vec2(0.06, 0.045), patch_col, 0.245, pxk);
		rs_part(a, q, vec2(-0.16, -0.045 + hs * 0.05), vec2(0.065, 0.045), patch_col, 0.245, pxk);
		rs_stroke(a, q, vec2(0.30, 0.048), vec2(0.27, 0.105), 0.014, vec3(0.88, 0.84, 0.72), 0.22, pxk);
		rs_stroke(a, q, vec2(0.30, -0.048), vec2(0.27, -0.105), 0.014, vec3(0.88, 0.84, 0.72), 0.22, pxk);
		rs_stroke(a, q, vec2(-0.22, 0.0), vec2(-0.30, 0.03), 0.014, dark, 0.20, pxk);
	} else if (form == 12) { // pig
		rs_part(a, q, vec2(0.0, 0.0), vec2(0.17, 0.10), col, 0.20, pxk);
		rs_part(a, q, vec2(0.19, 0.0), vec2(0.066, 0.056), col * 0.97, 0.17, pxk);
		rs_part(a, q, vec2(0.255, 0.0), vec2(0.032, 0.028), col * 1.12, 0.17, pxk);
		rs_part(a, q, vec2(0.17, 0.055), vec2(0.03, 0.022), col * 0.82, 0.18, pxk);
		rs_part(a, q, vec2(0.17, -0.055), vec2(0.03, 0.022), col * 0.82, 0.18, pxk);
		rs_part(a, q, vec2(-0.18, 0.0), vec2(0.026), col * 0.80, 0.19, pxk);
	} else if (form == 13) { // camel: two humps + long neck
		rs_part(a, q, vec2(0.0, 0.0), vec2(0.20, 0.075), col, 0.17, pxk);
		rs_part(a, q, vec2(-0.05, 0.0), vec2(0.07, 0.07), col * 1.06, 0.30, pxk);
		rs_part(a, q, vec2(0.07, 0.0), vec2(0.065, 0.065), col * 1.04, 0.30, pxk);
		rs_stroke(a, q, vec2(0.17, 0.0), vec2(0.34, 0.02), 0.034, col * 0.96, 0.17, pxk);
		rs_part(a, q, vec2(0.39, 0.02), vec2(0.06, 0.035), col * 0.92, 0.17, pxk);
		rs_stroke(a, q, vec2(-0.19, 0.0), vec2(-0.26, 0.02), 0.014, dark, 0.17, pxk);
	} else { // 14 yak: shaggy skirt, hump, wide horns
		rs_part(a, q, vec2(0.0, 0.0), vec2(0.25, 0.14), col * 0.70, 0.15, pxk);
		rs_part(a, q, vec2(0.0, 0.0), vec2(0.20, 0.105), col, 0.22, pxk);
		rs_part(a, q, vec2(0.06, 0.0), vec2(0.08, 0.08), col * 0.92, 0.27, pxk);
		rs_part(a, q, vec2(0.27, 0.0), vec2(0.07, 0.06), col * 0.80, 0.18, pxk);
		rs_stroke(a, q, vec2(0.28, 0.05), vec2(0.31, 0.17), 0.016, vec3(0.82, 0.78, 0.66), 0.22, pxk);
		rs_stroke(a, q, vec2(0.28, -0.05), vec2(0.31, -0.17), 0.016, vec3(0.82, 0.78, 0.66), 0.22, pxk);
	}
}

RSurf rt_herd(vec2 p, int form, vec3 tint, float seed, float px, float motion) {
	RSurf s = rs_empty();
	int n = form == 9 ? 4 : ((form == 10 || form == 12) ? 3 : ((form == 13 || form == 8) ? 2 : 3));
	float k = form == 9 ? 1.05 : (form == 10 ? 1.10 : (form == 12 ? 1.25 : (form == 14 ? 1.35 : 1.50)));
	float spread = form == 9 ? 0.50 : 0.46;
	for (int i = 0; i < 5; i++) {
		if (i >= n) {
			break;
		}
		float fi = float(i);
		float ang = fi * 2.39996 + seed * 6.283;
		float rad = spread * sqrt((fi + 0.5) / float(n));
		vec2 c = vec2(cos(ang), sin(ang)) * rad + rt_jit(fi, seed, 0.04);
		// 连续的停走周期；每只动物的种子决定相位，暂停时不会跳回原点。
		float phase = motion * (0.52 + rt_h(fi + 12.0, seed) * 0.28) + seed * 17.0 + fi * 2.3;
		float cycle = floor(phase / 6.2832);
		float t = fract(phase / 6.2832);
		float progress = smoothstep(0.15, 0.68, t);
		float walk = smoothstep(0.15, 0.25, t) * (1.0 - smoothstep(0.58, 0.68, t));
		vec2 from = vec2(sin(cycle * 1.7), cos(cycle * 1.3));
		vec2 to = vec2(sin((cycle + 1.0) * 1.7), cos((cycle + 1.0) * 1.3));
		c += mix(from, to, progress) * 0.10;
		float heading = rt_h(fi, seed) * 6.2832 + 0.38 * sin(phase * 0.65);
		float breathe = sin(phase * 3.8) * 0.012;
		if (length(p - c) > 0.44 * k + 0.34) {
			continue;
		}
		vec3 col = tint * (0.86 + 0.28 * rt_h(fi + 9.0, seed));
		RSurf a = rs_empty();
		vec2 q = rs_rot(-heading) * (p - c) / k;
		q.y /= 1.0 + breathe;
		// 头颈低频转动；身体保持稳定，迈步只影响四肢。
		float head_w = smoothstep(0.10, 0.26, q.x);
		q.y += head_w * sin(phase * 1.7) * 0.028;
		for (int leg = 0; leg < 4; leg++) {
			float fl = float(leg);
			float side = leg % 2 == 0 ? -1.0 : 1.0;
			float hip = leg < 2 ? -0.11 : 0.12;
			float step_x = sin(phase * 5.5 + fl * 2.4) * 0.033 * walk;
			rs_stroke(a, q, vec2(hip, side * 0.05), vec2(hip + step_x, side * 0.115),
				0.012, col * 0.53, 0.08, px / k);
		}
		rt_animal_local(a, q, form, col, rt_h(fi + 3.0, seed), px / k);
		rt_merge(s, a, k, heading, px);
	}
	s.floor_col = vec3(0.20, 0.16, 0.10);
	s.floor_a = (1.0 - smoothstep(0.30, 0.92, length(p))) * 0.10;
	return s;
}

// ---------------------------------------------------------------- geology

void rt_outcrop(inout RSurf s, vec2 q, vec3 col, float seed, float px) {
	rt_boulder(s, q, vec2(-0.18, 0.10) + rt_jit(0.0, seed, 0.05), vec2(0.42, 0.34), col * (0.92 + 0.16 * rt_h(1.0, seed)), 0.32, seed, px);
	rt_boulder(s, q, vec2(0.32, -0.10) + rt_jit(1.0, seed, 0.05), vec2(0.34, 0.28), col * (0.90 + 0.18 * rt_h(2.0, seed)), 0.30, seed + 0.3, px);
	rt_boulder(s, q, vec2(-0.02, -0.38) + rt_jit(2.0, seed, 0.05), vec2(0.26, 0.20), col * (0.94 + 0.14 * rt_h(3.0, seed)), 0.26, seed + 0.6, px);
}

RSurf rt_coal(vec2 p, vec3 tint, float seed, float px) {
	RSurf s = rs_empty();
	for (int i = 0; i < 9; i++) {
		float fi = float(i);
		float ang = fi * 2.39996 + seed * 6.28;
		vec2 c = vec2(cos(ang), sin(ang)) * 0.60 * sqrt((fi + 0.5) / 9.0) + rt_jit(fi, seed, 0.04);
		vec2 hs = vec2(0.13 + 0.09 * rt_h(fi, seed), 0.10 + 0.07 * rt_h(fi + 4.0, seed));
		rt_box(s, p, c, rt_h(fi + 8.0, seed) * 3.14, hs, tint * (0.85 + 0.35 * rt_h(fi + 2.0, seed)), 0.18 + 0.16 * rt_h(fi + 6.0, seed), px);
	}
	s.spec = 0.62;
	s.metallic = 0.25;
	s.floor_col = vec3(0.05, 0.05, 0.05);
	s.floor_a = (1.0 - smoothstep(0.0, 0.16, s.d)) * rt_fade(p) * 0.28;
	return s;
}

RSurf rt_crystals(vec2 p, int sub, vec3 tint, float seed, float px, bool scenery) {
	RSurf s = rs_empty();
	vec2 q = rs_rot((seed - 0.5) * 2.0) * p;
	float dc = rt_field_d(q * 1.18 + vec2(0.0, 0.0)) / 1.18 + (vf_vnoise(q * 8.0 + seed * 5.0) - 0.5) * 0.10;
	vec3 crust = sub == 2 ? vec3(0.66, 0.58, 0.22) : (sub == 1 ? vec3(0.60, 0.62, 0.56) : vec3(0.78, 0.76, 0.70));
	s.d = scenery ? 10.0 : dc;
	if (!scenery && dc < px) {
		s.h = 0.04;
		s.albedo = crust * (0.90 + 0.18 * vf_vnoise(q * 18.0 + seed));
		s.n = vec3(0.0, 0.0, 1.0);
		s.ao = 0.95;
	}
	if (sub == 0) { // salt cubes
		for (int i = 0; i < 6; i++) {
			float fi = float(i);
			vec2 c = vec2(cos(fi * 2.1 + seed * 6.0), sin(fi * 2.1 + seed * 6.0)) * 0.42 * sqrt((fi + 0.5) / 6.0) + rt_jit(fi, seed, 0.05);
			float sz = 0.10 + 0.08 * rt_h(fi, seed);
			rt_box(s, q, c, rt_h(fi + 3.0, seed) * 1.5, vec2(sz), mix(tint, vec3(0.80, 0.86, 0.92), 0.25 * rt_h(fi, seed)), 0.18 + 0.14 * rt_h(fi + 1.0, seed), px);
		}
		s.spec = 0.75;
	} else if (sub == 1) { // saltpeter needle tufts
		for (int i = 0; i < 3; i++) {
			float fi = float(i);
			vec2 c = (i == 0 ? vec2(-0.05, 0.05) : (i == 1 ? vec2(0.38, -0.24) : vec2(-0.36, -0.28))) + rt_jit(fi, seed, 0.04);
			if (length(q - c) > 0.66) {
				continue;
			}
			for (int k = 0; k < 8; k++) {
				float hk = rt_h(fi * 11.0 + float(k), seed);
				float ka = float(k) * 0.785 + hk * 0.5;
				rs_stroke(s, q, c, c + vec2(cos(ka), sin(ka)) * (0.20 + 0.14 * hk), 0.016, tint * (0.88 + 0.2 * hk), 0.20, px);
			}
		}
		s.spec = 0.5;
	} else { // sulfur crust and bubbles
		for (int i = 0; i < 7; i++) {
			float fi = float(i);
			vec2 c = vec2(cos(fi * 2.4 + seed * 5.0), sin(fi * 2.4 + seed * 5.0)) * 0.46 * sqrt((fi + 0.5) / 7.0);
			float rr = 0.08 + 0.11 * rt_h(fi, seed);
			rs_part(s, q, c, vec2(rr), tint * (0.86 + 0.26 * rt_h(fi + 2.0, seed)), 0.22 + 0.10 * rt_h(fi, seed), px);
		}
		s.spec = 0.55;
	}
	s.floor_col = crust * 0.5;
	s.floor_a = (1.0 - smoothstep(0.0, 0.16, s.d)) * rt_fade(p) * 0.20;
	return s;
}

RSurf rt_geology_solid(vec2 p, int form, int sub, vec3 tint, float seed, float px, bool scenery) {
	if (form == 18) {
		return rt_crystals(p, sub, tint, seed, px, scenery);
	}
	if (form == 17 && sub == 0) {
		return rt_coal(p, tint, seed, px);
	}
	RSurf s = rs_empty();
	vec2 q = rs_rot((seed - 0.5) * 3.0) * p;
	bool ore = form == 17;
	vec3 host = ore ? mix(vec3(0.50, 0.48, 0.44), tint, 0.10) : tint;
	if (!ore && sub == 4) { // flint: glassy angular shards
		for (int i = 0; i < 5; i++) {
			float fi = float(i);
			vec2 c = vec2(cos(fi * 2.39996 + seed * 6.0), sin(fi * 2.39996 + seed * 6.0)) * 0.48 * sqrt((fi + 0.5) / 5.0);
			rt_box(s, q, c, rt_h(fi + 1.0, seed) * 3.14, vec2(0.24 + 0.10 * rt_h(fi, seed), 0.09 + 0.05 * rt_h(fi + 5.0, seed)), host * (0.85 + 0.3 * rt_h(fi + 3.0, seed)), 0.20 + 0.14 * rt_h(fi + 6.0, seed), px);
		}
		s.spec = 0.65;
	} else {
		rt_outcrop(s, q, host, seed, px);
	}
	if (s.d < px) {
		float n1 = vf_vnoise(q * 7.0 + seed * 3.0);
		float ridge = 1.0 - abs(2.0 * vf_vnoise(q * 5.5 + seed * 5.0 + 3.0) - 1.0);
		vec3 al = s.albedo * (0.84 + 0.30 * vf_vnoise(q * 11.0 + seed));
		float crack = 1.0 - smoothstep(0.0, 0.030, abs(vf_vnoise(q * 7.5 + seed * 2.0) - 0.5));
		al *= 1.0 - 0.28 * crack;
		float spec = 0.14;
		float metallic = 0.0;
		if (!ore) {
			if (sub == 0) { // stone: lichen flecks
				al = mix(al, vec3(0.34, 0.42, 0.24), smoothstep(0.74, 0.86, vf_vnoise(q * 18.0 + seed * 4.0)) * 0.45);
			} else if (sub == 1) { // bauxite: pisolitic pebbles
				vec2 gp = q * 15.0;
				vec2 gid = floor(gp);
				float peb = 1.0 - smoothstep(0.18, 0.34, length(fract(gp) - 0.5 - (vf_hash22(gid) - 0.5) * 0.4));
				al = mix(al, al * 1.30 + vec3(0.04), peb * 0.55);
			} else if (sub == 2) { // limestone: layered strata
				float strata = 0.5 + 0.5 * sin((q.y + n1 * 0.12) * 30.0);
				al = mix(al * 0.90, al * 1.08, smoothstep(0.35, 0.65, strata));
			} else if (sub == 3) { // phosphate: dark and pale granules
				float gr = vf_hash12(floor(q * 26.0 + seed * 9.0));
				al = mix(al, gr > 0.55 ? al * 1.22 : al * 0.70, 0.45);
			}
		} else if (sub == 1) { // copper: verdigris patina + ore specks
			al = mix(al, tint, smoothstep(0.50, 0.66, n1) * 0.85);
			al = mix(al, vec3(0.72, 0.40, 0.20), step(0.87, vf_hash12(floor(q * 22.0))) * 0.8);
		} else if (sub == 2) { // iron: banded rust
			float bands = smoothstep(0.35, 0.65, 0.5 + 0.5 * sin((q.x * 0.8 + q.y * 0.6 + n1 * 0.35) * 28.0));
			al = mix(al * 0.92, tint * 1.05, bands * 0.85);
			spec = 0.20;
		} else if (sub == 3) { // gold: glitter specks, nuggets below
			al = mix(al, tint, step(0.90, vf_hash12(floor(q * 24.0 + seed))) * 0.9);
			spec = 0.5;
			metallic = 0.7;
		} else if (sub == 4) { // silver: bright wire veins
			al = mix(al, tint, smoothstep(0.88, 0.95, ridge));
			spec = 0.6;
			metallic = 0.6;
		} else if (sub == 5) { // rare earth: warm crystal grains
			al = mix(al, tint * 1.1, step(0.80, vf_hash12(floor(q * 18.0 + seed * 3.0))) * 0.85);
			spec = 0.35;
		} else if (sub == 8) { // zinc: botryoidal bumps
			vec2 gp = q * 11.0;
			vec2 gid = floor(gp);
			float bump = 1.0 - smoothstep(0.22, 0.44, length(fract(gp) - 0.5 - (vf_hash22(gid) - 0.5) * 0.3));
			al = mix(al, tint * (0.9 + 0.3 * bump), 0.45 + bump * 0.4);
		} else if (sub == 9) { // manganese: dark dendrites on pale rock
			float dend = smoothstep(0.84, 0.92, ridge) + smoothstep(0.88, 0.95, 1.0 - abs(2.0 * vf_vnoise(q * 12.0 + seed * 7.0) - 1.0)) * 0.7;
			al = mix(al * 1.08, tint * 0.8, clamp(dend, 0.0, 1.0));
		}
		s.albedo = al;
		s.spec = max(s.spec, spec);
		s.metallic = metallic;
	}
	if (ore) {
		if (sub == 3) { // gold nuggets
			for (int i = 0; i < 6; i++) {
				float fi = float(i);
				vec2 c = vec2(cos(fi * 2.4 + seed * 6.0), sin(fi * 2.4 + seed * 6.0)) * 0.46 * sqrt((fi + 0.5) / 6.0);
				rs_part(s, q, c, vec2(0.05 + 0.03 * rt_h(fi, seed)), tint * (0.95 + 0.25 * rt_h(fi, seed)), 0.40, px);
			}
			s.spec = 0.7;
			s.metallic = 0.8;
		} else if (sub == 6) { // tin: dark cassiterite crystals
			for (int i = 0; i < 4; i++) {
				float fi = float(i);
				vec2 c = vec2(cos(fi * 2.4 + seed * 6.0), sin(fi * 2.4 + seed * 6.0)) * 0.38 * sqrt((fi + 0.5) / 4.0);
				rt_box(s, q, c, rt_h(fi, seed) * 3.14, vec2(0.12, 0.05 + 0.03 * rt_h(fi + 3.0, seed)), tint * 0.55 * (0.9 + 0.2 * rt_h(fi + 1.0, seed)), 0.42, px);
			}
			s.spec = 0.55;
		} else if (sub == 7) { // lead: steel-blue galena cubes
			for (int i = 0; i < 3; i++) {
				float fi = float(i);
				vec2 c = (i == 0 ? vec2(-0.10, 0.08) : (i == 1 ? vec2(0.22, -0.10) : vec2(-0.20, -0.26)));
				float sz = i == 0 ? 0.17 : 0.12;
				rt_box(s, q, c, 0.3 + fi * 0.5 + rt_h(fi, seed) * 0.4, vec2(sz), tint * (0.9 + 0.2 * rt_h(fi, seed)), 0.42, px);
			}
			s.spec = 0.7;
			s.metallic = 0.7;
		}
	}
	s.floor_col = vec3(0.12, 0.11, 0.09);
	s.floor_a = (1.0 - smoothstep(0.0, 0.16, s.d)) * rt_fade(p) * 0.22;
	return s;
}

// ---------------------------------------------------------------- dispatcher

RSurf rt_resource(vec2 p, int form, int family, int sub, vec3 tint, float seed, float px, float motion, bool scenery) {
	if (family == 1) {
		return rt_herd(p, form, tint, seed, px, motion);
	}
	if (form == 6) {
		return rt_tree(p, tint, seed, px);
	}
	if (form == 26) {
		return rt_timber(p, tint, seed, px);
	}
	if (form == 7) {
		return rt_reed(p, tint, seed, px, motion);
	}
	if (form == 0) {
		return rt_cereal(p, tint, seed, px, motion, scenery);
	}
	if (family == 0) {
		return rt_crops(p, form, sub, tint, seed, px, motion, scenery);
	}
	if (form == 16 || form == 17 || form == 18) {
		return rt_geology_solid(p, form, sub, tint, seed, px, scenery);
	}
	return rs_geology(p, form, sub, seed, px, motion);
}

// ---------------------------------------------------------------- lens badges

float rt_sd_hex(vec2 p, float r) {
	vec3 k = vec3(-0.866025404, 0.5, 0.577350269);
	p = abs(p);
	p -= 2.0 * min(dot(k.xy, p), 0.0) * k.xy;
	p -= vec2(clamp(p.x, -k.z * r, k.z * r), r);
	return length(p) * sign(p.y);
}

// Shape-coded backing: animals = circle, plants = rounded square, minerals = hexagon.
float rt_badge_sdf(vec2 p, int family) {
	if (family == 1) {
		return length(p) - 0.86;
	}
	if (family == 0) {
		vec2 a = abs(p) - vec2(0.64);
		return length(max(a, vec2(0.0))) + min(max(a.x, a.y), 0.0) - 0.22;
	}
	return rt_sd_hex(p, 0.80);
}

vec3 rt_badge_ring(int family) {
	if (family == 1) {
		return vec3(0.93, 0.64, 0.28);
	}
	if (family == 0) {
		return vec3(0.56, 0.78, 0.38);
	}
	return vec3(0.62, 0.72, 0.84);
}
