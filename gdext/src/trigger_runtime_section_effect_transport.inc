Dictionary TriggerRuntime::poll_effects(int64_t after_effect_id,
                                        int32_t limit) const {
    PackedInt64Array ids, days, targets, sequences, values, p0, p1, p2, p3;
    PackedInt32Array priorities, triggers, generations, actions, domains,
        opcodes, durations, stacks;
    PackedStringArray trigger_keys, command_keys, definition_keys;
    const int32_t max_count = std::max(0, limit);
    for (const Effect &effect : _effects) {
        if (effect.id <= after_effect_id || effect.id <= _acked_effect_id) continue;
        ids.append(effect.id);
        days.append(effect.effective_day);
        priorities.append(effect.source_priority);
        triggers.append(effect.trigger_id);
        trigger_keys.append(effect.trigger_id >= 0 &&
            effect.trigger_id < static_cast<int32_t>(_definitions.size())
                ? _definitions[effect.trigger_id].key.c_str() : "");
        targets.append(static_cast<int64_t>(effect.target_handle));
        generations.append(static_cast<int32_t>(effect.target_generation));
        sequences.append(static_cast<int64_t>(effect.fire_sequence));
        actions.append(effect.action);
        domains.append(effect.domain);
        opcodes.append(effect.opcode);
        values.append(effect.resolved_value);
        durations.append(effect.duration_days);
        stacks.append(effect.stacks);
        command_keys.append(effect.command_key.c_str());
        definition_keys.append(effect.definition_key.c_str());
        p0.append(effect.payload[0]); p1.append(effect.payload[1]);
        p2.append(effect.payload[2]); p3.append(effect.payload[3]);
        if (max_count > 0 && ids.size() >= max_count) break;
    }
    Dictionary out;
    out["ok"] = true;
    out["effect_ids"] = ids;
    out["effective_days"] = days;
    out["source_priorities"] = priorities;
    out["trigger_ids"] = triggers;
    out["trigger_keys"] = trigger_keys;
    out["target_handles"] = targets;
    out["target_generations"] = generations;
    out["fire_sequences"] = sequences;
    out["actions"] = actions;
    out["domains"] = domains;
    out["opcodes"] = opcodes;
    out["resolved_values"] = values;
    out["duration_days"] = durations;
    out["stacks"] = stacks;
    out["command_keys"] = command_keys;
    out["definition_keys"] = definition_keys;
    out["payload_i0"] = p0; out["payload_i1"] = p1;
    out["payload_i2"] = p2; out["payload_i3"] = p3;
    out["count"] = ids.size();
    return out;
}

Dictionary TriggerRuntime::ack_effects(int64_t up_to_effect_id) {
    if (up_to_effect_id > _acked_effect_id) _acked_effect_id = up_to_effect_id;
    size_t keep = 0;
    while (keep < _effects.size() && _effects[keep].id <= _acked_effect_id) ++keep;
    if (keep > 0) _effects.erase(_effects.begin(), _effects.begin() + keep);
    Dictionary out;
    out["ok"] = true;
    out["acked_effect_id"] = _acked_effect_id;
    out["pending_effects"] = static_cast<int64_t>(_effects.size());
    return out;
}

Dictionary TriggerRuntime::ack_effect_ids(const PackedInt64Array &effect_ids) {
    std::unordered_set<int64_t> delivered;
    for (int64_t i = 0; i < effect_ids.size(); ++i) delivered.insert(effect_ids[i]);
    _effects.erase(std::remove_if(_effects.begin(), _effects.end(),
        [&delivered](const Effect &effect) { return delivered.count(effect.id) != 0; }),
        _effects.end());
    // IDs are allocated in ingress order, not canonical delivery order. Only
    // the gap-free numeric prefix may advance the legacy high-water cursor.
    int64_t frontier = _next_effect_id - 1;
    for (const Effect &effect : _effects) frontier = std::min(frontier, effect.id - 1);
    _acked_effect_id = std::max(_acked_effect_id, frontier);
    Dictionary out;
    out["ok"] = true;
    out["acked_effect_id"] = _acked_effect_id;
    out["pending_effects"] = static_cast<int64_t>(_effects.size());
    return out;
}

