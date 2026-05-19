// surface_params.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   定义 Stylized 半 PBR 的表面参数容器 SurfaceParams，并提供：
//     - make_surface_params 系列构造（含 emission/alpha 重载）
//     - blend_surface_overlay：material 层 mix
//     - SurfaceTextureSet 钩子：为后续接入真实贴图（albedo/normal/ORM atlas）
//       预留接口，当前 has_*=false 时所有 helper 为 no-op 直接 return surface。
//
// 调用方（Who）
//   - land_pipeline / water_pipeline 的 base surface 构建与 overlay
//   - brdf.gdshaderinc 的 evaluate_brdf 消费 SurfaceParams 字段
//   - 未来真实贴图接入：在 base_surface 阶段调 apply_albedo_map(s, ts, uv)
//
// 依赖（Why）
//   - material_constants.gdshaderinc：DEFAULT_* / ROUGHNESS_MIN/MAX / DEFAULT_ALPHA
//
// 性能（Cost）
//   纯结构体 + 简单 clamp/mix；apply_*_map helper 当前为 no-op，无任何 fetch。
// ─────────────────────────────────────────────────────────────────────────

// ═══════════════════════════════════════════════════════════════════════
// 一、SurfaceParams：半 PBR 表面参数
// ═══════════════════════════════════════════════════════════════════════
//   base_color  ：基础反照率（sRGB 域，进入 BRDF 前由 brdf.gdshaderinc 负责
//                 srgb_to_linear；其他风格化路径继续在 sRGB 域消费）
//   normal      ：表面法线（世界空间 / 屏幕空间 z+ up，已归一化）
//   roughness   ：粗糙度 [0,1]，通过 clamp 落到 [ROUGHNESS_MIN, ROUGHNESS_MAX]
//   metallic    ：金属度 [0,1]；半 PBR 路径用于 F0 lerp 与 diffuse 屏蔽
//   ao          ：环境遮蔽 [0,1]，乘到 ambient 项
//   alpha       ：最终 COLOR.a，由 global_adjustments 写出
//   emission    ：自发光 [0,1+]，BRDF 输出后直接相加（火山/闪电/夜景灯光接入点）
// ─────────────────────────────────────────────────────────────────────────
struct SurfaceParams {
	vec3 base_color;
	vec3 normal;
	float roughness;
	float metallic;
	float ao;
	float alpha;
	vec3 emission;
};

// ─── 构造：基础版（与 v9 兼容，emission/alpha 用默认值） ────────────────
SurfaceParams make_surface_params(vec3 base_color, vec3 normal, float roughness, float metallic, float ao) {
	SurfaceParams s;
	s.base_color = base_color;
	s.normal = normalize(normal);
	s.roughness = clamp(roughness, ROUGHNESS_MIN, ROUGHNESS_MAX);
	s.metallic = clamp(metallic, 0.0, 1.0);
	s.ao = clamp(ao, 0.0, 1.0);
	s.alpha = DEFAULT_ALPHA;
	s.emission = DEFAULT_EMISSION;
	return s;
}

// ─── 构造：完整版（含 emission/alpha） ──────────────────────────────────
SurfaceParams make_surface_params_full(
		vec3 base_color, vec3 normal,
		float roughness, float metallic, float ao,
		vec3 emission, float alpha) {
	SurfaceParams s;
	s.base_color = base_color;
	s.normal = normalize(normal);
	s.roughness = clamp(roughness, ROUGHNESS_MIN, ROUGHNESS_MAX);
	s.metallic = clamp(metallic, 0.0, 1.0);
	s.ao = clamp(ao, 0.0, 1.0);
	s.alpha = clamp(alpha, 0.0, 1.0);
	s.emission = max(emission, vec3(0.0));
	return s;
}

