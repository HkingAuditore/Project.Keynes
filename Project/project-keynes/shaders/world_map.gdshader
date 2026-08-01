shader_type canvas_item;
render_mode blend_mix;

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
// ═══════════════════════════════════════════════════════════════════════════
// 本文件 2026-05-19 由 2299 行单文件拆分为 1 个主 shader + 多个 .gdshaderinc：
//   uniforms / common_noise / height / climate_season / biome_color / vegetation /
//   weather_front / snow_cover / biome_detail / hillshade_tod / water / land_pipeline /
//   water_pipeline / global_adjustments  —— 详见 shaders/include/。
//
// 主文件仅保留：shader_type、render_mode、按拓扑顺序的 #include、vertex()、
// fragment()（SETUP 解码 → LAND/SEA 分支调度 → GLOBAL 输出）。具体算法均下沉到 include。
// 通道语义快速参考（详细请见 uniforms.gdshaderinc）：
//   height_tex (RG8 LINEAR)        归一化海拔 [0,1]，解码 (R*256 + G)/257
//   terrain_horizon_tex (RGBA8)    8 方向 horizon angle，high/low nibble packed
//   map_index_atlas (RGBA8 NEAREST) R=biome  GB=cell.index
//   enum/dyn/eco LUT:
//                                   per-cell enum / dynamic / ecology visual state
// ═══════════════════════════════════════════════════════════════════════════

// ─── Include 拓扑顺序（不可随意调整） ─────────────────────────────────────
//   uniforms       叶子，零依赖，必须最先。
//   material_constants 叶子（仅依赖 uniforms 中的 visual_quality 等）；集中常量、F0、特性开关。
//   common_noise   叶子，依赖 uniforms.noise_tex / NOISE_TEX_SCALE。
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
//   hillshade_tod  依赖 uniforms.height_tex / hillshade_* / tod_* / B_* + height.decode_height_rg8 + earth_daylight。
//   water          依赖 common_noise.* + uniforms.map_index_atlas / B_LAKE/B_REEF/B_KELP/B_SEA_ICE。
//   surface_params 半 PBR Stylized 参数结构（base_color/normal/roughness/metallic/ao/emission/alpha）。
//   tonemap        依赖 material_constants：srgb↔linear、ACES filmic、Reinhard legacy。
//   shore_common   依赖 uniforms + material_constants：sample_shore_neighborhood / compute_shore_halo。
//   terrain_horizon 依赖 uniforms.wrap_map_uv + visual_tile_sampling：解码 8 方向 horizon angle，
//                  一次 4-tap 采样同时给出 direct shadow、天空可见度(AO) 与 bent normal。
//   brdf           依赖 surface_params + material_constants + tonemap + terrain_horizon
//                  + cell_indirect（弹射项要按遮挡源 cell id 查 bounce_lut）：
//                  Cook-Torrance / Blinn-Phong fallback。
//   land/water/global pipelines  最后 include，封装 fragment 的陆地/水面/全局调度算法。

// ─────────────────────────────────────────────────────────────────────────
#include "res://shaders/include/shader_quality.gdshaderinc"
#include "res://shaders/include/uniforms.gdshaderinc"
#define VT_USE_HEIGHT
#define VT_USE_TERRAIN_NORMAL
#define VT_USE_HORIZON
#define VT_USE_GI_OCCLUDER
#define VT_USE_MAP_INDEX
#define VT_USE_FLOW
#define VT_USE_WATER_DEPTH
#define VT_USE_TERRAIN_DETAIL
#define VT_USE_EDGE_NEIGHBOR
#define VT_USE_EDGE_DISTANCE
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
#include "res://shaders/include/earth_daylight.gdshaderinc"
#include "res://shaders/include/material_constants.gdshaderinc"
#include "res://shaders/include/cell_indirect.gdshaderinc"
#include "res://shaders/include/common_noise.gdshaderinc"
#include "res://shaders/include/height.gdshaderinc"
#include "res://shaders/include/climate_season.gdshaderinc"
#include "res://shaders/include/biome_color.gdshaderinc"
#include "res://shaders/include/vegetation.gdshaderinc"
#include "res://shaders/include/weather_front.gdshaderinc"
#include "res://shaders/include/snow_cover.gdshaderinc"
#include "res://shaders/include/biome_detail.gdshaderinc"
#include "res://shaders/include/hillshade_tod.gdshaderinc"
#include "res://shaders/include/water.gdshaderinc"
#include "res://shaders/include/surface_params.gdshaderinc"
#include "res://shaders/include/terrain_surface_detail.gdshaderinc"
#include "res://shaders/include/tonemap.gdshaderinc"
#include "res://shaders/include/shore_common.gdshaderinc"
#include "res://shaders/include/terrain_horizon.gdshaderinc"
#include "res://shaders/include/brdf.gdshaderinc"
#include "res://shaders/include/land_pipeline.gdshaderinc"
#include "res://shaders/include/water_pipeline.gdshaderinc"

