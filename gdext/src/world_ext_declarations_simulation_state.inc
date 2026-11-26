// Simulation owner references, published data, and military and resource bridges.

    // Independent native economy authority. Concrete type lives in
    // economy_runtime.{h,cpp}; opaque here so the existing world header does
    // not expose the large chunk/market implementation to every pass TU.
    void                                     *_economy_runtime        = nullptr;
    // R-3: refresh ticks that could not take the economy input boundary lock.
    // `skips` is the lifetime total, `max_consecutive` the longest run of skipped
    // ticks, which is what tells "the worker is briefly busy" apart from "the refresh
    // is starved and never runs". Derived, never saved.
    uint64_t                                  _instance_refresh_lock_skips = 0;
    uint64_t                                  _instance_refresh_consecutive_skips = 0;
    uint64_t                                  _instance_refresh_max_consecutive_skips = 0;
    // Frozen economy input capture is immutable for a sample day.  Reuse the
    // boundary report across compact slices instead of rebuilding bridge
    // dictionaries and rescanning MapData on every slice.
    EconomyInputGeneration                   _economy_capture_generation;
    bool                                     _economy_capture_generation_valid = false;
    bool                                     _economy_capture_cached = false;
    bool                                     _economy_capture_force_full = true;
    uint64_t                                 _economy_capture_count = 0;
    uint64_t                                 _economy_capture_reuse_count = 0;
    godot::Dictionary                        _economy_capture_cached_report;
    // Main-thread-only compatibility report. Never read worker-owned vectors
    // without the authority boundary; a busy worker yields this private copy.
    mutable godot::Dictionary                _economy_read_report_cache;
    // Visual requests that arrived before the worker published its first
    // committed building view; replayed with the next request.
    mutable godot::PackedInt32Array          _building_visual_pending_cells;
    void invalidate_economy_read_view();
    godot::Dictionary population_cell_snapshot_live(int cell_idx,
                                                    bool include_details) const;
    // A running worker re-takes the economy boundary right after each input
    // capture, so a deferred Economy effect adapter call is replayed by the
    // next capture that already holds the boundary.
    // Country twins of the Economy adapters below: the same worker boundary
    // applies, and a deferred call is retried by the next runtime-graph
    // adapter pass (which runs every tick).
    godot::Dictionary dispatch_effect_native_country_unlocked();
    godot::Dictionary ack_effect_native_country_unlocked();
    godot::Dictionary settle_orphaned_effect_native_country_acks_unlocked();
    godot::Dictionary dispatch_effect_native_economy_unlocked();
    godot::Dictionary ack_effect_native_economy_unlocked();
    uint64_t                                  _canal_topology_generation = 0;
    // 运河编译态。原先是五个独立成员，现在整组进 HydrologyCanalState ——
    // hydrology_pass_pure 要能在 worker 侧跑，而 worker 拿不到 DCWorldExt 的成员。
    // 两边各持一份，各自按 _canal_topology_generation 失效。
    pk_async_climate::HydrologyCanalState     _hydrology_canal;
    // 每日重置的临时缓冲，抬成成员只为省掉每天四次分配。
    pk_async_climate::HydrologyScratch        _hydrology_scratch;
    std::unordered_set<uint64_t>              _canal_commit_idempotency;
    std::vector<int32_t>                      _canal_visual_dirty_cells;
    void                                     *_economy_csv_recorder   = nullptr;
    int64_t                                   _economy_last_notified_event_id = 0;
    void                                     *_country_runtime        = nullptr;
    void                                     *_country_ai_runtime     = nullptr;
    std::vector<std::string>                  _country_ai_personality_ids;
    int64_t                                   _country_ai_sync_day = -1;
    std::shared_ptr<RuntimeCountryPodCatalog> _country_ai_catalog_cache;

    // ---- Military
    std::shared_ptr<NativeMilitaryRuntime> _military;
    void bind_military_dependencies();
    bool military_executor_active() const;
    std::shared_ptr<const MilitaryCore> read_military_core() const;
    int64_t _military_render_selected_army = 0;
    int64_t _military_render_selection_revision = 0;
    int64_t _military_render_control_revision = -1;
    int64_t _military_render_front_revision = -1;
    // ---- Stratum mobilization (rebellion) surface
    godot::Dictionary get_cell_mobilization_snapshot(int cell_idx) const;
    godot::Dictionary get_country_mobilization_summary(int country_slot) const;
    godot::Dictionary get_mobilization_odds(int cell_idx, int profession,
                                            int action, int64_t spend_bp) const;
    // Synchronous at the paused narrative boundary: applies an already-rolled
    // rebellion outcome to the sparse row. Never touches conserved ledgers.
    bool apply_mobilization_result(int cell_idx, int profession, int action,
                                   bool success);
    // Player-facing "resolve the rebellion choice" entry. The row itself is
    // applied by apply_mobilization_result above; this one owns the odds roll
    // and the choice payload, so it must read through the economy boundary.
    godot::Dictionary resolve_player_mobilization(const godot::Dictionary &choice);
    // ---- Military cell stats
    // Published per-country metrics (design §17.1 `country.at_war` /
    // `country.soldier_share_q16`), keyed by country handle and rebuilt from
    // scratch on every publish. Derived and never saved: after a restore the
    // caller republishes from the restored Military state, and an absent row
    // legitimately means "peace, no army".
    struct MilitaryCountryMetricRow {
        int32_t slot = -1;
        int32_t at_war = 0;
        int32_t soldier_share_q16 = 0;
    };
    std::unordered_map<int64_t, MilitaryCountryMetricRow> _military_country_metrics;
    // Per-cell tag bitset, dense over `terrain().cell_count`, bit order given by
    // `MilitaryCellTagBit` in world_ext_military_cell_stats.cpp. Rebuilt by
    // set_military_cell_tags; sized once per terrain.
    std::vector<uint8_t> _military_cell_tag_bits;
    // --- end Military cell stats
    // --- end Military
    bool country_ai_sync_due(int64_t day) const;
    void country_ai_sync_plan(int64_t day);
    void country_ai_sync_finish(int64_t day, bool ok, godot::Dictionary &out);
    godot::Dictionary submit_country_ai_batch(const godot::Dictionary &packed_batch);
    void attach_country_ai_to_host();
    void push_country_ai_family_preferences();
    NativeCountryRuntime *country_query_runtime() const;
    mutable void *_country_query_runtime = nullptr;
    mutable std::shared_ptr<const RuntimeCountryPodSnapshot> _country_query_snapshot;
    void                                     *_modifier_runtime       = nullptr;
    void                                     *_economy_modifier_view  = nullptr;
    bool _economy_modifier_view_attached = false;  // economy reads the view, not main
    void                                     *_trigger_runtime         = nullptr;
    void                                     *_effect_runtime          = nullptr;
    // M2a: single write path for declarative Effect instances. Declared here as
    // a unique_ptr so the header stays free of the forwarder's own includes.
    std::unique_ptr<EffectInstanceForwarder>   _effect_forwarder;
    // Re-applied whenever configure_effects rebuilds/re-attaches the forwarder,
    // so a test can set the seam before the catalog exists.
    int32_t                                    _effect_forwarder_authority_override = -1;
    // Host-committed era-reward selection under worker Effect authority.
    // Session-only: a restored pending selection is re-submitted, which the
    // UNIQUE_SOURCE Modifier policy makes idempotent.
    void                                     *_ideology_runtime        = nullptr;
    uint64_t                                  _natural_resource_modifier_version =
        std::numeric_limits<uint64_t>::max();
    uint64_t                                  _natural_resource_modifier_catalog_hash = 0;
    uint64_t                                  _natural_resource_modifier_ids_hash = 0;
    int32_t                                   _natural_resource_modifier_cells = -1;
    int32_t                                   _natural_resource_modifier_active_factor_count = 0;
    godot::PackedFloat32Array                 _natural_resource_regen_factors;
    // 因子表只在 modifier 快照变动时重建，但 run_natural_resource_pass 原来每日
    // 重扫整表（resource_count × n_cells）做有限性校验与 active 计数，再对每个动态
    // 资源额外扫一遍 n_cells 判断 has_regen_modifier。表没变时结论恒定，故在重建
    // 处一次算清并缓存；pass 侧凭 (snapshot_version, factor_count) 命中即跳过。
    std::vector<uint8_t>                      _natural_resource_regen_resource_active;
    bool                                      _natural_resource_regen_summary_valid = false;
    bool                                      _natural_resource_regen_summary_rejected = false;

    // Bio occupancy keeps deterministic full-map semantics in phase one, but
    // reuses its cell lanes across daily calls. Published PackedArrays remain
    // transient output; these members only own native staging capacity.
    std::vector<int32_t>                      _bio_occupancy_bits_staging;
    std::vector<int32_t>                      _bio_occupancy_previous;
    std::vector<int32_t>                      _bio_occupancy_additions;
    godot::PackedInt32Array                   _bio_newly_occupied_cells;
    godot::PackedInt32Array                   _bio_newly_occupied_signals;
    void                                     *_bio_native_config_state = nullptr;
    bool seed_runtime_bio(const NativeEconomyRuntime &economy);
    void                                     *_bio_occupancy_slice_state = nullptr;
    std::shared_ptr<VisionResearchState>       _vision_research_state;
    bool seed_runtime_resource_reserves(NativeEconomyRuntime &runtime, int64_t day);
    std::vector<int32_t> _natural_resource_last_day;
    std::vector<uint8_t> _natural_resource_was_live;
    std::vector<uint8_t> _natural_resource_live_mark;
