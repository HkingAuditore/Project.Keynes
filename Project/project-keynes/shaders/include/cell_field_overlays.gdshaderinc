// cell_field_overlays.gdshaderinc
// ═══════════════════════════════════════════════════════════════════════════
// [cell-field-overlays 2026-11-18 / O0] 天气 overlay 与战争迷雾共用的「零 uniform」胶水。
//
// 方案文档：docs/plans/terrain-cell-field-overlays-plan.md §3.2（坐标契约）、
//           §3.4（天气采样流程）、§3.6（迷雾显示）、§3.7（门控与显示共用一个函数）
// 落地契约：docs/plans/terrain-cell-field-contract.md §9.1（回绕接缝 AA）
//
// 本文件的定位
//   `hex_cell_core.gdshaderinc` 给的是纯数学（三格 / 重心 / gap / 锐化 / AA）。
//   两个 overlay 消费者（`weather_overlay.gdshader`、`fog_of_war.gdshader`）还要各自
//   写一遍「wrap → 加扭曲 → 查三格」和「k → 可见度」这类**同一条坐标纪律**。写两遍
//   必然漂移（方案 §3.7 的目标就是让天气云的边界与迷雾薄纱的边界落在同一条线上），
//   所以把这几段提成本文件。
//
// 硬约束（与核心同一套）
//   1. **零 uniform、零 sampler**。只 include `hex_cell_core.gdshaderinc`（纯函数）。
//   2. 回绕（`wrap_world_pos`）**不在这里做**：那是 `uniforms.gdshaderinc` 的函数，
//      而天气 / 迷雾各自声明了自己的 `wrap_*`。回绕由调用方先做一次，本文件只接收
//      **已回绕**的坐标（见 pk_overlay_tri 的注释）。
//   3. 全部是 ALU：无纹理采样、无循环、无 fwidth（AA 在核心的 pk_hex_field_aa 里，
//      由调用方按「未回绕坐标」单独调）。
//
// 使用阶段：[O0] 只要求能编译 + 纯 ALU。真正接线在 O2（天气）/ O3（迷雾）。
// ═══════════════════════════════════════════════════════════════════════════
#ifndef PK_CELL_FIELD_OVERLAYS_INC
#define PK_CELL_FIELD_OVERLAYS_INC

#include "res://shaders/include/hex_cell_core.gdshaderinc"

// ─────────────────────────────────────────────────────────────────────────
// 三角形查询：坐标纪律只写一次
// ─────────────────────────────────────────────────────────────────────────
// 组装「已回绕世界坐标 + 外部给的扭曲位移」→ 对偶三角形。
//
// ⚠ 调用方**必须先** `wrap_world_pos()`：本文件零 uniform，拿不到 wrap_period_x。
//   典型写法（与地形 SETUP 同序）：
//       vec2 wp = wrap_world_pos(v_world);                       // 未回绕 → 回绕
//       vec2 ws = pk_soft_warp_tiled(wp, wrap_period_x, freq, amp * hex_size);
//       PkHexTri t = pk_overlay_tri(wp, grid, ws);                // 这里不再 wrap
//       float aa = pk_hex_field_aa(v_world, hex_size, 1.0);      // AA 用**未回绕**坐标
//
// 为什么扭曲之后不需要再 wrap 一次（与地形的 `p = wrap_world_pos(wp + warp)` 等价）：
//   offset 的 col = q + (r - (r&1))/2，而 q = (√3/3·x - y/3)/s。x 平移一个环绕周期
//   `wrap_period_x = map_w·√3·s` 时 Δq = map_w 恰好是整数列 ⇒ `pk_axial_to_offset_wrapped`
//   的 posmod 给出同一个 col，`t = a - floor(a)` 的小数部分也不变。所以少这一次 wrap
//   只影响浮点舍入（亚像素级），不会取错格。
//
// warp_world 的量级由调用方保证（方案 §3.6 约束 2：迷雾的扭曲幅度要从带宽反算并
// clamp，否则能把可见格的格心推进隔壁未探索格）。
PkHexTri pk_overlay_tri(vec2 wp_wrapped, PkHexGrid g, vec2 warp_world) {
	return pk_hex_tri(wp_wrapped + warp_world, g);
}

// ─────────────────────────────────────────────────────────────────────────
// 迷雾：三格 k 的加权 + 可见度曲线
// ─────────────────────────────────────────────────────────────────────────
// k 是「知识度」类别量（0 = 从未探索，1 = 当前可见），三格用**锐化后的 w** 混合
// （与地形同一条带宽上限，方案 §3.6）。三个 k 单独传进来而不是花 sampler 参数：
// 本文件零 sampler，取样与缓存策略留给调用方。
float pk_overlay_fog_k(vec3 w, float k0, float k1, float k2) {
	return dot(w, vec3(k0, k1, k2));
}

// 迷雾可见度（1 = 看得见这片区域，0 = 完全被云雾盖住）。
// 天气的迷雾门控与迷雾显示**必须调这一个函数**（方案 §3.7）：否则「已探索但不可见」
// 区域里，天气云消失的位置与迷雾薄纱的边界会各走一条线，错开 1~2 像素。
// 0.5 / 1.0 两个阈值就是今天迷雾层的 thick/presence 分界（fog_amount = 1 - k）。
float pk_overlay_fog_visibility(float k) {
	return smoothstep(0.5, 1.0, k);
}

