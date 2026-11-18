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
// ═══════════════════════════════════════════════════════════════════════════
// [cell-field-web 2026-11-18] `PK_WEB_WORLD_MIN` 与 `PK_CELL_FIELD` **正交，不互斥**。
// world-min 的唯一作用是「把水面着色源从这个 fragment 里摘掉」（水面由
// shaders/world_water_web.gdshader 的第二 pass 重画），从而避开 ANGLE/FXC 的
// 「两个着色源联合优化」悬崖（20.3 s 实测见本文件下方 PK_WEB_WORLD_MIN 注释块，与
// docs/web-export.md 的 Web 首编实测同源）。它**不是**「不渲染陆地」，也不含任何
// 逐像素索引图消费者：world_map_web_min.gdshaderinc 只补 cell_lut_uv /
// WATER_WRAP_TAU / water_wrap_* 三个叶子，不引用 enum_lut / dyn_lut / map_index。
// ⇒ 上一版那条 `#if defined(PK_CELL_FIELD) && defined(PK_WEB_WORLD_MIN)` →
// `#undef PK_CELL_FIELD` 的归一化已删除：它会静默把 Web LOW 的场函数关掉，
// 让陆地走 legacy 索引图、水面走场函数，海岸判定两套来源 ⇒ 必然错开 1~2 px
// （方案 §3.7「陆地与水面由同一个判断口决定」）。现在 world-min 变体同样可以
// 带 PK_CELL_FIELD，两边的 is_water 同源。
// ═══════════════════════════════════════════════════════════════════════════

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
// [macro-relief 2026-11-06] 提升烘焙粗法线、horizon 遮蔽与 GI bent normal 的默认权重；
//   保留生成期法线/地形 horizon 数据源不变，仅增强运行期宏观起伏的可读性。
// [packed-surface 2026-11-01 / 方案 A] 非 tiled 的 normal+relief 合并成 1 个 2 层
//   sampler2DArray `terrain_surface_tex`（layer0=normal、layer1=relief），Web 地形程序
//   腾出 1 槽恢复 noise_tex（common_noise 回到 1 次纹理采样的预烘包快路径）。Web 陆地
//   程序最终 8 槽 = height/map_index/enum/dyn/material/terrain_surface_tex/
//   terrain_horizon_tex/noise_tex。touch 触发重编。
// [p0-insolation-dead 2026-11-01] climate_season.season_offset_unified 无条件 return 0.0（on-map dyn_valid==1 ⇒ current_temp==dyn_temp，积分是死代码；padding 被 Fog 盖住，与 web 变体原行为一致）；touch 触发重编。
// [surface-array-edge 2026-11-02] 同一个 array 扩到 **6 层**：layer4 = edge_distance
//   （R 格界距离 / G 沟谷 crease / BA 8 邻域水·湖占比）、layer5 = edge_neighbor RG
//   （次生 cell id 16-bit；B = water_depth R，A 预留）。数据本来就在 native tile bundle 里
//   ⇒ 扩层零新增烘焙；陆地与两个水面程序共用同一 sampler ⇒ 恢复次生生态过渡 / crease /
//   海岸 halo / 次生水格时**一个材质槽都不新增**（Web 陆地仍 8 槽、HIGH 水面 7→8、
//   compact 水面 5→6）。touch 触发重编。
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
//   terrain_surface_tex (6×RGBA8)  非 tiled 地形 / 水面程序共用的打包数组：
//                                  layer0=normal（同上布局）、layer1=relief（RG=粗段/BA=细段）、
//                                  layer2=detail、layer3=occluder ids、
//                                  layer4=edge_distance（R 距离/G crease/BA 海岸占比）、
//                                  layer5=edge_neighbor（RG 次生 id；B 水深）
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
// [baked-surface 2026-11-01 / packed-surface 2026-11-01 / web-high-features 2026-11-01 /
//  surface-array-edge 2026-11-02]
// 法线/细节坡度/edge 静态场两端都只来自生成期烘焙纹理，非 tiled 的**固定 6 层**
// sampler2DArray `terrain_surface_tex`（normal/relief/detail/occluder/edge_distance/
// edge_neighbor）：
//   桌面 tiled：normal + relief 仍是两个数组（relief 是 relief_scale 倍分辨率，
//     不能同 array）+ water_depth + terrain_detail + edge_* + horizon + gi_occluder。
//   桌面 legacy（非 tiled）：6 层打包进 terrain_surface_tex，
//     保留 water_depth / horizon / gi_occluder / micro / bounce_lut。
//   Web 地形程序（LOW + HIGH land，PK_WEB_WATER_ONLY 之外）恰好 8 个材质槽 ——
//     height_tex / map_index_atlas / enum_lut / dyn_lut / terrain_material_tex /
//     terrain_surface_tex / terrain_horizon_tex / noise_tex。
//     方案 B：detail 读 surface array layer2；micro 读 material array 第 5 层；
//     GI 弹射读 surface array layer3（不再需要 bounce_lut）。都不新增 sampler。
//     [2026-11-02] 次生生态过渡（secondary biome 混合 + DitherUV 远景过渡）、沟谷 crease、
//     海岸 halo 占比改读 layer4/layer5 —— 同样是**已有槽**，8 槽预算不变。
//     [cell-field-web 2026-11-18] 启用场函数后旧三槽（map_index / enum / dyn）从声明里
//     删掉、cell_table 补 1 ⇒ **6 槽**：height / horizon / noise / material /
//     terrain_surface / cell_table。逐变体数字以
//     `tests/world/terrain_shader_variant_test.gd` 的 sampler 普查为准（等值断言）。
//   Web/Compatibility 水面（PK_WEB_WATER_ONLY，或桌面 Compatibility 的**非 tiled**
//     完整主 pass）：water_depth 槽打开（HIGH 水面 7→8 槽，新增的 1 槽就是 surface array；
//     桌面 Compatibility 主 pass 8 槽）。
//   Web land-only 程序不拿 water_depth（预算留给上面的 8 槽）；桌面 Compatibility tiled
//     变体保持方案 A 的 8 槽（tiled 的 water_depth/detail 是数组，会超 GLES3 预算）。
//   桌面 Compatibility（只有 PK_WEB_TEXTURE_BUDGET、没有 PK_WEB_HORIZON）：horizon 槽
//     不开（VT_USE_HORIZON 不定义，由 terrain_horizon 中性叶子兜底）。
#define VT_USE_HEIGHT
// [cell-field-web 2026-11-18] 预算变体（PK_WEB_TEXTURE_BUDGET）启用场函数后，旧三槽必须
// 从**声明**里删掉（见 uniforms.gdshaderinc 的 PK_CELL_FIELD_NO_LEGACY_LUT）：Web 陆地
// program 已用满 8 个 sampler，cell_table 会是第 9 个，第 9 张起每帧被引擎内建白纹覆盖，
// **不报错**、画面只是错的（方案 §3.2 / §3.4）。所以 VT_USE_MAP_INDEX 在该组合下不定义
// ⇒ visual_sample_map_index() / map_index_atlas 的任何残留引用直接变成编译错误，漏改
// 不可能靠"人眼 grep"溜过去。
// 开关本身由 uniforms 的宏表达（那里已经算好了 PK_CELL_FIELD && PK_WEB_TEXTURE_BUDGET），
// 本文件**不重复**加第二个宏。
#ifndef PK_CELL_FIELD_NO_LEGACY_LUT
#define VT_USE_MAP_INDEX
#endif
#define VT_USE_FLOW
// [surface-array-edge 2026-11-02] 非 tiled 的静态地表打包成 **6 层** sampler2DArray
// `terrain_surface_tex`（normal/relief/detail/occluder/edge_distance/edge_neighbor）。
// 陆地程序与两个水面程序声明的是同一个 sampler，VT_USE_* 只决定读哪一层 ⇒
// 恢复次生生态过渡 / crease / 海岸占比 / 次生水格时**一个材质槽都不新增**。
#if !defined(MAP_VISUAL_TILED)
#define VT_USE_TERRAIN_SURFACE_ARRAY
#endif
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
// [surface-array-edge 2026-11-02] 次生生态过渡（secondary biome 混合 + DitherUV 远景过渡）、
// 沟谷 crease、海岸 halo 占比全部改读 surface array 的 layer4/layer5。
// 数据本来就在同一个 native tile bundle 里，所以 8 槽预算不变、烘焙时间不变。
#define VT_USE_EDGE_NEIGHBOR
#define VT_USE_EDGE_DISTANCE
#endif
#if defined(PK_WEB_HORIZON)
#define VT_USE_HORIZON
#endif
#endif
// [B] HIGH 水面独立程序（WATER_ONLY，非 tiled）需要烘焙水深；land-only 程序不拿。
// [surface-array-edge 2026-11-02] 水面也吃同一个 surface array（7→8 槽）：layer4/5 恢复
// edge_mix / shore_frac / 次生水格，水色方块与浅滩因此变连续。不声明 normal/relief/horizon。
#if defined(PK_WEB_WATER_ONLY)
#define VT_USE_WATER_DEPTH
#if !defined(MAP_VISUAL_TILED)
#define VT_USE_EDGE_NEIGHBOR
#define VT_USE_EDGE_DISTANCE
#endif
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
#if defined(PK_WEB_TEXTURE_BUDGET) && !defined(PK_WEB_WATER_ONLY) && !defined(PK_WATER_ONLY) && !defined(MAP_VISUAL_TILED)
#define PK_TERRAIN_MICRO_ARRAY
#define PK_TERRAIN_PACKED_BOUNCE
#endif
// [cell-field 2026-11-18] 解析格界（docs/plans/terrain-hex-mesh-implementation-plan.md）：
// 像素「属于哪几格、各占多少」不再从逐像素索引图读，而由「世界坐标 + 一张连续扭曲场」
// 解析算出（对偶三角 + 重心权重）。开关 PK_CELL_FIELD，**默认关**；关闭时下面两段 do
// 都不定义 ⇒ 预处理产物与今日逐字节一致（截图 diff = 0 是验收项）。
//   VT_USE_CELL_TABLE    —— per-cell 三层表（class/state/aux），一个 sampler 顶掉
//                           map_index_atlas + enum_lut + dyn_lut 三个，净省 2 槽；
//   VT_USE_BOUNDARY_WARP —— 扭曲场（非 tiled 读 terrain_surface_tex layer6）。
// [cell-field-web 2026-11-18] world-min 变体**也要**这两个开关：它与场函数正交
// （只摘掉水面着色源），见文件头那条注释。之前的 `#ifndef PK_WEB_WORLD_MIN`
// 会把 Web LOW 的场函数关掉，现在已删除。
#ifdef PK_CELL_FIELD
#define VT_USE_CELL_TABLE
#if defined(MAP_VISUAL_TILED) || defined(VT_USE_TERRAIN_SURFACE_ARRAY)
#define VT_USE_BOUNDARY_WARP
#endif
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
// [cell-field 2026-11-18] 场函数必须在这之后 include：
//   依赖 terrain_surface_detail 的 terrain_edge_screen_width_px() 与
//   terrain_static_biome_is_water()；依赖 visual_tile_sampling 的 cell_table /
//   visual_sample_boundary_warp。land/water pipeline 都在它之后，故可自由调用。
// 关闭 PK_CELL_FIELD 时整段不 include（文件不存在于预处理产物里）。
// [cell-field-web 2026-11-18] 不再排除 world-min：那个变体也要场函数（见文件头）。
#ifdef PK_CELL_FIELD
#include "res://shaders/include/hex_cell_field.gdshaderinc"
#include "res://shaders/include/terrain_cell_field_detail.gdshaderinc"
#endif
#include "res://shaders/include/tonemap.gdshaderinc"
#ifndef PK_WEB_WORLD_MIN
#include "res://shaders/include/shore_common.gdshaderinc"
#endif
// [baked-surface 2026-11-01] horizon 所有变体统一 include：Web 全档位生成期烘焙，
// PK_WEB_HORIZON 覆盖 MOBILE_QUALITY_LOW 的早退；没有 horizon 采样槽的程序
// （Web 水面）由 include 内部的中性叶子兜底。terrain_horizon_neutral 不再使用。
#include "res://shaders/include/terrain_horizon.gdshaderinc"
#include "res://shaders/include/brdf.gdshaderinc"
#include "res://shaders/include/cloud_shadow.gdshaderinc"
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


