// Owner wiring, command ingestion, and published day tail queries.

    // ACTIVE production: point at the live NativeEconomyRuntime formula owner.
    // StageOps mutate flag is independent; default attach is mutate=false and
    // production mutations use worker_run_compact_slice.
    // Lifecycle boundary only: do not detach/reset the command executor while
    // a worker can still use it. request_stop() does not join that worker.
    void attach_economy_production_runtime(class NativeEconomyRuntime *rt) noexcept;
    // Worker economy's own ModifierRuntime (owned by DCWorldExt), refreshed by
    // the modifier stage so economy day D reads modifier day D.
    void attach_economy_modifier_view(ModifierRuntime *view) noexcept { _economy_modifier_view = view; }
    bool economy_production_runtime_attached() const noexcept {
        return _economy_production_runtime != nullptr;
    }
    // Country AI planner owned by DCWorldExt. Under ACTIVE+COUNTRY the worker
    // plans AI commands for day D from Country committed through D-1, queues
    // them with producer COUNTRY_AI_PRODUCER_ID before plan_day, and commits
    // the AI memory only when the Country day commits.
    void attach_country_ai_runtime(class CountryAiRuntime *runtime) noexcept {
        _country_ai_runtime.store(runtime, std::memory_order_release);
    }
    // Phase 4+: POD queue admits opcodes 1..23; commit_pending_commands applies
    // via EconomyPodCommandExecutor. Under POD_ACTIVE, opcodes 1–23 mutate
    // OwnedState first then pull into NativeEconomyRuntime (heavy opcodes
    // delegate apply then mirror). Host verifies hash/shape and recaptures only
    // on mismatch. Phase-5 binds population/market to OwnedState sole SoA.
    // Sync submit_commands remains a separate facade — do not double-submit.
    bool submit_economy_pod_command(const RuntimeEconomyPodCommand &command,
                                    std::string &error);
    bool poll_economy_pod_receipt(RuntimeEconomyPodReceipt &out) noexcept;
    const RuntimeEconomyPodReceipt *economy_pod_terminal(uint64_t request) const {
        return _economy_pod_authority.terminal_receipt(request);
    }
    void set_economy_sync_writes_forbidden(bool forbidden) noexcept;
    int64_t economy_input_requested_day() const noexcept {
        return _economy_input_requested_day.load(std::memory_order_acquire);
    }
    bool economy_worker_owns_execution() const noexcept override;
    std::unique_lock<std::mutex> try_lock_economy_input_capture() {
        return std::unique_lock<std::mutex>(
            _economy_authority_boundary_mutex, std::try_to_lock);
    }
    void attach_bio_state(std::shared_ptr<struct RuntimeBioState> state) {
        _executor_bio = std::move(state);
    }
    void attach_military(std::shared_ptr<NativeMilitaryRuntime> military);
    void attach_vision(std::shared_ptr<VisionResearchState> vision);
    bool restore_vision_seed(std::vector<uint8_t> &explored, bool &enabled,
                             uint64_t &player_handle, bool &checkpoint_found) const;
    bool restore_bio_seed(std::vector<int32_t> &occupancy) const;
    std::shared_ptr<const RuntimeVisionFrame> latest_vision() const;
    bool submit_fog_command(bool enabled, int64_t &effective_day);
    bool vision_executor_active() const noexcept;
    godot::Dictionary submit_economy_boundary_request(std::shared_ptr<RuntimeEconomyBoundaryRequest> request);
    bool military_executor_active() const noexcept;
    bool submit_military_commands(std::shared_ptr<MilitaryCommandBatch> batch);
    uint64_t allocate_command_request_id_for_ingress() override;
    void seed_events_ingress_cursor(int64_t next) noexcept {
        _events_ingress_cursor.store(next, std::memory_order_release);
    }
    int64_t events_ingress_cursor() const noexcept {
        return _events_ingress_cursor.load(std::memory_order_acquire);
    }
    int64_t allocate_events_ingress_key() noexcept {
        return _events_ingress_cursor.fetch_add(1, std::memory_order_relaxed);
    }
    bool enqueue_legacy_event_batch(const std::vector<RuntimeEventsRecord> &records,
                                    int64_t effective_day, uint64_t generation,
                                    std::string &error);
    bool has_bio_state() const noexcept { return bool(_executor_bio); }
    void reset_day_tail_for_world_change();
    void request_economy_read_view();
    bool has_resource_display_patch() const;
    RuntimeResourceDisplayPatch take_resource_display_patch();
    // The caller retains the day-tail gate until it consumes this result.
    // The queued computation owns value data and never uses a scene object.
    std::unique_lock<std::mutex> try_lock_economy_read_boundary() const;
    void complete_economy_input_capture() noexcept {
        {
            std::lock_guard<std::mutex> control_lock(_control_mutex);
            _economy_input_requested_day.store(-1, std::memory_order_release);
            _economy_input_signal.fetch_add(1, std::memory_order_release);
        }
        _control_cv.notify_all();
    }
    bool publish_country_catalog(const RuntimeCountryPodCatalog &catalog,
                                 std::string &error);
    bool country_pod_configured() const override {
        return _country_pod_configured.load(std::memory_order_acquire);
    }
