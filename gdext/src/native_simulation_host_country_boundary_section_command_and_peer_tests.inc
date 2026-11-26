bool NativeSimulationHost::country_command_receipt_self_test(
        std::string &error) const {
    error.clear();
    const auto snapshot = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    if (snapshot == nullptr || _country_pod_catalog.catalog_hash == 0) {
        error = "country_receipt_self_test_capture_missing";
        return false;
    }

    // Run the protocol against a temporary Host so this test never mutates a
    // live worker, clock, queue, or peer adapter. It deliberately stops at the
    // Country boundary: the packet was admitted by transport but cannot be
    // decoded by the worker, which must become RejectedAtExecution exactly
    // once and remain queryable by cursor.
    NativeSimulationHost probe;
    probe._country_pod_catalog = _country_pod_catalog;
    std::string bootstrap_error;
    if (!probe._country_pod_authority.bootstrap(
            *snapshot, probe._country_pod_catalog, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_receipt_self_test_bootstrap_failed" : bootstrap_error;
        return false;
    }
    probe._country_pod_configured.store(true, std::memory_order_release);
    probe._country_worker_session_epoch = 1;

    RuntimeCountryCommand valid_command;
    valid_command.request_id = 9901;
    valid_command.producer_id = 0;
    valid_command.sequence = 1;
    valid_command.submit_order = 1;
    const int64_t probe_day = std::max<int64_t>(0, snapshot->committed_day);
    valid_command.requested_day = probe_day;
    valid_command.effective_day = probe_day + 1;
    valid_command.opcode = 5; // SET_RESEARCH_WEIGHTS
    // The command is intentionally queue-admission-valid but execution-invalid
    // for this protocol-only fixture. The second malformed packet must reject
    // the whole semantic batch and remove this first packet from POD pending.
    valid_command.target_handle = 0;
    valid_command.weights_bp = {2500, 2500, 2500, 2500};

    RuntimeCommandPacket valid_packet = encode_country_packet(valid_command);

    RuntimeCommandPacket malformed_packet;
    malformed_packet.envelope.request_id = 9902;
    malformed_packet.envelope.producer_id = 0;
    malformed_packet.envelope.sequence = 2;
    malformed_packet.envelope.requested_day = probe_day;
    malformed_packet.envelope.effective_day = probe_day + 1;
    malformed_packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
    malformed_packet.envelope.opcode = 3;
    malformed_packet.envelope.payload_offset = 0;
    malformed_packet.envelope.payload_size = 0;
    std::vector<RuntimeCommandPacket> commands{valid_packet, malformed_packet};
    RuntimeDayCommit commit;
    std::string stage_error;
    if (probe.execute_country_worker_stage(
            valid_packet.envelope.effective_day, 1, commands, commit,
            stage_error, 1)) {
        error = "country_receipt_self_test_expected_execution_rejection";
        return false;
    }
    std::vector<CountryCommandReceipt> receipts;
    probe.poll_country_command_receipts(0, 8, receipts);
    if (receipts.size() != 2 || receipts[0].request_id != 9901 ||
        receipts[1].request_id != 9902 ||
        receipts[0].code != CountryCommandReceiptCode::REJECTED_AT_EXECUTION ||
        receipts[1].code != CountryCommandReceiptCode::REJECTED_AT_EXECUTION ||
        receipts[0].reason.empty() || receipts[1].reason.empty() ||
        probe._country_pod_authority.pending_command_count() != 0) {
        error = "country_receipt_self_test_terminal_missing:" +
            std::to_string(receipts.size()) + ":" +
            std::to_string(probe._country_pod_authority.pending_command_count());
        return false;
    }
    std::vector<CountryCommandReceipt> continuation;
    probe.poll_country_command_receipts(9901, 8, continuation);
    if (continuation.size() != 1 || continuation[0].request_id != 9902) {
        error = "country_receipt_self_test_cursor_continuation_invalid";
        return false;
    }
    std::vector<CountryCommandReceipt> replay;
    probe.poll_country_command_receipts(9902, 8, replay);
    if (!replay.empty()) {
        error = "country_receipt_self_test_cursor_replayed";
        return false;
    }
    return true;
}

bool NativeSimulationHost::country_peer_rejection_self_test(
        std::string &error) const {
    error.clear();
    const auto captured = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    if (captured == nullptr || _country_pod_catalog.catalog_hash == 0) {
        error = "country_rejection_self_test_capture_missing";
        return false;
    }

    RuntimeCountryPodSnapshot fixture = *captured;
    int32_t slot = -1;
    for (uint32_t candidate = 0; candidate < fixture.country_count; ++candidate) {
        if (fixture.country_active[candidate] != 0 &&
            fixture.territory_count[candidate] > 0) {
            slot = static_cast<int32_t>(candidate);
            break;
        }
    }
    if (slot < 0) {
        error = "country_rejection_self_test_active_country_missing";
        return false;
    }
    int32_t technology = -1;
    for (uint32_t candidate = 0;
         candidate < _country_pod_catalog.technology_count; ++candidate) {
        if (_country_pod_catalog.technology_effect_required[candidate] != 0) {
            technology = static_cast<int32_t>(candidate);
            break;
        }
    }
    if (technology < 0) {
        error = "country_rejection_self_test_effect_technology_missing";
        return false;
    }
    const size_t word_base = static_cast<size_t>(slot) * fixture.technology_words;
    for (uint32_t candidate = 0;
         candidate < fixture.technology_count; ++candidate) {
        const size_t word = word_base + candidate / 64u;
        const uint64_t bit = uint64_t{1} << (candidate % 64u);
        fixture.country_discovered[word] |= bit;
        fixture.country_pending_technologies[word] &= ~bit;
        if (static_cast<int32_t>(candidate) == technology)
            fixture.country_technologies[word] &= ~bit;
        else
            fixture.country_technologies[word] |= bit;
        fixture.research_progress[static_cast<size_t>(slot) *
            fixture.technology_count + candidate] = 0;
    }
    fixture.country_pending_technologies[word_base + static_cast<size_t>(
        technology / 64)] |= uint64_t{1} << (technology % 64);
    const int32_t domain = _country_pod_catalog.technology_domains[
        static_cast<size_t>(technology)];
    if (domain < 0 || domain >= static_cast<int32_t>(
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT)) {
        error = "country_rejection_self_test_domain_invalid";
        return false;
    }
    const size_t research_base = static_cast<size_t>(slot) *
        RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
    for (uint32_t lane = 0; lane < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++lane)
        fixture.research_weights_bp[research_base + lane] =
            lane == static_cast<uint32_t>(domain) ? 10000 : 0;
    for (uint32_t lane = 0; lane < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++lane) {
        const size_t queue_index = research_base + lane;
        fixture.research_queue_lengths[queue_index] = 0;
        const size_t queue_base = queue_index * 8u;
        for (uint32_t position = 0; position < 8u; ++position)
            fixture.research_queues[queue_base + position] = -1;
    }
    const size_t queue_index = research_base + static_cast<size_t>(domain);
    fixture.research_queue_lengths[queue_index] = 1;
    fixture.research_queues[queue_index * 8u] = technology;
    const size_t stock_index = static_cast<size_t>(slot) * fixture.good_count +
        static_cast<size_t>(_country_pod_catalog.technology_points_good_id);
    fixture.country_goods[stock_index] = 0;
    fixture.research_cost_factor[static_cast<size_t>(slot)] = 1.0;
    for (uint32_t lane = 0; lane < 4u; ++lane)
        fixture.research_efficiency[static_cast<size_t>(slot) * 4u + lane] = 1.0;
    fixture.research_active_index_valid = 1;
    fixture.research_active_country_slots = {slot};

    NativeSimulationHost probe;
    probe._country_pod_catalog = _country_pod_catalog;
    std::string bootstrap_error;
    if (!probe._country_pod_authority.bootstrap(
            fixture, probe._country_pod_catalog, bootstrap_error)) {
        error = bootstrap_error.empty()
            ? "country_rejection_self_test_bootstrap_failed" : bootstrap_error;
        return false;
    }
    probe._country_pod_configured.store(true, std::memory_order_release);
    probe._country_worker_session_epoch = 17;
    if (!probe.publish_country_snapshot(fixture)) {
        error = "country_rejection_self_test_initial_view_missing";
        return false;
    }
    const int64_t rejected_day = fixture.committed_day + 1;
    RuntimeDayCommit first_commit;
    std::string stage_error;
    if (probe.execute_country_worker_stage(
            rejected_day, 1, {}, first_commit, stage_error, 1) ||
        probe._country_worker_intents.empty()) {
        error = "country_rejection_self_test_intent_missing";
        return false;
    }
    CountryPeerIntent intent;
    if (!probe.poll_country_worker_intent(intent)) {
        error = "country_rejection_self_test_poll_missing";
        return false;
    }
    CountryPeerResult rejected;
    rejected.code = CountryPeerResultCode::REJECTED;
    rejected.opcode = intent.opcode;
    rejected.request_id = intent.request_id;
    rejected.session_epoch = intent.session_epoch;
    rejected.country_generation = intent.country_generation;
    rejected.committed_peer_generation = intent.peer_generation;
    rejected.peer_generation = intent.peer_generation;
    rejected.day = intent.day;
    rejected.continuation_index = intent.continuation_index;
    rejected.country_slot = intent.country_slot;
    rejected.technology = intent.technology;
    rejected.target_handle = intent.target_handle;
    country_peer_copy_reason(rejected.reason, "self_test_peer_rejected");
    if (!probe.submit_country_worker_result(rejected, stage_error)) {
        error = stage_error.empty() ? "country_rejection_self_test_submit_failed" :
            stage_error;
        return false;
    }
    const uint64_t generation_before = probe._country_pod_authority.generation();
    RuntimeDayCommit rejected_commit;
    if (!probe.execute_country_worker_stage(
            rejected_day, 1, {}, rejected_commit, stage_error, 1) ||
        (rejected_commit.completed_domain_mask &
            runtime_domain_mask(RuntimeDomainId::COUNTRY)) == 0u) {
        error = stage_error.empty() ? "country_rejection_self_test_not_committed" :
            stage_error;
        return false;
    }
    const CountryWorkerProtocolStatus rejected_status =
        probe.country_worker_protocol_status();
    RuntimeCountryPodSnapshot rejected_snapshot;
    if (!probe._country_pod_authority.snapshot(rejected_snapshot, stage_error)) {
        error = stage_error.empty() ? "country_rejection_self_test_snapshot_failed" :
            stage_error;
        return false;
    }
    const size_t target_bit_word = word_base + static_cast<size_t>(technology / 64);
    const uint64_t target_bit = uint64_t{1} << (technology % 64);
    const int64_t consumed_before_rejection = fixture.research_consumed_total[
        static_cast<size_t>(slot)];
    const int64_t consumed_after_rejection = rejected_snapshot.research_consumed_total[
        static_cast<size_t>(slot)];
    if (rejected_status.rejected_intents != 1 ||
        !rejected_status.has_unreported_rejection ||
        rejected_status.retry_day != rejected_day + 1 ||
        rejected_status.rejected_request_id != intent.request_id ||
        rejected_status.pending_intents != 0 ||
        probe._country_pod_authority.committed_day() != rejected_day ||
        probe._country_pod_authority.generation() != generation_before ||
        (rejected_snapshot.country_pending_technologies[target_bit_word] &
            target_bit) == 0 || consumed_after_rejection !=
            consumed_before_rejection ||
        !(rejected_status.plan_active || rejected_status.pending_intents != 0 ||
          rejected_status.result_count != 0 ||
          rejected_status.rejected_intents != 0 ||
          rejected_status.has_unreported_rejection)) {
        error = "country_rejection_self_test_barrier_state_invalid";
        return false;
    }
    CountryPeerResult duplicate = rejected;
    if (!probe.submit_country_worker_result(duplicate, stage_error)) {
        error = stage_error.empty() ? "country_rejection_self_test_duplicate_not_idempotent" :
            stage_error;
        return false;
    }
    CountryPeerIntent retry;
    RuntimeDayCommit retry_wait;
    // Pair the retry with a claim so the same Country plan contains both
    // a territory change and an outstanding technology peer.
    const auto unowned = std::find(fixture.cell_country_slot.begin(),
                                   fixture.cell_country_slot.end(), -1);
    if (unowned == fixture.cell_country_slot.end()) {
        error = "country_rejection_self_test_unowned_cell_missing";
        return false;
    }
    RuntimeCountryCommand claim;
    claim.request_id = probe.allocate_command_request_id();
    claim.sequence = 1;
    claim.opcode = 20; // CLAIM_UNOWNED_TERRITORY
    claim.cell = static_cast<int32_t>(unowned - fixture.cell_country_slot.begin());
    claim.effective_day = rejected_day + 1;
    claim.target_handle = intent.target_handle;
    if (!probe._country_pod_authority.queue_command(claim, stage_error)) {
        error = stage_error;
        return false;
    }
    if (probe.execute_country_worker_stage(
            rejected_day + 1, 1, {}, retry_wait, stage_error, 1) ||
        !probe.poll_country_worker_intent(retry) ||
        retry.request_id == intent.request_id) {
        error = "country_rejection_self_test_retry_identity_invalid";
        return false;
    }
    const auto waiting_view = probe.country_worker_read_view(0);
    if (waiting_view.snapshot == nullptr ||
        waiting_view.snapshot->cell_country_slot[claim.cell] != -1) {
        error = "country_rejection_self_test_unsealed_territory_visible";
        return false;
    }
    CountryPeerResult applied = rejected;
    applied.code = CountryPeerResultCode::APPLIED;
    applied.request_id = retry.request_id;
    applied.opcode = retry.opcode;
    applied.session_epoch = retry.session_epoch;
    applied.country_generation = retry.country_generation;
    applied.day = retry.day;
    applied.continuation_index = retry.continuation_index;
    applied.country_slot = retry.country_slot;
    applied.technology = retry.technology;
    applied.target_handle = retry.target_handle;
    applied.technology_flags = COUNTRY_PEER_EFFECT_FIRE_ACKED;
    if (!probe.submit_country_worker_result(applied, stage_error)) {
        error = stage_error.empty() ? "country_rejection_self_test_retry_submit_failed" :
            stage_error;
        return false;
    }
    RuntimeDayCommit retry_commit;
    if (!probe.execute_country_worker_stage(
            rejected_day + 1, 1, {}, retry_commit, stage_error, 1)) {
        error = stage_error.empty() ? "country_rejection_self_test_retry_commit_failed" :
            stage_error;
        return false;
    }
    const auto claim_view = probe.country_worker_read_view(waiting_view.generation);
    if (!claim_view.available ||
        claim_view.patch_base_generation != waiting_view.generation ||
        claim_view.changed_cells != std::vector<int32_t>{claim.cell} ||
        claim_view.changed_owners != std::vector<int32_t>{slot}) {
        error = "country_rejection_self_test_territory_patch_missing";
        return false;
    }
    RuntimeCountryPodSnapshot final_snapshot;
    if (!probe._country_pod_authority.snapshot(final_snapshot, stage_error)) {
        error = stage_error.empty() ? "country_rejection_self_test_final_snapshot_failed" :
            stage_error;
        return false;
    }
    const CountryWorkerProtocolStatus final_status =
        probe.country_worker_protocol_status();
    if ((final_snapshot.country_technologies[target_bit_word] & target_bit) == 0 ||
        final_snapshot.research_consumed_total[static_cast<size_t>(slot)] !=
            consumed_after_rejection || final_status.plan_active ||
        final_status.pending_intents != 0 || final_status.result_count != 0 ||
        final_status.rejected_intents != 0 ||
        final_status.has_unreported_rejection) {
        error = "country_rejection_self_test_final_state_invalid";
        return false;
    }
    return true;
}
