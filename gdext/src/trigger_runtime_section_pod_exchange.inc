bool TriggerRuntime::export_pod_catalog(RuntimeTriggerPodCatalog &out,
                                        std::string &error) const {
    error.clear();
    if (!_configured) { error = "trigger_runtime_not_configured"; return false; }
    out = RuntimeTriggerPodCatalog{};
    out.catalog_hash = _catalog_hash;
    out.max_states = _max_states;
    out.max_pending_events = _max_pending_events;
    out.distinct_capacity = _distinct_capacity;
    out.source_count = _source_count;
    out.event_type_span = _event_type_span;
    out.strict_source_cursors = _strict_source_cursors ? 1 : 0;
    out.condition_ops = _condition_ops;
    out.definitions.reserve(_definitions.size());
    for (const Definition &source : _definitions) {
        RuntimeTriggerDefinition definition;
        definition.key_hash = fnv_string(1469598103934665603ull, source.key);
        definition.version = source.version;
        definition.source_id = source.source_id;
        definition.event_type = source.event_type;
        definition.payload_schema = source.payload_schema;
        definition.aggregator = source.aggregator;
        definition.value_field = source.value_field;
        definition.distinct_field = source.distinct_field;
        definition.scope = source.scope;
        definition.target_resolver = source.target_resolver;
        definition.static_target = source.static_target;
        definition.threshold = source.threshold;
        definition.mode = source.mode;
        definition.cooldown_days = source.cooldown_days;
        definition.window_days = source.window_days;
        definition.qualifier_threshold = source.qualifier_threshold;
        definition.duration_field = source.duration_field;
        definition.development_metric_id = source.development_metric_id;
        definition.development_era_index = source.development_era_index;
        definition.condition_begin = source.condition_begin;
        definition.condition_count = source.condition_count;
        definition.effect_begin = source.effect_begin;
        definition.effect_count = source.effect_count;
        definition.selector_field = source.selector_field;
        definition.selector_value = source.selector_value;
        definition.enabled = source.enabled;
        definition.dynamic_binding = source.dynamic_binding;
        definition.selector_negated = source.selector_negated;
        out.definitions.push_back(definition);
    }
    out.effects.reserve(_effect_definitions.size());
    for (const EffectDefinition &source : _effect_definitions) {
        RuntimeTriggerEffectDefinition effect;
        effect.action = source.action;
        effect.source_priority = source.source_priority;
        effect.domain = source.domain;
        effect.opcode = source.opcode;
        effect.target_resolver = source.target_resolver;
        effect.static_target = source.static_target;
        effect.value_mode = source.value_mode;
        effect.value = source.value;
        effect.duration_days = source.duration_days;
        effect.stacks = source.stacks;
        effect.payload = source.payload;
        out.effects.push_back(effect);
    }
    return true;
}

