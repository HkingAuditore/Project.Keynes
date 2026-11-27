#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly restrict buffer RawGiSky {
	uint values[];
} raw_gi_sky;
layout(set = 0, binding = 1, std430) readonly restrict buffer RawHorizonDir0 {
	uint values[];
} raw_dir0;
layout(set = 0, binding = 2, std430) readonly restrict buffer RawHorizonDir1 {
	uint values[];
} raw_dir1;
layout(set = 0, binding = 3, std430) writeonly restrict buffer OutGiSky {
	uint values[];
} out_gi_sky;
layout(set = 0, binding = 4, std430) writeonly restrict buffer OutHorizonDir0 {
	uint values[];
} out_dir0;
layout(set = 0, binding = 5, std430) writeonly restrict buffer OutHorizonDir1 {
	uint values[];
} out_dir1;

layout(push_constant, std430) uniform Params {
	ivec2 logical_size;
	ivec2 grid_size;
	ivec2 interior_size;
	ivec2 layer_size;
	int gutter_px;
	int wrap_x;
} params;

int wrap_column(int x, int width) {
	if (params.wrap_x == 0) {
		return clamp(x, 0, width - 1);
	}
	if (x >= 0) {
		return x % width;
	}
	int r = (-x) % width;
	return (r == 0) ? 0 : (width - r);
}

uint logical_to_physical_index(ivec2 lp) {
	lp.x = wrap_column(lp.x, params.logical_size.x);
	lp.y = clamp(lp.y, 0, params.logical_size.y - 1);
	ivec2 tile = min(lp / params.interior_size, params.grid_size - ivec2(1));
	ivec2 local_p = lp - tile * params.interior_size + ivec2(params.gutter_px);
	int layer = tile.y * params.grid_size.x + tile.x;
	return uint(layer * params.layer_size.x * params.layer_size.y +
		local_p.y * params.layer_size.x + local_p.x);
}

vec4 unpack_rgba8(uint packed) {
	return vec4(
		float(packed & 0xFFu),
		float((packed >> 8u) & 0xFFu),
		float((packed >> 16u) & 0xFFu),
		float((packed >> 24u) & 0xFFu)
	) * (1.0 / 255.0);
}

uint pack_rgba8(vec4 v) {
	uint r = uint(clamp(floor(v.r * 255.0 + 0.5), 0.0, 255.0));
	uint g = uint(clamp(floor(v.g * 255.0 + 0.5), 0.0, 255.0));
	uint b = uint(clamp(floor(v.b * 255.0 + 0.5), 0.0, 255.0));
	uint a = uint(clamp(floor(v.a * 255.0 + 0.5), 0.0, 255.0));
	return r | (g << 8u) | (b << 16u) | (a << 24u);
}

void main() {
	ivec3 gid = ivec3(gl_GlobalInvocationID.xyz);
	if (gid.x >= params.layer_size.x || gid.y >= params.layer_size.y ||
			gid.z >= params.grid_size.x * params.grid_size.y) {
		return;
	}
	ivec2 tile = ivec2(gid.z % params.grid_size.x, gid.z / params.grid_size.x);
	ivec2 global_p = tile * params.interior_size + gid.xy - ivec2(params.gutter_px);
	global_p.x = wrap_column(global_p.x, params.logical_size.x);
	global_p.y = clamp(global_p.y, 0, params.logical_size.y - 1);

	float v_sky_sum = 0.0;
	vec3 bent_sum = vec3(0.0);
	vec4 dir0_sum = vec4(0.0);
	vec4 dir1_sum = vec4(0.0);

	for (int dy = -1; dy <= 1; ++dy) {
		float wy = (dy == 0) ? 2.0 : 1.0;
		for (int dx = -1; dx <= 1; ++dx) {
			float w = wy * ((dx == 0) ? 2.0 : 1.0);
			uint src_idx = logical_to_physical_index(global_p + ivec2(dx, dy));

			vec4 gi = unpack_rgba8(raw_gi_sky.values[src_idx]);
			v_sky_sum += gi.r * w;
			vec3 bent = vec3(gi.g * 2.0 - 1.0, gi.b * 2.0 - 1.0, gi.a);
			bent_sum += bent * w;

			dir0_sum += unpack_rgba8(raw_dir0.values[src_idx]) * w;
			dir1_sum += unpack_rgba8(raw_dir1.values[src_idx]) * w;
		}
	}

	float v_sky = clamp(v_sky_sum * (1.0 / 16.0), 0.0, 1.0);
	vec3 bent_n = (dot(bent_sum, bent_sum) > 1e-6) ? normalize(bent_sum) : vec3(0.0, 0.0, 1.0);
	vec4 gi_out = vec4(v_sky, bent_n.x * 0.5 + 0.5, bent_n.y * 0.5 + 0.5, clamp(bent_n.z, 0.0, 1.0));

	uint physical_index = uint(gid.z * params.layer_size.x * params.layer_size.y +
		gid.y * params.layer_size.x + gid.x);
	out_gi_sky.values[physical_index] = pack_rgba8(gi_out);
	out_dir0.values[physical_index] = pack_rgba8(dir0_sum * (1.0 / 16.0));
	out_dir1.values[physical_index] = pack_rgba8(dir1_sum * (1.0 / 16.0));
}
