// Shared placement and bitmap sampling for top-down vegetation and decorations.
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

// The resource shader's Web variant only needs the shared noise functions.
#ifndef PK_VF_NOISE_ONLY
struct VegCtx {
	float seed;
	vec2 seed_offset;
	float radius;
	float count;     // elements carried by the instance (1..32)
	float leaf;      // foliage amount: deciduous crowns thin to bare branches
	float vigor;     // structural presence: dieback removes whole elements
	float bloom;     // 0..1 flowering
	float px;        // local units per screen pixel
};

struct VegSurf {
	float cov;       // coverage 0..1, antialiased
	vec3 n;          // local-frame normal
	float ao;        // cavity / inter-element occlusion
	float tone;      // albedo multiplier
	float leaf_w;    // 1 = climate foliage palette, 0 = tint
	vec3 tint;       // bark, stone, petal, snow...
	float elem;      // per-element hash for colour variety
	float snow_hold; // how readily snow settles on this surface
	vec4 shadow_crown; // centre, radius and height of the crown selected by vf_elements
	vec4 art;        // crown bitmap hue (rgb at luma 0.5) and its weight vs the climate palette
};

VegSurf vf_empty() {
	VegSurf s;
	s.cov = 0.0;
	s.n = vec3(0.0, 0.0, 1.0);
	s.ao = 1.0;
	s.tone = 1.0;
	s.leaf_w = 1.0;
	s.tint = vec3(0.5);
	s.elem = 0.0;
	s.snow_hold = 1.0;
	s.shadow_crown = vec4(0.0, 0.0, 0.0, 1.0);
	s.art = vec4(0.5, 0.5, 0.5, 0.0);
	return s;
}
#endif // PK_VF_NOISE_ONLY

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

// Placement and lighting helpers are used by the decoration body pass.
#ifndef PK_VF_NOISE_ONLY
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
	float top;
	float edge;  // distance to the nearest element footprint
};

void vf_consider(inout VfElem e, inout float near_edge, vec2 p, vec2 c, float rr,
		float id, float top, bool cone) {
	float d = length(p - c);
	float sd = d - rr;
	e.edge = min(e.edge, sd);
	if (sd < 0.0) {
		float t = clamp(d / rr, 0.0, 1.0);
		float z = top * (cone ? (1.0 - t) : sqrt(1.0 - t * t));
		if (z > e.z) {
			e.z = z;
			e.c = c;
			e.r = rr;
			e.top = top;
			e.id = id;
			e.hit = 1.0;
		}
	} else if (e.hit < 0.5 && sd < near_edge) {
		// Remember the nearest element so antialiased rim pixels still shade.
		near_edge = sd;
		e.c = c;
		e.r = rr;
		e.top = top;
		e.id = id;
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
	vec4 h = vf_hash42(ctx.seed_offset + vec2(float(k) * 7.13, 3.7));
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

// Select the visible element in the deterministic ring or grove.
VfElem vf_elements(vec2 p, VegCtx ctx, float top, float keep, int form, bool cone) {
	VfElem e;
	e.c = vec2(0.0);
	e.r = 0.5;
	e.id = 0.0;
	e.z = 0.0;
	e.hit = 0.0;
	e.top = 0.0;
	e.edge = 9.0;
	float near_edge = 9.0;
	float n = max(ctx.count, 1.0);
	float r0 = ctx.radius;
	vec2 so = ctx.seed_offset;
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
			vf_consider(e, near_edge, p, sl.c, sl.r, sl.id, sl.top, cone);
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
				vf_consider(e, near_edge, p, sl.c, sl.r, sl.id, sl.top, cone);
			}
		}
	}
	return e;
}

