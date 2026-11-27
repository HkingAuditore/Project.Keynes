bool NativeSimulationHost::publish_country_reference(
        int64_t day, uint64_t reference_state_hash, std::string &error,
        const RuntimeCountryPodSnapshot *snapshot) {
    error.clear();
    if (day < 0 || reference_state_hash == 0) {
        error = "country_reference_invalid";
        return false;
    }
    if (snapshot != nullptr &&
        country_core_hash_business_state(*snapshot) != reference_state_hash) {
        error = "country_reference_state_hash_inconsistent";
        return false;
    }
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    RuntimeCountryPodSnapshot stored;
    if (snapshot != nullptr) stored = *snapshot;
    stored.state_hash = reference_state_hash;
    stored.committed_day = day;
    _country_references[day] = std::move(stored);
    while (_country_references.size() > 128u)
        _country_references.erase(_country_references.begin());
    return true;
}

void NativeSimulationHost::bind_shadow_country_peer_mirrors_locked() {
    for (auto &entry : _country_worker_intents) {
        const CountryPeerIntent &intent = entry.second;
        const auto existing = _country_worker_results.find(intent.request_id);
        if (existing != _country_worker_results.end() &&
            existing->second.code != CountryPeerResultCode::PENDING) {
            continue;
        }
        for (auto it = _country_shadow_peer_mirrors.begin();
             it != _country_shadow_peer_mirrors.end(); ++it) {
            if (it->opcode != intent.opcode ||
                it->country_slot != intent.country_slot ||
                it->technology != intent.technology ||
                it->day != intent.day) {
                continue;
            }
            CountryPeerResult bound = *it;
            bound.request_id = intent.request_id;
            bound.session_epoch = intent.session_epoch;
            bound.country_generation = intent.country_generation;
            bound.peer_generation = intent.peer_generation;
            bound.day = intent.day;
            bound.continuation_index = intent.continuation_index;
            bound.country_slot = intent.country_slot;
            bound.technology = intent.technology;
            bound.target_handle = intent.target_handle;
            bound.opcode = intent.opcode;
            if (bound.committed_peer_generation < bound.peer_generation)
                bound.committed_peer_generation = bound.peer_generation;
            _country_worker_results[intent.request_id] = bound;
            if (bound.code != CountryPeerResultCode::PENDING)
                _country_worker_terminal_results[intent.request_id] = bound;
            _country_shadow_peer_mirrors.erase(it);
            break;
        }
    }
}

void NativeSimulationHost::record_country_parity_locked(
        const RuntimeCountryPodSnapshot &worker) {
    const uint64_t worker_hash = worker.state_hash != 0
        ? worker.state_hash
        : country_core_hash_business_state(worker);
    _country_parity_worker_hash.store(worker_hash, std::memory_order_release);
    const auto found = _country_references.find(worker.committed_day);
    if (found == _country_references.end()) {
        static std::atomic<int> s_country_uncompared_reports_left{8};
        if (s_country_uncompared_reports_left.fetch_sub(
                1, std::memory_order_relaxed) > 0) {
            const int64_t first_reference_day = _country_references.empty()
                ? -1 : _country_references.begin()->first;
            const int64_t last_reference_day = _country_references.empty()
                ? -1 : _country_references.rbegin()->first;
            std::fprintf(stderr,
                         "[country][parity] worker_day=%lld uncompared "
                         "reference_range=%lld..%lld depth=%zu\n",
                         static_cast<long long>(worker.committed_day),
                         static_cast<long long>(first_reference_day),
                         static_cast<long long>(last_reference_day),
                         _country_references.size());
            std::fflush(stderr);
        }
        _country_parity_compared.store(0, std::memory_order_release);
        _country_parity_matched.store(0, std::memory_order_release);
        store_atomic_chars(_country_parity_status, "uncompared");
        store_atomic_chars48(_country_parity_field, "");
        return;
    }
    const uint64_t reference_hash = found->second.state_hash != 0
        ? found->second.state_hash
        : country_core_hash_business_state(found->second);
    _country_parity_compared.store(1, std::memory_order_release);
    _country_parity_compared_count.fetch_add(1, std::memory_order_relaxed);
    _country_parity_reference_hash.store(reference_hash, std::memory_order_release);
    if (reference_hash == worker_hash) {
        _country_parity_matched.store(1, std::memory_order_release);
        _country_parity_matched_count.fetch_add(1, std::memory_order_relaxed);
        store_atomic_chars(_country_parity_status, "comparable");
        store_atomic_chars48(_country_parity_field, "");
        _country_parity_index.store(-1, std::memory_order_release);
        return;
    }
    _country_parity_matched.store(0, std::memory_order_release);
    store_atomic_chars(_country_parity_status, "mismatch");
    int64_t first = _country_parity_first_mismatch_day.load(
        std::memory_order_acquire);
    if (first < 0)
        _country_parity_first_mismatch_day.store(worker.committed_day,
                                                 std::memory_order_release);
    char field[48]{};
    int32_t index = -1;
    if (!found->second.country_cash.empty() ||
        !found->second.cell_country_slot.empty()) {
        country_core_first_business_difference(
            found->second, worker, field, sizeof(field), index);
    } else {
        runtime_copy_text(field, "state_hash");
    }
    store_atomic_chars48(_country_parity_field, field);
    _country_parity_index.store(index, std::memory_order_release);
}

