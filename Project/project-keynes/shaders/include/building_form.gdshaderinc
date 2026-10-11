// building_form.gdshaderinc
// Shared geometry for the building body, cast-shadow and ground passes.
// Ids mirror the Form / Material / GroundKind enums in
// gdext/src/world_ext_building_visual.cpp; both tables must stay identical.
//
// Instance ABI (16 floats, encoded by gdext/src/world_ext_building_visual.cpp):
//   transform  basis x = local long axis * half length, basis y = perp * half width
//   color      r = eave height / BF_HEIGHT_RANGE, g = ridge height / BF_HEIGHT_RANGE,
//              b = (material + 0.5) / 16,                   (ground: r = param, g = flag)
//              a = rank in the cell's importance order, (n + 0.5) / N (ground: 1)
//   custom     r = (era * 6 + archetype) / 65, g = seed, b = cell / (cell_count - 1),
//              a = (form + 0.5) / 32                        (ground: a = (kind + 0.5) / 16)
// Plaza and road param = settlement wealth 0..1; yard flag 1 = mud; garden
// param = wealth, flag 1 = pool.
#ifndef BUILDING_FORM_INC
#define BUILDING_FORM_INC

const float BF_HEIGHT_RANGE = 16.0;

const int BF_GABLE = 0;
const int BF_HIPPED = 1;
const int BF_CONE = 2;
const int BF_DOME = 3;
const int BF_FLAT = 4;
const int BF_SAWTOOTH = 5;
const int BF_CROSS = 6;
const int BF_COURTYARD = 7;
const int BF_TOWER = 8;
const int BF_MOUND = 9;
const int BF_WINDMILL = 10;
const int BF_CHIMNEY = 11;
const int BF_GREENHOUSE = 12;
const int BF_COOLING = 13;
const int BF_TANK = 14;
const float BF_FORM_SCALE = 32.0;

const int BM_THATCH = 0;
const int BM_SHINGLE = 1;
const int BM_TILE = 2;
const int BM_SLATE = 3;
const int BM_METAL = 4;
const int BM_BITUMEN = 5;
const int BM_CONCRETE = 6;
const int BM_GLASS = 7;
const int BM_GREEN = 8;
const int BM_COPPER = 9;
const int BM_EARTH = 10;
const int BM_HAY = 11;
const int BM_CHARCOAL = 12;
const int BM_BRICK = 13;
const int BM_SOLAR = 14;
const int BM_STONE = 15;

const int BG_PLAZA = 0;
const int BG_ROAD = 1;
const int BG_FIELD = 2;
const int BG_PIT = 3;
const int BG_YARD = 4;
const int BG_SOLAR = 5;
const int BG_STONE_RING = 6;
const int BG_PADDY = 7;
const int BG_ORCHARD = 8;
const int BG_PASTURE = 9;
const int BG_GARDEN = 10;
const int BG_LOG_YARD = 11;
const int BG_SALT_PAN = 12;
const int BG_QUAY = 13;

float bf_hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float bf_vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = bf_hash12(i);
	float b = bf_hash12(i + vec2(1.0, 0.0));
	float c = bf_hash12(i + vec2(0.0, 1.0));
	float d = bf_hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float bf_fbm(vec2 p) {
	return bf_vnoise(p) * 0.57 + bf_vnoise(p * 2.13 + 7.1) * 0.29
		+ bf_vnoise(p * 4.37 + 3.7) * 0.14;
}

// Fades a pattern of `freq` cycles per world unit once a pixel covers more
// than about half a cycle, so courses and rows never shimmer at far zoom.
float bf_detail(float freq, float px) {
	return clamp(1.6 - px * freq * 2.4, 0.0, 1.0);
}

