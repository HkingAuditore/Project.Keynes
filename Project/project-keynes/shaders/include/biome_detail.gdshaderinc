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
//                voronoi。如做性能优化，可考虑：a) 把 fbm octaves 跟 visual_quality
//                联动；b) 把 voronoi/fbm 烘成 detail_atlas 由单次采样查表。
//                本轮不动。
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

vec3 procedural_biome_detail(int biome, vec2 wp) {
	// 60 FPS 优化（2026-06-15）：mobile 三档全跳 biome 内部纹理（1-3 fbm/voronoi 每 biome）
	// 视觉损失：陆地 biome 内部纯色（无纹理颗粒），但 biome 间颜色区分仍清晰。
#if defined(MOBILE_QUALITY_LOW) || defined(MOBILE_QUALITY_MID) || defined(MOBILE_QUALITY_HIGH)
	return vec3(1.0);  // 无 detail modulator
#else
	if (visual_quality <= 0) {
		return vec3(1.0);
	}
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
		// v10.3：上限 1.06×1.04=1.10，配合 hillshade 最多 ×1.6
		return vec3(mix(0.85, 1.06, n) * mix(0.95, 1.04, micro));
	}
	if (biome == B_MOUNTAIN) {
		float n = fbm(wp * 0.30, 4);
		float vor = voronoi_cell(wp * 0.16);
		// v10.3：上限从 1.20×1.10=1.32 降到 1.05×1.03=1.08
		// 配合 hillshade max 1.45 后总放大 ≤ 1.57，peak 色 (0.55) × 1.57 = 0.86 → 灰褐
		return vec3(mix(0.72, 1.05, n) * mix(0.92, 1.03, smoothstep(0.05, 0.5, vor)));
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
	return vec3(1.0);
#endif
}
