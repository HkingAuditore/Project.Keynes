// uniforms.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：world_map.gdshader 的全部 uniform / 常量 / varying 声明集中地。
//        所有"shader 的输入"都在本文件，shader 的"输出"分散在各个 helper include。
// 调用方：world_map.gdshader（主 shader）必须最早 include 本文件。
//         所有 helper include（biome_color / vegetation / weather_front / ...）
//         都假设本文件的 uniform/常量已经在 caller-scope 中可见。
// 依赖：无（叶子模块）。
// 兼容铁律：
//   - 本文件所有 uniform 的【名称 / 类型 / hint 修饰（hint_range / source_color /
//     filter_* / repeat_* / hint_default_black）/ 默认值】对 GDScript 端
//     set_shader_parameter("...") 与 world_map_material.tres 必须 100% 保持不变。
//   - 所有 B_* / V_* / CV_* / WT_* 常量名与数值不可改动（CPU 端 enum 与之对齐）。
//   - MAX_WEATHER_FRONTS=16 不可改（CPU 端会照此大小裁剪 weather_front_* 数组）。
// 性能（PERF）：无。本文件只声明，运行时无开销。
// ─────────────────────────────────────────────────────────────────────────


// =========================================================================
// 【纹理输入组】
// =========================================================================
// world_map.gdshader v9.atlas：高分辨率地理仿真渲染
//   height_tex       (RG8 16-bit, hm_size, LINEAR)
//                     归一化海拔 [0, 1]，解码 (R*256 + G) / 257
//   map_index_atlas  (RGBA8, derived_size, NEAREST)
//                     R = biome id
//                     G/B = cell.index low/high byte
//                     A = reserved
// scalar/vector 与旧 dynamic/smooth/ecology per-pixel atlas 已退役：
// moisture/temp/snow/ice/eco 改由 per-cell LUT 提供，flow/风场视觉退化为中性值。
uniform sampler2D height_tex : filter_linear, repeat_disable;
// [terrain-normal-bake 2026-06-25] 生成期烘焙的"总体地形法线"（RG8: nx,ny ∈ [0,1] 映射 [-1,1]，
// nz 在 shader 重建）。地形静态 → 运行期 1 次采样拿宏观山脉走向，替代每帧宽半径 4-tap。
// terrain_normal_tex_bound=false（未烘焙/旧存档）时 compute_terrain_normal 回退到运行期宽半径差分。
uniform sampler2D terrain_normal_tex : filter_linear, repeat_disable;
uniform bool terrain_normal_tex_bound = false;
uniform sampler2D map_index_atlas : filter_nearest, repeat_disable;
// [river-render-restore 2026-06-19] 河流 SDF（L8, derived_size）：R = 河流强度 [0,1]，
// 1=河心、0=远离河道。scalar_atlas 退役后单独用这张轻量纹理把河网视觉接回（见 land_pipeline
// 的 flow）。未绑定时采样得 0（无河），安全降级。
uniform sampler2D flow_tex : filter_linear, repeat_disable;
// [water-depth-tex 2026-06-26] 海/湖统一归一水深（R8, derived_size）：R = 水深 [0,1]，0=岸/陆、
// 1=最深。C++ 生成期算好 per-cell（海洋 1-E/sea + 湖泊湖岸→湖心碗形），bake 经 pixel_to_cell_index
// 扇出。water_pipeline 用它做深浅着色，单次采样取代旧"海洋 5×5 height 邻域 + 湖泊 16× biome 多半径"。
// has_water_depth_tex=false（未烘焙/旧存档/fused 失败）时回退旧逐邻域估算。
uniform sampler2D water_depth_tex : filter_linear, repeat_disable;
uniform bool has_water_depth_tex = false;
// map-visual-overhaul-v1：weather_field_tex 已从主地图 shader 完全移除。
// 海面天气视觉（storm/rain/cloud_field）现在全部由 weather_overlay.gdshader 的
// 三层独立云（cirrus/cumulus/fog）承担——主地图保持"清爽地表"，不画云。
// 历史 uniform：weather_field_tex / weather_field_ocean_enabled /
//               weather_field_ocean_strength （已删除）。
// v10.noise-pack：共享 noise 贴图（256×256 RGBA8 tileable，由 MapBaker 烘焙）。
// R=raw value_noise，G/B/A=2/3/4 octave fBM 预积分；fbm(p,N) 全局降为 1 次采样。
uniform sampler2D noise_tex    : filter_linear_mipmap, repeat_enable;
const float NOISE_TEX_SCALE = 256.0;

