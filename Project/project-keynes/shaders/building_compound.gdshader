shader_type canvas_item;
render_mode unshaded;

uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform sampler2D weather_lut : filter_nearest, repeat_disable;
uniform sampler2D building_style_lut : filter_nearest, repeat_disable;
uniform sampler2D building_material_atlas : filter_linear_mipmap, repeat_disable;
uniform sampler2D building_material_mask_atlas : filter_linear_mipmap, repeat_disable;
uniform vec2 lut_dims = vec2(1.0);
uniform float cell_count = 1.0;
uniform float camera_zoom = 1.0;
uniform float geometry_alpha = 1.0;
uniform int visual_quality = 1;
uniform bool use_authored_atlas = false;
uniform vec2 atlas_grid = vec2(12.0, 6.0);
uniform float atlas_tile_size = 160.0;
uniform float compound_visual_scale = 0.144;

// Reuse the terrain/vegetation astronomical daylight source. Buildings derive
// one stable map UV from the instance centre; TOD remains a material update and
// never rewrites the MultiMesh buffer.
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
uniform float tod_exposure = 1.0;

// Windows are emissive only after the local sun has crossed into night.  Keep
// the transition soft so the whole map does not pop when the terminator moves.
const float BUILDING_WINDOW_NIGHT_START = 0.18;
const float BUILDING_WINDOW_NIGHT_FULL = 0.62;
const float BUILDING_WINDOW_LIGHT_GAIN = 0.72;
#include "res://shaders/include/earth_daylight.gdshaderinc"

varying flat float v_style;
varying flat float v_cell;
varying flat float v_seed;
varying flat float v_profile;
varying vec2 v_uv;
varying flat vec2 v_map_uv;

vec4 style_parameter(float style, float parameter_index) {
	return texture(building_style_lut,
		vec2((parameter_index + 0.5) / 8.0, (style + 0.5) / 66.0));
}

vec2 lut_uv(float cell_value) {
	float cell = clamp(floor(cell_value * max(cell_count - 1.0, 1.0) + 0.5),
		0.0, max(cell_count - 1.0, 0.0));
	float x = mod(cell, max(lut_dims.x, 1.0));
	float y = floor(cell / max(lut_dims.x, 1.0));
	return (vec2(x, y) + 0.5) / max(lut_dims, vec2(1.0));
}

float box_mask(vec2 p, vec2 center, vec2 half_size, float softness) {
	vec2 d = half_size - abs(p - center);
	return smoothstep(-softness, softness, min(d.x, d.y));
}

float roof_mask(vec2 p, float apex_y, float eave_y, float eave_half_width) {
	float span = max(eave_y - apex_y, 0.001);
	float t = clamp((p.y - apex_y) / span, 0.0, 1.0);
	float width = max(0.02, eave_half_width * t);
	float inside_y = smoothstep(apex_y - 0.028, apex_y + 0.028, p.y)
		* (1.0 - smoothstep(eave_y - 0.028, eave_y + 0.028, p.y));
	float inside_x = smoothstep(-0.035, 0.035, width - abs(p.x));
	return inside_y * inside_x;
}

float circle_mask(vec2 p, vec2 center, float radius) {
	return 1.0 - smoothstep(radius - 0.035, radius + 0.035,
		length(p - center));
}

void vertex() {
	v_style = floor(INSTANCE_CUSTOM.r * 65.0 + 0.5);
	v_seed = INSTANCE_CUSTOM.g;
	v_cell = INSTANCE_CUSTOM.b;
	v_profile = floor(INSTANCE_CUSTOM.a * 2.0 + 0.5);
	v_uv = UV;
	vec2 world_center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xy;
	v_map_uv = (world_center - world_origin) / max(world_size, vec2(0.0001));
	VERTEX *= compound_visual_scale;
}

vec3 era_base(float era) {
	if (era < 1.0) return vec3(0.49, 0.32, 0.18); // stone
	if (era < 2.0) return vec3(0.58, 0.43, 0.27); // agrarian
	if (era < 4.0) return vec3(0.54, 0.43, 0.32); // kingdom/empire
	if (era < 6.0) return vec3(0.57, 0.47, 0.37); // exploration/enlightenment
	if (era < 8.0) return vec3(0.42, 0.35, 0.31); // steam/electrical
	if (era < 9.0) return vec3(0.47, 0.47, 0.44); // atomic
	if (era < 10.0) return vec3(0.40, 0.50, 0.53); // information
	return vec3(0.43, 0.52, 0.54); // intelligent
}