#include "res://shaders/include/global_adjustments.gdshaderinc"


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
	// 60 FPS 优化（2026-06-18）：scalar/vector 和 per-pixel dynamic atlas 已退役。
#ifdef PK_SKIP_PIXEL_NOISE
	vec4 pixel_noise = vec4(0.5);  // 中性灰值，不调 fbm 也不影响
#else
	vec4 pixel_noise = texture(noise_tex, (wp * 0.071 + vec2(19.0, -23.0)) / NOISE_TEX_SCALE);
	if ((pixel_noise.g + pixel_noise.b) <= 0.0001 && pixel_noise.a >= 0.98) {
		pixel_noise = derive_independent_noise4(wp * 0.071 + vec2(19.0, -23.0));
	}
#endif

	float elev = decode_height_rg8(uv);

	vec4 scals = vec4(0.0);  // scalar_atlas 退役：moist/lat 由 LUT/uv 重建。
	// [river-render-restore 2026-06-19] flow 通道单独从 flow_tex 重建（河流 SDF）。
	// 未绑定纹理时 texture() 返回 0 → 无河，安全。land/water pipeline 读 scals.g 画河网。
	// 低画质仍要保留静态河网；昂贵的河流动效/坡向流纹已在 land_pipeline 里按质量档裁掉。
	scals.g = visual_sample_flow(uv).r;
	vec4 vects = vec4(0.5);  // vector_atlas 退役：洋流/风视觉取中性零向量。

	// dyn_lut.a 与旧 dyn_atlas_smooth.a 同语义（水格=sea_ice_frac，陆格=vegetation_vitality）。
	// [dither-index 2026-06-25] 全档位 NEAREST：cell 索引边缘融合（烘焙期 Bayer dither）已在
	// 索引层软化离散硬边，无需再对 dyn/eco LUT 做跨格 4-tap 双线性。
	vec4 dyns = dyn_lut_nearest(uv);
	// Mobile 三档全跳 ecology（eco_valid=0 等同 dynamic 路径）
#if defined(MOBILE_QUALITY_LOW) || defined(MOBILE_QUALITY_MID) || defined(MOBILE_QUALITY_HIGH)
	vec4 ecos = vec4(0.0);  // foliage=0 → eco_valid=0，下游路径直接走 dynamic
#else
	vec4 ecos = eco_lut_nearest(uv);