Dictionary TriggerRuntime::replay_completed_research_signal(int32_t trigger_id,
        uint64_t target, int32_t cell, int64_t day) {
    RuntimeTriggerPodCatalog catalog;
    RuntimeTriggerSnapshot snapshot;
    std::string error;
    bool enqueued = false;
    if (!export_pod_catalog(catalog, error) || !export_pod_snapshot(snapshot, error) ||
        !RuntimeTriggerKernel::replay_completed_research_signal(
            catalog, snapshot, trigger_id, target, cell, day, error, &enqueued))
        return failure(error.empty() ? "trigger_research_replay_failed" : error.c_str());
    if (!adopt_pod_state(snapshot, _current_day, error))
        return failure(error.empty() ? "trigger_research_replay_apply_failed" : error.c_str());
    Dictionary out;
    out["ok"] = true;
    out["enqueued"] = enqueued;
    out["trigger_id"] = trigger_id;
    out["target_handle"] = static_cast<int64_t>(target);
    out["pending_effects"] = static_cast<int64_t>(_effects.size());
    return out;
}

Dictionary TriggerRuntime::handoff_effects(EffectRuntime *effect_runtime,
                                           NativeIdeologyRuntime *ideology_runtime,
                                           NativeSimulationHost *ideology_pod_host,
                                           int32_t limit) {
    if (!_configured || effect_runtime == nullptr) return failure("trigger_effect_handoff_unavailable");
    const int32_t max_count = std::max(1, std::min(limit, 4096));
    int32_t handed_off = 0;
    int64_t last_effect_id = _acked_effect_id;
    PackedInt64Array handed_off_ids;
    std::string blocked_reason;
    std::string blocked_command_key;
    std::string blocked_definition_key;
    int32_t blocked_action = 0;
    int32_t blocked_opcode = 0;
    int32_t blocked_trigger_id = -1;
    for (const Effect &effect : _effects) {
        if (effect.id <= _acked_effect_id) continue;
        if (handed_off >= max_count) break;
        if (effect.action == IDEOLOGY_COMMAND) {
            if (ideology_runtime == nullptr) {
                blocked_reason = "trigger_ideology_runtime_unavailable";
                blocked_command_key = effect.command_key;
                blocked_definition_key = effect.definition_key;
                blocked_action = effect.action;
                blocked_opcode = effect.opcode;
                blocked_trigger_id = effect.trigger_id;
                break;
            }
            std::string error;
            if (!ideology_runtime->submit_trigger_command_pod(effect.opcode,
                    effect.effective_day, effect.source_priority,
                    effect.id, effect.target_handle,
                    static_cast<int32_t>(effect.payload[0]), effect.resolved_value,
                    static_cast<uint32_t>(std::max<int64_t>(0, effect.payload[1])),
                    static_cast<int32_t>(effect.payload[2]),
                    static_cast<int32_t>(effect.payload[3]), error)) {
                blocked_reason = error.empty() ? "trigger_ideology_handoff_failed" : error;
                blocked_command_key = effect.command_key;
                blocked_definition_key = effect.definition_key;
                blocked_action = effect.action;
                blocked_opcode = effect.opcode;
                blocked_trigger_id = effect.trigger_id;
                break;
            }
            if (ideology_pod_host != nullptr) {
                RuntimeIdeologyPodCommand pod_command;
                pod_command.request_id = static_cast<uint64_t>(effect.id);
                pod_command.source_priority = effect.source_priority;
                pod_command.producer_id = 2u;
                pod_command.sequence = static_cast<uint64_t>(effect.id);
                pod_command.requested_day = effect.effective_day;
                pod_command.effective_day = effect.effective_day;
                pod_command.opcode = static_cast<RuntimeIdeologyPodOpcode>(
                    effect.opcode);
                pod_command.country_handle = effect.target_handle;
                pod_command.ideology_id = static_cast<int32_t>(effect.payload[0]);
                pod_command.value_q16 = effect.resolved_value;
                pod_command.offer_generation = static_cast<uint32_t>(
                    std::max<int64_t>(0, effect.payload[1]));
                pod_command.choice_index = static_cast<int32_t>(effect.payload[2]);
                pod_command.gate_id = static_cast<int32_t>(effect.payload[3]);
                if (!ideology_pod_host->queue_ideology_pod_command(
                        pod_command, error)) {
                    blocked_reason = error.empty()
                        ? "trigger_ideology_pod_handoff_failed" : error;
                    blocked_command_key = effect.command_key;
                    blocked_definition_key = effect.definition_key;
                    blocked_action = effect.action;
                    blocked_opcode = effect.opcode;
                    blocked_trigger_id = effect.trigger_id;
                    break;
                }
            }
            last_effect_id = effect.id;
            handed_off_ids.push_back(effect.id);
            ++handed_off;
            continue;
        }
        // Modifier / Country / Economy actions have native EffectRuntime
        // adapters. PUBLISH_EVENT (and other notice-side actions) used to
        // break the contiguous handoff cursor here; under runtime-graph
        // ACTIVE the GDScript EventBus path never drains that head, so
        // trigger_should_run + hard_ack=effect pin WorldClock forever
        // (see economy.social_pressure_notice stalls). Soft-ACK notices so
        // the queue can drain; EventBus delivery remains a facade concern.
        const bool native_modifier = effect.action >= MODIFIER_APPLY &&
            effect.action <= MODIFIER_SET_STACKS;
        if (effect.action == PUBLISH_EVENT ||
            effect.action == GAMEPLAY_COMMAND ||
            effect.action == CUSTOM_DOMAIN_COMMAND ||
            effect.action == IDEOLOGY_COMMAND) {
            last_effect_id = effect.id;
            handed_off_ids.push_back(effect.id);
            ++handed_off;
            continue;
        }
        if (!native_modifier && effect.action != COUNTRY_COMMAND &&
            effect.action != ECONOMY_COMMAND) {
            blocked_reason = "trigger_effect_domain_adapter_required";
            blocked_command_key = effect.command_key;
            blocked_definition_key = effect.definition_key;
            blocked_action = effect.action;
            blocked_opcode = effect.opcode;
            blocked_trigger_id = effect.trigger_id;
            break;
        }
        std::string error;
        int32_t effect_action = effect.action;
        int32_t opcode = effect.opcode;
        if (effect.action == COUNTRY_COMMAND)
            effect_action = EffectRuntime::COUNTRY_COMMAND;
        else if (effect.action == ECONOMY_COMMAND) {
            effect_action = EffectRuntime::ECONOMY_COMMAND;
            if (effect.command_key == "family.free_building")
                opcode = EconomyApi::COMMAND_FAMILY_FREE_BUILDING;
            else if (effect.command_key == "family.population_reward")
                opcode = EconomyApi::COMMAND_FAMILY_POPULATION_REWARD;
            else if (effect.command_key == "family.absorb_anonymous")
                opcode = EconomyApi::COMMAND_FAMILY_ABSORB_ANONYMOUS;
            else if (effect.command_key == "family.purchase_discount")
                opcode = EconomyApi::COMMAND_FAMILY_PURCHASE_DISCOUNT;
            else if (effect.command_key == "family.set_split_policy")
                opcode = EconomyApi::COMMAND_FAMILY_SET_SPLIT_POLICY;
        }
        if (!effect_runtime->enqueue_trigger_effect_pod(
                effect.id, effect.effective_day, effect.trigger_id,
                effect.target_handle, effect.target_generation,
                effect.fire_sequence, effect_action, effect.domain, opcode,
                effect.resolved_value, effect.duration_days, effect.stacks,
                effect.command_key, effect.definition_key, effect.payload, error)) {
            blocked_reason = error.empty() ? "trigger_effect_handoff_failed" : error;
            blocked_command_key = effect.command_key;
            blocked_definition_key = effect.definition_key;
            blocked_action = effect.action;
            blocked_opcode = effect.opcode;
            blocked_trigger_id = effect.trigger_id;
            break;
        }
        last_effect_id = effect.id;
        handed_off_ids.push_back(effect.id);
        ++handed_off;
    }
    if (handed_off > 0) ack_effect_ids(handed_off_ids);
    Dictionary out;
    out["ok"] = blocked_reason.empty();
    out["native_supported"] = true;
    out["handed_off"] = handed_off;
    out["last_effect_id"] = last_effect_id;
    out["effect_ids"] = handed_off_ids;
    out["acked_effect_id"] = _acked_effect_id;
    out["blocked"] = !blocked_reason.empty();
    if (!blocked_reason.empty()) {
        out["reason"] = String(blocked_reason.c_str());
        out["blocked_command_key"] = String(blocked_command_key.c_str());
        out["blocked_definition_key"] = String(blocked_definition_key.c_str());
        out["blocked_action"] = blocked_action;
        out["blocked_opcode"] = blocked_opcode;
        out["blocked_trigger_id"] = blocked_trigger_id;
    }
    return out;
}
