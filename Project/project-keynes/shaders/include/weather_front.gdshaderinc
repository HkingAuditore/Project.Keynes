// weather_front.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：天气锋面的几何 / 覆盖度 / 视觉掩码：
//        - weather_front_axis / _ellipse_distance / _gaussian_coverage：单个锋面
//          的椭圆 SDF & 高斯软覆盖（被 fragment 直接调用 + 被 weather_front_*
//          公共逻辑复用）。
//        - compute_extreme_weather_mask(wp, type_id)：BLIZZARD 等\"地形可见\"
//          天气的最终掩码（结合 visual.x/.y/.z 与 fbm 撕碎边缘）。
// 调用方：
//   - 水面 BLIZZARD 薄冰。
//   - snow_cover.apply_snow_cover 内部用于 BLIZZARD 新雪增强。

// 依赖（caller 必须先 include）：
//   - uniforms.gdshaderinc：MAX_WEATHER_FRONTS / weather_front_centers /
//     weather_front_shapes / weather_front_visuals / weather_front_types /
//     weather_front_count / WT_* 常量。

//   - common_noise.gdshaderinc：fbm（用于撕碎锋面边缘的 mask）。
// 性能（PERF）：仅保留 BLIZZARD 掩码查询；DROUGHT/HEATWAVE 调色与裂地已删除。


// ─────────────────────────────────────────────────────────────────────────

vec2 weather_front_axis(vec4 shape) {
	vec2 ax = shape.xy;
	if (dot(ax, ax) <= 0.0001) {
		return vec2(1.0, 0.0);
	}
	return normalize(ax);
}

float weather_front_ellipse_distance(vec2 wp, vec2 center, float radius, vec4 shape) {
	vec2 ax = weather_front_axis(shape);
	vec2 ay = vec2(-ax.y, ax.x);
	vec2 local = wp - center;
	float major = max(radius * max(shape.z, 0.05), 0.001);
	float minor = max(radius * max(shape.w, 0.05), 0.001);
	return length(vec2(dot(local, ax) / major, dot(local, ay) / minor));
}

float weather_front_gaussian_coverage(vec2 wp, vec4 center_data, vec4 shape) {
	float radius = center_data.z;
	if (radius < 0.001) {
		return 0.0;
	}
	float ed = weather_front_ellipse_distance(wp, center_data.xy, radius, shape);
	if (ed > 1.6) {
		return 0.0;
	}
	float k = ed / 0.5;
	return clamp(center_data.w * exp(-0.5 * k * k), 0.0, center_data.w);
}

float compute_extreme_weather_mask(vec2 wp, int type_id) {
	float best = 0.0;
	for (int i = 0; i < MAX_WEATHER_FRONTS; i++) {
		if (i >= weather_front_count) break;
		float wt_f = weather_front_types[i];
		if (wt_f < 0.0) continue;
		int wt_i = int(wt_f + 0.5);
		if (wt_i != type_id) continue;
		vec4 c = weather_front_centers[i];
		vec4 shape = weather_front_shapes[i];
		vec4 visual = weather_front_visuals[i];
		float radius = c.z;
		if (radius < 0.001) continue;
		float ed = weather_front_ellipse_distance(wp, c.xy, radius, shape);
		float spread = mix(1.0, 1.20, visual.z);
		float d = ed / spread;
		if (d > 1.65) continue;
		float radial = 1.0 - smoothstep(0.60, 1.34 + visual.z * 0.18, d);
		float freq = (type_id == WT_BLIZZARD) ? 0.020 : 0.034;
		vec2 offset = (type_id == WT_BLIZZARD) ? vec2(13.0, -7.0) : vec2(-29.0, 41.0);
		float n = fbm((wp + offset) * freq, 2);
		float visual_amount = (type_id == WT_BLIZZARD) ? max(visual.y, visual.x * 0.72) : max(visual.x, c.w);
		float threshold = mix(0.48, 0.22, clamp(visual_amount, 0.0, 1.0)) + visual.z * 0.10;
		float density = smoothstep(threshold, threshold + 0.24, n);
		float mask = radial * mix(0.62, 1.0, density) * clamp(visual_amount, 0.0, 1.0);
		best = max(best, mask);
	}
	return best;
}


