// cell_indirect.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   Cell-index 间接寻址（province-ID indirection）的解码 helper。把 map_index_atlas
//   的 G/B 通道解码成 cell.index，再把 cell.index 映射成 per-cell LUT
//   纹理（enum_lut / dyn_lut）的 texel 中心 uv。
//
// 调用方（Who）
//   - world_map.gdshader::fragment SETUP（当前唯一动态视觉路径）。
//
// 依赖（Why）
//   仅 uniforms.gdshaderinc（map_index_atlas / *_lut / lut_dims）。叶子模块。
//
// [cell-field-web 2026-11-18] 条件编译：`decode_cell_index` / `dyn_lut_nearest` 两个
// 「按 uv 解 index 再查 LUT」的入口在 PK_CELL_FIELD_NO_LEGACY_LUT（预算变体 + 场函数）
// 下整段剔除；`cell_lut_uv` 始终保留（纯 ALU，与纹理声明无关）。理由见各自函数上方的
// 注释与 docs/plans/terrain-cell-field-web-plan.md §2 / §3.2。
//
// 性能（Cost）
//   decode_cell_index = 1 texture fetch（NEAREST）。cell_lut_uv 纯 ALU。
//   一次 enum/dyn LUT 读 = decode(1) + lut(1) = 2 fetch（替代旧 1 fetch）。
// ─────────────────────────────────────────────────────────────────────────

// 解码每像素 cell 索引；返回 -1 表示 map 外（0xFFFF 哨兵）。
// [cell-field-web 2026-11-18] 预算 + 场函数组合（PK_CELL_FIELD_NO_LEGACY_LUT）下
// map_index_atlas 已从声明里删掉，本入口在该组合下**没有任何合法调用点**：world_map 的
// PK 路径全部改走场函数（pk_hex_cell_field / pk_cell_state_at），GI 弹射改走 cell_table
// layer3。整段包进门里 ⇒ 残留调用点变成编译错误，而不是又回到第 9 槽白纹理的静默错误
// （方案 §2 表 / §3.2）。注意 `cell_lut_uv()` **不在**门里：它是纯 ALU，非 PK 路径与
// 其它按 index 排列的 LUT 仍然需要它。
#ifndef PK_CELL_FIELD_NO_LEGACY_LUT
int decode_cell_index(vec2 uv) {
	vec2 gb = visual_sample_map_index(uv).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}
#endif

// 把 cell.index 映射成 per-cell LUT 网格的 texel 中心 uv（NEAREST 采样安全）。
vec2 cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) { lw = 1; }
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

// ── Stage C：per-cell LUT 平滑采样 ───────────────────────────────────────
// dyn_lut 存的是 per-cell 原始值。eco_lut 已从主地形 shader 移除（植被层自有）。
// [dither-index 2026-06-25] 跨 cell 边界软化已由烘焙期 Bayer dither（索引边缘融合）接管，
// 这里只保留单点 NEAREST 取值；旧的 4-tap 双线性 sample_*_lut_smooth 已删除。

// dyn_lut 单点 NEAREST。cid<0 → vec4(0)（下游 dyn_valid 会 gate 到 derived fallback）。
// [cell-field-web 2026-11-18] 同上：dyn_lut 在该组合下不再声明，本函数也没有调用点
// （动态状态改读 cell_table layer1 state）。`decode_dyn` 这个名字在本文件里从来没有过
// 独立实现 —— 方案 §2 表写的 `decode_dyn` 就是这里的 dyn_lut_nearest（同一处 LUT 读取）。
#ifndef PK_CELL_FIELD_NO_LEGACY_LUT
vec4 dyn_lut_nearest(vec2 uv) {
	int cid = decode_cell_index(uv);
	return (cid >= 0) ? texture(dyn_lut, cell_lut_uv(cid)) : vec4(0.0);
}
#endif
