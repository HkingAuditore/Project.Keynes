// Ground decals and submerged cues for ResourceVisualLayer (MultiMesh path).
// Requires resource_forms.gdshaderinc (rs_rot, vf_* noise).
//
// These are deliberately NOT objects: no outline, no cast shadow, soft noise
// edges. They tint the ground (soil, bare deposit scar, tar stain) or show a
// faint cue seen through water (shoals, seabed seeps, gas bubbles). Exact
// identification is the lens badge's job, never theirs.
// Every function returns rgb + coverage alpha in [0, 1] before global opacity.

float rd_fbm(vec2 p) {
	return vf_vnoise(p) * 0.55 + vf_vnoise(p * 2.03 + 11.7) * 0.30 + vf_vnoise(p * 4.11 + 3.1) * 0.15;
}

// Warped, broken-up blob that fades to zero well before the quad border.
float rd_patch_mask(vec2 p, vec2 q, float seed, float reach, float softness) {
	vec2 w = vec2(rd_fbm(q * 2.2 + seed * 17.0), rd_fbm(q * 2.2 + seed * 29.0 + 5.3)) - 0.5;
	float r = length((q + w * 0.55) * vec2(1.0, 1.22));
	float m = 1.0 - smoothstep(reach - softness, reach, r);
	m *= mix(0.45, 1.0, rd_fbm(q * 3.4 + seed * 7.0));
	return m * (1.0 - smoothstep(0.80, 1.0, length(p)));
}

// form: clay=19, sand=20, soil=22 (sub: fertile/arable/paddy/plantation/pasture),
// tracks=23, seep=21, gas=25, rock/vein/crystal=16/17/18 (bare scar under pebbles).
vec4 rd_ground_decal(vec2 p, int form, int sub, vec3 tint, float seed) {
	vec2 q = rs_rot(seed * 6.2832) * p;
	float grain = rd_fbm(q * 9.0 + seed * 3.0);
	float speck = vf_hash12(floor(q * 26.0 + seed * 13.0));
	vec3 col = tint;
	float reach = 0.92;
	float soft = 0.55;
	float strength = 1.0;
	if (form == 22) {
		// 无人工田垄；以不规则的苔草/短草斑表达地力。
		vec3 grass = mix(vec3(0.29, 0.39, 0.17), vec3(0.43, 0.52, 0.24), grain);
		float dry = clamp((0.38 - v_climate.g) * 1.8 + (1.0 - v_climate.a) * 0.8, 0.0, 1.0);
		col = mix(grass, vec3(0.49, 0.43, 0.25), dry);
		if (sub == 1) { // arable capacity: natural soil variation, never ploughed furrows
			col *= 0.90 + 0.16 * grain;
		} else if (sub == 2) { // paddy: wet, cooler, a little darker
			col = mix(col, vec3(0.30, 0.40, 0.38), 0.35) * (0.92 + 0.10 * grain);
		} else if (sub == 4) { // pasture: short bright sward, very light touch
			col *= 0.92 + 0.16 * grain;
			strength = 0.7;
		} else {
			col *= 0.86 + 0.24 * grain;
		}
	} else if (form == 19) { // clay: reddish damp earth
		col *= 0.88 + 0.22 * grain;
	} else if (form == 20) { // sand: pale grains
		col = mix(col, col * 1.10, step(0.7, speck)) * (0.92 + 0.12 * grain);
		strength = 0.8;
	} else if (form == 23) { // wild game: trampled trails, not a blob
		float trail = 1.0 - smoothstep(0.0, 0.07, abs(rd_fbm(q * 2.6 + seed) - 0.5));
		col = mix(vec3(0.42, 0.36, 0.25), tint, 0.4);
		strength = trail * 0.8;
		reach = 0.95;
		soft = 0.35;
	} else if (form == 21) { // oil on land: dark tar stain
		col = mix(vec3(0.10, 0.09, 0.08), tint, 0.3) * (0.85 + 0.25 * grain);
		reach = 0.60;
		soft = 0.40;
	} else if (form == 25) { // gas on land: bleached, cracked ground
		float crack = 1.0 - smoothstep(0.0, 0.035, abs(vf_vnoise(q * 7.0 + seed * 4.0) - 0.5));
		col = mix(vec3(0.62, 0.62, 0.56), tint, 0.25) * (1.0 - crack * 0.25);
		reach = 0.70;
		soft = 0.40;
		strength = 0.75;
	} else { // deposit scar: bare earth + gravel, only a hint of the mineral
		vec3 bare = vec3(0.47, 0.42, 0.34);
		col = mix(bare, tint, form == 18 ? 0.35 : 0.18);
		col *= 0.84 + 0.26 * grain;
		col = mix(col, col * 0.72, step(0.82, speck));
		col = mix(col, col * 1.18, step(0.93, speck));
		reach = 0.66;
		soft = 0.42;
	}
	// 细碎露土/矿砂保留地貌纹理，不能再画成一整块替换地表的底盘。
	float broken = smoothstep(0.43, 0.72, rd_fbm(q * 11.0 + seed * 23.0));
	float m = rd_patch_mask(p, q, seed, reach, soft) * strength;
	if (form == 16 || form == 17 || form == 18) {
		m *= broken * 0.55;
	} else if (form == 22) {
		m *= mix(0.22, 0.90, broken);
	} else if (form == 19 || form == 20) {
		m *= mix(0.12, 0.52, broken);
	}
	return vec4(col, clamp(m, 0.0, 1.0));
}

