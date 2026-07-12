#include "world_ext.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <limits>

namespace pk {

using namespace godot;

namespace {

constexpr int PK_EVENT_VEGETATION_SUCCESSION = 1;
constexpr int PK_EVENT_TERRAIN_FLIP = 2;
constexpr int PK_EVENT_WEATHER_FRONT_CHANGED = 3;
constexpr int PK_EVENT_VISUAL_DIRTY_INTENT = 4;
constexpr int PK_EVENT_ECONOMY_EPOCH_COMMITTED = 5;

constexpr int PK_EVENT_SOURCE_NATIVE = 1;
constexpr int PK_EVENT_SOURCE_GDSCRIPT = 2;
constexpr int PK_EVENT_SOURCE_DEBUG = 3;

constexpr int PK_PAYLOAD_NONE = 0;
constexpr int PK_PAYLOAD_SUCCESSION_V1 = 1; // i0=old_veg, i1=new_veg
constexpr int PK_PAYLOAD_ECONOMY_EPOCH_V1 = 2; // i0=epoch, i1=newest id, i2=count

static int64_t event_i64_at(const PackedInt64Array &arr, int idx, int64_t fallback) {
    return (idx >= 0 && idx < arr.size()) ? arr[idx] : fallback;
}

static int event_i32_at(const PackedInt32Array &arr, int idx, int fallback) {
    return (idx >= 0 && idx < arr.size()) ? arr[idx] : fallback;
}

static PackedInt32Array dictionary_i32_array(const Dictionary &d, const char *key) {
    if (!d.has(key)) {
        return PackedInt32Array();
    }
    Variant v = d[key];
    if (v.get_type() == Variant::PACKED_INT32_ARRAY) {
        return v;
    }
    return PackedInt32Array();
}

static PackedInt64Array dictionary_i64_array(const Dictionary &d, const char *key) {
    if (!d.has(key)) {
        return PackedInt64Array();
    }
    Variant v = d[key];
    if (v.get_type() == Variant::PACKED_INT64_ARRAY) {
        return v;
    }
    return PackedInt64Array();
}

} // namespace

int64_t DCWorldExt::_emit_gameplay_event(int64_t tick,
                                         int32_t phase,
                                         int32_t type,
                                         int32_t source,
                                         int32_t flags,
                                         int32_t entity_id,
                                         int32_t cell_idx,
                                         int32_t payload_schema,
                                         int32_t payload_i0,
                                         int32_t payload_i1,
                                         int32_t payload_i2,
                                         int32_t payload_i3) {
    if (_gameplay_max_events <= 0) {
        _gameplay_dropped_event_count += 1;
        if (_gameplay_first_dropped_event_id == 0) {
            _gameplay_first_dropped_event_id = _gameplay_next_event_id;
        }
        return 0;
    }
    GameplayEventRecord ev;
    ev.event_id = _gameplay_next_event_id++;
    ev.tick = tick;
    ev.phase = phase;
    ev.type = type;
    ev.source = source;
    ev.flags = flags;
    ev.entity_id = entity_id;
    ev.cell_idx = cell_idx;
    ev.payload_schema = payload_schema;
    ev.payload_i0 = payload_i0;
    ev.payload_i1 = payload_i1;
    ev.payload_i2 = payload_i2;
    ev.payload_i3 = payload_i3;
    _gameplay_events.push_back(ev);
    while (int(_gameplay_events.size()) > _gameplay_max_events) {
        if (_gameplay_first_dropped_event_id == 0) {
            _gameplay_first_dropped_event_id = _gameplay_events.front().event_id;
        }
        _gameplay_events.erase(_gameplay_events.begin());
        _gameplay_dropped_event_count += 1;
    }
    return ev.event_id;
}

void DCWorldExt::_emit_succession_events(const PackedInt32Array &indices,
                                         const PackedByteArray &to_veg,
                                         const uint8_t *old_veg,
                                         int old_veg_size,
                                         int64_t tick,
                                         int32_t phase,
                                         int32_t source) {
    const int n = std::min(indices.size(), to_veg.size());
    const int32_t *IDX = indices.ptr();
    const uint8_t *NEW_VEG = to_veg.ptr();
    for (int i = 0; i < n; ++i) {
        const int cell_idx = IDX[i];
        const int old_id = (old_veg != nullptr && cell_idx >= 0 && cell_idx < old_veg_size) ? int(old_veg[cell_idx]) : -1;
        const int new_id = int(NEW_VEG[i]);
        _emit_gameplay_event(tick,
                             phase,
                             PK_EVENT_VEGETATION_SUCCESSION,
                             source,
                             0,
                             cell_idx,
                             cell_idx,
                             PK_PAYLOAD_SUCCESSION_V1,
                             old_id,
                             new_id,
                             0,
                             0);
    }
}

Dictionary DCWorldExt::get_gameplay_event_schema() const {
    Dictionary schema;
    schema["version"] = 1;
    schema["format"] = String("columnar_packed_arrays");

    Dictionary types;
    types["VEGETATION_SUCCESSION"] = PK_EVENT_VEGETATION_SUCCESSION;
    types["TERRAIN_FLIP"] = PK_EVENT_TERRAIN_FLIP;
    types["WEATHER_FRONT_CHANGED"] = PK_EVENT_WEATHER_FRONT_CHANGED;
    types["VISUAL_DIRTY_INTENT"] = PK_EVENT_VISUAL_DIRTY_INTENT;
    types["ECONOMY_EPOCH_COMMITTED"] = PK_EVENT_ECONOMY_EPOCH_COMMITTED;
    schema["types"] = types;

    Dictionary sources;
    sources["NATIVE"] = PK_EVENT_SOURCE_NATIVE;
    sources["GDSCRIPT"] = PK_EVENT_SOURCE_GDSCRIPT;
    sources["DEBUG"] = PK_EVENT_SOURCE_DEBUG;
    schema["sources"] = sources;

    Dictionary payloads;
    payloads["NONE"] = PK_PAYLOAD_NONE;
    payloads["SUCCESSION_V1"] = PK_PAYLOAD_SUCCESSION_V1;
    payloads["ECONOMY_EPOCH_V1"] = PK_PAYLOAD_ECONOMY_EPOCH_V1;
    schema["payload_schemas"] = payloads;
    schema["fields"] = Array::make(
        "event_id", "tick", "phase", "type", "source", "flags", "entity_id",
        "cell_idx", "payload_schema", "payload_i0", "payload_i1", "payload_i2", "payload_i3");
    return schema;
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
    PackedInt32Array entity_arr = dictionary_i32_array(batch, "entity_id");
    PackedInt32Array cell_arr = dictionary_i32_array(batch, "cell_idx");
    PackedInt32Array schema_arr = dictionary_i32_array(batch, "payload_schema");
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
    for (int i = 0; i < count; ++i) {
        const int event_type = event_i32_at(type_arr, i, type_scalar);
        if (event_type <= 0) {
            continue;
        }
        const int cell_idx = event_i32_at(cell_arr, i, -1);
        const int entity_id = event_i32_at(entity_arr, i, cell_idx);
        const int64_t id = _emit_gameplay_event(
            event_i64_at(tick_arr, i, tick_scalar),
            event_i32_at(phase_arr, i, phase_scalar),
            event_type,
            event_i32_at(source_arr, i, source_scalar),
            event_i32_at(flags_arr, i, flags_scalar),
            entity_id,
            cell_idx,
            event_i32_at(schema_arr, i, schema_scalar),
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
        }
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    _gameplay_last_native_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    out["published"] = published;
    out["first_event_id"] = first_id;
    out["last_event_id"] = last_id;
    out["event_count"] = int(_gameplay_events.size());
    out["dropped_event_count"] = _gameplay_dropped_event_count;
    out["native_ms"] = _gameplay_last_native_ms;
    out["fallback"] = false;
    return out;
}

void DCWorldExt::_append_gameplay_event_to_arrays(const GameplayEventRecord &ev,
                                                  PackedInt64Array &ids,
                                                  PackedInt64Array &ticks,
                                                  PackedInt32Array &phase,
                                                  PackedInt32Array &type,
                                                  PackedInt32Array &source,
                                                  PackedInt32Array &flags,
                                                  PackedInt32Array &entity,
                                                  PackedInt32Array &cell,
                                                  PackedInt32Array &schema,
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
    entity.append(ev.entity_id);
    cell.append(ev.cell_idx);
    schema.append(ev.payload_schema);
    p0.append(ev.payload_i0);
    p1.append(ev.payload_i1);
    p2.append(ev.payload_i2);
    p3.append(ev.payload_i3);
}

Dictionary DCWorldExt::poll_gameplay_events(Dictionary opts) {
    auto t0 = std::chrono::high_resolution_clock::now();
    const StringName consumer_id = opts.has("consumer_id") ? StringName(opts["consumer_id"]) : StringName("default");
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
    PackedInt32Array entity;
    PackedInt32Array cell;
    PackedInt32Array schema;
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
        _append_gameplay_event_to_arrays(ev, ids, ticks, phase, type, source, flags, entity, cell, schema, p0, p1, p2, p3);
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
    out["entity_id"] = entity;
    out["cell_idx"] = cell;
    out["payload_schema"] = schema;
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
    const int64_t prev = _gameplay_consumer_ack.has(consumer_id) ? _gameplay_consumer_ack[consumer_id] : 0;
    const int64_t next = std::max(prev, up_to_event_id);
    _gameplay_consumer_ack[consumer_id] = next;
    out["consumer_id"] = consumer_id;
    out["previous_event_id"] = prev;
    out["acked_event_id"] = next;
    out["fallback"] = false;
    return out;
}

Dictionary DCWorldExt::replay_gameplay_events(Dictionary opts) const {
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
    PackedInt32Array entity;
    PackedInt32Array cell;
    PackedInt32Array schema;
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
        _append_gameplay_event_to_arrays(ev, ids, ticks, phase, type, source, flags, entity, cell, schema, p0, p1, p2, p3);
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
    out["entity_id"] = entity;
    out["cell_idx"] = cell;
    out["payload_schema"] = schema;
    out["payload_i0"] = p0;
    out["payload_i1"] = p1;
    out["payload_i2"] = p2;
    out["payload_i3"] = p3;
    out["count"] = ids.size();
    out["fallback"] = false;
    return out;
}

Dictionary DCWorldExt::snapshot_gameplay_event_journal(Dictionary opts) const {
    Dictionary replay_opts = opts;
    Dictionary out = replay_gameplay_events(replay_opts);
    out["version"] = 1;
    out["next_event_id"] = _gameplay_next_event_id;
    out["dropped_event_count"] = _gameplay_dropped_event_count;
    out["first_dropped_event_id"] = _gameplay_first_dropped_event_id;
    out["max_events"] = _gameplay_max_events;
    return out;
}

Dictionary DCWorldExt::restore_gameplay_event_journal(Dictionary snapshot) {
    _gameplay_events.clear();
    _gameplay_consumer_ack.clear();
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
    PackedInt32Array entity = dictionary_i32_array(snapshot, "entity_id");
    PackedInt32Array cell = dictionary_i32_array(snapshot, "cell_idx");
    PackedInt32Array schema = dictionary_i32_array(snapshot, "payload_schema");
    PackedInt32Array p0 = dictionary_i32_array(snapshot, "payload_i0");
    PackedInt32Array p1 = dictionary_i32_array(snapshot, "payload_i1");
    PackedInt32Array p2 = dictionary_i32_array(snapshot, "payload_i2");
    PackedInt32Array p3 = dictionary_i32_array(snapshot, "payload_i3");
    const int n = ids.size();
    _gameplay_events.reserve(n);
    for (int i = 0; i < n; ++i) {
        GameplayEventRecord ev;
        ev.event_id = ids[i];
        ev.tick = event_i64_at(ticks, i, 0);
        ev.phase = event_i32_at(phase, i, 0);
        ev.type = event_i32_at(type, i, 0);
        ev.source = event_i32_at(source, i, 0);
        ev.flags = event_i32_at(flags, i, 0);
        ev.entity_id = event_i32_at(entity, i, -1);
        ev.cell_idx = event_i32_at(cell, i, ev.entity_id);
        ev.payload_schema = event_i32_at(schema, i, 0);
        ev.payload_i0 = event_i32_at(p0, i, 0);
        ev.payload_i1 = event_i32_at(p1, i, 0);
        ev.payload_i2 = event_i32_at(p2, i, 0);
        ev.payload_i3 = event_i32_at(p3, i, 0);
        _gameplay_events.push_back(ev);
        if (ev.event_id >= _gameplay_next_event_id) {
            _gameplay_next_event_id = ev.event_id + 1;
        }
    }
    Dictionary out;
    out["restored"] = int(_gameplay_events.size());
    out["next_event_id"] = _gameplay_next_event_id;
    out["fallback"] = false;
    return out;
}

Dictionary DCWorldExt::clear_gameplay_events(Dictionary opts) {
    const bool keep_cursors = bool(opts.get("keep_cursors", false));
    _gameplay_events.clear();
    if (!keep_cursors) {
        _gameplay_consumer_ack.clear();
    }
    if (bool(opts.get("reset_ids", false))) {
        _gameplay_next_event_id = 1;
    }
    Dictionary out;
    out["event_count"] = 0;
    out["next_event_id"] = _gameplay_next_event_id;
    out["fallback"] = false;
    return out;
}

Dictionary DCWorldExt::get_gameplay_event_bus_report() const {
    Dictionary out;
    out["event_count"] = int(_gameplay_events.size());
    out["max_events"] = _gameplay_max_events;
    out["oldest_event_id"] = _gameplay_events.empty() ? 0 : _gameplay_events.front().event_id;
    out["newest_event_id"] = _gameplay_events.empty() ? 0 : _gameplay_events.back().event_id;
    out["next_event_id"] = _gameplay_next_event_id;
    out["dropped_event_count"] = _gameplay_dropped_event_count;
    out["first_dropped_event_id"] = _gameplay_first_dropped_event_id;
    out["native_ms"] = _gameplay_last_native_ms;
    out["fallback_reason"] = _gameplay_last_fallback_reason;

    Dictionary lag;
    const int64_t newest = _gameplay_events.empty() ? 0 : _gameplay_events.back().event_id;
    for (const KeyValue<StringName, int64_t> &kv : _gameplay_consumer_ack) {
        lag[kv.key] = newest - kv.value;
    }
    out["consumer_lag"] = lag;
    out["fallback"] = false;
    return out;
}

} // namespace pk
