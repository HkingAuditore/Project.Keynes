// Offset-space data, independent of clouds: R density, G normalized fog top.
uniform sampler2DArray valley_fog_table : filter_nearest, repeat_disable;
uniform sampler2D valley_fog_noise : filter_linear_mipmap, repeat_enable;
uniform int valley_fog_cur_layer = 0;
uniform int valley_fog_prev_layer = 0;
uniform bool valley_fog_active = false;
uniform bool valley_fog_visibility_required = false;
uniform float valley_fog_sea_level = 0.0;
group_uniforms Valley_Fog;
uniform float valley_fog_extinction : hint_range(0.0, 128.0, 0.5) = 32.0;
uniform float valley_fog_opacity : hint_range(0.0, 1.0, 0.01) = 0.78;
uniform float valley_fog_top_offset : hint_range(-0.05, 0.05, 0.0005) = 0.0;
uniform float valley_fog_noise_height : hint_range(0.0, 0.02, 0.0005) = 0.005;
uniform float valley_fog_noise_period_hex : hint_range(4.0, 64.0, 1.0) = 28.0;
uniform float valley_fog_drift : hint_range(0.0, 160.0, 1.0) = 40.0;
uniform float valley_fog_filament_strength : hint_range(0.0, 0.75, 0.01) = 0.24;
uniform float valley_fog_side_light : hint_range(0.0, 0.5, 0.01) = 0.13;
uniform float valley_fog_far_opacity : hint_range(0.0, 1.0, 0.01) = 0.58;
uniform int valley_fog_detail : hint_enum("Static", "Flow", "Flow and Lighting") = 2;
uniform int valley_fog_debug : hint_enum("Off", "Ground Height", "Thickness", "Alpha") = 0;
group_uniforms;

const float WX_VALLEY_FOG_NOISE_SLOPE_RANGE = 16.0;

bool wx_valley_fog_in_bounds(ivec2 cell, PkHexGrid grid) {
	return cell.y >= 0 && cell.y < grid.map_h;
}

bool wx_valley_fog_has_cell_data() {
	return cell_table_bound && all(equal(cell_table_size, map_dims));
}

bool wx_valley_fog_visible(ivec2 cell) {
	return texelFetch(cell_table, ivec3(cell, PK_WX_CELL_LAYER_AUX), 0).b > 0.5;
}

bool wx_valley_fog_land(ivec2 cell) {
	int biome = int(texelFetch(cell_table, ivec3(cell, PK_WX_CELL_LAYER_CLASS), 0).r * 255.0 + 0.5);
	return biome != B_OCEAN && biome != B_COAST && biome != B_LAKE
			&& biome != B_REEF && biome != B_KELP && biome != B_SEA_ICE;
}

float wx_valley_fog_weight(ivec2 cell, float weight, PkHexGrid grid) {
	if (!wx_valley_fog_in_bounds(cell, grid)) {
		return 0.0;
	}
	if (valley_fog_visibility_required && !wx_valley_fog_visible(cell)) {
		return 0.0;
	}
	return weight;
}

vec2 wx_valley_fog_fetch(ivec2 cell, float weight) {
	if (weight <= 0.0) {
		return vec2(0.0);
	}
	vec2 value = texelFetch(valley_fog_table, ivec3(cell, valley_fog_cur_layer), 0).rg;
	if (weather_lerp < 0.999 && valley_fog_prev_layer != valley_fog_cur_layer) {
		vec2 previous = texelFetch(valley_fog_table, ivec3(cell, valley_fog_prev_layer), 0).rg;
		value = mix(previous, value, weather_lerp);
	}
	return value * weight;
}

vec2 wx_sample_valley_fog(PkHexTri tri, PkHexTri ground_tri, PkHexGrid grid, out vec3 weights) {
	weights = vec3(0.0);
	bool cell_data = wx_valley_fog_has_cell_data();
	if (valley_fog_visibility_required && !cell_data) {
		return vec2(0.0);
	}

	// 视野与水陆取未扭曲地块，避免天气形状扰动把实时谷雾搬到隔壁格。
	int dom = pk_hex_tri_dom(ground_tri);
	ivec2 owner = dom == 0 ? ground_tri.c0 : (dom == 1 ? ground_tri.c1 : ground_tri.c2);
	if (!wx_valley_fog_in_bounds(owner, grid)) {
		return vec2(0.0);
	}
	if (valley_fog_visibility_required && !wx_valley_fog_visible(owner)) {
		return vec2(0.0);
	}
	if (cell_data && !wx_valley_fog_land(owner)) {
		return vec2(0.0);
	}

	weights = vec3(wx_valley_fog_weight(tri.c0, tri.w_raw.x, grid),
			wx_valley_fog_weight(tri.c1, tri.w_raw.y, grid),
			wx_valley_fog_weight(tri.c2, tri.w_raw.z, grid));
	vec2 combined = wx_valley_fog_fetch(tri.c0, weights.x)
			+ wx_valley_fog_fetch(tri.c1, weights.y)
			+ wx_valley_fog_fetch(tri.c2, weights.z);
	// 缺失或隐藏格让密度淡出。其高度不参与插值，避免把雾顶拉到海平面以下。
	combined.y /= max(dot(weights, vec3(1.0)), 0.0001);
	return combined;
}

