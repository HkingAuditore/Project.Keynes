#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly restrict buffer HeightPyramid {
	float values[];
} pyramid;
layout(set = 0, binding = 1, std430) writeonly restrict buffer PackedHorizon {
	uint values[];
} horizon;
layout(set = 0, binding = 2, std430) restrict buffer Metrics {
	uint non_converged;
} metrics;

layout(push_constant, std430) uniform Params {
	ivec2 logical_size;
	ivec2 grid_size;
	ivec2 interior_size;
	ivec2 layer_size;
	int gutter_px;
	int mip_count;
	int max_iterations;
	int wrap_x;
	float texel_x;
	float texel_y;
	float height_world_scale;
	float bias;
	float max_angle;
	float _pad0;
} params;

const float INV_SQRT2 = 0.70710678118654752440;
const vec2 DIRECTIONS[8] = vec2[8](
	vec2(1.0, 0.0), vec2(INV_SQRT2, INV_SQRT2),
	vec2(0.0, 1.0), vec2(-INV_SQRT2, INV_SQRT2),
	vec2(-1.0, 0.0), vec2(-INV_SQRT2, -INV_SQRT2),
	vec2(0.0, -1.0), vec2(INV_SQRT2, -INV_SQRT2)
);

ivec2 mip_size(int level) {
	int scale = 1 << level;
	return max((params.logical_size + ivec2(scale - 1)) / scale, ivec2(1));
}

int wrap_column(int x, int width) {
	if (params.wrap_x == 0) {
		return clamp(x, 0, width - 1);
	}
	int v = x % width;
	return v < 0 ? v + width : v;
}

float height_at(ivec2 p, int level) {
	ivec2 size = mip_size(level);
	p.x = wrap_column(p.x, size.x);
	p.y = clamp(p.y, 0, size.y - 1);
	int mip_offset = int(pyramid.values[level] + 0.5);
	return pyramid.values[mip_offset + p.y * size.x + p.x];
}

float segment_upper_height(vec2 origin, vec2 direction, float distance_px,
		float span_px, int level) {
	float scale = float(1 << level);
	vec2 a = origin + direction * distance_px;
	vec2 b = origin + direction * (distance_px + max(span_px - 1.0, 0.0));
	ivec2 ca = ivec2(floor(a / scale));
	ivec2 cb = ivec2(floor(b / scale));
	float h = height_at(ca, level);
	h = max(h, height_at(ivec2(cb.x, ca.y), level));
	h = max(h, height_at(ivec2(ca.x, cb.y), level));
	h = max(h, height_at(cb, level));
	return h;
}

float ray_limit(vec2 origin, vec2 direction) {
	float limit = 3.402823466e+38;
	if (abs(direction.y) > 1e-6) {
		float y_edge = direction.y > 0.0
			? float(params.logical_size.y - 1) - origin.y : origin.y;
		limit = min(limit, y_edge / abs(direction.y));
	}
	if (params.wrap_x == 0 && abs(direction.x) > 1e-6) {
		float x_edge = direction.x > 0.0
			? float(params.logical_size.x - 1) - origin.x : origin.x;
		limit = min(limit, x_edge / abs(direction.x));
	} else if (params.wrap_x != 0 && abs(direction.y) <= 1e-6) {
		limit = min(limit, float(params.logical_size.x));
	}
	return max(limit, 0.0);
}

float slope_for(float dh, vec2 direction, float distance_px) {
	if (dh <= 0.0 || distance_px <= 0.0) {
		return 0.0;
	}
	vec2 world_offset = direction * distance_px * vec2(params.texel_x, params.texel_y);
	float world_distance = max(length(world_offset), 1e-6);
	return dh * params.height_world_scale / world_distance;
}

uint quantize_angle(float slope) {
	float angle = atan(max(slope, 0.0));
	return uint(clamp(floor(angle / params.max_angle * 15.0 + 0.5), 0.0, 15.0));
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
	vec2 origin = vec2(global_p);
	float base_height = height_at(global_p, 0);
	uint q[8];

	for (int direction_id = 0; direction_id < 8; ++direction_id) {
		vec2 direction = DIRECTIONS[direction_id];
		float max_distance = ray_limit(origin, direction);
		float distance_px = 1.0;
		float best_slope = 0.0;
		int forced_level = -1;
		bool converged = false;

		for (int iteration = 0; iteration < 8192; ++iteration) {
			if (iteration >= params.max_iterations) {
				break;
			}
			if (distance_px > max_distance) {
				converged = true;
				break;
			}
			int desired_level = clamp(findMSB(max(int(distance_px * 0.125), 1)),
				0, params.mip_count - 1);
			int level = forced_level >= 0 ? forced_level : desired_level;
			float span_px = min(float(1 << level), max_distance - distance_px + 1.0);
			float upper_height = segment_upper_height(
				origin, direction, distance_px, span_px, level);
			float upper_slope = slope_for(
				upper_height - base_height - params.bias, direction, distance_px);

			if (level > 0 && upper_slope > best_slope) {
				forced_level = level - 1;
				continue;
			}
			if (level == 0) {
				ivec2 sample_p = ivec2(floor(origin + direction * distance_px + vec2(0.5)));
				sample_p.x = wrap_column(sample_p.x, params.logical_size.x);
				sample_p.y = clamp(sample_p.y, 0, params.logical_size.y - 1);
				float dh = height_at(sample_p, 0) - base_height - params.bias;
				best_slope = max(best_slope, slope_for(dh, direction, distance_px));
			}
			distance_px += max(span_px, 1.0);
			forced_level = -1;
		}

		if (!converged && distance_px <= max_distance) {
			float global_upper = height_at(ivec2(0), params.mip_count - 1);
			best_slope = max(best_slope, slope_for(
				global_upper - base_height - params.bias, direction, max(distance_px, 1.0)));
			atomicAdd(metrics.non_converged, 1u);
		}
		q[direction_id] = quantize_angle(best_slope);
	}

	uint packed = (q[0] << 4) | q[1];
	packed |= ((q[2] << 4) | q[3]) << 8;
	packed |= ((q[4] << 4) | q[5]) << 16;
	packed |= ((q[6] << 4) | q[7]) << 24;
	uint physical_index = uint(gid.z * params.layer_size.x * params.layer_size.y +
		gid.y * params.layer_size.x + gid.x);
	horizon.values[physical_index] = packed;
}
