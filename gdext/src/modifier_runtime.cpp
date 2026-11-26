#include "modifier_runtime.h"
#include "simulation_math.h"

#include "country_api.h"
#include "economy_api.h"
#include "runtime_effect_pod.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <set>

#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace pk {

using namespace godot;

namespace {
constexpr uint32_t SAVE_MAGIC = 0x444d4b50U; // PKMD
constexpr uint32_t SAVE_END = 0x21444e45U;
constexpr size_t JOURNAL_CAPACITY = 4096;
constexpr uint32_t BUCKET_REBUILD_INTERVAL = 256;

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    const uint8_t *bytes = reinterpret_cast<const uint8_t *>(&value);
    out.insert(out.end(), bytes, bytes + sizeof(T));
}

template <typename T>
bool read_le(const std::vector<uint8_t> &bytes, size_t &cursor, T &value) {
    if (cursor + sizeof(T) > bytes.size()) return false;
    std::memcpy(&value, bytes.data() + cursor, sizeof(T));
    cursor += sizeof(T);
    return true;
}

void append_string(std::vector<uint8_t> &out, const std::string &value) {
    append_le<uint32_t>(out, static_cast<uint32_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

bool read_string(const std::vector<uint8_t> &bytes, size_t &cursor,
                 std::string &value) {
    uint32_t size = 0;
    if (!read_le(bytes, cursor, size) || size > 1024 * 1024 ||
        cursor + size > bytes.size()) return false;
    value.assign(reinterpret_cast<const char *>(bytes.data() + cursor), size);
    cursor += size;
    return true;
}

uint64_t fnv_mix(uint64_t hash, const void *data, size_t size) {
    const uint8_t *bytes = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

uint64_t fnv_string(uint64_t hash, const std::string &value) {
    return fnv_mix(hash, value.data(), value.size());
}

uint64_t fnv_catalog_term(uint64_t hash, int32_t stat_id,
                          double add, double factor) {
    // 保留既有 x64 存档的 24 字节布局，不能把编译器填充字节当成目录数据。
    constexpr uint32_t reserved = 0;
    hash = fnv_mix(hash, &stat_id, sizeof(stat_id));
    hash = fnv_mix(hash, &reserved, sizeof(reserved));
    hash = fnv_mix(hash, &add, sizeof(add));
    return fnv_mix(hash, &factor, sizeof(factor));
}

double elapsed_ms(const std::chrono::steady_clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count();
}

Dictionary fail_dict(const char *reason) {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = reason;
    return out;
}
} // namespace

size_t ModifierRuntime::BucketKeyHash::operator()(const BucketKey &key) const noexcept {
    uint64_t hash = static_cast<uint32_t>(key.stat_id) * 0x9e3779b185ebca87ULL;
    hash ^= static_cast<uint64_t>(static_cast<uint32_t>(key.scope)) << 48U;
    hash ^= key.scope_id + 0x9e3779b97f4a7c15ULL + (hash << 6U) + (hash >> 2U);
    return static_cast<size_t>(hash);
}

bool ModifierRuntime::UniqueKey::operator==(const UniqueKey &other) const {
    return definition_id == other.definition_id && scope == other.scope &&
        scope_id == other.scope_id && source_type == other.source_type &&
        source_id == other.source_id;
}

size_t ModifierRuntime::UniqueKeyHash::operator()(const UniqueKey &key) const noexcept {
    uint64_t hash = static_cast<uint32_t>(key.definition_id) * 0x9e3779b185ebca87ULL;
    hash ^= static_cast<uint64_t>(static_cast<uint32_t>(key.scope)) << 32U;
    hash ^= key.scope_id + (hash << 6U) + (hash >> 2U);
    hash ^= key.source_type + (hash << 6U) + (hash >> 2U);
    hash ^= key.source_id + (hash << 6U) + (hash >> 2U);
    return static_cast<size_t>(hash);
}

bool ModifierRuntime::ExpiryNode::operator>(const ExpiryNode &other) const {
    if (day != other.day) return day > other.day;
    if (index != other.index) return index > other.index;
    return generation > other.generation;
}

size_t ModifierRuntime::BuildingKeyHash::operator()(const BuildingKey &key) const noexcept {
    uint64_t value = static_cast<uint32_t>(key.cell);
    value = value * 0x9e3779b185ebca87ULL ^ static_cast<uint32_t>(key.type);
    value = value * 0xc2b2ae3d27d4eb4fULL ^ static_cast<uint32_t>(key.owner);
    return static_cast<size_t>(value);
}

#include "modifier_runtime_section_catalog_and_snapshot.inc"

#include "modifier_runtime_section_commands.inc"

bool ModifierRuntime::valid_identity(const IdentityStore &store, uint64_t handle) const {
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
    return index < store.active.size() && store.active[index] != 0 && generation != 0 &&
        store.generation[index] == generation;
}

bool ModifierRuntime::validate_target(const Command &command, std::string &error) const {
    if (command.domain < 0 || command.domain >= DOMAIN_COUNT ||
        command.scope < GLOBAL || command.scope > ENTITY) {
        error = "modifier_target_shape_invalid";
        return false;
    }
    if (command.scope == GROUP && command.group_handle == 0 &&
        command.domain != ECONOMY) {
        error = "modifier_group_target_missing";
        return false;
    }
    if (command.domain == ECONOMY && command.group_handle != 0 &&
        command.group_handle >= static_cast<uint64_t>(_cell_count)) {
        error = "modifier_settlement_group_invalid";
        return false;
    }
    if (command.scope == ENTITY && command.entity_handle == 0 && command.domain != CLIMATE) {
        error = "modifier_entity_target_missing";
        return false;
    }
    if (command.scope == ENTITY) {
        if (command.domain == CLIMATE && command.entity_handle >= static_cast<uint64_t>(_cell_count)) {
            error = "modifier_cell_target_invalid";
            return false;
        }
        if (command.domain == COUNTRY && _country_runtime != nullptr &&
            !country_api::valid_handle(*_country_runtime, static_cast<int64_t>(command.entity_handle))) {
            error = "modifier_country_handle_stale";
            return false;
        }
        // Producer 161 = declared FamilyEffect, 162 = declared Ideology effect.
        // Both address the economy domain by a domain-owned entity handle
        // instead of a building identity, so the building check must not apply.
        // The ideology family shape is ENTITY-only and carries exactly one
        // family handle; group-scoped Economy commands remain cell targets.
        const bool declared_family_entity = command.domain == ECONOMY &&
            command.producer == 161 && command.entity_handle != 0;
        const bool ideology_family_entity = command.domain == ECONOMY &&
            command.producer == 162 && command.scope == ENTITY &&
            command.group_handle == 0 && command.entity_handle != 0;
        const bool family_effect_entity =
            declared_family_entity || ideology_family_entity;
        if (declared_family_entity && _economy_runtime != nullptr &&
            !economy_api::valid_family_effect_entity_handle(
                *_economy_runtime, command.entity_handle)) {
            error = "modifier_family_effect_handle_stale";
            return false;
        }
        if (ideology_family_entity && _economy_runtime != nullptr &&
            !economy_api::valid_family_effect_target_handle(
                *_economy_runtime, command.entity_handle)) {
            error = "modifier_ideology_family_handle_stale";
            return false;
        }
        if (command.domain == ECONOMY && !family_effect_entity &&
            !valid_identity(_building_identities, command.entity_handle)) {
            error = "modifier_building_handle_stale";
            return false;
        }
        if (command.domain == GAMEPLAY &&
            !valid_identity(_gameplay_identities, command.entity_handle) &&
            _person_targets.find(command.entity_handle) == _person_targets.end()) {
            error = "modifier_gameplay_handle_stale";
            return false;
        }
    }
    return true;
}

#include "modifier_runtime_section_buckets.inc"

void ModifierRuntime::push_event(Event event) {
    if (event.domain >= 0 && event.domain < DOMAIN_COUNT) {
        Store &store = _stores[event.domain];
        if (event.kind == EVENT_APPLY || event.kind == EVENT_REPLACE ||
            event.kind == EVENT_STACK || event.kind == EVENT_REFRESH ||
            event.kind == EVENT_MAGNITUDE) {
            ++store.apply_events;
        } else if (event.kind == EVENT_REMOVE) {
            ++store.remove_events;
        } else if (event.kind == EVENT_EXPIRE) {
            ++store.expire_events;
        } else if (event.kind == EVENT_REJECT) {
            ++store.reject_events;
        } else if (event.kind == EVENT_TARGET_CLEANUP) {
            ++store.target_cleanup_events;
        }
    }
    if (event.kind == EVENT_REJECT && !event.reason.empty()) record_error(event.reason);
    event.id = _next_event_id++;
    _events.push_back(std::move(event));
    while (_events.size() > JOURNAL_CAPACITY) {
        _events.pop_front();
        ++_journal_overflow;
    }
}

void ModifierRuntime::reject_command(const Command &command, int64_t day,
                                     const std::string &reason) {
    _results[command.request_id] = {false, reason, 0, day};
    ++_commands_rejected;
    push_event({0, day, EVENT_REJECT, command.domain, command.modifier_handle,
        command.definition_id, command.entity_handle, command.group_handle,
        command.scope, command.source_type, command.source_id, 0, 0,
        command.request_id, reason});
}

#include "modifier_runtime_section_instance_updates.inc"

#include "modifier_runtime_section_scope_queries.inc"

// ── Derived cell layer (plan 22 ADR01/ADR02, M1) ────────────────────────────
//
// ADR02 in code: this member lives OUTSIDE `_stores`, so the wholesale rebuild
// in `apply_pod_snapshot` (`:459-557`) cannot clear it. That is the entire reason
// the layer exists as a sibling of the instance Store rather than a bucket kind.
#include "modifier_runtime_section_consumer_values.inc"

#include "modifier_runtime_section_reports.inc"

uint64_t ModifierRuntime::allocate_identity(IdentityStore &store,
                                            const std::string &label) {
    uint32_t index = 0;
    if (!store.free_list.empty()) {
        index = store.free_list.back();
        store.free_list.pop_back();
        if (++store.generation[index] == 0) store.generation[index] = 1;
        store.labels[index] = label;
    } else {
        index = static_cast<uint32_t>(store.active.size());
        store.active.push_back(0);
        store.generation.push_back(1);
        store.labels.push_back(label);
    }
    store.active[index] = 1;
    return (static_cast<uint64_t>(store.generation[index]) << 32U) | index;
}

bool ModifierRuntime::retire_identity(IdentityStore &store, uint64_t handle) {
    if (!valid_identity(store, handle)) return false;
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    store.active[index] = 0;
    store.labels[index].clear();
    store.free_list.push_back(index);
    return true;
}

uint64_t ModifierRuntime::register_gameplay_object(const std::string &archetype) {
    const uint64_t handle = allocate_identity(_gameplay_identities, archetype);
    const size_t size = _gameplay_identities.active.size();
    for (size_t sid = 0; sid < _stats.size(); ++sid) {
        if (_stats[sid].domain != GAMEPLAY) continue;
        if (_gameplay_base_by_stat[sid].size() < size)
            _gameplay_base_by_stat[sid].resize(size, 0.0);
    }
    return handle;
}

bool ModifierRuntime::unregister_gameplay_object(uint64_t handle, int64_t day_index) {
    if (!valid_identity(_gameplay_identities, handle)) return false;
    std::vector<uint64_t> remove;
    const Store &store = _stores[GAMEPLAY];
    for (uint32_t index = 0; index < store.active.size(); ++index)
        if (store.active[index] != 0 && store.scope[index] == ENTITY &&
            store.entity_handle[index] == handle) remove.push_back(make_handle(store, index));
    for (uint64_t modifier : remove)
        remove_handle(GAMEPLAY, modifier, day_index, EVENT_TARGET_CLEANUP, 0,
                      "gameplay_target_destroyed");
    return retire_identity(_gameplay_identities, handle);
}

bool ModifierRuntime::set_gameplay_base(uint64_t handle, const std::string &key,
                                        double value, std::string &error) {
    if (!valid_identity(_gameplay_identities, handle)) {
        error = "modifier_gameplay_handle_stale";
        return false;
    }
    const int32_t sid = stat_id(key);
    if (sid < 0 || _stats[sid].domain != GAMEPLAY || !std::isfinite(value)) {
        error = "modifier_gameplay_stat_invalid";
        return false;
    }
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    if (_gameplay_base_by_stat[sid].size() <= index)
        _gameplay_base_by_stat[sid].resize(index + 1, 0.0);
    _gameplay_base_by_stat[sid][index] = value;
    return true;
}

bool ModifierRuntime::gameplay_effective(uint64_t handle, uint64_t group_handle,
                                         const std::string &key, double &out,
                                         std::string &error) const {
    if (!valid_identity(_gameplay_identities, handle)) {
        error = "modifier_gameplay_handle_stale";
        return false;
    }
    const int32_t sid = stat_id(key);
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    if (sid < 0 || _stats[sid].domain != GAMEPLAY ||
        sid >= static_cast<int32_t>(_gameplay_base_by_stat.size()) ||
        index >= _gameplay_base_by_stat[sid].size()) {
        error = "modifier_gameplay_stat_invalid";
        return false;
    }
    out = effective_value(GAMEPLAY, sid, handle, group_handle,
                          _gameplay_base_by_stat[sid][index]);
    return true;
}

uint64_t ModifierRuntime::ensure_building_identity(int32_t cell, int32_t type_id,
                                                   int32_t owner_signature_id) {
    const BuildingKey key{cell, type_id, owner_signature_id};
    const auto it = _building_handles.find(key);
    if (it != _building_handles.end() && valid_identity(_building_identities, it->second))
        return it->second;
    const uint64_t handle = allocate_identity(_building_identities,
        std::to_string(cell) + ":" + std::to_string(type_id) + ":" +
        std::to_string(owner_signature_id));
    _building_handles[key] = handle;
    return handle;
}

bool ModifierRuntime::retire_building_identity(int32_t cell, int32_t type_id,
                                               int32_t owner_signature_id,
                                               int64_t day_index) {
    const BuildingKey key{cell, type_id, owner_signature_id};
    const auto it = _building_handles.find(key);
    if (it == _building_handles.end()) return false;
    const uint64_t handle = it->second;
    std::vector<uint64_t> remove;
    const Store &store = _stores[ECONOMY];
    for (uint32_t index = 0; index < store.active.size(); ++index)
        if (store.active[index] != 0 && store.scope[index] == ENTITY &&
            store.entity_handle[index] == handle) remove.push_back(make_handle(store, index));
    for (uint64_t modifier : remove)
        remove_handle(ECONOMY, modifier, day_index, EVENT_TARGET_CLEANUP, 0,
                      "building_target_destroyed");
    _building_handles.erase(it);
    return retire_identity(_building_identities, handle);
}

void ModifierRuntime::register_person_target(uint64_t handle) {
    if (handle != 0) _person_targets.insert(handle);
}

void ModifierRuntime::unregister_person_target(uint64_t handle) {
    if (handle != 0) _person_targets.erase(handle);
}

#include "modifier_runtime_section_checkpoint.inc"

} // namespace pk
