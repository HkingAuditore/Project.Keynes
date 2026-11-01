shader_type canvas_item;
// [pk-web-texture-budget] 全部光照都是本 shader 自算（太阳向量/horizon shadow/GI），
// 项目从不使用引擎 Light2D；缺 unshaded 会让 Godot 额外编译"受光"路径，隐式多占
// 1-2 个 fragment 纹理单元（灯光贴图/阴影图集 sampler），在 Compatibility(GLES3/
// WebGL2) 16 单元预算下是纯浪费。其余同类全屏 canvas shader
// （data_overlay/fog_of_war/country_border/hex_edge_overlay）都已带 unshaded，
// 这里补齐。
render_mode blend_mix, unshaded;

// ═══════════════════════════════════════════════════════════════════════════
// [land-water-split 2026-11-02] 陆地 / 水面双 program 的宏归一（**只做别名，不动前缀**）。
// Web 的两套既有前缀 `PK_WEB_LAND_ONLY` / `PK_WEB_WATER_ONLY` 是字节契约
// （HexRenderer.WORLD_MAP_WEB_PREFIX* / WATER_WEB_HIGH_PREFIX / terrain_shader_variant_test
// 逐字节守着），绝不能改；桌面 / 移动（Vulkan / GLES3 / Mobile）新增
// `PK_LAND_ONLY` / `PK_WATER_ONLY`。这里把 Web 宏在 shader 内部归一到通用名，
// 让下方分支只认一种写法：Web 变体的**行为**逐字不变，只是统一了判定条件。
// ═══════════════════════════════════════════════════════════════════════════
#if defined(PK_WEB_LAND_ONLY) && !defined(PK_LAND_ONLY)
#define PK_LAND_ONLY
#endif
#if defined(PK_WEB_WATER_ONLY) && !defined(PK_WATER_ONLY)
#define PK_WATER_ONLY
#endif

// world_map.gdshader v9.atlas — 高分辨率地理仿真渲染（结构重构版 2026-05-19）
// [sky-sh-ambient 2026-06-29] 引入 L1 球谐天光（earth_daylight.earth_sky_sh）；本注释用于
// 触发顶层 shader 重编译，避免编辑 .gdshaderinc 后 Godot 残留旧编译缓存导致 "earth_sky_sh 未找到"。
// [sky-sh-water 2026-06-29b] 水面菲涅尔天空反射改吃方向化球谐天色（按波浪法线取样）；再次 touch。
// [sky-sh-water 2026-06-29c] 新增波浪 hillshade（water_wave_shade_strength）让无直射水域也见波浪；touch。
// [water-detail-sss 2026-06-29d] 新增高频细节法线(q>=2) + 廉价水体 SSS(q>=1)；touch 触发重编。
// [water-wave-readability 2026-06-29e] hillshade 默认强度 0.35→1.8 + 细节法线降频(可调 tiling) +
//   低频噪声复用(macro_lf/macro_vlf 省 2 个 fbm)；touch 触发重编。
// [water-detail-break-tiling 2026-06-29f] 细节法线叠中频 domain-warp 破 tiling(water_detail_normal_warp)；touch。
// [wave-patchiness 2026-06-29g] 波浪强度包络参数化(water_wave_patch_strength) + 细节法线增幅/放宽上限；touch。
// [detail-gate-fix 2026-06-29h] 修复细节法线门控 bug(wave_q 被钳到1→quality>=2 永不成立)，改用全局 visual_quality 判定(保持>=2 高画质专属)；touch。
// [sss-fix+base-normal 2026-06-29i] 修复 SSS 标定(pow(facing,3)×wave_act 压到 0) + 新增 water_base_normal_strength(宏观涌浪强度可调)；touch。
// [range-widen 2026-06-29j] 放宽水面调参 hint_range 上限 + patch 公式 lo clamp(防 patch>1 翻转)；touch。
// [params-bake 2026-06-29k] 固化用户实调水面参数默认值(shade1.5/patch1.23/base1.21/detail0.75/scale0.57/sss0.22)；touch。
// [base+patch tilling 2026-06-29l] 新增 water_base_normal_scale / water_wave_patch_scale 控制宏观涌浪与浪带的瓦片密度；touch。
// [params-bake 2026-06-29m] 固化水面参数(patch 1.58/scale2.69、base1.17/scale0.93、detailScale0.48、sss0.18)；touch。
// [terrain-gi 2026-07-31] 同一张 8 方向 horizon 图派生天空可见度(AO)、bent normal 与单次弹射，
//   环境光改按 bent normal 定向、按 sky visibility 遮蔽；新增 gi_occluder tile 与 bounce_lut；touch。
// [terrain-gi-tuning 2026-07-31b] 首轮实机配平：新增 gi_ao_floor / gi_ao_smoothing，
//   gi_bent_strength 与 gi_normal_floor 下调（暗部死黑 + 高频碎化）；新 uniform 必须 touch。
// [micro-soften+river-hierarchy 2026-07-31c] 微表面/细节法线全面软化 + 河宽幂律对比拉大；touch。
// [normal-soften+albedo 2026-07-31d] residual↓、细节法线改宽差分+zoom门控、高画质恢复 per-biome 程序纹理；touch。
// [terrain-material-tiles 2026-08-01] 四层材质族 Texture2DArray（uniforms/terrain_surface_detail/land_pipeline
//   三处 include 接入）；touch 触发重编，否则 include 改动命中旧编译缓存、贴图路径静默走程序化回退。
// [terrain-material-tiles 2026-08-01b] debug_view=7 材质门禁可视化（GM 面板可切）；touch。
// [terrain-material-tiles 2026-08-01c] 材质强度默认值提升（albedo 0.6 / normal 0.15）；touch。
// [terrain-material-tiles 2026-08-01d] world_size 128→384 修 mipmap 预滤波；GPT-image-2 风格化贴图换源；touch。
// [eco-lut-retire 2026-08-06] 主地形移除 eco_lut，Compatibility 预算槽让给 terrain_material_tex；touch。
// [water-edge-continuous 2026-08-02] 水体静态类别/水深改用距离场连续混合；LOW 编译期旁路。
// [river-normal-separation 2026-08-03] 河心改用水平面基准的独立水波法线，河岸才与地形法线过渡；touch。
// [baked-surface 2026-11-01] 两端删除"运行期高度差分法线"：hillshade_tod 只剩唯一入口
//   terrain_baked_normal（法线/细节坡度全部来自生成期烘焙纹理）。Web LOW 由
//   PK_WEB_HORIZON 真正执行 horizon 解码；上一轮的 Web 运行期细节法线开关整体删除。
// [packed-surface 2026-11-01 / 方案 A] 非 tiled 的 normal+relief 合并成 1 个 2 层
//   sampler2DArray `terrain_surface_tex`（layer0=normal、layer1=relief），Web 地形程序
//   腾出 1 槽恢复 noise_tex（common_noise 回到 1 次纹理采样的预烘包快路径）。Web 陆地
//   程序最终 8 槽 = height/map_index/enum/dyn/material/terrain_surface_tex/
//   terrain_horizon_tex/noise_tex。touch 触发重编。
// [p0-insolation-dead 2026-11-01] climate_season.season_offset_unified 无条件 return 0.0（on-map dyn_valid==1 ⇒ current_temp==dyn_temp，积分是死代码；padding 被 Fog 盖住，与 web 变体原行为一致）；touch 触发重编。
// ═══════════════════════════════════════════════════════════════════════════
// 本文件 2026-05-19 由 2299 行单文件拆分为 1 个主 shader + 多个 .gdshaderinc：
//   uniforms / common_noise / height / climate_season / biome_color / vegetation /
//   weather_front / snow_cover / biome_detail / hillshade_tod / water / land_pipeline /
//   water_pipeline / global_adjustments  —— 详见 shaders/include/。
//
// 主文件仅保留：shader_type、render_mode、按拓扑顺序的 #include、vertex()、
// fragment()（SETUP 解码 → LAND/SEA 分支调度 → GLOBAL 输出）。具体算法均下沉到 include。
// 通道语义快速参考（详细请见 uniforms.gdshaderinc）：
//   height_tex (RGBA8 LINEAR)      RG=海拔 (R*256+G)/257；B=river flow（原独立 flow_tex）
//   terrain_normal_tex (RGBA8)     2D：RG=粗法线 xy；BA=近景高度细节坡度（encode_slope）。
//                                  仅非 tiled 的**其它层**（植被/建筑/资源/贸易）消费。
//   terrain_surface_tex (2×RGBA8)  非 tiled 地形程序打包数组：layer0=normal（同上布局），
//                                  layer1=relief（RG=粗段/BA=细段分地形细节坡度）
//   terrain_horizon_tex (RGBA8)    8 方向 horizon angle，high/low nibble packed
//   noise_tex (RGBA8)              预烘噪声包（R raw value；GBA=fbm 2/3/4 octave 预积分）
//   map_index_atlas (RGBA8 NEAREST) R=biome  GB=cell.index
//   enum/dyn LUT:                  per-cell enum / dynamic visual state（eco_lut 已退役）
//   terrain_material_tex           四层材质族 Texture2DArray（albedo/rough/normal 打包）
// ═══════════════════════════════════════════════════════════════════════════

