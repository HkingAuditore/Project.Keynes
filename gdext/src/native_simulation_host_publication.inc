// Command queue and committed publication, authority proofs, and climate write-back.

    bool enqueue(RuntimeCommandPacket packet);
    // Country facade batches are a semantic admission unit. The Host checks
    // capacity before publishing any packet and assigns submit_order in the
    // same critical section, so transport chunking cannot split a business
    // batch or change its tie-break order.
    bool enqueue_batch(std::vector<RuntimeCommandPacket> packets, std::vector<int64_t> *effective_days = nullptr) override;
    bool enqueue_modifier_shadow(RuntimeCommandPacket packet);
    uint64_t allocate_command_request_id() override;
    void reserve_command_request_ids_through(uint64_t maximum) noexcept;
    uint64_t allocate_producer_sequence(uint32_t producer_id) override;
    bool poll_commit(uint64_t after_generation, RuntimeCommit &out);
    std::shared_ptr<const RuntimeClimateSnapshot> latest_climate_display() const;
    std::shared_ptr<const struct RuntimeDisplayBatch> take_day_publications(uint64_t after);
    bool poll_receipt(RuntimeCommandReceipt &out);
    bool poll_country_command_receipts(
            uint64_t after_request_id, uint32_t limit,
            std::vector<CountryCommandReceipt> &out);
    // Point lookup for Effect ACK. Cursor polls skip lower Effect terminals
    // once an unrelated Country commit advances the high-water mark.
    void poll_country_command_publications(uint64_t after_sequence, uint32_t limit,
        std::vector<CountryCommandReceipt> &out);
    bool try_country_command_terminal(
            uint64_t request_id, CountryCommandReceipt &out) override;
    bool country_command_receipt_self_test(std::string &error) const;
    bool country_peer_rejection_self_test(std::string &error) const;
    bool publish_country_economy_asset_requests(
            const std::vector<RuntimeEconomyAssetRequest> &requests,
            std::string &error);
    void acknowledge_country_economy_asset_consumed(uint64_t request_id) noexcept override;
    // An Economy continuation that commits Country and applies its own
    // market/merchant/cargo leg in one advance registers its wire id so the
    // generic flush leaves the COMPLETED terminal for the targeted settle.
    void defer_country_economy_asset_settlement(uint64_t request_id) override;
    // The owning continuation was abandoned: hand the wire id back to the
    // generic flush so its terminal still retires.
    void release_country_economy_asset_settlement(uint64_t request_id) noexcept override;
    bool country_economy_asset_settlement_deferred(uint64_t request_id) const override;
    void set_country_economy_asset_protocol_error_locked(
            RuntimeEconomyAssetProtocolError code, uint64_t transaction_id,
            uint64_t request_id, const char *reason) noexcept;
    bool request_save(uint64_t request_id);
    std::shared_ptr<const RuntimeSaveBundle> poll_save(uint64_t request_id);
    bool save_failed(uint64_t request_id) const {
        return request_id != 0 &&
            _save_failed_request_id.load(std::memory_order_acquire) == request_id;
    }
    std::string save_failure_reason() const;
    bool restore_bundle(const uint8_t *bytes, size_t size, std::string &error,
                        const uint8_t *external_ecp2 = nullptr, size_t external_ecp2_size = 0,
                        bool *recovered_truncated_ecp2 = nullptr);

    // Main-thread visual instrumentation is an atomic write-only feedback
    // path. It never touches worker-owned stores and never waits for the
    // simulation thread.
    void record_visual_timings(double ui_input_to_feedback_ms,
                               double visual_apply_ms,
                               double gpu_upload_ms);
    RuntimeThreadReport report() const;
    RuntimeWorkerTiming::MainWaitDays main_waits_by_day() const {
        return _worker_timing.main_wait_snapshot();
    }
    RuntimeGoldenSnapshot golden_snapshot() const;
    RuntimeGoldenSnapshot capture_golden_snapshot(int64_t day) const;
    void publish_restored_ideology_view();
    void profile_save_window(bool active) { _worker_timing.save(active); }
    bool stop_requested() const {
        return _stop_requested.load(std::memory_order_acquire);
    }
    // Reports the compile-time POD barrier coverage. This is deliberately
    // independent from the caller's graph_coverage_complete hint.
    static constexpr uint32_t implemented_domain_mask() {
        // Which domains have a real POD handler -- NOT which ones are currently
        // authoritative. Those are three different masks and conflating them
        // misreads the whole migration state:
        //   implemented (here)        compile-time; a domain may be listed and
        //                             still run in SHADOW only.
        //   requested_authority_mask  per-session, from the start() caller; must
        //                             be a subset of this one.
        //   completed_domain_mask     per-day report of what actually ran.
        // M5: all twelve domains have a bounded POD handler and participate
        // in the same frozen-input -> continuation -> atomic-COMMIT barrier.
        // This is the implementation capability mask; a session still has to
        // request a subset and prove it at a commit before it is granted.
        // Production requests the complete graph (0xFFF); focused diagnostics
        // may still request a smaller subset. Contract:
        // authoritative & EFFECT => worker is the sole Effect writer; snapshot
        // write-back targets legacy EffectRuntime; only effect_runtime /
        // run_effect_daily is suppressed. IDEOLOGY follows the same shape
        // against NativeIdeologyRuntime, TRIGGER_INPUT against TriggerRuntime.
        // MODIFIER intents ACK in-worker; Ideology's and Trigger's
        // EFFECT-targeted intents ACK in-worker after the Effect stage and
        // through the main-thread pump; other domains use the main-thread intent
        // pump. EVENTS is a worker-authority mirror only: the POD store owns the
        // stage bit, snapshot, and consumer cursor. The legacy
        // GameplayEventBus facade remains available only for explicit recovery
        // and compatibility reads.
        // ECONOMY owns ACTIVE production via attach_economy_production_runtime
        // + worker_run_compact_slice (same NativeEconomyRuntime formula owner).
        // StageOps stay mutate=false for SHADOW POD parity hashes only.
        // Main-thread economy_should_run is suppressed when worker-authoritative
        // AND the production runtime pointer is attached (fail-open to sync
        // otherwise).
        return runtime_domain_mask(RuntimeDomainId::INPUT_CAPTURE)
            | runtime_domain_mask(RuntimeDomainId::CLIMATE)
            | runtime_domain_mask(RuntimeDomainId::COUNTRY)
            | runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)
            | runtime_domain_mask(RuntimeDomainId::IDEOLOGY)
            | runtime_domain_mask(RuntimeDomainId::EFFECT)
            | runtime_domain_mask(RuntimeDomainId::MODIFIER)
            | runtime_domain_mask(RuntimeDomainId::GAMEPLAY_EFFECT)
            | runtime_domain_mask(RuntimeDomainId::ECONOMY)
            | runtime_domain_mask(RuntimeDomainId::EVENTS)
            | runtime_domain_mask(RuntimeDomainId::VISUAL)
            | runtime_domain_mask(RuntimeDomainId::COMMIT);
    }
    RuntimeWorkerState state() const override {
        return _state.load(std::memory_order_acquire);
    }
    // Domains this worker has proven at a barrier and now owns. Zero means the
    // main thread still owns every domain. Read by the schedule gate, so it is
    // published only after a commit whose completed_domain_mask covers the
    // request.
    uint32_t authoritative_domain_mask() const {
        return _authority_control.snapshot().granted_mask;
    }
    // Domains a PREVIOUS worker lifetime of this host proved at a barrier and was
    // granted. Both `request_stop()` and `set_fault()` clear the LIVE grant so the
    // main thread takes the domain back while the old worker winds down; this
    // ledger deliberately survives both, because the POD state and the handlers
    // that earned the grant are still installed and a restart resumes on exactly
    // that state. A restart re-publishes `lifetime_granted_mask() & requested`.
    //
    // Fresh worlds keep zero until their first committed day.
    uint32_t lifetime_granted_mask() const {
        return _authority_control.snapshot().proven_mask;
    }
    // Main-thread write-back boundary for ACTIVE Climate. Acquire, copy the
    // fields out, release. Non-blocking: returns false when the worker has not
    // committed a newer day.
    bool try_acquire_climate_writeback(uint64_t after_generation,
                                       uint32_t &slot) {
        return _climate_writeback.try_acquire_latest(after_generation, slot);
    }
    const RuntimeClimateSnapshot &climate_writeback_buffer(uint32_t slot) const {
        return _climate_writeback.read_buffer(slot);
    }
    void release_climate_writeback(uint32_t slot) {
        _climate_writeback.release(slot);
    }
    uint64_t climate_writeback_drop_count() const {
        return _climate_writeback.publish_drop_count();
    }
    static constexpr size_t ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY = 256u;
    // Worker-owned event snapshot boundary.  Consumers use this only after
    // EVENTS has been granted; legacy journal polling remains available for
    // explicit fallback/parity sessions.
    bool events_worker_authoritative() const {
        return domain_is_worker_authoritative(RuntimeDomainId::EVENTS);
    }
    // B8 P3：ACTIVE Climate 的主线程等待边界。
    // - after_generation > 0：等到 worker 已评估过该代次（plan 尝试，不要求提交）。
    // - after_generation == 0：等到输入 ring 有空位（可流水线发布下一天）。
    // timeout_ms < 0 表示等到条件满足；>= 0 是一次有界等待切片。
    //
    // 终止条件（故障保护，不是性能超时）：worker 进入 FAULTED/STOPPING/STOPPED、
    // Climate 权威被撤销、或 stop 被请求。
    bool wait_climate_consumed(uint64_t after_generation, int64_t timeout_ms,
                               uint64_t &consumed_generation,
                               std::string &error);
    void note_climate_writeback_input_generation(uint64_t generation) {
        _climate_writeback_input_generation.store(generation,
                                                   std::memory_order_release);
    }
    // Main-thread callers see live admission. Within an executor call, routing
    // keeps that call's data owners even if another thread requests stop.
    bool domain_is_worker_authoritative(RuntimeDomainId domain) const override {
        return (RuntimeExecutionContext::domains_for(this,
                    authoritative_domain_mask()) & runtime_domain_mask(domain)) != 0u;
    }
    // 主线程是否停推这个域：worker 已权威，或 ACTIVE 请求了该域、worker 仍在跑、但还
    // 没有一日提交覆盖它（授权窗口）。窗口里主线程若照常跑该域，它写进 MapData 的结果
    // 和镜像进命令环的命令（如 Country AI 决策）会被 worker 首日读走，读走多少取决于
    // 线程时机。stop/fault 撤销授权时窗口关闭，域交还主线程。
    bool domain_main_thread_suppressed(RuntimeDomainId domain) const override {
        if (domain_is_worker_authoritative(domain)) return true;
        if (_mode.load(std::memory_order_acquire) != RuntimeSimulationMode::ACTIVE ||
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(domain)) == 0u ||
            _stop_requested.load(std::memory_order_acquire)) {
            return false;
        }
        const RuntimeWorkerState s = state();
        return s == RuntimeWorkerState::STARTING || s == RuntimeWorkerState::RUNNING ||
               s == RuntimeWorkerState::PAUSED || s == RuntimeWorkerState::SAVE_PENDING;
    }

    // Snapshot of one field's cumulative divergence. Read on the main thread
    // while the worker keeps writing, so the counters are individually atomic
    // and a caller must not read cross-field invariants into them.
    struct ClimateParityFieldStatus {
        uint64_t diverged_days = 0;
        uint64_t compared_days = 0;
        uint64_t diverged_cells = 0;
        // Cells whose difference exceeds the field's tolerance band. For a
        // BITWISE field this equals diverged_cells; for a banded field it is
        // the subset that still needs explaining.
        uint64_t out_of_band_cells = 0;
        uint64_t out_of_band_days = 0;
        int64_t first_diverged_day = -1;
        int64_t first_out_of_band_day = -1;
        uint32_t first_cell = 0;
        uint32_t last_diverged_cells = 0;
        uint32_t last_out_of_band_cells = 0;
        double max_abs_delta = 0.0;
        double max_out_of_band_delta = 0.0;
        char first_reference_bits[24]{};
        char first_worker_bits[24]{};
    };
    ClimateParityFieldStatus climate_parity_field_status(size_t index) const;
    uint64_t climate_parity_forced_days() const {
        return _climate_parity_forced_days.load(std::memory_order_acquire);
    }
