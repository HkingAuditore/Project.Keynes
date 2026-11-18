// hex_cell_core.gdshaderinc
// ═══════════════════════════════════════════════════════════════════════════
// [cell-field-overlays 2026-11-18 / O0] 解析格界（hex cell field）的**纯数学核心**。
//
// 方案文档：docs/plans/terrain-cell-field-overlays-plan.md §3.1（核心拆分）、§3.2（坐标契约）
// 落地契约：docs/plans/terrain-cell-field-contract.md §1（不变量表）、§9.1（回绕接缝 AA）
//
// 为什么要有这个文件
//   地形的场函数（`hex_cell_field.gdshaderinc`）直接读 `hex_size` / `cell_table_size` /
//   `world_origin` / `wrap_*` / `terrain_warp_*`，这些都来自 `uniforms.gdshaderinc`。
//   而 `weather_overlay.gdshader` 与 `fog_of_war.gdshader` **不 include** uniforms（它们
//   各自声明了自己的 world_origin / world_size / wrap_*，再 include 一整份 uniforms 会
//   重复声明，还会拖进一大串用不到的 uniform）。所以把「纯数学、零 uniform」的部分提到
//   本文件，让地形 / 天气 / 迷雾共用同一套场函数：**一份数学，三个消费者**。
//
// 本文件的硬约束（验收项，`terrain_shader_variant_test.gd` 有源级断言守着）
//   1. **零 uniform、零 sampler、零 include**。全部是 `const` + `struct` + 纯函数。
//   2. 不读任何全局状态：几何参数一律从 `PkHexGrid` 入参进来，屏幕导数只从传入的
//      **未回绕**世界坐标取（见 pk_hex_field_aa）。
//   3. 无循环、无纹理采样、无隐式求导（fwidth 除外，且只在那一个函数里）。
//
// ── 与方案 §3.1 的一处**刻意偏离**（原文照录，便于评审核对）──────────────
//   方案 §3.1 写的是 `struct PkHexTri { ivec2 c[3]; vec3 w_raw; };`，本文件改为三个
//   独立字段 `ivec2 c0; ivec2 c1; ivec2 c2;`。理由：
//     · Godot 4 的 shader 语言对「struct 内数组」支持不可靠（赋值 / 逐元素写 / 按
//       uniform 或函数返回值传递时都可能编不过或静默退化），而本项目已经用
//       「三个独立 ivec2 字段」的 `HexCellField` 在 5 个 shader 变体上验证过；
//     · 三角形顶点是**固定 3 个**，展开写没有任何表达力损失，且索引选格本来就是
//       三元选择 `(i == 0) ? c0 : ((i == 1) ? c1 : c2)`（无数组构造器可用）。
//   调用方写法：`t.c0 / t.c1 / t.c2`，不要写 `t.c[i]`。
//
// ── 单位约定（三处必须一致：C++ / GDScript 镜像 / 本文件）─────────────────
//   gap  = (w_dom - w_i) * √3  ∈ [0, √3]
//        沿格中心连线 gap = 2·d / hex_size（d = 到格界的距离）
//        ⇒ 与 C++ run_bake_terrain_index_pass 的 edge_distance
//          （edge_distance_units = "normalized_hex_center_gap"）**同一单位**。
//   平局次序 dom：0 > 1 > 2（比较次序写死；CPU 镜像必须同序，parity 测试依赖它）。
//
// ── 坐标契约（方案 §3.2 / 契约 §9.1，两个消费方都必须遵守）────────────────
//   · `pk_hex_tri()` 的入参 `p_wrapped` **必须是已回绕**的世界坐标。回绕本身要用
//     `wrap_world_pos()`，而那是 uniforms 里的函数 ⇒ 回绕留在调用方（包装层 / 天气 /
//     迷雾各自 wrap 一次）。核心只管「已回绕坐标 → 三格 + 重心」。
//   · AA 带宽（`pk_hex_field_aa`）的导数**必须取未回绕的世界坐标**：对已回绕坐标求导，
//     跨经线接缝的那个 2×2 像素块里 q 会突然跳 map_w（60 格），fwidth 直接爆掉 ⇒
//     带宽被顶到 PK_FIELD_BAND_MAX，接缝处出现一条 1~2 像素宽的竖线（契约 §9.1）。
//   · 横向回绕只对 offset 的 **col** 做 posmod，**不在 axial 空间取模**：同一行里 q 平移
//     map_w 才对应 col 平移 map_w。row 越界 = 南北 padding，由调用方的查表函数处理。
// ═══════════════════════════════════════════════════════════════════════════
#ifndef PK_HEX_CORE_INC
#define PK_HEX_CORE_INC

