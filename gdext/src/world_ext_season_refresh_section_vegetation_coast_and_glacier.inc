    // ─── stage 4：vegetation_feedback ─────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_vegetation_feedback (line 3269).
    // 流程：1) 累加 donor 邻居 delta（陆地，elev_factor=clamp(1-elev*decay,0.1,1)）
    //       2) 应用 delta 到瞬时 moisture（限幅，供实时气候/vegetation）
    //       3) 重决策非永久 biome（不动 MOUNTAIN/SNOW/permanent_landform），
    //          仍使用 temp_365d + base_moisture/water_balance_30d，避免 donor 短期写入抖动 biome。
    if (stage == 4) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("lat_temp_rows") || !knobs.has("row_indices") ||
            !knobs.has("neighbor_indices") || !knobs.has("donor_table") ||
            !knobs.has("elev_decay")) {
            return fail("stage_4 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        const double elev_decay = double(knobs["elev_decay"]);
        if (n_cells <= 0 || height <= 0) return fail("stage_4 invalid dims");

        auto &lat_tab = arrays.latitude;
        auto &row_idx = arrays.rows;
        auto &nb_arr = arrays.neighbors;
        // donor_table[26]：每种 terrain 的 donor 强度（陆地非 donor=0）。
        auto &donor_tab = arrays.donors;
        if (lat_tab.size() < height) return fail("stage_4 lat_temp_rows size");
        if (row_idx.size() != n_cells) return fail("stage_4 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_4 neighbor_indices size");
        if (donor_tab.size() < 26) return fail("stage_4 donor_table size < 26");

        const int sid_terrain  = component("cell_terrain");
        const int sid_moist    = component("cell_moisture");
        const int sid_base_m   = component("cell_base_moisture");
        const int sid_wb30     = component("cell_water_balance_30d");
        const int sid_temp365  = component("cell_temp_365d");
        const int sid_elev     = component("cell_elevation");
        const int sid_landform = component("cell_landform");
        if (sid_terrain < 0 || sid_moist < 0 || sid_base_m < 0 || sid_wb30 < 0 ||
            sid_temp365 < 0 || sid_elev < 0 || sid_landform < 0) {
            return fail("stage_4 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_m = slot(sid_moist);
        Slot &s_bm = slot(sid_base_m);
        Slot &s_wb = slot(sid_wb30);
        Slot &s_t365 = slot(sid_temp365);
        Slot &s_e = slot(sid_elev);
        Slot &s_lf= slot(sid_landform);
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_bm.arr_f32.size() != n_cells || s_wb.arr_f32.size() != n_cells ||
            s_t365.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_lf.arr_u8.size() != n_cells) {
            return fail("stage_4 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        float         * const __restrict M    = s_m.arr_f32.ptrw();
        const float   * const __restrict BASE_MOIST = s_bm.arr_f32.ptr();
        const float   * const __restrict WB30 = s_wb.arr_f32.ptr();
        const float   * const __restrict TEMP365 = s_t365.arr_f32.ptr();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const float   * const __restrict DTAB = donor_tab.ptr();
        const float biome_wet_weight = std::max(0.0f, float(knobs.get("biome_water_balance_weight", 0.35)));
        const float biome_dry_penalty = std::max(0.0f, float(knobs.get("biome_drought_penalty", 0.25)));

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_moist, sid_landform};
        prepared.compute = [=]() -> SeasonStageCounts {
            // pass 1：累加 delta（per-target sum）
            std::vector<float> deltas(size_t(n_cells), 0.0f);
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t t = TERR[i];
                const float donor = (t < 26) ? DTAB[t] : 0.0f;
                if (donor == 0.0f) continue;
                double elev_factor = 1.0 - double(ELEV[i]) * elev_decay;
                if (elev_factor < 0.1) elev_factor = 0.1;
                else if (elev_factor > 1.0) elev_factor = 1.0;
                const float donor_eff = float(double(donor) * elev_factor);
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[i * 6 + d];
                    if (ni < 0 || ni >= n_cells) continue;
                    if (pk_is_water_terrain(TERR[ni])) continue;
                    deltas[size_t(ni)] += donor_eff;
                }
            }
            // pass 2：应用 delta（陆地 only，限幅）
            for (int i = 0; i < n_cells; ++i) {
                if (pk_is_water_terrain(TERR[i])) continue;
                const float d = deltas[size_t(i)];
                if (d == 0.0f) continue;
                double m = double(M[i]) + double(d);
                if (m < 0.0) m = 0.0;
                else if (m > 1.0) m = 1.0;
                M[i] = float(m);
            }
            // pass 3：redecide（慢气候输入；不动 MOUNTAIN/SNOW/permanent_landform）
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t cur = TERR[i];
                if (pk_is_water_terrain(cur)) continue;
                if (cur == 6 || cur == 9) continue;            // MOUNTAIN/SNOW
                if (pk_is_permanent_landform(cur)) continue;
                const double e = double(ELEV[i]);
                const double temp = pk_clamp01(double(TEMP365[i]));
                const double biome_moisture = pk_clamp01(
                    double(BASE_MOIST[i])
                    + std::max(double(WB30[i]), 0.0) * double(biome_wet_weight)
                    + std::min(double(WB30[i]), 0.0) * double(biome_dry_penalty));
                uint8_t new_t = pk_decide_terrain(e, temp, biome_moisture,
                                                  double(sea_level));
                if (pk_is_water_terrain(new_t) && !pk_is_water_terrain(cur)) {
                    new_t = cur;
                }
                if (new_t != cur) {
                    TERR[i] = new_t;

                    LF[i] = pk_derive_landform_preserve(new_t, ELEV[i], sea_level, LF[i]);
                    ++touched;
                }
            }
            return {touched};
        };
        return prepared;
    }

    // ─── stage 5：shrubland_pass ──────────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_shrubland_pass (line 3374).
    // 触发：陆地 + (GRASSLAND/STEPPE/SAVANNA/PLAIN) + !permanent_landform
    //   + land_h<=0.30 + temp>=0.50 + moisture∈[0.25, 0.40]
    //   + 至少 1 个 OCEAN/COAST 邻居 → SHRUBLAND(15)
    if (stage == 5) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices") || !knobs.has("neighbor_indices")) {
            return fail("stage_5 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_5 invalid dims");
        auto &row_idx = arrays.rows;
        auto &nb_arr = arrays.neighbors;
        if (row_idx.size() != n_cells) return fail("stage_5 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_5 neighbor_indices size");

        const int sid_terrain  = component("cell_terrain");
        const int sid_moist    = component("cell_moisture");
        const int sid_elev     = component("cell_elevation");
        const int sid_landform = component("cell_landform");
        if (sid_terrain < 0 || sid_moist < 0 || sid_elev < 0 || sid_landform < 0) {
            return fail("stage_5 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_m = slot(sid_moist);
        Slot &s_e = slot(sid_elev);
        Slot &s_lf= slot(sid_landform);
        if (s_t.arr_u8.size() != n_cells || s_m.arr_f32.size() != n_cells ||
            s_e.arr_f32.size() != n_cells || s_lf.arr_u8.size() != n_cells) {
            return fail("stage_5 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        const float   * const __restrict M    = s_m.arr_f32.ptr();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);
        const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_landform};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t t = TERR[i];
                if (pk_is_water_terrain(t)) continue;
                // 仅替换 GRASSLAND(3) / STEPPE(14) / SAVANNA(12) / PLAIN(2)
                if (t != 3 && t != 14 && t != 12 && t != 2) continue;
                if (pk_is_permanent_landform(t)) continue;
                const double e = double(ELEV[i]);
                const double land_h = (e - double(sea_level)) * inv_above_sea;
                if (land_h > 0.45) continue;
                int row = ROWI[i];
                if (row < 0) row = 0;
                else if (row > max_row) row = max_row;
                const double ny = double(row) * inv_max_row;
                const double temp = double(pk_compute_temperature(ny, e, double(sea_level)));
                // [climate-zone-fix P1] 与生成期 shrubland pass 同步：限真·暖温带地中海生态位
                // （temp 上限 0.58 排除热带/亚热带；湿度上沿收窄至 0.44）。
                if (temp < 0.42 || temp > 0.58) continue;
                const float mv = M[i];
                if (mv < 0.20f || mv > 0.44f) continue;
                bool has_sea = false;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[i * 6 + d];
                    if (ni < 0 || ni >= n_cells) continue;
                    const uint8_t nt = TERR[ni];
                    if (nt == 0 || nt == 1) { has_sea = true; break; }
                }
                if (!has_sea) continue;
                TERR[i] = 15; // SHRUBLAND
                LF[i] = pk_derive_landform_preserve(15, ELEV[i], sea_level, LF[i]);
                ++touched;
            }
            return {touched};
        };
        return prepared;
    }

    // ─── stage 6：mangrove_pass ───────────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_mangrove_pass (line 3413).
    // 触发：陆地 + !MOUNTAIN/SNOW/TUNDRA/SWAMP + !permanent_landform
    //   + land_h<=0.05 + temp>=0.65 + 紧邻 COAST + (has_river 或 SWAMP 邻接)
    //   → MANGROVE(16)
    if (stage == 6) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices") || !knobs.has("neighbor_indices")) {
            return fail("stage_6 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_6 invalid dims");
        auto &row_idx = arrays.rows;
        auto &nb_arr = arrays.neighbors;
        if (row_idx.size() != n_cells) return fail("stage_6 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_6 neighbor_indices size");

        const int sid_terrain  = component("cell_terrain");
        const int sid_elev     = component("cell_elevation");
        const int sid_moist    = component("cell_moisture");
        const int sid_river    = component("cell_has_river");
        const int sid_landform = component("cell_landform");
        if (sid_terrain < 0 || sid_elev < 0 || sid_moist < 0 || sid_river < 0 || sid_landform < 0) {
            return fail("stage_6 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_e = slot(sid_elev);
        Slot &s_m = slot(sid_moist);
        Slot &s_r = slot(sid_river);
        Slot &s_lf= slot(sid_landform);
        if (s_t.arr_u8.size() != n_cells || s_e.arr_f32.size() != n_cells ||
            s_m.arr_f32.size() != n_cells || s_r.arr_u8.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells) {
            return fail("stage_6 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        const float   * const __restrict M    = s_m.arr_f32.ptr();
        const uint8_t * const __restrict RIV  = s_r.arr_u8.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);
        const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_landform};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t t = TERR[i];
                if (pk_is_water_terrain(t)) continue;
                if (t == 6 || t == 9 || t == 8 || t == 10) continue; // MOUNTAIN/SNOW/TUNDRA/SWAMP
                if (pk_is_permanent_landform(t)) continue;
                const double e = double(ELEV[i]);
                const double land_h = (e - double(sea_level)) * inv_above_sea;
                if (land_h > 0.08) continue;
                int row = ROWI[i];
                if (row < 0) row = 0;
                else if (row > max_row) row = max_row;
                const double ny = double(row) * inv_max_row;
                const double temp = double(pk_compute_temperature(ny, e, double(sea_level)));
                if (temp < 0.60) continue;
                bool coast_nb = false;
                bool swamp_nb = false;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[i * 6 + d];
                    if (ni < 0 || ni >= n_cells) continue;
                    const uint8_t nt = TERR[ni];
                    if (nt == 1) coast_nb = true;
                    else if (nt == 10) swamp_nb = true;
                }
                if (!coast_nb) continue;
                if (!(RIV[i] || swamp_nb || M[i] >= 0.70f)) continue;
                TERR[i] = 16; // MANGROVE
                LF[i] = pk_derive_landform_preserve(16, ELEV[i], sea_level, LF[i]);
                ++touched;
            }
            return {touched};
        };
        return prepared;
    }

    // ─── stage 7：glacier_pass ────────────────────────────────────────────
    // SAME_SOURCE: map_generator.gd::_apply_glacier_pass (line 3699).
    // 触发：(SNOW/TUNDRA) + temp<0.05 + (沿海冰舌 land_h<0.20 && OCEAN/COAST/SEA_ICE 邻居
    //                                  || alpine land_h>0.65)
    //       → GLACIER(17)
    if (stage == 7) {
        if (!knobs.has("n_cells") || !knobs.has("height") || !knobs.has("sea_level") ||
            !knobs.has("row_indices") || !knobs.has("neighbor_indices")) {
            return fail("stage_7 missing required knob");
        }
        const int n_cells = int(knobs["n_cells"]);
        const int height = int(knobs["height"]);
        const float sea_level = float(knobs["sea_level"]);
        if (n_cells <= 0 || height <= 1) return fail("stage_7 invalid dims");
        auto &row_idx = arrays.rows;
        auto &nb_arr = arrays.neighbors;
        if (row_idx.size() != n_cells) return fail("stage_7 row_indices size");
        if (nb_arr.size() < n_cells * 6) return fail("stage_7 neighbor_indices size");

        const int sid_terrain  = component("cell_terrain");
        const int sid_elev     = component("cell_elevation");
        const int sid_landform = component("cell_landform");
        if (sid_terrain < 0 || sid_elev < 0 || sid_landform < 0) {
            return fail("stage_7 missing slot id");
        }
        Slot &s_t = slot(sid_terrain);
        Slot &s_e = slot(sid_elev);
        Slot &s_lf= slot(sid_landform);
        if (s_t.arr_u8.size() != n_cells || s_e.arr_f32.size() != n_cells ||
            s_lf.arr_u8.size() != n_cells) {
            return fail("stage_7 slot size mismatch");
        }

        uint8_t       * const __restrict TERR = s_t.arr_u8.ptrw();
        const float   * const __restrict ELEV = s_e.arr_f32.ptr();
        uint8_t       * const __restrict LF   = s_lf.arr_u8.ptrw();
        const int32_t * const __restrict NB   = nb_arr.ptr();
        const int32_t * const __restrict ROWI = row_idx.ptr();
        const int max_row = height - 1;
        const double inv_max_row = 1.0 / double(max_row > 0 ? max_row : 1);
        const double inv_above_sea = 1.0 / std::max(1.0 - double(sea_level), 0.001);

        PreparedSeasonStage prepared;
        prepared.slots = {sid_terrain, sid_landform};
        prepared.compute = [=]() -> SeasonStageCounts {
            int touched = 0;
            for (int i = 0; i < n_cells; ++i) {
                const uint8_t t = TERR[i];
                if (pk_is_water_terrain(t)) continue;
                if (t != 9 && t != 8) continue; // 仅 SNOW / TUNDRA
                const double e = double(ELEV[i]);
                const double land_h = (e - double(sea_level)) * inv_above_sea;
                int row = ROWI[i];
                if (row < 0) row = 0;
                else if (row > max_row) row = max_row;
                const double ny = double(row) * inv_max_row;
                const double temp = double(pk_compute_temperature(ny, e, double(sea_level)));
                if (temp >= 0.05) continue;
                bool coastal_glacier = false;
                if (land_h < 0.20) {
                    for (int d = 0; d < 6; ++d) {
                        const int ni = NB[i * 6 + d];
                        if (ni < 0 || ni >= n_cells) continue;
                        const uint8_t nt = TERR[ni];
                        if (nt == 0 || nt == 1 || nt == 20) {
                            coastal_glacier = true;
                            break;
                        }
                    }
                }
                const bool alpine_glacier = land_h > 0.65;
                if (!(coastal_glacier || alpine_glacier)) continue;
                TERR[i] = 17; // GLACIER
                LF[i] = pk_derive_landform_preserve(17, ELEV[i], sea_level, LF[i]);
                ++touched;
            }
            return {touched};
        };
        return prepared;
    }
