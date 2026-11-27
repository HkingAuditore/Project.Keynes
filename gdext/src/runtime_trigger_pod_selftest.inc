bool RuntimeTriggerPodAuthority::self_test(std::string &error) {
    error.clear(); RuntimeTriggerPodCatalog catalog; catalog.catalog_hash = 0x1234; catalog.source_count = 2; catalog.event_type_span = 4; catalog.max_states = 32; catalog.max_pending_events = 32; catalog.distinct_capacity = 8;
    RuntimeTriggerDefinition definition; definition.source_id=0; definition.event_type=1; definition.aggregator=static_cast<int32_t>(RuntimeTriggerAggregator::COUNT); definition.threshold=2; definition.effect_begin=0; definition.effect_count=1; catalog.definitions.push_back(definition);
    RuntimeTriggerEffectDefinition effect; effect.action=static_cast<int32_t>(RuntimeTriggerAction::COUNTRY_COMMAND); effect.opcode=14; effect.value_mode=static_cast<int32_t>(RuntimeTriggerValueMode::FIRE_COUNT); catalog.effects.push_back(effect);
    RuntimeTriggerPodAuthority authority; RuntimeTriggerSnapshot initial; if(!authority.bootstrap(initial,catalog,error)) return false;
    RuntimeTriggerCommand command; command.request_id=1; command.sequence=1; command.effective_day=0; command.requested_day=0; command.opcode=RuntimeTriggerCommandOpcode::INGEST_EVENT; command.event.source_id=0; command.event.event_id=1; command.event.day=0; command.event.event_type=1; if(!authority.queue_command(command,error)) return false;
    command.request_id=2; command.sequence=2; command.event.event_id=2; if(!authority.queue_command(command,error)) return false;
    RuntimeTriggerPodPlan plan; if(!authority.plan_day(0,1,plan,error) || plan.intents.size()!=1 || !authority.commit_day(plan,plan.acks,error)) return false;
    RuntimeTriggerPodSaveSection save; if(!authority.encode_save(save,error)) return false; RuntimeTriggerPodAuthority restored; if(!restored.restore_save(save,catalog,error)) return false;
    if (restored.state_hash() != authority.state_hash()) { error = "trigger_self_test_save_roundtrip_failed"; return false; }
    {
        RuntimeTriggerPodAuthority congested;
        RuntimeTriggerSnapshot empty;
        empty.next_effect_id = 100;
        if (!congested.bootstrap(empty, catalog, error)) return false;
        RuntimeTriggerCommand control;
        control.opcode = RuntimeTriggerCommandOpcode::SET_ENABLED;
        control.trigger_id = 0;
        for (uint32_t i = 1; i < RUNTIME_COMMAND_QUEUE_CAPACITY; ++i) {
            control.request_id = control.sequence = i;
            if (!congested.queue_command(control, error)) return false;
        }
        if (congested.queue_command(control, error) ||
            error != "trigger_command_capacity_exhausted") {
            error = "trigger_delivery_ack_slot_not_reserved";
            return false;
        }
        RuntimeTriggerCommand ack;
        ack.request_id = ack.sequence = RUNTIME_COMMAND_QUEUE_CAPACITY;
        ack.opcode = RuntimeTriggerCommandOpcode::ACK_EFFECTS;
        ack.ack_up_to_effect_id = 7;
        if (!congested.queue_command(ack, error)) return false;
        ack.ack_up_to_effect_id = 9;
        if (!congested.queue_command(ack, error)) return false;
        RuntimeTriggerPodSaveSection queued;
        RuntimeTriggerPodAuthority resumed;
        if (!congested.encode_save(queued, error) ||
            !resumed.restore_save(queued, catalog, error)) return false;
        RuntimeTriggerPodPlan drained;
        if (!resumed.plan_day(0, 1, drained, error) ||
            drained.consumed_commands.size() != RUNTIME_COMMAND_QUEUE_CAPACITY ||
            drained.next_state.acked_effect_id != 9 ||
            !resumed.commit_day(drained, {}, error)) {
            error = "trigger_delivery_ack_congestion_roundtrip_failed";
            return false;
        }
    }
    {
        RuntimeTriggerPodAuthority ordering;
        if (!ordering.bootstrap(initial, catalog, error)) return false;
        auto enqueue = [&](uint64_t id, int64_t day, uint8_t enabled) {
            RuntimeTriggerCommand value;
            value.request_id = id;
            value.sequence = id;
            value.requested_day = 0;
            value.effective_day = day;
            value.opcode = RuntimeTriggerCommandOpcode::SET_ENABLED;
            value.trigger_id = 0;
            value.enabled = enabled;
            return ordering.queue_command(value, error);
        };
        if (!enqueue(99, 2, 0) || !enqueue(10, 1, 0) || !enqueue(2, 1, 0) ||
            !enqueue(10, 1, 1) || !enqueue(1, 1, 1)) return false;
        RuntimeTriggerPodPlan ordered_plan;
        for (int attempt = 0; attempt < 2; ++attempt) {
            if (!ordering.plan_day(1, 2, ordered_plan, error)) return false;
            const std::array<uint64_t, 4> ids{1, 2, 10, 10};
            if (ordered_plan.consumed_commands.size() != ids.size() ||
                ordered_plan.next_state.enabled[0] != 1) {
                error = "trigger_command_stable_order_failed";
                return false;
            }
            for (size_t i = 0; i < ids.size(); ++i) {
                if (ordered_plan.consumed_commands[i].request_id != ids[i]) {
                    error = "trigger_command_order_failed";
                    return false;
                }
            }
            if (attempt == 0) ordering.discard_plan();
        }
        if (!ordering.commit_day(ordered_plan, {}, error) ||
            !ordering.plan_day(2, 3, ordered_plan, error) ||
            ordered_plan.consumed_commands.size() != 1 ||
            ordered_plan.consumed_commands[0].request_id != 99 ||
            ordered_plan.next_state.enabled[0] != 0 ||
            !ordering.commit_day(ordered_plan, {}, error)) {
            error = "trigger_command_retained_replay_failed";
            return false;
        }
    }
    {
        // Delivery ACK by explicit effect id. Canonical order is trigger 0 (id 2)
        // then trigger 1 (id 1); acking the delivered id 2 must not delete id 1.
        RuntimeTriggerPodCatalog ack_catalog = catalog;
        RuntimeTriggerDefinition second_definition = catalog.definitions[0];
        second_definition.event_type = 2;
        ack_catalog.definitions.push_back(second_definition);
        const uint64_t ack_target = (uint64_t{1} << 32u) | 7u;
        RuntimeTriggerEffectIntent canonical_first;
        canonical_first.id = 2;
        canonical_first.effective_day = 1;
        canonical_first.trigger_id = 0;
        canonical_first.effect_definition_id = 0;
        canonical_first.target_handle = ack_target;
        canonical_first.target_generation = 1;
        canonical_first.action = catalog.effects[0].action;
        canonical_first.domain = catalog.effects[0].domain;
        canonical_first.opcode = catalog.effects[0].opcode;
        RuntimeTriggerEffectIntent canonical_second = canonical_first;
        canonical_second.id = 1;
        canonical_second.trigger_id = 1;
        RuntimeTriggerSnapshot seeded;
        seeded.next_effect_id = 3;
        seeded.acked_effect_id = 0;
        seeded.pending_effects.push_back(canonical_first);
        seeded.pending_effects.push_back(canonical_second);
        RuntimeTriggerPodAuthority ack_authority;
        if (!ack_authority.bootstrap(seeded, ack_catalog, error)) return false;
        auto queue_ack_ids = [&](int64_t id) {
            RuntimeTriggerCommand command;
            command.request_id = command.sequence = static_cast<uint64_t>(id + 100);
            command.effective_day = 0;
            command.requested_day = 0;
            command.opcode = RuntimeTriggerCommandOpcode::ACK_EFFECT_IDS;
            command.resync_count = 1;
            command.resync_values[0] = id;
            return ack_authority.queue_command(command, error);
        };
        // Two same-day ACKs merge into one bounded id union.
        if (!queue_ack_ids(2) || !queue_ack_ids(1) ||
            ack_authority.pending_command_count() != 1) {
            error = "trigger_ack_ids_merge_failed";
            return false;
        }
        RuntimeTriggerPodPlan ack_plan;
        if (!ack_authority.plan_day(1, 1, ack_plan, error) ||
            !ack_plan.next_state.pending_effects.empty() ||
            ack_plan.next_state.acked_effect_id != 2 ||
            ack_plan.consumed_commands.size() != 1 ||
            !ack_authority.commit_day(ack_plan, {}, error)) {
            error = "trigger_ack_ids_apply_failed";
            return false;
        }
        // TPD1 round trip keeps the ACK_EFFECT_IDS command serializable.
        if (!queue_ack_ids(1)) { error = "trigger_ack_ids_requeue_failed"; return false; }
        RuntimeTriggerPodSaveSection ack_save;
        RuntimeTriggerPodAuthority ack_resumed;
        if (!ack_authority.encode_save(ack_save, error) ||
            !ack_resumed.restore_save(ack_save, ack_catalog, error)) return false;
        RuntimeTriggerPodPlan resumed_plan;
        if (!ack_resumed.plan_day(1, 1, resumed_plan, error) ||
            resumed_plan.consumed_commands.size() != 1 ||
            resumed_plan.next_state.acked_effect_id != 2) {
            error = "trigger_ack_ids_roundtrip_failed";
            return false;
        }
    }
    {
        // Recovery replay command: only a completed ONE_SHOT achievement with a
        // single COUNTRY_COMMAND(opcode 14 / domain 1 / CONSTANT 4) effect is
        // accepted; the event day is backfilled to day-1 and payload_i0 packs
        // (signal_index << 32) | cell. A pending replay is not duplicated.
        RuntimeTriggerPodCatalog replay_catalog = catalog;
        RuntimeTriggerDefinition achievement = catalog.definitions[0];
        achievement.event_type = 2;
        achievement.mode = static_cast<int32_t>(RuntimeTriggerMode::ONE_SHOT);
        achievement.development_metric_id = 0;
        achievement.condition_begin = 0;
        achievement.condition_count = 0;
        achievement.effect_begin = 1;
        achievement.effect_count = 1;
        replay_catalog.definitions.push_back(achievement);
        RuntimeTriggerEffectDefinition signal_effect;
        signal_effect.action = static_cast<int32_t>(RuntimeTriggerAction::COUNTRY_COMMAND);
        signal_effect.domain = 1;
        signal_effect.opcode = 14;
        signal_effect.target_resolver = static_cast<int32_t>(
            RuntimeTriggerTargetResolver::EVENT_ENTITY);
        signal_effect.value_mode = static_cast<int32_t>(RuntimeTriggerValueMode::CONSTANT);
        signal_effect.value = 4;
        signal_effect.payload = {42, 0, 0, 1};
        replay_catalog.effects.push_back(signal_effect);
        const uint64_t replay_target = (uint64_t{1} << 32u) | 7u;
        RuntimeTriggerSnapshot seeded;
        seeded.next_effect_id = 1;
        seeded.acked_effect_id = 0;
        RuntimeTriggerPodSnapshotState completed_state;
        completed_state.trigger_id = 1;
        completed_state.target_handle = replay_target;
        completed_state.target_generation = 1;
        completed_state.completed = 1;
        completed_state.initialized = 1;
        completed_state.distinct_keys.assign(replay_catalog.distinct_capacity,
            std::numeric_limits<int64_t>::min());
        seeded.states.push_back(completed_state);
        auto queue_replay = [&](RuntimeTriggerPodAuthority &authority, int64_t day) {
            RuntimeTriggerCommand command;
            command.request_id = command.sequence = static_cast<uint64_t>(day + 500);
            command.effective_day = day;
            command.requested_day = day;
            command.opcode = RuntimeTriggerCommandOpcode::REPLAY_COMPLETED_RESEARCH_SIGNAL;
            command.trigger_id = 1;
            command.event.entity_handle = replay_target;
            command.event.group_handle = 5;
            return authority.queue_command(command, error);
        };
        RuntimeTriggerPodAuthority replay_authority;
        if (!replay_authority.bootstrap(seeded, replay_catalog, error) ||
            !queue_replay(replay_authority, 3)) return false;
        RuntimeTriggerPodPlan replay_plan;
        if (!replay_authority.plan_day(3, 1, replay_plan, error) ||
            replay_plan.next_state.pending_effects.size() != 1) {
            error = "trigger_research_replay_missing_effect";
            return false;
        }
        const RuntimeTriggerEffectIntent &replayed = replay_plan.next_state.pending_effects[0];
        if (replayed.effective_day != 3 || replayed.target_handle != replay_target ||
            replayed.target_generation != 1 ||
            replayed.payload[0] != static_cast<int64_t>((uint64_t{42} << 32u) | 5u) ||
            !replay_authority.commit_day(replay_plan, {}, error)) {
            error = "trigger_research_replay_effect_invalid";
            return false;
        }
        if (!queue_replay(replay_authority, 4)) return false;
        RuntimeTriggerPodPlan duplicate_plan;
        if (!replay_authority.plan_day(4, 1, duplicate_plan, error) ||
            duplicate_plan.next_state.pending_effects.size() != 1 ||
            !replay_authority.commit_day(duplicate_plan, {}, error)) {
            error = "trigger_research_replay_not_deduplicated";
            return false;
        }
        // TPD1 round trip: a queued replay survives encode/restore and applies.
        RuntimeTriggerPodAuthority save_authority;
        if (!save_authority.bootstrap(seeded, replay_catalog, error) ||
            !queue_replay(save_authority, 3)) return false;
        RuntimeTriggerPodSaveSection replay_save;
        RuntimeTriggerPodAuthority replay_resumed;
        if (!save_authority.encode_save(replay_save, error) ||
            !replay_resumed.restore_save(replay_save, replay_catalog, error)) return false;
        RuntimeTriggerPodPlan resumed_replay;
        if (!replay_resumed.plan_day(3, 1, resumed_replay, error) ||
            resumed_replay.consumed_commands.size() != 1 ||
            resumed_replay.next_state.pending_effects.size() != 1) {
            error = "trigger_research_replay_roundtrip_failed";
            return false;
        }
    }
    if (!RuntimeTriggerSnapshotRing::self_test()) { error = "trigger_snapshot_ring_self_test_failed"; return false; }
    return true;
}
