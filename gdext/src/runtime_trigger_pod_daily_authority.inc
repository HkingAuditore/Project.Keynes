bool RuntimeTriggerPodAuthority::apply_command(RuntimeTriggerSnapshot &state,
                                                const RuntimeTriggerCommand &command,
                                                std::string &error) const {
    error.clear();
    if (!validate_command_shape(command, _catalog, error)) return false;
    if (command.observed_generation != 0 &&
        command.observed_generation != state.generation) {
        error = "stale_generation";
        return false;
    }
    switch (command.opcode) {
        case RuntimeTriggerCommandOpcode::INGEST_EVENT:
        case RuntimeTriggerCommandOpcode::INGEST_SNAPSHOT: {
            RuntimeTriggerEvent event = command.event;
            if (command.opcode == RuntimeTriggerCommandOpcode::INGEST_SNAPSHOT)
                event.snapshot = 1;
            if (!valid_event(event, _catalog)) { error = "trigger_event_invalid"; return false; }
            const size_t source = static_cast<size_t>(event.source_id);
            if (state.source_needs_resync[source] != 0) {
                error = "trigger_source_needs_resync";
                return false;
            }
            const int64_t cursor = state.source_cursor[source];
            if (event.event_id <= cursor) return true;
            if (_catalog.strict_source_cursors && cursor > 0 && event.event_id != cursor + 1) {
                state.source_needs_resync[source] = 1;
                state.source_gap_begin[source] = cursor + 1;
                state.source_gap_end[source] = event.event_id;
                for (RuntimeTriggerPodSnapshotState &trigger_state : state.states) {
                    if (trigger_state.trigger_id >= 0 &&
                        _catalog.definitions[trigger_state.trigger_id].source_id == event.source_id)
                        trigger_state.needs_resync = 1;
                }
                error = "trigger_source_gap";
                return false;
            }
            if (state.pending_events.size() >= static_cast<size_t>(_catalog.max_pending_events)) {
                error = "trigger_pending_event_capacity_exhausted";
                return false;
            }
            state.pending_events.push_back(event);
            state.source_cursor[source] = event.event_id;
            return true;
        }
        case RuntimeTriggerCommandOpcode::SET_ENABLED:
            if (command.trigger_id < 0 ||
                command.trigger_id >= static_cast<int32_t>(_catalog.definitions.size())) {
                error = "trigger_id_invalid"; return false;
            }
            state.enabled[command.trigger_id] = command.enabled != 0 ? 1 : 0;
            return true;
        case RuntimeTriggerCommandOpcode::RECONCILE_BRANCH_BINDING: {
            const RuntimeTriggerBranchBinding binding = command.binding;
            if (binding.trigger_id < 0 ||
                binding.trigger_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
                _catalog.definitions[binding.trigger_id].dynamic_binding == 0 ||
                binding.branch_handle == 0 || binding.cell < 0 ||
                binding.reward_target < 0 || binding.reward_target > 1) {
                error = "trigger_branch_binding_invalid"; return false;
            }
            auto found = std::find_if(state.branch_bindings.begin(), state.branch_bindings.end(),
                [&binding](const RuntimeTriggerBranchBinding &candidate) {
                    return candidate.trigger_id == binding.trigger_id &&
                        candidate.branch_handle == binding.branch_handle &&
                        candidate.cell == binding.cell;
                });
            if (binding.enabled == 0) {
                if (found != state.branch_bindings.end()) {
                    state.states.erase(std::remove_if(state.states.begin(), state.states.end(),
                        [&binding](const RuntimeTriggerPodSnapshotState &candidate) {
                            return candidate.trigger_id == binding.trigger_id &&
                                candidate.target_handle == binding.branch_handle;
                        }), state.states.end());
                    state.pending_effects.erase(std::remove_if(state.pending_effects.begin(),
                        state.pending_effects.end(),
                        [&binding](const RuntimeTriggerEffectIntent &candidate) {
                            return candidate.trigger_id == binding.trigger_id &&
                                candidate.target_handle == binding.branch_handle;
                        }), state.pending_effects.end());
                    state.branch_bindings.erase(found);
                }
                return true;
            }
            if (found == state.branch_bindings.end()) state.branch_bindings.push_back(binding);
            else *found = binding;
            std::stable_sort(state.branch_bindings.begin(), state.branch_bindings.end(),
                [](const RuntimeTriggerBranchBinding &a, const RuntimeTriggerBranchBinding &b) {
                    return std::tie(a.trigger_id, a.cell, a.branch_handle) <
                        std::tie(b.trigger_id, b.cell, b.branch_handle);
                });
            return true;
        }
        case RuntimeTriggerCommandOpcode::RESYNC_SOURCE: {
            if (command.source_id < 0 || command.source_id >= _catalog.source_count ||
                command.cursor < 0) { error = "trigger_resync_source_invalid"; return false; }
            state.source_cursor[command.source_id] = command.cursor;
            state.source_needs_resync[command.source_id] = 0;
            state.source_gap_begin[command.source_id] = 0;
            state.source_gap_end[command.source_id] = 0;
            for (RuntimeTriggerPodSnapshotState &trigger_state : state.states) {
                if (trigger_state.trigger_id >= 0 &&
                    _catalog.definitions[trigger_state.trigger_id].source_id == command.source_id)
                    trigger_state.needs_resync = 0;
            }
            for (uint32_t i = 0; i < command.resync_count; ++i) {
                const int32_t trigger_id = command.resync_trigger_ids[i];
                const uint64_t target = command.resync_target_handles[i];
                const int32_t state_index = find_or_create_state(
                    state, _catalog, trigger_id, target, error);
                if (state_index < 0) return false;
                RuntimeTriggerPodSnapshotState &trigger_state = state.states[state_index];
                const int64_t value = command.resync_values[i];
                trigger_state.accumulator = value;
                trigger_state.remainder = value %
                    std::max<int64_t>(1, _catalog.definitions[trigger_id].threshold);
                trigger_state.last_event_id = command.cursor;
                trigger_state.needs_resync = 0;
                trigger_state.initialized = 1;
            }
            return true;
        }
        case RuntimeTriggerCommandOpcode::ACK_EFFECTS:
            state.acked_effect_id = std::max(state.acked_effect_id,
                                             command.ack_up_to_effect_id);
            state.pending_effects.erase(std::remove_if(state.pending_effects.begin(),
                state.pending_effects.end(), [&state](const RuntimeTriggerEffectIntent &effect) {
                    return effect.id <= state.acked_effect_id;
                }), state.pending_effects.end());
            return true;
        case RuntimeTriggerCommandOpcode::ACK_EFFECT_IDS: {
            std::vector<int64_t> ids(command.resync_values.begin(),
                command.resync_values.begin() + command.resync_count);
            std::sort(ids.begin(), ids.end());
            state.pending_effects.erase(std::remove_if(state.pending_effects.begin(),
                state.pending_effects.end(), [&ids](const RuntimeTriggerEffectIntent &effect) {
                    return std::binary_search(ids.begin(), ids.end(), effect.id);
                }), state.pending_effects.end());
            int64_t frontier = state.next_effect_id - 1;
            for (const auto &effect : state.pending_effects)
                frontier = std::min(frontier, effect.id - 1);
            state.acked_effect_id = std::max(state.acked_effect_id, frontier);
            return true;
        }
        case RuntimeTriggerCommandOpcode::REPLAY_COMPLETED_RESEARCH_SIGNAL:
            return RuntimeTriggerKernel::replay_completed_research_signal(_catalog,
                state, command.trigger_id, command.event.entity_handle,
                static_cast<int32_t>(command.event.group_handle),
                command.effective_day, error);
        default:
            error = "trigger_command_opcode_invalid";
            return false;
    }
}