// ─── Overlay：在已有表面上 mix 一层材质（color+normal+roughness+metallic+ao） ─
SurfaceParams blend_surface_overlay(
		SurfaceParams s,
		vec3 overlay_color,
		vec3 overlay_normal,
		float overlay_roughness,
		float overlay_metallic,
		float overlay_ao,
		float weight) {
	float w = clamp(weight, 0.0, 1.0);
	s.base_color = mix(s.base_color, overlay_color, w);
	s.normal = normalize(mix(s.normal, normalize(overlay_normal), w));
	s.roughness = mix(s.roughness, clamp(overlay_roughness, ROUGHNESS_MIN, ROUGHNESS_MAX), w);
	s.metallic = mix(s.metallic, clamp(overlay_metallic, 0.0, 1.0), w);
	s.ao = mix(s.ao, clamp(overlay_ao, 0.0, 1.0), w);
	return s;
}

// ─── Emission 接入点：火山 / 闪电 / 城市夜景灯光 ────────────────────────
//   把一束 emission 颜色按 weight 注入到当前表面的自发光通道；BRDF 输出后
//   evaluate_brdf 末端会把 surface.emission 直接相加。
//   设计目标：动态特效系统不需要知道 BRDF 内部，只需要在 overlay 阶段调本函数。
SurfaceParams add_emission(SurfaceParams s, vec3 color, float weight) {
	float w = clamp(weight, 0.0, 1.0);
	s.emission += max(color, vec3(0.0)) * w;
	return s;
}

// ═══════════════════════════════════════════════════════════════════════
// 二、SurfaceTextureSet：真实贴图扩展钩子（接口先行）
// ═══════════════════════════════════════════════════════════════════════
//   当前 has_*=false 时所有 apply_*_map 是 no-op，调用点不需任何修改即可使用；
//   未来挂 splat / albedo atlas / normal atlas / ORM atlas 时，仅修改这些 helper
//   内部即可，所有调用点保持稳定。
//
//   设计要点：
//     1. 不在 struct 中放 sampler2D（GLSL 不支持结构体内 sampler）；改用 bool 标记
//        + 由 helper 内部直接读取全局 uniform 的方式实现。
//     2. 真实贴图接入时，仅在 helper 顶部加 `texture(albedo_atlas, uv)` 即可。
//     3. default_surface_texture_set() 给当前所有调用点用，行为等价于"不挂贴图"。
// ─────────────────────────────────────────────────────────────────────
struct SurfaceTextureSet {
	bool has_albedo;
	bool has_normal;
	bool has_orm;       // O=AO  R=Roughness  M=Metallic
	float blend_weight; // 贴图 vs procedural 的混合权重（0=纯 procedural）
};

SurfaceTextureSet default_surface_texture_set() {
	SurfaceTextureSet ts;
	ts.has_albedo = false;
	ts.has_normal = false;
	ts.has_orm = false;
	ts.blend_weight = 0.0;
	return ts;
}

// 接口签名稳定；当 has_*=false 时直接 return s，无任何 fetch / 计算开销。
SurfaceParams apply_albedo_map(SurfaceParams s, SurfaceTextureSet ts, vec2 uv) {
	if (!ts.has_albedo || ts.blend_weight <= 0.0) {
		return s;
	}
	// TODO[real-texture]: 在此处接入 albedo atlas，例如：
	//   vec3 sampled = texture(albedo_atlas, uv).rgb;
	//   s.base_color = mix(s.base_color, sampled, ts.blend_weight);
	return s;
}

SurfaceParams apply_normal_map(SurfaceParams s, SurfaceTextureSet ts, vec2 uv) {
	if (!ts.has_normal || ts.blend_weight <= 0.0) {
		return s;
	}
	// TODO[real-texture]: 在此处接入 normal atlas（unpack_normal + tangent space）
	return s;
}

SurfaceParams apply_orm_map(SurfaceParams s, SurfaceTextureSet ts, vec2 uv) {
	if (!ts.has_orm || ts.blend_weight <= 0.0) {
		return s;
	}
	// TODO[real-texture]: 在此处接入 ORM atlas，channel: R=AO, G=Roughness, B=Metallic
	//   vec3 orm = texture(orm_atlas, uv).rgb;
	//   s.ao        = mix(s.ao,        orm.r, ts.blend_weight);
	//   s.roughness = mix(s.roughness, orm.g, ts.blend_weight);
	//   s.metallic  = mix(s.metallic,  orm.b, ts.blend_weight);
	return s;
}
