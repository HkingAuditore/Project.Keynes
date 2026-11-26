bool RuntimeModifierPodAuthority::self_test(std::string &error) {
    clear_error(error);
    const auto fail = [&error](const char *reason) {
        if (error.empty()) error = reason;
        return false;
    };
    RuntimeModifierPodCatalog catalog;
    catalog.stats = {{0, -100.0, 100.0, 1}, {1, 0.0, 10.0, 1},
                     {2, 0.0, 100.0, 1}, {3, 0.0, 100.0, 1}};
    catalog.definitions = {{1, 0, POLICY_STACK_REFRESH, 4, 2, 0, 2},
                           {1, 1, POLICY_UNIQUE_SOURCE, 1, -1, 2, 1},
                           {1, 2, POLICY_INDEPENDENT, 2, -1, 3, 1},
                           {1, 3, POLICY_INDEPENDENT, 2, -1, 4, 1}};
    catalog.terms = {{0, 2.0, 1.0}, {0, 0.0, 1.5},
                     {1, 0.0, 1.25}, {2, 3.0, 1.0},
                     {3, 0.0, 0.75}};
    RuntimeModifierPodAuthority authority;
    if (!authority.configure(catalog, error)) return false;
    RuntimeModifierPodCatalog invalid_catalog = catalog;
    invalid_catalog.stats[0].domain = 4;
    RuntimeModifierPodAuthority catalog_probe;
    std::string expected_error;
    if (catalog_probe.configure(invalid_catalog, expected_error))
        return fail("modifier_pod_catalog_shape_self_test_failed");
    invalid_catalog = catalog;
    invalid_catalog.catalog_hash = 1;
    expected_error.clear();
    if (catalog_probe.configure(invalid_catalog, expected_error))
        return fail("modifier_pod_catalog_hash_self_test_failed");
    RuntimeModifierPodCommand apply;
    apply.request_id = 1; apply.producer_id = 2; apply.sequence = 1;
    apply.effective_day = 0; apply.opcode = COMMAND_APPLY; apply.domain = 0;
    apply.definition_id = 0; apply.scope = 2; apply.entity_handle = 7;
    apply.duration_days = 2; apply.stacks = 1; apply.magnitude_q16 = Q16_ONE;
    RuntimeModifierPodSnapshot planned;
    std::vector<RuntimeDomainAck> acks;
    RuntimeModifierPodReport report;
    if (!authority.plan_day(0, 1, {apply}, {}, planned, acks, report, error) ||
        !authority.commit_day(planned, error) || authority.snapshot().entries.size() != 1) return false;
    RuntimeModifierPodCommand stack = apply;
    stack.request_id = 2; stack.sequence = 2; stack.stacks = 2;
    if (!authority.plan_day(1, 1, {stack}, {}, planned, acks, report, error) ||
        !authority.commit_day(planned, error) || authority.snapshot().entries[0].stacks != 3) return false;
    RuntimeModifierPodCommand stale;
    stale.request_id = 3; stale.effective_day = 1; stale.opcode = COMMAND_SET_MAGNITUDE;
    stale.domain = 0; stale.modifier_handle = authority.snapshot().entries[0].modifier_handle + (1ull << 32u);
    stale.magnitude_q16 = Q16_ONE;
    if (!authority.plan_day(1, 1, {stale}, {}, planned, acks, report, error) ||
        acks.size() != 0 || report.rejected_commands != 1) return false;
    authority.discard_plan();
    std::vector<uint8_t> bytes;
    authority.serialize(bytes);
    RuntimeModifierPodAuthority restored;
    if (!restored.configure(catalog, error) || !restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().state_hash != authority.snapshot().state_hash) return false;

    RuntimeModifierPodAuthority semantics;
    if (!semantics.configure(catalog, error)) return false;
    apply.target_generation = 9;
    apply.magnitude_q16 = Q16_ONE / 2;
    std::vector<RuntimeModifierPodCommand> initial{apply};
    for (uint16_t domain = 1; domain < 4; ++domain) {
        RuntimeModifierPodCommand command = apply;
        command.request_id = static_cast<uint64_t>(domain) + 10u;
        command.sequence = static_cast<uint64_t>(domain) + 10u;
        command.domain = domain;
        command.definition_id = domain;
        command.scope = domain == 1 ? 1 : 2;
        command.entity_handle = 20u + domain;
        command.group_handle = 20u + domain;
        command.source_type = 30u + domain;
        command.source_id = 40u + domain;
        command.target_generation = 0;
        command.duration_days = -1;
        command.magnitude_q16 = Q16_ONE;
        initial.push_back(command);
    }
    if (!semantics.plan_day(0, 1, initial, {}, planned, acks, report, error) ||
        !semantics.commit_day(planned, error))
        return fail("modifier_pod_apply_self_test_failed");
    const RuntimeModifierPodSnapshot first = semantics.snapshot();
    if (first.entries.size() != 4 || first.buckets.size() != 4)
        return fail("modifier_pod_domain_isolation_self_test_failed");
    std::array<uint32_t, 4> domain_counts{};
    for (const auto &entry : first.entries) {
        if (entry.domain >= domain_counts.size())
            return fail("modifier_pod_entry_domain_self_test_failed");
        ++domain_counts[entry.domain];
    }
    if (domain_counts != std::array<uint32_t, 4>{1, 1, 1, 1})
        return fail("modifier_pod_domain_isolation_self_test_failed");
    const auto first_bucket = std::find_if(first.buckets.begin(), first.buckets.end(),
        [](const RuntimeModifierPodBucket &bucket) {
            return bucket.domain == 0 && bucket.scope == 2 &&
                bucket.stat_id == 0 && bucket.scope_id == 7;
        });
    if (first_bucket == first.buckets.end() ||
        std::abs(first_bucket->sum_add - 1.0) > 1e-12 ||
        std::abs(first_bucket->product_factor - 1.25) > 1e-12 ||
        std::abs(std::clamp((3.0 + first_bucket->sum_add) *
            first_bucket->product_factor, -100.0, 100.0) - 5.0) > 1e-12)
        return fail("modifier_pod_formula_self_test_failed");

    const uint64_t domain0_handle = first.entries[0].modifier_handle;
    const uint64_t domain2_handle = first.entries[2].modifier_handle;
    stack = apply;
    stack.request_id = 20; stack.sequence = 20; stack.effective_day = 1;
    stack.stacks = 2; stack.magnitude_q16 = Q16_ONE;
    RuntimeModifierPodCommand set_stacks = stack;
    set_stacks.request_id = 21; set_stacks.sequence = 21;
    set_stacks.opcode = COMMAND_SET_STACKS;
    set_stacks.modifier_handle = domain0_handle; set_stacks.stacks = 4;
    RuntimeModifierPodCommand set_magnitude = set_stacks;
    set_magnitude.request_id = 22; set_magnitude.sequence = 22;
    set_magnitude.opcode = COMMAND_SET_MAGNITUDE;
    set_magnitude.magnitude_q16 = Q16_ONE / 2;
    RuntimeModifierPodCommand refresh = set_stacks;
    refresh.request_id = 23; refresh.sequence = 23;
    refresh.opcode = COMMAND_REFRESH; refresh.duration_days = 3;
    RuntimeModifierPodCommand remove_unique = initial[1];
    remove_unique.request_id = 24; remove_unique.sequence = 24;
    remove_unique.effective_day = 1; remove_unique.opcode = COMMAND_REMOVE;
    remove_unique.modifier_handle = 0;
    RuntimeModifierPodCommand remove_exact = initial[2];
    remove_exact.request_id = 25; remove_exact.sequence = 25;
    remove_exact.effective_day = 1; remove_exact.opcode = COMMAND_REMOVE;
    remove_exact.modifier_handle = domain2_handle;
    const std::vector<RuntimeModifierPodCommand> mutations{
        refresh, remove_exact, set_magnitude, stack, remove_unique, set_stacks};
    if (!semantics.plan_day(1, 1, mutations, {}, planned, acks, report, error) ||
        !semantics.commit_day(planned, error))
        return fail("modifier_pod_opcode_self_test_failed");
    const RuntimeModifierPodSnapshot mutated = semantics.snapshot();
    const auto active0 = std::find_if(mutated.entries.begin(), mutated.entries.end(),
        [](const RuntimeModifierPodEntry &entry) { return entry.domain == 0; });
    if (mutated.entries.size() != 2 || active0 == mutated.entries.end() ||
        active0->stacks != 4 || active0->magnitude_q16 != Q16_ONE / 2 ||
        active0->applied_day != 1 || active0->expires_day != 4)
        return fail("modifier_pod_opcode_state_self_test_failed");
    const auto clamped_bucket = std::find_if(mutated.buckets.begin(), mutated.buckets.end(),
        [](const RuntimeModifierPodBucket &bucket) {
            return bucket.domain == 0 && bucket.stat_id == 0;
        });
    if (clamped_bucket == mutated.buckets.end() ||
        std::abs(clamped_bucket->sum_add - 4.0) > 1e-12 ||
        std::abs(clamped_bucket->product_factor - simulation_math::pow(1.25, 4.0)) > 1e-12 ||
        std::clamp((90.0 + clamped_bucket->sum_add) *
            clamped_bucket->product_factor, -100.0, 100.0) != 100.0)
        return fail("modifier_pod_magnitude_clamp_self_test_failed");

    if (!semantics.plan_day(2, 1, {}, {}, planned, acks, report, error) ||
        !semantics.commit_day(planned, error) || semantics.snapshot().entries.size() != 2)
        return fail("modifier_pod_expiry_early_self_test_failed");
    const uint64_t before_reject_hash = semantics.snapshot().state_hash;
    const uint64_t before_reject_generation = semantics.snapshot().generation;
    stale = set_magnitude;
    stale.request_id = 30; stale.sequence = 30; stale.effective_day = 3;
    stale.modifier_handle = domain0_handle + (1ull << 32u);
    if (!semantics.plan_day(3, 1, {stale}, {}, planned, acks, report, error) ||
        !acks.empty() || report.rejected_commands != 1)
        return fail("modifier_pod_stale_generation_self_test_failed");
    semantics.discard_plan();
    if (semantics.snapshot().state_hash != before_reject_hash ||
        semantics.snapshot().generation != before_reject_generation)
        return fail("modifier_pod_discard_self_test_failed");

    RuntimeModifierPodCommand valid_before_failure = initial[2];
    valid_before_failure.request_id = 31; valid_before_failure.sequence = 1;
    valid_before_failure.effective_day = 3;
    RuntimeModifierPodCommand rejected_intent = stale;
    rejected_intent.request_id = 32; rejected_intent.producer_id = 7;
    rejected_intent.sequence = 2; rejected_intent.entity_handle = 7;
    error.clear(); if (!committed_view_self_test(error)) return false;
    if (semantics.plan_day(3, 1, {valid_before_failure}, {rejected_intent},
            planned, acks, report, error))
        return fail("modifier_pod_failed_plan_self_test_failed");
    semantics.discard_plan();
    if (semantics.snapshot().state_hash != before_reject_hash ||
        semantics.snapshot().generation != before_reject_generation)
        return fail("modifier_pod_failed_plan_mutated_current");

    error.clear();
    if (!semantics.plan_day(4, 1, {}, {}, planned, acks, report, error) ||
        !semantics.commit_day(planned, error) || semantics.snapshot().entries.size() != 1 ||
        semantics.snapshot().entries[0].domain != 3)
        return fail("modifier_pod_expiry_boundary_self_test_failed");

    RuntimeModifierPodAuthority ordered_a;
    RuntimeModifierPodAuthority ordered_b;
    if (!ordered_a.configure(catalog, error) || !ordered_b.configure(catalog, error))
        return fail("modifier_pod_ordering_configure_failed");
    RuntimeModifierPodCommand earlier = initial[1];
    earlier.request_id = 40; earlier.producer_id = 1; earlier.sequence = 1;
    earlier.magnitude_q16 = Q16_ONE;
    RuntimeModifierPodCommand later = earlier;
    later.request_id = 41; later.producer_id = 2;
    later.magnitude_q16 = Q16_ONE / 2;
    RuntimeModifierPodSnapshot planned_b;
    std::vector<RuntimeDomainAck> acks_b;
    RuntimeModifierPodReport report_b;
    if (!ordered_a.plan_day(0, 1, {later, earlier}, {}, planned, acks, report, error) ||
        !ordered_a.commit_day(planned, error) ||
        !ordered_b.plan_day(0, 1, {earlier, later}, {}, planned_b, acks_b,
                            report_b, error) ||
        !ordered_b.commit_day(planned_b, error) ||
        ordered_a.snapshot().state_hash != ordered_b.snapshot().state_hash ||
        ordered_a.snapshot().entries[0].magnitude_q16 != Q16_ONE / 2)
        return fail("modifier_pod_stable_order_self_test_failed");

    RuntimeModifierPodAuthority ack_authority;
    if (!ack_authority.configure(catalog, error)) return false;
    RuntimeModifierPodCommand intent = apply;
    intent.request_id = 50; intent.producer_id = 5; intent.sequence = 6;
    intent.entity_handle = (static_cast<uint64_t>(9) << 32u) | 7u;
    intent.target_generation = 9;
    if (!ack_authority.plan_day(0, 1, {}, {intent}, planned, acks, report, error) ||
        acks.size() != 1 || acks[0].code != RuntimeDomainAckCode::OK ||
        acks[0].request_id != intent.request_id ||
        acks[0].transaction_id != intent.request_id ||
        acks[0].producer_id != intent.producer_id ||
        acks[0].sequence != intent.sequence ||
        acks[0].target_handle != intent.entity_handle ||
        acks[0].target_generation != intent.target_generation ||
        acks[0].effective_day != intent.effective_day)
        return fail("modifier_pod_ack_identity_self_test_failed");
    ack_authority.discard_plan();

    const uint64_t restored_hash = restored.snapshot().state_hash;
    bytes.back() ^= 0x80u;
    error.clear();
    if (restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().state_hash != restored_hash)
        return fail("modifier_pod_mdf2_transaction_self_test_failed");

    // L1-6: aggregation policy. Same two rows applied from two different source
    // ids; SUM adds them, MAX_SOURCE keeps the larger one, TOP_N with cap 1 does
    // the same as MAX here and cap 2 the same as SUM. The point is that the
    // policy is read from the stat and that the source identity is the pair
    // (source_type, source_id), not the instance row.
    {
        // `fail` above only writes when `error` is empty, and the corrupted-save
        // probe immediately before this block deliberately leaves a message
        // behind. Clearing here is what lets a real failure in this block be
        // visible instead of echoing the previous one.
        error.clear();
        auto make_catalog = [](int32_t policy, int32_t cap) {
            RuntimeModifierPodCatalog pod_catalog;
            RuntimeModifierPodStat stat;
            stat.domain = 1; stat.min_value = -100.0; stat.max_value = 100.0;
            stat.persistable = 1; stat.aggregate_policy = policy; stat.source_cap = cap;
            pod_catalog.stats.push_back(stat);
            RuntimeModifierPodDefinition pod_definition;
            pod_definition.version = 1; pod_definition.domain = 1;
            pod_definition.policy = 0; pod_definition.max_stacks = 8;
            pod_definition.default_duration = -1;
            pod_definition.term_begin = 0; pod_definition.term_count = 1;
            pod_catalog.definitions.push_back(pod_definition);
            RuntimeModifierPodTerm pod_term;
            pod_term.stat_id = 0; pod_term.add = 1.0; pod_term.factor = 1.0;
            pod_catalog.terms.push_back(pod_term);
            return pod_catalog;
        };
        std::string aggregate_error;
        auto total_add = [&make_catalog, &aggregate_error](int32_t policy, int32_t cap, double &out) {
            RuntimeModifierPodAuthority authority;
            RuntimeModifierPodCatalog pod_catalog = make_catalog(policy, cap);
            if (!authority.configure(pod_catalog, aggregate_error)) {
                if (aggregate_error.empty()) aggregate_error = "modifier_pod_aggregate_configure_failed";
                return false;
            }
            std::vector<RuntimeModifierPodCommand> rows;
            // magnitude 0.25 against an add of 1.0 gives 0.25 per row.
            for (uint64_t source = 1; source <= 2; ++source) {
                RuntimeModifierPodCommand row;
                row.request_id = 100 + source; row.producer_id = 1;
                row.sequence = 100 + source; row.effective_day = 0;
                // APPLY is 1; 2 is REMOVE, which would leave no bucket at all.
                row.opcode = static_cast<uint16_t>(RuntimeModifierPodOpcode::APPLY);
                row.domain = 1; row.definition_id = 0; row.scope = 2;
                row.entity_handle = 0; row.group_handle = 7;
                row.source_type = 0x4full; row.source_id = source;
                row.duration_days = -1; row.stacks = 1;
                row.magnitude_q16 = Q16_ONE / 4;
                rows.push_back(row);
            }
            RuntimeModifierPodSnapshot aggregate_snapshot;
            std::vector<RuntimeDomainAck> aggregate_acks;
            RuntimeModifierPodReport aggregate_report;
            if (!authority.plan_day(0, 1, rows, {}, aggregate_snapshot,
                                    aggregate_acks, aggregate_report, aggregate_error) ||
                !authority.commit_day(aggregate_snapshot, aggregate_error)) {
                if (aggregate_error.empty()) aggregate_error = "modifier_pod_aggregate_plan_failed";
                return false;
            }
            const RuntimeModifierPodSnapshot applied = authority.snapshot();
            if (applied.buckets.size() != 1) {
                aggregate_error = "modifier_pod_aggregate_bucket_count_failed";
                return false;
            }
            out = applied.buckets[0].sum_add;
            return true;
        };
        double sum = 0.0, max_source = 0.0, top1 = 0.0, top2 = 0.0;
        if (!total_add(0, 0, sum) || !total_add(1, 0, max_source) ||
            !total_add(2, 1, top1) || !total_add(2, 2, top2))
            return fail(aggregate_error.empty()
                ? "modifier_pod_aggregate_plan_self_test_failed"
                : aggregate_error.c_str());
        if (std::abs(sum - 0.5) > 1e-9)
            return fail("modifier_pod_aggregate_sum_self_test_failed");
        if (std::abs(max_source - 0.25) > 1e-9)
            return fail("modifier_pod_aggregate_max_self_test_failed");
        if (std::abs(top1 - 0.25) > 1e-9)
            return fail("modifier_pod_aggregate_top1_self_test_failed");
        if (std::abs(top2 - 0.5) > 1e-9)
            return fail("modifier_pod_aggregate_top2_self_test_failed");
    }

    error.clear();
    return true;
}