// =========================================================================
// 【Cell-index 间接寻址组（province-ID indirection）】
// =========================================================================
// cell-index indirection 是唯一动态视觉路径。
// map_index_atlas.g/b：cell.index 低/高字节；0xFFFF=map 外哨兵。
//   **必须 NEAREST**：索引插值会得到垃圾 cell。
// enum_lut（RGB8 NEAREST）：per-cell R=biome G=veg B=cover。
// dyn_lut（RGBA8 NEAREST）：per-cell R=temp G=wet B=snow A=ice|vitality。
// eco_lut（RGBA8 NEAREST）：per-cell ecology。
// lut_dims：(lut_w, lut_h) LUT 纹理网格尺寸，shader 据此把 cell.index → texel uv。
uniform sampler2D enum_lut : filter_nearest, repeat_disable;
uniform sampler2D dyn_lut  : filter_nearest, repeat_disable;
uniform sampler2D eco_lut  : filter_nearest, repeat_disable;
uniform vec2 lut_dims = vec2(1.0, 1.0);


// =========================================================================
// 【世界 / 分辨率组】
// =========================================================================
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
uniform vec2 hm_resolution = vec2(2048.0, 1536.0);
uniform vec2 derived_resolution = vec2(1024.0, 768.0);

uniform float sea_level : hint_range(0.0, 1.0) = 0.42;

float wrap_world_x(float x) {
	if (wrap_period_x <= 0.0001) {
		return x;
	}
	return wrap_origin_x + mod(x - wrap_origin_x, wrap_period_x);
}

vec2 wrap_world_pos(vec2 wp) {
	return vec2(wrap_world_x(wp.x), wp.y);
}

vec2 wrap_map_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = wrap_world_x(world_x);
	return vec2((wrapped_x - world_origin.x) / world_size.x, clamp(uv.y, 0.0, 1.0));
}


// =========================================================================
// 【季节 / 时钟 / climate 组】
// =========================================================================
// ─── Phase 1：季节相位 + 气候异常（每帧由 WorldClock 驱动） ───────────────
// season_phase ∈ [0, 4)：0=春 1=夏 2=秋 3=冬
// climate_anomaly ∈ [-0.2, +0.2]：长期气温偏移
// world_time：累积秒数，给海洋洋流流纹动画用（Phase 3）
uniform float season_phase : hint_range(0.0, 4.0) = 1.0;
uniform float climate_anomaly : hint_range(-0.5, 0.5) = 0.0;
uniform float world_time = 0.0;


// =========================================================================
// 【昼夜 / TOD（Time-Of-Day）组】
// =========================================================================
// ─── 任务 2/3：昼夜循环（1 个游戏季 = 1 次完整昼夜） ─────────────────────
// 由 WorldClock.day_phase_changed → HexRenderer.set_day_phase 推入；默认逐帧更新，
uniform float day_phase : hint_range(0.0, 1.0) = 0.25;
uniform bool day_night_enabled = true;
// 夜晚整体亮度压到白天的 [min, max]；默认 0.35~0.55（需求 3.4）
uniform float night_brightness_min : hint_range(0.0, 1.0) = 0.35;
uniform float night_brightness_max : hint_range(0.0, 1.0) = 0.55;

// ─── Pass 2（任务 2）：TOD 全局光照 uniform（单一数据源） ───────────────
// 由 TODProfile 经 HexRenderer.apply_tod 推入。禁止在 shader 内自行从 day_phase
// tod_sun_dir：切线空间下的入射光方向（已归一化，z 为固定高度分量）
uniform vec3  tod_sun_dir       = vec3(0.4, -0.7, 0.6);
uniform vec3  tod_sun_color     : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3  tod_ambient_color : source_color = vec3(0.65, 0.68, 0.75);
// night_factor ∈ [0, 1]，0=白天 1=夜晚；供地表/水体/粒子做一致的夜晚染色
uniform float tod_night_factor  : hint_range(0.0, 1.0) = 0.0;
// tod_exposure：最终 tonemap 前的曝光倍率（艺术化调节用）
uniform float tod_exposure      : hint_range(0.2, 2.5) = 1.0;