// ─── Include 拓扑顺序（不可随意调整） ─────────────────────────────────────
//   uniforms       叶子，零依赖，必须最先。
//   material_constants 叶子（仅依赖 uniforms 中的 visual_quality 等）；集中常量、F0、特性开关。
//   visual_tile_sampling 依赖 VT_USE_* 采样预算；声明 height/map_index/normal/relief/
//                  horizon/edge/water_depth/detail/gi 的 sampler 与解码 helper。
//   common_noise   全部变体 include；统一走 noise_tex 预烘包快路径（1 次纹理采样）。
//                  [packed-surface 2026-11-01] Web 地形程序恢复绑定 noise_tex。
//   height         叶子，依赖 uniforms.height_tex / hm_resolution。
//   climate_season 叶子，依赖 uniforms.axial_tilt_rad / season_temp_amp / insolation 组。
//   biome_color    叶子，依赖 uniforms.color_* / deep_ocean_* / B_* / ocean_current_enabled。
//   vegetation     依赖 common_noise.fbm + uniforms.V_* / vegetation_season_lut。
//   weather_front  依赖 common_noise.fbm + uniforms.MAX_WEATHER_FRONTS / WT_*（BLIZZARD）。

//   snow_cover     依赖 common_noise.fbm + height.decode_height_rg8 + weather_front.compute_extreme_weather_mask。
//   biome_detail   依赖 common_noise.fbm + common_noise.voronoi_cell + uniforms.B_*。
//   earth_daylight 叶子，仅依赖 uniforms.season_phase/day_phase/axial_tilt_rad。
//   植被气候物候权重内联于 land_pipeline，避免 include 热重载缓存版本错配：
//                  地球式昼夜（晨昏线）单一真源，被 hillshade_tod/brdf/water 统一调用。
//   hillshade_tod  依赖 visual_tile_sampling（烘焙 normal/relief）+ uniforms.hillshade_* /
//                  terrain_erosion_* / camera_zoom；唯一法线入口 terrain_baked_normal。
//   water          依赖 common_noise.* + uniforms.map_index_atlas / B_LAKE/B_REEF/B_KELP/B_SEA_ICE。
//   surface_params 半 PBR Stylized 参数结构（base_color/normal/roughness/metallic/ao/emission/alpha）。
//   tonemap        依赖 material_constants：srgb↔linear、ACES filmic、Reinhard legacy。
//   shore_common   依赖 uniforms + material_constants：sample_shore_neighborhood / compute_shore_halo。
//   terrain_horizon 所有变体统一 include；有 VT_USE_HORIZON 时解码 8 方向 horizon angle
//                  （一次 4-tap 采样同时给出 direct shadow、天空可见度(AO) 与 bent normal），
//                  没有采样槽的程序（Web 水面）内部退化为中性叶子。
//   brdf           依赖 surface_params + material_constants + tonemap + terrain_horizon
//                  + cell_indirect（弹射项要按遮挡源 cell id 查 bounce_lut）：
//                  Cook-Torrance / Blinn-Phong fallback。
//   land/water/global pipelines  最后 include，封装 fragment 的陆地/水面/全局调度算法。
//                  拆分 program 时两边互补：陆地 program 不 include water_pipeline，
//                  水面 program 不 include land_pipeline（PK_WEB_LAND_ONLY /
//                  PK_WEB_WATER_ONLY 与桌面 PK_LAND_ONLY / PK_WATER_ONLY 同义）。

