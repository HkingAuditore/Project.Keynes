// Economy writer control, authority selection, and capture and parity operations.

    // Per-stage sync reference for SHADOW Economy POD parity tooling. Does not
    // grant ACTIVE authority.
    void publish_economy_stage_reference(uint32_t stage, int64_t day,
                                         uint64_t generation,
                                         uint64_t state_hash,
                                         uint64_t work_units) noexcept override;
    bool execute_economy_worker_stage(int64_t day, uint64_t input_generation,
                                      uint32_t cell_count,
                                      uint64_t country_generation,
                                      uint64_t catalog_hash,
                                      std::string &error);
    void attach_economy_stage_ops(
        std::unique_ptr<EconomyGraphStageOps> ops) noexcept;
    // Phase-2.4.1: when true, StageOps are attached with mutate=true (armed for
    // future production handoff). Production ACTIVE still runs compact-slice
    // unless a later slice replaces that loop.
    void set_economy_stage_ops_mutate(bool mutate) noexcept {
        _economy_stage_ops_mutate.store(mutate, std::memory_order_release);
    }
    bool economy_stage_ops_mutate() const noexcept {
        return _economy_stage_ops_mutate.load(std::memory_order_acquire);
    }
    // After a complete ledger capture, optionally promote authority to
    // M6 keeps authority switches explicit. Mirror readiness is diagnostic;
    // it never changes the writer without an epoch-boundary API call.
    void set_economy_auto_pod_active(bool enabled) noexcept {
        _economy_auto_pod_active.store(enabled, std::memory_order_release);
    }
    bool economy_auto_pod_active() const noexcept {
        return _economy_auto_pod_active.load(std::memory_order_acquire);
    }
    // ECP2 dual-write / mid-epoch / authority cutover (E10). Dual-write defaults
    // on; mid-epoch and authority cutover default off until self_test proves RT.
    void set_economy_ecp2_dual_write(bool enabled) noexcept {
        _economy_ecp2_dual_write.store(enabled, std::memory_order_release);
    }
    bool economy_ecp2_dual_write() const noexcept {
        return _economy_ecp2_dual_write.load(std::memory_order_acquire);
    }
    void set_economy_ecp2_mid_epoch_save(bool enabled) noexcept {
        _economy_ecp2_mid_epoch_save.store(enabled, std::memory_order_release);
    }
    bool economy_ecp2_mid_epoch_save() const noexcept {
        return _economy_ecp2_mid_epoch_save.load(std::memory_order_acquire);
    }
    void set_economy_ecp2_authority(bool enabled) noexcept {
        _economy_ecp2_authority.store(enabled, std::memory_order_release);
    }
    bool economy_ecp2_authority() const noexcept {
        return _economy_ecp2_authority.load(std::memory_order_acquire);
    }
    // Phase-2.4.2: production writer selection. STAGE_OPS effective only when
    // soak experiment or soak_parity_ok is armed (P2.4.4.4); default compact.
    void set_economy_stage_ops_soak_experiment(bool enabled) noexcept {
        _economy_stage_ops_soak_experiment.store(enabled,
                                                 std::memory_order_release);
    }
    bool economy_stage_ops_soak_experiment() const noexcept {
        return _economy_stage_ops_soak_experiment.load(
            std::memory_order_acquire);
    }
    void set_economy_stage_ops_soak_parity_ok(bool ok) noexcept {
        _economy_stage_ops_soak_parity_ok.store(ok, std::memory_order_release);
    }
    bool economy_stage_ops_soak_parity_ok() const noexcept {
        return _economy_stage_ops_soak_parity_ok.load(
            std::memory_order_acquire);
    }
    void set_economy_production_writer(EconomyProductionWriter writer) noexcept {
        _economy_production_writer_requested.store(
            static_cast<uint32_t>(writer), std::memory_order_release);
        // Phase-2.4.5: StageOps may be effective once start gates pass (mutate +
        // readiness). Soak experiment / parity latch remain observability.
        _economy_production_writer_effective.store(
            static_cast<uint32_t>(writer), std::memory_order_release);
    }
    EconomyProductionWriter economy_production_writer_requested() const noexcept {
        return static_cast<EconomyProductionWriter>(
            _economy_production_writer_requested.load(std::memory_order_acquire));
    }
    EconomyProductionWriter economy_production_writer_effective() const noexcept override {
        return static_cast<EconomyProductionWriter>(
            _economy_production_writer_effective.load(std::memory_order_acquire));
    }
    // Phase-2.4.4.2: one Host pulse of StageOps production orchestration.
    // Requires mutate StageOps + production runtime. Soft-parks on pending_input.
    bool worker_run_stage_ops_slice(int64_t day, uint64_t input_generation,
                                    std::string &error, bool *done = nullptr,
                                    bool *pending_input = nullptr);
    bool economy_shadow_probe_enabled() const {
        return _economy_shadow_probe_enabled.load(std::memory_order_acquire);
    }
    // Phase-1 execution mode. Default ACTIVE_ONLY (SHADOW StageOps = 0).
    void set_economy_execution_mode(EconomyExecutionMode mode) noexcept;
    EconomyExecutionMode economy_execution_mode() const noexcept {
        return static_cast<EconomyExecutionMode>(
            _economy_execution_mode.load(std::memory_order_acquire));
    }
    bool economy_parity_shadow_enabled() const noexcept override {
        return economy_execution_mode() ==
                   EconomyExecutionMode::ACTIVE_WITH_PARITY &&
               economy_shadow_probe_enabled();
    }
    bool economy_worker_production_allowed() const noexcept {
        return economy_execution_mode() != EconomyExecutionMode::LEGACY_ONLY;
    }
    // Phase-2 authority switch. POD_ACTIVE is refused until the committed POD
    // mirror covers the full production ledger (see economy-ledger-migration-status).
    bool switch_economy_authority(RuntimeEconomyAuthorityMode mode,
                                  std::string &error) noexcept;
    // Deterministic release-gate probe for the fault handoff contract. It
    // uses an isolated host and never mutates the live simulation worker.
    bool economy_authority_fault_gate_self_test(std::string &error) const noexcept;
    // One-shot fault injection by domain/stage point name. Armed points trip
    // exactly once when the worker reaches that boundary (plan/reservation/
    // commit/Events/save/restore/authority switch). Returns false when the
    // point name is empty or truncated.
    bool arm_fault_injection(const char *point) noexcept;
    void clear_fault_injection() noexcept;
    bool fault_injection_armed() const noexcept {
        return _fault_injection_armed.load(std::memory_order_acquire);
    }
    uint64_t fault_injection_trip_count() const noexcept {
        return _fault_injection_trip_count.load(std::memory_order_acquire);
    }
    bool economy_worker_is_authoritative() const noexcept {
        return economy_production_runtime_attached() &&
               economy_execution_mode() != EconomyExecutionMode::LEGACY_ONLY &&
               domain_is_worker_authoritative(RuntimeDomainId::ECONOMY);
    }
    RuntimeEconomyAuthorityMode economy_authority_mode() const noexcept {
        return _economy_pod_authority.authority_mode();
    }
    bool economy_legacy_fallback_enabled() const noexcept {
        return economy_execution_mode() == EconomyExecutionMode::LEGACY_ONLY ||
               _economy_pod_authority.authority_mode() ==
                   RuntimeEconomyAuthorityMode::LEGACY_SYNC ||
               _economy_pod_authority.authority_mode() ==
                   RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY;
    }
    uint64_t economy_shadow_stage_invocations() const noexcept {
        return _economy_shadow_stage_invocations.load(std::memory_order_acquire);
    }
    uint64_t economy_shadow_stage_cache_hits() const noexcept {
        return _economy_shadow_stage_cache_hits.load(std::memory_order_acquire);
    }
