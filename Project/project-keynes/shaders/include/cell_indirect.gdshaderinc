// cell_indirect.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   Cell-index 间接寻址（province-ID indirection）的解码 helper。把 map_index_atlas
//   的 G/B 通道解码成 cell.index，再把 cell.index 映射成 per-cell LUT
//   纹理（enum_lut / dyn_lut / eco_lut）的 texel 中心 uv。
//
// 调用方（Who）
//   - world_map.gdshader::fragment SETUP（当前唯一动态视觉路径）。
//
// 依赖（Why）
//   仅 uniforms.gdshaderinc（map_index_atlas / *_lut / lut_dims）。叶子模块。
//
// 性能（Cost）
//   decode_cell_index = 1 texture fetch（NEAREST）。cell_lut_uv 纯 ALU。
//   一次 enum/dyn/eco LUT 读 = decode(1) + lut(1) = 2 fetch（替代旧 1 fetch）。
// ─────────────────────────────────────────────────────────────────────────

// 解码每像素 cell 索引；返回 -1 表示 map 外（0xFFFF 哨兵）。
int decode_cell_index(vec2 uv) {
	vec2 gb = visual_sample_map_index(uv).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

// 把 cell.index 映射成 per-cell LUT 网格的 texel 中心 uv（NEAREST 采样安全）。
vec2 cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) { lw = 1; }
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

// ── Stage C：per-cell LUT 平滑采样 ───────────────────────────────────────
// dyn_lut / eco_lut 存的是 per-cell 原始值。
// [dither-index 2026-06-25] 跨 cell 边界软化已由烘焙期 Bayer dither（索引边缘融合）接管，
// 这里只保留单点 NEAREST 取值；旧的 4-tap 双线性 sample_*_lut_smooth 已删除。

// dyn_lut 单点 NEAREST。cid<0 → vec4(0)（下游 dyn_valid 会 gate 到 derived fallback）。
vec4 dyn_lut_nearest(vec2 uv) {
	int cid = decode_cell_index(uv);
	return (cid >= 0) ? texture(dyn_lut, cell_lut_uv(cid)) : vec4(0.0);
}

vec4 eco_lut_nearest(vec2 uv) {
	int cid = decode_cell_index(uv);
	return (cid >= 0) ? texture(eco_lut, cell_lut_uv(cid)) : vec4(0.0);
}
