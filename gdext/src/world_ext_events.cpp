#include "runtime_narrative.h"
#include "world_ext.h"
#include "economy_runtime.h"
#include "native_simulation_host.h"

#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <chrono>
#include <limits>
#include <unordered_set>
#include <cstring>
#include <type_traits>

namespace pk {

using namespace godot;

#include "world_ext_events_section_journal_codecs.inc"

bool NativeSimulationHost::enqueue_event_consumer_ack(uint64_t consumer, int64_t event_id,
        int64_t day, uint64_t generation, bool seal) {
    const uint64_t sequence = allocate_producer_sequence(EVENTS_BRIDGE_PRODUCER_ID);
    RuntimeCommandPacket packet{};
    packet.envelope.request_id = EVENTS_BRIDGE_REQUEST_PREFIX | sequence;
    packet.envelope.producer_id = EVENTS_BRIDGE_PRODUCER_ID;
    packet.envelope.sequence = sequence;
    packet.envelope.observed_generation = generation;
    packet.envelope.requested_day = std::max<int64_t>(0, day);
    packet.envelope.effective_day = packet.envelope.requested_day;
    packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
    packet.envelope.opcode = static_cast<uint16_t>(RuntimeEventsCommand::ACK_CONSUMER);
    std::vector<uint8_t> payload;
    append_le<uint32_t>(payload, RUNTIME_EVENTS_ABI_VERSION);
    append_le<uint64_t>(payload, consumer);
    append_le<int64_t>(payload, event_id);
    packet.envelope.payload_size = static_cast<uint32_t>(payload.size());
    std::memcpy(packet.payload.data(), payload.data(), payload.size());
    return enqueue_batch_at({std::move(packet)}, nullptr, seal);
}

bool NativeSimulationHost::enqueue_legacy_event_batch(
        const std::vector<RuntimeEventsRecord> &records, int64_t effective_day,
        uint64_t generation, std::string &error) {
    const uint64_t sequence = allocate_producer_sequence(
        EVENTS_BRIDGE_PRODUCER_ID);
    const uint64_t request_id = EVENTS_BRIDGE_REQUEST_PREFIX | sequence;
    RuntimeCommandPacket packet{};
    packet.envelope.request_id = request_id;
    packet.envelope.producer_id = EVENTS_BRIDGE_PRODUCER_ID;
    packet.envelope.sequence = sequence;
    packet.envelope.observed_generation = generation;
    packet.envelope.requested_day = std::max<int64_t>(0, records.front().tick);
    packet.envelope.effective_day = std::max(packet.envelope.requested_day, effective_day);
    packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
    packet.envelope.opcode = static_cast<uint16_t>(RuntimeEventsCommand::APPEND_BATCH);
    std::vector<uint8_t> payload;
    payload.reserve(8u + records.size() * 84u);
    append_le<uint32_t>(payload, RUNTIME_EVENTS_ABI_VERSION);
    append_le<uint32_t>(payload, static_cast<uint32_t>(records.size()));
    for (const RuntimeEventsRecord &record : records) {
        append_le<int64_t>(payload, record.tick);
        append_le<int32_t>(payload, record.phase);
        append_le<int32_t>(payload, record.type);
        append_le<int32_t>(payload, record.source);
        append_le<int32_t>(payload, record.flags);
        append_le<uint64_t>(payload, record.entity_handle);
        append_le<int32_t>(payload, record.entity_id);
        append_le<int32_t>(payload, record.cell_idx);
        append_le<int32_t>(payload, record.payload_schema);
        append_le<int64_t>(payload, record.value_i64);
        append_le<int32_t>(payload, record.payload_i0);
        append_le<int32_t>(payload, record.payload_i1);
        append_le<int32_t>(payload, record.payload_i2);
        append_le<int32_t>(payload, record.payload_i3);
        append_le<uint64_t>(payload, static_cast<uint64_t>(record.event_id));
    }
    if (payload.size() > RUNTIME_MAX_COMMAND_PAYLOAD) {
        error = "events_bridge_payload_exceeded";
        return false;
    }
    packet.envelope.payload_size = static_cast<uint32_t>(payload.size());
    std::memcpy(packet.payload.data(), payload.data(), payload.size());
    if (!enqueue(std::move(packet))) {
        error = "events_bridge_queue_full";
        return false;
    }
    return true;
}

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
    ev.event_id = military_executor_active() ? _runtime_host->allocate_events_ingress_key()
        : _gameplay_next_event_id++;
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
    if (_runtime_host && _runtime_host->events_worker_authoritative()) {
        // ACTIVE Events assigns the durable event id when APPEND_BATCH commits.
        // This provisional id is only a synchronous ingress receipt; the
        // legacy deque must remain untouched so there is a single journal.
        return ev.event_id;
    }
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
        const bool custom_native = source.action == PK_EFFECT_ACTION_CUSTOM_DOMAIN &&
            source.domain == PK_EFFECT_CUSTOM_DOMAIN &&
            (source.opcode == PK_EFFECT_CUSTOM_AUDIT_OPCODE ||
             source.opcode == PK_EFFECT_CUSTOM_CANAL_COMMIT_OPCODE ||
             source.opcode == PK_EFFECT_CUSTOM_IDEOLOGY_FREE_DRAW_OPCODE);
        if ((!gameplay && !publish && !custom_native) || source.effective_day < 0 ||
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

    // In ACTIVE GAMEPLAY_EFFECT authority the main thread is an ingress
    // boundary only. Encode the typed rows once and submit them atomically to
    // the worker queue; the legacy journal path remains for SHADOW/PROBE.
    const bool worker_authoritative = _runtime_host &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::GAMEPLAY_EFFECT);
    if (worker_authoritative && !staged.empty()) {
        const RuntimeThreadReport report = _runtime_host->report();
        if (report.state == RuntimeWorkerState::STOPPED ||
            report.state == RuntimeWorkerState::STOPPING ||
            report.state == RuntimeWorkerState::FAULTED ||
            report.mode == RuntimeSimulationMode::OFF) {
            error = "gameplay_effect_worker_unavailable";
            return false;
        }
        std::vector<RuntimeCommandPacket> packets;
        packets.reserve(staged.size());
        for (const EffectGameplayCommand &command : staged) {
            const uint64_t sequence = _runtime_host->allocate_producer_sequence(
                GAMEPLAY_EFFECT_PRODUCER_ID);
            RuntimeCommandPacket packet{};
            packet.envelope.request_id = static_cast<uint64_t>(command.request_id);
            packet.envelope.producer_id = GAMEPLAY_EFFECT_PRODUCER_ID;
            packet.envelope.sequence = sequence;
            packet.envelope.observed_generation = report.generation;
            packet.envelope.requested_day = std::max<int64_t>(0, command.effective_day);
            packet.envelope.effective_day = command.effective_day;
            packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::GAMEPLAY_EFFECT);
            packet.envelope.opcode = static_cast<uint16_t>(command.opcode);
            std::vector<uint8_t> payload;
            payload.reserve(96);
            append_le<int32_t>(payload, command.action);
            append_le<int32_t>(payload, command.domain);
            append_le<int32_t>(payload, command.opcode);
            append_le<int64_t>(payload, command.effective_day);
            append_le<uint64_t>(payload, command.target_handle);
            append_le<uint32_t>(payload, command.target_generation);
            append_le<int64_t>(payload, command.value_i64);
            for (const int64_t value : command.payload) append_le<int64_t>(payload, value);
            append_le<uint64_t>(payload, command.idempotency_key);
            if (payload.size() > RUNTIME_MAX_COMMAND_PAYLOAD) {
                error = "gameplay_effect_payload_exceeded";
                return false;
            }
            packet.envelope.payload_size = static_cast<uint32_t>(payload.size());
            std::memcpy(packet.payload.data(), payload.data(), payload.size());
            packets.push_back(packet);
        }
        if (!_runtime_host->enqueue_batch(std::move(packets))) {
            error = "gameplay_effect_worker_queue_full";
            return false;
        }
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
    const bool worker_authoritative = _runtime_host &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::GAMEPLAY_EFFECT);
    if (worker_authoritative) {
        const RuntimeThreadReport report = _runtime_host->report();
        const bool worker_failed = report.state == RuntimeWorkerState::FAULTED ||
            report.state == RuntimeWorkerState::STOPPED;
        const uint32_t terminal = report.gameplay_effect_terminal;
        uint32_t completed = 0;
        std::vector<EffectGameplayCommand> retained;
        retained.reserve(_effect_gameplay_commands.size());
        for (const EffectGameplayCommand &command : _effect_gameplay_commands) {
            if (command.effective_day > day_index) { retained.push_back(command); continue; }
            EffectGameplayCommandResult &result = _effect_gameplay_results[command.request_id];
            if (worker_failed) {
                result.complete = 1; result.ok = 0; result.reason = "gameplay_effect_worker_faulted"; ++rejected;
            } else if (terminal > completed) {
                result.complete = 1; result.ok = 1; result.reason.clear(); ++completed; ++committed;
            } else {
                retained.push_back(command);
            }
        }
        _effect_gameplay_commands.swap(retained);
        out["ok"] = rejected == 0;
        out["committed"] = committed;
        out["rejected"] = rejected;
        out["pending"] = static_cast<int32_t>(_effect_gameplay_commands.size());
        out["done"] = _effect_gameplay_commands.empty();
        out["stage"] = "gameplay_effect";
        out["path"] = "GAMEPLAY_EFFECT_WORKER";
        out["worker_terminal"] = static_cast<int64_t>(terminal);
        return out;
    }
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
        if (command.action == PK_EFFECT_ACTION_CUSTOM_DOMAIN &&
            command.domain == PK_EFFECT_CUSTOM_DOMAIN &&
            command.opcode == PK_EFFECT_CUSTOM_IDEOLOGY_FREE_DRAW_OPCODE) {
            // SHADOW/probe has no worker Ideology authority to receive the
            // grant. The Effect transaction is still terminal-successful; the
            // ACTIVE path stages the typed Ideology command below.
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
    payloads["STRATUM_MOBILIZATION_V1"] = PK_PAYLOAD_STRATUM_MOBILIZATION_V1;
    schema["payload_schemas"] = payloads;
    schema["fields"] = Array::make(
        "event_id", "tick", "phase", "type", "source", "flags", "entity_handle",
        "entity_id", "cell_idx", "payload_schema", "value_i64", "payload_i0",
        "payload_i1", "payload_i2", "payload_i3");
    return schema;
}

