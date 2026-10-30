// vegetation_impostor.gdshaderinc
// Body pass of every vegetation / decoration layer (ShrubLayer and the
// family batches built by VegetationFamilyLayer).
//
// The instance mesh is a single quad. Everything that only depends on the
// instance (cell climate, phenology palette, canopy sun/horizon and
// sky visibility) is evaluated in the vertex stage and passed flat; the
// fragment stage draws the top-down form from vegetation_forms and lights it.
// 高档贴地植被按片元世界位置采样法线、昼夜与 horizon/GI；树冠保留簇中心采样。
//
// custom.a packs sub_form + (count - 0.5) / 32 (see ShrubLayer.pack_form).
// Family batches add style_id * 4 and read per-style shading from the style
// LUT, so one material draws every profile of the family correctly.

uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D eco_lut : filter_nearest, repeat_disable;

// 移动高档也执行法线着色；只恢复植被这条路径，不改变 horizon 或其他移动特效开关。
#if !defined(PK_SKIP_VEGETATION_SHADING) || defined(PK_QUALITY_HIGH)
#define VEG_TERRAIN_SHADING
#endif

uniform vec2 lut_dims = vec2(1.0, 1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
#define VT_USE_MAP_INDEX
#define VT_USE_HEIGHT
#define VT_USE_TERRAIN_NORMAL
#define VT_USE_HORIZON
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"

uniform float world_time = 0.0;
uniform float season_phase = 1.0;
uniform float day_phase = 0.25;
uniform int detail_form = 3;
uniform float wind_strength = 1.0;
uniform float dry_yellow_strength = 0.82;
uniform float wet_green_strength = 0.48;
uniform float lush_green_strength = 0.72;
uniform float heat_red_strength = 0.55;
uniform float autumn_red_strength = 0.42;
uniform float temperature_color_strength = 0.78;
uniform float moisture_color_strength = 0.82;
uniform float snow_white_strength = 0.90;
uniform float stress_hide_strength = 0.78;
uniform float snow_hide_strength = 0.62;
uniform float disappear_alpha_threshold = 0.08;
uniform float lod_alpha = 1.0;
uniform bool lod_debug_view = false;
uniform float vitality_dead_threshold = 0.12;
uniform float vitality_healthy_threshold = 0.72;
uniform float vitality_alpha_power = 1.10;
uniform float vitality_size_min = 0.34;
uniform float vitality_size_max = 1.08;
uniform float vitality_low_color_strength = 0.72;
uniform float vitality_high_color_strength = 0.42;
uniform float vitality_color_contrast = 0.90;
uniform float aquatic_response = 0.0;
// 0 = decoration archetypes (rock, snow, snag) keep their own colour; 1 = plants.
uniform float veg_response = 1.0;
uniform float phenology_response = 1.0;
uniform float phenology_color_dominance = 0.64;
uniform float albedo_light_floor = 0.38;
uniform float color_saturation_gain = 1.0;
uniform float color_value_gain = 1.0;
uniform float snow_body_color_retention = 0.0;
uniform float snow_alpha_loss_strength = 0.32;
uniform float snow_size_floor = 0.0;
uniform vec2 wind_dir = vec2(1.0, 0.18);
uniform float weather_wind_boost = 0.0;
uniform float bloom_strength = 0.0;
uniform float snow_burial = 0.55;
uniform float axial_tilt_rad = 0.41;
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);
uniform float tod_exposure = 1.0;

uniform bool terrain_normal_tex_bound = false;
uniform vec2 hm_resolution = vec2(2048.0, 1536.0);
uniform int veg_shade_quality = 2;
uniform bool terrain_horizon_tex_bound = false;
uniform float terrain_horizon_max_angle = 1.309;
uniform float terrain_horizon_softness = 0.30;
uniform float terrain_horizon_strength = 0.90;
uniform float terrain_horizon_cast_floor = 0.82;
uniform int terrain_horizon_debug_view = 0;
// Sky visibility GI shared with the terrain: plants must use the same horizon
// and LUT or valley shrubs float brighter than the ground they stand on.
uniform bool gi_lut_bound = false;
uniform vec3 gi_horizon_lut[16];
uniform float gi_ao_strength : hint_range(0.0, 1.0) = 0.90;
uniform float gi_ao_floor : hint_range(0.0, 1.0) = 0.38;
uniform float gi_bent_strength : hint_range(0.0, 1.0) = 0.35;
uniform float gi_normal_floor : hint_range(0.0, 1.0) = 0.85;
uniform float shading_enabled = 1.0;
uniform float terrain_normal_influence = 0.65;
uniform float sun_shade_strength = 0.55;
uniform float ambient_floor = 0.18;
uniform float contact_ao_strength = 0.42;
uniform float terrain_valley_ao_strength = 0.40;
uniform float terrain_valley_ao_gain = 6.0;

