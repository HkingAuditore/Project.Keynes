#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer HeightPyramid {
	float values[];
} pyramid;

layout(push_constant, std430) uniform Params {
	ivec2 src_size;
	ivec2 dst_size;
	int src_offset;
	int dst_offset;
	int _pad0;
	int _pad1;
} params;

void main() {
	ivec2 dst = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(dst, params.dst_size))) {
		return;
	}
	ivec2 src0 = dst * 2;
	float max_height = -3.402823466e+38;
	for (int oy = 0; oy < 2; ++oy) {
		for (int ox = 0; ox < 2; ++ox) {
			ivec2 src = min(src0 + ivec2(ox, oy), params.src_size - ivec2(1));
			max_height = max(max_height,
				pyramid.values[params.src_offset + src.y * params.src_size.x + src.x]);
		}
	}
	pyramid.values[params.dst_offset + dst.y * params.dst_size.x + dst.x] = max_height;
}
