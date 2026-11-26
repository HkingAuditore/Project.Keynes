bool NativeSimulationHost::switch_economy_authority(
        RuntimeEconomyAuthorityMode mode, std::string &error) noexcept {
    // Hold the boundary lock for the complete check + mode mutation + audit.
    // The worker takes the same lock around execute_day_plan/publish_day, so
    // an observed idle boundary cannot be invalidated by the next day starting
    // between the check and the actual authority change.
    //
    // CRITICAL: never block the Godot main thread on this lock. The worker may
    // hold it while parked on Country peer / environment input that only the
    // main thread can service. A blocking lock here deadlocks the whole game
    // with no fault/output (main stuck, worker stuck).
    std::unique_lock<std::mutex> boundary_lock(
        _economy_authority_boundary_mutex, std::try_to_lock);
    const uint64_t switch_started_us = now_us();
    error.clear();
    auto remember_blocker = [&](const char *reason) noexcept {
        const char *value = reason ? reason : "unknown";
        size_t i = 0;
        for (; i + 1 < _economy_authority_switch_blocker.size() && value[i] != '\0'; ++i)
            _economy_authority_switch_blocker[i].store(value[i], std::memory_order_relaxed);
        for (; i < _economy_authority_switch_blocker.size(); ++i)
            _economy_authority_switch_blocker[i].store('\0', std::memory_order_relaxed);
    };
    auto remember_reason = [&](const char *reason) noexcept {
        const char *value = reason ? reason : "unknown";
        size_t i = 0;
        for (; i + 1 < _economy_authority_switch_reason.size() && value[i] != '\0'; ++i)
            _economy_authority_switch_reason[i].store(value[i], std::memory_order_relaxed);
        for (; i < _economy_authority_switch_reason.size(); ++i)
            _economy_authority_switch_reason[i].store('\0', std::memory_order_relaxed);
    };
    if (!boundary_lock.owns_lock()) {
        _economy_authority_switch_rejected.fetch_add(1, std::memory_order_relaxed);
        remember_blocker("worker_day_lock_busy");
        error = "economy_authority_switch_requires_epoch_boundary";
        remember_reason(error.c_str());
        return false;
    }
    if (try_fault_injection("authority.switch.before")) {
        error = "economy_authority_switch_fault_injected_before";
        return false;
    }
    const RuntimeEconomyAuthorityMode current = _economy_pod_authority.authority_mode();
    const RuntimeWorkerState worker_state = state();
    if (worker_state == RuntimeWorkerState::FAULTED) {
        // A faulted worker must remain parked on its last committed snapshot;
        // authority cannot move while an unsafe partial mutation may exist.
        _economy_authority_fault_paused.store(true, std::memory_order_release);
        _economy_authority_switch_rejected.fetch_add(1, std::memory_order_relaxed);
        remember_blocker("worker_fault_paused_committed_snapshot");
        error = "economy_authority_switch_worker_fault_paused";
        remember_reason(error.c_str());
        return false;
    }
    if (worker_state == RuntimeWorkerState::STOPPING ||
        worker_state == RuntimeWorkerState::SAVE_PENDING) {
        _economy_authority_switch_rejected.fetch_add(1, std::memory_order_relaxed);
        remember_blocker("worker_lifecycle_not_at_boundary");
        error = "economy_authority_switch_requires_epoch_boundary";
        remember_reason(error.c_str());
        return false;
    }
    const bool command_queue_pending =
        _command_enqueue_pos.load(std::memory_order_acquire) !=
        _command_dequeue_pos.load(std::memory_order_acquire);
    const uint32_t worker_day_inflight =
        _worker_day_inflight.load(std::memory_order_acquire);
    const uint32_t economy_inflight =
        _economy_inflight_mutations.load(std::memory_order_acquire);
    const uint32_t worker_pending =
        _economy_pending_command_count.load(std::memory_order_acquire);
    if (static_cast<StageOpsDayPhase>(_stage_ops_day_phase_atomic.load(
            std::memory_order_acquire)) != StageOpsDayPhase::Done ||
        _economy_pod_pending_outbox.load(std::memory_order_acquire) != 0 ||
        _economy_pod_pending_inbox.load(std::memory_order_acquire) != 0 ||
        command_queue_pending || worker_day_inflight != 0 ||
        economy_inflight != 0 || worker_pending != 0) {
        _economy_authority_switch_rejected.fetch_add(1, std::memory_order_relaxed);
        const char *blocker = command_queue_pending
            ? "pending_command_queue"
            : (worker_pending != 0 ? "pending_worker_command"
               : (economy_inflight != 0 ? "economy_mutation_inflight"
                  : (worker_day_inflight != 0 ? "worker_day_inflight"
                     : "pending_epoch_mutation")));
        remember_blocker(blocker);
        error = "economy_authority_switch_requires_epoch_boundary";
        remember_reason(error.c_str());
        return false;
    }
    // Idempotent requests are safe once the worker is healthy and idle; keep
    // the fault/lifecycle/pending-work checks authoritative even for same-mode
    // calls.
    if (current == mode) return true;
    const uint64_t before_hash = _economy_pod_authority.state_hash();
    const uint64_t before_generation =
        _economy_pod_authority.committed_ledger_state().generation;
    const auto record_switch = [&]() noexcept {
        const uint64_t after_hash = _economy_pod_authority.state_hash();
        const uint64_t after_generation =
            _economy_pod_authority.committed_ledger_state().generation;
        _economy_authority_switch_count.fetch_add(1, std::memory_order_relaxed);
        _economy_authority_switch_audit_sequence.fetch_add(
            1u, std::memory_order_acq_rel);
        _economy_authority_switch_before_hash.store(before_hash, std::memory_order_release);
        _economy_authority_switch_after_hash.store(after_hash, std::memory_order_release);
        _economy_authority_switch_before_generation.store(before_generation, std::memory_order_release);
        _economy_authority_switch_after_generation.store(after_generation, std::memory_order_release);
        _economy_authority_last_committed_generation.store(after_generation, std::memory_order_release);
        _economy_authority_last_committed_hash.store(after_hash, std::memory_order_release);
        const char *reason = "epoch_boundary_authority_switch";
        size_t i = 0;
        remember_reason(reason);
        char audit[128];
        std::snprintf(audit, sizeof(audit), "mode=%u generation=%llu hash=%llu",
                      static_cast<unsigned>(current),
                      static_cast<unsigned long long>(before_generation),
                      static_cast<unsigned long long>(before_hash));
        i = 0;
        for (; i + 1 < _economy_authority_switch_audit_before.size() && audit[i] != '\0'; ++i)
            _economy_authority_switch_audit_before[i].store(audit[i], std::memory_order_relaxed);
        for (; i < _economy_authority_switch_audit_before.size(); ++i)
            _economy_authority_switch_audit_before[i].store('\0', std::memory_order_relaxed);
        std::snprintf(audit, sizeof(audit), "mode=%u generation=%llu hash=%llu",
                      static_cast<unsigned>(mode),
                      static_cast<unsigned long long>(after_generation),
                      static_cast<unsigned long long>(after_hash));
        i = 0;
        for (; i + 1 < _economy_authority_switch_audit_after.size() && audit[i] != '\0'; ++i)
            _economy_authority_switch_audit_after[i].store(audit[i], std::memory_order_relaxed);
        for (; i < _economy_authority_switch_audit_after.size(); ++i)
            _economy_authority_switch_audit_after[i].store('\0', std::memory_order_relaxed);
        remember_blocker("");
        const uint64_t completed_at = now_us();
        const uint64_t switch_latency = completed_at >= switch_started_us
            ? completed_at - switch_started_us : 0u;
        const uint64_t admitted_at =
            _last_command_admitted_us.load(std::memory_order_acquire);
        const uint64_t command_latency =
            admitted_at != 0 && completed_at >= admitted_at
                ? completed_at - admitted_at : 0u;
        _economy_authority_switch_latency_us.store(
            switch_latency, std::memory_order_release);
        _economy_authority_switch_command_latency_us.store(
            command_latency, std::memory_order_release);
        uint64_t audit_hash = mix_hash(before_hash, after_hash);
        audit_hash = mix_hash(audit_hash, before_generation);
        audit_hash = mix_hash(audit_hash, after_generation);
        audit_hash = mix_hash(audit_hash, static_cast<uint64_t>(current));
        audit_hash = mix_hash(audit_hash, static_cast<uint64_t>(mode));
        audit_hash = mix_hash(audit_hash, switch_latency);
        _economy_authority_switch_audit_hash.store(
            audit_hash, std::memory_order_release);
        // Keep a bounded sample history for p95/max reporting. The write
        // cursor is advanced only after both slots are visible, so a report
        // observing the new count can never include an uninitialised sample.
        const uint64_t sample_sequence =
            _economy_authority_switch_latency_sample_write.load(
                std::memory_order_relaxed);
        const size_t sample_slot = static_cast<size_t>(
            sample_sequence % ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY);
        _economy_authority_switch_latency_samples[sample_slot].store(
            switch_latency, std::memory_order_relaxed);
        _economy_authority_switch_command_latency_samples[sample_slot].store(
            command_latency, std::memory_order_relaxed);
        _economy_authority_switch_latency_sample_write.store(
            sample_sequence + 1u, std::memory_order_release);
        const uint64_t sample_count = std::min<uint64_t>(
            sample_sequence + 1u,
            ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY);
        _economy_authority_switch_latency_sample_count.store(
            sample_count, std::memory_order_release);
    };
    switch (mode) {
    case RuntimeEconomyAuthorityMode::LEGACY_SYNC:
        if (_economy_production_runtime != nullptr &&
            _economy_production_runtime->formula_owned_bound()) {
            _economy_production_runtime->unbind_formula_owned_state();
        }
        _economy_pod_authority.set_authority_mode(mode);
        record_switch();
        if (try_fault_injection("authority.switch.after")) {
            error = "economy_authority_switch_fault_injected_after";
            return false;
        }
        return true;
    case RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY:
        // Parity soak may run against the committed cohort/market mirror.
        // Production mutations stay on NativeEconomyRuntime; POD mirrors them.
        _economy_pod_authority.set_authority_mode(mode);
        record_switch();
        if (try_fault_injection("authority.switch.after")) {
            error = "economy_authority_switch_fault_injected_after";
            return false;
        }
        return true;
    case RuntimeEconomyAuthorityMode::POD_ACTIVE:
        // Phase-2.3.3 completes the committed mirror feature mask (ECP ABI9).
        // Still refuse until a live capture has set every REQUIRED_FOR_ACTIVE
        // bit. Phase-5 A+Y: bind NER population/market to OwnedState so
        // StageOps formulas mutate the sole SoA instance.
        if (!_economy_pod_authority.pod_active_ready()) {
            error = "economy_pod_active_incomplete_ledger_mirror";
            remember_blocker("economy_pod_active_incomplete_ledger_mirror");
            remember_reason(error.c_str());
            return false;
        }
        if (_economy_production_runtime != nullptr &&
            !_economy_production_runtime->formula_owned_bound()) {
                if (!_economy_production_runtime->bind_formula_owned_state(
                    _economy_pod_authority.state(), error)) {
                remember_blocker(error.c_str());
                remember_reason(error.c_str());
                return false;
            }
        }
        _economy_pod_authority.set_authority_mode(mode);
        record_switch();
        if (try_fault_injection("authority.switch.after")) {
            error = "economy_authority_switch_fault_injected_after";
            return false;
        }
        return true;
    }
    error = "economy_authority_mode_invalid";
    return false;
}