// Seen through the water surface. family 3 = fish shoal; form 21 = seabed oil
// seep; form 25 = cold gas vent with rising bubbles.
vec4 rd_submerged(vec2 p, int form, int family, int sub, float seed, float motion) {
	float edge = 1.0 - smoothstep(0.78, 1.0, length(p));
	if (family == 3) {
		vec3 fish_col = sub == 0 ? vec3(0.72, 0.86, 0.90) : vec3(0.74, 0.88, 0.80);
		float heading = seed * 6.2832;
		vec2 dir = vec2(cos(heading), sin(heading));
		float m = 0.0;
		for (int i = 0; i < 5; i++) {
			float fi = float(i);
			vec2 c = (vf_hash22(vec2(fi * 3.7 + 1.3, seed * 19.0)) - 0.5) * 0.95;
			c += dir * sin(motion * 0.25 + fi * 1.7) * 0.06;
			vec2 fp = rs_rot(-heading) * (p - c);
			fp.y += sin(fp.x * 18.0 + motion * 2.0 + fi) * 0.012;
			float body = length(fp / vec2(0.11, 0.035));
			m = max(m, 1.0 - smoothstep(0.75, 1.05, body));
		}
		float shimmer = (1.0 - smoothstep(0.2, 0.85, length(p))) * 0.10;
		return vec4(fish_col, clamp(max(m * 0.85, shimmer), 0.0, 1.0) * edge);
	}
	vec2 q = rs_rot(seed * 6.2832) * p * 1.25;
	vec2 rq = q;
	rq.y += (rq.x * rq.x - 0.12) * (seed - 0.5) * 0.4;
	float d_rift = min(length(rq * vec2(0.82, 2.3)) - 0.32,
		length((rs_rot(0.7) * (q - vec2(0.10, -0.05))) * vec2(1.1, 2.8)) - 0.20);
	float core = 1.0 - smoothstep(-0.04, 0.10, d_rift);
	float halo = 1.0 - smoothstep(0.0, 0.32, d_rift);
	if (form == 21) {
		// Seen through water a seep is a diffuse smudge, never a crisp capsule.
		float smudge = 1.0 - smoothstep(-0.10, 0.45, d_rift + (rd_fbm(q * 3.0 + seed * 9.0) - 0.5) * 0.35);
		smudge *= mix(0.55, 1.0, rd_fbm(q * 5.5 + seed * 4.0));
		vec3 col = mix(vec3(0.10, 0.16, 0.18), vec3(0.04, 0.06, 0.07), smudge);
		return vec4(col, clamp(smudge * 0.45, 0.0, 1.0) * edge);
	}
	float a = core * 0.30 + halo * 0.08;
	vec3 col = vec3(0.06, 0.12, 0.14);
	for (int b = 0; b < 3; b++) {
		float fb = float(b);
		float phase = fract(motion * 0.20 + fb * 0.33 + seed);
		vec2 bpos = vec2((fb - 1.0) * 0.14, mix(-0.10, 0.45, phase));
		float rad = mix(0.04, 0.08, phase);
		float ring = 1.0 - smoothstep(0.0, 0.018, abs(length(p - bpos) - rad));
		ring *= smoothstep(0.0, 0.15, phase) * (1.0 - phase);
		col = mix(col, vec3(0.80, 0.92, 0.96), ring);
		a = max(a, ring * 0.8);
	}
	return vec4(col, clamp(a, 0.0, 1.0) * edge);
}