#ifdef DETAIL_FAMILY_BATCH
uniform sampler2D detail_style_lut : filter_nearest, repeat_disable;
uniform vec2 detail_style_lut_size = vec2(16.0, 32.0);
vec4 detail_style_param(float style_id, float slot) {
	vec2 uv = vec2((slot + 0.5) / detail_style_lut_size.x,
		(style_id + 0.5) / detail_style_lut_size.y);
	return texture(detail_style_lut, uv);
}
#endif

#include "res://shaders/include/earth_daylight.gdshaderinc"
#include "res://shaders/include/vegetation_climate.gdshaderinc"
#include "res://shaders/include/vegetation_forms.gdshaderinc"

const float VEG_QUAD_HALF = 0.62;

varying flat vec4 v_a;  // seed, count, sub_form, leaf
varying flat vec4 v_b;  // vigor, bloom, form, albedo floor
varying flat vec4 v_c;  // wind dir (local), sway offset (local)
varying flat vec4 v_d;  // autumn red colour, red support
varying flat vec4 v_e;  // climate foliage colour, veg_response
varying flat vec4 v_f;  // snow amount, snow cap retention, body alpha, floor alpha
varying flat vec4 v_g;  // instance x axis, terrain normal xy
varying flat vec4 v_h;  // sun direction, valley ao
varying flat vec4 v_i;  // local day, sun high, moon, horizon visibility
varying flat vec4 v_j;  // bent normal, sky visibility
#ifdef VEG_TERRAIN_SHADING
varying vec2 v_ground_uv; // 不在顶点 wrap，避免跨地图接缝时插值穿过整张图。
#endif

float shrub_decode_height(vec2 uv) {
	vec2 rg = visual_sample_height(uv).rg;
	return (rg.r * 256.0 + rg.g) / 257.0;
}

vec2 shrub_wrap_map_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = wrap_origin_x + mod(world_x - wrap_origin_x, wrap_period_x);
	float ux = (wrapped_x - world_origin.x) / max(world_size.x, 1e-5);
	return vec2(ux, clamp(uv.y, 0.0, 1.0));
}

float shrub_horizon_unpack_byte(vec4 packed, int channel_index) {
	if (channel_index == 0) return floor(packed.r * 255.0 + 0.5);
	if (channel_index == 1) return floor(packed.g * 255.0 + 0.5);
	if (channel_index == 2) return floor(packed.b * 255.0 + 0.5);
	return floor(packed.a * 255.0 + 0.5);
}

float shrub_horizon_unpack_nibble(vec4 packed, int dir_index) {
	int ch = dir_index / 2;
	float byte_v = shrub_horizon_unpack_byte(packed, ch);
	float hi = floor(byte_v / 16.0);
	float lo = byte_v - hi * 16.0;
	return ((dir_index % 2) == 0) ? hi : lo;
}

float shrub_horizon_angle_by_index(vec4 packed, int dir_index) {
	int idx = dir_index;
	if (idx < 0) idx += 8;
	if (idx >= 8) idx -= 8;
	return (shrub_horizon_unpack_nibble(packed, idx) / 15.0) * terrain_horizon_max_angle;
}

float shrub_horizon_angle_from_packed(vec4 packed, float sector) {
	int i0 = int(floor(sector));
	float t = fract(sector);
	return mix(shrub_horizon_angle_by_index(packed, i0), shrub_horizon_angle_by_index(packed, i0 + 1), t);
}