// Soft blurred ellipse cast by one element: starts under the crown and
// stretches by its height along the shadow direction. sv = shadow offset per
// unit height (away from the sun, local units).
float vf_ellipse_shadow(vec2 p, VfSlot sl, vec2 axis, float offset_length, float max_len) {
	float len_raw = offset_length * sl.top;
	vec2 u = len_raw > 1e-4 ? axis : vec2(1.0, 0.0);
	float len = min(len_raw, max_len);
	vec2 v = u * len;
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

// Reuse the crown already selected for this pixel, including its actual
// radius and height. Forms drawn without a crown layout use their anchor.
// x: ground shadow, y: shadow on crowns. sv is the shadow offset per unit
// height of a single full-size plant.
vec2 vf_soft_shadow(vec2 p, float radius, vec4 crown, vec2 sv) {
	VfSlot slot;
	slot.c = crown.xy;
	slot.r = crown.z > 0.0 ? crown.z : radius;
	slot.top = crown.w;
	sv *= radius / 0.80;
	float offset_length = length(sv);
	vec2 axis = sv / max(offset_length, 1e-7);
	float shadow = vf_ellipse_shadow(p, slot, axis, offset_length, radius * 1.1)
		* step(0.001, slot.top);
	return vec2(shadow, shadow * smoothstep(slot.r * 0.9, slot.r * 1.25, length(p - slot.c)));
}

#ifdef VF_CROWN_ART
uniform sampler2DArray crown_art : filter_linear_mipmap, repeat_disable;
uniform sampler2DArray crown_normal_art : filter_linear_mipmap, repeat_disable;
uniform bool crown_art_bound = false;
uniform float crown_art_palette = 0.55;
uniform float crown_art_normal = 1.0;

// x = array layer, y = sprite in its 4x2 sheet. The generated decoration
// sheets follow DECORATION_FORMS in tools/resource_art/build.py.
ivec2 vf_bitmap_cell(int form, float id, float leaf) {
	if (form == VF_BROADLEAF && leaf < mix(0.18, 0.78, id)) {
		return ivec2(6, 5);
	}
	if (form <= VF_SHRUB || form == VF_ROCK) {
		int layer = form == VF_ROCK ? 4 : form;
		return ivec2(layer, int(floor(fract(id * 5.731 + 0.13) * 8.0)));
	}
	int cell = form < VF_ROCK ? form - VF_CACTUS : form - VF_CACTUS - 1;
	return ivec2(5 + cell / 8, cell % 8);
}

VegSurf vf_bitmap(int form, vec2 p, VegCtx ctx, bool far) {
	VegSurf s = vf_empty();
	if (!crown_art_bound) {
		return s;
	}
	float keep = form == VF_CACTUS ? 1.0
		: mix(form == VF_SHRUB ? 0.40 : 0.45, 1.0, ctx.vigor);
	VfElem e;
#ifdef PK_VEG_FAR_ONLY
	// The startup and hidden Web batches use a single mipmapped sprite.
	e.c = vec2(0.0);
	e.r = 0.82;
	e.id = ctx.seed;
#else
	float top = form == VF_SHRUB ? 0.55 : 1.0;
	e = vf_elements(p, ctx, top, keep, form, form == VF_CONIFER);
	s.shadow_crown = vec4(e.c, e.r, e.top);
	if (e.edge > e.r * 0.42) {
		return s;
	}
#endif
	vec2 q = (p - e.c) / max(e.r, 0.0001);
	float ang = e.id * VF_TAU * 3.0;
	float ca = cos(ang);
	float sa = sin(ang);
	mat2 rot = mat2(vec2(ca, sa), vec2(-sa, ca));
	vec2 qr = rot * q;
	if (max(abs(qr.x), abs(qr.y)) >= 1.0) {
		return s;
	}
	ivec2 sprite = vf_bitmap_cell(form, e.id, ctx.leaf);
	vec2 cell = vec2(float(sprite.y % 4), float(sprite.y / 4));
	vec2 uv = (cell + vec2(qr.x, -qr.y) * 0.5 + 0.5) / vec2(4.0, 2.0);
	// Clamp the footprint within a sprite's mip chain to avoid mixing neighbours.
	float k = min(ctx.px / (1.5 * e.r), 0.125);
	vec2 gx = vec2(k * 0.25, 0.0);
	vec2 gy = vec2(0.0, k * 0.5);
	vec3 uvw = vec3(uv, float(sprite.x));
	vec4 c = textureGrad(crown_art, uvw, gx, gy);
	s.cov = c.a;
	s.elem = e.id;
	bool bare = form == VF_BROADLEAF && sprite.x == 6;
	bool own_colour = bare || form == VF_ROCK || form == VF_SCREE || form == VF_SNOW_MOUND
		|| form == VF_SNAG || form == VF_FALLEN_LOG || form == VF_KELP || form == VF_CORAL;
	s.leaf_w = own_colour ? 0.0 : 1.0;
	s.tint = c.rgb;
	float luma = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	s.tone = own_colour ? 1.0 : clamp(luma * 2.0, 0.12, 1.9);
	s.art = vec4(c.rgb / max(2.0 * luma, 0.04), crown_art_palette);
	if (form == VF_FLOWER) {
		// Reveal the painted petal colours with the seasonal bloom signal.
		s.leaf_w = 1.0 - ctx.bloom * 0.75;
	}
	s.snow_hold = form == VF_KELP || form == VF_CORAL ? 0.0 : 1.0;
	if (!far && c.a > 0.0) {
		vec4 nm = textureGrad(crown_normal_art, uvw, gx, gy);
		vec2 nxy = transpose(rot) * ((nm.rg * 2.0 - 1.0) * crown_art_normal);
		s.n = normalize(vec3(nxy, max(sqrt(max(1.0 - dot(nxy, nxy), 0.0)), 0.35)));
		s.ao = mix(0.55, 1.0, nm.a);
	}
	return s;
}
#endif

#endif // PK_VF_NOISE_ONLY

#endif