// √3：gap 的换算系数（gap 单位 = 2·d/hex_size）。单一字面量在这里；
// `hex_cell_field.gdshaderinc` 的 `PK_FIELD_SQRT3` 是本常量的别名（不重复写值）。
const float PK_HEX_SQRT3 = 1.7320508075688772;

// 带宽上限：对偶三角形切换时，第三格在共享边上的 gap ≥ 0.5·√3 ≈ 0.866。
// 带宽一旦超过它，第三格会在共享边一侧有权重、另一侧突然消失 ⇒ 沿穿过格中心的
// 那些线出现接缝。0.86 留 0.6% 余量。验收项「带宽拉到上限时无接缝」。
// 这个常量放在核心里（而不是包装层）：迷雾的「地形早退像素必须不透明」判定
// （方案 §3.6 约束 3）要用**同一个**上限，而迷雾不 include 包装层。
const float PK_FIELD_BAND_MAX = 0.86;

// 网格几何参数。**由调用方从自己的 uniform 组装**（核心不碰任何 uniform）：
//   hex_size = 世界单位 / hex
//   map_w    = 地图列数（横向回绕周期；1 texel = 1 格）
//   map_h    = 地图行数（核心自身不用它：南北 padding 由调用方的查表函数 clamp）
struct PkHexGrid {
	float hex_size;
	int map_w;
	int map_h;
};

// 一个对偶三角形：三个顶点格的 offset 坐标（col 已 posmod，row 未做南北 clamp）+ 重心坐标。
// 重心顺序固定对应 c0 / c1 / c2，Σ = 1（up / down 三角形是彼此的镜像表达式）。
struct PkHexTri {
	ivec2 c0;
	ivec2 c1;
	ivec2 c2;
	vec3 w_raw;
};

// ─────────────────────────────────────────────────────────────────────────
// 坐标工具
// ─────────────────────────────────────────────────────────────────────────

// GLSL ES 3.00 对负操作数的 % 结果未定义、/ 的取整方向在旧驱动上也不可靠，而 offset
// 列号在地图西缘一定是负数。统一用 floor 实现（方案 §3.1「负数整除 / 取模」）。
int pk_posmod(int a, int m) {
	float fm = float(m);
	return a - m * int(floor(float(a) / fm));
}

// axial (q, r) → odd-r offset (col, row)。
//   col = q + (r - (r & 1)) / 2 ,  row = r
// r 为负时 (r & 1) 走二补码，与 C++ / GDScript 一致；(r - (r&1)) 恒为偶数，
// 故 /2 是精确整除，不依赖截断方向。
// **不做** map_w 取模：横向回绕只对 col 做 posmod（见 pk_axial_to_offset_wrapped），
// 不能在 axial 空间取模 —— 同一行里 q 平移 map_w 才对应 col 平移 map_w。
ivec2 pk_axial_to_offset(ivec2 qr) {
	int r = qr.y;
	return ivec2(qr.x + (r - (r & 1)) / 2, r);
}

// 只对 col 取模的回绕版（row 原样保留：南北越界在查表时按 padding 处理）。
// map_w 由调用方从 `PkHexGrid` 传入 —— 核心没有 uniform，参数必须显式。
ivec2 pk_axial_to_offset_wrapped(ivec2 qr, int map_w) {
	ivec2 o = pk_axial_to_offset(qr);
	o.x = pk_posmod(o.x, map_w);
	return o;
}

