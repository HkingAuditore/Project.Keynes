bool RuntimeEffectPodAuthority::cell_target_self_test(std::string &error) {
    const auto fail = [&error](const char *reason) {
        error = reason;
        return false;
    };
    RuntimeEffectPodCatalog catalog;
    catalog.metric_key_hashes = {hash_text("metric")};
    // Definition 0 addresses a settlement cell, definition 1 a family. They
    // differ in nothing but target_domain, so a guard that ignores that field
    // fails one of the cases below instead of passing both.
    for (int32_t program = 0; program < 2; ++program) {
        RuntimeEffectPodDefinition definition;
        definition.key_hash = hash_text(program == 0 ? "cell.program"
                                                     : "family.program");
        definition.cadence_days = 1;
        definition.max_work = 8;
        definition.instruction_begin = 0;
        definition.instruction_count = 2;
        definition.command_begin = 0;
        definition.command_count = 1;
        definition.target_domain = program == 0 ? 2 : 0;
        catalog.definitions.push_back(definition);
    }
    RuntimeEffectPodCommandDefinition command_definition;
    command_definition.action = RuntimeEffectPodAction::MODIFIER_COMMAND;
    command_definition.domain = 0;
    command_definition.opcode = 1;
    command_definition.target_resolver = RuntimeEffectPodTargetResolver::INSTANCE;
    command_definition.value_mode = RuntimeEffectPodValueMode::CONSTANT;
    command_definition.value = Q16_ONE;
    command_definition.command_key_hash = hash_text("cell.modifier");
    catalog.commands.push_back(command_definition);
    RuntimeEffectPodInstruction constant;
    constant.op = RuntimeEffectPodInstructionOp::CONST;
    constant.value = Q16_ONE;
    catalog.instructions.push_back(constant);
    RuntimeEffectPodInstruction emit;
    emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
    emit.arg0 = 0;
    catalog.instructions.push_back(emit);

    const auto install = [&error](RuntimeEffectPodAuthority &authority,
                                  int32_t program, uint64_t target_handle,
                                  int64_t instance_id,
                                  uint32_t target_generation = 1) {
        RuntimeEffectPodInstanceInput input;
        input.instance_id = instance_id;
        input.generation = 1;
        input.program_id = program;
        input.source_handle = 11;
        input.target_handle = target_handle;
        input.target_generation = target_generation;
        input.next_due_day = 0;
        return authority.upsert_instance(input, error);
    };

    // Cell 0: the case the main thread has always supported and the pod used to
    // read as "unset". Covers validation, command compilation and the EFP1 round
    // trip, because all three carried their own handle != 0 check.
    {
        RuntimeEffectPodAuthority authority;
        if (!authority.configure(catalog, error)) return false;
        if (!install(authority, 0, 0, 1))
            return fail("effect_cell_target_zero_instance_rejected");
        RuntimeEffectPodPlan plan;
        if (!authority.plan_day(0, 1, plan, error) || plan.intents.empty())
            return fail("effect_cell_target_zero_plan_failed");
        if (plan.intents.front().target_handle != 0 ||
            plan.intents.front().target_generation != 1)
            return fail("effect_cell_target_zero_handle_changed");
        if (!authority.commit_day(plan, error)) return false;
        std::vector<uint8_t> bytes;
        authority.serialize(bytes);
        RuntimeEffectPodAuthority restored;
        if (!restored.configure(catalog, error) ||
            !restored.restore(bytes.data(), bytes.size(), error))
            return fail("effect_cell_target_zero_restore_failed");
        if (restored.snapshot().instances.empty() ||
            restored.snapshot().instances.front().target_handle != 0)
            return fail("effect_cell_target_zero_restore_changed");
    }

    // A non-cell program still reads handle 0 as "unset".
    {
        RuntimeEffectPodAuthority authority;
        if (!authority.configure(catalog, error)) return false;
        if (install(authority, 1, 0, 2))
            return fail("effect_family_target_zero_accepted");
        if (error != "effect_pod_instance_invalid") return false;
    }

    // family.modifier.* puts the cell in target_generation, and EffectRuntime's
    // FAMILY adapter hands that field to the Modifier as the GROUP handle, where
    // ModifierRuntime accepts 0 for ECONOMY. So generation 0 is a real cell-0
    // target on this path -- and compile_command copies it straight through.
    {
        RuntimeEffectPodAuthority authority;
        if (!authority.configure(catalog, error)) return false;
        if (!install(authority, 1, 11, 5, 0))
            return fail("effect_family_target_generation_zero_rejected");
        RuntimeEffectPodPlan plan;
        if (!authority.plan_day(0, 1, plan, error) || plan.intents.empty())
            return fail("effect_family_target_generation_zero_plan_failed");
        if (plan.intents.front().target_generation != 0 ||
            plan.intents.front().target_handle != 11)
            return fail("effect_family_target_generation_zero_changed");
        if (!authority.commit_day(plan, error)) return false;
        std::vector<uint8_t> bytes;
        authority.serialize(bytes);
        RuntimeEffectPodAuthority restored;
        if (!restored.configure(catalog, error) ||
            !restored.restore(bytes.data(), bytes.size(), error))
            return fail("effect_family_target_generation_zero_restore_failed");
    }

    // The two exemptions are per field, not "any zero goes": a cell-domain
    // program still needs a real generation, and a family program still needs a
    // real handle.
    {
        RuntimeEffectPodAuthority authority;
        if (!authority.configure(catalog, error)) return false;
        if (install(authority, 0, 5, 6, 0))
            return fail("effect_cell_target_generation_zero_accepted");
        if (error != "effect_pod_instance_invalid") return false;
    }

    // A real cell index still works: the exemption is about which domain, not
    // about "zero is always fine".
    {
        RuntimeEffectPodAuthority authority;
        if (!authority.configure(catalog, error)) return false;
        if (!install(authority, 0, 5, 3))
            return fail("effect_cell_target_nonzero_rejected");
        RuntimeEffectPodPlan plan;
        if (!authority.plan_day(0, 1, plan, error) || plan.intents.empty() ||
            plan.intents.front().target_handle != 5)
            return fail("effect_cell_target_nonzero_plan_failed");
    }

    // STATIC 0 on a cell program is still unset -- neither STATIC nor SOURCE
    // carries a cell index, so the exemption must not leak to them. It is
    // already refused at catalog level, which this pins so the guarantee cannot
    // quietly move into (or out of) compile_command later.
    {
        RuntimeEffectPodCatalog static_catalog = catalog;
        static_catalog.commands[0].target_resolver =
            RuntimeEffectPodTargetResolver::STATIC;
        static_catalog.commands[0].static_target = 0;
        RuntimeEffectPodAuthority authority;
        if (authority.configure(static_catalog, error))
            return fail("effect_cell_target_static_zero_catalog_accepted");
        if (error != "effect_pod_command_invalid") return false;
    }
    return true;
}