// [tod-latitude-sun 2026-06-25] 逐像素太阳方向（近似点光源）总开关。
// true（默认）：主光方向按球面天文逐像素求解，不同纬度/时角得到不同的阴影方向与长度
//   （太阳高悬→短影弱方向；低垂→长影强方向）。配合昼夜晨昏线工作；夜侧无方向光。
// false：回退到全局 tod_sun_dir 单一方向（旧行为，全图同向）。
// 注：day_night_enabled=false（永昼）时本开关自动失效、同样回退全局方向，保持稳定。
uniform bool tod_latitude_sun_enabled = true;

// [tod 地形方向性 2026-06-25] 逐像素太阳移动在地形凹凸上的可读性增强。
// tod_sun_relief_max_up：太阳方向 up 分量截顶上限（原硬编码 0.92）。越低 → 太阳越偏水平 →
//   坡面方向性明暗越强、影子方向随时角旋转越明显。默认 0.88。
// tod_terrain_relief_strength：陆地专属的方向性明暗叠加强度（仅作用于陆地 BRDF 之后，
//   不影响水面反射）。朝阳坡变亮、背阳坡变暗，随太阳方位旋转 → 光源移动清晰可见。默认 0.35。
uniform float tod_sun_relief_max_up        : hint_range(0.5, 1.0) = 0.88;
uniform float tod_terrain_relief_strength  : hint_range(0.0, 1.0) = 0.35;

// ─── Pass 2 新增开关（任务 4/6） ─────────────────────────────────────────
// cloud_tod_tint_enabled：只给云阴影用；云本体渲染在 weather_overlay.gdshader。
uniform bool water_sparkle_enabled = true;
uniform bool cloud_tod_tint_enabled = true;


// =========================================================================
// 【水体子系统组】
// =========================================================================
// ─── Water Visual Overhaul（本轮）：水体子特性独立开关与参数 ────────────
// 这组开关对应 requirements.md 的需求 1/2/4/5 的细分子系统，保证"大一键关"
// （water_effect_enabled=false）之外，还能逐个切换每个效果。
// 统一波浪高度场（需求 1）
// 菲涅尔天空反射（需求 2）
// 河流流动条纹（需求 4）
// 珊瑚礁焦散（需求 5.1）
// 浅海/浅湖透底（需求 5.3/5.4）
uniform bool  water_waves_enabled            = true;
uniform bool  water_fresnel_enabled          = true;
uniform bool  river_flow_enabled             = true;
uniform bool  caustics_enabled               = true;
uniform bool  shallow_transparency_enabled   = true;
uniform float water_gloss                    : hint_range(4.0, 128.0) = 34.0;
uniform float water_reflection_strength      : hint_range(0.0, 1.0) = 0.32;
uniform float river_flow_speed               : hint_range(0.0, 4.0) = 0.75;
uniform float river_flow_freq                : hint_range(0.02, 1.0) = 0.16;
uniform float caustics_strength              : hint_range(0.0, 1.0) = 0.32;
uniform float deep_ocean_contrast            : hint_range(0.5, 3.0) = 0.96;
uniform vec3  lake_water_color : source_color = vec3(0.20, 0.48, 0.56);
uniform float shallow_transparency_factor    : hint_range(0.0, 1.0) = 0.56;
uniform float water_cartoon_color_strength   : hint_range(0.0, 1.0) = 0.75;
uniform float water_transition_softness      : hint_range(0.0, 1.0) = 1.0;
uniform float estuary_plume_strength         : hint_range(0.0, 1.0) = 0.65;

