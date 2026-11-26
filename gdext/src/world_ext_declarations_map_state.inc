// Entity pools, MapData binding, and atlas and weather state.

    // ---- entity / pool ----
    int                                       _entity_count = 0;

    struct Pool {
        godot::StringName name;
        int               start    = 0;
        int               capacity = 0;
        // free-list (LIFO stack of indices within [start, start+capacity)).
        // empty = pool fully allocated. Initialised in create_pool().
        godot::Vector<int> free_list;
    };
    godot::Vector<Pool>                       _pools;
    godot::HashMap<godot::StringName, int>    _pool_by_name;

    // ---- bind state ----
    godot::Object                            *_map_data = nullptr; // weak (GDScript holds strong ref)
    // DCWorld 句柄。C++ pass 通过 `_flush_slot_to_map` 直写 MapData，原本绕过
    // DCWorld dirty mask；flush 现在按值差异累积精确 cell indices。
    godot::Object                            *_dirty_world = nullptr; // weak
    // 多个视觉槽共享一份 per-cell union mask，round 末尾只跨边界发布一次。
    bool                                      _pending_mark_dirty_all = false;
    godot::PackedByteArray                    _pending_visual_dirty_mask;
    int                                       _pending_visual_dirty_count = 0;
    bool                                      _pending_visual_dirty_dense = false;
    // Economy writes resource extra-change lanes directly into native slots.
    // Until the native resource pass consumes and publishes them, MapData
    // still contains the preceding committed mirror and must not overwrite
    // those slots during a generic refresh.
    std::vector<uint8_t>                      _economy_resource_slot_resident;
    // BIND_TABLE 反查记忆化。_flush_slot_to_map / refresh_slots_from_map_keys 原来
    // 每次调用都线性扫 148 条表项，每条现构一个 StringName（UTF-8 解析 + 全局
    // StringName 表加锁查找）。资源 pass 每日 flush 约 28 个 slot、refresh 约 68 个
    // key，累计上万次 StringName 构造。查找结果对 (comp_id → 表项) 是恒定的，
    // 首次解析后缓存：-2 未解析，-1 不在表内，>=0 为表项下标。
    // _slot_visual_dirty_cache 同理缓存 pk_slot_affects_visual_dirty 的 String
    // begins_with 链：0 未解析，1 否，2 是。
    std::vector<int16_t>                      _slot_bind_index_cache;
    std::vector<uint8_t>                      _slot_visual_dirty_cache;
    bool                                      _bound    = false;
    bool                                      _native_world_configured = false;
    int                                       _native_world_cell_count = 0;
    int                                       _native_daily_tick_count = 0;
    double                                    _native_daily_perf_target_ms = 1.0;
    // seam-advection-fix 2026-08-03：经度环绕周期 = map.width·√3，单位是 size=1.0 的单位
    // 六边形空间（**不含 hex_size**，因为 cell_pos_x slot 由 map_data.gd 以
    // cube_to_world(q, r, 1.0) 填充，列距恰为 √3/2）。
    // 由 configure_native_world 一次性常驻，供 climate/weather 平流与上风探测内核做
    // cell_pos_x 差分的最小映像折叠（pk_wrap_min_image_dx）。
    // 0 = 未配置环绕域 → 内核退化为裸差分（旧行为）。
    // 各 pass 的 knobs["wrap_period_x"] 仍可逐次覆盖，供单测与显式调用方使用。
    double                                    _native_wrap_period_x = 0.0;
    godot::Array                              _native_fronts_snapshot;
    godot::Dictionary                        _native_dirty_report;
    godot::Dictionary                        _native_daily_report;
    godot::Dictionary                        _native_shadow_diff_report;
    bool                                      _native_daily_slice_active = false;
    bool                                      _native_daily_visual_commit_pending = false;
    int                                       _native_daily_slice_node_index = 0;
    int                                       _native_daily_slice_cell_cursor = 0;
    int                                       _native_daily_slice_range_node_index = -1;
    int                                       _native_daily_slice_cell_budget = 0;
    uint32_t                                  _native_daily_slice_range_node_bits = 0u;
    // Bitmask of slice-graph node indices GDScript must JIT-patch before they run
    // (temp-dependent passes). C++ batches consecutive non-yield nodes in one call.
    // Default 0xFFFFFFFF = yield before every node (legacy one-node-per-call).
    uint32_t                                  _native_daily_slice_yield_bits = 0xFFFFFFFFu;
    int                                       _native_daily_slice_round_id = 0;
    double                                    _native_daily_slice_elapsed_accum_ms = 0.0;
    bool                                      _native_daily_slice_any_pass_ran = false;
    godot::Dictionary                        _native_daily_slice_tick_knobs;
    godot::Dictionary                        _native_daily_slice_bundle;
    godot::Dictionary                        _native_daily_slice_breakdown;
    godot::Array                             _native_daily_slice_bundle_pass_keys;
    godot::Array                             _native_daily_slice_retained_authority;
    godot::Dictionary                        _native_daily_slice_state_snapshot;
    godot::Dictionary                        _native_ocean_physical_state;
    godot::Dictionary                        _native_runtime_config;
    godot::Dictionary                        _native_generation_report;
    godot::Dictionary                        _native_generation_cfg;
    godot::Dictionary                        _native_generation_profile;
    bool                                      _native_generation_active = false;
    int                                       _native_generation_seed = 0;

    // NativeRuntimeGraph state. Runtime pointers above remain the authority;
    // this state stores only scheduler cursors, counters and dirty generations.
    bool                                      _runtime_graph_configured = false;
    bool                                      _runtime_graph_enabled = false;
    bool                                      _runtime_graph_country_peer_adapter_enabled = false;
    int64_t                                   _runtime_graph_day = -1;
    uint64_t                                  _runtime_graph_generation = 0;
    uint32_t                                  _runtime_graph_dirty_mask = 0;
    uint32_t                                  _runtime_graph_next_cursor = 0;
    uint64_t                                  _runtime_graph_pulse_count = 0;
    uint64_t                                  _runtime_graph_abi_calls = 0;
    uint64_t                                  _runtime_graph_callback_count = 0;
    uint64_t                                  _runtime_graph_work_done = 0;
    uint64_t                                  _runtime_graph_budget_yields = 0;
    uint64_t                                  _runtime_graph_economy_slices = 0;
    uint64_t                                  _runtime_graph_economy_commits = 0;
    uint64_t                                  _runtime_graph_country_peer_service_calls = 0;
    uint64_t                                  _runtime_graph_country_peer_intents = 0;
    uint64_t                                  _runtime_graph_country_peer_completed = 0;
    uint64_t                                  _runtime_graph_country_peer_pending = 0;
    uint64_t                                  _runtime_graph_country_peer_rejected = 0;
    uint64_t                                  _runtime_graph_country_peer_faults = 0;
    std::string                               _runtime_graph_country_peer_fault_reason;
    uint64_t                                  _runtime_graph_trigger_blocked_pulses = 0;
    std::string                               _runtime_graph_trigger_blocked_reason;
    // Last Economy class-opinion revision handed to the worker Ideology stage.
    uint64_t                                  _ideology_opinion_published_revision = 0;
    uint32_t                                  _runtime_graph_last_elapsed_us = 0;
    uint32_t                                  _runtime_graph_last_status = 0;
    double                                    _runtime_graph_post_pulse_flush_ms = 0.0;
    double                                    _runtime_graph_country_territory_sync_ms = 0.0;
    uint64_t                                  _runtime_graph_flush_slot_count = 0;
    uint64_t                                  _runtime_graph_visual_diff_cell_count = 0;
    uint64_t                                  _runtime_graph_full_flush_count = 0;
    godot::Dictionary                         _runtime_graph_last_economy_report;
    std::string                               _runtime_graph_economy_capture_fatal_reason;
    std::unique_ptr<NativeSimulationHost>     _runtime_host;
    // 只在主线程应用完整提交后替换；读视图不读 worker scratch、不再次获取 ring。
    std::shared_ptr<const pk_async_physics::RuntimeClimatePhysicsState> _climate_physics_committed;
    uint64_t _climate_physics_map_id = 0;
    // Last climate writeback applied to MapData, whoever asked for it. The host's
    // per-frame apply and the season-refresh drain share one ring; without this
    // the host would re-apply a generation the drain already applied and roll
    // the *_prev lanes onto the current values.
    uint64_t _climate_writeback_applied_generation = 0;
    int64_t _climate_writeback_applied_day = -1;
    // 最近一次 capture_runtime_inputs() 的耗时（毫秒）。内联日把它一起回传，
    // 调用方就能把一帧拆成"capture + 12 域 + 其余 GDScript"，否则浏览器里
    // 24 秒的帧根本分不清是 C++ 日屏障还是捕获/GDScript。
    double _inline_capture_ms = 0.0;
    bool _climate_physics_capture_ready = false;

    // ---- archetype ----
    godot::Vector<godot::Array>               _archetypes;          // each entry = comp_ids
    godot::HashMap<godot::StringName, int>    _archetype_by_name;
    godot::PackedInt32Array                   _entity_archetype;    // index by entity idx

    // ---- EXPERIMENTAL: D-async opaque state (defined in .cpp) ----------
    // Holds the std::unordered_map<int, AsyncTask> and a global mutex.
    // Allocated lazily on first async_* call; freed in shutdown_all().
    void                                     *_async_state = nullptr;

    // ---- Async Climate Round opaque state（plan §async-stage-1，2026-06-14） ----
    // 实际类型 pk_async_climate::AsyncClimateRoundState 在 .cpp 内部定义。
    // lazy alloc 在 async_climate_round_register；析构走 async_climate_round_shutdown
    // (~DCWorldExt 也会兜底调用)。与 _async_state 同模式（void* opaque pointer）。
    // 单实例：只支持一个 round-level async task。
    void                                     *_async_climate_round_state = nullptr;

    // ---- Weather summary pass 持久化状态（plan/weather-hotpath-cpp）------
    // GDScript 侧 _prev_summary_seeds (Array[Dictionary]) 与
    // _prev_summary_membership (Dictionary[HexCell→cluster_idx]) 的 C++ 镜像：
    //   _prev_summary_seeds_state：跨 tick 存活的 seed 列表（type/center/area/
    //                              age/velocity）；按上 tick top-N 写入。
    //   _prev_summary_membership_state：长度 n_cells，[i] = cluster_idx 或 -1。
    //
    // 通过 `void *` opaque 指针避免在 .h 引入 std::vector / 复杂结构体（与
    // _async_state 同模式）；具体类型在 .cpp 内部 forward-declare 并 lazy alloc。
    void                                     *_summary_state          = nullptr;
    void                                     *_summary_state_snapshot = nullptr;

    // ─── plan/atlas-pipeline-cpp（2026-05-20）：atlas pipeline opaque state ─
    // 实际类型 pk::AtlasPipelineState 在 .cpp 顶部定义。lazy alloc 在
    // run_atlas_pipeline_step 首次调用；析构走 PackedArray RAII。与
    // _summary_state 同模式（void* opaque pointer）。
    void                                     *_atlas_state            = nullptr;
