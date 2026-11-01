// Shared GGX/Smith/Schlick kernel for terrain and the Web water pass.
#ifndef PK_PBR_MICROFACET_INC
#define PK_PBR_MICROFACET_INC
float D_GGX(float NdotH, float roughness) {
	float a = roughness * roughness;
	float a2 = a * a;
	float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
	return a2 / max(PI * denom * denom, 1e-7);
}

// ─── G：Smith joint masking-shadowing（Schlick-GGX 简化版） ────────────
float G_SchlickGGX(float NdotX, float k) {
	return NdotX / max(NdotX * (1.0 - k) + k, 1e-7);
}

float G_SmithGGX(float NdotL, float NdotV, float roughness) {
	float r = roughness + 1.0;
	float k = (r * r) / 8.0;  // 直接光照常用 k
	return G_SchlickGGX(NdotL, k) * G_SchlickGGX(NdotV, k);
}

// ─── F：Schlick Fresnel ─────────────────────────────────────────────────
vec3 F_Schlick(vec3 F0, float VdotH) {
	float t = pow(clamp(1.0 - VdotH, 0.0, 1.0), 5.0);
	return F0 + (vec3(1.0) - F0) * t;
}
#endif
