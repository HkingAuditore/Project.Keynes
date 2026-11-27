bool RuntimeEffectPodAuthority::plan_day(int64_t day, uint64_t input_generation,
                                         RuntimeEffectPodPlan &plan,
                                         std::string &error) {
    error.clear();
    plan = RuntimeEffectPodPlan{};
    if (!_configured) { error = "effect_pod_not_configured"; set_blocker(error.c_str()); return false; }
    if (day < 0 || input_generation == 0 ||
        (_current.committed_day >= 0 && day != _current.committed_day + 1)) {
        error = _current.committed_day >= 0 ? "effect_pod_day_not_sequential"
                                            : "effect_pod_context_invalid";
        set_blocker(error.c_str());
        return false;
    }
    if (_plan_ready) { error = "effect_pod_plan_already_pending"; set_blocker(error.c_str()); return false; }
    _next = _current;
    std::vector<RuntimeEffectPodCommand> emitted;
    emitted.reserve(std::min<uint32_t>(_command_capacity, 4096u));
    plan.base_generation = _current.generation;
    plan.input_generation = input_generation;
    uint64_t plan_hash = FNV_OFFSET;
    plan_hash = mix_value(plan_hash, day);
    plan_hash = mix_value(plan_hash, input_generation);
    plan_hash = mix_value(plan_hash, _current.generation);

    for (size_t instance_index_value = 0;
         instance_index_value < _next.instances.size(); ++instance_index_value) {
        RuntimeEffectPodInstance &instance = _next.instances[instance_index_value];
        // An explicit retire keeps the tombstone active only until its REMOVE
        // ACKs. Planning the removal is the whole point of that state.
        if (instance.active == 0 && instance.retire_requested == 0) continue;
        if (instance.program_id < 0 ||
            instance.program_id >= static_cast<int32_t>(_catalog.definitions.size())) {
            error = "effect_pod_program_invalid";
            set_blocker(error.c_str());
            return false;
        }
        const auto &definition =
            _catalog.definitions[static_cast<size_t>(instance.program_id)];
        if (instance.pending_transaction_id != 0) {
            int32_t tx_index = -1;
            for (size_t i = 0; i < _next.transactions.size(); ++i) {
                if (_next.transactions[i].transaction_id == instance.pending_transaction_id) {
                    tx_index = static_cast<int32_t>(i);
                    break;
                }
            }
            if (tx_index >= 0 && _next.transactions[static_cast<size_t>(tx_index)].status ==
                    RuntimeEffectPodTransactionStatus::PLANNED) {
                auto &transaction = _next.transactions[static_cast<size_t>(tx_index)];
                transaction.status = RuntimeEffectPodTransactionStatus::PREFLIGHTED;
                ++plan.retried_transaction_count;
                plan.required_ack_mask |= transaction.required_ack_mask;
                append_transaction_intents(_next, definition, instance, transaction,
                                           plan.intents, &plan_hash);
            }
            continue;
        }
        if (instance.expires_day >= 0 && instance.expires_day <= day) {
            if (definition.managed != 0 && instance.effect_applied != 0) {
                RuntimeEffectPodTransaction transaction;
                if (!append_retirement_transaction(
                        _next, definition, instance, day, emitted, transaction,
                        error, true)) {
                    set_blocker(error.c_str());
                    return false;
                }
                plan.required_ack_mask |= transaction.required_ack_mask;
                append_transaction_intents(_next, definition, instance, transaction,
                                           plan.intents, &plan_hash);
                continue;
            }
            instance.active = 0;
            continue;
        }
        // An explicit retire is a request to remove the live row now, not a
        // cadence event. Let it through even when the APPLY parked the instance
        // on a future due day.
        if (instance.retire_requested == 0 &&
            (instance.next_due_day < 0 || instance.next_due_day > day)) {
            continue;
        }
        if (instance.retire_requested != 0) {
            if (definition.managed == 0 || instance.effect_applied == 0) {
                instance.active = 0;
                instance.retire_requested = 0;
                continue;
            }
            RuntimeEffectPodTransaction transaction;
            if (!append_retirement_transaction(
                    _next, definition, instance, day, emitted, transaction,
                    error)) {
                set_blocker(error.c_str());
                return false;
            }
            plan.required_ack_mask |= transaction.required_ack_mask;
            append_transaction_intents(_next, definition, instance, transaction,
                                       plan.intents, &plan_hash);
            continue;
        }
        // Cadence is the gap after a successful fire. A never-fired instance
        // (fire_sequence==0) must retry on the next calendar day — technology
        // programs author cadence_days=3650, and using that as a failure
        // backoff parks Country pending activation for a decade.
        const int64_t retry_due = instance.fire_sequence == 0
            ? day + 1
            : day + std::max<int32_t>(1, definition.cadence_days);
        if (definition.enabled == 0) {
            instance.next_due_day = retry_due;
            continue;
        }
        const ManagedLifecycleDecision decision = evaluate_managed_lifecycle(
            definition, instance, _current, day);
        if (decision == ManagedLifecycleDecision::RETIRE) {
            RuntimeEffectPodTransaction transaction;
            if (!append_retirement_transaction(
                    _next, definition, instance, day, emitted, transaction,
                    error)) {
                set_blocker(error.c_str());
                return false;
            }
            plan.required_ack_mask |= transaction.required_ack_mask;
            append_transaction_intents(_next, definition, instance,
                                       transaction, plan.intents,
                                       &plan_hash);
            continue;
        }
        if (decision == ManagedLifecycleDecision::IDLE) {
            instance.last_evaluated_input_revision = instance.input_revision;
            instance.next_due_day = retry_due;
            continue;
        }
        emitted.clear();
        if (!execute_program(definition, instance, _current, day, emitted, error)) {
            set_blocker(error.c_str());
            return false;
        }
        if (emitted.empty()) {
            instance.last_evaluated_input_revision = instance.input_revision;
            if (definition.command_count > 0 && instance.fire_sequence == 0) {
                // Declarative commands exist but none emitted — retry tomorrow
                // instead of applying the multi-year cadence backoff.
                instance.next_due_day = day + 1;
                continue;
            }
            // Match sync EffectRuntime: a passed evaluation with zero commands
            // still advances fire_sequence so fire_acked observes the one-shot.
            instance.fire_sequence += 1u;
            instance.next_due_day = day + std::max<int32_t>(1, definition.cadence_days);
            continue;
        }
        RuntimeEffectPodTransaction transaction;
        if (!schedule_application(_next, definition, instance, day, emitted,
                                  transaction, error)) {
            set_blocker(error.c_str());
            return false;
        }
        plan.required_ack_mask |= transaction.required_ack_mask;
        append_transaction_intents(_next, definition, instance, transaction,
                                   plan.intents, &plan_hash);
    }
    _next.generation = _current.generation + 1u;
    _next.committed_day = day;
    _next.deterministic_state_hash = state_hash(_next);
    plan.deterministic_plan_hash = plan_hash;
    plan.next_snapshot = RuntimeEffectPodSnapshot{};
    build_snapshot(_next, plan.next_snapshot);
    plan.emitted_command_count = static_cast<uint32_t>(plan.intents.size());
    plan.preflight_ok = 1;
    _active_plan = &plan;
    _plan_ready = true;
    rebuild_report(&plan);
    return true;
}

