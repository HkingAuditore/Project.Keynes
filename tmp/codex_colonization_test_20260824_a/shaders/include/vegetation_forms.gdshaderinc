// vegetation_forms.gdshaderinc
// Top-down procedural impostors for every vegetation / decoration form.
//
// One instance is one quad; p is its local coordinate in [-1, 1]^2 (same
// orientation as the instance transform, +z toward the camera). A form returns
// the surface seen from straight above: coverage, height, normal, material
// mix and an optional ground darkening for the gaps between its elements.
// Forms that carry several elements (crowns, tussocks, stones) evaluate a
// small jittered element field and keep the highest surface, so a grove of
// fifteen crowns costs one 3x3 neighbourhood walk instead of fifteen draws.
// `cheap` returns after coverage and height; the caller uses that second
// evaluation, offset toward the sun, for crown-on-crown and ground shadows.

#ifndef PK_VEGETATION_FORMS_INC
#define PK_VEGETATION_FORMS_INC

const int VF_BROADLEAF = 0;
const int VF_CONIFER = 1;
const int VF_PALM = 2;
const int VF_SHRUB = 3;
const int VF_CACTUS = 4;
const int VF_REED = 5;
const int VF_GRASS = 6;
const int VF_LICHEN = 7;
const int VF_FLOWER = 8;
const int VF_ROCK = 9;
const int VF_SCREE = 10;
const int VF_SNOW_MOUND = 11;
const int VF_SNAG = 12;
const int VF_FALLEN_LOG = 13;
const int VF_MANGROVE = 14;
const int VF_KELP = 15;
const int VF_CORAL = 16;
const int VF_PEAT_TUFT = 17;

const float VF_TAU = 6.2831853;
const float VF_PI = 3.1415927;

struct VegCtx {
	float seed;
	float count;     // elements carried by the instance (1..32)
	float sub_form;  // 0 single, 1 cluster, 2 grove
	float leaf;      // foliage amount: deciduous crowns thin to bare branches
	float vigor;     // structural presence: dieback removes whole elements
	float bloom;     // 0..1 flowering
	vec2 wind;       // unit prevailing wind in the local frame
	float time;
	float px;        // local units per screen pixel
};

struct VegSurf {
	float cov;       // coverage 0..1, antialiased
	float h;         // surface height 0..1
	vec3 n;          // local-frame normal
	float ao;        // cavity / inter-element occlusion
	float tone;      // albedo multiplier
	float leaf_w;    // 1 = climate foliage palette, 0 = tint
	vec3 tint;       // bark, stone, petal, snow...
	float elem;      // per-element hash for colour variety
	float floor_a;   // ground darkening alpha where cov is 0
	float snow_hold; // how readily snow settles on this surface
};

VegSurf vf_empty() {
	VegSurf s;
	s.cov = 0.0;
	s.h = 0.0;
	s.n = vec3(0.0, 0.0, 1.0);
	s.ao = 1.0;
	s.tone = 1.0;
	s.leaf_w = 1.0;
	s.tint = vec3(0.5);
	s.elem = 0.0;
	s.floor_a = 0.0;
	s.snow_hold = 1.0;
	return s;
}

float vf_hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 vf_hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

vec4 vf_hash42(vec2 p) {
	vec4 p4 = fract(vec4(p.xyxy) * vec4(0.1031, 0.1030, 0.0973, 0.1099));
	p4 += dot(p4, p4.wzxy + 33.33);
	return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}

float vf_vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = vf_hash12(i);
	float b = vf_hash12(i + vec2(1.0, 0.0));
	float c = vf_hash12(i + vec2(0.0, 1.0));
	float d = vf_hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fades a pattern of the given frequency (cycles per local unit) once it
// drops below a few pixels, so distant forms stay calm instead of aliasing.
float vf_detail(float freq, float px) {
	return 1.0 - smoothstep(0.16, 0.50, freq * px);
}

// Coverage of a signed distance (negative inside), one pixel wide.
float vf_cov(float d, float px) {
	return 1.0 - smoothstep(-px, px, d);
}

vec2 vf_seed_offset(float seed) {
	return vec2(seed * 97.31 + 3.1, seed * 53.17 + 7.9);
}

// Crown radius in local units. Must match ShrubLayer.crown_local_radius() and
// the native scatter, which size the instance so a crown keeps its world size.
float vf_elem_radius(float count) {
	return count < 1.5 ? 0.80 : min(0.58, 0.88 / sqrt(count));
}

float vf_height_scale(int form) {
	if (form == VF_BROADLEAF || form == VF_CONIFER || form == VF_PALM || form == VF_SNAG) {
		return 0.42;
	}
	if (form == VF_SHRUB || form == VF_CACTUS || form == VF_MANGROVE || form == VF_ROCK) {
		return 0.24;
	}
	if (form == VF_REED || form == VF_SNOW_MOUND || form == VF_FALLEN_LOG || form == VF_SCREE) {
		return 0.14;
	}
	return 0.08;
}

struct VfElem {
	vec2 c;
	float r;
	float id;
	float z;
	float hit;
	float edge;  // union signed distance, negative inside any element
	int k;
};

void vf_consider(inout VfElem e, inout float near_edge, vec2 p, vec2 c, float rr,
		float id, float top, float lob, int k, bool cone) {
	float d = length(p - c) - rr * lob;
	float sd = d - rr;
	e.edge = min(e.edge, sd);
	if (sd < 0.0) {
		float t = clamp(d / rr, 0.0, 1.0);
		float z = top * (cone ? (1.0 - t) : sqrt(1.0 - t * t));
		if (z > e.z) {
			e.z = z;
			e.c = c;
			e.r = rr;
			e.id = id;
			e.hit = 1.0;
			e.k = k;
		}
	} else if (e.hit < 0.5 && sd < near_edge) {
		// Remember the nearest element so antialiased rim pixels still shade.
		near_edge = sd;
		e.c = c;
		e.r = rr;
		e.id = id;
		e.k = k;
	}
}

// One element of the instance layout. Shared by the body (vf_elements) and the
// soft sun shadow (vf_soft_shadow) so both see the same crowns.
struct VfSlot {
	vec2 c;
	float r;
	float top;
	float id;
	bool live;
};

// Ring layout for count <= 4.
VfSlot vf_ring_slot(int k, int cnt, VegCtx ctx, float r0, float top, float keep, int form) {
	VfSlot sl;
	vec4 h = vf_hash42(vf_seed_offset(ctx.seed) + vec2(float(k) * 7.13, 3.7));
	sl.live = !(k > 0 && h.w > keep);
	float ring = cnt <= 1 ? 0.0 : (0.86 - r0);
	float a = ctx.seed * VF_TAU + float(k) * VF_TAU / float(cnt) + (h.x - 0.5) * 0.9;
	float rr = r0 * (0.84 + 0.26 * h.y);
	float rad = ring * (0.72 + 0.34 * h.z);
	float elem_top = top * (0.86 + 0.28 * h.z);
	if (form == VF_CACTUS) {
		rr = k == 0 ? 0.34 : 0.17 + 0.05 * h.y;
		rad = k == 0 ? 0.0 : 0.50 + 0.12 * h.z;
		elem_top = k == 0 ? top : top * 0.68;
	}
	sl.c = vec2(cos(a), sin(a)) * rad;
	if (cnt <= 1) {
		sl.c = (h.xy - 0.5) * 0.06;
		rr = r0;
	}
	sl.r = rr;
	sl.top = elem_top;
	sl.id = fract(h.w * 7.31 + h.z);
	return sl;
}

