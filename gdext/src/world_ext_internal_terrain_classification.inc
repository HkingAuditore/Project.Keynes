// Internal terrain profile and terrain classification used in the anonymous namespace of world_ext_internal.h.

// ─── [P1 hypsometric remap 2026-06-25] 高程分段重映射（治平原/阶梯）─────────────────
// 在 normalize 之后对 land_h ∈ [0,1]（陆地相对海拔）应用一条单调三段曲线：低地段压平
// （出真平原）、中段做柔和台地（可辨但非硬 staircase）、高段陡升（拉开起伏、山更挺拔）。
// 端点固定 0→0、1→1；用 PCHIP（Fritsch–Carlson 单调限幅）保证 C1 连续 + 单调（不倒置高程序
// → 山仍最高、biome 序不乱）。控制点以 constexpr 落地，可一行调参。
//   Layer B（仿真高程 E，base pass）以 mix=1.0 施全曲线定结构；
//   Layer A（bake 期 per-pixel elev_blend）以小 mix 残差重锐化台地边缘（见 run_bake_terrain_index_pass）。
// 与 map_baker.gd 的 _make_hypso_curve / _hypso_remap_landh 逐位对齐。
constexpr int    PK_HYPSO_NP = 5;
// 形态：平原(低斜率压平) → 缓坡上台 → 台地 shelf(最平,可辨) → 高山陡升(拉开起伏)。
constexpr double PK_HYPSO_XS[PK_HYPSO_NP] = { 0.0, 0.32, 0.52, 0.70, 1.0 };
constexpr double PK_HYPSO_YS[PK_HYPSO_NP] = { 0.0, 0.34, 0.54, 0.70, 1.0 };
constexpr double PK_HYPSO_LAYER_A_MIX     = 0.0;   // [bimodal 2026-06-26] 置 0：双峰地台模型已直接产出平台，Layer A 关闭

// ─── [bimodal-hypsography 2026-06-26] 大陆-海洋高程：双峰测高(地台)模型参数 ─────────────
// 取代旧"径向穹顶"(elev∝离大陆中心距离)：用锐化的大陆性 mask 在「平坦深海平原」与「平坦大陆地台」
// 之间做陡过渡(大陆坡折→海岸陡坡)，山脉由独立造山带 ridged 信号叠加 → 复现地球双峰 hypsographic 曲线。
// 同时关闭 P1 Layer B(land 压平)与 #3 距岸 BFS 海洋加深(均被本模型吸收，constexpr 开关保留可回退)。
constexpr bool   PK_BIMODAL_ENABLED   = true;   // 主开关：false 回退旧径向穹顶 + P1/#3
constexpr double PK_CONT_RADIAL_W     = 1.00;   // 大陆距离场权重（主导大陆形状）
constexpr double PK_CONT_NOISE_W      = 0.40;   // fBm 海岸线扰动幅度（居中化，仅打皱海岸不抬基线）
constexpr double PK_CONT_THRESH       = 0.19;   // 海陆阈值(对 dist_field)：调小=大陆更大更整、内陆更干→生态更多样
                                                // [water-tuning 2026-06-26] 0.16→0.22→0.19：0.22 虽减陆地，但副作用是内陆抬升
                                                // lt=(C-0.5)*2 整体变缓 → 造山带 orogeny 被 lt 乘后高差变小、达 MOUNTAIN 阈值的格变少
                                                // → 山脉变矮变不显眼（用户反馈）。深海已改由下方"距岸距离驱动洋底深度"BFS 兜底，
                                                // 不再依赖高阈值开放洋面，故回调到 0.19（仍比原 0.16 略减陆地）以恢复山脉；山脉显眼度
                                                // 另由 PK_OROGENY_AMP 解耦增强。
