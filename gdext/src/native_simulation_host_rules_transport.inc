// Trigger, Modifier, Effect, and Ideology worker interfaces.

    bool configure_trigger_pod(const RuntimeTriggerPodCatalog &catalog,
                               std::string &error);
    bool queue_trigger_pod_command(const RuntimeTriggerCommand &command,
                                   std::string &error);
    // H8 ACTIVE write-back boundary. Acquire, apply into the legacy
    // TriggerRuntime facade, release. Non-blocking.
    bool try_acquire_trigger_snapshot(uint64_t after_generation, uint32_t &slot);
    const RuntimeTriggerSnapshot &trigger_snapshot_buffer(uint32_t slot) const;
    void release_trigger_snapshot(uint32_t slot);
    // H8 real-ACK transport. Trigger effect intents require a peer ACK before
    // the day commits; the worker Effect stage drains them in-worker when EFFECT
    // is granted in the same session, and this pair is the main-thread protocol
    // path for a TRIGGER-only grant.
    bool poll_trigger_pod_intent(RuntimeDomainIntent &intent);
    bool submit_trigger_pod_ack(const RuntimeDomainAck &ack, std::string &error);
    RuntimeTriggerPodDiagnostics trigger_pod_diagnostics() const;
    bool set_trigger_reference_frame(int64_t day, uint64_t input_hash,
                                     uint64_t state_hash, uint64_t effect_hash,
                                     std::string &error);
    const RuntimeTriggerPodCatalog &trigger_pod_catalog() const;
    bool encode_trigger_pod_save(std::vector<uint8_t> &bytes,
                                 std::string &error) const;
    bool restore_trigger_pod_save(const uint8_t *bytes, size_t size,
                                  std::string &error);
    bool configure_modifier_pod(const RuntimeModifierPodCatalog &catalog,
                                std::string &error);
    // Bind Modifier definition_key hashes (Effect FNV) → dense definition_id.
    // Required for Effect MODIFIER intents whose catalog payload_i0 is unset.
    void set_modifier_definition_key_hashes(
            const std::vector<std::pair<uint64_t, int32_t>> &entries);
    bool encode_modifier_pod_save(std::vector<uint8_t> &bytes,
                                  std::string &error) const;
    bool restore_modifier_pod_save(const uint8_t *bytes, size_t size,
                                   std::string &error);
    bool try_acquire_modifier_snapshot(uint64_t after_generation,
                                        uint32_t &slot);
    const RuntimeModifierPodSnapshot &modifier_snapshot_buffer(uint32_t slot) const;
    void release_modifier_snapshot(uint32_t slot);
    bool try_acquire_effect_snapshot(uint64_t after_generation, uint32_t &slot);
    const RuntimeEffectPodSnapshot &effect_snapshot_buffer(uint32_t slot) const;
    void release_effect_snapshot(uint32_t slot);
    bool try_acquire_ideology_snapshot(uint64_t after_generation, uint32_t &slot);
    const RuntimeIdeologyPodSnapshot &ideology_snapshot_buffer(uint32_t slot) const;
    void release_ideology_snapshot(uint32_t slot);
    bool modifier_pod_self_test(std::string *error = nullptr) const;
    uint64_t modifier_pod_catalog_hash() const {
        return _modifier_pod_configured ? _modifier_pod_catalog.catalog_hash : 0;
    }
    void set_events_probe_enabled(bool enabled) {
        _events_probe_enabled.store(enabled, std::memory_order_release);
    }
    bool events_probe_enabled() const {
        return _events_probe_enabled.load(std::memory_order_acquire);
    }
    bool try_acquire_events_snapshot(uint64_t after_generation, uint32_t &slot) {
        return _events_snapshots.try_acquire_latest(after_generation, slot);
    }
    const RuntimeEventsSnapshot &events_snapshot_buffer(uint32_t slot) const {
        return _events_snapshots.read_buffer(slot);
    }
    void release_events_snapshot(uint32_t slot) { _events_snapshots.release(slot); }
    bool configure_effect_pod(const RuntimeEffectPodCatalog &catalog,
                              std::string &error);
    bool encode_effect_pod_save(std::vector<uint8_t> &bytes,
                                std::string &error) const;
    bool restore_effect_pod_save(const uint8_t *bytes, size_t size,
                                 std::string &error);
    RuntimeEffectPodReport effect_pod_report() const {
        return _effect_pod_authority.report();
    }
    bool effect_pod_self_test(std::string *error = nullptr);
    // F7 host-stage smoke: plan/commit + MODIFIER intent emission + ACK
    // round-trip. Does not grant EFFECT ACTIVE authority.
    bool effect_pod_host_stage_self_test(std::string *error = nullptr);
    // Pins the transport-queue contract the ideology forwarder relies on:
    // upsert/retire replay in arrival order, re-ENSURE keeps the newest
    // payload, and a retire with nothing to retire is a counted no-op.
    bool effect_pod_transport_queue_self_test(std::string *error = nullptr);
    // Pins the Effect-intent -> Modifier-POD adapter mapping, which used to
    // guess the adapter from the Modifier domain for every command. The
    // reference implementation is EffectRuntime::dispatch_native_modifier
    // (effect_runtime.cpp); this TU cannot call it (it must not include
    // modifier_runtime.h, whose NativeCommand is the legacy output type), so
    // the expected field values below are transcribed from those branches and
    // each case names the lines it mirrors.
    bool modifier_effect_adapter_self_test(std::string *error = nullptr);
    // F7 SHADOW transport. Main-thread EffectRuntime remains production
    // authority; these queues only mirror declarative POD-expressible state
    // and expose worker intents/ACKs for diagnostics and Modifier E7.
    bool queue_effect_pod_instance(const RuntimeEffectPodInstanceInput &input,
                                   std::string &error);
    bool queue_effect_pod_metric(int64_t instance_id, uint32_t generation,
                                 int32_t metric_id, int64_t revision,
                                 int64_t value, std::string &error);
    bool queue_effect_pod_remove(int64_t instance_id, uint32_t generation,
                                 std::string &error);
    bool poll_effect_pod_intent(RuntimeDomainIntent &intent);
    void attach_effect_adapter(EffectRuntime *effect, class NativeCountryRuntime *country,
                               TriggerRuntime *trigger, NativeIdeologyRuntime *ideology);
    std::shared_ptr<const RuntimeEffectReadView> latest_effect_read_view() const;
    std::shared_ptr<const TriggerRuntime> latest_trigger_read_view() const;
    std::shared_ptr<const RuntimeIdeologyReadView> latest_ideology_read_view() const;
    std::shared_ptr<const RuntimeEraRewardView> latest_era_reward() const;
    std::shared_ptr<const RuntimeEraAdvancementView> latest_era_advancement() const;
    bool initialize_narrative(const godot::Dictionary &, const godot::Dictionary &);
    godot::Dictionary restore_narrative_checkpoint(const godot::Dictionary &);
    std::shared_ptr<const RuntimeNarrativeView> latest_narrative() const;
    godot::Dictionary capture_narrative() const;
    godot::Dictionary submit_narrative_choice_request(std::shared_ptr<struct RuntimeNarrativeRequest>);
    bool enqueue_event_consumer_ack(uint64_t consumer, int64_t event, int64_t day,
        uint64_t generation, bool seal);
    godot::Dictionary submit_era_reward_request(std::shared_ptr<RuntimeEraRewardRequest> request);
    bool effect_adapter_owned() const noexcept {
        return _effect_adapter_runtime != nullptr && !execution_has_stopped();
    }
    bool submit_effect_pod_ack(const RuntimeDomainAck &ack, std::string &error);
    int32_t effect_pod_program_id_for_key(const char *key) const override;
    // M2a: true once a compiled Effect POD catalog is installed. The forwarder
    // must report WORKER_TRANSPORT_NOT_READY rather than "ok" while EFFECT is
    // already worker-authoritative but this is still false -- otherwise every
    // queued instance fails and the batch looks partially accepted.
    bool effect_pod_transport_ready() const override { return _effect_pod_configured; }
    // Country ACTIVE peer adapter: technology.<id> instances live on the Effect
    // POD unique-writer. Sync EffectRuntime is writeback-only under F8.
    bool ensure_effect_pod_technology_instance(
            int64_t instance_id, uint32_t generation, int32_t program_id,
            uint64_t target_handle, uint32_t target_generation, int64_t day,
            std::string &error) override;
    // "Is this instance still in the Effect POD unique-writer's state?"
    //
    // Main-thread owners that keep their own bindings (Economy's family
    // effects) have to rebuild them after a load, and they cannot ask
    // EffectRuntime for this: under F8 ACTIVE it is writeback-only and only
    // refreshes on the main-thread pump, so it answers "absent" for every
    // instance the worker owns. Semantics mirror
    // EffectRuntime::has_instance_pod -- presence plus matching generation,
    // regardless of the active flag -- with one addition: a row the transport
    // has accepted but not yet installed also counts as present, because
    // otherwise every reader races the queue and reports a live instance as
    // missing.
    //
    // Reads the same committed snapshot ensure_effect_pod_technology_instance
    // reads, plus the pending upsert queue; it is a query only and never mutates
    // the authority.
    bool effect_pod_instance_exists(int64_t instance_id,
                                    uint32_t generation) const;
    bool effect_pod_instance_fire_acked(int64_t instance_id,
                                        uint32_t generation) const override;
    // After Effect soft-skip/catchup/ACK, PENDING Country ENSURE/NUDGE peers
    // must become READY without re-queue (re-queue spun the main-thread pump).
    // Removing Country soft-commit made this same-day promote mandatory.
    uint32_t resolve_pending_country_effect_peers();
    // Worker-side ENSURE_TECHNOLOGY_EFFECT, queued by the Country stage before
    // the same day's Effect stage, so the fire day never depends on the main thread.
    CountryPeerResult resolve_country_technology_effect(
            const CountryPeerIntent &intent);
    // Describes why a technology Effect instance has not fire-ACKed yet. The
    // caller prints it through Godot so the text reaches the editor Output
    // panel; this translation unit stays free of Godot headers.
    std::string describe_effect_pod_technology_state(int64_t instance_id,
                                                     uint32_t generation,
                                                     int32_t program_id,
                                                     int32_t technology) const override;
    bool configure_ideology_pod(const RuntimeIdeologyPodCatalog &catalog,
                                std::string &error);
    bool publish_ideology_opinion_snapshot(
        const RuntimeIdeologyOpinionSnapshot &snapshot, std::string &error);
    // SHADOW comparison captures the opinion at the reference's actual daily
    // entry. The explicit simulation day is the join key, not Economy's
    // committed_day or a period index. Continuations keep the first input.
    std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>
        pin_ideology_reference_opinion(int64_t day,
            const RuntimeIdeologyOpinionSnapshot &snapshot);
    // Diagnostic lineage: the opinion the worker actually consumed for `day`,
    // including its frozen Modifier factors. Null means no recorded worker plan.
    std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>
        worker_opinion_snapshot_for_day(int64_t day) const;
    // The opinion consumed by the worker plan that produced `generation`.
    // Write-back binds state and its frozen factors together; looking up only by
    // calendar day can select a newer plan when Economy and Ideology day scales
    // differ.
    std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>
        worker_opinion_snapshot_for_ideology_generation(
            uint64_t generation) const;
    bool queue_ideology_pod_command(const RuntimeIdeologyPodCommand &command,
                                    std::string &error);
    // Per-cell tag bitmap for the worker's condition selector. Transient: the
    // economy republishes it every epoch, so it is never serialised.
    void set_ideology_cell_tags(int32_t words, const std::vector<uint64_t> &bits);
    // Effect custom-domain grants are a semantic batch: validate and reserve
    // the whole batch before publishing any command to the Ideology transport.
    bool queue_ideology_pod_commands(
        const std::vector<RuntimeIdeologyPodCommand> &commands,
        std::string &error);
    void wake_for_ideology_response(const std::vector<RuntimeIdeologyPodCommand> &commands);
    bool poll_ideology_pod_intent(RuntimeDomainIntent &intent);
    bool submit_ideology_pod_ack(const RuntimeDomainAck &ack,
                                 std::string &error);
    std::shared_ptr<const RuntimeIdeologyPodSnapshot> ideology_pod_snapshot() const;
    bool encode_ideology_pod_save(std::vector<uint8_t> &bytes,
                                  std::string &error) const;
    bool restore_ideology_pod_save(const uint8_t *bytes, size_t size,
                                   std::string &error);
    bool ideology_pod_self_test(std::string *error = nullptr) const;
