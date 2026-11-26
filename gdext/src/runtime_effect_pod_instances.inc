bool RuntimeEffectPodAuthority::upsert_instance(
        const RuntimeEffectPodInstanceInput &input, std::string &error) {
    error.clear();
    if (!validate_instance(input, error)) return false;
    const auto &definition = _catalog.definitions[static_cast<size_t>(input.program_id)];
    int32_t index = -1;
    for (size_t i = 0; i < _current.instances.size(); ++i) {
        if (_current.instances[i].instance_id == input.instance_id) {
            index = static_cast<int32_t>(i);
            break;
        }
    }
    if (index < 0) {
        if (_current.instances.size() >= _instance_capacity) {
            error = "effect_pod_instance_capacity_exhausted";
            return false;
        }
        index = static_cast<int32_t>(_current.instances.size());
        _current.instances.emplace_back();
        _current.metric_values.resize(
            (static_cast<size_t>(index) + 1u) * _catalog.metric_key_hashes.size());
        _current.metric_revisions.resize(
            (static_cast<size_t>(index) + 1u) * _catalog.metric_key_hashes.size());
    }
    RuntimeEffectPodInstance &instance = _current.instances[static_cast<size_t>(index)];
    const uint32_t metric_base = static_cast<uint32_t>(
        static_cast<size_t>(index) * _catalog.metric_key_hashes.size());
    // Re-ENSURE from Country soft-skip must not wipe an in-flight fire ACK
    // sequence. Preserve fire / ack / pending transaction identity when the
    // same (instance_id, generation) is upserted again.
    const bool same_identity =
        instance.instance_id == input.instance_id &&
        instance.generation == input.generation;
    // A managed level/location transition advances the generation while the
    // downstream Modifier row still belongs to this instance identity. Losing
    // effect_applied or an in-flight transaction here would make a later
    // condition-false evaluation look "never applied", so no REMOVE is emitted
    // and the old tier stays live. Carry the lifecycle across that replacement;
    // the next true evaluation is forced to re-fire the new generation.
    const bool managed_replacement =
        same_identity == false &&
        instance.instance_id == input.instance_id &&
        definition.managed != 0 &&
        (instance.effect_applied != 0 ||
         instance.pending_transaction_id != 0);
    const bool carry_lifecycle = same_identity || managed_replacement;
    const uint64_t keep_fire =
        carry_lifecycle ? instance.fire_sequence : 0;
    const uint64_t keep_acked =
        carry_lifecycle ? instance.last_acked_fire_sequence : 0;
    const int64_t keep_pending_tx =
        carry_lifecycle ? instance.pending_transaction_id : 0;
    const uint64_t keep_pending_key =
        carry_lifecycle ? instance.pending_idempotency_key : 0;
    const int64_t keep_revision = instance.input_revision;
    const uint8_t keep_effect_applied =
        carry_lifecycle ? instance.effect_applied : 0;
    const int64_t keep_applied_revision =
        carry_lifecycle ? instance.applied_input_revision : 0;
    // The old generation's APPLY may still be the row that exists downstream.
    // Keep effect_applied so a false condition can remove it. A replacement
    // forces the next evaluation through needs_resync, which re-fires the new
    // tier without leaving an effect_applied=1 / applied_stack_count=0 wire
    // pair that restore() would reject.
    const int32_t keep_applied_stack_count =
        carry_lifecycle ? instance.applied_stack_count : 0;
    const bool level_changed = same_identity && instance.level != input.level;
    const uint8_t keep_needs_resync = (managed_replacement ||
        (level_changed && definition.managed != 0 && instance.effect_applied != 0))
        ? 1 : (same_identity ? instance.needs_resync : 0);
    const int64_t keep_evaluated_revision =
        same_identity && !level_changed ? instance.last_evaluated_input_revision : 0;
    // A re-ENSURE can race an explicit remove. Keep the retire request when it
    // belongs to an instance that has already applied (or has an in-flight
    // APPLY); the trailing ENSURE must not erase the only record that the row
    // still needs a REMOVE. A never-applied tombstone may still be reinstalled,
    // which is the recoverable retire/upsert ordering used by the transport.
    // The same applies when a level transition replaces the generation while a
    // REMOVE is pending.
    const uint8_t keep_retire_requested =
        carry_lifecycle && (instance.effect_applied != 0 ||
                            instance.pending_transaction_id != 0)
            ? instance.retire_requested
            : 0;
    // The latch belongs to whoever is evaluating. A same-identity re-ENSURE
    // (Country soft-skip) must not wipe it; a new generation is a new card tier
    // and starts the band over, so it takes the wire value.
    const uint8_t keep_latched = same_identity ? instance.latched : input.latched;
    instance = RuntimeEffectPodInstance{};
    instance.instance_id = input.instance_id;
    instance.generation = input.generation;
    instance.program_id = input.program_id;
    instance.source_type = input.source_type;
    instance.source_id = input.source_id;
    instance.source_handle = input.source_handle;
    instance.target_handle = input.target_handle;
    instance.target_generation = input.target_generation;
    instance.level = input.level;
    instance.magnitude_scale_q16 = input.magnitude_scale_q16;
    instance.latched = keep_latched;
    instance.metric_base = metric_base;
    instance.input_revision = keep_revision;
    instance.last_evaluated_input_revision = keep_evaluated_revision;
    instance.next_due_day = input.next_due_day;
    instance.expires_day = input.expires_day;
    instance.cadence_days = definition.cadence_days;
    instance.lifecycle = definition.lifecycle;
    instance.stack_policy = definition.stack_policy;
    instance.max_stacks = definition.max_stacks;
    instance.stack_key_hash = definition.stack_key_hash;
    instance.active = input.active ? 1 : 0;
    instance.fire_sequence = keep_fire;
    instance.effect_applied = keep_effect_applied;
    instance.applied_input_revision = keep_applied_revision;
    instance.applied_stack_count = keep_applied_stack_count;
    instance.needs_resync = keep_needs_resync;
    instance.last_acked_fire_sequence = keep_acked;
    instance.pending_transaction_id = keep_pending_tx;
    instance.pending_idempotency_key = keep_pending_key;
    instance.retire_requested = keep_retire_requested;
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return true;
}

