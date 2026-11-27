Dictionary DCWorldExt::poll_gameplay_events(Dictionary opts) {
    auto t0 = std::chrono::high_resolution_clock::now();
    const StringName consumer_id = opts.has("consumer_id") ? StringName(opts["consumer_id"]) : StringName("default");
    // Once EVENTS is authoritative, the worker snapshot is the only
    // production source. Keep the legacy API shape and annotate the source so
    // callers can migrate without maintaining a second journal.
    if (_runtime_host && _runtime_host->events_worker_authoritative()) {
        Dictionary worker = poll_runtime_events_snapshot_opts(opts);
        worker["consumer_id"] = consumer_id;
        worker["authority_source"] = String("runtime_events_worker");
        worker["legacy_journal_used"] = false;
        return worker;
    }
    const int64_t acked = _gameplay_consumer_ack.has(consumer_id) ? _gameplay_consumer_ack[consumer_id] : 0;
    const int64_t after_id = int64_t(opts.get("after_event_id", acked));
    const int max_events = std::max(0, int(opts.get("max_events", 256)));
    const int type_filter = int(opts.get("type", 0));
    const bool auto_ack = bool(opts.get("auto_ack", false));

    PackedInt64Array ids;
    PackedInt64Array ticks;
    PackedInt32Array phase;
    PackedInt32Array type;
    PackedInt32Array source;
    PackedInt32Array flags;
    PackedInt64Array entity_handle;
    PackedInt32Array entity;
    PackedInt32Array cell;
    PackedInt32Array schema;
    PackedInt64Array value;
    PackedInt32Array p0;
    PackedInt32Array p1;
    PackedInt32Array p2;
    PackedInt32Array p3;

    int64_t last_id = after_id;
    for (const GameplayEventRecord &ev : _gameplay_events) {
        if (ev.event_id <= after_id) {
            continue;
        }
        if (type_filter > 0 && ev.type != type_filter) {
            continue;
        }
        _append_gameplay_event_to_arrays(ev, ids, ticks, phase, type, source, flags,
            entity_handle, entity, cell, schema, value, p0, p1, p2, p3);
        last_id = ev.event_id;
        if (max_events > 0 && ids.size() >= max_events) {
            break;
        }
    }
    if (auto_ack && last_id > after_id) {
        _gameplay_consumer_ack[consumer_id] = last_id;
    }

    Dictionary out;
    out["event_id"] = ids;
    out["tick"] = ticks;
    out["phase"] = phase;
    out["type"] = type;
    out["source"] = source;
    out["flags"] = flags;
    out["entity_handle"] = entity_handle;
    out["entity_id"] = entity;
    out["cell_idx"] = cell;
    out["payload_schema"] = schema;
    out["value_i64"] = value;
    out["payload_i0"] = p0;
    out["payload_i1"] = p1;
    out["payload_i2"] = p2;
    out["payload_i3"] = p3;
    out["count"] = ids.size();
    out["last_event_id"] = last_id;
    out["consumer_id"] = consumer_id;
    out["consumer_lag"] = _gameplay_events.empty() ? 0 : int64_t(_gameplay_events.back().event_id - last_id);
    auto t1 = std::chrono::high_resolution_clock::now();
    _gameplay_last_native_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["native_ms"] = _gameplay_last_native_ms;
    out["fallback"] = false;
    return out;
}

