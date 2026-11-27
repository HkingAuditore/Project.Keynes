// Host lifecycle, publication, and runtime command declarations.

    // ---- bindings: runtime ----
    // Cold loading tasks use an isolated, unbound compute context. No live slots
    // or renderer objects cross this boundary. Handles are single-use generations.
    int64_t begin_loading_task(const godot::String &operation, const godot::Dictionary &input);
    godot::Dictionary poll_loading_task(int64_t handle);
    godot::Dictionary take_loading_task(int64_t handle);
    void cancel_loading_task(int64_t handle);
    void cancel_all_loading_tasks();
    godot::Dictionary encode_bake_height_flow_tex_data(const godot::Dictionary &input);
    godot::Dictionary run_native_daily_tick(const godot::Dictionary &tick_knobs);
    godot::Dictionary run_native_daily_slice(const godot::Dictionary &tick_knobs);
    // Coarse-grained native scheduler boundary. Configuration is cold-path;
    // advance_runtime_pulse is the only production bridge call needed to
    // drain cross-domain continuation work for one render frame.
    int configure_runtime_graph(const godot::Dictionary &boot_config);
    int64_t advance_runtime_pulse(int64_t day, double season_phase,
                                  double speed_scale, int budget_us, int flags = 0);
    void flush_runtime_visuals(uint32_t dirty_mask = 0);
    void set_runtime_qos(bool interactive);
    godot::Dictionary get_runtime_thread_report() const;
    godot::Dictionary get_runtime_control_state() const;
    godot::Dictionary get_runtime_perf_snapshot(int detail_level = 0) const;
    godot::Dictionary get_runtime_graph_last_economy_report() const;
    // Sparse-workset probe: scalar counters straight from the economy runtime.
    // Diagnostic only; called once per recorded perf row, never per frame.
    godot::Dictionary get_runtime_economy_probe_report() const;
    godot::Dictionary record_runtime_visual_timings(double ui_input_to_feedback_ms,
                                                    double visual_apply_ms,
                                                    double gpu_upload_ms);
    // Thread-isolated runtime host. These methods are non-blocking facade calls;
    // the worker is only enabled after the complete POD graph has been proven.
    godot::Dictionary start_runtime_worker(const godot::Dictionary &config);
    // native_daily_inline：在调用线程上同步跑完一天的 12 域日屏障。
    //
    // 只在 `start_runtime_worker({"native_daily_inline": true, ...})` 成功之后
    // 有效。与 worker 路径的区别只有"谁执行"和"peer 怎么满足"两件事：
    //   * 不 spawn 线程，build_day_plan/execute_day_plan/publish_day 全在
    //     主线程串行执行；
    //   * 日屏障缺 peer 结果时不进 CV 等待、不设 5s 超时，而是当场把 Country
    //     peer 适配器推一轮（Effect/Modifier/Economy 都在同一线程），再重试
    //     同一天。泵不动了才返回 ok=false —— 冻结可见，而不是 FAULTED。
    //
    // 返回字段：ok / code / reason / attempts / peer_pumped / from_day / day /
    // committed_day / completed_domain_mask / preflight_ok /
    // continuation_pending / work_units / dirty_families / elapsed_ms。
    // 另有分域耗时：stage_ms（12 域 → ms，键名见 runtime_domain_stage_key）/
    // attempt_ms / pre_stage_ms / climate_ms / plan_build_ms / commit_tail_ms /
    // peer_ms / capture_ms / budget_exceeded / executor_serial_only。
    // capture_ms 是紧接在这次调用之前的 capture_runtime_inputs() 的耗时，
    // 用来把调用方那一帧拆成"capture + 本日 12 域 + 其余 GDScript"。"当前这次
    // 捕获"与"上一次捕获"共用同一个 slot，所以只在每次 capture 时刷新。
    godot::Dictionary run_native_daily_inline_day();
    godot::Dictionary set_runtime_clock(bool paused, double speed_days_per_second);
    void profile_runtime_save_window(bool active);
      godot::Dictionary capture_runtime_inputs(const godot::Dictionary &inputs);
    // Reduces a production Climate state to the canonical parity hash. The
    // main thread passes the MapData arrays; the same C++ function the worker
    // uses produces the value, so the two sides are comparable by
    // construction instead of by convention.
    godot::Dictionary compute_runtime_climate_parity_hash(
            const godot::Dictionary &fields);
    // Publishes the reference for a day as state plus hash in one call. The
    // hash is derived from the state here, so the two cannot disagree, and the
    // retained state lets a mismatch be reported per field and cell.
    godot::Dictionary publish_runtime_climate_reference_state(
            int64_t day, const godot::Dictionary &fields);
    // The canonical parity field table, for tests and divergence reports.
    godot::Array get_runtime_climate_parity_fields() const;
    // Cumulative per-field divergence since the worker started. This is the
    // stage/field matrix a migration order is derived from.
    godot::Array get_runtime_climate_parity_divergence() const;
    // Diagnostic only: keeps a divergent SHADOW day advancing by adopting the
    // production reference, so more than one day can be measured.
    godot::Dictionary set_runtime_climate_parity_forcing(bool enabled);
    // Ideology parity reference capture. Off by default: it exports and stores a
    // full ideological snapshot per day, which production must not pay for.
    godot::Dictionary set_runtime_ideology_parity_enabled(bool enabled);
    godot::Dictionary submit_runtime_command(const godot::Dictionary &command);
    godot::Dictionary poll_runtime_receipts(int max_items = 128);
    godot::Dictionary set_runtime_qos_threaded(bool interactive);
    godot::Dictionary poll_runtime_commit(int64_t after_generation, bool take_days = false);
    godot::Dictionary read_runtime_map_lut_frame(godot::Object *map, int64_t day,
            int64_t generation, int cell_count, bool measure_copy = false) const;
    void clear_runtime_map_lut_frame();
    godot::Dictionary request_runtime_save(int64_t request_id);
    godot::Dictionary poll_runtime_save(int64_t request_id);
    godot::Dictionary restore_runtime_bundle(const godot::PackedByteArray &bytes,
                                             const godot::PackedByteArray &external_ecp2 = godot::PackedByteArray());
    godot::Dictionary request_runtime_stop(bool preserve_day_boundary = false);
    // True while the worker holds ACTIVE authority over the Climate domain, so
    // the main-thread Climate schedule must not run. Read straight off the host
    // rather than from a bundle field: a value injected by GDScript is a frame
    // stale, and a stale `false` would run a duplicate Climate day while the
    // worker is already producing one.
    bool climate_worker_authoritative() const;
    // The main-thread Climate schedule gate: authoritative, or ACTIVE Climate
    // requested and the worker's first day not yet committed.
    bool climate_main_thread_suppressed() const;
    bool climate_physics_authoritative() const;
    godot::Dictionary get_climate_physics_commit_info() const;
    godot::Dictionary get_climate_physics_read_view() const;
    // Applies the newest worker-committed Climate day into the DataCore slots
    // and flushes them to MapData. This is the main-thread half of ACTIVE
    // Climate: without it the worker would own the domain while MapData stayed
    // frozen at the day authority was granted.
    //
    // `after_generation` is the caller's cursor; pass the value returned in
    // "generation" by the previous successful call. Non-blocking, and a no-op
    // when the worker has not committed a newer day.
    godot::Dictionary apply_runtime_climate_writeback(int64_t after_generation);
    void finish_runtime_display_frame();
    RuntimeCommit _runtime_display_commit;
    std::shared_ptr<const RuntimeResourceDisplayPatch> _runtime_display_resources;
    std::shared_ptr<const RuntimeCommit> _runtime_map_display_commit;
    // B8 P3: block until the worker has evaluated environment generation
    // `after_environment_generation` (plan attempt, not necessarily a commit).
    // timeout_ms < 0 waits until the condition or a terminal worker state;
    // >= 0 is one bounded slice that the caller loops over while pumping
    // main-thread peer transport between slices.
    godot::Dictionary wait_climate_consumed(
        int64_t after_environment_generation, int64_t timeout_ms = -1);
    // P1：环境帧预发布器用的只读探测（"现在还能不能再塞一帧"）。**不加锁、不阻塞**
    // —— 内部 ring 的 has_capacity() 临界区只有一次 deque::size()。返回 false 表示
    // 调用方本帧应当放弃发布，下一帧再试，绝不等待。
    bool environment_ring_has_capacity() const;
    // P1：worker 已提交日。预发布器的上界要按"已提交"算，而不是"已发布"——
    // 环里未消费的帧只是内存，不是事实。
    int64_t runtime_committed_day() const;
    // Day the next environment frame must carry (-1 without a runtime host).
    int64_t runtime_next_environment_day() const;
    int64_t request_runtime_calendar_day(int64_t date);
    bool runtime_climate_writeback_self_test() const;
    bool runtime_snapshot_ring_self_test() const;
    bool runtime_domain_pod_self_test() const;
    bool runtime_authoritative_domains_self_test() const;
    bool runtime_climate_authority_self_test() const;
    bool runtime_climate_trace_self_test() const;
    // Returns a Dictionary rather than a bool: a parity failure needs its
    // reason to be actionable, and a bare false is what let earlier gaps sit
    // behind a green light.
    godot::Dictionary runtime_climate_parity_contract_test() const;
    // B8 P0: proves the worker kernel's canonical stage order and the
    // production native-daily graph order are the same contract. A single
    // reorder on either side fails here instead of surfacing as a numerical
    // divergence weeks later.
    godot::Dictionary runtime_climate_stage_order_contract_test() const;
    bool runtime_country_pod_authority_self_test() const;
    bool runtime_protocol_guard_self_test() const;
    bool runtime_trigger_pod_self_test() const;
    bool runtime_effect_pod_self_test() const;
    bool runtime_effect_host_stage_self_test();
    // M2b G-1: pins the Effect-intent -> Modifier-POD adapter mapping (TRIGGER,
    // FAMILY_EFFECT, GENERIC) against EffectRuntime::dispatch_native_modifier.
    bool runtime_effect_adapter_parity_self_test();
    bool runtime_ideology_pod_self_test() const;
    bool runtime_events_authority_self_test() const;
    bool runtime_economy_pod_self_test() const;
    godot::Dictionary switch_economy_authority(const godot::String &mode);
    bool runtime_economy_authority_fault_gate_self_test() const;
    // Exercises the shared effect target selector on a synthetic hex grid so
    // target selection is verifiable without a live map_data / epoch run.
    bool runtime_economy_target_selector_self_test() const;
    // MetricMask (infra item L0-1) capacity self check: proves ids past the
    // old 64 ceiling are addressable. Pure value-type assertions, no world
    // state, so it can run before any catalog is configured.
    bool runtime_metric_mask_self_test() const;
    bool arm_runtime_fault_injection(const godot::String &point);
    void clear_runtime_fault_injection();
    godot::Dictionary runtime_economy_stage_order_contract_test() const;
    // ② Native finalizer kernel for the round-complete delta-cap + thermal-init loops.
    godot::Dictionary run_native_daily_finalizer(godot::Dictionary knobs);
    godot::Dictionary run_native_sim_tick(const godot::Dictionary &ctx);
    godot::Dictionary get_native_daily_report() const;
    godot::Dictionary get_native_shadow_diff_report() const;
    godot::Dictionary native_ocean_physical_begin(const godot::Dictionary &ctx);
    godot::Dictionary native_ocean_physical_step(const godot::Dictionary &ctx);
    godot::Dictionary native_ocean_physical_finish(const godot::Dictionary &ctx);
    godot::Dictionary reset_native_ocean_physical_state(godot::String reason);
    godot::Dictionary get_native_ocean_physical_state_report() const;
    godot::Dictionary get_native_ocean_physical_hot_state() const;
    // 生成收尾 facade 引导链融合（dots-boot-facade-2026-10）：一次调用完成
    // habitat 掩码 → 河口羽流 → 矿藏储量 → 资源研究信号 CSR → 生态 province+播种
    // → 诊断聚合。子 pass 全部复用已验收实现，中间量不出 C++。
    // 输入/输出契约见 world_ext_boot_facade.cpp 顶部注释。
    godot::Dictionary run_boot_facade_pass(const godot::Dictionary &knobs);
    godot::Dictionary get_native_dirty_report() const;
