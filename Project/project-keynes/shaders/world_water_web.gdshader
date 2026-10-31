shader_type canvas_item;
// [pk-web-texture-budget] 与 world_map.gdshader 同一理由：光照全部自算、项目从不使用
// Light2D，缺 unshaded 会让 Godot 额外编译"受光"路径并隐式多占 1-2 个 fragment 纹理
// 单元。canvas_item 的其它全屏 shader（data_overlay / fog_of_war / country_border /
// hex_edge_overlay / world_map）都已带 unshaded，这里保持一致。
render_mode blend_mix, unshaded;

// ═══════════════════════════════════════════════════════════════════════════
// world_water_web.gdshader — [web-water-pass] web/GLES3 的水面「第二 pass」
// ───────────────────────────────────────────────────────────────────────────
// 为什么存在（Why）：ANGLE/D3D11 + FXC 在「同一个 fragment 里按像素二选一的
// 两个真正着色来源」上会踩寄存器压力悬崖。world_map 的逐条实测（同一份源码、
// 同一个编译前缀，只替换水面分支）：
//
//   变体                              首次编译
//   ├ 只留陆地（水面=常量）            2 473 ms
//   ├ 只留水面（陆地=常量）            1 089 ms
//   ├ 两者都在（拆分前的现状）        20 291 ms
//   ├ 水面改"紧凑 if/else"（≈25 行）  17 264 ms
//   └ 水面改"无分支三元/mix"（≈30 行）18 060 ms
//
// 即：与那第二个分支有多少行几乎无关（25 行 = 1000 行），删代码治不好。唯一有效的
// 修法是把水面**移出这个 fragment**。本文件就是被移出去的那一半：
//   pass 1 = world_map.gdshader 的 PK_WEB_WORLD_MIN 变体，只画陆地（水面像素输出
//            常量，等着被本 pass 覆盖）；
//   pass 2 = 本文件，整屏 quad，只画水格（非水格 `discard`）。
// 两片合计 ≈ 2.5 s + 1.1 s ≈ 3.6 s，替换掉 20.3 s。
//
// 谁创建（Who）：HexRenderer._sync_water_quad()。**仅**当
//   OS.has_feature("web") ∧ DCFeatureFlags.is_compatibility_renderer() ∧
//   HexRenderer._world_map_web_min_active()
// 才创建 MeshInstance2D（z_index=0，紧跟在 _world_quad 之后、植被/建筑层之下）。
// 桌面、以及 web 的中/高档（world_map 会自己画水面）**完全不创建**本节点，也不
// load 本文件；桌面 world_map 的预处理结果与改动前逐字节相同。
//
// ── 解码约定（必须与 world_map 的 SETUP 同源，禁止发明第二套）──────────────
//   行号以 2026-10-31 拆分后的 world_map.gdshader 为准。
//   * map_index_atlas（tiled 时是 visual_map_index_tiles 数组）：
//       G/B = cell.index 低/高字节，0xFFFF = map 外哨兵   → world_map.gdshader:236-237
//   * enum_lut : R=biome  G=veg  B=cover  A=迷雾知识度 k → world_map.gdshader:255-261
//   * dyn_lut  : A = 水格海冰占比 / 陆格植被活力          → world_map.gdshader:241,337
//   * height_tex : RG = 16-bit 归一高程 (R*256+G)/257      → world_map.gdshader:208-209
//   * 坐标 : uv = wrap_map_uv((v_world - world_origin) / world_size)
//                                                          → world_map.gdshader:184
//   * cell.index → LUT texel uv：**直接 #include cell_indirect.gdshaderinc**，用它的
//     cell_lut_uv()，不复制一份网格换算（复制会漂）。
//
// ── 为什么本 pass 覆盖后与"拆分前逐像素等价"（逐条对账）────────────────────
//   ① 水格判定：biome 取自同一张 enum_lut 的同一个字节，is_water 表达式逐字复制
//      world_map.gdshader:303-304。
//   ② 次生水体（water_secondary_biome / water_static_edge_mix）：web 纹理预算变体
//      **不定义 VT_USE_EDGE_DISTANCE**（world_map.gdshader:93-100），于是
//      terrain_edge_secondary_weight_d() 恒返回 0.0（terrain_surface_detail:181-186），
//      decode_edge_secondary_index() 恒返回 -1（terrain_surface_detail:14-26）⇒
//      world_map 里 secondary==primary 且 edge_mix==0。shore_frac 同理恒为 vec2(0)
//      （world_map.gdshader:222-231）。本 pass 直接取这些**编译期常量**，因此不需要
//      edge_distance sampler，也不需要 has_terrain_edge_data。
//   ③ 海冰：visual_water_ice_fraction = (cid<0) ? 1.0 : dyn_lut.a（world_map:337）。
//   ④ 迷雾：fog_k 来自 enum_lut.a；fog_early_out 命中时 pass 1 已经输出
//      fog_unexplored_color（world_map:384-387），本 pass 只要 `discard` 就等价；
//      灰化公式与 world_map:423-427 逐字一致（fog_gray_strength / fog_early_out_k
//      在 renderer 侧从不推送，两侧都用同一份默认值）。
//   ⑤ 收口：pass 1 的 apply_global_adjustments 在 PK_WEB_WORLD_MIN 下跳过 tonemap
//      （global_adjustments:49-56），只剩羊皮纸 tint + paper grain
//      （global_adjustments:64-66）。而 web 上 paper grain 的 grain 恒为 0.5
//      （PK_SKIP_PIXEL_NOISE ⇒ pixel_noise=vec4(0.5)，world_map:198-205），
//      mix(1-s, 1+s, 0.5) ≡ 1.0（至多 1 ulp），所以本 pass 只需补羊皮纸那一次 mix。
//      → 本 pass **不需要 noise_tex**（省 1 个 sampler + 1 次 fetch）。
//
// ── uniform 预算 ───────────────────────────────────────────────────────────
// 本文件只声明 4 个 sampler + 12 个标量/向量 uniform（world_map 是 186 个）。
// 已实测：uniform 数量不是编译成本（只声明同样 186 个 uniform 的常量函数体只要
// 66 ms，见 web_shader_warmup.PROBE_UNIFORM_SPLIT），所以少声明换不来编译时间；
// 收益在**纹理单元预算**（Compatibility 只有 16 个，材质 sampler 必须 ≤8）、绑定
// 状态与后续维护成本。少声明的另一面是"没人会误以为本 pass 也在消费某个参数"。
// ═══════════════════════════════════════════════════════════════════════════