// ─────────────────────────────────────────────────────────────────────────
#include "res://shaders/include/shader_quality.gdshaderinc"
#include "res://shaders/include/uniforms.gdshaderinc"
// ─── VT_USE_* 采样预算（决定 visual_tile_sampling 声明哪些 sampler）──────────
// [baked-surface 2026-11-01 / packed-surface 2026-11-01 / web-high-features 2026-11-01]
// 法线/细节坡度两端都只来自生成期烘焙纹理，非 tiled 的 normal+relief 打包成 1 个 array：
//   桌面 tiled：normal + relief 仍是两个数组（relief 是 relief_scale 倍分辨率，
//     不能同 array）+ water_depth + terrain_detail + edge_* + horizon + gi_occluder。
//   桌面 legacy（非 tiled）：normal+relief+detail(+occluder) 打包进 terrain_surface_tex，
//     保留 water_depth / edge_* / horizon / gi_occluder / micro / bounce_lut。
//   Web 地形程序（LOW + HIGH land，PK_WEB_WATER_ONLY 之外）恰好 8 个材质槽 ——
//     height_tex / map_index_atlas / enum_lut / dyn_lut / terrain_material_tex /
//     terrain_surface_tex / terrain_horizon_tex / noise_tex。
//     方案 B：detail 读 surface array layer2；micro 读 material array 第 5 层；
//     GI 弹射读 surface array layer3（不再需要 bounce_lut）。都不新增 sampler。
//   Web/Compatibility 水面（PK_WEB_WATER_ONLY，或桌面 Compatibility 的**非 tiled**
//     完整主 pass）：water_depth 槽打开（HIGH 水面 7 槽；桌面 Compatibility 主 pass 8 槽）。
//   Web land-only 程序不拿 water_depth（预算留给上面的 8 槽）；桌面 Compatibility tiled
//     变体保持方案 A 的 8 槽（tiled 的 water_depth/detail 是数组，会超 GLES3 预算）。
//   Web 水面程序（PK_WEB_WATER_ONLY）仍不开 surface/horizon（水面不需要地形几何法线）。
//   桌面 Compatibility（只有 PK_WEB_TEXTURE_BUDGET、没有 PK_WEB_HORIZON）：horizon 槽
//     不开（VT_USE_HORIZON 不定义，由 terrain_horizon 中性叶子兜底）。
#define VT_USE_HEIGHT
#define VT_USE_MAP_INDEX
#define VT_USE_FLOW
#if defined(PK_WEB_TEXTURE_BUDGET)
#ifndef PK_WEB_WATER_ONLY
#define VT_USE_TERRAIN_NORMAL
#define VT_USE_TERRAIN_RELIEF
// [B] 非 tiled detail 走 terrain_surface_tex layer2；tiled budget（桌面 Compatibility
// tiled 诊断路径）保持方案 A 的 8 槽，不新增 detail/water_depth 数组采样器。
// water_depth 只给"同程序里真的画水"的变体：桌面 Compatibility 完整主 pass（无 LAND_ONLY）；
// Web land-only 程序不拿（保持 8 槽）。
#if !defined(MAP_VISUAL_TILED)
#define VT_USE_TERRAIN_DETAIL
#if !defined(PK_WEB_LAND_ONLY)
#define VT_USE_WATER_DEPTH
#endif
#endif
#if defined(PK_WEB_HORIZON)
#define VT_USE_HORIZON
#endif
#endif
// [B] HIGH 水面独立程序（WATER_ONLY，非 tiled）需要烘焙水深；land-only 程序不拿。
#if defined(PK_WEB_WATER_ONLY)
#define VT_USE_WATER_DEPTH
#endif
#else
#define VT_USE_TERRAIN_NORMAL
#define VT_USE_TERRAIN_RELIEF
#define VT_USE_WATER_DEPTH
#define VT_USE_TERRAIN_DETAIL
#define VT_USE_EDGE_NEIGHBOR
#define VT_USE_EDGE_DISTANCE
#define VT_USE_HORIZON
// [pk-web-texture-budget] GI 单次弹射（gi_occluder tile + bounce_lut）只在桌面
// 启用；Compatibility 下裁掉——sky visibility/direct shadow 等其余 horizon 派生量
// 不受影响，只丢弹射色溢出这一项纯装饰性增强。
#define VT_USE_GI_OCCLUDER
#endif
// [web-high-features 2026-11-01 / 方案 B] 非 tiled Web/Compatibility 的 HIGH 地表特性包：
// 全部复用已有 sampler，不增加材质槽：
//   PK_TERRAIN_MICRO_ARRAY   — micro 走共享 terrain_material_tex 第 5 层（index 4）；
//   PK_TERRAIN_PACKED_BOUNCE — GI 弹射 occluder ids 走 terrain_surface_tex 第 4 层
//                              （index 3），不再采样 bounce_lut（该变体也没声明它）。
#if defined(PK_WEB_TEXTURE_BUDGET) && !defined(PK_WEB_WATER_ONLY) && !defined(MAP_VISUAL_TILED)
#define PK_TERRAIN_MICRO_ARRAY
#define PK_TERRAIN_PACKED_BOUNCE
#endif
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
#include "res://shaders/include/earth_daylight.gdshaderinc"
#include "res://shaders/include/material_constants.gdshaderinc"
#ifdef PK_WEB_WORLD_MIN
#include "res://shaders/include/world_map_web_min.gdshaderinc"
#else
#include "res://shaders/include/cell_indirect.gdshaderinc"
#endif
// [baked-surface 2026-11-01] common_noise 所有变体都 include：统一走 noise_tex 预烘包。
// [packed-surface 2026-11-01] 非 tiled 的 normal+relief 合并进 1 个 array 后腾出采样槽，
// noise_tex 在 Web 地形程序恢复绑定，上一轮的程序化噪声 fallback 已整体删除。
#include "res://shaders/include/common_noise.gdshaderinc"
#include "res://shaders/include/height.gdshaderinc"
#include "res://shaders/include/climate_season.gdshaderinc"
#include "res://shaders/include/biome_color.gdshaderinc"
#include "res://shaders/include/vegetation.gdshaderinc"
#ifndef PK_WEB_WORLD_MIN
#include "res://shaders/include/weather_front.gdshaderinc"
#endif
#include "res://shaders/include/snow_cover.gdshaderinc"
#include "res://shaders/include/biome_detail.gdshaderinc"
#include "res://shaders/include/hillshade_tod.gdshaderinc"
#if !defined(PK_WEB_WORLD_MIN) && !defined(PK_WEB_LAND_ONLY)
#include "res://shaders/include/water.gdshaderinc"
#endif
#include "res://shaders/include/surface_params.gdshaderinc"
#include "res://shaders/include/terrain_surface_detail.gdshaderinc"
#include "res://shaders/include/tonemap.gdshaderinc"
#ifndef PK_WEB_WORLD_MIN
#include "res://shaders/include/shore_common.gdshaderinc"
#endif
// [baked-surface 2026-11-01] horizon 所有变体统一 include：Web 全档位生成期烘焙，
// PK_WEB_HORIZON 覆盖 MOBILE_QUALITY_LOW 的早退；没有 horizon 采样槽的程序
// （Web 水面）由 include 内部的中性叶子兜底。terrain_horizon_neutral 不再使用。
#include "res://shaders/include/terrain_horizon.gdshaderinc"
#include "res://shaders/include/brdf.gdshaderinc"
// [land-water-split 2026-11-02] 水面 program 不 include 陆地管线（与陆地 program
// 不 include 水面管线对称）。Web HIGH 水面程序（PK_WEB_WATER_ONLY）经上面的别名也是
// PK_WATER_ONLY，因此同样只编自己那条着色来源；fragment 里陆地分支退化为占位常量，
// 不会再引用 render_land_pipeline。
#if !defined(PK_WATER_ONLY)
#include "res://shaders/include/land_pipeline.gdshaderinc"
#endif
#if !defined(PK_WEB_WORLD_MIN) && !defined(PK_WEB_LAND_ONLY) && !defined(PK_LAND_ONLY)
#include "res://shaders/include/water_pipeline.gdshaderinc"
#endif

