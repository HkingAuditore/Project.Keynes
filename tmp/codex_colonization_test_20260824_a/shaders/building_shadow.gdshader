shader_type canvas_item;
render_mode unshaded, blend_mul;

// Cast shadow + contact occlusion for one building volume, built the same way
// as the vegetation blob shadow: the shape is made in the vertex stage and the
// fragment only evaluates a soft edge. The mesh is the shadow hull fan from
// BuildingVisualLayer._make_shadow_hull_mesh(); vertices on footprint edges
// facing away from the sun are pushed along the shadow, which traces the
// convex hull of the footprint swept to its shadow height.

uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0);
uniform float cell_count = 1.0;
uniform float camera_zoom = 1.0;
uniform float shadow_strength = 0.55;
uniform int visual_quality = 1;
uniform float lod_fraction = 1.0;
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.4101523;
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);

const vec3 SHADOW_TINT = vec3(0.30, 0.35, 0.47);
const float SHADOW_MAX_REACH = 5.0;
// Ground margin around the hull that carries contact occlusion and penumbra.
const float SHADOW_MARGIN = 0.45;

#include "res://shaders/include/earth_daylight.gdshaderinc"
#include "res://shaders/include/building_form.gdshaderinc"

varying vec2 v_p;
varying flat vec2 v_half;
varying flat vec2 v_shift;    // local-frame ground shift of the shadow top
varying flat float v_form;
varying flat float v_cell;
varying flat float v_day;

vec2 lut_uv(float cell_value) {
	float cell = clamp(floor(cell_value * max(cell_count - 1.0, 1.0) + 0.5),
		0.0, max(cell_count - 1.0, 0.0));
	float x = mod(cell, max(lut_dims.x, 1.0));
	float y = floor(cell / max(lut_dims.x, 1.0));
	return (vec2(x, y) + 0.5) / max(lut_dims, vec2(1.0));
}

// Height whose sweep stands in for the roof: pitched roofs shade about half
// way up the pitch, round roofs less, a mound from its crown.
float shadow_height(int form, float he, float hr) {
	if (form == BF_FLAT || form == BF_CHIMNEY || form == BF_COOLING || form == BF_WINDMILL
			|| form == BF_TANK) {
		return hr;
	}
	if (form == BF_MOUND) return hr * 0.6;
	if (bf_is_round(form)) return mix(he, hr, 0.35);
	return mix(he, hr, 0.5);
}

// Courtyards shade as their outer block; the court itself is drawn by the body.
int shadow_form(int form) {
	return form == BF_COURTYARD ? BF_FLAT : form;
}

void vertex() {
	vec2 ax = MODEL_MATRIX[0].xy;
	vec2 ay = MODEL_MATRIX[1].xy;
	float hl = max(length(ax), 1e-4);
	float hw = max(length(ay), 1e-4);
	vec2 ux = ax / hl;
	vec2 uy = ay / hw;
	v_half = vec2(hl, hw);
	int form = int(INSTANCE_CUSTOM.a * BF_FORM_SCALE);
	v_form = float(form);
	v_cell = INSTANCE_CUSTOM.b;
	float he = COLOR.r * BF_HEIGHT_RANGE;
	float hr = COLOR.g * BF_HEIGHT_RANGE;

	vec2 world_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xy;
	vec2 map_uv = (world_center - world_origin) / max(world_size, vec2(0.0001));
	float lat_signed = clamp(map_uv.y, 0.0, 1.0) * 2.0 - 1.0;
	EarthDaylight ed = eval_earth_daylight(map_uv, lat_signed, day_night_enabled);
	v_day = ed.local_day;
	vec2 off_w = -ed.sun_dir.xy / max(ed.sun_dir.z, 0.22) * shadow_height(form, he, hr);
	float reach = length(off_w);
	if (reach > SHADOW_MAX_REACH) {
		off_w *= SHADOW_MAX_REACH / reach;
	}
	v_shift = vec2(dot(off_w, ux), dot(off_w, uy));

	vec2 corner = VERTEX;
	vec2 normal = UV;
	vec2 p = v_shift * 0.5;
	if (dot(normal, normal) > 0.25) {
		if (bf_is_round(form)) {
			vec2 dir = normalize(corner + normal);
			p = dir * (v_half.y + SHADOW_MARGIN) * 1.08;
			normal = dir;
		} else {
			p = corner * (v_half + vec2(SHADOW_MARGIN));
		}
		if (dot(normal, v_shift) > 0.0) {
			p += v_shift;
		}
	}
	v_p = p;
	VERTEX = p / v_half * step(COLOR.a, lod_fraction);
}

void fragment() {
	int form = shadow_form(int(v_form + 0.5));
	vec2 s = v_p;
	float px = max(length(fwidth(v_p)) * 0.7, 1e-4);

	// Distance to the swept footprint, taking the sweep point nearest to s.
	float span = dot(v_shift, v_shift);
	float t = span > 1e-6 ? clamp(dot(s, v_shift) / span, 0.0, 1.0) : 0.0;
	float d = bf_footprint(form, s - v_shift * t, v_half);
	float soft = px + 0.05 + 0.08 * t * sqrt(span);
	float cast = 1.0 - smoothstep(-soft, soft, d);

	vec2 cell_uv = lut_uv(v_cell);
	float knowledge = texture(enum_lut, cell_uv).a;
	float live = step(0.88, knowledge);
	float darkness = cast * shadow_strength * v_day;

	// Contact occlusion survives night and overcast: it grounds the volume.
	float fg = bf_footprint(form, s, v_half);
	darkness = max(darkness, exp(-max(fg, 0.0) * 5.0) * 0.32);

	darkness *= mix(0.65, 1.0, live) * smoothstep(0.36, 0.54, camera_zoom);
	if (darkness < 0.003) discard;
	COLOR = vec4(mix(vec3(1.0), SHADOW_TINT, clamp(darkness, 0.0, 0.9)), 1.0);
}
