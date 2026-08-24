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
	uint conservative_tail_rays;
	uint global_fallback_rays;
	uint occluder_sentinel_texels;
} metrics;
// [terrain-gi 2026-07-31] 遮挡源 cell id 输出。RG=主导遮挡源低/高字节，BA=次遮挡源，
// 打包顺序与 RGBA8 纹理一致（低字节在低位）。0xFFFF=无有效遮挡源。
// 只记录几何，不记录颜色：地表 albedo 每日随 dyn/eco LUT 变化，运行期查 bounce_lut 即可。
layout(rgba8, set = 0, binding = 3) readonly uniform image2DArray source_map_index;
layout(set = 0, binding = 4, std430) writeonly restrict buffer PackedOccluder {
	uint values[];
} occluder;

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

// [wrap-seam-fix 2026-07-31] GLSL 规范 §5.9 规定 % 在任一操作数为负时结果**未定义**，
// 不是 C 那样的截断取余。实测某驱动上 (-2) % 70 返回 -26，于是 `v < 0 ? v + width : v`
// 这类兜底会算出 44 而不是 68——西向越过接缝的射线整段采到错误的列，接缝西侧出现一条
// 明显的错误阴影带。这里保证只用非负左操作数，负数分支单独镜像回去。
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

float height_at_logical(ivec2 p, int level) {
	int scale = 1 << level;
	ivec2 size = mip_size(level);
	// The last X cell of a non-power-of-two mip can be narrower than scale.
	// Preserve the level-0 period before reducing the coordinate to a mip cell.
	p.x = wrap_column(p.x, params.logical_size.x) / scale;
	p.y = clamp(p.y, 0, params.logical_size.y - 1) / scale;
	int mip_offset = int(pyramid.values[level] + 0.5);
	return pyramid.values[mip_offset + p.y * size.x + p.x];
}

float segment_column_upper_height(int logical_x, int y0, int y1, int level) {
	float h = height_at_logical(ivec2(logical_x, y0), level);
	return max(h, height_at_logical(ivec2(logical_x, y1), level));
}

