#include "world_ext.h"

#include "trigger_runtime.h"
#include "effect_runtime.h"
#include "economy_runtime.h"
#include "ideology_runtime.h"
#include "native_simulation_host.h"

#include <cstring>
#include <atomic>
#include <vector>

namespace pk {

using namespace godot;

namespace {
std::atomic<uint64_t> g_trigger_pod_request_id{1};
std::atomic<uint64_t> g_trigger_pod_sequence{1};

bool publish_trigger_command(DCWorldExt *world,
                             RuntimeTriggerCommand command,
                             Dictionary &result) {
    if (world == nullptr || world->trigger_pod_host() == nullptr) return true;
    command.request_id = g_trigger_pod_request_id.fetch_add(1, std::memory_order_relaxed);
    command.producer_id = 1;
    command.sequence = g_trigger_pod_sequence.fetch_add(1, std::memory_order_relaxed);
    std::string error;
    if (!world->trigger_pod_host()->queue_trigger_pod_command(command, error)) {
        result["pod_shadow_ok"] = false;
        result["pod_shadow_reason"] = String(error.c_str());
        return false;
    }
    result["pod_shadow_ok"] = true;
    return true;
}

void publish_trigger_event_batch(DCWorldExt *world, const Dictionary &batch,
                                 bool snapshot, Dictionary &result) {
    if (world == nullptr || world->trigger_pod_host() == nullptr) return;
    const Variant raw_ids = batch.get("event_ids", PackedInt64Array());
    if (raw_ids.get_type() != Variant::PACKED_INT64_ARRAY) return;
    const PackedInt64Array ids = raw_ids;
    const PackedInt32Array source_ids = batch.get("source_ids", PackedInt32Array());
    const PackedInt64Array days = batch.get("days", PackedInt64Array());
    const PackedInt32Array event_types = batch.get("event_types", PackedInt32Array());
    const PackedInt32Array schemas = batch.get("payload_schemas", PackedInt32Array());
    const PackedInt64Array entities = batch.get("entity_handles", PackedInt64Array());
    const PackedInt64Array groups = batch.get("group_handles", PackedInt64Array());
    const PackedInt64Array values = batch.get("values", PackedInt64Array());
    const PackedInt64Array p0 = batch.get("payload_i0", PackedInt64Array());
    const PackedInt64Array p1 = batch.get("payload_i1", PackedInt64Array());
    const PackedInt64Array p2 = batch.get("payload_i2", PackedInt64Array());
    const PackedInt64Array p3 = batch.get("payload_i3", PackedInt64Array());
    const int32_t source_scalar = int32_t(batch.get("source_id_scalar", 0));
    const int32_t count = std::max(0, std::min<int32_t>(
        int32_t(batch.get("count", ids.size())), ids.size()));
    for (int32_t i = 0; i < count; ++i) {
        RuntimeTriggerCommand command;
        command.effective_day = i < days.size() ? days[i] : 0;
        command.requested_day = command.effective_day;
        command.opcode = snapshot ? RuntimeTriggerCommandOpcode::INGEST_SNAPSHOT
                                  : RuntimeTriggerCommandOpcode::INGEST_EVENT;
        command.event.source_id = i < source_ids.size() ? source_ids[i] : source_scalar;
        command.event.event_id = ids[i];
        command.event.day = command.effective_day;
        command.event.event_type = i < event_types.size() ? event_types[i] : 0;
        command.event.payload_schema = i < schemas.size() ? schemas[i] : 0;
        command.event.entity_handle = i < entities.size() ? uint64_t(entities[i]) : 0;
        command.event.group_handle = i < groups.size() ? uint64_t(groups[i]) : 0;
        command.event.value = i < values.size() ? values[i] : 1;
        command.event.payload = {i < p0.size() ? p0[i] : 0,
            i < p1.size() ? p1[i] : 0, i < p2.size() ? p2[i] : 0,
            i < p3.size() ? p3[i] : 0};
        if (!publish_trigger_command(world, command, result)) return;
    }
}
TriggerRuntime *runtime_from(void *opaque) {
    return static_cast<TriggerRuntime *>(opaque);
}
const TriggerRuntime *runtime_from(const void *opaque) {
    return static_cast<const TriggerRuntime *>(opaque);
}
Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "trigger_runtime_unavailable";
    return out;
}
} // namespace

