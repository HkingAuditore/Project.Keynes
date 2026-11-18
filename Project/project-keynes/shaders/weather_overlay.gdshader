shader_type canvas_item;
// [pk-web-texture-budget] 同 world_map.gdshader：不依赖引擎 Light2D，补 unshaded
// 省掉隐式受光路径的纹理单元。
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"
// [mobile-high-full 2026-11-17] HIGH 档取消了 PK_MOBILE_ANY（见 shader_quality.gdshaderinc），
// 但**天气云**的全量 4/3/2 octave fbm + 域扭曲是这份 shader 里最贵的部分，而且和
// 玩家抱怨的"光照丑 / 迷雾没细节"不是同一条路径（那是 water / land / vegetation /
// fog 的 `!PK_MOBILE_ANY` 段）。所以这里单独把天气云留在廉价噪声上，避免"高画质"
// 一开就掉到个位数帧。要验证全量天气云，前置 `#define PK_WEATHER_FULL_CLOUDS`。
#if defined(PK_WEB_WEATHER_MIN) || defined(PK_MOBILE_ANY) || defined(PK_WEATHER_LOW) || defined(PK_WEATHER_MID) \
		|| (defined(PK_MOBILE_HIGH_SLIM) && !defined(PK_WEATHER_FULL_CLOUDS))
#define PK_WEATHER_CHEAP_NOISE
#endif

// ════════════════════════════════════════════════════════════════════════
// weather_overlay.gdshader — 天气云 overlay（2026-06-19 精简重写）
//
// **两条互斥编译的数据通路**（同一份文件，由 `PK_CELL_FIELD` 二选一）：
//   · 宏关（默认，逐字节 = 加这套功能之前）：weather_lut（per-cell 天气场 LUT，由
//     encode_cell_luts 产出）经 map_index_atlas.GB 的 cell.index **间接寻址**逐格采样，
//     副格来自 edge_neighbor / edge_distance，移动档在 texel 空间做 Bayer 选格，
//     桌面档再补一圈 6 邻环平均。见 `sample_field_weather` 的旧实现（`#ifndef` 块）。
//   · 宏开（方案 O2）：改用共享场函数（hex_cell_core + cell_field_overlays）解析出
//     对偶三角形与原始重心权重 w_raw，连续量三格插值、类型先查 profile 再混结果；
//     读 offset 空间的 weather_table（4 层，层号双缓冲）。sampler 8 → 2。
//     开关注释见 weather_layer.gd 的 CELL_FIELD_SETTING。
// 单噪声系统：解析梯度噪声（Perlin-like，quintic 插值），无任何纹理噪声依赖。
// 三层云：cumulus（中层主云）/ cirrus（高层卷云）/ fog（低层山雾）。
// 降水：按天气类型 profile flag 叠加（闪电已移除）。
// filter_nearest 采样：旧路径是 map_index_atlas（biome）+ 三张 index 空间 LUT；
//   场函数路径是 cell_table（迷雾 k）与 weather_table（天气 + 风），全部 texelFetch。
//
// [web-weather-min] web / ANGLE 裁剪变体（2026-10-31）：
//   桌面版首帧编译在 ANGLE 上约 45 秒，卡住 web 加载条（曾在 98%）。原因不是 shader 体积，
//   而是 cloud_density_soft 被 fragment 内联十几处、每处再展开 4/3/2 octave 的解析 Perlin
//   fbm（每次 fbm 展开 6 轮循环 × 4 次 cloud_hash22 × 2 个 sin）+ 域扭曲 + 接缝伙伴 ×2。
//   本变体（weather_layer.gd 在 web 上 prepend `#define PK_WEB_WEATHER_MIN`）用
//   include/weather_overlay_web_min.gdshaderinc 里的「无 sin / 无循环」双 octave 值噪声替换
//   整座 fbm 栈，并编译掉：域扭曲、体积法线 4-tap、单向光照梯度、偏移投影阴影、山雾 4 点
//   邻域、接缝伙伴采样。保留：三层云（中云/卷云/低雾）、coverage 重映射曲线、逐像素晨昏
//   光照与银边、云下直射阴影、天气 LUT 的连续副格混合、全部 uniform 契约。
//   桌面路径（未定义该宏）逐字不变。
//   [O2] 这个变体只换噪声栈、不碰取样：与 PK_CELL_FIELD **正交**（方案 §4：天气第一版
//   Web 就能开），所以 `PK_WEB_WEATHER_MIN + PK_CELL_FIELD` 也是一份合法变体
//   （tests/world/weather_overlay_field_test.gd 编它并断言 sampler 仍是 2 张）。
// ════════════════════════════════════════════════════════════════════════

// 帧间插值系数（两条路径共用）：0=prev 1=curr,两次仿真更新之间随时间推进。
uniform float weather_lerp : hint_range(0.0, 1.0) = 1.0;

#ifndef PK_CELL_FIELD
// ── 旧路径：cell-index 间接寻址（cloud-from-field 2026-06-20）────────────────
//   per-cell 天气场 LUT。R=weather_type, G=intensity, B=cloud, A=vapor（与 encode_cell_luts
//   同布局）。wx_decode_cell_index(uv) 用 map_index_atlas.GB 取 cell.index，再 wx_cell_lut_uv
//   采样本格天气。
//   整段在 `#ifndef PK_CELL_FIELD` 里：开关关闭时预处理产物与今天**逐字节一致**，开关
//   打开时下面 5 个 sampler 全部从声明里消失（sampler 普查：8 → 2，方案 §3.9）。
uniform sampler2D weather_lut : filter_nearest, repeat_disable;
uniform sampler2D weather_lut_prev : filter_nearest, repeat_disable;  // 上一仿真帧 LUT(帧间插值减两次更新间横跳)
uniform vec2 lut_dims = vec2(0.0);
uniform sampler2D wind_lut : filter_nearest, repeat_disable;
uniform sampler2D wind_lut_prev : filter_nearest, repeat_disable;
uniform bool has_local_wind = false;
uniform bool has_wind_prev = false;
// 视野门控：enum_lut.a = 迷雾知识度 k。已探索但当前看不见的地方不该显示实时天气
// ——「你记得这里的地形，但不知道今天下不下雨」这个信号比灰化本身更能说明问题。
// fog_mask_enabled 关闭时整个分支被 uniform 条件跳过，不产生额外采样。
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform bool has_terrain_edge_data = false;
uniform float terrain_ecotone_width : hint_range(0.0, 0.96) = 0.84;
#endif

// 视野门控总开关（两条路径共用）。PK_CELL_FIELD 路径下还要 `cell_table_bound` 为真才
// 真的生效 —— 表没就绪时宁可整段跳过，也不读一张不存在的层（方案 §3.4 末条）。
uniform bool fog_mask_enabled = false;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;

#ifndef PK_CELL_FIELD
#define VT_USE_MAP_INDEX
#define VT_USE_EDGE_NEIGHBOR
#define VT_USE_EDGE_DISTANCE
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
#endif

#ifdef PK_CELL_FIELD
// ════════════════════════════════════════════════════════════════════════════
// [cell-field-overlays 2026-11-18 / O2] PK_CELL_FIELD：天气改用共享场函数
//
// 方案：docs/plans/terrain-cell-field-overlays-plan.md §3.2（坐标契约）/ §3.4（采样流程）/
//       §3.5（类型怎么处理）/ §3.7（迷雾门控与迷雾显示共用一个函数）/ §3.9（采样账）
//
// 与旧路径的差别（旧路径由上面的 #ifndef 保留、编译期整段剔除）：
//   · 归属不再来自 map_index_atlas 的 NEAREST texel（类别量），而是由世界坐标解析算出
//     一个对偶三角形 + 原始重心权重 w_raw（hex_cell_core.gdshaderinc）；
//   · 连续量（intensity / cloud / vapor / 风）一律 `Σ w_i · value_i`，不锐化、不要 fwidth；
//   · 天气类型是类别量：**先查 profile 再按 w 混合结果**，绝不插值 type ID（§3.5）；
//   · 桌面 6 邻环、Bayer 选格、副格双采样、依赖读的间接寻址全部删除（§3.4 末段）；
//   · sampler 从约 8 张降到 **2** 张（cell_table + weather_table）。
//
// 数据源（O1 已落地，见 scripts/rendering/bakers/cell_lut_baker.gd 的 weather_table 段）：
//   weather_table = Texture2DArray RGBA8, map_w × map_h, **offset 空间**, 4 层：
//     layer 0/1 天气 A/B : R=type G=intensity B=cloud A=vapor（与 weather_lut 同字节）
//     layer 2/3 风   A/B : RG=单位风向*0.5+0.5 B=speed/20 A=1（与 wind_lut 同编码）
//   双缓冲靠**层号**：cur = weather_cur_layer，prev = weather_prev_layer = 1 - cur；
//   风用 2 + cur / 2 + prev。层号翻转与天气提交同一次（不拷贝、不重传）。
//
// ⚠ 这里的 uniform 一律**不得依赖默认值**（方案 §3.2 第 2 条）：hex_size / map_dims /
//   *_size / *_bound / 层号全部由 weather_layer.gd 推送。默认值只保证"宿主还没推"时
//   退化成**没有云**，而不是画出错位的云（bound=false ⇒ sample_field_weather 直接空返回）。
// ⚠ 函数形参名不得与 uniform 同名（Godot 把两者放同一命名空间）：本文件里
//   `hex_size` / `map_dims` / `cell_table` / `weather_table` / `wrap_period_x` 等名字
//   只作 uniform 使用，helper 的形参用 c / g / layer / v 这类短名。
// ════════════════════════════════════════════════════════════════════════════
#include "res://shaders/include/cell_field_overlays.gdshaderinc"

