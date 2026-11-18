vec2 wx_decode_wind(vec4 encoded) {
	vec2 dir = encoded.rg * 2.0 - 1.0;
	float len = length(dir);
	return len > 0.01 ? dir / len * (0.25 + encoded.b) : vec2(0.0);
}
