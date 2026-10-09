// material_constants.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责（What）
//   集中所有 shader 端的"材质 / 光照常量"——magic number、F0 表、roughness↔gloss
//   映射、视图方向常量、特性开关。下游所有 inc 都不应再写裸数值。
//
// 调用方（Who）
//   - brdf.gdshaderinc        ：消费 F0 / NdotL clamp / 能量守恒系数
//   - surface_params.gdshaderinc ：消费默认 emission/alpha / 默认 metallic
//   - land_pipeline / water_pipeline ：消费 SPEC/GLOSS 映射、Fresnel 系数
//   - global_adjustments      ：消费 tonemap 曝光偏置
//
// 依赖（Why）
//   零依赖叶子。本文件只能 #include 在 uniforms 之后、所有 pipeline 之前。
//
// 性能（Cost）
//   全部为 const / #define，无任何运行时开销；编译期常量折叠。
// ─────────────────────────────────────────────────────────────────────────

// ═══════════════════════════════════════════════════════════════════════
// 一、特性总开关（一键回退）
// ═══════════════════════════════════════════════════════════════════════
//   USE_PBR_BRDF：1 = Cook-Torrance (GGX+Smith+Schlick+能量守恒)
//                 0 = Blinn-Phong legacy（与 v9 视觉等价，用于回滚验证）
//   USE_LINEAR_LIGHTING：1 = 进入 BRDF 前 srgb→linear，输出前 linear→srgb + tonemap
//                        0 = 直接 sRGB 域运算（legacy 兼容）
//   USE_FILMIC_TONEMAP：1 = ACES Approx 替代旧的 x/(1+0.35x)
//                       0 = 走 tonemap_reinhard_legacy
// ─────────────────────────────────────────────────────────────────────
#if defined(PK_MOBILE_ANY)
// 移动端全档位需要优先稳帧：保留 stylized 光照，但跳过手机 GPU 上发热明显的
// Cook-Torrance + linear/filmic 路径。
const bool USE_PBR_BRDF        = false;
const bool USE_LINEAR_LIGHTING = false;
const bool USE_FILMIC_TONEMAP  = false;
#else
const bool USE_PBR_BRDF        = true;
const bool USE_LINEAR_LIGHTING = true;
const bool USE_FILMIC_TONEMAP  = true;
#endif

// ═══════════════════════════════════════════════════════════════════════
// 二、视图模型
// ═══════════════════════════════════════════════════════════════════════
//   2D top-down canvas_item，观察方向恒为 +Z。未来若切倾斜视角，仅改此处即可。
// ─────────────────────────────────────────────────────────────────────
const vec3 VIEW_DIR_TOP_DOWN = vec3(0.0, 0.0, 1.0);

// ═══════════════════════════════════════════════════════════════════════
// 三、BRDF 常量
// ═══════════════════════════════════════════════════════════════════════
//   PI / INV_PI            ：标准常量（PI 为 Godot Shading Language 内置常量，
//                           不可重复声明；本处仅声明 INV_PI）
//   F0_DIELECTRIC_DEFAULT  ：非金属基础反射率（vec3(0.04) 业界标准）
//   F0_WATER               ：水（IOR≈1.33 ⇒ F0≈0.02）
//   F0_SNOW_ICE            ：雪/冰（IOR≈1.31 ⇒ F0≈0.018，但雪场 BRDF 实测约 0.03）
//   ROUGHNESS_MIN/MAX      ：避免 GGX 在 roughness=0 时除零
//   NDOTL_BIAS             ：低法线掠射角抗噪声偏置
// ─────────────────────────────────────────────────────────────────────
const float INV_PI              = 0.31830988618;
const vec3  F0_DIELECTRIC_DEFAULT = vec3(0.04);
const vec3  F0_WATER              = vec3(0.02);
const vec3  F0_SNOW_ICE           = vec3(0.03);
const float ROUGHNESS_MIN       = 0.04;
const float ROUGHNESS_MAX       = 1.00;
const float NDOTL_BIAS          = 0.0005;