// ShaderToy 启发的两层视觉增强（参考 3tyBRh "2D Stylized Water" 与 dtKcWz
// "2D Ocean Waves"）：
//  - water_domain_warp_strength：在水色采样前把世界坐标做一次 fbm 扭曲，
//    让 "湖/海/礁/藻" 的交界不再是规整直线，而是像水被搅散一样的 wavy edge。
//  - water_wave_line_strength：原为"横向波痕条纹"总强度；本轮（Water Calm
//    防止水面重新出现高对比密集纹理）。字段名保留是为了不破坏既有 .tscn 序列化。
uniform float water_domain_warp_strength : hint_range(0.0, 4.0) = 1.45;
uniform float water_wave_line_strength   : hint_range(0.0, 1.0) = 0.70;
// ─── Water Calm Noise（本轮）：低对比度柔和噪声的两个细分强度 ───────────
// water_calm_noise_brightness  : 亮度扰动层（大尺度 fbm，默认约 ±5%）的强度系数
// water_calm_noise_tint_strength: 色相扰动层（更低频 fbm 在冷/暖 tint 之间
//                                 mix，默认约 ±2%）的强度系数
uniform float water_calm_noise_brightness    : hint_range(0.0, 1.0) = 0.95;
uniform float water_calm_noise_tint_strength : hint_range(0.0, 1.0) = 0.95;
// biome 软混合半径（世界坐标单位，越大过渡带越宽；0 = 关闭软混合，回退到硬切）
uniform float water_biome_blend_radius   : hint_range(0.0, 4.0) = 3.15;


// =========================================================================
// 【视觉总开关组】
// =========================================================================
// ─── 任务 1：视觉总开关（shader 侧占位；具体分支在后续任务接入） ─────────
// 声明为 uniform 是为了让 CPU 侧 set_shader_parameter 永远有效，避免写入一个
uniform int visual_quality : hint_range(0, 2) = 2;
uniform bool water_effect_enabled = true;
uniform bool ocean_current_enabled = true;
uniform bool extreme_weather_ground_effect_enabled = true;


// =========================================================================
// 【insolation / 季节温度组】
// =========================================================================
// 季节温度振幅。2026-05-19 Plan-C：默认 0.20 → 0.32（与 climate_profile.gd
// season_temp_amp / hex_renderer.gd 同步）。让中高纬地块在年度循环中真正
// 穿过雪线带 [0.30, 0.48]。运行时由 hex_renderer.set_shader_parameter 推送，
// 此默认值仅在 shader 单独编译/调试时生效。
uniform float season_temp_amp : hint_range(0.0, 0.4) = 0.32;
// ─── True Insolation-Driven Climate（Phase F）: CPU/GPU 同源参数 ──────
// 兼容开关。运行时由 renderer 强制保持 true；false 仅用于旧材质/离线对比。
uniform bool true_insolation_enabled = true;
// 黄赤交角（弧度），23.5° ≈ 0.4101523
uniform float axial_tilt_rad : hint_range(0.0, 0.7854) = 0.4101523;
// 连续日长项幅度
uniform float insolation_daylen_amp : hint_range(0.0, 1.0) = 0.35;
// 把 (insol_now - insol_mean) 映射回温度偏移的增益
uniform float insolation_season_gain : hint_range(0.0, 2.0) = 1.0;


// =========================================================================
// 【植被 / 雪 / 洋流 / 风组】
// =========================================================================
// 植被换色总开关与强度
uniform float vegetation_season_strength : hint_range(0.0, 1.0) = 0.85;
// 动态雪量（季节性雪盖叠加在 biome SNOW 之外）总开关与强度
uniform float dynamic_snow_strength : hint_range(0.0, 1.0) = 0.85;
// 调试用：true 时雪盖跳过 fbm cosmetic 抖动，直接拿 dyn_snow 上屏，
// 用于验证 CPU→atlas→shader 链路是否健康（屏幕值应 ≈ info_panel.snow_cover）。
uniform bool debug_force_dyn_snow_only = false;
// 洋流动画总开关与强度
uniform float ocean_current_strength : hint_range(0.0, 1.0) = 0.88;


// =========================================================================
// 【深海色彩层次组】
// =========================================================================
// ─── Deep Ocean Layered Color（深海色彩层次感） ─────────────────────────
// 总开关振幅。0 = 完全还原旧视觉；1 = 子层按各自默认振幅全量生效。
uniform float deep_ocean_color_richness         : hint_range(0.0, 1.0) = 0.85;
// 洋流冷/暖色偏：暖流（低纬→高纬）偏微暖，寒流（高纬→低纬）偏冷青。
uniform float deep_ocean_current_tint_strength  : hint_range(0.0, 1.0) = 0.60;
// 纬度/温度驱动色温带：热带翠绿—温带中性—极地冷青。
uniform float deep_ocean_latitude_tint_strength : hint_range(0.0, 1.0) = 0.85;
// 深渊幽冷：深海最深段加压暗与微蓝紫偏移，强化质感。
uniform float deep_ocean_abyss_tint_strength    : hint_range(0.0, 1.0) = 0.60;
// 海盆 gyre 色斑增强：放大半封闭海 vs 开阔腹地的色相差。
uniform float deep_ocean_patch_boost            : hint_range(0.0, 1.0) = 0.50;