float shrub_sample_horizon_angle(vec2 uv, vec2 sun_xy) {
	float angle = atan(sun_xy.y, sun_xy.x);
	if (angle < 0.0) angle += 6.2831853;
	float sector = angle / 0.78539816;
	vec2 dims = visual_static_texture_size();
	vec2 p = shrub_wrap_map_uv(uv) * dims - vec2(0.5);
	vec2 b = floor(p);
	vec2 f = fract(p);
	vec2 inv_dims = 1.0 / max(dims, vec2(1.0));
	vec2 uv00 = shrub_wrap_map_uv((b + vec2(0.5, 0.5)) * inv_dims);
	vec2 uv10 = shrub_wrap_map_uv((b + vec2(1.5, 0.5)) * inv_dims);
	vec2 uv01 = shrub_wrap_map_uv((b + vec2(0.5, 1.5)) * inv_dims);
	vec2 uv11 = shrub_wrap_map_uv((b + vec2(1.5, 1.5)) * inv_dims);
	float h00 = shrub_horizon_angle_from_packed(visual_sample_horizon(uv00), sector);
	float h10 = shrub_horizon_angle_from_packed(visual_sample_horizon(uv10), sector);
	float h01 = shrub_horizon_angle_from_packed(visual_sample_horizon(uv01), sector);
	float h11 = shrub_horizon_angle_from_packed(visual_sample_horizon(uv11), sector);
	return mix(mix(h00, h10, f.x), mix(h01, h11, f.x), f.y);
}

float shrub_horizon_direct_visibility(vec2 uv, vec3 light_dir) {
#ifdef PK_SKIP_HORIZON_SHADOWS
	return 1.0;
#else
	if (!terrain_horizon_tex_bound || veg_shade_quality < 1 || terrain_horizon_strength <= 0.0) {
		return 1.0;
	}
	vec2 sun_xy = light_dir.xy;
	float sun_h_len = length(sun_xy);
	if (sun_h_len <= 1e-4) return 1.0;
	sun_xy /= sun_h_len;
	float horizon_angle = shrub_sample_horizon_angle(uv, sun_xy);
	float sun_elev = atan(max(light_dir.z, 0.0) / max(sun_h_len, 1e-4));
	float shadow = smoothstep(sun_elev - terrain_horizon_softness,
		sun_elev + terrain_horizon_softness, horizon_angle);
	float horizon_day_w = smoothstep(-0.14, 0.18, light_dir.z);
	return clamp(1.0 - shadow * terrain_horizon_strength * horizon_day_w, 0.0, 1.0);
#endif
}

const float SHRUB_GI_INV_SQRT2 = 0.70710678;
const vec2 SHRUB_GI_DIRECTIONS[8] = vec2[8](
	vec2(1.0, 0.0), vec2(SHRUB_GI_INV_SQRT2, SHRUB_GI_INV_SQRT2),
	vec2(0.0, 1.0), vec2(-SHRUB_GI_INV_SQRT2, SHRUB_GI_INV_SQRT2),
	vec2(-1.0, 0.0), vec2(-SHRUB_GI_INV_SQRT2, -SHRUB_GI_INV_SQRT2),
	vec2(0.0, -1.0), vec2(SHRUB_GI_INV_SQRT2, -SHRUB_GI_INV_SQRT2)
);

struct ShrubSkySample {
	float visibility;
	vec3 bent_normal;
};