#include "res://shaders/include/global_adjustments.gdshaderinc"


#ifdef PK_WEB_WORLD_MIN
// ⚠ 本注释块整体包在 PK_WEB_WORLD_MIN 里，目的就是让**桌面变体的预处理产物逐字节
// 不变**（这一点由 tmp/next/_probe 的 expand-diff 守着）。
//
// [web-water-pass] 水面已从本 fragment **整段移出**，见
//   shaders/world_water_web.gdshader（第二 pass）+ hex_renderer._sync_water_quad()。
// 上一轮在这里留过一个"紧凑水面"函数（biome 底色 + 深度 + 岸线 + 海冰，无 fbm /
// 无循环）作为缓解手段，实测证明它治不好，反而更容易被误认为"已经优化过了"：
//   只留陆地（水面=常量）              2 473 ms
//   只留水面（陆地=常量）              1 089 ms
//   两者都在                           20 291 ms
//   水面改紧凑 if/else（≈25 行）       17 264 ms
//   水面改无分支三元/mix（≈30 行）     18 060 ms
// 结论：悬崖与第二个着色来源的**行数无关**（25 行 = 1000 行），是 ANGLE/FXC 的寄存器
// 压力型非线性。唯一有效的做法是让这个 fragment 只剩一个着色来源。所以
// PK_WEB_WORLD_MIN 下水面像素输出一个常量占位色，由 world_water_web.gdshader 整屏
// 覆盖重画。占位色刻意选成"暗海蓝"：万一第二 pass 因故没画（档位被裁 / 编译失败），
// 屏幕上是一片偏平的深蓝，而不是一眼假的品红。
#endif

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// ═══════════════════════════════════════════════════════════════════════
	// SETUP 0：Atlas 采样 / 通道解码
	// ───────────────────────────────────────────────────────────────────────
	// 动态视觉状态统一走 cell-index + LUT；旧 per-pixel dynamic/smooth/ecology atlas
	// 以及 scalar/vector atlas 已退役。
	// ═══════════════════════════════════════════════════════════════════════
	vec2 wp = wrap_world_pos(v_world);
	vec2 uv = wrap_map_uv((v_world - world_origin) / world_size);
	// v10.noise-cache：本像素只采样一次全局噪声包，供后续"随机抖动/强度扰动"
	// 类视觉细节复用。真正需要独立频率/方向/时间推进的结构噪声（水纹、河口等）
	// 仍走专用 fbm，避免所有效果同形同相。
	//
	// pixel_rand4 语义（半 PBR 重构后约定）：
	//   .r = phase / jitter（结构噪声相位扰动）
	//   .g = amplitude / paper grain
	//   .b = equator-band / paper grain（与 global_adjustments 共享）
	//   .a = equator mix / dissolve overlay
	// 这 4 个分量在 v10.noise-pack 中是 raw value + fbm-2/3/4-octave 的预积分，
	// 谱形不同但仍是同坐标采样，对"独立 RV"的要求是软约束。下游若需严格独立
	// 随机数，应另调 derive_independent_noise4(wp + offset)。
	// [packed-surface 2026-11-01] 非 tiled 的 normal+relief 合并成 1 个 2 层 array 后，
	// Web 地形程序恢复 noise_tex 绑定：pixel_noise 重新走预烘噪声包（1 次纹理采样），
	// MOBILE_QUALITY_LOW 仍按 PK_SKIP_PIXEL_NOISE 退化成中性灰（移动端省采样）。
	// 60 FPS 优化（2026-06-18）：scalar/vector 和 per-pixel dynamic atlas 已退役。
