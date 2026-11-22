// Included inside namespace pk by runtime_pod_protocol.h.
struct RuntimeThreadReport {
    uint32_t domain_abi_version = RUNTIME_DOMAIN_ABI_VERSION;
    uint32_t pod_domain_abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    RuntimeWorkerState state = RuntimeWorkerState::STOPPED;
    RuntimeSimulationMode mode = RuntimeSimulationMode::OFF;
    // native_daily_inline：日屏障由调用线程逐日执行，本 host 没有 worker 线程。
    // 这个位置是结构体尾部之前的最后一个标量块，追加字段不影响任何既有调用点。
    bool inline_daily = false;
    bool graph_coverage_complete = false;
    // Coverage is a prerequisite, not proof that the worker owns gameplay
    // authority.  This remains false until every daily domain has a native
    // POD handler and the worker has completed the full barrier.
    bool authority_ready = false;
    uint32_t required_domain_mask = RUNTIME_ALL_DOMAIN_MASK;
    uint32_t implemented_domain_mask = 0;
    uint32_t missing_domain_mask = RUNTIME_ALL_DOMAIN_MASK;
    // Per-domain authority. `authority_ready` above keeps its whole-graph
    // meaning: it stays false until every domain has a POD handler. A domain
    // whose parity is proven can be promoted on its own before that, which is
    // what these two describe.
    //
    //   requested   = the mask the caller asked to own at start()
    //   authoritative = the subset the worker has actually proven at a barrier
    //
    // Main-thread schedule gates read `authoritative_domain_mask`, never
    // `authority_ready`; a partial promotion must suppress exactly the
    // promoted domains and leave the rest on the main thread.
    uint32_t requested_authority_mask = 0;
    uint32_t authoritative_domain_mask = 0;
    // Domains that performed real ACTIVE work this session (sticky OR bits).
    // Distinct from completed_domain_mask / granted authority.
    uint32_t active_evidence_mask = 0;
    char graph_coverage_state[32]{};
    char coverage_blocker[64]{};
    bool interactive = false;
    bool paused = true;
    double speed_days_per_second = 0.0;
    int64_t committed_day = 0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    uint64_t last_commit_produced_at_us = 0;
    // Main-thread visual timings are fed back through the facade. They stay in
    // the POD report so CSV/diagnostic consumers have one stable namespace.
    double ui_input_to_feedback_ms = 0.0;
    double visual_apply_ms = 0.0;
    double gpu_upload_ms = 0.0;
    // Facade calls are intentionally non-blocking.  Keep this explicit in
    // the report so a future bridge cannot silently introduce a wait.
    uint64_t main_wait_on_sim_us = 0;
    std::array<uint64_t, 10> worker_time_us{};
    uint64_t environment_generation = 0;
    int64_t environment_day = 0;
    uint32_t environment_cell_count = 0;
    bool environment_topology_validated = false;
    uint64_t invalid_environment_rejected = 0;
    uint64_t input_capture_count = 0;
    uint64_t input_capture_reused = 0;
    uint64_t input_capture_generation = 0;
    int64_t input_capture_day = -1;
    uint64_t input_capture_hash = 0;
    uint64_t gameplay_effect_generation = 0;
    uint32_t gameplay_effect_pending = 0;
    uint32_t gameplay_effect_terminal = 0;
    uint64_t gameplay_effect_state_hash = 0;
    uint64_t stale_environment_rejected = 0;
    uint64_t command_queue_capacity_exceeded = 0;
    uint64_t receipt_queue_capacity_exceeded = 0;
    uint64_t worker_fault_count = 0;
    uint64_t completed_days = 0;
    uint32_t day_stage_count = 0;
    uint32_t day_completed_stage_count = 0;
    uint64_t day_work_units = 0;
    // SHADOW-only worker ABI diagnostics. These fields describe the pure POD
    // pipeline even while implemented_domain_mask correctly remains partial.
    uint32_t pod_completed_domain_mask = 0;
    uint32_t pod_completed_stage_count = 0;
    uint64_t pod_work_units = 0;
    uint32_t pod_intent_count = 0;
    uint32_t pod_fallback_count = 0;
    bool economy_pod_ready = false;
    bool economy_pod_committed = false;
    bool economy_pod_authority_ready = false;
    int64_t economy_pod_committed_day = -1;
    int64_t economy_pod_epoch_sample_day = -1;
    uint64_t economy_pod_generation = 0;
    uint64_t economy_pod_state_hash = 0;
    uint64_t economy_pod_input_generation = 0;
    uint64_t economy_pod_country_generation = 0;
    uint32_t economy_pod_completed_stage_mask = 0;
    uint32_t economy_pod_pending_outbox = 0;
    uint32_t economy_pod_pending_inbox = 0;
    uint32_t economy_pod_operation_gate_mask = 0;
    uint32_t economy_pod_parity_ready_mask = 0;
    // Phase-2.1 mirror completeness (EconomyPodMirrorFeature bits).
    uint32_t economy_pod_mirror_feature_mask = 0;
    uint32_t economy_pod_committed_ledger_abi = 0;
    bool economy_pod_active_ready = false;
    uint64_t economy_authority_switch_count = 0;
    uint64_t economy_authority_switch_before_hash = 0;
    uint64_t economy_authority_switch_after_hash = 0;
    uint64_t economy_authority_switch_latency_us = 0;
    // Rolling latency evidence for the accepted authority handoffs. The
    // scalar above is the last sample; these aggregates are computed from the
    // bounded worker-owned ring so long-running soak tests can assert p95/max
    // without retaining unbounded history.
    uint64_t economy_authority_switch_latency_p95_us = 0;
    uint64_t economy_authority_switch_latency_max_us = 0;
    // Time from the last accepted command admission to the completed authority
    // handoff. This stays zero when the boundary had no command traffic.
    uint64_t economy_authority_switch_command_latency_us = 0;
    uint64_t economy_authority_switch_command_latency_p95_us = 0;
    uint64_t economy_authority_switch_command_latency_max_us = 0;
    uint64_t economy_authority_switch_latency_sample_count = 0;
    uint64_t economy_authority_switch_rejected = 0;
    uint64_t economy_authority_switch_audit_sequence = 0;
    uint64_t economy_authority_switch_audit_hash = 0;
    uint64_t economy_authority_switch_before_generation = 0;
    uint64_t economy_authority_switch_after_generation = 0;
    uint64_t fault_injection_trip_count = 0;
    bool fault_injection_armed = false;
    char fault_injection_point[64]{};
    uint32_t economy_inflight_mutations = 0;
    uint32_t worker_day_inflight = 0;
    uint32_t economy_pending_command_count = 0;
    bool economy_authority_fault_paused = false;
    uint64_t economy_authority_last_committed_generation = 0;
    uint64_t economy_authority_last_committed_hash = 0;
    char economy_authority_switch_reason[64]{};
    char economy_authority_switch_blocker[64]{};
    char economy_authority_switch_audit_before[128]{};
    char economy_authority_switch_audit_after[128]{};
    uint32_t completion_gate_missing_domain_mask = 0;
    bool active_gate_blocked = false;
    // Phase-1 Economy execution mode + SHADOW StageOps accounting.
    uint32_t economy_execution_mode = 0; // EconomyExecutionMode ordinal
    bool economy_shadow_probe_enabled = false;
    uint64_t economy_shadow_stage_invocations = 0;
    uint64_t economy_shadow_stage_cache_hits = 0;
    // Phase-2.4.1: production writer observability. Writer remains
    // compact_slice until StageOps mutate becomes the production loop.
    bool economy_stage_ops_mutate = false;
    bool economy_auto_pod_active = false;
    uint64_t economy_pod_command_recapture_count = 0;
    uint64_t economy_pod_command_verify_count = 0;
    // Phase-5 A+Y: "owned_state" when StageOps formulas alias OwnedState SoA.
    char economy_formula_backing[32]{};
    char economy_production_writer[32]{};
    // Phase-2.4.2: requested vs effective writer (effective stays compact_slice
    // while stage_ops production is gated not-ready).
    char economy_production_writer_requested[32]{};
    char economy_production_writer_effective[32]{};
    // Phase-2.4.4.1: StageOps writer readiness checklist (see
    // ECONOMY_STAGE_OPS_READY_*). PRELUDE bit means API exists; runtime may
    // still need a successful drain before plan_epoch.
    uint32_t economy_stage_ops_readiness_mask = 0;
    bool economy_stage_ops_prelude_ready = false;
    bool economy_stage_ops_soak_experiment = false;
    bool economy_stage_ops_soak_parity_ok = false;
    uint32_t economy_replay_completed_stage_mask = 0;
    uint32_t economy_replay_stage_cursor = 0;
    uint64_t economy_replay_input_hash = 0;
    uint64_t economy_replay_base_hash = 0;
    uint64_t economy_replay_next_hash = 0;
    std::array<uint64_t, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT> economy_replay_stage_hash{};
    std::array<uint64_t, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT> economy_replay_stage_work{};
    std::array<double, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT> economy_replay_stage_ms{};
    bool economy_replay_input_captured = false;
    bool economy_replay_committed = false;
    bool economy_replay_parity_ready = false;
    char economy_replay_fallback_reason[64]{};
    // Worker-published tax/subsidy schedule probe. Epoch millisecond counters
    // reset when the economy epoch metrics clear. Mask bit 0 is income.
    char economy_yield_reason[48]{};
    char economy_stage_name[32]{};
    char economy_substage_name[40]{};
    double economy_epoch_fiscal_ms = 0.0;
    double economy_fiscal_settlement_ms = 0.0;
    double economy_income_subsidy_ms = 0.0;
    uint32_t economy_negative_tax_mask = 0;
    uint32_t economy_active_tax_mask = 0;
    uint32_t economy_attempt_slices = 0;
    // Consolidated SHADOW domain-authority runner metrics. These are
    // diagnostic only; implemented_domain_mask remains the promotion gate.
    uint32_t domain_authority_planned_mask = 0;
    uint32_t domain_authority_committed_mask = 0;
    uint32_t domain_authority_ack_count = 0;
    uint64_t domain_authority_input_hash = 0;
    uint64_t domain_authority_state_hash = 0;
    double domain_authority_plan_ms = 0.0;
    double domain_authority_replay_ms = 0.0;
    char domain_authority_fallback_reason[64]{};
    uint32_t domain_stage_fallback_count = 0;
    char domain_stage_fallback_reason[64]{};
    bool climate_pod_ready = false;
    double climate_pod_plan_ms = 0.0;
    double climate_pod_replay_ms = 0.0;
    uint64_t climate_pod_work_units = 0;
    uint32_t climate_pod_changed_cells = 0;
    uint64_t climate_pod_state_hash = 0;
    uint64_t climate_pod_reference_hash = 0;
    bool climate_pod_parity_compared = false;
    bool climate_pod_parity_matched = false;
    uint64_t climate_pod_parity_mismatch_count = 0;
    char climate_pod_parity_reason[64]{};
    int64_t climate_parity_day = -1;
    uint16_t climate_parity_stage = 0;
    uint32_t climate_parity_cell = 0;
    uint64_t climate_parity_input_generation = 0;
    uint64_t climate_parity_base_generation = 0;
    uint64_t climate_parity_trace_hash = 0;
    char climate_parity_field[48]{};
    char climate_parity_reference_bits[24]{};
    char climate_parity_worker_bits[24]{};
    char climate_pod_fallback_reason[64]{};
    // 1 << RuntimeClimateStage 的位掩码。差集（production & ~worker）= "生产算了、
    // worker 没算"，这是分叉矩阵里 stage 9..13 那些字段唯一可信的归因来源；缺了它
    // "worker 缺实现"和"这一天生产本来也没跑"在矩阵上长得一模一样。
    int32_t climate_production_stage_mask = 0;
    int32_t climate_worker_stage_mask = 0;
    // ── B8-2：worker 自持 cyclone 的当日事实 ─────────────────────────────
    // alive = 当天推进/淘汰后仍在 store blob 里的条目数；injected/replaced 是
    // 当天 genesis 的动作；decayed 是推进淘汰数；touched 是 stamp 覆盖格数。
    // 这四个数让 soak/C3 的 JSON 能直接判定"气旋有没有非平凡演化"，不必去
    // 解析 stderr 的 [climate/worker][b8] 诊断。
    int32_t climate_cyclone_alive = 0;
    int32_t climate_cyclone_injected = 0;
    int32_t climate_cyclone_replaced = 0;
    int32_t climate_cyclone_decayed = 0;
    int32_t climate_cyclone_touched = 0;
    // 逐 stage 的 worker 侧耗时与工作量，索引即 RuntimeClimateStage。
    // RuntimeClimateVerticalReport 早就有这两条，但没进 ThreadReport，GDScript 因此
    // 拿不到任何 per-stage 数据，performance.csv 只能记一个总的 climate_pod_plan_ms。
    // ACTIVE 下"哪个 stage 变慢了"必须能在不重编译的情况下回答。
    std::array<double, static_cast<size_t>(
        pk_async_climate::CLIMATE_STAGE_SLOT_COUNT)> climate_stage_ms{};
    std::array<uint64_t, static_cast<size_t>(
        pk_async_climate::CLIMATE_STAGE_SLOT_COUNT)> climate_stage_work{};
    // ── B8 P0：Climate 交付游标 ──────────────────────────────────────────
    // `climate_committed_day` 是 worker Climate store 的日，不是 worker 时钟；
    // `climate_consumed_generation` 统计 worker 实际尝试过 plan 的环境代次
    // （成功失败都算），所以主线程可以问"这一天输入被看到没有"，而不必等提交成功。
    //
    // environment_* 把"worker 慢"与"输入被覆盖/溢出"分开：FIFO ring 下未消费深度 =
    // pending；溢出丢弃 = dropped；SHADOW force 覆盖 = superseded。
    int64_t climate_committed_day = -1;
    uint64_t climate_consumed_generation = 0;
    uint64_t environment_published_days = 0;
    uint64_t environment_consumed_days = 0;
    uint64_t environment_superseded_days = 0;
    uint64_t environment_dropped_days = 0;
    uint64_t environment_ring_pending = 0;
    // Composite stall reason for the day under worker evaluation (see
    // RUNTIME_DAY_STALL_*). Derived + sticky peer bits; 0 when the day is free.
    uint32_t day_stall_reason_mask = 0;
    int64_t day_stall_day = -1;
    uint64_t day_stall_peer_ms = 0;
    // 最后一个卡住 worker 的日计划缺口（`requested_authority_mask &
    // ~day_commit.completed_domain_mask`）。day_stall_reason_mask 只说「在等什么
    // 外部输入」，缺一个 stall 位时它恒为 0；这张 mask 才点名「哪个域的阶段还没
    // 完成」。注意与上面的 missing_domain_mask 不是一回事：那个是「handler 没实现」，
    // 这个是「今天这个阶段没跑完」。worker 侧只写不改，主线程只读。
    int64_t day_wait_day = -1;
    uint32_t day_wait_missing_mask = 0;
    int64_t day_wait_env_day = -1;
    uint32_t day_wait_ring = 0;
    // 哪个域、因为哪一行而放弃今天。有些 park 分支只 `stage.completed = 0`
    // 就 continue，不设 stall 位也不写 fallback reason；没有这两个字段，
    // 「日历推不动」在日志里就完全没有归因。
    uint32_t day_park_domain_mask = 0;
    char day_park_reason[48]{};
    // 被永久拒绝并丢弃的 Effect 实例（见 drain_effect_transport_queues）。计数非零
    // 说明有内容级缺陷，但日历不会再因此冻结。
    uint64_t effect_instance_rejected_count = 0;
    char effect_instance_reject_detail[96]{};
    uint64_t climate_wait_total_ms = 0;
    uint64_t climate_wait_last_ms = 0;
    uint64_t climate_wait_max_ms = 0;
    uint32_t command_queue_depth = 0;
    uint32_t receipt_queue_depth = 0;
    double time_debt_days = 0.0;
    uint32_t climate_trace_depth = 0;
    int64_t climate_trace_front_day = -1;
    int64_t climate_trace_lag_days = 0;
    uint64_t climate_trace_latest_hash = 0;
    uint64_t climate_trace_capacity_exceeded = 0;
    uint64_t climate_trace_consumed = 0;
    uint64_t climate_trace_missing = 0;
    uint32_t climate_trace_captured = 0;
    uint32_t climate_trace_reference_ready = 0;
    uint32_t climate_trace_consumable = 0;
    uint64_t climate_trace_reference_rejected = 0;
    uint64_t climate_trace_reference_pending = 0;
      uint32_t executor_workers = 0;
      uint64_t country_pod_snapshot_generation = 0;
      uint64_t country_pod_state_hash = 0;
      uint64_t country_pod_work_units = 0;
      uint32_t country_pod_active_country_count = 0;
      uint32_t country_pod_active_index_count = 0;
    uint32_t country_pod_pending_checks = 0;
    bool country_pod_ack_pending = false;
    char country_pod_blocker[64]{};
    // Country worker transport status is copied into the immutable report
    // snapshot by NativeSimulationHost::report().  The Godot formatter must
    // only consume these fields; it cannot reach back into the host object.
    bool country_worker_configured = false;
    bool country_worker_plan_active = false;
    bool country_worker_waiting_for_peer = false;
    uint32_t country_worker_pending_intents = 0;
    uint32_t country_worker_queued_intents = 0;
    uint32_t country_worker_result_count = 0;
    uint32_t country_worker_rejected_results = 0;
    uint64_t country_worker_session_epoch = 0;
    uint64_t country_worker_country_generation = 0;
    int64_t country_worker_day = -1;
    uint32_t country_worker_continuation_index = 0;
    uint64_t country_worker_boundary_id = 0;
    uint64_t country_worker_last_admitted_submit_order = 0;
    uint64_t country_worker_expected_base_generation = 0;
    uint64_t country_worker_catalog_hash = 0;
    bool country_worker_authoritative = false;
    char country_worker_last_reason[64]{};
    uint8_t country_parity_compared = 0;
    uint8_t country_parity_matched = 0;
    uint64_t country_parity_compared_count = 0;
    uint64_t country_parity_matched_count = 0;
    int64_t country_parity_first_mismatch_day = -1;
    uint64_t country_parity_reference_hash = 0;
    uint64_t country_parity_worker_hash = 0;
    int32_t country_parity_index = -1;
    char country_parity_status[64]{};
    char country_parity_field[48]{};
    // Ideology parity, mirroring the country pair.
    bool ideology_parity_compared = false;
    bool ideology_parity_matched = false;
    int64_t ideology_parity_compared_count = 0;
    int64_t ideology_parity_matched_count = 0;
    uint64_t ideology_parity_reference_hash = 0;
    uint64_t ideology_parity_worker_hash = 0;
    int64_t ideology_parity_first_mismatch_day = -1;
    // R8-4: worker days with no reference on the same calendar day. A run whose
    // calendars disagree must be visible as uncompared, never as matched.
    int64_t ideology_parity_uncompared_day_offset = 0;
    char ideology_parity_field[48]{};
    // Raw numbers behind a `points*` parity field. Empty until a mismatch lands,
    // then it keeps the FIRST differing country row so a failure is readable
    // from the report alone instead of requiring a debugger rerun. Plain POD:
    // this header is deliberately free of any godot dependency.
    bool ideology_parity_points_diff_valid = false;
    int64_t ideology_parity_points_diff_day = -1;
    int64_t ideology_parity_points_diff_slot = -1;
    int64_t ideology_parity_points_diff_reference_countries = 0;
    int64_t ideology_parity_points_diff_worker_countries = 0;
    int64_t ideology_parity_points_diff_handle = 0;
    int64_t ideology_parity_points_diff_reference_handle = 0;
    int64_t ideology_parity_points_diff_worker_handle = 0;
    int64_t ideology_parity_points_diff_reference_points_q16 = 0;
    int64_t ideology_parity_points_diff_worker_points_q16 = 0;
    int64_t ideology_parity_points_diff_reference_lifetime_q16 = 0;
    int64_t ideology_parity_points_diff_worker_lifetime_q16 = 0;
    int64_t ideology_parity_points_diff_reference_revision = 0;
    int64_t ideology_parity_points_diff_worker_revision = 0;
    int32_t ideology_parity_points_diff_reference_baseline_ready = 0;
    int32_t ideology_parity_points_diff_worker_baseline_ready = 0;
    int64_t ideology_parity_points_diff_reference_baseline_population = 0;
    int64_t ideology_parity_points_diff_worker_baseline_population = 0;
    int64_t ideology_parity_points_diff_reference_baseline_buildings = 0;
    int64_t ideology_parity_points_diff_worker_baseline_buildings = 0;
    int32_t ideology_parity_points_diff_reference_history_count = 0;
    int32_t ideology_parity_points_diff_worker_history_count = 0;
    int32_t ideology_parity_points_diff_reference_history_head = 0;
    int32_t ideology_parity_points_diff_worker_history_head = 0;
    std::array<int64_t, 8> ideology_parity_points_diff_reference_history_q16{};
    std::array<int64_t, 8> ideology_parity_points_diff_worker_history_q16{};
    int64_t ideology_parity_points_diff_reference_last_day = -1;
    int64_t ideology_parity_points_diff_worker_round_day = -1;
    int64_t ideology_parity_points_diff_worker_committed_day = -1;
    int64_t ideology_parity_points_diff_reference_catalog_hash = 0;
    int64_t ideology_parity_points_diff_worker_catalog_hash = 0;
    int64_t ideology_parity_reference_publish_count = 0;
    int64_t ideology_parity_reference_published_day = -1;
    int64_t ideology_parity_reference_published_countries = 0;
    int32_t ideology_parity_reference_published_with_points_revision = 0;
    int64_t ideology_parity_reference_skipped_count = 0;
    char ideology_parity_reference_skip_reason[48]{};
    // Catalog agreement is a comparison precondition, not a business field.
    int64_t ideology_parity_catalog_mismatch_count = 0;
    int64_t ideology_parity_last_reference_catalog_hash = 0;
    int64_t ideology_parity_last_worker_catalog_hash = 0;
    int64_t ideology_parity_worker_opinion_revision = 0;
    // A1: the period the worker actually consumed, and the commit day of that
    // opinion. A driver uses these to bind the main thread to the SAME input.
    int64_t ideology_parity_worker_opinion_period_index = -1;
    int64_t ideology_parity_worker_opinion_committed_day = -1;
    int64_t ideology_parity_worker_committed_day = -1;
    int64_t ideology_parity_paired_reference_day = -1;
    int64_t ideology_parity_paired_worker_day = -1;
    int64_t ideology_parity_row_mismatch_slot = -1;
    int64_t ideology_parity_row_mismatch_reference_handle = 0;
    int64_t ideology_parity_row_mismatch_worker_handle = 0;
    int64_t ideology_parity_row_mismatch_reference_points = 0;
    int64_t ideology_parity_row_mismatch_worker_points = 0;
    bool modifier_pod_ready = false;
    double modifier_pod_plan_ms = 0.0;
    double modifier_pod_replay_ms = 0.0;
    uint64_t modifier_pod_work_units = 0;
    uint64_t modifier_pod_state_hash = 0;
    uint64_t modifier_pod_snapshot_generation = 0;
    uint32_t modifier_pod_ack_count = 0;
    char modifier_pod_fallback_reason[64]{};
    // F7 SHADOW Effect Host stage telemetry. Effect remains outside
    // implemented_domain_mask until F8; these fields only prove the worker
    // day stage ran and never grant ACTIVE authority.
    bool effect_pod_ready = false;
    double effect_pod_plan_ms = 0.0;
    double effect_pod_replay_ms = 0.0;
    uint64_t effect_pod_state_hash = 0;
    uint64_t effect_pod_snapshot_generation = 0;
    uint32_t effect_pod_ack_count = 0;
    uint32_t effect_pod_intent_count = 0;
    uint32_t effect_pod_managed_intent_count = 0;
    uint32_t effect_pod_unmanaged_intent_count = 0;
    uint32_t effect_pod_program_intent_count = 0;
    std::array<int32_t, RUNTIME_EFFECT_INTENT_PROGRAM_REPORT_CAPACITY>
        effect_pod_intent_program_ids{};
    uint32_t effect_pod_transaction_count = 0;
    // Retire requests that found nothing to retire (absent instance) versus
    // ones whose generation had already been superseded. Both are benign
    // no-ops that mirror EffectRuntime::retire_instance_pod, but a non-zero
    // stale count means an install raced a retire and is worth investigating.
    uint64_t effect_retire_absent_count = 0;
    uint64_t effect_retire_stale_count = 0;
    char effect_pod_fallback_reason[64]{};
    bool ideology_pod_ready = false;
    double ideology_pod_plan_ms = 0.0;
    double ideology_pod_replay_ms = 0.0;
    uint64_t ideology_pod_state_hash = 0;
    uint64_t ideology_pod_snapshot_generation = 0;
    uint32_t ideology_pod_pending_transition_count = 0;
    uint32_t ideology_pod_intent_count = 0;
    // Worker days Ideology skipped because Economy had no committed opinion yet.
    uint32_t ideology_opinion_wait_days = 0;
    // Day the worker last committed IDEOLOGY for. -1 means it never ran.
    //
    // `IdeologyParityReport` has a same-named field, but that one is assigned only
    // while a parity reference is being recorded, so a production session -- and any
    // fixture that never completes a parity day -- leaves it at -1 forever. This copy
    // is the POD's own committed day (`_ideology_pod_committed_day`), i.e. the field a
    // caller can use to ask "has the worker finished day N yet".
    int64_t ideology_pod_committed_day = -1;
    char ideology_pod_fallback_reason[64]{};
    bool events_probe_enabled = false;
    bool events_pod_ready = false;
    double events_pod_plan_ms = 0.0;
    double events_pod_replay_ms = 0.0;
    uint64_t events_pod_state_hash = 0;
    uint64_t events_pod_snapshot_generation = 0;
    uint32_t events_pod_event_count = 0;
    uint32_t events_pod_ack_count = 0;
    uint64_t events_pod_drop_count = 0;
    uint64_t events_pod_rejected_count = 0;
    int64_t events_failed_day = -1;
    char events_pod_fallback_reason[64]{};
    // Trigger POD SHADOW parity. These fields are diagnostic only and never
    // contribute to implemented_domain_mask or authoritative_domain_mask.
    int64_t trigger_parity_day = -1;
    int64_t trigger_reference_day = -1;
    uint64_t trigger_input_hash = 0;
    uint64_t trigger_reference_input_hash = 0;
    uint64_t trigger_reference_state_hash = 0;
    uint64_t trigger_worker_state_hash = 0;
    uint64_t trigger_reference_effect_hash = 0;
    uint64_t trigger_worker_effect_hash = 0;
    uint32_t trigger_required_ack_count = 0;
    uint32_t trigger_received_ack_count = 0;
    uint32_t trigger_pending_ack_count = 0;
    uint64_t trigger_generation = 0;
    int64_t trigger_committed_day = -1;
    int64_t trigger_acked_effect_id = 0;
    uint32_t trigger_pending_command_count = 0;
    uint8_t trigger_parity_compared = 0;
    uint8_t trigger_parity_matched = 0;
    int32_t trigger_first_divergence_index = -1;
    char trigger_first_divergence_kind[32]{};
    char trigger_blocker[64]{};
    // H7/H8 ACTIVE Trigger stage. The parity fields above describe the POD
    // authority against the synchronous reference frame; these describe the
    // worker stage that owns it.
    bool trigger_pod_ready = false;
    double trigger_pod_plan_ms = 0.0;
    double trigger_pod_replay_ms = 0.0;
    uint64_t trigger_pod_state_hash = 0;
    uint64_t trigger_pod_snapshot_generation = 0;
    uint32_t trigger_pod_intent_count = 0;
    uint32_t trigger_pod_ack_count = 0;
    char trigger_pod_fallback_reason[64]{};
    // ── Web-worker P0/P2 观测字段 ──────────────────────────────────────────
    // Country peer 结果的解析归属。`in_worker` 由 worker 自己的
    // resolve_pending_country_effect_peers() 提升（P2 目标形态），`by_main`
    // 由主线程泵提升（今天的形态）。两者长期同时为 0 而 pending_intents > 0
    // 就是"peer 谁都没在推进"，必须能看见。
    uint64_t country_peer_resolved_in_worker = 0;
    uint64_t country_peer_resolved_by_main = 0;
    char fault_code[64]{};
};

