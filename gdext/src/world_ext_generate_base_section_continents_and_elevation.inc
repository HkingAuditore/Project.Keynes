    // ── 大陆中心点：与 _make_continent_centers + _try_place 逐位同源 ──
    // GDScript `_rng.seed = effective_seed`（无 xor 混淆），用 Godot RNG 同款 PCG。
    struct Center {
        double x;
        double y;
        double radius;
    };
    std::vector<Center> centers;
    centers.reserve(size_t(std::max(1, num_continents) * (1 + std::max(0, satellites_per_main))));
    Ref<RandomNumberGenerator> rng;  rng.instantiate();
    if (rng.is_null()) {
        return fail("rng_instantiate_failed", "rng");
    }
    rng->set_seed(uint64_t(seed));
    const double base_radius_unit = continent_size * 0.6;
    const int n_main = std::max(1, num_continents);
    const int n_satellite = n_main * std::max(0, satellites_per_main);
    auto try_place = [&](double radius, double lo, double hi, double sep_factor, int attempts) -> void {
        for (int attempt = 0; attempt < attempts; ++attempt) {
            const double px = double(rng->randf_range(lo, hi));
            const double py = double(rng->randf_range(lo, hi));
            bool ok = true;
            for (const Center &c : centers) {
                // [cylindrical-earth-daylight] 经度环绕最短距离 → 中心间距在接缝处也正确，避免左右各放一坨。
                double dx = std::fabs(px - c.x);
                if (dx > 0.5) dx = 1.0 - dx;
                const double dy = py - c.y;
                const double d = std::sqrt(dx * dx + dy * dy);
                if (d < (radius + c.radius) * sep_factor) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                centers.push_back(Center{px, py, radius});
                return;
            }
        }
    };
    for (int i = 0; i < n_main; ++i) {
        const double radius = (main_radius_min + (main_radius_max - main_radius_min) * double(rng->randf())) * base_radius_unit;
        try_place(radius, main_place_min, main_place_max, main_sep, 50);
    }
    for (int i = 0; i < n_satellite; ++i) {
        const double radius = (sat_radius_min + (sat_radius_max - sat_radius_min) * double(rng->randf())) * base_radius_unit;
        try_place(radius, sat_place_min, sat_place_max, sat_sep, 30);
    }

    // ── 板块构造基底（terrain-overhaul Phase 0）─────────────────────────────
    // 用 Voronoi 板块（泊松散点 + Lloyd 松弛）替代放射状大陆中心：每板块标 oceanic/
    // continental + 漂移向量；会聚边界沿板块缝隙抬升线状山脉带/岛弧，离散边界成洋中脊/
    // 裂谷。基础海拔 = 板块基线(跨边界平滑混合) + 边界抬升，再叠 fBm 细节。tectonic_blend
    // 在板块场与旧放射场之间插值（默认偏板块，可调回 0 降风险）。
    // 回归修复(2026-06-18)：默认回退到放射状大陆(0.0)。板块基线归一化后会把全图抬成超大
    // 高原大陆，导致过冷/枯干/山地荒漠铺满。代码保留，重新标定前默认关闭。
    const double tectonic_blend = pk_clamp01(getd(profile, "tectonic_blend", 0.0));
    const int tectonic_plate_count = std::max(3, std::min(40, geti(profile, "tectonic_plate_count", 14)));
    const double tectonic_continental_fraction = pk_clamp01(getd(profile, "tectonic_continental_fraction", 0.45));
    const double tectonic_continental_base = getd(profile, "tectonic_continental_base", 0.62);
    const double tectonic_oceanic_base = getd(profile, "tectonic_oceanic_base", 0.15);
    const double tectonic_uplift_amp = getd(profile, "tectonic_uplift_amp", 0.55);
    const double tectonic_ridge_width = std::max(0.005, getd(profile, "tectonic_ridge_width", 0.06));
    const double tectonic_drift_speed = getd(profile, "tectonic_drift_speed", 1.0);
    const int tectonic_lloyd_iters = std::max(0, std::min(6, geti(profile, "tectonic_lloyd_iters", 2)));

    struct Plate { double x, y; double dx, dy; bool continental; double base_h; };
    std::vector<Plate> plates;
    if (tectonic_blend > 0.0) {
        Ref<RandomNumberGenerator> prng;  prng.instantiate();
        if (prng.is_valid()) prng->set_seed(uint64_t(seed) + 4400ull);
        plates.reserve(size_t(tectonic_plate_count));
        for (int i = 0; i < tectonic_plate_count; ++i) {
            Plate p;
            p.x = prng.is_valid() ? double(prng->randf()) : 0.5;
            p.y = prng.is_valid() ? double(prng->randf()) : 0.5;
            const double ang = (prng.is_valid() ? double(prng->randf()) : 0.0) * 2.0 * M_PI;
            const double spd = tectonic_drift_speed * (0.4 + 0.6 * (prng.is_valid() ? double(prng->randf()) : 0.5));
            p.dx = simulation_math::cos(ang) * spd;
            p.dy = simulation_math::sin(ang) * spd;
            p.continental = (prng.is_valid() ? double(prng->randf()) : 0.5) < tectonic_continental_fraction;
            p.base_h = p.continental ? tectonic_continental_base : tectonic_oceanic_base;
            plates.push_back(p);
        }
        // Lloyd 松弛：32x32 采样网格 → 质心，去聚集得到近泊松分布。
        for (int it = 0; it < tectonic_lloyd_iters && plates.size() > 1; ++it) {
            constexpr int G = 32;
            std::vector<double> ax(plates.size(), 0.0), ay(plates.size(), 0.0);
            std::vector<int> cnt(plates.size(), 0);
            for (int gy = 0; gy < G; ++gy) {
                for (int gx = 0; gx < G; ++gx) {
                    const double sx = (double(gx) + 0.5) / double(G);
                    const double sy = (double(gy) + 0.5) / double(G);
                    int best = 0; double bestd = 1e30;
                    for (size_t p = 0; p < plates.size(); ++p) {
                        const double ddx = sx - plates[p].x, ddy = sy - plates[p].y;
                        const double dd = ddx * ddx + ddy * ddy;
                        if (dd < bestd) { bestd = dd; best = int(p); }
                    }
                    ax[size_t(best)] += sx; ay[size_t(best)] += sy; cnt[size_t(best)]++;
                }
            }
            for (size_t p = 0; p < plates.size(); ++p) {
                if (cnt[p] > 0) { plates[p].x = ax[p] / double(cnt[p]); plates[p].y = ay[p] / double(cnt[p]); }
            }
        }
    }
    auto tectonic_elev_at = [&](double nx, double ny, double dist_perturb) -> double {
        int p0 = -1, p1 = -1;
        double d0 = 1e30, d1 = 1e30;
        for (size_t p = 0; p < plates.size(); ++p) {
            const double ddx = nx - plates[p].x;
            const double ddy = ny - plates[p].y;
            const double dd = std::sqrt(ddx * ddx + ddy * ddy) + dist_perturb;
            if (dd < d0) { d1 = d0; p1 = p0; d0 = dd; p0 = int(p); }
            else if (dd < d1) { d1 = dd; p1 = int(p); }
        }
        if (p0 < 0) return tectonic_oceanic_base;
        if (p1 < 0) return plates[size_t(p0)].base_h;
        const double denom = std::max(d0 + d1, 1e-6);
        const double w1 = d0 / denom; // 越靠近边界 → 对方板块权重越大(被动陆缘/大陆架)
        double base = plates[size_t(p0)].base_h * (1.0 - w1) + plates[size_t(p1)].base_h * w1;
        const double bf = 1.0 - pk_smoothstep(0.0, tectonic_ridge_width, std::fabs(d1 - d0));
        if (bf > 0.0) {
            const Plate &A = plates[size_t(p0)];
            const Plate &B = plates[size_t(p1)];
            double n01x = B.x - A.x, n01y = B.y - A.y;
            const double nl = std::sqrt(n01x * n01x + n01y * n01y);
            if (nl > 1e-6) { n01x /= nl; n01y /= nl; }
            double approach = (A.dx * n01x + A.dy * n01y) - (B.dx * n01x + B.dy * n01y);
            if (approach > 1.5) approach = 1.5;
            else if (approach < -1.5) approach = -1.5;
            if (approach > 0.0) {
                base += bf * approach * tectonic_uplift_amp; // 会聚：山脉带/岛弧
            } else {
                const bool both_ocean = !A.continental && !B.continental;
                if (both_ocean) base += bf * (-approach) * tectonic_uplift_amp * 0.35; // 洋中脊
                else base -= bf * (-approach) * tectonic_uplift_amp * 0.30;            // 裂谷
            }
        }
        return base;
    };
    (void)tectonic_elev_at;  // [bimodal 2026-06-26] 双峰路径不调用（tectonic 仍保留作回退基础设施）

    PackedInt32Array q_arr;
    PackedInt32Array r_arr;
    PackedInt32Array s_arr;
    PackedFloat32Array elevation_arr;
    PackedFloat32Array moisture_arr;
    PackedFloat32Array base_moisture_arr;
    PackedFloat32Array temp_arr;
    PackedFloat32Array temp_baseline_arr;
    PackedFloat32Array temp_30d_arr;
    PackedFloat32Array temp_365d_arr;
    PackedFloat32Array temp_anomaly_arr;
    PackedFloat32Array thermal_energy_arr;
    PackedFloat32Array cell_lat_norm_arr;
    PackedFloat32Array temp_baseline_year_arr;
    PackedFloat32Array snow_cover_arr;
    PackedByteArray terrain_arr;
    PackedByteArray base_terrain_arr;
    PackedByteArray landform_arr;
    PackedByteArray base_landform_arr;
    PackedByteArray vegetation_arr;
    PackedByteArray base_vegetation_arr;
    PackedByteArray cover_arr;
    PackedByteArray is_water_arr;
    PackedByteArray ema_initialized_arr;

    q_arr.resize(n);
    r_arr.resize(n);
    s_arr.resize(n);
    elevation_arr.resize(n);
    moisture_arr.resize(n);
    base_moisture_arr.resize(n);
    temp_arr.resize(n);
    temp_baseline_arr.resize(n);
    temp_30d_arr.resize(n);
    temp_365d_arr.resize(n);
    temp_anomaly_arr.resize(n);
    thermal_energy_arr.resize(n);
    cell_lat_norm_arr.resize(n);
    temp_baseline_year_arr.resize(n);
    snow_cover_arr.resize(n);
    terrain_arr.resize(n);
    base_terrain_arr.resize(n);
    landform_arr.resize(n);
    base_landform_arr.resize(n);
    vegetation_arr.resize(n);
    base_vegetation_arr.resize(n);
    cover_arr.resize(n);
    is_water_arr.resize(n);
    ema_initialized_arr.resize(n);

    int32_t *Q = q_arr.ptrw();
    int32_t *R = r_arr.ptrw();
    int32_t *S = s_arr.ptrw();
    float *E = elevation_arr.ptrw();
    float *M = moisture_arr.ptrw();
    float *BM = base_moisture_arr.ptrw();
    float *T = temp_arr.ptrw();
    float *TB = temp_baseline_arr.ptrw();
    float *T30 = temp_30d_arr.ptrw();
    float *T365 = temp_365d_arr.ptrw();
    float *TA = temp_anomaly_arr.ptrw();
    float *TH = thermal_energy_arr.ptrw();
    float *LAT = cell_lat_norm_arr.ptrw();
    float *TY = temp_baseline_year_arr.ptrw();
    float *SNOW = snow_cover_arr.ptrw();
    uint8_t *TERR = terrain_arr.ptrw();
    uint8_t *BTERR = base_terrain_arr.ptrw();
    uint8_t *LF = landform_arr.ptrw();
    uint8_t *BLF = base_landform_arr.ptrw();
    uint8_t *VEG = vegetation_arr.ptrw();
    uint8_t *BVEG = base_vegetation_arr.ptrw();
    uint8_t *COV = cover_arr.ptrw();
    uint8_t *IW = is_water_arr.ptrw();
    uint8_t *EMA = ema_initialized_arr.ptrw();

    const auto t0 = std::chrono::high_resolution_clock::now();
    const double inv_w = 1.0 / double(std::max(width - 1, 1));
    const double inv_h = 1.0 / double(std::max(height - 1, 1));

    constexpr int DQ[6] = { 1, 1, 0, -1, -1, 0 };
    constexpr int DR[6] = { 0, -1, -1, 0, 1, 1 };
    auto index_for_qr = [&](int q, int r) -> int {
        // [cylindrical-earth-daylight] 东西经度环绕：r(南北)保持硬边界返回 -1，
        // col(经度)用 posmod 绕回 [0,width) → 生成期邻居访问与运行时 map_data 一样东西连通；
        // 雨影 upwind 探针、侵蚀/水文 BFS 等读此函数的 pass 自动获得东西环绕。
        if (r < 0 || r >= height) return -1;
        int col = q + ((r - (r & 1)) / 2);
        col = ((col % width) + width) % width;
        return r * width + col;
    };

    // [cylindrical-earth-daylight] 圆柱噪声采样 helper：把经度轴(nx∈[0,1))映射到半径
    // scale/TWO_PI 的圆环 (cosθ,sinθ)，纬度走 z 轴线性。圆周长 = scale → 与原 nx*scale
    // 特征尺度一致；col=0 与 col=width 处 (cosθ,sinθ) 严格相等 → 海拔/气候/湖等噪声东西无缝。
    // PK_TWO_PI 为文件作用域常量（见上方定义）→ 无捕获 lambda 可直接用、不触发 MSVC C3493。
    auto cyl_noise = [](FastNoiseLite *nz, double ct, double st, double ny, double scale,
                        double ox, double oy, double oz) -> double {
        const double rc = scale / PK_TWO_PI;
        return double(nz->get_noise_3d(ct * rc + ox, st * rc + oy, ny * scale + oz));
    };

    // 地台起伏 / 造山带 / 山脊噪声按格距定义：大图得到更多、同等格尺寸的山系，而不是把
    // 参考图的山系整体放大（放大后格间高差 ∝ 1/s，内陆读成平地）。大陆轮廓仍按整图定义。
    // N <= feature_ref_cells 时 feature_scale=1，与旧行为逐位一致。
    const double feature_ref_cells = std::max(100.0, getd(profile, "feature_ref_cells", 2400.0));
    const double feature_scale = simulation_math::pow(std::max(1.0, std::sqrt(double(width) * double(height) / feature_ref_cells)),
                                          std::clamp(getd(profile, "feature_scale_exp", 1.0), 0.0, 1.0));

    // ── 1. coords + elevation —— 镜像 _compute_elevation（行主序，与 all_cells() 一致）──
    for (int row = 0; row < height; ++row) {
        for (int col = 0; col < width; ++col) {
            const int idx = row * width + col;
            const int q = col - ((row - (row & 1)) / 2);
            Q[idx] = q;
            R[idx] = row;
            S[idx] = -q - row;
            LAT[idx] = float(double(row) * inv_h);

            const double nx = double(col) * inv_w;   // [0,1] 含端点：仅保留给 tectonic_elev_at（默认关闭）
            (void)nx;                                 // [bimodal] 双峰路径不用 nx（tectonic 旁路）
            const double ny = double(row) * inv_h;
            // [cylindrical-earth-daylight] 经度坐标 period=width（lon=col/width∈[0,1)）：col=0 与
            // col=width-1 仅差 1 角步、相邻而非重合（若用 col/(width-1) 会让首尾列采到同一角→"双列"接缝）。
            const double lon = double(col) / double(width);
            const double theta = PK_TWO_PI * lon;   // 经度角（周期）→ 东西无缝
            const double ct = simulation_math::cos(theta);
            const double st = simulation_math::sin(theta);
            const double dist_perturb = cyl_noise(height_warp.ptr(), ct, st, ny, 250.0, 11.3, -7.1, 0.0) * continent_warp_amp;
            // [bimodal-hypsography 2026-06-26] 大陆距离场（不再 pow → 当 mask 种子而非穹顶）。
            double dist_field = 0.0;
            for (const Center &c : centers) {
                // [cylindrical-earth-daylight] 经度环绕最短距离 → 大陆可跨接缝、东西无缝。
                double dx = std::fabs(lon - c.x);
                if (dx > 0.5) dx = 1.0 - dx;
                const double dy = ny - c.y;
                const double d = std::sqrt(dx * dx + dy * dy) + dist_perturb;
                const double df = pk_clamp01(1.0 - d / c.radius);
                if (df > dist_field) dist_field = df;
            }
            // [cylindrical-earth-daylight] 大陆形状 fBm（domain-warp，圆柱无缝）。
            const double rc200 = 200.0 / PK_TWO_PI;
            const double cx = ct * rc200;
            const double cy = st * rc200;
            const double cz = ny * 200.0;
            const double u_warp = double(height_warp->get_noise_3d(cx + 11.3, cy - 7.1, cz)) * 35.0;
            const double v_warp = double(height_warp->get_noise_3d(cx - 23.7, cy + 41.5, cz)) * 35.0;
            const double c1 = double(height_noise->get_noise_3d(cx + u_warp, cy + v_warp, cz));
            const double c2 = double(detail_noise->get_noise_3d(cx * 1.7 + u_warp, cy * 1.7 + v_warp, cz * 1.7));
            const double cont_noise = ((c1 * 0.70 + c2 * 0.30) + 1.0) * 0.5;
            const double offshore_raw = cyl_noise(detail_noise.ptr(), ct, st, ny, 900.0, -333.0, 217.0, 0.0);
            const double offshore = simulation_math::pow(std::max(offshore_raw - 0.55, 0.0), 1.5) * offshore_amp;  // 近海岛屿
            const double macro = cyl_noise(height_noise.ptr(), ct, st, ny, 95.0 * feature_scale, 701.0, -419.0, 0.0);   // 大尺度起伏
            // 极地纬度衰减（双峰下用于降低极地大陆性；旧路径下仍用于减高程）。
            const double edge_dy = std::fabs(ny - 0.5) * 2.0;
            const double edge_perturb = cyl_noise(height_warp.ptr(), ct, st, ny, 150.0, 199.0, -73.0, 0.0) * 0.38;
            const double edge_t = pk_smoothstep(edge_falloff_start, edge_falloff_end, edge_dy + edge_perturb);

            double e_out;
            if (PK_BIMODAL_ENABLED) {
                // ── 双峰地台模型：大陆性 mask → 平坦大陆地台 / 平坦深海平原 + 陡大陆坡折 + 造山带 ──
                double cont = dist_field * PK_CONT_RADIAL_W + (cont_noise - 0.5) * PK_CONT_NOISE_W + offshore;
                cont *= (1.0 - edge_t * PK_POLAR_OCEAN);   // 极地偏海/冰盖
                const double C = pk_smoothstep(PK_CONT_THRESH - PK_CONT_MARGIN,
                                               PK_CONT_THRESH + PK_CONT_MARGIN, cont);  // 锐化→陡坡折
                // 造山带：ridged(1-|n|，成脉) × 低频 belt(成带) → 成脉山系；仅陆地(随 C)。
                const double ro1 = cyl_noise(height_noise.ptr(), ct, st, ny, 115.0 * feature_scale, 313.0, -271.0, 0.0);
                const double ro2 = cyl_noise(detail_noise.ptr(), ct, st, ny, 57.0 * feature_scale, -191.0, 421.0, 0.0);
                double ridge = (1.0 - std::fabs(ro1)) * 0.7 + (1.0 - std::fabs(ro2)) * 0.3;
                ridge = pk_clamp01(ridge);
                const double belt_n = cyl_noise(detail_noise.ptr(), ct, st, ny, 70.0 * feature_scale, 137.0, -91.0, 0.0);
                const double belt = pk_smoothstep(PK_OROG_BELT_LO, PK_OROG_BELT_HI, (belt_n + 1.0) * 0.5);
                const double orogeny = simulation_math::pow(ridge, PK_OROG_SHARP) * belt * PK_OROGENY_AMP;
                // 合成：海岸线定在 C=0.5。陆地从海岸(sea)抬到内陆平台(含造山) → 内陆平坦 + 海岸上坡(海岸法线)；
                // 水侧仅占位(确保 E<sea)，真实深度由下面 #3 距岸 BFS 重塑出大陆架→坡→深渊。跳过 min/max normalize。
                const double platform = PK_PLATFORM_H + macro * PK_PLATFORM_UNDULATE + orogeny;
                if (C >= 0.5) {
                    const double lt = (C - 0.5) * 2.0;          // 0=海岸 → 1=内陆（margin 内成海岸坡，之后平台）
                    e_out = sea_level + lt * platform;
                } else {
                    // [water-tuning 2026-06-26] 此处仅产出"水侧占位深度"(确保 E<sea_level，供 dist_ocean
                    // 与海陆 mask 正确播种)；最终洋底深度由上文 dist_ocean 之后的"距岸距离驱动洋底深度"
                    // BFS 统一重写。凹幂律(p=0.62)使占位本身也呈架→坡过渡，BFS 关闭时仍是合理回退。
                    const double wt = simulation_math::pow(pk_clamp01((0.5 - C) * 2.0), 0.62);          // 0=海岸 → 1=开阔洋
                    e_out = sea_level - 0.02 - wt * (sea_level * PK_OCEAN_DEPTH_FRAC);
                }
            } else {
                // ── 旧径向穹顶（回退路径；配合 PK_HYPSO Layer A/B 与 #3 BFS 的开关）──
                const double noise_01 = cont_noise;
                const double meso = (cyl_noise(detail_noise.ptr(), ct, st, ny, 400.0, 137.0, -91.0, 0.0) + 1.0) * 0.5;
                const double coast = cyl_noise(height_noise.ptr(), ct, st, ny, 80.0, 500.0, 500.0, 0.0) * 0.06;
                const double df15 = simulation_math::pow(dist_field, 1.5);
                double raw = df15 * (dist_field_weight + noise_01 * noise_weight + meso * meso_weight)
                    + coast + offshore + macro * df15 * macro_relief_weight;
                raw -= edge_t * edge_falloff_depth;
                e_out = raw;
            }
            E[idx] = float(pk_clamp01(e_out));
        }
    }

    // ── 2. normalize —— 镜像 _normalize_elevation ──
    // [bimodal 2026-06-26] 双峰模型已锚定 sea_level 直接产出 [0,1]；min/max 拉伸会移动海平面位置 →
    // 双峰路径下跳过，仅旧径向路径(PK_BIMODAL_ENABLED=false)才归一化。
    if (!PK_BIMODAL_ENABLED) {
        double min_e = std::numeric_limits<double>::infinity();
        double max_e = -std::numeric_limits<double>::infinity();
        for (int i = 0; i < n; ++i) {
            const double e = double(E[i]);
            if (e < min_e) min_e = e;
            if (e > max_e) max_e = e;
        }
        const double range_e = max_e - min_e;
        if (range_e >= 0.001) {
            const double inv_range = 1.0 / range_e;
            for (int i = 0; i < n; ++i) E[i] = float((double(E[i]) - min_e) * inv_range);
        }
    }
