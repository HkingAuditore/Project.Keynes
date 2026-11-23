// Included inside NativeSimulationHost. Executor stages and private boundary operations.
    struct DayExecution;
    RuntimeDayCommit execute_shadow_day(DayExecution &);
    void prepare_climate_day(DayExecution &);
    bool capture_day_input(DayExecution &, const RuntimeEnvironmentSnapshot &);
    bool run_day_events(DayExecution &, int64_t);
    bool stage_input_capture(DayExecution &, RuntimeDomainPlan &);
    bool stage_climate(DayExecution &, RuntimeDomainPlan &);
    bool stage_country(DayExecution &, RuntimeDomainPlan &);
    void publish_country_input_rejections();
    bool stage_trigger_input(DayExecution &, RuntimeDomainPlan &);
    bool stage_ideology(DayExecution &, RuntimeDomainPlan &);
    bool stage_effect(DayExecution &, RuntimeDomainPlan &);
    bool stage_modifier(DayExecution &, RuntimeDomainPlan &);
    bool stage_gameplay_effect(DayExecution &, RuntimeDomainPlan &);
    bool stage_economy(DayExecution &, RuntimeDomainPlan &);
    bool stage_events(DayExecution &, RuntimeDomainPlan &);
    bool stage_visual(DayExecution &, RuntimeDomainPlan &);
    bool stage_commit(DayExecution &, RuntimeDomainPlan &);
    const char *stage_natural_resource_recovery(DayExecution &);
    void merge_resource_display_patch(RuntimeResourceDisplayPatch &patch) const;
    void publish_display_batch(std::shared_ptr<const RuntimeCommit> commit,
                               const RuntimeDayRecord &record);
    void reset_display_batch();
    const char *stage_bio_occupancy(DayExecution &);
    static uint64_t now_us();
    static uint64_t mix_hash(uint64_t value, uint64_t input);
    // A worker publishes STOPPED immediately before returning.  Reusing a
    // host must not make the Godot thread join that already-finished handle;
    // the handle is handed to a detached reaper instead.  Destruction waits
    // for reapers after requesting stop, so the host object remains alive for
    // the last instruction of the old worker.
    bool reap_completed_worker_nonblocking();
    void worker_main();
    // Inline and worker preserve accepted backlogs and share the ordering rule.
    void drain_inline_day_commands(int64_t day,
                                   std::vector<RuntimeCommandPacket> &day_commands,
                                   std::vector<RuntimeCommandReceipt> &day_receipts,
                                   uint64_t &admitted_submit_order);
    RuntimeDayPlan build_day_plan(int64_t day, double speed_scale, const RuntimeEnvironmentSnapshot *environment,
                                  uint64_t command_watermark = 0) const;
    RuntimeDayCommit execute_day_plan(
            RuntimeDayPlan &plan,
            const RuntimeEnvironmentSnapshot *environment,
            const std::vector<RuntimeCommandPacket> &day_commands,
            std::vector<RuntimeCommandReceipt> &day_receipts,
            uint64_t admitted_submit_order);
    bool execute_country_worker_stage(
            int64_t day, uint64_t input_generation,
            const std::vector<RuntimeCommandPacket> &day_commands,
            RuntimeDayCommit &commit, std::string &error,
            uint64_t admitted_submit_order);
    void bind_shadow_country_peer_mirrors_locked();
    void record_country_parity_locked(const RuntimeCountryPodSnapshot &worker);
    // Drain Economy-origin CREATED requests into COUNTRY_PREPARED + pollable
    // queue. Country stage and Economy same-day retry share this helper so a
    // fiscal/asset enqueue cannot park the worker until the next day attempt
    // (which used to fill the Climate input ring and pin WorldClock).
    // Returns how many origin requests were prepared (0 = queue was empty).
    uint32_t prepare_economy_origin_country_assets(std::string &error);
    bool country_authority_drain_idle_locked() const;
    void queue_country_milestone_notifications_locked(
        const std::shared_ptr<const RuntimeCountryPodSnapshot> &snapshot);
    // How one Ideology day ended. Only PARKED retries the day; FAULT means the
    // stage's inputs can never arrive (no catalog, no Country snapshot, a day
    // before the POD's committed day), so retrying would only hang.
    enum class IdeologyStageOutcome : uint8_t {
        COMMITTED,
        ALREADY_COMMITTED,  // a parked day planned again; the POD settled it
        AWAITING_OPINION,   // Economy has not committed an opinion yet
        PARKED,
        FAULT,
    };
    IdeologyStageOutcome execute_ideology_worker_stage(int64_t day,
                                                       RuntimeDayCommit &commit,
                                                       std::string &error);
    // Real Ideology -> Modifier bridge (replaced the synthetic OK ACK; used when the
    // worker also owns MODIFIER). Transition rows are resolved against the
    // Modifier catalog up front (all-or-nothing), submitted as one atomic
    // Modifier batch, and the Ideology ACK is derived from the committed
    // Modifier batch result.
    void stage_ideology_modifier_commands(int64_t day,
                                          uint64_t input_generation);
    void settle_ideology_modifier_acks(
        const std::vector<uint8_t> &batch_ok, bool committed);
    bool ideology_modifier_bridge_active() const;
    bool execute_trigger_worker_stage(int64_t day, uint64_t input_generation,
                                      RuntimeDayCommit &commit,
                                      std::string &error);
    // Day-local publish of Trigger effect intents. Ids are monotonic inside the
    // authority and a discarded plan replays the same ones, so the watermark is
    // what stops an ACK-barrier retry from queueing a duplicate.
    void publish_trigger_intents_locked(
            const std::vector<RuntimeTriggerEffectIntent> &intents);
    // H8 in-worker bridge, same shape as ack_ideology_intents_in_worker: Trigger
    // effect intents are delivered by the Effect stage under a joint grant, so
    // the ACK barrier settles on the next Trigger visit instead of waiting a
    // frame for the main-thread pump.
    uint32_t ack_trigger_intents_in_worker(int64_t day);
    std::vector<uint8_t> encode_trigger_transport() const;
    bool restore_trigger_transport(const std::vector<uint8_t> &, std::string &, bool install);
    bool execute_effect_worker_stage(int64_t day, uint64_t input_generation,
                                     RuntimeDayCommit &commit,
                                     std::string &error);
    // Apply queued instance/metric/remove/ACK transport without planning a day.
    // Soft-skip and climate-park paths must call this so main-thread ENSURE
    // registrations are not stranded in `_effect_instance_queue`.
    bool drain_effect_transport_queues(std::string &error);
    std::vector<uint8_t> encode_effect_transport() const;
    void restore_effect_transport(const std::vector<uint8_t> &bytes);
    // E8: shared Modifier POD stage for SHADOW diagnostics and ACTIVE
    // production. authority_plan is non-null only on SHADOW (fixture ACK /
    // domain-runner commit). ACTIVE passes nullptr. Failure isolates
    // Modifier — callers must not roll back Climate/Country already
    // committed the same day.
    bool execute_modifier_worker_stage(
            int64_t day, uint64_t input_generation,
            const std::vector<RuntimeCommandPacket> &day_commands,
            bool effect_upstream_ok,
            RuntimeDomainAuthorityPlan *authority_plan,
            std::string &authority_error,
            std::string &error);
    // Resolve Effect MODIFIER intent → Modifier definition_id via key hash.
    int32_t resolve_modifier_definition_id_for_effect_intent(
            const RuntimeDomainIntent &intent) const;
    // Single place that turns an Effect-produced intent into a Modifier POD
    // command. Split out of execute_modifier_worker_stage so the adapter
    // mapping can be asserted without planning a day (planning one feeds ACKs
    // back into the Effect authority, which a mapping fixture has no
    // transactions for). Returns false when the intent must be dropped.
    bool map_effect_intent_to_modifier_command(
            const RuntimeDomainIntent &intent, uint64_t input_generation,
            RuntimeModifierPodCommand &command);
    // Rebuild day-local Effect intents for COMMITTED transactions still missing
    // ACKs (day-lane retry soft-skip must not drop the Modifier handoff).
    void reemit_effect_committed_pending_intents(int64_t day);
    // PUBLISH_EVENT intents do not go through Modifier; ACK them in-worker so
    // technology activation is not pinned on the main-thread Effect pump.
    uint32_t ack_effect_events_intents_in_worker(
            const std::vector<RuntimeDomainIntent> &intents);
    void publish_country_command_terminals(
            const std::vector<RuntimeCountryCommand> &commands,
            CountryCommandReceiptCode code, uint64_t generation,
            const char *reason, bool include_superseded_ai = false);
    void retire_country_ai_ingress(const std::vector<RuntimeCommandPacket> &packets);
    bool try_freeze_command_inputs(int64_t day);
    void drain_command_inbox(std::vector<RuntimeCommandPacket> &out) {
        drain_command_inbox_through(out, _command_enqueue_pos.load(std::memory_order_acquire));
    }
    void drain_command_inbox_through(std::vector<RuntimeCommandPacket> &out, uint64_t end);
    void register_country_acceptance(const RuntimeCommandPacket &packet);
    int64_t frozen_command_day() const noexcept {
        return (_command_seal.load(std::memory_order_acquire) & ~int64_t{1}) / 2;
    }
    bool launch_executor(bool paused);
    bool resume_same_world_executor(double speed, bool paused);
    bool push_receipt(const RuntimeCommandReceipt &receipt);
    void publish_day(int64_t from_day, int64_t day,
                     const RuntimeDayCommit &day_commit,
                     const std::vector<RuntimeCommandReceipt> &day_receipts);
    void set_fault(const char *code);
    // Grant and revoke share one atomic state; a finishing day cannot undo stop.
    void publish_authority_grant(uint32_t mask) noexcept {
        _authority_control.grant(mask);
    }
    void record_save_failure(const char *reason);
    void publish_economy_tax_diag(const std::string &yield_reason,
                                  uint32_t slices);
    // Returns true when an armed one-shot injection matched `point` and
    // transitioned the worker into FAULTED. Call sites must abort the current
    // boundary immediately after a true return.
    bool try_fault_injection(const char *point) noexcept;
    // Publishes the first diverging Climate field/cell into the report slots.
    // These slots existed in the ABI but nothing ever wrote them, so a parity
    // failure could only be observed as two unequal hashes.
    void publish_climate_parity_divergence(const RuntimeClimateParityReport &diff);
    void clear_climate_parity_divergence();
    // Folds one day's full per-field comparison into the cumulative stats.
    void accumulate_climate_parity_fields(
            int64_t day, const RuntimeClimateStore &reference,
            const RuntimeClimateStore &worker);
    void reset_climate_parity_fields();
    bool serialize_country_economy_asset_journal(
            std::vector<uint8_t> &out, std::string &error) const;
    bool restore_country_economy_asset_journal(
            const uint8_t *bytes, size_t size, std::string &error);
    void build_save_bundle(uint64_t request_id,
                           const std::vector<RuntimeCommandPacket> &pending_commands);
    bool service_save_request(std::vector<RuntimeCommandPacket> &pending_commands);
    void service_inline_save_request();
    void seed_executor_command_orders();
    static bool command_packet_before(const RuntimeCommandPacket &a, const RuntimeCommandPacket &b);
