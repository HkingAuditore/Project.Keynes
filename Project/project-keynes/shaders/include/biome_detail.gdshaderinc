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
//                voronoi。分档：
//                  - 移动端 / 桌面 visual_quality<=1 + 已绑 terrain_detail_tex → 读烘焙 L8
//                  - 桌面 visual_quality>=2 → **完整 per-biome 程序配方**（不因 tiled
//                    绑了 L8 而早退；否则高画质永远看不到沙丘/林冠等纹理）
//                  - visual_quality==0 → 恒等 1.0
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
//
// [pixel-scale-detail 2026-11-03] 近景高频（手机主路径）：上面所有配方都是**固定世界
// 尺度**（k=0.12~1.20 ⇒ 纹素 5.5~0.83 world units），相机放大时被等比拉大；移动端更
// 彻底——它走 baked L8（单通道烘焙细节，纹素 ≈2 world units），近景完全没有高频。
// 现在对外入口 procedural_biome_detail() = 原配方 + 一层常量世界尺度的高频颗粒，
// 只按「参照图层的纹素投影到几个屏幕像素」交叉淡入（pk_near_detail_blend）。
// 低频项频率一律不动 ⇒ 缩放时 biome 大斑块不跳变；高频层世界尺度常量 ⇒ 纹理不游动。
// ─────────────────────────────────────────────────────────────────────────

#include "res://shaders/include/pixel_scale.gdshaderinc"

// ─── 锐利程序化贴图（不依赖 hex，世界坐标连续） ─────────────────────────

const float TERRAIN_DETAIL_BAKE_MIN = 0.70;
const float TERRAIN_DETAIL_BAKE_MAX = 1.30;

float terrain_macro_amplitude(int biome) {
	// [albedo-visibility 2026-07-31] 烘焙 L8 路径的幅度整体抬高：旧值 ±6~9% 在强法线
	// 明暗下几乎不可见。移动端/中画质仍走这条廉价路径，需要能读出地表差异。
	if (biome == B_MOUNTAIN || biome == B_HILL || biome == B_BADLANDS || biome == B_MESA) {
		return 0.16;
	}
	if (biome == B_FOREST || biome == B_JUNGLE || biome == B_TAIGA || biome == B_MANGROVE) {
		return 0.14;
	}
	if (biome == B_DESERT || biome == B_COLD_DESERT || biome == B_SALT_FLAT) {
		return 0.13;
	}
	if (biome == B_SWAMP || biome == B_DELTA || biome == B_FLOODPLAIN || biome == B_MOOR) {
		return 0.10;
	}
	if (biome == B_SNOW || biome == B_GLACIER) {
		return 0.07;
	}
	return 0.11;
}

// ─── [pixel-scale-detail 2026-11-03] 近景高频颗粒（乘性，围绕 1.0）─────────────
// 为什么不逐 biome 复制一份 3.5× 尺度变体：fbm(wp*k*3.5) 与 fbm(wp*k) 在给定点上
// 互不相干（同一张预积分噪声包的不同采样点），所以"3.5× 变体"与"另起一个高频场"
// 在视觉上是同一类东西；而这里只花**一次** fetch、只在一个地方调参，并且能同时
// 覆盖三条路径（baked L8 / vq==1 廉价 / vq>=2 全套配方）—— 逐分支复制会在每条
// 分支里各加一次 fetch，反而更贵、更容易在某个 biome 漏掉。
// 频率取 1.55（纹素 ≈0.645 world units）：比所有现有高频项（finest = JUNGLE 的
// 1/1.20 = 0.83）更细约 1.3×，在桌面 zoom 3 / 移动端 zoom 2.2 时是 1.9 / 1.4 px/纹素。
const float PK_NEAR_DETAIL_FREQ = 1.55;
const vec2 PK_NEAR_DETAIL_OFFSET = vec2(31.7, -17.3);
// 参照纹素的典型世界尺寸：烘焙 L8 detail（world≈2200 units / derived 1024 ≈2.1）与
// 程序 micro fbm（1/0.45 ≈2.22）量级一致，取 2.0 让两条路径共用同一套门控刻度。
const float PK_NEAR_DETAIL_REF_TEXEL_WORLD = 2.0;

