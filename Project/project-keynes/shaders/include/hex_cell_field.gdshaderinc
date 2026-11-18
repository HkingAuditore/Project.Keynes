// hex_cell_field.gdshaderinc
// ═══════════════════════════════════════════════════════════════════════════
// [cell-field 2026-11-18] 解析格界（hex cell field）—— 方案唯一真源。
//
// [cell-field-overlays 2026-11-18 / O0] **本文件现在是包装层**：
//   纯数学（三格 / 重心 / dom / gap / 锐化 / AA / 坐标工具 / 带宽上限常量）已经搬到
//   `shaders/include/hex_cell_core.gdshaderinc`（零 uniform、零 sampler、零 include），
//   由地形、天气 overlay、战争迷雾三方共用。
//   本文件只保留**必须碰 uniform / sampler 的那一层**：
//     · 用 uniform（`hex_size` / `pk_cell_map_w` / `pk_cell_map_h`）组装 `PkHexGrid`；
//     · 扭曲场解码 `pk_boundary_warp_world`（要 `world_origin` / `world_size` /
//       `wrap_map_uv` / `terrain_warp_*` / 边界扭曲采样器）；
//     · `cell_table` 的 texelFetch 与层号常量；
//     · 只给地形用的门控（`pk_hex_px` / `pixel_noise` 依赖 terrain 的 include 次序）。
//   公开 API 的**签名与语义一字未改**（`HexCellField` / `pk_hex_cell_field*` /
//   `pk_cell_field_*` / `pk_cell_*` / `pk_field_*` / `pk_byte_of` 等）。
//   唯一的签名变化：`pk_axial_to_offset_wrapped` 现在只有核心里那一份，**多一个 map_w
//   参数**（`ivec2 pk_axial_to_offset_wrapped(ivec2 qr, int map_w)`）；GLSL 不支持函数
//   重载，所以包装层不再提供单参版本，本文件内的调用点已全部改齐。
//
// 方案文档：docs/plans/terrain-hex-mesh-implementation-plan.md §3.1–§3.3
// 落地契约：docs/plans/terrain-cell-field-contract.md
//
// 原则：**烘焙连续量，不烘焙类别量。** 像素「属于哪几格、各占多少」不再从逐像素
// 索引图读，而是由「世界坐标 + 一张连续扭曲场」解析算出：
//   1. p = wrap(wp) + warp(wp)                       扭曲后的世界坐标
//   2. a = 分数 axial 坐标（与 CPU HexUtils.world_to_cube 同口径，pointy-top / odd-r）
//   3. floor/fract 锁定一个**对偶三角形**（六边形 Voronoi 的 Delaunay 对偶）
//   4. fract 直接给出该三角形三个顶点格的重心权重
//
// 为什么这样能得到与 CPU 相同的归属：
//   三角形内任意点的最近格中心必在这三个顶点之中 ⇒ argmax(重心) ≡ cube_round。
//   「w_A = w_B」那条等值线正好是六边形的边，三格交点就是三角形重心。
//   归属由坐标解析给出，与纹素边界无关 ⇒ 任意 zoom 都不会出现纹素台阶。
//
// ── 依赖（caller 必须在这些 include 之后 include 本文件）──────────────────
//   uniforms.gdshaderinc               —— hex_size / map_dims / wrap_* / visual_quality / B_SEA_ICE
//   visual_tile_sampling.gdshaderinc   —— visual_sample_boundary_warp / cell_table sampler
//   terrain_surface_detail.gdshaderinc —— terrain_edge_screen_width_px()
//   pixel_scale.gdshaderinc            —— pk_hex_px()（门控选格的抖动幅度用）
//   （本文件只做 ALU + texelFetch；不含循环、不含 texture() 的隐式求导，
//     因此可以放进任何控制流，见方案 §3.9。唯一的导数在 pk_hex_cell_field 里，
//     它由调用方在非一致控制流之外调用 —— 契约 §9.4。）
//
// ── 单位约定（三处必须一致：C++ / GDScript 镜像 / 本文件）───────────────
//   gap  = (w_dom - w_i) * √3  ∈ [0, √3]
//        沿格中心连线 gap = 2·d / hex_size（d = 到格界的距离）
//        ⇒ 与 C++ run_bake_terrain_index_pass 的 edge_distance
//          （edge_distance_units = "normalized_hex_center_gap"）**同一单位**。
//   平局次序 dom：0 > 1 > 2（比较次序写死；CPU 镜像必须同序，parity 测试依赖它）。
//   带宽上限 PK_FIELD_BAND_MAX = 0.86 与 √3 的**唯一字面量**在核心里（见下）。
// ═══════════════════════════════════════════════════════════════════════════
#ifndef PK_HEX_CELL_FIELD_INC
#define PK_HEX_CELL_FIELD_INC

