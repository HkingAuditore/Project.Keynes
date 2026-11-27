// World generation, resource initialization, and bake encoders.

    // ---- bindings: generation ----
    godot::Dictionary run_native_world_generate_base_pass(int seed,
                                                          const godot::Dictionary &cfg,
                                                          const godot::Dictionary &profile);
    godot::Dictionary run_native_world_generate_post_base_pass(int seed,
                                                               const godot::Dictionary &cfg,
                                                               const godot::Dictionary &profile,
                                                               const godot::Dictionary &input);
    // dots-total-cpp step4（2026-06-25）：base + post_base 融合单次驱动。
    // 在 C++ 进程内先跑 base、再用其结果跑 post_base，base 的 10×n_cells SoA bundle
    // 留在 C++、不出语言边界（原先 base 结果要 C++→GDScript 校验→再回 post_base）。
    // 返回 post_base 最终 bundle（合并 base 诊断键 base_water_count/base_land_count/
    // base_native_ms/native_algorithm 供 GDScript 打印）。base 失败 → 直接回传 base 结果
    // （rc/fallback 透传，caller 据此中止）。
    godot::Dictionary run_native_world_generate_full_pass(int seed,
                                                          const godot::Dictionary &cfg,
                                                          const godot::Dictionary &profile);
    // PKMAP 旁路：从冻结合成结果填 `_gen_river_*`，邻居用 index_for_qr 现场重建。
    // 跳过 post_base 读包时必须调用，否则 run_bake_river_sdf_pass 无河。
    godot::Dictionary restuff_generation_river_cache(const godot::Dictionary &input);
    // Static, generation-only research evidence. Input/output are packed arrays;
    // no MapData/Object access or per-cell Variant allocation occurs in the loop.
    godot::Dictionary run_research_signal_generation_pass(const godot::Dictionary &knobs);
    // 生成期自然资源矿藏储量（O(资源 × cell) 的适宜度扫描 + 排名分配）。
    // 逐行复刻 map_generator.gd `_bootstrap_natural_resource_deposits()`：
    // 输入是 cell SoA + 每种资源的参数表，输出每种资源一条 reserve Float32 列。
    // 噪声用 GDScript 建好的 Ref<Noise> 传入，保证与旧路径同值。
    godot::Dictionary run_resource_deposit_pass(const godot::Dictionary &knobs);
    godot::Dictionary run_native_world_generate_pass(int seed,
                                                     const godot::Dictionary &cfg,
                                                     const godot::Dictionary &profile);
    godot::Dictionary start_native_generation(int seed,
                                              const godot::Dictionary &cfg,
                                              const godot::Dictionary &profile);
    godot::Dictionary run_native_generation_slice(const godot::Dictionary &budget);
    godot::Dictionary finish_native_generation();
    // ─── Natural resources（economy.resources）──────────────────────────
    //   GDScript wrapper：MapGenerator.run_natural_resource_pass_native
    //   System：NaturalResourceDailySystem（每日，priority 排在 climate 之后）
    //
    //   默认资源使用半隐式（IMEX）常数生产 + 线性损失模板：
    //     tn            = clamp((temp - temp_lo[r]) / (temp_hi[r] - temp_lo[r]), 0, 1)
    //     m             = moisture
    //     gen_climate   = gen_base[r]   + gen_temp[r]*tn   + gen_moisture[r]*m
    //     decay_climate = decay_base[r] + decay_temp[r]*tn + decay_moisture[r]*m
    //     P             = gen_climate + gen_self[r] - decay_climate
    //     L             = max(0, decay_self[r])
    //     reserve'      = max(0, (reserve + P) / (1 + L))
    //   ecology_capacity[r] > 0 的种群资源走 Beverton-Holt 密度增长：适生度缩放
    //   承载量/增长/迁入，超过承载量时自然下降，气候压力增加比例死亡。多日 stride
    //   逐日迭代非线性式；extra_change 始终只应用一次。
    //
    //   knobs（GDScript 一次打包，ResourceProfileRegistry.build_pass_knobs + n_cells）：
    //     标量： n_cells (int), resource_count (int)
    //     PackedStringArray： reserve_slots（C++ slot 名，长度 resource_count）
    //     PackedFloat32Array（长度 resource_count，按资源索引对齐）：
    //       habitat_modes, temp_lo, temp_hi,
    //       gen_base/gen_temp/gen_moisture/gen_self,
    //       decay_base/decay_temp/decay_moisture/decay_self,
    //       ecology_capacity/ecology_growth_rate/ecology_immigration/
    //       ecology_stress_mortality_rate
    //
    //   读：cell_temp / cell_moisture / cell_is_water
    //   写：每个 reserve_slots[r]（clamp 后 flush 回 MapData）
    //
    //   返回 Dictionary：{ done, path, published_to_slot, published_slots,
    //     resource_count, n_cells, total_delta, native_ms, compute_ms,
    //     fallback_reason（失败时）}。
    godot::Dictionary run_natural_resource_pass(const godot::Dictionary &knobs);
    godot::Dictionary get_natural_resource_regen_factors(
        const godot::PackedStringArray &resource_ids, int32_t n_cells);
    // cpp-dots（temp-baseline-authority-2026-06）：cell_temp_baseline_year 的权威 C++ 烘焙。
    // 海冰 + 显示温度的运行期 baseline 原由 GDScript map_data.bake_lat_temp_year_lut 就地
    // pow(cos,..) 烤出来再推给 slot——仿真量权威落在 GDScript。本 pass 用唯一 C++ 实现
    // pk_lat_temp_bell 从 knobs["lat_norm"]（ny∈[0,1] 几何量）算 baseline，写
    // cell_temp_baseline_year slot 并 _flush_slot_to_map 回 MapData。GDScript 自烤改为 fallback。
    godot::Dictionary run_temp_baseline_year_bake(godot::Dictionary knobs);
    // 生成期 height/biome/moisture/veg/cover 逐像素烘焙。
    // 离散数据使用硬主 cell；另产出副 cell RG8 + 边界距离 R8 供屏幕空间边缘混合。
    // 复刻 map_baker.gd::_bake_height_biome_moisture；产出 7 buffer + CSR + pixel_to_cell_index。
    godot::Dictionary run_bake_terrain_index_pass(godot::Dictionary knobs);
    // ─── 生成期 per-pixel 几何场 buffer-encoder（dots-total-cpp 续，2026-06-25）────
    // 纯 buffer-encoder：不读 _slots / 不要求 _bound，全部输入由 knobs PackedArray 喂入
    // （同 encode_bake_* / run_bake_terrain_index_pass 范式，bake 期 bind 时机不定）。
    // GDScript 只发请求 + 收结果，O(n_pixels) 热循环全部在 C++。
    //
    // run_bake_latitude_field_pass：复刻 map_baker.gd::_bake_latitude_buffer。逐像素
    //   ny = y / max(H-1,1)。输入 w/h。输出 latitude_buffer(F32 PackedFloat32Array)。
    godot::Dictionary run_bake_latitude_field_pass(godot::Dictionary knobs);
    // run_bake_river_sdf_pass：复刻 map_baker.gd::_bake_river_sdf 的**全部计算**——
    //   河流图遍历（trace，读 post_base 暂存的 `_gen_river_*` ext 拓扑）+ 连续经度展开 +
    //   Catmull-Rom 致密化 + warp 噪声（FastNoiseLite 复刻 _warp_noise_lo/hi）+ 变宽 polyline
    //   stamp + chamfer 3-4 双通 SDT + 归一化 [0,1] flow。**无任何河流链/拓扑跨语言传入**：
    //   GDScript 只传 bake 几何参数，C++ 直接读自己暂存的拓扑 trace（零再传输）。
    //   前置：必须先调用 run_native_world_generate_post_base_pass（填 `_gen_river_*`）。
    //   输入 w/h/origin_x/origin_y/inv_world_x/inv_world_y/hex_size/seed/base_radius_px/
    //   sdf_max_dist_px/cr_step/wrap_period_x。输出 out_buf(F32 PackedFloat32Array，= world.flow_buffer)。
    godot::Dictionary run_bake_river_sdf_pass(godot::Dictionary knobs);
    // run_bake_erosion_pass：复刻 map_baker.gd::_hydraulic_erosion。droplet 水力侵蚀，
    //   用 Ref<RandomNumberGenerator>（同 seed 复刻 baker _rng PCG）逐滴随机起点/方向。
    //   in/out height buffer，内部 clamp [0,1]。输入 w/h/height_buffer（PackedFloat32Array）/seed +
    //   num_drops/max_steps/inertia/capacity_factor/min_capacity/deposit_speed/erode_speed/
    //   evaporation/gravity/brush_radius。输出 height_out(F32 PackedFloat32Array)。
    godot::Dictionary run_bake_erosion_pass(godot::Dictionary knobs);
    // run_bake_erosion_spl_pass（terrain-erosion-spl，2026-11-18）：SPL 汇流侵蚀管线的
    //   buffer-encoder 入口，只给测试 / A-B probe 喂合成高度场；**生产**走
    //   run_bake_geometry_fields_pass 的 dem_erosion_mode = spl / spl+carve 分支——两者共用
    //   world_ext_bake.cpp 内的同一份 pk_run_erosion_spl_pipeline（算法只一处，不复制）。
    //   模式语义（契约 §3.1，已裁决）：
    //     carve     = 现状全序（汇流刻谷 + droplet），height_buffer 逐位不变 → hash 门禁的回退基线；
    //     spl       = 只跑 SPL 管线（建树 → 隐式下切 → [沉积/谷底展宽] → 限坡），不跑 carve、不跑 droplet；
    //     spl+carve = SPL 管线 + 浅刻谷（carve 深度 × dem_spl_carve_scale），不跑 droplet；
    //     droplet   = 仅 droplet（历史对照）。
    //   **C++ 缺省恒 "carve"**（dem_erosion_mode 缺省）：Project/perf-validation 加载同一 DLL 但不传
    //   该 knob → 行为逐位不变（计划 §12 Q5）。
    //   入参 knobs：
    //     width / height；height_buffer(PackedFloat32Array，入口高度) /
    //     relief_buffer(PackedFloat32Array，局地起伏，0 = 平原) /
    //     wet_buffer(PackedByteArray，1 = 水体或河心像素 → 汇流出口，不参与下切/限坡)；
    //     sea_level；hex_px（缺省时由 size_x + hex_size 反推）；wrap_cols（0 = 不环绕，>2 时前
    //     wrap_cols 列为经线周期，其后列是 x-wrap_cols 的别名）+ 全部 dem_* knob
    //     （dem_erosion_max_dim、dem_spl_iters/k/m/min_area_hex、dem_slope_limit_*、
    //      dem_crest_round、dem_dep_*/dem_floor_*、dem_spl_carve_scale、dem_erosion_pit_audit）。
    //     本 pass 只按 spl / spl+carve 解释 dem_erosion_mode（其余值按 spl 处理）。
    //   单位：除 dem_erosion_max_dim（像素）与各 ms 外，所有长度/面积参数以 hex 为单位（计划 §4.2），
    //     因此 512 / 1024 / 2048 三档平台宏观形态一致；迭代次数只按分辨率分档。
    //   出参：fallback=false、path="gdext"、height_out(F32)、width/height、erosion_mode、
    //     erosion_grid_w/h/factor、flow_ms/spl_ms/dep_ms/limit_ms/carve_ms/upsample_ms、
    //     fill_ms/mfd_ms/wall_ms（仅 spl+carve 的浅刻谷）、spl_iters_effective、spl_p99_drop、
    //     spl_max_drop、eroded_vol、deposited_vol、spl_sea_clamped、spl_nan、pits_in、pits_out、
    //     elapsed_ms、reason（契约 §3.3/§3.4，未执行项 = -1）。
    //   失败（尺寸不符 / 缓冲缺失 / 栅格退化）→ fallback=true + reason，**不** push_error
    //     （供测试与融合 pass 作判据）。
    //   不变量（计划 §3.2）：h ≤ h_pre、陆地 ≥ sea_level + 5e-4、水体/河心像素逐位不变、
    //     deposited_vol ≤ eroded_vol、同 knobs 同分辨率逐位可复现（串行、无 RNG、无时间依赖）。
    godot::Dictionary run_bake_erosion_spl_pass(godot::Dictionary knobs);
    // run_bake_geometry_fields_pass（dots-total-cpp step2，2026-06-25）：bake 期几何场编排
    //   下沉 C++ 的单次驱动。GDScript 只发一次请求（一个 knobs Dictionary 含 terrain-index
    //   所需 cell SoA + 几何参数 + erosion 常量），C++ 在进程内依次串起已验证的
    //   terrain-index → erosion → river SDF → latitude sub-pass，中间 buffer
    //   （尤其 height_buffer）全部留在 C++、不跨语言往返；一次返回完整几何 bundle。river 读
    //   post_base 暂存的 `_gen_river_*` 拓扑（零再传输），故前置仍需先跑 post_base。
    //   输出合并 bundle：height_buffer/biome_buffer/moisture_buffer/vegetation_buffer/
    //   cover_buffer（terrain）+ flow_buffer（river out_buf）+ latitude_buffer +
    //   CSR（cell_first_px/cell_px_count/flat_px_indices）+ pixel_to_cell_index +
    //   total_px + width/height + 各 stage 的 *_elapsed_ms 诊断。
    //   terrain sub-pass 失败 → 整体 fallback=true（caller 回退旧 per-pass / GDScript 路径）；
    //   erosion sub-pass 失败 → 用未侵蚀 height 续算（非致命），不令整体 fallback。
    //   [terrain-erosion-spl 2026-11-18] 其中「①b 刻谷 + ② 液滴侵蚀」这一段按 knobs
    //   dem_erosion_mode 分支（契约 §3.1，语义与 run_bake_erosion_spl_pass 的注释相同）：
    //     carve = 现状全序（刻谷 + droplet），height_buffer 逐位不变；spl* = 走 SPL 管线，
    //     不跑 carve/droplet；droplet = 仅 droplet。**缺省恒 carve**（不传 knob → 逐位不变）。
    //   侵蚀分项只增不改（契约 §3.4）：erosion_mode / erosion_grid_w|h|factor /
    //     flow_ms|spl_ms|dep_ms|limit_ms|carve_ms|upsample_ms / fill_ms|mfd_ms|wall_ms /
    //     spl_iters_effective|spl_p99_drop|spl_max_drop|eroded_vol|deposited_vol /
    //     spl_sea_clamped|spl_nan|pits_in|pits_out / erosion_reason，未执行项 = -1。
    godot::Dictionary run_bake_geometry_fields_pass(godot::Dictionary knobs);

    // ---- bindings: bake_encoders ----
    // ─── Bake-time static texture encoders（map encoder C++ 迁移）──────────
    // GDScript 仍负责 Image/ImageTexture 创建与 update；C++ 只做逐像素 byte payload。
    // 返回统一 Dictionary：{ fallback, reason, path, elapsed_ms, data, width, height, format }。
    godot::Dictionary encode_bake_height_tex_data(godot::Dictionary knobs);      // F32 [0,1] → RG8
    godot::Dictionary encode_bake_terrain_normal_tex_data(godot::Dictionary knobs); // F32 height → RG8 粗法线(nx,ny)
    godot::Dictionary encode_bake_horizon_tex_data(godot::Dictionary knobs);      // F32 height → RGBA8 packed 8-dir horizon
    godot::Dictionary encode_bake_r8_tex_data(godot::Dictionary knobs);          // U8 → L8，default_byte 可选
    godot::Dictionary encode_bake_flow_tex_data(godot::Dictionary knobs);        // F32 [0,1] → L8
    godot::Dictionary encode_bake_enum_atlas_payload(godot::Dictionary knobs);   // map_index RGBA8
    godot::Dictionary encode_bake_upwelling_tex_data(godot::Dictionary knobs);   // SoA upwelling → L8