bool RuntimeEffectPodAuthority::commit_day(RuntimeEffectPodPlan &plan,
                                            std::string &error) {
    error.clear();
    if (!_plan_ready || _active_plan != &plan || plan.preflight_ok == 0) {
        error = "effect_pod_plan_missing";
        return false;
    }
    if (plan.base_generation != _current.generation ||
        plan.next_snapshot.catalog_hash != _catalog.catalog_hash ||
        plan.next_snapshot.generation != _next.generation) {
        error = "effect_pod_plan_generation_mismatch";
        _plan_ready = false;
        _active_plan = nullptr;
        return false;
    }
    for (auto &transaction : _next.transactions) {
        if (transaction.status == RuntimeEffectPodTransactionStatus::PREFLIGHTED)
            transaction.status = RuntimeEffectPodTransactionStatus::COMMITTED;
    }
    compact_acked_transactions(_next);
    _next.deterministic_state_hash = state_hash(_next);
    _current = std::move(_next);
    _next = State{};
    build_snapshot(_current, _snapshot);
    plan.next_snapshot = _snapshot;
    plan.committed = 1;
    _plan_ready = false;
    _active_plan = nullptr;
    rebuild_report();
    return true;
}

void RuntimeEffectPodAuthority::discard_plan() {
    _active_plan = nullptr;
    _plan_ready = false;
    _next = _current;
    rebuild_report();
}