bool TriggerRuntime::export_pod_snapshot(RuntimeTriggerSnapshot &out,
                                         std::string &error) const {
    error.clear();
    if (!_configured) { error = "trigger_runtime_not_configured"; return false; }
    out = RuntimeTriggerSnapshot{};
    out.generation = 0;
    out.catalog_hash = _catalog_hash;
    out.committed_day = _current_day;
    out.current_day = _current_day;
    out.next_effect_id = _next_effect_id;
    out.acked_effect_id = _acked_effect_id;
    out.source_cursor = _source_cursor;
    out.source_needs_resync = _source_needs_resync;
    out.source_gap_begin = _source_gap_begin;
    out.source_gap_end = _source_gap_end;
    out.enabled.reserve(_definitions.size());
    for (const Definition &definition : _definitions) out.enabled.push_back(definition.enabled);
    out.states.reserve(_state_count);
    for (int32_t i = 0; i < _state_count; ++i) {
        RuntimeTriggerPodSnapshotState state;
        state.trigger_id = _state.trigger_id[i];
        state.target_handle = _state.target_handle[i];
        state.target_generation = _state.target_generation[i];
        state.accumulator = _state.accumulator[i];
        state.remainder = _state.remainder[i];
        state.last_event_id = _state.last_event_id[i];
        state.fire_sequence = _state.fire_sequence[i];
        state.cooldown_until = _state.cooldown_until[i];
        state.window_start_day = _state.window_start_day[i];
        state.last_observed = _state.last_observed[i];
        state.last_sample_day = _state.last_sample_day[i];
        state.completed = _state.completed[i];
        state.initialized = _state.initialized[i];
        state.needs_resync = _state.needs_resync[i];
        const size_t begin = static_cast<size_t>(i) * _distinct_capacity;
        state.distinct_keys.assign(_distinct_keys.begin() + begin,
                                   _distinct_keys.begin() + begin + _distinct_capacity);
        out.states.push_back(std::move(state));
    }
    for (const BranchBinding &binding : _branch_bindings) {
        out.branch_bindings.push_back({binding.trigger_id, binding.branch_handle,
            binding.cell, binding.reward_target, 1});
    }
    out.pending_events.reserve(_pending_events.size());
    for (const Event &source : _pending_events) {
        RuntimeTriggerEvent event;
        event.source_id = source.source_id; event.event_id = source.event_id;
        event.day = source.day; event.event_type = source.event_type;
        event.payload_schema = source.payload_schema; event.entity_handle = source.entity_handle;
        event.group_handle = source.group_handle; event.value = source.value;
        event.payload = source.payload; event.snapshot = source.snapshot ? 1 : 0;
        out.pending_events.push_back(event);
    }
    out.pending_effects.reserve(_effects.size());
    for (const Effect &source : _effects) {
        RuntimeTriggerEffectIntent effect;
        effect.id = source.id; effect.effective_day = source.effective_day;
        effect.source_priority = source.source_priority; effect.trigger_id = source.trigger_id;
        effect.effect_definition_id = source.effect_definition_id;
        effect.target_handle = source.target_handle; effect.target_generation = source.target_generation;
        effect.fire_sequence = source.fire_sequence; effect.action = source.action;
        effect.domain = source.domain; effect.opcode = source.opcode;
        effect.resolved_value = source.resolved_value; effect.duration_days = source.duration_days;
        effect.stacks = source.stacks; effect.payload = source.payload;
        out.pending_effects.push_back(effect);
    }
    return true;
}