vec4 wx_shade_valley_fog(vec2 wp, vec2 ground_uv, vec2 world_dx, vec2 world_dy,
		vec2 fog, vec2 fog_wind, EarthDaylight daylight, out vec3 probe) {
	probe = vec3(0.0);
	if (fog.x <= 0.0 && valley_fog_debug != 1) {
		return vec4(0.0);
	}
	float ground = decode_height_rg8(ground_uv);
	probe.x = ground;
	// 陆格内的河床也可能低于海平面。有水陆分类时沿用格的归属，避免在河道上切出硬边。
	if (fog.x <= 0.0 || (!wx_valley_fog_has_cell_data() && ground <= valley_fog_sea_level)) {
		return vec4(0.0);
	}

	float base_thickness = fog.y + valley_fog_top_offset - ground;
	if (base_thickness <= -valley_fog_noise_height * 0.5) {
		return vec4(0.0);
	}
	float footprint = max(length(world_dx), length(world_dy)) / max(hex_size, 0.001);
	float height_noise = 0.0;
	vec2 surface_slope = vec2(0.0);
	float filament = 0.0;
	if (valley_fog_detail > 0) {
		float base_period = max(hex_size * valley_fog_noise_period_hex, 1.0);
		float wrap_tiles = max(round(wrap_period_x / base_period), 1.0);
		vec2 noise_scale = vec2(wrap_period_x > 0.0001 ? wrap_tiles / wrap_period_x : 1.0 / base_period,
				1.0 / base_period);
		vec2 noise_uv = (wp - vec2(wrap_origin_x, 0.0)) * noise_scale;
		vec2 grad_x = world_dx * noise_scale;
		vec2 grad_y = world_dy * noise_scale;
		vec3 phases = weather_flow_phases();
		// 云的风解码有 0.25 的最低速度偏置，谷雾静风时应停在原地。
		float wind_length = length(fog_wind);
		float drift = clamp((wind_length - 0.251) * valley_fog_drift, 0.0, hex_size * 0.7);
		vec2 displacement = fog_wind * (drift / max(wind_length, 0.001));
		vec4 a = textureGrad(valley_fog_noise, noise_uv - displacement * noise_scale * phases.x, grad_x, grad_y);
		vec4 b = textureGrad(valley_fog_noise, noise_uv - displacement * noise_scale * phases.y, grad_x, grad_y);
		vec4 noise_data = mix(b, a, phases.z);
		float amplitude = valley_fog_noise_height * smoothstep(0.0, 0.38, fog.x);
		height_noise = amplitude * (noise_data.r - 0.5);
		// GB 存同一高度的 UV 斜率。缩放同时应用于位移和斜率，保证方向光与雾面一致。
		surface_slope = (noise_data.gb * 2.0 - 1.0) * WX_VALLEY_FOG_NOISE_SLOPE_RANGE
				* noise_scale * amplitude * hex_size * 42.0;
		filament = (noise_data.a - 0.5) * (1.0 - smoothstep(0.16, 0.46, footprint));
	}

	float thickness = max(base_thickness + height_noise, 0.0);
	float optical_depth = fog.x * thickness * valley_fog_extinction;
	float transmission = exp(-optical_depth);
	// 雾丝只调制半透明部分；远景保留大轮廓，降低对道路和国界的遮挡。
	float body = 4.0 * transmission * (1.0 - transmission);
	float distance_fade = mix(1.0, valley_fog_far_opacity, smoothstep(0.35, 1.25, footprint));
	float alpha = (1.0 - exp(-optical_depth * (1.0 + filament * valley_fog_filament_strength * body)))
			* valley_fog_opacity * distance_fade * weather_strength;
	vec3 color = vec3(0.80, 0.88, 0.94);
	if (cloud_tod_tint_enabled) {
		color = clamp(daylight.amb_col * vec3(1.38, 1.33, 1.22), vec3(0.0), vec3(1.0));
		if (valley_fog_detail >= 2) {
			vec3 normal = normalize(vec3(-surface_slope, 1.0));
			float side = clamp(dot(normal.xy, daylight.sun_dir.xy), -0.65, 0.65);
			color += daylight.sun_col * (valley_fog_side_light * side * daylight.local_day);
		}
		color = clamp(color * tod_exposure, vec3(0.0), vec3(1.0));
	}
	probe.yz = vec2(clamp(thickness * valley_fog_extinction, 0.0, 1.0), alpha);
	return vec4(color, alpha);
}
