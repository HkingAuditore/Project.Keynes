#include "native_simulation_host_trigger_delivery.h"

#include "country_api.h"
#include "effect_runtime.h"
#include "native_simulation_day_context.h"
#include "native_simulation_host.h"
#include "pk_log.h"
#include "trigger_runtime.h"

#include <algorithm>

namespace pk {

using namespace godot;

godot::Dictionary reconcile_trigger_research(TriggerRuntime &trigger,
    const NativeCountryRuntime &country, const EffectRuntime *effect_runtime,
    int limit, const std::function<godot::Dictionary(int32_t, int64_t, int32_t, int64_t)> &submit) {
    RuntimeTriggerPodCatalog catalog;
    RuntimeTriggerSnapshot snapshot;
    std::string error;
    Dictionary out;
    out["ok"] = false;
    out["complete"] = false;
    if (!trigger.export_pod_catalog(catalog, error) ||
        !trigger.export_pod_snapshot(snapshot, error)) {
        out["reason"] = String(error.c_str());
        return out;
    }
    if (!country_api::economy_available(country)) return out;
    std::unordered_map<uint64_t, Dictionary> countries;
    int32_t submitted = 0;
    bool delivery_pending = false;
    const int64_t day = std::max<int64_t>(1, snapshot.committed_day + 1);
    for (const auto &state : snapshot.states) {
        if (!state.completed || state.trigger_id < 0 ||
            state.trigger_id >= static_cast<int32_t>(catalog.definitions.size())) continue;
        const auto &definition = catalog.definitions[state.trigger_id];
        if (definition.development_metric_id < 0 || definition.effect_count != 1 ||
            definition.mode != static_cast<int32_t>(RuntimeTriggerMode::ONE_SHOT)) continue;
        const auto &effect = catalog.effects[definition.effect_begin];
        if (effect.action != static_cast<int32_t>(RuntimeTriggerAction::COUNTRY_COMMAND) ||
            effect.opcode != CountryApi::COMMAND_DISCOVER_COUNTRY_SIGNAL) continue;
        auto found = countries.find(state.target_handle);
        if (found == countries.end())
            found = countries.emplace(state.target_handle,
                country_api::country_snapshot(country, static_cast<int64_t>(state.target_handle))).first;
        const Dictionary &owner = found->second;
        if (!static_cast<bool>(owner.get("ok", false))) continue;
        const int32_t signal = static_cast<int32_t>(effect.payload[0]);
        if (country_api::has_research_signal(country, static_cast<int32_t>(state.target_handle), signal)) continue;
        if (effect_runtime && effect_runtime->has_pending_research_discovery(state.target_handle, signal)) {
            delivery_pending = true;
            continue;
        }
        const int32_t cell = static_cast<int32_t>(owner.get("cell", -1));
        if (cell < 0) continue;
        const bool already_pending = std::any_of(snapshot.pending_effects.begin(),
            snapshot.pending_effects.end(), [&state](const RuntimeTriggerEffectIntent &pending) {
                return pending.trigger_id == state.trigger_id &&
                    pending.target_handle == state.target_handle;
            });
        if (already_pending) continue;
        if (submitted >= std::max(1, std::min(limit, 256))) {
            out["ok"] = true;
            out["submitted"] = submitted;
            return out;
        }
        // This is an adapter reconciliation, not a second writer: Trigger
        // replays its durable completion through Effect and Country's normal
        // boundary. The representative owned cell is recorded as recovery
        // provenance at this boundary, not as the original sample location.
        const Dictionary replay = submit(
            state.trigger_id, static_cast<int64_t>(state.target_handle), cell, day);
        if (!static_cast<bool>(replay.get("ok", false))) {
            out["reason"] = replay.get("reason", "trigger_research_replay_failed");
            out["submitted"] = submitted;
            return out;
        }
        ++submitted;
    }
    out["ok"] = true;
    out["complete"] = !delivery_pending;
    out["submitted"] = submitted;
    return out;
}

std::shared_ptr<const TriggerRuntime> NativeSimulationHost::latest_trigger_read_view() const {
    const auto commit = std::atomic_load(&_latest_commit);
    return commit && commit->day_tail && commit->day_tail->trigger
        ? commit->day_tail->trigger : _trigger_delivery.initial_view;
}

const char *NativeSimulationHost::stage_trigger_delivery(DayExecution &day) {
    auto &delivery = _trigger_delivery;
    if (!delivery.runtime || !_effect_adapter_runtime) return nullptr;
    const int64_t committed_day = day.plan.context.day;
    RuntimeTriggerSnapshot snapshot;
    std::string error;
    if (!_domain_authority_runner.read_trigger_snapshot(snapshot, error) ||
        (snapshot.generation > delivery.runtime->pod_snapshot_generation() &&
         !delivery.runtime->apply_pod_snapshot(snapshot, error))) {
        pk::log_error("[trigger] executor delivery snapshot: %s", error.c_str());
        return "trigger_executor_snapshot_failed";
    }
    if (!delivery.research_reconciled && _effect_adapter_country &&
        !country_api::has_pending_effect_commands(*_effect_adapter_country)) {
        const auto country = country_asset_snapshot();
        const auto view = country
            ? country_api::copy_committed_read_view(*_effect_adapter_country, *country) : nullptr;
        if (view) {
            uint64_t replay_count = 0;
            const Dictionary recovery = reconcile_trigger_research(*delivery.runtime, *view,
                _effect_adapter_runtime, 64, [&](int32_t trigger, int64_t handle, int32_t cell, int64_t due) {
                    RuntimeTriggerCommand command;
                    command.opcode = RuntimeTriggerCommandOpcode::REPLAY_COMPLETED_RESEARCH_SIGNAL;
                    command.request_id = 0xE7F1000000000000ull | (static_cast<uint64_t>(due) << 16u) |
                        ++replay_count;
                    command.producer_id = 1;
                    command.sequence = command.request_id;
                    command.effective_day = command.requested_day = due;
                    command.trigger_id = trigger;
                    command.event.entity_handle = static_cast<uint64_t>(handle);
                    command.event.group_handle = static_cast<uint64_t>(cell);
                    Dictionary result;
                    result["ok"] = _domain_authority_runner.queue_trigger_command(command, error);
                    if (!error.empty()) result["reason"] = String(error.c_str());
                    return result;
                });
            if (!static_cast<bool>(recovery.get("ok", false)))
                return "trigger_executor_research_reconciliation_failed";
            delivery.research_reconciled = static_cast<bool>(recovery.get("complete", false));
        }
    }
    // The live Trigger effect cursor always moves after Effect has published
    // its ordinary daily adapter transactions and before the Ideology refresh.
    const Dictionary handed = delivery.runtime->handoff_effects(
        _effect_adapter_runtime, delivery.ideology, this, 512);
    if (!static_cast<bool>(handed.get("ok", false))) {
        pk::log_error("[trigger] executor handoff: %s",
            String(handed.get("reason", "")).utf8().get_data());
        return "trigger_executor_handoff_failed";
    }
    const PackedInt64Array ids = handed.get("effect_ids", PackedInt64Array());
    for (int64_t offset = 0; offset < ids.size(); offset += RUNTIME_TRIGGER_RESYNC_CAPACITY) {
        RuntimeTriggerCommand ack;
        ack.opcode = RuntimeTriggerCommandOpcode::ACK_EFFECT_IDS;
        ack.request_id = 0xE7F2000000000000ull | static_cast<uint64_t>(ids[offset]);
        ack.producer_id = 1;
        ack.sequence = ack.request_id;
        ack.effective_day = ack.requested_day = committed_day + 1;
        ack.resync_count = static_cast<uint32_t>(std::min<int64_t>(
            RUNTIME_TRIGGER_RESYNC_CAPACITY, ids.size() - offset));
        for (uint32_t i = 0; i < ack.resync_count; ++i) ack.resync_values[i] = ids[offset + i];
        if (!_domain_authority_runner.queue_trigger_command(ack, error))
            return "trigger_executor_ack_failed";
    }
    if (ids.size() > 0 && _effect_adapter_country) {
        const Dictionary country = _effect_adapter_runtime->dispatch_native_country(
            _effect_adapter_country, true);
        if (!static_cast<bool>(country.get("ok", false))) {
            pk::log_error("[trigger] executor Country delivery: %s",
                String(country.get("reason", "")).utf8().get_data());
            return "trigger_executor_country_dispatch_failed";
        }
    }
    _executor_day_tail->trigger = std::make_shared<TriggerRuntime>(*delivery.runtime);
    return nullptr;
}

} // namespace pk
