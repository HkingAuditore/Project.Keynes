    // ── 统一气候场（terrain-overhaul Phase 3）：距海距离 + 海洋温度调节 ──
    // 复用 base pass 传来的 dist_ocean_arr；缺失则按 elev<sea_level 现场重算 BFS。
    const double coastal_temp_moderation = getd(profile, "coastal_temp_moderation", 0.18);
    // [scale-fix 2026-07-30] 衰减长度 ×s（与 base pass 一致），保持海洋调温的物理范围恒定。
    const double coastal_temp_scale = std::max(0.5, getd(profile, "coastal_temp_scale", 6.0) * gen_dist_scale);
    std::vector<int32_t> dist_ocean(size_t(n), -1);
    if (dist_ocean_arr.size() == n) {
        const int32_t *DO = dist_ocean_arr.ptr();
        for (int i = 0; i < n; ++i) dist_ocean[size_t(i)] = DO[i];
    } else {
        std::vector<int> bfsq;
        bfsq.reserve(size_t(n));
        for (int i = 0; i < n; ++i) {
            if (double(E[i]) < sea_level) { dist_ocean[size_t(i)] = 0; bfsq.push_back(i); }
        }
        for (size_t qi = 0; qi < bfsq.size(); ++qi) {
            const int cur = bfsq[qi];
            const int nd = dist_ocean[size_t(cur)] + 1;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || dist_ocean[size_t(ni)] >= 0) continue;
                dist_ocean[size_t(ni)] = nd;
                bfsq.push_back(ni);
            }
        }
    }
    auto ocean_influence = [&](int i) -> double {
        const int dd = dist_ocean[size_t(i)];
        if (dd < 0) return 0.0;
        return simulation_math::exp(-double(dd) / std::max(coastal_temp_scale, 0.5));
    };
    // 生成期分类温度：纬度钟形 - 海拔惩罚，再按海洋邻近度拉向温带。与 base pass gen_temp 一致，
    // 保证 base/post_base 同一套温度→biome 判定（gen_once）。运行时温度场 TEMP[] 不受影响。
    auto gen_temp = [&](int i) -> double {
        const double base = pk_lat_temp_bell((row_norm(i) - 0.5) * 2.0) - pk_alt_penalty(double(E[i]), sea_level);
        const double infl = ocean_influence(i);
        return pk_clamp01(base + infl * coastal_temp_moderation * (0.5 - base));
    };

    auto cube_distance = [&](int a, int b) -> int {
        // [cylindrical-earth-daylight] 东西环绕的最短 cube 距离：把 b 沿 col 方向 ±width
        // 平移（offset col±width ⇔ cube q±width, s∓width, r 不变），取三者最小 →
        // 火山间距等横向度量在接缝处也正确。
        const int dq = Q[a] - Q[b];
        const int dr = R[a] - R[b];
        const int ds = S[a] - S[b];
        const int d0 = (std::abs(dq) + std::abs(dr) + std::abs(ds)) / 2;
        const int d1 = (std::abs(dq - width) + std::abs(dr) + std::abs(ds + width)) / 2;
        const int d2 = (std::abs(dq + width) + std::abs(dr) + std::abs(ds - width)) / 2;
        return std::min(d0, std::min(d1, d2));
    };
    auto sync_axes = [&](int i) {
        const uint8_t lf = pk_derive_landform_with_volcano(TERR[i], E[i], float(sea_level), VOLC[i] != 0);
        const uint8_t veg = pk_derive_vegetation(TERR[i], lf, TEMP[i], M[i]);
        uint8_t cov = pk_derive_cover(TERR[i], 0.0f);
        if (ocean_enabled && UP != nullptr && TERR[i] == 0) {
            bool has_land_neighbor = false;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && !pk_is_water_terrain(TERR[ni])) {
                    has_land_neighbor = true;
                    break;
                }
            }
            if (!has_land_neighbor && UP[i] > 0.6f) cov = 6; // PELAGIC_BLOOM
        }
        LF[i] = lf;
        BLF[i] = lf;
        VEG[i] = veg;
        BVEG[i] = veg;
        COV[i] = cov;
        IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
        BTERR[i] = TERR[i];
    };

    for (int i = 0; i < n; ++i) {
        BM[i] = M[i];
        RIV[i] = 0;
        RFLOW_OUT[i] = 0.0f;
        RDOWN[i] = -1;
        HPARENT_OUT[i] = -1;
        VOLC[i] = 0;
        IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
    }

    // Hydrologic correction: Priority-Flood style spill surface + parent graph.
    // This is the light-weight equivalent of DEM depression filling used by
    // RichDEM/FlowFill workflows: every cell gets an outlet path through its
    // lowest spill, so lakes and rivers are derived from one coherent drainage
    // surface rather than local raw-elevation pits.
    std::vector<uint8_t> connected(size_t(n), 0);
    std::vector<int> queue;
    queue.reserve(size_t(n));
    for (int i = 0; i < n; ++i) {
        if (!pk_is_ocean_connected_seed_terrain(TERR[i])) continue;
        // [cylindrical-earth-daylight] 仅南北极(row)作排水出口种子；东西经度环绕由 NB(已 posmod) 在 BFS 扩散时连通。
        const int row = R[i];
        if (row == 0 || row == height - 1) {
            connected[size_t(i)] = 1;
            queue.push_back(i);
        }
    }
    for (size_t qi = 0; qi < queue.size(); ++qi) {
        const int cur = queue[qi];
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(cur) * 6 + d];
            if (ni < 0 || connected[size_t(ni)]) continue;
            if (!pk_is_ocean_connected_seed_terrain(TERR[ni])) continue;
            connected[size_t(ni)] = 1;
            queue.push_back(ni);
        }
    }

    using HydroNode = std::pair<float, int>;
    std::priority_queue<HydroNode, std::vector<HydroNode>, std::greater<HydroNode>> hydro_pq;
    std::vector<uint8_t> hydro_seen(size_t(n), 0);
    std::vector<float> hydro_fill(size_t(n), std::numeric_limits<float>::infinity());
    std::vector<int32_t> hydro_parent(size_t(n), -1);
    std::vector<int> hydro_order;
    hydro_order.reserve(size_t(n));
    for (int i = 0; i < n; ++i) {
        // [cylindrical-earth-daylight] 仅南北极(row)作水文 flood 出海口；东西经度环绕由 index_for_qr/NB 处理。
        const int row = R[i];
        if (row != 0 && row != height - 1) continue;
        hydro_seen[size_t(i)] = 1;
        hydro_fill[size_t(i)] = E[i];
        hydro_pq.push(HydroNode(E[i], i));
        hydro_order.push_back(i);
    }
    while (!hydro_pq.empty()) {
        const HydroNode cur_node = hydro_pq.top();
        hydro_pq.pop();
        const float cur_z = cur_node.first;
        const int cur = cur_node.second;
        if (cur_z > hydro_fill[size_t(cur)] + 0.000001f) continue;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(cur) * 6 + d];
            if (ni < 0 || hydro_seen[size_t(ni)] != 0) continue;
            hydro_seen[size_t(ni)] = 1;
            const float spill_z = std::max(E[ni], cur_z);
            hydro_fill[size_t(ni)] = spill_z;
            hydro_parent[size_t(ni)] = cur;
            hydro_pq.push(HydroNode(spill_z, ni));
            hydro_order.push_back(ni);
        }
    }
    for (int i = 0; i < n; ++i) {
        HPARENT_OUT[i] = hydro_parent[size_t(i)];
    }

    auto reclassify_drained_land = [&](int i) {
        const double eff_e = std::max(double(E[i]), sea_level + 0.012);
        const double eff_m = std::max(double(M[i]), 0.38);
        uint8_t nt = pk_decide_terrain_ex(eff_e, gen_temp(i),
                                          eff_m, sea_level, true);
        if (pk_is_water_terrain(nt)) nt = 2; // PLAIN fallback; drained tiny pits should not stay blue.
        TERR[i] = nt;
    };

    std::vector<uint8_t> lake_candidate(size_t(n), 0);
    for (int i = 0; i < n; ++i) {
        if (connected[size_t(i)] != 0) continue;
        const double depth = double(hydro_fill[size_t(i)]) - double(E[i]);
        if (depth >= hydro_lake_min_depth) lake_candidate[size_t(i)] = 1;
        if (pk_is_ocean_connected_seed_terrain(TERR[i]) && !connected[size_t(i)] && depth > 0.001) {
            lake_candidate[size_t(i)] = 1;
        }
    }

    int lake_count = 0;
    int lake_component_count = 0;
    int drained_tiny_lake_count = 0;
    std::vector<uint8_t> lake_seen(size_t(n), 0);
    std::vector<int> comp;
    comp.reserve(256);
    for (int i = 0; i < n; ++i) {
        if (lake_seen[size_t(i)] != 0 || lake_candidate[size_t(i)] == 0) continue;
        comp.clear();
        queue.clear();
        queue.push_back(i);
        lake_seen[size_t(i)] = 1;
        double volume = 0.0;
        double max_depth = 0.0;
        for (size_t qi = 0; qi < queue.size(); ++qi) {
            const int cur = queue[qi];
            comp.push_back(cur);
            const double depth = std::max(0.0, double(hydro_fill[size_t(cur)]) - double(E[cur]));
            volume += depth;
            max_depth = std::max(max_depth, depth);
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || lake_seen[size_t(ni)] != 0 || lake_candidate[size_t(ni)] == 0) continue;
                lake_seen[size_t(ni)] = 1;
                queue.push_back(ni);
            }
        }
        const bool keep_lake = int(comp.size()) >= hydro_lake_min_cells ||
                (int(comp.size()) >= 4 && volume >= hydro_lake_min_volume && max_depth >= hydro_lake_min_depth * 1.5);
        if (keep_lake) {
            ++lake_component_count;
            for (int v : comp) {
                TERR[v] = 18; // LAKE
                ++lake_count;
            }
        } else {
            for (int v : comp) {
                if (pk_is_water_terrain(TERR[v])) {
                    reclassify_drained_land(v);
                    ++drained_tiny_lake_count;
                }
            }
        }
    }
    for (int i = 0; i < n; ++i) {
        if (pk_is_ocean_connected_seed_terrain(TERR[i]) && !connected[size_t(i)]) {
            reclassify_drained_land(i);
            ++drained_tiny_lake_count;
        }
        IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
    }

    // Snapshot base moisture before rain shadow / river ecology.
    for (int i = 0; i < n; ++i) BM[i] = M[i];

    // 复刻 _apply_rain_shadow_per_cell(season_phase=1.0)：
    //   1) jitter 来自 _height_warp.get_noise_2d(q*8, r*8)*0.04（需重建同款 FastNoiseLite）；
    //   2) upwind 目标是 cell + best_dir*lookback 的直接 cube 跳转（== get_cell_by_cube），
    //      而非逐步 NB 走步——后者在地图边缘对角方向会与 GDScript 差 1 格。
    Ref<FastNoiseLite> rs_warp;  rs_warp.instantiate();
    if (rs_warp.is_valid()) {
        rs_warp->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
        rs_warp->set_seed(seed + 13);
        rs_warp->set_frequency(0.025);
        rs_warp->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
        rs_warp->set_fractal_octaves(3);
    }
    int rain_shadow_touched = 0;
    if (lookback > 0 && rs_warp.is_valid()) {
        for (int i = 0; i < n; ++i) {
            if (pk_is_water_terrain(TERR[i])) continue;
            // [cylindrical-earth-daylight] 雨影 jitter 经度环绕：把原 Q*8 的经度轴换成周长 8*width
            // 的圆环(每 col 弧长≈8，特征尺度不变)，纬度仍 R*8 → 接缝处风扰动连续；配合下方
            // index_for_qr 的 upwind 探针(已环绕)，雨影在东西方向无缝、不再有边缘断层。
            const int rs_col = i % width;
            const double rs_rc = 8.0 * double(width) / PK_TWO_PI;
            const double rs_theta = PK_TWO_PI * (double(rs_col) / double(width));
            const double jitter = double(rs_warp->get_noise_3d(simulation_math::cos(rs_theta) * rs_rc,
                                                               simulation_math::sin(rs_theta) * rs_rc,
                                                               double(R[i]) * 8.0)) * 0.04;
            const PkWind2 wind = pk_wind_belt_wind_at(row_norm(i), 1.0, jitter);
            const int dir = pk_upwind_dir_index_from_wind(wind.x, wind.y);
            if (dir < 0) continue;
            const int probe = index_for_qr(Q[i] + DQ[dir] * lookback, R[i] + DR[dir] * lookback);
            if (probe < 0) continue;
            if (double(E[probe]) > double(E[i]) + rain_threshold) {
                M[i] = float(double(M[i]) * rain_factor);
                ++rain_shadow_touched;
            }
        }
    }

    int redecide_touched = 0;
    for (int i = 0; i < n; ++i) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || t == 6 || t == 9 || t == 8) continue;
        // 用统一气候场温度(gen_temp，含海洋调节)重判 biome，与 base pass 同源。
        const uint8_t nt = pk_decide_terrain_ex(double(E[i]), gen_temp(i),
                                                double(M[i]), sea_level, true);
        // [破碎湖修复 2026-06-19] 绝不把陆地重新判回水：内陆低于海平面但已被 reclassify_
        // drained_land 排干成陆(PLAIN)的格，其原始 E 仍 < sea_level，若用原始 E 重判会被重新
        // 判成 COAST/OCEAN → 内陆遍布"碎水/破碎湖"(实测 ~144 内陆 COAST 格)。陆→水一律跳过；
        // 真正的内陆湖由上方基于洼地深度的 LAKE 检测专门生成。
        if (pk_is_water_terrain(nt) && !pk_is_water_terrain(t)) continue;
        if (nt != t) {
            TERR[i] = nt;
            ++redecide_touched;
        }
    }

    std::vector<int> land;
    land.reserve(size_t(n));
    for (int i = 0; i < n; ++i) {
        if (!pk_is_water_terrain(TERR[i])) land.push_back(i);
    }
    // Flow accumulation on the hydrologically corrected parent graph.
    std::vector<float> flow(size_t(n), 0.0f);
    const double inv_above_sea = 1.0 / std::max(1.0 - sea_level, 0.001);
    for (int i = 0; i < n; ++i) {
        if (connected[size_t(i)] != 0 && pk_is_water_terrain(TERR[i])) continue;
        if (pk_is_water_terrain(TERR[i]) && TERR[i] != 18) continue;
        const double base_rain = 0.4 + (1.6 - 0.4) * double(M[i]);
        const double lh = (double(hydro_fill[size_t(i)]) - sea_level) * inv_above_sea;
        const double oro = 1.0 + std::max(lh - 0.30, 0.0) * orographic_boost;
        flow[size_t(i)] = pk_is_water_terrain(TERR[i]) ? 0.0f : float(base_rain * oro);
    }
    for (auto it = hydro_order.rbegin(); it != hydro_order.rend(); ++it) {
        const int i = *it;
        const int p = hydro_parent[size_t(i)];
        if (p < 0) continue;
        if (connected[size_t(i)] != 0 && pk_is_water_terrain(TERR[i])) continue;
        flow[size_t(p)] += flow[size_t(i)];
    }
    // ── 河道起始：按"上游汇水面积(汇水格数)"有效阈值取河道 ───────────────────────
    // [river-rework 2026-06-19] 旧法按 flow 分位选 top-X% 地块为源头再向下追踪 → 标出 land 的
    // 固定比例(实测分位 0.72→占全图 ~10% 成"填满大陆的网"；调高分位又退化成贴海岸的短段)。
    // 改用地貌学经典 channel-initiation：汇水面积≥阈值才成河 → 天然稀疏树状网：上游细流在累积
    // 足够汇水后出现，向下汇成干流。大图会按 cell 数温和放大阈值，避免固定格数阈值把超大
    // 流域切出过密支流，同时保留 profile slider 的相对密度含义。
    std::vector<int> up_count(size_t(n), 0);
    for (int i : land) up_count[size_t(i)] = 1;
    for (auto it = hydro_order.rbegin(); it != hydro_order.rend(); ++it) {
        const int i = *it;
        if (up_count[size_t(i)] == 0) continue;
        const int p = hydro_parent[size_t(i)];
        if (p < 0) continue;
        up_count[size_t(p)] += up_count[size_t(i)];
    }
    float river_threshold = std::numeric_limits<float>::infinity();
    for (int i : land) {
        if (up_count[size_t(i)] >= channel_init) {
            RIV[i] = 1;
            river_threshold = std::min(river_threshold, flow[size_t(i)]);
        }
    }
    int headwater_touched = 0;
    if (river_headwater_init < channel_init) {
        for (int i : land) {
            if (RIV[i] != 0) continue;
            if (land_h(i) < river_headwater_min_land_h) continue;
            if (up_count[size_t(i)] < river_headwater_init) continue;
            std::vector<int> path;
            path.reserve(24);
            bool connects = false;
            int cur = i;
            for (int step = 0; step < 24 && cur >= 0 && cur < n; ++step) {
                if (pk_is_water_terrain(TERR[cur])) { connects = true; break; }
                path.push_back(cur);
                const int p = hydro_parent[size_t(cur)];
                if (p < 0 || p == cur) break;
                if (RIV[p] != 0 || pk_is_water_terrain(TERR[p])) { connects = true; break; }
                cur = p;
            }
            if (!connects || path.size() < 2) continue;
            for (int v : path) {
                if (RIV[v] == 0) {
                    RIV[v] = 1;
                    ++headwater_touched;
                }
                river_threshold = std::min(river_threshold, flow[size_t(v)]);
            }
        }
    }
    if (!std::isfinite(river_threshold)) river_threshold = 0.0f;
    (void)river_percentile;  // 旧分位参数保留读取以兼容，不再用于河道选择。
    // 清理：移除不接触水体或过短的孤立河段(channel-init 一般已连通到海/湖，此为安全网)。
    {
        std::vector<uint8_t> riv_seen(size_t(n), 0);
        for (int i : land) {
            if (RIV[i] == 0 || riv_seen[size_t(i)]) continue;
            std::vector<int> comp;
            comp.push_back(i);
            riv_seen[size_t(i)] = 1;
            bool touches_water = false;
            for (size_t qi = 0; qi < comp.size(); ++qi) {
                const int cur = comp[qi];
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(cur) * 6 + d];
                    if (ni < 0) continue;
                    if (pk_is_water_terrain(TERR[ni])) touches_water = true;
                    if (riv_seen[size_t(ni)] || RIV[ni] == 0) continue;
                    riv_seen[size_t(ni)] = 1;
                    comp.push_back(ni);
                }
            }
            if (!touches_water || int(comp.size()) < hydro_river_min_length) {
                for (int v : comp) RIV[v] = 0;
            }
        }
    }
    std::vector<int> unmark;
    for (int i : land) {
        if (RIV[i] == 0) continue;
        bool has_river_or_water = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && (RIV[ni] != 0 || pk_is_water_terrain(TERR[ni]))) {
                has_river_or_water = true;
                break;
            }
        }
        if (!has_river_or_water) unmark.push_back(i);
    }
    for (int i : unmark) RIV[i] = 0;

    // [scale-fix 2026-07-30] RFLOW 归一化改用"基准等效流量" flow_eq = flow × (15000/N)。
    // 同源点汇流量 ∝ N（单位面积产流率 size-invariant × 流域格数 ∝ N）→ flow_eq 跨分辨率
    // 不变；min(≈channel-init 处流量)与 max(最大流域出口)同乘该系数，log min-max 两端不再
    // 缩放不一致（旧法大图 log 区间更宽、中流归一流量系统性偏高 → 同一条河在大图偏宽）。
    // 等效流量仍是 15000 格量级，log1p 的动态压缩特性不受影响。
    const double flow_eq_scale = river_map_reference_cells / std::max(1.0, double(n));
    float max_river_flow = 0.0f;
    for (int i = 0; i < n; ++i) {
        if (RIV[i] != 0) max_river_flow = std::max(max_river_flow, flow[size_t(i)] * float(flow_eq_scale));
    }
    const double river_threshold_eq = double(river_threshold) * flow_eq_scale;
    const double log_min_flow = simulation_math::log1p(std::max(river_threshold_eq, 0.0));
    const double log_max_flow = simulation_math::log1p(std::max(double(max_river_flow), river_threshold_eq + 0.001));
    const double inv_log_range = 1.0 / std::max(log_max_flow - log_min_flow, 0.001);
    // 生态保留旧归一标尺，视觉河宽调参不得静默改变大河、三角洲和泛滥平原阈值。
    std::vector<float> river_ecology_flow(size_t(n), 0.0f);
    int river_lake_snap_touched = 0;
    for (int i = 0; i < n; ++i) {
        if (RIV[i] == 0) continue;
        const int p = hydro_parent[size_t(i)];
        if (p >= 0 && (RIV[p] != 0 || pk_is_water_terrain(TERR[p]))) {
            RDOWN[i] = p;
        }
        // [river-hierarchy 2026-07-31] 地板 0.15→0.06、跨度 0.85→0.94：旧地板把大量
        // 近阈值支流顶到同一宽度带，再经 stamp 幂律后视觉几乎无差。压低地板后小支流
        // 真正变细，干流仍可顶到 1.0。
        const double raw_norm = (simulation_math::log1p(std::max(double(flow[size_t(i)]) * flow_eq_scale, 0.0)) - log_min_flow) * inv_log_range;
        river_ecology_flow[size_t(i)] = float(std::clamp(0.15 + raw_norm * 0.85, 0.15, 1.0));
        RFLOW_OUT[i] = float(std::clamp(0.06 + raw_norm * 0.94, 0.06, 1.0));
    }
    for (int i : land) {
        if (RIV[i] == 0) continue;
        const int cur_down = RDOWN[i];
        if (cur_down >= 0 && cur_down < n && pk_is_water_terrain(TERR[cur_down])) continue;
        int best_lake = -1;
        float best_e = std::numeric_limits<float>::infinity();
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || TERR[ni] != 18) continue; // LAKE
            if (E[ni] < best_e) {
                best_e = E[ni];
                best_lake = ni;
            }
        }
        if (best_lake >= 0) {
            RDOWN[i] = best_lake;
            ++river_lake_snap_touched;
        }
    }

    // [river-confluence-snap 2026-06-26] 相邻河末端可视合并 ─────────────────────────────
    // 现象：河流线只沿"下游父边"(RDOWN)逐段 stamp(run_bake_river_sdf_pass / _bake_river_sdf)，
    // 六边形网格相邻 ≠ 会画连接线。两个直接相邻的 river cell 若不构成父子关系，中间不绘段 →
    // 渲染出"末端/起点贴边却不合并"的干缝。此处只缝合"可视悬空末端"：某 river cell 的 RDOWN<0
    // (其水文父非河/水 → trace 在它处断链)，若 1 格邻居存在 river cell 且接它不成环，就把 RDOWN
    // 接到最佳邻居(优先：其链能抵达终端水体 > 流量更大 > 高程更低)，让 trace 多画一段把两条链缝合。
    // 仅对 RDOWN<0 的悬空末端动手：不重路由已有正常下游的河格 → 不改动既有河链/流域。
    // RDOWN 仅供 SDF trace + cell.river_downstream(可视)消费；运行期汇流走 hydro_parent(HP，独立
    // 无环)，本 snap 完全不触碰运行期语义。成环检测：沿邻居 RDOWN 走 ≤64 步若回到自身则跳过；
    // 因只给原本 RDOWN<0(无出边)的 cell 添加唯一出边、且添加前已验证目标不可达自身，RDOWN 始终保持无环。
    int river_confluence_snap_touched = 0;
    {
        // 从 start 沿 RDOWN 行走：命中 target 返回 true(成环)；中途遇终端水体置 hits_water=true 返回 false。
        auto reaches = [&](int start, int target, bool &hits_water) -> bool {
            hits_water = false;
            int cur = start;
            for (int step = 0; step < 64 && cur >= 0 && cur < n; ++step) {
                if (cur == target) return true;
                if (pk_is_water_terrain(TERR[cur])) { hits_water = true; return false; }
                cur = RDOWN[cur];
            }
            return false;
        };
        for (int i : land) {
            if (RIV[i] == 0 || pk_is_water_terrain(TERR[i])) continue;
            if (RDOWN[i] >= 0) continue;  // 已有下游：保留既有河链，不重路由
            int best = -1;
            bool best_water = false;
            float best_flow = -1.0f;
            float best_e = std::numeric_limits<float>::infinity();
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni < 0 || RIV[ni] == 0 || pk_is_water_terrain(TERR[ni])) continue;
                bool ni_water = false;
                if (reaches(ni, i, ni_water)) continue;  // 接它会成环 → 跳过
                const bool better =
                    (best < 0) ||
                    (ni_water && !best_water) ||
                    (ni_water == best_water && RFLOW_OUT[ni] > best_flow) ||
                    (ni_water == best_water && RFLOW_OUT[ni] == best_flow && E[ni] < best_e);
                if (better) {
                    best = ni;
                    best_water = ni_water;
                    best_flow = RFLOW_OUT[ni];
                    best_e = E[ni];
                }
            }
            if (best >= 0) {
                RDOWN[i] = best;
                ++river_confluence_snap_touched;
            }
        }
    }

    // [river-incision 2026-06-25] #2b 河流切进仿真高程 E（cell 粒度）──────────────────
    // 现状：河流是独立 SDF overlay，从不进高度场 → 河岸/护岸在地形法线里完全无落差(平地上画线)。
    // 此处在河网最终化 + lake-snap 之后、河岸生态/floodplain 分类之前，沿河道下切 E + 两侧陆地邻居
    // 抬升成堤岸：① 给出河岸的宏观高程落差(coarse 法线/relief/height_tex 都看得到)；② 下切后 land_h
    // 降低 → 下游 floodplain/canyon/delta 分类自洽地在河谷成形(C 选项要的"影响分类")。下切按 RFLOW
    // 缩放(大河更深)；河道始终保持 land(>= sea_level+余量)不反转成海；堤岸抬 clamp≤1。crisp 像素级
    // 河岸由 bake 层(#2a，按 flow SDF 逐像素 V 形)叠加。base pass 已 100% C++ → 无 GDScript 镜像。
    {
        constexpr double PK_RIVER_INCISE   = 0.018;  // 河道最大下切(E 单位，× RFLOW)
        constexpr double PK_RIVER_BANK     = 0.008;  // 河岸最大抬升(堤)(E 单位，× RFLOW)
        constexpr double PK_RIVER_MIN_LAND = 0.004;  // 河道保留在 sea_level 之上的最小余量
        std::vector<float> e_bank(size_t(n), 0.0f);  // 堤岸抬升累积(读原始 RFLOW 计算，避免顺序依赖)
        const double floor_e = sea_level + PK_RIVER_MIN_LAND;
        for (int i : land) {
            if (RIV[i] == 0 || pk_is_water_terrain(TERR[i])) continue;
            const double rw = double(RFLOW_OUT[i]);
            double e = double(E[i]) - PK_RIVER_INCISE * rw;
            if (e < floor_e) e = floor_e;
            E[i] = float(e);
            const float bank = float(PK_RIVER_BANK * rw);
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni < 0 || RIV[ni] != 0 || pk_is_water_terrain(TERR[ni])) continue;
                if (bank > e_bank[size_t(ni)]) e_bank[size_t(ni)] = bank;  // 多河相邻取最强
            }
        }
        for (int i = 0; i < n; ++i) {
            if (e_bank[size_t(i)] <= 0.0f) continue;
            double e = double(E[i]) + double(e_bank[size_t(i)]);
            if (e > 1.0) e = 1.0;
            E[i] = float(e);
        }
    }

    // [coast-erosion 2026-06-26] #2c 水域波蚀：让水体(海/湖)像河流一样介入地形侵蚀——近岸陆地被
    // 邻接水体的波浪能量侵蚀，向"海蚀台地"下蚀(高处海崖蚀得快、渐近水线平台)。与河流下切 #2b 并列：
    // 河流沿河道切，水域沿岸线切。波能 ∝ 邻接水体的开阔/深度(深海邻居=大风区=强浪，浅滩/小湖弱) ×
    // 岸线包围度。只下蚀、clamp 在 sea_level 之上(不把陆地翻成海、不引发海岸级联);仅读邻居水体 E
    // (本 pass 不改水格)→ 顺序无关。下蚀后 land_h 降低 → 下游 floodplain/beach 分类自洽。base pass
    // 已 100% C++ → 无 GDScript 镜像。一键回退：profile coast_wave_erosion=0。
    int coast_erosion_touched = 0;
    {
        const double coast_wave_erosion = std::max(0.0, getd(profile, "coast_wave_erosion", 0.30));
        if (coast_wave_erosion > 0.0) {
            constexpr double PK_WAVE_MIN_LAND = 0.004;  // 蚀后保留在 sea_level 之上的最小余量
            constexpr double PK_LAKE_WAVE_MUL = 0.35;   // 湖泊波能(风区小)相对海洋折减
            const double floor_e = sea_level + PK_WAVE_MIN_LAND;
            const double inv_sea = 1.0 / std::max(sea_level, 0.001);
            for (int i : land) {
                if (pk_is_water_terrain(TERR[i])) continue;
                if (double(E[i]) <= floor_e) continue;  // 已贴水线的低地无可蚀
                double energy = 0.0;
                int wn = 0;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(i) * 6 + d];
                    if (ni < 0 || !pk_is_water_terrain(TERR[ni])) continue;
                    ++wn;
                    // 深度代理：水体越深(离水线越远)风区越大、浪能越强；浅滩/海岸弱。
                    double depth_proxy = (sea_level - double(E[ni])) * inv_sea;
                    if (depth_proxy < 0.0) depth_proxy = 0.0; else if (depth_proxy > 1.0) depth_proxy = 1.0;
                    const double type_mul = (TERR[ni] == 18) ? PK_LAKE_WAVE_MUL : 1.0;  // 18=LAKE
                    energy += type_mul * (0.30 + 0.70 * depth_proxy);
                }
                if (wn == 0) continue;
                const double e_avg = energy / double(wn);
                const double coverage = double(wn) / 6.0;  // 被水包围越多蚀得越强
                double wave = e_avg * (0.45 + 0.55 * coverage);
                if (wave < 0.0) wave = 0.0; else if (wave > 1.0) wave = 1.0;
                // 海蚀台地：下蚀量 ∝ 高于水线的高度 → 高处海崖蚀得快、渐近水线成平台。
                double e = double(E[i]);
                e -= coast_wave_erosion * wave * (e - sea_level);
                if (e < floor_e) e = floor_e;
                E[i] = float(e);
                ++coast_erosion_touched;
            }
        }
    }

    int river_count = 0;
    for (int i = 0; i < n; ++i) river_count += int(RIV[i] != 0);

    int river_ecology_touched = 0;
    int river_desert_repaired = 0;
    int river_floodplain_channel_touched = 0;
    for (int i : land) {
        if (RIV[i] == 0 || pk_is_water_terrain(TERR[i])) continue;
        const uint8_t t = TERR[i];
        const double temp = gen_temp(i);
        const double lh = land_h(i);
        const float river_w = river_ecology_flow[size_t(i)];
        const bool strong_river = river_w >= 0.55f || flow[size_t(i)] >= river_threshold * 1.8f;
        const bool desert_like = (t == 7 || t == 24 || t == 25 || t == 26 || t == 30);
        const bool lowland_river = lh <= 0.18 || (strong_river && lh <= 0.28);
        const float target_m = strong_river ? 0.74f : 0.66f;
        if (M[i] < target_m) M[i] = target_m;
        if (t == 22 || t == 23 || t == 29) {
            ++river_ecology_touched;
            continue;
        }
        if (desert_like) {
            uint8_t nt = t;
            if (lowland_river) {
                nt = (temp > 0.45 && M[i] >= 0.78f) ? uint8_t(10) : uint8_t(29); // SWAMP/FLOODPLAIN
            } else if (strong_river && temp > 0.35) {
                nt = 23; // OASIS on arid upland channels
            } else if (temp > 0.30) {
                nt = 14; // STEPPE buffer around smaller arid channels
            } else {
                nt = 13; // TAIGA：寒冷河谷已有高湿地板，不应继续保持 COLD_DESERT
            }
            if (nt != t) {
                TERR[i] = nt;
                ++river_ecology_touched;
                ++river_desert_repaired;
            }
            continue;
        }
        if (pk_is_permanent_landform(t)) {
            ++river_ecology_touched;
            continue;
        }
        if (lowland_river && (t == 2 || t == 3 || t == 12 || t == 14 || t == 15)) {
            TERR[i] = 29; // FLOODPLAIN
            ++river_ecology_touched;
            ++river_floodplain_channel_touched;
            continue;
        }
        if (t == 2) {
            uint8_t nt = t;
            if (temp > 0.55) nt = strong_river ? uint8_t(11) : uint8_t(4); // JUNGLE/FOREST
            else if (temp > 0.30) nt = strong_river ? uint8_t(29) : uint8_t(3); // FLOODPLAIN/GRASSLAND
            if (nt != t) {
                TERR[i] = nt;
                ++river_ecology_touched;
            }
        }
    }

    // terrain-overhaul Phase 4：删除旧 vegetation-feedback 单向加湿棘轮 + 不一致温度
    // (纬度-only、permanent_only=false)的二次重判——它会把统一气候场重新抹湿、与 gen_temp
    // 判定打架，并是"陆地普遍过湿、沙漠消失"的元凶之一。biome 现在只在上方 redecide
    // (gen_temp + 风输送湿度)判一次，再叠 river_ecology 河岸微调，单遍联立、内陆干旱得以保留。
    (void)veg_elev_decay;
    int vegetation_feedback_touched = 0;

    // ─── 统一距水场（water-bodies systemic, dots-total-cpp）────────────────────
    // 海/湖/河流多源 BFS（lake/river 此处均已最终判定）：
    //   water_dist[i]      = 到最近水体的格距（-1 = 未达 / 远内陆，截断于 water_dist_max）
    //   water_src_kind[i]  = 最近水源类型（0=海洋性 / 1=湖 / 2=河流；255=无）
    // 海洋 source = ocean-connected 水格（OCEAN/COAST/REEF/SEA_ICE/KELP）；湖 = LAKE(18)；
    // 河流 = 所有 RIV；流量仅缩放局地增益。纯内部中间场：仅供下方气候回灌 / 水缘生态消费，
    // 不出境（架构铁律：O(n) 中间数据留 C++；M[]/TERR[] 的改动经既有导出自然下传）。
    const int   water_dist_max     = std::max(1, geti(cfg, "water_dist_max", 8));
    const float water_big_river_min = float(getd(cfg, "water_big_river_flow_min", 0.55));
    std::vector<int32_t> water_dist(size_t(n), -1);
    std::vector<uint8_t> water_src_kind(size_t(n), 255);
    std::vector<float> water_src_flow(size_t(n), 0.0f);
    int water_src_sea = 0, water_src_lake = 0, water_src_river = 0;
    {
        std::vector<int> wq;
        wq.reserve(size_t(n));
        for (int i = 0; i < n; ++i) {
            const uint8_t t = TERR[i];
            uint8_t kind = 255;
            if (t == 18) { kind = 1; ++water_src_lake; }                 // LAKE → 湖泊效应
            else if (pk_is_water_terrain(t)) { kind = 0; ++water_src_sea; } // 海洋性
            // 所有成形河道都维持窄河岸带；water_big_river_min 只控制流量加成，
            // 不再把多数支流排除在生态水源之外。
            else if (RIV[i] != 0) { kind = 2; ++water_src_river; }
            if (kind != 255) {
                water_dist[size_t(i)] = 0;
                water_src_kind[size_t(i)] = kind;
                if (kind == 2) water_src_flow[size_t(i)] = river_ecology_flow[size_t(i)];
                wq.push_back(i);
            }
        }
        for (size_t qi = 0; qi < wq.size(); ++qi) {
            const int cur = wq[qi];
            const int cd = water_dist[size_t(cur)];
            if (cd >= water_dist_max) continue;                          // 半径截断（控开销 + 仅近邻带回灌）
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || water_dist[size_t(ni)] >= 0) continue;     // 越界 / 已访问
                water_dist[size_t(ni)]     = cd + 1;
                water_src_kind[size_t(ni)] = water_src_kind[size_t(cur)];
                water_src_flow[size_t(ni)] = water_src_flow[size_t(cur)];
                wq.push_back(ni);
            }
        }
    }
