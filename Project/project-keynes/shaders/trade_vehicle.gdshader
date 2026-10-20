shader_type canvas_item;
render_mode unshaded;

uniform sampler2D path_texture : filter_nearest, repeat_disable;
uniform sampler2D visibility_texture : filter_nearest, repeat_disable;
uniform sampler2D vehicle_atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 route_info[32]; // point count, length, last observed wall second, active
uniform float visual_seconds = 0.0;
uniform float wall_seconds = 0.0;
uniform float camera_x = 0.0;
uniform float wrap_period = 0.0;
uniform float map_width = 1.0;
uniform bool fog_enabled = false;
uniform bool reduced_motion = false;
uniform float vehicle_size = 24.0;
uniform float layer_alpha = 1.0;
uniform float travel_speed = 11.0;
uniform float stale_fade_seconds = 2.0;
// Daylight and terrain use exactly the map/building addressing and decode.
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
uniform int visual_quality = 2;
uniform bool shadow_pass = false;
uniform float shadow_strength = 0.32;
uniform float shadow_height_ratio = 0.12;
uniform vec4 shadow_shapes[12]; // occupied UV center.xy and size.zw, from UITokens
uniform float shadow_heights[12];
uniform float shadow_max_length_ratio = 0.60;
uniform vec2 shadow_footprint = vec2(0.95, 0.90);
uniform float shadow_edge_softness = 0.35;
uniform vec4 shadow_color : source_color = vec4(0.11, 0.13, 0.17, 1.0);
#define VT_USE_HORIZON
#define VT_USE_TERRAIN_NORMAL
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
uniform bool terrain_normal_tex_bound = false;
uniform bool terrain_horizon_tex_bound = false;
uniform float terrain_horizon_max_angle = 1.309;
uniform float terrain_horizon_softness = 0.30;
uniform float terrain_horizon_strength = 0.90;
uniform float terrain_normal_influence = 0.65;
uniform bool gi_lut_bound = false;
uniform vec3 gi_horizon_lut[16];
uniform float gi_ao_strength = 0.90;
uniform float gi_ao_floor = 0.38;
uniform float gi_ao_smoothing = 0.75;
uniform float gi_bent_strength = 0.35;
uniform float gi_normal_floor = 0.85;
#include "res://shaders/include/earth_daylight.gdshaderinc"
vec2 wrap_map_uv(vec2 uv) { return visual_static_wrap_uv(uv); }
#include "res://shaders/include/terrain_horizon.gdshaderinc"

varying flat float sprite_row;
varying flat float vehicle_alpha;
varying flat vec3 vehicle_light;
varying vec2 sprite_uv;

// One canonical east-facing TRUE vertical view per vehicle. Rotating the quad
// gives every heading without mixing oblique frames or stretching the art.
vec4 atlas_sample(vec2 uv) {
	if (any(lessThan(uv, vec2(0.002))) || any(greaterThan(uv, vec2(0.998)))) {
		return vec4(0.0);
	}
	int style = clamp(int(sprite_row), 0, 11);
	return texture(vehicle_atlas, (vec2(float(style % 2), float(style / 2)) + uv) / vec2(2.0, 6.0));
}

float cell_visible(float payload) {
	if (!fog_enabled) { return 1.0; }
	int cell = int(round(payload)) / 4;
	int width = max(1, int(map_width));
	// MapData visibility bytes are 0/1, normalized R8 reads 1 as 1/255.
	return step(0.001, texelFetch(visibility_texture, ivec2(cell % width, cell / width), 0).r);
}

