bool RuntimeEffectPodAuthority::magnitude_scale_self_test(std::string &error) {
    const auto fail = [&error](const char *reason) {
        error = reason;
        return false;
    };
    // One MODIFIER command whose compiled value is 1.0, armed with a 2x scale.
    // Under worker authority the main thread's dispatch_native_modifier is
    // suppressed, so this intent is the ONLY place the multiplier can land: a
    // pod that ignored `magnitude_scale_q16` would emit 1.0 and every synergy
    // would silently be a no-op on the worker.
    RuntimeEffectPodCatalog catalog;
    catalog.metric_key_hashes = {};
    RuntimeEffectPodDefinition definition;
    definition.key_hash = hash_text("scale.fixture");
    definition.cadence_days = 1;
    definition.max_work = 8;
    definition.instruction_begin = 0;
    definition.instruction_count = 2;
    definition.command_begin = 0;
    definition.command_count = 1;
    catalog.definitions.push_back(definition);
    catalog.commands.push_back(RuntimeEffectPodCommandDefinition{
        RuntimeEffectPodAction::MODIFIER_COMMAND, 0, 1,
        RuntimeEffectPodTargetResolver::INSTANCE, 0,
        RuntimeEffectPodValueMode::STACK_TOP, 0, -1, 1,
        hash_text("modifier"), 0, {}});
    RuntimeEffectPodInstruction constant;
    constant.op = RuntimeEffectPodInstructionOp::CONST;
    constant.value = Q16_ONE;
    catalog.instructions.push_back(constant);
    RuntimeEffectPodInstruction emit;
    emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
    emit.arg0 = 0;
    catalog.instructions.push_back(emit);

    RuntimeEffectPodAuthority authority;
    if (!authority.configure(catalog, error)) return false;
    RuntimeEffectPodInstanceInput input;
    input.instance_id = 11;
    input.generation = 1;
    input.program_id = 0;
    input.source_handle = 5;
    input.target_handle = 6;
    input.target_generation = 1;
    input.magnitude_scale_q16 = Q16_ONE * 2;
    if (!authority.upsert_instance(input, error))
        return fail("effect_scale_instance_rejected");
    RuntimeEffectPodPlan plan;
    if (!authority.plan_day(0, 1, plan, error) || plan.intents.size() != 1u)
        return fail("effect_scale_plan_failed");
    if (plan.intents.front().magnitude_q16 != static_cast<int32_t>(Q16_ONE * 2))
        return fail("effect_scale_not_applied_on_worker");
    // Unscaled control: the same program with the default 1.0 must come out at
    // exactly the compiled value, otherwise "2x" could be an off-by-one clamp.
    RuntimeEffectPodAuthority plain;
    if (!plain.configure(catalog, error)) return false;
    input.instance_id = 12;
    input.magnitude_scale_q16 = Q16_ONE;
    if (!plain.upsert_instance(input, error))
        return fail("effect_scale_control_rejected");
    RuntimeEffectPodPlan plain_plan;
    if (!plain.plan_day(0, 1, plain_plan, error) || plain_plan.intents.size() != 1u)
        return fail("effect_scale_control_plan_failed");
    if (plain_plan.intents.front().magnitude_q16 != static_cast<int32_t>(Q16_ONE))
        return fail("effect_scale_control_changed");

    // Kind 16 derives its scale from the source cap. A cap of 6 yields 1/6,
    // below the generic 0.25x authoring floor, but it is a valid count step.
    definition.key_hash = hash_text("scale.source_count.fixture");
    definition.target_selector_kind = MAX_SELECTOR_KIND;
    definition.min_magnitude_scale_q16 = Q16_ONE / 6;
    catalog.definitions.clear();
    catalog.definitions.push_back(definition);
    RuntimeEffectPodAuthority source_count;
    if (!source_count.configure(catalog, error))
        return fail("effect_source_count_scale_configure_failed");
    input.instance_id = 13;
    input.magnitude_scale_q16 = Q16_ONE / 6;
    if (!source_count.upsert_instance(input, error))
        return fail("effect_source_count_scale_rejected");
    RuntimeEffectPodPlan source_count_plan;
    if (!source_count.plan_day(0, 1, source_count_plan, error) ||
            source_count_plan.intents.size() != 1u)
        return fail("effect_source_count_scale_plan_failed");
    if (source_count_plan.intents.front().magnitude_q16 != Q16_ONE / 6)
        return fail("effect_source_count_scale_clamped");
    return true;
}

