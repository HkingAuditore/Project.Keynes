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
	float sea_level;
	int lowpass_radius;
} params;

int wrap_column(int x, int width) {
	if (x >= 0) {
		return x % width;
	}
	int r = (-x) % width;
	return (r == 0) ? 0 : (width - r);
}

float decode_height(ivec2 logical_p) {
	logical_p.x = wrap_column(logical_p.x, params.logical_size.x);
	logical_p.y = clamp(logical_p.y, 0, params.logical_size.y - 1);
	ivec2 tile = min(logical_p / params.interior_size, params.grid_size - ivec2(1));
	ivec2 local_p = logical_p - tile * params.interior_size + ivec2(params.gutter_px);
	int layer = tile.y * params.grid_size.x + tile.x;
	vec4 encoded = imageLoad(source_height, ivec3(local_p, layer));
	float high_byte = floor(encoded.r * 255.0 + 0.5);
	float low_byte = floor(encoded.g * 255.0 + 0.5);
	return max((high_byte * 256.0 + low_byte) / 65535.0, params.sea_level);
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(p, params.logical_size))) {
		return;
	}
	float decoded_height = decode_height(p);
	if (params.lowpass_radius > 0) {
		float sum = 0.0;
		for (int oy = -1; oy <= 1; ++oy) {
			float wy = oy == 0 ? 2.0 : 1.0;
			for (int ox = -1; ox <= 1; ++ox) {
				float wx = ox == 0 ? 2.0 : 1.0;
				sum += decode_height(p + ivec2(ox, oy)) * wx * wy;
			}
		}
		decoded_height = sum * 0.0625;
	}
	// Horizon receivers over water live at the surface. Keep bathymetry in the
	// source Tile unchanged; only this derived visibility field is flattened.
	pyramid.values[params.base_offset + p.y * params.logical_size.x + p.x] =
		max(decoded_height, params.sea_level);
}