// [cell-field-overlays 2026-11-18 / O0] 纯数学部分。核心自带 include guard，
// 天气 / 迷雾再 include 一次也不会重复定义。
#include "res://shaders/include/hex_cell_core.gdshaderinc"

// 带宽上限 PK_FIELD_BAND_MAX 与 √3 的定义都在核心里（单一字面量）：
//   PK_FIELD_BAND_MAX = 0.86   —— 第三格在共享边上的 gap ≥ √3/2 ≈ 0.866，
//                                 带宽一旦超过它，沿穿过格中心的线会出现接缝。
//   PK_HEX_SQRT3      = 1.7320508075688772
// 这里只留一个**别名**，让 terrain 侧既有的 `PK_FIELD_SQRT3` 用例（world_map 的
// debug 视图 18 要用它算 hex 角点）继续可用，同时不出现第二份字面量。
const float PK_FIELD_SQRT3 = PK_HEX_SQRT3;

// warp 场解码：C++ 烘 RG8 时存的是 clamp((warp_x + hi_x) / terrain_warp_range, -1, 1)
// 映射到 [0,1]，所以这里先解回 [-1,1] 再乘回 range。
// 两个 uniform 由 GDScript 从 C++ 报告的 boundary_warp_range 推送，**不在 shader 里
// 写死**：C++ 与 shader 各写一份常量是这类几何契约最常见的漂移点。
uniform float terrain_warp_range = 1.6;
uniform float terrain_warp_amp = 0.4;

// cell_table 三层（offset 空间，1 texel = 1 格）：见 visual_tile_sampling 的层契约。
// layer0 class : R=biome  G=vegetation  B=cover  A=landform
// layer1 state : R=temp   G=wet         B=snow   A=vitality / sea_ice（与 dyn_lut 同字节）
// layer2 aux   : R=fog_k  G=water_depth B=flags  A=reserved
// 层号常量必须与 GDScript DCCellTableCodec.LAYER_* 同值。
#define PK_CELL_LAYER_CLASS 0
#define PK_CELL_LAYER_STATE 1
#define PK_CELL_LAYER_AUX   2

// cell_table 尺寸别名。**用 vec2 而不是 ivec2**：本项目 shader 侧的整数尺寸统一走
// `uniform vec2 <name>`（见 uniforms 的 lut_dims / hm_resolution），GDScript 侧用
// Vector2 推送，跨后端零风险；ivec2 uniform 在部分 Compatibility 路径上不可靠。
#define pk_cell_map_w int(cell_table_size.x + 0.5)
#define pk_cell_map_h int(cell_table_size.y + 0.5)

// 坐标工具 pk_posmod / pk_axial_to_offset / pk_axial_to_offset_wrapped 在核心里
// （纯数学，天气与迷雾也要用）。回绕版的签名是
//   `ivec2 pk_axial_to_offset_wrapped(ivec2 qr, int map_w)`
// —— map_w 必须显式传（核心没有 uniform）。本文件一律传 `pk_cell_map_w`。

// ─────────────────────────────────────────────────────────────────────────
// 网格参数：uniform → PkHexGrid（核心唯一的几何入口）
// ─────────────────────────────────────────────────────────────────────────
// 只在需要时调；返回值是纯值，调用点自己拿一个局部变量复用即可。
PkHexGrid pk_hex_field_grid() {
	PkHexGrid g;
	g.hex_size = hex_size;
	g.map_w = pk_cell_map_w;
	g.map_h = pk_cell_map_h;
	return g;
}

