// Climate input and daily temperature, moisture, wind, and ice passes.

    // ---- bindings: climate ----
    // Landmass/province topology, origin-habitat fill + niche pack, and daily occupancy.
    // Knobs in / packed arrays out; occupancy is the persisted presence bitset.
    godot::Dictionary run_bio_province_pass(const godot::Dictionary &knobs);
    godot::Dictionary run_bio_seed_pass(const godot::Dictionary &knobs);
    godot::Dictionary run_bio_bootstrap_pass(const godot::Dictionary &knobs);
    godot::Dictionary configure_bio_occupancy(const godot::Dictionary &config);
    godot::Dictionary apply_runtime_species_writeback();
    godot::Dictionary run_bio_occupancy_pass(const godot::Dictionary &knobs);
    // Deterministic cursor continuation.  The opaque state is transient and
    // is published only after the final fixed cell range completes.
    godot::Dictionary run_bio_occupancy_slice(const godot::Dictionary &knobs);
    // ─── Hot-loop entry points (stubs; filled in I3.B/C) ─────────────────
    // Returning -1.0 indicates "not implemented yet, fall back to GDScript".
    // GDScript-side caller checks `< 0` and routes to the legacy path.
    double run_climate_pass_a(const godot::Dictionary &cp_struct, double phase, double season_phase);
    // [Phase C.3c] climate_pass_a 的 WorkerThreadPool 并行变体。
    // 主循环纯 cell-local map（无 race），按 cell range 拆 n_tasks 段并行；
    // n_tasks=0 时自适应（ceil(n/1024) 截 [1,16]，与 ocean_water/land_thread 一致）。
    // 算法与 run_climate_pass_a 严格 1:1（共用 prelude 与 main loop body）；返回值同语义。
    double run_climate_pass_a_thread(const godot::Dictionary &cp_struct, double phase, double season_phase, int n_tasks);
    // F.1 (P0): weather field solve (vapor / cloud / precip / instability /
    //           intensity / convergence / type) — single-shot full pass.
    //
    //   GDScript 源：scripts/weather/weather_system.gd::run_weather_field_solve_slice
    //                 (line 641+, "B-full Step-2" SoA-aware fast path)
    //   ClimateProfile flag：use_gdext_weather_field
    //   性能目标：13ms → < 2ms（charter §7 第一优先级）
    //
    //   入参 `knobs` Dictionary（GDScript 一次打包）：
    //     标量： start_idx, end_idx, n_cells, season_idx (int)
    //            climate_anomaly, season_phase (float)
    //            world_bounds_pos_y, world_bounds_size_y (float)
    //            field_advect_steps (int)
    //            field_diffusion, field_condensation_gain,
    //            field_orographic_lift_gain, field_convergence_gain,
    //            field_ocean_evap_gain, field_precip_decay (float)
    //            refresh_convergence (bool)
    //     PackedArray（zero-copy read）：
    //            cell_pos          : PackedVector2Array  (n_cells)
    //            neighbor_indices  : PackedInt32Array    (n_cells * 6)
    //            prev_vapor        : PackedFloat32Array  (n_cells)
    //            prev_precip       : PackedFloat32Array  (n_cells)
    //            temp_transport_anomaly : PackedFloat32Array  (n_cells)
    //              ↑ 由 GDScript 从 cells[i].temperature_transport_anomaly
    //                按 i 顺序提取（该字段尚未在 schema 中作 SoA 镜像；
    //                F.x phase II 数据所有权下移 PR 中再迁移到 schema）
    //
    //   写：直接写到 cell_weather_{vapor/cloud/precip/instability/intensity/
    //       convergence/type/field_init} slot 数组（=GDScript map.weather_*_arr
    //       的 CoW alias）。GDScript 调用方在调用后再把这些 SoA 拷回
    //       _field_slice_next_* 即可保持 commit_weather_field_solve() 不变。
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；
    //          < 0.0 → 任意先决条件不满足，调用方走 GDScript 回退。
    //
    //   bit-equal 容差：1e-4（含 sqrt + clamp + lerp 链）。
    //   切片限制：本实现要求 start_idx == 0 且 end_idx == n_cells（即"全量"）。
    //             因为多 slice 共享 SoA 写会污染下一 slice 的读，单元格预算 < n
    //             一律 fallback。F.x 后续 PR 可加 dirty-flag 双缓冲解锁。
    double run_weather_field_solve_pass(const godot::Dictionary &knobs);
    // 独立全场 ψ 推进 pass（每 weather 轮一次、不切片、半拉格朗日平流）。让天气随风成片移动。
    double run_synoptic_advance_pass(const godot::Dictionary &knobs);
    godot::Dictionary run_weather_field_commit_pass(godot::Dictionary knobs);
    // F.2 (P1): ocean water + land 两个独立 pass
    //   GDScript 源：map_generator.gd::_ocean_water_pass_soa (line 4679+) +
    //                ::_ocean_land_pass_soa (line 4762+)
    //   ClimateProfile flag：use_gdext_ocean_water / use_gdext_ocean_land
    //   性能目标：6.8ms → < 1ms (两个 pass 各 ~0.5ms)
    //   依赖序：land_pass 必须在 water_pass 之后跑（land 读 water 写过的 anomaly）
    //
    //   入参 `knobs` Dictionary（与 F.1/F.3/F.5 同模板）：
    //
    //   --- run_ocean_water_pass(knobs) 字段 ---
    //     标量： n_cells (int), advect_steps (int), heat_mix (float)
    //     PackedArray（read-only 输入）：
    //            neighbor_indices  : PackedInt32Array    (n_cells * 6)
    //            baseline_arr      : PackedFloat32Array  (n_cells)
    //                ↑ GDScript 预算：if ema_init[i]: temp_baseline[i],
    //                                  else: _compute_temperature(_cube_row_norm, elev[i])
    //            temp_before_arr   : PackedFloat32Array  (n_cells)
    //                ↑ GDScript 预算：if temp[i] > 0: temp[i], else: baseline[i]
    //            ocean_current_x_arr : PackedFloat32Array (n_cells)
    //            ocean_current_y_arr : PackedFloat32Array (n_cells)
    //                ↑ 必须！由 GDScript 从 cells[i].ocean_current.x/y 提取。
    //                  schema 里的 cell_ocean_current_x/y SoA 镜像由
    //                  rebuild_soa_from_cells 仅在世界生成时填一次；
    //                  physical_circulation_solver 之后改的是 HexCell，
    //                  从不回写 SoA。如果直接读 C++ slot，advect 方向用的
    //                  是初始 (近 0) 值，cascading 全图温度雪崩。
    //                  （Demo Complex Pass 类同问题，2026-05-13 用户验收时
    //                   F.2 land 正反馈 + ocean_current stale 双重 bug 暴露。）
    //     PackedArray（write 输出）：
    //            anomaly_out      : PackedFloat32Array  (n_cells)
    //                ↑ C++ 写每个 water cell 的 anomaly = temp_mixed - baseline
    //                  （非 water cell 由 land pass 后续覆盖；初始可全 0）
    //
    //   --- run_ocean_land_pass(knobs) 字段 ---
    //     标量： n_cells (int), effective_leak (float)
    //     PackedArray（read-only 输入）：
    //            neighbor_indices       : PackedInt32Array    (n_cells * 6)
    //            fallback_baseline_arr  : PackedFloat32Array  (n_cells)
    //                ↑ 必填！runtime baseline 非有限值时的兜底值。
    //            ocean_current_x_arr    : PackedFloat32Array  (n_cells)
    //            ocean_current_y_arr    : PackedFloat32Array  (n_cells)
    //                ↑ 必填！同 water pass 一样从 cells 提取（SoA stale 问题）
    //     PackedArray（in/out）：
    //            anomaly_inout    : PackedFloat32Array  (n_cells)
    //                ↑ 既读（water 邻居的 anomaly，由 water pass 写入），
    //                  也写（land cell 自身的 anomaly）
    //
    //   读：cell_temp, cell_is_water, cell_pos_x, cell_pos_y,
    //       cell_ocean_current_x, cell_ocean_current_y
    //   写：cell_temp（mix 后）+ knobs["anomaly_inout"]
    //
    //   返回：≥ 0.0 → 接管完成 (=elapsed_ms)；< 0.0 → fallback
    //   bit-equal 容差：1e-4（含 sqrt + lerp + dot product 链）
    double run_ocean_water_pass(godot::Dictionary knobs);
    double run_ocean_land_pass (godot::Dictionary knobs);
    double run_wind_air_mass_pass(godot::Dictionary knobs);
    double run_wind_surface_pass(godot::Dictionary knobs);
    // plan/sim-2ms-simd-dirty-budget — SIMD/Thread variants for ocean passes.
    //
    // run_ocean_water_pass_simd:
    //   与原 scalar 版同签名 / 同输出语义；内部走 water-cell / land-cell 预筛
    //   + 直线 hot kernel，消除主循环外层 if(IW[i]==0|!=0) 分支让编译器自由
    //   auto-vectorize。CoW fix（anomaly_out / anomaly_inout 仍走 duplicate）
    //   保持不变。ulp ≤ 4 容差（charter §risk=B 已批）。
    //   仅在 ClimateProfile.use_gdext_ocean_water_simd / use_gdext_ocean_land_simd
    //   = true 时由调用方派发。
    //
    // run_ocean_water_pass_thread / run_ocean_land_pass_thread:
    //   预筛 idx 按 n_tasks 切 WorkerThreadPool；n_water / n_land < 256 时
    //   降级单线程；wtp == nullptr 时 in-thread fallback。n_tasks <= 0 时
    //   按 ~1024 cells/task 自适应（cap 至 16）。
    //   仅在 ClimateProfile.use_gdext_thread_fallback = true 且 SIMD 不达
    //   预算时由调用方派发。
    double run_ocean_water_pass_simd  (godot::Dictionary knobs);
    double run_ocean_water_pass_thread(godot::Dictionary knobs, int n_tasks);
    double run_ocean_land_pass_thread (godot::Dictionary knobs, int n_tasks);
    // F.3 (P1): climate Pass-B (local climate coupling)
    //   GDScript 源：scripts/geography/map_generator.gd::_climate_pass_b_soa
    //                 (line 4311+, SoA-aware fast path)
    //   ClimateProfile flag：use_gdext_climate_pass_b
    //   性能目标：5.2ms → < 0.5ms（charter §7 P1）
    //
    //   入参 `knobs` Dictionary（GDScript 一次打包，与 F.1/F.5 同模板）：
    //     标量： n_cells (int)
    //            winter_boost, snow_cool, veg_cool, diurnal_amp, evap_gain,
    //            rs_threshold, rs_factor, t_freeze, coupling_gain, coast_leak,
    //            season_phase (float, orbital/year phase only)
    //            rs_lookback (int)
    //            go_sparse (bool；本实现不支持稀疏路径，go_sparse=true 时
    //                       直接 return -1.0 fallback；后续 PR 加 dirty mask
    //                       处理后再启用)
    //     PackedArray（zero-copy read）：
    //            neighbor_indices         : PackedInt32Array    (n_cells * 6)
    //            temp_transport_anomaly   : PackedFloat32Array  (n_cells)
    //                ↑ 由 GDScript 从 cells[i].temperature_transport_anomaly 提取
    //                  （schema 尚未为该字段建 SoA 镜像；同 F.1）
    //            foliage_table            : PackedFloat32Array  (按 VegetationType.VEG
    //                ↑ enum 顺序的 _vegetation_foliage_density 值，~24 个 float)
    //
    //   读：cell_temp, cell_moisture, cell_snow_cover, cell_is_water,
    //       cell_landform, cell_vegetation, cell_elevation, cell_lat_norm,
    //       cell_pos_x, cell_pos_y, cell_insolation_dev
    //   写：cell_temp, cell_moisture
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)
    //          < 0.0 → 任意先决条件不满足 / go_sparse=true，调用方走 GDScript
    //
    //   bit-equal 容差：1e-4（含 sqrt + sin + smoothstep + cos 链）
    //   未支持的特性：
    //     - go_sparse=true 时的稀疏路径 → fallback
    //     - cell.temperature_breakdown UI 调试 dict 写入 → 不写入（GDScript
    //       fallback 会写；F.3 ON 时 inspector 看选中 cell 的 breakdown 会空，
    //       后续 PR 用 dirty selection list 单独补回 < 100 cells 的写入即可）
    //     - [DIAG pass_b_end] 末尾统计 print（GDScript caller 在 C++ pass 之后
    //       自己 dump SoA 即可，本 C++ 不打日志）
    double run_climate_pass_b(const godot::Dictionary &knobs);
    // plan/sim-2ms-simd-dirty-budget — SIMD/Thread variants for hot pass-B.
    //
    // run_climate_pass_b_simd:
    //   与 run_climate_pass_b 同签名 / 同输出语义；内部走 land-cell 预筛 +
    //   直线 hot kernel（albedo / coastal / landform / write）+ scalar
    //   rain-shadow 子段。MSVC /O2 /arch:AVX2 在直线 land-only 循环上能自
    //   动向量化；显式 AVX2 8-lane block 包在 PK_HAVE_AVX2 内对最 SIMD-
    //   friendly 段（albedo）做强制向量化。
    //   ulp 容差：≤ 4（plan §验收 §B）。
    //   仅在 ClimateProfile.use_gdext_pass_b_simd = true 时由调用方派发。
    //
    // run_climate_pass_b_thread:
    //   land-cell 主段按 n_tasks 切 WorkerThreadPool；rain-shadow 子段仍
    //   单线程跑（其内含的串行 probe + 邻居最佳方向 search 无可分发性）。
    //   仅在 ClimateProfile.use_gdext_thread_fallback = true 且 SIMD 路径
    //   未达预算时由调用方派发；wtp == nullptr 时 in-thread fallback。
    double run_climate_pass_b_simd  (const godot::Dictionary &knobs);
    double run_climate_pass_b_thread(const godot::Dictionary &knobs, int n_tasks);
    // F.4 (P2): sea ice daily pass
    //   GDScript 源：scripts/geography/map_generator.gd::_apply_sea_ice_daily_pass
    //                 (line 3856+, 2-phase 算法)
    //   ClimateProfile flag：use_gdext_sea_ice
    //   性能目标：5.1ms → < 0.5ms（charter §7 P2）
    //
    //   算法结构（与 GDScript 1:1 镜像）：
    //     Phase A — has_cold_neighbor 快照（用前一日 sea_ice_fraction）：
    //       for each water cell：
    //         如果任一邻居是 water 且 sea_ice_fraction >= 0.6 → has_cold_neighbor[i] = 1
    //     Phase B — 主循环（fraction 增量更新 + 翻转候选收集）：
    //       for each cell：
    //         非 water → fraction = 0；continue
    //         LAKE → fraction = 0；continue
    //         t_eff = clamp(temp + ice_delay * max(0, transport_anomaly) -
    //                       (upwelling > 0.3 ? 0.5 * upwelling : 0), 0, 1)
    //         k_freeze_eff = k_freeze * (has_cold_neighbor ? 1 + contagion : 1)
    //         delta = k_freeze_eff * max(0, t_form - t_eff) - k_melt * max(0, t_eff - t_melt)
    //         new_frac = clamp(prev_frac + delta, 0, 1)
    //         写 cell_sea_ice_frac[i] = new_frac
    //         判断翻转候选：
    //           prev terrain != SEA_ICE && new_frac >= threshold → flip_to_ice
    //           prev terrain == SEA_ICE && new_frac < threshold - hysteresis →
    //               flip_to_base（保留 base_terrain，base==SEA_ICE 时回退到 OCEAN）
    //
    //   入参 `knobs` Dictionary（GDScript 一次打包，F.5 同模板）：
    //     标量： n_cells (int)
    //            k_freeze, k_melt, t_form, t_melt, contagion (float)
    //            threshold, hysteresis (float)
    //            ice_delay (float)
    //            enable_ocean_heat_transport (bool)
    //            terrain_lake_id, terrain_sea_ice_id, terrain_ocean_id (int)
    //                ↑ TerrainType.LAKE / SEA_ICE / OCEAN 的 enum 值（C++ 不持有 enum）
    //     PackedArray（zero-copy read）：
    //            neighbor_indices       : PackedInt32Array    (n_cells * 6)
    //            base_terrain_arr       : PackedByteArray     (n_cells)
    //                ↑ cells[i].base_terrain；翻回时知道目标 terrain
    //            water_terrain_ids      : PackedByteArray     (~6 entries)
    //                ↑ 与 GDScript map_generator.gd::_is_water 1:1 对齐：
    //                  OCEAN / COAST / LAKE / REEF / KELP / SEA_ICE 共 6 种 enum 值。
    //                  C++ 端用作 256-entry is_water LUT，避免硬编码 enum。
    //            temp_transport_anomaly : PackedFloat32Array  (n_cells)
    //                ↑ 必填（schema 尚未为该字段建 SoA 镜像，与 F.2 同问题）
    //            upwelling_strength     : PackedFloat32Array  (n_cells)
    //                ↑ 必填（同上）
    //
    //   读：cell_terrain (U8), cell_sea_ice_frac (F32, prev), cell_temp (F32)
    //       + 入参 PackedArray（含 insolation_now_arr 当前辐照）
    //   写：cell_sea_ice_frac slot；**不**写 cell_terrain slot（terrain 翻转走
    //       GDScript 端 apply_terrain，保持 multi-axis 同步语义；charter §2.5
    //       STRUCT-001 反模式规避）
    //
    //   knobs 输出回填（C++ 写 PackedInt32Array / PackedByteArray 进 knobs）：
    //     flip_to_ice_list      : PackedInt32Array  — 当日跨过 threshold 的 cell idx
    //     flip_to_base_list     : PackedInt32Array  — 当日跌回 threshold-hysteresis 的 cell idx
    //     flip_to_base_terrain  : PackedByteArray   — 与 flip_to_base_list 同长，
    //                                                 每项 = base_terrain（base==SEA_ICE 时 = OCEAN_id）
    //     stat_water_count      : int  (写到 knobs，用 Variant int 存)
    //     stat_flipped_count    : int  (写到 knobs)
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；< 0.0 → fallback
    //   bit-equal 容差：1e-6（fraction 是简单 muladd / clamp，无 sqrt）
    //
    //   sig 设计：knobs 走 by-value（非 const&），让 C++ 端能写回 flip lists
    //             给 GDScript caller。Godot Dictionary 是 RefCounted，by-value
    //             实际是 ref 共享，写回是合法行为（与 F.2 ocean_water/land 同模式）。
    double run_sea_ice_daily_pass(godot::Dictionary knobs, float season_phase);
    // [Phase C.3d] sea_ice 并行变体
    //   行为 = run_sea_ice_daily_pass，但 Phase A (cold_neighbor 快照) +
    //   Phase B (主循环 + flip emit) 都走 WorkerThreadPool 并行。
    //   emit lists (flip_to_ice / flip_to_base / flip_to_base_terrain) 通过
    //   thread-local Emit + 串行 reduce (按 task_idx 升序) 保持与 scalar
    //   bit-equal（任务内部 cell idx 升序 + 任务顺序合并 = 整体升序）。
    //   counters (water_count / flipped_count) 同模式 reduce。
    //   仅在 ClimateProfile.use_gdext_thread_fallback = true 时调用。
    double run_sea_ice_daily_pass_thread(godot::Dictionary knobs, float season_phase, int n_tasks);
    // F.5 (P2): transpiration pass
    //   GDScript 源：scripts/geography/map_generator.gd::_apply_transpiration_pass (line 4938+)
    //   ClimateProfile flag：use_gdext_transpiration
    //   性能目标：3.2ms → < 0.3ms
    //
    //   入参 `knobs` Dictionary（GDScript 一次打包，与 F.1 同模板）：
    //     标量： n_cells (int)
    //            outflow_rate, self_rate (float)
    //     PackedArray（zero-copy read）：
    //            neighbor_indices  : PackedInt32Array    (n_cells * 6)
    //            donor_table       : PackedFloat32Array  (按 VegetationType.VEG enum 顺序，
    //                                ~24 个 float；每项 = transpiration[VEG_id]，避免
    //                                hot loop 反射 VegetationProfile)
    //
    //   读：cell_landform / cell_vegetation / cell_moisture
    //   写：cell_moisture (clamp(m + delta, 0, 1))
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；
    //          < 0.0 → 任意先决条件不满足，调用方走 GDScript 回退。
    double run_transpiration_pass(godot::Dictionary knobs);
    // Runtime hydrology: daily local water balance + parent-graph routing.
    // Optional knob: neighbor_indices (n_cells * 6) lets river discharge maintain
    // narrow river/riparian moisture floors and boost adjacent soil/water balance.
    godot::Dictionary run_runtime_hydrology_pass(const godot::Dictionary &knobs);