#include "res://shaders/include/shader_quality.gdshaderinc"

// 宏链守卫：本 pass 的等价性建立在"web-LOW 档"这个前提上（②的 VT_USE_EDGE_DISTANCE
// 裁掉、⑤的 PK_SKIP_PIXEL_NOISE 恒等式都只在 LOW/受限平台档成立）。宏链万一接错，
// 宁可编不出来，也不要静默产出一份"看起来能用但和 pass 1 不一致"的变体。
// 与 world_map_web_min.gdshaderinc 的 PK_QUALITY_LOW 守卫同款。
#ifndef PK_QUALITY_LOW
#error "world_water_web.gdshader requires MOBILE_QUALITY_LOW / PK_SHADER_TIER_LOW"
#endif

// ═══════════════════════════════════════════════════════════════════════════
// 【世界 / 坐标系】与 uniforms.gdshaderinc:172-176 同名同义，只声明本 pass 用到的。
// varying 同 uniforms.gdshaderinc:688（vertex 写、fragment 读世界坐标）。
// ═══════════════════════════════════════════════════════════════════════════
varying vec2 v_world;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;

// ═══════════════════════════════════════════════════════════════════════════
// 【Cell-index 间接寻址】与 uniforms.gdshaderinc:139-147 同源：
//   enum_lut / dyn_lut 必须 NEAREST；lut_dims 是 LUT 网格尺寸。
// world_map 还声明 map_index_atlas（此处由 visual_tile_sampling 按 tiled/legacy 二选一
// 声明）、height_tex（同上），所以下面两个 VT_USE_* 之外不重复声明。
// ═══════════════════════════════════════════════════════════════════════════
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform sampler2D dyn_lut : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0, 1.0);