// ─────────────────────────────────────────────────────────────────────────
// 扭曲场
// ─────────────────────────────────────────────────────────────────────────

// 世界坐标处的扭曲偏移（世界单位）。未烘焙 warp 层时恒为 0 ⇒ 退化成直边六边形
// 归属（仍然与 CPU cube_round 一致，只是没有「侵蚀弯曲」观感）。
vec2 pk_boundary_warp_world(vec2 wp_wrapped) {
#ifdef VT_USE_BOUNDARY_WARP
	if (!terrain_warp_layer_bound) {
		return vec2(0.0);
	}
	vec2 uv = wrap_map_uv((wp_wrapped - world_origin) / world_size);
	vec2 rg = visual_sample_boundary_warp(uv).rg;
	// RG8 解码 ≈ 0.1 wu 量化误差，zoom 6 下 < 1 px；双线性插值保证场连续。
	return (rg * 2.0 - 1.0) * (terrain_warp_range * hex_size * terrain_warp_amp);
#else
	return vec2(0.0);
#endif
}

// ─────────────────────────────────────────────────────────────────────────
// 场函数
// ─────────────────────────────────────────────────────────────────────────
struct HexCellField {
	ivec2 c0;       // offset 坐标 (col, row)，col 已 posmod；row 越界 = padding
	ivec2 c1;
	ivec2 c2;
	vec3 w_raw;     // 扭曲坐标上的重心坐标（连续量用，§3.3）
	vec3 w;         // 锐化后权重，Σ=1（类别量用，§3.3）
	vec3 gap;       // 与主导格的 gap，normalized_hex_center_gap 口径
	int dom;        // argmax(w_raw)，== CPU cube_round(p + warp)
	// [cell-field 2026-11-18] 本像素**实际使用**的锐化带宽（gap 单位）：
	//   band = clamp(max(band_gap, AA 项), 1e-4, PK_FIELD_BAND_MAX)
	// AA 项 = pk_hex_field_aa(world_pos, hex_size, terrain_edge_screen_width_px())。
	// 只给 debug 视图 23（tests/world/cell_field_gpu_parity_probe.gd 回读比对）与
	// 以后的诊断用；任何着色路径都不得读它（它不是数据契约的一部分）。
	// **CPU 镜像 DCHexCellField 不产出这个成员**：GDScript 没有屏幕导数，等价值是
	// clamp(band_gap, 1e-4, PK_FIELD_BAND_MAX)（见 hex_cell_field.gd 的 field_at 注释）。
	float band;
};

// world_pos 必须是**未回绕**的顶点世界坐标（即 varying v_world），函数内部自己 wrap。
//
// 为什么入参是未回绕坐标而不是已回绕坐标（review 2026-11-18 第 1 条）：
// AA 带宽要取屏幕导数。如果对**已回绕**坐标求导，跨过经线接缝的那个 2×2 像素块里
// q 会突然跳 map_w（60 格），fwidth 直接爆掉 ⇒ 带宽被顶到 PK_FIELD_BAND_MAX，
// 接缝处出现一条 1~2 像素宽、混合拉满的竖线。旧路径没这个问题，因为它求导的对象是
// 采样出来的 edge_distance，那个值跨接缝是连续的。
// 对未回绕的 v_world 求导则处处连续（回绕只是一次 mod，不改变局部缩放）。
//
// band_gap 是调用方给的带宽（gap 单位）；最终带宽还要和屏幕导数取 max，
// 以免近景时 AA 带窄于 1 像素。
//
// [cell-field-overlays 2026-11-18 / O0] 数学全在核心：
//   pk_hex_tri → w_raw + 三格；pk_hex_tri_w_gap → gap；pk_hex_tri_dom → dom；
//   pk_hex_sharpen → w；pk_hex_field_aa → AA 项。本函数只做装配。
HexCellField pk_hex_cell_field(vec2 world_pos, float band_gap) {
	HexCellField f;
	// 1. 扭曲。先 wrap 保证 p 的量级小（fract 精度），再叠加扭曲偏移。
	vec2 wp = wrap_world_pos(world_pos);
	vec2 p = wrap_world_pos(wp + pk_boundary_warp_world(wp));

	// 2–5. 分数 axial → 对偶三角形 → 三格 offset（横向只 posmod col）+ 重心坐标。
	PkHexTri tri = pk_hex_tri(p, pk_hex_field_grid());
	f.c0 = tri.c0;
	f.c1 = tri.c1;
	f.c2 = tri.c2;
	f.w_raw = tri.w_raw;

	// 6. gap 与主导格。
	f.gap = pk_hex_tri_w_gap(tri);

	// 7. 带宽：AA 下限用**未回绕**坐标的导数（见上面的注释）。
	//    |∇gap| = 2/hex_size 是精确值 ⇒ 一个屏幕像素对应的 gap 跨度就是
	//    2·pixel_world/hex_size（核心 pk_hex_field_aa 的系数来源）。
	float aa = pk_hex_field_aa(world_pos, hex_size, terrain_edge_screen_width_px());
	float band = clamp(max(band_gap, aa), 1e-4, PK_FIELD_BAND_MAX);
	f.band = band;
	f.w = pk_hex_sharpen(f.w_raw, band);

	// 8. 平局次序写死 0 > 1 > 2（CPU 镜像必须同序）。
	f.dom = pk_hex_tri_dom(tri);
	return f;
}

