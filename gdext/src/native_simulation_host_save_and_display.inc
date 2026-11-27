// Save/restore requests, accepted backlog, displayed day, and worker report state.

    uint64_t _country_read_view_generation = 0;
    uint64_t _country_read_view_patch_base_generation = 0;
    // View generation of the newest publish whose territory patch was non-empty.
    // A consumer behind the patch base still does not need a full owner copy
    // when this generation is already at or behind the consumer cursor.
    uint64_t _country_read_view_territory_generation = 0;
    uint32_t _country_read_view_dirty_families = 0;
    std::vector<int32_t> _country_read_view_changed_cells;
    std::vector<int32_t> _country_read_view_changed_owners;
    std::atomic<bool> _events_probe_enabled{false};

    std::atomic<bool> _save_requested{false};
    std::atomic<uint64_t> _save_request_id{0};
    // Separate acknowledgement makes each published bundle consumable once.
    mutable std::atomic<uint64_t> _save_consumed_request_id{0};
    std::atomic<uint64_t> _save_failed_request_id{0};
    // Save rejection may leave a healthy runtime; it is separate from _fault_code.
    std::array<std::atomic<char>, 64> _save_failure_reason{};
    std::shared_ptr<const RuntimeSaveBundle> _save_bundle;
    RuntimeSaveBundle _pending_restore_bundle;
    bool _has_pending_restore = false;
    // Accepted world backlog; the active executor has exclusive access.
    std::vector<RuntimeCommandPacket> _executor_pending_commands;
    std::shared_ptr<const RuntimeEnvironmentSnapshot> _executor_day_environment;
    std::shared_ptr<class RuntimeWorldEnvironment> _world_environment;
    static constexpr int64_t CALENDAR_LOOKAHEAD = 8;
    std::atomic<int64_t> _clock_requested_day{-1};
    std::atomic<bool> _calendar_suspended{true};
    std::atomic<int64_t> _display_consumed_day{-1};
    std::shared_ptr<const RuntimeDisplayBatch> _published_display;
    std::shared_ptr<struct RuntimeFiscalHistory> _display_finances;
    godot::Array _display_notices;
    std::vector<uint8_t> _executor_cell_lut_pending;
    std::vector<std::array<uint32_t, 4>> _cell_lut_words;
    void publish_cell_lut_changes(RuntimeDayTail &tail, const RuntimeDayTail *previous);
    std::atomic<bool> _inline_day_pending{false};
    std::vector<RuntimeCommandPacket> _prestart_modifier_commands;

    std::atomic<uint64_t> _command_queue_capacity_exceeded{0};
    std::atomic<uint64_t> _receipt_queue_capacity_exceeded{0};
    RuntimeWorkerTiming _worker_timing;
    RuntimeDayWaterfall _day_waterfall;
    std::atomic<uint64_t> _worker_fault_count{0};
    std::atomic<uint64_t> _completed_days{0};
    std::atomic<uint32_t> _last_day_stage_count{0};
    std::atomic<uint32_t> _last_day_completed_stages{0};
    std::atomic<uint64_t> _last_day_work_units{0};
    std::atomic<uint32_t> _pod_completed_domain_mask{0};
    std::atomic<uint32_t> _pod_completed_stage_count{0};
    std::atomic<uint64_t> _pod_work_units{0};
    std::atomic<uint32_t> _pod_intent_count{0};
    std::atomic<uint32_t> _pod_fallback_count{0};
