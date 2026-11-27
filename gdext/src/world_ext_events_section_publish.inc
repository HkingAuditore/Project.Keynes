bool DCWorldExt::publish_legacy_military_events(std::vector<RuntimeEventsRecord> &records) {
    for (auto &record : records) {
        record.event_id = _emit_gameplay_event(record.tick, record.phase, record.type,
            record.source, record.flags, record.entity_handle, record.entity_id, record.cell_idx,
            record.payload_schema, record.value_i64, record.payload_i0, record.payload_i1,
            record.payload_i2, record.payload_i3);
    }
    records.erase(std::remove_if(records.begin(), records.end(), [](const auto &record) {
        return record.event_id <= 0;
    }), records.end());
    if (records.empty()) return true;
    std::string error;
    const bool queued = queue_events_bridge_batch(_runtime_host.get(), records, error);
    return queued || !_runtime_host || !_runtime_host->events_worker_authoritative();
}

Dictionary DCWorldExt::publish_gameplay_events(Dictionary batch) {
    auto t0 = std::chrono::high_resolution_clock::now();
    Dictionary out;
    const int max_events = int(batch.get("max_events", _gameplay_max_events));
    if (max_events > 0) {
        _gameplay_max_events = max_events;
    }

    PackedInt64Array tick_arr = dictionary_i64_array(batch, "tick");
    PackedInt32Array phase_arr = dictionary_i32_array(batch, "phase");
    PackedInt32Array type_arr = dictionary_i32_array(batch, "type");
    PackedInt32Array source_arr = dictionary_i32_array(batch, "source");
    PackedInt32Array flags_arr = dictionary_i32_array(batch, "flags");
    PackedInt64Array entity_handle_arr = dictionary_i64_array(batch, "entity_handle");
    PackedInt32Array entity_arr = dictionary_i32_array(batch, "entity_id");
    PackedInt32Array cell_arr = dictionary_i32_array(batch, "cell_idx");
    PackedInt32Array schema_arr = dictionary_i32_array(batch, "payload_schema");
    PackedInt64Array value_arr = dictionary_i64_array(batch, "value_i64");
    PackedInt32Array p0_arr = dictionary_i32_array(batch, "payload_i0");
    PackedInt32Array p1_arr = dictionary_i32_array(batch, "payload_i1");
    PackedInt32Array p2_arr = dictionary_i32_array(batch, "payload_i2");
    PackedInt32Array p3_arr = dictionary_i32_array(batch, "payload_i3");

    int count = int(batch.get("count", type_arr.size()));
    if (count <= 0) {
        count = std::max(cell_arr.size(), entity_arr.size());
    }
    const int64_t tick_scalar = int64_t(batch.get("tick_scalar", int64_t(batch.get("tick", 0))));
    const int phase_scalar = int(batch.get("phase_scalar", int(batch.get("phase", 0))));
    const int type_scalar = int(batch.get("type_scalar", int(batch.get("type", 0))));
    const int source_scalar = int(batch.get("source_scalar", int(batch.get("source", PK_EVENT_SOURCE_GDSCRIPT))));
    const int flags_scalar = int(batch.get("flags_scalar", int(batch.get("flags", 0))));
    const int schema_scalar = int(batch.get("payload_schema_scalar", int(batch.get("payload_schema", PK_PAYLOAD_NONE))));

    if (count <= 0) {
        out["published"] = 0;
        out["fallback"] = false;
        out["reason"] = String("empty_batch");
        return out;
    }

    int published = 0;
    int64_t first_id = 0;
    int64_t last_id = 0;
    std::vector<RuntimeEventsRecord> bridge_records;
    bridge_records.reserve(RUNTIME_EVENTS_MAX_BATCH_RECORDS);
    _events_bridge_queued = 0;
    _events_bridge_failed = 0;
    _events_bridge_last_reason = String();
    for (int i = 0; i < count; ++i) {
        const int event_type = event_i32_at(type_arr, i, type_scalar);
        if (event_type <= 0) {
            continue;
        }
        const int cell_idx = event_i32_at(cell_arr, i, -1);
        const int entity_id = event_i32_at(entity_arr, i, cell_idx);
        const uint64_t entity_handle = static_cast<uint64_t>(event_i64_at(
            entity_handle_arr, i, entity_id >= 0 ? int64_t(entity_id) : int64_t{0}));
        const int64_t id = _emit_gameplay_event(
            event_i64_at(tick_arr, i, tick_scalar),
            event_i32_at(phase_arr, i, phase_scalar),
            event_type,
            event_i32_at(source_arr, i, source_scalar),
            event_i32_at(flags_arr, i, flags_scalar),
            entity_handle,
            entity_id,
            cell_idx,
            event_i32_at(schema_arr, i, schema_scalar),
            event_i64_at(value_arr, i, 1),
            event_i32_at(p0_arr, i, 0),
            event_i32_at(p1_arr, i, 0),
            event_i32_at(p2_arr, i, 0),
            event_i32_at(p3_arr, i, 0));
        if (id > 0) {
            if (first_id == 0) {
                first_id = id;
            }
            last_id = id;
            published += 1;
            RuntimeEventsRecord pod_record;
            pod_record.event_id = id;
            pod_record.tick = event_i64_at(tick_arr, i, tick_scalar);
            pod_record.phase = event_i32_at(phase_arr, i, phase_scalar);
            pod_record.type = event_type;
            pod_record.source = event_i32_at(source_arr, i, source_scalar);
            pod_record.flags = event_i32_at(flags_arr, i, flags_scalar);
            pod_record.entity_handle = entity_handle;
            pod_record.entity_id = entity_id;
            pod_record.cell_idx = cell_idx;
            pod_record.payload_schema = event_i32_at(schema_arr, i, schema_scalar);
            pod_record.value_i64 = event_i64_at(value_arr, i, 1);
            pod_record.payload_i0 = event_i32_at(p0_arr, i, 0);
            pod_record.payload_i1 = event_i32_at(p1_arr, i, 0);
            pod_record.payload_i2 = event_i32_at(p2_arr, i, 0);
            pod_record.payload_i3 = event_i32_at(p3_arr, i, 0);
            bridge_records.push_back(pod_record);
            if (bridge_records.size() == RUNTIME_EVENTS_MAX_BATCH_RECORDS) {
                std::string bridge_error;
                if (queue_events_bridge_batch(_runtime_host.get(), bridge_records,
                                               bridge_error)) {
                    ++_events_bridge_queued;
                } else {
                    ++_events_bridge_failed;
                    _events_bridge_last_reason = String(bridge_error.c_str());
                }
                bridge_records.clear();
            }
        }
    }
    if (!bridge_records.empty()) {
        std::string bridge_error;
        if (queue_events_bridge_batch(_runtime_host.get(), bridge_records,
                                      bridge_error)) {
            ++_events_bridge_queued;
        } else {
            ++_events_bridge_failed;
            _events_bridge_last_reason = String(bridge_error.c_str());
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    _gameplay_last_native_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    const bool worker_authoritative =
        _runtime_host && _runtime_host->events_worker_authoritative();
    const bool durable = !worker_authoritative || _events_bridge_failed == 0;
    if (!durable) {
        published = 0;
        first_id = 0;
        last_id = 0;
    }
    out["ok"] = durable;
    out["published"] = published;
    out["first_event_id"] = first_id;
    out["last_event_id"] = last_id;
    out["event_count"] = int(_gameplay_events.size());
    out["dropped_event_count"] = _gameplay_dropped_event_count;
    out["native_ms"] = _gameplay_last_native_ms;
    out["fallback"] = false;
    out["events_bridge_queued"] = static_cast<int64_t>(_events_bridge_queued);
    out["events_bridge_failed"] = static_cast<int64_t>(_events_bridge_failed);
    out["events_bridge_reason"] = _events_bridge_last_reason;
    out["authority_source"] = worker_authoritative
        ? String("runtime_events_worker") : String("legacy_gameplay_event_bus");
    out["legacy_journal_used"] = !worker_authoritative;
    return out;
}

void DCWorldExt::_append_gameplay_event_to_arrays(const GameplayEventRecord &ev,
                                                  PackedInt64Array &ids,
                                                  PackedInt64Array &ticks,
                                                  PackedInt32Array &phase,
                                                  PackedInt32Array &type,
                                                  PackedInt32Array &source,
                                                  PackedInt32Array &flags,
                                                  PackedInt64Array &entity_handle,
                                                  PackedInt32Array &entity,
                                                  PackedInt32Array &cell,
                                                  PackedInt32Array &schema,
                                                  PackedInt64Array &value,
                                                  PackedInt32Array &p0,
                                                  PackedInt32Array &p1,
                                                  PackedInt32Array &p2,
                                                  PackedInt32Array &p3) const {
    ids.append(ev.event_id);
    ticks.append(ev.tick);
    phase.append(ev.phase);
    type.append(ev.type);
    source.append(ev.source);
    flags.append(ev.flags);
    entity_handle.append(static_cast<int64_t>(ev.entity_handle));
    entity.append(ev.entity_id);
    cell.append(ev.cell_idx);
    schema.append(ev.payload_schema);
    value.append(ev.value_i64);
    p0.append(ev.payload_i0);
    p1.append(ev.payload_i1);
    p2.append(ev.payload_i2);
    p3.append(ev.payload_i3);
}
