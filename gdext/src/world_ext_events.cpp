#include "world_ext.h"
#include "economy_runtime.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <limits>
#include <unordered_set>

namespace pk {

using namespace godot;

namespace {

constexpr int PK_EVENT_VEGETATION_SUCCESSION = 1;
constexpr int PK_EVENT_TERRAIN_FLIP = 2;
constexpr int PK_EVENT_WEATHER_FRONT_CHANGED = 3;
constexpr int PK_EVENT_VISUAL_DIRTY_INTENT = 4;
constexpr int PK_EVENT_ECONOMY_EPOCH_COMMITTED = 5;
constexpr int PK_EVENT_ECONOMY_CONSTRUCTION_COMPLETED = 6;
constexpr int PK_EVENT_ECONOMY_TRADE_ARRIVED = 7;
constexpr int PK_EVENT_ECONOMY_SOCIAL_PRESSURE = 8;
constexpr int PK_EVENT_TARIFF_SUBSIDY_INTENT = 15;

constexpr int PK_EVENT_SOURCE_NATIVE = 1;
constexpr int PK_EVENT_SOURCE_GDSCRIPT = 2;
constexpr int PK_EVENT_SOURCE_DEBUG = 3;
constexpr int PK_EVENT_SOURCE_EFFECT = 4;
constexpr int PK_EFFECT_ACTION_GAMEPLAY = 4;
constexpr int PK_EFFECT_ACTION_PUBLISH_EVENT = 5;
constexpr int PK_EFFECT_ACTION_CUSTOM_DOMAIN = 6;
constexpr int PK_EFFECT_GAMEPLAY_DOMAIN = 3;
constexpr int PK_EFFECT_PUBLISH_DOMAIN = 4;
constexpr int PK_EFFECT_CUSTOM_DOMAIN = 6;
constexpr int PK_EFFECT_CUSTOM_AUDIT_OPCODE = 1;
constexpr int PK_EFFECT_CUSTOM_CANAL_COMMIT_OPCODE = 2;

constexpr int PK_PAYLOAD_NONE = 0;
constexpr int PK_PAYLOAD_SUCCESSION_V1 = 1; // i0=old_veg, i1=new_veg
constexpr int PK_PAYLOAD_ECONOMY_EPOCH_V1 = 2; // i0=epoch, i1=newest id, i2=count
constexpr int PK_PAYLOAD_ECONOMY_CONSTRUCTION_V1 = 3; // i0=type hash, i1=type id, i2=owner signature, i3=sponsor family index
constexpr int PK_PAYLOAD_ECONOMY_TRADE_V1 = 4; // i0=source, i1=destination, i2=good, i3=inter-country
// i0=new level, i1=worst dimension, i2=worst need, i3=previous level;
// value=population-weighted composite Q16, entity_id=population, flags=1 when
// the level fell.
constexpr int PK_PAYLOAD_SOCIAL_PRESSURE_V1 = 5;
// cell=destination, entity_id=order, value=quantity; i0=source,
// i1=source country slot, i2=destination country slot, i3=good.
constexpr int PK_PAYLOAD_ECONOMY_TRADE_V2 = 8;

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
                                         uint64_t entity_handle,
                                         int32_t entity_id,
                                         int32_t cell_idx,
                                         int32_t payload_schema,
                                         int64_t value_i64,
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
    ev.entity_handle = entity_handle;
    ev.entity_id = entity_id;
    ev.cell_idx = cell_idx;
    ev.payload_schema = payload_schema;
    ev.value_i64 = value_i64;
    ev.payload_i0 = payload_i0;
    ev.payload_i1 = payload_i1;
    ev.payload_i2 = payload_i2;
    ev.payload_i3 = payload_i3;
    _gameplay_events.push_back(ev);
    while (int(_gameplay_events.size()) > _gameplay_max_events) {
        if (_gameplay_first_dropped_event_id == 0) {
            _gameplay_first_dropped_event_id = _gameplay_events.front().event_id;
        }
        _gameplay_events.pop_front();
        _gameplay_dropped_event_count += 1;
    }
    return ev.event_id;
}

bool DCWorldExt::submit_effect_gameplay_commands_pod(
        const EffectGameplayCommand *commands, size_t count,
        std::vector<int64_t> &request_ids, std::string &error) {
    request_ids.clear();
    if ((commands == nullptr && count != 0) || count > 1000000ULL) {
        error = "effect_gameplay_command_batch_invalid";
        return false;
    }
    if (_effect_gameplay_commands.size() + count > 1000000ULL ||
        _effect_gameplay_results.size() + count > 1000000ULL) {
        error = "effect_gameplay_queue_capacity_exceeded";
        return false;
    }
    std::vector<EffectGameplayCommand> staged;
    staged.reserve(count);
    std::unordered_map<uint64_t, int64_t> staged_keys;
    request_ids.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        const EffectGameplayCommand &source = commands[i];
        const bool gameplay = source.action == PK_EFFECT_ACTION_GAMEPLAY &&
            source.domain == PK_EFFECT_GAMEPLAY_DOMAIN && source.opcode > 0;
        const bool publish = source.action == PK_EFFECT_ACTION_PUBLISH_EVENT &&
            source.domain == PK_EFFECT_PUBLISH_DOMAIN && source.opcode > 0;
        const bool custom_audit = source.action == PK_EFFECT_ACTION_CUSTOM_DOMAIN &&
            source.domain == PK_EFFECT_CUSTOM_DOMAIN &&
            (source.opcode == PK_EFFECT_CUSTOM_AUDIT_OPCODE ||
             source.opcode == PK_EFFECT_CUSTOM_CANAL_COMMIT_OPCODE);
        if ((!gameplay && !publish && !custom_audit) || source.effective_day < 0 ||
            source.idempotency_key == 0) {
            error = source.action == PK_EFFECT_ACTION_PUBLISH_EVENT
                ? "effect_publish_event_command_invalid"
                : "effect_gameplay_native_consumer_unregistered";
            return false;
        }
        const auto existing = _effect_gameplay_idempotency.find(
            source.idempotency_key);
        if (existing != _effect_gameplay_idempotency.end()) {
            request_ids.push_back(existing->second);
            continue;
        }
        const auto duplicate = staged_keys.find(source.idempotency_key);
        if (duplicate != staged_keys.end()) {
            request_ids.push_back(duplicate->second);
            continue;
        }
        EffectGameplayCommand command = source;
        command.request_id = _effect_gameplay_next_request_id +
            static_cast<int64_t>(staged.size());
        staged_keys.emplace(command.idempotency_key, command.request_id);
        request_ids.push_back(command.request_id);
        staged.push_back(command);
    }
    if (_effect_gameplay_next_request_id > std::numeric_limits<int64_t>::max() -
            static_cast<int64_t>(staged.size())) {
        error = "effect_gameplay_request_id_exhausted";
        return false;
    }
    for (const EffectGameplayCommand &command : staged) {
        _effect_gameplay_idempotency.emplace(command.idempotency_key,
            command.request_id);
        _effect_gameplay_results.emplace(command.request_id,
            EffectGameplayCommandResult{});
        _effect_gameplay_commands.push_back(command);
    }
    _effect_gameplay_next_request_id += static_cast<int64_t>(staged.size());
    return true;
}