#ifdef PK_CELL_FIELD
// ═══════════════════════════════════════════════════════════════════════════
// [cell-field 2026-11-18] PK_CELL_FIELD 下 SETUP 专用的小 helper。
// 只做 ALU、只复用 hex_cell_field 的公开函数，不新增任何采样。
// 关闭开关时整段被预处理剔除 ⇒ 预处理产物与今日逐字节一致。
// （公共场函数与查表 helper 属于 lead 独占的 hex_cell_field.gdshaderinc，这里只放
//  world_map SETUP 自己的三格混合 / 边界判定 / 岸线占比，避免公共文件继续长大。）
// ═══════════════════════════════════════════════════════════════════════════

// 防出洞的岸带宽度（gap 单位，与 pk_cell_field_edge_gap / edge_distance 同一单位）。
// 0.02 = 0.01·hex_size ≈ 0.22 wu，远小于 zoom 6 下的 1 像素；用法见 SETUP 的 is_water。
const float PK_FIELD_SHORE_EPS = 0.02;

// 三格 state（layer1 的四个通道都是连续量）按权重混合。
// hex_cell_field 的 pk_field_blend_channel 只按 class 的单通道选择，state 需要整
// vec4 一起混，所以在这里镜像一份（与 pk_field_blend_channel 逐项同式）。
vec4 pk_field_blend_state(vec3 weights, vec4 s0, vec4 s1, vec4 s2) {
	return s0 * weights.x + s1 * weights.y + s2 * weights.z;
}

