Dictionary TriggerRuntime::report() const {
    Dictionary out;
    out["configured"] = _configured;
    out["protocol_version"] = PROTOCOL_VERSION;
    out["save_schema_version"] = SAVE_SCHEMA_VERSION;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    out["current_day"] = _current_day;
    out["definition_count"] = static_cast<int64_t>(_definitions.size());
    out["effect_definition_count"] = static_cast<int64_t>(_effect_definitions.size());
    out["branch_binding_count"] = static_cast<int64_t>(_branch_bindings.size());
    out["state_count"] = _state_count;
    out["state_capacity"] = _max_states;
    out["pending_events"] = static_cast<int64_t>(_pending_events.size());
    out["pending_effects"] = static_cast<int64_t>(_effects.size());
    out["events_ingested"] = static_cast<int64_t>(_events_ingested);
    out["events_deduplicated"] = static_cast<int64_t>(_events_deduplicated);
    out["events_rejected"] = static_cast<int64_t>(_events_rejected);
    out["rules_evaluated"] = static_cast<int64_t>(_rules_evaluated);
    out["effects_emitted"] = static_cast<int64_t>(_effects_emitted);
    out["gap_count"] = static_cast<int64_t>(_gap_count);
    out["resync_count"] = static_cast<int64_t>(_resync_count);
    out["last_ingest_ms"] = _last_ingest_ms;
    out["last_evaluate_ms"] = _last_evaluate_ms;
    out["last_error"] = String(_last_error.c_str());
    PackedInt64Array cursors;
    PackedInt64Array gap_begin;
    PackedInt64Array gap_end;
    PackedByteArray gaps;
    for (int32_t source = 0; source < _source_count; ++source) {
        cursors.append(_source_cursor[source]);
        gaps.append(_source_needs_resync[source]);
        gap_begin.append(_source_gap_begin[source]);
        gap_end.append(_source_gap_end[source]);
    }
    out["source_cursors"] = cursors;
    out["source_needs_resync"] = gaps;
    out["source_gap_begin"] = gap_begin;
    out["source_gap_end"] = gap_end;
    return out;
}

PackedByteArray TriggerRuntime::capture() const {
    PackedByteArray packed;
    if (!_configured) return packed;
    std::vector<uint8_t> bytes;
    append_le<uint32_t>(bytes, SAVE_MAGIC);
    append_le<uint32_t>(bytes, SAVE_SCHEMA_VERSION);
    append_le<uint64_t>(bytes, _catalog_hash);
    append_le<int64_t>(bytes, _current_day);
    append_le<int64_t>(bytes, _next_effect_id);
    append_le<int64_t>(bytes, _acked_effect_id);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_source_count));
    for (int32_t source = 0; source < _source_count; ++source) {
        append_le<int64_t>(bytes, _source_cursor[source]);
        append_le<uint8_t>(bytes, _source_needs_resync[source]);
        append_le<int64_t>(bytes, _source_gap_begin[source]);
        append_le<int64_t>(bytes, _source_gap_end[source]);
    }
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_state_count));
    for (int32_t i = 0; i < _state_count; ++i) {
        append_string(bytes, _definitions[_state.trigger_id[i]].key);
        append_le<uint64_t>(bytes, _state.target_handle[i]);
        append_le<uint32_t>(bytes, _state.target_generation[i]);
        append_le<int64_t>(bytes, _state.accumulator[i]);
        append_le<int64_t>(bytes, _state.remainder[i]);
        append_le<int64_t>(bytes, _state.last_event_id[i]);
        append_le<uint64_t>(bytes, _state.fire_sequence[i]);
        append_le<int64_t>(bytes, _state.cooldown_until[i]);
        append_le<int64_t>(bytes, _state.window_start_day[i]);
        append_le<int64_t>(bytes, _state.last_observed[i]);
        append_le<int64_t>(bytes, _state.last_sample_day[i]);
        append_le<uint8_t>(bytes, _state.completed[i]);
        append_le<uint8_t>(bytes, _state.initialized[i]);
        append_le<uint8_t>(bytes, _state.needs_resync[i]);
        const size_t begin = static_cast<size_t>(i) * _distinct_capacity;
        for (int32_t d = 0; d < _distinct_capacity; ++d)
            append_le<int64_t>(bytes, _distinct_keys[begin + d]);
    }
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_pending_events.size()));
    for (const Event &event : _pending_events) {
        append_le<int32_t>(bytes, event.source_id);
        append_le<int64_t>(bytes, event.event_id);
        append_le<int64_t>(bytes, event.day);
        append_le<int32_t>(bytes, event.event_type);
        append_le<int32_t>(bytes, event.payload_schema);
        append_le<uint64_t>(bytes, event.entity_handle);
        append_le<uint64_t>(bytes, event.group_handle);
        append_le<int64_t>(bytes, event.value);
        for (int p = 0; p < 4; ++p) append_le<int64_t>(bytes, event.payload[p]);
        append_le<uint8_t>(bytes, event.snapshot ? 1 : 0);
    }
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_effects.size()));
    for (const Effect &effect : _effects) {
        append_le<int64_t>(bytes, effect.id);
        append_le<int64_t>(bytes, effect.effective_day);
        append_le<int32_t>(bytes, effect.source_priority);
        append_string(bytes, _definitions[effect.trigger_id].key);
        append_le<uint64_t>(bytes, effect.target_handle);
        append_le<uint32_t>(bytes, effect.target_generation);
        append_le<uint64_t>(bytes, effect.fire_sequence);
        append_le<int32_t>(bytes, effect.action);
        append_le<int32_t>(bytes, effect.domain);
        append_le<int32_t>(bytes, effect.opcode);
        append_le<int64_t>(bytes, effect.resolved_value);
        append_le<int32_t>(bytes, effect.duration_days);
        append_le<int32_t>(bytes, effect.stacks);
        append_string(bytes, effect.command_key);
        append_string(bytes, effect.definition_key);
        for (int p = 0; p < 4; ++p) append_le<int64_t>(bytes, effect.payload[p]);
    }
    append_le<uint32_t>(bytes, SAVE_END);
    packed.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty()) std::memcpy(packed.ptrw(), bytes.data(), bytes.size());
    return packed;
}

