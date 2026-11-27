// Physical climate raster output and field validation declarations.

    // ─── DOTS-Total-CPP（plan/dots-total-cpp 任务 4）─────────────────────
    // run_ocean_field_rasterize：ocean current + upwelling 一次性 hex→pixel byte 直出。
    //
    // GDScript 源：scripts/rendering/map_baker.gd::_rasterize_ocean_current_slice_from_hex
    //               + _rasterize_upwelling_slice_from_hex
    //
    // ClimateProfile flag：use_gdext_ocean_currents_pixel（默认 false，需求 8.5 验收后开）
    //
    // 性能目标：消除 ocean_currents 17 个 GDScript pixel slice（25ms slow slice），
    //           620544 像素一次性 C++ loop ≤ 5ms。
    //
    //   入参 `knobs` Dictionary：
    //     标量：n_cells (int), w (int), h (int), update_atlas_data (bool)
    //     可选标量：start_idx (int, 默认 0), end_idx (int, 默认 W*H)
    //               — 像素区间 [start_idx, end_idx)，用于 sub-tick 切片
    //                 把 4.7ms 整图 raster 拆成 N 片 ~1.2ms（每像素独立无依赖）
    //     PackedArray：
    //           pixel_to_cell_idx : PackedInt32Array (W*H)，每像素对应 cell index 或 -1
    //           dst_currents      : PackedByteArray  (W*H*2)，输出 R+G byte
    //           dst_upwelling     : PackedByteArray  (W*H*1)，输出 byte
    //           atlas_data        : PackedByteArray  (W*H*4)，可选；若 size 匹配则同步更新
    //   读：cell_terrain / cell_ocean_current_x / cell_ocean_current_y /
    //       cell_upwelling_strength SoA
    //   写：dst_currents / dst_upwelling / atlas_data（in/out via knobs ptrw）
    //   返回 Dictionary：{ "elapsed_ms", "fallback", "reason", "pixels",
    //                     "atlas_updated", "start_idx", "end_idx" }
    godot::Dictionary run_ocean_field_rasterize(godot::Dictionary knobs);
    // ─── DOTS-Total-CPP（A 方案 / wind raster 孪生）─────────────────────
    // run_wind_field_rasterize：wind_x / wind_y SoA → hex→pixel byte 直出。
    //
    // GDScript 源：scripts/rendering/map_baker.gd::_rasterize_wind_slice_from_hex
    //               (Stage 7 _PHYS_STAGE_WIND_RASTER 内部循环)
    //
    // ClimateProfile flag：复用 use_gdext_ocean_currents_pixel（孪生场景：
    //                       同样的 hex→pixel byte rasterize，无需新 flag）
    //
    // 性能目标：消除 ocean_currents 21 片 × 87ms 的 wind raster GDScript 循环。
    //           620544 像素一次性 C++ loop ≤ 5ms。
    //
    //   入参 `knobs` Dictionary：
    //     标量：n_cells (int), w (int), h (int), update_atlas_data (bool)
    //     PackedArray：
    //           pixel_to_cell_idx : PackedInt32Array (W*H)，每像素对应 cell index 或 -1
    //           dst_wind          : PackedByteArray  (W*H*2)，输出 wx/wy byte
    //           atlas_data        : PackedByteArray  (W*H*4)，可选；若 size 匹配则同步写 [+2]/[+3]
    //   读：cell_wind_x / cell_wind_y SoA
    //   写：dst_wind / atlas_data[i*4+2..+3]（in/out via knobs ptrw）
    //   返回 Dictionary：{ "elapsed_ms", "fallback", "reason", "pixels", "atlas_updated" }
    //
    //   ⚠️ 与 ocean 行为差异：cell idx 无效（lookup 缺失或 -1）时，wx 默认 1.0、wy 默认 0.0
    //                          （与 GDScript _rasterize_wind_slice_from_hex 严格 1:1）。
    godot::Dictionary run_wind_field_rasterize(godot::Dictionary knobs);
    // ─── DOTS-Total-CPP（A 方案 / phys nan_guard 孪生）─────────────────────
    // phys_field_nan_guard：扫 cell_wind_{x,y,speed} / cell_ocean_current_{x,y}
    // / cell_upwelling_strength 这 6 个 SoA，统计 NaN/Inf 数量。
    //
    // GDScript 源：scripts/rendering/map_baker.gd::_physical_solve_step_one
    //   _PHYS_STAGE_WIND_RASTER 第一帧的 `for c in map.all_cells(): is_finite()`
    //   循环（2400 cell × 6 字段 ≈ 22ms），是 phys_wind_raster slice 的最大头。
    //
    // 这里直接读 _slots 里的 PackedFloat32Array.ptr() 顺序扫，编译器
    // 会自动向量化成 AVX2 SIMD（_mm256_cmp_ps NaN+Inf 检测），目标
    // < 0.1ms（2400 cell × 6 ≈ 56KB 顺序读）。
    //
    // 返回 int：bad cell 数（任一字段 NaN/Inf 即 +1，不重复计数）。
    // -1 表示 SoA size mismatch / slot 缺失（GDScript 应回落到原慢路径）。
    int phys_field_nan_guard();