#include "world_ext_events_section_publish.inc"

bool DCWorldExt::configure_gameplay_narrative(Dictionary packet, Dictionary state) {
    return _runtime_host && _runtime_host->initialize_narrative(packet, state);
}

Dictionary DCWorldExt::get_gameplay_narrative_view() const {
    Dictionary out;
    out["ai_reply_delay_days"] = RuntimeNarrativeCatalog::AI_REPLY_DELAY_DAYS;
    const auto view = _runtime_host ? _runtime_host->latest_narrative() : nullptr;
    if (!view) return out;
    out["day"] = view->day;
    out["event_pause_mask"] = static_cast<int32_t>(view->pause_mask);
    out["last_popup_day"] = view->popup_day;
    out["active_offer"] = view->active_offer.duplicate(true);
    out["ready_queue"] = view->queue.duplicate(true);
    out["chronicle"] = view->chronicle.duplicate(true);
    out["ai_requests"] = view->ai_requests.duplicate(true);
    out["waiting_for_external_input_day"] = view->waiting_for_external_input_day;
    out["ai_enabled"] = view->ai_enabled;
    out["ai_enabled_requested"] = view->ai_enabled_requested;
    out["unrest_fact_cursor"] = view->unrest_fact;
    return out;
}

Dictionary DCWorldExt::capture_gameplay_narrative() const {
    return _runtime_host ? _runtime_host->capture_narrative() : Dictionary();
}

