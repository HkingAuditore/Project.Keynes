// height.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：高度图解码。把 height_tex 的 RG8（16-bit packed）还原成归一化海拔 [0,1]。
// 调用方：fragment() 各处（hypsometric / hillshading / 水面深度 / 山地 PBR 法线 /
//         BLIZZARD 坡度权重 / 河流坡度），以及 hillshade_tod.gdshaderinc 内部的
//         compute_terrain_normal / hillshading_two_lights。
// 依赖（caller 必须先 include）：
//   - uniforms.gdshaderinc 中的 sampler2D height_tex
// 性能（PERF）：单次纹理 fetch；fragment 中被调用约 30+ 次（Sobel 3×3 + 五处 4-tap +
//                Coastal offshore 5×5 邻域）。这是已知热点，未来若做性能优化可考虑
//                把 hillshade 法线提到 vertex 或单独 pass（本轮不动）。
// ─────────────────────────────────────────────────────────────────────────

// ─── 高度解码（RG8 16-bit） ──────────────────────────────────────────────

float decode_height_rg8(vec2 uv) {
	vec4 s = texture(height_tex, wrap_map_uv(uv));
	return (s.r * 256.0 + s.g) / 257.0;
}