Dictionary DCWorldExt::configure_triggers(const Dictionary &catalog) {
    if (_trigger_runtime == nullptr) _trigger_runtime = new TriggerRuntime();
    Dictionary out = runtime_from(_trigger_runtime)->configure(catalog);
    if (static_cast<bool>(out.get("ok", false)) && _economy_runtime != nullptr) {
        static_cast<NativeEconomyRuntime *>(_economy_runtime)->attach_trigger_runtime(
            runtime_from(_trigger_runtime));
    }
    if (static_cast<bool>(out.get("ok", false))) {
        if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
        RuntimeTriggerPodCatalog pod_catalog;
        std::string error;
        if (!runtime_from(_trigger_runtime)->export_pod_catalog(pod_catalog, error) ||
            !_runtime_host->configure_trigger_pod(pod_catalog, error)) {
            out["pod_shadow_ok"] = false;
            out["pod_shadow_reason"] = String(error.c_str());
        } else {
            out["pod_shadow_ok"] = true;
        }
    }
    return out;
}

Dictionary DCWorldExt::submit_trigger_events(const Dictionary &batch) {
    if (_trigger_runtime == nullptr) return unavailable();
    Dictionary out = runtime_from(_trigger_runtime)->submit_events(batch);
    if (static_cast<bool>(out.get("ok", false))) publish_trigger_event_batch(this, batch, false, out);
    return out;
}

Dictionary DCWorldExt::submit_trigger_snapshots(const Dictionary &batch) {
    if (_trigger_runtime == nullptr) return unavailable();
    Dictionary out = runtime_from(_trigger_runtime)->submit_snapshots(batch);
    if (static_cast<bool>(out.get("ok", false))) publish_trigger_event_batch(this, batch, true, out);
    return out;
}

Dictionary DCWorldExt::run_trigger_daily(int64_t day_index) {
    if (_trigger_runtime == nullptr) return unavailable();
    Dictionary out = runtime_from(_trigger_runtime)->run_daily(day_index);
    if (static_cast<bool>(out.get("ok", false)) && _runtime_host != nullptr) {
        // The synchronous facade remains authoritative in Stage H. Publish
        // only its canonical post-day hashes; the worker compares them after
        // committing the same day, so an older worker state is never treated
        // as a divergence for the new reference frame.
        std::string error;
        const uint64_t input_hash = static_cast<uint64_t>(day_index) + 1u;
        if (!_runtime_host->set_trigger_reference_frame(
                day_index, input_hash,
                runtime_from(_trigger_runtime)->pod_state_hash(),
                runtime_from(_trigger_runtime)->pod_effect_hash(), error)) {
            out["pod_shadow_reference_ok"] = false;
            out["pod_shadow_reference_reason"] = String(error.c_str());
        } else {
            out["pod_shadow_reference_ok"] = true;
        }
    }
    return out;
}

