#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rg8, set = 0, binding = 0) readonly uniform image2DArray source_height;
layout(set = 0, binding = 1, std430) restrict buffer HeightPyramid {
	float values[];
} pyramid;

layout(push_constant, std430) uniform Params {
	ivec2 logical_size;
	ivec2 grid_size;
	ivec2 interior_size;
	ivec2 layer_size;
	int gutter_px;
	int base_offset;
	int _pad0;
	int _pad1;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(p, params.logical_size))) {
		return;
	}
	ivec2 tile = p / params.interior_size;
	ivec2 local_p = p - tile * params.interior_size + ivec2(params.gutter_px);
	int layer = tile.y * params.grid_size.x + tile.x;
	vec4 encoded = imageLoad(source_height, ivec3(local_p, layer));
	float high_byte = floor(encoded.r * 255.0 + 0.5);
	float low_byte = floor(encoded.g * 255.0 + 0.5);
	pyramid.values[params.base_offset + p.y * params.logical_size.x + p.x] =
		(high_byte * 256.0 + low_byte) / 65535.0;
}