bool RuntimeEffectPodAuthority::latch_self_test(std::string &error) {
    const auto fail = [&error](const char *reason) {
        error = reason;
        return false;
    };
    // NOT(STATE_GTE(LATCHED, Q16_ONE)): "last time did NOT pass".
    // Day 0 latched=0 -> not(false)=true  -> pass, latch 1
    // Day 1 latched=1 -> not(true) =false -> fail, latch 0
    // Day 2 latched=0 -> not(false)=true  -> pass, latch 1
    // Alternating is the point: a one-shot assertion cannot tell "the latch was
    // written" from "the condition happened to be true".
    RuntimeEffectPodCatalog catalog;
    catalog.metric_key_hashes = {};
    RuntimeEffectPodDefinition definition;
    definition.key_hash = hash_text("latch.program");
    definition.cadence_days = 1;
    definition.max_work = 8;
    definition.condition_begin = 0;
    definition.condition_count = 2;
    // No instructions and no commands, deliberately. A firing instance would
    // otherwise open a transaction, and a transaction that is not acked parks
    // the instance on `pending_transaction_id` -- day 1 would then emit nothing
    // for a reason that has nothing to do with the latch, and the fixture would
    // pass while proving the opposite of what it claims. A commandless program
    // still records pass/fail: see the fire_sequence assertions below.
    definition.instruction_begin = 0;
    definition.instruction_count = 0;
    definition.command_begin = 0;
    definition.command_count = 0;
    catalog.definitions.push_back(definition);

    RuntimeEffectPodCondition read_latch;
    read_latch.op = RuntimeEffectPodConditionOp::STATE_GTE;
    read_latch.arg0 = 5;  // STATE_LATCHED
    read_latch.value = Q16_ONE;
    catalog.conditions.push_back(read_latch);
    RuntimeEffectPodCondition negate;
    negate.op = RuntimeEffectPodConditionOp::BOOL_NOT;
    catalog.conditions.push_back(negate);

    RuntimeEffectPodAuthority authority;
    if (!authority.configure(catalog, error)) return false;
    RuntimeEffectPodInstanceInput input;
    input.instance_id = 7;
    input.generation = 1;
    input.program_id = 0;
    input.source_handle = 3;
    input.target_handle = 4;
    input.target_generation = 1;
    input.next_due_day = 0;
    if (!authority.upsert_instance(input, error))
        return fail("effect_latch_instance_rejected");

    // day 0: latched 0 -> NOT(false) = pass. latching 1.  fire_sequence 0 -> 1
    // day 1: latched 1 -> NOT(true)  = fail. latching 0.  fire_sequence stays 1
    // day 2: latched 0 -> NOT(false) = pass. latching 1.  fire_sequence 1 -> 2
    //
    // Both columns matter, and they catch different bugs:
    //   * write-back missing  -> latched stays 0, so every day passes and
    //     fire_sequence climbs 1/2/3. Caught by the latched column.
    //   * read path missing   -> STATE_GTE(LATCHED) answers 0 forever, so
    //     again every day passes. Caught by day 1 of either column.
    const uint8_t expected_latched[3] = {1, 0, 1};
    const uint64_t expected_fire_sequence[3] = {1, 1, 2};
    for (int64_t day = 0; day < 3; ++day) {
        RuntimeEffectPodPlan plan;
        // A fresh input_generation per day: the authority rejects a repeat plan
        // for the same generation, and this fixture is about the latch, not
        // about idempotent replanning. Sequential days also require committing,
        // since plan_day refuses to skip ahead of `committed_day`.
        if (!authority.plan_day(day, static_cast<uint64_t>(day + 1u), plan,
                                error))
            return fail("effect_latch_plan_failed");
        if (plan.next_snapshot.instances.empty())
            return fail("effect_latch_instance_missing_from_snapshot");
        const RuntimeEffectPodInstance &after = plan.next_snapshot.instances.front();
        if (after.latched != expected_latched[day] ||
                after.fire_sequence != expected_fire_sequence[day]) {
            error = std::string("effect_latch_oscillation_broken day=") +
                std::to_string(day) + " latched=" +
                std::to_string(after.latched) + " expected=" +
                std::to_string(expected_latched[day]) + " fire_sequence=" +
                std::to_string(after.fire_sequence) + " expected=" +
                std::to_string(expected_fire_sequence[day]);
            return false;
        }
        if (!authority.commit_day(plan, error))
            return fail("effect_latch_commit_failed");
    }
    return true;
}