Dictionary DCWorldExt::ack_gameplay_events(StringName consumer_id, int64_t up_to_event_id) {
    Dictionary out;
    const bool worker_authoritative =
        _runtime_host && _runtime_host->events_worker_authoritative();
    int64_t prev = _gameplay_consumer_ack.has(consumer_id)
        ? _gameplay_consumer_ack[consumer_id] : 0;
    int64_t next = std::max(prev, up_to_event_id);
    bool skip_worker_ack = false;
    // ACTIVE Events owns the consumer cursor in the worker snapshot. Keep the
    // legacy cursor untouched there; probe/fallback retains the old API state.
    if (!worker_authoritative) {
        _gameplay_consumer_ack[consumer_id] = next;
    } else {
        // 旧游标是 legacy 日志 id，可能领先 worker 的 next_event_id；混入后
        // ACK 会被 Events 判非法。权威下只信 worker 快照，并截断到已发布 id。
        uint32_t slot = 0;
        if (_runtime_host->try_acquire_events_snapshot(0, slot)) {
            const RuntimeEventsSnapshot &snapshot =
                _runtime_host->events_snapshot_buffer(slot);
            prev = worker_consumer_ack(snapshot, stable_consumer_key(consumer_id));
            next = std::min(up_to_event_id, snapshot.next_event_id - 1);
            skip_worker_ack = next <= prev;
            next = std::max(prev, next);
            _runtime_host->release_events_snapshot(slot);
        } else {
            prev = 0;
            next = 0;
            skip_worker_ack = true;
        }
    }
    out["consumer_id"] = consumer_id;
    out["previous_event_id"] = prev;
    out["acked_event_id"] = next;
    out["fallback"] = false;
    out["events_bridge_queued"] = int64_t(0);
    out["events_bridge_failed"] = int64_t(0);
    out["events_bridge_reason"] = String();
    // In EVENTS-authoritative mode the typed ACK is the production path. In
    // probe/fallback mode it remains best-effort and cannot make the legacy
    // acknowledgement fail.
    if (_runtime_host && !skip_worker_ack &&
        (_runtime_host->events_probe_enabled() || worker_authoritative) &&
        next >= 0) {
        std::string bridge_error;
        if (queue_events_bridge_ack(_runtime_host.get(), consumer_id, next,
                                    bridge_error)) {
            out["events_bridge_queued"] = int64_t(1);
        } else {
            out["events_bridge_failed"] = int64_t(1);
            out["events_bridge_reason"] = String(bridge_error.c_str());
        }
    }
    return out;
}

Dictionary DCWorldExt::poll_runtime_events_snapshot(int64_t after_generation) {
    Dictionary opts;
    opts["after_generation"] = after_generation;
    return poll_runtime_events_snapshot_opts(opts);
}

