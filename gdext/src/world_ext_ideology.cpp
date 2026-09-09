#include "world_ext.h"

#include "country_runtime.h"
#include "economy_runtime.h"
#include "effect_runtime.h"
#include "ideology_runtime.h"
#include "native_simulation_host.h"

#include <algorithm>

namespace pk {
using namespace godot;

namespace {
NativeIdeologyRuntime *ideology_runtime_from(void *opaque) {
    return static_cast<NativeIdeologyRuntime *>(opaque);
}
const NativeIdeologyRuntime *ideology_runtime_from(const void *opaque) {
    return static_cast<const NativeIdeologyRuntime *>(opaque);
}
Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "ideology_runtime_unavailable";
    return out;
}

uint64_t worker_request_id(uint32_t producer_id, uint64_t sequence,
        uint16_t opcode, uint64_t country_handle) {
    uint64_t hash = 1469598103934665603ull;
    const auto mix = [&hash](uint64_t value) {
        for (uint32_t byte = 0; byte < 8; ++byte) {
            hash ^= static_cast<uint8_t>((value >> (byte * 8u)) & 0xffu);
            hash *= 1099511628211ull;
        }
    };
    mix(producer_id); mix(sequence); mix(opcode); mix(country_handle);
    return hash == 0 ? 1 : hash;
}

RuntimeIdeologyOpinionSnapshot copy_opinion_snapshot(
        const NativeEconomyRuntime::CountryClassOpinionSnapshot &source) {
    RuntimeIdeologyOpinionSnapshot out;
    out.revision = source.revision;
    out.class_hash = source.class_hash;
    out.committed_day = source.commit_day;
    out.country_count = static_cast<uint32_t>(std::max(0, source.country_count));
    out.class_count = static_cast<uint32_t>(std::max(0, source.class_count));
    out.country_handles = source.country_handles;
    out.country_generations = source.country_generations;
    out.population = source.population;
    out.funds = source.funds;
    out.owner_employed = source.owner_employed;
    out.satisfaction_weighted = source.satisfaction_weighted;
    out.satisfaction_q16 = source.satisfaction_q16;
    return out;
}
} // namespace

Dictionary DCWorldExt::configure_ideologies(const Dictionary &catalog) {
    if (_ideology_runtime == nullptr) _ideology_runtime = new NativeIdeologyRuntime();
    ideology_runtime_from(_ideology_runtime)->attach_country_runtime(
        static_cast<NativeCountryRuntime *>(_country_runtime));
    ideology_runtime_from(_ideology_runtime)->attach_economy_runtime(
        static_cast<NativeEconomyRuntime *>(_economy_runtime));
    ideology_runtime_from(_ideology_runtime)->attach_effect_runtime(
        static_cast<EffectRuntime *>(_effect_runtime));
    Dictionary result = ideology_runtime_from(_ideology_runtime)->configure(catalog);
    if (!bool(result.get("ok", false)) || _country_runtime == nullptr)
        return result;
    RuntimeCountryPodSnapshot country;
    RuntimeIdeologyPodCatalog pod_catalog;
    std::string error;
    if (!static_cast<NativeCountryRuntime *>(_country_runtime)->export_pod_snapshot(
            country, error) ||
        !ideology_runtime_from(_ideology_runtime)->export_pod_catalog(
            country, pod_catalog, error)) {
        result["worker_shadow_configured"] = false;
        result["worker_shadow_reason"] = String(error.c_str());
        return result;
    }
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    const bool configured = _runtime_host->configure_ideology_pod(
        pod_catalog, error);
    result["worker_shadow_configured"] = configured;
    result["worker_catalog_hash"] = static_cast<int64_t>(pod_catalog.catalog_hash);
    if (!configured) result["worker_shadow_reason"] = String(error.c_str());
    if (configured && _economy_runtime != nullptr) {
        RuntimeIdeologyOpinionSnapshot opinion = copy_opinion_snapshot(
            static_cast<NativeEconomyRuntime *>(_economy_runtime)
                ->country_class_opinion_snapshot());
        std::string opinion_error;
        result["worker_opinion_published"] =
            _runtime_host->publish_ideology_opinion_snapshot(
                opinion, opinion_error);
    }
    return result;
}

Dictionary DCWorldExt::submit_ideology_commands(const Dictionary &batch) {
    if (_ideology_runtime == nullptr) return unavailable();
    Dictionary result = ideology_runtime_from(_ideology_runtime)->submit_commands(batch);
    if (!bool(result.get("ok", false)) || _runtime_host == nullptr)
        return result;
    const PackedInt32Array opcodes = batch.get("opcodes", PackedInt32Array());
    const PackedInt32Array producers = batch.get("producer_ids", PackedInt32Array());
    const PackedInt32Array priorities = batch.get("source_priorities", PackedInt32Array());
    const PackedInt32Array ideology_ids = batch.get("ideology_ids", PackedInt32Array());
    const PackedInt32Array choices = batch.get("choice_indices", PackedInt32Array());
    const PackedInt32Array gates = batch.get("gate_ids", PackedInt32Array());
    const PackedInt64Array days = batch.get("effective_days", PackedInt64Array());
    const PackedInt64Array sequences = batch.get("sequences", PackedInt64Array());
    const PackedInt64Array handles = batch.get("country_handles", PackedInt64Array());
    const PackedInt64Array values = batch.get("values_q16", PackedInt64Array());
    const PackedInt64Array offers = batch.get("offer_generations", PackedInt64Array());
    bool mirrored = true;
    std::string error;
    for (int32_t index = 0; index < opcodes.size(); ++index) {
        RuntimeIdeologyPodCommand command;
        command.producer_id = producers.is_empty() ? 1u :
            static_cast<uint32_t>(std::max(0, producers[index]));
        command.sequence = static_cast<uint64_t>(std::max<int64_t>(0, sequences[index]));
        command.source_priority = priorities[index];
        command.opcode = static_cast<RuntimeIdeologyPodOpcode>(opcodes[index]);
        command.country_handle = static_cast<uint64_t>(handles[index]);
        command.request_id = worker_request_id(command.producer_id,
            command.sequence, static_cast<uint16_t>(command.opcode),
            command.country_handle);
        command.requested_day = days[index];
        command.effective_day = days[index];
        command.ideology_id = ideology_ids[index];
        command.value_q16 = values[index];
        command.offer_generation = static_cast<uint32_t>(
            std::max<int64_t>(0, offers[index]));
        command.choice_index = choices[index];
        command.gate_id = gates[index];
        if (!_runtime_host->queue_ideology_pod_command(command, error)) {
            mirrored = false;
            break;
        }
    }
    result["worker_shadow_mirrored"] = mirrored;
    if (!mirrored) result["worker_shadow_reason"] = String(error.c_str());
    return result;
}