// ═══════════════════════════════════════════════════════════════════════════
// 【迷雾】口径与 uniforms.gdshaderinc:158-166 + renderer _push_fog_uniforms() 一致。
// 刻意**不声明** fog_unexplored_color：未探索像素由 pass 1 上色，本 pass discard。
// ═══════════════════════════════════════════════════════════════════════════
uniform bool fog_gray_enabled = true;
uniform float fog_gray_strength : hint_range(0.0, 1.0) = 0.75;
uniform bool fog_early_out_enabled = false;
uniform float fog_early_out_k : hint_range(0.0, 0.5) = 0.02;

// ═══════════════════════════════════════════════════════════════════════════
// 【羊皮纸】apply_global_adjustments 的最后一步；world_map 侧同名同 hint 同默认值，
// 由 renderer 的 @export 属性直推（_apply_uniforms():4447-4448，本 pass 在
// _apply_water_uniforms():1108-1109 推同一对属性）。
// 声明必须逐字与 uniforms.gdshaderinc:547-548 一致：source_color hint 会影响
// Godot 对传入 Color 的处理，两边不同就会差一个色。
// ═══════════════════════════════════════════════════════════════════════════
uniform vec3 parchment_tint : source_color = vec3(0.96, 0.88, 0.74);
uniform float parchment_strength : hint_range(0.0, 0.4) = 0.10;

// ═══════════════════════════════════════════════════════════════════════════
// 【调试视图让位】terrain_surface_debug_view != 0 时 pass 1 会整屏输出诊断色
// （world_map.gdshader:441-482），本 pass 必须整体让位，否则 GM 面板的 13/14/16/17
// 会被水面覆盖掉。1 个 int 换"诊断工具在 web 上仍然可用"是划算的。
// ═══════════════════════════════════════════════════════════════════════════
uniform int terrain_surface_debug_view = 0;

// ── 只为解码服务的地表静态贴图：height（RG=高程）与 map_index（GB=cell id）──
// 这两个 VT_USE_* 必须定义在 include 之前；tiled/legacy 的二选一由 include 内部的
// MAP_VISUAL_TILED 决定（与 world_map.gdshader:85-110 完全同一套约定）。
#define VT_USE_HEIGHT
#define VT_USE_MAP_INDEX
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"

// cell_lut_uv()（唯一对外成员）+ decode_cell_index()/dyn_lut_nearest()（本文件不用，
// 编译器整段删掉）。依赖上面已声明的 dyn_lut / lut_dims / visual_sample_map_index。
#include "res://shaders/include/cell_indirect.gdshaderinc"

// ═══════════════════════════════════════════════════════════════════════════
// 【Biome / Cover id】只取本 pass 真正比较到的 7 个。
// 数值必须与 uniforms.gdshaderinc:570-644 逐值一致（CPU 端 terrain_type.gd /
// cover_type.gd 亦与之对齐）。tests/world/terrain_shader_variant_test.gd 有一条
// 逐值一致性断言守着这里，改一处必须改另一处。
// ═══════════════════════════════════════════════════════════════════════════
const int B_OCEAN   = 0;
const int B_COAST   = 1;
const int B_LAKE    = 18;
const int B_REEF    = 19;
const int B_SEA_ICE = 20;
const int B_KELP    = 21;
const int CV_SEA_ICE = 3;

// ═══════════════════════════════════════════════════════════════════════════
// 【wrap helper】逐字复制 uniforms.gdshaderinc:185-203（wrap_world_x / wrap_map_uv）。
// 只复制这两个：本 pass 不需要 wrap_world_pos（水面 web-min 的着色函数不消费 wp）。
// 逐字复制是硬要求——差一个 clamp 或 mod 就会在环绕缝/极区产生一像素宽的光带。
// test 里有一条"文本必须与 uniforms.gdshaderinc 逐字相同"的断言守着。
// ═══════════════════════════════════════════════════════════════════════════
float wrap_world_x(float x) {
	if (wrap_period_x <= 0.0001) {
		return x;
	}
	return wrap_origin_x + mod(x - wrap_origin_x, wrap_period_x);
}

