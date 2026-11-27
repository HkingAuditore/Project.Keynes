    // ── 3. carve lake seeds —— 两阶段标记后统一下沉，避免同一低频湖盆内的
    // 邻接候选被先凿出的水格排斥成碎小湖。
    PackedByteArray is_lake_seed_arr;
    is_lake_seed_arr.resize(n);
    {
        uint8_t *LS = is_lake_seed_arr.ptrw();
        for (int i = 0; i < n; ++i) LS[i] = 0;
        const double sea = sea_level;
        const double w_min = lake_seed_min_interior;
        const double w_max = 1.0 - lake_seed_min_interior;
        // [湖泊多样化 2026-06-19] 每格记录目标下沉深度(0=非种子)，按噪声强度做"中心深/边缘浅"渐变。
        std::vector<float> seed_depth(size_t(n), 0.0f);
        const double small_thr = std::min(0.95, lake_seed_threshold + 0.08);  // 小湖阈值(+0.14 过严→几乎无小湖；放宽到 +0.08 让小湖成形，仍靠 pit-fill≥4 格防碎湖)
        const double warp_amp = 7.0;                                          // domain-warp 振幅(hex 单位)
        for (int row = 0; row < height; ++row) {
            for (int col = 0; col < width; ++col) {
                const int idx = row * width + col;
                if (double(E[idx]) < sea + 0.04) continue;
                const double ny = double(row) * inv_h;
                // [cylindrical-earth-daylight] 仅排除南北极附近(纬度)，东西可环绕成湖、不再排除。
                if (ny < w_min || ny > w_max) continue;
                // [cylindrical-earth-daylight] domain warp + 圆柱采样：经度走半径 width/TWO_PI
                // 的圆环(arc/col≈1 hex，尺度与原 Q 一致)，纬度走 z；经度 period=width（col/width）
                // 使 col=0 与 col=width-1 相邻不重合 → 湖盆可跨接缝、东西无缝。经度 warp 经 Δθ 施加。
                const double l_theta = PK_TWO_PI * (double(col) / double(width));
                const double l_rc = double(width) / PK_TWO_PI;
                const double lcx = simulation_math::cos(l_theta) * l_rc;
                const double lcy = simulation_math::sin(l_theta) * l_rc;
                const double lz = double(row);
                const double warp_lon = double(lake_noise_small->get_noise_3d(lcx + 211.0, lcy - 77.0, lz)) * warp_amp;
                const double warp_lat = double(lake_noise_small->get_noise_3d(lcx - 53.0, lcy + 169.0, lz)) * warp_amp;
                const double th2 = l_theta + warp_lon / l_rc;   // 经度方向 warp（保持周期）
                const double wcx = simulation_math::cos(th2) * l_rc;
                const double wcy = simulation_math::sin(th2) * l_rc;
                const double wz = lz + warp_lat;                // 纬度方向 warp
                const double n_large = double(lake_noise->get_noise_3d(wcx, wcy, wz));
                const double n_small = double(lake_noise_small->get_noise_3d(wcx, wcy, wz));
                double strength = -1.0;  // <0 表示非种子
                if (n_large >= lake_seed_threshold) {
                    // 大/中湖盆：强度=超阈幅度→噪声峰(湖心)深、近阈值(湖缘)浅
                    strength = (n_large - lake_seed_threshold) / std::max(1e-3, 1.0 - lake_seed_threshold);
                } else if (n_small >= small_thr) {
                    // 小湖点：整体更浅(0.35 缩放)，避免与大湖同深
                    strength = 0.35 * (n_small - small_thr) / std::max(1e-3, 1.0 - small_thr);
                }
                if (strength < 0.0) continue;
                bool has_water_nb = false;
                for (int d = 0; d < 6; ++d) {
                    const int ni = index_for_qr(Q[idx] + DQ[d], R[idx] + DR[d]);
                    if (ni >= 0 && double(E[ni]) < sea) { has_water_nb = true; break; }
                }
                if (has_water_nb) continue;
                LS[idx] = 1;
                const double sc = (strength > 1.0) ? 1.0 : strength;                    // clamp01
                seed_depth[size_t(idx)] = float(lake_seed_depth * (0.55 + 0.95 * sc));  // 0.55x~1.5x 深度梯度
            }
        }
        for (int i = 0; i < n; ++i) {
            if (LS[i] != 0) E[i] = float(sea - double(seed_depth[size_t(i)]));
        }
    }

    // ── 4. smooth pit depressions —— 镜像 _smooth_pit_depressions（就地，迭代至稳定）──
    for (int it = 0; it < pit_fill_max_iters; ++it) {
        bool changed = false;
        for (int row = 0; row < height; ++row) {
            for (int col = 0; col < width; ++col) {
                const int idx = row * width + col;
                if (double(E[idx]) < sea_level) continue;
                double lowest_nb = std::numeric_limits<double>::infinity();
                for (int d = 0; d < 6; ++d) {
                    const int ni = index_for_qr(Q[idx] + DQ[d], R[idx] + DR[d]);
                    if (ni < 0) continue;
                    const double e = double(E[ni]);
                    if (e < lowest_nb) lowest_nb = e;
                }
                if (lowest_nb < std::numeric_limits<double>::infinity() && double(E[idx]) <= lowest_nb) {
                    E[idx] = float(lowest_nb + 0.001);
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }

    // ── 5'. [P5-2.3 2026-11-18] 脊线残差：只给脊顶一点锐度，山脊主体已由 §2.4' 内生 ─────────
    // 旧 §5 是「侵蚀之后再叠脊噪声」的整段加法：脊信号与汇水完全无关 → 脊线横跨河谷、在谷中筑坝
    // （后文 post-base Priority-Flood 再把坝后谷判成湖盆）。现在 ridge_add 已前移到 §R（输入 E0
    // 冻结）并作为 §2.4' 的抬升场参与「抬升 vs 下切」平衡；本节只保留同一份 ridge_add 的**残差**：
    // 加法乘 ridge_residual_frac（契约 §A.1：默认 0.15、上限 0.30 —— 再高就重新筑坝；0 = 完全内生）。
    // ridge_boost_amp 现在既是 ridge_add 的幅度，残差幅度 = 它 × 残差比例，故这里不再乘 amp。
    // 其余按计划 §3.1「§5' 只改加法」保持原样：冻结基底 ridge_pre、p99 二分预算求全局缩放 g、
    // 6% 尾巴指数软上限，以及 ridge_budget_scale / ridge_base_scale 等诊断键都不变。
    if (ridge_boost_amp > 0.0) {
        const double ridge_resid = std::clamp(getd(profile, "ridge_residual_frac", 0.15), 0.0, 0.30);
        // 所有尺寸统一使用冻结输入，避免按扫描顺序读到已抬升邻格（脊加法已不再读邻格，但 ridge_pre
        // 仍需独立冻结：下面的 base_scale 与 p99 预算必须按未抬升的基底算）。
        std::vector<float> ridge_pre(size_t(n), -1.0f);
        for (int i = 0; i < n; ++i) {
            if (double(E[i]) >= sea_level) ridge_pre[size_t(i)] = E[i];  // -1 = 非陆地，不加脊残差
        }
        if (!ridge_pre.empty()) {
            std::vector<int> land_idx;
            land_idx.reserve(size_t(n));
            for (int i = 0; i < n; ++i) {
                if (ridge_pre[size_t(i)] >= 0.0f) land_idx.push_back(i);
            }
            if (!land_idx.empty()) {
                std::vector<float> scratch(land_idx.size());
                const size_t k99 = std::min(land_idx.size() - 1, size_t(double(land_idx.size()) * 0.99));
                // 极端配置中基底先按海平面锚定的统一比例留出空间，保留高程序。
                for (size_t j = 0; j < land_idx.size(); ++j) scratch[j] = ridge_pre[size_t(land_idx[j])];
                std::nth_element(scratch.begin(), scratch.begin() + std::ptrdiff_t(k99), scratch.end());
                const double base_p99 = double(scratch[k99]);
                const double base_target = sea_level + (soft_max - sea_level) * 0.94;
                const double base_scale = base_p99 > base_target
                    ? (base_target - sea_level) / std::max(base_p99 - sea_level, 1e-6) : 1.0;
                for (int i : land_idx) ridge_pre[size_t(i)] = float(sea_level +
                    (double(ridge_pre[size_t(i)]) - sea_level) * base_scale);
                auto p99_at = [&](double g) -> double {
                    for (size_t j = 0; j < land_idx.size(); ++j) {
                        const size_t i = size_t(land_idx[j]);
                        scratch[j] = float(double(ridge_pre[i]) + g * ridge_resid * double(ridge_add[i]));
                    }
                    std::nth_element(scratch.begin(), scratch.begin() + std::ptrdiff_t(k99), scratch.end());
                    return double(scratch[k99]);
                };
                double g = 1.0;
                if (p99_at(1.0) > soft_max) {
                    double lo = 0.0, hi = 1.0;
                    for (int it = 0; it < 24; ++it) {
                        const double mid = 0.5 * (lo + hi);
                        if (p99_at(mid) > soft_max) hi = mid; else lo = mid;
                    }
                    g = lo;
                }
                int tail_count = 0;
                for (const int i : land_idx) {
                    double h = double(ridge_pre[size_t(i)]) + g * ridge_resid * double(ridge_add[size_t(i)]);
                    if (h > soft_max) {
                        const double span = land_elev_cap - soft_max;
                        h = soft_max + span * (1.0 - simulation_math::exp(-(h - soft_max) / span));
                        ++tail_count;
                    }
                    E[i] = float(h);
                }
                out["ridge_budget_scale"] = g;
                out["ridge_base_scale"] = base_scale;
                out["ridge_tail_cells"] = tail_count;
                out["ridge_land_cells"] = int(land_idx.size());
                out["ridge_elevation_cap"] = land_elev_cap;
            }
        }
    }

    // ── 5b. 小型内陆洼地高程回填（消除"零碎湖"根因）────────────────────────
    // 实证(CSV 20260619_032716)：内陆遍布 ~96 个 1~5 格、高程恒为 sea-lake_seed_depth
    // 的 below-sea 洼地(湖泊种子散点)，后续被判成 COAST → 满屏"零碎湖"，且其原始 E<sea
    // 在运行时被重新判水 → 用户所述"前几 tick 干盆地、之后突然灌满水"(issue#1)。
    // 根治：在 E 仍可写的 base pass，按【高程连通性】找出未与主海洋相连的 below-sea 连通块——
    // 面积 < lake_min 的小块直接抬到 sea+eps(永久成陆，下游任何 pass 都不会再把它判成水)；
    // >= lake_min 的大盆地保留(在 post pass 自然成内陆湖 LAKE)。阈值与 post pass 的
    // hydro_lake_min_cells 同源，保证 base/post 判定一致、不再有"漏网孤立水"。
    {
        const double sea = sea_level;
        const int lake_min = std::max(1, int(getd(profile, "hydro_lake_min_cells", 8.0)));
        std::vector<uint8_t> ocean_e(size_t(n), 0);
        std::vector<int> obfs;
        obfs.reserve(size_t(n));
        for (int row = 0; row < height; ++row) {
            for (int col = 0; col < width; ++col) {
                const int idx = row * width + col;
                if (double(E[idx]) >= sea) continue;
                if (row == 0 || row == height - 1) {  // [cylindrical] 仅南北极作海洋种子；东西经度环绕由 index_for_qr 处理
                    ocean_e[size_t(idx)] = 1;
                    obfs.push_back(idx);
                }
            }
        }
        for (size_t bi = 0; bi < obfs.size(); ++bi) {
            const int cur = obfs[bi];
            for (int d = 0; d < 6; ++d) {
                const int ni = index_for_qr(Q[cur] + DQ[d], R[cur] + DR[d]);
                if (ni < 0 || ocean_e[size_t(ni)]) continue;
                if (double(E[ni]) >= sea) continue;
                ocean_e[size_t(ni)] = 1;
                obfs.push_back(ni);
            }
        }
        std::vector<uint8_t> pit_seen(size_t(n), 0);
        std::vector<int> pit_comp;
        pit_comp.reserve(256);
        int pit_filled = 0;
        // [湖泊多样化 2026-06-19] 含 lake_seed 的洼地放宽到 ≥4 格即保留为小湖；非种子的噪声碎坑
        // 仍按 lake_min(8) 填平 → 既出现小湖大小层次，又不让随机碎湖回归(沿用之前碎湖修复)。
        const uint8_t *LS_ptr = is_lake_seed_arr.ptr();
        const int seed_keep_min = std::min(lake_min, 4);
        for (int s = 0; s < n; ++s) {
            if (double(E[s]) >= sea || ocean_e[size_t(s)] || pit_seen[size_t(s)]) continue;
            pit_comp.clear();
            pit_comp.push_back(s);
            pit_seen[size_t(s)] = 1;
            // 同时记录该洼地的"溢出口"高度 = 最低的陆地(E>=sea)边界邻居。
            double spill_e = std::numeric_limits<double>::infinity();
            bool comp_has_seed = (LS_ptr[size_t(s)] != 0);
            for (size_t qi = 0; qi < pit_comp.size(); ++qi) {
                const int cur = pit_comp[qi];
                for (int d = 0; d < 6; ++d) {
                    const int ni = index_for_qr(Q[cur] + DQ[d], R[cur] + DR[d]);
                    if (ni < 0) continue;
                    if (double(E[ni]) >= sea) {            // 陆地边界 = 出口候选
                        if (double(E[ni]) < spill_e) spill_e = double(E[ni]);
                        continue;
                    }
                    if (pit_seen[size_t(ni)] || ocean_e[size_t(ni)]) continue;
                    pit_seen[size_t(ni)] = 1;
                    pit_comp.push_back(ni);
                    if (LS_ptr[size_t(ni)] != 0) comp_has_seed = true;
                }
            }
            const int keep_min = comp_has_seed ? seed_keep_min : lake_min;
            if (int(pit_comp.size()) < keep_min) {
                // [空洞平滑 2026-06-19] 旧版统一压到 sea+0.012 的固定低值 → 内陆遍布比周围明显
                // 低一截的"小坑斑块"(用户反馈：空洞太小、地面碎)。改为回填到溢出口高度(略低
                // 0.012)，使原洼地与最近陆地出口齐平、平滑融入周围地形，不再读作突兀低斑。
                double fill_e = sea + 0.012;
                if (std::isfinite(spill_e)) fill_e = std::max(sea + 0.012, spill_e - 0.012);
                for (int v : pit_comp) E[v] = float(fill_e);
                pit_filled += int(pit_comp.size());
            }
        }
    }