bool NativeSimulationHost::mirror_country_peer_result(
        const CountryPeerResult &result, std::string &error) {
    error.clear();
    if (result.code == CountryPeerResultCode::PENDING) return true;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    _country_shadow_peer_mirrors.push_back(result);
    while (_country_shadow_peer_mirrors.size() > 4096u)
        _country_shadow_peer_mirrors.pop_front();
    bind_shadow_country_peer_mirrors_locked();
    _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
    _control_cv.notify_all();
    return true;
}

bool NativeSimulationHost::mirror_sync_country_economy_asset(
        const RuntimeEconomyAssetRequest &request,
        const RuntimeEconomyAssetResult &result, std::string &error) {
    error.clear();
    if (!_country_pod_configured.load(std::memory_order_acquire)) return true;
    if (domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)) return true;
    if (request.request_id == 0) {
        error = "country_shadow_economy_mirror_request_invalid";
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        RuntimeEconomyAssetRequest stored = request;
        stored.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
        _country_economy_asset_requests[request.request_id] = stored;
        _country_economy_asset_terminal_results[request.request_id] = result;
        _country_economy_asset_results[request.request_id] = result;
        ++_country_economy_asset_protocol.terminal_requests;
        _country_economy_asset_protocol.last_request_id = request.request_id;
        _country_economy_asset_protocol.last_transaction_id = request.transaction_id;
    }
    return true;
}

