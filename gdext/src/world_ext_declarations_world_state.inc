// Season, cyclone, generation, event, and ocean state.

    // ─── Phase B+（2026-05-21）：season refresh round 切片调度 opaque state ─
    // 实际类型 pk::SeasonRoundState 在 world_ext.cpp 顶部定义（含 generation
    // 计数器 / current stage / round_knobs 缓存 / 计时累加）。lazy alloc 在
    // start_season_round 首次成功路径；abort_season_round 内手动 delete + 置
    // null；DCWorldExt 析构内自动清理（与 _summary_state / _atlas_state 同模式）。
    // B+ b1 粒度：每 slice 跑整 stage（不在 stage 内 cursor 切片）。
    void                                     *_season_round           = nullptr;

    // q/r → cell idx 反查 hash（summary pass cube_to_idx 用）。lazy rebuild：
    // 在 run_weather_summary_fronts_pass 内部，发现 _summary_qr_to_idx_size !=
    // n_cells 时清空重建。size 不变（即 cell 拓扑稳定）时直接复用。
    std::unordered_map<int64_t, int>          _summary_qr_to_idx;
    int                                       _summary_qr_to_idx_size = -1;

    // ─── plan/weather-refresh-cpp-all: cyclone wake 持久化状态 ───────────
    // 等价于 weather_system.ocean_current_perturbation Dictionary<key, entry> 的
    // C++ 镜像。key = cell.q*10000+cell.r （与 GDScript 1:1 对齐，C++ 端用 int64_t
    // 存储兼容负坐标 hash）。Entry 跨 tick 存活：每日 cyclone_wake_step 头部衰减/
    // 淘汰，尾部按 STORM front 中心 cell 注入。GDScript 端通过
    // get_cyclone_perturbations_dict() 拉镜像。
    struct CycloneWakeEntry {
        uint64_t     stable_id = 0;
        int64_t      key = 0;       // cell.q * 10000 + cell.r
        int          cell_idx = -1;
        godot::Vector2 vec;
        godot::Vector2 vec_init;
        godot::Vector2 steering;
        float        intensity = 0.0f;
        float        radius_cells = 2.0f;
        float        age_days = 0.0f;
        float        move_progress = 0.0f;
        int          days_left = 0; // compatibility projection
        int          init_days = 0;
    };
    std::vector<CycloneWakeEntry>  _cyclone_perturbations;
    uint64_t                       _cyclone_next_stable_id = 1;
    uint32_t                       _cyclone_force_generation = 0;
    std::vector<uint32_t>          _cyclone_force_tag;
    std::vector<uint32_t>          _cyclone_visit_tag;
    std::vector<float>             _cyclone_force_x;
    std::vector<float>             _cyclone_force_y;
    std::vector<float>             _cyclone_force_lift;
    int                            _cyclone_last_touched_cells = 0;
    int                            _cyclone_total_genesis = 0;
    int                            _cyclone_total_decay = 0;

    // Stage6c (2026-06-23): 对流抑制记忆，per-cell，跨 tick/slice 存活的 C++ 端权威状态。
    // 上一版走 knob in/out 数组经 const Dictionary CoW 回传失败(实测抑制 no-op)，改存为 ext 成员→
    // 无边界穿越、保证持久。run_weather_field_solve_pass 读写；尺寸变化(换地图)时清零。
    std::vector<float>             _wx_conv_inhib;
    // Synoptic eddy field ψ (emergent weather variability). Prognostic, per-cell, cross-tick.
    // Double-buffered as ext members (proven round-trip, like _wx_conv_inhib): _prev is the
    // round-start snapshot read for advection; _cur is written this round. Sized on map change.
    std::vector<float>             _wx_synoptic;
    std::vector<float>             _wx_synoptic_prev;

    // ─── 天气邻域几何缓存（perf P2，2026-06-29）────────────────────────────
    // run_weather_field_solve_pass 在每轮 start_idx==0 用 wf_wrapped_delta 预算
    // 每 cell 6 邻居的 self->nb wrapped delta (dx,dy) 与 inv_dist=1/sqrt(|d|²)。
    // 主循环 aligned_idx / upstream chain / convergence 改读缓存→消除热循环内
    // 重复 wrapped_delta/sqrt。bit-equal：缓存值由相同 wf_wrapped_delta/Math::sqrt
    // 同序算出。尺寸(换图)或 wrap 变化时由 build 逻辑重填。
    std::vector<float>             _wf_nb_dx;            // n*6, self->nb wrapped delta x
    std::vector<float>             _wf_nb_dy;            // n*6, self->nb wrapped delta y
    std::vector<float>             _wf_nb_invd;          // n*6, 1/sqrt(|d|²) 或 0 (dl2<=1e-4 哨兵)
    // 同一份 cell_pos 的 POD 视图。共享纯内核不能接 godot::Vector2，而单纯把
    // PackedVector2Array 解交织成两条 float lane 是逐位无损的，所以内核与生产
    // 热路径读到的位置完全相同。每轮 start_idx==0 重填。
    std::vector<float>             _wf_pos_x;            // n
    std::vector<float>             _wf_pos_y;            // n
    int                            _wf_nb_geom_n = 0;    // 已构建几何缓存的 n_cells（0=未填）
    float                          _wf_nb_geom_wrap = -1.0f;  // 构建时的 wrap_width_x（变更→失效）

    // ─── 生成期河流拓扑缓存（dots-total-cpp step1，2026-06-25）────────────
    // run_native_world_generate_post_base_pass 末尾把 river 拓扑（by cell.index）暂存为 ext 成员，
    // 供同一 generation ext 实例的 run_bake_river_sdf_pass 直接 trace（零跨语言再传输）。
    // 换图（n_cells 变化）或新生成时由 post-base 重填覆盖。tracing 复刻 map_baker.gd::_trace_all_rivers。
    int                            _gen_river_n = 0;          // n_cells（0=未填）
    std::vector<int32_t>           _gen_river_q;              // cube q
    std::vector<int32_t>           _gen_river_r;              // cube r
    std::vector<uint8_t>           _gen_river_terrain;        // 最终 terrain（含所有翻转）
    std::vector<float>             _gen_river_elev;           // 最终 elevation
    std::vector<uint8_t>           _gen_river_has;            // has_river 0/1
    std::vector<float>             _gen_river_flow;           // river_flow（生成期宽度源）
    std::vector<int32_t>           _gen_river_downstream;     // declared downstream cell index（-1=无）
    std::vector<int32_t>           _gen_river_neighbors;      // n*6 邻居 cell index（-1=越界），DQ/DR 序

    struct GameplayEventRecord {
        int64_t event_id = 0;
        int64_t tick = 0;
        int32_t phase = 0;
        int32_t type = 0;
        int32_t source = 0;
        int32_t flags = 0;
        uint64_t entity_handle = 0;
        int32_t entity_id = -1;
        int32_t cell_idx = -1;
        int32_t payload_schema = 0;
        int64_t value_i64 = 0;
        int32_t payload_i0 = 0;
        int32_t payload_i1 = 0;
        int32_t payload_i2 = 0;
        int32_t payload_i3 = 0;
    };
    struct EffectGameplayCommandResult {
        uint8_t complete = 0;
        uint8_t ok = 0;
        std::string reason;
    };
    std::deque<GameplayEventRecord>         _gameplay_events;
    godot::HashMap<godot::StringName, int64_t> _gameplay_consumer_ack;
    int64_t                                 _gameplay_next_event_id = 1;
    int64_t                                 _gameplay_dropped_event_count = 0;
    int64_t                                 _gameplay_first_dropped_event_id = 0;
    int                                     _gameplay_max_events = 8192;
    double                                  _gameplay_last_native_ms = 0.0;
    godot::String                           _gameplay_last_fallback_reason;
    uint64_t                                _events_bridge_queued = 0;
    uint64_t                                _events_bridge_failed = 0;
    godot::String                           _events_bridge_last_reason;
    std::vector<EffectGameplayCommand>      _effect_gameplay_commands;
    std::unordered_map<int64_t, EffectGameplayCommandResult>
                                                _effect_gameplay_results;
    std::unordered_map<uint64_t, int64_t>   _effect_gameplay_idempotency;
    std::unordered_map<uint64_t, int64_t>   _effect_gameplay_event_ids;
    int64_t                                 _effect_gameplay_next_request_id = 1;

    // 内部辅助：cyclone wake 一日推进。由 run_weather_refresh_daily_pass 调用。
    // fronts 入参 = run_weather_summary_fronts_pass 返回的 Array[Dictionary]
    // （含 type/center/intensity/velocity 字段，与 GDScript WeatherFront 1:1）。
    // 返回耗时 ms（含 phase1 衰减/淘汰 + phase2 注入）。
    //
    // 细粒度遥测（Phase B.2）：通过 knobs by-ref 写回 6 个字段（与 stage_b 同模式）：
    //   cyclone_phase1_decay_ms : double  Phase 1 总耗时 ms
    //   cyclone_phase2_inject_ms: double  Phase 2 总耗时 ms
    //   cyclone_n_decayed       : int     Phase 1 衰减后仍存活的 entry 数
    //   cyclone_n_evicted       : int     Phase 1 淘汰的 entry 数
    //   cyclone_n_replaced      : int     Phase 2 命中已有 key 覆盖更新的次数
    //   cyclone_n_injected      : int     Phase 2 新增 entry 的次数
    // caller 需要 by-value 复制 knobs 再传入（避免污染上游 Dictionary 引用），
    // 等价于 stage_b_pass 的处理模式（world_ext.cpp:7750）。
    double cyclone_wake_step(godot::Dictionary &knobs,
                             const godot::Array &fronts_from_summary);
    void _advance_and_stamp_cyclones(const godot::Dictionary &knobs,
                                     int n_cells, const int32_t *neighbors,
                                     const godot::Vector2 *positions,
                                     const uint8_t *terrain, const float *temp,
                                     const float *wind_x, const float *wind_y,
                                     const float *wind_speed, const float *vapor,
                                     const float *instability, const float *lat_norm);
    void _ensure_enso_basin_cache(int n_cells, const uint8_t *is_water,
                                  const uint8_t *terrain, const float *lat_norm,
                                  const float *pos_x, const int32_t *neighbors,
                                  const godot::PackedByteArray &ocean_terrain_ids,
                                  float tropical_lat_limit, int max_basins,
                                  float wrap_period_x, int world_seed);
    void _apply_enso_ocean_slice(godot::Dictionary &knobs, int n_cells,
                                 int start_idx, int end_idx,
                                 const uint8_t *is_water,
                                 const uint8_t *terrain, const float *lat_norm,
                                 const float *pos_x, const int32_t *neighbors,
                                 const float *wind_x, const float *wind_speed,
                                 float *ocean_anomaly, float *transport_anomaly);