// 便捷入口：band 取 terrain_ecotone_width（与 C++ edge_distance 同单位，方案 §3.2）。
HexCellField pk_hex_cell_field_default(vec2 world_pos) {
	return pk_hex_cell_field(world_pos, terrain_ecotone_width);
}

// ── 只求归属、不求权重的入口（P4-1 纹样锚点选格用）──────────────────────
// **不含 fwidth / dFdx**：方案 §3.9 第 3 条规定非一致控制流里的导数未定义，
// 而纹样锚点选格就是在「画不画这个点」的分支里按锚点坐标调一次。
// 也因此它没有 AA 项，只给整数归属，采样次数与 pk_hex_cell_field 相同（1 次 warp）。
// [cell-field-overlays 2026-11-18 / O0] 实现改成调核心的 pk_hex_tri + pk_hex_tri_dom；
// 顶点 offset 已经是核心算好的回绕 offset，不用再换一次。
ivec2 pk_hex_dom_offset(vec2 world_pos) {
	vec2 wp = wrap_world_pos(world_pos);
	vec2 p = wrap_world_pos(wp + pk_boundary_warp_world(wp));
	PkHexTri tri = pk_hex_tri(p, pk_hex_field_grid());
	int dom = pk_hex_tri_dom(tri);
	return (dom == 0) ? tri.c0 : ((dom == 1) ? tri.c1 : tri.c2);
}

// 到最近格界的距离（gap 单位），等价于今天 edge_distance.R 的语义：
// dominant 的 gap 恒为 0，所以取两个非主导格里较小的那个。
// 连续、无纹素台阶 —— 直接喂给现有的 terrain_edge_secondary_weight_d() /
// compute_terrain_static_material()，下游公式一个字都不用改。
// [cell-field-overlays 2026-11-18 / O0] 语义与核心 pk_hex_tri_gap **逐值相等**：
// 地形早退判定（world_map.gdshader 的 field_edge_gap >= PK_FIELD_BAND_MAX）读它，
// 迷雾侧复算同一判定时读核心版本 ⇒ 两条路径必须给出同一个数。
float pk_cell_field_edge_gap(HexCellField f) {
	PkHexTri tri;
	tri.c0 = f.c0;
	tri.c1 = f.c1;
	tri.c2 = f.c2;
	tri.w_raw = f.w_raw;
	return pk_hex_tri_gap(tri);
}

// 权重最低的格的下标（0/1/2）—— 三格里的"第三名"。
int pk_cell_field_least(HexCellField f) {
	return (f.w.x <= f.w.y && f.w.x <= f.w.z) ? 0 : ((f.w.y <= f.w.z) ? 1 : 2);
}