// Jittered grid layout for groves (count > 4); cell in grid units.
VfSlot vf_grid_slot(vec2 cell, vec2 so, float pitch, float r0, float top, float keep) {
	VfSlot sl;
	vec4 h = vf_hash42(cell);
	sl.c = (cell + 0.5 + (h.xy - 0.5) * 0.70 - so) * pitch;
	sl.r = r0 * (0.80 + 0.38 * h.z);
	float lim = 0.90 - sl.r * 0.62 - 0.16 * vf_hash12(cell + 17.3);
	sl.live = length(sl.c) <= lim && h.w <= keep;
	sl.top = top * (0.78 + 0.40 * h.z);
	sl.id = fract(h.w * 7.31 + h.z);
	return sl;
}

// keep: fraction of elements that survive dieback. lob: shared outline
// perturbation (fraction of the radius), en: the noise value it scales.
VfElem vf_elements(vec2 p, VegCtx ctx, float top, float lob_amp, float en,
		float keep, int form, bool cone) {
	VfElem e;
	e.c = vec2(0.0);
	e.r = 0.5;
	e.id = 0.0;
	e.z = 0.0;
	e.hit = 0.0;
	e.edge = 9.0;
	e.k = 0;
	float near_edge = 9.0;
	float n = max(ctx.count, 1.0);
	float r0 = vf_elem_radius(n);
	vec2 so = vf_seed_offset(ctx.seed);
	float lob = (en - 0.5) * lob_amp;
	if (n < 4.5) {
		int cnt = int(n + 0.5);
		for (int k = 0; k < 4; k++) {
			if (k >= cnt) {
				break;
			}
			VfSlot sl = vf_ring_slot(k, cnt, ctx, r0, top, keep, form);
			if (!sl.live) {
				continue;
			}
			vf_consider(e, near_edge, p, sl.c, sl.r, sl.id, sl.top, lob, k, cone);
		}
	} else {
		float pitch = r0 * 1.62;
		vec2 gi = floor(p / pitch + so);
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				VfSlot sl = vf_grid_slot(gi + vec2(float(i), float(j)), so, pitch, r0, top, keep);
				if (!sl.live) {
					continue;
				}
				vf_consider(e, near_edge, p, sl.c, sl.r, sl.id, sl.top, lob,
					(i + 1) + (j + 1) * 3, cone);
			}
		}
	}
	return e;
}

// Soft blurred ellipse cast by one element: starts under the crown and
// stretches by its height along the shadow direction. sv = shadow offset per
// unit height (away from the sun, local units).
float vf_ellipse_shadow(vec2 p, VfSlot sl, vec2 sv, float max_len) {
	vec2 v = sv * sl.top;
	float len_raw = length(v);
	vec2 u = len_raw > 1e-4 ? v / len_raw : vec2(1.0, 0.0);
	float len = min(len_raw, max_len);
	v = u * len;
	vec2 d = p - (sl.c + v * 0.5);
	float a = dot(d, u) / (sl.r * 1.05 + len * 0.5);
	float b = dot(d, vec2(-u.y, u.x)) / (sl.r * 1.05);
	// Penumbra grows with the occluder-to-ground distance, i.e. as the sun
	// drops: crisp and short at noon, long, wide and lighter at dusk.
	float soft = clamp(len_raw / (sl.r * 2.5), 0.0, 1.0);
	float t = sqrt(a * a + b * b);
	return (1.0 - smoothstep(mix(0.90, 0.55, soft), mix(1.22, 1.70, soft), t))
		* mix(1.0, 0.72, soft);
}

// Approximate sun shadow of the whole layout from per-element ellipses instead
// of re-evaluating the form. x: ground shadow (every element), y: shadow on
// crowns (only elements whose footprint does not contain p). sv is the shadow
// offset per unit height of a single full-size plant.
vec2 vf_soft_shadow(vec2 p, VegCtx ctx, int form, vec2 sv) {
	float top = form == VF_SHRUB ? 0.55 : 1.0;
	float keep = form == VF_CACTUS ? 1.0
		: mix(form == VF_SHRUB ? 0.40 : 0.45, 1.0, ctx.vigor);
	float n = max(ctx.count, 1.0);
	float r0 = vf_elem_radius(n);
	// Plant height follows crown size; the cap keeps a grove's shadows inside
	// the 3x3 search below.
	sv *= r0 / 0.80;
	float max_len = r0 * 1.1;
	float ground = 0.0;
	float crown = 0.0;
	if (n < 4.5) {
		int cnt = int(n + 0.5);
		for (int k = 0; k < 4; k++) {
			if (k >= cnt) {
				break;
			}
			VfSlot sl = vf_ring_slot(k, cnt, ctx, r0, top, keep, form);
			if (!sl.live) {
				continue;
			}
			float w = vf_ellipse_shadow(p, sl, sv, max_len);
			ground = max(ground, w);
			crown = max(crown, w * smoothstep(sl.r * 0.9, sl.r * 1.25, length(p - sl.c)));
		}
	} else {
		vec2 so = vf_seed_offset(ctx.seed);
		float pitch = r0 * 1.62;
		vec2 sv_mean = sv * top;
		float sv_len = length(sv_mean);
		vec2 back = sv_len > max_len ? sv_mean * (max_len / sv_len) : sv_mean;
		vec2 gi = floor((p - back * 0.5) / pitch + so);
		for (int j = -1; j <= 1; j++) {
			for (int i = -1; i <= 1; i++) {
				VfSlot sl = vf_grid_slot(gi + vec2(float(i), float(j)), so, pitch, r0, top, keep);
				if (!sl.live) {
					continue;
				}
				float w = vf_ellipse_shadow(p, sl, sv, max_len);
				ground = max(ground, w);
				crown = max(crown, w * smoothstep(sl.r * 0.9, sl.r * 1.25, length(p - sl.c)));
			}
		}
	}
	return vec2(ground, crown);
}

// Bare branch skeleton inside one crown, q in crown units. Only the winning
// crown pays for the atan.
float vf_branches(vec2 q, float id, float pxq, float nmain, float reach) {
	float rho = length(q);
	float th = atan(q.y, q.x);
	float bend = sin(rho * 4.0 + id * 9.0) * 0.22;
	float sec = th / VF_TAU * nmain + id * 3.0 + bend;
	float da = abs(fract(sec) - 0.5) * VF_TAU / nmain * rho;
	float w = mix(0.085, 0.020, rho);
	float limb_len = reach * (0.70 + 0.30 * vf_hash12(vec2(floor(sec), id * 31.0)));
	float limb = (1.0 - smoothstep(w - pxq, w + pxq, da)) * step(rho, limb_len);
	float n2 = nmain * 2.6;
	float sec2 = th / VF_TAU * n2 + id * 5.0 - bend * 1.7 + rho * 1.3;
	float da2 = abs(fract(sec2) - 0.5) * VF_TAU / n2 * rho;
	float w2 = mix(0.032, 0.012, rho);
	float twig = (1.0 - smoothstep(w2 - pxq, w2 + pxq, da2))
		* smoothstep(0.30, 0.45, rho) * step(rho, reach);
	float trunk = 1.0 - smoothstep(0.10 - pxq, 0.10 + pxq, rho);
	return max(max(limb, twig * 0.85), trunk);
}

