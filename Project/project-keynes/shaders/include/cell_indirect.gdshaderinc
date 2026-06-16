// cell_indirect.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   Cell-index 间接寻址（province-ID indirection）的解码 helper。把每像素的
//   cell_index_tex(RG8) 解码成 cell.index，再把 cell.index 映射成 per-cell LUT
//   纹理（enum_lut / dyn_lut / eco_lut）的 texel 中心 uv。
//
// 调用方（Who）
//   - world_map.gdshader::fragment SETUP（use_cell_indirection 为真时）。
//
// 依赖（Why）
//   仅 uniforms.gdshaderinc（cell_index_tex / *_lut / lut_dims）。叶子模块。
//
// 性能（Cost）
//   decode_cell_index = 1 texture fetch（NEAREST）。cell_lut_uv 纯 ALU。
//   一次 enum/dyn/eco LUT 读 = decode(1) + lut(1) = 2 fetch（替代旧 1 fetch）。
// ─────────────────────────────────────────────────────────────────────────

// 解码每像素 cell 索引；返回 -1 表示 map 外（0xFFFF 哨兵）。
int decode_cell_index(vec2 uv) {
	vec2 rg = texture(cell_index_tex, uv).rg;
	int lo = int(rg.r * 255.0 + 0.5);
	int hi = int(rg.g * 255.0 + 0.5);
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
// dyn_lut / eco_lut 存的是 per-cell 原始值（NEAREST 取出会出现 hex 硬边）。
// 桌面端用 4-tap 双线性：在 cell_index_tex 的 bilinear footprint 上取 4 个 cell，
// 按子像素权重混合它们的 LUT 值，补回跨 cell 边界平滑（替代旧 CPU box-blur 的 LINEAR 消边）。
// 邻居落在 map 外（cid<0）时退回中心 cell 值，避免边缘被拉向 0。
// mobile 用单点 NEAREST（dyn_lut_nearest / eco_lut_nearest），省 fetch、接受轻微阶梯。

// dyn_lut 单点 NEAREST。cid<0 → vec4(0)（下游 dyn_valid 会 gate 到 derived fallback）。
vec4 dyn_lut_nearest(vec2 uv) {
	int cid = decode_cell_index(uv);
	return (cid >= 0) ? texture(dyn_lut, cell_lut_uv(cid)) : vec4(0.0);
}

vec4 sample_dyn_lut_smooth(vec2 uv) {
	int cid_c = decode_cell_index(uv);
	vec4 center = (cid_c >= 0) ? texture(dyn_lut, cell_lut_uv(cid_c)) : vec4(0.0);
	vec2 res = vec2(textureSize(cell_index_tex, 0));
	vec2 tc = uv * res - 0.5;
	vec2 base = floor(tc);
	vec2 f = tc - base;
	vec2 inv = 1.0 / res;
	int i00 = decode_cell_index((base + vec2(0.5, 0.5)) * inv);
	int i10 = decode_cell_index((base + vec2(1.5, 0.5)) * inv);
	int i01 = decode_cell_index((base + vec2(0.5, 1.5)) * inv);
	int i11 = decode_cell_index((base + vec2(1.5, 1.5)) * inv);
	vec4 c00 = (i00 >= 0) ? texture(dyn_lut, cell_lut_uv(i00)) : center;
	vec4 c10 = (i10 >= 0) ? texture(dyn_lut, cell_lut_uv(i10)) : center;
	vec4 c01 = (i01 >= 0) ? texture(dyn_lut, cell_lut_uv(i01)) : center;
	vec4 c11 = (i11 >= 0) ? texture(dyn_lut, cell_lut_uv(i11)) : center;
	return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}

vec4 eco_lut_nearest(vec2 uv) {
	int cid = decode_cell_index(uv);
	return (cid >= 0) ? texture(eco_lut, cell_lut_uv(cid)) : vec4(0.0);
}

vec4 sample_eco_lut_smooth(vec2 uv) {
	int cid_c = decode_cell_index(uv);
	vec4 center = (cid_c >= 0) ? texture(eco_lut, cell_lut_uv(cid_c)) : vec4(0.0);
	vec2 res = vec2(textureSize(cell_index_tex, 0));
	vec2 tc = uv * res - 0.5;
	vec2 base = floor(tc);
	vec2 f = tc - base;
	vec2 inv = 1.0 / res;
	int i00 = decode_cell_index((base + vec2(0.5, 0.5)) * inv);
	int i10 = decode_cell_index((base + vec2(1.5, 0.5)) * inv);
	int i01 = decode_cell_index((base + vec2(0.5, 1.5)) * inv);
	int i11 = decode_cell_index((base + vec2(1.5, 1.5)) * inv);
	vec4 c00 = (i00 >= 0) ? texture(eco_lut, cell_lut_uv(i00)) : center;
	vec4 c10 = (i10 >= 0) ? texture(eco_lut, cell_lut_uv(i10)) : center;
	vec4 c01 = (i01 >= 0) ? texture(eco_lut, cell_lut_uv(i01)) : center;
	vec4 c11 = (i11 >= 0) ? texture(eco_lut, cell_lut_uv(i11)) : center;
	return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
}