// ─────────────────────────────────────────────────────────────────────────
// 对偶三角形查询（六边形 Voronoi 的 Delaunay 对偶）
// ─────────────────────────────────────────────────────────────────────────
// 输入 p_wrapped 必须**已回绕**（用调用方的 wrap_world_pos；核心不能回绕）。
// 分数 axial 与 CPU HexUtils.world_to_cube 同式：
//   q = √3/3·x - y/3 ,  r = 2/3·y ，再除以 hex_size。
// 分数坐标最大约 60–100，fract 需要 highp；Godot 4 GLES3/Vulkan 默认 32 位 float。
// 全程 step/mix + 三元选择，无分支无循环（方案 §3.9 第 1 条）；地形的 AA 带宽
// 依赖「这里不做任何非线性压缩」，改公式会同时改像素值。
PkHexTri pk_hex_tri(vec2 p_wrapped, PkHexGrid g) {
	PkHexTri tri;
	vec2 a = vec2((0.5773502691896258 * p_wrapped.x - p_wrapped.y / 3.0) / g.hex_size,
			(2.0 / 3.0 * p_wrapped.y) / g.hex_size);
	vec2 b = floor(a);
	vec2 t = a - b;
	ivec2 o = ivec2(b);

	// 上 / 下三角用 step 选择，不写 if（§3.9 第 1 条：场函数无分支）。
	float up = step(1.0, t.x + t.y);
	int u = int(up);
	ivec2 q0 = o + ivec2(u, u);          // (0,0) 或 (1,1)
	ivec2 q1 = o + ivec2(1 - u, u);      // (1,0) 或 (0,1)
	ivec2 q2 = o + ivec2(u, 1 - u);      // (0,1) 或 (1,0)

	// fract 直接就是重心坐标；上下三角的重心坐标互为镜像表达式。
	tri.w_raw = mix(vec3(1.0 - t.x - t.y, t.x, t.y),
			vec3(t.x + t.y - 1.0, 1.0 - t.x, 1.0 - t.y), up);

	// offset 坐标（横向只 posmod col）。
	tri.c0 = pk_axial_to_offset_wrapped(q0, g.map_w);
	tri.c1 = pk_axial_to_offset_wrapped(q1, g.map_w);
	tri.c2 = pk_axial_to_offset_wrapped(q2, g.map_w);
	return tri;
}

// argmax(w_raw) —— 三格里的主导格。**平局次序写死 0 > 1 > 2**（CPU 镜像必须同序，
// parity 测试依赖它；契约 §1「归属 dom」）。
int pk_hex_tri_dom(PkHexTri t) {
	return (t.w_raw.x >= t.w_raw.y && t.w_raw.x >= t.w_raw.z) ? 0
			: ((t.w_raw.y >= t.w_raw.z) ? 1 : 2);
}

// 三格的 per-cell gap 向量：主力格恒为 0，其余两格是到格界的 gap（gap 单位）。
//   gap_i = (max(w_raw) - w_raw_i) · √3 ∈ [0, √3]
// 与地形旧实现 `f.gap = (wm - f.w_raw) * PK_FIELD_SQRT3` **逐位相同**（同一表达式）。
vec3 pk_hex_tri_w_gap(PkHexTri t) {
	float wm = max(t.w_raw.x, max(t.w_raw.y, t.w_raw.z));
	return (wm - t.w_raw) * PK_HEX_SQRT3;
}

// 到最近格界的 gap（gap 单位）—— 学名 `edge_distance`，`normalized_hex_center_gap` 口径。
// 主导格的 gap 恒为 0，所以取**两个非主导格**里较小的那个（1e3 是"另一格不存在"的
// 哨兵，任何真实阈值都比它小）。与旧的 pk_cell_field_edge_gap(HexCellField)
// **逐值相等**：地形早退判定 `field_edge_gap >= PK_FIELD_BAND_MAX` 靠这条。
// 连续、无纹素台阶；|∇gap| = 2/hex_size（AA 带宽的解析依据）。
float pk_hex_tri_gap(PkHexTri t) {
	vec3 gap = pk_hex_tri_w_gap(t);
	int dom = pk_hex_tri_dom(t);
	float a = (dom == 0) ? 1e3 : gap.x;
	float b = (dom == 1) ? 1e3 : gap.y;
	float c = (dom == 2) ? 1e3 : gap.z;
	return min(a, min(b, c));
}

