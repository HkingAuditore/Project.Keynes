// Map atlas, overlays, and visual instancing declarations.

    // ---- bindings: visual ----
    godot::Dictionary bake_trade_visual_paths(const godot::Dictionary &snapshot,
                                              int map_width, double hex_size) const;
    // Numeric 2.5D building chunk baker. The Godot side supplies only flat
    // chunk-local PackedArrays; C++ returns MultiMesh-ready 16-float buffers.
    godot::Dictionary bake_building_visual_chunk(godot::Dictionary knobs);
    godot::Dictionary configure_vision_research(const godot::Dictionary &config);
    godot::Dictionary get_runtime_vision_frame(int64_t after_revision) const;
    godot::Dictionary set_runtime_fog_enabled(bool enabled);
    godot::Dictionary submit_player_confirmation(const godot::String &action, int64_t value,
                                                 int64_t effective_day);
    godot::Dictionary run_vision_research_pass(const godot::Dictionary &knobs);
    godot::Dictionary filter_bio_research_observations(
        const godot::PackedInt32Array &cells,
        const godot::PackedInt32Array &signals) const;
    godot::Dictionary run_sea_ice_atlas_prepare(godot::Dictionary knobs);
    godot::Dictionary patch_enum_atlas_axes(godot::Dictionary knobs);
    // High-resolution visual-only tile. The low-resolution geometry remains
    // authoritative; this pass never creates high-resolution pixel CSR data.
    godot::Dictionary run_bake_visual_tile_layer_pass(godot::Dictionary knobs);
    // Native fallback for tiled horizon publication. Resamples one physical
    // tile (including gutters) from the authoritative low-resolution RGBA8
    // horizon without introducing a GDScript per-pixel loop.
    godot::Dictionary run_resample_visual_horizon_layer_pass(godot::Dictionary knobs);
    // ─── Dirty-Push Atlas Encode (plan/dirty-push-atlas-encode 阶段 F) ────
    // 4 张运行期 atlas baker 的 byte-fill 阶段下沉 C++/SIMD：
    //   encode_dynamic_cell_atlas：RGBA8。R=q01(temp), G=q01(moist),
    //     B=q01(snow), A = passable_sea ? 0 : q01(vitality)。镜像
    //     map_baker.gd::_dynamic_cell_signature + dynamic_cell_atlas_chunk_step。
    //   encode_ecology_visual_atlas：RGBA8。R=q01(foliage), G=q01(stress),
    //     B=transition_age, A=q01(growth_damage)。需要持久状态：
    //     prev_veg / prev_vitality_byte / prev_transition_age（per-cell byte 数组），
    //     由 GDScript 端按 cell_indices 顺序传入并由 C++ 端写出新值（同长度）返回。
    //     镜像 _ecology_visual_signature + ecology_visual_atlas_chunk_step。
    //   encode_dyn_smooth_atlas：RGBA8。中心 sig 0.5 + ≤6 邻居均值 0.5 → q01。
    //     需要 neighbor_indices PackedInt32Array（长度 n_cells*6，越界为 -1，
    //     与 run_physical_circulation_pass 同构）。镜像 dyn_atlas_smooth_chunk_step。
    //   encode_ice_state_atlas：R8。byte = sea_ice_frac > 0 ? max(1, ceil(*255)) : 0。
    //     仅水域写非零，由 GDScript 端在 cell_indices 中只放水域 dirty cell。
    //     镜像 ice_state_atlas_chunk_step（含 _q01_byte_ice）。
    //
    // ClimateProfile flag：cpp_atlas_encode_enabled（默认 false）。
    //
    // 共享 CSR 协议（所有 4 个 method 通用）：
    //   knobs Dictionary 入参：
    //     "n_pix"            : int      （= W*H）
    //     "stride_bytes"     : int      （RGBA=4，R8=1）
    //     "atlas_buffer"     : PackedByteArray（长度 n_pix * stride_bytes，C++ 端 ptrw 直写）
    //     "cell_indices"     : PackedInt32Array（dirty cell SoA idx 数组，长度 K）
    //     "cell_first_px"    : PackedInt32Array（长度 K，CSR row-ptr：第 i 个 cell 在 flat_px_indices 起始）
    //     "cell_px_count"    : PackedInt32Array（长度 K，第 i 个 cell 的像素数）
    //     "flat_px_indices"  : PackedInt32Array（长度 = sum(px_count)，所有像素 idx 顺序拼接）
    //     "cell_is_water"    : PackedByteArray（长度 K，0/1；dynamic / dyn_smooth pass 必需）
    //                          语义：is_water = not passable_land（含 SEA_ICE/LAKE 等所有水域）
    //     # ecology pass 额外：
    //     "prev_veg"         : PackedByteArray（长度 K）
    //     "prev_vitality"    : PackedByteArray（长度 K）
    //     "prev_transition"  : PackedByteArray（长度 K）
    //     "cache_valid"      : bool（false 时 transition_age 强制清 0）
    //     # dyn_smooth pass 额外：
    //     "neighbor_indices" : PackedInt32Array（长度 n_cells * 6，-1 表示越界邻居）
    //     "neighbor_is_water": PackedByteArray（长度 K * 6，按 cell_indices 顺序对每个邻居打包 is_water）
    //
    // 返回 Dictionary：
    //   "elapsed_ms"     : double（C++ 端 hot loop 耗时）
    //   "fallback"       : bool（true 表示参数非法 / 槽位缺失，调用方应走 GDScript 路径）
    //   "reason"         : String（fallback 时的理由）
    //   "pixels_written" : int（实际写入的像素数）
    //   "atlas_buffer"   : PackedByteArray（直写后的 buffer；GDScript 端取回赋给 world.*_buffer）
    //   # ecology 额外返回：
    //   "new_veg"        : PackedByteArray（长度 K，本 tick 写回 _last_ecology_veg_bytes）
    //   "new_vitality"   : PackedByteArray（长度 K）
    //   "new_transition" : PackedByteArray（长度 K，本 tick 写回 _ecology_transition_age_bytes；调用方须按 erase if==0 维护 _eco_active_decay_set）
    //   "new_sigs"       : PackedInt32Array（长度 K，写回 _last_ecology_visual_sigs；dynamic/smooth/ice 也返回，写回各自 _last_*_sigs）
    //
    // 失败模式（fallback=true）：n_pix<=0、CSR 数组长度不匹配、SoA slot 缺失或大小不够、
    // atlas_buffer 大小不匹配 stride*n_pix。
    godot::Dictionary encode_dynamic_cell_atlas(godot::Dictionary knobs);
    godot::Dictionary encode_ecology_visual_atlas(godot::Dictionary knobs);
    godot::Dictionary encode_dyn_smooth_atlas(godot::Dictionary knobs);
    godot::Dictionary encode_ice_state_atlas(godot::Dictionary knobs);
    // ─── Debug Data Overlay Atlas Encode (plan/debug-overlay-perf v2, 2026-06-12) ──
    // data_overlay_baker.gd 的 O(n_pixels) pixel fan-out 下沉 C++（debug 模式
    // 温度/天气等 overlay 卡顿主因之一）。GDScript 端仍负责 18 个 overlay mode
    // 的 per-cell 采样（仅 ~n_cells 次，分支重、含 latitude_buffer / atan2 /
    // 非 schema 字段，留 GDScript 最稳、零 bit-divergence 风险），把每个 cell
    // 编码后的 R/G byte + 有效标记打包成 per-cell 数组传入；本方法负责把每个
    // 有效 cell 的 (R, G, 0, 255) 扇出写到它覆盖的全部像素（典型 ~62 万次写），
    // 并先 memset 清零（无效/未覆盖像素 alpha=0）。
    //
    // 复用 WorldData 持久 SoA CSR（cell_first_px_arr / cell_px_count_arr /
    // flat_px_indices_arr，按 cell.index 索引，整图一次性构建），零大数组拷贝。
    // 与 encode_dynamic_cell_atlas 等共用 flat_px 复用语义（first/count 直接索
    // 引整图 flat，不要求紧凑串接）。
    //
    // 不依赖 _bound / _slots —— overlay 数据全部由 GDScript 预采样喂入，因此即
    // 便 climate slot 未绑定（或地图刚生成）也能工作。
    //
    // knobs:
    //   "n_pix"           : int  (= W*H)
    //   "n_cells"         : int  (= cell_first_px / cell_r / cell_g / cell_valid 长度)
    //   "atlas_buffer"    : PackedByteArray (n_pix*4，RGBA8，C++ ptrw 直写)
    //   "cell_first_px"   : PackedInt32Array (n_cells；world.cell_first_px_arr，-1=空)
    //   "cell_px_count"   : PackedInt32Array (n_cells；world.cell_px_count_arr)
    //   "flat_px_indices" : PackedInt32Array (整图 flat；world.flat_px_indices_arr)
    //   "cell_r"          : PackedByteArray (n_cells；按 cell.index 的 R byte)
    //   "cell_g"          : PackedByteArray (n_cells；G byte)
    //   "cell_valid"      : PackedByteArray (n_cells；0/1，0=该 cell 不写像素)
    //
    // 返回:
    //   "elapsed_ms"     : double（hot loop 耗时）
    //   "fallback"       : bool（true=参数非法，调用方走 GDScript fan-out）
    //   "reason"         : String
    //   "pixels_written" : int
    //   "atlas_buffer"   : PackedByteArray（直写后的 buffer，调用方取回上传纹理）
    godot::Dictionary encode_overlay_atlas(godot::Dictionary knobs);
    // ─── plan/atlas-pipeline-cpp（2026-05-20）：4 张 atlas 全管线主入口 ─────
    // dynamic_visual_atlas_upload_system 每帧热路径整套搬到 C++：dirty 消费 →
    // 4 张 atlas value-diff（per-atlas prev_sigs snapshot 兜底 dirty 语义 bug）
    // → 1-跳邻居膨胀（smooth 用）→ CSR 打包 → 4 张 atlas encode → 4-phase 调
    // 度节流。GD 端薄壳每 tick 只调一次本入口，拿 atlas_buffers Dict 后做
    // 4 次 ImageTexture.update。
    //
    // opts (Dictionary 输入):
    //   "world"            : Object（DCWorld 实例，必填）
    //   "soft_budget_us"   : int（本 tick 软预算，C++ 内部每 phase / chunk 边界检查；默认 1500）
    //   "max_cells"        : int（本 tick 最多处理 cell 数；默认 4096）
    //   "enable_diag"      : bool（开则填 12 个 ms_* 字段；默认 false）
    //   "encode_knobs_*"   : Dictionary（4 个 atlas 的 encode 旋钮，转发给内部 encode_*）
    //
    // 返回 (Dictionary):
    //   "done"             : bool（true 表示本 stride 4 phase 全部完成）
    //   "phase"            : int（当前 phase 枚举，0=IDLE..5=DONE）
    //   "cursor"           : int（当前 phase 内 cursor，调试用）
    //   "atlas_buffers"    : Dictionary { "dyn"/"eco"/"smo"/"ice" : PackedByteArray }（仅 finalize 阶段含）
    //   "stride_real"      : Dictionary { 4 个 atlas 的真·变化 cell 数 }
    //   "ms_breakdown"     : Dictionary（12 个 phase 细分时间，enable_diag=true 才填）
    //
    // 与现有 encode_* 关系：本方法在内部直接复用 4 个 encode_* 函数体，prev_sigs
    // 从 AtlasPipelineState::prev_sigs_* 读取，无需 GD 端来回传 snapshot。
    godot::Dictionary run_atlas_pipeline_step(godot::Dictionary opts);
    // 地图重生成 / map_regenerate 时调，使 AtlasPipelineState::csr_cache 与
    // prev_sigs 失效；下一次 run_atlas_pipeline_step 会按 dirty 全集重建。
    // 无副作用、O(1) 清空 PackedArray。
    void invalidate_atlas_csr_cache();
    // 一次性把 GD 端 ecology 持久状态（map_baker.gd _eco_foliage/_eco_stress/
    // _eco_transition_age_bytes / _eco_growth_damage / _eco_active_decay_set）
    // 迁移到 C++ 端 AtlasPipelineState。init 阶段调一次，之后完全由 C++ 维护。
    //
    // state (Dictionary):
    //   "foliage"           : PackedFloat32Array（长度 n_cells，per-cell foliage 0..1）
    //   "stress"            : PackedFloat32Array（同上，stress 0..1）
    //   "transition_age"    : PackedFloat32Array（同上，秒）
    //   "growth_damage"     : PackedFloat32Array（同上，0..1）
    //   "active_decay"      : PackedInt32Array（active decay set 的 cell.index 列表）
    //
    // 容错：缺失字段以默认 0 填充；长度不匹配以 n_cells 截断/补 0。
    void migrate_eco_persistent_from_gd(godot::Dictionary state);
    // ─── Cell-index 间接寻址（province-ID indirection）─────────────────────
    // encode_cell_luts：per-cell（n_cells texel）enum/dyn/eco LUT 编码。与 4-phase
    //   fan-out pipeline 共用 pk_atlas_sig_dynamic / pk_atlas_sig_ecology 公式，
    //   保证 LUT 与全分辨率 atlas bit-equivalent。eco transition_age 由
    //   AtlasPipelineState::lut_* 持久状态自维护（与 pipeline eco 状态独立）。
    //   可选 opts["snow_cover_arr"] 只覆盖雪盖视觉通道，避免为修复雪盖 stale
    //   而全量 refresh_slots_from_map() 覆盖 native-only 槽。
    //   SAME_SOURCE: map_baker.gd::bake_cell_luts / _bake_cell_luts_gd。
    godot::Dictionary encode_cell_luts(godot::Dictionary opts);
    // ─── Detail scatter（vegetation-visual-pcg 阶段 A）────────────────────
    //   encode_detail_scatter：植被/点缀散布的 per-instance 热循环 + MultiMesh
    //   buffer 组装下沉 C++。纯 buffer-encoder：只读 knobs 内的 flat PackedArray，
    //   不读 _slots、不写 slot；结果 MultiMesh buffer（每实例 16 float =
    //   transform2d 8 + color 4 + custom 4）直接随返回 Dict 回传，GDScript 端
    //   `multimesh.buffer = buf` 一次赋值，零逐实例 marshalling。
    //   SAME_SOURCE: shrub_layer.gd::_rebuild_instances（GDScript fallback）。
    godot::Dictionary encode_detail_scatter(godot::Dictionary knobs);
    // Dirty-cell variant for succession events. It consumes the same flat per-cell
    // arrays as encode_detail_scatter, but callers pass only the current event batch.
    godot::Dictionary encode_detail_scatter_delta(godot::Dictionary knobs);
    // Multi-profile/family bridge: one Godot→native call accepts an Array of delta
    // requests and returns tagged payloads. Requests share PackedArray references;
    // no per-instance Variant marshalling is introduced.
    godot::Dictionary encode_detail_scatter_family_cells(godot::Dictionary knobs);