Dictionary DCWorldExt::poll_runtime_events_snapshot_opts(const Dictionary &opts) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["available"] = false;
        out["fallback"] = true;
        out["reason"] = "runtime_worker_not_started";
        return out;
    }
    const StringName consumer_id = opts.has("consumer_id")
        ? StringName(opts["consumer_id"]) : StringName("default");
    const int type_filter = int(opts.get("type", 0));
    const int max_events = std::max(0, int(opts.get("max_events", 256)));
    const bool auto_ack = bool(opts.get("auto_ack", false));
    const int64_t start_tick = int64_t(opts.get(
        "start_tick", std::numeric_limits<int64_t>::min()));
    const int64_t end_tick = int64_t(opts.get(
        "end_tick", std::numeric_limits<int64_t>::max()));
    const int64_t acked = _gameplay_consumer_ack.has(consumer_id)
        ? _gameplay_consumer_ack[consumer_id] : 0;
    const bool explicit_after_event_id = opts.has("after_event_id");
    int64_t after_event_id = int64_t(opts.get("after_event_id", acked));
    const uint64_t requested_generation = static_cast<uint64_t>(std::max<int64_t>(
        0, int64_t(opts.get("after_generation", 0))));
    const uint64_t after = requested_generation;
    uint32_t slot = 0;
    if (!_runtime_host->try_acquire_events_snapshot(after, slot)) {
        out["ok"] = true;
        out["available"] = false;
        out["fallback"] = false;
        out["generation"] = static_cast<int64_t>(after);
        out["consumer_id"] = consumer_id;
        out["last_event_id"] = after_event_id;
        out["consumer_lag"] = int64_t(0);
        return out;
    }

    const RuntimeEventsSnapshot &snapshot =
        _runtime_host->events_snapshot_buffer(slot);
    const int64_t worker_acked =
        worker_consumer_ack(snapshot, stable_consumer_key(consumer_id));
    if (!explicit_after_event_id && _runtime_host->events_worker_authoritative())
        after_event_id = worker_acked;
    PackedInt64Array ids;
    PackedInt64Array ticks;
    PackedInt32Array phases;
    PackedInt32Array types;
    PackedInt32Array sources;
    PackedInt32Array flags;
    PackedInt64Array entity_handles;
    PackedInt32Array entity_ids;
    PackedInt32Array cell_indices;
    PackedInt32Array payload_schemas;
    PackedInt64Array values;
    PackedInt32Array payload_i0;
    PackedInt32Array payload_i1;
    PackedInt32Array payload_i2;
    PackedInt32Array payload_i3;
    int64_t last_event_id = after_event_id;
    for (const RuntimeEventsRecord &event : snapshot.events) {
        if (event.event_id <= after_event_id || event.tick < start_tick ||
            event.tick > end_tick ||
            (type_filter > 0 && event.type != type_filter)) continue;
        ids.append(event.event_id);
        ticks.append(event.tick);
        phases.append(event.phase);
        types.append(event.type);
        sources.append(event.source);
        flags.append(event.flags);
        entity_handles.append(static_cast<int64_t>(event.entity_handle));
        entity_ids.append(event.entity_id);
        cell_indices.append(event.cell_idx);
        payload_schemas.append(event.payload_schema);
        values.append(event.value_i64);
        payload_i0.append(event.payload_i0);
        payload_i1.append(event.payload_i1);
        payload_i2.append(event.payload_i2);
        payload_i3.append(event.payload_i3);
        last_event_id = event.event_id;
        if (max_events > 0 && ids.size() >= max_events) break;
    }
    if (auto_ack && last_event_id > after_event_id &&
        !_runtime_host->events_worker_authoritative())
        _gameplay_consumer_ack[consumer_id] = last_event_id;
    PackedInt64Array ack_keys;
    PackedInt64Array ack_event_ids;
    ack_keys.resize(static_cast<int64_t>(snapshot.consumer_acks.size()));
    ack_event_ids.resize(static_cast<int64_t>(snapshot.consumer_acks.size()));
    for (int64_t i = 0; i < static_cast<int64_t>(snapshot.consumer_acks.size()); ++i) {
        const RuntimeEventsConsumerAck &ack = snapshot.consumer_acks[static_cast<size_t>(i)];
        ack_keys[i] = static_cast<int64_t>(ack.consumer_key);
        ack_event_ids[i] = ack.event_id;
    }
    PackedInt64Array idempotency_keys;
    PackedInt64Array idempotency_requests;
    PackedInt64Array idempotency_events;
    idempotency_keys.resize(static_cast<int64_t>(snapshot.idempotency.size()));
    idempotency_requests.resize(static_cast<int64_t>(snapshot.idempotency.size()));
    idempotency_events.resize(static_cast<int64_t>(snapshot.idempotency.size()));
    for (int64_t i = 0; i < static_cast<int64_t>(snapshot.idempotency.size()); ++i) {
        const RuntimeEventsIdempotencyEvidence &entry =
            snapshot.idempotency[static_cast<size_t>(i)];
        idempotency_keys[i] = static_cast<int64_t>(entry.key);
        idempotency_requests[i] = static_cast<int64_t>(entry.request_id);
        idempotency_events[i] = entry.event_id;
    }

    out["ok"] = true;
    out["available"] = true;
    out["fallback"] = false;
    out["abi_version"] = static_cast<int>(snapshot.abi_version);
    out["generation"] = static_cast<int64_t>(snapshot.generation);
    out["state_hash"] = static_cast<int64_t>(snapshot.state_hash);
    out["committed_day"] = snapshot.committed_day;
    out["next_event_id"] = snapshot.next_event_id;
    out["capacity"] = static_cast<int>(snapshot.capacity);
    out["dropped_event_count"] = static_cast<int64_t>(snapshot.dropped_event_count);
    out["first_dropped_event_id"] = snapshot.first_dropped_event_id;
    out["event_id"] = ids;
    out["tick"] = ticks;
    out["phase"] = phases;
    out["type"] = types;
    out["source"] = sources;
    out["flags"] = flags;
    out["entity_handle"] = entity_handles;
    out["entity_id"] = entity_ids;
    out["cell_idx"] = cell_indices;
    out["payload_schema"] = payload_schemas;
    out["value_i64"] = values;
    out["payload_i0"] = payload_i0;
    out["payload_i1"] = payload_i1;
    out["payload_i2"] = payload_i2;
    out["payload_i3"] = payload_i3;
    out["count"] = ids.size();
    out["consumer_id"] = consumer_id;
    out["last_event_id"] = last_event_id;
    out["consumer_lag"] = snapshot.events.empty() ? 0 :
        int64_t(snapshot.events.back().event_id - last_event_id);
    out["consumer_key"] = ack_keys;
    out["consumer_event_id"] = ack_event_ids;
    out["ack_count"] = ack_keys.size();
    out["idempotency_key"] = idempotency_keys;
    out["idempotency_request_id"] = idempotency_requests;
    out["idempotency_event_id"] = idempotency_events;
    out["idempotency_count"] = idempotency_keys.size();
    const int64_t auto_ack_event_id =
        std::min(last_event_id, snapshot.next_event_id - 1);
    if (auto_ack && auto_ack_event_id > worker_acked) {
        std::string ack_error;
        if (queue_events_bridge_ack(_runtime_host.get(), consumer_id,
                                    auto_ack_event_id, ack_error)) {
            out["auto_ack_queued"] = true;
        } else {
            out["auto_ack_queued"] = false;
            out["auto_ack_error"] = String(ack_error.c_str());
        }
    } else {
        out["auto_ack_queued"] = false;
    }
    _runtime_host->release_events_snapshot(slot);
    return out;
}