bool DCWorldExt::effect_gameplay_command_result_pod(int64_t request_id,
        bool &complete, bool &ok, std::string &reason) const {
    complete = false;
    ok = false;
    reason.clear();
    const auto found = _effect_gameplay_results.find(request_id);
    if (found == _effect_gameplay_results.end()) {
        reason = "effect_gameplay_request_unknown";
        return false;
    }
    complete = found->second.complete != 0;
    ok = found->second.ok != 0;
    reason = found->second.reason;
    return true;
}

bool DCWorldExt::gameplay_effect_should_run(int64_t day_index) const {
    for (const EffectGameplayCommand &command : _effect_gameplay_commands)
        if (command.effective_day <= day_index) return true;
    return false;
}

Dictionary DCWorldExt::run_gameplay_effects(int64_t day_index) {
    Dictionary out;
    int32_t committed = 0;
    int32_t rejected = 0;
    std::vector<EffectGameplayCommand> retained;
    retained.reserve(_effect_gameplay_commands.size());
    for (const EffectGameplayCommand &command : _effect_gameplay_commands) {
        if (command.effective_day > day_index) {
            retained.push_back(command);
            continue;
        }
        EffectGameplayCommandResult &result = _effect_gameplay_results[
            command.request_id];
        const auto duplicate = _effect_gameplay_event_ids.find(
            command.idempotency_key);
        if (duplicate != _effect_gameplay_event_ids.end()) {
            result.complete = 1;
            result.ok = 1;
            result.reason.clear();
            ++committed;
            continue;
        }
        if (command.action == PK_EFFECT_ACTION_CUSTOM_DOMAIN &&
            command.domain == PK_EFFECT_CUSTOM_DOMAIN &&
            command.opcode == PK_EFFECT_CUSTOM_CANAL_COMMIT_OPCODE) {
            std::string commit_error;
            if (!commit_canal_effect(command.target_handle,
                    command.target_generation, command.idempotency_key,
                    commit_error)) {
                result.complete = 1;
                result.ok = 0;
                result.reason = commit_error.empty()
                    ? "canal_commit_failed" : commit_error;
                ++rejected;
                continue;
            }
            _effect_gameplay_event_ids.emplace(command.idempotency_key, -1);
            result.complete = 1;
            result.ok = 1;
            result.reason.clear();
            ++committed;
            continue;
        }
        if (_gameplay_max_events <= 0) {
            result.complete = 1;
            result.ok = 0;
            result.reason = "effect_publish_event_journal_disabled";
            ++rejected;
            continue;
        }
        const int64_t event_id = _emit_gameplay_event(command.effective_day, 95,
            command.opcode, PK_EVENT_SOURCE_EFFECT, 0, command.target_handle,
            static_cast<int32_t>(command.payload[0]),
            static_cast<int32_t>(command.payload[1]),
            static_cast<int32_t>(command.payload[2]), command.value_i64,
            static_cast<int32_t>(command.payload[0]),
            static_cast<int32_t>(command.payload[1]),
            static_cast<int32_t>(command.payload[2]),
            static_cast<int32_t>(command.payload[3]));
        if (event_id <= 0) {
            result.complete = 1;
            result.ok = 0;
            result.reason = "effect_publish_event_journal_overflow";
            ++rejected;
            continue;
        }
        _effect_gameplay_event_ids.emplace(command.idempotency_key, event_id);
        result.complete = 1;
        result.ok = 1;
        result.reason.clear();
        ++committed;
    }
    _effect_gameplay_commands.swap(retained);
    out["ok"] = rejected == 0;
    out["committed"] = committed;
    out["rejected"] = rejected;
    out["pending"] = static_cast<int32_t>(_effect_gameplay_commands.size());
    out["done"] = _effect_gameplay_commands.empty();
    out["stage"] = "gameplay_effect";
    out["path"] = "GAMEPLAY_EFFECT";
    return out;
}