bool DCWorldExt::trigger_should_run(int64_t day_index) const {
    return _trigger_runtime != nullptr &&
        runtime_from(_trigger_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::poll_trigger_effects(int64_t after_effect_id,
                                             int limit) const {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->poll_effects(after_effect_id, limit);
}

Dictionary DCWorldExt::ack_trigger_effects(int64_t up_to_effect_id) {
    if (_trigger_runtime == nullptr) return unavailable();
    Dictionary out = runtime_from(_trigger_runtime)->ack_effects(up_to_effect_id);
    if (static_cast<bool>(out.get("ok", false))) {
        RuntimeTriggerCommand command;
        command.opcode = RuntimeTriggerCommandOpcode::ACK_EFFECTS;
        command.effective_day = 0;
        command.requested_day = 0;
        command.ack_up_to_effect_id = up_to_effect_id;
        publish_trigger_command(this, command, out);
    }
    return out;
}

Dictionary DCWorldExt::handoff_trigger_effects(int limit) {
    if (_trigger_runtime == nullptr || _effect_runtime == nullptr)
        return unavailable();
    return runtime_from(_trigger_runtime)->handoff_effects(
        static_cast<EffectRuntime *>(_effect_runtime),
        static_cast<NativeIdeologyRuntime *>(_ideology_runtime),
        _runtime_host.get(), limit);
}

Dictionary DCWorldExt::set_trigger_enabled(const Dictionary &batch) {
    if (_trigger_runtime == nullptr) return unavailable();
    Dictionary out = runtime_from(_trigger_runtime)->set_enabled(batch);
    const PackedInt32Array ids = batch.get("trigger_ids", PackedInt32Array());
    const PackedByteArray values = batch.get("enabled", PackedByteArray());
    if (static_cast<bool>(out.get("ok", false)) && ids.size() == values.size()) {
        for (int32_t i = 0; i < ids.size(); ++i) {
            RuntimeTriggerCommand command;
            command.opcode = RuntimeTriggerCommandOpcode::SET_ENABLED;
            command.effective_day = 0;
            command.requested_day = 0;
            command.trigger_id = ids[i];
            command.enabled = values[i];
            if (!publish_trigger_command(this, command, out)) break;
        }
    }
    return out;
}

Dictionary DCWorldExt::reconcile_trigger_branch_bindings(const Dictionary &batch) {
    if (_trigger_runtime == nullptr) return unavailable();
    Dictionary out = runtime_from(_trigger_runtime)->reconcile_branch_bindings(batch);
    const PackedStringArray keys = batch.get("trigger_keys", PackedStringArray());
    const PackedInt64Array branches = batch.get("branch_handles", PackedInt64Array());
    const PackedInt32Array cells = batch.get("cells", PackedInt32Array());
    const PackedInt32Array rewards = batch.get("reward_targets", PackedInt32Array());
    const PackedByteArray enabled = batch.get("enabled", PackedByteArray());
    if (static_cast<bool>(out.get("ok", false)) && keys.size() == branches.size() &&
        keys.size() == cells.size() && keys.size() == rewards.size() &&
        keys.size() == enabled.size()) {
        RuntimeTriggerPodCatalog catalog;
        std::string error;
        if (_runtime_host && runtime_from(_trigger_runtime)->export_pod_catalog(catalog, error)) {
            for (int32_t i = 0; i < keys.size(); ++i) {
                RuntimeTriggerCommand command;
                command.opcode = RuntimeTriggerCommandOpcode::RECONCILE_BRANCH_BINDING;
                command.effective_day = 0;
                command.requested_day = 0;
                command.binding.branch_handle = uint64_t(branches[i]);
                command.binding.cell = cells[i];
                command.binding.reward_target = rewards[i];
                command.binding.enabled = enabled[i];
                for (int32_t trigger_id = 0; trigger_id < int32_t(catalog.definitions.size()); ++trigger_id) {
                    if (catalog.definitions[trigger_id].key_hash == 0) continue;
                    // The key hash is sufficient for the numeric worker bridge;
                    // the facade remains the authoritative string lookup.
                    const CharString text = String(keys[i]).utf8();
                    uint64_t hash = 1469598103934665603ull;
                    for (const char *p = text.get_data(); p != nullptr && *p != '\0'; ++p) {
                        hash ^= static_cast<uint8_t>(*p); hash *= 1099511628211ull;
                    }
                    if (hash == catalog.definitions[trigger_id].key_hash) {
                        command.binding.trigger_id = trigger_id; break;
                    }
                }
                if (!publish_trigger_command(this, command, out)) break;
            }
        }
    }
    return out;
}

Dictionary DCWorldExt::get_trigger_branch_progress(int64_t branch_handle) const {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->branch_progress(
            static_cast<uint64_t>(branch_handle));
}

Dictionary DCWorldExt::get_development_progress(int64_t country_handle,
                                                int32_t era_index) const {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->development_progress(
            static_cast<uint64_t>(country_handle), era_index);
}

Dictionary DCWorldExt::resync_trigger_source(const Dictionary &snapshot) {
    if (_trigger_runtime == nullptr) return unavailable();
    const PackedInt32Array trigger_ids = snapshot.get("trigger_ids", PackedInt32Array());
    const PackedInt64Array targets = snapshot.get("target_handles", PackedInt64Array());
    const PackedInt64Array values = snapshot.get("values", PackedInt64Array());
    if (trigger_ids.size() != targets.size() || trigger_ids.size() != values.size()) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "trigger_resync_columns_invalid";
        return out;
    }
    if (trigger_ids.size() > static_cast<int32_t>(RUNTIME_TRIGGER_RESYNC_CAPACITY)) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "trigger_resync_capacity_exceeded";
        return out;
    }
    Dictionary out = runtime_from(_trigger_runtime)->resync_source(snapshot);
    if (static_cast<bool>(out.get("ok", false))) {
        RuntimeTriggerCommand command;
        command.opcode = RuntimeTriggerCommandOpcode::RESYNC_SOURCE;
        command.effective_day = 0;
        command.requested_day = 0;
        command.source_id = int32_t(snapshot.get("source_id", -1));
        command.cursor = int64_t(snapshot.get("cursor", 0));
        command.resync_count = static_cast<uint32_t>(trigger_ids.size());
        for (uint32_t i = 0; i < command.resync_count; ++i) {
            command.resync_trigger_ids[i] = trigger_ids[i];
            command.resync_target_handles[i] = static_cast<uint64_t>(targets[i]);
            command.resync_values[i] = values[i];
        }
        publish_trigger_command(this, command, out);
    }
    return out;
}

Dictionary DCWorldExt::get_trigger_report() const {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->report();
}

PackedByteArray DCWorldExt::capture_trigger_state() const {
    return _trigger_runtime == nullptr ? PackedByteArray()
        : runtime_from(_trigger_runtime)->capture();
}

Dictionary DCWorldExt::restore_trigger_state(const PackedByteArray &bytes) {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->restore(bytes);
}

Dictionary DCWorldExt::clear_trigger_state() {
    return _trigger_runtime == nullptr ? unavailable()
        : runtime_from(_trigger_runtime)->clear_state();
}

} // namespace pk