// 世界单位 / hex（= hex 半径；宿主推 host.hex_size）。
// ⚠ 不要用 hex_world_diameter 反推：那个 uniform 在天气 / 迷雾 / 地形三处默认值不同
//   （38 / 未声明 / 44，方案 §1.4），新代码只用本 uniform。
uniform float hex_size = 22.0;
// (map_w, map_h)，宿主推 Vector2(map.width, map.height)。
uniform vec2 map_dims = vec2(0.0);
// per-cell 属性表（offset 空间，4 层 RGBA8）。这里只用 layer2.R = 迷雾知识度 k，
// 让天气的视野门控与迷雾显示**共用同一个函数**（方案 §3.7）。
uniform sampler2DArray cell_table : filter_nearest, repeat_disable;
uniform vec2 cell_table_size = vec2(0.0);
uniform bool cell_table_bound = false;
// 天气 + 风的 offset 空间表（4 层，见文件头）。**不加 source_color**：字节
// （R=类型 / G=intensity / ...）是数据不是颜色，sRGB 转换会把 type 通道也一起改掉。
uniform sampler2DArray weather_table : filter_nearest, repeat_disable;
uniform vec2 weather_table_size = vec2(0.0);
uniform bool weather_table_bound = false;
uniform int weather_cur_layer = 0;
uniform int weather_prev_layer = 1;
// 查表前的低频域扭曲（方案 §2「为什么天气也要扭曲」）：纯 w_raw 插值时，一个下雨格
// 被晴天包围会得到一顶以格心为顶点的"软六边形帐篷"，轮廓仍带六边形感。加一层
// 约 0.3~0.5 格的**可平铺**扭曲（横向周期 = wrap_period_x，否则回绕接缝两侧会取到
// 不同的格）把帐篷打散成不规则团块。
//   weather_warp_freq : 1 / 世界单位。默认 0.004 ⇒ 波长 ≈ 250 wu ≈ 5~6 个 hex。
//   weather_warp_amp  : × hex_size（世界单位位移幅度）。默认 0.75 ⇒ 每轴 ≈ 0.37 hex 直径。
// 参数值待美术联调（方案 §8-2），走 uniform 就是为了不重编 shader。
uniform float weather_warp_freq = 0.004;
uniform float weather_warp_amp = 0.75;
// 迷雾带宽（gap 单位）：与迷雾显示**必须同值**，否则天气云消失的位置与薄纱边界错开
// （方案 §3.7）。约束 fog_field_band < √3/2（PK_FIELD_BAND_MAX），建议 0.6。
uniform float fog_field_band = 0.6;
// [O23] 迷雾**自己的**扭曲（真源 = fog_of_war_layer.gd 的 FOG_WARP_FREQ / FOG_WARP_AMP，
// 由 weather_layer.gd 从真源推过来；数值默认值刻意与 fog_of_war.gdshader:158-159 的同名
// uniform 默认值相同 —— 万一宿主没推，两边退化成同一组参数，而不是"天气一套、迷雾一套"）。
//
// 为什么天气要**另外**吃这两个值，而不是复用上面的 weather_warp_*：天气云的形态是天气
// 自己的美术参数（方案 §3.4 / §8-2），与迷雾无关；但**迷雾门控取 k 的取样位置**必须与
// fog_of_war.gdshader 逐像素一致（方案 §3.7：云的消失边界与薄纱边界是同一条线）。
// 扭曲决定 k 在哪儿取样 ⇒ 参数一旦分家，函数再一致边界也会错开。
// ⚠ 单位：freq = 1 / 世界单位；amp 要再乘 hex_size（见 pk_soft_warp_tiled 的说明）。
uniform float fog_warp_freq = 0.0042;
uniform float fog_warp_amp = 0.55;

// weather_table 层号：必须与 bakers/cell_lut_baker.gd 的 WEATHER_TABLE_LAYER_* 同值。
const int PK_WX_LAYER_WEATHER_A = 0;
const int PK_WX_LAYER_WEATHER_B = 1;
const int PK_WX_LAYER_WIND_BASE = 2;
// cell_table 层号：必须与 bakers/cell_table_codec.gd 的 LAYER_* 同值。
const int PK_WX_CELL_LAYER_CLASS = 0;
const int PK_WX_CELL_LAYER_AUX = 2;
#endif
uniform float world_time = 0.0;
// 与洋流和云影一致：双相位交替，重置时权重为零。
vec3 weather_flow_phases() {
	float phase = fract(world_time / 24.0);
	return vec3(phase, fract(phase + 0.5), 1.0 - abs(1.0 - 2.0 * phase));
}
// 一个 hex 的“直径”（wp 单位）。邻域采样偏移按它物理换算，避免与 map_index_atlas
// 的 hex 像素尺度发生频率共振导致六边形晶格。
uniform float hex_world_diameter = 38.0;
// 云下假阴影沿背光方向的投影偏移（hex 直径倍数）。太阳越低偏移越长 → 悬浮感越强。

// 昼夜（TOD）：方向光色 / 环境光色 / 晨昏全部走 earth_daylight 唯一真源（见下方 include），
// 不再由 GDScript 推单一 tod_sun_color/tod_ambient_color/tod_night_factor（那会让全图云统一明暗、
// 与逐像素晨昏线的地面/水面/植被对不上）。此处仅保留：总开关、迎光屏幕方向（earth_daylight 不给
// 2D 方向，云体积梯度需要它）、全局曝光、云染色开关。
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale : hint_range(0.2, 1.5) = 1.0;
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);
uniform float tod_exposure : hint_range(0.2, 2.5) = 1.0;
uniform bool cloud_tod_tint_enabled = true;

// [cylindrical-earth-daylight] 逐像素经纬度晨昏线唯一真源（与地形 brdf / 水面 / 植被同 include）。
// earth_daylight 要求 caller 在 include 前声明下列同名 uniform（默认值同 uniforms.gdshaderinc，
// 保证 GDScript 尚未推入时退化为“正午永昼”而非黑屏）。
uniform float season_phase : hint_range(0.0, 4.0) = 1.0;
uniform float day_phase : hint_range(0.0, 1.0) = 0.25;
uniform float axial_tilt_rad : hint_range(0.0, 0.7854) = 0.4101523;
#include "res://shaders/include/earth_daylight.gdshaderinc"

// 全局
uniform int weather_overlay_quality : hint_range(0, 2) = 2;
uniform float weather_strength : hint_range(0.0, 1.0) = 1.0;
// [cloud-opacity 2026-11-07] 云层不透明度总控（只影响云，不影响雨幕/风）。
// 原来 cumulus 的 alpha 上限 0.86 ≈ 实心白云，铺满地图会糊住地形。
uniform float cloud_opacity_scale : hint_range(0.0, 1.0) = 0.72;

// 天气数据源：weather_lut（per-cell LUT，见 sample_field_weather）。旧 weather_front_* uniform 已删。

// 天气类型表。
const int MAX_WEATHER_TYPES = 8;
uniform vec4 weather_profile_colors[MAX_WEATHER_TYPES];

const int WT_CLEAR = 0;
const int WT_RAIN = 1;
const int WT_STORM = 2;
const int WT_BLIZZARD = 3;
const int WT_DROUGHT = 4;
const int WT_FOG = 5;
const int WT_HEATWAVE = 6;
const int WT_MONSOON = 7;

const int B_OCEAN = 0;
const int B_COAST = 1;
const int B_HILL = 5;
const int B_MOUNTAIN = 6;
const int B_LAKE = 18;
const int B_REEF = 19;
const int B_SEA_ICE = 20;
const int B_KELP = 21;

varying vec2 v_world;

float wx_wrap_world_x(float x) {
	if (wrap_period_x <= 0.0001) {
		return x;
	}
	return wrap_origin_x + mod(x - wrap_origin_x, wrap_period_x);
}

vec2 wx_wrap_world_pos(vec2 wp) {
	return vec2(wx_wrap_world_x(wp.x), wp.y);
}

vec2 wx_wrap_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = wx_wrap_world_x(world_x);
	return vec2((wrapped_x - world_origin.x) / world_size.x, clamp(uv.y, 0.0, 1.0));
}

float wx_cloud_seam_weight(vec2 wp) {
	if (wrap_period_x <= 0.0001) {
		return 0.0;
	}
	vec2 wwp = wx_wrap_world_pos(wp);
	float seam_width = min(max(hex_world_diameter * 3.0, 1.0), wrap_period_x * 0.25);
	float seam_x = wrap_origin_x + wrap_period_x;
	float dist_to_right = clamp(seam_x - wwp.x, 0.0, seam_width);
	return 1.0 - smoothstep(0.0, seam_width, dist_to_right);
}

vec2 wx_cloud_seam_partner(vec2 wp) {
	return wx_wrap_world_pos(wp) - vec2(wrap_period_x, 0.0);
}

int effective_weather_quality() {
#if defined(PK_WEB_WEATHER_MIN)
	return 2;
#elif defined(MOBILE_QUALITY_LOW) || defined(PK_WEATHER_LOW)
	return 0;
#elif defined(MOBILE_QUALITY_MID) || defined(PK_WEATHER_MID)
	return 1;
#elif defined(MOBILE_QUALITY_HIGH) || defined(PK_WEATHER_HIGH)
	return 2;
#else
	return weather_overlay_quality;
#endif
}

// 廉价算术 hash（非纹理）——仅用于低雾 mountain_w 的邻域抖动，破除六边形对称。
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float hash_signed(vec2 p) {
	return hash21(p) - 0.5;
}

// ── 解析梯度噪声（Perlin，quintic）：云形唯一来源，平滑、无纹理网格 ──
// cloud_hash22 / cloud_grad_noise / cloud_fbm / cloud_fbm_evolve 已抽到共享
// include，与 fog_of_war.gdshader 共用同一份实现。
#ifndef PK_WEATHER_CHEAP_NOISE
#include "res://shaders/include/cloud_noise.gdshaderinc"
#endif

// [web-weather-min] web / ANGLE 裁剪变体：廉价噪声 + 裁剪版云密度（见 include 文件头）。
// 只被下方所有 `#ifdef PK_WEB_WEATHER_MIN` 路径调用。定义这个变体后，cloud_fbm /
// cloud_fbm_evolve 在本 shader 里不再有任何调用点 → 不进驱动编译（它们是编译成本主项）。
#ifdef PK_WEATHER_CHEAP_NOISE
#include "res://shaders/include/weather_overlay_web_min.gdshaderinc"
#endif