// 权重排序后的三格下标，从高到低：pk_cell_field_rank(f, 0/1/2) ∈ {0,1,2}。
// 用比较 + 三元选择实现，无分支、无循环（§3.9）。
int pk_cell_field_rank(HexCellField f, int rank) {
	int i0 = f.dom;
	int i2 = pk_cell_field_least(f);
	int i1 = 3 - i0 - i2;   // 0+1+2 = 3
	return (rank == 0) ? i0 : ((rank == 1) ? i1 : i2);
}

vec4 pk_cell_field_ranked_class(HexCellField f, int rank,
		vec4 e0, vec4 e1, vec4 e2) {
	int i = pk_cell_field_rank(f, rank);
	return (i == 0) ? e0 : ((i == 1) ? e1 : e2);
}

float pk_cell_field_ranked_weight(HexCellField f, int rank) {
	int i = pk_cell_field_rank(f, rank);
	return (i == 0) ? f.w.x : ((i == 1) ? f.w.y : f.w.z);
}

float pk_cell_field_ranked_weight_raw(HexCellField f, int rank) {
	int i = pk_cell_field_rank(f, rank);
	return (i == 0) ? f.w_raw.x : ((i == 1) ? f.w_raw.y : f.w_raw.z);
}

ivec2 pk_cell_field_offset(HexCellField f, int i) {
	return (i == 0) ? f.c0 : ((i == 1) ? f.c1 : f.c2);
}

ivec2 pk_cell_field_dom_offset(HexCellField f) {
	return pk_cell_field_offset(f, f.dom);
}

float pk_cell_field_dom_weight(HexCellField f) {
	return max(f.w.x, max(f.w.y, f.w.z));
}

// ─────────────────────────────────────────────────────────────────────────
// per-cell 查表（texelFetch，无过滤、与像素位置无关）
// ─────────────────────────────────────────────────────────────────────────
// row 越界（南北边界）= padding，类别按 B_SEA_ICE（与今天 cid < 0 的表现一致），
// 不查表。用 mix 而不是 if：本函数在 fragment 里被无条件调用 3 次。
vec4 pk_cell_table_fetch(ivec2 c, int layer) {
	int row = clamp(c.y, 0, pk_cell_map_h - 1);
	vec4 v = texelFetch(cell_table, ivec3(pk_posmod(c.x, pk_cell_map_w), row, layer), 0);
	float inside = step(0.0, float(c.y)) * step(float(c.y), float(pk_cell_map_h - 1));
	// padding 的 class 只有 R 通道有意义（= B_SEA_ICE），其余通道置 0。
	vec4 pad = vec4(float(B_SEA_ICE) / 255.0, 0.0, 0.0, 0.0);
	return mix(pad, v, inside);
}

vec4 pk_cell_class_at(ivec2 c)  { return pk_cell_table_fetch(c, PK_CELL_LAYER_CLASS); }
vec4 pk_cell_state_at(ivec2 c)  { return pk_cell_table_fetch(c, PK_CELL_LAYER_STATE); }
vec4 pk_cell_aux_at(ivec2 c)    { return pk_cell_table_fetch(c, PK_CELL_LAYER_AUX); }

// 三格一次取齐（调用方常要 3-way；写成固定三连，采样次数是常数，§3.9 第 2 条）。
void pk_cell_field_classes(HexCellField f, out vec4 e0, out vec4 e1, out vec4 e2) {
	e0 = pk_cell_class_at(f.c0);
	e1 = pk_cell_class_at(f.c1);
	e2 = pk_cell_class_at(f.c2);
}

// RGBA8 归一化 → 整数通道。
int pk_byte_of(float v) { return int(v * 255.0 + 0.5); }
int pk_cell_biome_of(vec4 cls)  { return pk_byte_of(cls.r); }
int pk_cell_veg_of(vec4 cls)    { return pk_byte_of(cls.g); }
int pk_cell_cover_of(vec4 cls)  { return pk_byte_of(cls.b); }
int pk_cell_landform_of(vec4 cls) { return pk_byte_of(cls.a); }