// Shared crown-field shading for broadleaf-like elements: hemisphere normal
// plus analytic leaf-clump bumps whose frequency follows the crown size.
void vf_crown_shade(inout VegSurf s, VfElem e, vec2 p, float clump_freq, float bump_amp,
		float px) {
	vec2 q = (p - e.c) / e.r;
	float t2 = clamp(dot(q, q), 0.0, 0.97);
	vec3 n = normalize(vec3(q * 0.92, sqrt(1.0 - t2) + 0.12));
	float det = vf_detail(clump_freq / e.r * 0.16, px);
	vec2 qa = q * clump_freq + e.id * 17.0;
	vec2 qb = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * q * clump_freq * 1.9 + e.id * 5.0;
	vec2 grad = vec2(cos(qa.x) * sin(qa.y), sin(qa.x) * cos(qa.y))
		+ 0.5 * vec2(cos(qb.x) * sin(qb.y), sin(qb.x) * cos(qb.y));
	n = normalize(n + vec3(grad * bump_amp * det, 0.0));
	float clump = sin(qa.x) * sin(qa.y) + 0.5 * sin(qb.x) * sin(qb.y);
	s.n = n;
	s.tone = (0.98 + 0.10 * clump * det) * (0.90 + 0.18 * e.id);
	s.ao = mix(0.70, 1.0, smoothstep(0.0, 0.60, e.z));
	s.elem = e.id;
}

// Contact darkening hugging the element union; groves add a faint understorey
// only inside the patch so the forest floor never shows a disc outline.
float vf_canopy_floor(VfElem e, vec2 p, float count) {
	float contact = exp(-max(e.edge, 0.0) * 8.0) * 0.13;
	float under = count > 4.5 ? 0.10 * (1.0 - smoothstep(0.45, 0.78, length(p))) : 0.0;
	return max(contact, under);
}

float vf_floor_patch(vec2 p, float strength) {
	return strength * (1.0 - smoothstep(0.62, 0.92, length(p)));
}

// ── Canopy ─────────────────────────────────────────────────────────────────

VegSurf vf_broadleaf(vec2 p, VegCtx ctx, bool cheap, bool deciduous_skeleton) {
	VegSurf s = vf_empty();
	float r0 = vf_elem_radius(ctx.count);
	float fe = 1.5 / r0;
	vec2 so = vf_seed_offset(ctx.seed);
	float en = vf_vnoise(p * fe + so);
	float det = vf_detail(fe, ctx.px);
	float keep = mix(0.45, 1.0, ctx.vigor);
	VfElem e = vf_elements(p, ctx, 1.0, 0.32 * det, en, keep, VF_BROADLEAF, false);
	float union_cov = vf_cov(e.edge, ctx.px);
	s.floor_a = vf_canopy_floor(e, p, ctx.count);
	if (union_cov <= 0.0) {
		return s;
	}
	vec2 q = (p - e.c) / e.r;
	// Leaf-off: foliage thins as a fine stipple (leaf clusters), never as big
	// blotches, and the bare crown keeps a translucent twig haze over the limbs.
	float stip_f = fe * 4.2;
	float stip = vf_vnoise(p * stip_f + so + 5.1) * 0.60 + vf_vnoise(p * fe * 1.4 + so + 2.0) * 0.40;
	float lm = smoothstep(stip - 0.10, stip + 0.10, ctx.leaf * 1.08);
	lm = mix(smoothstep(0.15, 0.85, ctx.leaf), lm, vf_detail(stip_f, ctx.px));
	float br = 0.0;
	float haze = 0.0;
	if (deciduous_skeleton && lm < 0.999) {
		br = vf_branches(q, e.id, ctx.px / e.r, 5.0 + floor(e.id * 3.0), 0.96);
		haze = 0.40 * (1.0 - smoothstep(0.55, 1.0, length(q)) * 0.5);
	}
	float wood = max(br, haze);
	s.cov = union_cov * max(lm, wood);
	s.h = e.z * mix(0.55, 1.0, lm);
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	vf_crown_shade(s, e, p, 3.4 + e.id * 1.4, 0.40, ctx.px);
	s.leaf_w = lm / max(max(lm, wood), 1e-4);
	float bark_w = 1.0 - s.leaf_w;
	s.tint = mix(vec3(0.47, 0.41, 0.35), vec3(0.30, 0.25, 0.20), br);
	if (s.leaf_w < 0.5) {
		s.n = normalize(vec3(q * 0.35, 1.0));
		s.ao = 0.84;
	}
	// Fine leaf speckle where the crown is large enough on screen.
	float sp = vf_vnoise(p * fe * 6.0 + so * 1.7);
	s.tone *= 1.0 + (sp - 0.5) * 0.16 * vf_detail(fe * 6.0, ctx.px);
	s.snow_hold = mix(0.85, 0.55, bark_w);
	return s;
}

VegSurf vf_conifer(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	float keep = mix(0.45, 1.0, ctx.vigor);
	VfElem e = vf_elements(p, ctx, 1.0, 0.0, 0.5, keep, VF_CONIFER, true);
	s.floor_a = vf_canopy_floor(e, p, ctx.count);
	float union_cov = vf_cov(e.edge, ctx.px);
	if (union_cov <= 0.0) {
		return s;
	}
	vec2 q = (p - e.c) / e.r;
	float rho = length(q);
	vec2 dir = rho > 1e-4 ? q / rho : vec2(0.0);
	float th = atan(q.y, q.x);
	// Branch tips: an uneven spike count broken up by direction noise, so the
	// outline reads as layered boughs rather than a gear.
	float nsp = 11.0 + floor(e.id * 5.0);
	float tip_noise = vf_vnoise(dir * 2.6 + e.id * 13.0);
	float wave = 0.5 + 0.5 * cos(th * nsp + e.id * 20.0 + tip_noise * 3.0);
	float spikes = clamp(0.70 * wave * wave + 0.30 * vf_vnoise(dir * 5.5 + e.id * 7.0), 0.0, 1.0);
	float det = vf_detail(nsp / (VF_TAU * e.r) * 2.0, ctx.px);
	// Star cut applies to the nearest crown too, so the disc union never shows
	// as a rim outside the bough tips.
	float star = 1.0 - smoothstep(-ctx.px / e.r, ctx.px / e.r,
		rho - (1.0 - 0.26 * (1.0 - spikes) * det));
	s.cov = union_cov * star;
	s.h = e.z;
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	// Bough sprays radiate from the leader; whorl tiers stay soft and noisy.
	float tier_det = vf_detail(2.6 / e.r, ctx.px);
	float tier = fract(rho * 2.6 + spikes * 0.45 + tip_noise * 0.6 + e.id);
	float boughs = vf_vnoise(q * 6.5 + e.id * 31.0);
	vec2 perp = vec2(-dir.y, dir.x);
	s.n = normalize(vec3(dir * (0.62 + 0.40 * tier * tier_det)
		+ perp * (wave - 0.5) * 0.45 * det, 0.90));
	float spray = mix(0.80, 1.08, wave) * smoothstep(0.0, 0.35, rho) + (1.0 - smoothstep(0.0, 0.35, rho));
	s.tone = (0.84 + 0.14 * e.id) * mix(1.0, spray * (0.92 + 0.10 * smoothstep(0.0, 0.8, tier))
		+ (boughs - 0.5) * 0.14, det);
	s.tone *= 1.0 + 0.12 * (1.0 - smoothstep(0.0, 0.10, rho));
	s.ao = mix(0.72, 1.0, smoothstep(0.0, 0.7, e.z));
	s.elem = e.id;
	s.snow_hold = 0.6 + 0.4 * smoothstep(0.3, 0.8, tier);
	return s;
}