bool RuntimeEffectPodAuthority::remove_instance(int64_t instance_id,
                                                uint32_t generation,
                                                std::string &error) {
    error.clear();
    const int32_t index = instance_index(instance_id, generation);
    if (index < 0) { error = "effect_pod_instance_stale_generation"; return false; }
    auto &instance = _current.instances[static_cast<size_t>(index)];
    const auto &definition =
        _catalog.definitions[static_cast<size_t>(instance.program_id)];
    // An explicit retire must undo what the instance actually applied. Let the
    // next plan emit a REMOVE transaction; planning handles inactive tombstones
    // while their pending transaction is live, and the ACK clears lifecycle
    // state. Unmanaged instances keep the old immediate tombstone behaviour.
    if (definition.managed != 0 &&
        (instance.effect_applied != 0 ||
         instance.pending_transaction_id != 0)) {
        instance.retire_requested = 1;
        _current.deterministic_state_hash = state_hash(_current);
        build_snapshot(_current, _snapshot);
        rebuild_report();
        return true;
    }
    instance.active = 0;
    instance.retire_requested = 1;
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return true;
}

bool RuntimeEffectPodAuthority::set_metric(int64_t instance_id, uint32_t generation,
                                           int32_t metric_id, int64_t revision,
                                           int64_t value, std::string &error) {
    error.clear();
    const int32_t index = instance_index(instance_id, generation);
    if (index < 0) { error = "effect_pod_metric_stale_generation"; return false; }
    if (metric_id < 0 || metric_id >= static_cast<int32_t>(_catalog.metric_key_hashes.size()) ||
        revision < 0) {
        error = "effect_pod_metric_invalid";
        return false;
    }
    auto &instance = _current.instances[static_cast<size_t>(index)];
    const size_t offset = static_cast<size_t>(instance.metric_base) +
        static_cast<size_t>(metric_id);
    if (offset >= _current.metric_values.size()) {
        error = "effect_pod_metric_slab_invalid";
        return false;
    }
    if (revision < _current.metric_revisions[offset]) return true;
    // `metric_revisions` is the per-column CHANGE watermark, not "highest
    // revision seen": it feeds deterministic_state_hash and the EFP1 payload,
    // so advancing it for an unchanged value would republish the snapshot and
    // read downstream as a real input change. Revision 0 means "never
    // observed" -- every producer starts at day * 4 + 1.
    if (_current.metric_revisions[offset] != 0 &&
            _current.metric_values[offset] == value)
        return true;
    _current.metric_revisions[offset] = revision;
    _current.metric_values[offset] = value;
    instance.input_revision = std::max(instance.input_revision, revision);
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return true;
}

uint32_t RuntimeEffectPodAuthority::reschedule_unfired_due_instances(
        int64_t committed_day) {
    if (!_configured || committed_day < 0 || _plan_ready) return 0;
    const int64_t next_day = committed_day + 1;
    uint32_t nudged = 0;
    for (auto &instance : _current.instances) {
        if (instance.active == 0 || instance.fire_sequence != 0) continue;
        if (instance.next_due_day < 0) continue;
        // Never-fired instances must land on the next sequential plan day.
        // They may sit on the already-closed committed day (late ENSURE) or
        // far in the future after a cadence-days failure backoff (technology
        // programs author cadence_days=3650).
        if (instance.next_due_day == next_day) continue;
        instance.next_due_day = next_day;
        ++nudged;
    }
    if (nudged == 0) return 0;
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return nudged;
}

