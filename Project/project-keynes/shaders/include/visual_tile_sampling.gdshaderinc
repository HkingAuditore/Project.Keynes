// Shared static-map raster addressing. Consumers define only the VT_USE_*
// fields they need before including this file.
vec2 visual_static_wrap_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = wrap_origin_x + mod(world_x - wrap_origin_x, wrap_period_x);
	return vec2((wrapped_x - world_origin.x) / world_size.x, clamp(uv.y, 0.0, 1.0));
}

#ifdef MAP_VISUAL_TILED
uniform vec2 visual_domain_origin = vec2(0.0);
uniform vec2 visual_domain_size = vec2(1.0);
uniform vec2 visual_grid_size = vec2(1.0);
uniform vec2 visual_interior_size = vec2(1.0);
uniform vec2 visual_layer_size = vec2(1.0);
uniform vec2 visual_logical_resolution = vec2(1.0);
uniform float visual_gutter_px = 2.0;

vec3 visual_tile_address(vec2 map_uv) {
	vec2 wp = world_origin + map_uv * world_size;
	if (wrap_period_x > 0.0001) {
		wp.x = wrap_origin_x + mod(wp.x - wrap_origin_x, wrap_period_x);
	}
	vec2 domain_uv = (wp - visual_domain_origin) / max(visual_domain_size, vec2(0.0001));
	if (wrap_period_x > 0.0001) {
		domain_uv.x = fract(domain_uv.x);
	} else {
		domain_uv.x = clamp(domain_uv.x, 0.0, 1.0 - 0.0000001);
	}
	domain_uv.y = clamp(domain_uv.y, 0.0, 1.0 - 0.0000001);
	vec2 scaled = domain_uv * visual_grid_size;
	vec2 tile_xy = min(floor(scaled), visual_grid_size - vec2(1.0));
	vec2 local01 = scaled - tile_xy;
	vec2 physical_px = vec2(visual_gutter_px) + local01 * visual_interior_size;
	float layer = tile_xy.y * visual_grid_size.x + tile_xy.x;
	return vec3(physical_px / visual_layer_size, layer);
}

vec2 visual_static_texture_size() {
	return visual_logical_resolution;
}
#endif

#ifdef VT_USE_HEIGHT
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_height_tiles : filter_linear, repeat_disable;
vec4 visual_sample_height(vec2 uv) { return texture(visual_height_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D height_tex : filter_linear, repeat_disable;
vec4 visual_sample_height(vec2 uv) { return texture(height_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

#ifdef VT_USE_TERRAIN_NORMAL
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_terrain_normal_tiles : filter_linear, repeat_disable;
vec4 visual_sample_terrain_normal(vec2 uv) { return texture(visual_terrain_normal_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D terrain_normal_tex : filter_linear, repeat_disable;
vec4 visual_sample_terrain_normal(vec2 uv) { return texture(terrain_normal_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

#ifdef VT_USE_HORIZON
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_horizon_tiles : filter_nearest, repeat_disable;
vec4 visual_sample_horizon(vec2 uv) { return texture(visual_horizon_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D terrain_horizon_tex : filter_nearest, repeat_disable;
vec4 visual_sample_horizon(vec2 uv) { return texture(terrain_horizon_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

#ifdef VT_USE_MAP_INDEX
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_map_index_tiles : filter_nearest, repeat_disable;
vec4 visual_sample_map_index(vec2 uv) { return texture(visual_map_index_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D map_index_atlas : filter_nearest, repeat_disable;
vec4 visual_sample_map_index(vec2 uv) { return texture(map_index_atlas, visual_static_wrap_uv(uv)); }
#endif
#ifndef MAP_VISUAL_TILED
vec2 visual_static_texture_size() { return vec2(textureSize(map_index_atlas, 0)); }
#endif
#endif

#ifdef VT_USE_FLOW
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_flow_tiles : filter_linear, repeat_disable;
vec4 visual_sample_flow(vec2 uv) { return texture(visual_flow_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D flow_tex : filter_linear, repeat_disable;
vec4 visual_sample_flow(vec2 uv) { return texture(flow_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

#ifdef VT_USE_WATER_DEPTH
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_water_depth_tiles : filter_linear, repeat_disable;
vec4 visual_sample_water_depth(vec2 uv) { return texture(visual_water_depth_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D water_depth_tex : filter_linear, repeat_disable;
vec4 visual_sample_water_depth(vec2 uv) { return texture(water_depth_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

#ifdef VT_USE_TERRAIN_DETAIL
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_terrain_detail_tiles : filter_linear, repeat_disable;
vec4 visual_sample_terrain_detail(vec2 uv) { return texture(visual_terrain_detail_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D terrain_detail_tex : filter_linear, repeat_disable;
vec4 visual_sample_terrain_detail(vec2 uv) { return texture(terrain_detail_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

#ifdef VT_USE_EDGE_NEIGHBOR
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_edge_neighbor_tiles : filter_nearest, repeat_disable;
vec4 visual_sample_edge_neighbor(vec2 uv) { return texture(visual_edge_neighbor_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D terrain_edge_neighbor_tex : filter_nearest, repeat_disable;
vec4 visual_sample_edge_neighbor(vec2 uv) { return texture(terrain_edge_neighbor_tex, visual_static_wrap_uv(uv)); }
#endif
#endif

#ifdef VT_USE_EDGE_DISTANCE
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_edge_distance_tiles : filter_linear, repeat_disable;
vec4 visual_sample_edge_distance(vec2 uv) { return texture(visual_edge_distance_tiles, visual_tile_address(uv)); }
#else
uniform sampler2D terrain_edge_distance_tex : filter_linear, repeat_disable;
vec4 visual_sample_edge_distance(vec2 uv) { return texture(terrain_edge_distance_tex, visual_static_wrap_uv(uv)); }
#endif
#endif
