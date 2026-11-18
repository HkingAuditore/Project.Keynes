// cell_field_web_probe.gdshader
// ═══════════════════════════════════════════════════════════════════════════
// [cell-field-web 2026-11-18] 启动自检用的**最小**解析格界探针（方案 §3.5）。
//
// 目的：把「某个浏览器 / 驱动上格界算错」从"玩家看到全白或海岸出洞"变成
// 「boot 期自动降级 + 一条遥测」。本 shader 只做一件事：对**预设世界坐标**求像素
// 归属，把结果编码成颜色回读，由 `scripts/rendering/cell_field_web_probe.gd`
// 逐像素与 CPU 镜像 `DCHexCellField` 对撞。
//
// 它刻意**不**画真实地图、不读任何地图资源：
//   cell_table 由 GDScript 现造一张 8×6×4 层的小表（每层内容已知，含一个金丝雀 texel）；
//   world_origin / world_size / hex_size 等 uniform 也全部由调用方推入。
// 验收口径（契约 §6 / 方案 §5「自检」）：四个环境全部 pass，人为破坏时判 fail。
//
// ── 它**测不到**什么（写清楚，别指望它）────────────────────────────────────
//   真实 world_map program 的 **sampler 槽位分配**不归它管：这里只有 3 张 sampler。
//   槽位由方案 §3.2（宏下删声明）与 §3.3（逐变体 sampler 普查）在编译期/测试期守住。
//   两层合起来才覆盖「功能不可用」与「槽位超限」这两类问题（方案 §3.5 末段）。
//
// ── include 顺序是硬约束（与 world_map.gdshader 同一拓扑）──────────────────
//   uniforms             叶子，必须最先（varying v_world / hex_size / wrap_* 都在这）。
//   VT_USE_CELL_TABLE    必须在 visual_tile_sampling 之前：那个 include 按它决定是否
//                        声明 `cell_table` sampler（见契约 §4.1）。
//   visual_tile_sampling 声明 cell_table + 各 VT_USE_* 采样器。
//   material_constants / surface_params
//                        下面 terrain_surface_detail 的编译期依赖（ROUGHNESS_MIN /
//                        SurfaceParams）。它们在 world_map 里分别位于
//                        visual_tile_sampling 与 terrain_surface_detail 之间，
//                        本文件保持同一个相对次序。
//   pixel_scale          `pk_hex_px()` —— hex_cell_field 的门控函数要用。
//   terrain_surface_detail
//                        `terrain_edge_screen_width_px()` 与
//                        `terrain_static_biome_is_water()`：hex_cell_field 的两个外部依赖。
//                        GLSL 没有函数前向声明，所以**必须先 include 它**再 include 场函数
//                        （契约 §8 D1 记的就是这条）。
//   hex_cell_field        场函数本体（dom / gap / w / band）。
// ═══════════════════════════════════════════════════════════════════════════
shader_type canvas_item;

// [cell-field-web 2026-11-18] render_mode 的选择（理由见文件末尾「输出编码」）：
//   blend_disabled —— 本 shader 把**金丝雀 texel 的字节值直接放进 A**。canvas_item 默认
//     `blend_mix` 下 `dst = src.rgb·src.a + dst·(1−src.a)`，alpha≠1 会把 rgb 一起乘小，
//     回读出来的 R/G/B 就不再是 dom 字节；上一轮 debug view 22 正是在这条上踩过
//     （alpha=0 让整像素变成清屏色，与"没画"完全无法区分，见契约 §9.3）。
//     关掉混合 ⇒ 片元原样写进 RGBA8 目标，四个通道互相独立、逐位可回读。
//   unshaded —— 本项目从不用 Light2D；保留受光路径只会让引擎多编一份 program 变体，
//     在 Web/Compatibility 上还要多占纹理单元。世界地图主 shader 同样带 unshaded。
render_mode blend_disabled, unshaded;

// ── 探针固定编译成「Web 形状」的那一套宏 ───────────────────────────────────
// PK_CELL_FIELD：要测的就是场函数路径（关掉它这探针什么也没测）。
// PK_WEB_TEXTURE_BUDGET：Web / 桌面 Compatibility 只有 8 个材质 sampler 槽
//   （`uniforms.gdshaderinc` 的预算说明）。不加这个宏，光 uniforms 就声明 8 张
//   sampler，cell_table 会成为第 9 张并被引擎内建白纹覆盖 —— 自检本身就被这条
//   静默坑污染，在真机上会把"能跑"误判成"不能跑"。加了之后本程序只有
//   noise_tex / terrain_material_tex / cell_table 三张，任何后端都在预算内。
// 两个宏也正好触发 `PK_CELL_FIELD_NO_LEGACY_LUT`（uniforms 按 plan §3.2 定义），
// 于是本探针编译的是**与线上 PK 变体同一套**宏组合，而不是一个特制组合。
#define PK_CELL_FIELD
#define PK_WEB_TEXTURE_BUDGET