bool RuntimeTriggerPodAuthority::plan_day(int64_t day, uint64_t input_generation,
                                          RuntimeTriggerPodPlan &plan,
                                          std::string &error) {
    error.clear();
    plan.header = RuntimeDomainHeader{};
    plan.consumed_commands.clear();
    plan.intents.clear();
    plan.acks.clear();
    plan.required_ack_count = 0;
    plan.preflight_ok = 0;
    plan.committed = 0;
    if (!_bootstrapped) { error = "trigger_pod_not_bootstrapped"; return false; }
    if (_plan_active) { error = "trigger_plan_already_pending"; return false; }
    if (day < 0 || day < _state.committed_day) { error = "trigger_day_invalid"; return false; }
    plan.header.domain = static_cast<uint16_t>(RuntimeDomainId::TRIGGER_INPUT);
    plan.header.day = day;
    plan.header.input_generation = input_generation;
    plan.header.base_generation = _state.generation;
    {
        EconomyCostProbe copy_cost("trigger.plan_copy", day, _state.states.size());
        copy_trigger_snapshot_reuse_capacity(plan.next_state, _state);
    }
    std::vector<RuntimeTriggerCommand> retained;
    {
    EconomyCostProbe command_cost("trigger.commands", day, _pending_commands.size());
    static const bool scalar_commands = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_TRIGGER_COMMAND_COPY_SCALAR);
        return value && std::strcmp(value, "1") == 0;
    }();
    std::vector<RuntimeTriggerCommand> scalar_ordered;
    std::vector<const RuntimeTriggerCommand *> ordered;
    if (scalar_commands) {
        scalar_ordered = _pending_commands;
        std::stable_sort(scalar_ordered.begin(), scalar_ordered.end(), command_less);
    } else if (!std::is_sorted(_pending_commands.begin(), _pending_commands.end(), command_less)) {
        // 命令携带大块 resync 数组；只排序引用，原表到成功 preflight 后才改动。
        ordered.reserve(_pending_commands.size());
        for (const auto &command : _pending_commands) ordered.push_back(&command);
        std::stable_sort(ordered.begin(), ordered.end(), [](const auto *a, const auto *b) {
            return command_less(*a, *b);
        });
    }
    retained.reserve(_pending_commands.size());
    for (size_t i = 0; i < _pending_commands.size(); ++i) {
        const RuntimeTriggerCommand &command = scalar_commands ? scalar_ordered[i]
            : ordered.empty() ? _pending_commands[i] : *ordered[i];
        if (command.effective_day > day) { retained.push_back(command); continue; }
        if (!apply_command(plan.next_state, command, error)) {
            plan.header.preflight_ok = 0;
            copy_reason(plan.header.fallback_reason, error);
            _diagnostics.day = day;
            copy_reason(_diagnostics.blocker, error);
            return false;
        }
        plan.consumed_commands.push_back(command);
    }
    EconomyCostProbe::record("trigger.command_order_copy_bytes", day, 0.0,
        scalar_ordered.size() * sizeof(RuntimeTriggerCommand));
    EconomyCostProbe::record("trigger.command_order_reference_bytes", day, 0.0,
        ordered.size() * sizeof(const RuntimeTriggerCommand *));
    }
    static const bool verify_kernel = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_TRIGGER_MEMO_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    RuntimeTriggerSnapshot reference_state;
    if (verify_kernel) reference_state = plan.next_state;
    std::string kernel_error;
    if (!RuntimeTriggerKernel::evaluate_day(_catalog, plan.next_state, day,
                                            plan.intents, kernel_error)) {
        error = kernel_error.empty() ? "trigger_kernel_failed" : kernel_error;
        plan.header.preflight_ok = 0;
        copy_reason(plan.header.fallback_reason, error);
        _diagnostics.day = day;
        copy_reason(_diagnostics.blocker, error);
        return false;
    }
    if (verify_kernel) {
        std::vector<RuntimeTriggerEffectIntent> reference_intents;
        std::string reference_error;
        if (!RuntimeTriggerKernel::evaluate_day(_catalog, reference_state, day,
                reference_intents, reference_error, true) ||
            hash_snapshot_impl(reference_state) != hash_snapshot_impl(plan.next_state) ||
            hash_effects(reference_intents) != hash_effects(plan.intents)) {
            error = "trigger_binding_index_reference_mismatch";
            return false;
        }
    }
    plan.next_state.generation = _state.generation + 1u;
    plan.next_state.committed_day = day;
    {
        EconomyCostProbe canonical_cost("trigger.canonicalize", day, plan.next_state.states.size());
        canonicalize_snapshot_in_place(plan.next_state, true);
    }
    uint64_t hash_with_gen = 0;
    uint64_t hash_zero_gen = 0;
    hash_snapshot_dual(plan.next_state, hash_with_gen, hash_zero_gen);
    if (verify_kernel) {
        const uint64_t reference_with_gen = hash_snapshot_impl(plan.next_state);
        const uint64_t generation = plan.next_state.generation;
        plan.next_state.generation = 0;
        const uint64_t reference_zero_gen = hash_snapshot_impl(plan.next_state);
        plan.next_state.generation = generation;
        if (hash_with_gen != reference_with_gen || hash_zero_gen != reference_zero_gen) {
            error = "trigger_hash_dual_reference_mismatch";
            return false;
        }
    }
    plan.header.state_hash = hash_with_gen;
    plan.header.intent_count = static_cast<uint32_t>(plan.intents.size());
    plan.required_ack_count = static_cast<uint32_t>(plan.intents.size());
    plan.header.ack_count = plan.required_ack_count;
    for (const RuntimeTriggerEffectIntent &intent : plan.intents) {
        RuntimeDomainAck ack;
        ack.transaction_id = static_cast<uint64_t>(intent.id);
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.domain = static_cast<uint16_t>(intent.domain);
        ack.effective_day = intent.effective_day;
        plan.acks.push_back(ack);
    }
    plan.header.preflight_ok = 1;
    _active_plan = &plan;
    _plan_active = true;
    _diagnostics.day = day;
    _diagnostics.input_hash = input_generation;
    _diagnostics.generation = _state.generation;
    _diagnostics.committed_day = _state.committed_day;
    _diagnostics.acked_effect_id = _state.acked_effect_id;
    _diagnostics.pending_command_count = static_cast<uint32_t>(_pending_commands.size());
    _diagnostics.worker_state_hash = hash_zero_gen;
    _diagnostics.worker_effect_hash = hash_effects(plan.intents);
    _diagnostics.required_ack_count = plan.required_ack_count;
    _diagnostics.received_ack_count = 0;
    _diagnostics.pending_ack_count = plan.required_ack_count;
    _diagnostics.parity_compared = 0;
    _diagnostics.parity_matched = 0;
    _diagnostics.first_divergence_index = -1;
    copy_reason32(_diagnostics.first_divergence_kind, "");
    copy_reason(_diagnostics.blocker, "trigger_reference_pending");
    _pending_commands.swap(retained);
    return true;
}