// 按权重挑出某一通道的期望值（类别量不要这样用；这里给「LOW 档只读主导格」与
// 「纹样锚点选格」这类只需要一个整数的场合）。
vec3 pk_cell_field_weight(HexCellField f) { return f.w; }

// ─────────────────────────────────────────────────────────────────────────
// 三格 3-way 加权：类别量用锐化权重 w，连续量用原始权重 w_raw（方案 §3.3）
// ─────────────────────────────────────────────────────────────────────────
float pk_cell_field_blend_raw(HexCellField f, vec3 v) {
	return dot(v, f.w_raw);
}

// ─────────────────────────────────────────────────────────────────────────
// 门控阶段选格（方案 §3.6）
// ─────────────────────────────────────────────────────────────────────────
// 植被 / 覆盖 / 地貌着色这类「只能按一种 biome 画」的阶段，今天靠 DitherUV 在主 / 副
// 之间二选一（纹素化的 Bayer 网点）。改为在**每格世界锚定的抖动量**上做 argmax：
//   近景：权重接近的格子互相争抢 ⇒ 得到一条自然的碎边；
//   远景：抖动量按 hex 的像素投影淡出 ⇒ 退化成 argmax(w)，即弯曲的硬边。
//
// [review 2026-11-18 第 2 条] 抖动必须是**随位置变化**的噪声，不能是整格常量。
// 如果每格只加一个常量 j_i，胜负线落在 (w_A − w_B) = (j_B − j_A) 上，右边是常数 ⇒
// 效果只是把整条边界平移一个固定量（且各对邻格平移量不同）——那是一条光滑、但与颜色
// 边界错开的线，不是碎边。方案 §3.6 写的是 n(wp, cell_i)，即每格一份随位置变化的噪声。
//
// 实现上不新增采样：SETUP 已经采过一次 `pixel_noise`（预烘噪声包），直接复用它的 .r，
// 每格加一个不同相位再 fract ⇒ 同一位置的噪声在三个格子上被解相关，边界才会碎。
// 见契约文档"偏离 D2"。
// （这一族留在包装层：它是**地形门控**专用，依赖 pixel_noise 与 pk_hex_px，
//   天气 / 迷雾都不用，不属于核心数学。）
const float PK_GATE_JITTER_AMP = 0.30;

// 2D 整数格 hash → [0,1]。uint 位运算在 GLSL ES 3.00 / Vulkan 都成立；显式 highp 防止
// mediump 下高位被截断（那样整片格子会退化成周期图案）。
float pk_cell_hash01(ivec2 c) {
	highp uint h = uint(c.x) * 0x1F123BB5u ^ uint(c.y) * 0x9E3779B1u;
	h ^= h >> 15u;
	h *= 0x2545F491u;
	h ^= h >> 13u;
	return float(h & 0x00FFFFFFu) * (1.0 / 16777215.0);
}

// 返回抖动后胜出格的 (biome, vegetation, cover)。
// 用 ivec3 而不是三个 out 参数：调用点多在 SETUP 里，写起来更短。
// pixel_noise = SETUP 里那次全局噪声采样（§3.8 已计入预算，这里零新增采样）。
ivec3 pk_cell_field_gate_class(HexCellField f, vec4 e0, vec4 e1, vec4 e2,
		vec4 pixel_noise) {
#ifdef PK_QUALITY_LOW
	// LOW 档：§3.8 的预算是"只读主导格"，门控阶段也不做抖动 ⇒ 直接 argmax(w)。
	int i_low = f.dom;
	vec4 e_low = (i_low == 0) ? e0 : ((i_low == 1) ? e1 : e2);
	return ivec3(pk_byte_of(e_low.r), pk_byte_of(e_low.g), pk_byte_of(e_low.b));
#else
	// hex 在屏幕上不足 2px 时格界本身就是亚像素的，抖动只会变成闪烁 ⇒ 淡出。
	float amp = PK_GATE_JITTER_AMP * smoothstep(2.0, 8.0, pk_hex_px());
	// 三格相位不同：fract(v + phase_i) 在 v 变化时各自的回绕点不同 ⇒ 互相解相关。
	vec3 phase = vec3(pk_cell_hash01(f.c0), pk_cell_hash01(f.c1), pk_cell_hash01(f.c2));
	vec3 jitter = fract(vec3(pixel_noise.r) * 3.0 + phase) - 0.5;
	vec3 score = f.w + amp * 2.0 * jitter;
	int i = (score.x >= score.y && score.x >= score.z) ? 0
			: ((score.y >= score.z) ? 1 : 2);
	vec4 e = (i == 0) ? e0 : ((i == 1) ? e1 : e2);
	return ivec3(pk_byte_of(e.r), pk_byte_of(e.g), pk_byte_of(e.b));
#endif
}