// =========================================================================
// 【洋流可视化组】
// =========================================================================
// ─── 任务 9：洋流可视化 toggle ──────────────────────────────────────────
// ocean_current_debug：0 = 正常渲染（低对比流纹）；1 = 调试模式（高对比带箭头感流向）。
uniform bool  ocean_current_debug = false;
// Systemic Ocean Currents：独立 L8 纹理，编码 per-pixel 上升流强度（0=下沉 / 128=中性 / 255=上升）。
// 主路径不采样；仅 ocean_current_debug 开启时作为彩色覆盖叠加。
uniform sampler2D ocean_upwelling_tex : source_color, filter_linear, repeat_disable;


// =========================================================================
// 【植被轴 / 覆盖物轴 / 生态可视化组】
// =========================================================================
uniform float vegetation_axis_strength : hint_range(0.0, 1.0) = 0.35;
uniform float cover_axis_strength : hint_range(0.0, 1.0) = 0.65;
uniform float ecology_visual_strength : hint_range(0.0, 1.0) = 0.70;
uniform float snowline_visual_strength : hint_range(0.0, 1.0) = 0.85;
uniform float foliage_density_strength : hint_range(0.0, 1.0) = 0.75;
uniform int ecology_visual_quality : hint_range(0, 2) = 2;


// =========================================================================
// 【季节过渡 dissolve 组】
// =========================================================================
// Seasonal terrain transition overlay. Main terrain stays opaque; the temporary
// old-terrain layer dissolves out over early-season progress to avoid hard cuts.
uniform bool season_transition_overlay = false;
uniform float season_transition_progress : hint_range(0.0, 1.0) = 1.0;
uniform float season_transition_softness : hint_range(0.02, 0.45) = 0.18;


// =========================================================================
// 【天气锋面组】
// =========================================================================
// ─── Milestone 3：天气子系统（最多 MAX_WEATHER_FRONTS 个活跃锋面） ──────
//   weather_front_centers[i] = (center.x, center.y, radius, intensity ∈ [0,1])
//   weather_front_types[i]   = WeatherType.WT id（< 0 表示该 slot 空，shader 跳过）
//   weather_front_count      = 实际活跃数（≤ MAX_WEATHER_FRONTS）
// fragment 端循环遍历，对每个 front 算高斯覆盖 → max-merge 取最强 → 按类型叠加 overlay。
// CPU 兼容铁律：MAX_WEATHER_FRONTS 不可改（weather_layer.gd / weather_system 按此填充）。
const int MAX_WEATHER_FRONTS = 16;
uniform vec4 weather_front_centers[MAX_WEATHER_FRONTS];
uniform vec4 weather_front_shapes[MAX_WEATHER_FRONTS];
uniform vec4 weather_front_visuals[MAX_WEATHER_FRONTS];
uniform float weather_front_types[MAX_WEATHER_FRONTS];
uniform int weather_front_count = 0;