bool NativeSimulationHost::country_shadow_parity_self_test(std::string &error) const {
    error.clear();
    const auto snapshot = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    if (snapshot == nullptr || _country_pod_catalog.catalog_hash == 0) {
        error = "country_parity_self_test_capture_missing";
        return false;
    }
    if (country_core_hash_business_state(*snapshot) != snapshot->state_hash) {
        error = "country_parity_self_test_export_hash_mismatch";
        return false;
    }
    if (snapshot->research_queue_lengths.size() !=
            static_cast<size_t>(snapshot->country_count) *
                RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT ||
        snapshot->research_weights_bp.size() !=
            static_cast<size_t>(snapshot->country_count) *
                RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT) {
        error = "country_parity_self_test_research_lane_shape";
        return false;
    }
    {
        // ACTIVE UI reads through this replica. A shape mismatch here is the
        // exact failure that leaves research enqueue stuck on "次日生效".
        NativeCountryRuntime read_replica;
        if (!read_replica.apply_committed_read_snapshot(*snapshot)) {
            error = "country_parity_self_test_read_replica_rejected";
            return false;
        }
    }
    int32_t slot = -1;
    for (uint32_t candidate = 0; candidate < snapshot->country_count; ++candidate) {
        if (snapshot->country_active[candidate] != 0) {
            slot = static_cast<int32_t>(candidate);
            break;
        }
    }
    if (slot < 0) {
        error = "country_parity_self_test_active_country_missing";
        return false;
    }
    NativeSimulationHost probe;
    RuntimeCountryPodSnapshot fixture = *snapshot;
    fixture.country_pending_technologies.assign(
        fixture.country_pending_technologies.size(), 0);
    fixture.research_queue_lengths.assign(
        fixture.research_queue_lengths.size(), 0);
    fixture.country_cash[static_cast<size_t>(slot)] = 0;
    fixture.state_hash = country_core_hash_business_state(fixture);
    probe._country_pod_catalog = _country_pod_catalog;
    std::string bootstrap_error;
    if (!probe._country_pod_authority.bootstrap(
            fixture, probe._country_pod_catalog, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_parity_self_test_bootstrap_failed" : bootstrap_error;
        return false;
    }
    probe._country_pod_configured.store(true, std::memory_order_release);
    probe._country_worker_session_epoch = 1;
    probe._mode.store(RuntimeSimulationMode::SHADOW, std::memory_order_release);
    // The synchronous producer leads this worker by a Country boundary. The
    // future receipt must stay queued while today's command/hash is checked.
    RuntimeEconomyAssetRequest future_credit;
    future_credit.operation = RuntimeEconomyAssetOperation::FISCAL_COLLECT;
    future_credit.session_epoch = 1;
    future_credit.transaction_id = 7702;
    future_credit.request_id = 7702;
    future_credit.day = fixture.committed_day + 2;
    future_credit.operation_sequence = 1;
    future_credit.country_slot = slot;
    RuntimeEconomyAssetResult future_result;
    future_result.code = RuntimeEconomyAssetResultCode::COMPLETED;
    future_result.state = RuntimeEconomyAssetState::COMPLETED;
    future_result.committed_cash = 17;
    if (!probe.mirror_sync_country_economy_asset(
            future_credit, future_result, error)) return false;
    RuntimeEconomyAssetRequest future_purchase = future_credit;
    future_purchase.operation = RuntimeEconomyAssetOperation::RESEARCH_PURCHASE;
    future_purchase.request_id = 7703;
    future_purchase.transaction_id = 7703;
    future_purchase.operation_sequence = 2;
    future_purchase.reserved_cash = 11;
    future_purchase.prepared_quantity = 3;
    RuntimeEconomyAssetResult purchase_result = future_result;
    purchase_result.committed_cash = 11;
    purchase_result.committed_quantity = 3;
    if (!probe.mirror_sync_country_economy_asset(
            future_purchase, purchase_result, error)) return false;
    RuntimeCountryCommand rename;
    rename.request_id = 7701;
    rename.producer_id = 0;
    rename.sequence = 1;
    rename.submit_order = 1;
    rename.requested_day = fixture.committed_day + 1;
    rename.effective_day = fixture.committed_day + 1;
    rename.opcode = 2;
    rename.target_handle =
        (static_cast<uint64_t>(fixture.country_generation[static_cast<size_t>(slot)])
         << 32u) | static_cast<uint32_t>(slot);
    const char *renamed = "ParityRename";
    for (size_t i = 0; i + 1u < rename.display_name.size() && renamed[i] != '\0'; ++i)
        rename.display_name[i] = renamed[i];
    RuntimeCountryPodAuthority core;
    if (!core.bootstrap(fixture, _country_pod_catalog, bootstrap_error) ||
        !core.queue_command(rename, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_parity_self_test_core_queue_failed" : bootstrap_error;
        return false;
    }
    RuntimeCountryPodPlan core_plan;
    if (!core.plan_day(rename.effective_day, 1, core_plan, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_parity_self_test_core_plan_failed" : bootstrap_error;
        return false;
    }
    std::vector<RuntimeDomainAck> core_acks;
    core_acks.reserve(core_plan.intents.size());
    for (const RuntimeDomainIntent &intent : core_plan.intents) {
        RuntimeDomainAck ack;
        ack.request_id = intent.request_id != 0 ? intent.request_id : intent.source_id;
        ack.transaction_id = intent.source_id;
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.domain = intent.target_domain;
        ack.code = RuntimeDomainAckCode::OK;
        ack.effective_day = intent.effective_day;
        core_acks.push_back(ack);
    }
    if (!core.commit_day(core_plan, core_acks, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_parity_self_test_core_commit_failed" : bootstrap_error;
        return false;
    }
    RuntimeCountryPodSnapshot core_state;
    if (!core.snapshot(core_state, error)) return false;
    std::string publish_error;
    if (!probe.publish_country_reference(
            rename.effective_day, core_state.state_hash, publish_error, &core_state)) {
        error = publish_error.empty()
            ? "country_parity_self_test_reference_failed" : publish_error;
        return false;
    }
    RuntimeCommandPacket packet = encode_country_packet(rename);
    RuntimeDayCommit commit;
    std::string stage_error;
    auto ack_worker_intents = [&]() {
        CountryPeerIntent intent;
        while (probe.poll_country_worker_intent(intent)) {
            CountryPeerResult result;
            result.protocol_version = intent.protocol_version;
            result.code = CountryPeerResultCode::APPLIED;
            result.opcode = intent.opcode;
            result.request_id = intent.request_id;
            result.session_epoch = intent.session_epoch;
            result.country_generation = intent.country_generation;
            result.peer_generation = intent.peer_generation;
            result.committed_peer_generation = intent.peer_generation;
            result.day = intent.day;
            result.continuation_index = intent.continuation_index;
            result.country_slot = intent.country_slot;
            result.technology = intent.technology;
            result.target_handle = intent.target_handle;
            std::string submit_error;
            if (!probe.submit_country_worker_result(result, submit_error)) {
                error = submit_error.empty()
                    ? "country_parity_self_test_ack_failed" : submit_error;
                return false;
            }
        }
        return true;
    };
    if (!probe.execute_country_worker_stage(
            rename.effective_day, 1, {packet}, commit, stage_error, 1)) {
        if (stage_error != "country_worker_peer_results_pending" ||
            !ack_worker_intents()) {
            if (error.empty()) {
                error = stage_error.empty()
                    ? "country_parity_self_test_worker_failed" : stage_error;
            }
            return false;
        }
        stage_error.clear();
        if (!probe.execute_country_worker_stage(
                rename.effective_day, 1, {packet}, commit, stage_error, 1)) {
            error = stage_error.empty()
                ? "country_parity_self_test_worker_commit_failed" : stage_error;
            return false;
        }
    }
    RuntimeCountryPodSnapshot worker_state;
    if (!probe._country_pod_authority.snapshot(worker_state, error)) return false;
    char field[48]{};
    int32_t index = -1;
    if (country_core_first_business_difference(
            core_state, worker_state, field, sizeof(field), index) ||
        country_core_hash_business_state(worker_state) != core_state.state_hash) {
        error = std::string("country_parity_self_test_field_mismatch:") + field;
        return false;
    }
    if (!probe.flush_country_economy_asset_commits(
            error, 0, false, future_credit.day) ||
        !probe._country_pod_authority.snapshot(worker_state, error)) return false;
    const size_t country = static_cast<size_t>(slot);
    const size_t points = country * fixture.good_count +
        static_cast<size_t>(_country_pod_catalog.technology_points_good_id);
    const int64_t expected_cash = core_state.country_cash[country] + 17 - 11;
    const int64_t expected_points = core_state.country_goods[points] + 3;
    const int64_t expected_purchased = core_state.research_purchased_total[country] + 3;
    if (worker_state.country_cash[country] != expected_cash ||
        worker_state.country_goods[points] != expected_points ||
        worker_state.research_purchased_total[country] != expected_purchased) {
        error = "country_parity_self_test_dated_assets_missing";
        return false;
    }
    if (!probe.mirror_sync_country_economy_asset(
            future_credit, future_result, error) ||
        !probe.mirror_sync_country_economy_asset(
            future_purchase, purchase_result, error) ||
        !probe.flush_country_economy_asset_commits(
            error, 0, false, future_credit.day + 1) ||
        !probe._country_pod_authority.snapshot(worker_state, error)) return false;
    if (worker_state.country_cash[country] != expected_cash ||
        worker_state.country_goods[points] != expected_points ||
        worker_state.research_purchased_total[country] != expected_purchased) {
        error = "country_parity_self_test_dated_assets_reapplied";
        return false;
    }
    return true;
}