uint32_t RuntimeEffectPodAuthority::catchup_fire_never_fired_instances(
        int64_t fire_day, std::vector<RuntimeDomainIntent> &out_intents,
        std::string &error) {
    error.clear();
    if (!_configured || fire_day < 0 || _plan_ready) return 0;
    // Only catch up the immediate next Effect day. Firing further ahead would
    // desync committed_day sequencing for the real plan_day lane.
    if (_current.committed_day < 0 || fire_day != _current.committed_day + 1)
        return 0;
    uint32_t fired = 0;
    std::vector<RuntimeEffectPodCommand> emitted;
    emitted.reserve(16);
    for (size_t instance_index_value = 0;
         instance_index_value < _current.instances.size(); ++instance_index_value) {
        RuntimeEffectPodInstance &instance =
            _current.instances[instance_index_value];
        if (instance.active == 0 || instance.fire_sequence != 0) continue;
        if (instance.pending_transaction_id != 0) continue;
        if (instance.next_due_day < 0 || instance.next_due_day > fire_day)
            continue;
        if (instance.program_id < 0 ||
            instance.program_id >= static_cast<int32_t>(_catalog.definitions.size())) {
            error = "effect_pod_program_invalid";
            return fired;
        }
        const auto &definition =
            _catalog.definitions[static_cast<size_t>(instance.program_id)];
        if (definition.enabled == 0) {
            instance.next_due_day = fire_day + 1;
            continue;
        }
        if (instance.retire_requested != 0) {
            if (definition.managed == 0) {
                instance.active = 0;
                instance.retire_requested = 0;
                continue;
            }
            // A never-applied instance has no downstream row to remove, even
            // though its reference object may carry an unresolved command.
            // Retire the row now so a later ENSURE cannot resurrect it.
            if (instance.effect_applied == 0) {
                instance.active = 0;
                instance.retire_requested = 0;
                instance.next_due_day = fire_day + 1;
                continue;
            }
            RuntimeEffectPodTransaction transaction;
            if (!append_retirement_transaction(
                    _current, definition, instance, fire_day, emitted,
                    transaction, error)) {
                return fired;
            }
            _current.transactions.back().status =
                RuntimeEffectPodTransactionStatus::COMMITTED;
            append_transaction_intents(_current, definition, instance,
                                       transaction, out_intents);
            ++fired;
            continue;
        }
        const ManagedLifecycleDecision decision = evaluate_managed_lifecycle(
            definition, instance, _current, fire_day);
        if (decision == ManagedLifecycleDecision::RETIRE) {
            RuntimeEffectPodTransaction transaction;
            if (!append_retirement_transaction(
                    _current, definition, instance, fire_day, emitted,
                    transaction, error)) {
                return fired;
            }
            _current.transactions.back().status =
                RuntimeEffectPodTransactionStatus::COMMITTED;
            append_transaction_intents(_current, definition, instance,
                                       transaction, out_intents);
            ++fired;
            continue;
        }
        if (decision == ManagedLifecycleDecision::IDLE) {
            instance.last_evaluated_input_revision = instance.input_revision;
            instance.next_due_day = fire_day + 1;
            continue;
        }
        emitted.clear();
        if (!execute_program(definition, instance, _current, fire_day, emitted,
                             error)) {
            return fired;
        }
        if (emitted.empty()) {
            instance.last_evaluated_input_revision = instance.input_revision;
            if (definition.command_count > 0) {
                instance.next_due_day = fire_day + 1;
                continue;
            }
            instance.fire_sequence += 1u;
            instance.next_due_day =
                fire_day + std::max<int32_t>(1, definition.cadence_days);
            ++fired;
            continue;
        }
        RuntimeEffectPodTransaction transaction;
        if (!schedule_application(_current, definition, instance, fire_day,
                                  emitted, transaction, error)) {
            return fired;
        }
        // Mirror commit_day: catch-up emits are already live on _current.
        _current.transactions.back().status =
            RuntimeEffectPodTransactionStatus::COMMITTED;
        append_transaction_intents(_current, definition, instance,
                                   transaction, out_intents);
        ++fired;
    }
    if (fired == 0) return 0;
    _current.generation += 1u;
    _current.deterministic_state_hash = state_hash(_current);
    build_snapshot(_current, _snapshot);
    rebuild_report();
    return fired;
}