#include "res://shaders/include/uniforms.gdshaderinc"

// 只要 cell_table（不定义 MAP_INDEX / ENUM / DYN / HORIZON / HEIGHT / FLOW 等预算宏）：
// 探针的采样集合越小，越不容易被无关 sampler 的驱动怪癖污染结论。
#define VT_USE_CELL_TABLE

// layer3 = class_by_index（方案 §3.1）：第 i 格放在 (i % W, i / W)，内容与 layer0 同构。
// hex_cell_field.gdshaderinc 只定义 CLASS/STATE/AUX 三个层号，layer3 由本探针自带 ——
// 合成的 4 层表就是照这张层契约造的（见 cell_field_web_probe.gd 的 LAYER_*）。
#ifndef PK_CELL_LAYER_BY_INDEX
#define PK_CELL_LAYER_BY_INDEX 3
#endif

#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
#include "res://shaders/include/material_constants.gdshaderinc"
#include "res://shaders/include/pixel_scale.gdshaderinc"
#include "res://shaders/include/surface_params.gdshaderinc"
#include "res://shaders/include/terrain_surface_detail.gdshaderinc"
#include "res://shaders/include/hex_cell_field.gdshaderinc"

// ── 金丝雀 texel 的坐标（默认值与 cell_field_web_probe.gd 的 CANARY_* 常量同值；
//    GDScript 每次都会推，常量只是兜底）──────────────────────────────────────
// 用 vec2 而不是 ivec2：契约 §8 D5 —— 本项目 shader 侧整数尺寸/坐标统一走 vec2，
// ivec2 uniform 在部分 Compatibility 路径上不可靠。
uniform vec2 probe_canary_texel = vec2(5.0, 2.0);
uniform float probe_canary_layer = 2.0;

void vertex() {
	// v_world 的语义与生产**逐字同一句**（world_map.gdshader:390-392）：
	//   `v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;`
	// 生产里 quad 的顶点本来就是世界坐标，所以那里 v_world 直接等于 VERTEX；
	// 探针没有真实地图，于是用调用方推入的 world_origin / world_size 把 ColorRect
	// 的 0..1 局部 UV 线性映射成一块**预设世界矩形**：
	//   world = world_origin + UV * world_size
	// 这与 `renderer_map_assets.gd::_build_world_quad_mesh()` 造 quad 顶点的式子
	// 「origin + uv·size」同源，因此 world_origin / world_size 推错时自检必然失败
	// （parity 探针的 Pass D 用另一条路覆盖同一件事）。
	v_world = world_origin + UV * world_size;
}

void fragment() {
	// 场函数用**与实际渲染同一个**入口（含 fwidth 的 AA 下限）：探针要证明的不是
	// "GDScript 能复现公式"，而是"这块 GPU / 这个驱动跑出来的 dom 与 CPU 镜像一致"。
	HexCellField f = pk_hex_cell_field_default(v_world);
	ivec2 dom = pk_cell_field_dom_offset(f);

	// layer3 class_by_index：第 i 格放在 (i % W, i / W)。index 由主导格的 offset 反算
	// —— 于是 row 算错必然让 B 变（R/G 只带得下 col 的 16 位，row 靠这一路兜住）。
	int cell_index = dom.y * pk_cell_map_w + dom.x;
	ivec2 index_texel = ivec2(pk_posmod(cell_index, pk_cell_map_w),
			cell_index / pk_cell_map_w);
	vec4 by_index = texelFetch(cell_table,
			ivec3(index_texel, PK_CELL_LAYER_BY_INDEX), 0);

	// 金丝雀：一个**值唯一**的 texel，用来抓"纹理不完整 ⇒ 采样恒为 (0,0,0,1)"这类
	// 静默失败（方案 §3.4 第 1 条：要求 mipmap 过滤却没有 mip 层级时不报错，采样恒黑）。
	// 坐标走 uniform，所以哪怕整张表被读成 0，只要金丝雀对得上就说明纹理读得到。
	vec4 canary = texelFetch(cell_table,
			ivec3(int(probe_canary_texel.x + 0.5), int(probe_canary_texel.y + 0.5),
					int(probe_canary_layer + 0.5)), 0);

	// ── 输出编码（方案 §3.5 第 2 条）──────────────────────────────────────
	//   R = 主导格 offset col 低字节 / 255
	//   G = 主导格 offset col 高字节 / 255（本探针 8 列宽 ⇒ 恒 0，但它必须真的是 0）
	//   B = layer3 按 index 查出的 biome（原始归一化值，CPU 侧比自己算出的 byte/255）
	//   A = 金丝雀 texel 的 R 通道（原始归一化值）
	COLOR = vec4(
			float(dom.x & 255) / 255.0,
			float((dom.x >> 8) & 255) / 255.0,
			by_index.r,
			canary.r);
}