vec2 wrap_map_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = wrap_world_x(world_x);
	return vec2((wrapped_x - world_origin.x) / world_size.x, clamp(uv.y, 0.0, 1.0));
}

// ═══════════════════════════════════════════════════════════════════════════
// 水面着色本体 —— 从 world_map.gdshader 拆分前那段 `#ifdef PK_WEB_WORLD_MIN` 里的
// render_water_pipeline_web_min() **原样搬迁**（该函数已随本次拆分从 world_map 删除；
// 迁移前的原文见 git 历史 / tmp/next/web_water_two_pass_IMPL.md）。
// 只删掉签名里那 8 个从未被函数体读取的形参（wp / uv / scals / lat_signed /
// current_temp / ocean_current_v / wind_v / pixel_noise），保留全部算式与常量。
// 这也是 web 上水面"没有波光/SSS/焦散/洋流条纹"的原因 —— web-LOW 档本来就没跑
// 这些子系统（waves_on=false、ctx.quality=0），视觉增量只存在于桌面。
//
// ⚠ 这里**一个 if 都不能有**。实测（当时还在 world_map 里）：把水面分支换成常量 →
// world_map 总编译 2 473 ms；换成带 if/else-if 的紧凑版本 → 17 264 ms。分歧分支
// 一旦出现在第二个大着色来源里，FXC 的优化时间就从"秒"跳到"十几秒"。本 pass 现在
// 是独立的 fragment，理论上没那么敏感，但仍保持全直线写法（编译器可降成 select），
// 免得将来有人把本 pass 合回主 shader 时重新踩同一个坑。
// ═══════════════════════════════════════════════════════════════════════════
vec3 render_water_pipeline_web_min(
		int biome,
		int cover,
		int secondary_biome,
		int secondary_cover,
		float edge_mix,
		float elev,
		float dyn_ice_frac,
		vec2 shore_frac) {
	// 深度：elev 是 [0,1] 的归一化高程，海面普遍很低，越浅越亮。
	float depth_t = clamp(elev * 3.5, 0.0, 1.0);
	vec3 col = mix(vec3(0.045, 0.115, 0.235), vec3(0.185, 0.400, 0.470), depth_t);
	// 次生水体（湖泊/内海交界）向主 biome 混合，保留边缘过渡。
	col = mix(col, col * 0.92 + vec3(0.02, 0.03, 0.02), clamp(edge_mix, 0.0, 0.5));
	float w_coast = (biome == B_COAST) ? 1.0 : 0.0;
	float w_lake = (biome == B_LAKE) ? 1.0 : 0.0;
	float w_reef = (biome == B_REEF) ? 1.0 : 0.0;
	float w_kelp = (biome == B_KELP) ? 1.0 : 0.0;
	vec3 biome_tint =
		vec3(0.235, 0.470, 0.500) * w_coast +
		vec3(0.145, 0.320, 0.390) * w_lake +
		vec3(0.145, 0.430, 0.445) * w_reef +
		vec3(0.090, 0.240, 0.205) * w_kelp;
	float biome_w = clamp(w_coast + w_lake + w_reef + w_kelp, 0.0, 1.0);
	col = mix(col, biome_tint, biome_w * 0.48);
	// 岸线浅滩：shore_frac 是陆/水两侧的岸线占比。
	float shore = clamp(max(shore_frac.x, shore_frac.y), 0.0, 1.0);
	col = mix(col, vec3(0.290, 0.545, 0.560), shore * 0.45);
	// 海冰：biome / cover / 动态冰量取最大，再向近白色混合（同样无分支）。
	float ice_flag = max(
		max((biome == B_SEA_ICE) ? 1.0 : 0.0, (secondary_biome == B_SEA_ICE) ? 1.0 : 0.0),
		max((cover == CV_SEA_ICE) ? 1.0 : 0.0, (secondary_cover == CV_SEA_ICE) ? 1.0 : 0.0));
	float ice = max(clamp(dyn_ice_frac, 0.0, 1.0), ice_flag * 0.85);
	col = mix(col, vec3(0.840, 0.900, 0.950), ice);
	return col;
}