bool NativeSimulationHost::economy_authority_fault_gate_self_test(
        std::string &error) const noexcept {
    error.clear();
    if (!EconomyInvariantProbe::run(error)) return false;
    // 遗留 AI 包的终态可供收尾/保存查询，但不能污染玩家回执流。
    const auto receipt_probe = std::make_unique<NativeSimulationHost>();
    RuntimeCountryCommand old_ai;
    old_ai.request_id = 1;
    old_ai.producer_id = COUNTRY_AI_PRODUCER_ID;
    old_ai.sequence = 131072;
    old_ai.effective_day = 2;
    receipt_probe->publish_country_command_terminals({old_ai},
        CountryCommandReceiptCode::COMMITTED, 3, nullptr);
    if (!receipt_probe->_country_command_terminals.empty()) {
        error = "worker_ai_internal_commands_became_player_terminals";
        return false;
    }
    for (int repeat = 0; repeat < 2; ++repeat)
        receipt_probe->publish_country_command_terminals({old_ai},
            CountryCommandReceiptCode::REJECTED_AT_EXECUTION, 10838,
            "country_ai_superseded_by_worker", true);
    CountryCommandReceipt terminal;
    std::vector<CountryCommandReceipt> player_receipts;
    if (!receipt_probe->try_country_command_terminal(1, terminal) ||
        terminal.code != CountryCommandReceiptCode::REJECTED_AT_EXECUTION ||
        terminal.reason != "country_ai_superseded_by_worker" ||
        receipt_probe->_country_command_terminals.size() != 1u ||
        !receipt_probe->poll_country_command_receipts(0, 8, player_receipts) ||
        !player_receipts.empty()) {
        error = "superseded_ai_terminal_not_idempotent_or_leaked";
        return false;
    }
    RuntimeCountryCommand player = old_ai;
    player.request_id = 2;
    player.producer_id = 0;
    receipt_probe->publish_country_command_terminals({player},
        CountryCommandReceiptCode::COMMITTED, 10839, nullptr);
    if (!receipt_probe->poll_country_command_receipts(0, 8, player_receipts) ||
        player_receipts.size() != 1u || player_receipts[0].request_id != 2) {
        error = "superseded_ai_terminal_filter_hid_player_receipt";
        return false;
    }
    // Unlike worker-local AI, a synchronous AI mirror owns an admitted Host
    // packet. Its terminal must retire that packet without entering the UI
    // receipt stream; otherwise the old enqueue repeats on every worker day.
    RuntimeCountryCommand mirrored_ai = old_ai;
    mirrored_ai.request_id = 3;
    CountryCommandReceipt admitted_ai;
    admitted_ai.request_id = mirrored_ai.request_id;
    admitted_ai.producer_id = COUNTRY_AI_PRODUCER_ID;
    admitted_ai.code = CountryCommandReceiptCode::ACCEPTED;
    receipt_probe->_country_command_states.emplace(3, admitted_ai);
    for (int repeat = 0; repeat < 2; ++repeat)
        receipt_probe->publish_country_command_terminals({mirrored_ai},
            CountryCommandReceiptCode::COMMITTED, 10840, nullptr);
    if (!receipt_probe->try_country_command_terminal(3, terminal) ||
        terminal.code != CountryCommandReceiptCode::COMMITTED ||
        receipt_probe->_country_command_terminals.size() != 3u ||
        !receipt_probe->poll_country_command_receipts(0, 8, player_receipts) ||
        player_receipts.size() != 1u || player_receipts[0].request_id != 2) {
        error = "mirrored_ai_terminal_not_retired_or_leaked";
        return false;
    }
    // First exercise the epoch-boundary half on a worker-shaped host without
    // starting a thread.  The switch must observe the explicit in-flight
    // counters even when the command ring itself is empty.
    const auto boundary_probe = std::make_unique<NativeSimulationHost>();
    boundary_probe->_state.store(RuntimeWorkerState::RUNNING,
                                  std::memory_order_release);
    boundary_probe->_worker_day_inflight.store(1u, std::memory_order_release);
    std::string boundary_error;
    if (boundary_probe->switch_economy_authority(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY,
            boundary_error) ||
        boundary_error != "economy_authority_switch_requires_epoch_boundary") {
        error = "economy_authority_inflight_switch_not_rejected";
        return false;
    }
    boundary_probe->_worker_day_inflight.store(0u, std::memory_order_release);
    boundary_probe->_economy_pending_command_count.store(1u, std::memory_order_release);
    if (boundary_probe->switch_economy_authority(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY,
            boundary_error)) {
        error = "economy_authority_pending_command_gate_weakened";
        return false;
    }
    boundary_probe->_economy_pending_command_count.store(0u, std::memory_order_release);
    boundary_probe->_state.store(RuntimeWorkerState::PAUSED,
                                  std::memory_order_release);
    boundary_error.clear();
    if (!boundary_probe->switch_economy_authority(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY,
            boundary_error) ||
        boundary_probe->_economy_authority_switch_audit_sequence.load(
            std::memory_order_acquire) != 1u) {
        error = "economy_authority_idle_switch_not_audited";
        return false;
    }
    // Keep this probe isolated: constructing a temporary host does not start a
    // thread, and the live host (if any) remains untouched.
    const auto probe = std::make_unique<NativeSimulationHost>();
    probe->_authority_control.begin_lifetime();
    probe->_mode.store(RuntimeSimulationMode::ACTIVE, std::memory_order_release);
    probe->_state.store(RuntimeWorkerState::RUNNING, std::memory_order_release);
    probe->_committed_day.store(7, std::memory_order_release);
    probe->publish_authority_grant(runtime_domain_mask(RuntimeDomainId::CLIMATE));
    auto control = probe->control_state();
    if (control.authority_ready || control.committed_day != 7 ||
        control.authoritative_domain_mask != runtime_domain_mask(RuntimeDomainId::CLIMATE)) {
        error = "runtime_control_partial_grant_not_visible";
        return false;
    }
    probe->request_stop();
    if (probe->control_state().authoritative_domain_mask != 0u) {
        error = "runtime_control_stop_did_not_revoke";
        return false;
    }
    // Model a commit tail that runs after stop has already revoked the grant.
    probe->publish_authority_grant(probe->lifetime_granted_mask());
    probe->_authority_control.mark_graph_ready();
    if (probe->control_state().authoritative_domain_mask != 0u ||
        probe->control_state().authority_ready) {
        error = "runtime_control_late_commit_reopened_stopped_lifetime";
        return false;
    }
    probe->_authority_control.begin_lifetime();
    probe->_state.store(RuntimeWorkerState::RUNNING, std::memory_order_release);
    probe->publish_authority_grant(probe->lifetime_granted_mask());
    if (probe->control_state().authoritative_domain_mask !=
            runtime_domain_mask(RuntimeDomainId::CLIMATE)) {
        error = "runtime_control_restart_grant_not_visible";
        return false;
    }
    probe->set_fault("self_test_worker_fault");
    probe->request_stop();
    probe->publish_authority_grant(probe->lifetime_granted_mask());
    probe->_authority_control.mark_graph_ready();
    if (probe->state() != RuntimeWorkerState::FAULTED ||
        probe->control_state().state != RuntimeWorkerState::FAULTED ||
        probe->control_state().authoritative_domain_mask != 0u ||
        probe->control_state().authority_ready ||
        probe->control_state().committed_day != 7 ||
        !probe->_economy_authority_fault_paused.load(std::memory_order_acquire)) {
        error = "economy_authority_fault_pause_not_armed";
        return false;
    }
    std::string switch_error;
    if (probe->switch_economy_authority(
            RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY,
            switch_error) ||
        switch_error != "economy_authority_switch_worker_fault_paused") {
        error = "economy_authority_fault_switch_not_rejected";
        return false;
    }
    const uint64_t committed_generation =
        probe->_economy_authority_last_committed_generation.load(
            std::memory_order_acquire);
    const uint64_t committed_hash =
        probe->_economy_authority_last_committed_hash.load(
            std::memory_order_acquire);
    if (committed_generation !=
            probe->_economy_pod_authority.committed_ledger_state().generation ||
        committed_hash != probe->_economy_pod_authority.state_hash()) {
        error = "economy_authority_fault_snapshot_not_retained";
        return false;
    }
    return true;
}