float bf_box(vec2 p, vec2 b) {
	vec2 d = abs(p) - b;
	return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

bool bf_is_round(int form) {
	return form == BF_CONE || form == BF_DOME || form == BF_MOUND
		|| form == BF_WINDMILL || form == BF_CHIMNEY || form == BF_COOLING || form == BF_TANK;
}

float bf_cross_nave(vec2 half_size) { return half_size.y * 0.40; }
float bf_cross_transept_x(vec2 half_size) { return half_size.x * 0.30; }
float bf_courtyard_wing(vec2 half_size) { return min(half_size.x, half_size.y) * 0.40; }

// Signed distance to the ground footprint (negative inside).
float bf_footprint(int form, vec2 p, vec2 half_size) {
	if (bf_is_round(form)) {
		return length(p) - half_size.y;
	}
	if (form == BF_CROSS) {
		float nw = bf_cross_nave(half_size);
		float nave = bf_box(p, vec2(half_size.x, nw));
		float transept = bf_box(p - vec2(bf_cross_transept_x(half_size), 0.0),
			vec2(nw * 1.05, half_size.y));
		return min(nave, transept);
	}
	if (form == BF_COURTYARD) {
		float t = bf_courtyard_wing(half_size);
		return max(bf_box(p, half_size), -bf_box(p, half_size - vec2(t)));
	}
	return bf_box(p, half_size);
}

float bf_gable(float across, float half_w, float he, float hr) {
	return he + (hr - he) * clamp(1.0 - abs(across) / max(half_w, 0.001), 0.0, 1.0);
}

// Roof surface height above ground at local point p (ridge runs along local x).
float bf_roof_height(int form, vec2 p, vec2 half_size, float he, float hr) {
	if (form == BF_GABLE || form == BF_GREENHOUSE) {
		return bf_gable(p.y, half_size.y, he, hr);
	}
	if (form == BF_HIPPED || form == BF_TOWER) {
		float run = min(half_size.y - abs(p.y), half_size.x - abs(p.x));
		return he + (hr - he) * clamp(run / max(half_size.y, 0.001), 0.0, 1.0);
	}
	if (form == BF_CONE || form == BF_WINDMILL) {
		float r = length(p) / max(half_size.y, 0.001);
		return he + (hr - he) * clamp(1.0 - r, 0.0, 1.0);
	}
	if (form == BF_DOME) {
		float r = length(p) / max(half_size.y, 0.001);
		return he + (hr - he) * sqrt(max(0.0, 1.0 - r * r));
	}
	if (form == BF_MOUND) {
		float r = length(p) / max(half_size.y, 0.001);
		return hr * sqrt(max(0.0, 1.0 - r * r));
	}
	if (form == BF_SAWTOOTH) {
		float teeth = max(2.0, floor(half_size.x / 0.75 + 0.5));
		float x = (p.x + half_size.x) / (2.0 * half_size.x) * teeth;
		return he + (hr - he) * fract(x);
	}
	if (form == BF_CROSS) {
		float nw = bf_cross_nave(half_size);
		float z = abs(p.y) <= nw ? bf_gable(p.y, nw, he, hr) : he;
		float tx = p.x - bf_cross_transept_x(half_size);
		if (abs(tx) <= nw * 1.05) {
			z = max(z, bf_gable(tx, nw * 1.05, he, hr));
		}
		return z;
	}
	if (form == BF_COURTYARD) {
		float t = bf_courtyard_wing(half_size);
		float d_outer = -bf_box(p, half_size);
		float d_inner = bf_box(p, half_size - vec2(t));
		return he + (hr - he) * clamp(min(d_outer, d_inner) / (t * 0.5), 0.0, 1.0);
	}
	return he;
}

// Parameter span [t0, t1] over which the ray s - lift * t lies inside a box or
// disc; an empty span has t0 > t1.
vec2 bf_slab_axis(float s, float l, float b) {
	if (abs(l) < 1e-5) {
		return abs(s) <= b ? vec2(-1e6, 1e6) : vec2(1e6, -1e6);
	}
	float a = (s - b) / l;
	float c = (s + b) / l;
	return vec2(min(a, c), max(a, c));
}

vec2 bf_box_span(vec2 s, vec2 lift, vec2 b) {
	vec2 x = bf_slab_axis(s.x, lift.x, b.x);
	vec2 y = bf_slab_axis(s.y, lift.y, b.y);
	return vec2(max(x.x, y.x), min(x.y, y.y));
}

vec2 bf_disc_span(vec2 s, vec2 lift, float r) {
	float a = dot(lift, lift);
	if (a < 1e-8) {
		return length(s) <= r ? vec2(-1e6, 1e6) : vec2(1e6, -1e6);
	}
	float b = dot(s, lift);
	float disc = b * b - a * (dot(s, s) - r * r);
	if (disc < 0.0) {
		return vec2(1e6, -1e6);
	}
	float q = sqrt(disc);
	return vec2((b - q) / a, (b + q) / a);
}

// Highest t in [0, top] of a span, or -1 when the span misses that range.
float bf_span_top(vec2 span, float top) {
	float t = min(span.y, top);
	return t >= max(span.x, 0.0) ? t : -1.0;
}

// Highest point (t in [0, top]) where the leaned view ray s - lift * t meets
// the wall of the footprint; -1 when the ray misses the walls.
float bf_wall_t(int form, vec2 s, vec2 lift, vec2 half_size, float top) {
	if (bf_is_round(form)) {
		return bf_span_top(bf_disc_span(s, lift, half_size.y), top);
	}
	if (form == BF_CROSS) {
		float nw = bf_cross_nave(half_size);
		float nave = bf_span_top(bf_box_span(s, lift, vec2(half_size.x, nw)), top);
		float transept = bf_span_top(bf_box_span(s - vec2(bf_cross_transept_x(half_size), 0.0),
			lift, vec2(nw * 1.05, half_size.y)), top);
		return max(nave, transept);
	}
	vec2 outer = bf_box_span(s, lift, half_size);
	float t = bf_span_top(outer, top);
	if (form == BF_COURTYARD && t >= 0.0) {
		vec2 inner = bf_box_span(s, lift, half_size - vec2(bf_courtyard_wing(half_size)));
		if (t > inner.x && t < inner.y) {
			// The ray top is over the court: the visible face is the court wall.
			t = inner.x >= max(outer.x, 0.0) ? inner.x : -1.0;
		}
	}
	return t;
}

// Outward wall normal at a ground point on the footprint boundary.
vec2 bf_wall_normal(int form, vec2 p, vec2 half_size) {
	if (bf_is_round(form)) {
		return length(p) > 1e-5 ? normalize(p) : vec2(0.0, 1.0);
	}
	vec2 c = vec2(0.0);
	vec2 b = half_size;
	float sign_in = 1.0;
	if (form == BF_CROSS) {
		float nw = bf_cross_nave(half_size);
		vec2 tc = vec2(bf_cross_transept_x(half_size), 0.0);
		vec2 tb = vec2(nw * 1.05, half_size.y);
		if (abs(bf_box(p - tc, tb)) < abs(bf_box(p, vec2(half_size.x, nw)))) {
			c = tc;
			b = tb;
		} else {
			b = vec2(half_size.x, nw);
		}
	} else if (form == BF_COURTYARD) {
		vec2 inner = half_size - vec2(bf_courtyard_wing(half_size));
		if (abs(bf_box(p, inner)) < abs(bf_box(p, half_size))) {
			b = inner;
			sign_in = -1.0;
		}
	}
	vec2 q = abs(p - c) / max(b, vec2(1e-4));
	vec2 n = q.x > q.y ? vec2(sign(p.x - c.x), 0.0) : vec2(0.0, sign(p.y - c.y));
	return n * sign_in;
}

// Traditional windmills carry four lattice sails; concrete/metal ones are
// three-blade turbines on a slim mast.
bool bf_is_turbine(int mat) {
	return mat == BM_CONCRETE || mat == BM_METAL;
}

float bf_sail_radius(int mat, float radius) {
	return bf_is_turbine(mat) ? 1.35 : radius * 2.4;
}

// Coverage of the rotor at a point on the rotor plane, relative to the hub.
float bf_sails(vec2 q, int mat, float radius, float angle, float px) {
	float reach = bf_sail_radius(mat, radius);
	float cover = 0.0;
	if (bf_is_turbine(mat)) {
		for (int k = 0; k < 3; k++) {
			float a = angle + float(k) * 2.0943951;
			vec2 d = vec2(cos(a), sin(a));
			float along = dot(q, d);
			float side = dot(q, vec2(-d.y, d.x));
			float width = mix(0.07, 0.025, clamp(along / reach, 0.0, 1.0)) + px * 0.5;
			float blade = step(0.0, along) * (1.0 - smoothstep(reach - px, reach + px, along))
				* (1.0 - smoothstep(width - px, width + px, abs(side)));
			cover = max(cover, blade);
		}
		return max(cover, 1.0 - smoothstep(0.09 - px, 0.09 + px, length(q)));
	}
	for (int k = 0; k < 4; k++) {
		float a = angle + float(k) * 1.5707963;
		vec2 d = vec2(cos(a), sin(a));
		float along = dot(q, d);
		float side = dot(q, vec2(-d.y, d.x));
		float in_len = smoothstep(radius * 0.25, radius * 0.25 + px, along)
			* (1.0 - smoothstep(reach - px, reach + px, along));
		float spar = 1.0 - smoothstep(0.035 - px, 0.035 + px, abs(side));
		float cloth = smoothstep(-px, px, side)
			* (1.0 - smoothstep(radius * 0.36 - px, radius * 0.36 + px, side));
		cover = max(cover, in_len * max(spar, cloth * 0.92));
	}
	return cover;
}

#endif // BUILDING_FORM_INC