// 该 offset 行是否落在真实地图内。row 越界（南北边界之外）的 texel 是 padding
// 哨兵（pk_cell_table_fetch 只把 R 填成 B_SEA_ICE，其余通道为 0），连续量按它混合
// 会得到 0.08 这种假温度/假雪。返回 0/1，供权重遮罩与 dyn_valid 使用。
float pk_field_row_in_bounds(ivec2 c) {
	return step(0.0, float(c.y)) * step(float(c.y), float(pk_cell_map_h - 1));
}

// 解析岸线占比（方案 §3.7）：把「edge_distance.BA 的 8 邻域水 / 湖格占比」换成
// 「对偶三角形三格里水格 / 湖格占的权重」。水判定与 pk_cell_field_is_water_dom 共用
// terrain_static_biome_is_water，所以岸线占比与水陆分支不会各说各话。
// 用 w_raw：岸线占比是连续量（方案 §3.3）。
vec2 pk_cell_field_shore_frac(HexCellField f, vec4 e0, vec4 e1, vec4 e2) {
	int b0 = pk_byte_of(e0.r);
	int b1 = pk_byte_of(e1.r);
	int b2 = pk_byte_of(e2.r);
	float w0 = terrain_static_biome_is_water(b0) ? f.w_raw.x : 0.0;
	float w1 = terrain_static_biome_is_water(b1) ? f.w_raw.y : 0.0;
	float w2 = terrain_static_biome_is_water(b2) ? f.w_raw.z : 0.0;
	float l0 = (b0 == B_LAKE) ? f.w_raw.x : 0.0;
	float l1 = (b1 == B_LAKE) ? f.w_raw.y : 0.0;
	float l2 = (b2 == B_LAKE) ? f.w_raw.z : 0.0;
	return vec2(w0 + w1 + w2, l0 + l1 + l2);
}