Dictionary DCWorldExt::publish_ideology_worker_inputs() {
    Dictionary out;
    if (_runtime_host == nullptr || _economy_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "ideology_worker_inputs_unavailable";
        return out;
    }
    RuntimeIdeologyOpinionSnapshot snapshot = copy_opinion_snapshot(
        static_cast<NativeEconomyRuntime *>(_economy_runtime)
            ->country_class_opinion_snapshot());
    std::string error;
    const bool ok = _runtime_host->publish_ideology_opinion_snapshot(
        snapshot, error);
    out["ok"] = ok;
    out["code"] = ok ? "ok" : String(error.c_str());
    out["revision"] = static_cast<int64_t>(snapshot.revision);
    out["committed_day"] = snapshot.committed_day;
    return out;
}

Dictionary DCWorldExt::poll_ideology_worker_intent() {
    Dictionary out;
    if (_runtime_host == nullptr) { out["ok"] = false; out["code"] = "runtime_host_unavailable"; return out; }
    RuntimeDomainIntent intent;
    if (!_runtime_host->poll_ideology_pod_intent(intent)) {
        out["ok"] = true; out["available"] = false; return out;
    }
    out["ok"] = true; out["available"] = true;
    out["request_id"] = static_cast<int64_t>(intent.request_id);
    out["transaction_id"] = static_cast<int64_t>(intent.source_id);
    out["target_handle"] = static_cast<int64_t>(intent.target_handle);
    out["target_generation"] = static_cast<int64_t>(intent.target_generation);
    out["effective_day"] = intent.effective_day;
    out["flags"] = static_cast<int64_t>(intent.flags);
    PackedInt64Array payload;
    for (int64_t value : intent.payload) payload.append(value);
    out["payload"] = payload;
    return out;
}

Dictionary DCWorldExt::submit_ideology_worker_ack(const Dictionary &source) {
    Dictionary out;
    if (_runtime_host == nullptr) { out["ok"] = false; out["code"] = "runtime_host_unavailable"; return out; }
    RuntimeDomainAck ack;
    ack.request_id = static_cast<uint64_t>(static_cast<int64_t>(source.get("request_id", 0)));
    ack.transaction_id = static_cast<uint64_t>(static_cast<int64_t>(source.get("transaction_id", 0)));
    ack.target_handle = static_cast<uint64_t>(static_cast<int64_t>(source.get("target_handle", 0)));
    ack.target_generation = static_cast<uint32_t>(static_cast<int64_t>(source.get("target_generation", 0)));
    ack.domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
    ack.code = static_cast<RuntimeDomainAckCode>(static_cast<int32_t>(source.get("code", 0)));
    ack.effective_day = static_cast<int64_t>(source.get("effective_day", 0));
    std::string error;
    const bool ok = _runtime_host->submit_ideology_pod_ack(ack, error);
    out["ok"] = ok; out["code"] = ok ? "ok" : String(error.c_str());
    return out;
}

Dictionary DCWorldExt::poll_ideology_receipts(int64_t after_receipt_id,
        int32_t limit) const {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->poll_receipts(
            after_receipt_id, limit);
}

Dictionary DCWorldExt::run_ideology_daily(int64_t day_index) {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->run_daily(day_index);
}

bool DCWorldExt::ideology_should_run(int64_t day_index) const {
    return _ideology_runtime != nullptr &&
        ideology_runtime_from(_ideology_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::get_ideology_snapshot(int64_t country_handle) const {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->snapshot(country_handle);
}

Dictionary DCWorldExt::explain_ideology(int64_t country_handle, int32_t ideology_id) {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->explain(country_handle, ideology_id);
}

Dictionary DCWorldExt::explain_ideologies(int64_t country_handle,
        const PackedInt32Array &ideology_ids) {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->explain_batch(
            country_handle, ideology_ids);
}

Dictionary DCWorldExt::get_ideology_report() const {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->report();
}

PackedByteArray DCWorldExt::capture_ideology_state() const {
    return _ideology_runtime == nullptr ? PackedByteArray()
        : ideology_runtime_from(_ideology_runtime)->capture();
}

Dictionary DCWorldExt::restore_ideology_state(const PackedByteArray &bytes) {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->restore(bytes);
}

Dictionary DCWorldExt::clear_ideology_state() {
    return _ideology_runtime == nullptr ? unavailable()
        : ideology_runtime_from(_ideology_runtime)->clear_state();
}

} // namespace pk
