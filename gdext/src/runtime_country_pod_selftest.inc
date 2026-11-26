bool RuntimeCountryPodAuthority::self_test(std::string &error) {
    error.clear();
    RuntimeCountryPodCatalog catalog;
    catalog.catalog_hash = 0x43545259504f4433ULL; // CTRY POD3
    catalog.technology_count = 4;
    catalog.technology_words = 1;
    catalog.technology_points_good_id = 0;
    catalog.technology_costs.assign(4, 1);
    catalog.technology_domains = {0, 1, 2, 3};
    catalog.technology_flags.assign(4, 0);
    catalog.technology_effect_required.assign(4, 0);
    catalog.prerequisite_offsets.assign(5, 0);
    catalog.entry_milestone_indices.assign(4, -1);
    catalog.research_condition_offsets.assign(5, 0);
    catalog.reveal_condition_offsets.assign(5, 0);
    catalog.research_conditions_complete = true;
    catalog.political_regime_ids = {"local_council", "early_clan"};
    catalog.political_regime_capability_bits = {0u, CountryApi::CAP_TREASURY_CONSTRUCTION};
    catalog.political_regime_catalog_hash = 1;

    RuntimeCountryPodSnapshot state;
    state.session_epoch = 1;
    state.generation = 1;
    state.committed_day = -1;
    state.last_research_day = -1;
    state.catalog_hash = catalog.catalog_hash;
    state.cell_count = 4;
    state.country_count = 2;
    state.technology_words = 1;
    state.technology_count = 4;
    state.good_count = 1;
    state.profession_count = 1;
    state.building_type_count = 1;
    state.country_stable_ids = {"alpha", "beta"};
    state.country_display_names = {"Alpha", "Beta"};
    state.research_signal_words = 0;
    state.research_signal_count = 0;
    state.bootstrapped = true;
    state.research_active_index_valid = true;
    state.country_active = {1, 1};
    state.country_generation = {1, 1};
    state.country_state_version = {0, 0};
    state.country_political_regime_ids = {0, 0};
    state.country_political_regime_capabilities = {0u, 0u};
    state.research_active_country_slots = {0, 1};
    state.territory_count = {2, 2};
    state.country_cash = {0, 0};
    state.country_goods = {0, 0};
    state.cell_country_slot = {0, 0, 1, 1};
    state.territory_offsets = {0, 2, 4};
    state.territory_cells = {0, 1, 2, 3};
    state.country_technologies = {0, 0};
    state.country_discovered = {15, 15};
    state.country_pending_technologies = {0, 0};
    state.research_signal_evidence_offsets = {0, 0, 0};
    state.research_queues.assign(2 * 4 * COUNTRY_QUEUE_SLOTS, -1);
    state.research_queue_lengths.assign(2 * 4, 0);
    state.research_weights_bp.assign(2 * 4, 2500);
    state.research_auto_purchase = {0, 0};
    state.research_deferred_points = {0, 0};
    state.research_progress.assign(2 * 4, 0);
    state.research_cost_factor = {1.0, 1.0};
    state.research_efficiency.assign(2 * 4, 1.0);
    state.research_peer_flags.assign(2 * 4, 0);
    state.research_purchased_total = {0, 0};
    state.research_consumed_total = {0, 0};
    state.research_progress_total = {0, 0};
    state.research_completed_total = {0, 0};
    state.is_water = {0, 0, 0, 0};

    // Eligibility comes from the compiled condition, including alternatives.
    // Its compatibility prerequisite CSR must not impose an extra ALL gate.
    RuntimeCountryPodCatalog route_catalog = catalog;
    route_catalog.prerequisite_offsets = {0, 1, 1, 1, 1};
    route_catalog.prerequisites = {1};
    route_catalog.research_condition_offsets = {0, 3, 3, 3, 3};
    route_catalog.research_condition_ops = {1, 1, 11};
    route_catalog.research_condition_refs = {1, 2, 2};
    route_catalog.research_condition_values = {0, 0, 0};
    RuntimeCountryPodSnapshot route_state = state;
    route_state.country_technologies[0] = uint64_t{1} << 2u;
    route_state.country_goods[0] = 1;
    RuntimeCountryCommand enqueue;
    enqueue.request_id = 9001;
    enqueue.sequence = 1;
    enqueue.effective_day = 0;
    enqueue.requested_day = 0;
    enqueue.target_handle = uint64_t{1} << 32u;
    enqueue.opcode = 6;
    enqueue.aux = 0;
    enqueue.domain = 0;
    enqueue.position = -1;
    RuntimeCountryPodAuthority route_authority;
    RuntimeCountryPodPlan route_plan;
    if (!route_authority.bootstrap(route_state, route_catalog, error) ||
        !route_authority.queue_command(enqueue, error) ||
        !route_authority.plan_day(0, 1, route_plan, error) ||
        route_plan.next_state.research_consumed_total[0] != 1 ||
        (route_plan.next_state.country_technologies[0] & 1u) == 0) {
        error = "country_pod_self_test_alternative_route_blocked:" + error;
        return false;
    }
    RuntimeCountryPodCatalog milestone_catalog = catalog;
    milestone_catalog.technology_flags[0] = 2;
    for (int32_t carrier = 0; carrier < 4; ++carrier) {
        RuntimeCountryPodAuthority milestone_authority;
        RuntimeCountryPodPlan milestone_plan;
        enqueue.domain = carrier;
        if (!milestone_authority.bootstrap(state, milestone_catalog, error) ||
            !milestone_authority.queue_command(enqueue, error) ||
            !milestone_authority.plan_day(0, 1, milestone_plan, error) ||
            milestone_plan.next_state.research_queue_lengths[
                static_cast<size_t>(carrier)] != 1) {
            error = "country_pod_self_test_milestone_carrier_rejected:" + error;
            return false;
        }
    }
    RuntimeCountryPodAuthority wrong_domain_authority;
    RuntimeCountryPodPlan wrong_domain_plan;
    if (!wrong_domain_authority.bootstrap(state, catalog, error) ||
        !wrong_domain_authority.queue_command(enqueue, error)) return false;
    if (wrong_domain_authority.plan_day(0, 1, wrong_domain_plan, error) ||
        error != "country_research_domain_mismatch") {
        error = "country_pod_self_test_ordinary_wrong_domain_accepted";
        return false;
    }

    RuntimeCountryPodAuthority authority;
    if (!authority.bootstrap(state, catalog, error)) return false;
    RuntimeCountryPodSnapshot malformed = state;
    malformed.territory_offsets[1] = 4;
    RuntimeCountryPodAuthority malformed_authority;
    if (malformed_authority.bootstrap(malformed, catalog, error)) {
        error = "country_pod_self_test_malformed_snapshot_accepted";
        return false;
    }
    RuntimeCountryCommand transfer;
    transfer.request_id = 1;
    transfer.producer_id = 2;
    transfer.sequence = 1;
    transfer.requested_day = 0;
    transfer.effective_day = 0;
    transfer.opcode = 3;
    transfer.target_handle = (uint64_t{1} << 32u) | 1u;
    transfer.cell = 0;
    if (!authority.queue_command(transfer, error)) return false;
    RuntimeCountryPodPlan plan;
    if (!authority.plan_day(0, 1, plan, error) ||
        !authority.commit_day(plan, {}, error)) return false;
    RuntimeCountryPodSnapshot committed;
    if (!authority.snapshot(committed, error) || committed.committed_day != 0 ||
        committed.cell_country_slot[0] != 1 ||
        committed.territory_offsets != std::vector<int32_t>({0, 1, 4})) {
        error = "country_pod_self_test_commit_failed";
        return false;
    }
    RuntimeCountryCommand stale = transfer;
    stale.request_id = 2;
    stale.sequence = 2;
    stale.requested_day = 0;
    stale.effective_day = 0;
    stale.observed_generation = 999;
    RuntimeCountryPodAuthority stale_authority;
    if (!stale_authority.bootstrap(state, catalog, error) ||
        !stale_authority.queue_command(stale, error)) return false;
    RuntimeCountryPodPlan stale_plan;
    if (stale_authority.plan_day(0, 1, stale_plan, error) ||
        error != "stale_command_generation") {
        error = "country_pod_self_test_stale_generation_not_rejected";
        return false;
    }
    RuntimeCountryPodCatalog reveal_catalog = catalog;
    reveal_catalog.reveal_condition_offsets = {0, 1, 1, 1, 1};
    reveal_catalog.reveal_condition_ops = {2};
    reveal_catalog.reveal_condition_refs = {0};
    reveal_catalog.reveal_condition_values = {0};
    RuntimeCountryPodSnapshot reveal_state = state;
    reveal_state.country_discovered = {14, 15};
    reveal_state.research_signal_count = 1;
    reveal_state.research_signal_words = 1;
    reveal_state.country_research_signals = {0, 0};
    reveal_state.research_signal_cell_offsets = {0, 0, 0};
    RuntimeCountryPodAuthority reveal_authority;
    if (!reveal_authority.bootstrap(reveal_state, reveal_catalog, error))
        return false;
    RuntimeCountryCommand discover_signal;
    discover_signal.request_id = 3;
    discover_signal.producer_id = 2;
    discover_signal.sequence = 3;
    discover_signal.requested_day = 0;
    discover_signal.effective_day = 0;
    discover_signal.opcode = 14;
    discover_signal.target_handle = uint64_t{1} << 32u;
    discover_signal.cell = 0;
    discover_signal.aux = 0;
    if (!reveal_authority.queue_command(discover_signal, error)) return false;
    RuntimeCountryPodPlan reveal_plan;
    if (!reveal_authority.plan_day(0, 1, reveal_plan, error) ||
        !reveal_authority.commit_day(reveal_plan, {}, error))
        return false;
    RuntimeCountryPodSnapshot revealed;
    if (!reveal_authority.snapshot(revealed, error) ||
        (revealed.country_discovered[0] & uint64_t{1}) == 0) {
        error = "country_pod_self_test_signal_reveal_not_applied";
        return false;
    }
    RuntimeCountryPodSaveSection save;
    if (!authority.encode_save(save, error)) return false;
    RuntimeCountryPodAuthority restored;
    if (!restored.restore_save(save, catalog, error) ||
        restored.state_hash() != authority.state_hash()) {
        error = "country_pod_self_test_restore_failed";
        return false;
    }
    save.payload.back() ^= 1u;
    if (restored.restore_save(save, catalog, error) ||
        restored.state_hash() != authority.state_hash()) {
        error = "country_pod_self_test_restore_not_transactional";
        return false;
    }

    RuntimeCountryPodCatalog research_catalog = catalog;
    research_catalog.technology_effect_required.assign(4, 0);
    research_catalog.technology_effect_required[0] = 1;
    research_catalog.technology_flags[0] |= 2;
    RuntimeCountryPodSnapshot research_state = state;
    research_state.country_goods = {1, 0};
    research_state.research_queues.assign(2 * 4 * COUNTRY_QUEUE_SLOTS, -1);
    research_state.research_queue_lengths.assign(2 * 4, 0);
    research_state.research_queues[0] = 0;
    research_state.research_queue_lengths[0] = 1;
    research_state.research_weights_bp.assign(2 * 4, 0);
    research_state.research_weights_bp[0] = 10000;
    research_state.research_weights_bp[4] = 10000;
    research_state.research_progress.assign(2 * 4, 0);
    research_state.research_cost_factor = {1.0, 1.0};
    research_state.research_efficiency.assign(2 * 4, 1.0);
    research_state.research_peer_flags.assign(2 * 4, 0);
    research_state.last_research_day = -1;
    RuntimeCountryPodAuthority research_authority;
    if (!research_authority.bootstrap(research_state, research_catalog, error))
        return false;
    RuntimeCountryPodPlan research_plan;
    if (!research_authority.plan_day(0, 1, research_plan, error) ||
        research_plan.intents.size() != 1u ||
        !research_plan.activated_milestones.empty() ||
        research_plan.next_state.research_consumed_total[0] != 1 ||
        research_plan.next_state.last_research_day != 0) {
        error = "country_pod_self_test_research_plan_failed";
        return false;
    }
    RuntimeDomainAck research_ack;
    research_ack.request_id = research_plan.intents[0].request_id;
    research_ack.transaction_id = research_plan.intents[0].source_id;
    research_ack.target_handle = research_plan.intents[0].target_handle;
    research_ack.target_generation = research_plan.intents[0].target_generation;
    research_ack.domain = research_plan.intents[0].target_domain;
    research_ack.code = RuntimeDomainAckCode::OK;
    research_ack.effective_day = research_plan.intents[0].effective_day;
    research_ack.technology_flags = COUNTRY_PEER_EFFECT_EXISTS |
        COUNTRY_PEER_EFFECT_FIRE_ACKED;
    if (!research_authority.commit_day(research_plan, {research_ack}, error))
        return false;
    RuntimeCountryPodSnapshot researched;
    if (!research_authority.snapshot(researched, error) ||
        (researched.country_technologies[0] & 1u) == 0 ||
        (researched.country_pending_technologies[0] & 1u) != 0 ||
        researched.research_consumed_total[0] != 1 ||
        researched.last_research_day != 0) {
        error = "country_pod_self_test_research_commit_failed";
        return false;
    }
    if (research_plan.activated_milestones.size() != 1u ||
        research_plan.activated_milestones[0].slot != 0 ||
        research_plan.activated_milestones[0].technology != 0) {
        error = "country_pod_self_test_milestone_activation_unreported";
        return false;
    }
    RuntimeCountryPodPlan continuation_plan;
    if (!research_authority.plan_day(1, 2, continuation_plan, error) ||
        continuation_plan.next_state.research_consumed_total[0] != 1 ||
        !continuation_plan.activated_milestones.empty()) {
        error = "country_pod_self_test_research_double_consume";
        return false;
    }
    if (!research_authority.commit_day(continuation_plan, {}, error)) return false;
    if (country_core_hash_business_state(committed) != committed.state_hash) {
        error = "country_pod_self_test_export_hash_mismatch";
        return false;
    }
    return true;
}