// Same formula as terrain_horizon.gdshaderinc (V_sky = 1/8 sum cos^2 h_d),
// Caller chooses the canopy anchor or the high-quality ground pixel UV.
ShrubSkySample shrub_sample_sky(vec2 uv) {
	ShrubSkySample s;
	s.visibility = 1.0;
	s.bent_normal = vec3(0.0, 0.0, 1.0);
#ifdef PK_SKIP_HORIZON_SHADOWS
	return s;
#else
	if (!terrain_horizon_tex_bound || !gi_lut_bound || veg_shade_quality < 1) return s;
	vec4 packed = visual_sample_horizon(shrub_wrap_map_uv(uv));
	vec4 bytes = floor(packed * 255.0 + 0.5);
	vec4 hi = floor(bytes * 0.0625);
	vec4 lo = bytes - hi * 16.0;
	int nibbles[8];
	nibbles[0] = int(hi.r); nibbles[1] = int(lo.r);
	nibbles[2] = int(hi.g); nibbles[3] = int(lo.g);
	nibbles[4] = int(hi.b); nibbles[5] = int(lo.b);
	nibbles[6] = int(hi.a); nibbles[7] = int(lo.a);
	float sum = 0.0;
	vec3 bent = vec3(0.0);
	for (int d = 0; d < 8; d++) {
		vec3 entry = gi_horizon_lut[nibbles[d]];
		sum += entry.x;
		bent += entry.x * vec3(SHRUB_GI_DIRECTIONS[d] * entry.y, entry.z);
	}
	float v_scaled = mix(1.0, clamp(sum * 0.125, 0.0, 1.0), gi_ao_strength);
	s.visibility = clamp(mix(gi_ao_floor, 1.0, v_scaled), 0.0, 1.0);
	float bent_len = length(bent);
	s.bent_normal = (bent_len > 1e-4)
		? normalize(mix(vec3(0.0, 0.0, 1.0), bent / bent_len, gi_bent_strength))
		: vec3(0.0, 0.0, 1.0);
	return s;
#endif
}

int decode_cell_index(vec2 uv) {
	vec2 gb = visual_sample_map_index(uv).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

vec2 cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) {
		lw = 1;
	}
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

vec4 sample_dyn_state(vec2 uv) {
	int cid = decode_cell_index(uv);
	return (cid >= 0) ? texture(dyn_lut, cell_lut_uv(cid)) : vec4(0.0);
}

vec4 sample_eco_state(vec2 uv) {
#ifdef PK_QUALITY_LOW
	return vec4(0.0);
#else
	int cid = decode_cell_index(uv);
	return (cid >= 0) ? texture(eco_lut, cell_lut_uv(cid)) : vec4(0.0);
#endif
}

bool veg_form_has_skeleton(int form) {
	return form == VF_BROADLEAF || form == VF_SHRUB || form == VF_SNAG || form == VF_MANGROVE
		|| form == VF_CONIFER || form == VF_PALM || form == VF_CACTUS;
}

bool veg_form_is_canopy(int form) {
	return form == VF_BROADLEAF || form == VF_CONIFER || form == VF_PALM || form == VF_SNAG;
}

bool veg_form_follows_ground(int form) {
	return form == VF_GRASS || form == VF_LICHEN || form == VF_PEAT_TUFT
		|| form == VF_FLOWER || form == VF_SHRUB;
}