// ── 云密度主函数：软轮廓 + 清晰核心 + 时间扰动细节（cumulus / 雾 / front 共用）──
// p：世界坐标（调用方已做风向 advection）。coverage：该点语义云量 [0,1]。seed：错开不同 front。
// 低频层负责大团柔和边缘；中高频只在云核逐步增强，让内部纹理清楚但边缘仍羽化。
float cloud_density_soft(vec2 p, float coverage, float seed) {
	if (coverage <= 0.001) {
		return 0.0;
	}
#ifdef PK_WEATHER_CHEAP_NOISE
	// 低/中档、移动/Web 共用无循环的三角格点梯度噪声，保留双相位。
	// web-min：轻量梯度噪声替代 4/3/2 octave 旋转 fbm + 域扭曲；remap 曲线一模一样。
	return cloud_density_soft_min(p, coverage, seed);
#else
	int q = effective_weather_quality();
	float t = world_time;

	float cloud_mask = smoothstep(0.025, 0.18, coverage);
	float amount = smoothstep(0.04, 0.3, coverage);

#if defined(PK_MOBILE_ANY)
	float low_pulse = 0.92 + 0.08 * sin(t * 0.09 + seed * 1.7);
	return clamp(cloud_mask * mix(0.22, 0.58, amount) * low_pulse, 0.0, 1.0);
#else

	// Classic fBM cloud stack:
	// 1) low-frequency fBM gives continuous cloud texture;
	// 2) domain warp breaks circular/noisy repetition;
	// 3) billow/detail fBM adds puffy internal contrast;
	// 4) coverage remap controls how much texture survives.
	vec2 warp = vec2(0.0);
#if !defined(PK_MOBILE_HIGH_SLIM)
	if (q >= 2) {
		vec2 warp_p = p * 0.0012 + vec2(seed * 0.23, -seed * 0.17);
		float wa = cloud_fbm_evolve(warp_p + vec2(13.7, 2.9), 1, t * 0.10);
		float wb = cloud_fbm_evolve(warp_p + vec2(-5.4, 19.1), 1, -t * 0.09);
		warp = (vec2(wa, wb) - vec2(0.5)) * mix(0.32, 0.78, amount);
	}
#endif

	// 噪声相位必须只由世界坐标/时间/seed 决定，不能由 coverage 决定；否则每次 weather_lut 刷新云量变化时，噪声坐标也会跳。
	vec2 base_p = p * 0.0038 + warp + vec2(seed * 0.37, seed * 0.61);
	int body_oct = 3;
	float body_noise = cloud_fbm_evolve(base_p, body_oct, t * 0.16);
	float detail_noise = cloud_fbm_evolve(base_p * 2.35 + vec2(11.7, 4.2), 2, t * 0.34);
	float billow = 1.0 - abs(detail_noise * 2.0 - 1.0);
	float fine_noise = (q >= 2)
		? cloud_fbm_evolve(base_p * 5.10 + vec2(-21.3, 15.8), 1, t * 0.58)
		: detail_noise;
	float shape = clamp(body_noise * 0.68 + billow * 0.20 + fine_noise * 0.12, 0.0, 1.0);

	// coverage=1 时保留连续 fBM 纹理，不再用高阈值把云挖成孤岛；
	// coverage 较低时才提高 cutoff，形成云边界退缩。
	float coverage_cut = mix(0.66, 0.26, amount);
	float density = clamp((shape - coverage_cut) / max(1.0 - coverage_cut, 0.001), 0.0, 1.0);
	float soft_texture = smoothstep(0.05, 0.88, density);
	float cloud_core = smoothstep(0.66, 1.00, density);
	float texture_cloud = clamp(soft_texture * 0.82 + cloud_core * 0.08, 0.0, 1.0);
	float opacity = mix(0.38, 0.82, amount);
	return clamp(texture_cloud * cloud_mask * opacity, 0.0, 1.0);
#endif
#endif
}

struct CloudLayerSample {
	float density;
	float edge;
	float coverage;
	float height_bias;
};

CloudLayerSample make_cloud_layer(float density, float edge, float coverage, float height_bias) {
	CloudLayerSample s;
	s.density = clamp(density, 0.0, 1.0);
	s.edge = clamp(edge, 0.0, 1.0);
	s.coverage = clamp(coverage, 0.0, 1.0);
	s.height_bias = clamp(height_bias, 0.0, 1.0);
	return s;
}

CloudLayerSample empty_cloud_layer() {
	return make_cloud_layer(0.0, 0.0, 0.0, 0.0);
}

float remap_cloud_density(float shape, float coverage, float core_boost) {
	float cover_gate = smoothstep(0.02, 0.18, coverage);
	float d = clamp(shape * cover_gate, 0.0, 1.0);
	float core = d * d;
	float contrast = smoothstep(0.08, 0.88, d);
	return clamp(mix(d * 0.74, contrast, 0.42) + core * core_boost * 0.58, 0.0, 1.0);
}

// 中云 advection 世界坐标（风向漂移 + 侧向翻卷）。抽出以便云影/光照梯度复用同一坐标系，
// 避免与 sample_cumulus_layer 内联公式漂移。
vec2 cumulus_advect(vec2 wp, vec2 axis, float phase) {
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x);
	float t = world_time;
	return wp - axis * phase * 24.0 * 1.45 + side * sin(t * 0.19 + dot(wp, dir) * 0.0022) * hex_world_diameter * 0.22;
}

float cloud_density_alpha(float density) {
	// 可见度与遮挡度解耦：薄云更早显形，厚云不再把 alpha 顶满挡住地块。
	float soft = smoothstep(0.020, 0.56, density);
	float core = smoothstep(0.54, 1.00, density);
	return clamp(pow(soft, 0.90) * 0.54 + core * 0.16, 0.0, 0.70);
}

// billboard 白云着色：以亮白为主，迎太阳侧更亮、背光侧 / 厚核略压暗形成体积感，薄边银边。
// 光照走 earth_daylight：sun_col（晨昏暖橙↔正午暖白）、amb_col（夜冷蓝↔昼天空）、local_day（夜=0）。
// 方向光乘 local_day → 夜侧无阳照（与 brdf.make_lighting_context 同源），云的明暗随晨昏线扫过。
// [cell-field-overlays 2026-11-18 / O2] **不再吃 int 天气类型**（方案 §3.5）：
// 函数体从来不按 type 分支/染色（见下面「云层光照不按天气类型染色/压暗」那条），参数
// 一直是死参数。场函数路径下"先查表再按 w 混合"的 tint 由调用方算好（weather_profile_colors
// 的加权和就是 w.color），所以这里连 type 都不需要 —— 删掉参数而不是传一个
// wt_dom 进来当摆设。旧路径调点同签名（区域外），因此宏关闭时行为不变。
vec3 compute_cloud_lighting(CloudLayerSample layer, vec3 base_tint, float light_grad, float thickness, float silver_gain, vec3 sun_col, vec3 amb_col, float local_day) {
	if (!cloud_tod_tint_enabled) {
		return base_tint;
	}
	float d = layer.density;
	float thick = clamp(thickness, 0.0, 1.0);
	float sun_facing = smoothstep(-0.52, 0.55, light_grad);
	float shade = mix(0.72, 1.02, sun_facing);  // 背光侧柔和压暗、迎光侧略抬亮
	shade *= mix(1.0, 0.86, d * 0.46);           // 厚核轻压暗，出体积感
	shade *= mix(1.0, 0.74, thick * (1.0 - sun_facing) * 0.72); // 假厚度背光自阴影
	float rim = layer.edge * silver_gain * (0.38 + 0.68 * sun_facing) * mix(1.0, 0.72, thick);
	vec3 sun_c = sun_col * local_day;            // 夜侧 local_day=0 → 无方向光
	float amb_w = mix(0.18, 0.31, local_day);
	vec3 col = base_tint * (amb_col * amb_w + sun_c * (shade * 0.84 + rim * 0.42));
	col = mix(col, col * vec3(0.72, 0.75, 0.84), thick * (1.0 - sun_facing) * 0.20);
	// 云层光照不按天气类型染色/压暗，保证同云量同显示。
	// 夜侧地板由环境光（夜冷蓝）决定，不再用裸常数 → 与地面夜色同冷调。
	return max(col * tod_exposure, amb_col * mix(0.17, 0.27, local_day));
}

vec4 apply_cloud_layer(vec3 base_col, float base_alpha, CloudLayerSample layer, vec3 layer_col, float alpha_scale, float occlusion) {
	float density = layer.density;
	float shaded_density = density * (1.0 - clamp(occlusion, 0.0, 1.0) * 0.28);
	float layer_alpha = clamp(cloud_density_alpha(shaded_density) * alpha_scale * weather_strength, 0.0, 0.96);
	vec3 density_col = layer_col * mix(1.08, 0.90, density);
	float blend_w = clamp(layer_alpha * (0.60 + layer.edge * 0.20 + density * 0.30), 0.0, 1.0);
	vec3 col = mix(base_col, density_col, blend_w);
	float alpha = clamp(base_alpha + layer_alpha * (1.0 - base_alpha * 0.22), 0.0, 0.97);
	return vec4(col, alpha);
}

// ── 三层云采样 ──

// 高云（卷云）：各向异性拉丝薄纱，沿风向延展。
float sample_high_cloud_shape(vec2 wp, vec2 axis, float coverage) {
	if (coverage <= 0.001) {
		return 0.0;
	}
#ifdef PK_WEATHER_CHEAP_NOISE
	// web-min：单 octave 梯度噪声拉丝（桌面为 2~3 octave cloud_fbm + 高频 fiber 叠加）。
	return sample_cirrus_band_min(wp, axis, coverage);
#else
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x);
	float t = world_time;
	float u = dot(wp, dir);
	float v = dot(wp, side);
	vec2 sp = vec2(u * 0.004, v * 0.012);
	int q = effective_weather_quality();
	float band = cloud_fbm(sp, (q >= 2) ? 3 : 2);
	float streak = smoothstep(mix(0.62, 0.42, coverage), 0.82, band);
	if (q >= 2) {
		float fiber = cloud_fbm(sp * 2.3 + vec2(11.0, -5.0), 1);
		streak *= 0.76 + 0.24 * smoothstep(0.40, 0.80, fiber);
	}
	return clamp(streak * coverage, 0.0, 1.0);
#endif
}

float sample_high_cloud_raw(vec2 wp, vec2 axis, float coverage) {
	vec3 phases = weather_flow_phases();
	// 固定拉丝方向，局地风只改变平流，避免换风重旋世界坐标。
	vec2 band_axis = vec2(1.0, 0.15);
	float a = sample_high_cloud_shape(wp - axis * phases.x * 24.0 * 2.2, band_axis, coverage);
	float b = sample_high_cloud_shape(wp - axis * phases.y * 24.0 * 2.2, band_axis, coverage);
	return mix(b, a, phases.z);
}

