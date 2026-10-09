// vegetation.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// 职责：植被四季换色（Dissolve 翻面 + LUT 派色） + 植被轴 tint。
//        本文件提供"按 vegetation id × 季节相位"算颜色调制 tint 的全部 helper。
// 调用方：fragment() 陆地分支：
//          - vegetation_seasonal_tint_lut → 南/北半球各一次得到 north_tint /
//            south_tint，按 lat_signed smoothstep 软混合。
//          - vegetation_tint / biome_accepts_vegetation_tint → 植被轴叠加段
//            （仅在 PLAIN/HILL/MOUNTAIN/GRASSLAND 等"主色单一"地形启用）。
//          - vegetation_seasonal_tint / _dissolve 是历史/兼容版本（不消费 veg id），
//            目前 fragment 路径只调用 _lut 版本，但保留以便手动切换调试。
// 依赖（caller 必须先 include）：
//   - uniforms.gdshaderinc：V_* 常量 / V_COUNT / vegetation_season_lut /
//     vegetation_anomaly_shift / climate_anomaly。
//   - common_noise.gdshaderinc：fbm（Dissolve mask 由两层 fbm 叠加产生）。
// 性能（PERF）：vegetation_seasonal_tint_lut 单像素调用 2 次（南北各一次），每次
//                包含 2 次 fbm（octaves=2 + octaves=1，共约 3 个 octave 的纹理 fetch）；
//                陆地像素约 6 次 fbm 累计。可考虑把南北 mix 拆成单次 + 软 mask，
//                本轮不动。
// ─────────────────────────────────────────────────────────────────────────

// 返回乘性 tint（应用为 base * vegetation_seasonal_tint(...)）
// 2026-05-18 P0-A：拉大四季色板差异，让"植被随季节变化"成为肉眼可见的主导视觉信号。
//   春：嫩绿（明亮、略偏黄绿）
//   夏：深墨绿（浓郁、压暗黄轴）
//   秋：金黄+橙红（强暖偏移，蓝轴显著下沉）
//   冬：枯灰偏冷蓝（饱和度大幅压低、整体偏冷）
vec3 vegetation_seasonal_tint(float phase) {
	vec3 spring = vec3(0.96, 1.14, 0.82);  // 鲜嫩绿
	vec3 summer = vec3(0.66, 1.05, 0.58);  // 深墨绿
	vec3 autumn = vec3(1.30, 0.82, 0.42);  // 金黄橙红
	vec3 winter = vec3(0.62, 0.66, 0.78);  // 枯灰冷蓝
	if (phase < 1.0) return mix(spring, summer, phase);
	if (phase < 2.0) return mix(summer, autumn, phase - 1.0);
	if (phase < 3.0) return mix(autumn, winter, phase - 2.0);
	return mix(winter, spring, phase - 3.0);
}

// 2026-05-18 N9：经典 Dissolve（溶解）风格的季节换色——替代 N1 的"整体 lerp + 相位抖动"。
// 思路：
//   原 lerp 模型：mix(season_A, season_B, fract(phase))
//     → 所有像素同步、整片同时变色（即使加了 phase_jitter 也只是把"同步"换成"按低频
//       fbm 分块同步"，本质仍是软渐变）。
//   Dissolve 模型：每个像素从噪声图获得一个独立"相位阈值" noise ∈ [0,1]，当全局
//     fract(phase) 越过该阈值时，该像素瞬间（或在窄带 w 内）从 A 切到 B。整体效果就是
//     屏幕上看到"按 fbm 形状的色斑一片片先后翻面"，正是经典 Dissolve 质感。
// 数学：local_t = clamp((global_t - noise) / w + 0.5, 0, 1)，再用 smoothstep 软化。
//   w → 0 接近硬噪点边；w → 1 退化回普通 lerp。这里用 0.35 给出"明显但不刺眼"的破碎带。
// 多层噪声：用低频 + 高频 fbm 叠加，得到"大色块边缘破碎成细斑"的层次（避免单频纯圆斑）。
vec3 vegetation_seasonal_tint_dissolve(float phase, vec2 wp) {
	vec3 spring = vec3(0.96, 1.14, 0.82);
	vec3 summer = vec3(0.66, 1.05, 0.58);
	vec3 autumn = vec3(1.30, 0.82, 0.42);
	vec3 winter = vec3(0.62, 0.66, 0.78);
	// 取出"上一季 A"和"下一季 B"以及它们之间的进度 global_t = fract(phase)。
	int idx = int(floor(phase));
	float global_t = phase - float(idx);
	vec3 col_a;
	vec3 col_b;
	if (idx == 0)      { col_a = spring; col_b = summer; }
	else if (idx == 1) { col_a = summer; col_b = autumn; }
	else if (idx == 2) { col_a = autumn; col_b = winter; }
	else               { col_a = winter; col_b = spring; }
	// 两层 fbm 叠加得到每像素相位阈值：低频给"大色块"，高频给"边缘破碎细斑"。
	// 频率刻意与 N1/N2/N7 错开，避免和其它噪声层产生条带共振。
	float n_lo = fbm(wp * 0.050 + vec2(-11.0, 41.0), 2);
	float n_hi = fbm(wp * 0.180 + vec2( 27.0, -53.0), 1);
	float pix_threshold = clamp(n_lo * 0.70 + n_hi * 0.30, 0.0, 1.0);
	// Dissolve 过渡带：w 越小越像噪点撕裂感、w 越大越软。0.35 是经验值——
	// 既能让用户清楚看到"色斑在按形状先后翻面"，又不会留下大量同时存在的破碎噪点。
	const float DISSOLVE_W = 0.35;
	float local_t = (global_t - pix_threshold) / DISSOLVE_W + 0.5;
	float mask = smoothstep(0.0, 1.0, clamp(local_t, 0.0, 1.0));
	return mix(col_a, col_b, mask);
}