bool DCWorldExt::commit_canal_effect(
        uint64_t project_handle, uint32_t project_generation,
        uint64_t idempotency_key, std::string &error) {
    if (idempotency_key == 0 || project_handle == 0 || project_generation == 0) {
        error = "canal_commit_identity_invalid";
        return false;
    }
    if (_canal_commit_idempotency.find(idempotency_key) !=
            _canal_commit_idempotency.end()) return true;
    if (_economy_runtime == nullptr || !_bound) {
        error = "canal_commit_runtime_unavailable";
        return false;
    }
    const int mask_sid = component_id(StringName("cell_canal_edge_mask"));
    const int water_sid = component_id(StringName("cell_canal_water"));
    if (mask_sid < 0 || mask_sid >= _slots.size() || water_sid < 0 ||
        water_sid >= _slots.size() || _slots[mask_sid].dtype != SlotDType::U8 ||
        _slots[water_sid].dtype != SlotDType::F32) {
        error = "canal_commit_slots_unavailable";
        return false;
    }
    std::vector<int32_t> route_cells;
    std::vector<int32_t> route_dirs;
    uint64_t topology_hash = 0;
    NativeEconomyRuntime *runtime =
        static_cast<NativeEconomyRuntime *>(_economy_runtime);
    if (!runtime->canal_project_commit_payload(project_handle,
            project_generation, route_cells, route_dirs, topology_hash, error))
        return false;
    if (route_cells.size() < 2 || route_cells.size() > 33 ||
        route_dirs.size() + 1 != route_cells.size()) {
        error = "canal_commit_route_shape_invalid";
        return false;
    }
    PackedByteArray next_mask = _slots[mask_sid].arr_u8;
    const int32_t cell_count = next_mask.size();
    if (topology_hash == 0 || runtime->canal_topology_hash() != topology_hash) {
        error = "canal_commit_topology_stale";
        return false;
    }
    if (_map_data == nullptr ||
        !_map_data->has_method(StringName("neighbor_indices_packed"))) {
        error = "canal_commit_neighbors_unavailable";
        return false;
    }
    const Variant neighbor_variant = _map_data->call(
        StringName("neighbor_indices_packed"));
    if (neighbor_variant.get_type() != Variant::PACKED_INT32_ARRAY) {
        error = "canal_commit_neighbors_invalid";
        return false;
    }
    const PackedInt32Array neighbors = neighbor_variant;
    if (neighbors.size() != cell_count * 6) {
        error = "canal_commit_neighbors_invalid";
        return false;
    }
    const int32_t *neighbor_ptr = neighbors.ptr();
    std::unordered_set<int32_t> unique_cells;
    for (size_t edge = 0; edge < route_dirs.size(); ++edge) {
        const int32_t from = route_cells[edge];
        const int32_t to = route_cells[edge + 1];
        const int32_t direction = route_dirs[edge];
        if (from < 0 || from >= cell_count || to < 0 || to >= cell_count ||
            from == to || direction < 0 || direction >= 6 ||
            neighbor_ptr[from * 6 + direction] != to ||
            neighbor_ptr[to * 6 + ((direction + 3) % 6)] != from ||
            !unique_cells.insert(from).second) {
            error = "canal_commit_route_invalid";
            return false;
        }
    }
    if (!unique_cells.insert(route_cells.back()).second) {
        error = "canal_commit_route_repeats_cell";
        return false;
    }
    uint8_t *mask = next_mask.ptrw();
    for (size_t edge = 0; edge < route_dirs.size(); ++edge) {
        const int32_t from = route_cells[edge];
        const int32_t to = route_cells[edge + 1];
        const int32_t direction = route_dirs[edge];
        const int32_t reverse = (direction + 3) % 6;
        mask[from] = static_cast<uint8_t>(mask[from] | (1U << direction));
        mask[to] = static_cast<uint8_t>(mask[to] | (1U << reverse));
    }
    // One assignment publishes the fully validated route to the slot. No
    // consumer can observe a half-built canal.
    _slots.write[mask_sid].arr_u8 = next_mask;
    _flush_slot_to_map(mask_sid);
    if (!runtime->refresh_canal_topology(next_mask.ptr(),
            _slots[water_sid].arr_f32.ptr(), cell_count, error)) return false;
    ++_canal_topology_generation;
    _canal_visual_dirty_cells.insert(_canal_visual_dirty_cells.end(),
        route_cells.begin(), route_cells.end());
    std::sort(_canal_visual_dirty_cells.begin(), _canal_visual_dirty_cells.end());
    _canal_visual_dirty_cells.erase(std::unique(_canal_visual_dirty_cells.begin(),
        _canal_visual_dirty_cells.end()), _canal_visual_dirty_cells.end());
    _canal_commit_idempotency.insert(idempotency_key);
    (void)topology_hash;
    return true;
}

