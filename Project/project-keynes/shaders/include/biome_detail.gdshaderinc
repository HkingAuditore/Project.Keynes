// biome_detail.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：每个 biome 的"程序化贴图"——用 fbm / voronoi 噪声让大块地表内部产生
//        具有地理含义的细节调制（森林冠层斑驳 / 沙丘走向 / 高山岩纹 / 红树根 /
//        盐沼晶体 / 荒原沉积层条纹 / ...）。返回乘性 modulator（围绕 1.0）。
// 调用方：fragment() 陆地分支在 vegetation tint 与湿度调制之间调用一次。
// 依赖（caller 必须先 include）：
//   - uniforms.gdshaderinc：B_* 常量。
//   - common_noise.gdshaderinc：fbm / voronoi_cell。
// 性能（PERF）：本函数是 fragment 内单像素 fbm 调用的最大集中地。最差路径
//                （B_JUNGLE）：1 次 voronoi + 3 次 fbm（octaves 3/3/1）≈ 8 个
//                octave 的噪声 fetch。其他 biome 通常 1~2 次 fbm + 0~1 次
//                voronoi。移动端 MID/HIGH 与桌面 visual_quality==1 改读
//                terrain_detail_tex（bake-time L8），LOW 直接跳过采样。
//
// 每个 biome 的噪声配方一览（方便手动调整某一种地表）：
//   B_FOREST   : voronoi(0.30) + fbm(0.40, oct=3)             — 林冠斑驳
//   B_GRASSLAND: fbm(0.18, 3) + fbm(0.45, 1)                  — 草地起伏 + 微纹
//   B_DESERT   : sin(wp · dune_dir + fbm(0.06,1)) + fbm(0.30,1)— 沙丘走向 + 微沙
//   B_HILL     : fbm(0.20, 3) + fbm(0.45, 1)                  — 丘陵起伏 + 微纹
//   B_MOUNTAIN : fbm(0.30, 4) + voronoi(0.16)                 — 岩纹 + 大块山体
//   B_PLAIN    : fbm(0.12, 3) + fbm(0.40, 1)
//   B_TUNDRA   : fbm(0.16, 3)
//   B_SNOW     : fbm(0.20, 3) + fbm(0.50, 1)
//   B_SWAMP    : fbm(0.55, 3) + fbm(0.18, 2)                  — 水洼 + 泥纹
//   B_JUNGLE   : voronoi(0.45) + fbm(0.55, 3) + fbm(1.20, 1)  — 林冠 + 中层 + 微纹
//   B_SAVANNA  : fbm(0.16, 3) + voronoi(0.22)                 — 草 + 散点树丛
//   B_TAIGA    : voronoi(0.34) + fbm(0.40, 3) + fbm(0.65, 2)
//   B_STEPPE   : fbm(0.14, 3) + fbm(0.50, 1)
//   B_SHRUBLAND: voronoi(0.36) + fbm(0.30, 3)
//   B_MANGROVE : fbm(0.50, 3) + voronoi(0.55)
//   B_GLACIER  : fbm(0.18, 3) + voronoi(0.70)                 — 冰起伏 + 冰裂缝
//   B_DELTA    : fbm(0.35, 3) + fbm(0.55, 2)
//   B_OASIS    : voronoi(0.40) + fbm(0.50, 3)                 — 绿洲核心 + 周围沙渐变
//   B_SALT_FLAT: voronoi(1.10) + voronoi(0.30)                — 晶体 + 大块裂纹
//   B_BADLANDS : sin(y + fbm(0.12,2)) + fbm(0.40, 3)          — 横向沉积层
// ─────────────────────────────────────────────────────────────────────────

// ─── 锐利程序化贴图（不依赖 hex，世界坐标连续） ─────────────────────────

const float TERRAIN_DETAIL_BAKE_MIN = 0.70;
const float TERRAIN_DETAIL_BAKE_MAX = 1.30;

float terrain_macro_amplitude(int biome) {
	if (biome == B_MOUNTAIN || biome == B_HILL || biome == B_BADLANDS || biome == B_MESA) {
		return 0.095;
	}
	if (biome == B_FOREST || biome == B_JUNGLE || biome == B_TAIGA || biome == B_MANGROVE) {
		return 0.082;
	}
	if (biome == B_DESERT || biome == B_COLD_DESERT || biome == B_SALT_FLAT) {
		return 0.075;
	}
	if (biome == B_SWAMP || biome == B_DELTA || biome == B_FLOODPLAIN || biome == B_MOOR) {
		return 0.055;
	}
	if (biome == B_SNOW || biome == B_GLACIER) {
		return 0.040;
	}
	return 0.065;
}