// ─── map-visual-overhaul-v1：按 vegetation id 的 LUT 派四季色 ────────────
// 与 vegetation_seasonal_tint_dissolve 同款 Dissolve 翻面 mask（保持已有"破碎边缘"质感），
// 但每种 vegetation 使用专属的四季 LUT —— 解决"所有植被同色换季"的视觉病灶。
// climate_anomaly 升高时按 vegetation_anomaly_shift[veg] 叠加（可正可负），
// 让苔原带北移、热带森林夏天偏旱化等长期视觉信号宏观可见。
vec3 vegetation_seasonal_tint_lut(int veg, float phase, vec2 wp) {
	int v = clamp(veg, 0, V_COUNT - 1);
	int idx = int(floor(phase));
	float global_t = phase - float(idx);
	int season_a = idx & 3;          // 上一季
	int season_b = (idx + 1) & 3;    // 下一季
	vec3 col_a = vegetation_season_lut[v * 4 + season_a].rgb;
	vec3 col_b = vegetation_season_lut[v * 4 + season_b].rgb;
	// Dissolve 翻面（与 _dissolve 共用频率 / 相位以保持视觉一致）
	float n_lo = fbm(wp * 0.050 + vec2(-11.0, 41.0), 2);
	float n_hi = fbm(wp * 0.180 + vec2( 27.0, -53.0), 1);
	float pix_threshold = clamp(n_lo * 0.70 + n_hi * 0.30, 0.0, 1.0);
	const float DISSOLVE_W = 0.35;
	float local_t = (global_t - pix_threshold) / DISSOLVE_W + 0.5;
	float mask = smoothstep(0.0, 1.0, clamp(local_t, 0.0, 1.0));
	vec3 col = mix(col_a, col_b, mask);
	// 长期 climate_anomaly 叠加：将 anomaly_shift 视为偏色（[-1,1] 区间），
	// 与基色按 abs(anomaly) 强度做 add 调整，避免在 anomaly=0 时改变现有外观。
	vec3 shift = vegetation_anomaly_shift[v].rgb;
	col += shift * climate_anomaly;
	return max(col, vec3(0.0));
}

// ─── Milestone 2：植被轴色相调制 ────────────────────────────────────────
// 返回乘性 tint（围绕 1.0 浮动），代表"在 biome 主色基础上的植被偏色"。
//   - 针叶林 / 北方林         → 偏墨青绿
//   - 草本植被               → 偏黄绿
//   - 干旱植被               → 偏黄褐
//   - 苔原 / 裸地            → 偏冷灰
// 仅在"主色不能完整表达植被"的地形上生效（PLAIN/HILL/MOUNTAIN/PEAK/LOWLAND/
// GRASSLAND），FOREST/JUNGLE/DESERT/SAVANNA/TAIGA 等 biome 主色已经精确，跳过。
vec3 vegetation_tint(int veg) {
	if (veg == V_TROPICAL_RAINFOREST) return vec3(0.78, 1.10, 0.78);
	if (veg == V_SUBTROPICAL_FOREST)  return vec3(0.82, 1.08, 0.78);
	if (veg == V_TROPICAL_DRY_FOREST) return vec3(0.92, 1.06, 0.74);
	if (veg == V_TEMPERATE_DECIDUOUS) return vec3(0.86, 1.08, 0.76);
	if (veg == V_TEMPERATE_CONIFER)   return vec3(0.78, 1.00, 0.74);
	if (veg == V_TAIGA)               return vec3(0.74, 0.96, 0.74);
	if (veg == V_BOREAL_SHRUB)        return vec3(0.85, 0.98, 0.78);
	if (veg == V_TEMPERATE_GRASSLAND) return vec3(0.92, 1.06, 0.76);
	if (veg == V_TEMPERATE_STEPPE)    return vec3(1.05, 1.02, 0.74);
	if (veg == V_MEDITERRANEAN_SHRUB) return vec3(1.00, 0.96, 0.78);
	if (veg == V_SAVANNA)             return vec3(1.08, 1.00, 0.72);
	if (veg == V_DESERT_SCRUB)        return vec3(1.10, 1.00, 0.78);
	if (veg == V_XERIC_DESERT)        return vec3(1.14, 1.02, 0.74);
	if (veg == V_OASIS_VEG)           return vec3(0.86, 1.10, 0.78);
	if (veg == V_TUNDRA)              return vec3(0.92, 0.96, 0.92);
	if (veg == V_ALPINE_TUNDRA)       return vec3(0.92, 0.94, 0.94);
	if (veg == V_ALPINE_MEADOW)       return vec3(0.88, 1.05, 0.82);
	if (veg == V_POLAR_DESERT)        return vec3(0.96, 0.96, 0.98);
	if (veg == V_MANGROVE)            return vec3(0.78, 1.02, 0.80);
	if (veg == V_SWAMP)               return vec3(0.84, 1.02, 0.80);
	if (veg == V_MARSH)               return vec3(0.88, 1.04, 0.82);
	return vec3(1.0);
}

// FOREST/JUNGLE/DESERT/SAVANNA/TAIGA/... 主色已经精确表达植被，跳过避免双倍饱和。
bool biome_accepts_vegetation_tint(int biome) {
	return (biome == B_PLAIN
		|| biome == B_HILL
		|| biome == B_MOUNTAIN
		|| biome == B_GRASSLAND);
}