// ─────────────────────────────────────────────────────────────────────────
// 锐化权重（类别量用 w，连续量用 w_raw；契约 §1「锐化」）
// ─────────────────────────────────────────────────────────────────────────
//   gap_i = (max(w_raw) - w_raw_i) · √3
//   k_i   = 1 - smoothstep(0, band, gap_i)
//   w     = k / Σk
// band 必须是**已 clamp 到 [1e-4, PK_FIELD_BAND_MAX]** 的最终带宽（调用方负责把
// 屏幕导数下限并进去）。地形侧的公式与这里逐字同式 —— 天气只用 w_raw（不锐化），
// 迷雾用本函数（带宽比地形宽，方案 §3.6）。
vec3 pk_hex_sharpen(vec3 w_raw, float band) {
	vec3 gap = (max(w_raw.x, max(w_raw.y, w_raw.z)) - w_raw) * PK_HEX_SQRT3;
	vec3 k = 1.0 - smoothstep(vec3(0.0), vec3(band), gap);
	return k / max(k.x + k.y + k.z, 1e-5);
}

// ─────────────────────────────────────────────────────────────────────────
// AA 带宽（契约 §9.1 的精确式）
// ─────────────────────────────────────────────────────────────────────────
//   aa = 2 / max(hex_size, 1e-4) · max(|fwidth(world_pos).x|, |fwidth(world_pos).y|) · edge_px
//
// ⚠ **只能从 fragment 调用**：函数体里有 fwidth（屏幕导数）。而且调用点不得位于
//   **非一致**控制流（逐像素分支）里 —— 那里导数未定义（方案 §3.9 第 3 条；契
//   约 §9.4 的 P4-1 坑就是这条，需要「不进导数」的入口时请用 pk_hex_tri 而不是本函数）。
//
// ⚠ 入参必须是**未回绕**的世界坐标（varying v_world 原值）。取已回绕坐标的导数会让
//   经线接缝处的 2×2 像素块 fwidth 爆掉（q 跳 map_w），带宽被顶到 PK_FIELD_BAND_MAX
//   并在接缝上留下一条 1~2 px 的竖线（契约 §9.1 的 bug）。
//
// 为什么系数是 2/hex_size：gap 沿格界法向是严格的 2·d/hex_size ⇒ |∇gap| = 2/hex_size，
// 所以一个屏幕像素对应的 gap 跨度就是 2·pixel_world/hex_size。
// 为什么取两轴较大者而不是 length()：轴对齐缩放下 length 会多算 √2（与
// pixel_scale.gdshaderinc::pk_world_per_px_at 同一取舍）。
//
// ⚠ 第二参数名是 `cell_hex_size` 而**不是** `hex_size`（对方案 §3.1 签名的一处命名
//   偏离，类型与位置不变，调用点不受影响）：Godot 的 shader 语言把「函数参数」与
//   「全局 uniform」放在同一个命名空间，而三个消费者**都必须**声明
//   `uniform float hex_size`，写 `float hex_size` 会直接报
//   `SHADER ERROR: Redefinition of 'hex_size'.`（实测）。同理见
//   `cell_field_overlays.gdshaderinc::pk_soft_warp_tiled` 的 `wrap_period`。
float pk_hex_field_aa(vec2 world_pos_unwrapped, float cell_hex_size, float edge_px) {
	return 2.0 / max(cell_hex_size, 1e-4)
			* max(abs(fwidth(world_pos_unwrapped).x), abs(fwidth(world_pos_unwrapped).y))
			* edge_px;
}

#endif // PK_HEX_CORE_INC