// =========================================================================
// 【地形 Hypsometric 色阶组】
// =========================================================================
// ─── Hypsometric 色阶（海陆双向，等高线设色） ────────────────────────────
// Open Ocean Color Rebalance v3：水体 BRDF 粗糙度抬高后（顶视镜面退化为柔和高光，
// 不再过曝），深海少了镜面"提亮"，色板自带的深/浅对比重新暴露 → 用户反馈"浅海深海
// 差距太大"。v3 进一步压缩：抬亮 deep/mid、轻压 coast，把浅↔深亮度比从 ~1.9x 收到 ~1.4x。
// 注意：实际渲染值由 world_map_material.tres 覆盖，这里的默认值与 .tres 保持一致。
// 旧值 (v2) / 新值 (v3) / 视觉影响：
//   deep_ocean   (0.14, 0.22, 0.34) → (0.22, 0.31, 0.43)   深海明显抬亮，去黑洞感
//   mid_ocean    (0.20, 0.30, 0.42) → (0.25, 0.35, 0.46)   中海域抬亮、过渡更连续
//   color_shallow(0.28, 0.42, 0.52) → (0.27, 0.40, 0.49)   浅海略压暗
//   coast_water  (0.34, 0.50, 0.56) → (0.30, 0.43, 0.51)   海岸再压一档、贴近浅海
uniform vec3 color_deep_ocean   : source_color = vec3(0.22, 0.31, 0.43);
uniform vec3 color_mid_ocean    : source_color = vec3(0.25, 0.35, 0.46);
uniform vec3 color_shallow      : source_color = vec3(0.27, 0.40, 0.49);
uniform vec3 color_coast_water  : source_color = vec3(0.30, 0.43, 0.51);
uniform vec3 color_beach        : source_color = vec3(0.85, 0.78, 0.55);
uniform vec3 color_lowland      : source_color = vec3(0.62, 0.68, 0.42);
uniform vec3 color_hill         : source_color = vec3(0.66, 0.55, 0.32);
uniform vec3 color_mountain     : source_color = vec3(0.45, 0.38, 0.34);
uniform vec3 color_peak         : source_color = vec3(0.55, 0.50, 0.46);
uniform vec3 color_snow         : source_color = vec3(0.96, 0.96, 0.96);


// =========================================================================
// 【Hillshading 组】
// =========================================================================
// ─── 极端天气地表反馈（仅保留 BLIZZARD 雪/薄冰；裂地与热浪/干旱调色已删除）────
// ─── 双光源 hillshading ──────────────────────────────────────────────────

uniform float hillshade_strength : hint_range(0.0, 1.0) = 0.45;
uniform float hillshade_slope_gain : hint_range(0.5, 24.0) = 8.0;
uniform vec2  hillshade_dir      = vec2(-0.55, -0.55);
uniform vec2  hillshade_fill_dir = vec2( 0.60,  0.40);
// [terrain-normal 分层 2026-06-25] 粗法线（烘焙/宽半径）+ 细节法线（运行期，按 biome/性能档）分层控制。
//   compute_terrain_normal：① 粗法线给山脉总体走向（治"走向不清晰"）；② 细节法线只在需要的地形 +
//   高画质上叠（治"密密麻麻"）；③ 低/中端机不算细节（性能分档）。
uniform float hillshade_coarse_radius   : hint_range(1.0, 16.0) = 4.0;  // 未绑定烘焙法线时运行期回退半径(texel)
uniform float hillshade_coarse_strength : hint_range(0.0, 3.0)  = 1.6;  // 烘焙粗法线 xy 强度再缩放（基底明暗）
uniform bool  hillshade_detail_enabled = true;                          // 细节法线总开关
uniform float hillshade_detail_strength : hint_range(0.0, 1.0)  = 0.5;  // 细节法线全局强度（再乘 biome 因子）
// [shore-normal 2026-06-25] 近岸滩坡法线：近海陆地(elev 略高于 sea_level 的窄带)单独解开细节门控，
//   让海岸读出滩坡/切岸起伏（B_COAST 是水体不调本函数；近岸陆地多为 B_PLAIN，biome 因子≈0.12 被压平）。
//   用 coast_sdf=elev-sea_level 做近岸 gate，不影响内陆平原(P0 真平)。
uniform float shore_detail_strength : hint_range(0.0, 1.0) = 0.45;       // 近岸滩坡细节强度(0=关)
uniform float shore_band_height     : hint_range(0.001, 0.2) = 0.06;     // 近岸带高度(land_h 厚度，越小越贴岸)
// [coast-smooth 2026-06-26] 平滑海岸线：水陆边界是 per-cell 六边形枚举硬边(阶梯)，河流是连续 SDF。
// 这里在海岸一圈把陆/水颜色统一混向"水色与陆色的中间色"(mix(color_coast_water,color_lowland))做柔和
// 过渡带，掩盖六边形硬边。定位/粗细由 shore_w(邻域水/陆接触度,已 smoothstep)×width 控制——对称、内陆
// 与开阔水/浅湖 shore_w=0 → 不染(不发灰)。0=关(回退旧硬边)。
uniform float coast_smooth_strength  : hint_range(0.0, 1.0) = 0.65;   // 过渡混合强度(0=关)
uniform float coast_smooth_width     : hint_range(0.2, 4.0) = 1.8;    // 过渡带粗细(越大越粗)
uniform float coast_shore_land_bias  : hint_range(0.0, 1.0) = 0.5;    // 过渡色偏向:0=全水色 1=全陆色(lowland)