Dictionary DCWorldExt::replay_gameplay_events(Dictionary opts) const {
    if (_runtime_host && _runtime_host->events_worker_authoritative()) {
        Dictionary worker_opts = opts;
        worker_opts["consumer_id"] = StringName("__events_replay__");
        worker_opts["after_event_id"] = int64_t(0);
        worker_opts["after_generation"] = int64_t(0);
        worker_opts["auto_ack"] = false;
        Dictionary out = const_cast<DCWorldExt *>(this)->
            poll_runtime_events_snapshot_opts(worker_opts);
        out["authority_source"] = String("runtime_events_worker");
        out["legacy_journal_used"] = false;
        return out;
    }
    const int64_t start_tick = int64_t(opts.get("start_tick", std::numeric_limits<int64_t>::min()));
    const int64_t end_tick = int64_t(opts.get("end_tick", std::numeric_limits<int64_t>::max()));
    const int type_filter = int(opts.get("type", 0));
    const int max_events = std::max(0, int(opts.get("max_events", 0)));

    PackedInt64Array ids;
    PackedInt64Array ticks;
    PackedInt32Array phase;
    PackedInt32Array type;
    PackedInt32Array source;
    PackedInt32Array flags;
    PackedInt64Array entity_handle;
    PackedInt32Array entity;
    PackedInt32Array cell;
    PackedInt32Array schema;
    PackedInt64Array value;
    PackedInt32Array p0;
    PackedInt32Array p1;
    PackedInt32Array p2;
    PackedInt32Array p3;
    for (const GameplayEventRecord &ev : _gameplay_events) {
        if (ev.tick < start_tick || ev.tick > end_tick) {
            continue;
        }
        if (type_filter > 0 && ev.type != type_filter) {
            continue;
        }
        _append_gameplay_event_to_arrays(ev, ids, ticks, phase, type, source, flags,
            entity_handle, entity, cell, schema, value, p0, p1, p2, p3);
        if (max_events > 0 && ids.size() >= max_events) {
            break;
        }
    }
    Dictionary out;
    out["event_id"] = ids;
    out["tick"] = ticks;
    out["phase"] = phase;
    out["type"] = type;
    out["source"] = source;
    out["flags"] = flags;
    out["entity_handle"] = entity_handle;
    out["entity_id"] = entity;
    out["cell_idx"] = cell;
    out["payload_schema"] = schema;
    out["value_i64"] = value;
    out["payload_i0"] = p0;
    out["payload_i1"] = p1;
    out["payload_i2"] = p2;
    out["payload_i3"] = p3;
    out["count"] = ids.size();
    out["fallback"] = false;
    return out;
}
