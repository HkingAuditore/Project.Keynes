shader_type canvas_item;
render_mode unshaded, blend_disabled;

#include "res://shaders/include/weather_wind_decode.gdshaderinc"

uniform sampler2DArray source_table : filter_nearest, repeat_disable;
uniform int current_layer = 0;

void fragment() {
	ivec2 pixel = ivec2(FRAGCOORD.xy);
	int height = textureSize(source_table, 0).y;
	int plane = pixel.y / height;
	int endpoint = pixel.x & 1;
	ivec2 cell = ivec2(pixel.x / 2, pixel.y % height);
	int layer = (current_layer ^ (1 - endpoint)) + 2 * plane;
	vec4 source = texelFetch(source_table, ivec3(cell, layer), 0);
	float current_type = texelFetch(source_table, ivec3(cell, current_layer), 0).r;
	vec4 weather = vec4(current_type, source.gba);
	vec2 wind = wx_decode_wind(source) * 0.4 + 0.5;
	COLOR = mix(weather, vec4(wind, 0.0, 1.0), float(plane));
}