// offset (col,row) → 该格中心的世界坐标（pointy-top / odd-r，对 §3.1 的分数 axial
// 做**逆运算**，与 pk_axial_to_offset 是两条独立表达式）：
//   q = col - (row - (row & 1)) / 2,  r = row        （pk_axial_to_offset 的逆）
//   x = √3·s·(q + r/2),              y = 1.5·s·r      （分数 axial 定义的逆）
// 只给 debug 视图 18 的独立复核用：把「重心 argmax」与「世界距离最近」两条路径
// 对撞，任何 offset 换算 / 回绕 / padding 的错都会立刻变红。
vec2 pk_offset_hex_center(ivec2 c) {
	int q = c.x - (c.y - (c.y & 1)) / 2;
	float r = float(c.y);
	return hex_size * vec2(PK_FIELD_SQRT3 * (float(q) + r * 0.5), 1.5 * r);
}

#endif // PK_CELL_FIELD


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
	// [cell-field 2026-11-18] 解析格界：整条 fragment 只算这一次。
	//   1 次 warp 纹理采样 + 一段纯 ALU + 3 次 texelFetch（per-cell 小表，全命中缓存）。
	// 结果以 `HexCellField + 三格 class` 往下传给 land / water pipeline 与静态材质，
	// 下游不再重算（重算等于把 §3.8 的预算翻倍）。
#ifdef PK_CELL_FIELD
	HexCellField cell_field = pk_hex_cell_field_default(v_world);
	vec4 cell_e0 = vec4(0.0);
	vec4 cell_e1 = vec4(0.0);
	vec4 cell_e2 = vec4(0.0);
	pk_cell_field_classes(cell_field, cell_e0, cell_e1, cell_e2);
#endif
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
	// 采样点统一提到分支之前：`terrain_shader_variant_test.gd` 用一次调用点的
	// 出现次数守着"整条 fragment 只采一次 edge_distance"（所以这里连注释都别再写
	// 那个带括号的调用形式）。PK_CELL_FIELD 下仍然要这一次采样（只为 .g 的沟谷 crease）。
	vec2 shore_frac = vec2(0.0);
#ifdef VT_USE_EDGE_DISTANCE
	vec4 edge_px = visual_sample_edge_distance(uv);
#endif
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 三个量拆成两条来源（方案 §3.7）：
	//   scals.r    ← 解析格距 pk_cell_field_edge_gap()。单位与今天的 edge_distance.R
	//                相同（normalized_hex_center_gap），但连续、无纹素台阶；下游
	//                terrain_edge_secondary_weight_d() / 静态材质边缘公式一个字都不用改。
	//   shore_frac ← 解析：三格里水格 / 湖格按 w_raw 累加，不再读 layer4.BA 的 8 邻域统计。
	//   scals.a    —— **保留**读 layer4.G：沟谷 crease 是烘焙连续量，与格界归属无关，
	//                方案 §3.8 明确要求留着（该次采样仍在，只是不再读 .r / .ba）。
	float field_edge_gap = pk_cell_field_edge_gap(cell_field);
	scals.r = field_edge_gap;
#ifdef VT_USE_EDGE_DISTANCE
	scals.a = edge_px.g;
#endif
	shore_frac = pk_cell_field_shore_frac(cell_field, cell_e0, cell_e1, cell_e2);
#else
#ifdef VT_USE_EDGE_DISTANCE
	scals.r = edge_px.r;
	scals.a = edge_px.g;
	shore_frac = edge_px.ba;
#else
	scals.r = 1.0;
#endif
#endif

#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] PK 路径不采逐像素索引图 / enum_lut / dyn_lut，全部改成
	// cell_table 的 texelFetch（无过滤、无导数、全命中缓存）：
	//   biome / veg / cover / landform ← layer0 class（三格已在 SETUP 顶部取好，取主导格）
	//   dyns（temp/wet/snow/vitality|sea_ice）← layer1 state，连续量按 w_raw 三格混合（§3.3）
	//   fog_k ← layer2 aux.R，**只读主导格**（与今天 enum_lut.a 的"硬主 cell"语义逐值一致；
	//           方案 §3.3 把 fog_k 归为类别量，所以不做插值）
	// 采样记账（方案 §3.8，陆地 program）：MID/HIGH = warp 1 + class 3 + state 3 + aux 1
	//   + edge_distance 1（沟谷 crease）+ height 1 + noise 1 + 静态材质 2 = 13；
	//   LOW = warp 1 + class 3 + state 1 + aux 1 + edge 1 + height 1 + noise 1 + 材质 1 = 10。
	//   （LOW 与 MID 的差别只有 state 1↔3 与材质 1↔2；水面 program 的 aux 仍是 3，P3 再算。）
	// _cell_id 仍被 debug 视图引用，但本变体里它的所有消费点都已换成场函数 ⇒ 固定 -1
	// （保留定义是为了不改下游函数原型，顺带让 cell_lut_uv() 的 LUT 读取自然退化）。
	int _cell_id = -1;
	ivec2 field_dom_c = pk_cell_field_dom_offset(cell_field);
	// padding 行（南北边界之外）没有真实格：先把它们的权重清零，再在真实格之间重新
	// 归一。三格全越界时退回原始 w_raw —— 那个像素本来就在地图外，dyn_valid / fog_k
	// 会走与今天 cid < 0 一致的分支。
	float field_inb0 = pk_field_row_in_bounds(cell_field.c0);
	float field_inb1 = pk_field_row_in_bounds(cell_field.c1);
	float field_inb2 = pk_field_row_in_bounds(cell_field.c2);
	vec3 field_w_valid = cell_field.w_raw * vec3(field_inb0, field_inb1, field_inb2);
	float field_valid = field_w_valid.x + field_w_valid.y + field_w_valid.z;