VegSurf vf_palm(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	float keep = mix(0.45, 1.0, ctx.vigor);
	VfElem e = vf_elements(p, ctx, 1.0, 0.0, 0.5, keep, VF_PALM, false);
	s.floor_a = exp(-max(e.edge, 0.0) * 7.0) * 0.12;
	if (e.edge > ctx.px) {
		return s;
	}
	vec2 q = (p - e.c) / e.r;
	float rho = length(q);
	float th = atan(q.y, q.x);
	float nf = 7.0 + floor(e.id * 3.0);
	float sec = th / VF_TAU * nf + e.id * 4.0 + rho * 0.35;
	float f = fract(sec) - 0.5;
	float da = abs(f) * VF_TAU / nf * rho;
	float pxq = ctx.px / e.r;
	float w = 0.21 * pow(sin(VF_PI * clamp(rho / 0.98, 0.0, 1.0)), 0.7) + 0.015;
	float frond = (1.0 - smoothstep(w - pxq, w + pxq, da)) * step(rho, 0.98);
	float hub = 1.0 - smoothstep(0.11 - pxq, 0.11 + pxq, rho);
	float leafy = frond * smoothstep(0.05, 0.35, ctx.leaf + 0.25);
	s.cov = max(leafy, hub);
	s.h = e.z * (1.0 - rho * 0.45);
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	vec2 dir = rho > 1e-4 ? q / rho : vec2(0.0);
	vec2 perp = vec2(-dir.y, dir.x);
	float side = sign(f) * clamp(da / max(w, 1e-3), 0.0, 1.0);
	s.n = normalize(vec3(dir * (0.20 + rho * 0.95) + perp * side * 0.45, 1.0));
	float det = vf_detail(13.0 / e.r, ctx.px);
	float leaflet = step(0.32, fract(rho * 13.0 + abs(f) * 9.0 + e.id));
	s.tone = (0.90 + 0.18 * e.id) * mix(1.0, 0.74 + 0.30 * leaflet, det);
	s.tone *= 1.0 - 0.20 * (1.0 - smoothstep(0.0, 0.025 + pxq, da)) * det;
	s.ao = mix(0.66, 1.0, smoothstep(0.0, 0.5, rho)) * mix(0.75, 1.0, smoothstep(0.0, 0.6, w - da + 0.4));
	s.elem = e.id;
	if (hub > 0.5 && leafy < hub) {
		s.leaf_w = 0.0;
		vec2 nut = fract(q * 9.0 + e.id) - 0.5;
		s.tint = mix(vec3(0.36, 0.27, 0.16), vec3(0.48, 0.38, 0.18),
			step(length(nut), 0.30));
		s.n = vec3(0.0, 0.0, 1.0);
	}
	s.snow_hold = 0.5;
	return s;
}

VegSurf vf_snag(vec2 p, VegCtx ctx, bool cheap, bool roots) {
	VegSurf s = vf_empty();
	vec2 so = vf_seed_offset(ctx.seed);
	vec2 c = (vf_hash22(so) - 0.5) * 0.08;
	vec2 q = (p - c) / 0.86;
	float rho = length(q);
	if (rho > 1.05) {
		return s;
	}
	float id = fract(ctx.seed * 13.7);
	float pxq = ctx.px / 0.86;
	float br;
	if (roots) {
		// Prop roots arch out from the trunk; thicker, fewer, reaching further.
		float th = atan(q.y, q.x);
		float nr = 8.0 + floor(id * 4.0);
		float sec = th / VF_TAU * nr + id * 3.0 + sin(rho * 5.0 + id * 7.0) * 0.18;
		float da = abs(fract(sec) - 0.5) * VF_TAU / nr * rho;
		float w = mix(0.07, 0.035, rho);
		float reach = 0.78 + 0.22 * vf_hash12(vec2(floor(sec), id * 17.0));
		br = (1.0 - smoothstep(w - pxq, w + pxq, da)) * step(rho, reach);
		br = max(br, 1.0 - smoothstep(0.13 - pxq, 0.13 + pxq, rho));
		s.floor_a = 0.22 * (1.0 - smoothstep(0.55, 1.0, rho));
	} else {
		br = vf_branches(q, id, pxq, 4.0 + floor(id * 2.0), 0.72);
		s.floor_a = exp(-rho * 6.0) * 0.20;
	}
	s.cov = br;
	s.h = roots ? 0.55 * sin(VF_PI * clamp(rho, 0.0, 1.0)) + 0.2 : 1.0 - rho;
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	s.n = normalize(vec3(q * 0.35, 1.0));
	s.tone = roots ? 0.70 + 0.35 * sin(VF_PI * clamp(rho, 0.0, 1.0)) : 0.92 + 0.12 * id;
	s.leaf_w = 1.0;
	s.ao = 0.85;
	s.elem = id;
	s.snow_hold = 0.45;
	return s;
}

// ── Brush and ground ───────────────────────────────────────────────────────

VegSurf vf_shrub(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	float r0 = vf_elem_radius(ctx.count);
	float fe = 1.8 / r0;
	vec2 so = vf_seed_offset(ctx.seed);
	float en = vf_vnoise(p * fe + so);
	float det = vf_detail(fe, ctx.px);
	float keep = mix(0.40, 1.0, ctx.vigor);
	VfElem e = vf_elements(p, ctx, 0.55, 0.40 * det, en, keep, VF_SHRUB, false);
	s.floor_a = exp(-max(e.edge, 0.0) * 8.0) * 0.16;
	float union_cov = vf_cov(e.edge, ctx.px);
	if (union_cov <= 0.0) {
		return s;
	}
	vec2 q = (p - e.c) / e.r;
	float stip_f = fe * 4.0;
	float stip = vf_vnoise(p * stip_f + so + 2.3) * 0.65 + vf_vnoise(p * fe * 1.3 + so) * 0.35;
	float lm = smoothstep(stip - 0.10, stip + 0.10, ctx.leaf * 1.05 + 0.10);
	lm = mix(smoothstep(0.0, 0.75, ctx.leaf), lm, vf_detail(stip_f, ctx.px));
	float br = lm < 0.999 ? vf_branches(q, e.id, ctx.px / e.r, 6.0, 0.9) : 0.0;
	s.cov = union_cov * max(lm, br * 0.9);
	s.h = e.z;
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	vf_crown_shade(s, e, p, 4.6 + e.id * 2.0, 0.50, ctx.px);
	s.tone *= 0.94;
	s.leaf_w = lm / max(max(lm, br * 0.9), 1e-4);
	s.tint = vec3(0.36, 0.30, 0.24);
	// Berries / blossom dots.
	if (ctx.bloom > 0.01) {
		vec2 g = q * 4.5 + e.id * 9.0;
		vec2 gi = floor(g);
		float pick = vf_hash12(gi + 3.3);
		float dot_r = length(fract(g) - 0.5 - (vf_hash22(gi) - 0.5) * 0.4);
		float berry = step(1.0 - ctx.bloom * 0.45, pick)
			* (1.0 - smoothstep(0.14, 0.14 + ctx.px / e.r * 4.5, dot_r));
		s.leaf_w *= 1.0 - berry;
		s.tint = mix(s.tint, mix(vec3(0.92, 0.88, 0.80), vec3(0.78, 0.22, 0.30),
			step(0.5, vf_hash12(gi + 8.1))), berry);
	}
	s.snow_hold = 0.9;
	return s;
}

