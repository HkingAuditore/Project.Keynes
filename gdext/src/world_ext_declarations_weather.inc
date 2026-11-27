// Weather field, summaries, and cyclone mode declarations.

    // ─── Weather Hot-Path C++ 化（plan/weather-hotpath-cpp）───────────────
    //
    // dist：_distribute_weather_field_to_cells C++ 化
    //   GDScript 源：scripts/weather/weather_system.gd::_distribute_weather_field_to_cells
    //                 (line 1290+)
    //   ClimateProfile flag：use_gdext_weather_distribute（默认 true）
    //   性能目标：~11.6ms → < 1.5ms（n_cells = 2400 基线）
    //
    //   入参 `knobs` Dictionary（GDScript 一次打包）：
    //     标量：n_cells (int)
    //           snow_threshold_temp, snow_min_intensity, flood_heavy_intensity,
    //           flood_heavy_precip, flood_lowland_intensity, flood_lowland_elev,
    //           flood_lowland_moisture (float)
    //     PackedArray（zero-copy read-write via SoA view）：
    //           weather_type, weather_intensity, weather_precip,
    //           weather_field_initialized,
    //           moisture_arr, temp_arr, cover_arr, accumulated_snow_days_arr,
    //           landform_arr, terrain_arr （详见 cpp 实装）
    //
    //   写：moisture / temperature / cover / current_state["cover"]（通过 schema
    //       回写） / accumulated_snow_days；并通过 out 字段返回 cover_dirty bool。
    //   返回：≥ 0.0 → 接管完成（=elapsed_ms）；< 0.0 → fallback。
    //
    //   sig 设计：返回 Dictionary 而非 double，包含 { "elapsed_ms", "cover_dirty" }。
    //             elapsed_ms < 0 表示 precondition 失败。
    godot::Dictionary run_weather_distribute_pass(const godot::Dictionary &knobs);
    // summary：_build_field_summary_fronts C++ 化
    //   GDScript 源：scripts/weather/weather_system.gd::_build_field_summary_fronts
    //                 (line 1322+)
    //   ClimateProfile flag：use_gdext_weather_summary（默认 true）
    //   性能目标：~17.8ms → < 3.0ms（n_cells = 2400, field_summary_limit = 16）
    //
    //   入参 `knobs` Dictionary：
    //     标量：n_cells (int), field_summary_limit (int), hex_size (float)
    //           summary_intensity_enter (float, =0.10),
    //           summary_intensity_hold  (float, =0.06),
    //           merge_ratio (float, =0.65), max_merge_rounds (int, =4)
    //           day_counter (int, 仅 debug 用)
    //     PackedArray（zero-copy read，SoA view）：
    //           cell_pos, neighbor_indices,
    //           weather_type, weather_intensity, weather_field_initialized,
    //           weather_cloud, weather_precip, wind_x, wind_y
    //     fallback：avg_wind_x, avg_wind_y (float, 新生 cluster 用)
    //
    //   读：上述 SoA + 持久化的 _prev_summary_seeds / _prev_summary_membership
    //       （C++ 内部维护，跨 tick 存活）
    //   写：返回 Dictionary { "elapsed_ms": float, "fronts": Array[Dictionary] }。
    //       每个 front Dictionary 字段：type/center/intensity/radius/axis/
    //       stable_axis/velocity/major_scale/minor_scale/age_days/ttl_days/
    //       life_progress/edge_seed/cloud_amount/precip_amount。
    //
    //   sig 设计：返回 Dictionary，字段 elapsed_ms < 0 表示 precondition 失败；
    //             此时 fronts 字段为空 Array，调用方 fallback 到 GDScript。
    godot::Dictionary run_weather_summary_fronts_pass(const godot::Dictionary &knobs);
    // 清空 C++ 端持久化的 summary 状态（_prev_summary_seeds / _prev_summary_membership）。
    // 在 GDScript 切换 use_gdext_weather_summary flag、或开关 verify mode 时调用，
    // 避免新旧实现互相污染。无副作用、O(1) 清空（vector::clear）。
    void reset_weather_summary_state();
    // verify 协议辅助：snapshot / restore 持久化状态。set_summary_verify_mode 在 dev
    // 模式下要求"先跑 C++ 再跑 GDScript"两遍，跑 GDScript 之前必须把 C++ 写脏的状态
    // 还原到本 tick 入口；这两个接口配合 GDScript 端的 prev_seeds shadow 完成往返。
    void snapshot_weather_summary_state();
    void restore_weather_summary_state();
    // ─── plan/weather-refresh-cpp-all: 顶层一体化 weather refresh ────────
    //
    // 单 C++ 调用内顺序执行 5 段：
    //   ① run_weather_field_solve_pass(knobs)
    //   ② run_weather_distribute_pass(knobs)
    //   ③ run_weather_summary_fronts_pass(knobs)   ← 产 fronts Array
    //   ④ cyclone_wake_step(knobs, fronts)         ← 新增（front_advect.gd::tick_cyclone_wake 1:1 移植）
    //   ⑤ run_stage_b_pass(knobs)
    //
    // 设计原则（方案 X）：内部**直接复用已有 4 个 run_*_pass 公开 API**，
    // 不抽 *_inline，不动现有 pass 函数体。代价是顶层 pass 内会重复解析同一
    // Dictionary 4 次（每次 ~10-50μs），与节省的 4 次 GD↔CPP round-trip
    // (~0.3-0.8ms) 相比仍净赚。
    //
    // ClimateProfile flag：use_gdext_weather_refresh_daily（默认 true）
    //
    // knobs 入参：所有子 pass 的 knobs 字段合并到同一 Dictionary，
    //             各子 pass 各自只读自己需要的 key。本顶层 pass 额外要求：
    //   标量： hex_size (float, cyclone_wake 用)
    //          cyclone_wake_days (int, cyclone wake 持续天数)
    //          cyclone_storm_type_id (int, WeatherType.WT.STORM 枚举值)
    //          water_terrain_ids 已在 summary pass knobs 中存在，cyclone 复用
    //   summary pass knobs 中已含 cell q/r 反查能力（_summary_qr_to_idx），
    //     cyclone 通过 cell_q/cell_r SoA 反查注入点。
    //
    // 返回 Dictionary：
    //   { rc: 0/-1, fail_stage: String?, weather_tick_ms,
    //     advance_ms, distribute_ms, cyclone_ms, fronts_count,
    //     albedo_ms, veg_dyn_ms, feedback_ms, total_ms, fronts: Array }
    //   任一子段 rc<0 时 { rc:-1, fail_stage:"field_solve|distribute|summary|stage_b" }
    //   立即短路返回，caller 走 GDScript fallback。
    //
    // 副作用：除子 pass 自身的副作用外，本顶层 pass 维护
    //   _cyclone_perturbations (std::vector<CycloneWakeEntry>) 跨 tick 存活。
    //   GDScript 端通过 get_cyclone_perturbations_dict() 取镜像，落到
    //   weather_system.ocean_current_perturbation Dictionary。
    godot::Dictionary run_weather_refresh_daily_pass(const godot::Dictionary &knobs);
    // 镜像 API：把 C++ 端 _cyclone_perturbations 导出成 GDScript Dictionary，
    // 结构与 weather_system.ocean_current_perturbation 1:1（key = cell.q*10000+cell.r 的
    // 64-bit int hash；value = Dictionary{ vec: Vector2, vec_init: Vector2,
    // days_left: int, init_days: int }）。
    //
    // 调用时机：refresh_weather_daily 在 ext call 成功后立即调一次，把结果
    // 回灌 weather_system.ocean_current_perturbation，下游消费方（航运 AI、
    // shader overlay、soak dump）零感知 C++ 切换。
    godot::Dictionary get_cyclone_perturbations_dict() const;
    godot::Dictionary get_active_cyclone_snapshot() const;
    godot::Dictionary get_climate_modes_report() const;
    godot::Dictionary capture_climate_modes_state() const;
    godot::Dictionary restore_climate_modes_state(const godot::Dictionary &state);
