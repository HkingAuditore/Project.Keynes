uint64_t TriggerRuntime::resolve_target(const Definition &definition,
                                        const Event &event) const {
    switch (definition.target_resolver) {
        case TARGET_SOURCE_ENTITY:
        case TARGET_EVENT_ENTITY: return event.entity_handle;
        case TARGET_EVENT_GROUP: return event.group_handle;
        case TARGET_SNAPSHOT: return event.entity_handle != 0
            ? event.entity_handle : event.group_handle;
        default: return definition.static_target;
    }
}

uint64_t TriggerRuntime::resolve_effect_target(const EffectDefinition &effect,
                                               uint64_t state_target,
                                               const Event &event) const {
    switch (effect.target_resolver) {
        case TARGET_SOURCE_ENTITY:
        case TARGET_EVENT_ENTITY: return event.entity_handle;
        case TARGET_EVENT_GROUP: return event.group_handle;
        case TARGET_SNAPSHOT: return state_target;
        default: return effect.static_target != 0 ? effect.static_target : state_target;
    }
}

int64_t TriggerRuntime::event_field(const Event &event, int32_t field) const {
    switch (field) {
        case VALUE_ONE: return 1;
        case VALUE_I64: return event.value;
        case PAYLOAD_I0: return event.payload[0];
        case PAYLOAD_I1: return event.payload[1];
        case PAYLOAD_I2: return event.payload[2];
        case PAYLOAD_I3: return event.payload[3];
        case ENTITY_HANDLE: return static_cast<int64_t>(event.entity_handle);
        case GROUP_HANDLE: return static_cast<int64_t>(event.group_handle);
        default: return 0;
    }
}

bool TriggerRuntime::event_matches(const Definition &definition,
                                   const Event &event) const {
    if (definition.selector_field < 0) return true;
    const bool equal = event_field(event, definition.selector_field) ==
        definition.selector_value;
    return definition.selector_negated != 0 ? !equal : equal;
}

void TriggerRuntime::mark_source_gap(int32_t source_id, int64_t expected,
                                     int64_t actual) {
    if (source_id >= 0 && source_id < _source_count) {
        _source_needs_resync[source_id] = 1;
        _source_gap_begin[source_id] = expected;
        _source_gap_end[source_id] = actual;
    }
    for (int32_t i = 0; i < _state_count; ++i) {
        const int32_t trigger_id = _state.trigger_id[i];
        if (trigger_id >= 0 && _definitions[trigger_id].source_id == source_id)
            _state.needs_resync[i] = 1;
    }
    ++_gap_count;
    _last_error = "trigger_source_gap:" + std::to_string(source_id) + ":" +
        std::to_string(expected) + ":" + std::to_string(actual);
}