// =========================================================================
// 【河流组】
// =========================================================================
// ─── 河流（从 flow accumulation） ───────────────────────────────────────
uniform float river_strength       : hint_range(0.0, 1.0) = 0.85;
uniform float river_threshold_low  : hint_range(0.0, 1.0) = 0.62;
uniform float river_threshold_high : hint_range(0.0, 1.0) = 0.90;
uniform vec3  river_color          : source_color = vec3(0.30, 0.50, 0.68);
uniform vec3  river_outline_color  : source_color = vec3(0.16, 0.30, 0.45);


// =========================================================================
// 【等高线 / 海岸光晕 / 羊皮纸组】
// =========================================================================
// ─── 可选等高线 ──────────────────────────────────────────────────────────
uniform bool  contour_enabled = false;
uniform float contour_step       : hint_range(0.01, 0.20) = 0.05;
uniform float contour_strength   : hint_range(0.0, 0.40) = 0.18;
uniform vec3  contour_color      : source_color = vec3(0.20, 0.16, 0.10);

// ─── 海岸光晕 ─────────────────────────────────────────────────────────────
uniform vec3  coast_halo_color    : source_color = vec3(0.78, 0.86, 0.88);
uniform float coast_halo_strength : hint_range(0.0, 1.0) = 0.22;

// ─── 羊皮纸 ───────────────────────────────────────────────────────────────
uniform vec3  parchment_tint        : source_color = vec3(0.96, 0.88, 0.74);
uniform float parchment_strength    : hint_range(0.0, 0.4) = 0.10;
uniform float paper_grain_strength  : hint_range(0.0, 0.2) = 0.05;


// =========================================================================
// 【Biome / Vegetation / Cover / Weather ID 常量组】
// =========================================================================
// CPU 兼容铁律：以下常量名与数值必须与 scripts/terrain_type.gd、
// scripts/vegetation_type.gd、scripts/cover_type.gd、scripts/weather_type.gd
// 的 enum 顺序与值严格一致；改一处必须改另一处。
//
// TerrainType.TERRAIN id
const int B_OCEAN     = 0;
const int B_COAST     = 1;
const int B_PLAIN     = 2;
const int B_GRASSLAND = 3;
const int B_FOREST    = 4;
const int B_HILL      = 5;
const int B_MOUNTAIN  = 6;
const int B_DESERT    = 7;
const int B_TUNDRA    = 8;
const int B_SNOW      = 9;
const int B_SWAMP     = 10;
const int B_JUNGLE    = 11;
const int B_SAVANNA   = 12;
const int B_TAIGA     = 13;
const int B_STEPPE    = 14;
const int B_SHRUBLAND = 15;
const int B_MANGROVE  = 16;
const int B_GLACIER   = 17;
const int B_LAKE      = 18;
const int B_REEF      = 19;
const int B_SEA_ICE   = 20;
const int B_KELP      = 21;
const int B_DELTA     = 22;
const int B_OASIS     = 23;
const int B_SALT_FLAT = 24;
const int B_BADLANDS  = 25;
// terrain-overhaul 新增地形（与 terrain_type.gd 尾部追加严格对齐）
const int B_COLD_DESERT = 26;
const int B_CHAPARRAL   = 27;
const int B_MOOR        = 28;
const int B_FLOODPLAIN  = 29;
const int B_MESA        = 30;