PackedInt32Array DCWorldExt::consume_canal_visual_dirty_cells() {
    PackedInt32Array out;
    out.resize(static_cast<int64_t>(_canal_visual_dirty_cells.size()));
    for (int64_t i = 0; i < out.size(); ++i)
        out.set(i, _canal_visual_dirty_cells[static_cast<size_t>(i)]);
    _canal_visual_dirty_cells.clear();
    return out;
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
                             0,
                             cell_idx,
                             cell_idx,
                             PK_PAYLOAD_SUCCESSION_V1,
                             1,
                             old_id,
                             new_id,
                             0,
                             0);
    }
}

Dictionary DCWorldExt::get_gameplay_event_schema() const {
    Dictionary schema;
    schema["version"] = 2;
    schema["format"] = String("columnar_packed_arrays");

    Dictionary types;
    types["VEGETATION_SUCCESSION"] = PK_EVENT_VEGETATION_SUCCESSION;
    types["TERRAIN_FLIP"] = PK_EVENT_TERRAIN_FLIP;
    types["WEATHER_FRONT_CHANGED"] = PK_EVENT_WEATHER_FRONT_CHANGED;
    types["VISUAL_DIRTY_INTENT"] = PK_EVENT_VISUAL_DIRTY_INTENT;
    types["ECONOMY_EPOCH_COMMITTED"] = PK_EVENT_ECONOMY_EPOCH_COMMITTED;
    types["ECONOMY_CONSTRUCTION_COMPLETED"] = PK_EVENT_ECONOMY_CONSTRUCTION_COMPLETED;
    types["ECONOMY_TRADE_ARRIVED"] = PK_EVENT_ECONOMY_TRADE_ARRIVED;
    types["ECONOMY_SOCIAL_PRESSURE"] = PK_EVENT_ECONOMY_SOCIAL_PRESSURE;
    types["TARIFF_SUBSIDY_INTENT"] = PK_EVENT_TARIFF_SUBSIDY_INTENT;
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
    payloads["ECONOMY_CONSTRUCTION_V1"] = PK_PAYLOAD_ECONOMY_CONSTRUCTION_V1;
    payloads["ECONOMY_TRADE_V1"] = PK_PAYLOAD_ECONOMY_TRADE_V1;
    payloads["ECONOMY_TRADE_V2"] = PK_PAYLOAD_ECONOMY_TRADE_V2;
    payloads["SOCIAL_PRESSURE_V1"] = PK_PAYLOAD_SOCIAL_PRESSURE_V1;
    schema["payload_schemas"] = payloads;
    schema["fields"] = Array::make(
        "event_id", "tick", "phase", "type", "source", "flags", "entity_handle",
        "entity_id", "cell_idx", "payload_schema", "value_i64", "payload_i0",
        "payload_i1", "payload_i2", "payload_i3");
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

Dictionary DCWorldExt::snapshot_gameplay_event_journal(Dictionary opts) const {
    Dictionary replay_opts = opts;
    Dictionary out = replay_gameplay_events(replay_opts);
    // v4 permits event_id == -1 for custom gameplay-domain commits (canals).
    // Those commands mutate authoritative slots instead of appending a normal
    // GameplayEventRecord, but still need durable idempotency evidence.
    out["version"] = 4;
    out["next_event_id"] = _gameplay_next_event_id;
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
        if (ev.event_id >= _gameplay_next_event_id) {
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
    out["next_event_id"] = _gameplay_next_event_id;
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
    out["effect_pending_commands"] = static_cast<int64_t>(_effect_gameplay_commands.size());
    out["effect_idempotency_count"] = static_cast<int64_t>(_effect_gameplay_idempotency.size());

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
