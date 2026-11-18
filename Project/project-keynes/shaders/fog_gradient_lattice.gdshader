shader_type canvas_item;
render_mode unshaded, blend_disabled;

#include "res://shaders/include/cloud_noise.gdshaderinc"
#include "res://shaders/include/fog_lattice.gdshaderinc"

uniform float evolution_start;
uniform float evolution_step;

void fragment() {
	ivec2 pixel = ivec2(FRAGCOORD.xy);
	int row = pixel.y % FOG_LATTICE_SIDE;
	vec2 band = FOG_BANDS[pixel.y / FOG_LATTICE_SIDE];
	vec2 p = vec2(float(pixel.x / 2), float(row - FOG_LATTICE_Y_BIAS));
	vec2 above = vec2(float(pixel.x / 2), float((row + 1) % FOG_LATTICE_SIDE - FOG_LATTICE_Y_BIAS));
	float clock = (evolution_start + float(pixel.x & 1) * evolution_step) * band.x;
	COLOR = 0.5 + vec4(fog_evolving_gradient(p, clock, band.y),
		fog_evolving_gradient(above, clock, band.y)) / 3.0;
}
