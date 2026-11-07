// Shared direct-sun transmittance. Only desktop high-quality shader variants
// define PK_CLOUD_SHADOW_DIRECT; all other variants compile to a neutral value.
#ifdef PK_CLOUD_SHADOW_DIRECT
uniform sampler2D cloud_shadow_tex : filter_linear, repeat_disable;
uniform bool cloud_shadow_field_bound = false;
uniform float cloud_shadow_strength = 0.48;
uniform float cloud_shadow_wrap_origin_uv = 0.0;
uniform float cloud_shadow_wrap_period_uv = 0.0;
// 厚云时环境光/天光的额外衰减比例（0=完全不压，1=与直射同幅压暗）。
// 只压直射会让云影"发灰"，给间接光一点衰减才能读出乌云压顶的层次。
uniform float cloud_shadow_ambient_weight = 0.35;

vec2 cloud_shadow_wrap_map_uv(vec2 map_uv) {
	if (cloud_shadow_wrap_period_uv > 0.0001) {
		map_uv.x = cloud_shadow_wrap_origin_uv
			+ mod(map_uv.x - cloud_shadow_wrap_origin_uv, cloud_shadow_wrap_period_uv);
	} else {
		map_uv.x = clamp(map_uv.x, 0.0, 1.0);
	}
	map_uv.y = clamp(map_uv.y, 0.0, 1.0);
	return map_uv;
}

float cloud_shadow_amount(vec2 map_uv) {
	if (!cloud_shadow_field_bound || cloud_shadow_strength <= 0.0) {
		return 0.0;
	}
	vec2 uv = cloud_shadow_wrap_map_uv(map_uv);
	return clamp(texture(cloud_shadow_tex, uv).r * cloud_shadow_strength, 0.0, 0.60);
}

float cloud_shadow_direct_visibility(vec2 map_uv, float local_day) {
	return 1.0 - cloud_shadow_amount(map_uv) * clamp(local_day, 0.0, 1.0);
}

// 间接光用的遮蔽：幅度按 cloud_shadow_ambient_weight 缩放，弱于直射遮蔽，
// 避免山谷/夜景被压成死黑。无云影场时恒为 1.0。
float cloud_shadow_ambient_visibility(vec2 map_uv, float local_day) {
	return 1.0 - cloud_shadow_amount(map_uv) * cloud_shadow_ambient_weight
		* clamp(local_day, 0.0, 1.0);
}
#else
float cloud_shadow_amount(vec2 map_uv) {
	return 0.0;
}

float cloud_shadow_direct_visibility(vec2 map_uv, float local_day) {
	return 1.0;
}

float cloud_shadow_ambient_visibility(vec2 map_uv, float local_day) {
	return 1.0;
}
#endif