void vertex() {
	int row = clamp(int(INSTANCE_CUSTOM.x), 0, 31);
	vec4 info = route_info[row];
	int count = clamp(int(info.x), 2, 1024);
	float phase = INSTANCE_CUSTOM.y;
	float progress = reduced_motion ? phase : fract(phase + visual_seconds * travel_speed / max(info.y, 1.0));
	float distance = progress * info.y;
	int low = 0;
	int high = count - 1;
	for (int i = 0; i < 10; i++) {
		int mid = (low + high + 1) / 2;
		float cost = texelFetch(path_texture, ivec2(mid, row), 0).b;
		if (cost <= distance) { low = mid; } else { high = mid - 1; }
	}
	int edge = min(low, count - 2);
	vec4 a = texelFetch(path_texture, ivec2(edge, row), 0);
	vec4 b = texelFetch(path_texture, ivec2(edge + 1, row), 0);
	float t = clamp((distance - a.b) / max(b.b - a.b, 0.001), 0.0, 1.0);
	vec2 center = mix(a.rg, b.rg, t);
	if (wrap_period > 0.0) { center.x += round((camera_x - center.x) / wrap_period) * wrap_period; }
	vec2 direction = b.rg - a.rg;
	direction = normalize(direction + vec2(0.000001, 0.0));
	vec2 across = vec2(-direction.y, direction.x);
	int mode = int(round(a.a)) % 4;
	sprite_row = INSTANCE_CUSTOM.z + float(mode);
	vec4 first = texelFetch(path_texture, ivec2(0, row), 0);
	vec4 last = texelFetch(path_texture, ivec2(count - 1, row), 0);
	float visible = cell_visible(a.a) * cell_visible(b.a) * cell_visible(first.a) * cell_visible(last.a);
	float stale = info.w > 0.5 ? 1.0 : 1.0 - clamp((wall_seconds - info.z) / stale_fade_seconds, 0.0, 1.0);
	vehicle_alpha = visible * stale * layer_alpha;
	// Every vertex evaluates the SAME caravan center; no per-pixel terrain/TOD
	// fetches. Both passes share the immutable path and visibility textures.
	vec2 map_uv = (center - world_origin) / max(world_size, vec2(0.0001));
	EarthDaylight ed = eval_earth_daylight(map_uv, clamp(map_uv.y, 0.0, 1.0) * 2.0 - 1.0, day_night_enabled);
	vec3 n = vec3(0.0, 0.0, 1.0);
	TerrainHorizonSample hs;
	hs.direct_visibility = 1.0;
	hs.sky_visibility = 1.0;
	hs.bent_normal = n;
	hs.nearest_packed = vec4(0.0);
	hs.has_data = false;
	if (visual_quality >= 2) {
		if (terrain_normal_tex_bound) {
			n = normalize(vec3((visual_sample_terrain_normal(map_uv).rg * 2.0 - 1.0) * terrain_normal_influence, 1.0));
		}
		if (terrain_horizon_tex_bound && terrain_horizon_strength > 0.0) {
			hs = terrain_horizon_evaluate(map_uv, ed.sun_dir);
		}
	}
	vec3 amb_n = hs.has_data ? normalize(mix(n, hs.bent_normal, gi_bent_strength)) : n;
	float sky = hs.has_data ? terrain_horizon_apply_normal(hs.sky_visibility, n, hs.bent_normal) : 1.0;
	vec3 amb = earth_sky_sh(ed.amb_col, ed.sun_col, ed.sun_dir, ed.local_day, amb_n);
	float ndl = max(dot(n, ed.sun_dir), 0.0) * ed.local_day * hs.direct_visibility;
	float mdl = max(dot(n, -ed.sun_dir), 0.0) * ed.moon_strength;
	vehicle_light = (amb * mix(1.0, 0.62, ed.local_day) * sky + ed.sun_col * ndl * 0.78
		+ EARTH_MOONLIGHT * mdl * 0.40) * tod_exposure;
	vec2 scale = vec2(vehicle_size, vehicle_size * 0.5);
	vec2 expanded = vec2(1.0);
	vec2 shift = vec2(0.0);
	if (shadow_pass) {
		// Fit THIS sprite's occupied art, not its transparent atlas cell.
		int style = clamp(int(sprite_row), 0, 11);
		vec4 shape = shadow_shapes[style];
		vec2 foot_offset = (shape.xy - vec2(0.5)) * scale;
		center += direction * foot_offset.x + across * foot_offset.y;
		scale *= max(shape.zw * shadow_footprint, vec2(0.01));
		float relative_height = shadow_heights[style];
		float height = vehicle_size * shadow_height_ratio * relative_height;
		shift = -ed.sun_dir.xy / max(ed.sun_dir.z, 0.15) * height;
		float max_shift = vehicle_size * shadow_max_length_ratio * relative_height;
		shift *= min(1.0, max_shift / max(length(shift), 0.001));
		// Low sun still lengthens the ellipse, starting from the fitted footprint.
		vec2 offset_local = vec2(dot(shift, direction), dot(shift, across)) / scale;
		expanded += abs(offset_local);
		vehicle_alpha *= shadow_strength * ed.local_day * hs.direct_visibility
			* smoothstep(0.0, 0.15, ed.sun_dir.z) * (visual_quality >= 2 ? 1.0 : 0.0);
	}
	// QuadMesh UV.y is inverted; vertex local XY already has image-down Y.
	sprite_uv = VERTEX + vec2(0.5);
	vec2 local = VERTEX * expanded * scale;
	VERTEX = center + direction * local.x + across * local.y + shift * 0.5;
}

void fragment() {
	if (vehicle_alpha <= 0.001) { discard; }
	if (shadow_pass) {
		float radius = length((sprite_uv - vec2(0.5)) * 2.0);
		float coverage = 1.0 - smoothstep(1.0 - shadow_edge_softness, 1.0, radius);
		if (coverage * vehicle_alpha < 0.003) { discard; }
		COLOR = vec4(shadow_color.rgb, coverage * vehicle_alpha * shadow_color.a);
	} else {
		vec4 paint = atlas_sample(sprite_uv);
		if (paint.a < 0.025) { discard; }
		COLOR = vec4(paint.rgb * vehicle_light, paint.a * vehicle_alpha);
	}
}
