#include "world_ext.h"

#include "country_runtime.h"
#include "economy_runtime.h"
#include "modifier_runtime.h"
#include "native_simulation_host.h"

#include <cstring>
#include <limits>
#include <type_traits>
#include <vector>

namespace pk {

using namespace godot;

namespace {
ModifierRuntime *runtime_from(void *opaque) {
    return static_cast<ModifierRuntime *>(opaque);
}
const ModifierRuntime *runtime_from(const void *opaque) {
    return static_cast<const ModifierRuntime *>(opaque);
}
Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "modifier_runtime_unavailable";
    return out;
}
} // namespace

Dictionary DCWorldExt::configure_modifiers(const Dictionary &catalog,
                                           int cell_count) {
    if (_modifier_runtime == nullptr) _modifier_runtime = new ModifierRuntime();
    ModifierRuntime *runtime = runtime_from(_modifier_runtime);
    runtime->attach_country_runtime(static_cast<NativeCountryRuntime *>(_country_runtime));
    runtime->attach_economy_runtime(static_cast<NativeEconomyRuntime *>(_economy_runtime));
    if (_country_runtime != nullptr)
        static_cast<NativeCountryRuntime *>(_country_runtime)->attach_modifier_runtime(runtime);
    if (_economy_runtime != nullptr)
        static_cast<NativeEconomyRuntime *>(_economy_runtime)->attach_modifier_runtime(runtime);
    Dictionary result = runtime->configure(catalog, cell_count);
    if (!static_cast<bool>(result.get("ok", false))) return result;
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    RuntimeModifierPodCatalog pod_catalog;
    std::string pod_error;
    const bool pod_ok = runtime->export_pod_catalog(pod_catalog, pod_error) &&
        _runtime_host->configure_modifier_pod(pod_catalog, pod_error);
    if (pod_ok) {
        std::vector<std::pair<uint64_t, int32_t>> key_hashes;
        runtime->export_definition_key_hashes(key_hashes);
        _runtime_host->set_modifier_definition_key_hashes(key_hashes);
    }
    result["modifier_pod_ready"] = pod_ok;
    result["modifier_pod_fallback_reason"] = String(pod_error.c_str());
    result["modifier_pod_catalog_hash"] = pod_ok
        ? static_cast<int64_t>(_runtime_host->modifier_pod_catalog_hash()) : 0;
    return result;
}