// ─────────────────────────────────────────────────────────────────────────
// 场数据包：跨 include 传递的唯一形式
// ─────────────────────────────────────────────────────────────────────────
// Godot 的 shader 语言**不允许全局非常量变量**（"Global non-constant variables are
// not supported"），所以场不能在 SETUP 里算一次存进全局给下游读。约定是：
//
//   1. world_map.gdshader 的 SETUP 算**一次** `pk_hex_cell_field_default(wp)` +
//      `pk_cell_field_classes(f, e0, e1, e2)`；
//   2. 以 `HexCellField f, vec4 e0, vec4 e1, vec4 e2` 四个入参往下传：
//        render_land_pipeline(...  #ifdef PK_CELL_FIELD , f, e0, e1, e2 #endif)
//        render_water_pipeline(... 同上)
//        compute_terrain_static_material_field(f, e0, e1, e2, ...)
//   3. 签名的那 4 个参数用 `#ifdef PK_CELL_FIELD` 包住，关闭时函数原型与今日逐字相同
//      ⇒ 预处理产物不变（截图 diff = 0 的验收前提）。
//
// 下面三个 helper 是"主导格"与"3-way 通道混合"的标准写法，避免各调用点各写一套。

vec4 pk_field_class_of(HexCellField f, vec4 e0, vec4 e1, vec4 e2) {
	return (f.dom == 0) ? e0 : ((f.dom == 1) ? e1 : e2);
}

// 某通道按给定权重的三格混合。weights 传 f.w（类别量）或 f.w_raw（连续量）。
//   channel: 0=R(biome) 1=G(veg) 2=B(cover) 3=A(landform)
float pk_field_blend_channel(int channel, vec3 weights,
		vec4 e0, vec4 e1, vec4 e2) {
	float a = (channel == 0) ? e0.r : ((channel == 1) ? e0.g
			: ((channel == 2) ? e0.b : e0.a));
	float b = (channel == 0) ? e1.r : ((channel == 1) ? e1.g
			: ((channel == 2) ? e1.b : e1.a));
	float c = (channel == 0) ? e2.r : ((channel == 1) ? e2.g
			: ((channel == 2) ? e2.b : e2.a));
	return a * weights.x + b * weights.y + c * weights.z;
}

float pk_field_blend_class_raw(int channel, HexCellField f,
		vec4 e0, vec4 e1, vec4 e2) {
	return pk_field_blend_channel(channel, f.w_raw, e0, e1, e2);
}

// ─────────────────────────────────────────────────────────────────────────
// 水陆判定（方案 §3.7）
// ─────────────────────────────────────────────────────────────────────────
// 陆地与水面两个 program 必须调用**同一个**函数、读同一份数据，海岸线才是 dom 在水 / 陆
// 之间切换的那条弯曲等值线。
// e0/e1/e2 = 三格 class（先用 pk_cell_field_classes 取好，避免重复 fetch）。
int pk_cell_field_dom_biome(HexCellField f, vec4 e0, vec4 e1, vec4 e2) {
	return (f.dom == 0) ? pk_byte_of(e0.r)
			: ((f.dom == 1) ? pk_byte_of(e1.r) : pk_byte_of(e2.r));
}

bool pk_cell_field_is_water_dom(HexCellField f, vec4 e0, vec4 e1, vec4 e2) {
	return terrain_static_biome_is_water(pk_cell_field_dom_biome(f, e0, e1, e2));
}

#endif // PK_HEX_CELL_FIELD_INC