VegSurf vf_cactus(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	VfElem e = vf_elements(p, ctx, 1.0, 0.0, 0.5, 1.0, VF_CACTUS, false);
	s.floor_a = exp(-max(e.edge, 0.0) * 8.0) * 0.15;
	s.cov = vf_cov(e.edge, ctx.px);
	s.h = e.z;
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	vec2 q = (p - e.c) / e.r;
	float rho = length(q);
	float th = atan(q.y, q.x);
	float ribs = e.k == 0 ? 12.0 : 8.0;
	float rib = cos(th * ribs + e.id * 3.0);
	float det = vf_detail(ribs / (VF_TAU * e.r), ctx.px);
	vec2 dir = rho > 1e-4 ? q / rho : vec2(0.0);
	vec2 perp = vec2(-dir.y, dir.x);
	float t2 = clamp(rho * rho, 0.0, 0.97);
	s.n = normalize(vec3(dir * rho * 0.9 + perp * sin(th * ribs + e.id * 3.0) * 0.22 * det,
		sqrt(1.0 - t2) + 0.15));
	s.tone = (0.90 + 0.12 * e.id) * mix(1.0, 0.82 + 0.18 * (rib * 0.5 + 0.5), det);
	s.ao = mix(0.70, 1.0, smoothstep(0.0, 0.6, e.z));
	s.elem = e.id;
	// Areole spine dots along the rib crests.
	float spine = step(0.85, rib) * step(0.6, fract(rho * 7.0 + e.id)) * det;
	s.tone += spine * 0.22;
	if (e.k == 0 && ctx.bloom > 0.02) {
		float petals = 0.30 + 0.12 * abs(cos(th * 3.0));
		float fl = (1.0 - smoothstep(petals - 0.04, petals + 0.04, rho))
			* step(0.35, ctx.bloom + e.id * 0.3);
		s.leaf_w = 1.0 - fl;
		s.tint = mix(vec3(0.95, 0.40, 0.55), vec3(0.98, 0.82, 0.30), step(0.5, e.id));
	}
	s.snow_hold = 0.7;
	return s;
}

VegSurf vf_reed(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	vec2 so = vf_seed_offset(ctx.seed);
	float patch_r = length(p) + (vf_vnoise(p * 2.1 + so) - 0.5) * 0.36;
	if (patch_r > 0.95) {
		return s;
	}
	s.floor_a = 0.24 * (1.0 - smoothstep(0.62, 0.90, patch_r));
	float pitch = 0.15;
	vec2 g = p / pitch + so;
	vec2 gi = floor(g);
	vec2 wd = ctx.wind;
	vec2 wp = vec2(-wd.y, wd.x);
	float best_z = -1.0;
	float edge = 9.0;
	vec2 best_dir = wd;
	float best_side = 0.0;
	float best_id = 0.0;
	float head = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 cell = gi + vec2(float(i), float(j));
			vec4 h = vf_hash42(cell);
			vec2 c = (cell + 0.5 + (h.xy - 0.5) * 0.85 - so) * pitch;
			if (length(c) > 0.80 + (h.w - 0.5) * 0.22) {
				continue;
			}
			vec2 dir = normalize(wd + wp * (h.z - 0.5) * 1.5);
			float L = 0.07 + 0.05 * h.w;
			float wdt = 0.013;
			vec2 v = p - c;
			float t = clamp(dot(v, dir), -L, L);
			vec2 off = v - dir * t;
			float d = length(off) - wdt * (1.0 - 0.45 * abs(t) / L);
			float hd = length(p - (c + dir * L)) - 0.022;
			float with_head = h.x > 0.45 ? min(d, hd) : d;
			edge = min(edge, with_head);
			float z = 0.45 + 0.55 * h.w;
			if (with_head < 0.0 && z > best_z) {
				best_z = z;
				best_dir = dir;
				best_side = dot(off, vec2(-dir.y, dir.x)) / wdt;
				best_id = h.z;
				head = (h.x > 0.45 && hd < d) ? 1.0 : 0.0;
			}
		}
	}
	s.cov = vf_cov(edge, ctx.px);
	s.h = max(best_z, 0.0);
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	vec2 perp = vec2(-best_dir.y, best_dir.x);
	s.n = normalize(vec3(perp * clamp(best_side, -1.0, 1.0) * 0.8 + best_dir * 0.15, 1.0));
	s.tone = 0.86 + 0.26 * best_id;
	s.elem = best_id;
	s.ao = mix(0.72, 1.0, s.h);
	if (head > 0.5) {
		s.leaf_w = 0.0;
		s.tint = vec3(0.40, 0.27, 0.15);
		s.n = vec3(0.0, 0.0, 1.0);
	}
	s.snow_hold = 0.7;
	return s;
}

VegSurf vf_grass(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	float keep = mix(0.35, 1.0, ctx.vigor);
	VfElem e = vf_elements(p, ctx, 0.40, 0.0, 0.5, keep, VF_GRASS, false);
	// Blades reach past the element disc, so test a slightly larger radius.
	if (e.edge > 0.35 * e.r) {
		return s;
	}
	vec2 q = (p - e.c) / (e.r * 1.15);
	q -= ctx.wind * dot(q, q) * 0.28;
	float rho = length(q);
	vec2 dir = rho > 1e-4 ? q / rho : vec2(1.0, 0.0);
	float pxq = ctx.px / e.r;
	// Tussock: a dense core with many uneven blade tips fanning out; the
	// reach varies with direction noise so no two tufts share a silhouette.
	float det = vf_detail(14.0 / VF_TAU, pxq);
	float tips = 0.55 * vf_vnoise(dir * 3.2 + e.id * 13.0)
		+ 0.45 * mix(0.5, vf_vnoise(dir * 9.0 + e.id * 7.0), det);
	float reach = 0.48 + 0.62 * tips * tips;
	float fan = 1.0 - smoothstep(reach - pxq * 1.5, reach + pxq * 1.5, rho);
	float core = 1.0 - smoothstep(0.34 - pxq, 0.34 + pxq, rho);
	s.cov = max(fan * mix(1.0, 0.78, smoothstep(0.4, 1.0, rho)), core);
	s.h = e.z * (1.0 - rho * 0.8);
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	float th = atan(q.y, q.x);
	float strands = 0.5 + 0.5 * cos(th * 23.0 + e.id * 40.0 + rho * 4.0);
	s.n = normalize(vec3(q * 0.75 + vec2(-dir.y, dir.x) * (strands - 0.5) * 0.30 * det, 1.0));
	s.tone = (0.80 + 0.34 * rho) * (0.92 + 0.16 * e.id) * mix(1.0, 0.90 + 0.18 * strands, det);
	s.ao = mix(0.62, 1.0, smoothstep(0.0, 0.7, rho));
	s.elem = e.id;
	if (ctx.bloom > 0.02) {
		vec2 g = p * 9.0 + vf_seed_offset(ctx.seed);
		vec2 gi = floor(g);
		float fl = step(1.0 - ctx.bloom * 0.30, vf_hash12(gi))
			* (1.0 - smoothstep(0.16, 0.16 + ctx.px * 18.0, length(fract(g) - 0.5)));
		s.leaf_w = 1.0 - fl;
		s.tint = mix(vec3(0.96, 0.92, 0.84), vec3(0.92, 0.74, 0.24), step(0.5, vf_hash12(gi + 4.1)));
	}
	s.snow_hold = 1.0;
	return s;
}