vec3 archetype_tint(float archetype) {
	if (archetype < 0.5) return vec3(1.08, 0.96, 0.72); // agriculture
	if (archetype < 1.5) return vec3(0.78, 0.74, 0.68); // extractive
	if (archetype < 2.5) return vec3(0.98, 0.79, 0.65); // manufacturing
	if (archetype < 3.5) return vec3(0.70, 0.82, 0.88); // energy
	if (archetype < 4.5) return vec3(0.88, 0.90, 0.84); // knowledge
	return vec3(1.00, 0.82, 0.60); // service
}

void fragment() {
	if (use_authored_atlas) {
		float authored_era = floor(v_style / 6.0);
		float authored_archetype = mod(v_style, 6.0);
		// Band breakpoints mirror _style_palette so the authored and procedural
		// paths never disagree about what an era looks like.
		float art_era = authored_era < 2.0 ? 0.0
			: (authored_era < 6.0 ? 1.0 : (authored_era < 8.0 ? 2.0 : 3.0));
		float tile_index = (art_era * 6.0 + authored_archetype) * 3.0
			+ clamp(v_profile, 0.0, 2.0);
		vec2 tile = vec2(mod(tile_index, atlas_grid.x),
			floor(tile_index / atlas_grid.x));
		// Stay inside the tile so mip sampling cannot bleed a neighbour's roof
		// into this silhouette at far zoom.
		vec2 inset = vec2(0.5) / (atlas_grid * max(atlas_tile_size, 1.0));
		vec2 tile_uv = clamp(v_uv, inset, vec2(1.0) - inset);
		vec2 atlas_uv = (tile + tile_uv) / atlas_grid;
		vec4 authored = texture(building_material_atlas, atlas_uv);
		vec4 surface = texture(building_material_mask_atlas, atlas_uv);
		if (authored.a < 0.012) discard;

		vec2 authored_cell_uv = lut_uv(v_cell);
		vec4 authored_dyn = texture(dyn_lut, authored_cell_uv);
		vec4 authored_knowledge = texture(enum_lut, authored_cell_uv);
		vec4 authored_weather = texture(weather_lut, authored_cell_uv);
		vec4 authored_palette = style_parameter(v_style, 1.0);
		bool authored_live = authored_knowledge.a > 0.88;
		vec3 authored_color = authored.rgb;
		if (authored_live) {
			float authored_snow = authored_dyn.b * surface.r
				* authored_palette.a;
			authored_color = mix(authored_color, vec3(0.90, 0.93, 0.95),
				clamp(authored_snow, 0.0, 0.86));
			if (visual_quality > 0) {
				float authored_wet = authored_dyn.g * authored_weather.g * surface.g;
				authored_color *= 1.0 - authored_wet * 0.15;
				authored_color += vec3(0.022, 0.024, 0.026)
					* authored_wet * surface.a;
			}
		} else {
			float authored_gray = dot(authored_color, vec3(0.299, 0.587, 0.114));
			authored_color = mix(vec3(authored_gray), authored_color, 0.38) * 0.78;
		}
		float authored_lat = clamp(v_map_uv.y, 0.0, 1.0) * 2.0 - 1.0;
		EarthDaylight authored_ed = eval_earth_daylight(
			v_map_uv, authored_lat, day_night_enabled);
		// surface.r doubles as a conservative up-facing weight: roofs receive
		// more sky/direct light than walls while preserving the flat palette.
		float authored_up = clamp(surface.r, 0.0, 1.0);
		vec3 authored_light = authored_ed.amb_col * mix(0.72, 1.0, authored_up)
			+ authored_ed.sun_col * authored_ed.local_day
				* mix(0.12, 0.34, authored_up) * max(authored_ed.sun_dir.z, 0.0)
			+ authored_ed.moon_col * authored_ed.moon_strength
				* mix(0.05, 0.12, authored_up);
		authored_color *= max(authored_light, vec3(0.08)) * tod_exposure;
		// Windows are emissive only for live knowledge.  Fogged memory keeps its
		// remembered neutral appearance instead of receiving live TOD lighting.
		if (authored_live && surface.b > 0.001) {
			float authored_window_night = smoothstep(
				BUILDING_WINDOW_NIGHT_START, BUILDING_WINDOW_NIGHT_FULL,
				authored_ed.pixel_night);
			authored_color += vec3(1.0, 0.62, 0.24) * surface.b
				* authored_window_night * BUILDING_WINDOW_LIGHT_GAIN * tod_exposure;
		}
		float authored_alpha = authored.a * geometry_alpha
			* smoothstep(0.36, 0.54, camera_zoom);
		COLOR = vec4(authored_color, authored_alpha);
	} else {
	// Procedural fallback body, kept so a missing authored atlas still renders.
	float era = floor(v_style / 6.0);
	float archetype = mod(v_style, 6.0);
	vec2 uv = lut_uv(v_cell);
	vec4 dyn = texture(dyn_lut, uv);
	vec4 knowledge = texture(enum_lut, uv);
	vec4 weather = texture(weather_lut, uv);
	vec4 shape = style_parameter(v_style, 0.0);
	vec4 palette = style_parameter(v_style, 1.0);
	vec4 masks = texture(building_material_mask_atlas,
		vec2((archetype + 0.5) / 6.0, (era + 0.5) / 11.0));
	vec3 atlas_color = texture(building_material_atlas,
		vec2((archetype + 0.5) / 6.0, (era + 0.5) / 11.0)).rgb;
	vec3 base = mix(era_base(era) * archetype_tint(archetype),
		atlas_color, visual_quality > 0 ? 0.42 : 0.22);

	// The body is a compact orthographic house glyph. The dark foundation is
	// deliberately wider than the facade, while the two roof planes meet at a
	// visible ridge. This remains readable when the camera is exactly overhead.
	vec2 p = v_uv * 2.0 - 1.0;
	float steepness = clamp((shape.r - 0.72) / 0.52, 0.0, 1.0);
	float modern = smoothstep(7.0, 10.0, era);
	float apex_y = mix(-0.58, -0.82, steepness);
	apex_y = mix(apex_y, -0.43, modern * 0.70);
	float eave_y = 0.02;
	float roof_half = mix(0.66, 0.76, clamp(shape.g, 0.0, 1.0));
	float roof_outer = roof_mask(p, apex_y - 0.075, eave_y + 0.085,
		roof_half + 0.075);
	float roof = roof_mask(p, apex_y, eave_y, roof_half);
	float roof_left = roof * (1.0 - smoothstep(-0.025, 0.025, p.x));
	float roof_right = roof * smoothstep(-0.025, 0.025, p.x);
	float roof_ridge = box_mask(p, vec2(0.0, apex_y + 0.045),
		vec2(0.028, 0.075), 0.012);
	float eave = box_mask(p, vec2(0.0, eave_y + 0.045),
		vec2(roof_half + 0.035, 0.042), 0.016);

	float wall_height = mix(0.26, 0.34, clamp(shape.g, 0.0, 1.0));
	float wall_front = box_mask(p, vec2(-0.045, 0.30),
		vec2(0.50, wall_height), 0.025);
	float wall_side = box_mask(p, vec2(0.47, 0.30),
		vec2(0.15, wall_height * 0.94), 0.022);
	float foundation = box_mask(p, vec2(0.02, 0.61),
		vec2(0.59, 0.075), 0.022);
	float foundation_edge = box_mask(p, vec2(0.02, 0.64),
		vec2(0.64, 0.036), 0.012);

	vec3 foundation_color = vec3(0.105, 0.075, 0.055);
	vec3 wall_color = base * 1.13;
	vec3 side_color = base * 0.67;
	vec3 roof_left_color = base * 1.28;
	vec3 roof_right_color = base * 0.91;
	vec3 roof_outline = vec3(0.145, 0.095, 0.055);
	vec3 color = foundation_color * max(foundation, foundation_edge);
	color = mix(color, wall_color, wall_front);
	color = mix(color, side_color, wall_side);
	color = mix(color, roof_outline, roof_outer);
	color = mix(color, roof_left_color, roof_left);
	color = mix(color, roof_right_color, roof_right);
	color = mix(color, min(roof_left_color * 1.18, vec3(1.0)), roof_ridge * 0.72);
	color = mix(color, vec3(0.075, 0.052, 0.035), eave * 0.80);

	// A small chimney is behind the ridge. Its cap is intentionally visible
	// even at the strategic zoom so the silhouette cannot be mistaken for a
	// flat resource marker.
	float chimney = box_mask(p, vec2(-0.34, -0.22), vec2(0.065, 0.20), 0.014);
	float chimney_cap = box_mask(p, vec2(-0.34, -0.40), vec2(0.095, 0.035), 0.010);
	color = mix(color, vec3(0.19, 0.13, 0.095), chimney);
	color = mix(color, vec3(0.10, 0.072, 0.052), chimney_cap);

	// Door and two windows anchor the facade. They are larger and warmer than
	// the old micro marks so a single instance reads as a dwelling.
	float door_frame = box_mask(p, vec2(-0.20, 0.39), vec2(0.13, 0.225), 0.016);
	float door = box_mask(p, vec2(-0.20, 0.405), vec2(0.082, 0.19), 0.010);
	float window_l = box_mask(p, vec2(0.12, 0.235), vec2(0.105, 0.078), 0.014);
	float window_r = box_mask(p, vec2(0.36, 0.235), vec2(0.072, 0.072), 0.014);
	float windows = max(window_l, window_r);
	float window_glow = max(
		box_mask(p, vec2(0.12, 0.235), vec2(0.064, 0.040), 0.009),
		box_mask(p, vec2(0.36, 0.235), vec2(0.039, 0.036), 0.009));
	color = mix(color, vec3(0.14, 0.085, 0.048), door_frame);
	color = mix(color, vec3(0.050, 0.035, 0.025), door);
	color = mix(color, vec3(0.115, 0.085, 0.055), windows);
	color = mix(color, vec3(0.98, 0.72, 0.31), window_glow);

	// Category facilities are small secondary silhouettes on the same quad.
	// They change the reading of a compound without turning every type into a
	// separate node or material.
	float feature = 0.0;
	if (archetype < 0.5) {
		feature = box_mask(p, vec2(0.48, 0.61), vec2(0.20, 0.045), 0.010);
		feature = max(feature, box_mask(p, vec2(0.48, 0.53),
			vec2(0.16, 0.025), 0.008));
	} else if (archetype < 1.5) {
		feature = circle_mask(p, vec2(0.48, 0.58), 0.14);
		feature *= 0.70 + 0.18 * sin((p.x + v_seed) * 28.0);
	} else if (archetype < 2.5) {
		feature = box_mask(p, vec2(0.55, 0.07), vec2(0.048, 0.27), 0.010);
		feature = max(feature, box_mask(p, vec2(0.55, -0.21),
			vec2(0.11, 0.030), 0.008));
	} else if (archetype < 3.5) {
		feature = box_mask(p, vec2(0.51, 0.03), vec2(0.045, 0.31), 0.010);
		feature = max(feature, box_mask(p, vec2(0.51, -0.28),
			vec2(0.15, 0.028), 0.008));
	} else if (archetype < 4.5) {
		feature = circle_mask(p, vec2(0.43, -0.08), 0.15);
		feature *= step(-0.08, p.y);
	} else {
		feature = box_mask(p, vec2(0.45, 0.54), vec2(0.24, 0.065), 0.012);
		feature = max(feature, box_mask(p, vec2(0.45, 0.43),
			vec2(0.19, 0.023), 0.008));
	}
	vec3 feature_color = archetype < 1.5 ? vec3(0.17, 0.13, 0.09)
		: archetype < 3.5 ? vec3(0.105, 0.115, 0.12)
		: vec3(0.30, 0.23, 0.13);
	color = mix(color, feature_color, feature * 0.76);

	bool live_visible = knowledge.a > 0.88;
	float snow_roof_mask = max(roof_left, roof_right) + eave * 0.24;
	float snow = live_visible ? dyn.b * snow_roof_mask * palette.a * masks.r : 0.0;
	// Keep roof planes distinct under snow; only the brightest ridge becomes
	// white, preserving the house silhouette in a blizzard.
	color = mix(color, vec3(0.89, 0.92, 0.94), snow * 0.78);
	if (live_visible && visual_quality > 0) {
		float wet = dyn.g * weather.g * masks.g;
		color *= 1.0 - wet * 0.13;
		color += vec3(0.024, 0.021, 0.017) * wet * max(roof, wall_front);
	}
	if (!live_visible) {
		float gray = dot(color, vec3(0.299, 0.587, 0.114));
		color = mix(vec3(gray), color, 0.38) * 0.78;
	}
	float lat_signed = clamp(v_map_uv.y, 0.0, 1.0) * 2.0 - 1.0;
	EarthDaylight ed = eval_earth_daylight(v_map_uv, lat_signed, day_night_enabled);
	float roof_weight = clamp(max(roof, roof_ridge), 0.0, 1.0);
	vec3 building_light = ed.amb_col * mix(0.72, 1.0, roof_weight)
		+ ed.sun_col * ed.local_day * mix(0.12, 0.34, roof_weight)
			* max(ed.sun_dir.z, 0.0)
		+ ed.moon_col * ed.moon_strength * mix(0.05, 0.12, roof_weight);
	color *= max(building_light, vec3(0.08)) * tod_exposure;
	if (live_visible) {
		float window_night = smoothstep(BUILDING_WINDOW_NIGHT_START,
			BUILDING_WINDOW_NIGHT_FULL, ed.pixel_night);
		color += vec3(1.0, 0.62, 0.24) * window_glow
			* window_night * BUILDING_WINDOW_LIGHT_GAIN * tod_exposure;
	}

	float glyph = max(max(max(roof_outer, wall_front),
		max(wall_side, foundation)), max(chimney, max(feature, windows)));
	if (glyph < 0.01) discard;
	float alpha = glyph * geometry_alpha * smoothstep(0.36, 0.54, camera_zoom);
	COLOR = vec4(color, alpha);
	}
}
