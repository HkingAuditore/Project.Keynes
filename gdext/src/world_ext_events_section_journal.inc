Dictionary DCWorldExt::snapshot_gameplay_event_journal(Dictionary opts) const {
    Dictionary replay_opts = opts;
    Dictionary out = replay_gameplay_events(replay_opts);
    // v4 permits event_id == -1 for custom gameplay-domain commits (canals).
    // Those commands mutate authoritative slots instead of appending a normal
    // GameplayEventRecord, but still need durable idempotency evidence.
    out["version"] = 4;
    out["next_event_id"] = military_executor_active() ? _runtime_host->events_ingress_cursor()
        : _gameplay_next_event_id;
    out["dropped_event_count"] = _gameplay_dropped_event_count;
    out["first_dropped_event_id"] = _gameplay_first_dropped_event_id;
    out["max_events"] = _gameplay_max_events;
    std::vector<std::pair<uint64_t, int64_t>> effect_keys;
    effect_keys.reserve(_effect_gameplay_idempotency.size());
    for (const auto &entry : _effect_gameplay_idempotency) {
        const auto event = _effect_gameplay_event_ids.find(entry.first);
        if (event != _effect_gameplay_event_ids.end())
            effect_keys.push_back({entry.first, entry.second});
    }
    std::sort(effect_keys.begin(), effect_keys.end());
    PackedInt64Array idempotency_keys;
    PackedInt64Array request_ids;
    PackedInt64Array event_ids;
    idempotency_keys.resize(static_cast<int64_t>(effect_keys.size()));
    request_ids.resize(static_cast<int64_t>(effect_keys.size()));
    event_ids.resize(static_cast<int64_t>(effect_keys.size()));
    for (int64_t i = 0; i < static_cast<int64_t>(effect_keys.size()); ++i) {
        const auto event = _effect_gameplay_event_ids.find(effect_keys[static_cast<size_t>(i)].first);
        idempotency_keys[i] = static_cast<int64_t>(effect_keys[static_cast<size_t>(i)].first);
        request_ids[i] = effect_keys[static_cast<size_t>(i)].second;
        event_ids[i] = event == _effect_gameplay_event_ids.end() ? 0 : event->second;
    }
    out["effect_idempotency_keys"] = idempotency_keys;
    out["effect_request_ids"] = request_ids;
    out["effect_event_ids"] = event_ids;
    return out;
}