Dictionary DCWorldExt::submit_modifier_commands(const Dictionary &packed_batch) {
    if (_modifier_runtime == nullptr) return unavailable();
    ModifierRuntime *runtime = runtime_from(_modifier_runtime);
    const bool worker_authoritative = _runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::MODIFIER);

    auto encode_and_enqueue = [&](const Dictionary &batch,
                                  const PackedInt64Array &request_ids,
                                  bool require_enqueue) -> Dictionary {
        Dictionary result;
        result["ok"] = true;
        const PackedInt32Array opcodes = batch.get("opcodes", PackedInt32Array());
        const PackedInt32Array producers = batch.get("producer_ids", PackedInt32Array());
        const PackedInt64Array sequences = batch.get("sequences", PackedInt64Array());
        const PackedInt64Array days = batch.get("effective_days", PackedInt64Array());
        const PackedStringArray definitions = batch.get("definition_keys", PackedStringArray());
        const PackedInt32Array domains = batch.get("domains", PackedInt32Array());
        const PackedInt32Array scopes = batch.get("scopes", PackedInt32Array());
        const PackedInt64Array entities = batch.get("entity_handles", PackedInt64Array());
        const PackedInt64Array groups = batch.get("group_handles", PackedInt64Array());
        const PackedInt64Array source_types = batch.get("source_types", PackedInt64Array());
        const PackedInt64Array source_ids = batch.get("source_ids", PackedInt64Array());
        const PackedInt32Array durations = batch.get("duration_days", PackedInt32Array());
        const PackedInt32Array stacks = batch.get("stacks", PackedInt32Array());
        const PackedInt32Array magnitudes = batch.get("magnitude_q16", PackedInt32Array());
        const PackedInt64Array handles = batch.get("modifier_handles", PackedInt64Array());
        const int32_t count = request_ids.size();
        int32_t enqueued = 0;
        std::string enqueue_error;
        const RuntimeThreadReport host_report = _runtime_host->report();
        for (int32_t i = 0; i < count; ++i) {
            RuntimeCommandPacket packet;
            packet.envelope.request_id = static_cast<uint64_t>(request_ids[i]);
            packet.envelope.producer_id = static_cast<uint32_t>(producers[i]);
            packet.envelope.sequence = static_cast<uint64_t>(sequences[i]);
            packet.envelope.observed_generation = host_report.generation;
            packet.envelope.requested_day = days[i];
            packet.envelope.effective_day = days[i];
            packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
            packet.envelope.opcode = static_cast<uint16_t>(opcodes[i]);
            packet.envelope.payload_size = RUNTIME_MODIFIER_POD_WIRE_SIZE;
            size_t cursor = 0;
            const auto append = [&packet, &cursor](auto value) {
                using T = decltype(value);
                using U = std::make_unsigned_t<T>;
                U bits = static_cast<U>(value);
                for (size_t byte = 0; byte < sizeof(T); ++byte) {
                    packet.payload[cursor++] = static_cast<uint8_t>(
                        bits & static_cast<U>(0xffu));
                    bits >>= 8u;
                }
            };
            const int32_t definition_id = runtime->definition_id_for_key(
                definitions[i].utf8().get_data());
            const uint64_t entity_handle = static_cast<uint64_t>(entities[i]);
            const uint32_t target_generation = scopes[i] == ModifierRuntime::ENTITY
                ? static_cast<uint32_t>(entity_handle >> 32u) : 0u;
            append(static_cast<uint32_t>(RUNTIME_MODIFIER_POD_WIRE_ABI_VERSION));
            append(static_cast<uint16_t>(domains[i]));
            append(static_cast<uint16_t>(scopes[i]));
            append(definition_id);
            append(entity_handle);
            append(static_cast<uint64_t>(groups[i]));
            append(static_cast<uint64_t>(source_types[i]));
            append(static_cast<uint64_t>(source_ids[i]));
            append(static_cast<int32_t>(durations[i]));
            append(static_cast<int32_t>(stacks[i]));
            append(static_cast<int32_t>(magnitudes[i]));
            append(static_cast<uint64_t>(handles[i]));
            append(target_generation);
            append(host_report.environment_generation);
            if (cursor != RUNTIME_MODIFIER_POD_WIRE_SIZE ||
                !_runtime_host->enqueue_modifier_shadow(std::move(packet))) {
                enqueue_error = "modifier_host_enqueue_failed";
                if (require_enqueue) {
                    result["ok"] = false;
                    result["reason"] = String(enqueue_error.c_str());
                    result["modifier_host_enqueued"] = enqueued;
                    return result;
                }
                continue;
            }
            ++enqueued;
        }
        result["request_ids"] = request_ids;
        result["modifier_host_enqueued"] = enqueued;
        result["modifier_shadow_enqueued"] = enqueued;
        result["modifier_shadow_fallback_reason"] = String(enqueue_error.c_str());
        return result;
    };

    if (worker_authoritative) {
        // E8: Host is the sole writer. Never apply to legacy first.
        if (!_runtime_host) {
            Dictionary out;
            out["ok"] = false;
            out["reason"] = "modifier_host_unavailable";
            return out;
        }
        const PackedInt32Array opcodes = packed_batch.get("opcodes", PackedInt32Array());
        const int32_t count = opcodes.size();
        PackedInt64Array request_ids;
        request_ids.resize(count);
        for (int32_t i = 0; i < count; ++i) {
            request_ids.set(i, static_cast<int64_t>(
                _runtime_host->allocate_command_request_id()));
        }
        return encode_and_enqueue(packed_batch, request_ids, true);
    }

    Dictionary result = runtime->submit_commands(packed_batch);
    if (!static_cast<bool>(result.get("ok", false)) || !_runtime_host) return result;
    const PackedInt64Array request_ids = result.get("request_ids", PackedInt64Array());
    Dictionary mirrored = encode_and_enqueue(packed_batch, request_ids, false);
    result["modifier_shadow_enqueued"] = mirrored.get("modifier_host_enqueued", 0);
    result["modifier_shadow_fallback_reason"] =
        mirrored.get("modifier_shadow_fallback_reason", "");
    return result;
}