void vertex() {
	// 与 world_map.gdshader:167-169 逐字相同：两块 quad 共用同一个 ArrayMesh，
	// 又是同一个父节点的直接子节点（都无自身变换），所以 v_world 逐像素相等。
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// 调试视图整屏归 pass 1（见 uniform 处注释）。
	if (terrain_surface_debug_view > 0) {
		discard;
	}

	// ── SETUP：坐标 + cell 索引（与 world_map:184-241 同源，采样顺序刻意不同：
	// 先把"是不是水"判掉再取 height/dyn，非水像素只花 2 次 fetch 就 discard）──
	vec2 uv = wrap_map_uv((v_world - world_origin) / world_size);
	vec4 map_px = visual_sample_map_index(uv);
	int cell_id = int(map_px.g * 255.0 + 0.5) + int(map_px.b * 255.0 + 0.5) * 256;
	cell_id = (cell_id >= 65535) ? -1 : cell_id;

	int biome;
	int cover;
	float fog_k;
	float dyn_ice_frac;
	// world_map 在 PK_QUALITY_LOW 下把"次生水体查表"整段裁掉
	// （world_map:338-354 的 `#if !defined(PK_QUALITY_LOW)`），secondary 恒等于
	// primary、edge_mix 恒为 0，这里直接按该结论赋值。
	int secondary_biome;
	int secondary_cover;
	float static_edge_mix = 0.0;
	if (cell_id >= 0) {
		vec4 elut = texture(enum_lut, cell_lut_uv(cell_id));
		biome = int(elut.r * 255.0 + 0.5);
		cover = int(elut.b * 255.0 + 0.5);
		fog_k = elut.a;
		dyn_ice_frac = texture(dyn_lut, cell_lut_uv(cell_id)).a;
		secondary_biome = biome;
		secondary_cover = cover;
	} else {
		// 地图外 padding：world_map 把它表现为海冰（world_map:274-278 / 337）。
		biome = B_SEA_ICE;
		cover = 0;
		fog_k = 1.0;
		dyn_ice_frac = 1.0;
		secondary_biome = B_SEA_ICE;
		secondary_cover = 0;
	}

	// 逐字复制 world_map:303-304 的水格判定（同一张 enum_lut、同一个字节）。
	bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);
	if (!is_water) {
		discard;
	}
	// 未探索像素：pass 1 已经输出 fog_unexplored_color，这里让位即可（同色）。
	if (fog_early_out_enabled && (fog_k <= fog_early_out_k)) {
		discard;
	}

	// 水深 → 归一高程（height.RG = 16-bit，解码同 world_map:208-209）。
	vec4 height_px = visual_sample_height(uv);
	float elev = (height_px.r * 256.0 + height_px.g) / 257.0;
	// web budget 变体不定义 VT_USE_EDGE_DISTANCE ⇒ shore_frac 恒为 0
	// （world_map:222-231）。保留变量是为了让算式与 pass 1 逐字对得上。
	vec2 shore_frac = vec2(0.0);

	vec3 col = render_water_pipeline_web_min(
		biome, cover, secondary_biome, secondary_cover,
		static_edge_mix, elev, dyn_ice_frac, shore_frac);

	// 已探索但当前不可见 → 去饱和 + 压暗。逐字复制 world_map:423-427。
	if (fog_gray_enabled) {
		float gray_amt = (1.0 - smoothstep(0.5, 1.0, fog_k)) * fog_gray_strength;
		col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))) * 0.82, gray_amt);
	}

	// apply_global_adjustments 的 web-min 收口：只有羊皮纸 tint 一项真正生效
	// （tonemap 在 PK_WEB_WORLD_MIN 下被裁掉；paper grain 的 grain 恒 0.5 ⇒ 乘子 ≡1）。
	col = mix(col, col * parchment_tint, parchment_strength);
	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