Dictionary TriggerRuntime::restore(const PackedByteArray &packed) {
    if (!_configured) return failure("trigger_runtime_not_configured");
    const uint8_t *bytes = packed.ptr();
    const size_t size = static_cast<size_t>(packed.size());
    size_t cursor = 0;
    uint32_t magic = 0, version = 0, source_count = 0, state_count = 0,
             pending_count = 0, effect_count = 0, end = 0;
    uint64_t catalog_hash = 0;
    int64_t current_day = -1, next_effect = 1, acked_effect = 0;
    if (!read_le(bytes, size, cursor, magic) ||
        !read_le(bytes, size, cursor, version) ||
        !read_le(bytes, size, cursor, catalog_hash) ||
        !read_le(bytes, size, cursor, current_day) ||
        !read_le(bytes, size, cursor, next_effect) ||
        !read_le(bytes, size, cursor, acked_effect) ||
        !read_le(bytes, size, cursor, source_count))
        return failure("trigger_restore_header_truncated");
    if (magic != SAVE_MAGIC)
        return failure("trigger_restore_magic_invalid");
    if (version != SAVE_SCHEMA_VERSION || catalog_hash != _catalog_hash ||
        source_count != static_cast<uint32_t>(_source_count))
        return failure("catalog_hash_mismatch");

    reset_runtime_state();
    // PKTR is the facade's own save. The worker restores its POD section
    // separately and resumes its own generation counter, so the write-back gate
    // must not reject the first snapshot after a load.
    _pod_snapshot_generation = 0;
    _current_day = current_day;
    _next_effect_id = next_effect;
    _acked_effect_id = acked_effect;
    for (uint32_t source = 0; source < source_count; ++source) {
        if (!read_le(bytes, size, cursor, _source_cursor[source]) ||
            !read_le(bytes, size, cursor, _source_needs_resync[source]) ||
            !read_le(bytes, size, cursor, _source_gap_begin[source]) ||
            !read_le(bytes, size, cursor, _source_gap_end[source]))
            return failure("trigger_restore_source_truncated");
    }
    if (!read_le(bytes, size, cursor, state_count) ||
        state_count > static_cast<uint32_t>(_max_states))
        return failure("trigger_restore_state_count_invalid");
    for (uint32_t saved = 0; saved < state_count; ++saved) {
        std::string key;
        uint64_t target = 0;
        uint32_t generation = 0;
        if (!read_string(bytes, size, cursor, key) ||
            !read_le(bytes, size, cursor, target) ||
            !read_le(bytes, size, cursor, generation))
            return failure("trigger_restore_state_truncated");
        int32_t trigger_id = -1;
        for (int32_t i = 0; i < static_cast<int32_t>(_definitions.size()); ++i)
            if (_definitions[i].key == key) { trigger_id = i; break; }
        if (trigger_id < 0) return failure("trigger_restore_definition_missing");
        const int32_t state_index = find_or_create_state(trigger_id, target, generation);
        if (state_index < 0 ||
            !read_le(bytes, size, cursor, _state.accumulator[state_index]) ||
            !read_le(bytes, size, cursor, _state.remainder[state_index]) ||
            !read_le(bytes, size, cursor, _state.last_event_id[state_index]) ||
            !read_le(bytes, size, cursor, _state.fire_sequence[state_index]) ||
            !read_le(bytes, size, cursor, _state.cooldown_until[state_index]) ||
            !read_le(bytes, size, cursor, _state.window_start_day[state_index]) ||
            !read_le(bytes, size, cursor, _state.last_observed[state_index]) ||
            !read_le(bytes, size, cursor, _state.last_sample_day[state_index]) ||
            !read_le(bytes, size, cursor, _state.completed[state_index]) ||
            !read_le(bytes, size, cursor, _state.initialized[state_index]) ||
            !read_le(bytes, size, cursor, _state.needs_resync[state_index]))
            return failure("trigger_restore_state_payload_invalid");
        const size_t begin = static_cast<size_t>(state_index) * _distinct_capacity;
        for (int32_t d = 0; d < _distinct_capacity; ++d)
            if (!read_le(bytes, size, cursor, _distinct_keys[begin + d]))
                return failure("trigger_restore_distinct_truncated");
    }
    if (!read_le(bytes, size, cursor, pending_count) ||
        pending_count > static_cast<uint32_t>(_max_pending_events))
        return failure("trigger_restore_pending_count_invalid");
    for (uint32_t saved = 0; saved < pending_count; ++saved) {
        Event event;
        uint8_t snapshot = 0;
        if (!read_le(bytes, size, cursor, event.source_id) ||
            !read_le(bytes, size, cursor, event.event_id) ||
            !read_le(bytes, size, cursor, event.day) ||
            !read_le(bytes, size, cursor, event.event_type) ||
            !read_le(bytes, size, cursor, event.payload_schema) ||
            !read_le(bytes, size, cursor, event.entity_handle) ||
            !read_le(bytes, size, cursor, event.group_handle) ||
            !read_le(bytes, size, cursor, event.value))
            return failure("trigger_restore_pending_truncated");
        for (int p = 0; p < 4; ++p)
            if (!read_le(bytes, size, cursor, event.payload[p]))
                return failure("trigger_restore_pending_payload_truncated");
        if (!read_le(bytes, size, cursor, snapshot))
            return failure("trigger_restore_pending_flag_truncated");
        event.snapshot = snapshot != 0;
        _pending_events.push_back(event);
    }
    if (!read_le(bytes, size, cursor, effect_count) || effect_count > 1000000U)
        return failure("trigger_restore_effect_count_invalid");
    for (uint32_t saved = 0; saved < effect_count; ++saved) {
        Effect effect;
        std::string trigger_key;
        if (!read_le(bytes, size, cursor, effect.id) ||
            !read_le(bytes, size, cursor, effect.effective_day) ||
            !read_le(bytes, size, cursor, effect.source_priority) ||
            !read_string(bytes, size, cursor, trigger_key) ||
            !read_le(bytes, size, cursor, effect.target_handle) ||
            !read_le(bytes, size, cursor, effect.target_generation) ||
            !read_le(bytes, size, cursor, effect.fire_sequence) ||
            !read_le(bytes, size, cursor, effect.action) ||
            !read_le(bytes, size, cursor, effect.domain) ||
            !read_le(bytes, size, cursor, effect.opcode) ||
            !read_le(bytes, size, cursor, effect.resolved_value) ||
            !read_le(bytes, size, cursor, effect.duration_days) ||
            !read_le(bytes, size, cursor, effect.stacks) ||
            !read_string(bytes, size, cursor, effect.command_key) ||
            !read_string(bytes, size, cursor, effect.definition_key))
            return failure("trigger_restore_effect_truncated");
        effect.trigger_id = -1;
        for (int32_t i = 0; i < static_cast<int32_t>(_definitions.size()); ++i)
            if (_definitions[i].key == trigger_key) { effect.trigger_id = i; break; }
        if (effect.trigger_id < 0) return failure("trigger_restore_effect_definition_missing");
        for (int p = 0; p < 4; ++p)
            if (!read_le(bytes, size, cursor, effect.payload[p]))
                return failure("trigger_restore_effect_payload_truncated");
        if (effect.trigger_id >= 0 && effect.trigger_id < static_cast<int32_t>(_definitions.size())) {
            const Definition &definition = _definitions[effect.trigger_id];
            for (int32_t offset = 0; offset < definition.effect_count; ++offset) {
                const int32_t effect_id = definition.effect_begin + offset;
                const EffectDefinition &candidate = _effect_definitions[effect_id];
                if (candidate.action == effect.action && candidate.domain == effect.domain &&
                    candidate.opcode == effect.opcode &&
                    candidate.command_key == effect.command_key &&
                    candidate.definition_key == effect.definition_key &&
                    candidate.payload == effect.payload) {
                    effect.effect_definition_id = effect_id;
                    break;
                }
            }
        }
        _effects.push_back(std::move(effect));
    }
    if (!read_le(bytes, size, cursor, end) || end != SAVE_END || cursor != size)
        return failure("trigger_restore_end_invalid");
    Dictionary out = report();
    out["ok"] = true;
    return out;
}

Dictionary TriggerRuntime::clear_state() {
    if (!_configured) return failure("trigger_runtime_not_configured");
    reset_runtime_state();
    // A cleared facade has no worker generation history; the next write-back
    // must be accepted rather than rejected as stale.
    _pod_snapshot_generation = 0;
    Dictionary out;
    out["ok"] = true;
    out["migration"] = "legacy_empty_trigger_state";
    return out;
}