// ═══════════════════════════════════════════════════════════════════════
// 四、Stylized Modulator（半 PBR 风格化乘子）
// ═══════════════════════════════════════════════════════════════════════
//   AMBIENT_FLOOR_LAND     ：陆地环境光最低限（避免阴影侧死黑）
//   AMBIENT_FLOOR_WATER    ：水面环境光最低限
//   HILLSHADE_BASE_LIFT    ：hillshade 提升基线（旧 land 中的 +0.55）
//   NIGHT_BRIGHTNESS_FLOOR ：夜晚最暗系数（旧 mix(1, 0.55, night)）
//   SUN_INTENSITY_GAIN     ：阳光增益（线性空间下的 sun radiance multiplier）
// ─────────────────────────────────────────────────────────────────────
const float AMBIENT_FLOOR_LAND     = 0.18;
const float AMBIENT_FLOOR_WATER    = 0.22;
const float HILLSHADE_BASE_LIFT    = 0.55;
const float NIGHT_BRIGHTNESS_FLOOR = 0.68;
const float SUN_INTENSITY_GAIN     = 1.00;

// ═══════════════════════════════════════════════════════════════════════
// 五、Legacy Blinn-Phong 系数（USE_PBR_BRDF=0 路径用）
// ═══════════════════════════════════════════════════════════════════════
//   GLOSS_MAX_LEGACY / GLOSS_MIN_LEGACY ：mix(128, 4, roughness)
//   SPEC_MAX_LAND_LEGACY / SPEC_MIN_LAND_LEGACY  ：mix(0.25, 0.02, r)
//   SPEC_MAX_WATER_LEGACY / SPEC_MIN_WATER_LEGACY：mix(0.85, 0.25, r)
// ─────────────────────────────────────────────────────────────────────
const float GLOSS_MAX_LEGACY       = 128.0;
const float GLOSS_MIN_LEGACY       = 4.0;
const float SPEC_MAX_LAND_LEGACY   = 0.25;
const float SPEC_MIN_LAND_LEGACY   = 0.02;
const float SPEC_MAX_WATER_LEGACY  = 0.85;
const float SPEC_MIN_WATER_LEGACY  = 0.25;
const float WATER_SPECULAR_DAY_LEGACY   = 0.50;
const float WATER_SPECULAR_NIGHT_LEGACY = 0.18;

// ═══════════════════════════════════════════════════════════════════════
// 六、Tonemap 参数
// ═══════════════════════════════════════════════════════════════════════
//   TONEMAP_EXPOSURE_BIAS  ：进入 tonemap 前的全局曝光偏置（可与 tod_exposure 叠加）
//   REINHARD_K_LEGACY      ：旧 x/(1+k*x) 的 k=0.35
//   ACES_A/B/C/D/E         ：ACES Approx (Narkowicz 2015) 拟合参数
// ─────────────────────────────────────────────────────────────────────
const float TONEMAP_EXPOSURE_BIAS = 1.00;
const float REINHARD_K_LEGACY     = 0.35;
const float ACES_A = 2.51;
const float ACES_B = 0.03;
const float ACES_C = 2.43;
const float ACES_D = 0.59;
const float ACES_E = 0.14;

// ═══════════════════════════════════════════════════════════════════════
// 七、Material Role Defaults（不同地物的默认材质参数）
// ═══════════════════════════════════════════════════════════════════════
//   未来真实贴图接入前的 procedural 默认值。让 metallic / emission 真正生效。
// ─────────────────────────────────────────────────────────────────────
const float DEFAULT_METALLIC_LAND      = 0.00;
const float DEFAULT_METALLIC_WATER     = 0.00;
const float DEFAULT_METALLIC_SNOW      = 0.02;   // 雪面有微弱镜面金属感
const float DEFAULT_METALLIC_ICE       = 0.05;
const float DEFAULT_AO_LAND            = 1.00;
const float DEFAULT_AO_WATER           = 1.00;
const float DEFAULT_ALPHA              = 1.00;
const vec3  DEFAULT_EMISSION           = vec3(0.0);

// ═══════════════════════════════════════════════════════════════════════
// 八、特殊覆盖层（雪盖 / 海岸 halo）权重上限
// ═══════════════════════════════════════════════════════════════════════
const float SHORE_HALO_WEIGHT_MAX  = 0.72;   // 旧 shore_w * 0.72
const float SNOW_OVERLAY_MAX       = 1.00;

// ═══════════════════════════════════════════════════════════════════════
// 九、河流水面法线
// ═══════════════════════════════════════════════════════════════════════
// 河心必须使用以水平面为基准的独立水面法线，不能继续继承地形/材质法线。
// RIVER_NORMAL_WAVE_WEIGHT 控制河面水波相对水平面的起伏；河岸混合窗口只负责
// 把独立水面法线平滑接回地形，避免窄河边缘出现法线硬切。
const float RIVER_NORMAL_WAVE_WEIGHT = 0.46;
const float RIVER_NORMAL_BLEND_START = 0.08;
const float RIVER_NORMAL_BLEND_END   = 0.68;