Dictionary DCWorldExt::restore_gameplay_event_journal(Dictionary snapshot) {
    _gameplay_events.clear();
    _gameplay_consumer_ack.clear();
    _effect_gameplay_commands.clear();
    _effect_gameplay_results.clear();
    _effect_gameplay_idempotency.clear();
    _effect_gameplay_event_ids.clear();
    _canal_commit_idempotency.clear();
    _effect_gameplay_next_request_id = 1;
    const int version = int(snapshot.get("version", 2));
    if (version != 2 && version != 3 && version != 4) {
        Dictionary invalid;
        invalid["ok"] = false;
        invalid["reason"] = "gameplay_journal_schema_unsupported";
        return invalid;
    }
    _gameplay_next_event_id = int64_t(snapshot.get("next_event_id", 1));
    _gameplay_dropped_event_count = int64_t(snapshot.get("dropped_event_count", 0));
    _gameplay_first_dropped_event_id = int64_t(snapshot.get("first_dropped_event_id", 0));
    _gameplay_max_events = std::max(1, int(snapshot.get("max_events", _gameplay_max_events)));

    PackedInt64Array ids = dictionary_i64_array(snapshot, "event_id");
    PackedInt64Array ticks = dictionary_i64_array(snapshot, "tick");
    PackedInt32Array phase = dictionary_i32_array(snapshot, "phase");
    PackedInt32Array type = dictionary_i32_array(snapshot, "type");
    PackedInt32Array source = dictionary_i32_array(snapshot, "source");
    PackedInt32Array flags = dictionary_i32_array(snapshot, "flags");
    PackedInt64Array entity_handle = dictionary_i64_array(snapshot, "entity_handle");
    PackedInt32Array entity = dictionary_i32_array(snapshot, "entity_id");
    PackedInt32Array cell = dictionary_i32_array(snapshot, "cell_idx");
    PackedInt32Array schema = dictionary_i32_array(snapshot, "payload_schema");
    PackedInt64Array value = dictionary_i64_array(snapshot, "value_i64");
    PackedInt32Array p0 = dictionary_i32_array(snapshot, "payload_i0");
    PackedInt32Array p1 = dictionary_i32_array(snapshot, "payload_i1");
    PackedInt32Array p2 = dictionary_i32_array(snapshot, "payload_i2");
    PackedInt32Array p3 = dictionary_i32_array(snapshot, "payload_i3");
    const int n = ids.size();
    for (int i = 0; i < n; ++i) {
        GameplayEventRecord ev;
        ev.event_id = ids[i];
        ev.tick = event_i64_at(ticks, i, 0);
        ev.phase = event_i32_at(phase, i, 0);
        ev.type = event_i32_at(type, i, 0);
        ev.source = event_i32_at(source, i, 0);
        ev.flags = event_i32_at(flags, i, 0);
        ev.entity_id = event_i32_at(entity, i, -1);
        ev.entity_handle = static_cast<uint64_t>(event_i64_at(
            entity_handle, i, ev.entity_id >= 0 ? int64_t(ev.entity_id) : int64_t{0}));
        ev.cell_idx = event_i32_at(cell, i, ev.entity_id);
        ev.payload_schema = event_i32_at(schema, i, 0);
        ev.value_i64 = event_i64_at(value, i, 1);
        ev.payload_i0 = event_i32_at(p0, i, 0);
        ev.payload_i1 = event_i32_at(p1, i, 0);
        ev.payload_i2 = event_i32_at(p2, i, 0);
        ev.payload_i3 = event_i32_at(p3, i, 0);
        _gameplay_events.push_back(ev);
        // In ACTIVE, replay rows use worker IDs while next_event_id is the
        // independent main-thread ingress cursor. Preserve its saved value.
        if (!snapshot.has("next_event_id") && ev.event_id >= _gameplay_next_event_id) {
            _gameplay_next_event_id = ev.event_id + 1;
        }
    }
    if (version >= 3) {
        PackedInt64Array effect_keys = dictionary_i64_array(snapshot,
            "effect_idempotency_keys");
        PackedInt64Array effect_requests = dictionary_i64_array(snapshot,
            "effect_request_ids");
        PackedInt64Array effect_events = dictionary_i64_array(snapshot,
            "effect_event_ids");
        if (effect_keys.size() != effect_requests.size() ||
            effect_keys.size() != effect_events.size()) {
            Dictionary invalid;
            invalid["ok"] = false;
            invalid["reason"] = "gameplay_effect_idempotency_shape_invalid";
            return invalid;
        }
        for (int i = 0; i < effect_keys.size(); ++i) {
            const uint64_t key = static_cast<uint64_t>(effect_keys[i]);
            const int64_t request = effect_requests[i];
            const int64_t event = effect_events[i];
            const bool custom_commit = version >= 4 && event == -1;
            // The journal is a bounded ring. Idempotency evidence outlives the
            // scrolled-out GameplayEventRecord, so a positive event_id may be
            // absent from the restored event list after long sessions. Reject
            // only malformed keys/requests; do not require the referenced event
            // to still exist.
            if (key == 0 || request <= 0 ||
                (!custom_commit && event <= 0) ||
                !_effect_gameplay_idempotency.emplace(key, request).second ||
                !_effect_gameplay_event_ids.emplace(key, event).second ||
                !_effect_gameplay_results.emplace(request,
                    EffectGameplayCommandResult{1, 1, {}}).second) {
                Dictionary invalid;
                invalid["ok"] = false;
                invalid["reason"] = "gameplay_effect_idempotency_invalid";
                return invalid;
            }
            if (custom_commit) _canal_commit_idempotency.insert(key);
            _effect_gameplay_next_request_id = std::max(
                _effect_gameplay_next_request_id, request + 1);
        }
    }
    Dictionary out;
    out["ok"] = true;
    out["restored"] = int(_gameplay_events.size());
    out["next_event_id"] = military_executor_active() ? _runtime_host->events_ingress_cursor()
        : _gameplay_next_event_id;
    out["fallback"] = false;
    return out;
}

Dictionary DCWorldExt::clear_gameplay_events(Dictionary opts) {
    const bool keep_cursors = bool(opts.get("keep_cursors", false));
    _gameplay_events.clear();
    _effect_gameplay_commands.clear();
    _effect_gameplay_results.clear();
    _effect_gameplay_idempotency.clear();
    _effect_gameplay_event_ids.clear();
    _canal_commit_idempotency.clear();
    _effect_gameplay_next_request_id = 1;
    if (!keep_cursors) {
        _gameplay_consumer_ack.clear();
    }
    if (bool(opts.get("reset_ids", false))) {
        _gameplay_next_event_id = 1;
    }
    Dictionary out;
    out["event_count"] = 0;
    out["next_event_id"] = military_executor_active() ? _runtime_host->events_ingress_cursor()
        : _gameplay_next_event_id;
    out["fallback"] = false;
    return out;
}
