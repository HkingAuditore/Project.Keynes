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
#define PK_MOBILE_ANY
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

#endif
