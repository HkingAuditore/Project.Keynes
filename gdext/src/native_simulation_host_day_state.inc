// Day execution, published state, narrative boundary, and climate input capture state.

    struct CommandQueueSlot {
        RuntimeCommandPacket packet{};
    };

    struct ClimateParityFieldAccumulator {
        std::atomic<uint64_t> diverged_days{0};
        std::atomic<uint64_t> compared_days{0};
        std::atomic<uint64_t> diverged_cells{0};
        std::atomic<uint64_t> out_of_band_cells{0};
        std::atomic<uint64_t> out_of_band_days{0};
        std::atomic<int64_t> first_diverged_day{-1};
        std::atomic<int64_t> first_out_of_band_day{-1};
        std::atomic<uint32_t> first_cell{0};
        std::atomic<uint32_t> last_diverged_cells{0};
        std::atomic<uint32_t> last_out_of_band_cells{0};
        std::atomic<double> max_abs_delta{0.0};
        std::atomic<double> max_out_of_band_delta{0.0};
        std::array<std::atomic<char>, 24> first_reference_bits{};
        std::array<std::atomic<char>, 24> first_worker_bits{};
    };

    std::atomic<RuntimeWorkerState> _state{RuntimeWorkerState::STOPPED};
    mutable std::mutex _annual_mutex;
    AnnualDevelopmentLedger _annual_ledger;
    std::shared_ptr<const AnnualReportPublication> _published_annual;
    bool _annual_history_changed = false;
    void publish_annual_view_locked();
    std::atomic<bool> _annual_enabled{false};
    std::atomic<uint64_t> _annual_country{0};
    uint64_t _annual_queued_reward = 0;
    std::atomic<RuntimeSimulationMode> _mode{RuntimeSimulationMode::OFF};
    // native_daily_inline：单线程内联日。见公开区同名注释。
    std::atomic<bool> _inline_daily_mode{false};
    // 内联日分域计时累加器。只在内联模式下写（worker 日恒为 0），执行者恒是
    // 同一个调用线程，所以不需要原子；run_inline_day() 在每次尝试开始时清零、
    // 结束时抄进 InlineDayOutcome。
    std::array<double, RUNTIME_DOMAIN_STAGE_COUNT> _inline_stage_ms{};
    double _inline_pre_stage_ms = 0.0;
    double _inline_climate_ms = 0.0;
    // 本次尝试是否被单日墙钟预算看门狗掐断（见 execute_day_plan 的预算检查）。
    bool _inline_budget_exceeded = false;
    std::atomic<bool> _stop_requested{false};
    std::atomic<bool> _paused{true};
    std::atomic<bool> _interactive{false};
    std::atomic<double> _speed_days_per_second{0.0};
    std::atomic<bool> _graph_coverage_complete{false};
    std::atomic<uint32_t> _requested_authority_mask{0};
    static_assert((RUNTIME_ALL_DOMAIN_MASK & ~0xffffu) == 0u,
                  "authority control mask capacity exceeded");
    RuntimeAuthorityControl _authority_control;
    // True once a worker lifetime actually started on this host. Together with a
    // non-zero `lifetime_granted_mask()` it is the positive proof that `start()` is a
    // RESTART of a world this host already ran (see the resume-day block in
    // `start()`), as opposed to a fresh world on a reused host.
    std::atomic<bool> _has_started_once{false};
    std::atomic<uint32_t> _active_evidence_mask{0};
    std::atomic<uint32_t> _completion_gate_missing_domain_mask{0};
    std::atomic<bool> _active_gate_blocked{false};
    std::atomic<int64_t> _committed_day{0};
    std::atomic<uint64_t> _generation{0};
    // Slow readers can keep this commit while the worker publishes a new one.
    std::shared_ptr<const RuntimeCommit> _latest_commit;
    std::shared_ptr<RuntimeDayTail> _executor_day_tail;
    std::shared_ptr<VisionResearchState> _executor_vision;
    const char *stage_vision(DayExecution &day);
    const char *stage_effect_adapter(DayExecution &day);
    const char *stage_trigger_delivery(DayExecution &day);
    const char *stage_ideology_projection(DayExecution &day);
    std::shared_ptr<const RuntimeIdeologyReadView> capture_ideology_read_view() const;
    const char *settle_era_rewards(DayExecution &day);
    bool suppress_event_popups_on(int64_t day) const;
    const char *player_confirmation_block(int64_t published_day = -1);
    RuntimePlayerConfirmation _player_confirmation;
    uint64_t confirmation_country() const;
    uint32_t player_ideology_offer() const;
    bool ideology_response_queued(uint32_t generation) const;
    void prepare_player_ideology_responses(int64_t day, bool opinion_missing);
    bool service_player_confirmations();
    bool player_response_admits(int64_t day) const;
    void admit_player_response_through(int64_t day);
    void finish_player_confirmation_day(int64_t day);
    std::vector<uint8_t> encode_player_confirmation(int64_t day) const;
    static bool decode_player_confirmation(const std::vector<uint8_t> &bytes, int64_t day,
                                           RuntimePlayerConfirmation *state);
    bool service_annual_presentations();
    void execute_era_advancement_request(RuntimeEraRewardRequest &request);
    bool install_era_advancement_setup();
    const char *stage_era_advancement(DayExecution &day);
    const char *stage_prepare_environment(DayExecution &day);
    std::shared_ptr<const RuntimeEnvironmentSnapshot> executor_environment_for_day(int64_t day);
    void capture_climate_display(RuntimeClimateSnapshot &out) const;
    bool settle_player_regime(RuntimeEraAdvancement &state, int32_t regime, int64_t day);
    bool submit_era_milestone(RuntimeEraAdvancement &state, int32_t era,
        int64_t requested, int64_t effective, int64_t sequence, bool consume_goods);
    bool service_era_reward_requests();
    void prepare_era_advancement_day(int64_t day);
    const char *stage_narrative(DayExecution &);
    bool service_narrative_requests();
    void request_stop_locked();
    void publish_narrative_boundary(int64_t);
    const char *narrative_input_block(bool suppress_popups) const;
    struct NarrativeDay sample_narrative_day(int64_t) const;
    void sample_narrative_military(struct NarrativeCountryView &) const;
    bool prepare_narrative_day(int64_t);
    godot::Dictionary resolve_narrative_choice(int64_t, const godot::Dictionary &);
    bool dispatch_narrative_independence(int64_t);
    std::shared_ptr<const RuntimeEraRewardView> capture_era_reward() const;
    EffectRuntime *_effect_adapter_runtime = nullptr;
    class NativeCountryRuntime *_effect_adapter_country = nullptr;
    RuntimeTriggerDelivery _trigger_delivery;
    void apply_fog_commands(const std::vector<RuntimeCommandPacket> &commands);
    bool submit_vision_observations(uint64_t country, int64_t day,
                                    std::vector<uint64_t> &observations);
    bool submit_species_observations(int64_t day, const std::vector<int32_t> &cells,
                                      const std::vector<int32_t> &signals, int32_t &submitted);
    bool enqueue_batch_at(std::vector<RuntimeCommandPacket> packets,
                          std::vector<int64_t> *effective_days, bool seal,
                          const std::function<bool()> &admit_peer = {});
    std::shared_ptr<NativeMilitaryRuntime> _executor_military;
    std::deque<std::shared_ptr<MilitaryCommandBatch>> _military_commands; // _control_mutex
    std::deque<std::shared_ptr<RuntimeEconomyBoundaryRequest>> _economy_boundary_requests;
    std::deque<std::shared_ptr<RuntimeEconomyBoundaryRequest>> _colonization_read_results;
    bool _colonization_quotes_ready = false;
    std::deque<std::shared_ptr<RuntimeEraRewardRequest>> _era_reward_requests;
    std::deque<uint64_t> _annual_presentations;
    std::deque<std::shared_ptr<RuntimeNarrativeRequest>> _narrative_requests;
    godot::Array _boundary_command_results;
    void publish_boundary_command_result(const char *command, int64_t sequence,
                                         godot::Dictionary result);
    std::shared_ptr<class RuntimeNarrative> _executor_narrative;
    godot::Dictionary _restored_narrative;
    std::shared_ptr<const RuntimeNarrativeView> _published_narrative;
    std::shared_ptr<const RuntimeEraRewardView> _published_era_reward;
    std::shared_ptr<RuntimeEraAdvancement> _era_advancement;
    std::shared_ptr<const RuntimeEraAdvancementView> _published_era_advancement;
    std::shared_ptr<RuntimeEraRewardRequest> _era_advancement_bind, _era_advancement_restore;
    bool player_requests_pending_locked() const noexcept;
    bool service_economy_boundary_requests();
    void service_economy_read_view();
    bool _economy_read_view_requested = false; // protected by _control_mutex
    const std::vector<uint8_t> *colonization_visibility() const override;
    std::atomic<int64_t> _events_ingress_cursor{1};
    bool service_military_commands();
    const char *stage_military(DayExecution &day);
    void capture_world_continuation(RuntimeSaveBundle &bundle) const;
    std::vector<uint8_t> capture_bio_state() const, capture_vision_state() const;
    std::vector<uint8_t> capture_narrative_save_bytes() const;
    void publish_military_day();
    std::shared_ptr<struct RuntimeBioState> _executor_bio;
    std::vector<int32_t> _executor_resource_display_cells;
    mutable std::mutex _resource_display_mutex;
    RuntimeResourceDisplayPatch _resource_display_patch;
    // M4/M5 diagnostics. These fields describe the frozen input manifest and
    // the committed visual-intent batch without exposing worker vectors.
    std::atomic<uint64_t> _input_capture_count{0};
    std::atomic<uint64_t> _input_capture_reused{0};
    std::atomic<uint64_t> _input_capture_generation{0};
    std::atomic<int64_t> _input_capture_day{-1};
    std::atomic<uint64_t> _input_capture_hash{0};
    // Worker-owned frozen manifest. The scalar report fields above are the
    // lock-free diagnostic projection; this POD value is retained for the
    // current day barrier and ECP2/checkpoint handoff.
    RuntimeInputCaptureManifest _input_manifest{};
    std::atomic<uint64_t> _gameplay_effect_generation{0};
    std::atomic<uint32_t> _gameplay_effect_pending{0};
    std::atomic<uint32_t> _gameplay_effect_terminal{0};
    std::atomic<uint64_t> _gameplay_effect_state_hash{0};
    std::atomic<uint64_t> _last_commit_produced_at_us{0};
    std::atomic<double> _ui_input_to_feedback_ms{0.0};
    std::atomic<double> _visual_apply_ms{0.0};
    std::atomic<double> _gpu_upload_ms{0.0};
    // The inbox publishes a whole input batch with one write-cursor update.
    std::atomic<uint64_t> _command_enqueue_pos{0};
    std::atomic<uint64_t> _command_dequeue_pos{0};
    std::map<int64_t, std::vector<RuntimeCountryCommand>> _country_observations;
    std::mutex _command_producer_mutex;
    std::vector<RuntimeCommandPacket> _executor_inbox;
    // Monotonic admission order for the shared command boundary. This is
    // independent of producer-local sequence numbers and is Country's final
    // same-day tie-breaker.
    std::atomic<uint64_t> _command_submit_order{0};
    std::atomic<uint64_t> _command_request_id{0};
    // 日执行者（worker，或内联模式的日事务）自己分配的请求号单独计数，并打上
    // EXECUTOR_REQUEST_ID_TAG。和主线程入口共用一个计数器时，两边谁先取号取决于
    // 帧时序，号码又进了 Economy 财政日志和哈希。
    static constexpr uint64_t EXECUTOR_REQUEST_ID_TAG = 1ull << 62;
    std::atomic<uint64_t> _executor_request_id{0};
    std::array<CommandQueueSlot, RUNTIME_COMMAND_QUEUE_CAPACITY> _command_slots{};
    std::array<std::atomic<uint64_t>, 256> _producer_sequences{};
    std::atomic<uint64_t> _fallback_producer_sequence{0};
    std::atomic<uint64_t> _receipt_write{0};
    std::atomic<uint64_t> _receipt_read{0};
    std::array<RuntimeCommandReceipt, RUNTIME_RECEIPT_QUEUE_CAPACITY> _receipts{};

    mutable std::mutex _control_mutex;
    std::condition_variable _control_cv;
    // B8 P3：主线程交付等待专用。不能复用 _control_cv —— worker 的日循环也在
    // 同一个 CV 上等 preflight 重试，而 worker 自己在消费环境后 notify 会让它
    // 自唤醒自旋（实测 50 天内 3200 万次不提交的重试）。
    std::condition_variable _climate_wait_cv;
    RuntimeThreadRetirement _retired_workers;
    std::thread _worker;
    std::shared_ptr<std::atomic<bool>> _worker_returned =
        std::make_shared<std::atomic<bool>>(true);
    std::shared_ptr<const RuntimeEnvironmentSnapshot> _environment_snapshot;
    RuntimeEnvironmentInputRing _environment_ring;
    std::shared_ptr<const RuntimeCountryPodSnapshot> _country_snapshot;
    std::shared_ptr<const RuntimeCountryPodSnapshot> _country_committed_snapshot;
    // Economy conservation / opening·VERIFY pins. Updated only by sealed
    // authority publishes — never by peer-wait plan preview.
    std::shared_ptr<const RuntimeCountryPodSnapshot> _country_economy_audit_snapshot;
    std::shared_ptr<const CountryCoreCheckpoint> _country_checkpoint;
    mutable std::shared_ptr<const RuntimeCountryPodDiagnostics> _country_pod_diagnostics;
    std::atomic<uint64_t> _environment_generation{0};
    std::atomic<int64_t> _environment_day{0};
    std::atomic<uint32_t> _environment_cell_count{0};
    std::atomic<bool> _environment_topology_validated{false};
    std::atomic<uint64_t> _invalid_environment_rejected{0};
    std::atomic<uint64_t> _stale_environment_rejected{0};
    // B8 P0 delivery cursors. `published` counts accepted publishes; `consumed`
    // counts plan attempts (not commits) so the main thread can wait for an
    // input to be *seen* without requiring the day to succeed. `superseded`
    // counts published days that a newer publish overwrote before the worker
    // planned against them — the single latest-value slot's silent loss.
    std::atomic<uint64_t> _environment_published_days{0};
    std::atomic<uint64_t> _environment_consumed_days{0};
    std::atomic<uint64_t> _environment_superseded_days{0};
    std::atomic<uint64_t> _environment_dropped_days{0};
    std::atomic<uint64_t> _climate_consumed_generation{0};
    // 上一个被记录进 environment_consumed_days 的代次。无效天重试会反复评估同一
    // 份环境；把它算成"消费了一天"会让计数变成重试次数而不是交付天数。
    std::atomic<uint64_t> _climate_last_counted_generation{0};
    std::atomic<uint64_t> _climate_wait_total_ms{0};
    std::atomic<uint64_t> _climate_wait_last_ms{0};
    std::atomic<uint64_t> _climate_wait_max_ms{0};
    RuntimeClimateTrace _climate_trace;
    std::atomic<uint64_t> _climate_trace_latest_hash{0};
    std::atomic<uint64_t> _climate_trace_consumed{0};
    std::atomic<uint64_t> _climate_trace_missing{0};
    // Incremented whenever the main thread releases a reference-backed trace
    // frame. The worker waits on this value at the day barrier, so a missing
    // reference never degenerates into a fixed-interval polling loop.
    std::atomic<uint64_t> _climate_trace_signal{0};