#ifdef PK_SKIP_PIXEL_NOISE
	vec4 pixel_noise = vec4(0.5);  // 中性灰值，不调 fbm 也不影响
#else
	vec4 pixel_noise = texture(noise_tex, (wp * 0.071 + vec2(19.0, -23.0)) / NOISE_TEX_SCALE);
	if ((pixel_noise.g + pixel_noise.b) <= 0.0001 && pixel_noise.a >= 0.98) {
		pixel_noise = derive_independent_noise4(wp * 0.071 + vec2(19.0, -23.0));
	}
#endif

	// height 一次采样同时给出：RG=16-bit 高程，B=天然河流 SDF，A=运河 SDF。
	vec4 height_px = visual_sample_height(uv);
	float elev = (height_px.r * 256.0 + height_px.g) / 257.0;

	vec4 scals = vec4(0.0);  // scalar_atlas 退役：moist/lat 由 LUT/uv 重建。
	// [river-render-restore / height-flow-pack] flow：Legacy/Tiled 均自 height*.B。
	// land/water pipeline 读 scals.g 画河网。低画质仍要保留静态河网；昂贵的河流动效/
	// 坡向流纹已在 land_pipeline 里按质量档裁掉。
	// 降级必须走 has_flow_tex 而不是"没绑就采样得 0"：GLES3/WebGL2 下解析不到的
	// sampler2D 兜底成 4×4 白纹理，flow 会恒为 1，整片陆地被混上河水色。
	float flow_raw = height_px.b;
	scals.g = has_flow_tex ? flow_raw : 0.0;
	scals.b = height_px.a;
	// edge_distance 一次采样：scals.r = 格界距离（生态过渡 / 材质边缘），
	// scals.a = 烘焙沟谷折痕，shore_frac = 8 邻域水 / 湖占比（海岸 halo）。
	// 下游一律从这里取，不再重复采样。
	vec2 shore_frac = vec2(0.0);
#ifdef VT_USE_EDGE_DISTANCE
	vec4 edge_px = visual_sample_edge_distance(uv);
	scals.r = edge_px.r;
	scals.a = edge_px.g;
	shore_frac = edge_px.ba;
#else
	scals.r = 1.0;
