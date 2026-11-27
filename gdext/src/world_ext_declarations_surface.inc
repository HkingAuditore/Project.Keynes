// Albedo, vegetation, weather fronts, and seasonal refresh declarations.

    // ─── DOTS-Final-Push（plan/dots-final-push 任务 2）：albedo pass ─────
    //   GDScript 源：scripts/geography/map_generator.gd::_apply_albedo_pass
    //   ClimateProfile flag：use_gdext_albedo
    //   性能目标：~3.6ms → < 0.5ms
    //
    //   算法（与 GDScript 1:1 镜像）：
    //     for each cell i:
    //       if is_water[i]: continue
    //       alb = albedo_table[veg[i]]
    //       if cover[i] == CV.SNOW (=1) || cover[i] == CV.GLACIER (=2):
    //         alb = max(alb, 0.75)
    //       dt = (reference_albedo - alb) * albedo_temp_gain
    //       temp[i] = clamp(temp[i] + dt, 0, 1)
    //
    //   入参 `knobs` Dictionary：
    //     标量： n_cells (int)
    //            reference_albedo (float)         — ClimateProfile.reference_albedo
    //            albedo_temp_gain (float)          — ClimateProfile.albedo_temp_gain
    //            snow_cover_albedo (float, =0.75) — SNOW/GLACIER cover 的反照率下限
    //            cover_snow_id (int, =1)          — CoverType.CV.SNOW 枚举值
    //            cover_glacier_id (int, =2)       — CoverType.CV.GLACIER 枚举值
    //     PackedArray（zero-copy read）：
    //            albedo_table : PackedFloat32Array — 按 VegetationType.VEG enum 顺序
    //
    //   读：cell_is_water (U8) / cell_vegetation (U8) / cell_cover (U8) / cell_temp (F32)
    //   写：cell_temp (F32)
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；< 0.0 → fallback。
    double run_albedo_pass(const godot::Dictionary &knobs);
    // ─── DOTS-Final-Push（plan/dots-final-push 任务 3）：vegetation dynamics ─
    //   GDScript 源：scripts/geography/map_generator.gd::_apply_vegetation_dynamics
    //   ClimateProfile flag：use_gdext_vegetation_dynamics
    //   性能目标：~9.2ms → < 1.0ms
    //
    //   算法分工（与 GDScript 1:1 镜像，但演替触发由 GDScript 后处理）：
    //     C++ 主循环（每 cell 独立）：
    //       if is_water[i]: continue
    //       compat = exp(-0.5 * ((t - ideal_t[v])/tol_t[v])² + ((m - ideal_m[v])/tol_m[v])²)
    //       dv = 0
    //       if v != NONE:
    //         if compat >= 0.6: dv = (compat - 0.5) * 2 * rate
    //         elif compat <= 0.4: dv = -(0.5 - compat) * 2 * rate * harshness
    //       wt = (weather_field_init[i] != 0) ? weather_type[i] : WT.CLEAR
    //       wi = (weather_field_init[i] != 0) ? weather_intensity[i] : 0
    //       base_pen = weather_penalty[wt]
    //       resist  = resistance_lut[v * n_wt + wt]
    //       dv -= base_pen * wi * (1 - resist)
    //       vitality[i] = clamp(vitality[i] + dv * scale, 0, 1)
    //       streak update（sticky in [low, high]）
    //       if low_streak[i] >= degrade_days && next_down[v] != v：候选 succession
    //       elif high_streak[i] >= upgrade_days && next_up[v] != v：候选 succession
    //
    //   入参 `knobs` Dictionary：
    //     标量： n_cells (int)
    //            day_scale (float)                 — max(day_scale, 1.0)
    //            streak_days (int)                 — round(scale)
    //            vitality_change_rate (float)
    //            compat_harshness (float)
    //            plant_water_balance_weight / plant_soil_buffer_weight (float)
    //            plant_drought_penalty / succession_min_compat_gain (float)
    //            low_threshold (float)
    //            high_threshold (float)
    //            succession_degrade_days (int)
    //            succession_upgrade_days (int)
    //            n_wt (int)                         — WeatherType.WT.size()
    //            wt_clear_id (int)                  — WeatherType.WT.CLEAR 枚举值
    //            veg_none_id (int)                  — VegetationType.VEG.NONE 枚举值
    //     PackedArray（zero-copy read）：
    //            ideal_temp_table  : PackedFloat32Array  (n_veg)
    //            ideal_moist_table : PackedFloat32Array  (n_veg)
    //            temp_tol_table    : PackedFloat32Array  (n_veg)
    //            moist_tol_table   : PackedFloat32Array  (n_veg)
    //            weather_penalty_table : PackedFloat32Array  (n_wt)
    //            resistance_table  : PackedFloat32Array  (n_veg * n_wt) — sparse 0.0 default
    //            next_up_table     : PackedByteArray     (n_veg)         — VEG.next_richer
    //            next_down_table   : PackedByteArray     (n_veg)         — VEG.next_harsher
	//     PackedArray（in/out — 仅老 caller 路径需要；B3b 后这 3 个字段已下沉到
	//     SoA schema：cell.vegetation_vitality / vitality_low_streak /
	//     vitality_high_streak。stage_b_pass 走 use_soa=true 时直读 _slots ptrw。
	//     该独立 wrapper 保留 PackedArray in/out 以保持向后兼容）：
	//            vitality_arr      : PackedFloat32Array  (n_cells)
	//            low_streak_arr    : PackedInt32Array    (n_cells)
	//            high_streak_arr   : PackedInt32Array    (n_cells)
	//
	//   读：cell_is_water (U8) / cell_vegetation (U8) / cell_temp_30d (F32) /
	//       cell_moisture / water_balance_30d / soil_moisture (F32) / cell_weather_type (U8) /
	//       cell_weather_intensity (F32) / cell_weather_field_init (U8)
	//   写：vitality_arr / low_streak_arr / high_streak_arr (in/out) /
	//       cell_vegetation_growth_pressure (target - previous vitality)
    //
    //   knobs 输出回填（C++ 写进 knobs）：
    //     succession_indices : PackedInt32Array  — 触发演替的 cell idx
    //     succession_to_veg  : PackedByteArray   — 与 indices 同长，目标新 veg id
    //                          上家：next_up[v]； 下家：next_down[v]（区分由 caller 看 streak 判断）
    //     stat_succession_count : int (写到 knobs)
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；< 0.0 → fallback。
    //   knobs 走 by-value（非 const&），让 C++ 端能写回 succession lists（与 sea_ice 同模式）。
    double run_vegetation_dynamics_pass(godot::Dictionary knobs);
    // ─── DOTS-Final-Push（plan/dots-final-push 任务 4）：climate feedback ─
    //   GDScript 源：scripts/geography/map_generator.gd::_apply_weather_to_map_feedback_pass
    //   ClimateProfile flag：use_gdext_climate_feedback
    //   性能目标：~6.1ms → < 0.5ms
    //
    //   算法（与 GDScript 1:1 镜像，每日小权重累加 ≤ 0.5%）：
    //     for each cell i:
    //       if is_water[i]: continue
    //       if ocean_drift_gain > 0:
    //         sum_an + n_water = sum/count(nb_water_anomaly)
    //         if n_water > 0 && |avg_an| > 0.005:
    //           coastal_ratio = clamp(n_water/6, 0, 1)
    //           d_base = clamp(ocean_drift_gain * avg_an * coastal_ratio * scale, -clamp, clamp)
    //           base_moisture[i] = clamp(base_moisture[i] + d_base, 0, 1)
    //       wt = init ? weather_type[i] : WT.CLEAR
    //       wi = init ? weather_intensity[i] : 0
    //       if wi < 0.01: continue
    //       precip = match(wt) {RAIN: wi, STORM: 0.8wi, MONSOON: 1.2wi,
    //                          BLIZZARD: 0.3wi, DROUGHT: -0.6wi, HEATWAVE: -0.4wi, _: 0}
    //       d_soil = clamp(soil_gain * precip * scale, -clamp, clamp)
    //       soil_moisture[i] = clamp(soil_moisture[i] + d_soil, -0.5, 0.5)
    //       d_veg = clamp(veg_gain * precip * scale, -clamp, clamp)
    //       vg_pressure[i] = clamp(vg_pressure[i] + d_veg, -0.5, 0.5)
    //
    //   入参 `knobs` Dictionary：
    //     标量： n_cells (int)
    //            soil_gain (float)
    //            veg_gain (float)
    //            write_weather_veg_pressure (bool, optional, default true)
    //            scale (float)              — max(day_scale, 1.0)
    //            per_day_clamp (float)      — feedback_per_day_clamp * scale
    //            ocean_drift_gain (float)   — 0 表示禁用 ocean→base 漂移
    //            wt_clear_id (int)          — WeatherType.WT.CLEAR
    //            wt_rain_id / wt_storm_id / wt_monsoon_id / wt_blizzard_id /
    //            wt_drought_id / wt_heatwave_id (int) — 6 个 WT 枚举值
	//     PackedArray（zero-copy read — 仅老 caller 路径需要；B3b 后已下沉到 SoA：
	//     cell.temperature_transport_anomaly。stage_b_pass 走 use_soa=true 时直读 _slots）：
	//            neighbor_indices       : PackedInt32Array    (n_cells * 6)
	//            temp_transport_anomaly : PackedFloat32Array  (n_cells)
	//                ↑ 与 climate_pass_b 同字段
	//     PackedArray（in/out — 仅老 caller 路径需要；B3b 后这 2 个字段已下沉到 SoA：
	//     cell.soil_moisture / cell.vegetation_growth_pressure。stage_b_pass 走
	//     use_soa=true 时直读 _slots ptrw。该独立 wrapper 保留 PackedArray in/out 以保持向后兼容）：
	//            soil_moisture_arr    : PackedFloat32Array  (n_cells)
	//            veg_growth_pressure_arr : PackedFloat32Array (n_cells)
    //
    //   读：cell_is_water (U8) / cell_weather_type (U8) /
    //       cell_weather_intensity (F32) / cell_weather_field_init (U8) /
    //       cell_base_moisture (F32) — direct write
    //       + 入参 PackedArray
    //   写：cell_base_moisture (F32) / soil_moisture_arr / veg_growth_pressure_arr (in/out)
    //       write_weather_veg_pressure=false 时保留 vegetation_dynamics 当 tick 写入的
    //       target-vitality 生态压力信号。
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；< 0.0 → fallback。
    double run_climate_feedback_pass(godot::Dictionary knobs);
    // ─── 方案 B：stage_b 三段合并（plan/stage-b-combine） ──────────────────
    //   GDScript 源：scripts/geography/map_generator.gd::refresh_daily_stage_b
    //   ClimateProfile flag：use_gdext_stage_b_combined
    //   性能目标：stage_b 累加 6–15ms → ≤ 1.5ms（消除 GDScript 端 3 次 pack/unpack
    //   围栏：vit/lo/hi、soil/vg/tta、albedo_table/8 LUT 一次性入参）
    //
	//   行为 = run_albedo_pass + run_vegetation_dynamics_pass +
	//         run_climate_feedback_pass 的顺序内联，**算法完全 1:1 复制**：
	//     ① albedo（写 cell_temp）→ 仅当 run_albedo=true
	//     ② veg_dyn（读最新 cell_temp + 写 vitality/streak/演替候选）→ 仅当 run_veg_dyn=true
	//     ③ feedback（写 cell_base_moisture / soil/vg in/out）→ 仅当 run_feedback=true
	//   cross-pass 依赖：albedo 写 cell_temp、veg_dyn 读 cell_temp，合并版本里
	//   两段共享同一份 SoA ptrw，**无需中间 _flush_slot_to_map**（对比现状 GDScript
	//   三段间需要 _flush_slot_to_map → MapData → refresh_slots_from_map 来回拷贝）。
	//
	//   B3b 数据所有权下沉（plan/b3b-data-ownership-lowering）：
	//     新增 `use_soa` 开关（bool，默认 false 兼容旧路径）。当 use_soa=true 时：
	//       - vit/streak/soil/vg/tta 五字段全部走 _slots[sid].arr_* ptrw 直读直写
	//       - knobs 中 vitality_arr / low_streak_arr / high_streak_arr /
	//         soil_moisture_arr / veg_growth_pressure_arr / temp_transport_anomaly
	//         可省略（即使存在也不读不写）
	//       - 末尾批量 flush 6 个 slot（vit/low_streak/high_streak/soil/vg）回 MapData
	//       - 消除 GDScript 端 6 段 pack/unpack hot loop（实测 ~6.5ms wall 节省）
    //
    //   入参 `knobs` Dictionary（合并版本，knobs key 命名空间用前缀避免冲突）：
	//     总开关：
	//       n_cells (int)
	//       run_albedo / run_veg_dyn / run_feedback (bool)  — stride 语义保留
	//       use_soa (bool, optional, default false)         — B3b 数据所有权下沉开关
    //
    //     albedo 段（仅 run_albedo=true 时读，其它情况可省略）：
    //       reference_albedo / albedo_temp_gain (float)
    //       snow_cover_albedo (float, =0.75)
    //       cover_snow_id / cover_glacier_id (int, =1, 2)
    //       albedo_table : PackedFloat32Array (n_veg)
    //
    //     veg_dyn 段（仅 run_veg_dyn=true 时读）：
    //       day_scale (float)
    //       streak_days (int)
    //       vitality_change_rate / compat_harshness (float)
    //       plant_water_balance_weight / plant_soil_buffer_weight (float)
    //       plant_drought_penalty / succession_min_compat_gain (float)
    //       low_threshold / high_threshold (float)
    //       succession_degrade_days / succession_upgrade_days (int)
    //       n_wt (int)
    //       wt_clear_id / veg_none_id (int)
    //       ideal_temp_table / ideal_moist_table / temp_tol_table /
    //       moist_tol_table : PackedFloat32Array (n_veg)
    //       weather_penalty_table : PackedFloat32Array (n_wt)
    //       resistance_table : PackedFloat32Array (n_veg * n_wt)
	//       next_up_table / next_down_table : PackedByteArray (n_veg)
	//       vitality_arr : PackedFloat32Array (n_cells, in/out) — 仅 use_soa=false 时必填
	//       low_streak_arr / high_streak_arr : PackedInt32Array (n_cells, in/out) — 仅 use_soa=false 时必填
    //
    //     feedback 段（仅 run_feedback=true 时读）：
    //       soil_gain / veg_gain / scale / per_day_clamp / ocean_drift_gain (float)
    //       write_weather_veg_pressure (bool, optional, default true)
    //       wt_rain_id / wt_storm_id / wt_monsoon_id /
    //       wt_blizzard_id / wt_drought_id / wt_heatwave_id (int)
	//       neighbor_indices : PackedInt32Array (n_cells * 6)
	//       temp_transport_anomaly : PackedFloat32Array (n_cells) — 仅 use_soa=false 时必填
	//       soil_moisture_arr : PackedFloat32Array (n_cells, in/out) — 仅 use_soa=false 时必填
	//       veg_growth_pressure_arr : PackedFloat32Array (n_cells, in/out) — 仅 use_soa=false 时必填
    //
    //   读：cell_is_water / cell_vegetation / cell_cover / cell_temp /
    //       cell_moisture / cell_weather_type / cell_weather_intensity /
    //       cell_weather_field_init / cell_base_moisture
    //   写：cell_temp（albedo）、cell_base_moisture（feedback）；in/out arrays
    //
	//   knobs 输出回填（C++ 写进 knobs）：
	//     albedo_ms / veg_dyn_ms / feedback_ms (float) — 每段单独 ms，供 caller 计时
	//     succession_indices : PackedInt32Array
	//     succession_to_veg  : PackedByteArray
	//     stat_succession_count : int
	//     vitality_arr / low_streak_arr / high_streak_arr (in/out 写回) — 仅 use_soa=false
	//     soil_moisture_arr / veg_growth_pressure_arr (in/out 写回) — 仅 use_soa=false
	//     注：use_soa=true 时这些字段直接 flush 到 SoA + MapData，无需 PackedArray 回写
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms 合计)；< 0.0 → fallback。
    //   knobs 走 by-value（非 const&），让 C++ 能写回 succession + ms breakdown。
    double run_stage_b_pass(godot::Dictionary knobs);
    // F.6 (P3): weather front advect (含 front pool 批量提取模式)
    //   GDScript 源：scripts/weather/weather_front.gd::advance_one_day +
    //                refresh_visual_lifecycle (line 74-127)
    //   ClimateProfile flag：use_gdext_weather_front
    //   性能目标：3.0ms → < 0.5ms（charter §7 P3）
    //   N=16 fronts，单线程足够
    //
    //   设计：fronts batch-extract 模式（Phase 1.2 / dots-full-migration §F.6）
    //     - WeatherFront.pack_into_dict(_active_fronts) 输出 SoA Dictionary
    //     - C++ pass(batch) 直接读写 batch 内 PackedArray
    //     - WeatherFront.apply_dict_to_fronts(batch, _active_fronts) 写回 OOP
    //     - emergent_coupling 的 decay_mul / precip_bonus 在 GDScript 端预算（map 查询），
    //       caller 在 pack 之前已经把 decay_per_day 改过；C++ 只看修改后的 decay。
    //     - wind 采样在 GDScript 端预算（一次 batch wind_per_front Vector2Array），
    //       Vector2.ZERO 表示该 front 无风（C++ 跳过旋转）。
    //
    //   入参 `knobs` Dictionary：
    //     标量： n_fronts (int)
    //            max_axis_turn_rad (float, =0.383972 = 22°/day)
    //     PackedArray（in/out — read 旧值，write 新值）：
    //            front_center_x / .._y       : F32 (n)  — write velocity 应用后
    //            front_velocity_x / .._y     : F32 (n)  — write 重算后
    //            front_axis_x / .._y         : F32 (n)  — write 旋转后
    //            front_stable_axis_x / .._y  : F32 (n)  — write 旋转后
    //            front_radius                : F32 (n)  — read only
    //            front_intensity             : F32 (n)  — write decay 后
    //            front_decay_per_day         : F32 (n)  — read（已含 emergent decay_mul）
    //            front_age_days              : I32 (n)  — write age++
    //            front_type                  : I32 (n)  — read only (refresh_visual_lifecycle 用)
    //            front_ttl_days              : I32 (n)  — read only (refresh_visual_lifecycle 用)
    //            front_life_progress         : F32 (n)  — write
    //            front_cloud_amount          : F32 (n)  — write
    //            front_precip_amount         : F32 (n)  — write
    //            front_dissolve_amount       : F32 (n)  — write
    //            front_alive                 : U8  (n)  — write (intensity > 0.01 && age < ttl)
    //            wind_per_front              : PackedVector2Array (n)
    //                ↑ caller 用 wind_fn(front.center) 预算；ZERO 表示无风
    //
    //   读：knobs 内的 PackedArray（CoW share with GDScript）
    //   写：knobs 内的 PackedArray（in-place via ptrw）；不动任何 _slots[]
    //
    //   返回：≥ 0.0 → C++ 接管完成 (=elapsed_ms)；< 0.0 → fallback
    //   bit-equal 容差：1e-5（含 sin / cos / smoothstep 链）
    //
    //   sig 设计：knobs 走 by-value（非 const&），与 F.4 同模式（让 C++
    //             直接修改 PackedArray ptrw，借 Dictionary refcount 共享）。
    double run_weather_front_advect_pass(godot::Dictionary knobs);
    godot::Dictionary run_season_refresh_stage(godot::Dictionary knobs);
    godot::Dictionary run_season_refresh_micro_pass(godot::Dictionary knobs);
    // ─── Phase B+：season refresh round 一次跨界整 round 切片调度 ──────────
    // 与 run_season_refresh_stage 协作（B+ 路径下 run_season_round_slice 内部
    // 直接复用 run_season_refresh_stage 的 stage dispatch，零算法复制）。
    //
    // 用法（GDScript caller）：
    //   handle = ext.start_season_round(round_knobs)         # round 起始（一次烘焙 row tables / jitter / donor）
    //   while not done:
    //       slice = ext.run_season_round_slice(handle, max_usec)  # 每 SUS slot 调一次，b1=stage 边界粒度
    //       done = slice.done
    //   fin = ext.finish_season_round(handle)                # GDScript 拿 fin 后做一次 facade sync + history push
    //
    // round_knobs（一次塞齐 12 个 stage 所需的全部字段，B+ 内部按 stage 取用）：
    //   "season"               : int    (0..3)
    //   "n_cells"              : int
    //   "height"               : int
    //   "sea_level"            : float
    //   "moist_scale"          : float                       # stage 0
    //   "rain_shadow_lookback" : int                         # stage 1
    //   "rain_shadow_threshold": float                       # stage 1
    //   "rain_shadow_factor"   : float                       # stage 1
    //   "season_phase"         : float                       # stage 1
    //   "elev_decay"           : float                       # stage 4
    //   "decay"                : float                       # stage 11 (=feedback decay)
    //   "lat_temp_rows"        : PackedFloat32Array          # stage 2/4/9
    //   "season_offset_rows"   : PackedFloat32Array          # stage 2/9 (=sync_state)
    //   "row_indices"          : PackedInt32Array            # stage 2/3/4/5/6/7/swamp
    //   "neighbor_indices"     : PackedInt32Array            # stage 1/4/5/6/7/swamp
    //   "jitter_arr"           : PackedFloat32Array          # stage 1
    //   "donor_table"          : PackedFloat32Array          # stage 4
    //   "soil_moisture_arr"    : PackedFloat32Array (in/out) # stage 11
    //   "veg_growth_pressure_arr": PackedFloat32Array (in/out) # stage 11
    //
    // start_season_round 返回：
    //   { "handle": int (>=0 成功，<0 fallback), "fallback": bool, "reason": String }
    // run_season_round_slice 返回：
    //   { "done": bool, "stage": int (当前 round_stage 0..11),
    //     "stages_done_this_slice": int, "elapsed_ms": float,
    //     "fallback": bool, "reason": String }
    // finish_season_round 返回：
    //   { "total_native_ms": float, "slices_used": int, "stages_done": int,
    //     "soil_moisture_arr": PackedFloat32Array (decayed, write-back to map),
    //     "veg_growth_pressure_arr": PackedFloat32Array (decayed, write-back to map) }
    // abort_season_round：清 round state，让 generation +=1 让悬挂 handle 失效。
    godot::Dictionary start_season_round(godot::Dictionary round_knobs);
    godot::Dictionary run_season_round_slice(int handle, int max_usec);
    godot::Dictionary finish_season_round(int handle);
    void abort_season_round();