vec3 baked_biome_detail(int biome, vec2 uv) {
	float d = visual_sample_terrain_detail(uv).r;
	float signal = clamp((mix(TERRAIN_DETAIL_BAKE_MIN, TERRAIN_DETAIL_BAKE_MAX, d) - 1.0)
			/ max(TERRAIN_DETAIL_BAKE_MAX - 1.0, 0.001), -1.0, 1.0);
	return vec3(1.0 + signal * terrain_macro_amplitude(biome));
}

vec3 procedural_biome_detail(int biome, vec2 wp, vec2 uv) {
	if (visual_quality <= 0) {
		return vec3(1.0);
	}
	if (has_terrain_detail_tex) {
		return baked_biome_detail(biome, uv);
	}
#if defined(PK_MOBILE_ANY)
	return vec3(1.0);
#else
	if (visual_quality == 1) {
		float n = fbm(wp * 0.18, 2);
		float amp = 0.060;
		if (biome == B_FOREST || biome == B_JUNGLE || biome == B_TAIGA || biome == B_MANGROVE) {
			amp = 0.095;
		} else if (biome == B_MOUNTAIN || biome == B_HILL || biome == B_BADLANDS || biome == B_GLACIER) {
			amp = 0.085;
		} else if (biome == B_DESERT || biome == B_SALT_FLAT) {
			float bands = sin(dot(wp, vec2(0.85, 0.30)) * 0.040 + n * 4.0) * 0.5 + 0.5;
			return vec3(mix(0.94, 1.07, bands));
		} else if (biome == B_SWAMP || biome == B_DELTA || biome == B_OASIS) {
			amp = 0.075;
		}
		return vec3(mix(1.0 - amp, 1.0 + amp, n));
	}
	if (biome == B_FOREST) {
		float vor = voronoi_cell(wp * 0.30);
		float n = fbm(wp * 0.40, 3);
		float modulator = mix(0.78, 1.15, smoothstep(0.05, 0.6, vor));
		modulator *= mix(0.92, 1.05, n);
		return vec3(modulator);
	}
	if (biome == B_GRASSLAND) {
		float n = fbm(wp * 0.18, 3);
		float micro = fbm(wp * 0.45, 1);  // v9.fbm-opt：micro ±0.05，单 octave 足够
		return vec3(mix(0.85, 1.10, n) * mix(0.95, 1.05, micro));
	}
	if (biome == B_DESERT) {
		vec2 dune_dir = vec2(0.85, 0.30);
		float t = dot(wp, dune_dir) * 0.040;
		// v9.fbm-opt：sin 内部的 phase 扰动，单 octave 已经够"沙丘走向有变化"
		float waves = sin(t + fbm(wp * 0.06, 1) * 5.0) * 0.5 + 0.5;
		float micro = fbm(wp * 0.30, 1);
		return vec3(mix(0.88, 1.10, waves) * mix(0.95, 1.05, micro));
	}
	if (biome == B_HILL) {
		float n = fbm(wp * 0.20, 3);
		float micro = fbm(wp * 0.45, 1);  // v9.fbm-opt
		// 放大丘陵明暗纹理，让中海拔读起来更像连续坡面而不是一块均匀台面。
		return vec3(mix(0.82, 1.12, n) * mix(0.93, 1.06, micro));
	}
	if (biome == B_MOUNTAIN) {
		// [山体去点阵 2026-06-25] 降频 + 降对比：用更大尺度的块面与岩体分区取代
		// 高频细密岩点，避免"点阵噪声"观感，更接近真实连绵山脉的大面块。
		//   freq 0.32→0.20 / oct 4→3   → 特征更大更柔
		//   voronoi 0.14→0.095          → 岩体分区更宽
		//   crag    0.62→0.38 / amp ↓   → 弱化高频岩脊
		//   亮度对比 0.68~1.16 → 0.86~1.10（约 2.4×→1.28× 收窄）
		float n = fbm(wp * 0.20, 3);
		float vor = voronoi_cell(wp * 0.095);
		float crag = fbm(wp * 0.38 + vec2(13.0, -7.0), 2);
		return vec3(mix(0.86, 1.10, n) * mix(0.94, 1.05, smoothstep(0.06, 0.55, vor)) * mix(0.975, 1.03, crag));
	}
	if (biome == B_PLAIN) {
		float n = fbm(wp * 0.12, 3);
		float micro = fbm(wp * 0.40, 1);  // v9.fbm-opt
		return vec3(mix(0.92, 1.08, n) * mix(0.97, 1.03, micro));
	}
	if (biome == B_TUNDRA) {
		float n = fbm(wp * 0.16, 3);
		return vec3(mix(0.85, 1.08, n));
	}
	if (biome == B_SNOW) {
		float n = fbm(wp * 0.20, 3);
		float micro = fbm(wp * 0.50, 1);  // v9.fbm-opt
		return vec3(mix(0.78, 1.03, n) * mix(0.94, 1.02, micro));
	}
	if (biome == B_SWAMP) {
		float pools = fbm(wp * 0.55, 3);
		float mud = fbm(wp * 0.18 + vec2(13.0, -7.0), 2);
		float pool_factor = smoothstep(0.55, 0.45, pools);
		float base_mod = mix(0.88, 1.08, mud);
		float pool_mod = mix(1.0, 0.78, pool_factor);
		return vec3(base_mod * pool_mod);
	}
	if (biome == B_JUNGLE) {
		float canopy = voronoi_cell(wp * 0.45);
		float n = fbm(wp * 0.55, 3);
		float micro = fbm(wp * 1.20, 1);  // v9.fbm-opt：micro ±0.05，单 octave 足够
		float canopy_mod = mix(0.72, 1.08, smoothstep(0.05, 0.55, canopy));
		float n_mod = mix(0.92, 1.05, n);
		float micro_mod = mix(0.94, 1.04, micro);
		return vec3(canopy_mod * n_mod * micro_mod);
	}
	if (biome == B_SAVANNA) {
		// 稀树草原：金黄草低频 fbm + 散点深绿（树丛）voronoi
		float grass = fbm(wp * 0.16, 3);
		float trees = voronoi_cell(wp * 0.22);
		float tree_factor = smoothstep(0.05, 0.45, trees);
		float grass_mod = mix(0.85, 1.12, grass);
		float tree_mod = mix(0.62, 1.0, tree_factor);
		return vec3(grass_mod * tree_mod);
	}
	if (biome == B_TAIGA) {
		// 泰加：FOREST 同款但更暗、加冷调白点（积雪未融）
		float vor = voronoi_cell(wp * 0.34);
		float n = fbm(wp * 0.40, 3);
		float patches = fbm(wp * 0.65 + vec2(11.0, 17.0), 2);
		float modulator = mix(0.70, 1.05, smoothstep(0.05, 0.6, vor));
		modulator *= mix(0.90, 1.04, n);
		float frost = smoothstep(0.78, 0.92, patches);
		modulator *= mix(1.0, 1.18, frost);
		return vec3(modulator);
	}
	if (biome == B_STEPPE) {
		float n = fbm(wp * 0.14, 3);
		float micro = fbm(wp * 0.50, 1);  // v9.fbm-opt
		return vec3(mix(0.90, 1.06, n) * mix(0.96, 1.04, micro));
	}
	if (biome == B_SHRUBLAND) {
		// 灌丛：中频斑点（灌木簇）+ 微干燥粒
		float vor = voronoi_cell(wp * 0.36);
		float n = fbm(wp * 0.30, 3);
		float bush = mix(0.82, 1.05, smoothstep(0.05, 0.55, vor));
		float n_mod = mix(0.93, 1.06, n);
		return vec3(bush * n_mod);
	}
	if (biome == B_MANGROVE) {
		// 红树林：SWAMP 同款水洼但更深、加密集树根 voronoi
		float pools = fbm(wp * 0.50, 3);
		float roots = voronoi_cell(wp * 0.55);
		float pool_factor = smoothstep(0.55, 0.40, pools);
		float root_mod = mix(0.78, 1.0, smoothstep(0.05, 0.45, roots));
		float pool_mod = mix(1.0, 0.70, pool_factor);
		return vec3(root_mod * pool_mod);
	}
	if (biome == B_GLACIER) {
		// 冰川：低频起伏 + 高频裂纹（voronoi 边缘 = 冰裂缝）
		float n = fbm(wp * 0.18, 3);
		float crack = voronoi_cell(wp * 0.70);
		float crack_factor = smoothstep(0.0, 0.18, crack);
		return vec3(mix(0.92, 1.06, n) * mix(0.78, 1.02, crack_factor));
	}
	if (biome == B_DELTA) {
		float n = fbm(wp * 0.35, 3);
		float fans = fbm(wp * 0.55 + vec2(13.0, -7.0), 2);
		float pools = smoothstep(0.55, 0.40, fans);
		float n_mod = mix(0.85, 1.10, n);
		float pool_mod = mix(1.0, 0.78, pools);
		return vec3(n_mod * pool_mod);
	}
	if (biome == B_OASIS) {
		// 绿洲：中心鲜绿 + 周围淡黄沙渐变（径向 fade 用 voronoi 距离场）
		float vor = voronoi_cell(wp * 0.40);
		float n = fbm(wp * 0.50, 3);
		// vor 越小 = 越靠近某个特征点（绿洲核心） → 鲜绿
		float core = smoothstep(0.40, 0.05, vor);
		float n_mod = mix(0.92, 1.10, n);
		float core_mod = mix(0.85, 1.20, core);
		return vec3(n_mod * core_mod);
	}
	if (biome == B_SALT_FLAT) {
		float crystals = voronoi_cell(wp * 1.10);
		float crystal_factor = smoothstep(0.0, 0.15, crystals);
		float crack = voronoi_cell(wp * 0.30);
		float crack_factor = smoothstep(0.0, 0.10, crack);
		return vec3(mix(0.85, 1.10, crystal_factor) * mix(0.95, 1.02, crack_factor));
	}
	if (biome == B_BADLANDS) {
		// 荒原：横向沉积层条纹（用世界 y mod）+ 高频粗砂
		float bands = sin(wp.y * 0.45 + fbm(wp * 0.12, 2) * 4.0) * 0.5 + 0.5;
		float sand = fbm(wp * 0.40, 3);
		return vec3(mix(0.85, 1.18, bands) * mix(0.92, 1.06, sand));
	}
	// ── terrain-overhaul 新增地形 detail ──
	if (biome == B_COLD_DESERT) {
		// 寒漠：低对比砾漠斑驳 + 微风成纹理（比热沙漠更冷更碎）
		float n = fbm(wp * 0.22, 3);
		float grit = fbm(wp * 0.55, 1);
		return vec3(mix(0.90, 1.08, n) * mix(0.96, 1.04, grit));
	}
	if (biome == B_CHAPARRAL) {
		// 硬叶灌丛：中频灌木簇（voronoi）+ 干草微粒
		float vor = voronoi_cell(wp * 0.40);
		float n = fbm(wp * 0.32, 3);
		return vec3(mix(0.84, 1.05, smoothstep(0.05, 0.55, vor)) * mix(0.94, 1.05, n));
	}
	if (biome == B_MOOR) {
		// 泥炭湿原：低频水洼斑 + 苔藓微纹（偏暗、低对比）
		float pools = fbm(wp * 0.45, 3);
		float pool_factor = smoothstep(0.55, 0.40, pools);
		float n = fbm(wp * 0.28, 2);
		return vec3(mix(0.88, 1.04, n) * mix(1.0, 0.80, pool_factor));
	}
	if (biome == B_FLOODPLAIN) {
		// 泛滥平原：曲流/牛轭斑（中频 fbm）+ 肥沃斑驳
		float n = fbm(wp * 0.30, 3);
		float ribbons = fbm(wp * 0.50 + vec2(9.0, -5.0), 2);
		float ribbon_mod = mix(1.0, 0.85, smoothstep(0.55, 0.42, ribbons));
		return vec3(mix(0.90, 1.08, n) * ribbon_mod);
	}
	if (biome == B_MESA) {
		// 方山：平顶 + 陡壁横向岩层条带（比 BADLANDS 更规整、更暖）
		float bands = sin(wp.y * 0.36 + fbm(wp * 0.10, 2) * 3.0) * 0.5 + 0.5;
		float rock = fbm(wp * 0.34, 3);
		return vec3(mix(0.88, 1.14, bands) * mix(0.94, 1.05, rock));
	}
	return vec3(1.0);
#endif
}