#if defined(PK_QUALITY_LOW)
	// LOW 档（方案 §3.8 的 state 1 预算）：只读主导格 1 个 texel，不混合。
	vec4 dyns = pk_cell_state_at(field_dom_c);
#else
	// MID/HIGH 档：state 三格按 w_raw 混合（连续量，格界处不再有雪线/海冰硬台阶）。
	// 权重在真实格之间重新归一，padding 格的哨兵 state 不会混进来。
	vec3 field_w = (field_valid > 1e-5)
			? field_w_valid / field_valid : cell_field.w_raw;
	vec4 dyns = pk_field_blend_state(field_w,
			pk_cell_state_at(cell_field.c0),
			pk_cell_state_at(cell_field.c1),
			pk_cell_state_at(cell_field.c2));
#endif
	// fog_k：1 次 texelFetch（主导格 aux.R）。padding 行的 aux 是哨兵（只有 R 被填成
	// B_SEA_ICE），按今天 cid < 0 的口径取 1.0（padding 视作全知，迷雾层自己会盖住）。
	float field_fog = mix(1.0, pk_cell_aux_at(field_dom_c).r,
			pk_field_row_in_bounds(field_dom_c));
#else
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
#endif

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
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 类别三元组取**主导格**的 layer0（pk_field_class_of），
	// 语义等价于今天 enum_lut[主 cell]。padding 行由 pk_cell_table_fetch 的哨兵给出
	// B_SEA_ICE / 0 / 0，与今天 cid < 0 的三个赋值逐值一致。
	// fog_k 直接取主导格 layer2.R（上面的 field_fog，1 次 texelFetch）：与今天
	// enum_lut[主 cell].a 的语义逐值一致（方案 §3.3 把 fog_k 归为类别量，不插值）；
	// 移动端那条 DitherUV 次生选格整段编译掉（方案 §3.6）。
	vec4 field_cls_dom = pk_field_class_of(cell_field, cell_e0, cell_e1, cell_e2);
	biome = pk_byte_of(field_cls_dom.r);
	veg = pk_byte_of(field_cls_dom.g);
	cover = pk_byte_of(field_cls_dom.b);
	fog_k = field_fog;
#else
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
#endif
	// [landform 轴可视化 2026-06-25] landform id 走 map_index_atlas.A（per-pixel, NEAREST），
	// 供陆地管线给火山/高原/峡谷/裂谷/高峰补充专属着色。地图外哨兵采样得 0（=DEEP_OCEAN，陆地分支不消费）。
	// [cell-field 2026-11-18] PK 变体改读主导格 layer0.A（padding 哨兵 A=0，与 map_index 的
	// 地图外哨兵同值）。
#ifdef PK_CELL_FIELD
	int landform = pk_byte_of(field_cls_dom.a);
#else
	int landform = int(map_px.a * 255.0 + 0.5);
#endif
	float moist = dyns.g;
	// [cell-field-web 2026-11-18] lat_norm 的归一化分母不再借 map_index 纹理的尺寸：
	// `visual_static_texture_size()` 在非 tiled 下就是 `textureSize(map_index_atlas, 0)`，
	// 而 map_index_atlas 在该组合下整张退役。改用 derived_resolution —— 二者**逐值相等**：
	//   非 tiled：derived_resolution ← world.derived_size（renderer_material_publish.gd:404-405），
	//             而 map_index_atlas = world.enum_atlas_tex 正是按 world.derived_size 生成
	//             （map_baker.gd:774 `world.derived_size = world.hm_size`、:916-918），
	//             `textureSize()` 取回的又是整数像素尺寸 ⇒ 同一个数。
	//   tiled：  derived_resolution ← visual_tiles.layout.logical_size（同文件 :404-409），
	//             `visual_static_texture_size()` 也返回 visual_logical_resolution，
	//             同样由 renderer_terrain_horizon.gd:750 推自 layout.logical_size。
#ifdef PK_CELL_FIELD_NO_LEGACY_LUT
	float _Hf = derived_resolution.y;
#else
	float _Hf = visual_static_texture_size().y;
#endif
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
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] dyn_valid = 「三格里真实格占的权重过半」。与今天
	// cid < 0 ⇒ 0 的硬判定语义相同（padding 格的 state 权重已被清零），但在南北
	// 边界一格之内是渐变的，不会再出现整块"温度=0 冷边"。
	float dyn_valid = step(0.5, field_valid);
#else
	float dyn_valid = (_cell_id < 0) ? 0.0 : 1.0;
#endif
	moist = mix(moist, dyn_wet, dyn_valid);
	// flow + river_edge_warp 仅在陆地的 river 分支才用，这里推迟到 _if (!is_water)_ 计算，
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 水陆判定（方案 §3.7）：陆地与水面两个 program 调用
	// **同一个**函数、读同一份数据 ⇒ 海岸线就是 dom 在水 / 陆之间切换的那条弯曲等值线。
	bool is_water = pk_cell_field_is_water_dom(cell_field, cell_e0, cell_e1, cell_e2);
