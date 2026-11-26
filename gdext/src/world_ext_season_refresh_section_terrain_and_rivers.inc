    // ─── stage 1：rain_shadow_per_cell ────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_rain_shadow_per_cell (line 3149).
    // 流程：陆地 cell → wind_vector 优先 / WindBelt fallback → upwind hex dir
    // → lookback N 步 → 若上风 cell 海拔高 threshold → moisture *= factor。
    if (stage == 1) {
        if (!knobs.has("n_cells") || !knobs.has("rain_shadow_lookback") ||
            !knobs.has("rain_shadow_threshold") || !knobs.has("rain_shadow_factor") ||
            !knobs.has("neighbor_indices") || !knobs.has("season_phase") ||
            !knobs.has("jitter_arr")) {
            return fail("stage_1 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int lookback = std::max(0, int(knobs["rain_shadow_lookback"]));
        const float threshold = float(knobs["rain_shadow_threshold"]);
        const float factor = float(knobs["rain_shadow_factor"]);
        const double season_phase = double(knobs["season_phase"]);
        if (n_cells <= 0) return fail("stage_1 n_cells <= 0");

        const int sid_terrain = component("cell_terrain");
        const int sid_moist   = component("cell_moisture");
        const int sid_elev    = component("cell_elevation");
        const int sid_wx      = component("cell_wind_x");
        const int sid_wy      = component("cell_wind_y");
        const int sid_lat     = component("cell_lat_norm");
        if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 ||
            sid_wx < 0 || sid_wy < 0 || sid_lat < 0) {
            return fail("stage_1 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_m = slot(sid_moist);
        Slot &s_e = slot(sid_elev);
        Slot &s_wx = slot(sid_wx);
        Slot &s_wy = slot(sid_wy);
        Slot &s_lat = slot(sid_lat);
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_wx.arr_f32.size() != n_cells ||
            s_wy.arr_f32.size() != n_cells || s_lat.arr_f32.size() != n_cells) {
            return fail("stage_1 slot size mismatch");
        }
        auto &nb_arr = arrays.neighbors;
        if (nb_arr.size() < n_cells * 6) return fail("stage_1 neighbor_indices size mismatch");
        auto &jitter_arr = arrays.jitter;
        if (jitter_arr.size() != n_cells) return fail("stage_1 jitter_arr size mismatch");

        const uint8_t * const __restrict TERR = s_t.arr_u8.ptr();
        float         * const __restrict M    = s_m.arr_f32.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        const float   * const __restrict WX   = s_wx.arr_f32.ptr();
        const float   * const __restrict WY   = s_wy.arr_f32.ptr();
        const float   * const __restrict LAT  = s_lat.arr_f32.ptr();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const float   * const __restrict JITTER = jitter_arr.ptr();

        // 6 hex 方向（与 pk_upwind_dir_index_from_wind 内 DIRS 同源），
        // 用于把 wind 向量映射到 0..5 索引。
        constexpr int DIRS[6][3] = {
            { 1,  0, -1}, { 1, -1,  0}, { 0, -1,  1},
            {-1,  0,  1}, {-1,  1,  0}, { 0,  1, -1},
        };
        constexpr double inv_sqrt2 = 0.7071067811865475;

        auto pick_dir_from_wind = [=](double wx, double wy) -> int {
            const double len2 = wx * wx + wy * wy;
            if (len2 <= 0.0001) return -1;
            const double inv_len = 1.0 / std::sqrt(len2);
            const double nx = wx * inv_len;
            const double ny_ = wy * inv_len;
            const double wq = std::sqrt(3.0) / 3.0 * nx - ny_ / 3.0;
            const double wr = 2.0 / 3.0 * ny_;
            const double ws = -wq - wr;
            const double clen = std::sqrt(wq * wq + wr * wr + ws * ws);
            if (clen <= 0.0001) return -1;
            const double uq = -wq / clen;
            const double ur = -wr / clen;
            const double us = -ws / clen;
            int best = 0;
            double best_dot = -std::numeric_limits<double>::infinity();
            for (int d = 0; d < 6; ++d) {
                const double dot = uq * double(DIRS[d][0]) * inv_sqrt2
                                 + ur * double(DIRS[d][1]) * inv_sqrt2
                                 + us * double(DIRS[d][2]) * inv_sqrt2;
                if (dot > best_dot) { best_dot = dot; best = d; }
            }
            return best;
        };

        PreparedSeasonStage prepared;
        prepared.slots = {sid_moist};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                if (pk_is_water_terrain(TERR[i])) continue;
                if (lookback <= 0) continue;
                int dir;
                // 先用 cell.wind_vector（地形扰动后的实际盛行风），与 _pick_upwind_dir 一致。
                const double cell_wx = double(WX[i]);
                const double cell_wy = double(WY[i]);
                const double wv_len2 = cell_wx * cell_wx + cell_wy * cell_wy;
                if (wv_len2 > 0.0001) { // wv.length() > 0.01 等价
                    dir = pick_dir_from_wind(cell_wx, cell_wy);
                } else {
                    // Fallback：WindBelt.wind_at(ny, season_phase, lat_jitter)
                    const double ny = double(LAT[i]);
                    const double jitter = double(JITTER[i]);
                    const PkWind2 w = pk_wind_belt_wind_at(ny, season_phase, jitter);
                    dir = pick_dir_from_wind(double(w.x), double(w.y));
                }
                if (dir < 0) continue;

                int probe = i;
                for (int step = 0; step < lookback; ++step) {
                    const int ni = NB[probe * 6 + dir];
                    if (ni < 0 || ni >= n_cells) { probe = -1; break; }
                    probe = ni;
                }
                if (probe < 0) continue;
                if (ELEV[probe] > ELEV[i] + threshold) {
                    M[i] = M[i] * factor;
                    ++touched;
                }
            }
            return {touched};
        };
        return prepared;
    }

    // ─── stage 2：seasonal_redecide_terrain ───────────────────────────────
    // SAME_SOURCE: map_generator.gd::_seasonal_redecide_terrain (line 2474).
    // 流程：非永久气候 / 非永久地标 → 用 temp_365d + base_moisture/water_balance_30d
    //       算慢时间尺度 biome 气候 → _decide_terrain → apply_terrain（写 terrain + 派生 landform）。
    //       瞬时 moisture 只供实时气候；vegetation/cover 由后续慢速演替阶段维护。
    if (stage == 2) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("lat_temp_rows") || !knobs.has("season_offset_rows") ||
            !knobs.has("row_indices")) {
            return fail("stage_2 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 0) return fail("stage_2 invalid dims");

        auto &lat_tab = arrays.latitude;
        auto &off_tab = arrays.season_offsets;
        auto &row_idx = arrays.rows;
        if (lat_tab.size() < height || off_tab.size() < height) return fail("stage_2 row tables size");
        if (row_idx.size() != n_cells) return fail("stage_2 row_indices size");

        const int sid_terrain   = component("cell_terrain");
        const int sid_base_t    = component("cell_base_terrain");
        const int sid_elev      = component("cell_elevation");
        const int sid_moist     = component("cell_moisture");
        const int sid_base_m    = component("cell_base_moisture");
        const int sid_wb30      = component("cell_water_balance_30d");
        const int sid_landform  = component("cell_landform");
        const int sid_vegetation= component("cell_vegetation");
        const int sid_cover     = component("cell_cover");
        const int sid_snow      = component("cell_snow_cover");
        const int sid_is_water  = component("cell_is_water");
        if (sid_terrain < 0 || sid_base_t < 0 || sid_elev < 0 || sid_moist < 0 ||
            sid_base_m < 0 || sid_wb30 < 0 ||
            sid_landform < 0 || sid_vegetation < 0 || sid_cover < 0 || sid_snow < 0 ||
            sid_is_water < 0) {
            return fail("stage_2 missing slot id");
        }
        Slot &s_t  = slot(sid_terrain);
        Slot &s_bt = slot(sid_base_t);
        Slot &s_e  = slot(sid_elev);
        Slot &s_m  = slot(sid_moist);
        Slot &s_bm = slot(sid_base_m);
        Slot &s_wb = slot(sid_wb30);
        Slot &s_lf = slot(sid_landform);
        Slot &s_vg = slot(sid_vegetation);
        Slot &s_cv = slot(sid_cover);
        Slot &s_sn = slot(sid_snow);
        Slot &s_iw = slot(sid_is_water);
        if (s_t.arr_u8.size() != n_cells || s_bt.arr_u8.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_bm.arr_f32.size() != n_cells || s_wb.arr_f32.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells || s_vg.arr_u8.size() != n_cells ||
            s_cv.arr_u8.size() != n_cells || s_sn.arr_f32.size() != n_cells ||
            s_iw.arr_u8.size() != n_cells) {
            return fail("stage_2 slot size mismatch");
        }

        uint8_t       * const __restrict TERR  = s_t.arr_u8.ptrw();
        const uint8_t * const __restrict BTERR = s_bt.arr_u8.ptr();
        const float   * const __restrict ELEV  = s_e.arr_f32.ptr();
        const float   * const __restrict MOIST = s_m.arr_f32.ptr();
        const float   * const __restrict BASE_MOIST = s_bm.arr_f32.ptr();
        const float   * const __restrict WB30 = s_wb.arr_f32.ptr();
        const int sid_temp_365d = component("cell_temp_365d");
        if (sid_temp_365d < 0 || slot(sid_temp_365d).arr_f32.size() != n_cells) {
            return fail("stage_2 temp_365d slot size mismatch");
        }
        const float * const __restrict TEMP365 = slot(sid_temp_365d).arr_f32.ptr();
        uint8_t       * const __restrict LF    = s_lf.arr_u8.ptrw();
        uint8_t       * const __restrict VG    = s_vg.arr_u8.ptrw();
        uint8_t       * const __restrict CV    = s_cv.arr_u8.ptrw();
        uint8_t       * const __restrict IW    = s_iw.arr_u8.ptrw();

        const float   * const __restrict SNOW  = s_sn.arr_f32.ptr();
        const float   * const __restrict LATT  = lat_tab.ptr();
        const float   * const __restrict OFFT  = off_tab.ptr();
        const int32_t * const __restrict ROWI  = row_idx.ptr();
        const float biome_wet_weight = std::max(0.0f, float(knobs.get("biome_water_balance_weight", 0.35)));
        const float biome_dry_penalty = std::max(0.0f, float(knobs.get("biome_drought_penalty", 0.25)));

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_landform, sid_is_water};
        (void)MOIST;
        (void)LATT;
        (void)OFFT;
        (void)ROWI;
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            const int max_row = height - 1;
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t cur = TERR[i];
                const uint8_t bt = BTERR[i];
                if (pk_is_water_terrain(cur)) {
                    if (!pk_is_water_terrain(bt)) {
                        TERR[i] = bt;
                        LF[i] = pk_derive_landform(bt, ELEV[i], sea_level);
                        IW[i] = pk_is_water_terrain(bt) ? uint8_t(1) : uint8_t(0);
                        ++touched;

                    }
                    continue;
                }
                uint8_t new_t;

                if (bt == 9) { // SNOW base = 永久 SNOW
                    new_t = bt;
                } else if (pk_is_permanent_landform(bt)) {
                    new_t = bt;
                } else {
                    int row = ROWI[i];
                    if (row < 0) row = 0;
                    else if (row > max_row) row = max_row;
                    const double e = double(ELEV[i]);
                    const double temp_year = pk_clamp01(double(TEMP365[i]));
                    const double biome_moisture = pk_clamp01(
                        double(BASE_MOIST[i])
                        + std::max(double(WB30[i]), 0.0) * double(biome_wet_weight)
                        + std::min(double(WB30[i]), 0.0) * double(biome_dry_penalty));
                    new_t = pk_decide_terrain(e, temp_year, biome_moisture,
                                              double(sea_level));
                    // 生成期已排干/回填的内陆低洼陆地仍保留原始 below-sea elevation；
                    // runtime 季节重判不得把非水地块重新判回 COAST/OCEAN。
                    if (pk_is_water_terrain(new_t) && !pk_is_water_terrain(cur)) {
                        new_t = !pk_is_water_terrain(bt) ? bt : cur;
                    }
                }
                if (new_t != cur) ++touched;

                TERR[i] = new_t;
                IW[i] = pk_is_water_terrain(new_t) ? uint8_t(1) : uint8_t(0);
                // apply_terrain multi-axis sync（与 hex_cell.gd::apply_terrain 一致：

                // terrain 写后，三轴派生由 _sync_axes 完成。这里用 stage 8 同款 derive 路径。）
                uint8_t lf_new = pk_derive_landform(new_t, ELEV[i], sea_level);
                // 结构性地貌保留（与 stage 8 sync_current_state 同口径）：生成期通过多格邻域
                // 起伏分析写入的 PEAK(8)/VOLCANO(12)/PLATEAU(13)/RIFT_VALLEY(14)/CANYON(15)
                // 无法由单格 pk_derive_landform 复现，季节重判必须保留，否则首个 refresh round
                // 就会把高原/高峰/裂谷/峡谷整片塌缩成朴素 MOUNTAIN/HILL（见 tile_data 实测）。
                const uint8_t prev_lf = LF[i];
                if (prev_lf == 8 || prev_lf == 12 || prev_lf == 13 || prev_lf == 14 || prev_lf == 15) {
                    lf_new = prev_lf;
                }
                LF[i] = lf_new;
                // vegetation 用当前 moisture + 季节温度（由当前 runtime temp 派生；这里
                // 用 lat_tab 行温度 + off 近似；与 GDScript _seasonal_redecide_terrain
                // 路径不调用 _sync_axes_for_cell（只 apply_terrain），但下游 stage 9
                // 会 sync）。为保持 bit-equal：仅写 terrain + landform，veg/cover 留给
                // stage 9 (sync_current_state) 统一处理。
                (void)VG; (void)CV; (void)SNOW;
            }
            return {touched};
        };
        return prepared;
    }

    // ─── stage 3：river_ecology ───────────────────────────────────────────

    // SAME_SOURCE: map_generator.gd::_apply_river_ecology (line 3190).
    // 流程：has_river && 非水 → moisture=max(moist, 0.66~0.72)；
    //       河流穿越沙漠/恶地/寒漠时转为 FLOODPLAIN / OASIS / STEPPE；
    //       低地河道优先形成 FLOODPLAIN，避免大河边继续保持荒漠群系。
    if (stage == 3) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices")) {
            return fail("stage_3 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_3 invalid dims");
        auto &row_idx = arrays.rows;
        if (row_idx.size() != n_cells) return fail("stage_3 row_indices size");

        const int sid_terrain  = component("cell_terrain");
        const int sid_moist    = component("cell_moisture");
        const int sid_elev     = component("cell_elevation");
        const int sid_river    = component("cell_has_river");
        const int sid_rflow    = component("cell_river_flow");
        const int sid_landform = component("cell_landform");
        if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 || sid_river < 0 || sid_rflow < 0 ||
            sid_landform < 0) {
            return fail("stage_3 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_m = slot(sid_moist);
        Slot &s_e = slot(sid_elev);
        Slot &s_r = slot(sid_river);
        Slot &s_rf= slot(sid_rflow);
        Slot &s_lf= slot(sid_landform);
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_r.arr_u8.size() != n_cells ||
            s_rf.arr_f32.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells) {
            return fail("stage_3 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        float         * const __restrict M    = s_m.arr_f32.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        const uint8_t * const __restrict RIV  = s_r.arr_u8.ptr();
        const float   * const __restrict RFLOW= s_rf.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_moist, sid_landform};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                if (RIV[i] == 0) continue;
                const uint8_t t = TERR[i];
                if (pk_is_water_terrain(t)) continue;
                int row = ROWI[i];
                if (row < 0) row = 0;
                else if (row > max_row) row = max_row;
                const double ny = double(row) * inv_max_row;
                const double temp = double(pk_compute_temperature(ny, double(ELEV[i]), double(sea_level)));
                const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);
                const double lh = (double(ELEV[i]) - double(sea_level)) * inv_above_sea;
                const bool strong_river = RFLOW[i] >= 0.55f;
                const bool lowland_river = lh <= 0.18 || (strong_river && lh <= 0.28);
                const float target_m = strong_river ? 0.72f : 0.66f;
                if (M[i] < target_m) { M[i] = target_m; ++touched; }
                if (t == 22 || t == 23 || t == 29) continue;

                uint8_t new_t = t;
                if (t == 7 || t == 24 || t == 25 || t == 26 || t == 30) {
                    if (lowland_river) new_t = 29;        // FLOODPLAIN
                    else if (strong_river && temp > 0.35) new_t = 23; // OASIS
                    else if (temp > 0.30) new_t = 14;     // STEPPE riparian buffer
                } else if (!pk_is_permanent_landform(t)) {
                    if (lowland_river && (t == 2 || t == 3 || t == 12 || t == 14 || t == 15)) {
                        new_t = 29; // FLOODPLAIN
                    } else if (t == 2) {
                        if (temp > 0.55) new_t = strong_river ? uint8_t(11) : uint8_t(4);
                        else if (temp > 0.30) new_t = strong_river ? uint8_t(29) : uint8_t(3);
                    }
                }
                if (new_t != t) {
                    TERR[i] = new_t;
                    LF[i] = pk_derive_landform_preserve(new_t, ELEV[i], sea_level, LF[i]);
                    ++touched;
                }
            }
            return {touched};
        };
        return prepared;
    }