#endif
	vec4 vects = vec4(0.5);  // vector_atlas 退役：洋流/风视觉取中性零向量。

	// map_index 一次采样：R=像素 biome，GB=cell id，A=landform。
	vec4 map_px = visual_sample_map_index(uv);
	int _cell_id = int(map_px.g * 255.0 + 0.5) + int(map_px.b * 255.0 + 0.5) * 256;
	_cell_id = (_cell_id >= 65535) ? -1 : _cell_id;
	// dyn_lut.a 与旧 dyn_atlas_smooth.a 同语义（水格=sea_ice_frac，陆格=vegetation_vitality）。
	// [dither-index 2026-06-25] 全档位 NEAREST：cell 索引边缘融合（烘焙期 Bayer dither）已在
	// 索引层软化离散硬边，无需再对 dyn/eco LUT 做跨格 4-tap 双线性。
	vec4 dyns = (_cell_id >= 0) ? texture(dyn_lut, cell_lut_uv(_cell_id)) : vec4(0.0);
	// [eco-lut-retire 2026-08-06] 主地形不再读 eco_lut：着色与 dyn_vitality 重叠，
	// 纹理槽让给 terrain_material_tex（web/mobile/desktop 统一）。植被层自有 eco_lut。

	// enum 通道（biome/veg/cover）走 cell 索引图 + enum_lut。
	// cid<0 是极地外侧的不可交互 padding。玩家地图把它表现为海冰，既明确世界边界，
	// 也避免无归属区域看起来像可点击海洋；模拟与选格仍只认真实 cell id。
	int biome;
	int veg;
	int cover;
	// fog_k = 视野知识度：0 未探索 / 0.5 已探索未可见 / 1 完全可见。它搭车在
	// enum_lut 的 A 通道上，所以拿到它是**零新增 texture sample** —— 主 shader
	// 本来就无条件采这张 LUT，只是多读一个分量。地图外 padding 视作全知，不参与
	// 迷雾（padding 本就由迷雾层自己盖住）。
	float fog_k = 1.0;
	if (_cell_id >= 0) {
		vec4 elut = texture(enum_lut, cell_lut_uv(_cell_id));
		biome = int(elut.r * 255.0 + 0.5);
		veg   = int(elut.g * 255.0 + 0.5);
		cover = int(elut.b * 255.0 + 0.5);
		fog_k = elut.a;
#if defined(PK_MOBILE_ANY)
		// 与 FogOfWarLayer 使用同一移动端 DitherUV 选择，仅替换知识度的视觉采样；
		// 地表分类、交互和动态权威状态仍属于硬主 cell。
		float fog_edge_w = terrain_edge_secondary_weight_d(scals.r, wp);
		if (fog_edge_w > 0.0001
				&& terrain_mobile_dither_uv_threshold(uv, wp) < fog_edge_w) {
			int fog_secondary_id = decode_edge_secondary_index(uv);
			if (fog_secondary_id >= 0) {
				fog_k = texture(enum_lut, cell_lut_uv(fog_secondary_id)).a;
			}
		}
#endif
	} else {
		biome = B_SEA_ICE;
		veg = 0;
		cover = 0;
	}
	// [landform 轴可视化 2026-06-25] landform id 走 map_index_atlas.A（per-pixel, NEAREST），
	// 供陆地管线给火山/高原/峡谷/裂谷/高峰补充专属着色。地图外哨兵采样得 0（=DEEP_OCEAN，陆地分支不消费）。
	int landform = int(map_px.a * 255.0 + 0.5);
	float moist = dyns.g;
	float _Hf = visual_static_texture_size().y;
	float lat_norm = clamp((uv.y * _Hf - 0.5) / max(_Hf - 1.0, 1.0), 0.0, 1.0);
	float dyn_temp = dyns.r;
	float dyn_wet = dyns.g;
	float dyn_snow = dyns.b;
	float dyn_vitality = dyns.a;
	// [snow-dyn-valid-fix 2026-06-16] 真实格子动态 atlas/LUT 恒为有效。
	// 历史背景：旧值 step(0.02, dyn_temp) 是为了兜底"bake_world 阶段温度尚未初始化
	// (默认 0.0)→ atlas R 通道为 0"的时序窗口。但该哨兵把真实极寒格(温度=0)误判为
	// "未初始化"，导致整格动态状态(含 100% 雪盖)被清零、屏幕不出雪。
	// 现已在 map_generator.gd 把温度 Bootstrap 前移到 bake_world 之前，atlas 从第 0
	// 帧即带真实纬度温度，不再存在未初始化窗口，因此恒信 atlas 真值（含温度=0 的极寒）。
	// 唯一例外：cell-indirection 下地图外哨兵像素（cid<0）采样为 vec4(0)，仍回退
	// derived_temp，避免地图边缘出现"温度=0 冷边"。on-map 真实格永远有效。
	float dyn_valid = (_cell_id < 0) ? 0.0 : 1.0;
	moist = mix(moist, dyn_wet, dyn_valid);
	vec2 ocean_current_v = vects.rg * 2.0 - 1.0;
	vec2 wind_v          = vects.ba * 2.0 - 1.0;

	// flow + river_edge_warp 仅在陆地的 river 分支才用，这里推迟到 _if (!is_water)_ 计算，
	bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);
	// [land-water-split 2026-11-02] 水面 program（Web HIGH 与桌面/移动 PK_WATER_ONLY）：
	// 只画水。陆地像素 discard —— 陆地像素由陆地 program 负责（含混合 block 的陆地像素）；
	// 未探索的**水**像素不 discard，落到下面的 fog 出口画 fog_unexplored_color（与陆地
	// program 同一 uniform 值），保证纯水 block 在分 mesh 后仍有迷雾色。
	// debug 视图由 renderer 回退单 program，这里保留 discard 作为防御。
#ifdef PK_WATER_ONLY
	// Reuse the PC water pipeline without compiling a second land shading source.
	if (!is_water || terrain_surface_debug_view != 0) { discard; }
#endif
	// The static base color already uses continuous edge blending, but later
	// climate/vegetation/cover stages are biome-gated. Feed those stages a
	// DitherUV-selected visual biome as well, otherwise they redraw the hard
	// primary-cell silhouette after the distance-field blend.
	int visual_land_biome = biome;
	int visual_land_veg = veg;
	int visual_land_cover = cover;
	if (!is_water && _cell_id >= 0 && has_terrain_edge_data) {
		float land_edge_w = terrain_edge_secondary_weight_d(scals.r, wp);
		float land_dither_probability =
				land_edge_w * terrain_land_dither_zoom_strength();
		if (land_dither_probability > 0.0001
				&& terrain_mobile_dither_uv_threshold(uv, wp)
						< land_dither_probability) {
			int land_secondary_id = decode_edge_secondary_index(uv);
			if (land_secondary_id >= 0) {
				vec4 land_secondary_enum = texture(enum_lut, cell_lut_uv(land_secondary_id));
				int land_secondary_biome = int(land_secondary_enum.r * 255.0 + 0.5);
				if (!terrain_static_biome_is_water(land_secondary_biome)) {
					visual_land_biome = land_secondary_biome;
					visual_land_veg = int(land_secondary_enum.g * 255.0 + 0.5);
					visual_land_cover = int(land_secondary_enum.b * 255.0 + 0.5);
				}
			}
		}
	}
	// Water keeps hard primary ownership, but MID/HIGH pass the secondary static
	// material and a continuous distance-field weight into one water evaluation.
	// LOW compiles this lookup out entirely. Dynamic state remains primary-owned.
	int water_secondary_biome = biome;
	int water_secondary_cover = cover;
	float water_static_edge_mix = 0.0;
	float visual_water_ice_fraction = (_cell_id < 0) ? 1.0 : dyns.a;