VegSurf vf_lichen(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	vec2 so = vf_seed_offset(ctx.seed);
	float n1 = vf_vnoise(p * 2.2 + so);
	float n2 = vf_vnoise(p * 5.3 + so * 1.7);
	float nn = n1 * 0.65 + n2 * 0.35;
	float shape = length(p) - 0.84 + (nn - 0.5) * 0.60;
	float blot = smoothstep(0.30, 0.36, nn + ctx.vigor * 0.12);
	s.cov = vf_cov(shape, ctx.px) * blot;
	s.h = 0.05;
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	float rim = 1.0 - smoothstep(0.0, 0.08, nn + ctx.vigor * 0.12 - 0.33);
	float spot = step(0.70, vf_vnoise(p * 3.3 + so * 2.1));
	s.tint = mix(vec3(0.64, 0.66, 0.56), vec3(0.80, 0.54, 0.20), spot);
	s.leaf_w = 0.45 * (1.0 - spot);
	s.tone = 0.90 + 0.18 * n2 + rim * 0.12;
	s.n = normalize(vec3((vec2(n1, n2) - 0.5) * 0.4, 1.0));
	s.elem = n1;
	s.snow_hold = 1.0;
	return s;
}

VegSurf vf_flower(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	float r0 = vf_elem_radius(ctx.count);
	float fe = 2.0 / r0;
	vec2 so = vf_seed_offset(ctx.seed);
	float en = vf_vnoise(p * fe + so);
	float keep = mix(0.35, 1.0, ctx.vigor);
	VfElem e = vf_elements(p, ctx, 0.30, 0.30 * vf_detail(fe, ctx.px), en, keep, VF_FLOWER, false);
	s.floor_a = exp(-max(e.edge, 0.0) * 18.0) * 0.18;
	s.cov = vf_cov(e.edge, ctx.px);
	s.h = e.z;
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	vf_crown_shade(s, e, p, 6.0, 0.45, ctx.px);
	if (ctx.bloom > 0.02 && e.id > 0.30) {
		vec2 fc = e.c + (vf_hash22(vec2(e.id * 41.0, 3.0)) - 0.5) * e.r * 0.5;
		vec2 fq = (p - fc) / (e.r * 0.55);
		float fr = length(fq);
		float th = atan(fq.y, fq.x);
		float petal = 0.55 + 0.45 * abs(cos(th * 2.5));
		float bloom_size = smoothstep(0.02, 0.5, ctx.bloom);
		float fl = 1.0 - smoothstep(petal * bloom_size - 0.06, petal * bloom_size + 0.06, fr);
		float eye = 1.0 - smoothstep(0.18, 0.26, fr);
		float pick = fract(e.id * 5.77);
		vec3 petal_col = pick < 0.25 ? vec3(0.95, 0.94, 0.90)
			: (pick < 0.5 ? vec3(0.96, 0.80, 0.22)
			: (pick < 0.75 ? vec3(0.84, 0.36, 0.64) : vec3(0.52, 0.48, 0.90)));
		s.leaf_w = 1.0 - fl;
		s.tint = mix(petal_col, vec3(0.95, 0.75, 0.20), eye * step(pick, 0.75));
		s.n = normalize(mix(s.n, vec3(0.0, 0.0, 1.0), fl * 0.7));
		s.h += fl * 0.1;
	}
	s.snow_hold = 1.0;
	return s;
}

VegSurf vf_peat(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	float r0 = vf_elem_radius(ctx.count);
	float fe = 1.6 / r0;
	vec2 so = vf_seed_offset(ctx.seed);
	float en = vf_vnoise(p * fe + so);
	VfElem e = vf_elements(p, ctx, 0.22, 0.36 * vf_detail(fe, ctx.px), en,
		mix(0.4, 1.0, ctx.vigor), VF_PEAT_TUFT, false);
	s.floor_a = max(exp(-max(e.edge, 0.0) * 12.0) * 0.20, vf_floor_patch(p, 0.18));
	s.cov = vf_cov(e.edge, ctx.px);
	s.h = e.z;
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	vf_crown_shade(s, e, p, 7.0, 0.30, ctx.px);
	float red = step(0.55, e.id) * smoothstep(0.35, 0.65, vf_vnoise(p * 4.0 + so * 3.0));
	s.leaf_w = 1.0 - red * 0.7;
	s.tint = vec3(0.58, 0.26, 0.20);
	vec2 g = p * 11.0 + so;
	vec2 gi = floor(g);
	float cotton = step(0.86 - ctx.bloom * 0.2, vf_hash12(gi))
		* (1.0 - smoothstep(0.12, 0.12 + ctx.px * 22.0, length(fract(g) - 0.5)))
		* vf_detail(11.0, ctx.px);
	s.leaf_w *= 1.0 - cotton;
	s.tint = mix(s.tint, vec3(0.95, 0.95, 0.92), cotton);
	s.snow_hold = 1.0;
	return s;
}

// ── Hardscape ──────────────────────────────────────────────────────────────

VegSurf vf_rock(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	vec2 so = vf_seed_offset(ctx.seed);
	vec2 pe = vec2(p.x * 0.86, p.y * 1.12);
	float dn = vf_vnoise(p * 1.6 + so) * 0.6 + vf_vnoise(p * 3.7 + so) * 0.4;
	float r = 0.70;
	float rad = length(pe);
	float d = rad - r + (dn - 0.5) * 0.42;
	s.floor_a = exp(-max(d, 0.0) * 12.0) * 0.36;
	s.cov = vf_cov(d, ctx.px);
	float t = clamp(rad / (r + 0.2), 0.0, 1.0);
	s.h = 0.8 * pow(max(1.0 - t * t, 0.0), 0.6);
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	// Voronoi facets: each cell tilts the dome normal a little, so the boulder
	// reads as weathered planes, not a polished gem.
	vec2 g = p * 1.7 + so;
	vec2 gi = floor(g);
	float f1 = 9.0;
	float f2 = 9.0;
	vec2 fid = vec2(0.0);
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 cell = gi + vec2(float(i), float(j));
			vec2 fp = cell + vf_hash22(cell);
			float dd = length(g - fp);
			if (dd < f1) {
				f2 = f1;
				f1 = dd;
				fid = cell;
			} else if (dd < f2) {
				f2 = dd;
			}
		}
	}
	vec2 fh = vf_hash22(fid + 5.3);
	float det = vf_detail(1.7, ctx.px);
	vec3 dome = normalize(vec3(pe / (r + 0.2) * 1.1, max(1.0 - t * t, 0.05)));
	s.n = normalize(dome + vec3((fh - 0.5) * 0.45 * det, 0.0));
	float crack = 1.0 - smoothstep(0.0, 0.035 + ctx.px * 2.5, f2 - f1);
	crack *= smoothstep(0.30, 0.62, vf_vnoise(p * 4.5 + so * 1.3));
	s.ao = 1.0 - 0.42 * crack * det;
	s.ao *= mix(0.70, 1.0, smoothstep(0.0, 0.45, s.h));
	float grain = vf_vnoise(p * 6.0 + so * 1.9);
	s.tone = (0.84 + 0.14 * fh.x) * (0.92 + 0.14 * grain * vf_detail(6.0, ctx.px));
	float spot = smoothstep(0.66, 0.74, vf_vnoise(p * 7.0 + so * 2.0)) * step(0.35, s.n.z)
		* vf_detail(7.0, ctx.px);
	// Stone keeps half its own warm grey so sky ambient never turns it blue.
	s.leaf_w = 0.5 * (1.0 - spot);
	vec3 stone = mix(vec3(0.54, 0.51, 0.46), vec3(0.62, 0.56, 0.47), fh.y);
	s.tint = mix(stone, mix(vec3(0.46, 0.52, 0.30), vec3(0.78, 0.60, 0.26), step(0.5, fh.y)), spot);
	s.elem = fh.x;
	s.snow_hold = 0.75 * smoothstep(0.55, 0.85, s.n.z);
	return s;
}