// ─── [landform 轴可视化 2026-06-25] 地貌专属着色配方 ─────────────────────────
// 职责：给"没有专属 terrain biome、仅靠高程无法辨识"的地貌补充视觉特征。
// 只处理 terrain 表达不了的 5 种：VOLCANO / PLATEAU / CANYON / RIFT_VALLEY / PEAK；
// 其余地貌（PLAIN/LOWLAND/HILL/MOUNTAIN/DELTA/BADLANDS/SALT_FLAT/水体）已由 terrain
// 着色覆盖，直接返回原色（emission=0）。
// 入参：landform id、世界坐标 wp、当前底色 col、坡度 slope_mag、河流距离场 flow。
// 返回 vec4：rgb=调制后底色，a=自发光强度（仅火山口 > 0，caller 乘 lava 色写入 emission）。
// 性能：仅匹配到的地貌像素才跑 voronoi/fbm；其余 early-return。mobile / q<1 走廉价纯色 tint。
vec4 landform_visual(int landform, vec2 wp, vec3 col, float slope_mag, float flow) {
	if (landform == LF_VOLCANO) {
		// [volcano-crater 2026-06-25] 环形山改由生成期高度场(中心火山口下凹 + 第一环环脊抬升)
		// 配合 hillshade 自然成形；着色仅压暗成深玄武岩并按坡度强调火山口内壁/环脊轮廓。
		// 移除旧的多点 voronoi 橙斑与自发光 → 几乎无发光、完全融入地形（emission 恒 0）。
		vec3 basalt = col * vec3(0.55, 0.52, 0.54);   // 压暗成深玄武岩
		float wall = smoothstep(0.20, 0.58, slope_mag); // 高坡度(口壁/环脊)更暗，凸显环形轮廓
		vec3 rgb = mix(basalt, basalt * vec3(0.78, 0.74, 0.72), wall);
#if !defined(MOBILE_QUALITY_LOW) && !defined(MOBILE_QUALITY_MID) && !defined(MOBILE_QUALITY_HIGH)
		if (visual_quality >= 1) {
			float rock = fbm(wp * 0.22, 2);            // 玄武岩纹理，破除纯色
			rgb *= mix(0.95, 1.06, rock);
		}
#endif
		return vec4(rgb, 0.0);
	}
	if (landform == LF_PLATEAU) {
		// 高原：平顶冷调微提亮 + 崖壁（高坡度）压暗描边，突出"抬升台地"轮廓
		float wall = smoothstep(0.18, 0.55, slope_mag);
		vec3 top = col * vec3(1.02, 1.02, 1.05);
		vec3 wallc = col * vec3(0.80, 0.76, 0.70);
		return vec4(mix(top, wallc, wall), 0.0);
	}
	if (landform == LF_CANYON) {
		// landform id 为 nearest 字段，不能驱动整格明暗。只在连续的坡壁和河道外缘
		// 施加克制的暖岩色；河流本体和没有几何特征的谷底保持原色。
		float wall = smoothstep(0.24, 0.62, slope_mag);
		float bank = smoothstep(river_threshold_low * 0.56, river_threshold_low * 0.94, flow)
				* (1.0 - smoothstep(river_threshold_low, river_threshold_high, flow));
		float dry_land = 1.0 - smoothstep(river_threshold_low, river_threshold_high, flow);
		float rock_mask = clamp(wall * 0.42 + bank * 0.24, 0.0, 0.48) * dry_land;
		vec3 warm_rock = col * vec3(1.055, 0.985, 0.925);
		vec3 rgb = mix(col, warm_rock, rock_mask);
#if !defined(MOBILE_QUALITY_LOW) && !defined(MOBILE_QUALITY_MID) && !defined(MOBILE_QUALITY_HIGH)
		if (visual_quality >= 1) {
			float band = fbm(wp * 0.20, 2);
			rgb *= mix(1.0, mix(0.985, 1.015, band), rock_mask);
		}
#endif
		return vec4(rgb, 0.0);
	}
	if (landform == LF_RIFT_VALLEY) {
		// 裂谷仅保留很弱的坡壁材质提示，体积完全由连续 normal/horizon 表达。
		float wall = smoothstep(0.30, 0.68, slope_mag) * 0.22;
		return vec4(mix(col, col * vec3(1.035, 0.985, 0.945), wall), 0.0);
	}
	if (landform == LF_PEAK) {
		// 高峰：裸岩更冷亮（积雪由雪盖层负责，这里只轻微提冷调岩色）
		return vec4(col * vec3(0.98, 1.00, 1.05), 0.0);
	}
	return vec4(col, 0.0);
}