float sample_high_cloud(vec2 wp, vec2 axis, float coverage) {
	vec2 primary_wp = wx_wrap_world_pos(wp);
	float base = sample_high_cloud_raw(primary_wp, axis, coverage);
#ifdef PK_WEB_WEATHER_MIN
	// web-min：接缝伙伴采样会让整份噪声再内联一遍（编译成本 ×2，只换来东西环绕接缝处
	// 一条几像素宽的过渡）。web 上直接放弃接缝双采样。
	return base;
#else
	float seam_w = wx_cloud_seam_weight(primary_wp);
	if (seam_w <= 0.001) {
		return base;
	}
	return mix(base, sample_high_cloud_raw(wx_cloud_seam_partner(primary_wp), axis, coverage), seam_w);
#endif
}


// 低云 / 山雾：贴地、慢漂，biome_weight（山地权重）调制可见度。
float sample_low_fog_raw(vec2 wp, vec2 axis, float intensity, float biome_weight) {
	if (biome_weight <= 0.001 || intensity <= 0.001) {
		return 0.0;
	}
	float t = world_time;
	vec2 dir = (length(axis) > 0.001) ? normalize(axis) : vec2(1.0, 0.0);
	vec3 phases = weather_flow_phases();
	float a = cloud_density_soft(wp - axis * phases.x * 24.0 * 0.8, clamp(intensity + 0.12, 0.0, 1.0), 53.0);
	float b = cloud_density_soft(wp - axis * phases.y * 24.0 * 0.8, clamp(intensity + 0.12, 0.0, 1.0), 53.0);
	float fog = mix(b, a, phases.z);
	return clamp(fog * intensity * biome_weight, 0.0, 1.0);
}

float sample_low_fog(vec2 wp, vec2 axis, float intensity, float biome_weight) {
	vec2 primary_wp = wx_wrap_world_pos(wp);
	float base = sample_low_fog_raw(primary_wp, axis, intensity, biome_weight);
#ifdef PK_WEB_WEATHER_MIN
	// web-min：同 sample_high_cloud，放弃接缝双采样。
	return base;
#else
	float seam_w = wx_cloud_seam_weight(primary_wp);
	if (seam_w <= 0.001) {
		return base;
	}
	return mix(base, sample_low_fog_raw(wx_cloud_seam_partner(primary_wp), axis, intensity, biome_weight), seam_w);
#endif
}

float cumulus_flow_density(vec2 wp, vec2 axis, float coverage) {
	vec3 phases = weather_flow_phases();
	float a = cloud_density_soft(cumulus_advect(wp, axis, phases.x), coverage, 13.0);
	float b = cloud_density_soft(cumulus_advect(wp, axis, phases.y), coverage, 13.0);
	return mix(b, a, phases.z);
}

float sample_cumulus_density(vec2 wp, vec2 axis, float coverage) {
	if (coverage <= 0.001) {
		return 0.0;
	}
	vec2 primary_wp = wx_wrap_world_pos(wp);
	float base = cumulus_flow_density(primary_wp, axis, coverage);
#ifdef PK_WEB_WEATHER_MIN
	// web-min：中云是唯一每像素必算的云密度，接缝双采样等于把它整份再编译一次 → 放弃接缝。
	return base;
#else
	float seam_w = wx_cloud_seam_weight(primary_wp);
	if (seam_w <= 0.001) {
		return base;
	}
	return mix(base, cumulus_flow_density(wx_cloud_seam_partner(primary_wp), axis, coverage), seam_w);
#endif
}

// 中云（积云）：视觉主角，跟风漂移、内部持续翻卷。coverage 已是语义云量，单次取密度。
CloudLayerSample sample_cumulus_layer(vec2 wp, vec2 axis, float coverage) {
	if (coverage <= 0.001) {
		return empty_cloud_layer();
	}
	float density = sample_cumulus_density(wp, axis, coverage);
	float feather = smoothstep(0.025, 0.30, density) * (1.0 - smoothstep(0.50, 0.86, density));
	float rim = smoothstep(0.10, 0.46, density) * (1.0 - smoothstep(0.58, 0.98, density));
	float edge = clamp(feather * 0.72 + rim * 0.42, 0.0, 1.0);
	return make_cloud_layer(density, edge, coverage, 0.55);
}

// ── 逐格天气场采样结果（结构沿用旧名 FrontField，现由 weather_lut / weather_table 填充）──
struct FrontField {
	vec3 color;
	float alpha;
	float intensity;
	float cloud;
	float precip;
	float shadow;
	float edge;
	int type;
	vec2 axis;
	// [cell-field-overlays 2026-11-18 / O2] 低雾用的「山地权重」。旧路径在 fragment 里现算
	// （4 点 golden-angle 邻域），场函数路径在 sample_field_weather 里用三格 biome 混合，
	// 顺便复用已经求出的三角形与 w_raw —— 所以带在结构里。旧路径恒为 0（并由 fragment
	// 的旧分支覆盖它自己的 mountain_w），字段只被 PK 分支读取。
	float mountain_w;
};

FrontField empty_field() {
	FrontField f;
	f.color = vec3(0.0);
	f.alpha = 0.0;
	f.intensity = 0.0;
	f.cloud = 0.0;
	f.precip = 0.0;
	f.shadow = 0.0;
	f.edge = 0.0;
	f.type = WT_CLEAR;
	f.axis = vec2(1.0, 0.0);
	f.mountain_w = 0.0;
	return f;
}

float precip_cloud_bias(float precip) {
	// 用连续降水量替代离散 weather_type 增强云量，避免类型跳变造成云层频闪。
	float p = smoothstep(0.04, 0.72, precip);
	return mix(1.0, 1.06, p);
}

float precip_cloud_opacity_bias(float precip) {
	float p = smoothstep(0.04, 0.72, precip);
	return mix(1.0, 1.04, p);
}


// front_axis / front_ellipse_distance / visual_weather_intensity 已随 sample_fronts 一并删除。

// ── cell-index 间接寻址（与 cell_indirect.gdshaderinc 同公式；此处内联，避免引入 dyn/eco LUT 依赖）──
// [cell-field-overlays 2026-11-18 / O2] 整段（含下面的 Bayer 选格 / 6 邻环 / 副格双采样）
// 只在旧路径编译。PK_CELL_FIELD 变体里这些符号一个都不存在 —— 这是"删掉 Bayer 选格、
// 副格间接寻址、桌面 6 邻环"的可验证形式（tests/world/weather_overlay_field_test.gd 的
// 缺席断言）；反过来，宏关时它们必须在（否则那条断言就是恒真的空断言）。
#ifndef PK_CELL_FIELD
int wx_decode_cell_index(vec2 uv) {
	vec2 gb = visual_sample_map_index(wx_wrap_uv(uv)).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}
vec2 wx_cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) { lw = 1; }
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

#endif // PK_CELL_FIELD（旧路径的 cell-index 解码）

// 风编码解码（RG = 单位风向 * 0.5 + 0.5，B = speed / 20，A = 1）：两条路径共用。
// 纯解码、不碰 sampler，所以放在守卫外面 —— 旧路径仍然逐字节调用同一份实现。
vec2 wx_decode_wind(vec4 encoded) {
	vec2 dir = encoded.rg * 2.0 - 1.0;
	float len = length(dir);
	return len > 0.01 ? dir / len * (0.25 + encoded.b) : vec2(0.0);
}

#ifndef PK_CELL_FIELD
vec2 wx_sample_wind(int cid) {
	if (!has_local_wind || cid < 0) return vec2(0.0);
	vec2 uv = wx_cell_lut_uv(cid);
	vec2 wind = wx_decode_wind(texture(wind_lut, uv));
	if (has_wind_prev) wind = mix(wx_decode_wind(texture(wind_lut_prev, uv)), wind, clamp(weather_lerp, 0.0, 1.0));
	return wind;
}