bool TriggerRuntime::adopt_pod_state(const RuntimeTriggerSnapshot &snapshot,
                                     int64_t day_index, std::string &error) {
    error.clear();
    for (const RuntimeTriggerPodSnapshotState &source : snapshot.states) {
        if (source.trigger_id < 0 ||
            source.trigger_id >= static_cast<int32_t>(_definitions.size()) ||
            source.distinct_keys.size() != static_cast<size_t>(_distinct_capacity)) {
            error = "trigger_state_restore_failed";
            return false;
        }
    }
    for (const RuntimeTriggerBranchBinding &source : snapshot.branch_bindings) {
        if (source.trigger_id < 0 ||
            source.trigger_id >= static_cast<int32_t>(_definitions.size())) {
            error = "trigger_branch_binding_restore_failed";
            return false;
        }
    }
    const uint64_t events_ingested = _events_ingested;
    const uint64_t events_deduplicated = _events_deduplicated;
    const uint64_t events_rejected = _events_rejected;
    const uint64_t effects_emitted = _effects_emitted;
    const uint64_t rules_evaluated = _rules_evaluated;
    const uint64_t gap_count = _gap_count;
    const uint64_t resync_count = _resync_count;
    // Effect delivery stays a main-thread cursor even under H8 authority: the
    // facade hands the contiguous prefix to EffectRuntime and ACKs it back to the
    // worker as an ACK_EFFECTS command. Clamping instead of overwriting keeps a
    // write-back that predates that command from replaying an already delivered
    // effect.
    const int64_t acked_effect_id = _acked_effect_id;
    const int64_t next_effect_id = _next_effect_id;
    reset_runtime_state();
    _branch_bindings.clear();
    _current_day = day_index;
    _next_effect_id = std::max(next_effect_id, snapshot.next_effect_id);
    _acked_effect_id = std::max(acked_effect_id, snapshot.acked_effect_id);
    _source_cursor = snapshot.source_cursor;
    _source_needs_resync = snapshot.source_needs_resync;
    _source_gap_begin = snapshot.source_gap_begin;
    _source_gap_end = snapshot.source_gap_end;
    for (size_t i = 0; i < snapshot.enabled.size() &&
                       i < _definitions.size(); ++i)
        _definitions[i].enabled = snapshot.enabled[i] != 0 ? 1 : 0;
    for (const RuntimeTriggerBranchBinding &source : snapshot.branch_bindings) {
        _branch_bindings.push_back({source.trigger_id, source.branch_handle,
                                    source.cell, source.reward_target});
    }
    rebuild_branch_index();
    for (const RuntimeTriggerPodSnapshotState &source : snapshot.states) {
        const int32_t index = find_or_create_state(source.trigger_id,
            source.target_handle, source.target_generation);
        if (index < 0) { error = "trigger_state_restore_failed"; return false; }
        _state.accumulator[index] = source.accumulator;
        _state.remainder[index] = source.remainder;
        _state.last_event_id[index] = source.last_event_id;
        _state.fire_sequence[index] = source.fire_sequence;
        _state.cooldown_until[index] = source.cooldown_until;
        _state.window_start_day[index] = source.window_start_day;
        _state.last_observed[index] = source.last_observed;
        _state.last_sample_day[index] = source.last_sample_day;
        _state.completed[index] = source.completed;
        _state.initialized[index] = source.initialized;
        _state.needs_resync[index] = source.needs_resync;
        const size_t begin = static_cast<size_t>(index) * _distinct_capacity;
        std::copy(source.distinct_keys.begin(), source.distinct_keys.end(),
                  _distinct_keys.begin() + begin);
    }
    for (const RuntimeTriggerEvent &source : snapshot.pending_events) {
        Event event;
        event.source_id = source.source_id; event.event_id = source.event_id;
        event.day = source.day; event.event_type = source.event_type;
        event.payload_schema = source.payload_schema;
        event.entity_handle = source.entity_handle;
        event.group_handle = source.group_handle;
        event.value = source.value; event.payload = source.payload;
        event.snapshot = source.snapshot != 0;
        _pending_events.push_back(event);
    }
    for (const RuntimeTriggerEffectIntent &source : snapshot.pending_effects) {
        Effect effect;
        effect.id = source.id; effect.effective_day = source.effective_day;
        effect.source_priority = source.source_priority;
        effect.trigger_id = source.trigger_id;
        effect.effect_definition_id = source.effect_definition_id;
        effect.target_handle = source.target_handle;
        effect.target_generation = source.target_generation;
        effect.fire_sequence = source.fire_sequence; effect.action = source.action;
        effect.domain = source.domain; effect.opcode = source.opcode;
        effect.resolved_value = source.resolved_value;
        effect.duration_days = source.duration_days; effect.stacks = source.stacks;
        effect.payload = source.payload;
        if (source.effect_definition_id >= 0 &&
            source.effect_definition_id < static_cast<int32_t>(_effect_definitions.size())) {
            const EffectDefinition &definition = _effect_definitions[source.effect_definition_id];
            effect.command_key = definition.command_key;
            effect.definition_key = definition.definition_key;
        }
        _effects.push_back(std::move(effect));
    }
    _events_ingested = events_ingested;
    _events_deduplicated = events_deduplicated;
    _events_rejected = events_rejected;
    _effects_emitted = effects_emitted;
    _rules_evaluated = rules_evaluated;
    _gap_count = gap_count;
    _resync_count = resync_count;
    return true;
}

bool TriggerRuntime::apply_pod_snapshot(const RuntimeTriggerSnapshot &snapshot,
                                        std::string &error) {
    error.clear();
    if (!_configured) { error = "trigger_runtime_not_configured"; return false; }
    if (snapshot.catalog_hash != _catalog_hash) {
        error = "trigger_snapshot_catalog_mismatch";
        return false;
    }
    // Generation gate. The ring hands out the newest READY buffer, so a caller
    // that polls twice in one frame — or after a worker restart replayed an
    // older generation — must not walk the facade backwards.
    if (snapshot.generation <= _pod_snapshot_generation) {
        error = "trigger_snapshot_generation_stale";
        return false;
    }
    const int64_t day = snapshot.committed_day >= 0
        ? snapshot.committed_day : _current_day;
    if (!adopt_pod_state(snapshot, day, error)) return false;
    _pod_snapshot_generation = snapshot.generation;
    return true;
}

uint64_t TriggerRuntime::pod_state_hash() const {
    RuntimeTriggerSnapshot snapshot;
    std::string error;
    return export_pod_snapshot(snapshot, error)
        ? RuntimeTriggerPodAuthority::canonical_state_hash(snapshot) : 0;
}

uint64_t TriggerRuntime::pod_effect_hash() const {
    RuntimeTriggerSnapshot snapshot;
    std::string error;
    return export_pod_snapshot(snapshot, error)
        ? RuntimeTriggerPodAuthority::canonical_effect_hash(snapshot.pending_effects) : 0;
}