// 返回乘性 detail（≈1.0）。t=0（远景/中景）时直接返回入参 ⇒ 连一次噪声采样都不付。
vec3 pk_apply_near_detail(vec3 detail, int biome, vec2 wp) {
	float t = pk_near_detail_blend(wp, PK_NEAR_DETAIL_REF_TEXEL_WORLD);
	if (t <= 0.001) {
		return detail;
	}
	// 幅度 0.19~0.23（规范建议 0.15~0.30 的中段）：岩/丘陵最碎，雪/冰最平
	// —— 近景白色噪点最刺眼，所以让 terrain_macro_amplitude 把雪地再压一档。
	float amp = 0.20 * (0.9 + 1.6 * terrain_macro_amplitude(biome));
	float grain = fbm(wp * PK_NEAR_DETAIL_FREQ + PK_NEAR_DETAIL_OFFSET, 2) - 0.5;
	return detail * (1.0 + grain * (t * amp));
}

#ifdef VT_USE_TERRAIN_DETAIL
vec3 baked_biome_detail(int biome, vec2 uv) {
	float d = visual_sample_terrain_detail(uv).r;
	float signal = clamp((mix(TERRAIN_DETAIL_BAKE_MIN, TERRAIN_DETAIL_BAKE_MAX, d) - 1.0)
			/ max(TERRAIN_DETAIL_BAKE_MAX - 1.0, 0.001), -1.0, 1.0);
	return vec3(1.0 + signal * terrain_macro_amplitude(biome));
}
#endif

// 原样保留的低频配方（含 vq<=0 早退）。对外只通过下面的 procedural_biome_detail()
// 调用，本函数不再直接被片段着色器引用。
vec3 procedural_biome_detail_base(int biome, vec2 wp, vec2 uv) {
	if (visual_quality <= 0) {
		return vec3(1.0);
	}
#if defined(PK_MOBILE_ANY)
	// 移动端始终走烘焙 L8（或跳过），不算完整程序配方。
#ifdef VT_USE_TERRAIN_DETAIL
	if (terrain_detail_available()) {
		return baked_biome_detail(biome, uv);
	}
#endif
	return vec3(1.0);
#else
	// [albedo-visibility 2026-07-31] 桌面高画质必须跑完整 per-biome 程序纹理。
	// 旧逻辑：只要绑了 terrain_detail（tiled 模式永远绑）就早退到单通道 L8，
	// 导致 visual_quality=2 时下方整段森林/沙丘/岩纹配方变成死代码——这就是
	// "高画质也看不出纹理"的根因。中画质继续用烘焙 L8 保性能。
	// [web-high-features 2026-11-01 / 方案 B] 非 tiled（含 Web/Compatibility）的
	// detail 已迁到 terrain_surface_tex layer2，`terrain_detail_available()` 对
	// tiled(2D 绑定)/非 tiled(layer_count>=3) 都成立；LOW(vq<=0) 在上方已早退。
#ifdef VT_USE_TERRAIN_DETAIL
	if (visual_quality < 2 && terrain_detail_available()) {
		return baked_biome_detail(biome, uv);
	}
#endif
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

// ─── [pixel-scale-detail 2026-11-03] 对外入口：低频配方 + 近景高频颗粒 ─────────
// 低频（决定 biome 大斑块）完全来自 procedural_biome_detail_base()，频率一个字没动；
// 高频颗粒只在近景（纹素投影 ≥2.5px，见 pk_near_detail_blend）叠加，成本 1 次噪声
// 采样，远景/中景 t=0 时一次都不采。
// vq<=0 由 base 早退成 vec3(1.0)，这里显式保持像素级恒等（LOW 契约：不许出现新噪声）。
vec3 procedural_biome_detail(int biome, vec2 wp, vec2 uv) {
	vec3 detail = procedural_biome_detail_base(biome, wp, uv);
	if (visual_quality <= 0) {
		return detail;
	}
	return pk_apply_near_detail(detail, biome, wp);
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
