bool NativeSimulationHost::country_authority_drain_idle_locked() const {
    if (!_country_worker_intent_queue.empty() ||
        !_country_worker_intents.empty() ||
        !_country_worker_notifications.empty() ||
        !_economy_origin_asset_queue.empty() ||
        !_country_economy_asset_request_queue.empty() ||
        _country_pod_plan_active.load(std::memory_order_acquire)) {
        return false;
    }
    // Accepted Host receipts are still open work. Terminal receipts stay.
    for (const auto &entry : _country_command_states) {
        if (entry.second.code == CountryCommandReceiptCode::ACCEPTED)
            return false;
    }
    // SHADOW sync mirrors leave COUNTRY_PREPARED rows with a terminal result;
    // those are drained. Anything still in-flight (no terminal / non-terminal
    // state) blocks handoff the same way begin_save blocks on asset tx.
    for (const auto &entry : _country_economy_asset_requests) {
        if (entry.second.state == RuntimeEconomyAssetState::COMPLETED ||
            entry.second.state == RuntimeEconomyAssetState::REJECTED ||
            entry.second.state == RuntimeEconomyAssetState::FAULTED) {
            continue;
        }
        const auto terminal =
            _country_economy_asset_terminal_results.find(entry.first);
        if (terminal != _country_economy_asset_terminal_results.end() &&
            economy_asset_result_terminal(terminal->second)) {
            // COMPLETED research / continuation-owned terminals still await
            // Economy settlement flush; do not treat them as handoff-ready.
            if ((entry.second.operation ==
                     RuntimeEconomyAssetOperation::RESEARCH_PURCHASE ||
                 _country_economy_asset_self_settled.count(entry.first) != 0) &&
                terminal->second.code ==
                    RuntimeEconomyAssetResultCode::COMPLETED &&
                _country_economy_asset_committed.find(entry.first) ==
                    _country_economy_asset_committed.end()) {
                return false;
            }
            continue;
        }
        return false;
    }
    return true;
}

bool NativeSimulationHost::prepare_country_authority_handoff(
        CountryAuthorityOwner target, std::string &error) {
    error.clear();
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    if (!country_authority_drain_idle_locked()) {
        error = "country_authority_handoff_busy";
        country_peer_copy_reason(_country_authority_handoff_reason, error.c_str());
        _country_authority_prepare_pending = false;
        return false;
    }
    if (target == _country_authority_owner) {
        error = "country_authority_handoff_same_owner";
        country_peer_copy_reason(_country_authority_handoff_reason, error.c_str());
        _country_authority_prepare_pending = false;
        return false;
    }
    _country_authority_prepared = target;
    _country_authority_prepare_pending = true;
    country_peer_copy_reason(_country_authority_handoff_reason, "");
    return true;
}

bool NativeSimulationHost::abort_country_authority_handoff(std::string &error) {
    error.clear();
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    _country_authority_prepare_pending = false;
    _country_authority_prepared = _country_authority_owner;
    country_peer_copy_reason(_country_authority_handoff_reason,
                             "country_authority_handoff_aborted");
    return true;
}

bool NativeSimulationHost::install_country_authority_handoff(std::string &error) {
    error.clear();
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    if (!_country_authority_prepare_pending) {
        error = "country_authority_handoff_not_prepared";
        country_peer_copy_reason(_country_authority_handoff_reason, error.c_str());
        return false;
    }
    if (!country_authority_drain_idle_locked()) {
        error = "country_authority_handoff_busy";
        country_peer_copy_reason(_country_authority_handoff_reason, error.c_str());
        _country_authority_prepare_pending = false;
        _country_authority_prepared = _country_authority_owner;
        return false;
    }
    const CountryAuthorityOwner next = _country_authority_prepared;
    // SYNC→WORKER requires a published main-thread checkpoint. Live POD
    // replacement while the worker thread may enter Country stage is unsafe;
    // D10 publishes the immutable capture and advances session epoch. The
    // next worker start / D12 ACTIVE path bootstraps from this snapshot.
    if (next == CountryAuthorityOwner::WORKER) {
        const auto snapshot = std::atomic_load_explicit(
            &_country_snapshot, std::memory_order_acquire);
        if (snapshot == nullptr || _country_pod_catalog.catalog_hash == 0) {
            error = "country_authority_handoff_checkpoint_missing";
            country_peer_copy_reason(_country_authority_handoff_reason,
                                     error.c_str());
            _country_authority_prepare_pending = false;
            _country_authority_prepared = _country_authority_owner;
            return false;
        }
        _country_committed_snapshot = snapshot;
        _country_worker_country_generation = snapshot->generation;
        _country_worker_day = snapshot->committed_day;
    } else if (_country_pod_configured.load(std::memory_order_acquire)) {
        // WORKER→SYNC: freeze the last POD business state into the published
        // capture so main-thread restore/verify sees the handoff boundary.
        RuntimeCountryPodSnapshot pod_snapshot;
        std::string snapshot_error;
        if (_country_pod_authority.snapshot(pod_snapshot, snapshot_error)) {
            auto copy = std::make_shared<RuntimeCountryPodSnapshot>(
                std::move(pod_snapshot));
            std::shared_ptr<const RuntimeCountryPodSnapshot> view = copy;
            std::atomic_store_explicit(&_country_snapshot, view,
                                       std::memory_order_release);
            std::atomic_store_explicit(&_country_economy_audit_snapshot, view,
                                       std::memory_order_release);
            _country_committed_snapshot = copy;
            _country_worker_country_generation = copy->generation;
            _country_worker_day = copy->committed_day;
        }
    }
    _country_authority_owner = next;
    _country_authority_prepare_pending = false;
    ++_country_worker_session_epoch;
    if (_country_worker_session_epoch == 0) _country_worker_session_epoch = 1;
    country_peer_copy_reason(_country_authority_handoff_reason, "");
    return true;
}

