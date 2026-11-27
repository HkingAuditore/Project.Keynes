    // ─── 水体气候回灌（仅新增 base 阶段不存在的湖/河项；海洋项不重做）──────────────
    // 职责收紧：海洋调温 / 沿海湿度地板 / land_continentality 由 base pass 维持，
    // 这里只补 post_base 才判定的湖泊与窄河岸湿润带。全部 floor(max)/additive 语义 +
    // 指数衰减 + water_dist_max 截断，不全局抬湿；回灌后由下方受保护的最终重判统一消费。
    // 改动写入 M[]，经既有 moisture_arr 导出自然下传给 HexCell / bake terrain-index。
    // 注：大河河道格(RIV)本身已在 river_ecology(上方)被 floor 到 0.66/0.74；这里把湿润带
    // 外扩到河道近邻的非河道陆地，与上方不冲突（仍是 floor，取较大值）。
    // [延后] 湖泊局地温度调节：TEMP[] 为只读、且 bind 后 republish 会重算温度场，
    // 在此写温度无持久收益，需要专门的 temp-adjust 通道后再做，本期只做湿度。
    int lakeshore_moist_touched = 0;
    int riparian_moist_touched = 0;
    {
        const float lake_moist_floor    = float(getd(cfg, "lake_moist_floor", 0.55));
        const float lake_moist_scale    = float(std::max(0.25, getd(cfg, "lake_moist_scale", 2.5)));
        const float river_riparian_floor= float(std::clamp(getd(cfg, "river_riparian_floor", 0.36), 0.0, 1.0));
        const float river_riparian_gain = float(getd(cfg, "river_riparian_gain", 0.12));
        const float river_riparian_scale= float(std::max(0.25, getd(cfg, "river_riparian_scale", 2.0)));
        for (int i : land) {
            const int wd = water_dist[size_t(i)];
            if (wd <= 0) continue;                                   // 0=水体自身/无效；只回灌陆地近邻带
            const uint8_t kind = water_src_kind[size_t(i)];
            if (kind == 1) {                                         // 湖滨增湿带（floor）
                const float decay = simulation_math::exp(-float(wd) / lake_moist_scale);
                const float floor_m = lake_moist_floor * decay;
                if (M[i] < floor_m) { M[i] = floor_m; ++lakeshore_moist_touched; }
            } else if (kind == 2) {                                 // 河谷 riparian 地板 + 增湿（封顶）
                if (wd > 2) continue;                               // 河岸带保持窄，不把整个流域抬湿
                const float flow_scale = std::max(0.01f, water_big_river_min);
                const float flow_strength = std::clamp(water_src_flow[size_t(i)] / flow_scale, 0.0f, 1.0f);
                if (wd == 1) {
                    const float floor_m = river_riparian_floor + 0.06f * flow_strength;
                    if (M[i] < floor_m) { M[i] = floor_m; ++riparian_moist_touched; }
                }
                const float add = river_riparian_gain * simulation_math::exp(-float(wd) / river_riparian_scale);
                if (add > 0.0f) {
                    float m = M[i] + add;
                    if (m > 1.0f) m = 1.0f;
                    if (m > M[i]) { M[i] = m; ++riparian_moist_touched; }
                }
            }
            // kind==0（海洋性）：base pass 已处理，这里不动，避免双重计算。
        }
    }

    // 所有静态水分驱动完成后，用同一 gen_temp + 分类器做唯一一次最终气候重判。
    // 河道和特征地形保留给专用覆盖 pass，避免恢复旧 vegetation-feedback 正反馈或抹掉绿洲/河漫滩。
    int final_climate_redecide_evaluated = 0;
    int final_climate_redecide_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (RIV[i] != 0 || pk_is_water_terrain(t) || pk_is_permanent_landform(t)) continue;
        if (t == 6 || t == 9 || t == 8) continue; // MOUNTAIN/SNOW/TUNDRA 保持生成期稳定边界
        ++final_climate_redecide_evaluated;
        const uint8_t nt = pk_decide_terrain_ex(double(E[i]), gen_temp(i),
                                                double(M[i]), sea_level, true);
        if (pk_is_water_terrain(nt)) continue; // 排干的 below-sea 陆地不得重新变回水体
        if (nt != t) {
            TERR[i] = nt;
            ++final_climate_redecide_touched;
        }
    }

    int shrubland_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t)) continue;
        if (!(t == 3 || t == 14 || t == 12 || t == 2)) continue;
        if (pk_is_permanent_landform(t)) continue;
        const double lh = land_h(i);
        if (lh > 0.45) continue;
        const double temp = gen_temp(i);
        // [climate-zone-fix P1] 限制为真·暖温带地中海生态位：加温度上限(0.58)排除热带/亚热带
        // 沿海格（原仅 temp>=0.42 无上限→把任意暖区沿海中湿格刷成 MEDIT，占陆地 21%、远超
        // 真地中海气候 ~6%），并收窄湿度上沿（地中海半干 moist≈0.35）。
        if (temp < 0.42 || temp > 0.58) continue;
        if (M[i] < 0.20f || M[i] > 0.44f) continue;
        bool has_sea = false;
        const int dd = dist_ocean[size_t(i)];
        if (dd >= 0 && dd <= 4) has_sea = true;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && (TERR[ni] == 0 || TERR[ni] == 1)) { has_sea = true; break; }
        }
        if (has_sea) {
            TERR[i] = 15;
            ++shrubland_touched;
        }
    }

    int mangrove_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t)) continue;
        if (t == 6 || t == 9 || t == 8 || t == 10) continue;
        if (pk_is_permanent_landform(t)) continue;
        if (land_h(i) > 0.08) continue;
        const double temp = gen_temp(i);
        if (temp < 0.60) continue;
        bool coast_nb = false;
        bool swamp_nb = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            if (TERR[ni] == 1) coast_nb = true;
            else if (TERR[ni] == 10) swamp_nb = true;
        }
        if (coast_nb && (RIV[i] != 0 || swamp_nb || M[i] >= 0.70f)) {
            TERR[i] = 16;
            ++mangrove_touched;
        }
    }

    int glacier_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (!(t == 9 || t == 8)) continue;
        const double temp = gen_temp(i);
        if (temp >= 0.05) continue;
        bool coastal = false;
        if (land_h(i) < 0.20) {
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && (TERR[ni] == 0 || TERR[ni] == 1 || TERR[ni] == 20)) {
                    coastal = true;
                    break;
                }
            }
        }
        if (coastal || land_h(i) > 0.65) {
            TERR[i] = 17;
            ++glacier_touched;
        }
    }

    int swamp_touched = 0;
    const int swamp_water_band = std::max(0, geti(cfg, "swamp_water_band", 2));
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || t == 6 || t == 9 || t == 8) continue;
        if (pk_is_permanent_landform(t)) continue;
        if (land_h(i) > 0.10 || M[i] < 0.75f) continue;
        const double temp = pk_clamp01(pk_lat_temp_bell((row_norm(i) - 0.5) * 2.0) - pk_alt_penalty(E[i], sea_level));
        if (temp < 0.30) continue;
        bool has_water = (RIV[i] != 0);
        if (!has_water) {
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && pk_is_water_terrain(TERR[ni])) { has_water = true; break; }
            }
        }
        // [water-bodies] 统一距水场：湖/大河近邻带(不止 1 格邻接)也算"近水"，让湿地沿
        // 湖滨/河谷成有宽度的连续带（与上方湿度回灌同源、graded）。高 M(0.75)+低地+暖温
        // 三道既有闸门仍在，故不会因放宽近水判定而泛滥。
        if (!has_water && swamp_water_band > 0) {
            const int wd = water_dist[size_t(i)];
            const uint8_t wk = water_src_kind[size_t(i)];
            if (wd > 0 && wd <= swamp_water_band && (wk == 1 || wk == 2)) has_water = true;
        }
        if (has_water) {
            TERR[i] = 10;
            ++swamp_touched;
        }
    }

    // 火山候选：镜像 _apply_volcano_pass —— 行主序（cell 索引升序）遍历 MOUNTAIN 且
    // land_h>=阈值，再用 Godot RandomNumberGenerator(seed+7717) Fisher-Yates 洗牌
    // （与 GDScript 逐位同源，不能用 xorshift 替代，否则洗牌序列不一致）。
    // 注意：必须用 0..n 索引序，不能用 `land`——`land` 已被 flow-accumulation 按高程
    // 降序排过序（见上方 std::sort），而 GDScript `_apply_volcano_pass` 遍历的
    // `map.all_cells()` = _cells.values() 是 set_cell 的 row-major 插入序。两者顺序
    // 不一致会让洗牌前的候选数组次序错位，导致火山落点分歧（parity FAIL）。
    std::vector<int> volcano_candidates;
    for (int i = 0; i < n; ++i) {
        if (TERR[i] != 6) continue;
        if (geomorph_h(i) < volcano_min_land_h) continue;
        volcano_candidates.push_back(i);
    }
    Ref<RandomNumberGenerator> volc_rng;  volc_rng.instantiate();
    if (volc_rng.is_valid()) {
        volc_rng->set_seed(uint64_t(seed + 7717));
        for (int i = int(volcano_candidates.size()) - 1; i > 0; --i) {
            const int j = volc_rng->randi_range(0, i);
            std::swap(volcano_candidates[size_t(i)], volcano_candidates[size_t(j)]);
        }
    }
    std::vector<int> volcano_placed;
    for (int cand : volcano_candidates) {
        if (int(volcano_placed.size()) >= max_volcanoes) break;
        bool ok = true;
        for (int p : volcano_placed) {
            if (cube_distance(cand, p) < volcano_min_dist) { ok = false; break; }
        }
        if (!ok) continue;
        VOLC[cand] = 1;
        LF[cand] = 12;   // VOLCANO
        BLF[cand] = 12;
        volcano_placed.push_back(cand);

        // [volcano-crater 2026-06-25] 生成期把火山塑成环形山高度场：中心 cell 下凹成火山口(caldera)，
        // 第一环 6 邻居抬升成环形山脊(rim)。map_baker 的 barycentric 高度插值(self+2 邻居)会把这组
        // per-cell 高差平滑烘进 height_tex，靠 hillshade 自然成形——取代旧 shader 的密集橙点。
        // 幅度以归一化高程(0..1)计；volcano_min_dist 默认 6 → 不同火山的环脊邻域不会重叠。
        E[cand] = float(pk_clamp01(double(E[cand]) - volcano_crater_depth));
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(cand) * 6 + d];
            if (ni < 0) continue;
            if (pk_is_water_terrain(TERR[ni])) continue;   // 不抬海/湖/海岸，避免环山探进水里
            if (VOLC[ni]) continue;                         // 邻居自身是火山则不二次抬升
            // 方位抖动破除完美圆环 artifact（确定性 hash，无 RNG → 不影响落点 parity）。
            const double hv = simulation_math::sin(double(cand) * 12.9898 + double(d) * 78.233) * 43758.5453;
            const double jitter = 0.80 + 0.40 * (hv - std::floor(hv));
            E[ni] = float(pk_clamp01(double(E[ni]) + volcano_rim_height * jitter));
        }
    }

    int delta_touched = 0;
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i]) || RIV[i] == 0 || pk_is_permanent_landform(TERR[i])) continue;
        if (land_h(i) > 0.20) continue;
        if (river_ecology_flow[size_t(i)] < 0.35f) continue;
        bool ocean_nb = false;
        bool coast_nb = false;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && (TERR[ni] == 0 || TERR[ni] == 1)) { ocean_nb = true; coast_nb = TERR[ni] == 1; break; }
        }
        if (ocean_nb && (coast_nb || river_ecology_flow[size_t(i)] >= 0.55f)) {
            TERR[i] = 22;
            if (M[i] < 0.78f) M[i] = 0.78f;
            ++delta_touched;
        }
    }

    int oasis_touched = 0;
    for (int i : land) {
        const uint8_t t = TERR[i];
        if (pk_is_water_terrain(t) || pk_is_permanent_landform(t)) continue;
        // 回归修复(2026-06-18)：绿洲仅在真正的暖沙漠(DESERT)中生成，避免对任意干暖陆地
        // 滥铺(此前 698 格/5.5%)。寒漠/草原/灌丛不结绿洲。
        if (t != 7) continue;
        if (BM[i] > 0.38f && M[i] > 0.45f) continue;
        if (gen_temp(i) < 0.40) continue;
        bool has_water = (RIV[i] != 0);
        if (!has_water) {
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(i) * 6 + d];
                if (ni >= 0 && TERR[ni] == 18) { has_water = true; break; }
            }
        }
        if (has_water) {
            if (M[i] < 0.55f) M[i] = 0.55f;
            TERR[i] = 23;
            ++oasis_touched;
        }
    }

    // terrain-overhaul Phase 5：盐滩收紧——仅真正内陆(距海 ≥ salt_flat_min_dist)的内流盆地
    // 底部(局部洼地)才结盐，消除沿海/坡地"错位盐滩" artifact。
    const int salt_flat_min_dist = std::max(0, geti(profile, "salt_flat_min_dist_ocean", 4));
    int salt_flat_touched = 0;
    for (int i : land) {
        if (TERR[i] != 7 && TERR[i] != 26) continue;
        if (land_h(i) > 0.18) continue;
        const int dd = dist_ocean[size_t(i)];
        if (dd >= 0 && dd < salt_flat_min_dist) continue; // 离海太近 → 非内流盐碱
        bool endorheic = (RIV[i] == 0);
        float min_nb = E[i];
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            min_nb = std::min(min_nb, E[ni]);
            if (endorheic && (RIV[ni] != 0 || pk_is_water_terrain(TERR[ni]))) endorheic = false;
        }
        // 必须位于盆地底部（≤ 最低邻居 + 微容差），避免坡面误判。
        const bool basin_floor = (double(E[i]) <= double(min_nb) + 0.02);
        if (endorheic && basin_floor) {
            TERR[i] = 24;
            ++salt_flat_touched;
        }
    }

    int badlands_touched = 0;
    int badlands_candidate_count = 0;
    int badlands_candidate_components = 0;
    int badlands_budget_rejected = 0;
    int badlands_largest_component = 0;
    int badlands_budget = 0;
    int mesa_touched = 0;
    int arid_source_count = 0;
    for (int i : land) {
        if (TERR[i] == 7 || TERR[i] == 24 || TERR[i] == 26) ++arid_source_count;
    }

    std::vector<uint8_t> badlands_candidate_mask(size_t(n), 0);
    std::vector<double> badlands_score(size_t(n), 0.0);
    for (int i : land) {
        if (TERR[i] != 7 && TERR[i] != 26) continue;
        float min_e = E[i];
        float max_e = E[i];
        float max_nb = -1.0e9f;
        bool water_nb = false;
        int rugged_neighbors = 0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0) continue;
            min_e = std::min(min_e, E[ni]);
            max_e = std::max(max_e, E[ni]);
            max_nb = std::max(max_nb, E[ni]);
            if (pk_is_water_terrain(TERR[ni]) || RIV[ni] != 0) water_nb = true;
            if (std::abs(double(E[ni]) - double(E[i])) >= badlands_min_relief * 0.35) {
                ++rugged_neighbors;
            }
        }
        // 荒原/方山是干旱侵蚀地貌，不应占用河道或紧贴海、湖、河岸。
        if (water_nb || RIV[i] != 0) continue;
        const double relief = double(max_e) - double(min_e);
        if (relief < badlands_min_relief) continue;
        // 方山(MESA)：高差地貌中本格为局部高点(平顶台地)且海拔够高；
        // 否则为侵蚀沟壑恶地(BADLANDS)。
        const bool flat_top = (double(E[i]) >= double(max_nb) - 0.004) && (geomorph_h(i) > 0.18);
        if (flat_top) {
            TERR[i] = 30; // MESA
            ++mesa_touched;
            continue;
        }
        if (rugged_neighbors < badlands_min_rugged_neighbors) continue;
        badlands_candidate_mask[size_t(i)] = 1;
        badlands_score[size_t(i)] = relief * 3.0
                + (1.0 - double(M[i])) * 0.15
                + double(rugged_neighbors) * 0.02;
        ++badlands_candidate_count;
    }

    // 荒原是沙漠中的局地侵蚀斑块，而不是所有崎岖沙漠的默认分类。候选区按
    // 连通分量处理，从最高分格向邻格生长；默认让候选区自身决定斑块大小，
    // 只有显式配置安全阀时才按总量/斑块格数截断。
    struct BadlandsComponent {
        std::vector<int> cells;
        int seed = -1;
        double best_score = -1.0;
    };
    std::vector<uint8_t> badlands_seen(size_t(n), 0);
    std::vector<BadlandsComponent> badlands_components;
    for (int i : land) {
        if (!badlands_candidate_mask[size_t(i)] || badlands_seen[size_t(i)]) continue;
        BadlandsComponent comp;
        comp.cells.push_back(i);
        badlands_seen[size_t(i)] = 1;
        for (size_t qi = 0; qi < comp.cells.size(); ++qi) {
            const int cur = comp.cells[qi];
            const double score = badlands_score[size_t(cur)];
            if (score > comp.best_score || (score == comp.best_score && cur < comp.seed)) {
                comp.best_score = score;
                comp.seed = cur;
            }
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || badlands_seen[size_t(ni)]
                        || !badlands_candidate_mask[size_t(ni)]) continue;
                badlands_seen[size_t(ni)] = 1;
                comp.cells.push_back(ni);
            }
        }
        badlands_components.push_back(std::move(comp));
    }
    badlands_candidate_components = int(badlands_components.size());
    std::sort(badlands_components.begin(), badlands_components.end(),
            [](const BadlandsComponent &a, const BadlandsComponent &b) {
                if (a.best_score == b.best_score) return a.seed < b.seed;
                return a.best_score > b.best_score;
            });

    const int land_budget = int(std::floor(double(land.size()) * badlands_max_land_ratio));
    const int arid_budget = int(std::floor(double(arid_source_count) * badlands_max_arid_ratio));
    badlands_budget = std::max(0, std::min(land_budget, arid_budget));
    std::vector<uint8_t> badlands_selected(size_t(n), 0);
    std::vector<uint8_t> badlands_queued(size_t(n), 0);
    for (const BadlandsComponent &comp : badlands_components) {
        if (badlands_touched >= badlands_budget) break;
        int patch_quota = std::min(int(comp.cells.size()), badlands_budget - badlands_touched);
        if (badlands_max_patch_cells > 0) {
            patch_quota = std::min(patch_quota, badlands_max_patch_cells);
        }
        if (patch_quota <= 0 || comp.seed < 0) continue;

        std::priority_queue<std::pair<double, int>> frontier;
        frontier.push({badlands_score[size_t(comp.seed)], -comp.seed});
        badlands_queued[size_t(comp.seed)] = 1;
        int patch_size = 0;
        while (!frontier.empty() && patch_size < patch_quota) {
            const int cur = -frontier.top().second;
            frontier.pop();
            if (badlands_selected[size_t(cur)]) continue;
            badlands_selected[size_t(cur)] = 1;
            TERR[cur] = 25; // BADLANDS
            ++patch_size;
            ++badlands_touched;
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || badlands_queued[size_t(ni)]
                        || !badlands_candidate_mask[size_t(ni)]) continue;
                badlands_queued[size_t(ni)] = 1;
                frontier.push({badlands_score[size_t(ni)], -ni});
            }
        }
        badlands_largest_component = std::max(badlands_largest_component, patch_size);
    }
    badlands_budget_rejected = badlands_candidate_count - badlands_touched;