#ifdef PK_LAND_ONLY
	// 防出洞（方案 §3.7）：两个 program 分别编译，同一表达式在恰好落在等值线上的
	// 像素上可能给出不同结果（一边 discard、另一边也 discard ⇒ 1 px 洞）。规则是
	// 「画在**下层**的 program 放宽 ε，上层严格」，宁可重叠不许出洞。
	//
	// 哪边是下层（绘制顺序证据）：
	//   renderer_scene_services.gd:91-94 建 _world_quad（陆地 program，z_index=0）；
	//   renderer_shader_water.gd:687-696 把 _water_quad 的 z_index 也设为 0，再
	//   move_child 到 _world_quad.get_index() + 1，注释原文「水面盖住陆地」。
	// ⇒ **陆地是下层、水面是上层**，所以放宽 ε 的是陆地 program：岸带（gap < ε）内
	//   即使 dom 判成水也照常画陆地色；正常像素仍由上层水面 program 覆盖，只有那个
	//   1 px 争议带会退化成陆地色而不是一个洞。
	is_water = is_water && (field_edge_gap >= PK_FIELD_SHORE_EPS);
#endif
#else
	bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);
#endif
	vec2 ocean_current_v = vec2(0.0);
	vec2 wind_v = vec2(0.0);
#if !defined(PK_LAND_ONLY) && (!defined(PK_WEB_TEXTURE_BUDGET) || defined(PK_WEB_WATER_ONLY))
	if (is_water && ocean_current_enabled && ocean_current_flow_tex_bound) {
		ocean_current_v = textureLod(ocean_current_flow_tex, uv, 2.0).rg * 2.0 - 1.0;
	}
#endif
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
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 门控阶段选格（方案 §3.6）：不再用 DitherUV 在主 / 副之间
	// 二选一（那是 Bayer 网点，近景 `terrain_land_dither_zoom_strength()` 归零后退化成
	// 硬主 id ⇒ 纹素台阶），改为在**每格世界锚定的抖动量**上做 argmax：近景碎边、远景
	// 退化成 argmax(w) 的弯曲硬边。整段不再读 terrain_mobile_dither_uv_threshold /
	// terrain_land_dither_zoom_strength / decode_edge_secondary_index / enum_lut。
	// 门控不能把水格配色带进陆地像素（方案 §3.7「颜色不跨水陆」）：胜者若是水格，
	// 退回主导格三元组 —— 与今天 land_secondary 的水格守卫同义。
	if (!is_water) {
		ivec3 field_gate = pk_cell_field_gate_class(
				cell_field, cell_e0, cell_e1, cell_e2, pixel_noise);
		int field_gate_water = terrain_static_biome_is_water(field_gate.x) ? 1 : 0;
		visual_land_biome = (field_gate_water == 1) ? biome : field_gate.x;
		visual_land_veg = (field_gate_water == 1) ? veg : field_gate.y;
		visual_land_cover = (field_gate_water == 1) ? cover : field_gate.z;
	}
#else
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
#endif
	// Water keeps hard primary ownership, but MID/HIGH pass the secondary static
	// material and a continuous distance-field weight into one water evaluation.
	// LOW compiles this lookup out entirely. Dynamic state remains primary-owned.
	int water_secondary_biome = biome;
	int water_secondary_cover = cover;
	float water_static_edge_mix = 0.0;
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 海冰比例：layer1.A 按 w_raw 三格混合（连续量，冰缘不再
	// 沿格界硬切）。dyns 在 PK 下就是三格 state 的 w_raw 混合；padding 像素 dyn_valid=0
	// ⇒ 与今天 cid < 0 取 1.0（整片海冰）一致。
	float visual_water_ice_fraction = mix(1.0, dyns.a, dyn_valid);
#else
	float visual_water_ice_fraction = (_cell_id < 0) ? 1.0 : dyns.a;
#endif
#if !defined(PK_QUALITY_LOW)
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 次生水格 = 权重第二的那一格（pk_cell_field_rank(f, 1)），
	// 混合权重就是它的 w_raw。今天的 water_edge_w 是距离场导出的连续量，这里换成同一
	// 语义的连续量；候选仍必须是水格（与今天 candidate_biome 的守卫同义）。
	{
		vec4 field_rank1_cls = pk_cell_field_ranked_class(cell_field, 1, cell_e0, cell_e1, cell_e2);
		int field_rank1_biome = pk_byte_of(field_rank1_cls.r);
		bool field_second_ok = is_water && terrain_static_biome_is_water(field_rank1_biome);
		water_secondary_biome = field_second_ok ? field_rank1_biome : water_secondary_biome;
		water_secondary_cover = field_second_ok ? pk_byte_of(field_rank1_cls.b) : water_secondary_cover;
		water_static_edge_mix = field_second_ok
				? pk_cell_field_ranked_weight_raw(cell_field, 1) : 0.0;
	}
#else
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
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 「三格均未探索」才早退，但**不额外采 aux**：
	// edge_gap ≥ PK_FIELD_BAND_MAX ⇒ 邻格权重为 0，这个像素既不在任何格界带里，也没有
	// 邻居能在视觉上渗进来 —— 主导格未探索就等于整块未探索；反过来，整条过渡带
	// （edge_gap < 带宽）永远不早退，正是「三格里至少有一格已探索」原本要保护的性质。
	// fog_k 本身是主导格 aux.R 的 1 次 texelFetch（见 SETUP），LOW 档与今天逐值等价。
	bool fog_hidden = fog_early_out_enabled
			&& (fog_k <= fog_early_out_k)
			&& (field_edge_gap >= PK_FIELD_BAND_MAX);
