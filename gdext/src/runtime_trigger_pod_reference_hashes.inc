uint64_t RuntimeTriggerPodAuthority::hash_snapshot_impl(
        const RuntimeTriggerSnapshot &snapshot) {
    uint64_t hash = FNV_OFFSET;
    hash = mix_value(hash, snapshot.generation);
    hash = mix_value(hash, snapshot.catalog_hash);
    hash = mix_value(hash, snapshot.committed_day);
    hash = mix_value(hash, snapshot.current_day);
    hash = mix_value(hash, snapshot.next_effect_id);
    hash = mix_value(hash, snapshot.acked_effect_id);
    for (const int64_t value : snapshot.source_cursor) hash = mix_value(hash, value);
    for (const uint8_t value : snapshot.source_needs_resync) hash = mix_value(hash, value);
    for (const int64_t value : snapshot.source_gap_begin) hash = mix_value(hash, value);
    for (const int64_t value : snapshot.source_gap_end) hash = mix_value(hash, value);
    for (const uint8_t value : snapshot.enabled) hash = mix_value(hash, value);
    for (const RuntimeTriggerPodSnapshotState &state : snapshot.states) {
        hash = mix_value(hash, state.trigger_id);
        hash = mix_value(hash, state.target_handle);
        hash = mix_value(hash, state.target_generation);
        hash = mix_value(hash, state.accumulator);
        hash = mix_value(hash, state.remainder);
        hash = mix_value(hash, state.last_event_id);
        hash = mix_value(hash, state.fire_sequence);
        hash = mix_value(hash, state.cooldown_until);
        hash = mix_value(hash, state.window_start_day);
        hash = mix_value(hash, state.last_observed);
        hash = mix_value(hash, state.last_sample_day);
        hash = mix_value(hash, state.completed);
        hash = mix_value(hash, state.initialized);
        hash = mix_value(hash, state.needs_resync);
        for (const int64_t key : state.distinct_keys) hash = mix_value(hash, key);
    }
    for (const RuntimeTriggerBranchBinding &binding : snapshot.branch_bindings) {
        hash = mix_value(hash, binding.trigger_id); hash = mix_value(hash, binding.branch_handle);
        hash = mix_value(hash, binding.cell); hash = mix_value(hash, binding.reward_target);
        hash = mix_value(hash, binding.enabled);
    }
    for (const RuntimeTriggerEvent &event : snapshot.pending_events) {
        hash = mix_value(hash, event.source_id); hash = mix_value(hash, event.event_id);
        hash = mix_value(hash, event.day); hash = mix_value(hash, event.event_type);
        hash = mix_value(hash, event.payload_schema); hash = mix_value(hash, event.entity_handle);
        hash = mix_value(hash, event.group_handle); hash = mix_value(hash, event.value);
        for (const int64_t value : event.payload) hash = mix_value(hash, value);
        hash = mix_value(hash, event.snapshot);
    }
    for (const RuntimeTriggerEffectIntent &effect : snapshot.pending_effects) {
        hash = mix_value(hash, effect.id); hash = mix_value(hash, effect.effective_day);
        hash = mix_value(hash, effect.source_priority); hash = mix_value(hash, effect.trigger_id);
        hash = mix_value(hash, effect.effect_definition_id); hash = mix_value(hash, effect.target_handle);
        hash = mix_value(hash, effect.target_generation); hash = mix_value(hash, effect.fire_sequence);
        hash = mix_value(hash, effect.action); hash = mix_value(hash, effect.domain);
        hash = mix_value(hash, effect.opcode); hash = mix_value(hash, effect.resolved_value);
        hash = mix_value(hash, effect.duration_days); hash = mix_value(hash, effect.stacks);
        for (const int64_t value : effect.payload) hash = mix_value(hash, value);
    }
    return hash;
}

uint64_t RuntimeTriggerPodAuthority::hash_snapshot(
        const RuntimeTriggerSnapshot &snapshot) {
    if (is_snapshot_canonical(snapshot)) {
        return hash_snapshot_impl(snapshot);
    }
    return hash_snapshot_impl(canonicalize_snapshot(snapshot, true));
}

uint64_t RuntimeTriggerPodAuthority::hash_effects(
        const std::vector<RuntimeTriggerEffectIntent> &effects) {
    return canonical_effect_hash(effects);
}

