// shader_quality.gdshaderinc
// Central compile-time quality-tier aliases.
//
// Runtime uniforms may still tune intensity, but mobile performance tiers must
// be compile-time cut with these macros so low-end variants do not carry high
// cost texture/noise/detail paths in the compiled shader.

#ifndef PK_SHADER_QUALITY_INC
#define PK_SHADER_QUALITY_INC

// New canonical names -> existing mobile names, for gradual migration.
#if defined(PK_SHADER_TIER_LOW) && !defined(MOBILE_QUALITY_LOW)
#define MOBILE_QUALITY_LOW
#endif
#if defined(PK_SHADER_TIER_MID) && !defined(MOBILE_QUALITY_MID)
#define MOBILE_QUALITY_MID
#endif
#if defined(PK_SHADER_TIER_HIGH) && !defined(MOBILE_QUALITY_HIGH)
#define MOBILE_QUALITY_HIGH
#endif

// Existing mobile names -> canonical aliases.
#if defined(MOBILE_QUALITY_LOW)
#define PK_QUALITY_LOW
#define PK_MOBILE_ANY
#elif defined(MOBILE_QUALITY_MID)
#define PK_QUALITY_MID
#define PK_MOBILE_ANY
#elif defined(MOBILE_QUALITY_HIGH)
#define PK_QUALITY_HIGH
// [mobile-high-full 2026-11-17] HIGH 档**故意不再定义 PK_MOBILE_ANY**。
//
// 这里原来把「这台机器是移动平台」和「该少画点」混成了同一个宏。全工程二十多处
// `#if !defined(PK_MOBILE_ANY)` 因此是在**任何**移动档位都不编译的 —— 包括玩家
// 主动把画质调到"高"的时候。真机反馈「高画质下各种光照极其丑陋」就是它：
//
//   水面 water_pipeline / water.gdshaderinc
//     · 波浪方向 B、细节法线、macro 明暗、section 混合
//     · 次表面散射(SSS)、阳光闪点(sparkle)、海藻/海冰/礁石、泛光带、
//       极端天气的地面效果、zone noise
//     · PK_QUALITY_LOW 另有一条 `waves_on = false`（连波浪都不动）
//   陆地 land_pipeline / terrain_surface_detail / world_map
//     · 河流与运河的流动、河面法线（直接置 (0,0,1) 平水面）
//     · 像素噪声退化成中性灰 PK_SKIP_PIXEL_NOISE
//     · 水面 cell id 混合、覆盖度细节、生物群系过渡
//   植被 vegetation_impostor
//     · 地平线遮蔽（= 山体/地形阴影）PK_SKIP_HORIZON_SHADOWS、生态态采样、自阴影
//   天气 weather_overlay
//     · 4/3/2 octave fbm + 域扭曲 → 单层低频（PK_WEATHER_CHEAP_NOISE）
//     · 云层遮挡、卷云层
//
// 结果就是"高画质"只剩一套 bare 光照：没有 SSS、没有闪点、没有河面法线、
// 没有山体阴影、云是一个模糊团。这不是性能取舍，是档位语义错了。
//
// 现在 HIGH = 「桌面同款光照路径 + 只为移动 GPU 保留的 SLIM 裁剪」；
// LOW / MID 行为逐字节不变（默认 auto 档仍然落在 LOW）。
#define PK_MOBILE_HIGH_SLIM
#else
#define PK_QUALITY_DESKTOP
#endif

#if defined(PK_MOBILE_ANY)
#define PK_SKIP_DETAIL_NORMALS
#define PK_SKIP_HORIZON_SHADOWS
#endif

#if defined(PK_MOBILE_ANY)
#define PK_SKIP_PIXEL_NOISE
#define PK_SKIP_PROCEDURAL_DETAIL
#define PK_SKIP_EXTRA_WATER_NOISE
#define PK_SKIP_WEATHER_DETAIL
#define PK_SKIP_VEGETATION_SHADING
#endif

// Environment lookup is compiled only into eligible world-map variants.
#if !defined(PK_WEB_TEXTURE_BUDGET)
	#if defined(PK_SKY_QUALITY_HIGH) && defined(PK_QUALITY_DESKTOP) && !defined(PK_WATER_ONLY)
		#define PK_SKY_HAS_IRRADIANCE
		#define PK_SKY_HAS_REFLECTION
	#elif defined(PK_SKY_QUALITY_HIGH) && defined(PK_QUALITY_DESKTOP) && defined(PK_WATER_ONLY)
		#define PK_SKY_HAS_REFLECTION
	#elif defined(PK_SKY_QUALITY_MID) && defined(PK_QUALITY_DESKTOP) && defined(PK_WATER_ONLY)
		#define PK_SKY_HAS_REFLECTION
	#elif (defined(PK_QUALITY_MID) || defined(PK_QUALITY_HIGH)) && defined(PK_WATER_ONLY)
		#define PK_SKY_HAS_REFLECTION
	#endif
#endif

#endif
