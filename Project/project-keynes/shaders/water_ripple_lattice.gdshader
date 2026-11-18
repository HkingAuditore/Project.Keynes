shader_type canvas_item;
render_mode unshaded, blend_disabled;

#include "res://shaders/include/water_lattice.gdshaderinc"

uniform vec4 cycles = vec4(0.0);

void fragment() {
	ivec2 pixel = ivec2(FRAGCOORD.xy);
	int page = pixel.y / WATER_LATTICE_SIDE;
	int row = pixel.y % WATER_LATTICE_SIDE;
	vec2 seeds[3] = vec2[3](
		water_ripple_seeds(cycles.x, cycles.y, 71.0),
		water_ripple_seeds(cycles.z, cycles.w, 133.0),
		vec2(211.0, 307.0)
	);
	vec2 origin = vec2(float(pixel.x), float(row - WATER_LATTICE_Y_BIAS));
	vec2 above = vec2(float(pixel.x), float((row + 1) % WATER_LATTICE_SIDE - WATER_LATTICE_Y_BIAS));
	vec2 pair = seeds[page];
	COLOR = vec4(water_hash32(origin + pair.x).x, water_hash32(origin + pair.y).x,
		water_hash32(above + pair.x).x, water_hash32(above + pair.y).x);
}
