// world_map_web_min.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// [web-world-min] world_map.gdshader 的 web / GLES3 裁剪变体「叶片」集合。
//
// 唯一外部开关：world_map.gdshader 里的 `#ifdef PK_WEB_WORLD_MIN`
// （由 hex_renderer._apply_shader_variant_prefix() 在 Compatibility + LOW 档 prepend）。
//
// 为什么需要（Why）：本变体把 world_map 展开链路里 6 个 include 整段裁掉
// （common_noise / cell_indirect / tonemap / shore_common / weather_front /
// terrain_horizon），但主文件与存活 include 仍引用其中极少数叶子 helper。本文件
// 只补这些叶子，**不重复声明任何 uniform**（uniform 集合必须与桌面逐项一致）。
// ─────────────────────────────────────────────────────────────────────────
#ifndef PK_WEB_WORLD_MIN_INC
#define PK_WEB_WORLD_MIN_INC

// 与 hex_renderer._world_map_web_min_active() 必须一致：本变体只在
// 「Compatibility 后端 + MOBILE_QUALITY_LOW 档」下生成。少了这个前提，下面的裁剪
// 就会砍到 MID/HIGH 档真正会执行的代码（ctx.quality>=1 的水体分支）。
#ifndef PK_QUALITY_LOW
#error "PK_WEB_WORLD_MIN requires MOBILE_QUALITY_LOW / PK_SHADER_TIER_LOW"
#endif

// ── cell-index → LUT texel uv（原 cell_indirect.gdshaderinc，唯一存活成员）──
vec2 cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) { lw = 1; }
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

// ── 8 方向 horizon 解码器（原 terrain_horizon.gdshaderinc）──────────────
// web 上 horizon 烘焙被平台开关关掉：main.gd 强制 DCFeatureFlags.
// set_terrain_horizon_gpu_bake(false)，map_baker 因此把 terrain_horizon_tex 置 null
// （web 也禁止落 CPU marching）。再加上 MOBILE_QUALITY_LOW 本来就让
// terrain_horizon_evaluate() 直接返回中性值，所以这里只保留中性值 + 同一份
// apply_normal 公式——对屏幕输出逐值等价于现状，只是不再编译解码器。
struct TerrainHorizonSample {
	float direct_visibility;
	float sky_visibility;
	vec3 bent_normal;
	vec4 nearest_packed;
	bool has_data;
};

TerrainHorizonSample terrain_horizon_evaluate(vec2 uv, vec3 light_dir) {
	TerrainHorizonSample neutral;
	neutral.direct_visibility = 1.0;
	neutral.sky_visibility = 1.0;
	neutral.bent_normal = vec3(0.0, 0.0, 1.0);
	neutral.nearest_packed = vec4(0.0);
	neutral.has_data = false;
	return neutral;
}

float terrain_horizon_apply_normal(float sky_visibility, vec3 geometric_normal, vec3 bent_normal) {
	if (gi_normal_floor >= 1.0) {
		return clamp(sky_visibility, 0.0, 1.0);
	}
	float align = clamp(dot(normalize(geometric_normal), normalize(bent_normal)), 0.0, 1.0);
	return clamp(sky_visibility * mix(gi_normal_floor, 1.0, align), 0.0, 1.0);
}

// ── 周期波相位（原 water.gdshaderinc，kelp 条纹仍在用）──────────────────
// apply_kelp_features 的 along_k / across_k 不是 quality-gated，所以这两个叶子必须保留
// 真实实现（其余 water.gdshaderinc 成员在 q0 下全部不可达）。
const float WATER_WRAP_TAU = 6.2831853;

float water_wrap_lon_angle(vec2 wp) {
	if (wrap_period_x <= 0.0001) {
		return 0.0;
	}
	float wx = wrap_world_x(wp.x);
	return fract((wx - wrap_origin_x) / wrap_period_x) * WATER_WRAP_TAU;
}

float water_periodic_wave_phase(vec2 wp, vec2 dir, float k) {
	if (wrap_period_x <= 0.0001) {
		return dot(wp, dir) * k;
	}
	float theta = water_wrap_lon_angle(wp);
	float desired_cycles = dir.x * k * wrap_period_x / WATER_WRAP_TAU;
	float cycles = floor(abs(desired_cycles) + 0.5);
	float phase_x = (cycles > 0.0) ? sign(desired_cycles) * cycles * theta : 0.0;
	return phase_x + dir.y * wp.y * k;
}

// ── legacy Reinhard（原 tonemap.gdshaderinc，Blinn-Phong legacy 路径在用）──
vec3 tonemap_reinhard_legacy(vec3 x) {
	return x / (1.0 + x * REINHARD_K_LEGACY);
}

#endif // PK_WEB_WORLD_MIN_INC