NativeSimulationHost::CountryAuthorityHandoffStatus
NativeSimulationHost::country_authority_handoff_status() const {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    CountryAuthorityHandoffStatus out;
    out.owner = _country_authority_owner;
    out.prepared_target = _country_authority_prepared;
    out.prepare_pending = _country_authority_prepare_pending;
    out.session_epoch = _country_worker_session_epoch;
    std::memcpy(out.last_reason, _country_authority_handoff_reason.data(),
                sizeof(out.last_reason));
    return out;
}

bool NativeSimulationHost::country_authority_handoff_self_test(
        std::string &error) const {
    error.clear();
    NativeSimulationHost probe;
    probe._country_worker_session_epoch = 7;
    std::string local;
    RuntimeEconomyAssetRequest busy;
    busy.request_id = 1;
    busy.transaction_id = 1;
    busy.session_epoch = 7;
    busy.day = 0;
    if (!probe.enqueue_economy_origin_country_asset(busy, local)) {
        error = "country_handoff_self_test_seed_failed";
        return false;
    }
    if (probe.prepare_country_authority_handoff(
            CountryAuthorityOwner::WORKER, local) ||
        local != "country_authority_handoff_busy") {
        error = "country_handoff_self_test_busy_failed";
        return false;
    }
    if (probe.country_authority_handoff_status().owner !=
            CountryAuthorityOwner::SYNC) {
        error = "country_handoff_self_test_owner_mutated";
        return false;
    }
    probe._economy_origin_asset_queue.clear();
    probe._country_economy_asset_requests.clear();
    probe._country_economy_asset_protocol = {};
    if (probe.prepare_country_authority_handoff(
            CountryAuthorityOwner::WORKER, local)) {
        // No published checkpoint yet: install must fail closed.
        if (probe.install_country_authority_handoff(local) ||
            local != "country_authority_handoff_checkpoint_missing") {
            error = "country_handoff_self_test_checkpoint_guard_failed";
            return false;
        }
        if (probe.country_authority_handoff_status().owner !=
                CountryAuthorityOwner::SYNC ||
            probe.country_authority_handoff_status().prepare_pending) {
            error = "country_handoff_self_test_checkpoint_owner_mutated";
            return false;
        }
    } else {
        error = local.empty() ? "country_handoff_self_test_prepare_failed" : local;
        return false;
    }
    // Install only requires a published capture pointer + catalog identity.
    // Avoid full POD shape validation here; production capture paths own that.
    auto fixture = std::make_shared<RuntimeCountryPodSnapshot>();
    fixture->bootstrapped = true;
    fixture->generation = 1;
    fixture->committed_day = 0;
    fixture->session_epoch = 7;
    std::atomic_store_explicit(
        &probe._country_snapshot,
        std::shared_ptr<const RuntimeCountryPodSnapshot>(fixture),
        std::memory_order_release);
    probe._country_pod_catalog.catalog_hash = 1;
    if (!probe.prepare_country_authority_handoff(
            CountryAuthorityOwner::WORKER, local)) {
        error = local.empty() ? "country_handoff_self_test_prepare_failed" : local;
        return false;
    }
    if (!probe.abort_country_authority_handoff(local) ||
        probe.country_authority_handoff_status().prepare_pending ||
        probe.country_authority_handoff_status().owner !=
            CountryAuthorityOwner::SYNC) {
        error = "country_handoff_self_test_abort_failed";
        return false;
    }
    const uint64_t epoch = probe._country_worker_session_epoch;
    if (!probe.prepare_country_authority_handoff(
            CountryAuthorityOwner::WORKER, local)) {
        error = local.empty() ? "country_handoff_self_test_prepare_failed" : local;
        return false;
    }
    if (!probe.install_country_authority_handoff(local) ||
        probe.country_authority_handoff_status().owner !=
            CountryAuthorityOwner::WORKER ||
        probe.country_authority_handoff_status().session_epoch <= epoch) {
        error = "country_handoff_self_test_install_failed";
        return false;
    }
    const uint64_t worker_epoch =
        probe.country_authority_handoff_status().session_epoch;
    if (!probe.prepare_country_authority_handoff(
            CountryAuthorityOwner::SYNC, local) ||
        !probe.install_country_authority_handoff(local) ||
        probe.country_authority_handoff_status().owner !=
            CountryAuthorityOwner::SYNC ||
        probe.country_authority_handoff_status().session_epoch <= worker_epoch) {
        error = "country_handoff_self_test_roundtrip_failed";
        return false;
    }
    return true;
}