constexpr double PK_CONT_MARGIN       = 0.05;   // 海陆过渡带宽（小→大陆坡越陡、海岸落差/法线越强）
constexpr double PK_POLAR_OCEAN       = 0.85;   // 极地大陆性衰减（→两极偏海/冰盖）
constexpr double PK_PLATFORM_H        = 0.07;   // 大陆地台高出海平面的平坦基面
constexpr double PK_PLATFORM_UNDULATE = 0.04;   // 地台大尺度起伏(很小，保持地台平坦)
                                                // [density-fix 2026-06-30] 0.03→0.04：略增地台起伏，
                                                // 减少完美平坦的中等海拔区（这些区域此前批量落入 PLATEAU）。
                                                // platform_max 现 = 0.07+0.04+0.48 = 0.59，e_out_max = 0.42+0.59 = 1.01，
                                                // 仅极少数最高内陆峰顶被 clamp 至 1.0（0.01 差异，视觉不可见）。
constexpr double PK_OCEAN_DEPTH_FRAC  = 0.90;   // 深海平原深度 = sea_level × 此值（越大越深）
constexpr double PK_OROGENY_AMP       = 0.48;   // 造山带最大抬升(山脉相对地台的高度)
                                                // [water-tuning 2026-06-26] 0.42→0.48：与陆地占比(CONT_THRESH)解耦地增强山脉显眼度，
                                                // 补偿 CONT_THRESH 调整对内陆抬升的影响。platform_max=PLATFORM_H+UNDULATE+AMP=0.59,
                                                // e_out_max=sea_level(0.42)+lt(≤1)*0.59=1.01，仅极少数最高峰顶被 clamp 至 1.0（0.01 差异，可忽略）。
constexpr double PK_OROG_SHARP        = 1.6;    // ridged 锐度(大→山脊更尖窄)
constexpr double PK_OROG_BELT_LO      = 0.42;   // 造山带 belt 下阈(控制山系覆盖)
constexpr double PK_OROG_BELT_HI      = 0.72;   // 造山带 belt 上阈


struct PkHypsoCurve {
    double xs[PK_HYPSO_NP], ys[PK_HYPSO_NP], m[PK_HYPSO_NP];
    // 单调 cubic Hermite 求值（x 在 [0,1]，端点外 clamp 到端点值）。
    double eval(double x) const {
        if (x <= xs[0]) return ys[0];
        if (x >= xs[PK_HYPSO_NP - 1]) return ys[PK_HYPSO_NP - 1];
        int k = 0;
        while (k < PK_HYPSO_NP - 2 && x >= xs[k + 1]) ++k;
        const double h = xs[k + 1] - xs[k];
        const double t = (x - xs[k]) / h;
        const double t2 = t * t, t3 = t2 * t;
        const double h00 =  2.0 * t3 - 3.0 * t2 + 1.0;
        const double h10 =        t3 - 2.0 * t2 + t;
        const double h01 = -2.0 * t3 + 3.0 * t2;
        const double h11 =        t3 -       t2;
        return h00 * ys[k] + h10 * h * m[k] + h01 * ys[k + 1] + h11 * h * m[k + 1];
    }
};

// 由 constexpr 控制点构造曲线切线（Fritsch–Carlson 单调限幅），每 pass 调一次（非热循环）。
static PkHypsoCurve pk_make_hypso_curve() {
    PkHypsoCurve c;
    for (int i = 0; i < PK_HYPSO_NP; ++i) { c.xs[i] = PK_HYPSO_XS[i]; c.ys[i] = PK_HYPSO_YS[i]; }
    double d[PK_HYPSO_NP - 1];
    for (int i = 0; i < PK_HYPSO_NP - 1; ++i) d[i] = (c.ys[i + 1] - c.ys[i]) / (c.xs[i + 1] - c.xs[i]);
    c.m[0] = d[0];
    c.m[PK_HYPSO_NP - 1] = d[PK_HYPSO_NP - 2];
    for (int i = 1; i < PK_HYPSO_NP - 1; ++i) {
        c.m[i] = (d[i - 1] * d[i] <= 0.0) ? 0.0 : (d[i - 1] + d[i]) * 0.5;
    }
    for (int i = 0; i < PK_HYPSO_NP - 1; ++i) {
        if (d[i] == 0.0) { c.m[i] = 0.0; c.m[i + 1] = 0.0; continue; }
        const double a = c.m[i] / d[i], b = c.m[i + 1] / d[i];
        const double s = a * a + b * b;
        if (s > 9.0) {
            const double tau = 3.0 / std::sqrt(s);
            c.m[i]     = tau * a * d[i];
            c.m[i + 1] = tau * b * d[i];
        }
    }
    return c;
}