VegSurf vf_scree(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	VfElem e = vf_elements(p, ctx, 0.30, 0.0, 0.5, 1.0, VF_SCREE, false);
	s.floor_a = exp(-max(e.edge, 0.0) * 16.0) * 0.28;
	if (e.edge > ctx.px) {
		return s;
	}
	vec2 q = (p - e.c) / e.r;
	float a = e.id * VF_TAU;
	vec2 qr = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * q;
	float angular = mix(length(qr), max(abs(qr.x) * 1.05, abs(qr.y) * 1.3), 0.6);
	float pxq = ctx.px / e.r;
	s.cov = 1.0 - smoothstep(0.92 - pxq, 0.92 + pxq, angular);
	s.h = e.z * (1.0 - angular * 0.6);
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	vec2 tilt = vf_hash22(vec2(e.id * 37.0, 1.7)) - 0.5;
	s.n = normalize(vec3(q * 0.55 + tilt * 0.9, 1.0));
	s.tone = 0.78 + 0.36 * fract(e.id * 3.71);
	s.ao = mix(0.70, 1.0, smoothstep(0.0, 0.5, 1.0 - angular));
	s.elem = e.id;
	s.snow_hold = 0.9;
	return s;
}

VegSurf vf_snow_mound(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	vec2 so = vf_seed_offset(ctx.seed);
	vec2 wd = ctx.wind;
	vec2 q = vec2(dot(p, wd) * 0.72, dot(p, vec2(-wd.y, wd.x)));
	float dn = vf_vnoise(p * 1.8 + so);
	float rad = length(q);
	float d = rad - 0.76 + (dn - 0.5) * 0.30;
	s.floor_a = exp(-max(d, 0.0) * 10.0) * 0.08;
	// Drifts melt into the snowfield: a wide soft rim instead of a hard shell.
	s.cov = 1.0 - smoothstep(-0.22, ctx.px, d);
	float t = clamp(rad / 0.86, 0.0, 1.0);
	s.h = 0.6 * sqrt(max(1.0 - t * t, 0.0));
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	// Drifts are steeper on the lee side.
	float lee = dot(p, wd) > 0.0 ? 1.4 : 0.8;
	vec2 grad = p / 0.86 * lee;
	s.n = normalize(vec3(grad * 0.8, max(1.0 - t * t, 0.08) + 0.2));
	float det = vf_detail(14.0 / VF_TAU, ctx.px);
	s.tone = 1.0 + 0.025 * sin(q.y * 14.0 + dn * 7.0) * det;
	s.leaf_w = 0.0;
	s.tint = vec3(0.92, 0.94, 0.98);
	s.snow_hold = 0.0;
	return s;
}

VegSurf vf_fallen_log(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	vec2 so = vf_seed_offset(ctx.seed);
	float L = 0.78;
	float x = p.x;
	float y = p.y + sin(x * 2.0 + ctx.seed * 6.0) * 0.04;
	float rr = 0.17 * (1.0 - 0.18 * (x / L));
	float dx = max(abs(x) - L, 0.0);
	float d = length(vec2(dx, y)) - rr;
	// One stub where a branch broke off.
	vec2 stub_c = vec2(L * (0.2 + 0.3 * fract(ctx.seed * 7.0)) * sign(fract(ctx.seed * 3.0) - 0.5),
		rr * 0.6);
	vec2 sv = p - stub_c;
	float stub = length(vec2(sv.x, max(abs(sv.y) - 0.10, 0.0))) - 0.035;
	d = min(d, stub);
	s.floor_a = exp(-max(d, 0.0) * 12.0) * 0.34;
	s.cov = vf_cov(d, ctx.px);
	float across = clamp(y / rr, -1.0, 1.0);
	s.h = 0.30 * sqrt(max(1.0 - across * across, 0.0));
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	s.n = normalize(vec3(0.0, across, sqrt(max(1.0 - across * across, 0.0)) + 0.1));
	float det = vf_detail(10.0, ctx.px);
	float bark = vf_vnoise(vec2(x * 3.0, across * 6.0) + so);
	s.tone = (0.82 + 0.22 * bark) * mix(1.0, 0.88 + 0.12 * sin(across * 14.0 + bark * 4.0), det);
	s.ao = mix(0.62, 1.0, s.n.z);
	if (x > L - 0.01) {
		// Cut end: pale wood with growth rings.
		float ring = fract(length(vec2(x - L, y)) / rr * 4.0);
		s.leaf_w = 0.0;
		s.tint = vec3(0.70, 0.57, 0.38) * (0.88 + 0.12 * step(0.5, ring));
		s.n = normalize(vec3(0.6, 0.0, 0.8));
	}
	float moss = smoothstep(0.58, 0.70, vf_vnoise(p * 4.0 + so * 1.3)) * step(0.4, s.n.z);
	s.leaf_w *= 1.0 - moss;
	s.tint = mix(s.tint, vec3(0.30, 0.42, 0.18), moss);
	s.snow_hold = 0.9;
	return s;
}

// ── Aquatic ────────────────────────────────────────────────────────────────

