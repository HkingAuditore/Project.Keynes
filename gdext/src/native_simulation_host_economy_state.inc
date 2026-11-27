// Economy replay, parity, command verification, and worker production state.

    std::atomic<bool> _economy_pod_ready{false};
    std::atomic<bool> _economy_pod_committed{false};
    std::atomic<bool> _economy_pod_authority_ready{false};
    std::atomic<int64_t> _economy_pod_committed_day{-1};
    std::atomic<int64_t> _economy_pod_epoch_sample_day{-1};
    std::atomic<uint64_t> _economy_pod_generation{0};
    std::atomic<uint64_t> _economy_pod_state_hash{0};
    std::atomic<uint64_t> _economy_pod_input_generation{0};
    std::atomic<uint64_t> _economy_pod_country_generation{0};
    std::atomic<uint32_t> _economy_pod_completed_stage_mask{0};
    std::atomic<uint32_t> _economy_pod_pending_outbox{0};
    std::atomic<uint32_t> _economy_pod_pending_inbox{0};
    std::atomic<uint32_t> _economy_pod_operation_gate_mask{0};
    std::atomic<uint32_t> _economy_pod_parity_ready_mask{0};
    std::atomic<bool> _economy_sync_writes_forbidden{false};
    std::atomic<uint32_t> _economy_replay_completed_stage_mask{0};
    std::atomic<uint32_t> _economy_replay_stage_cursor{0};
    std::atomic<uint64_t> _economy_replay_input_hash{0};
    std::atomic<uint64_t> _economy_replay_base_hash{0};
    std::atomic<uint64_t> _economy_replay_next_hash{0};
    std::array<std::atomic<uint64_t>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_replay_stage_hash{};
    std::array<std::atomic<uint64_t>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_replay_stage_work{};
    std::array<std::atomic<double>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_replay_stage_ms{};
    std::atomic<bool> _economy_replay_input_captured{false};
    std::atomic<bool> _economy_replay_committed{false};
    std::atomic<bool> _economy_replay_parity_ready{false};
    std::array<std::atomic<char>, 64> _economy_replay_fallback_reason{};
    std::atomic<int64_t> _economy_reference_day{-1};
    std::atomic<uint64_t> _economy_reference_generation{0};
    std::atomic<uint64_t> _economy_reference_hash{0};
    std::array<std::atomic<uint64_t>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_stage_reference_hash{};
    std::array<std::atomic<uint64_t>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_stage_reference_work{};
    std::array<std::atomic<uint8_t>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_stage_reference_present{};
    RuntimeEconomyPodAuthority _economy_pod_authority;
    // Worker-only capture buffer for the daily non-bound mirror; swapped with
    // the POD publication each day so lane storage is reused, not reallocated.
    RuntimeEconomyLedgerState _economy_mirror_capture_scratch;
    std::unique_ptr<EconomyGraphStageOps> _economy_stage_ops;
    // Default ACTIVE_ONLY; StageOps mutate/writer are armed at worker start
    // (Phase-2.4.5 defaults: mutate=true, writer=stage_ops).
    std::atomic<uint32_t> _economy_execution_mode{
        static_cast<uint32_t>(EconomyExecutionMode::ACTIVE_ONLY)};
    std::atomic<bool> _economy_shadow_probe_enabled{false};
    std::atomic<bool> _economy_stage_ops_mutate{false};
    std::atomic<bool> _economy_auto_pod_active{false};
    std::atomic<bool> _economy_ecp2_dual_write{true};
    std::atomic<bool> _economy_ecp2_mid_epoch_save{false};
    std::atomic<bool> _economy_ecp2_authority{false};
    std::atomic<uint64_t> _economy_authority_switch_count{0};
    std::atomic<uint64_t> _economy_authority_switch_before_hash{0};
    std::atomic<uint64_t> _economy_authority_switch_after_hash{0};
    std::atomic<uint64_t> _economy_authority_switch_latency_us{0};
    std::atomic<uint64_t> _economy_authority_switch_latency_p95_us{0};
    std::atomic<uint64_t> _economy_authority_switch_latency_max_us{0};
    std::atomic<uint64_t> _economy_authority_switch_command_latency_us{0};
    std::atomic<uint64_t> _economy_authority_switch_command_latency_p95_us{0};
    std::atomic<uint64_t> _economy_authority_switch_command_latency_max_us{0};
    std::atomic<uint64_t> _economy_authority_switch_latency_sample_count{0};
    std::array<std::atomic<uint64_t>,
               ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY>
        _economy_authority_switch_latency_samples{};
    std::array<std::atomic<uint64_t>,
               ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY>
        _economy_authority_switch_command_latency_samples{};
    // The write cursor is published after both sample slots are written.
    // Authority switches are serialized by _economy_authority_boundary_mutex;
    // readers only need acquire ordering and never wait on this ring.
    std::atomic<uint64_t> _economy_authority_switch_latency_sample_write{0};
    std::atomic<uint64_t> _economy_authority_switch_rejected{0};
    std::atomic<uint64_t> _economy_authority_switch_audit_sequence{0};
    std::atomic<uint64_t> _economy_authority_switch_audit_hash{0};
    std::atomic<uint64_t> _economy_authority_switch_before_generation{0};
    std::atomic<uint64_t> _economy_authority_switch_after_generation{0};
    std::atomic<uint64_t> _economy_authority_last_committed_generation{0};
    std::atomic<uint64_t> _economy_authority_last_committed_hash{0};
    std::atomic<bool> _economy_authority_fault_paused{false};
    std::array<std::atomic<char>, 64> _economy_authority_switch_reason{};
    std::array<std::atomic<char>, 64> _economy_authority_switch_blocker{};
    std::array<std::atomic<char>, 128> _economy_authority_switch_audit_before{};
    std::array<std::atomic<char>, 128> _economy_authority_switch_audit_after{};
    // A switch is valid only while the worker is between semantic day plans.
    // These counters make that boundary observable instead of inferring it
    // from the command ring alone (the worker owns a private pending vector).
    std::atomic<uint32_t> _worker_day_inflight{0};
    std::atomic<uint32_t> _economy_inflight_mutations{0};
    std::atomic<uint32_t> _economy_pending_command_count{0};
    std::atomic<uint64_t> _last_command_admitted_us{0};
    // Serializes the semantic-day transaction with an explicit Economy
    // authority handoff.  The counters above are diagnostic evidence; this
    // mutex is the actual epoch-boundary gate that prevents a switch from
    // passing an idle check while the worker starts the next day.
    mutable std::mutex _economy_authority_boundary_mutex;
    // Twice the last sealed day, with the low bit marking an input publication.
    std::atomic<int64_t> _command_seal{-2};
    std::atomic<int64_t> _economy_input_requested_day{-1};
    // Sticky peer/fiscal stall bits (OR). Climate-capacity is derived live.
    std::atomic<uint32_t> _day_stall_reason_mask{0};
    std::atomic<int64_t> _day_stall_day{-1};
    std::atomic<uint64_t> _day_stall_peer_since_us{0};
    uint64_t _last_peer_stall_warning = 0;
    // Last day-plan gap seen by the retry loop. Written by the worker, read by
    // the main-thread report; monotonically overwritten, never cleared -- a
    // stale value still names the last stage that held the calendar, which is
    // what a post-mortem needs (day_stall_reason_mask can be 0 the whole time).
    std::atomic<int64_t> _day_wait_day{-1};
    std::atomic<uint32_t> _day_wait_missing_mask{0};
    std::atomic<int64_t> _day_wait_env_day{-1};
    std::atomic<uint32_t> _day_wait_ring{0};
    // P2：Country peer 解析归属与 deferred 计数。谁来推进 peer 是 web 能不能
    // 并行起来的分水岭，所以必须在报告里是可数的，而不是靠日志猜。
    std::atomic<uint64_t> _country_peer_resolved_in_worker{0};
    std::atomic<uint64_t> _country_peer_resolved_by_main{0};
    // 为什么某个域的阶段今天没完成。有些 park 分支（Effect 等 Climate、Effect
    // 目录未就绪）只是 `stage.completed = 0; continue;`，既不设 stall 位也不写
    // fallback reason，日志里完全无痕；这一对字段把它们点名。
    std::atomic<uint32_t> _day_park_domain_mask{0};
    std::array<std::atomic<char>, 48> _day_park_reason{};
    // 被永久拒绝的 Effect 实例（validate_instance 不通过）。这些行会被丢弃而不是
    // 回队，否则 Effect 阶段永远在同一行失败、把日历钉死；计数与字段快照是为了
    // 回头修产生端。
    std::atomic<uint64_t> _effect_instance_rejected_count{0};
    std::array<std::atomic<char>, 96> _effect_instance_reject_detail{};
    std::atomic<uint64_t> _economy_input_signal{0};
    std::atomic<uint64_t> _economy_pod_command_recapture_count{0};
    std::atomic<uint64_t> _economy_pod_command_verify_count{0};
    // Phase-2.4.4.4 soak experiment flag (observability). Parity latch defaults
    // true after Phase-2.4.5 dual-path handoff.
    std::atomic<bool> _economy_stage_ops_soak_experiment{false};
    std::atomic<bool> _economy_stage_ops_soak_parity_ok{true};
    std::atomic<uint32_t> _economy_production_writer_requested{
        static_cast<uint32_t>(EconomyProductionWriter::STAGE_OPS)};
    std::atomic<uint32_t> _economy_production_writer_effective{
        static_cast<uint32_t>(EconomyProductionWriter::STAGE_OPS)};
    // Phase-2.4.4.2: StageOps Host day-loop continuation (ACTIVE writer path).
    enum class StageOpsDayPhase : uint8_t {
        Prelude = 0,
        PlanEpoch = 1,
        AdvanceStages = 2,
        CommitEpoch = 3,
        Done = 4,
    };
    int64_t _stage_ops_day_index = -1;
    uint64_t _stage_ops_day_input_generation = 0;
    StageOpsDayPhase _stage_ops_day_phase = StageOpsDayPhase::Done;
    std::atomic<uint8_t> _stage_ops_day_phase_atomic{
        static_cast<uint8_t>(StageOpsDayPhase::Done)};
    std::atomic<uint64_t> _economy_shadow_stage_invocations{0};
    std::atomic<uint64_t> _economy_shadow_stage_cache_hits{0};
    // Parity stage-result cache keyed by (sample_day, input_generation).
    // Avoids re-running SHADOW StageOps for the same frozen input workset.
    int64_t _economy_shadow_cache_day = -1;
    uint64_t _economy_shadow_cache_input_generation = 0;
    uint64_t _economy_shadow_cache_country_generation = 0;
    uint64_t _economy_shadow_cache_catalog_hash = 0;
    bool _economy_shadow_cache_valid = false;
    std::unique_ptr<EconomyPodCommandExecutor> _economy_pod_command_executor;
    // Non-owning: DCWorldExt's NativeEconomyRuntime, ACTIVE production only.
    NativeEconomyRuntime *_economy_production_runtime = nullptr;
    ModifierRuntime *_economy_modifier_view = nullptr;
    void refresh_economy_modifier_view(const RuntimeModifierPodSnapshot &snapshot);
