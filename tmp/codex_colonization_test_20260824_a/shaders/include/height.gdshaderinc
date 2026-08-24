// height.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：高度图解码。把 height_tex 的 RG（16-bit packed；纹理可为 RG8 或 RGBA8）还原成归一化海拔 [0,1]。
// Legacy height_tex 现为 RGBA8（B=flow），本函数只读 .rg，与格式兼容。
// 调用方：fragment() 各处（hypsometric / hillshading / 水面深度 / 山地 PBR 法线 /
//         BLIZZARD 坡度权重 / 河流坡度），以及 hillshade_tod.gdshaderinc 内部的
//         compute_terrain_normal / hillshading_two_lights。
// 依赖（caller 必须先 include）：
//   - visual_tile_sampling / VT_USE_HEIGHT（height_tex 或 visual_height_tiles）
// 性能（PERF）：单次纹理 fetch；fragment 中被调用约 30+ 次（Sobel 3×3 + 五处 4-tap +
//                Coastal offshore 5×5 邻域）。这是已知热点，未来若做性能优化可考虑
//                把 hillshade 法线提到 vertex 或单独 pass（本轮不动）。
// ─────────────────────────────────────────────────────────────────────────

// ─── 高度解码（RG 16-bit；纹理格式 RG8 或 RGBA8） ─────────────────────────

float decode_height_rg8(vec2 uv) {
	vec4 s = visual_sample_height(uv);
	return (s.r * 256.0 + s.g) / 257.0;
}