bool RuntimeTriggerPodAuthority::commit_day(RuntimeTriggerPodPlan &plan,
                                            const std::vector<RuntimeDomainAck> &acks,
                                            std::string &error) {
    error.clear();
    if (!_plan_active || _active_plan != &plan) { error = "trigger_plan_missing"; return false; }
    std::set<int64_t> received;
    for (const RuntimeDomainAck &ack : acks) {
        for (const RuntimeTriggerEffectIntent &intent : plan.intents) {
            if (ack_matches(ack, intent)) received.insert(intent.id);
        }
        if (ack.code == RuntimeDomainAckCode::RETRY ||
            ack.code == RuntimeDomainAckCode::STALE_GENERATION) {
            _pending_commands.insert(_pending_commands.end(), plan.consumed_commands.begin(),
                                     plan.consumed_commands.end());
            std::stable_sort(_pending_commands.begin(), _pending_commands.end(),
                [](const RuntimeTriggerCommand &a, const RuntimeTriggerCommand &b) {
                    return std::tie(a.effective_day, a.producer_id, a.sequence, a.request_id) <
                        std::tie(b.effective_day, b.producer_id, b.sequence, b.request_id);
                });
            _plan_active = false;
            _active_plan = nullptr;
            _diagnostics.received_ack_count = static_cast<uint32_t>(received.size());
            _diagnostics.pending_ack_count = plan.required_ack_count -
                std::min<uint32_t>(plan.required_ack_count, _diagnostics.received_ack_count);
            copy_reason(_diagnostics.blocker,
                        ack.code == RuntimeDomainAckCode::RETRY ? "ack_retry" : "stale_generation");
            error = ack.code == RuntimeDomainAckCode::RETRY ? "ack_retry" : "stale_generation";
            return false;
        }
        if (ack.code == RuntimeDomainAckCode::REJECTED) {
            _pending_commands.insert(_pending_commands.end(), plan.consumed_commands.begin(),
                                     plan.consumed_commands.end());
            std::stable_sort(_pending_commands.begin(), _pending_commands.end(), command_less);
            _plan_active = false;
            _active_plan = nullptr;
            copy_reason(_diagnostics.blocker, "ack_rejected");
            error = "ack_rejected";
            return false;
        }
    }
    _diagnostics.received_ack_count = static_cast<uint32_t>(received.size());
    _diagnostics.pending_ack_count = plan.required_ack_count > received.size()
        ? plan.required_ack_count - static_cast<uint32_t>(received.size()) : 0;
    if (received.size() < plan.required_ack_count) {
        error = "ack_barrier_incomplete";
        copy_reason(_diagnostics.blocker, error);
        return false;
    }
    {
        EconomyCostProbe copy_cost("trigger.commit_copy", plan.header.day, plan.next_state.states.size());
        copy_trigger_snapshot_reuse_capacity(_state, plan.next_state);
    }
    _state_hash = plan.header.state_hash != 0
        ? plan.header.state_hash
        : hash_snapshot(_state);
    plan.committed = 1;
    _plan_active = false;
    _active_plan = nullptr;
    if (_diagnostics.worker_state_hash == 0) {
        _diagnostics.worker_state_hash = canonical_state_hash(_state);
    }
    _diagnostics.worker_effect_hash = hash_effects(_state.pending_effects);
    _diagnostics.generation = _state.generation;
    _diagnostics.committed_day = _state.committed_day;
    _diagnostics.acked_effect_id = _state.acked_effect_id;
    _diagnostics.pending_command_count = static_cast<uint32_t>(_pending_commands.size());
    compare_reference_frame();
    return true;
}

void RuntimeTriggerPodAuthority::discard_plan() {
    if (_plan_active && _active_plan != nullptr) {
        _pending_commands.insert(_pending_commands.end(),
            _active_plan->consumed_commands.begin(), _active_plan->consumed_commands.end());
        std::stable_sort(_pending_commands.begin(), _pending_commands.end(),
            [](const RuntimeTriggerCommand &a, const RuntimeTriggerCommand &b) {
                return std::tie(a.effective_day, a.producer_id, a.sequence, a.request_id) <
                    std::tie(b.effective_day, b.producer_id, b.sequence, b.request_id);
            });
    }
    _active_plan = nullptr;
    _plan_active = false;
}

bool RuntimeTriggerPodAuthority::snapshot(RuntimeTriggerSnapshot &out,
                                          std::string &error) const {
    error.clear();
    if (!_bootstrapped) { error = "trigger_pod_not_bootstrapped"; return false; }
    EconomyCostProbe copy_cost("trigger.snapshot_copy", _state.current_day, _state.states.size());
    copy_trigger_snapshot_reuse_capacity(out, _state);
    return true;
}
