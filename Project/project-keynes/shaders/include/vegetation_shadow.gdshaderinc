// vegetation_shadow.gdshaderinc
// Cast-shadow pass of vegetation layers: a soft ellipse per instance,
// stretched away from the local sun in the vertex stage. Crown-on-crown and
// in-patch ground shadows are drawn by the body pass; this pass carries the
// part that falls outside the instance quad.
//
// The ellipse length is the plant height over the sun elevation. Height is a
// world quantity, so for clusters and groves (bigger instances carrying
// smaller crowns, see vf_elem_radius) the local-frame length shrinks with the
// crown radius.

uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0, 1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
#define VT_USE_MAP_INDEX
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
uniform float lod_alpha = 1.0;

uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform float axial_tilt_rad = 0.41;
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);

uniform float vitality_dead_threshold = 0.12;
uniform float vitality_healthy_threshold = 0.72;
uniform float vitality_alpha_power = 1.10;
uniform float snow_hide_strength = 0.62;
uniform float aquatic_response = 0.0;

#ifdef DETAIL_FAMILY_BATCH
uniform sampler2D detail_style_lut : filter_nearest, repeat_disable;
uniform vec2 detail_style_lut_size = vec2(16.0, 32.0);
#endif

uniform vec4 shadow_color = vec4(0.05, 0.06, 0.08, 1.0);
uniform float shadow_strength = 0.32;
uniform float shadow_length_scale = 1.0;
uniform float shadow_max_len = 3.6;
uniform float shadow_min_sun_elevation = 0.16;
uniform float shadow_foot_radius = 0.55;
uniform float shadow_edge_softness = 0.25;

#include "res://shaders/include/earth_daylight.gdshaderinc"

varying float shadow_alpha_v;
varying float shadow_r;
varying float shadow_soft;

int sh_decode_cell_index(vec2 uv) {
	vec2 gb = visual_sample_map_index(uv).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

vec2 sh_cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) { lw = 1; }
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

float sh_vitality_norm(float vitality) {
	float dead_t = min(vitality_dead_threshold, vitality_healthy_threshold - 0.001);
	float healthy_t = max(vitality_healthy_threshold, dead_t + 0.001);
	return clamp((clamp(vitality, 0.0, 1.0) - dead_t) / (healthy_t - dead_t), 0.0, 1.0);
}

void vertex() {
	vec2 uv = clamp(INSTANCE_CUSTOM.rg, vec2(0.0), vec2(1.0));
#ifdef PK_QUALITY_LOW
	VERTEX = vec2(0.0);
	shadow_r = 1.0;
	shadow_alpha_v = 0.0;
	shadow_soft = 0.0;
#else
	float packed = max(INSTANCE_CUSTOM.a, 0.0);
	float casts = 1.0;
	float foot = shadow_foot_radius;
	float length_scale = shadow_length_scale;
	float strength = shadow_strength;
#ifdef DETAIL_FAMILY_BATCH
	float style_id = floor(packed * 0.25 + 0.0001);
	packed -= style_id * 4.0;
	vec4 style_shadow = texture(detail_style_lut,
		vec2(2.5, style_id + 0.5) / max(detail_style_lut_size, vec2(1.0)));
	casts = step(0.5, style_shadow.r);
	foot = style_shadow.g;
	length_scale = style_shadow.b;
	strength = style_shadow.a;
#endif
	float sub_form = floor(packed + 0.0001);
	float count = floor(clamp(packed - sub_form, 0.0, 0.9999) * 32.0) + 1.0;
	float crown_r = count < 1.5 ? 0.80 : min(0.58, 0.88 / sqrt(count));
	float height_local = crown_r / 0.80;

	float lat_signed = uv.y * 2.0 - 1.0;
	EarthDaylight ed = eval_earth_daylight(uv, lat_signed, day_night_enabled);

	int cid = sh_decode_cell_index(uv);
	vec4 dyn = (cid >= 0) ? texture(dyn_lut, sh_cell_lut_uv(cid)) : vec4(0.0);
	float vitality = mix(dyn.a, 0.86, aquatic_response);
	float snow = dyn.b;
	float presence = pow(sh_vitality_norm(vitality), vitality_alpha_power);
	presence *= 1.0 - clamp(snow, 0.0, 1.0) * snow_hide_strength;
	// Woody structure keeps a lighter shadow after the leaves are gone.
	presence = max(presence, smoothstep(0.0, 0.35, sh_vitality_norm(vitality)) * 0.45);

	vec2 sun_h = ed.sun_dir.xy;
	float sun_len = length(sun_h);
	float sun_up = max(ed.sun_dir.z, 0.0);
	vec2 sdir = (sun_len > 1e-4) ? -sun_h / sun_len : vec2(0.0, 1.0);
	float proj = clamp(sun_len / max(sun_up, shadow_min_sun_elevation), 0.0, shadow_max_len)
		* length_scale * height_local;

	vec2 inst_ax = vec2(MODEL_MATRIX[0].x, MODEL_MATRIX[0].y);
	float inst_axl = length(inst_ax);
	vec2 nax = (inst_axl > 1e-5) ? inst_ax / inst_axl : vec2(1.0, 0.0);
	vec2 nay = vec2(-nax.y, nax.x);
	vec2 sdl = vec2(dot(sdir, nax), dot(sdir, nay));
	vec2 perp = vec2(-sdl.y, sdl.x);

	vec2 p = VERTEX;
	float half_major = foot + proj * 0.5;
	float center_along = proj * 0.5;
	// Low sun: longer shadow, wider penumbra that also widens away from the plant.
	shadow_soft = clamp(proj / max(foot * 2.5, 1e-3), 0.0, 1.0);
	float spread = 1.0 + 0.45 * clamp(p.x, 0.0, 1.0) * shadow_soft;
	VERTEX = sdl * (center_along + p.x * half_major) + perp * (p.y * foot * spread);

	shadow_r = length(p);
	shadow_alpha_v = strength * lod_alpha * ed.local_day * clamp(presence, 0.0, 1.0) * casts
		* (sub_form > 1.5 ? 0.55 : (sub_form > 0.5 ? 0.80 : 1.0))
		* mix(1.0, 0.85, shadow_soft);
	if (shadow_alpha_v < 0.003) {
		VERTEX = vec2(0.0);
	}
#endif
}

void fragment() {
	float edge = 1.0 - smoothstep(mix(shadow_edge_softness, 0.0, shadow_soft), 1.0, shadow_r);
	float a = shadow_alpha_v * edge;
	if (a < 0.003) {
		discard;
	}
	COLOR = vec4(shadow_color.rgb, a);
}
