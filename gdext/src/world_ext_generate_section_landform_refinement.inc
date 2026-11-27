    // ── 高原(PLATEAU) landform override：高海拔、低局部起伏、连通成片的陆地 ──
    // 不新增 terrain；只把三轴 landform 覆写为 PLATEAU，保留原 biome/vegetation。
    auto land_neighbor_count = [&](int i) -> int {
        int land_nb = 0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni >= 0 && !pk_is_water_terrain(TERR[ni])) ++land_nb;
        }
        return land_nb;
    };
    auto geomorph_relief = [&](int i) -> double {
        float min_e = E[i], max_e = E[i];
        for (int dq = -relief_radius; dq <= relief_radius; ++dq) {
            const int dr_lo = std::max(-relief_radius, -dq - relief_radius);
            const int dr_hi = std::min(relief_radius, -dq + relief_radius);
            for (int dr = dr_lo; dr <= dr_hi; ++dr) {
                if (dq == 0 && dr == 0) continue;
                const int ni = index_for_qr(Q[i] + dq, R[i] + dr);
                if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
                min_e = std::min(min_e, E[ni]);
                max_e = std::max(max_e, E[ni]);
            }
        }
        return (double(max_e) - double(min_e)) * relief_radius_norm;
    };

    std::vector<uint8_t> plateau_candidate(size_t(n), 0);
    int plateau_candidate_count = 0;
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i]) || VOLC[i] != 0) continue;
        if (pk_is_permanent_landform(TERR[i])) continue;
        const double lh = geomorph_h(i);
        if (lh < plateau_min_land_h || lh > 0.90) continue;
        if (land_neighbor_count(i) < 2) continue;
        const double relief = geomorph_relief(i);
        const bool broad_bench = lh >= plateau_min_land_h && relief <= plateau_max_relief;
        const bool high_bench = lh >= plateau_min_land_h + 0.10 && relief <= plateau_max_relief * 1.35;
        if (broad_bench || high_bench) {
            plateau_candidate[size_t(i)] = 1;
            ++plateau_candidate_count;
        }
    }
    int plateau_touched = 0;
    std::vector<uint8_t> plateau_seen(size_t(n), 0);
    for (int i : land) {
        if (!plateau_candidate[size_t(i)] || plateau_seen[size_t(i)]) continue;
        std::vector<int> comp;
        comp.push_back(i);
        plateau_seen[size_t(i)] = 1;
        for (size_t qi = 0; qi < comp.size(); ++qi) {
            const int cur = comp[qi];
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || plateau_seen[size_t(ni)] || !plateau_candidate[size_t(ni)]) continue;
                plateau_seen[size_t(ni)] = 1;
                comp.push_back(ni);
            }
        }
        const bool high_small_plateau = int(comp.size()) >= 2 && geomorph_h(comp[0]) >= plateau_min_land_h + 0.12;
        if (int(comp.size()) < plateau_min_cells && !high_small_plateau) continue;
        for (int v : comp) {
            LF[v] = 13;  // PLATEAU
            BLF[v] = 13;
            ++plateau_touched;
        }
    }

    // ── 山地(MOUNTAIN)瘦身：山脉应是高起伏地带，高海拔平缓面应落到 PLATEAU/HILL ──
    int mountain_demoted = 0;
    int mountain_to_plateau = 0;
    int mountain_height_candidates = 0;
    int mountain_relief_candidates = 0;
    int mountain_kept = 0;
    for (int i : land) {
        if (LF[i] != 7 || pk_is_water_terrain(TERR[i]) || VOLC[i] != 0) continue;
        if (TERR[i] == 22 || TERR[i] == 24 || TERR[i] == 25 || TERR[i] == 30) continue;
        const double lh = geomorph_h(i);
        if (land_neighbor_count(i) < 3) continue;
        const double relief = geomorph_relief(i);
        const bool summit_rugged = lh >= peak_min_land_h && relief >= mountain_min_relief * 0.65;
        const bool keep_mountain = lh >= mountain_min_land_h && (relief >= mountain_min_relief || summit_rugged);
        if (lh >= mountain_min_land_h) ++mountain_height_candidates;
        if (lh >= mountain_min_land_h && (relief >= mountain_min_relief || summit_rugged)) {
            ++mountain_relief_candidates;
        }
        if (keep_mountain) {
            ++mountain_kept;
            continue;
        }

        if (lh >= plateau_min_land_h && lh <= 0.90 && relief <= plateau_max_relief * 1.10) {
            LF[i] = 13;  // PLATEAU
            BLF[i] = 13;
            ++mountain_to_plateau;
        } else {
            LF[i] = 6;   // HILL
            BLF[i] = 6;
            ++mountain_demoted;
        }
    }

    // ── [density-fix 2026-06-30] PLATEAU 面积占比上限剪裁 ──
    // 高原此前无任何密度上限（PEAK 按 land/N 限量、RIFT 按 land/N 限量，唯独 PLATEAU 没有），
    // 导致大地图上所有满足 land_h/relief 条件的平坦中高海拔区全部标为 PLATEAU。
    // 现按连通分量面积从大到小累计，保留至 plateau_max_land_ratio × land 为止，
    // 其余较小连通分量整体降级为 HILL（保留大高原、清理碎片）。
    int plateau_demoted_to_hill = 0;
    if (plateau_max_land_ratio < 1.0) {
        std::vector<uint8_t> plat_seen(size_t(n), 0);
        std::vector<std::vector<int>> plat_comps;
        for (int i : land) {
            if (LF[i] != 13 || plat_seen[size_t(i)]) continue;
            std::vector<int> comp;
            comp.push_back(i);
            plat_seen[size_t(i)] = 1;
            for (size_t qi = 0; qi < comp.size(); ++qi) {
                const int cur = comp[qi];
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(cur) * 6 + d];
                    if (ni < 0 || plat_seen[size_t(ni)] || LF[ni] != 13) continue;
                    plat_seen[size_t(ni)] = 1;
                    comp.push_back(ni);
                }
            }
            plat_comps.push_back(std::move(comp));
        }
        std::sort(plat_comps.begin(), plat_comps.end(),
                [](const std::vector<int> &a, const std::vector<int> &b){ return a.size() > b.size(); });
        const int plateau_cap = std::max(0, int(double(land.size()) * plateau_max_land_ratio));
        int plateau_kept = 0;
        for (const auto &comp : plat_comps) {
            if (plateau_kept < plateau_cap) {
                plateau_kept += int(comp.size());
            } else {
                for (int v : comp) {
                    LF[v] = 6;   // HILL
                    BLF[v] = 6;
                    ++plateau_demoted_to_hill;
                }
            }
        }
    }

    // ── 峰顶(PEAK) landform sparsify：山脉是主体，高峰只保留局部 summit ──
    // 基础 landform helper 只能按单格海拔分段，容易把高海拔山原整片判成 PEAK。
    // 这里先退回为 MOUNTAIN，再按局部相对高度、邻域落差和最小间距选出少量真正峰顶。
    int peak_demoted = 0;
    for (int i : land) {
        if (LF[i] == 8) {
            LF[i] = 7;
            BLF[i] = 7;
            ++peak_demoted;
        }
    }
    struct PeakCandidate {
        int idx;
        double score;
    };
    std::vector<PeakCandidate> peak_candidates;
    peak_candidates.reserve(64);
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i]) || VOLC[i] != 0) continue;
        if (TERR[i] == 22 || TERR[i] == 24 || TERR[i] == 25 || TERR[i] == 30) continue;
        const double lh = geomorph_h(i);
        if (lh < peak_min_land_h) continue;
        float min_nb = E[i];
        float max_nb = -1.0e9f;
        int land_nb = 0;
        int lower_prominent = 0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
            ++land_nb;
            min_nb = std::min(min_nb, E[ni]);
            max_nb = std::max(max_nb, E[ni]);
            if (double(E[i]) - double(E[ni]) >= peak_min_prominence) ++lower_prominent;
        }
        if (land_nb < 3) continue;
        const double relief = double(E[i]) - double(min_nb);
        const bool local_cap = double(E[i]) >= double(max_nb) - 0.006;
        if (!local_cap || lower_prominent < 2 || relief < peak_min_prominence) continue;
        peak_candidates.push_back({i, lh + relief * 2.0 + 0.01 * double(lower_prominent)});
    }
    std::sort(peak_candidates.begin(), peak_candidates.end(),
              [](const PeakCandidate &a, const PeakCandidate &b) {
                  if (a.score == b.score) return a.idx < b.idx;
                  return a.score > b.score;
              });
    const int peak_limit = std::max(1, int(land.size()) / peak_land_cells_per_peak);
    int peak_touched = 0;
    std::vector<int> peak_placed;
    peak_placed.reserve(size_t(peak_limit));
    for (const PeakCandidate &cand : peak_candidates) {
        if (peak_touched >= peak_limit) break;
        bool far_enough = true;
        for (int p : peak_placed) {
            if (cube_distance(cand.idx, p) < 3) { far_enough = false; break; }
        }
        if (!far_enough) continue;
        LF[cand.idx] = 8;
        BLF[cand.idx] = 8;
        peak_placed.push_back(cand.idx);
        ++peak_touched;
    }

    // ── 裂谷地貌(RIFT_VALLEY) override：两侧抬升夹住的连续线状洼地 ──
    // 局部剖面先确定两侧断崖方向，再只沿断崖之间的谷轴连接候选。裂谷是连续构造带，
    // 不使用全图数量、面积或格间距配额；最小物理长度仅过滤孤立洼点和短沟槽。
    int rift_touched = 0;
    int rift_candidate_count = 0;
    int rift_component_count = 0;
    int rift_rejected_fragment_count = 0;
    int rift_largest_component = 0;
    std::vector<uint8_t> rift_candidate(size_t(n), 0);
    std::vector<int8_t> rift_cross_axis(size_t(n), -1);
    for (int i = 0; i < n; ++i) {
        if (pk_is_water_terrain(TERR[i])) continue;
        if (LF[i] == 8 || LF[i] == 12 || LF[i] == 13) continue; // 高峰/火山/高原保留
        const double lh = geomorph_h(i);
        if (lh < 0.03 || lh > 0.72) continue;
        int higher = 0, land_nb = 0;
        double max_raise = 0.0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
            ++land_nb;
            const double raise = double(E[ni]) - double(E[i]);
            if (raise > rift_min_wall * (4.0 / 3.0)) ++higher;
            if (raise > max_raise) max_raise = raise;
        }
        if (land_nb < 3 || higher < 2 || max_raise < rift_min_wall * 1.875) continue;
        double best_axis = 0.0;
        int best_cross_axis = -1;
        for (int d = 0; d < 3; ++d) {
            const int a = NB[size_t(i) * 6 + d];
            const int b = NB[size_t(i) * 6 + ((d + 3) % 6)];
            if (a < 0 || b < 0 || pk_is_water_terrain(TERR[a]) || pk_is_water_terrain(TERR[b])) continue;
            const double ra = double(E[a]) - double(E[i]);
            const double rb = double(E[b]) - double(E[i]);
            if (ra <= rift_min_wall || rb <= rift_min_wall) continue;
            const double axis_score = std::min(ra, rb) + 0.35 * std::max(ra, rb);
            if (axis_score > best_axis) {
                best_axis = axis_score;
                best_cross_axis = d;
            }
        }
        if (best_axis < rift_min_axis || best_cross_axis < 0) continue;
        rift_candidate[size_t(i)] = 1;
        rift_cross_axis[size_t(i)] = int8_t(best_cross_axis);
        ++rift_candidate_count;
    }

    auto follows_rift_axis = [&](int cell, int dir) -> bool {
        const int cross = int(rift_cross_axis[size_t(cell)]);
        return cross >= 0 && dir != cross && dir != cross + 3;
    };
    std::vector<uint8_t> rift_seen(size_t(n), 0);
    for (int seed_cell : land) {
        if (!rift_candidate[size_t(seed_cell)] || rift_seen[size_t(seed_cell)]) continue;
        std::vector<int> component;
        component.push_back(seed_cell);
        rift_seen[size_t(seed_cell)] = 1;
        for (size_t qi = 0; qi < component.size(); ++qi) {
            const int cur = component[qi];
            for (int d = 0; d < 6; ++d) {
                const int ni = NB[size_t(cur) * 6 + d];
                if (ni < 0 || !rift_candidate[size_t(ni)] || rift_seen[size_t(ni)]) continue;
                if (!follows_rift_axis(cur, d) || !follows_rift_axis(ni, (d + 3) % 6)) continue;
                rift_seen[size_t(ni)] = 1;
                component.push_back(ni);
            }
        }
        ++rift_component_count;
        rift_largest_component = std::max(rift_largest_component, int(component.size()));

        int endpoint = component.front();
        int farthest_dist = -1;
        for (int cell : component) {
            const int dist = cube_distance(component.front(), cell);
            if (dist > farthest_dist) {
                farthest_dist = dist;
                endpoint = cell;
            }
        }
        int span_cells = 1;
        for (int cell : component) {
            span_cells = std::max(span_cells, cube_distance(endpoint, cell) + 1);
        }
        if (int(component.size()) < rift_min_length || span_cells < rift_min_length) {
            rift_rejected_fragment_count += int(component.size());
            continue;
        }
        for (int cell : component) {
            LF[cell] = 14;  // RIFT_VALLEY
            BLF[cell] = 14;
            ++rift_touched;
        }
    }

    // ── 峡谷(CANYON) override：河流深切、两壁陡立的线状侵蚀峡谷 ──
    // 与 BADLANDS(干旱软岩片状恶地)、RIFT_VALLEY(构造离散边界裂谷) 三者区分：
    //   * CANYON 必须有河道穿过(RIV != 0)，且对置两侧都有明显陡壁(河流下切成 gorge)；
    //   * 不限定干旱，湿润山区的深切河谷(如长江三峡型)也成峡谷；
    //   * 跑在 rift 之后并跳过已写入的结构性地貌，避免与裂谷/高原/高峰重复占用。
    const double canyon_min_wall = getd(profile, "canyon_min_wall", 0.05);
    const double canyon_min_axis = getd(profile, "canyon_min_axis", 0.06);
    int canyon_touched = 0;
    for (int i : land) {
        if (pk_is_water_terrain(TERR[i])) continue;
        if (RIV[i] == 0) continue;                                   // 必须有河道穿过
        if (LF[i] == 8 || LF[i] == 12 || LF[i] == 13 || LF[i] == 14) continue; // 峰/火山/高原/裂谷保留
        const double lh = geomorph_h(i);
        if (lh < 0.05 || lh > 0.85) continue;
        int land_nb = 0, higher = 0;
        double max_raise = 0.0;
        for (int d = 0; d < 6; ++d) {
            const int ni = NB[size_t(i) * 6 + d];
            if (ni < 0 || pk_is_water_terrain(TERR[ni])) continue;
            ++land_nb;
            const double raise = double(E[ni]) - double(E[i]);
            if (raise > canyon_min_wall) ++higher;
            if (raise > max_raise) max_raise = raise;
        }
        if (land_nb < 3 || higher < 2 || max_raise < canyon_min_wall) continue;
        // 对置轴：河谷两壁都明显抬升 → gorge（区别于单侧山坡上的河道）。
        double best_axis = 0.0;
        for (int d = 0; d < 3; ++d) {
            const int a = NB[size_t(i) * 6 + d];
            const int b = NB[size_t(i) * 6 + ((d + 3) % 6)];
            if (a < 0 || b < 0 || pk_is_water_terrain(TERR[a]) || pk_is_water_terrain(TERR[b])) continue;
            const double ra = double(E[a]) - double(E[i]);
            const double rb = double(E[b]) - double(E[i]);
            if (ra <= canyon_min_wall * 0.5 || rb <= canyon_min_wall * 0.5) continue;
            best_axis = std::max(best_axis, std::min(ra, rb) + 0.35 * std::max(ra, rb));
        }
        if (best_axis < canyon_min_axis) continue;
        LF[i] = 15;  // CANYON
        BLF[i] = 15;
        ++canyon_touched;
    }
