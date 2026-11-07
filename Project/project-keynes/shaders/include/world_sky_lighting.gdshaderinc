#ifndef WORLD_SKY_LIGHTING_INC
#define WORLD_SKY_LIGHTING_INC

// Linear L1 diffuse irradiance coefficients, ordered DC, east, north, up.
uniform bool sky_ibl_bound = false;
uniform float sky_ambient_strength = 1.0;
uniform vec3 sky_day_sh_l1[4];
uniform vec3 sky_night_sh_l1[4];

uniform float sky_global_day_weight = 1.0;

#if defined(PK_SKY_HAS_IRRADIANCE)
uniform sampler2DArray sky_irradiance_array : filter_linear, repeat_disable;
uniform bool sky_irradiance_bound = false;
#endif

#if defined(PK_SKY_HAS_REFLECTION)
uniform sampler2DArray sky_specular_array : filter_linear, repeat_disable;
uniform bool sky_specular_bound = false;
uniform int sky_specular_level_count = 8;
uniform float sky_reflection_strength = 1.0;
#endif

const float SKY_RGBM_RANGE = 16.0;
const float SKY_PI = 3.14159265359;


vec3 sky_eval_profile_l1(float local_day, vec3 N) {
	vec3 n = normalize(N);
	vec3 day_directional = sky_day_sh_l1[1] * n.x
		+ sky_day_sh_l1[2] * n.y + sky_day_sh_l1[3] * n.z;
	vec3 night_directional = sky_night_sh_l1[1] * n.x
		+ sky_night_sh_l1[2] * n.y + sky_night_sh_l1[3] * n.z;
	vec3 day_value = sky_day_sh_l1[0] + day_directional * (2.0 / 3.0);
	vec3 night_value = sky_night_sh_l1[0] + night_directional * (2.0 / 3.0);
	return max(mix(night_value, day_value, clamp(local_day, 0.0, 1.0))
		* sky_ambient_strength, vec3(0.0));
}


vec3 sky_linear_to_srgb(vec3 color) {
	vec3 c = max(color, vec3(0.0));
	vec3 lo = c * 12.92;
	vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
	return mix(lo, hi, greaterThan(c, vec3(0.0031308)));
}


vec3 sky_srgb_to_linear(vec3 color) {
	vec3 c = max(color, vec3(0.0));
	vec3 lo = c / 12.92;
	vec3 hi = pow((c + 0.055) / 1.055, vec3(2.4));
	return mix(lo, hi, greaterThan(c, vec3(0.04045)));
}


vec3 sky_ambient_linear(float local_day, vec3 N,
		vec3 fallback_ambient, vec3 fallback_sun, vec3 sun_dir) {
	if (sky_ibl_bound) {
		return sky_eval_profile_l1(local_day, N);
	}
	return sky_srgb_to_linear(earth_sky_sh(
		fallback_ambient, fallback_sun, sun_dir, local_day, N));
}


vec3 sky_ambient_srgb(float local_day, vec3 N,
		vec3 fallback_ambient, vec3 fallback_sun, vec3 sun_dir) {
	if (sky_ibl_bound) {
		return sky_linear_to_srgb(sky_eval_profile_l1(local_day, N));
	}
	return earth_sky_sh(fallback_ambient, fallback_sun, sun_dir, local_day, N);
}


vec2 sky_octahedral_uv(vec3 direction) {
	vec3 n = normalize(direction);
	vec2 p = n.xy / max(abs(n.x) + abs(n.y) + abs(n.z), 0.000001);
	if (n.z < 0.0) {
		p = (1.0 - abs(p.yx)) * sign(p.xy);
	}
	return p * 0.5 + 0.5;
}


vec3 sky_decode_rgbm(vec4 encoded) {
	return encoded.rgb * encoded.a * SKY_RGBM_RANGE;
}


#if defined(PK_SKY_HAS_IRRADIANCE)
vec3 sky_sample_irradiance(vec3 N, float local_day) {
	vec2 uv = sky_octahedral_uv(N);
	vec3 day_value = sky_decode_rgbm(texture(sky_irradiance_array, vec3(uv, 0.0)));
	vec3 night_value = sky_decode_rgbm(texture(sky_irradiance_array, vec3(uv, 1.0)));
	return mix(night_value, day_value, clamp(local_day, 0.0, 1.0))
		* sky_ambient_strength;
}
#endif


#if defined(PK_SKY_HAS_REFLECTION)
vec3 sky_sample_prefiltered_reflection(vec3 direction, float roughness, float local_day) {
	int levels = max(sky_specular_level_count, 1);
	float level = floor(clamp(roughness, 0.0, 1.0) * float(levels - 1) + 0.5);
	vec2 uv = sky_octahedral_uv(direction);
	vec3 day_value = sky_decode_rgbm(texture(sky_specular_array, vec3(uv, level)));
	vec3 night_value = sky_decode_rgbm(texture(sky_specular_array, vec3(uv, level + float(levels))));
	return mix(night_value, day_value, clamp(local_day, 0.0, 1.0))
		* sky_reflection_strength;
}
#endif

#endif
