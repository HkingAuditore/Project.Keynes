// Physical wind, pressure, and ocean circulation declarations.

    // ─── Block B: ocean_currents wind solver C++ pass ─────────────────────
    //
    //   GDScript 源：scripts/rendering/physical_circulation_solver.gd::solve_wind_field
    //                 (line 246-454, 195 行)
    //   ClimateProfile flag：use_gdext_wind_field（默认 false；本 PR 完成 +
    //                        SAME_SOURCE A/B 通过 + p95 ≤ 5ms 后切 true）
    //   性能目标：35.55ms p95 → < 5ms（charter §7 / dots-wind-validation.md）
    //
    //   算法结构（与 GDScript 1:1 镜像）：
    //     Pass 0 — 海岸 BFS（≤ _WIND_COAST_THERMAL_MAX_DIST=5 步）：
    //       识别每个陆地 cell 距海岸的格数，用作沿海热力压差权重
    //     主循环 — 每 cell：
    //       (a) 纬度基线 v_base = wind_belt_at(ny shifted by solar declination)
    //       (b) 6 邻域离散梯度 grad_slp = (1/3)*Σ(slp_nb-slp_self)*d_unit
    //       (d) 科氏偏转：仅对 -grad_slp 做（北半球右偏 / 南半球左偏）
    //       (c) 沿海权重只放大 SLP 梯度项；方向由 pressure gradient 决定
    //       合成 v_sum = w_lat*v_base + w_grad*v_grad + synoptic perturbation
    //       (e) 地形/摩擦衰减 + 山脉绕流（mountain neighbor 切向偏转）
    //       写 wind_x_arr[i], wind_y_arr[i], wind_speed_out[i]
    //
    //   入参 `knobs` Dictionary：
    //     标量： n_cells (int)
    //            hex_size (float)
    //            season_phase (float, orbital/year phase only)
    //            terrain_aware (int 0/1)  — 见 ClimateProfile.enable_terrain_aware_wind
    //            world_bounds_pos_y (float)
    //            world_bounds_size_y (float)
    //     PackedArray（zero-copy read）：
    //            neighbor_indices : PackedInt32Array (n_cells * 6)
    //                ↑ 顺序与 HexUtils.CUBE_DIRECTIONS 一致
    //                  (0=E, 1=NE, 2=NW, 3=W, 4=SW, 5=SE)
    //            slp_arr          : PackedFloat32Array (n_cells)
    //                ↑ 必填！由 GDScript 从 cell.slp 提取
    //                  （cell.slp 不在 schema 中）
    //            water_terrain_ids: PackedByteArray (~4 entries)
    //                ↑ TerrainType 枚举 OCEAN/COAST/REEF/KELP，
    //                  与 _is_water_terrain 1:1 对齐
    //            land_lf_mountain : int (knobs scalar) = LandformType.LF.MOUNTAIN
    //            land_lf_peak     : int (knobs scalar) = LandformType.LF.PEAK
    //            land_lf_hill     : int (knobs scalar) = LandformType.LF.HILL
    //
    //   读：cell_pos_y (lat 推导), cell_terrain (U8), cell_landform (U8) +
    //       knobs["slp_arr"] + knobs["neighbor_indices"]
    //   写：cell_wind_x slot (F32), cell_wind_y slot (F32) + flush_slot_to_map
    //   knobs 输出：
    //     wind_speed_out : PackedFloat32Array (n_cells)
    //         ↑ caller 拿这个数组写每 cell.wind_speed
    //         （cell.wind_speed 不在 schema）
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；
    //         < 0.0 → 任意先决条件不满足，调用方走 GDScript 回退。
    //
    //   bit-equal 容差：1e-4（含 sin/cos/sqrt/normalize 链）
    //   未支持的特性：none（与 GDScript 算法 1:1 镜像）
    double run_wind_field_pass(godot::Dictionary knobs);
    godot::Dictionary run_physical_circulation_pass(godot::Dictionary knobs);
    // ─── plan/dots-slp-psi-cpp: SLP field solver (stage 1) ───────────────
    // Native SLP authority:
    //   Pass A: latitude pressure belts + insolation-driven land/sea thermal
    //           pressure + closed-loop thermal/ice/snow/moist terms.
    //   Pass B: smooth_passes-round 6-neighbor Jacobi smoothing
    //
    // knobs in:   n_cells, hex_size, season_phase, smooth_passes,
    //             world_bounds_pos_y, world_bounds_size_y,
    //             neighbor_indices, water_terrain_ids,
    //             slp_lat_amp, slp_land_amp, slp_water_damp,
    //             slp_interior_boost, slp_coast_damp,
    //             axial_tilt_deg, insolation_daylen_amp
    // knobs out:  slp_out (PackedFloat32Array, length n_cells)
    //
    // Dictionary out: { elapsed_ms, fallback (bool), reason (String) }
    //   elapsed_ms < 0 -> caller falls back to GDScript path.
    godot::Dictionary run_slp_field_pass(godot::Dictionary knobs);
    // ─── plan/dots-slp-psi-cpp: PSI ocean stream-function solver ─────────
    // Fused stage 3 + 4 + 5 (init + SOR iters + finalize) in one C++ call:
    //   init     : enumerate water cells in cell-index order (1:1 with
    //              GDScript), build nb_idx, compute wind_stress_curl,
    //              compute beta_abs / r_factor / source per water cell.
    //   iters    : SOR Gauss-Seidel in-place iterations (psi_total_iters
    //              default 24), bit-equal to GDScript step_psi_solver.
    //   finalize : 6-neighbor gradient -> ocean_current, +/- 90 deg
    //              rotate, thermohaline high-lat overlay, clamp [-1,1].
    //
    // knobs in:   n_cells, hex_size, world_bounds_pos_y/size_y,
    //             neighbor_indices, cell_q, cell_r, water_terrain_ids,
    //             wind_x_arr, wind_y_arr, wind_speed_arr,
    //             psi_total_iters, psi_sor_omega, psi_r_base,
    //             psi_beta_floor, psi_source_scale, ocean_current_scale,
    //             thermohaline_weight, upwelling_highlat_abs,
    //             cold_sink_temp
    // knobs out:  wind_stress_curl_out, ocean_psi_out,
    //             ocean_current_x_out, ocean_current_y_out
    //             (each PackedFloat32Array of length n_cells; land cells
    //              filled with 0)
    //
    // Dictionary out: { elapsed_ms, fallback (bool), reason (String) }
    godot::Dictionary run_psi_solver_pass(godot::Dictionary knobs);
    // ─── dots-total-cpp step3（2026-06-25）：物理环流编排下沉（仅生成期一次性路径）──
    // run_physical_solve_pass：单次驱动，在 C++ 进程内按序串起 SLP → wind → PSI →
    //   upwelling 四个已验证 kernel（均读 bound slot + publish_to_slot），中间量
    //   （slp→wind 经 slp_arr、wind→psi 经 wind_*_arr）在 C++ 内从返回值/slot 串联，
    //   不跨语言往返。GDScript 一次请求（combined knobs = 4 stage 输入并集，含
    //   neighbor_indices/water_terrain_ids/prev_slp_arr + 全部标量/profile 参数 +
    //   heat_transport/solve_ocean/terrain_aware 标志），C++ 自动注入 chained 键
    //   （slp_arr/wind_x_arr/wind_y_arr/wind_speed_arr/stage）。仅 `_bake_initial_*` /
    //   `rebake_ocean_currents` 等**已经是原子完成**的路径用它（运行期逐帧分摊路径
    //   `_physical_solve_step_one` 不受影响）。任一 sub-pass fallback → 整体 fallback，
    //   GDScript 回退到原 step_one loop。NaN 守门 + 风场 RG8 光栅化仍在 GDScript
    //   （wrapper 调 phys_field_nan_guard + _bake_initial_vector_buffers）。
    //   输出 { fallback, reason, slp_ms, wind_ms, psi_ms, upwelling_ms, psi_ran,
    //   elapsed_ms }。前置：ext 必须 bind_map_data。
    godot::Dictionary run_physical_solve_pass(godot::Dictionary knobs);
