    // ── 最终孤立水体清理（修复"大陆内部单格海洋"）──────────────────────────
    // 根因：connected[] 在湖泊/排水改写地形后变 stale，孤立残留的 OCEAN/COAST 又被
    // 升级成 REEF/KELP。这里在所有地形改写之后、最终轴派生之前，按当前地形重算一次
    // 海洋连通性：从地图边缘的水格 BFS。任何未连通主海洋的水体——达到湖泊最小面积者
    // 视作内陆湖(LAKE)，否则排干回收为陆地(reclassify_drained_land)。这样单格/碎小海洋
    // 不再出现在大陆内部，同时合法内陆湖/内海得以保留。
    int isolated_water_drained = 0;
    int isolated_water_to_lake = 0;
    {
        std::vector<uint8_t> ocean_conn(size_t(n), 0);
        std::vector<int> bfs;
        bfs.reserve(size_t(n));
        for (int i = 0; i < n; ++i) {
            if (!pk_is_water_terrain(TERR[i])) continue;
            // [cylindrical-earth-daylight] 仅南北极(row)作海洋种子；东西经度环绕由 NB 处理。
            const int row = R[i];
            if (row == 0 || row == height - 1) {
                ocean_conn[size_t(i)] = 1;
                bfs.push_back(i);
            }
        }
        for (size_t bi = 0; bi < bfs.size(); ++bi) {
            const int cur = bfs[bi];
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || ocean_conn[size_t(ni)]) continue;
                if (!pk_is_water_terrain(TERR[ni])) continue;
                ocean_conn[size_t(ni)] = 1;
                bfs.push_back(ni);
            }
        }
        // 安全阀：地图边缘必须存在主海洋；否则(全封闭水世界)跳过清理，避免误排干整片海。
        if (!bfs.empty()) {
            std::vector<uint8_t> visited_cl(size_t(n), 0);
            std::vector<int> comp_cl;
            comp_cl.reserve(256);
            for (int i = 0; i < n; ++i) {
                if (!pk_is_water_terrain(TERR[i]) || ocean_conn[size_t(i)] || visited_cl[size_t(i)]) continue;
                comp_cl.clear();
                comp_cl.push_back(i);
                visited_cl[size_t(i)] = 1;
                for (size_t qi = 0; qi < comp_cl.size(); ++qi) {
                    const int cur = comp_cl[qi];
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(cur) * 6 + d];
                        if (ni < 0 || visited_cl[size_t(ni)]) continue;
                        if (!pk_is_water_terrain(TERR[ni]) || ocean_conn[size_t(ni)]) continue;
                        visited_cl[size_t(ni)] = 1;
                        comp_cl.push_back(ni);
                    }
                }
                const bool keep_as_lake = int(comp_cl.size()) >= hydro_lake_min_cells;
                for (int v : comp_cl) {
                    if (keep_as_lake) {
                        TERR[v] = 18; // LAKE
                        ++isolated_water_to_lake;
                    } else {
                        reclassify_drained_land(v);
                        ++isolated_water_drained;
                    }
                }
            }
            for (int i = 0; i < n; ++i) {
                IW[i] = pk_is_water_terrain(TERR[i]) ? uint8_t(1) : uint8_t(0);
            }
        }
    }



    // ── [water-depth-tex 2026-06-26] 统一水深信号 water_depth01 ∈ [0,1]（海/湖共用一张 R8 图）──────
    // 取代 shader 端"海洋 5×5 height 邻域 + 湖泊 16× biome-atlas 多半径"两套深浅估算：C++ 在此算好
    // 每格归一水深，bake 经 pixel_to_cell_index 扇出成 R8 water_depth_tex，shader 每水像素仅 1 次采样。
    // 海洋/海岸/礁/海草/海冰用 1-E/sea_level（E 已含洋底距岸 BFS 梯度）；湖泊用下方 bathymetry 的碗形
    // ramp × 湖体尺寸因子（小塘浅、大湖深）；非水格 0（shader 仅水像素读）。
    PackedFloat32Array water_depth_arr;
    water_depth_arr.resize(n);
    float * const WDEPTH = water_depth_arr.ptrw();
    for (int i = 0; i < n; ++i) WDEPTH[i] = 0.0f;

    // ── [lake-bathymetry 2026-06-26] 湖泊水下深度场（湖岸浅→湖心深，对标海洋距岸 BFS）──────────
    // 根因：海洋洋底由 base pass 两段距岸 BFS（§2.55 + water-tuning）刻出"大陆架→坡→深渊"的真实
    // 高程梯度，而湖泊只在 post_base 被打 TERR=18 标志、湖底高程仍是洼地填充后的近似平面 → 渲染端
    // 只能用 shader 邻域代理(compute_lake_shore_proxy)凑深浅，大湖中央一片均一（用户反馈"湖泊没有
    // 像海洋那样的深度/海拔变化"）。这里在所有 LAKE 最终确定后、sync_axes 之前，对每个湖泊连通域：
    // 从湖岸向湖心做多源 BFS 得每格离岸 hex 距离，按距离把湖底高程压向"以该湖水面(hydro_fill)为
    // 深度=0 基准的碗形梯度"。仅下切(min)、绝不抬升 → 不会把水翻到陆上；TERR 不改 → LAKE 分类/
    // landform 不受影响（pk_derive_landform 对 terrain==18 恒返回 LAKE）。湖深随湖体半径自适应（大湖
    // 更深）并叠低频噪声造湖底起伏。下游：HexCell.elevation→height 纹理→shader lake_bathy / relief /
    // hillshade 全部拿到真实湖盆深度。一键回退：profile lake_bathymetry_scale=0。
    {
        constexpr double PK_LAKE_SHELF_CELLS = 1.5;   // 近岸浅滩宽度(hex)：绝对离岸距离，不按湖半径归一
        constexpr double PK_LAKE_DEEP_CELLS  = 7.0;    // 到此离岸距离(hex)达满深 → 大湖内部整体判深水（关键修复）
        constexpr double PK_LAKE_MIN_DEPTH      = 0.050; // 物理碗形最小中心下切（height 单位）
        constexpr double PK_LAKE_MAX_DEPTH      = 0.240; // 物理下切上限（防穿到极端低高程）
        constexpr double PK_LAKE_BASIN_AMP      = 0.18;  // 湖底低频起伏幅度（×深度，仅深区生效）
        const double lake_bathy_scale = getd(profile, "lake_bathymetry_scale", 1.0); // 0=关闭

        if (lake_bathy_scale > 1e-4) {
            // 湖底起伏噪声（确定性，按 seed）：让湖盆不是完美碗形，出现水下浅丘/深潭。
            Ref<FastNoiseLite> lake_floor_noise;  lake_floor_noise.instantiate();
            if (lake_floor_noise.is_valid()) {
                lake_floor_noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX_SMOOTH);
                lake_floor_noise->set_seed(seed + 7757);
                lake_floor_noise->set_frequency(0.06);
                lake_floor_noise->set_fractal_type(FastNoiseLite::FRACTAL_FBM);
                lake_floor_noise->set_fractal_octaves(3);
            }
            std::vector<uint8_t> lb_seen(size_t(n), 0);
            std::vector<int32_t> sdist(size_t(n), -1);   // 离岸 hex 距离（仅湖内有效，逐域复位）
            std::vector<int> comp;  comp.reserve(256);
            std::vector<int> bfs;   bfs.reserve(256);
            int lake_bathy_components = 0;
            int lake_bathy_cells = 0;
            for (int s0 = 0; s0 < n; ++s0) {
                if (lb_seen[size_t(s0)] || TERR[s0] != 18) continue;
                // ① 收集该湖连通域。
                comp.clear();
                comp.push_back(s0);
                lb_seen[size_t(s0)] = 1;
                for (size_t qi = 0; qi < comp.size(); ++qi) {
                    const int cur = comp[qi];
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(cur) * 6 + d];
                        if (ni < 0 || lb_seen[size_t(ni)] || TERR[ni] != 18) continue;
                        lb_seen[size_t(ni)] = 1;
                        comp.push_back(ni);
                    }
                }
                ++lake_bathy_components;
                // ② 多源 BFS：湖内紧邻非湖(或出界)的格 = 岸(dist=0)，向湖心逐 hex 递增。
                bfs.clear();
                for (int c : comp) {
                    bool on_shore = false;
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(c) * 6 + d];
                        if (ni < 0 || TERR[ni] != 18) { on_shore = true; break; }
                    }
                    if (on_shore) { sdist[size_t(c)] = 0; bfs.push_back(c); }
                }
                int max_dist = 0;
                for (size_t bi = 0; bi < bfs.size(); ++bi) {
                    const int cur = bfs[bi];
                    const int cd = sdist[size_t(cur)];
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[size_t(cur) * 6 + d];
                        if (ni < 0 || TERR[ni] != 18 || sdist[size_t(ni)] >= 0) continue;
                        sdist[size_t(ni)] = cd + 1;
                        if (cd + 1 > max_dist) max_dist = cd + 1;
                        bfs.push_back(ni);
                    }
                }
                // ③ 湖深（物理碗形下切幅度）随湖体半径自适应：小塘浅、大湖到上限。
                double depth_amp = (double(max_dist) / PK_LAKE_DEEP_CELLS) * PK_LAKE_MAX_DEPTH * lake_bathy_scale;
                if (depth_amp < PK_LAKE_MIN_DEPTH) depth_amp = PK_LAKE_MIN_DEPTH;
                if (depth_amp > PK_LAKE_MAX_DEPTH) depth_amp = PK_LAKE_MAX_DEPTH;
                const double inv_deep = 1.0 / std::max(1.0, PK_LAKE_DEEP_CELLS - PK_LAKE_SHELF_CELLS);
                // ④ 逐格压湖底：以该格水面 hydro_fill 为深度=0 基准，按归一离岸距离刻碗形（仅下切）。
                for (int c : comp) {
                    const double surface = std::isfinite(hydro_fill[size_t(c)])
                                         ? double(hydro_fill[size_t(c)])
                                         : double(E[c]);
                    // 绝对离岸距离 ramp（对标海洋 shelf→deep，不按湖半径归一 → 大湖内部整体判深水）。
                    const double sd = (sdist[size_t(c)] >= 0) ? double(sdist[size_t(c)]) : 0.0;
                    double ramp = (sd - PK_LAKE_SHELF_CELLS) * inv_deep;
                    if (ramp < 0.0) ramp = 0.0; else if (ramp > 1.0) ramp = 1.0;
                    double depth01 = pk_smoothstep(0.0, 1.0, ramp);
                    if (lake_floor_noise.is_valid() && depth01 > 0.0) {
                        // [cylindrical-earth-daylight] 经度环绕采样，接缝处湖底连续。
                        const int col = c % width;
                        const double th = PK_TWO_PI * (double(col) / double(width));
                        const double rc = double(width) / PK_TWO_PI;
                        const double bn = double(lake_floor_noise->get_noise_3d(
                            simulation_math::cos(th) * rc, simulation_math::sin(th) * rc, double(R[c])));
                        depth01 += bn * PK_LAKE_BASIN_AMP * depth01;
                        if (depth01 < 0.0) depth01 = 0.0; else if (depth01 > 1.0) depth01 = 1.0;
                    }
                    double floor_e = surface - depth01 * depth_amp;
                    if (floor_e < 0.0) floor_e = 0.0;
                    if (floor_e < double(E[c])) { E[c] = float(floor_e); ++lake_bathy_cells; }
                    // [water-depth-tex] per-cell 只存"水面高度"（湖=该湖 hydro_fill 水位）；真实逐像素
                    // 水深由 bake 用 surface - height_tex(像素) 算（见 world_ext_bake），直接吃生成的高程图。
                    WDEPTH[c] = float(surface);
                    sdist[size_t(c)] = -1; // 复位供下一连通域复用
                }
            }
            out["lake_bathymetry_components"] = lake_bathy_components;
            out["lake_bathymetry_cells_carved"] = lake_bathy_cells;
        }
    }

    // water_depth01 现承载 per-cell "水面高度"：湖泊已在上面存其 hydro_fill 水位；这里补海洋/海岸/
    // 礁/海草/海冰 = sea_level；陆地 = 0。真实逐像素水深由 bake 用 surface - height_tex 算。
    {
        for (int i = 0; i < n; ++i) {
            if (TERR[i] == 18) continue;                 // 湖：上面已存其水面
            if (!pk_is_water_terrain(TERR[i])) { WDEPTH[i] = 0.0f; continue; }  // 陆地 = 0
            WDEPTH[i] = float(sea_level);                // 海洋/海岸/礁/海草/海冰水面 = sea_level
        }
    }

    for (int i = 0; i < n; ++i) {
        sync_axes(i);
    }
