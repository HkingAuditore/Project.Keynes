const int FOG_LATTICE_SIDE = 128;
const int FOG_LATTICE_Y_BIAS = 32;
const vec2 FOG_BANDS[10] = vec2[10](
	vec2(0.32, 0.0),
	vec2(0.29, 1.0),
	vec2(0.21, 2.0),
	vec2(0.24, 3.0),
	vec2(0.46, 0.0),
	vec2(0.68, 1.0),
	vec2(0.97, 2.0),
	vec2(1.31, 3.0),
	vec2(0.71, 5.0),
	vec2(0.68, 0.0));
vec2 fog_evolving_gradient(vec2 lattice, float t, float seed) {
	vec2 h = cloud_hash22(lattice);
	vec2 g = -1.0 + 2.0 * h;
	float direction = (h.x < 0.5) ? -1.0 : 1.0;
	float rate = (0.34 + 0.32 * h.y) * (0.88 + 0.09 * seed);
	float angle = t * rate * direction;
	float cs = cos(angle);
	float sn = sin(angle);
	return vec2(cs * g.x - sn * g.y, sn * g.x + cs * g.y);
}