Dictionary TriggerRuntime::submit_events(const Dictionary &batch) {
    if (!_configured) return failure("trigger_runtime_not_configured");
    const auto started = std::chrono::steady_clock::now();
    const PackedInt32Array source_ids = get_i32(batch, "source_ids");
    const PackedInt64Array event_ids = get_i64(batch, "event_ids");
    const PackedInt64Array days = get_i64(batch, "days");
    const PackedInt32Array event_types = get_i32(batch, "event_types");
    const PackedInt32Array schemas = get_i32(batch, "payload_schemas");
    const PackedInt64Array entities = get_i64(batch, "entity_handles");
    const PackedInt64Array groups = get_i64(batch, "group_handles");
    const PackedInt64Array values = get_i64(batch, "values");
    const PackedInt64Array p0 = get_i64(batch, "payload_i0");
    const PackedInt64Array p1 = get_i64(batch, "payload_i1");
    const PackedInt64Array p2 = get_i64(batch, "payload_i2");
    const PackedInt64Array p3 = get_i64(batch, "payload_i3");
    const int32_t source_scalar = int32_t(batch.get("source_id_scalar", 0));
    int32_t count = int32_t(batch.get("count", event_ids.size()));
    count = std::min<int32_t>(count, static_cast<int32_t>(event_ids.size()));
    int32_t accepted = 0;
    int32_t deduplicated = 0;
    int64_t last_accepted = 0;
    for (int32_t i = 0; i < count; ++i) {
        const int32_t source = i32_at(source_ids, i, source_scalar);
        const int64_t id = event_ids[i];
        if (source < 0 || source >= _source_count || id <= 0) {
            ++_events_rejected;
            continue;
        }
        if (_source_needs_resync[source] != 0) {
            ++_events_rejected;
            continue;
        }
        const int64_t cursor = _source_cursor[source];
        if (id <= cursor) {
            ++deduplicated;
            ++_events_deduplicated;
            continue;
        }
        if (_strict_source_cursors && cursor > 0 && id != cursor + 1) {
            mark_source_gap(source, cursor + 1, id);
            ++_events_rejected;
            continue;
        }
        if (static_cast<int32_t>(_pending_events.size()) >= _max_pending_events) {
            mark_source_gap(source, cursor + 1, id);
            _last_error = "trigger_pending_event_capacity_exhausted";
            ++_events_rejected;
            continue;
        }
        Event event;
        event.source_id = source;
        event.event_id = id;
        event.day = i64_at(days, i, _current_day < 0 ? 0 : _current_day);
        event.event_type = i32_at(event_types, i, 0);
        event.payload_schema = i32_at(schemas, i, 0);
        event.entity_handle = static_cast<uint64_t>(i64_at(entities, i, 0));
        event.group_handle = static_cast<uint64_t>(i64_at(groups, i, 0));
        event.value = i64_at(values, i, 1);
        event.payload = {i64_at(p0, i, 0), i64_at(p1, i, 0),
                         i64_at(p2, i, 0), i64_at(p3, i, 0)};
        _pending_events.push_back(event);
        _source_cursor[source] = id;
        last_accepted = id;
        ++accepted;
        ++_events_ingested;
    }
    _last_ingest_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    Dictionary out;
    out["ok"] = true;
    out["accepted"] = accepted;
    out["deduplicated"] = deduplicated;
    out["last_accepted_event_id"] = last_accepted;
    out["pending_events"] = static_cast<int64_t>(_pending_events.size());
    out["needs_resync"] = !_last_error.empty();
    out["reason"] = String(_last_error.c_str());
    return out;
}

bool TriggerRuntime::submit_events_pod(const EventInput *events, size_t count,
                                       size_t &accepted, int64_t &last_accepted,
                                       std::string &error) {
    accepted = 0;
    last_accepted = 0;
    error.clear();
    if (!_configured) {
        error = "trigger_runtime_not_configured";
        return false;
    }
    if (events == nullptr && count != 0) {
        error = "trigger_event_input_missing";
        return false;
    }
    const auto started = std::chrono::steady_clock::now();
    for (size_t i = 0; i < count; ++i) {
        const EventInput &input = events[i];
        if (input.source_id < 0 || input.source_id >= _source_count ||
            input.event_id <= 0 || _source_needs_resync[input.source_id] != 0) {
            ++_events_rejected;
            continue;
        }
        const int64_t cursor = _source_cursor[input.source_id];
        if (input.event_id <= cursor) {
            ++_events_deduplicated;
            ++accepted;
            last_accepted = input.event_id;
            continue;
        }
        if (_strict_source_cursors && cursor > 0 && input.event_id != cursor + 1) {
            mark_source_gap(input.source_id, cursor + 1, input.event_id);
            ++_events_rejected;
            continue;
        }
        if (static_cast<int32_t>(_pending_events.size()) >= _max_pending_events) {
            mark_source_gap(input.source_id, cursor + 1, input.event_id);
            _last_error = "trigger_pending_event_capacity_exhausted";
            ++_events_rejected;
            continue;
        }
        Event event;
        event.source_id = input.source_id;
        event.event_id = input.event_id;
        event.day = input.day;
        event.event_type = input.event_type;
        event.payload_schema = input.payload_schema;
        event.entity_handle = input.entity_handle;
        event.group_handle = input.group_handle;
        event.value = input.value;
        event.payload = input.payload;
        _pending_events.push_back(event);
        _source_cursor[input.source_id] = input.event_id;
        last_accepted = input.event_id;
        ++accepted;
        ++_events_ingested;
    }
    _last_ingest_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started).count();
    if (accepted != count) {
        error = _last_error.empty() ? "trigger_event_rejected" : _last_error;
        return false;
    }
    return true;
}

Dictionary TriggerRuntime::submit_snapshots(const Dictionary &batch) {
    const size_t pending_before = _pending_events.size();
    Dictionary normalized = batch.duplicate();
    normalized["source_id_scalar"] = int32_t(batch.get("source_id_scalar", 0));
    Dictionary result = submit_events(normalized);
    if (bool(result.get("ok", false))) {
        for (size_t index = pending_before; index < _pending_events.size(); ++index)
            _pending_events[index].snapshot = true;
    }
    return result;
}