// ─── Milestone 2：VegetationType.VEG id ──────────────────────────────────
// 与 scripts/vegetation_type.gd 严格按 enum 顺序对齐，shader 端按 id 直接 if-else 派色。
const int V_NONE                = 0;
const int V_POLAR_DESERT        = 1;
const int V_TUNDRA              = 2;
const int V_ALPINE_TUNDRA       = 3;
const int V_ALPINE_MEADOW       = 4;
const int V_TAIGA               = 5;
const int V_BOREAL_SHRUB        = 6;
const int V_TEMPERATE_DECIDUOUS = 7;
const int V_TEMPERATE_CONIFER   = 8;
const int V_TEMPERATE_GRASSLAND = 9;
const int V_TEMPERATE_STEPPE    = 10;
const int V_MEDITERRANEAN_SHRUB = 11;
const int V_SUBTROPICAL_FOREST  = 12;
const int V_SAVANNA             = 13;
const int V_TROPICAL_RAINFOREST = 14;
const int V_TROPICAL_DRY_FOREST = 15;
const int V_DESERT_SCRUB        = 16;
const int V_XERIC_DESERT        = 17;
const int V_OASIS_VEG           = 18;
const int V_MANGROVE            = 19;
const int V_SWAMP               = 20;
const int V_MARSH               = 21;
const int V_KELP_FOREST         = 22;
const int V_CORAL_REEF          = 23;
// terrain-overhaul 新增植被（与 vegetation_type.gd 尾部追加严格对齐）
const int V_CLOUD_FOREST        = 24;
const int V_MONSOON_FOREST      = 25;
const int V_SEAGRASS            = 26;
const int V_PEAT_BOG            = 27;
const int V_COUNT               = 28;

// ─── Milestone 2：CoverType.CV id ────────────────────────
const int CV_NONE       = 0;
const int CV_SNOW       = 1;
const int CV_GLACIER    = 2;
const int CV_SEA_ICE    = 3;
const int CV_PERMAFROST = 4;
const int CV_FLOODING   = 5;
// Systemic Ocean Currents：远洋华（浮游生物繁殖）
const int CV_PELAGIC_BLOOM = 6;
// ─── landform 轴可视化（LandformType.LF id，与 scripts/geography/landform_type.gd 严格对齐）──
// 由 map_index_atlas.A 通道（per-pixel）承载。仅用于给 terrain 无法表达的地貌补充视觉特征。
const int LF_DEEP_OCEAN  = 0;
const int LF_OCEAN       = 1;
const int LF_COAST       = 2;
const int LF_LAKE        = 3;
const int LF_PLAIN       = 4;
const int LF_LOWLAND     = 5;
const int LF_HILL        = 6;
const int LF_MOUNTAIN    = 7;
const int LF_PEAK        = 8;
const int LF_DELTA       = 9;
const int LF_BADLANDS    = 10;
const int LF_SALT_FLAT   = 11;
const int LF_VOLCANO     = 12;
const int LF_PLATEAU     = 13;
const int LF_RIFT_VALLEY = 14;
const int LF_CANYON      = 15;
// ─── Milestone 3：WeatherType.WT id ──────────────────────────────────────
const int WT_CLEAR    = 0;
// 与 scripts/weather_type.gd 严格按 enum 数值对齐；4(DROUGHT)/6(HEATWAVE) 的地表调色已删除。
const int WT_RAIN     = 1;
const int WT_STORM    = 2;
const int WT_BLIZZARD = 3;
const int WT_FOG      = 5;


// =========================================================================
// 【植被四季 LUT 组（依赖 V_COUNT 常量必须先声明）】
// =========================================================================
// ─── map-visual-overhaul-v1：植被四季换色 LUT ─────────────────────────
// 24 个植被类型 × 4 季（春/夏/秋/冬）× 4 通道（rgb 叠乘色 + 保留 a）。
// 由 hex_renderer._push_vegetation_season_lut() 在 setup 时 push 一次，运行时不刷新。
// shader 端按当前像素半球的 season_phase ∈ [0,4) 做 4 段 cubic mix，南北半球反相。
// climate_anomaly 叠加：vegetation_anomaly_shift[veg] * climate_anomaly。
// 96 个 vec4 占 1.5 KiB uniform buffer，远低于 Godot 默认 16 KiB UBO 上限。
uniform vec4 vegetation_season_lut[V_COUNT * 4];     // [veg*4 + season]
uniform vec4 vegetation_anomaly_shift[V_COUNT];      // 每种植被一个 climate_anomaly 叠加色


// =========================================================================
// 【varying（vertex → fragment）】
// =========================================================================
varying vec2 v_world;