VegSurf vf_kelp(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	vec2 so = vf_seed_offset(ctx.seed);
	// The holdfast sits upstream; fronds stream with the current, so the
	// field is anchored at -wind and every blade is swept downstream.
	vec2 wd = ctx.wind;
	vec2 c = (vf_hash22(so) - 0.5) * 0.10 - wd * 0.45;
	vec2 v = (p - c) / 0.90;
	float id = fract(ctx.seed * 11.3);
	float along = dot(v, wd);
	vec2 wp = vec2(-wd.y, wd.x);
	float across = dot(v, wp);
	if (along < -0.12 || along > 1.30 || abs(across) > 0.75) {
		return s;
	}
	float nf = 4.0 + floor(id * 3.0);
	float best = 9.0;
	float best_t = 0.0;
	float best_side = 0.0;
	for (int k = 0; k < 6; k++) {
		if (float(k) >= nf) {
			break;
		}
		float hk = vf_hash12(vec2(id * 31.0, float(k) * 7.7));
		float hk2 = vf_hash12(vec2(id * 17.0 + 3.1, float(k) * 5.3));
		// Fronds rise from a spread-out holdfast and drift almost parallel,
		// each with its own wave, so a bed never reads as a fan or arrow.
		float start = (float(k) / max(nf - 1.0, 1.0) - 0.5) * 0.42 + (hk2 - 0.5) * 0.16;
		float spread = (hk - 0.5) * 0.30;
		float len = 0.70 + 0.55 * hk2;
		float t = clamp(along / len, 0.0, 1.0);
		float sway = sin(t * (4.0 + 3.0 * hk) - ctx.time * 0.6 + hk * 9.0) * 0.11 * t;
		float centre = start + spread * t + sway;
		float w = (0.050 + 0.035 * hk) * sin(VF_PI * clamp(t * 0.85 + 0.15, 0.0, 1.0)) + 0.010;
		float d = abs(across - centre) - w;
		if (along > len) {
			d = max(d, along - len);
		}
		if (d < best) {
			best = d;
			best_t = t;
			best_side = (across - centre) / max(w, 1e-3);
		}
	}
	float pxq = ctx.px / 0.9;
	s.cov = vf_cov(best, pxq) * mix(0.62, 0.40, best_t);
	s.h = 0.06;
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	s.n = normalize(vec3(wp * clamp(best_side, -1.0, 1.0) * 0.40, 1.0));
	float bladder = 1.0 - smoothstep(0.20, 0.34, abs(fract(best_t * 7.0) - 0.5));
	s.tone = 0.86 + 0.18 * id + bladder * 0.14 * vf_detail(7.0, ctx.px);
	s.leaf_w = 0.35;
	s.tint = vec3(0.38, 0.34, 0.15);
	s.elem = id;
	s.snow_hold = 0.0;
	return s;
}

VegSurf vf_coral(vec2 p, VegCtx ctx, bool cheap) {
	VegSurf s = vf_empty();
	float r0 = vf_elem_radius(ctx.count);
	float fe = 1.7 / r0;
	vec2 so = vf_seed_offset(ctx.seed);
	float en = vf_vnoise(p * fe + so);
	VfElem e = vf_elements(p, ctx, 0.30, 0.34 * vf_detail(fe, ctx.px), en,
		mix(0.4, 1.0, ctx.vigor), VF_CORAL, false);
	s.cov = vf_cov(e.edge, ctx.px) * 0.92;
	s.h = e.z;
	if (cheap || s.cov <= 0.0) {
		return s;
	}
	vf_crown_shade(s, e, p, 5.0, 0.35, ctx.px);
	vec2 q = (p - e.c) / e.r;
	float det = vf_detail(4.0 / e.r, ctx.px);
	float groove = abs(sin(vf_vnoise(q * 3.0 + e.id * 7.0) * 9.0));
	s.tone *= mix(1.0, 0.72 + 0.28 * smoothstep(0.2, 0.6, groove), det);
	float pick = fract(e.id * 4.37);
	vec3 col = pick < 0.25 ? vec3(0.92, 0.48, 0.52)
		: (pick < 0.5 ? vec3(0.95, 0.64, 0.34)
		: (pick < 0.75 ? vec3(0.66, 0.46, 0.80) : vec3(0.90, 0.84, 0.48)));
	s.tint = col;
	s.leaf_w = 0.35;
	s.snow_hold = 0.0;
	return s;
}

VegSurf vf_eval(int form, vec2 p, VegCtx ctx, bool cheap) {
	if (form == VF_BROADLEAF) return vf_broadleaf(p, ctx, cheap, true);
	if (form == VF_CONIFER) return vf_conifer(p, ctx, cheap);
	if (form == VF_PALM) return vf_palm(p, ctx, cheap);
	if (form == VF_SHRUB) return vf_shrub(p, ctx, cheap);
	if (form == VF_CACTUS) return vf_cactus(p, ctx, cheap);
	if (form == VF_REED) return vf_reed(p, ctx, cheap);
	if (form == VF_GRASS) return vf_grass(p, ctx, cheap);
	if (form == VF_LICHEN) return vf_lichen(p, ctx, cheap);
	if (form == VF_FLOWER) return vf_flower(p, ctx, cheap);
	if (form == VF_ROCK) return vf_rock(p, ctx, cheap);
	if (form == VF_SCREE) return vf_scree(p, ctx, cheap);
	if (form == VF_SNOW_MOUND) return vf_snow_mound(p, ctx, cheap);
	if (form == VF_SNAG) return vf_snag(p, ctx, cheap, false);
	if (form == VF_FALLEN_LOG) return vf_fallen_log(p, ctx, cheap);
	if (form == VF_MANGROVE) return vf_snag(p, ctx, cheap, true);
	if (form == VF_KELP) return vf_kelp(p, ctx, cheap);
	if (form == VF_CORAL) return vf_coral(p, ctx, cheap);
	if (form == VF_PEAT_TUFT) return vf_peat(p, ctx, cheap);
	return vf_shrub(p, ctx, cheap);
}

// Distant fallback: once a whole instance is only a few pixels wide, a soft
// lumpy disc in the element colour reads the same and skips the field walk.
VegSurf vf_far(int form, vec2 p, VegCtx ctx) {
	VegSurf s = vf_empty();
	vec2 so = vf_seed_offset(ctx.seed);
	float extent = (form == VF_LICHEN || form == VF_REED || form == VF_KELP) ? 0.78 : 0.82;
	if (form == VF_FALLEN_LOG) {
		float d = length(vec2(max(abs(p.x) - 0.78, 0.0), p.y)) - 0.17;
		s.cov = vf_cov(d, ctx.px);
		s.h = 0.2;
		s.leaf_w = 1.0;
		return s;
	}
	bool multi = ctx.count > 1.5;
	float lump = multi ? 0.50 : 0.25;
	float d = length(p) - extent + (vf_vnoise(p * 2.0 + so) - 0.5) * lump;
	float density = (form == VF_SNAG || form == VF_MANGROVE) ? 0.45
		: ((form == VF_REED || form == VF_GRASS || form == VF_KELP) ? 0.75 : 1.0);
	if (form == VF_BROADLEAF) {
		density = mix(0.45, 1.0, smoothstep(0.1, 0.6, ctx.leaf));
	}
	s.cov = vf_cov(d, ctx.px) * density;
	vec2 q = p / extent;
	float crowns = 1.0;
	if (multi) {
		// Element-scale blotches keep a cluster or grove broken into crowns
		// instead of a single puck, at the cost of one noise tap.
		float fe = 0.85 / vf_elem_radius(ctx.count);
		crowns = vf_vnoise(p * fe + so * 1.7);
		s.cov *= smoothstep(0.22, 0.48, crowns);
	}
	s.h = 0.5;
	s.n = normalize(vec3(q * 0.30, 1.0));
	s.tone = 0.90 + 0.18 * crowns;
	s.elem = crowns;
	s.ao = 0.94;
	if (form == VF_ROCK || form == VF_SCREE || form == VF_SNOW_MOUND) {
		s.leaf_w = form == VF_SNOW_MOUND ? 0.0 : 1.0;
		s.tint = vec3(0.92, 0.94, 0.98);
	}
	if (form == VF_CORAL) {
		s.leaf_w = 0.35;
		s.tint = vec3(0.90, 0.56, 0.48);
	}
	if (form == VF_KELP) {
		s.leaf_w = 0.35;
		s.tint = vec3(0.38, 0.34, 0.15);
	}
	s.floor_a = exp(-max(d, 0.0) * 14.0) * 0.10;
	return s;
}

#endif