float segment_upper_height(vec2 origin, vec2 direction, float distance_px,
		float span_px, int level) {
	vec2 a = origin + direction * distance_px;
	vec2 b = origin + direction * (distance_px + max(span_px - 1.0, 0.0));
	ivec2 pa = ivec2(floor(a));
	ivec2 pb = ivec2(floor(b));
	float h = segment_column_upper_height(pa.x, pa.y, pb.y, level);
	h = max(h, segment_column_upper_height(pb.x, pa.y, pb.y, level));
	if (params.wrap_x != 0) {
		float period = float(params.logical_size.x);
		bool crosses_seam = floor(a.x / period) != floor(b.x / period);
		if (crosses_seam) {
			// A span is at most one mip block wide, but the periodic tail block can
			// be shorter. Query both sides explicitly so a seam-crossing span still
			// has a conservative max-height bound.
			h = max(h, segment_column_upper_height(0, pa.y, pb.y, level));
			h = max(h, segment_column_upper_height(
				params.logical_size.x - 1, pa.y, pb.y, level));
		}
	}
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

// logical texel → 它所属 Tile 的 physical 坐标 + layer。与 decode shader 的
// physical → logical 互为逆运算，共用同一 interior/gutter 契约。
ivec3 logical_to_physical(ivec2 lp) {
	lp.x = wrap_column(lp.x, params.logical_size.x);
	lp.y = clamp(lp.y, 0, params.logical_size.y - 1);
	ivec2 tile = min(lp / params.interior_size, params.grid_size - ivec2(1));
	ivec2 local_p = lp - tile * params.interior_size + ivec2(params.gutter_px);
	return ivec3(local_p, tile.y * params.grid_size.x + tile.x);
}

const uint OCCLUDER_SENTINEL = 0xFFFFu;

// map_index 的 G/B 通道即 cell.index 低/高字节（与 cell_indirect.decode_cell_index 同源）。
uint cell_id_at_logical(int packed_index) {
	if (packed_index < 0) {
		return OCCLUDER_SENTINEL;
	}
	ivec2 lp = ivec2(packed_index % params.logical_size.x, packed_index / params.logical_size.x);
	vec4 texel = imageLoad(source_map_index, logical_to_physical(lp));
	uint lo = uint(floor(texel.g * 255.0 + 0.5));
	uint hi = uint(floor(texel.b * 255.0 + 0.5));
	uint cid = lo + hi * 256u;
	return (cid >= OCCLUDER_SENTINEL) ? OCCLUDER_SENTINEL : cid;
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
	float base_height = height_at_logical(global_p, 0);
	uint q[8];
	// 每方向的最强遮挡命中点，压成 logical y*W+x 省一半寄存器；-1 = 无精确命中。
	int hit_index[8];

	for (int direction_id = 0; direction_id < 8; ++direction_id) {
		vec2 direction = DIRECTIONS[direction_id];
		float max_distance = ray_limit(origin, direction);
		float distance_px = 1.0;
		float best_slope = 0.0;
		int best_hit = -1;
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
				float dh = height_at_logical(sample_p, 0) - base_height - params.bias;
				float candidate = slope_for(dh, direction, distance_px);
				if (candidate > best_slope) {
					best_slope = candidate;
					best_hit = sample_p.y * params.logical_size.x + sample_p.x;
				}
			}
			distance_px += max(span_px, 1.0);
			forced_level = -1;
		}

		if (!converged && distance_px <= max_distance) {
			atomicAdd(metrics.non_converged, 1u);
			atomicAdd(metrics.conservative_tail_rays, 1u);
			// Finish the unresolved ray with direction-local pyramid spans. Each span
			// uses its nearest distance with a max-height bound, so it can overestimate
			// occlusion but cannot import an unrelated mountain from elsewhere on the map.
			for (int tail_iteration = 0; tail_iteration < 512; ++tail_iteration) {
				if (distance_px > max_distance) {
					converged = true;
					break;
				}
				int level = clamp(findMSB(max(int(distance_px * 0.125), 1)),
					0, params.mip_count - 1);
				float span_px = min(float(1 << level), max_distance - distance_px + 1.0);
				float upper_height = segment_upper_height(
					origin, direction, distance_px, span_px, level);
				float tail_slope = slope_for(
					upper_height - base_height - params.bias, direction, distance_px);
				if (tail_slope > best_slope) {
					best_slope = tail_slope;
					// 保守 tail 只知道 span 的高度上界，不知道具体命中 texel。一旦它成为
					// 最强遮挡，之前记录的精确命中就不再对应最大角，必须作废——宁可丢掉
					// 这条射线的弹射贡献，也不能把错误的 cell 当成遮挡源。
					best_hit = -1;
				}
				distance_px += max(span_px, 1.0);
			}
			if (distance_px > max_distance) {
				converged = true;
			}
			if (!converged && distance_px <= max_distance) {
				// This should only be reachable for pathological dimensions. Retain the
				// old global bound as a last-resort conservative guarantee and report it.
				float global_upper = height_at_logical(ivec2(0), params.mip_count - 1);
				float global_slope = slope_for(
					global_upper - base_height - params.bias, direction, max(distance_px, 1.0));
				if (global_slope > best_slope) {
					best_slope = global_slope;
					best_hit = -1;
				}
				atomicAdd(metrics.global_fallback_rays, 1u);
			}
		}
		q[direction_id] = quantize_angle(best_slope);
		hit_index[direction_id] = best_hit;
	}

	uint packed = (q[0] << 4) | q[1];
	packed |= ((q[2] << 4) | q[3]) << 8;
	packed |= ((q[4] << 4) | q[5]) << 16;
	packed |= ((q[6] << 4) | q[7]) << 24;
	uint physical_index = uint(gid.z * params.layer_size.x * params.layer_size.y +
		gid.y * params.layer_size.x + gid.x);
	horizon.values[physical_index] = packed;

	// ── [terrain-gi 2026-07-31] top-2 遮挡方向的落点 cell ───────────────────
	// argmax 必须对【量化后的 q】而非 best_slope 求，且用严格大于（先到先得、最小 index
	// 优先）：运行期 shader 只能看到量化后的 nibble，两侧规则必须逐字一致，否则烘焙记录的
	// cell 会与运行期选出的权重配错方向。
	int d0 = -1;
	int d1 = -1;
	uint q0 = 0u;
	uint q1 = 0u;
	for (int d = 0; d < 8; ++d) {
		if (q[d] > q0) {
			q1 = q0;
			d1 = d0;
			q0 = q[d];
			d0 = d;
		} else if (q[d] > q1) {
			q1 = q[d];
			d1 = d;
		}
	}
	uint cid0 = (d0 >= 0 && q0 > 0u) ? cell_id_at_logical(hit_index[d0]) : OCCLUDER_SENTINEL;
	uint cid1 = (d1 >= 0 && q1 > 0u) ? cell_id_at_logical(hit_index[d1]) : OCCLUDER_SENTINEL;
	if (cid0 == OCCLUDER_SENTINEL) {
		// 主源无效时次源也不写：运行期以 cid0 为准做早退，留着 cid1 只会误导。
		cid1 = OCCLUDER_SENTINEL;
		atomicAdd(metrics.occluder_sentinel_texels, 1u);
	}
	occluder.values[physical_index] = (cid0 & 0xFFFFu) | ((cid1 & 0xFFFFu) << 16);
}