Dictionary DCWorldExt::submit_gameplay_narrative(StringName kind, Dictionary args) {
    if (!_runtime_host) return narrative_response(false, "narrative_runtime_unavailable");
    if (kind == StringName("restore")) return _runtime_host->restore_narrative_checkpoint(args);
    auto request = std::make_shared<RuntimeNarrativeRequest>();
    using Kind = RuntimeNarrativeRequest::Kind;
    if (kind == StringName("choose")) request->kind = Kind::CHOOSE;
    else if (kind == StringName("ai_result")) request->kind = Kind::AI_RESULT;
    else if (kind == StringName("ai_enabled")) request->kind = Kind::SET_AI;
    else if (kind == StringName("pause_policy")) request->kind = Kind::PAUSE_POLICY;
    else return narrative_response(false, "narrative_command_invalid");
    request->args = args.duplicate(true);
    return _runtime_host->submit_narrative_choice_request(std::move(request));
}

#include "world_ext_events_section_consumers.inc"

#include "world_ext_events_section_journal.inc"

Dictionary DCWorldExt::get_gameplay_event_bus_report() const {
    Dictionary out;
    out["event_count"] = int(_gameplay_events.size());
    out["max_events"] = _gameplay_max_events;
    out["oldest_event_id"] = _gameplay_events.empty() ? 0 : _gameplay_events.front().event_id;
    out["newest_event_id"] = _gameplay_events.empty() ? 0 : _gameplay_events.back().event_id;
    out["next_event_id"] = military_executor_active() ? _runtime_host->events_ingress_cursor()
        : _gameplay_next_event_id;
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