bool RuntimeEffectPodAuthority::self_test(std::string &error) {
    const auto fail = [&error](const char *reason) {
        error = reason;
        return false;
    };
    // Cell 0 is a real target on the main thread, so the pod has to agree. Kept
    // as its own fixture because this one pins exact plan hashes and adding a
    // second program to its catalog would move all of them.
    if (!cell_target_self_test(error)) return false;
    if (!latch_self_test(error)) return false;
    if (!magnitude_scale_self_test(error)) return false;
    // Managed lifecycle: one apply, one deactivation after the condition
    // falls, and no idle churn while the same input stays applied. The
    // fixture also pins ACK semantics and ACKED transaction compaction.
    {
        RuntimeEffectPodCatalog managed_catalog;
        managed_catalog.metric_key_hashes = {hash_text("managed.metric")};
        RuntimeEffectPodDefinition managed;
        managed.key_hash = hash_text("managed.program");
        managed.cadence_days = 1;
        managed.max_work = 8;
        managed.managed = 1;
        managed.condition_begin = 0;
        managed.condition_count = 1;
        managed.instruction_begin = 0;
        managed.instruction_count = 2;
        managed.command_begin = 0;
        managed.command_count = 1;
        managed_catalog.definitions.push_back(managed);
        RuntimeEffectPodCondition condition;
        condition.op = RuntimeEffectPodConditionOp::METRIC_GTE;
        condition.arg0 = 0;
        condition.value = Q16_ONE;
        managed_catalog.conditions.push_back(condition);
        RuntimeEffectPodInstruction constant;
        constant.op = RuntimeEffectPodInstructionOp::CONST;
        constant.value = 0;  // not used: command value is constant
        managed_catalog.instructions.push_back(constant);
        RuntimeEffectPodInstruction emit;
        emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
        emit.arg0 = 0;
        managed_catalog.instructions.push_back(emit);
        RuntimeEffectPodCommandDefinition apply;
        apply.action = RuntimeEffectPodAction::MODIFIER_COMMAND;
        apply.domain = 2;
        apply.opcode = 1;
        apply.target_resolver = RuntimeEffectPodTargetResolver::INSTANCE;
        apply.value_mode = RuntimeEffectPodValueMode::CONSTANT;
        apply.value = Q16_ONE;
        apply.duration_days = -1;
        apply.stacks = 1;
        apply.command_key_hash = hash_text("managed.command");
        apply.definition_key_hash = hash_text("managed.stat");
        managed_catalog.commands.push_back(apply);

        RuntimeEffectPodAuthority authority;
        if (!authority.configure(managed_catalog, error)) return false;
        RuntimeEffectPodInstanceInput input;
        input.instance_id = 7001;
        input.generation = 1;
        input.program_id = 0;
        input.source_handle = 3;
        input.target_handle = 4;
        input.target_generation = 1;
        input.next_due_day = 0;
        if (!authority.upsert_instance(input, error))
            return fail("effect_managed_setup_failed");
        if (!authority.set_metric(7001, 1, 0, 1, 2 * Q16_ONE, error))
            return fail("effect_managed_metric_failed");

        int64_t transaction_id = 0;
        for (int64_t day = 0; day < 3; ++day) {
            RuntimeEffectPodPlan plan;
            if (!authority.plan_day(day, static_cast<uint64_t>(day + 1),
                                    plan, error)) {
                return fail("effect_managed_true_plan_failed");
            }
            if (day == 0) {
                if (plan.intents.size() != 1u)
                    return fail("effect_managed_initial_apply_missing");
                transaction_id = plan.next_snapshot.transactions.empty()
                    ? 0 : plan.next_snapshot.transactions.front().transaction_id;
                if (!authority.commit_day(plan, error))
                    return fail("effect_managed_initial_commit_failed");
                RuntimeDomainAck ack;
                ack.transaction_id = static_cast<uint64_t>(transaction_id);
                ack.target_handle = 4;
                ack.target_generation = 1;
                ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
                ack.effective_day = day;
                ack.code = RuntimeDomainAckCode::OK;
                if (!authority.apply_ack(ack, error))
                    return fail("effect_managed_initial_ack_failed");
                const auto &applied = authority.snapshot().instances.front();
                if (applied.effect_applied != 1 ||
                        applied.applied_input_revision != 1 ||
                        applied.applied_stack_count != 1) {
                    return fail("effect_managed_ack_state_not_recorded");
                }
            } else {
                if (!plan.intents.empty())
                    return fail("effect_managed_true_days_refired");
                if (!authority.commit_day(plan, error))
                    return fail("effect_managed_true_commit_failed");
                if (!authority.snapshot().transactions.empty())
                    return fail("effect_managed_acked_transaction_not_compacted");
            }
        }

        // Falling condition: exactly one REMOVE, then silence until applied.
        if (!authority.set_metric(7001, 1, 0, 2, 0, error))
            return fail("effect_managed_metric_lower_failed");
        RuntimeEffectPodPlan retire_plan;
        if (!authority.plan_day(3, 4, retire_plan, error) ||
                retire_plan.intents.size() != 1u)
            return fail("effect_managed_retire_missing");
        const auto &retire_command = retire_plan.next_snapshot.command_arena[
            retire_plan.next_snapshot.transactions.front().command_begin];
        if (retire_command.action != RuntimeEffectPodAction::MODIFIER_COMMAND ||
                retire_command.opcode != 2 ||
                retire_plan.next_snapshot.transactions.front()
                    .transition_stack_count != 0) {
            return fail("effect_managed_retire_shape_invalid");
        }
        transaction_id = retire_plan.next_snapshot.transactions.front()
            .transaction_id;
        if (!authority.commit_day(retire_plan, error))
            return fail("effect_managed_retire_commit_failed");
        RuntimeDomainAck retire_ack;
        retire_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        retire_ack.target_handle = 4;
        retire_ack.target_generation = 1;
        retire_ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        retire_ack.effective_day = 3;
        retire_ack.code = RuntimeDomainAckCode::OK;
        if (!authority.apply_ack(retire_ack, error))
            return fail("effect_managed_retire_ack_failed");
        const auto &retired = authority.snapshot().instances.front();
        if (retired.effect_applied != 0 ||
                retired.applied_input_revision != 0 ||
                retired.applied_stack_count != 0 ||
                authority.snapshot().transactions.empty() ||
                authority.snapshot().transactions.front().status !=
                    RuntimeEffectPodTransactionStatus::ACKED) {
            return fail("effect_managed_retire_state_not_cleared");
        }
        RuntimeEffectPodPlan idle_plan;
        if (!authority.plan_day(4, 5, idle_plan, error) ||
                !idle_plan.intents.empty() ||
                !authority.commit_day(idle_plan, error)) {
            return fail("effect_managed_false_day_refired");
        }
        if (!authority.snapshot().transactions.empty() ||
                !authority.snapshot().command_arena.empty()) {
            return fail("effect_managed_acked_transaction_not_compacted");
        }

        // Re-apply, then exercise the explicit remove path. This is the
        // cell-instance case: the instance must stay scheduled long enough to
        // emit a REMOVE and only become a tombstone after that REMOVE ACKs.
        const int64_t reapply_day = 5;
        if (!authority.set_metric(7001, 1, 0, 3, 2 * Q16_ONE, error))
            return fail("effect_managed_reapply_metric_failed");
        RuntimeEffectPodPlan reapply_plan;
        if (!authority.plan_day(reapply_day, 6, reapply_plan, error) ||
                reapply_plan.intents.size() != 1u) {
            return fail("effect_managed_reapply_missing");
        }
        transaction_id = reapply_plan.next_snapshot.transactions.front()
            .transaction_id;
        if (!authority.commit_day(reapply_plan, error))
            return fail("effect_managed_reapply_commit_failed");
        RuntimeDomainAck reapply_ack;
        reapply_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        reapply_ack.target_handle = 4;
        reapply_ack.target_generation = 1;
        reapply_ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        reapply_ack.effective_day = reapply_day;
        reapply_ack.code = RuntimeDomainAckCode::OK;
        if (!authority.apply_ack(reapply_ack, error))
            return fail("effect_managed_reapply_ack_failed");
        if (!authority.remove_instance(7001, 1, error))
            return fail("effect_managed_remove_request_failed");
        // A same-identity re-ENSURE may arrive after the explicit remove while
        // the APPLY is still settling. It must not erase the pending REMOVE.
        input.next_due_day = 6;
        if (!authority.upsert_instance(input, error) ||
                authority.snapshot().instances.front().retire_requested == 0) {
            return fail("effect_managed_remove_request_erased");
        }
        RuntimeEffectPodPlan remove_plan;
        if (!authority.plan_day(6, 7, remove_plan, error) ||
                remove_plan.intents.size() != 1u) {
            return fail("effect_managed_remove_missing");
        }
        const auto &remove_snapshot = remove_plan.next_snapshot;
        // The re-apply transaction is ACKED but remains until this commit
        // compacts it, so the newly planned retirement is the last row.
        const auto &remove_transaction = remove_snapshot.transactions.back();
        const auto &remove_command = remove_snapshot.command_arena[
            remove_transaction.command_begin];
        if (remove_transaction.transition_stack_count != 0 ||
                remove_command.opcode != 2) {
            return fail("effect_managed_remove_shape_invalid");
        }
        transaction_id = remove_transaction.transaction_id;
        if (!authority.commit_day(remove_plan, error))
            return fail("effect_managed_remove_commit_failed");
        RuntimeDomainAck remove_ack;
        remove_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        remove_ack.target_handle = 4;
        remove_ack.target_generation = 1;
        remove_ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        remove_ack.effective_day = 6;
        remove_ack.code = RuntimeDomainAckCode::OK;
        if (!authority.apply_ack(remove_ack, error))
            return fail("effect_managed_remove_ack_failed");
        const auto &removed = authority.snapshot().instances.front();
        if (removed.active != 0 || removed.effect_applied != 0 ||
                removed.retire_requested != 0) {
            return fail("effect_managed_remove_tombstone_invalid");
        }

        // Duration expiry uses the same retirement transaction rather than
        // silently tombstoning an applied managed row.
        RuntimeEffectPodCatalog duration_catalog = managed_catalog;
        duration_catalog.definitions[0].lifecycle =
            RuntimeEffectPodLifecycle::DURATION;
        duration_catalog.definitions[0].duration_days = 2;
        RuntimeEffectPodAuthority duration_authority;
        if (!duration_authority.configure(duration_catalog, error))
            return fail("effect_managed_duration_configure_failed");
        RuntimeEffectPodInstanceInput duration_input;
        duration_input.instance_id = 7002;
        duration_input.generation = 1;
        duration_input.program_id = 0;
        duration_input.source_handle = 3;
        duration_input.target_handle = 4;
        duration_input.target_generation = 1;
        duration_input.next_due_day = 0;
        if (!duration_authority.upsert_instance(duration_input, error) ||
                !duration_authority.set_metric(
                    7002, 1, 0, 1, 2 * Q16_ONE, error)) {
            return fail("effect_managed_duration_setup_failed");
        }
        RuntimeEffectPodPlan duration_apply;
        if (!duration_authority.plan_day(0, 1, duration_apply, error) ||
                duration_apply.intents.size() != 1u) {
            return fail("effect_managed_duration_apply_missing");
        }
        transaction_id = duration_apply.next_snapshot.transactions.front()
            .transaction_id;
        if (!duration_authority.commit_day(duration_apply, error))
            return fail("effect_managed_duration_apply_commit_failed");
        RuntimeDomainAck duration_ack;
        duration_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        duration_ack.target_handle = 4;
        duration_ack.target_generation = 1;
        duration_ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        duration_ack.effective_day = 0;
        duration_ack.code = RuntimeDomainAckCode::OK;
        if (!duration_authority.apply_ack(duration_ack, error))
            return fail("effect_managed_duration_apply_ack_failed");
        for (int64_t day = 1; day < 2; ++day) {
            RuntimeEffectPodPlan plan;
            if (!duration_authority.plan_day(
                    day, static_cast<uint64_t>(day + 1), plan, error) ||
                    !plan.intents.empty() ||
                    !duration_authority.commit_day(plan, error)) {
                return fail("effect_managed_duration_idle_failed");
            }
        }
        RuntimeEffectPodPlan duration_retire;
        if (!duration_authority.plan_day(2, 3, duration_retire, error) ||
                duration_retire.intents.size() != 1u ||
                duration_retire.next_snapshot.command_arena[
                    duration_retire.next_snapshot.transactions.front().command_begin]
                    .opcode != 2) {
            return fail("effect_managed_duration_retire_missing");
        }

        for (int64_t day = 7; day < 105; ++day) {
            RuntimeEffectPodPlan plan;
            if (!authority.plan_day(day, static_cast<uint64_t>(day + 1),
                                    plan, error) ||
                    !plan.intents.empty() ||
                    !authority.commit_day(plan, error)) {
                return fail("effect_managed_idle_day_churned");
            }
        }
        if (!authority.snapshot().transactions.empty() ||
                !authority.snapshot().command_arena.empty()) {
            return fail("effect_managed_compaction_invalid");
        }

        // Removing an instance while its APPLY is in flight must still retire
        // the row the APPLY is about to create. Keep the request across the
        // APPLY ACK, then emit exactly one REMOVE on the next plan.
        RuntimeEffectPodAuthority pending_remove_authority;
        if (!pending_remove_authority.configure(managed_catalog, error))
            return fail("effect_managed_pending_remove_configure_failed");
        RuntimeEffectPodInstanceInput pending_remove_input;
        pending_remove_input.instance_id = 7003;
        pending_remove_input.generation = 1;
        pending_remove_input.program_id = 0;
        pending_remove_input.source_handle = 3;
        pending_remove_input.target_handle = 4;
        pending_remove_input.target_generation = 1;
        pending_remove_input.next_due_day = 0;
        if (!pending_remove_authority.upsert_instance(
                pending_remove_input, error) ||
                !pending_remove_authority.set_metric(
                    7003, 1, 0, 1, 2 * Q16_ONE, error)) {
            return fail("effect_managed_pending_remove_setup_failed");
        }
        RuntimeEffectPodPlan pending_apply;
        if (!pending_remove_authority.plan_day(0, 1, pending_apply, error) ||
                pending_apply.intents.size() != 1u) {
            return fail("effect_managed_pending_remove_apply_missing");
        }
        transaction_id = pending_apply.next_snapshot.transactions.front()
            .transaction_id;
        if (!pending_remove_authority.commit_day(pending_apply, error) ||
                !pending_remove_authority.remove_instance(7003, 1, error)) {
            return fail("effect_managed_pending_remove_request_failed");
        }
        const auto &pending_removed =
            pending_remove_authority.snapshot().instances.front();
        if (pending_removed.active == 0 ||
                pending_removed.effect_applied != 0 ||
                pending_removed.retire_requested == 0 ||
                pending_removed.pending_transaction_id == 0) {
            return fail("effect_managed_pending_remove_tombstoned_early");
        }
        RuntimeDomainAck pending_apply_ack;
        pending_apply_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        pending_apply_ack.target_handle = 4;
        pending_apply_ack.target_generation = 1;
        pending_apply_ack.domain =
            static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        pending_apply_ack.effective_day = 0;
        pending_apply_ack.code = RuntimeDomainAckCode::OK;
        if (!pending_remove_authority.apply_ack(pending_apply_ack, error))
            return fail("effect_managed_pending_remove_apply_ack_failed");
        const auto &pending_applied =
            pending_remove_authority.snapshot().instances.front();
        if (pending_applied.active == 0 ||
                pending_applied.effect_applied == 0 ||
                pending_applied.retire_requested == 0 ||
                pending_applied.pending_transaction_id != 0) {
            return fail("effect_managed_pending_remove_ack_state_invalid");
        }
        RuntimeEffectPodPlan pending_retire;
        if (!pending_remove_authority.plan_day(1, 2, pending_retire, error) ||
                pending_retire.intents.size() != 1u ||
                pending_retire.next_snapshot.transactions.back().status !=
                    RuntimeEffectPodTransactionStatus::PREFLIGHTED) {
            return fail("effect_managed_pending_remove_retire_missing");
        }
        const auto &pending_retire_transaction =
            pending_retire.next_snapshot.transactions.back();
        const auto &pending_retire_command =
            pending_retire.next_snapshot.command_arena[
                pending_retire_transaction.command_begin];
        if (pending_retire_transaction.transition_stack_count != 0 ||
                pending_retire_command.opcode != 2) {
            return fail("effect_managed_pending_remove_retire_shape_invalid");
        }
        transaction_id = pending_retire_transaction.transaction_id;
        if (!pending_remove_authority.commit_day(pending_retire, error))
            return fail("effect_managed_pending_remove_retire_commit_failed");
        RuntimeDomainAck pending_retire_ack;
        pending_retire_ack.transaction_id = static_cast<uint64_t>(transaction_id);
        pending_retire_ack.target_handle = 4;
        pending_retire_ack.target_generation = 1;
        pending_retire_ack.domain =
            static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        pending_retire_ack.effective_day = 1;
        pending_retire_ack.code = RuntimeDomainAckCode::OK;
        if (!pending_remove_authority.apply_ack(
                pending_retire_ack, error)) {
            return fail("effect_managed_pending_remove_retire_ack_failed");
        }
        const auto &pending_retired =
            pending_remove_authority.snapshot().instances.front();
        if (pending_retired.active != 0 ||
                pending_retired.effect_applied != 0 ||
                pending_retired.retire_requested != 0) {
            return fail("effect_managed_pending_remove_tombstone_invalid");
        }
        RuntimeEffectPodPlan pending_compaction;
        if (!pending_remove_authority.plan_day(
                2, 3, pending_compaction, error) ||
                !pending_compaction.intents.empty() ||
                !pending_remove_authority.commit_day(
                    pending_compaction, error) ||
                !pending_remove_authority.snapshot().transactions.empty() ||
                !pending_remove_authority.snapshot().command_arena.empty()) {
            return fail("effect_managed_pending_remove_compaction_failed");
        }
    }
    error.clear(); if (!committed_view_self_test(error)) return false;
    RuntimeEffectPodCatalog catalog;
    catalog.metric_key_hashes = {hash_text("metric")};
    RuntimeEffectPodDefinition definition;
    definition.key_hash = hash_text("fixture");
    definition.cadence_days = 1;
    definition.max_work = 64;
    definition.instruction_begin = 0;
    definition.instruction_count = 12;
    definition.command_begin = 0;
    definition.command_count = 6;
    catalog.definitions.push_back(definition);
    const std::array<RuntimeEffectPodCommandDefinition, 6> command_definitions{
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::MODIFIER_COMMAND, 0, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("modifier"), 0, {}},
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::COUNTRY_COMMAND, 1, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("country"), 0, {}},
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::ECONOMY_COMMAND, 2, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("economy"), 0, {}},
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::GAMEPLAY_COMMAND, 3, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("gameplay"), 0, {}},
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::PUBLISH_EVENT, 4, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("event"), 0, {}},
        RuntimeEffectPodCommandDefinition{RuntimeEffectPodAction::CUSTOM_DOMAIN_COMMAND, 6, 1,
            RuntimeEffectPodTargetResolver::INSTANCE, 0, RuntimeEffectPodValueMode::STACK_TOP,
            0, -1, 1, hash_text("custom"), 0, {}},
    };
    catalog.commands.assign(command_definitions.begin(), command_definitions.end());
    for (uint32_t i = 0; i < 6; ++i) {
        RuntimeEffectPodInstruction constant;
        constant.op = RuntimeEffectPodInstructionOp::CONST;
        constant.value = Q16_ONE;
        catalog.instructions.push_back(constant);
        RuntimeEffectPodInstruction emit;
        emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
        emit.arg0 = static_cast<int32_t>(i);
        catalog.instructions.push_back(emit);
    }
    RuntimeEffectPodAuthority authority;
    if (!authority.configure(catalog, error)) return false;
    RuntimeEffectPodInstanceInput input;
    input.instance_id = 1;
    input.generation = 2;
    input.program_id = 0;
    input.source_handle = 9;
    input.target_handle = 99;
    input.target_generation = 3;
    if (!authority.upsert_instance(input, error)) return false;
    if (!authority.set_metric(1, 2, 0, 1, 7, error)) return false;
    RuntimeEffectPodPlan plan;
    if (!authority.plan_day(0, 1, plan, error) || plan.intents.size() != 6u ||
        plan.required_ack_mask != 0x3fu || plan.deterministic_plan_hash == 0)
        return fail("effect_self_test_initial_plan_failed");
    const int64_t transaction_id = plan.next_snapshot.transactions.front().transaction_id;
    if (!authority.commit_day(plan, error)) return false;
    RuntimeDomainAck first;
    first.transaction_id = static_cast<uint64_t>(transaction_id);
    first.target_handle = 99;
    first.target_generation = 3;
    first.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
    first.effective_day = 0;
    if (!authority.apply_ack(first, error)) return false;
    if (authority.snapshot().transactions.front().received_ack_mask != 1u)
        return fail("effect_self_test_first_ack_failed");
    if (!authority.apply_ack(first, error) ||
        authority.snapshot().transactions.front().duplicate_ack_count != 1u) {
        error = "effect_self_test_duplicate_ack_failed:" +
            std::to_string(authority.snapshot().transactions.front().received_ack_mask) +
            ":" + std::to_string(authority.snapshot().transactions.front().duplicate_ack_count) +
            ":" + std::to_string(static_cast<int>(authority.snapshot().transactions.front().status)) +
            ":" + error;
        return false;
    }
    RuntimeDomainAck retry = first;
    retry.code = RuntimeDomainAckCode::RETRY;
    if (!authority.apply_ack(retry, error) ||
        authority.snapshot().transactions.front().status != RuntimeEffectPodTransactionStatus::PLANNED)
        return fail("effect_self_test_retry_failed");
    RuntimeEffectPodPlan retry_plan;
    if (!authority.plan_day(1, 2, retry_plan, error) || retry_plan.intents.size() != 6u ||
        !authority.commit_day(retry_plan, error)) return fail("effect_self_test_retry_plan_failed");
    for (const RuntimeEffectPodCommand &command : authority.snapshot().command_arena) {
        RuntimeDomainAck ack;
        ack.transaction_id = static_cast<uint64_t>(transaction_id);
        ack.target_handle = command.target_handle;
        ack.target_generation = command.target_generation;
        ack.domain = adapter_domain(command.action);
        ack.effective_day = command.effective_day;
        if (!authority.apply_ack(ack, error)) return false;
    }
    if (authority.snapshot().transactions.front().status != RuntimeEffectPodTransactionStatus::ACKED)
        return fail("effect_self_test_final_ack_failed");
    std::vector<uint8_t> bytes;
    authority.serialize(bytes);
    RuntimeEffectPodAuthority restored;
    if (!restored.configure(catalog, error) || !restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().deterministic_state_hash != authority.snapshot().deterministic_state_hash)
        return fail("effect_self_test_save_roundtrip_failed");
    const uint64_t before = restored.snapshot().deterministic_state_hash;
    bytes.back() ^= 0x5a;
    if (restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().deterministic_state_hash != before)
        return fail("effect_self_test_corrupt_restore_mutated_state");

    // R-2: the latch must survive the worker's own save/restore.
    //
    // `latched` is evaluated state the worker owns (STATE_LATCHED reads it), and it
    // was already in the snapshot layout. What this pins is that a LATCHED instance
    // stays latched across serialize -> restore: without it, a restored day re-passes
    // a condition that had already latched, so a "hold while the condition is still
    // true" card silently re-fires on every load.
    //
    // Seeded through `upsert_instance` with a NEW identity, which is the one path
    // that takes `latched` from the input (a same-identity re-ensure deliberately
    // keeps the local latch, so it could not seed this).
    {
        error.clear();
        RuntimeEffectPodInstanceInput seed;
        seed.instance_id = 990001;
        seed.generation = 1;
        seed.program_id = 0;
        seed.latched = 1;
        seed.active = true;
        // The catalog's definition 0 targets a settlement cell, whose zero policy
        // requires a real handle and generation. Passing 0 fails
        // `validate_instance` with `effect_pod_instance_invalid`, which is why the
        // first attempt could not seed this instance at all.
        seed.target_handle = 1;
        seed.target_generation = 1;
        seed.source_handle = 1;
        std::string seed_error;
        if (!authority.upsert_instance(seed, seed_error)) {
            error = "effect_self_test_latched_setup_failed:" + seed_error;
            return false;
        }
        bool seeded = false;
        for (const auto &instance : authority.snapshot().instances) {
            if (instance.instance_id != seed.instance_id) continue;
            if (instance.latched != 1) {
                error = "effect_self_test_latched_not_set"; return false;
            }
            seeded = true;
        }
        if (!seeded) { error = "effect_self_test_latched_missing"; return false; }
        std::vector<uint8_t> latched_bytes;
        authority.serialize(latched_bytes);
        RuntimeEffectPodAuthority latched_restored;
        if (!latched_restored.configure(catalog, error) ||
            !latched_restored.restore(latched_bytes.data(), latched_bytes.size(),
                                      error)) {
            error = "effect_self_test_latched_restore_failed"; return false;
        }
        bool restored_latched = false;
        for (const auto &instance : latched_restored.snapshot().instances) {
            if (instance.instance_id != seed.instance_id) continue;
            if (instance.latched != 1) {
                error = "effect_self_test_latched_not_preserved_by_restore";
                return false;
            }
            // And the answer STATE_LATCHED reads must survive with it, not just
            // the byte.
            if (RuntimeEffectPodAuthority::state_value(instance, 5, 0) != Q16_ONE) {
                error = "effect_self_test_latched_state_value_lost"; return false;
            }
            restored_latched = true;
        }
        if (!restored_latched) {
            error = "effect_self_test_latched_lost_by_restore"; return false;
        }
    }
    return true;
}