#else
	bool fog_hidden = fog_early_out_enabled && (fog_k <= fog_early_out_k);
#endif
	if (fog_hidden) {
		COLOR = vec4(fog_unexplored_color, 1.0);
	} else {
		if (!is_water) {
#if !defined(PK_PROBE_NO_LAND) && !defined(PK_WATER_ONLY)
			col = render_land_pipeline(
				visual_land_biome, biome, visual_land_veg, visual_land_cover, landform,
				elev, moist, wp, uv, scals, lat_signed, current_temp,
				wind_v, dyn_snow, dyn_valid, dyn_vitality, pixel_noise, shore_frac
#ifdef PK_CELL_FIELD
				, cell_field, cell_e0, cell_e1, cell_e2
#endif
				);
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
				visual_water_ice_fraction, shore_frac, pixel_noise
#ifdef PK_CELL_FIELD
				, cell_field, cell_e0, cell_e1, cell_e2
#endif
				);
#endif
#else
			col = vec3(0.1, 0.2, 0.4);     // PROBE: water pipeline removed
#endif
		}
		int visual_surface_cover = is_water ? cover : visual_land_cover;
		int visual_surface_veg = is_water ? veg : visual_land_veg;

		// 已探索但当前不可见 → "褪色的记忆"，不是"压暗的脏块"。
		// k=0.5 处最强，k=1 归零。零新增采样，只是几条 ALU。
		//
		// [fog-memory-wash 2026-11-17] 原来是 `mix(col, 灰, amt) * 0.82`：整体压暗 18%
		// 再全去饱和。深色海面上这直接变成一圈近黑的脏环，而且把地形烘焙的块状边缘
		// 一起放大 —— 真机"迷雾很丑"的观感有一半来自这里（关掉迷雾那一帧的同区域
		// 是明亮的浅海）。记忆层应该是**提亮+褪色**：往纸色靠，明度不低于原图，
		// 顺便把块状边缘糊掉，和手绘纸本的底子也更搭。
		if (fog_gray_enabled) {
			float gray_amt = (1.0 - smoothstep(0.5, 1.0, fog_k)) * fog_gray_strength;
			float mem_l = dot(col, vec3(0.299, 0.587, 0.114));
			// 去饱和后的中性灰，稍微偏暖（纸），再向纸色提一档。
			vec3 memory = vec3(mem_l) * vec3(1.02, 1.00, 0.96);
			memory = mix(memory, vec3(0.88, 0.86, 0.82), 0.22);
			// 暗部抬得比亮部多：海面/山影不再塌成黑块，亮部基本不动。
			memory = max(memory, vec3(mem_l) * 0.86 + 0.10);
			col = mix(col, memory, gray_amt);
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
#ifdef PK_CELL_FIELD
		// ── [cell-field 2026-11-18] 18–21：解析格界的四档诊断（方案 §5 P1 完成判据）。
		// 都只在 PK_CELL_FIELD 变体里存在（需要场函数），除 18/21 各多一次扭曲场采样
		// 之外没有新增采样，且都在 uniform 分支（terrain_surface_debug_view）内。
		} else if (terrain_surface_debug_view == 18) {
			// 18 = dom 一致性（tools/cell_field_gpu_probe.gd 读这一档）：绿 = 一致，红 = 不一致。
			//   用**两条独立路径**复算归属并对撞：
			//     A（场函数）：对偶三角形重心 argmax ⇒ dom；
			//     B（本档）：把三格的 offset 反解成 hex 中心（offset→axial→世界坐标，
			//       即 pk_axial_to_offset 与分数 axial 的逆运算），取像素到三个中心的
			//       欧氏距离最近者。
			//   两条路径的中间步骤完全不同（重心 vs offset 换算 + 世界距离），所以这一档
			//   能抓到 pk_axial_to_offset / pk_posmod 回绕 / padding 判定的错 —— 正是与
			//   CPU cube_round 做 parity 时最容易漂的那一层。格界带上可红可绿（亚像素 +
			//   平局次序），其余区域必须全绿。
			//   本变体**不读**索引图（契约 §6 的 grep 断言）；「dom vs 烘焙 cell id」的
			//   另一半由 CPU 侧的 hex_cell_field_parity_test.gd 守着：GPU 这半证明 shader
			//   场函数自洽，CPU 那半证明镜像 == 烘焙索引。
			vec2 field_pw = wrap_world_pos(wp + pk_boundary_warp_world(wp));
			vec2 field_ctr0 = pk_offset_hex_center(cell_field.c0);
			vec2 field_ctr1 = pk_offset_hex_center(cell_field.c1);
			vec2 field_ctr2 = pk_offset_hex_center(cell_field.c2);
			// offset col 已被 posmod 到 [0, map_w)，而 pw.x 是回绕后的世界坐标（可能为负），
			// 所以按 wrap_period_x 把中心平移回离像素最近的那一份；只有真正回绕时才做。
			if (wrap_period_x > 0.0001) {
				field_ctr0.x += wrap_period_x * round((field_pw.x - field_ctr0.x) / wrap_period_x);
				field_ctr1.x += wrap_period_x * round((field_pw.x - field_ctr1.x) / wrap_period_x);
				field_ctr2.x += wrap_period_x * round((field_pw.x - field_ctr2.x) / wrap_period_x);
			}
			float field_dd0 = length(field_pw - field_ctr0);
			float field_dd1 = length(field_pw - field_ctr1);
			float field_dd2 = length(field_pw - field_ctr2);
			int field_nearest = (field_dd0 <= field_dd1 && field_dd0 <= field_dd2) ? 0
					: ((field_dd1 <= field_dd2) ? 1 : 2);
			COLOR = vec4((field_nearest == cell_field.dom)
					? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0), 1.0);
		} else if (terrain_surface_debug_view == 19) {
			// 19 = 三格锐化权重 w 直接当 RGB（R=c0 G=c1 B=c2）。三格交汇处应是三色
			// 平滑过渡；出现黑线/白线说明 w 的归一化或 band 有问题（方案 §3.2 接缝）。
			COLOR = vec4(cell_field.w, 1.0);
		} else if (terrain_surface_debug_view == 20) {
			// 20 = 解析格距 vs 烘焙 edge_distance.R 的差值（契约 §6：gap < 0.86 区间内
			// |Δ| < 0.02）。灰阶 = |Δ|×25（0.02 → 0.5 亮度），|Δ| > 0.04 直接标红。
			// 全黑 = 两条数据源一致；整屏红 = 单位或坐标口径错（例如把 world 单位当 gap，
			// 或 warp 没生效）。scals.r 在 PK 下就是 pk_cell_field_edge_gap()。
			// 复用 SETUP 那一次 edge_distance 采样（不新增采样点）。
#ifdef VT_USE_EDGE_DISTANCE
			float field_gap_err = abs(edge_px.r - scals.r);
			vec3 field_gap_col = vec3(clamp(field_gap_err * 25.0, 0.0, 1.0));
			if (field_gap_err > 0.04) { field_gap_col = vec3(1.0, 0.0, 0.0); }
#else
			vec3 field_gap_col = vec3(scals.r);
#endif
			COLOR = vec4(field_gap_col, 1.0);
		} else if (terrain_surface_debug_view == 21) {
			// 21 = 扭曲场可视化：pk_boundary_warp_world(wp) 归一到 [-1,1] 后映射到 [0,1]
			// 打 RG（0.5 = 无扭曲）。整屏死灰 = layer6 / tiled warp tile 没绑
			// （terrain_warp_layer_bound=false），此时格界退化成直边六边形但归属仍正确。
			// 本档多一次扭曲场采样（场函数初始化已经采过一次）。
			vec2 field_warp_vis = pk_boundary_warp_world(wp)
					/ max(hex_size * terrain_warp_amp * terrain_warp_range, 1e-4);
			COLOR = vec4(field_warp_vis * 0.5 + 0.5, 0.0, 1.0);
		} else if (terrain_surface_debug_view == 22) {
			// 22 = dom 格的 offset 编码 —— **GPU ↔ CPU 逐像素回读比对专用**
			//   （tests/world/cell_field_gpu_parity_probe.gd 解码后与
			//     DCHexCellField.dom_at() 逐像素对撞；这是唯一能证明"GPU 与 CPU 用的是
			//     同一个坐标系"的通道，见 review 2026-11-18「没有任何测试验证 GPU 和
			//     CPU 用的是同一个坐标系」）。
			//   R,G = col 的低 / 高字节，B = row 的低字节，每个通道 byte/255。
			//   A = **常量 1.0**。
			// 为什么 A 不放 row 的高字节：本程序是 `render_mode blend_mix`（第 8 行），
			// 片元 alpha = 0 时 MIX 的 `dst = src.rgb·src.a + dst·(1−src.a)` 会把 rgb
			// 一起乘成 0，回读就是一片清屏色（实测：整个视图等于 viewport 的 clear
			// color，且与"什么都没画"无法区分）—— 编码必须让 alpha 非 0 才可回读。
			// row ∈ [0, 255) 时高字节本来就是 0，所以本视图对 col ∈ [0, 4095]、
			// row ∈ [0, 255] **仍然是无损的**；row 越界（padding 行 / 超 255）时高位
			// 会被截断，仅供目视诊断，不要拿它做数值比对。
			// 零新增采样：pk_cell_field_dom_offset 只复用 SETUP 已算好的场。
			ivec2 field_enc_c = pk_cell_field_dom_offset(cell_field);
			COLOR = vec4(
					float(field_enc_c.x & 255) / 255.0,
					float((field_enc_c.x >> 8) & 255) / 255.0,
					float(field_enc_c.y & 255) / 255.0,
					1.0);
		} else if (terrain_surface_debug_view == 23) {
			// 23 = **实际使用**的锐化带宽 band（灰阶 = band / PK_FIELD_BAND_MAX）。
			//   band = clamp(max(terrain_ecotone_width, AA 项), 1e-4, 0.86)，
			//   AA 项 = 2/hex_size · max(|fwidth(v_world)|) · terrain_edge_screen_width_px()。
			// 全图均匀灰 = AA 项主导且没有导数爆点；**经线接缝那一列整列变白（= 1.0）
			// 说明导数取在了已回绕坐标上**——review 2026-11-18 第 1 条的病征。
			// 本档是那条 bug 的回归信号：terrain_ecotone_width 调到足够小后，
			// max(band) 应该只剩 AA 项的量级（探针 Pass C 断言 < 0.10）。
			// 零新增采样（band 是场函数里已经算出来的局部量，只是额外存进 struct）。
			COLOR = vec4(vec3(cell_field.band / PK_FIELD_BAND_MAX), 1.0);
#endif // PK_CELL_FIELD
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