uint64_t RuntimeTriggerPodAuthority::canonical_state_hash(
        const RuntimeTriggerSnapshot &snapshot) {
    // Generation is a worker transaction detail. The facade exports zero
    // because it has no corresponding POD commit generation; excluding it
    // makes the reference and worker hashes describe the same semantic state.
    if (is_snapshot_canonical(snapshot)) {
        if (snapshot.generation == 0) {
            return hash_snapshot_impl(snapshot);
        }
        RuntimeTriggerSnapshot &mutable_ref =
            const_cast<RuntimeTriggerSnapshot &>(snapshot);
        const uint64_t saved_gen = mutable_ref.generation;
        mutable_ref.generation = 0;
        const uint64_t result = hash_snapshot_impl(mutable_ref);
        mutable_ref.generation = saved_gen;
        return result;
    }
    return hash_snapshot_impl(canonicalize_snapshot(snapshot, false));
}

uint64_t RuntimeTriggerPodAuthority::canonical_effect_hash(
        const std::vector<RuntimeTriggerEffectIntent> &effects) {
    std::vector<RuntimeTriggerEffectIntent> ordered = effects;
    std::stable_sort(ordered.begin(), ordered.end(), effect_less);
    uint64_t hash = FNV_OFFSET;
    hash = mix_value(hash, static_cast<uint64_t>(ordered.size()));
    for (const RuntimeTriggerEffectIntent &effect : ordered) {
        hash = mix_value(hash, effect.id);
        hash = mix_value(hash, effect.effective_day);
        hash = mix_value(hash, effect.source_priority);
        hash = mix_value(hash, effect.trigger_id);
        hash = mix_value(hash, effect.effect_definition_id);
        hash = mix_value(hash, effect.target_handle);
        hash = mix_value(hash, effect.target_generation);
        hash = mix_value(hash, effect.fire_sequence);
        hash = mix_value(hash, effect.action);
        hash = mix_value(hash, effect.domain);
        hash = mix_value(hash, effect.opcode);
        hash = mix_value(hash, effect.resolved_value);
        hash = mix_value(hash, effect.duration_days);
        hash = mix_value(hash, effect.stacks);
        for (const int64_t value : effect.payload) hash = mix_value(hash, value);
    }
    return hash;
}

bool RuntimeTriggerPodAuthority::compare_reference_frame() {
    if (!_reference_pending) return false;
    _diagnostics.reference_day = _reference_day;
    _diagnostics.reference_input_hash = _reference_input_hash;
    _diagnostics.reference_state_hash = _reference_state_hash;
    _diagnostics.reference_effect_hash = _reference_effect_hash;
    if (_state.committed_day != _reference_day) {
        _diagnostics.parity_compared = 0;
        _diagnostics.parity_matched = 0;
        copy_reason(_diagnostics.blocker, _state.committed_day < _reference_day
            ? "trigger_reference_pending" : "trigger_reference_stale");
        return false;
    }
    _diagnostics.parity_compared = 1;
    _diagnostics.parity_matched =
        _reference_state_hash == canonical_state_hash(_state) &&
        _reference_effect_hash == canonical_effect_hash(_state.pending_effects);
    _diagnostics.first_divergence_index = _diagnostics.parity_matched ? -1 : 0;
    copy_reason32(_diagnostics.first_divergence_kind,
                  _diagnostics.parity_matched ? "" : "hash");
    copy_reason(_diagnostics.blocker,
                _diagnostics.parity_matched ? "" : "trigger_parity_mismatch");
    _reference_pending = false;
    return true;
}

bool RuntimeTriggerPodAuthority::set_reference_frame(
        int64_t day, uint64_t input_hash, uint64_t state_hash,
        uint64_t effect_hash, std::string &error) {
    error.clear();
    if (!_bootstrapped) { error = "trigger_pod_not_bootstrapped"; return false; }
    if (day < 0 || input_hash == 0 || state_hash == 0 || effect_hash == 0) {
        error = "trigger_reference_invalid";
        return false;
    }
    _reference_pending = true;
    _reference_day = day;
    _reference_input_hash = input_hash;
    _reference_state_hash = state_hash;
    _reference_effect_hash = effect_hash;
    _diagnostics.day = day;
    _diagnostics.input_hash = input_hash;
    compare_reference_frame();
    return true;
}