#endif

	// enum 通道（biome/veg/cover）走 cell 索引图 + enum_lut。
	// cid<0 是极地外侧的不可交互 padding。玩家地图把它表现为海冰，既明确世界边界，
	// 也避免无归属区域看起来像可点击海洋；模拟与选格仍只认真实 cell id。
	int biome;
	int veg;
	int cover;
	int _cell_id = decode_cell_index(uv);
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
		float fog_edge_w = terrain_edge_secondary_weight(uv, wp);
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
	int landform = int(visual_sample_map_index(uv).a * 255.0 + 0.5);
	float moist = dyns.g;
	float _Hf = visual_static_texture_size().y;
	float lat_norm = clamp((uv.y * _Hf - 0.5) / max(_Hf - 1.0, 1.0), 0.0, 1.0);
	float dyn_temp = dyns.r;
	float dyn_wet = dyns.g;
	float dyn_snow = dyns.b;
	float dyn_vitality = dyns.a;
	float eco_foliage = ecos.r;
	float eco_stress = ecos.g;
	float eco_transition = ecos.b;
	float eco_growth = ecos.a;
	float eco_valid = step(0.01, eco_foliage + eco_stress + eco_transition);
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
	// The static base color already uses continuous edge blending, but later
	// climate/vegetation/cover stages are biome-gated. Feed those stages a
	// DitherUV-selected visual biome as well, otherwise they redraw the hard
	// primary-cell silhouette after the distance-field blend.
	int visual_land_biome = biome;
	int visual_land_veg = veg;
	int visual_land_cover = cover;
	if (!is_water && _cell_id >= 0 && has_terrain_edge_data) {
		float land_edge_w = terrain_edge_secondary_weight(uv, wp);
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
	// Ocean visual ownership deliberately combines the broad distance field with
	// DitherUV on every platform. It only selects between two water cells; the
	// primary cell still owns topology, interaction, simulation and the branch.
	int visual_water_biome = biome;
	int visual_water_cover = cover;
	float visual_water_ice_fraction = (_cell_id < 0) ? 1.0 : dyns.a;
	if (is_water && _cell_id >= 0 && has_terrain_edge_data) {
		float water_edge_w = terrain_edge_secondary_weight(uv, wp);
		if (water_edge_w > 0.0001
				&& terrain_mobile_dither_uv_threshold(uv, wp) < water_edge_w) {
			int water_secondary_id = decode_edge_secondary_index(uv);
			if (water_secondary_id >= 0) {
				vec4 water_secondary_enum = texture(enum_lut, cell_lut_uv(water_secondary_id));
				int water_secondary_biome = int(water_secondary_enum.r * 255.0 + 0.5);
				if (terrain_static_biome_is_water(water_secondary_biome)) {
					visual_water_biome = water_secondary_biome;
					visual_water_cover = int(water_secondary_enum.b * 255.0 + 0.5);
				}
			}
		}
	}

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
			col = render_land_pipeline(
				visual_land_biome, visual_land_veg, visual_land_cover, landform,
				elev, moist, wp, uv, scals, lat_signed, current_temp,
				wind_v, dyn_snow, dyn_valid, dyn_vitality, eco_foliage, eco_stress,
				eco_transition, eco_growth, eco_valid, pixel_noise);
		} else {
			col = render_water_pipeline(
				visual_water_biome, visual_water_cover, elev, wp, uv, scals,
				lat_signed, current_temp, ocean_current_v, wind_v,
				visual_water_ice_fraction);
		}
		int visual_surface_cover = is_water ? visual_water_cover : visual_land_cover;
		int visual_surface_veg = is_water ? veg : visual_land_veg;

		// 已探索但当前不可见 → 去饱和 + 压暗。k=0.5 处最灰，k=1 归零。
		// 零新增采样，只是几条 ALU。
		if (fog_gray_enabled) {
			float gray_amt = (1.0 - smoothstep(0.5, 1.0, fog_k)) * fog_gray_strength;
			col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))) * 0.82, gray_amt);
		}

		// 保留旧 11 参数 ABI，避免 ShaderInclude 热缓存与主 shader 热重载不同步。
		// 气候参数仅用于接口兼容，global_adjustments 内不再消费它们。
		if (terrain_surface_debug_view > 0) {
			COLOR = vec4(terrain_surface_debug_color(uv, wp, _cell_id), 1.0);
		} else {
			COLOR = apply_global_adjustments(
				col, wp, pixel_noise, dyn_snow, current_temp, moist, dyn_vitality, dyn_valid,
				visual_surface_cover, is_water ? 0.0 : 1.0,
				visual_surface_veg == V_NONE ? 0.0 : 1.0);
		}
	}
}