#if !defined(PK_QUALITY_LOW)
	if (is_water && _cell_id >= 0 && has_terrain_edge_data) {
		float water_edge_w = terrain_edge_secondary_weight_d(scals.r, wp);
		if (water_edge_w > 0.0001) {
			int water_secondary_id = decode_edge_secondary_index(uv);
			if (water_secondary_id >= 0) {
				vec4 water_secondary_enum = texture(enum_lut, cell_lut_uv(water_secondary_id));
				int candidate_biome = int(water_secondary_enum.r * 255.0 + 0.5);
				if (terrain_static_biome_is_water(candidate_biome)) {
					water_secondary_biome = candidate_biome;
					water_secondary_cover = int(water_secondary_enum.b * 255.0 + 0.5);
					water_static_edge_mix = water_edge_w;
				}
			}
		}
	}
#endif

	// ═══════════════════════════════════════════════════════════════════════
	// SETUP 1：季节相位 + 当前温度（每帧由 WorldClock 驱动）
	// ───────────────────────────────────────────────────────────────────────
	// 提前算好 lat_signed / season_offset / current_temp，让后续
	// 植被 / 雪 / 海冰 / 深海色温分支都消费同一组温度值。
	// ═══════════════════════════════════════════════════════════════════════
	// ─── Phase 1：季节相位 + 当前温度（每帧由 WorldClock 驱动） ───────────
	float lat_signed = lat_norm * 2.0 - 1.0;            // [-1, 1]
	// True Insolation-Driven：CPU / GPU 同源日照偏移；兼容 bool 不再切换 legacy 分支。
	float season_offset = season_offset_unified(lat_signed, season_phase);
	float derived_temp = compute_current_temp(elev, lat_signed, season_offset);
	float current_temp = mix(derived_temp, dyn_temp, dyn_valid);

	// ═══════════════════════════════════════════════════════════════════════
	vec3 col;

	// ═══════════════════════════════════════════════════════════════════════
	// ═══════════════════════════════════════════════════════════════════════
	// 主分支：陆地 / 海面
	// ───────────────────────────────────────────────────────────────────────
	// 每条分支都按：basecolor → 变色层 → 覆盖层 → 光照。
	// 分支外只保留全局视觉调整（羊皮纸、季节过渡 alpha、COLOR 写出）。
	// ═══════════════════════════════════════════════════════════════════════
	// 未探索早退：这些像素会被 FogOfWarLayer 的**完全不透明**厚云盖住，画什么都
	// 看不见，所以整条陆地/水体/BRDF/hillshade 管线（几十次采样）可以整段跳过。
	// GPU 分支按 wave 粒度生效：迷雾区是大片连续屏幕区域，发散 wave 只有 O(边界
	// 周长)，相对 O(面积) 可忽略。canvas_item 的 fragment 禁用 return，所以只能
	// 用 if/else 把两条出口都写出来。
	bool fog_hidden = fog_early_out_enabled && (fog_k <= fog_early_out_k);
	if (fog_hidden) {
		COLOR = vec4(fog_unexplored_color, 1.0);
	} else {
		if (!is_water) {
#if !defined(PK_PROBE_NO_LAND) && !defined(PK_WATER_ONLY)
			col = render_land_pipeline(
				visual_land_biome, biome, visual_land_veg, visual_land_cover, landform,
				elev, moist, wp, uv, scals, lat_signed, current_temp,
				wind_v, dyn_snow, dyn_valid, dyn_vitality, pixel_noise, shore_frac);
#else
			col = vec3(0.2, 0.35, 0.15);   // PROBE: land pipeline removed
#endif
		} else {
#ifndef PK_PROBE_NO_WATER
#if defined(PK_WEB_WORLD_MIN) || defined(PK_WEB_SPLIT_WATER)
			// [web-water-pass] web-LOW 档：水面由独立的第二 pass
			// （shaders/world_water_web.gdshader）整屏覆盖重画，这里只出一个常量。
			// 这是本次结构性修复的**全部内容**：本 fragment 从此只有一个真正的
			// 着色来源（陆地），FXC 不再踩"两个来源联合优化"的 20.3 s 悬崖。
			// 常量取值与 PK_PROBE_NO_WATER 探针一致（该探针因此退化为等价路径，
			// 但按约定保留：它是"水面像素到底由谁画"的开关）。
			col = vec3(0.1, 0.2, 0.4);
#elif defined(PK_LAND_ONLY)
			// [land-water-split 2026-11-02] 桌面 / 移动陆地 program：水面像素由独立的
			// 水面 program 绘制（混合 block 两张覆盖 mesh 都覆盖，这里 discard 才不会
			// 盖掉水；未探索像素已在上面走 fog 出口，与水面 program 同色）。
			discard;
#else
			col = render_water_pipeline(
				biome, cover, water_secondary_biome, water_secondary_cover,
				water_static_edge_mix, elev, wp, uv, scals,
				lat_signed, current_temp, ocean_current_v, wind_v,
				visual_water_ice_fraction, shore_frac, pixel_noise);
#endif
#else
			col = vec3(0.1, 0.2, 0.4);     // PROBE: water pipeline removed
#endif
		}
		int visual_surface_cover = is_water ? cover : visual_land_cover;
		int visual_surface_veg = is_water ? veg : visual_land_veg;

		// 已探索但当前不可见 → 去饱和 + 压暗。k=0.5 处最灰，k=1 归零。
		// 零新增采样，只是几条 ALU。
		if (fog_gray_enabled) {
			float gray_amt = (1.0 - smoothstep(0.5, 1.0, fog_k)) * fog_gray_strength;
			col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))) * 0.82, gray_amt);
		}

		// 保留旧 11 参数 ABI，避免 ShaderInclude 热缓存与主 shader 热重载不同步。
		// 气候参数仅用于接口兼容，global_adjustments 内不再消费它们。
		// 13 = 陆/水分支判定。用户报告的现象是「所有格子都像被一层水面渲染覆盖」，
		// 这一档直接把 is_water 的取值画出来，并按具体水 biome 分色，一眼区分成因：
		//   绿   = 走陆地管线（正常陆地）
		//   白   = B_SEA_ICE。cid<0 时 biome 被无条件赋成它，所以整片白 = 索引失效
		//   蓝   = B_OCEAN，即 enum_lut.r 读成 0
		//   青/深蓝/品红/黄 = COAST / LAKE / REEF / KELP
		// 14 = flow（河流 SDF）。灰阶=原始取值，红=已越过 river_threshold_low，也就是
		// land_pipeline 会把该像素混上河水色的区域。正常应当是接近全黑的底图上几条细红
		// 河线；整屏发白/发红即 flow 采样器落到 GLES3 兜底白纹理（Legacy 应读 height_tex）。
		// 刻意读未经 has_flow_tex 门控的 flow_raw：门控已经把管线侧的故障挡住了，这一档
		// 要能继续报出"纹理其实没绑"这件事，否则修复会把诊断一起掩盖掉。
		if (terrain_surface_debug_view == 14) {
			float f = clamp(flow_raw, 0.0, 1.0);
			vec3 fv = vec3(f);
			if (f >= river_threshold_low) { fv = vec3(1.0, 0.0, 0.0); }
			COLOR = vec4(fv, 1.0);
		} else if (terrain_surface_debug_view == 16) {
			// 16 = flow 所在采样器尺寸（height_tex / visual_height_tiles），
			// 以 12 位二进制条读出（0..4095）。
			// 上半屏 = 宽，下半屏 = 高；左边是最高位，白=1、深蓝=0，每 4 位一条红分隔。
			// 读出 derived_size = 正常；读出 4×4 = 采样器落到了引擎默认白纹理。
			// tests/_tmp_decode_texsize_view.gd 可以直接从截图里把这两个数解出来。
			ivec2 fs = visual_flow_texture_size();
			int val = (SCREEN_UV.y < 0.5) ? fs.x : fs.y;
			int bit = clamp(11 - int(floor(SCREEN_UV.x * 12.0)), 0, 11);
			vec3 c = (((val >> bit) & 1) == 1) ? vec3(1.0) : vec3(0.05, 0.05, 0.20);
			if (bit % 4 == 3 && fract(SCREEN_UV.x * 12.0) < 0.08) {
				c = vec3(1.0, 0.0, 0.0);
			}
			COLOR = vec4(c, 1.0);
		} else if (terrain_surface_debug_view == 17) {
			// 17 = 用 texelFetch 整数取样 flow，绕过 filter_linear 与 wrap uv。
			// 若这一档恢复出细红河线而 14 仍整屏红，问题在过滤/采样状态而非纹理内容。
			float f = clamp(visual_flow_texel(uv), 0.0, 1.0);
			vec3 fv = vec3(f);
			if (f >= river_threshold_low) { fv = vec3(1.0, 0.0, 0.0); }
			COLOR = vec4(fv, 1.0);
		} else if (terrain_surface_debug_view == 13) {
			vec3 branch = vec3(0.0, 1.0, 0.0);
			if (biome == B_SEA_ICE) { branch = vec3(1.0); }
			else if (biome == B_OCEAN) { branch = vec3(0.0, 0.25, 1.0); }
			else if (biome == B_COAST) { branch = vec3(0.0, 0.9, 0.9); }
			else if (biome == B_LAKE) { branch = vec3(0.0, 0.0, 0.5); }
			else if (biome == B_REEF) { branch = vec3(1.0, 0.0, 1.0); }
			else if (biome == B_KELP) { branch = vec3(1.0, 0.9, 0.0); }
			COLOR = vec4(branch, 1.0);
		} else if (terrain_surface_debug_view == 11 || terrain_surface_debug_view == 12
				|| terrain_surface_debug_view == 15) {
			// 11 = 光照后、apply_global_adjustments 前；12 = 光照前的底色；
			// 15 = 河流 flow 层之前的静态材质底色（三者都在 land_pipeline 里取值）。
			COLOR = vec4(col, 1.0);
		} else if (terrain_surface_debug_view > 0) {
			COLOR = vec4(terrain_surface_debug_color(uv, wp, _cell_id), 1.0);
		} else {
#ifdef PK_PROBE_NO_GLOBAL_ADJ
			COLOR = vec4(col, 1.0);   // [probe] global_adjustments
#else
			COLOR = apply_global_adjustments(
				col, wp, pixel_noise, dyn_snow, current_temp, moist, dyn_vitality, dyn_valid,
				visual_surface_cover, is_water ? 0.0 : 1.0,
				visual_surface_veg == V_NONE ? 0.0 : 1.0);
#endif // PK_PROBE_NO_GLOBAL_ADJ
		}
	}
}