Dictionary DCWorldExt::run_modifier_daily(int64_t day_index) {
    if (_modifier_runtime == nullptr) return unavailable();
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::MODIFIER)) {
        Dictionary out;
        out["ok"] = true;
        out["done"] = true;
        out["work_done"] = 0;
        out["commands_applied"] = 0;
        out["expired"] = 0;
        out["stage"] = "modifier_worker_authoritative";
        out["path"] = "MODIFIER_WORKER";
        out["suppressed"] = true;
        return out;
    }
    return runtime_from(_modifier_runtime)->run_daily(day_index);
}

bool DCWorldExt::modifier_should_run(int64_t day_index) const {
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(
            RuntimeDomainId::MODIFIER)) {
        return false;
    }
    return _modifier_runtime != nullptr &&
        runtime_from(_modifier_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::get_modifier_command_result(int64_t request_id) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->command_result(request_id);
}

Dictionary DCWorldExt::list_modifiers(int domain, int64_t entity_handle,
                                      const String &stat_key) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->list_modifiers(
            domain, static_cast<uint64_t>(entity_handle), stat_key);
}

Dictionary DCWorldExt::explain_modifier_stat(int domain, int64_t entity_handle,
                                             int64_t group_handle,
                                             const String &stat_key,
                                             double base_value) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->explain(domain,
            static_cast<uint64_t>(entity_handle), static_cast<uint64_t>(group_handle),
            stat_key, base_value);
}

Dictionary DCWorldExt::get_modifier_report() const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->report();
}

Dictionary DCWorldExt::poll_modifier_events(int64_t after_event_id,
                                            int limit) const {
    return _modifier_runtime == nullptr ? unavailable()
        : runtime_from(_modifier_runtime)->poll_events(after_event_id, limit);
}

double DCWorldExt::evaluate_modifier_stat(int domain, int64_t entity_handle,
                                          int64_t group_handle,
                                          const String &stat_key,
                                          double base_value) const {
    return _modifier_runtime == nullptr ? base_value
        : runtime_from(_modifier_runtime)->effective_value(domain,
            stat_key.utf8().get_data(), static_cast<uint64_t>(entity_handle),
            static_cast<uint64_t>(group_handle), base_value);
}

int64_t DCWorldExt::register_gameplay_modifier_object(const String &archetype) {
    return _modifier_runtime == nullptr ? 0 : static_cast<int64_t>(
        runtime_from(_modifier_runtime)->register_gameplay_object(
            archetype.utf8().get_data()));
}

Dictionary DCWorldExt::unregister_gameplay_modifier_object(int64_t handle,
                                                           int64_t day_index) {
    if (_modifier_runtime == nullptr) return unavailable();
    Dictionary out;
    out["ok"] = runtime_from(_modifier_runtime)->unregister_gameplay_object(
        static_cast<uint64_t>(handle), day_index);
    out["reason"] = static_cast<bool>(out["ok"]) ? "" :
        "modifier_gameplay_handle_stale";
    return out;
}

