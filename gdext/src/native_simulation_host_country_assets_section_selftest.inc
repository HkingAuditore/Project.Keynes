bool NativeSimulationHost::country_economy_asset_protocol_self_test(
        std::string &error) const {
    error.clear();
    NativeSimulationHost probe;
    probe._country_worker_session_epoch = 41;
    probe.reserve_command_request_ids_through(9000);
    if (probe.allocate_command_request_id() != 9001) {
        error = "country_economy_asset_restored_request_floor_failed";
        return false;
    }
    probe.reserve_command_request_ids_through(7000);
    if (probe.allocate_command_request_id() != 9002) {
        error = "country_economy_asset_request_floor_rewound";
        return false;
    }

    RuntimeEconomyAssetRequest off_thread_cash;
    off_thread_cash.operation = RuntimeEconomyAssetOperation::CASH_FROM_COHORT;
    std::string boundary_error;
    if (probe.prepare_worker_cohort_cash(off_thread_cash, boundary_error) ||
        boundary_error != "country_worker_cohort_cash_boundary_invalid" ||
        !probe._country_economy_asset_requests.empty()) {
        error = "country_worker_cohort_cash_wrong_thread_accepted";
        return false;
    }
    // The two rejection classes must stay separated. A contract violation is a
    // caller bug and has to stay fatal; an open Country plan window is
    // backpressure and has to stay retryable. Collapsing them back into one
    // reason is what turned a normal continuation into an economy stop.
    if (runtime_country_asset_pending_reason(
            "country_worker_cohort_cash_boundary_invalid") ||
        !runtime_country_asset_pending_reason(
            "country_economy_asset_country_plan_pending")) {
        error = "country_worker_cohort_cash_reason_class_collapsed";
        return false;
    }
    // Same split for colonization. Under Country worker authority the paired
    // CLAIM commits on the worker's own boundary, so Economy SETTLE can observe
    // the target as still unowned. That is backpressure: classifying it as a
    // lost target sent the settlers home while the claim still landed, leaving
    // the player a cell they owned with nobody living on it.
    if (!runtime_country_asset_pending_reason(
            "country_economy_asset_territory_claim_pending")) {
        error = "country_economy_territory_claim_reason_class_collapsed";
        return false;
    }

    RuntimeEconomyAssetRequest request;
    request.operation = RuntimeEconomyAssetOperation::TREASURY_SPEND;
    request.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
    request.session_epoch = 41;
    request.transaction_id = 7001;
    request.request_id = 7101;
    request.origin_epoch = 2;
    request.origin_stage = 9;
    request.continuation_index = 3;
    request.day = 12;
    request.operation_sequence = 99;
    request.country_generation = 5;
    request.peer_generation = 9;
    request.country_handle = 0x100000001ULL;
    request.country_slot = 0;
    request.target_slot = 2;
    request.good_count = 1;
    request.good_ids[0] = 4;
    request.good_quantities[0] = 7;
    request.requested_cash = 10;
    request.reserved_cash = 10;
    std::string publish_error;
    if (!probe.publish_country_economy_asset_requests({request}, publish_error)) {
        error = publish_error.empty()
            ? "country_economy_asset_self_test_publish_failed" : publish_error;
        return false;
    }
    RuntimeEconomyAssetRequest polled;
    if (!probe.poll_country_economy_asset_request(polled) ||
        !economy_asset_request_equal(polled, request)) {
        error = "country_economy_asset_self_test_poll_mismatch";
        return false;
    }
    RuntimeEconomyAssetRequest mismatch = request;
    mismatch.requested_cash = 11;
    if (probe.publish_country_economy_asset_requests({mismatch}, publish_error) ||
        publish_error != "country_economy_asset_request_duplicate_mismatch") {
        error = "country_economy_asset_self_test_duplicate_admission_failed";
        return false;
    }

    RuntimeEconomyAssetResult prepared;
    prepared.code = RuntimeEconomyAssetResultCode::PEER_PREPARED;
    prepared.state = RuntimeEconomyAssetState::PEER_PREPARED;
    prepared.accepted = 1;
    prepared.session_epoch = request.session_epoch;
    prepared.transaction_id = request.transaction_id;
    prepared.request_id = request.request_id;
    prepared.operation = request.operation;
    prepared.continuation_index = request.continuation_index;
    prepared.day = request.day;
    prepared.country_generation = request.country_generation;
    prepared.peer_generation = request.peer_generation;
    prepared.committed_peer_generation = 10;
    prepared.country_slot = request.country_slot;
    prepared.target_slot = request.target_slot;
    std::string result_error;
    if (!probe.submit_country_economy_asset_result(prepared, result_error) ||
        !probe.submit_country_economy_asset_result(prepared, result_error)) {
        error = result_error.empty()
            ? "country_economy_asset_self_test_prepare_failed" : result_error;
        return false;
    }
    RuntimeEconomyAssetResult bad_generation = prepared;
    bad_generation.committed_peer_generation = 8;
    if (probe.submit_country_economy_asset_result(
            bad_generation, result_error) ||
        result_error != "country_economy_asset_result_generation_mismatch") {
        error = "country_economy_asset_self_test_generation_guard_failed";
        return false;
    }

    RuntimeEconomyAssetResult completed = prepared;
    completed.code = RuntimeEconomyAssetResultCode::COMPLETED;
    completed.state = RuntimeEconomyAssetState::COMPLETED;
    completed.committed_cash = 10;
    completed.committed_goods_total = 7;
    if (!probe.submit_country_economy_asset_result(completed, result_error) ||
        !probe.submit_country_economy_asset_result(completed, result_error)) {
        error = result_error.empty()
            ? "country_economy_asset_self_test_complete_failed" : result_error;
        return false;
    }
    RuntimeEconomyAssetResult mismatched_terminal = completed;
    mismatched_terminal.reason[0] = 'x';
    if (probe.submit_country_economy_asset_result(
            mismatched_terminal, result_error) ||
        result_error != "country_economy_asset_result_duplicate_mismatch") {
        error = "country_economy_asset_self_test_terminal_guard_failed";
        return false;
    }

    // A stale peer result after the CREATED->COUNTRY_PREPARED transition is
    // retryable: the old polled copy is no longer the canonical request, and
    // no asset was committed by the rejected message.
    auto transition_probe_host = std::make_unique<NativeSimulationHost>();
    transition_probe_host->_country_worker_session_epoch = request.session_epoch;
    RuntimeEconomyAssetRequest transition_probe;
    transition_probe.operation = RuntimeEconomyAssetOperation::RESEARCH_PURCHASE;
    transition_probe.state = RuntimeEconomyAssetState::CREATED;
    transition_probe.session_epoch = request.session_epoch;
    transition_probe.transaction_id = 7202;
    transition_probe.request_id = 7202;
    transition_probe.origin_domain = static_cast<uint32_t>(RuntimeDomainId::ECONOMY);
    transition_probe.origin_epoch = request.origin_epoch;
    transition_probe.origin_stage = request.origin_stage;
    transition_probe.day = request.day;
    transition_probe.operation_sequence = 7202;
    transition_probe.country_handle = request.country_handle;
    transition_probe.country_slot = -1;
    transition_probe.target_slot = request.target_slot;
    transition_probe.requested_quantity = 1;
    transition_probe.requested_cash = 1;
    transition_probe.requested_goods_total = 1;
    if (!transition_probe_host->publish_country_economy_asset_requests(
            {transition_probe}, publish_error)) {
        error = "country_economy_asset_self_test_transition_seed_failed";
        return false;
    }
    RuntimeEconomyAssetRequest stale_transition;
    if (!transition_probe_host->poll_country_economy_asset_request(stale_transition)) {
        error = "country_economy_asset_self_test_transition_poll_failed";
        return false;
    }
    RuntimeEconomyAssetRequest prepared_transition = stale_transition;
    prepared_transition.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
    prepared_transition.country_slot = request.country_slot;
    prepared_transition.country_generation = request.country_generation;
    prepared_transition.prepared_quantity = 1;
    prepared_transition.reserved_cash = 1;
    if (!transition_probe_host->publish_country_economy_asset_requests(
            {prepared_transition}, publish_error)) {
        error = "country_economy_asset_self_test_transition_publish_failed";
        return false;
    }
    RuntimeEconomyAssetResult stale_transition_result;
    stale_transition_result.code = RuntimeEconomyAssetResultCode::COMPLETED;
    stale_transition_result.state = RuntimeEconomyAssetState::COMPLETED;
    stale_transition_result.accepted = 1;
    stale_transition_result.session_epoch = stale_transition.session_epoch;
    stale_transition_result.transaction_id = stale_transition.transaction_id;
    stale_transition_result.request_id = stale_transition.request_id;
    stale_transition_result.operation = stale_transition.operation;
    stale_transition_result.day = stale_transition.day;
    stale_transition_result.country_slot = stale_transition.country_slot;
    stale_transition_result.target_slot = stale_transition.target_slot;
    stale_transition_result.country_generation = prepared_transition.country_generation;
    stale_transition_result.peer_generation = prepared_transition.peer_generation;
    stale_transition_result.committed_peer_generation = prepared_transition.peer_generation;
    stale_transition_result.committed_quantity = 1;
    stale_transition_result.committed_cash = 1;
    if (transition_probe_host->submit_country_economy_asset_result(
            stale_transition_result, result_error) ||
        result_error != "country_economy_asset_result_identity_retry_pending") {
        error = result_error.empty()
            ? "country_economy_asset_self_test_transition_retry_missing"
            : result_error;
        return false;
    }
    if (!transition_probe_host->requeue_country_economy_asset_request(
            stale_transition.request_id, publish_error)) {
        error = publish_error.empty()
            ? "country_economy_asset_self_test_transition_requeue_failed"
            : publish_error;
        return false;
    }
    const RuntimeEconomyAssetProtocolStatus status =
        probe.country_economy_asset_protocol_status();
    if (status.queued_requests != 0 || status.pending_requests != 0 ||
        status.terminal_requests != 1 || status.rejected_results != 0) {
        error = "country_economy_asset_self_test_status_mismatch";
        return false;
    }

    // D7T1 must retain all three durable shapes: terminal rows, a Country
    // request that has not yet been polled, and an Economy-origin request
    // waiting for Country prepare. The Country apply marker is included to
    // prove a restored duplicate cannot apply the same asset mutation twice.
    probe._country_economy_asset_committed.insert(request.request_id);
    RuntimeEconomyAssetRequest pending = request;
    pending.operation = RuntimeEconomyAssetOperation::FISCAL_RESERVE;
    pending.state = RuntimeEconomyAssetState::COUNTRY_PREPARED;
    pending.transaction_id = 7002;
    pending.request_id = 7102;
    pending.day = 13;
    pending.operation_sequence = 100;
    pending.continuation_index = 0;
    pending.peer_generation = 9;
    pending.good_count = 0;
    pending.good_id = -1;
    pending.good_ids = {};
    pending.good_quantities = {};
    pending.requested_quantity = 5;
    pending.prepared_quantity = 5;
    pending.requested_cash = 5;
    pending.reserved_cash = 5;
    pending.requested_goods_total = 0;
    pending.reserved_goods_total = 0;
    if (!probe.publish_country_economy_asset_requests({pending}, publish_error)) {
        error = publish_error.empty()
            ? "country_economy_asset_self_test_pending_seed_failed"
            : publish_error;
        return false;
    }
    RuntimeEconomyAssetRequest dispatched_pending;
    if (!probe.poll_country_economy_asset_request(dispatched_pending) ||
        dispatched_pending.request_id != pending.request_id) {
        error = "country_economy_asset_self_test_pending_dispatch_failed";
        return false;
    }
    RuntimeEconomyAssetRequest origin = pending;
    origin.operation = RuntimeEconomyAssetOperation::FISCAL_RETURN;
    origin.state = RuntimeEconomyAssetState::CREATED;
    origin.transaction_id = 7003;
    origin.request_id = 7103;
    origin.operation_sequence = 101;
    origin.prepared_quantity = 0;
    origin.reserved_cash = 0;
    if (!probe.enqueue_economy_origin_country_asset(origin, publish_error)) {
        error = publish_error.empty()
            ? "country_economy_asset_self_test_origin_seed_failed"
            : publish_error;
        return false;
    }
    std::vector<uint8_t> journal;
    std::string journal_error;
    // Terminal history may predate the current transport session. Its matched
    // request/result identity remains durable; unresolved requests may not.
    probe._country_economy_asset_requests.at(request.request_id).session_epoch = 40;
    probe._country_economy_asset_results.at(request.request_id).session_epoch = 40;
    probe._country_economy_asset_terminal_results.at(request.request_id).session_epoch = 40;
    if (!probe.serialize_country_economy_asset_journal(journal, journal_error) ||
        journal.size() < 16u) {
        error = journal_error.empty()
            ? "country_economy_asset_self_test_journal_encode_failed"
            : journal_error;
        return false;
    }
    auto restored = std::make_unique<NativeSimulationHost>();
    restored->_country_worker_session_epoch = 52;
    if (!restored->restore_country_economy_asset_journal(
            journal.data(), journal.size(), journal_error)) {
        error = journal_error.empty()
            ? "country_economy_asset_self_test_journal_restore_failed"
            : journal_error;
        return false;
    }
    probe._country_economy_asset_requests.at(pending.request_id).session_epoch = 40;
    std::vector<uint8_t> stale_pending_journal;
    if (!probe.serialize_country_economy_asset_journal(stale_pending_journal, journal_error)) {
        error = "country_economy_asset_self_test_stale_pending_encode_failed";
        return false;
    }
    auto stale_pending_restore = std::make_unique<NativeSimulationHost>();
    stale_pending_restore->_country_worker_session_epoch = 52;
    if (stale_pending_restore->restore_country_economy_asset_journal(
            stale_pending_journal.data(), stale_pending_journal.size(), journal_error) ||
        journal_error != "d7_transaction_journal_request_invalid") {
        error = "country_economy_asset_self_test_stale_pending_accepted";
        return false;
    }
    probe._country_economy_asset_requests.at(pending.request_id).session_epoch = 41;
    RuntimeEconomyAssetRequest bootstrap_history = request;
    bootstrap_history.operation = RuntimeEconomyAssetOperation::FISCAL_COLLECT;
    bootstrap_history.origin_domain = static_cast<uint32_t>(RuntimeDomainId::ECONOMY);
    bootstrap_history.day = -1;
    if (!economy_asset_journal_request_valid(bootstrap_history, journal_error, true) ||
        economy_asset_journal_request_valid(bootstrap_history, journal_error, false)) {
        error = "country_economy_asset_self_test_bootstrap_history_invalid";
        return false;
    }
    const auto restored_terminal =
        restored->_country_economy_asset_terminal_results.find(request.request_id);
    const auto restored_pending =
        restored->_country_economy_asset_requests.find(pending.request_id);
    const auto restored_origin =
        restored->_country_economy_asset_requests.find(origin.request_id);
    if (restored_terminal ==
            restored->_country_economy_asset_terminal_results.end() ||
        restored_pending == restored->_country_economy_asset_requests.end() ||
        restored_origin == restored->_country_economy_asset_requests.end() ||
        restored_pending->second.transaction_id != pending.transaction_id ||
        restored_origin->second.transaction_id != origin.transaction_id ||
        restored_pending->second.session_epoch != 52 ||
        restored_origin->second.session_epoch != 52 ||
        restored->_country_economy_asset_committed.find(request.request_id) ==
            restored->_country_economy_asset_committed.end()) {
        error = "country_economy_asset_self_test_journal_identity_failed";
        return false;
    }
    const RuntimeEconomyAssetProtocolStatus restored_status =
        restored->country_economy_asset_protocol_status();
    if (restored_status.queued_requests != 1 ||
        restored_status.pending_requests != 2 ||
        restored_status.terminal_requests != 1 ||
        restored_status.recovered_transactions != 3) {
        error = "country_economy_asset_self_test_journal_status_failed";
        return false;
    }
    RuntimeEconomyAssetRequest rebound_pending;
    if (!restored->poll_country_economy_asset_request(rebound_pending) ||
        rebound_pending.request_id != pending.request_id ||
        rebound_pending.session_epoch != 52) {
        error = "country_economy_asset_self_test_pending_requeue_failed";
        return false;
    }
    if (restored->_economy_origin_asset_queue.empty() ||
        restored->_economy_origin_asset_queue.front() != origin.request_id) {
        error = "country_economy_asset_self_test_origin_requeue_failed";
        return false;
    }
    RuntimeEconomyAssetResult old_session = completed;
    if (restored->submit_country_economy_asset_result(
            old_session, result_error) ||
        result_error != "country_economy_asset_result_session_mismatch") {
        error = "country_economy_asset_self_test_old_session_guard_failed";
        return false;
    }
    RuntimeEconomyAssetResult rebound = completed;
    rebound.session_epoch = 52;
    if (!restored->submit_country_economy_asset_result(rebound, result_error) ||
        restored->country_economy_asset_protocol_status().duplicate_messages == 0) {
        error = result_error.empty()
            ? "country_economy_asset_self_test_restored_duplicate_failed"
            : result_error;
        return false;
    }
    restored->acknowledge_country_economy_asset_consumed(request.request_id);
    if (restored->_country_economy_asset_requests.find(request.request_id) !=
            restored->_country_economy_asset_requests.end() ||
        restored->_country_economy_asset_terminal_results.find(request.request_id) !=
            restored->_country_economy_asset_terminal_results.end() ||
        restored->_country_economy_asset_requests.find(pending.request_id) ==
            restored->_country_economy_asset_requests.end()) {
        error = "country_economy_asset_self_test_consumed_retirement_failed";
        return false;
    }
    std::vector<uint8_t> retired_journal;
    if (!restored->serialize_country_economy_asset_journal(
            retired_journal, journal_error)) {
        error = journal_error.empty()
            ? "country_economy_asset_self_test_retired_journal_encode_failed"
            : journal_error;
        return false;
    }
    auto retired_restore = std::make_unique<NativeSimulationHost>();
    retired_restore->_country_worker_session_epoch = 54;
    if (!retired_restore->restore_country_economy_asset_journal(
            retired_journal.data(), retired_journal.size(), journal_error) ||
        retired_restore->_country_economy_asset_requests.find(request.request_id) !=
            retired_restore->_country_economy_asset_requests.end() ||
        retired_restore->_country_economy_asset_requests.find(pending.request_id) ==
            retired_restore->_country_economy_asset_requests.end()) {
        error = journal_error.empty()
            ? "country_economy_asset_self_test_retired_journal_restore_failed"
            : journal_error;
        return false;
    }
    std::vector<uint8_t> corrupted = journal;
    corrupted[4] ^= 0xffu;
    auto corrupt_probe = std::make_unique<NativeSimulationHost>();
    corrupt_probe->_country_worker_session_epoch = 53;
    if (corrupt_probe->restore_country_economy_asset_journal(
            corrupted.data(), corrupted.size(), journal_error)) {
        error = "country_economy_asset_self_test_corrupt_journal_accepted";
        return false;
    }

    // A goods-only treasury spend (colonization kit cargo) must move goods
    // without touching treasury cash, and a peer result that commits more cash
    // than prepare reserved must be refused rather than debited.
    {
        RuntimeCountryPodSnapshot pod;
        pod.country_count = 1;
        pod.good_count = 2;
        pod.generation = 3;
        pod.country_cash = {1000};
        pod.country_goods = {0, 50};
        pod.country_state_version = {0};
        const RuntimeCountryPodCatalog pod_catalog;
        RuntimeEconomyAssetRequest goods_spend;
        goods_spend.operation = RuntimeEconomyAssetOperation::TREASURY_SPEND;
        goods_spend.country_slot = 0;
        goods_spend.requested_cash = 0;
        goods_spend.requested_quantity = 7;
        goods_spend.requested_goods_total = 7;
        goods_spend.good_count = 1;
        goods_spend.good_id = 1;
        goods_spend.good_ids[0] = 1;
        goods_spend.good_quantities[0] = 7;
        std::string pod_error;
        if (!country_core_apply_economy_asset_prepare(
                pod, pod_catalog, goods_spend, pod_error) ||
            goods_spend.reserved_cash != 0) {
            error = "country_economy_asset_self_test_goods_spend_prepare_failed";
            return false;
        }
        RuntimeEconomyAssetResult goods_done;
        goods_done.code = RuntimeEconomyAssetResultCode::COMPLETED;
        goods_done.state = RuntimeEconomyAssetState::COMPLETED;
        goods_done.committed_quantity = 7;
        goods_done.committed_cash = 7;
        RuntimeCountryPodSnapshot legacy_pod = pod;
        if (country_core_apply_economy_asset_commit(
                legacy_pod, pod_catalog, goods_spend, goods_done, pod_error) ||
            pod_error != "country_economy_asset_commit_cash_exceeds_reserved" ||
            legacy_pod.country_cash[0] != 1000) {
            error = "country_economy_asset_self_test_goods_spend_cash_guard_failed";
            return false;
        }
        goods_done.committed_cash = 0;
        if (!country_core_apply_economy_asset_commit(
                pod, pod_catalog, goods_spend, goods_done, pod_error) ||
            pod.country_cash[0] != 1000 || pod.country_goods[1] != 43) {
            error = "country_economy_asset_self_test_goods_spend_commit_failed";
            return false;
        }
    }

    // A continuation-owned COMPLETED terminal is neither swept in by the
    // generic flush nor reported idle for authority handoff until its owner
    // settles it or releases it.
    {
        auto settle_probe = std::make_unique<NativeSimulationHost>();
        RuntimeEconomyAssetRequest owned = request;
        owned.request_id = 7201;
        owned.transaction_id = 7201;
        RuntimeEconomyAssetResult owned_done = completed;
        owned_done.request_id = owned.request_id;
        owned_done.transaction_id = owned.transaction_id;
        settle_probe->_country_economy_asset_requests[owned.request_id] = owned;
        settle_probe->_country_economy_asset_terminal_results[owned.request_id] =
            owned_done;
        settle_probe->defer_country_economy_asset_settlement(owned.request_id);
        std::string flush_error;
        if (!settle_probe->country_economy_asset_settlement_deferred(
                owned.request_id) ||
            !settle_probe->flush_country_economy_asset_commits(flush_error) ||
            settle_probe->_country_economy_asset_committed.count(
                owned.request_id) != 0 ||
            settle_probe->country_authority_drain_idle_locked()) {
            error = "country_economy_asset_self_test_deferred_settle_swept";
            return false;
        }
        settle_probe->release_country_economy_asset_settlement(owned.request_id);
        if (settle_probe->country_economy_asset_settlement_deferred(
                owned.request_id) ||
            !settle_probe->country_authority_drain_idle_locked()) {
            error = "country_economy_asset_self_test_deferred_release_failed";
            return false;
        }
    }
    return true;
}
