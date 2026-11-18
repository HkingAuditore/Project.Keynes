vec3 water_hash32(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yzz) * p3.zyx);
}

const int WATER_LATTICE_SIDE = 256;
const int WATER_LATTICE_Y_BIAS = 32;

vec2 water_ripple_seeds(float cycle0, float cycle1, float seed) {
	return vec2(seed, seed + 5.0) + mod(vec2(cycle0, cycle1), 997.0) * 13.7;
}
