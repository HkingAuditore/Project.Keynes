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
// 开阔水面本身的底色和环境光更暗，云影保留独立的响应比例。
// 默认 0.58：比陆地弱，但不会被海面 BRDF 和高光完全吞掉。
uniform float cloud_shadow_water_scale = 0.58;

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

// [cloud-tiling 2026-11-18] 软压缩的上限尺度。原来这里是硬 clamp(…, 0.60)：
// field 只要超过 0.60/strength≈0.7 就全部压成同一个常数，一块云心于是成了一片
// 完全同色的暗斑（"铁板"）；同时云影最深能吃掉 60% 直射 + 21% 环境，暗部直接
// 死黑。改成指数软膝后单调性保留（云心越厚仍然越暗），但永远碰不到平台。
const float CLOUD_SHADOW_SOFT_MAX = 0.85;

float cloud_shadow_amount(vec2 map_uv) {
	if (!cloud_shadow_field_bound || cloud_shadow_strength <= 0.0) {
		return 0.0;
	}
	vec2 uv = cloud_shadow_wrap_map_uv(map_uv);
	float raw = texture(cloud_shadow_tex, uv).r * cloud_shadow_strength;
	return CLOUD_SHADOW_SOFT_MAX * (1.0 - exp(-raw / CLOUD_SHADOW_SOFT_MAX));
}

float cloud_shadow_direct_visibility(vec2 map_uv, float local_day) {
	return 1.0 - cloud_shadow_amount(map_uv) * clamp(local_day, 0.0, 1.0);
}

float cloud_shadow_water_direct_visibility(vec2 map_uv, float local_day) {
	return 1.0 - cloud_shadow_amount(map_uv) * cloud_shadow_water_scale
		* clamp(local_day, 0.0, 1.0);
}

// 间接光用的遮蔽：幅度按 cloud_shadow_ambient_weight 缩放，弱于直射遮蔽，
// 避免山谷/夜景被压成死黑。无云影场时恒为 1.0。
float cloud_shadow_ambient_visibility(vec2 map_uv, float local_day) {
	return 1.0 - cloud_shadow_amount(map_uv) * cloud_shadow_ambient_weight
		* clamp(local_day, 0.0, 1.0);
}

float cloud_shadow_water_ambient_visibility(vec2 map_uv, float local_day) {
	return 1.0 - cloud_shadow_amount(map_uv) * cloud_shadow_ambient_weight
		* cloud_shadow_water_scale * clamp(local_day, 0.0, 1.0);
}
#else
float cloud_shadow_amount(vec2 map_uv) {
	return 0.0;
}

float cloud_shadow_direct_visibility(vec2 map_uv, float local_day) {
	return 1.0;
}

float cloud_shadow_water_direct_visibility(vec2 map_uv, float local_day) {
	return 1.0;
}

float cloud_shadow_ambient_visibility(vec2 map_uv, float local_day) {
	return 1.0;
}

float cloud_shadow_water_ambient_visibility(vec2 map_uv, float local_day) {
	return 1.0;
}
#endif