bool RuntimeEffectPodAuthority::apply_ack(const RuntimeDomainAck &ack,
                                          std::string &error) {
    error.clear();
    if (!_configured) { error = "effect_pod_not_configured"; return false; }
    const int32_t tx_index = transaction_index(static_cast<int64_t>(ack.transaction_id));
    if (tx_index < 0) { error = "effect_pod_ack_transaction_unknown"; return false; }
    auto &transaction = _current.transactions[static_cast<size_t>(tx_index)];
    bool matched = false;
    uint32_t matched_bit = 0;
    for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
        const size_t command_index = static_cast<size_t>(transaction.command_begin) + ordinal;
        if (command_index >= _current.command_arena.size()) continue;
        const auto &command = _current.command_arena[command_index];
        if (ack_matches(ack, command)) {
            matched = true;
            matched_bit |= adapter_ack_bit(command.action);
        }
    }
    if (!matched) { error = "effect_pod_ack_command_mismatch"; return false; }
    transaction.last_ack_code = static_cast<uint16_t>(ack.code);
    if (ack.code == RuntimeDomainAckCode::OK) {
        if ((transaction.received_ack_mask & matched_bit) != 0u) {
            ++transaction.duplicate_ack_count;
            _current.deterministic_state_hash = state_hash(_current);
            build_snapshot(_current, _snapshot);
            rebuild_report();
            return true;
        }
        transaction.received_ack_mask |= matched_bit;
        if ((transaction.received_ack_mask & transaction.required_ack_mask) ==
                transaction.required_ack_mask) {
            transaction.status = RuntimeEffectPodTransactionStatus::ACKED;
            const int32_t instance_index_value = instance_index(
                transaction.source_instance_id, transaction.source_generation);
            if (instance_index_value >= 0) {
                auto &instance = _current.instances[static_cast<size_t>(instance_index_value)];
                instance.pending_transaction_id = 0;
                instance.pending_idempotency_key = 0;
                instance.last_acked_fire_sequence = transaction.fire_sequence;
                const auto &definition = _catalog.definitions[
                    static_cast<size_t>(instance.program_id)];
                const bool retirement =
                    transaction.transition_stack_count == 0;
                if (definition.managed != 0 && retirement) {
                    instance.effect_applied = 0;
                    instance.applied_input_revision = 0;
                    instance.applied_stack_count = 0;
                    if (instance.retire_requested) {
                        instance.active = 0;
                        instance.retire_requested = 0;
                    }
                } else if (definition.managed != 0) {
                    instance.effect_applied = 1;
                    instance.applied_input_revision =
                        std::max(instance.applied_input_revision,
                                 transaction.input_revision);
                    instance.applied_stack_count = std::max(
                        1, transaction.transition_stack_count);
                } else {
                    // Unmanaged programs keep their historical bookkeeping.
                    instance.applied_stack_count = instance.stack_count;
                    if (instance.retire_requested) instance.active = 0;
                }
            }
        }
    } else if (ack.code == RuntimeDomainAckCode::RETRY) {
        transaction.status = RuntimeEffectPodTransactionStatus::PLANNED;
        ++transaction.retry_count;
    } else if (ack.code == RuntimeDomainAckCode::REJECTED) {
        transaction.status = RuntimeEffectPodTransactionStatus::REJECTED;
        const int32_t instance_index_value = instance_index(
            transaction.source_instance_id, transaction.source_generation);
        if (instance_index_value >= 0)
            _current.instances[static_cast<size_t>(instance_index_value)].pending_transaction_id = 0;
    } else if (ack.code == RuntimeDomainAckCode::STALE_GENERATION) {
        transaction.status = RuntimeEffectPodTransactionStatus::RESYNC_REQUIRED;
        const int32_t instance_index_value = instance_index(
            transaction.source_instance_id, transaction.source_generation);
        if (instance_index_value >= 0)
            _current.instances[static_cast<size_t>(instance_index_value)].needs_resync = 1;
    }
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return true;
}

bool RuntimeEffectPodAuthority::apply_acks(
        const std::vector<RuntimeDomainAck> &acks, std::string &error) {
    for (const auto &ack : acks) {
        if (!apply_ack(ack, error)) return false;
    }
    return true;
}

bool RuntimeEffectPodAuthority::snapshot(RuntimeEffectPodSnapshot &out,
                                         std::string &error) const {
    error.clear();
    if (!_configured) { error = "effect_pod_not_configured"; return false; }
    out = _snapshot;
    return true;
}