// ─────────────────────────────────────────────────────────────────────────
// 可平铺低频扭曲（纯 ALU 值噪声），返回**世界单位**位移
// ─────────────────────────────────────────────────────────────────────────
// 来源说明（**搬数学，不 include**）：这两段是 `shaders/include/cloud_noise.gdshaderinc`
// 的 `cloud_hash22` / `cloud_grad_noise_tiled` 与 `fog_of_war.gdshader` 的
// `fog_tileable_scale` 的合体。**不能**直接 include `cloud_noise.gdshaderinc`：
//   · 天气里 `cloud_noise` 是在 `weather_overlay.gdshader` 内部按档位裁剪的（Web 变体
//     另有 `weather_overlay_web_min.gdshaderinc`），共享 include 一 include 进来就会把
//     一堆 FBM 也带进迷雾程序，破坏两边的编译体积预算；
//   · 迷雾程序自己的噪声是带时间演化的另一套（`fog_grad_noise_tiled_evolve`），
//     与这里要的「静态、低频、只做域扭曲」不是同一个东西。
// 数学本身逐式相同（quintic 插值的一阶导连续，放大后不出现方格棱）。
//
// 为什么必须可平铺：地图东西向无限滚动，采样点会被折回一个环绕周期内。不可平铺的
// 扭曲会让接缝两侧取到**不同的格子** ⇒ 天气云与迷雾边在经线上错开一截（方案 §3.2 第 3 条）。
//
// 晶格角点 hash：整数格 → [0,1)^2。与 cloud_hash22 同式（sin 折叠），代价 2 次 sin。
vec2 pk_overlay_hash22(vec2 lattice) {
	vec2 h = vec2(dot(lattice, vec2(127.1, 311.7)),
			dot(lattice, vec2(269.5, 183.3)));
	return fract(sin(h) * 43758.5453123);
}

// 域缩放修正：让噪声的 x 环绕周期恰好落在 **整数个**晶格上。
// 取 4 的倍数是为了让 1/2、1/4 频率的二级扭曲层也落在整数格上（照抄
// fog_of_war.gdshader::fog_tileable_scale 的口径）。缩放被改动的幅度通常 < 1%，
// 云团 / 迷雾团的大小变化看不出来。返回 0 表示地图不环绕（不做折叠）。
//
// ⚠ 参数名是 `wrap_period` 而不是 `wrap_period_x`：Godot 的 shader 语言把函数参数与
//   全局 uniform 放在同一个命名空间，而两个消费者都声明了 `uniform float
//   wrap_period_x`（fog_of_war.gdshader:82、weather_overlay.gdshader:61），参数写成
//   同名会直接 `SHADER ERROR: Redefinition of 'wrap_period_x'.`。调用点照旧把自己的
//   `wrap_period_x` uniform 传进来即可，语义不变。
float pk_overlay_tile_period(float wrap_period, float freq) {
	return (wrap_period <= 0.0001) ? 0.0
			: max(8.0, round(wrap_period * freq * 0.25) * 4.0);
}

// 可平铺梯度噪声（值域 [0,1]）。period_cells 是 x 方向的晶格周期（整数格）；
// < 1 表示不环绕。
// x 的折叠走 **pk_posmod**（floor 口径），不用 GLSL 的 `%`：负操作数的 `%` 在
// GLSL ES 3.00 下结果未定义，而西缘（x < 0）的晶格坐标一定是负数。
float pk_overlay_grad_noise_tiled(vec2 p, int period_cells) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	int ix = int(i.x);
	int pm = max(period_cells, 1);
	int wx0 = pk_posmod(ix, pm);
	int wx1 = pk_posmod(ix + 1, pm);
	int x0 = (period_cells >= 1) ? wx0 : ix;
	int x1 = (period_cells >= 1) ? wx1 : ix + 1;
	vec2 ga = 2.0 * pk_overlay_hash22(vec2(float(x0), i.y)) - vec2(1.0);
	vec2 gb = 2.0 * pk_overlay_hash22(vec2(float(x1), i.y)) - vec2(1.0);
	vec2 gc = 2.0 * pk_overlay_hash22(vec2(float(x0), i.y + 1.0)) - vec2(1.0);
	vec2 gd = 2.0 * pk_overlay_hash22(vec2(float(x1), i.y + 1.0)) - vec2(1.0);
	float va = dot(ga, f);
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	float n = va + u.x * (vb - va) + u.y * (vc - va)
			+ u.x * u.y * (va - vb - vc + vd);
	return 0.5 + 0.5 * n;
}

// 可平铺低频扭曲：返回**世界单位**的位移（调用方加到已回绕的世界坐标上）。
//   wp            已回绕世界坐标（wrap_world_pos 的结果）
//   wrap_period   环绕周期（世界单位，即调用方的 `wrap_period_x`；0 = 不环绕）
//   freq          噪声频率（1 / 世界单位），两轴取同一噪声的两个相位图层
//   amp_world     位移幅度（世界单位）——**由调用方算**：迷雾用它从带宽上限反算
//                 （方案 §3.6），天气用 0.3~0.5 个 hex（§3.4）
// 每轴各一次噪声（相位偏移 (17.3, -9.1) 解相关），输出 ≈ [-amp, +amp] 的两轴位移。
vec2 pk_soft_warp_tiled(vec2 wp, float wrap_period, float freq, float amp_world) {
	float f = max(freq, 1e-6);
	float period_cells = pk_overlay_tile_period(wrap_period, f);
	// 不环绕时 period_cells = 0 ⇒ 退回原始频率（不折叠晶格）。
	float scale = (period_cells >= 1.0) ? period_cells / wrap_period : f;
	int period_i = int(period_cells + 0.5);
	vec2 np = wp * scale;
	float n0 = pk_overlay_grad_noise_tiled(np, period_i);
	float n1 = pk_overlay_grad_noise_tiled(np + vec2(17.3, -9.1), period_i);
	return (vec2(n0, n1) - vec2(0.5)) * (2.0 * amp_world);
}

#endif // PK_CELL_FIELD_OVERLAYS_INC