int wx_decode_edge_secondary(vec2 uv) {
	vec2 rg = visual_sample_edge_neighbor(wx_wrap_uv(uv)).rg;
	int lo = int(rg.r * 255.0 + 0.5);
	int hi = int(rg.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

float wx_bayer2_digit(vec2 bit_xy) {
	if (bit_xy.y < 0.5) {
		return (bit_xy.x < 0.5) ? 0.0 : 2.0;
	}
	return (bit_xy.x < 0.5) ? 3.0 : 1.0;
}

const float WX_DITHER_THRESHOLD_MARGIN = 0.18;

float wx_mobile_dither_uv_threshold(vec2 uv, vec2 wp) {
	vec2 atlas_dims = visual_static_texture_size();
	vec2 pixel_xy = floor(wx_wrap_uv(uv) * atlas_dims);
	if (wrap_period_x > 0.0001 && world_size.x > 0.0001) {
		float period_px = max(
				8.0,
				round((atlas_dims.x * wrap_period_x / world_size.x) / 8.0) * 8.0);
		float phase = (wx_wrap_world_x(wp.x) - wrap_origin_x) / wrap_period_x;
		pixel_xy.x = floor(fract(phase) * period_px);
	}
	vec2 p = mod(pixel_xy, 8.0);
	float value = 16.0 * wx_bayer2_digit(mod(p, 2.0))
			+ 4.0 * wx_bayer2_digit(mod(floor(p * 0.5), 2.0))
			+ wx_bayer2_digit(floor(p * 0.25));
	float raw_threshold = (value + 0.5) / 64.0;
	return mix(
			WX_DITHER_THRESHOLD_MARGIN,
			1.0 - WX_DITHER_THRESHOLD_MARGIN,
			raw_threshold);
}

float wx_edge_secondary_weight(vec2 uv) {
	if (!has_terrain_edge_data || terrain_ecotone_width <= 0.0001) {
		return 0.0;
	}
	float edge_distance = visual_sample_edge_distance(wx_wrap_uv(uv)).r;
	float one_screen_pixel = max(fwidth(edge_distance), 1.0 / 255.0);
	float quality_scale;
#if defined(MOBILE_QUALITY_LOW)
	quality_scale = 0.58;
#elif defined(MOBILE_QUALITY_MID)
	quality_scale = 0.82;
#elif defined(MOBILE_QUALITY_HIGH)
	quality_scale = 0.94;
#else
	quality_scale = (weather_overlay_quality <= 0) ? 0.68
			: ((weather_overlay_quality == 1) ? 0.92 : 1.0);
#endif
	float width = clamp(terrain_ecotone_width * quality_scale, one_screen_pixel, 0.98);
	float analytic = 0.5 * (1.0 - smoothstep(0.0, width, edge_distance));
	float aa = 0.5 * (1.0 - smoothstep(0.0, one_screen_pixel, edge_distance));
	return max(analytic, aa);
}

// 逐格 LUT 采样(只采当前帧)。帧间插值不在这里做(否则每 tap 翻倍采样)，改在 sample_field_weather
// 算出最终标量后、只对中心 cell 采一次 prev 做 mix → 全程只多 1 次采样。
vec4 wx_sample_lut(int cid) {
	return texture(weather_lut, wx_cell_lut_uv(cid));
}
#endif // PK_CELL_FIELD（旧路径：sampler 辅助 / Bayer 选格 / 副格 / 6 邻环）

#ifdef PK_CELL_FIELD
// ─── 场函数路径的装配层（方案 §3.4）─────────────────────────────────────────
// 网格参数：几何一律来自 uniform（hex_size / map_dims），**不从 hex_world_diameter
// 反推、不信默认值**（方案 §3.2 第 2 条）。map_w 同时是横向回绕周期。
PkHexGrid wx_field_grid() {
	PkHexGrid g;
	g.hex_size = max(hex_size, 1e-3);
	g.map_w = max(int(map_dims.x + 0.5), 1);
	g.map_h = max(int(map_dims.y + 0.5), 1);
	return g;
}

// 三格之一在 weather_table 里的 texel（offset 空间；col 已 posmod、row 未 clamp）。
// row 越界 = 南北 padding：先把 row clamp 进纹理（绝不越界读），再乘 inside 掩码清零。
// 为什么"清零"就是 padding 语义：建表时 o2i == -1 的 texel 四通道全部写
// WEATHER_TABLE_PAD_TYPE（= WT_CLEAR = 0，见 bakers/cell_lut_baker.gd），所以"读那一格"
// 与"读 0"逐字节相同。反过来若 clamp 到 0 / map_h-1 后**不**清零，就会把真实地图数据
// 混进地图外区域 —— 南北边缘凭空长出天气（旧路径 cid < 0 早退同样不给天气）。
vec4 wx_fetch_weather(ivec2 c, int layer, PkHexGrid g) {
	int row = clamp(c.y, 0, g.map_h - 1);
	float inside = step(0.0, float(c.y)) * step(float(c.y), float(g.map_h - 1));
	return texelFetch(weather_table, ivec3(pk_posmod(c.x, g.map_w), row, layer), 0) * inside;
}

// 三格之一的风（已解码成世界单位向量）。层号规则：wind = 2 + cur / 2 + prev。
// ⚠ 掩码必须乘在**解码之后**：风编码是 RG = 方向*0.5+0.5，padding 的 0 字节解码出来是
// dir = (-1,-1)、长度 1.41 > 0.01，会得到 (-0.707,-0.707)*0.25 这个"假风"，而不是零风。
vec2 wx_fetch_wind(ivec2 c, int layer, PkHexGrid g) {
	int row = clamp(c.y, 0, g.map_h - 1);
	float inside = step(0.0, float(c.y)) * step(float(c.y), float(g.map_h - 1));
	return wx_decode_wind(
			texelFetch(weather_table, ivec3(pk_posmod(c.x, g.map_w), row, layer), 0)) * inside;
}

// 三格之一的迷雾知识度 k（cell_table.aux.R，0..1）。
// [2026-11-18 修复] padding（row 越界）取 **k = 0**，与 `fog_of_war.gdshader::fog_cell_k`
// 逐值一致 —— 那一圈地图外薄带上的迷雾是**完全不透明**的，天气也必须一并被门控掉，
// 否则会出现「迷雾已经盖住、云还在被算」的无意义着色（且两边边界会分家）。
// 早先这里写的是 `mix(B_SEA_ICE/255, …)`：那既不是迷雾的 k，也不是地形的 k，只是把
// 一个 **biome 常量**（20/255≈0.078）混进了 **知识度** 通道，属笔误。
float wx_fetch_fog_k(ivec2 c, PkHexGrid g) {
	int row = clamp(c.y, 0, g.map_h - 1);
	vec4 v = texelFetch(cell_table, ivec3(pk_posmod(c.x, g.map_w), row, PK_WX_CELL_LAYER_AUX), 0);
	float inside = step(0.0, float(c.y)) * step(float(c.y), float(g.map_h - 1));
	return mix(0.0, v.r, inside);
}

// [O23] 按**长度**做径向 clamp（GLSL 没有 clamp_length）—— 与
// fog_of_war.gdshader::fog_clamp_length 逐式相同，是本文件唯一一处"抄迷雾"的数学。
//
// 为什么迷雾门控也要 clamp：迷雾侧的扭曲是**按长度限幅**的（方案 §3.6 约束 2：
// A ≤ (√3/2 − band/2)·s，保证可见格的格心仍是纯主导格）。天气若用同一组 freq/amp
// 却不限幅，|warp| 超过 A_max 的那些像素上 k 的取样点就会与迷雾错开（amp=0.55 时
// 双轴合成最坏 0.78·hex_size，而 A_max ≈ 0.57·hex_size ⇒ **大部分像素**都不受限），
// 于是"云消失的边界"与"薄纱边界"又分家 —— 那正是本任务要消掉的东西。
// 逐轴 clamp 不行：会把位移方块的角削成斜边，形态看出方向性。
vec2 wx_clamp_length(vec2 v, float max_len) {
	float l = length(v);
	return v * min(1.0, max_len / max(l, 1e-5));
}

// 低雾的「山地权重」（0..1）。旧路径用 4 点 golden-angle 环 + hash 抖动去平滑 texel 台阶
// （方案 §1.1 记录的同类问题）；场函数下 biome 归属本来就随坐标连续，所以直接按 w_raw
// 混合三格权重 —— 抖动与邻域采样存在的理由一起消失。
// 权重取值沿用桌面旧公式（M=1.0 / H=0.65 / 其它陆=0.35 / 水=0）：移动·Web 旧的二值近似
// （0.55、其它陆 0）是省采样的妥协，场函数下两者采样次数一样，没必要再近似。
float wx_biome_mountain_weight(ivec2 c, PkHexGrid g) {
	int row = clamp(c.y, 0, g.map_h - 1);
	int biome = int(texelFetch(cell_table,
			ivec3(pk_posmod(c.x, g.map_w), row, PK_WX_CELL_LAYER_CLASS), 0).r * 255.0 + 0.5);
	bool water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);
	return (biome == B_MOUNTAIN) ? 1.0 : ((biome == B_HILL) ? 0.65 : (water ? 0.0 : 0.35));
}

// 天气类型 → profile 行。**先查表**：颜色 / 透明度由调用方按 w 混合结果（方案 §3.5）。
// type 字节只在这里被解释一次，绝不参与插值；clamp 是因为 padding / 空槽字节写坏时
// 动态索引会越界（GLES3 对越界数组索引同样未定义）。
vec4 wx_profile_row(float type_byte) {
	return weather_profile_colors[clamp(int(type_byte * 255.0 + 0.5), 0, MAX_WEATHER_TYPES - 1)];
}
#endif // PK_CELL_FIELD（场函数装配层）

// ── 逐格天气场采样：两条路径互斥编译（宏关 = 今天逐字节相同的旧实现）──
#ifndef PK_CELL_FIELD
// 逐格天气场采样（cloud-from-field 2026-06-20）：经 cell-index 间接寻址读 weather_lut。
// type/intensity/cloud/vapor 取中心 cell（枚举不可插值）；只做帧间(prev)时间平滑。
// Spatial transitions use the shared neighbor/distance field; the hard atlas
// index remains authoritative and is never dither-remapped.
// 替代旧 sample_fronts 椭圆摘要 → 云精确对应 HexCell.weather_*。
FrontField sample_field_weather(vec2 wp) {
	FrontField best = empty_field();
	if (lut_dims.x < 1.0) return best; // weather_lut 未就绪 → 无云
	vec2 uv = wx_wrap_uv((wp - world_origin) / world_size);
	int cid_c = wx_decode_cell_index(uv);
	if (cid_c < 0) return best;
	float edge_w = wx_edge_secondary_weight(uv);
	int secondary_id = (edge_w > 0.0001) ? wx_decode_edge_secondary(uv) : -1;
	// [web-weather-min] web 变体保留桌面版的「副格连续混合」：每像素只多 1 次 weather_lut
	// 采样，却能去掉 DitherUV 的硬边；web 的瓶颈是编译期，不是这 1 次采样。
#if defined(PK_MOBILE_ANY) && !defined(PK_WEB_WEATHER_MIN)
	if (secondary_id >= 0 && wx_mobile_dither_uv_threshold(uv, wp) < edge_w) {
		cid_c = secondary_id;
	}
	// 移动端只采样 DitherUV 选中的一个视觉 cell，避免连续混合的副 LUT 成本。
	secondary_id = -1;
#endif
	// 视野屏蔽提前于所有云计算：不可见格直接退成无云，顺带把三层云 / TOD 光照 /
	// 投影阴影整条管线一起省掉。
	float fog_vis = 1.0;
	if (fog_mask_enabled) {
		float fog_k = texture(enum_lut, wx_cell_lut_uv(cid_c)).a;
		if (secondary_id >= 0) {
			float secondary_k = texture(enum_lut, wx_cell_lut_uv(secondary_id)).a;
			fog_k = mix(fog_k, secondary_k, edge_w);
		}
		fog_vis = smoothstep(0.5, 1.0, fog_k);
		if (fog_vis < 0.01) return best;
	}
	vec4 center = wx_sample_lut((cid_c));
	if (secondary_id >= 0) {
		vec4 secondary = wx_sample_lut(secondary_id);
		center.gba = mix(center.gba, secondary.gba, edge_w);
	}
	int wt = int(center.r * 255.0 + 0.5);

	float intensity_amount = center.g;
	float cloud_amount = center.b;
	float vapor_amount = center.a;
	// 帧间插值(时间平滑)：两次仿真更新(commit)之间渲染每帧都画,直接显示会在更新瞬间横跳。把上一帧标量
	// 按 weather_lerp(weather_layer 按 LUT 实际更新节奏推进 0→1)平滑过渡到当前帧 → 消时间横跳。type 离散不插。
	if (weather_lerp < 0.999) {
		vec4 prev_c = texture(weather_lut_prev, wx_cell_lut_uv(cid_c));
		if (secondary_id >= 0) {
			vec4 prev_secondary = texture(weather_lut_prev, wx_cell_lut_uv(secondary_id));
			prev_c.gba = mix(prev_c.gba, prev_secondary.gba, edge_w);
		}
		intensity_amount = mix(prev_c.g, intensity_amount, weather_lerp);
		cloud_amount = mix(prev_c.b, cloud_amount, weather_lerp);
		vapor_amount = mix(prev_c.a, vapor_amount, weather_lerp);
	}
	// 噪声坐标是连续的 world position，但 weather_lut 的 cloud/vapor 仍是
	// per-cell 标量；只采中心 cell 会让同一片噪声在六边形边界被不同阈值硬切。
	// 用真实 pointy-top 六邻居的世界偏移做低权重空间混合，只混合连续量，
	// 天气类型仍由中心 cell 决定。这样跨 cell 的云形不会重新起一套阈值。
#if !defined(PK_MOBILE_ANY) && !defined(PK_WEB_WEATHER_MIN)
	if (effective_weather_quality() >= 1) {
		vec2 hex_east = vec2(hex_world_diameter * 0.8660254, 0.0);
		vec2 hex_diag = vec2(hex_world_diameter * 0.4330127,
			hex_world_diameter * 0.75);
		vec2 weather_neighbor_offsets[6] = vec2[6](
			hex_east, -hex_east,
			hex_diag, vec2(-hex_diag.x, hex_diag.y),
			-hex_diag, vec2(hex_diag.x, -hex_diag.y)
		);
		vec3 neighbor_sum = vec3(0.0);
		float neighbor_count = 0.0;
		for (int ni = 0; ni < 6; ni++) {
			vec2 neighbor_uv = wx_wrap_uv(
				(wp + weather_neighbor_offsets[ni] - world_origin) / world_size);
			int neighbor_id = wx_decode_cell_index(neighbor_uv);
			if (neighbor_id < 0 || neighbor_id == cid_c) {
				continue;
			}
			vec4 neighbor = wx_sample_lut(neighbor_id);
			if (weather_lerp < 0.999) {
				vec4 neighbor_prev = texture(weather_lut_prev, wx_cell_lut_uv(neighbor_id));
				neighbor.gba = mix(neighbor_prev.gba, neighbor.gba, weather_lerp);
			}
			neighbor_sum += neighbor.gba;
			neighbor_count += 1.0;
		}
		if (neighbor_count > 0.0) {
			vec3 center_weather = vec3(intensity_amount, cloud_amount, vapor_amount);
			vec3 neighbor_weather = neighbor_sum / neighbor_count;
			float spatial_blend = (effective_weather_quality() >= 2) ? 0.42 : 0.30;
			vec3 smoothed_weather = mix(center_weather, neighbor_weather, 0.55);
			center_weather = mix(center_weather, smoothed_weather, spatial_blend);
			intensity_amount = center_weather.x;
			cloud_amount = center_weather.y;
			vapor_amount = center_weather.z;
		}
	}
#endif
	float precip_amount = intensity_amount;
	float visual_cloud_amount = clamp((cloud_amount + 0.6 * vapor_amount), 0.0, 1.0);
	// 云层以 weather_cloud + weather_vapor 为基础。2026-06-29：水汽先进入可视云量，
	// 显示端要让湿润区的层云/薄积云可见，避免只在降水核心处看见云。
	float cloud_linear = clamp(visual_cloud_amount / 0.8, 0.0, 1.0);
	float cloud_shaped = smoothstep(0.05, 0.8, visual_cloud_amount);
	float cloud_cover = clamp(mix(cloud_linear, cloud_shaped, 0.44) * precip_cloud_bias(precip_amount), 0.0, 1.0);
	float precip_gate = clamp(precip_amount * 1.05, 0.0, 1.0);


	best.color = (wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_colors[wt].rgb : vec3(0.0);
	best.alpha = ((wt >= 0 && wt < MAX_WEATHER_TYPES) ? weather_profile_colors[wt].a : 0.0) * fog_vis;
	best.intensity = intensity_amount * fog_vis;
	best.cloud = cloud_cover * fog_vis;
	best.precip = precip_gate * fog_vis;
	best.shadow = clamp(cloud_cover * 0.6, 0.0, 1.0) * fog_vis;
	best.edge = vapor_amount * fog_vis;
	best.type = wt;
	best.axis = wx_sample_wind(cid_c);
	if (secondary_id >= 0) best.axis = mix(best.axis, wx_sample_wind(secondary_id), edge_w);
	return best;
}

#else // PK_CELL_FIELD
// ════════════════════════════════════════════════════════════════════════════
// [cell-field-overlays 2026-11-18 / O2] 场函数版 sample_field_weather（方案 §3.4 / §3.5）
//
// 入参是**未回绕**的世界坐标（方案 §3.2 第 1 条）：函数内部先 wrap 一次，再由
// pk_overlay_tri 叠加可平铺低频扭曲后求对偶三角形。
//
// 采样账（方案 §3.9，按分支全部展平的最坏情况）：
//   天气 cur 3 +（weather_lerp < 0.999 时）天气 prev 3 + 风 cur 3 + 风 prev 3
//   + 迷雾 aux 3（fog_mask_enabled ∧ cell_table_bound）+ 低雾 class 3（低雾门控内）= 15
// 全是两张 ≤ 40 KB 小表的 texelFetch（无过滤、命中 L1）。三个条件 weather_lerp /
// fog_mask_enabled / cell_table_bound 都**只依赖 uniform** ⇒ 整屏走向一致，各平台都能
// 真正跳过（方案 §3.9 末条允许保留这类条件）。
//
// [O23 2026-11-18] 迷雾门控改用**迷雾自己的**三角形（t_fog）之后账本的变化：
//   · 纹理采样**净增 0**：那 3 次 aux texelFetch 本来就有，只是从 t 的三格换成 t_fog 的
//     三格（k 的取样位置必须与 fog_of_war.gdshader 一致，见下方门控段）；
//   · 纯 ALU **+1 次 pk_soft_warp_tiled**（2 次 pk_overlay_grad_noise_tiled = 8 次
//     pk_overlay_hash22，零纹理）＋ 1 次 length() 的 clamp。
// 所以 sampler 账不变（仍是 2 张表），只多两个 uniform 与一小段 ALU。
// ════════════════════════════════════════════════════════════════════════════
FrontField sample_field_weather(vec2 world_pos) {
	FrontField best = empty_field();
	// 数据没就绪（宏开着但 weather_table 未发布）⇒ 整段退回**无云**，绝不读不存在的层。
	// 为什么不用旧路径兜底：旧实现只在宏关闭态编译（它是"逐字节不变"的回退保证本身），
	// 两份实现同时编进来会让 sampler 从 2 涨回 8。weather_layer.gd::_push_weather_table()
	// 在同一个条件下打一次 push_warning，把"开关开着但表没就绪"报到日志里。
	if (!weather_table_bound) {
		return best;
	}
	PkHexGrid g = wx_field_grid();
	vec2 wp = wx_wrap_world_pos(world_pos);
	// 扭曲必须沿 x 周期可平铺（周期 = wrap_period_x），否则回绕接缝两侧会取到不同的格子
	// ⇒ 经线上出现一条云形错位（方案 §3.2 第 3 条）。
	vec2 ws = pk_soft_warp_tiled(wp, wrap_period_x, weather_warp_freq, weather_warp_amp * hex_size);
	PkHexTri t = pk_overlay_tri(wp, g, ws);
	vec3 w = t.w_raw;

	// 视野门控（方案 §3.7）：与迷雾显示**同一组函数 + 同一组参数**（pk_hex_sharpen +
	// pk_overlay_fog_k + pk_overlay_fog_visibility），三格 k 读 cell_table.aux.R。
	// 放在所有云计算之前：不可见处直接退成无云，顺带把三层云 / TOD 光照 / 投影阴影
	// 整条管线一起省掉。
	//
	// [O23 2026-11-18] k 的三角形**单独构造**：门控的函数一致但参数不一致，边界仍会错开
	// （k 的取样位置由扭曲决定）。所以这里用迷雾那组 fog_warp_* 重新求一次三角形，
	// 云自己的 t / w 继续用 weather_warp_*（那是天气形态参数，与迷雾无关）。
	// 三个参数（fog_warp_freq / fog_warp_amp / fog_field_band）在 GDScript 侧只有一个
	// 真源（fog_of_war_layer.gd 的常量），由 weather_layer.gd 从真源推给本材质。
	float fog_vis = 1.0;
	if (fog_mask_enabled && cell_table_bound) {
		// 迷雾显示的 k 用**锐化后**的权重与自己的带宽（方案 §3.6）：天气门控必须跟着走，
		// 否则「已探索未可见」区域里云消失的位置与薄纱边界会各走一条线。
		float fog_band = clamp(fog_field_band, 1e-4, PK_FIELD_BAND_MAX);
		vec2 ws_fog = pk_soft_warp_tiled(wp, wrap_period_x, fog_warp_freq, fog_warp_amp * hex_size);
		// 约束 2 的同一上限（与 fog_of_war.gdshader 的 fog_warp_amax 逐式相同，band 也取自
		// 同一组参数）：不加这一步，|warp| 超过 A_max 的像素上取样点就会与迷雾错开。
		float fog_amax = max(PK_HEX_SQRT3 * 0.5 - fog_band * 0.5, 0.0) * hex_size;
		PkHexTri t_fog = pk_overlay_tri(wp, g, wx_clamp_length(ws_fog, fog_amax));
		vec3 w_fog = pk_hex_sharpen(t_fog.w_raw, fog_band);
		float fog_k = pk_overlay_fog_k(w_fog,
				wx_fetch_fog_k(t_fog.c0, g), wx_fetch_fog_k(t_fog.c1, g),
				wx_fetch_fog_k(t_fog.c2, g));
		fog_vis = pk_overlay_fog_visibility(fog_k);
		if (fog_vis < 0.01) {
			return best;
		}
	}

	// 层号：cur / prev 是一对（O1 双缓冲，prev = 1 - cur）。clamp 只是不让脏 uniform 去
	// 索引不存在的层（GLES3 对越界 layer 的 texelFetch 返回值未定义）。bound 为真时
	// 两者本来就在 0/1，这里不引入分支代价。
	int cur = clamp(weather_cur_layer, PK_WX_LAYER_WEATHER_A, PK_WX_LAYER_WEATHER_B);
	int prev = clamp(weather_prev_layer, PK_WX_LAYER_WEATHER_A, PK_WX_LAYER_WEATHER_B);

	// 固定 3 次 texelFetch，三格展开写、不用循环（方案 §3.9 第 2 条）。
	vec4 c0 = wx_fetch_weather(t.c0, cur, g);
	vec4 c1 = wx_fetch_weather(t.c1, cur, g);
	vec4 c2 = wx_fetch_weather(t.c2, cur, g);
	vec2 wind0 = wx_fetch_wind(t.c0, PK_WX_LAYER_WIND_BASE + cur, g);
	vec2 wind1 = wx_fetch_wind(t.c1, PK_WX_LAYER_WIND_BASE + cur, g);
	vec2 wind2 = wx_fetch_wind(t.c2, PK_WX_LAYER_WIND_BASE + cur, g);

	// 帧间插值（时间平滑）：条件只依赖 uniform weather_lerp。**只插连续量 .gba**；
	// type 通道（.r）不插 —— 类型是类别量，走下面的"先查表再混结果"。
	if (weather_lerp < 0.999) {
		vec4 p0 = wx_fetch_weather(t.c0, prev, g);
		vec4 p1 = wx_fetch_weather(t.c1, prev, g);
		vec4 p2 = wx_fetch_weather(t.c2, prev, g);
		c0.gba = mix(p0.gba, c0.gba, weather_lerp);
		c1.gba = mix(p1.gba, c1.gba, weather_lerp);
		c2.gba = mix(p2.gba, c2.gba, weather_lerp);
		// 风是向量：**先解码再插值**（与旧路径 mix(decode, decode) 同序 —— 在编码域
		// 插值会把归一化方向算错）。
		wind0 = mix(wx_fetch_wind(t.c0, PK_WX_LAYER_WIND_BASE + prev, g), wind0, weather_lerp);
		wind1 = mix(wx_fetch_wind(t.c1, PK_WX_LAYER_WIND_BASE + prev, g), wind1, weather_lerp);
		wind2 = mix(wx_fetch_wind(t.c2, PK_WX_LAYER_WIND_BASE + prev, g), wind2, weather_lerp);
	}

	// 连续量：原始重心权重 w_raw 的三格线性组合（不锐化，方案 §2 原则表）。
	// 结果是对偶三角网上的分段线性场 ⇒ 跨格处处连续，所以天气侧不需要 fwidth。
	vec3 gba = w.x * c0.gba + w.y * c1.gba + w.z * c2.gba;
	float intensity_amount = gba.x;
	float cloud_amount = gba.y;
	float vapor_amount = gba.z;

	// 类型：**先查 profile 再按 w 混合结果**（方案 §3.5）。绝不混合 type ID ⇒
	// 雨区与雪区之间得到一条连续的雨夹雪过渡带，而不是色调硬切。
	vec4 prof = w.x * wx_profile_row(c0.r) + w.y * wx_profile_row(c1.r) + w.z * wx_profile_row(c2.r);
	// 主导格类型：只留给"仍然需要整数类型"的下游。当前**没有**这样的下游
	// （compute_cloud_lighting 不吃 int，见它的函数头），保留它是给 O4 探针与以后可能
	// 出现的按类型分支用 —— 有它就能在交界处单独检查是否跳变，而不必改采样路径。
	int dom = pk_hex_tri_dom(t);
	vec4 c_dom = (dom == 0) ? c0 : ((dom == 1) ? c1 : c2);
	int wt_dom = clamp(int(c_dom.r * 255.0 + 0.5), 0, MAX_WEATHER_TYPES - 1);

	float precip_amount = intensity_amount;
	float visual_cloud_amount = clamp((cloud_amount + 0.6 * vapor_amount), 0.0, 1.0);
	// 云层以 weather_cloud + weather_vapor 为基础（2026-06-29：水汽先进可视云量）。
	float cloud_linear = clamp(visual_cloud_amount / 0.8, 0.0, 1.0);
	float cloud_shaped = smoothstep(0.05, 0.8, visual_cloud_amount);
	float cloud_cover = clamp(mix(cloud_linear, cloud_shaped, 0.44) * precip_cloud_bias(precip_amount), 0.0, 1.0);
	float precip_gate = clamp(precip_amount * 1.05, 0.0, 1.0);

	best.color = prof.rgb;
	best.alpha = prof.a * fog_vis;
	best.intensity = intensity_amount * fog_vis;
	best.cloud = cloud_cover * fog_vis;
	best.precip = precip_gate * fog_vis;
	best.shadow = clamp(cloud_cover * 0.6, 0.0, 1.0) * fog_vis;
	best.edge = vapor_amount * fog_vis;
	best.type = wt_dom;
	// 风：Σ w_i · wind_i（同样 w_raw；prev 已在上面按解码域插值）。
	best.axis = w.x * wind0 + w.y * wind1 + w.z * wind2;

	// 低雾的「山地权重」：旧路径在 fragment 里做 4 点邻域（桌面）/ 1 点（移动 · Web）；
	// 这里改成三格 class.biome 的 w_raw 混合。门控与旧路径完全一致（q>=2 且 w.cloud>0.05，
	// 即 fog_intensity > 0.001），而且低/中档根本没编译低雾 ⇒ 这 3 次读取一般被整段跳过。
#if !defined(PK_WEATHER_LOW) && !defined(PK_WEATHER_MID)
	if (effective_weather_quality() >= 2 && best.cloud > 0.05) {
		best.mountain_w = clamp(w.x * wx_biome_mountain_weight(t.c0, g)
				+ w.y * wx_biome_mountain_weight(t.c1, g)
				+ w.z * wx_biome_mountain_weight(t.c2, g), 0.0, 1.0);
	}
#endif
	return best;
}
#endif // PK_CELL_FIELD

// sample_fronts（旧 fronts 椭圆通路）已删除——云分布改由 sample_field_weather 逐格 LUT 驱动。

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 wp = wx_wrap_world_pos(v_world);
	vec2 uv = wx_wrap_uv((v_world - world_origin) / world_size);

	// [cell-field-overlays 2026-11-18 / O2] 场函数路径的入参是**未回绕**世界坐标（方案 §3.2
	// 第 1 条，函数内部自己 wrap）；旧路径保持传已回绕的 wp，一字未改。
#ifdef PK_CELL_FIELD
	FrontField w = sample_field_weather(v_world);
#else
	FrontField w = sample_field_weather(wp);
#endif

	int q_weather = effective_weather_quality();
#ifndef PK_CELL_FIELD
	// 旧路径的 biome 采样：is_water 自 2026-06 起已无下游读取（低雾单独取一次 fog_biome），
	// 场函数路径连 map_index_atlas 都不绑定，所以整段只在旧路径编译。
	int biome = 0;
#if !defined(PK_MOBILE_ANY)
	biome = int(visual_sample_map_index(wx_wrap_uv(uv)).r * 255.0 + 0.5);
#endif
	bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);
#endif

	// 低雾仅高档启用；无雾时跳过山地采样。移动/Web 使用中心格近似。
	float fog_intensity = (q_weather >= 2 && w.cloud > 0.05) ? w.cloud * 0.65 : 0.0;
	float mountain_w = 0.0;
#ifdef PK_CELL_FIELD
	// 场函数路径：三格 class.biome 的 w_raw 混合已在 sample_field_weather 里算好
	// （复用同一个三角形，不重算扭曲噪声），门控也一致。
	mountain_w = w.mountain_w;
#else
#ifdef PK_WEATHER_CHEAP_NOISE
	// web-min：山地权重退化成「中心格 biome」二值近似（桌面版是 4 点 golden-angle 邻域 + hash
	// 抖动）。省掉 4 次邻域贴图取样、8 次 hash，以及一个可动态索引的 vec2[4] 局部数组 ——
	// 后者在 ANGLE→HLSL 里会变成真实数组/寄存器溢出，是编译期与运行期的双重成本。
	if (fog_intensity > 0.001) {
		// 不能复用上面的 biome：mobile 质量档下它被编译成常量 0，所以这里单独取一次
		// （filter_nearest，命中同一 texel，代价可忽略）。
		int fog_biome = int(visual_sample_map_index(wx_wrap_uv(uv)).r * 255.0 + 0.5);
		mountain_w = (fog_biome == B_MOUNTAIN) ? 1.0 : ((fog_biome == B_HILL) ? 0.55 : 0.0);
	}
#else
	if (fog_intensity > 0.001) {
		// 山地权重（仅低雾用）：4 点 golden-angle 邻域 + hash 抖动，平滑陆海/海拔过渡，
		// 偏移按 hex_world_diameter 物理换算，避免六边形直边。
		vec2 ring_step = vec2(hex_world_diameter) / max(world_size, vec2(0.001));
		const float GA = 2.39996323;
		vec2 m_offs[4] = vec2[4](
			vec2(0.0, 0.0),
			vec2(cos(GA * 1.0 + 0.7), sin(GA * 1.0 + 0.7)) * 2.6,
			vec2(cos(GA * 2.0 + 0.7), sin(GA * 2.0 + 0.7)) * 3.3,
			vec2(cos(GA * 3.0 + 0.7), sin(GA * 3.0 + 0.7)) * 2.9
		);
		float mw_sum = 0.0;
		float mw_tot = 0.0;
		for (int li = 0; li < 4; li++) {
			vec2 jj = vec2(
				hash_signed(floor(wp * 0.18 + vec2(31.0 + float(li) * 11.0, -47.0))),
				hash_signed(floor(wp * 0.18 + vec2(-19.0, 23.0 + float(li) * 9.0)))
			);
			vec2 s_uv = wx_wrap_uv(uv + m_offs[li] * ring_step + jj * 1.4 * ring_step);
			int bs = int(visual_sample_map_index(s_uv).r * 255.0 + 0.5);
			bool s_water = (bs == B_OCEAN) || (bs == B_COAST) || (bs == B_LAKE)
					|| (bs == B_REEF) || (bs == B_KELP) || (bs == B_SEA_ICE);
			float bw = (bs == B_MOUNTAIN) ? 1.0 : ((bs == B_HILL) ? 0.65 : (s_water ? 0.0 : 0.35));
			float kw = (li == 0) ? 1.4 : 1.0;
			mw_sum += bw * kw;
			mw_tot += kw;
		}
		mountain_w = clamp(mw_sum / max(mw_tot, 0.001)
				+ hash_signed(floor(wp * 0.085 + vec2(67.0, -31.0))) * 0.18, 0.0, 1.0);
	}
#endif
#endif // PK_CELL_FIELD（旧路径的山地权重邻域采样）

	vec2 cumulus_axis = w.axis;
	vec2 cirrus_axis = w.axis;

	// 高云强度：只随云量出现，不按天气类型开关。
	float cirrus_intensity = w.cloud * 0.48;
	float cirrus = 0.0;
#ifndef PK_WEATHER_LOW
	cirrus = (q_weather >= 1) ? sample_high_cloud(wp, cirrus_axis, cirrus_intensity) : 0.0;
#endif
	// 中云（主云）强度：使用已按天气层级增强后的 w.cloud。
	float cumulus_intensity = (w.cloud > 0.02) ? w.cloud : 0.0;
	CloudLayerSample cumulus_layer = sample_cumulus_layer(wp, cumulus_axis, cumulus_intensity);
	float cumulus = cumulus_layer.density;

	// 低雾强度也只随云量和山地权重，不按天气类型改变；q0 完全跳过。
	float local_fog_w = mountain_w;
	float low_fog = 0.0;
#if !defined(PK_WEATHER_LOW) && !defined(PK_WEATHER_MID)
	low_fog = (fog_intensity > 0.001) ? sample_low_fog(wp, w.axis, fog_intensity, local_fog_w) : 0.0;
#endif

#ifndef PK_WEATHER_CHEAP_NOISE
	// 透明像素也参与相邻云边像素的导数计算。只在全画面一致的画质分支中取导数。
	vec2 grad_xy = vec2(0.0);
	if (q_weather >= 2) {
		vec2 world_pixel = vec2(length(dFdx(wp)), length(dFdy(wp)));
		grad_xy = vec2(dFdx(cumulus), dFdy(cumulus))
			/ max(world_pixel, vec2(0.001)) * hex_world_diameter * 0.34;
	}
#endif

	bool has_layer = (cumulus > 0.001) || (cirrus > 0.001) || (low_fog > 0.001) || (w.precip > 0.001);
	if (!has_layer) {
		COLOR = vec4(0.0);
	} else {
		// 只给可见天气计算经纬度光照，保留与地表相同的晨昏线和太阳方向。
		float lat_signed = clamp(uv.y * 2.0 - 1.0, -1.0, 1.0);
		EarthDaylight ed = eval_earth_daylight(uv, lat_signed, day_night_enabled);

		CloudLayerSample cirrus_layer = make_cloud_layer(
			remap_cloud_density(cirrus, cirrus_intensity, 0.16),
			smoothstep(0.05, 0.42, cirrus) * (1.0 - smoothstep(0.58, 0.96, cirrus)),
			cirrus_intensity,
			0.92
		);
		CloudLayerSample fog_layer = make_cloud_layer(
			remap_cloud_density(low_fog, max(fog_intensity, local_fog_w), 0.24),
			smoothstep(0.04, 0.42, low_fog) * (1.0 - smoothstep(0.54, 0.96, low_fog)),
			max(fog_intensity, local_fog_w),
			0.18
		);

		// 低/中/移动/Web 只用已有密度和边缘；高档复用分支外的导数来计算层内光照。
		float cumulus_thickness = clamp(cumulus_layer.density * (0.80 + 0.20 * cumulus_intensity), 0.0, 1.0);
		float cumulus_light_grad = clamp(cumulus_layer.edge * 0.45 + cumulus_layer.density * 0.18 - 0.30, -1.0, 1.0);
#ifndef PK_WEATHER_CHEAP_NOISE
		if (q_weather >= 2) {
			vec2 sun_h = ed.sun_dir.xy;
			float sun_horiz = clamp(length(sun_h), 0.0, 1.0);
			vec2 sun_axis = (sun_horiz > 1e-4) ? sun_h / sun_horiz : normalize(vec2(0.62, -0.38));
			float sun_up = max(ed.sun_dir.z, 0.0);
			vec3 fake_normal = normalize(vec3(-grad_xy * 2.9, 0.92));
			vec3 fake_sun = normalize(vec3(sun_axis * max(sun_horiz, 0.001), max(sun_up, 0.10)));
			cumulus_light_grad = clamp((dot(fake_normal, fake_sun) - 0.52) * 2.25
				+ dot(grad_xy, sun_axis) * 0.82 - cumulus_thickness * 0.18, -1.0, 1.0)
				* (0.42 + 0.58 * sun_horiz);
		}
#endif

#ifdef PK_WEB_WEATHER_MIN
		// web-min：层间遮挡纯 ALU（fog/cumulus 密度已在手），按桌面 q2 语义保留，不额外取样。
		float layer_occlusion = clamp(fog_layer.density * 0.34 + cumulus_layer.density * 0.28, 0.0, 1.0);
#else
		float layer_occlusion = (q_weather >= 2)
			? clamp(fog_layer.density * 0.34 + cumulus_layer.density * 0.28, 0.0, 1.0)
			: 0.0;
#endif

		// 局部云核/羽边（密度驱动）：先算，供压暗与亮度调制复用（cloud_core 后续阴影也用）。
		float cloud_core = smoothstep(0.38, 0.92, cumulus_layer.density);
		float cloud_edge_soft = 1.0 - smoothstep(0.18, 0.58, cumulus_layer.density);
		// 强云区不再把整格底色压成灰片；只让云纹理本身更厚、更少银边。
		float dense_cell = smoothstep(0.14, 0.32, w.cloud);
		float dense_core = clamp(dense_cell * (0.35 + 0.65 * cloud_core), 0.0, 1.0);
		vec3 main_base = mix(vec3(0.97, 0.98, 1.00), vec3(0.55, 0.62, 0.72), ed.pixel_night);
		main_base = mix(main_base, vec3(0.82, 0.86, 0.92), dense_core * 0.28);
#ifdef PK_WEB_WEATHER_MIN
		// web-min：银边增益直接取桌面 q2 值（纯 ALU，不额外取样），只是没有体积梯度可乘。
		float silver = mix(1.08, 0.58, dense_core);
#else
		float silver = mix((q_weather >= 2) ? 1.08 : 0.72, 0.58, dense_core);
#endif
		vec3 col = compute_cloud_lighting(cumulus_layer, main_base, cumulus_light_grad, cumulus_thickness, silver, ed.sun_col, ed.amb_col, ed.local_day);
		// 边缘过亮项(>1)在强云核轻微收敛，避免羽边白点闪烁（但不压成暗块）。
#ifdef PK_WEB_WEATHER_MIN
		float bright_mul = mix(1.08 + cloud_edge_soft * 0.06, 0.82, cloud_core * 0.54);
#else
		float bright_mul = mix(1.08 + cloud_edge_soft * 0.06, 0.82, cloud_core * ((q_weather >= 2) ? 0.54 : 0.38));
#endif
		col *= mix(bright_mul, min(bright_mul, 1.02), dense_core);
		float precip_alpha_factor = precip_cloud_opacity_bias(w.precip);
		// 云量分层：旧公式只看 density，且经过多次上限压缩，弱云/强云最终
		// 都落在相近的 alpha。这里把天气场的 cloud 强度重新带回显示端：
		// 弱云保持轻薄，强云获得更高密度增益；WeatherProfile 的 overlay_base_alpha
		// 作为类型级的薄雾/暴雨底幕，只在确实有云时生效，避免 clear 铺底。
		float cloud_strength = smoothstep(0.03, 0.72, w.cloud);
		float cloud_alpha_gain = mix(0.58, 1.30, cloud_strength);
		float profile_alpha = clamp(w.alpha
			* smoothstep(0.02, 0.36, w.cloud) * 0.26 * weather_strength, 0.0, 0.26);
		float alpha = clamp(profile_alpha
			+ cloud_density_alpha(cumulus_layer.density)
				* cloud_alpha_gain * mix(1.0, 1.06, dense_core)
				* precip_alpha_factor * weather_strength * 1.18,
			0.0, min(0.90, 0.80 * precip_alpha_factor));
		alpha = clamp(alpha * cloud_opacity_scale, 0.0, 0.94);

		// 低雾（底层，介于地面与中云之间）。
		if (fog_layer.density > 0.001) {
			vec3 fog_base = mix(vec3(0.80, 0.84, 0.88), vec3(0.62, 0.68, 0.74), ed.pixel_night);
			vec3 fog_col = compute_cloud_lighting(fog_layer, fog_base, 0.0, fog_layer.density * 0.55, 0.08, ed.sun_col, ed.amb_col, ed.local_day);
			vec4 fog_comp = apply_cloud_layer(col, alpha, fog_layer, fog_col, 0.95 * cloud_opacity_scale, 0.0);
			col = fog_comp.rgb;
			alpha = fog_comp.a;
		}

		// 高云（卷云，最上层薄纱）。
		if (cirrus_layer.density > 0.001) {
			vec3 cirrus_base = mix(vec3(0.92, 0.94, 0.98), ed.sun_col, 0.28);
			cirrus_base = mix(cirrus_base, vec3(0.72, 0.78, 0.88), ed.pixel_night);
			vec3 cirrus_col = compute_cloud_lighting(cirrus_layer, cirrus_base, cirrus_layer.edge * 0.18, cirrus_layer.density * 0.28, 0.36, ed.sun_col, ed.amb_col, ed.local_day);
			vec4 cirrus_comp = apply_cloud_layer(col, alpha, cirrus_layer, cirrus_col, 0.42 * cloud_opacity_scale, layer_occlusion * 0.45);
			col = cirrus_comp.rgb;
			alpha = min(cirrus_comp.a, 0.94);
		}

		float tod_alpha = mix(0.65, 1.0, ed.local_day);
		// 云层随 TOD 变暗/变薄，避免夜侧像白色贴片盖在地表上。
		COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), min(alpha * tod_alpha, 0.94));
	}
}
