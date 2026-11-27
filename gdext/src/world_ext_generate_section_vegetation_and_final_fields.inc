    const PackedFloat32Array ideal_t_arr = profile.get("veg_ideal_temp", PackedFloat32Array());
    const PackedFloat32Array ideal_m_arr = profile.get("veg_ideal_moist", PackedFloat32Array());
    const PackedFloat32Array tol_t_arr = profile.get("veg_temp_tol", PackedFloat32Array());
    const PackedFloat32Array tol_m_arr = profile.get("veg_moist_tol", PackedFloat32Array());
    const bool have_veg_profiles = ideal_t_arr.size() >= 28 && ideal_m_arr.size() >= 28 &&
                                   tol_t_arr.size() >= 28 && tol_m_arr.size() >= 28;
    const float min_suitability = float(std::clamp(getd(profile, "vegetation_min_suitability", 0.18), 0.0, 1.0));
    const float tie_epsilon = float(std::max(0.0, getd(profile, "vegetation_tie_epsilon", 1e-6)));
    const float water_balance_weight = float(std::max(0.01, getd(profile, "plant_water_balance_weight", 0.35)));
    const float soil_buffer_weight = float(std::max(0.01, getd(profile, "plant_soil_buffer_weight", 0.30)));
    const float drought_penalty = float(std::max(0.01, getd(profile, "plant_drought_penalty", 0.25)));
    int vegetation_candidate_count = 0;
    int vegetation_none_count = 0;
    int vegetation_biome_reconciled_count = 0;
    int plant_water_nonzero_land_count = 0;
    int river_adjacent_desert_count = 0;
    int coastal_highland_desert_count = 0;
    double vegetation_score_sum = 0.0;
    float vegetation_score_min = 1.0f;
    float vegetation_score_max = 0.0f;
    float terrain_soft_weight_min = 1.25f;
    float terrain_soft_weight_max = 0.35f;
    const auto vegetation_t0 = std::chrono::high_resolution_clock::now();

    for (int i = 0; i < n; ++i) {
        const double temp_gen = gen_temp(i);
        TEMP[i] = float(temp_gen); // The same coastal-adjusted source used by terrain.
        T30[i] = TEMP[i];
        T365[i] = TEMP[i];
        const float delta = std::clamp(M[i] - BM[i], -0.5f, 0.5f);
        float wb30 = 0.0f;
        float soil = 0.0f;
        if (delta >= 0.0f) {
            wb30 = std::clamp(delta * 0.60f / water_balance_weight, 0.0f, 0.5f);
            soil = std::clamp(delta * 0.40f / soil_buffer_weight, 0.0f, 0.5f);
        } else {
            wb30 = std::clamp(delta / drought_penalty, -0.5f, 0.0f);
        }
        const float plant_water = std::clamp(
            BM[i] + std::max(wb30, 0.0f) * water_balance_weight +
            std::max(soil, 0.0f) * soil_buffer_weight +
            std::min(wb30, 0.0f) * drought_penalty, 0.0f, 1.0f);
        WB30[i] = wb30;
        SOIL[i] = soil;
        PLANT_WATER[i] = plant_water;
        if (IW[i] == 0 && plant_water > 0.01f) ++plant_water_nonzero_land_count;

        uint8_t selected = 0;
        float best_score = 0.0f;
        float current_score = 0.0f;
        if (IW[i] != 0) {
            // Water vegetation is a physical substrate constraint.
            if (TERR[i] == 1 && temp_gen > 0.42 && temp_gen < 0.74) selected = 26; // seagrass
            else if (TERR[i] == 19) selected = 23; // coral reef
            else if (TERR[i] == 21) selected = 22; // kelp forest
        } else if (TERR[i] != 17 && TERR[i] != 24 && have_veg_profiles) {
            for (uint8_t v = 1; v < 28; ++v) {
                if (!pk_vegetation_candidate_allowed(TERR[i], v)) continue;
                const float climate = pk_vegetation_climate_score_for_type(
                    v, TEMP[i], plant_water, ideal_t_arr[v], ideal_m_arr[v], tol_t_arr[v], tol_m_arr[v]);
                const float terrain_weight = pk_vegetation_terrain_weight(TERR[i], LF[i], v, plant_water);
                terrain_soft_weight_min = std::min(terrain_soft_weight_min, terrain_weight);
                terrain_soft_weight_max = std::max(terrain_soft_weight_max, terrain_weight);
                const float score = climate * terrain_weight;
                if (score > best_score + tie_epsilon) {
                    best_score = score;
                    selected = v;
                }
            }
            if (best_score < min_suitability) selected = 0;
            ++vegetation_candidate_count;
        } else if (IW[i] == 0) {
            selected = pk_derive_vegetation(TERR[i], LF[i], TEMP[i], M[i]);
            best_score = selected == 0 ? 0.0f : 0.5f;
        }

        // Keep ecological lag for compatible transitions, but repair an
        // obviously cross-biome winner before publishing the initial state.
        if (selected != 0 && pk_vegetation_needs_biome_reconcile(TERR[i], selected)) {
            const uint8_t repaired = pk_derive_vegetation(TERR[i], LF[i], TEMP[i], M[i]);
            if (repaired != selected) {
                selected = repaired;
                ++vegetation_biome_reconciled_count;
            }
        }

        if (have_veg_profiles && selected > 0 && selected < 28) {
            best_score = pk_vegetation_climate_score_for_type(
                selected, TEMP[i], plant_water, ideal_t_arr[selected], ideal_m_arr[selected],
                tol_t_arr[selected], tol_m_arr[selected]) *
                pk_vegetation_terrain_weight(TERR[i], LF[i], selected, plant_water);
            const uint8_t previous = BVEG[i];
            if (previous > 0 && previous < 28 && previous != 22 && previous != 23 && previous != 26) {
                current_score = pk_vegetation_climate_score_for_type(
                    previous, TEMP[i], plant_water, ideal_t_arr[previous], ideal_m_arr[previous],
                    tol_t_arr[previous], tol_m_arr[previous]) *
                    pk_vegetation_terrain_weight(TERR[i], LF[i], previous, plant_water);
            }
        }
        VEG[i] = selected;
        BVEG[i] = selected;
        if (selected == 0) ++vegetation_none_count;

        if (selected > 0) {
            const float vitality = std::clamp(0.15f + 0.85f * best_score, 0.0f, 1.0f);
            VITALITY[i] = vitality;
            VREGEN[i] = std::clamp(best_score, 0.0f, 1.0f);
            VG_PRESSURE[i] = std::clamp(best_score - current_score, 0.0f, 1.0f);
            if (have_veg_profiles && selected < 28) {
                const float tt = std::max(tol_t_arr[selected], 0.05f);
                const float tm = std::max(tol_m_arr[selected], 0.05f);
                VHEAT[i] = std::clamp((TEMP[i] - ideal_t_arr[selected] - tt) / tt, 0.0f, 1.0f);
                VCOLD[i] = std::clamp((ideal_t_arr[selected] - tt - TEMP[i]) / tt, 0.0f, 1.0f);
                VDROUGHT[i] = std::clamp((ideal_m_arr[selected] - tm - plant_water) / tm, 0.0f, 1.0f);
            } else {
                VHEAT[i] = 0.0f;
                VCOLD[i] = 0.0f;
                VDROUGHT[i] = 0.0f;
            }
            vegetation_score_sum += best_score;
            vegetation_score_min = std::min(vegetation_score_min, best_score);
            vegetation_score_max = std::max(vegetation_score_max, best_score);
        } else {
            VITALITY[i] = 0.0f;
            VG_PRESSURE[i] = 0.0f;
            VHEAT[i] = 0.0f;
            VDROUGHT[i] = 0.0f;
            VCOLD[i] = 0.0f;
            VREGEN[i] = 0.0f;
        }
        if (selected == 17 && (RIV[i] != 0 || [&]() {
                for (int d = 0; d < 6; ++d) { const int ni = NB[size_t(i) * 6 + d]; if (ni >= 0 && RIV[ni] != 0) return true; }
                return false;
            }())) {
            ++river_adjacent_desert_count;
        }
        if ((LF[i] == 6 || LF[i] == 7 || LF[i] == 8 || LF[i] == 13) &&
            !dist_ocean.empty() && dist_ocean[size_t(i)] >= 0 && dist_ocean[size_t(i)] <= 2 &&
            (selected == 16 || selected == 17)) {
            ++coastal_highland_desert_count;
        }
    }
    const auto vegetation_t1 = std::chrono::high_resolution_clock::now();
    const double vegetation_native_ms =
        std::chrono::duration<double, std::milli>(vegetation_t1 - vegetation_t0).count();

    int water_count = 0;
    int volcano_count = 0;
    int desert_class_count = 0;
    int cold_desert_count = 0;
    int plateau_count = 0;
    int peak_count = 0;
    int rift_count = 0;
    int highland_river_count = 0;
    int mountain_peak_river_count = 0;
    int xeric_desert_count = 0;
    int shrubland_count = 0;
    int mangrove_count = 0;
    int moor_count = 0;
    for (int i = 0; i < n; ++i) {
        if (IW[i]) ++water_count;
        if (VOLC[i]) ++volcano_count;
        if (TERR[i] == 7 || TERR[i] == 24 || TERR[i] == 25 || TERR[i] == 30 || TERR[i] == 26) ++desert_class_count;
        if (TERR[i] == 26) ++cold_desert_count;
        if (LF[i] == 13) ++plateau_count;
        if (LF[i] == 8) ++peak_count;
        if (LF[i] == 14) ++rift_count;
        if (RIV[i] != 0 && (LF[i] == 6 || LF[i] == 7 || LF[i] == 8 || LF[i] == 13)) ++highland_river_count;
        if (RIV[i] != 0 && (LF[i] == 7 || LF[i] == 8)) ++mountain_peak_river_count;
        if (VEG[i] == 17) ++xeric_desert_count;
        if (TERR[i] == 15) ++shrubland_count;
        if (TERR[i] == 16) ++mangrove_count;
        if (TERR[i] == 28) ++moor_count;
    }

    const auto t1 = std::chrono::high_resolution_clock::now();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    out["rc"] = 0;
    out["status"] = String("completed");
    out["path"] = String("gdext");
    out["fallback"] = false;
    out["fallback_reason"] = String();
    out["reason"] = String();
    out["fail_stage"] = String();
    out["published_to_slot"] = false;
    out["n_cells"] = n;
    out["width"] = width;
    out["height"] = height;
    out["seed"] = seed;
    out["water_count"] = water_count;
    out["land_count"] = n - water_count;
    out["lake_count"] = lake_count;
    out["river_count"] = river_count;
    out["volcano_count"] = volcano_count;
    out["elapsed_ms"] = elapsed_ms;
    out["native_ms"] = elapsed_ms;
    out["compute_ms"] = elapsed_ms;
    out["generation_progress"] = 1.0;

    // ── QA 度量（生成诊断，无行为副作用，t1 之后计算不计入 native_ms）──
    // 连通分量分析最终水体 → 抓单格海洋；陆地低于海平面比例；biome 香农熵；河流占比。
    // 作为每阶段改造的回归基线（GDScript 端会 print 出来）。
    Dictionary qa_metrics;
    {
        std::vector<uint8_t> seen_qa(size_t(n), 0);
        std::vector<int> stack_qa;
        stack_qa.reserve(256);
        int single_water = 0;   // size == 1
        int tiny_water = 0;     // size <= 3
        int small_water = 0;    // size <= 5
        int water_bodies = 0;
        int largest_water = 0;
        for (int i = 0; i < n; ++i) {
            if (IW[i] == 0 || seen_qa[size_t(i)]) continue;
            stack_qa.clear();
            stack_qa.push_back(i);
            seen_qa[size_t(i)] = 1;
            int sz = 0;
            while (!stack_qa.empty()) {
                const int cur = stack_qa.back();
                stack_qa.pop_back();
                ++sz;
                for (int d = 0; d < 6; ++d) {
                    const int ni = NB[size_t(cur) * 6 + d];
                    if (ni >= 0 && IW[ni] != 0 && !seen_qa[size_t(ni)]) {
                        seen_qa[size_t(ni)] = 1;
                        stack_qa.push_back(ni);
                    }
                }
            }
            ++water_bodies;
            if (sz == 1) ++single_water;
            if (sz <= 3) ++tiny_water;
            if (sz <= 5) ++small_water;
            if (sz > largest_water) largest_water = sz;
        }
        int land_below_sea = 0;
        int terr_hist[64] = {0};
        for (int i = 0; i < n; ++i) {
            if (IW[i] == 0 && double(E[i]) < sea_level) ++land_below_sea;
            const uint8_t t = TERR[i];
            if (t < 64) ++terr_hist[t];
        }
        double entropy = 0.0;
        int distinct_terr = 0;
        for (int t = 0; t < 64; ++t) {
            if (terr_hist[t] <= 0) continue;
            ++distinct_terr;
            const double p = double(terr_hist[t]) / double(n);
            entropy -= p * simulation_math::log2(p);
        }
        const int land_count_qa = n - water_count;
        qa_metrics["water_bodies"] = water_bodies;
        qa_metrics["single_tile_water"] = single_water;
        qa_metrics["tiny_water_le3"] = tiny_water;
        qa_metrics["small_water_le5"] = small_water;
        qa_metrics["largest_water_body"] = largest_water;
        qa_metrics["land_below_sealevel"] = land_below_sea;
        qa_metrics["land_below_sealevel_ratio"] = (land_count_qa > 0) ? double(land_below_sea) / double(land_count_qa) : 0.0;
        qa_metrics["terrain_entropy_bits"] = entropy;
        qa_metrics["terrain_distinct"] = distinct_terr;
        qa_metrics["river_ratio"] = (n > 0) ? double(river_count) / double(n) : 0.0;
        qa_metrics["badlands_land_ratio"] = (land_count_qa > 0)
                ? double(badlands_touched) / double(land_count_qa) : 0.0;
        qa_metrics["badlands_arid_ratio"] = (arid_source_count > 0)
                ? double(badlands_touched) / double(arid_source_count) : 0.0;
        qa_metrics["badlands_largest_component"] = badlands_largest_component;
    }
    out["qa_metrics"] = qa_metrics;

    Dictionary stage_counts;
    stage_counts["rain_shadow"] = rain_shadow_touched;
    stage_counts["redecide"] = redecide_touched;
    stage_counts["final_climate_redecide"] = final_climate_redecide_touched;
    stage_counts["headwater_river"] = headwater_touched;
    stage_counts["river_lake_snap"] = river_lake_snap_touched;
    stage_counts["river_confluence_snap"] = river_confluence_snap_touched;
    stage_counts["coast_wave_erosion"] = coast_erosion_touched;
    stage_counts["river_ecology"] = river_ecology_touched;
    stage_counts["river_desert_repaired"] = river_desert_repaired;
    stage_counts["river_floodplain_channel"] = river_floodplain_channel_touched;
    stage_counts["vegetation_feedback"] = vegetation_feedback_touched;
    stage_counts["shrubland"] = shrubland_touched;
    stage_counts["mangrove"] = mangrove_touched;
    stage_counts["glacier"] = glacier_touched;
    stage_counts["swamp"] = swamp_touched;
    stage_counts["delta"] = delta_touched;
    stage_counts["oasis"] = oasis_touched;
    stage_counts["salt_flat"] = salt_flat_touched;
    stage_counts["badlands"] = badlands_touched;
    stage_counts["badlands_candidates"] = badlands_candidate_count;
    stage_counts["badlands_budget_rejected"] = badlands_budget_rejected;
    stage_counts["mesa"] = mesa_touched;
    stage_counts["floodplain"] = floodplain_touched;
    stage_counts["moor"] = moor_touched;
    stage_counts["chaparral"] = chaparral_touched;
    stage_counts["plateau"] = plateau_touched;
    stage_counts["plateau_candidates"] = plateau_candidate_count;
    stage_counts["plateau_demoted_to_hill"] = plateau_demoted_to_hill;
    stage_counts["mountain_demoted"] = mountain_demoted;
    stage_counts["mountain_to_plateau"] = mountain_to_plateau;
    stage_counts["mountain_height_candidates"] = mountain_height_candidates;
    stage_counts["mountain_relief_candidates"] = mountain_relief_candidates;
    stage_counts["mountain_kept"] = mountain_kept;
    stage_counts["peak_summit"] = peak_touched;
    stage_counts["peak_candidates"] = int(peak_candidates.size());
    stage_counts["peak_demoted"] = peak_demoted;
    stage_counts["rift_valley"] = rift_touched;
    stage_counts["canyon"] = canyon_touched;
    stage_counts["reef"] = reef_touched;
    stage_counts["kelp"] = kelp_touched;
    stage_counts["pelagic_bloom"] = pelagic_touched;
    stage_counts["isolated_water_drained"] = isolated_water_drained;
    stage_counts["isolated_water_to_lake"] = isolated_water_to_lake;
    out["stage_counts"] = stage_counts;


    out["river_map_reference_cells"] = river_map_reference_cells;
    out["river_map_scale"] = river_map_scale;
    out["river_map_scale_exponent"] = river_map_scale_exponent;
    // [scale-fix 2026-07-30] 分辨率归一诊断：验证时核对 s / relief 阈值缩放 / 等效流量系数
    out["gen_dist_scale"] = gen_dist_scale;
    out["relief_thresh_scale"] = relief_thresh_scale;
    out["relief_thresh_scale_exp"] = relief_thresh_scale_exp;
    out["mountain_min_relief_effective"] = mountain_min_relief;
    out["plateau_max_relief_effective"] = plateau_max_relief;
    out["geomorph_relief_radius"] = relief_radius;
    out["geomorph_relief_radius_norm"] = relief_radius_norm;
    out["badlands_min_relief_effective"] = badlands_min_relief;
    out["flow_eq_scale"] = flow_eq_scale;
    out["rain_shadow_lookback_effective"] = lookback;
    out["river_channel_init_base"] = river_channel_init_base;
    out["river_channel_init_effective"] = channel_init;
    out["river_headwater_init_base"] = river_headwater_init_base;
    out["river_headwater_init_effective"] = river_headwater_init;
    out["hydro_river_min_length_base"] = hydro_river_min_length_base;
    out["hydro_river_min_length_effective"] = hydro_river_min_length;
    out["river_flow_threshold"] = double(river_threshold);
    out["river_ecology_source_count"] = water_src_river;
    out["lakeshore_moist_touched"] = lakeshore_moist_touched;
    out["riparian_moist_touched"] = riparian_moist_touched;
    out["final_climate_redecide_evaluated"] = final_climate_redecide_evaluated;
    out["final_climate_redecide_touched"] = final_climate_redecide_touched;
    out["river_lake_snap_count"] = river_lake_snap_touched;
    out["river_confluence_snap_count"] = river_confluence_snap_touched;
    out["desert_class_count"] = desert_class_count;
    out["rift_candidate_count"] = rift_candidate_count;
    out["mountain_height_candidates"] = mountain_height_candidates;
    out["mountain_relief_candidates"] = mountain_relief_candidates;
    out["mountain_kept"] = mountain_kept;
    out["peak_candidate_count"] = int(peak_candidates.size());
    out["plateau_candidate_count"] = plateau_candidate_count;
    out["rift_component_count"] = rift_component_count;
    out["rift_rejected_fragment_count"] = rift_rejected_fragment_count;
    out["rift_largest_component"] = rift_largest_component;
    out["rift_min_length_effective"] = rift_min_length;
    out["badlands_arid_source_count"] = arid_source_count;
    out["badlands_candidate_count"] = badlands_candidate_count;
    out["badlands_candidate_components"] = badlands_candidate_components;
    out["badlands_selected_count"] = badlands_touched;
    out["badlands_budget"] = badlands_budget;
    out["badlands_budget_rejected"] = badlands_budget_rejected;
    out["badlands_largest_component"] = badlands_largest_component;
    out["cold_desert_count"] = cold_desert_count;
    out["plateau_count"] = plateau_count;
    out["peak_count"] = peak_count;
    out["rift_valley_count"] = rift_count;
    out["highland_river_count"] = highland_river_count;
    out["mountain_peak_river_count"] = mountain_peak_river_count;
    out["xeric_desert_count"] = xeric_desert_count;
    out["shrubland_count"] = shrubland_count;
    out["mangrove_count"] = mangrove_count;
    out["moor_count"] = moor_count;
    out["vegetation_candidate_count"] = vegetation_candidate_count;
    out["vegetation_biome_reconciled_count"] = vegetation_biome_reconciled_count;
    out["vegetation_native_ms"] = vegetation_native_ms;
    out["vegetation_none_count"] = vegetation_none_count;
    out["vegetation_score_min"] = vegetation_candidate_count > vegetation_none_count ? vegetation_score_min : 0.0f;
    out["vegetation_score_mean"] = vegetation_candidate_count > 0
        ? float(vegetation_score_sum / double(std::max(1, vegetation_candidate_count))) : 0.0f;
    out["vegetation_score_max"] = vegetation_score_max;
    out["plant_water_nonzero_land_count"] = plant_water_nonzero_land_count;
    out["river_adjacent_desert_count"] = river_adjacent_desert_count;
    out["coastal_highland_desert_count"] = coastal_highland_desert_count;
    out["terrain_soft_weight_min"] = vegetation_candidate_count > 0 ? terrain_soft_weight_min : 0.0f;
    out["terrain_soft_weight_max"] = vegetation_candidate_count > 0 ? terrain_soft_weight_max : 0.0f;

    out["q_arr"] = q_arr;
    out["r_arr"] = r_arr;
    out["s_arr"] = s_arr;
    out["elevation_arr"] = elevation_arr;
    out["moisture_arr"] = moisture_arr;
    out["base_moisture_arr"] = base_moisture_arr;
    out["temp_arr"] = temp_arr;
    out["temp_baseline_arr"] = temp_baseline_arr;
    out["temp_30d_arr"] = temp_30d_arr;
    out["temp_365d_arr"] = temp_365d_arr;
    out["temp_anomaly_arr"] = temp_anomaly_arr;
    out["thermal_energy_arr"] = thermal_energy_arr;
    out["cell_lat_norm_arr"] = cell_lat_norm_arr;
    out["temp_baseline_year_arr"] = temp_baseline_year_arr;
    out["snow_cover_arr"] = snow_cover_arr;
    // 透传 base pass 生成的湖泊种子标记（仅 UI 信息面板用，post_base 不改写）。
    out["is_lake_seed_arr"] = input.get("is_lake_seed_arr", PackedByteArray());
    out["terrain_arr"] = terrain_arr;
    out["base_terrain_arr"] = base_terrain_arr;
    out["landform_arr"] = landform_arr;
    out["base_landform_arr"] = base_landform_arr;
    out["vegetation_arr"] = vegetation_arr;
    out["base_vegetation_arr"] = base_vegetation_arr;
    out["vegetation_vitality_arr"] = vegetation_vitality_arr;
    out["soil_moisture_arr"] = soil_moisture_arr;
    out["water_balance_30d_arr"] = water_balance_30d_arr;
    out["plant_available_water_arr"] = plant_available_water_arr;
    out["vegetation_growth_pressure_arr"] = vegetation_growth_pressure_arr;
    out["vegetation_heat_stress_arr"] = vegetation_heat_stress_arr;
    out["vegetation_drought_stress_arr"] = vegetation_drought_stress_arr;
    out["vegetation_cold_stress_arr"] = vegetation_cold_stress_arr;
    out["vegetation_regen_score_arr"] = vegetation_regen_score_arr;
    out["cover_arr"] = cover_arr;
    out["is_water_arr"] = is_water_arr;
    out["has_river_arr"] = has_river_arr;
    out["river_flow_arr"] = river_flow_arr;
    out["river_downstream_arr"] = river_downstream_arr;
    out["hydro_parent_arr"] = hydro_parent_arr;
    out["has_volcano_arr"] = has_volcano_arr;
    out["ema_initialized_arr"] = ema_initialized_arr;
    out["water_depth_arr"] = water_depth_arr;   // [water-depth-tex] 海/湖统一归一水深 ∈ [0,1]
    if (upwelling_arr.size() == n) out["upwelling_strength_arr"] = upwelling_arr;

    PackedInt32Array neighbors;
    if (row_major && neighbors.resize(NB.size()) == OK) {
        int32_t *data = neighbors.ptrw();
        std::copy(NB.begin(), NB.end(), data);
        if (width == 1) {
            // MapData excludes self edges; keep the generator's inputs intact.
            for (int i = 0; i < n; ++i)
                data[size_t(i) * 6] = data[size_t(i) * 6 + 3] = -1;
        }
        out["neighbor_indices"] = neighbors;
    }
    // The river baker retains its own topology and final physical columns.
    _gen_river_n = n;
    _gen_river_q.assign(Q, Q + n);
    _gen_river_r.assign(R, R + n);
    _gen_river_terrain.assign(TERR, TERR + n);
    _gen_river_elev.assign(E, E + n);
    _gen_river_has.assign(RIV, RIV + n);
    _gen_river_flow.assign(RFLOW_OUT, RFLOW_OUT + n);
    _gen_river_downstream.assign(RDOWN, RDOWN + n);
    _gen_river_neighbors = std::move(NB);

    return out;