// 锚定 sea_level 的便捷封装：仅重塑陆地段（e>sea），below-sea 原样返回；mix<1 时与原值线性混合。
static inline double pk_hypso_remap_elev(const PkHypsoCurve &c, double e,
                                         double sea, double inv_above, double above, double mix) {
    if (e <= sea || inv_above <= 0.0) return e;
    const double lh  = (e - sea) * inv_above;
    const double lhr = c.eval(lh);
    const double mixed = (mix >= 1.0) ? lhr : (lh + (lhr - lh) * mix);
    return sea + mixed * above;
}

// SAME_SOURCE: map_generator.gd::_decide_terrain (permanent_only parameter mirrored).
// 返回值是 TerrainType.TERRAIN 整数：
//   OCEAN=0 / COAST=1 / SNOW=9 / MOUNTAIN=6 / TUNDRA=8 / HILL=5 /
//   JUNGLE=11 / SAVANNA=12 / DESERT=7 / FOREST=4 / GRASSLAND=3 / STEPPE=14 /
//   TAIGA=13 / PLAIN=2.
static inline uint8_t pk_decide_terrain_ex(double elevation, double temperature,
                                           double moisture, double sea_level,
                                           bool permanent_only) {
    if (elevation < sea_level - 0.06) return 0; // OCEAN
    if (elevation < sea_level) return 1;        // COAST

    const double denom = (1.0 - sea_level) > 0.001 ? (1.0 - sea_level) : 0.001;
    const double land_h = (elevation - sea_level) / denom;
    const double geomorph_h = pk_geomorph_h(elevation, sea_level);

    const double snow_line = permanent_only ? 0.85 : 0.82;
    const double snow_line_temp = permanent_only ? 0.26 : 0.34;
    const double cold_snow_line = permanent_only ? 0.70 : 0.55;
    const double cold_snow_temp = permanent_only ? 0.05 : 0.08;
    const double polar_temp = permanent_only ? -1.0 : 0.03;

    if (land_h > snow_line && temperature < snow_line_temp) return 9;       // SNOW
    if (land_h > cold_snow_line && temperature < cold_snow_temp) return 9;  // SNOW
    if (temperature < polar_temp) return 9;                                 // SNOW

    // ── terrain-overhaul Phase 4 统一分类器：landform 与 biome 解耦 ──
    // 仅"真高山"保留 MOUNTAIN 地形(裸岩高差)；旧 land_h>0.22→HILL 的大面积压扁已删除——
    // 中高海拔交回气候 biome 决定，山地起伏改由 pk_derive_landform 派生(HILL/MOUNTAIN/PEAK
    // landform)，植被由 pk_derive_vegetation 按 is_alpine 给高山草甸/高山针叶林。直接提升
    // 中高海拔生物群系多样性，不再把温带森林/草原压成统一 HILL。
    const double mountain_line = permanent_only ? 0.72 : 0.70;
    if (geomorph_h > mountain_line) return 6;  // MOUNTAIN（真高山裸岩）
    if (temperature < 0.20) return 8;      // TUNDRA（寒冷无林）

    // Whittaker：温度×湿度联立气候 biome，覆盖全部中/低海拔（起伏交给 landform）。
    // 旧热带门 JUNGLE 过宽会吞掉季风林；连续雨林现在只占湿尾，
    // 赤道带几乎拿不到 JUNGLE→雨林，被压成 SAVANNA→MONSOON。湿端阈值整体下移贴合实际分布；
    // 并把旧单一"热带(>0.55)"拆成真热带(>0.66 赤道暖湿)与亚热带/暖温带(0.55–0.66)，
    // 让 FOREST 地形在亚热带可达，修复 pk_derive_vegetation case FOREST 的 temp>0.55
    // 亚热带林死分支(原 FOREST 仅 0.38–0.55 存在→SUBTROPICAL_FOREST 永不可达)。
    // [zonal-envelope 2026-08-01] 温度带边界按 lat_temp_bell(exp=1.3) 重新标定到地理纬度：
    //   旧"真热带 >0.66"≈距赤道 43°，把温带漏斗进热带干端分类；新 0.80≈33°（回归线外缘）。
    //   亚热带 0.55–0.80≈33–51°、温带 0.38–0.55≈51–62°、寒带 0.20–0.38≈62–77°。
    // 湿度门槛配合新 base_moisture 纬带分布（赤道 mean≈0.45、副热带≈0.22-0.29、
    // 中纬≈0.31、风暴路径海岸 0.45+）校准：温带 FOREST 0.55→0.46 让温带森林回归，
    // 温带 GRASSLAND/STEPPE 下移收窄草原漏斗；JUNGLE 0.54 边界对齐规则保持不变。
    if (temperature > 0.80) {              // 真热带（赤道带，0–33°）
        if (moisture > 0.64) return 11;    // JUNGLE → 连续湿润热带森林
        if (moisture > 0.32) return 12;    // SAVANNA
        // [zonal-envelope 二轮] 热带草系干端 0.20→0.24：游戏内实测草原系 39.9% 仍偏高，
        // 干端 0.20-0.24 带转真荒漠（萨赫勒干缘收紧），与 whittaker SAVANNA 下限同步。
        if (moisture > 0.24) return 14;    // STEPPE（干热草）
        return 7;                          // DESERT
    }
    if (temperature > 0.55) {              // 亚热带 / 暖温带（33–51°，湿端→亚热带常绿林）
        if (moisture > 0.40) return 4;     // FOREST → 派生 SUBTROPICAL_FOREST（0.36→0.40 防森林超带）
        if (moisture > 0.24) return 3;     // GRASSLAND
        if (moisture > 0.16) return 14;    // STEPPE
        return 7;                          // DESERT（副热带荒漠）
    }
    if (temperature > 0.38) {              // 温带（51–62°）
        if (moisture > 0.42) return 4;     // FOREST（扩大中纬湿润森林带）
        if (moisture > 0.28) return 3;     // GRASSLAND（0.32→0.28：收窄草原漏斗）
        if (moisture > 0.16) return 14;    // STEPPE
        return 7;                          // DESERT（温带内陆荒漠）
    }
    // 凉温带 / 北方带（0.20–0.38）
    if (moisture > 0.45) return 13;        // TAIGA
    // [water-tuning 2026-06-26] STEPPE(温带草原)加温度下限：实测 32.8% 的 STEPPE 落在 temp<0.30 的
    // 凉冷/亚极地带 → 视觉上"高纬出现温带草原"。仅 temp>0.30 的暖凉温带保留 STEPPE；更冷的凉温带
    // 按湿度回落到针叶林/苔原/寒漠，符合亚极地地理。
    if (temperature > 0.30) {
        if (moisture > 0.22) return 14;    // STEPPE（温带草原，限暖凉温带）
        return 26;                         // COLD_DESERT
    }
    // 冷凉温带 / 亚极地（0.20–0.30）：不再判温带草原
    if (moisture > 0.28) return 13;        // TAIGA（湿→针叶林）
    if (moisture > 0.16) return 8;         // TUNDRA（中湿→苔原/草甸）
    return 26;                             // COLD_DESERT（寒漠：冷而极旱，区别于热沙漠）
}

static inline uint8_t pk_decide_terrain(double elevation, double temperature,
                                        double moisture, double sea_level) {
    return pk_decide_terrain_ex(elevation, temperature, moisture, sea_level, false);
}