void vertex() {
	float form_f = float(detail_form);
	float wind_s = wind_strength;
	float phen_resp = phenology_response;
	float phen_dom = phenology_color_dominance;
	float veg_resp = veg_response;
	float bloom_s = bloom_strength;
	float snow_ret = snow_body_color_retention;
	float alb_floor = albedo_light_floor;
	float burial = snow_burial;
	float aquatic = aquatic_response;
	float size_floor = snow_size_floor;
	float sat_gain = color_saturation_gain;
	float val_gain = color_value_gain;
	float packed = max(INSTANCE_CUSTOM.a, 0.0);
#ifdef DETAIL_FAMILY_BATCH
	float style_id = floor(packed * 0.25 + 0.0001);
	packed -= style_id * 4.0;
	wind_s = detail_style_param(style_id, 0.0).r;
	vec4 s3 = detail_style_param(style_id, 3.0);
	vec4 s4 = detail_style_param(style_id, 4.0);
	vec4 s5 = detail_style_param(style_id, 5.0);
	form_f = s3.r;
	phen_resp = s3.g;
	phen_dom = s3.b;
	veg_resp = s3.a;
	bloom_s = s4.r;
	snow_ret = s4.g;
	alb_floor = s4.b;
	burial = s4.a;
	aquatic = s5.r;
	size_floor = s5.g;
	sat_gain = s5.b;
	val_gain = s5.a;
#endif
	int form = int(form_f + 0.5);
	float sub_form = floor(packed + 0.0001);
	float count = floor(clamp(packed - sub_form, 0.0, 0.9999) * 32.0) + 1.0;
	float seed = INSTANCE_CUSTOM.b;

	vec2 inst_ax = MODEL_MATRIX[0].xy;
	float inst_axl = length(inst_ax);
	vec2 bx = (inst_axl > 1e-5) ? inst_ax / inst_axl : vec2(1.0, 0.0);
	vec2 by = vec2(-bx.y, bx.x);
	vec2 uv = clamp(INSTANCE_CUSTOM.rg, vec2(0.0), vec2(1.0));
	vec4 dyn = sample_dyn_state(uv);
	vec4 eco = sample_eco_state(uv);
	VegCellState cs = veg_cell_state(dyn, eco, aquatic);
	float presence = veg_presence(cs, dyn, phen_resp);
	float vit_n = veg_vitality_norm(cs.vitality);

	bool skeleton = veg_form_has_skeleton(form);
	bool canopy = veg_form_is_canopy(form);
	float vigor = smoothstep(0.0, 0.35, vit_n);
	float leaf = smoothstep(0.04, 0.70, presence);
	if (form == VF_SNAG) {
		leaf = 0.0;
	}
	if (form == VF_ROCK || form == VF_SCREE || form == VF_FALLEN_LOG || form == VF_SNOW_MOUND) {
		vigor = 1.0;
		leaf = 1.0;
	}
	float body_alpha = skeleton ? max(presence, vigor * 0.92) : presence;
	if (form == VF_ROCK || form == VF_SCREE || form == VF_FALLEN_LOG) {
		body_alpha = 1.0;
	}
	if (form == VF_SNOW_MOUND) {
		body_alpha = smoothstep(0.05, 0.35, cs.snow);
	}
	body_alpha *= 1.0 - cs.snow * snow_alpha_loss_strength * (skeleton ? 0.25 : 1.0)
		* (form == VF_SNOW_MOUND ? 0.0 : 1.0);
	body_alpha *= lod_alpha * min(COLOR.a * 1.25, 1.0);

	float scale = 1.0;
	if (canopy) {
		scale = mix(0.86, 1.0, vigor);
	} else if (skeleton) {
		scale = mix(0.55, 1.0, smoothstep(0.0, 0.85, max(presence, vigor * 0.6)));
	} else if (form != VF_ROCK && form != VF_SCREE && form != VF_FALLEN_LOG && form != VF_SNOW_MOUND) {
		scale = mix(0.30, 1.0, smoothstep(0.0, 0.85, presence));
		scale *= mix(vitality_size_min, vitality_size_max, pow(vit_n, 0.85));
	}
	float snow_restore = smoothstep(0.12, 0.72, cs.snow);
	scale = max(scale, mix(scale, size_floor, snow_restore));
	float bury = clamp(cs.snow * burial, 0.0, 0.85);
	scale *= 1.0 - bury * 0.36;
	bool hidden = body_alpha < disappear_alpha_threshold;
	VERTEX *= hidden ? 0.0 : scale;
#ifdef VEG_TERRAIN_SHADING
	v_ground_uv = ((MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy - world_origin)
		/ max(world_size, vec2(0.00001));
#endif

	vec2 wdir = normalize(wind_dir + vec2(0.0001, 0.0));
	vec2 wdir_local = vec2(dot(wdir, bx), dot(wdir, by));
	float sway = sin(world_time * (0.75 + fract(seed * 7.7) * 1.65) + seed * 6.2831853);
	sway += 0.45 * sin(world_time * 1.7 + seed * 11.0);
	sway += weather_wind_boost * (0.9 * sin(world_time * 3.4 + seed * 5.13) + 0.5);
	float sway_amp = mix(0.010, 0.024, fract(seed * 17.13)) * (wind_s + weather_wind_boost)
		* (canopy ? 1.0 : 1.8) * smoothstep(0.10, 0.75, presence);
	vec2 sway_off = wdir_local * sway * sway_amp;

	VegPalette pal = veg_palette(COLOR.rgb, cs, seed, phen_resp, phen_dom, veg_resp, sat_gain, val_gain);
	float bloom = bloom_s * clamp(pal.sprouting * 1.8 + presence * 0.35, 0.0, 1.0)
		* vit_n * (1.0 - pal.snow_amt * 0.85);

	float lat_signed = uv.y * 2.0 - 1.0;
	EarthDaylight ed = eval_earth_daylight(uv, lat_signed, day_night_enabled);
	bool pixel_ground = false;
#ifdef VEG_TERRAIN_SHADING
	pixel_ground = veg_shade_quality >= 2 && veg_form_follows_ground(form);
#endif
	// High-quality ground samples these at its actual surface below; do not pay
	// for both an anchor horizon lookup and the per-pixel lookup.
	float horizon_vis = 1.0;
	ShrubSkySample sky;
	sky.bent_normal = vec3(0.0, 0.0, 1.0);
	sky.visibility = 1.0;
	if (!pixel_ground) {
		horizon_vis = shrub_horizon_direct_visibility(uv, ed.sun_dir);
		sky = shrub_sample_sky(uv);
	}

	vec2 terrain_n = vec2(0.0);
	float valley_ao = 0.0;
#ifdef VEG_TERRAIN_SHADING
	bool pixel_terrain = veg_shade_quality >= 2 && veg_form_follows_ground(form);
	bool terrain_shading = true;
#ifdef PK_SKIP_VEGETATION_SHADING
	terrain_shading = pixel_terrain;
#endif
	if (terrain_shading && terrain_normal_tex_bound && !pixel_terrain) {
		terrain_n = (visual_sample_terrain_normal(uv).rg * 2.0 - 1.0) * terrain_normal_influence;
	}
	if (terrain_shading && veg_shade_quality >= 2 && terrain_valley_ao_strength > 0.0 && !gi_lut_bound) {
		vec2 texel = 3.0 / hm_resolution;
		float hc = shrub_decode_height(uv);
		float hn = (shrub_decode_height(uv + vec2(texel.x, 0.0))
			+ shrub_decode_height(uv - vec2(texel.x, 0.0))
			+ shrub_decode_height(uv + vec2(0.0, texel.y))
			+ shrub_decode_height(uv - vec2(0.0, texel.y))) * 0.25;
		valley_ao = clamp((hn - hc) * terrain_valley_ao_gain, 0.0, 1.0);
	}
#endif

	float floor_alpha = (skeleton ? max(presence, vigor) : presence) * lod_alpha;
	if (form == VF_ROCK || form == VF_SCREE || form == VF_FALLEN_LOG || form == VF_SNOW_MOUND) {
		floor_alpha = body_alpha;
	}
	v_a = vec4(seed, count, sub_form, leaf);
	v_b = vec4(vigor, bloom, form_f, alb_floor);
	v_c = vec4(wdir_local, sway_off);
	v_d = vec4(pal.red_col, pal.red_amt);
	v_e = vec4(pal.leaf, veg_resp);
	v_f = vec4(pal.snow_amt, snow_ret, hidden ? 0.0 : body_alpha, hidden ? 0.0 : floor_alpha);
	v_g = vec4(bx, terrain_n);
	v_h = vec4(ed.sun_dir, valley_ao);
	v_i = vec4(ed.local_day, ed.sun_high, ed.moon_strength, horizon_vis);
	v_j = vec4(sky.bent_normal, sky.visibility);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float px = max(length(fwidth(p)) * 0.75, 1e-4);
	VegCtx ctx;
	ctx.seed = v_a.x;
	ctx.count = v_a.y;
	ctx.sub_form = v_a.z;
	ctx.leaf = v_a.w;
	ctx.vigor = v_b.x;
	ctx.bloom = v_b.y;
	ctx.wind = v_c.xy;
	ctx.time = world_time;
	ctx.px = px;
	int form = int(v_b.z + 0.5);
	vec2 pe = p - v_c.zw;

	float elem_px = vf_elem_radius(ctx.count) / px;
#ifdef PK_MOBILE_ANY
	bool far = elem_px < 6.0;
#else
	bool far = elem_px < 3.0;
#endif
	// GLSL ES 3.0 (the Compatibility/WebGL2 backend) rejects `?:` when the
	// operands are structs, which the old one-liner `far ? vf_far(...) :
	// vf_eval(...)` did. Branch instead so the desktop (SPIR-V) and web builds
	// share one source.
	VegSurf s = vf_empty();
	if (far) {
		s = vf_far(form, pe, ctx);
	} else {
		s = vf_eval(form, pe, ctx, false);
	}

	vec3 L = v_h.xyz;
	vec4 daylight = v_i;
	vec4 sky = v_j;
#ifdef VEG_TERRAIN_SHADING
	if (veg_shade_quality >= 2 && veg_form_follows_ground(form)) {
		vec2 ground_uv = shrub_wrap_map_uv(v_ground_uv);
		EarthDaylight ed = eval_earth_daylight(ground_uv, ground_uv.y * 2.0 - 1.0, day_night_enabled);
		L = ed.sun_dir;
		daylight = vec4(ed.local_day, ed.sun_high, ed.moon_strength,
			shrub_horizon_direct_visibility(ground_uv, L));
		ShrubSkySample ground_sky = shrub_sample_sky(ground_uv);
		sky = vec4(ground_sky.bent_normal, ground_sky.visibility);
	}
#endif
	vec2 bx = v_g.xy;
	vec2 by = vec2(-bx.y, bx.x);
	float local_day = daylight.x;
	float sun_vis = 1.0;
	float floor_shadow = 0.0;
#ifndef PK_MOBILE_ANY
	float hs = vf_height_scale(form);
	if (!far && veg_shade_quality >= 2 && local_day > 0.02 && hs > 0.1) {
		vec2 sl = vec2(dot(L.xy, bx), dot(L.xy, by)) / max(L.z, 0.28);
		vec2 sh = vf_soft_shadow(pe, ctx, form, -sl * hs);
		sun_vis = 1.0 - sh.y * 0.50 * step(0.001, s.cov);
		// Fade before the quad border so the shadow never shows a straight cut.
		vec2 ap = abs(p);
		floor_shadow = sh.x * (1.0 - smoothstep(0.72, 0.98, max(ap.x, ap.y)));
	}
#endif

	float body_a = s.cov * v_f.z;
	float floor_a = max(s.floor_a * contact_ao_strength * 2.0,
		floor_shadow * 0.70 * local_day * daylight.w) * v_f.w * (1.0 - s.cov);
	if (body_a + floor_a < 0.004) {
		discard;
	}

	vec3 n_loc = s.n;
	vec2 terrain_n = v_g.zw;
#ifdef VEG_TERRAIN_SHADING
	if (veg_shade_quality >= 2 && veg_form_follows_ground(form) && terrain_normal_tex_bound) {
		terrain_n = (visual_sample_terrain_normal(v_ground_uv).rg * 2.0 - 1.0) * terrain_normal_influence;
	}
#endif
	vec3 N = normalize(vec3(n_loc.x * bx + n_loc.y * by + terrain_n * n_loc.z, n_loc.z));
	vec3 leaf = v_e.rgb;
	leaf *= 0.90 + 0.20 * fract(s.elem * 13.7 + ctx.seed);
	float red_pick = smoothstep(0.40, 0.70, fract(s.elem * 7.31 + ctx.seed * 3.3));
	leaf = mix(leaf, v_d.rgb, red_pick * v_d.a);
	if (s.art.a > 0.0) {
		// Crown bitmap hue at the climate palette's brightness: drought/autumn/snow still
		// drive the colour, the sprite keeps its own species tint and leaf detail.
		// The sprites are summer green, so their hue weight fades as the palette leaves
		// green (autumn gold/red, drought straw, cold grey); s.tone keeps the leaf detail.
		float leaf_l = dot(leaf, vec3(0.299, 0.587, 0.114));
		float greenness = smoothstep(0.08, 0.35, (leaf.g - max(leaf.r, leaf.b)) / max(leaf.g, 0.01));
		leaf = mix(leaf, s.art.rgb * 2.0 * leaf_l, s.art.a * mix(0.15, 1.0, greenness));
	}
	vec3 albedo = mix(s.tint, leaf, s.leaf_w) * s.tone;
	float cap = smoothstep(0.35, 0.85, n_loc.z + (fract(s.elem * 5.3 + p.x * 3.1) - 0.5) * 0.16);
	float local_snow = v_f.x * s.snow_hold * mix(1.0, cap, max(v_f.y, 0.55));
	albedo = mix(albedo, vec3(0.93, 0.95, 0.99), clamp(local_snow, 0.0, 1.0));

	vec3 sun_col = mix(EARTH_DAYLIGHT_DUSK, EARTH_DAYLIGHT_NOON, daylight.y);
	vec3 amb_col = mix(EARTH_NIGHT_AMBIENT, EARTH_DAY_AMBIENT, local_day);
	if (!day_night_enabled) {
		sun_col *= EARTH_ETERNAL_SUN_GAIN;
		amb_col *= EARTH_ETERNAL_AMBIENT_GAIN;
	}
	vec3 rgb;
	bool use_shading = shading_enabled > 0.5;
#ifndef VEG_TERRAIN_SHADING
	use_shading = false;
#elif defined(PK_SKIP_VEGETATION_SHADING)
	use_shading = use_shading && veg_shade_quality >= 2 && veg_form_follows_ground(form);
#endif
	if (use_shading) {
		float wrap = 0.30 * s.leaf_w;
		float diff = clamp((dot(N, L) + wrap) / (1.0 + wrap), 0.0, 1.0);
		float direct = diff * local_day * daylight.w * sun_vis;
		vec3 bent = sky.xyz;
		vec3 amb_n = N;
		if (gi_bent_strength > 0.0) {
			vec3 mixed_n = mix(N, bent, gi_bent_strength);
			amb_n = dot(mixed_n, mixed_n) > 1e-6 ? normalize(mixed_n) : N;
		}
		float gi_ao = clamp(sky.w * mix(gi_normal_floor, 1.0, clamp(dot(N, bent), 0.0, 1.0)), 0.0, 1.0);
		vec3 amb = earth_sky_sh(amb_col, sun_col, L, local_day, amb_n) * gi_ao;
		float moon = max(dot(N, -L), 0.0) * daylight.z;
		vec3 light = max(amb * mix(1.0, 0.70, local_day), vec3(ambient_floor * 0.5))
			+ sun_col * direct * sun_shade_strength * 1.40
			+ EARTH_MOONLIGHT * moon * 0.35;
		rgb = albedo * light * s.ao;
		rgb *= 1.0 - v_h.w * terrain_valley_ao_strength * mix(0.38, 1.0, v_e.a);
		rgb = max(rgb, albedo * v_b.w * 0.45 * mix(0.35, 1.0, local_day));
	} else {
		vec3 light = max(amb_col * sky.w, vec3(ambient_floor)) + sun_col * (local_day * 0.35 * daylight.w);
		rgb = albedo * light;
	}
	float horizon_cast = clamp((1.0 - daylight.w) * local_day, 0.0, 1.0);
	if (horizon_cast > 0.001) {
		float veg_floor = mix(1.0, terrain_horizon_cast_floor, 0.70);
		if (gi_lut_bound) {
			veg_floor = mix(1.0, veg_floor, mix(1.0, sky.w, gi_ao_strength));
		}
		rgb *= mix(1.0, veg_floor, horizon_cast);
	}
	rgb *= mix(1.0, 0.86, 1.0 - local_day);
	rgb *= tod_exposure;
	if (terrain_horizon_debug_view == 1) {
		rgb = vec3(clamp((1.0 - daylight.w) * local_day, 0.0, 1.0));
	} else if (terrain_horizon_debug_view == 2) {
		rgb = vec3(daylight.w);
	}
	if (lod_debug_view) {
		rgb = vec3(lod_alpha);
	}
	vec3 floor_col = mix(vec3(0.035, 0.05, 0.045), vec3(0.26, 0.31, 0.42), v_f.x * 0.7);
	if (veg_form_follows_ground(form)) {
		// Contact/snow in the gaps is still ground material, not an emissive
		// overlay. Keep its cool night palette and exposure with the vegetation.
		floor_col *= mix(EARTH_NIGHT_AMBIENT / EARTH_DAY_AMBIENT, vec3(1.0), local_day) * tod_exposure;
	}
	float a = body_a + floor_a;
	COLOR = vec4((rgb * body_a + floor_col * floor_a) / a, clamp(a, 0.0, 1.0));}