Dictionary DCWorldExt::set_gameplay_modifier_base(int64_t handle,
                                                  const String &stat_key,
                                                  double value) {
    if (_modifier_runtime == nullptr) return unavailable();
    std::string error;
    const bool ok = runtime_from(_modifier_runtime)->set_gameplay_base(
        static_cast<uint64_t>(handle), stat_key.utf8().get_data(), value, error);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::get_gameplay_modifier_effective(int64_t handle,
                                                       int64_t group_handle,
                                                       const String &stat_key) const {
    if (_modifier_runtime == nullptr) return unavailable();
    double value = 0.0;
    std::string error;
    const bool ok = runtime_from(_modifier_runtime)->gameplay_effective(
        static_cast<uint64_t>(handle), static_cast<uint64_t>(group_handle),
        stat_key.utf8().get_data(), value, error);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(error.c_str());
    out["effective_value"] = value;
    return out;
}

PackedByteArray DCWorldExt::capture_modifier_domain(int domain) const {
    PackedByteArray out;
    if (_modifier_runtime == nullptr) return out;
    std::vector<uint8_t> bytes;
    std::string error;
    if (!runtime_from(_modifier_runtime)->serialize_domain(domain, bytes, error))
        return out;
    out.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}

Dictionary DCWorldExt::restore_modifier_domain(int domain,
                                               const PackedByteArray &bytes) {
    if (_modifier_runtime == nullptr) return unavailable();
    std::vector<uint8_t> native(static_cast<size_t>(bytes.size()));
    if (!native.empty()) std::memcpy(native.data(), bytes.ptr(), native.size());
    std::string error;
    const bool ok = runtime_from(_modifier_runtime)->restore_domain(domain, native, error);
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::clear_modifier_domain(int domain) {
    if (_modifier_runtime == nullptr) return unavailable();
    if (domain < 0 || domain >= ModifierRuntime::DOMAIN_COUNT)
        return unavailable();
    runtime_from(_modifier_runtime)->clear_domain(domain);
    Dictionary out;
    out["ok"] = true;
    out["domain"] = domain;
    out["migration"] = "legacy_empty_modifier_store";
    return out;
}

Dictionary DCWorldExt::get_runtime_modifier_snapshot(int64_t after_generation) {
    Dictionary out;
    out["ok"] = false;
    out["available"] = false;
    if (!_runtime_host) {
        out["reason"] = "runtime_host_unavailable";
        return out;
    }
    const uint64_t cursor = after_generation < 0
        ? std::numeric_limits<uint64_t>::max()
        : static_cast<uint64_t>(after_generation);
    uint32_t slot = 0;
    if (!_runtime_host->try_acquire_modifier_snapshot(cursor, slot)) {
        out["ok"] = true;
        out["reason"] = "";
        return out;
    }
    const RuntimeModifierPodSnapshot &snapshot =
        _runtime_host->modifier_snapshot_buffer(slot);
    bool shape_ok = snapshot.abi_version == RUNTIME_MODIFIER_POD_ABI_VERSION &&
        snapshot.catalog_hash == _runtime_host->modifier_pod_catalog_hash();
    for (const RuntimeModifierPodEntry &entry : snapshot.entries)
        shape_ok = shape_ok && entry.domain < 4;
    for (const RuntimeModifierPodBucket &bucket : snapshot.buckets)
        shape_ok = shape_ok && bucket.domain < 4 && bucket.scope < 3;
    if (!shape_ok) {
        _runtime_host->release_modifier_snapshot(slot);
        out["reason"] = "modifier_snapshot_shape_or_catalog_invalid";
        return out;
    }
    PackedInt64Array domain_versions;
    domain_versions.resize(4);
    for (int32_t i = 0; i < 4; ++i)
        domain_versions.set(i, static_cast<int64_t>(snapshot.domain_versions[i]));
    PackedInt32Array entry_domains, entry_definitions, entry_scopes,
        entry_generations, entry_stacks, entry_magnitudes;
    PackedInt64Array entry_handles, entry_targets, entry_entities, entry_groups,
        entry_source_types, entry_source_ids, entry_applied_days, entry_expiry_days;
    const int64_t entry_count = static_cast<int64_t>(snapshot.entries.size());
    entry_domains.resize(entry_count); entry_definitions.resize(entry_count);
    entry_scopes.resize(entry_count); entry_generations.resize(entry_count);
    entry_stacks.resize(entry_count); entry_magnitudes.resize(entry_count);
    entry_handles.resize(entry_count); entry_targets.resize(entry_count);
    entry_entities.resize(entry_count); entry_groups.resize(entry_count);
    entry_source_types.resize(entry_count); entry_source_ids.resize(entry_count);
    entry_applied_days.resize(entry_count); entry_expiry_days.resize(entry_count);
    for (int64_t i = 0; i < entry_count; ++i) {
        const auto &entry = snapshot.entries[static_cast<size_t>(i)];
        entry_domains.set(i, entry.domain); entry_definitions.set(i, entry.definition_id);
        entry_scopes.set(i, entry.scope); entry_generations.set(i, entry.target_generation);
        entry_stacks.set(i, entry.stacks); entry_magnitudes.set(i, entry.magnitude_q16);
        entry_handles.set(i, static_cast<int64_t>(entry.modifier_handle));
        entry_targets.set(i, static_cast<int64_t>(entry.target_handle));
        entry_entities.set(i, static_cast<int64_t>(entry.entity_handle));
        entry_groups.set(i, static_cast<int64_t>(entry.group_handle));
        entry_source_types.set(i, static_cast<int64_t>(entry.source_type));
        entry_source_ids.set(i, static_cast<int64_t>(entry.source_id));
        entry_applied_days.set(i, entry.applied_day); entry_expiry_days.set(i, entry.expires_day);
    }
    PackedInt32Array bucket_domains, bucket_scopes, bucket_stats, bucket_counts;
    PackedInt64Array bucket_scope_ids;
    PackedFloat64Array bucket_adds, bucket_factors;
    const int64_t bucket_count = static_cast<int64_t>(snapshot.buckets.size());
    bucket_domains.resize(bucket_count); bucket_scopes.resize(bucket_count);
    bucket_stats.resize(bucket_count); bucket_counts.resize(bucket_count);
    bucket_scope_ids.resize(bucket_count); bucket_adds.resize(bucket_count);
    bucket_factors.resize(bucket_count);
    for (int64_t i = 0; i < bucket_count; ++i) {
        const auto &bucket = snapshot.buckets[static_cast<size_t>(i)];
        bucket_domains.set(i, bucket.domain); bucket_scopes.set(i, bucket.scope);
        bucket_stats.set(i, static_cast<int32_t>(bucket.stat_id));
        bucket_counts.set(i, static_cast<int32_t>(bucket.active_count));
        bucket_scope_ids.set(i, static_cast<int64_t>(bucket.scope_id));
        bucket_adds.set(i, bucket.sum_add); bucket_factors.set(i, bucket.product_factor);
    }
    out["ok"] = true; out["available"] = true; out["reason"] = "";
    out["abi_version"] = static_cast<int64_t>(snapshot.abi_version);
    out["generation"] = static_cast<int64_t>(snapshot.generation);
    out["committed_day"] = snapshot.committed_day;
    out["catalog_hash"] = static_cast<int64_t>(snapshot.catalog_hash);
    out["state_hash"] = static_cast<int64_t>(snapshot.state_hash);
    out["domain_versions"] = domain_versions;
    out["entry_domains"] = entry_domains; out["entry_handles"] = entry_handles;
    out["entry_target_handles"] = entry_targets; out["entry_target_generations"] = entry_generations;
    out["entry_definition_ids"] = entry_definitions; out["entry_scopes"] = entry_scopes;
    out["entry_entity_handles"] = entry_entities; out["entry_group_handles"] = entry_groups;
    out["entry_source_types"] = entry_source_types; out["entry_source_ids"] = entry_source_ids;
    out["entry_stacks"] = entry_stacks; out["entry_magnitude_q16"] = entry_magnitudes;
    out["entry_applied_days"] = entry_applied_days; out["entry_expiry_days"] = entry_expiry_days;
    out["bucket_domains"] = bucket_domains; out["bucket_scopes"] = bucket_scopes;
    out["bucket_stat_ids"] = bucket_stats; out["bucket_scope_ids"] = bucket_scope_ids;
    out["bucket_sum_add"] = bucket_adds; out["bucket_product_factor"] = bucket_factors;
    out["bucket_active_counts"] = bucket_counts;
    _runtime_host->release_modifier_snapshot(slot);
    return out;
}


Dictionary DCWorldExt::apply_runtime_modifier_snapshot(int64_t after_generation) {
    Dictionary out;
    out["ok"] = false;
    out["available"] = false;
    out["applied"] = false;
    if (_modifier_runtime == nullptr) {
        out["reason"] = "modifier_runtime_unavailable";
        return out;
    }
    if (!_runtime_host) {
        out["reason"] = "runtime_host_unavailable";
        return out;
    }
    if (!_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::MODIFIER)) {
        out["ok"] = true;
        out["reason"] = "modifier_not_worker_authoritative";
        return out;
    }
    const uint64_t cursor = after_generation < 0
        ? std::numeric_limits<uint64_t>::max()
        : static_cast<uint64_t>(after_generation);
    uint32_t slot = 0;
    if (!_runtime_host->try_acquire_modifier_snapshot(cursor, slot)) {
        out["ok"] = true;
        out["reason"] = "";
        return out;
    }
    const RuntimeModifierPodSnapshot &snapshot =
        _runtime_host->modifier_snapshot_buffer(slot);
    bool shape_ok = snapshot.abi_version == RUNTIME_MODIFIER_POD_ABI_VERSION &&
        snapshot.catalog_hash == _runtime_host->modifier_pod_catalog_hash();
    for (const RuntimeModifierPodEntry &entry : snapshot.entries)
        shape_ok = shape_ok && entry.domain < 4;
    for (const RuntimeModifierPodBucket &bucket : snapshot.buckets)
        shape_ok = shape_ok && bucket.domain < 4 && bucket.scope < 3;
    if (!shape_ok) {
        _runtime_host->release_modifier_snapshot(slot);
        out["reason"] = "modifier_snapshot_shape_or_catalog_invalid";
        return out;
    }
    std::string apply_error;
    const bool applied =
        runtime_from(_modifier_runtime)->apply_pod_snapshot(snapshot, apply_error);
    out["ok"] = applied;
    out["available"] = true;
    out["applied"] = applied;
    out["generation"] = static_cast<int64_t>(snapshot.generation);
    out["committed_day"] = snapshot.committed_day;
    out["state_hash"] = static_cast<int64_t>(snapshot.state_hash);
    out["reason"] = applied ? "" : String(apply_error.c_str());
    _runtime_host->release_modifier_snapshot(slot);
    return out;
}

Dictionary DCWorldExt::runtime_modifier_pod_self_test() const {
    std::string error;
    const bool authority_ok = RuntimeModifierPodAuthority::self_test(error);
    NativeSimulationHost protocol_host;
    const bool protocol_ok = authority_ok && protocol_host.modifier_pod_self_test(&error);
    const bool ok = authority_ok && protocol_ok;
    Dictionary out;
    out["ok"] = ok;
    out["reason"] = ok ? "" : String(error.c_str());
    out["implemented_domain_mask"] = static_cast<int64_t>(
        NativeSimulationHost::implemented_domain_mask());
    return out;
}

float DCWorldExt::modifier_climate_radiative_target(int cell,
                                                    float base_value) const {
    return _modifier_runtime == nullptr ? base_value
        : runtime_from(_modifier_runtime)->climate_radiative_target(cell, base_value);
}

double DCWorldExt::modifier_country_output_factor(int64_t country_handle) const {
    return _modifier_runtime == nullptr ? 1.0
        : runtime_from(_modifier_runtime)->country_economy_output_factor(
            static_cast<uint64_t>(country_handle));
}

int64_t DCWorldExt::ensure_modifier_building_handle(int cell, int type_id,
                                                    int owner_signature_id) {
    return _modifier_runtime == nullptr ? 0 : static_cast<int64_t>(
        runtime_from(_modifier_runtime)->ensure_building_identity(
            cell, type_id, owner_signature_id));
}

double DCWorldExt::modifier_building_output_factor(int64_t building_handle,
                                                   int64_t settlement_cell) const {
    return _modifier_runtime == nullptr ? 1.0
        : runtime_from(_modifier_runtime)->economy_building_output_factor(
            static_cast<uint64_t>(building_handle),
            static_cast<uint64_t>(settlement_cell), 2);
}

} // namespace pk
