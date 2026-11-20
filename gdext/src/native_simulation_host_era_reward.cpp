#include "native_simulation_day_context.h"
#include "native_simulation_host_support.h"

#include "country_api.h"
#include "effect_runtime.h"
#include "pk_log.h"
#include "runtime_era_reward.h"
#include "runtime_golden_diagnostics.h"

#include <algorithm>

namespace pk {
namespace {

constexpr uint32_t ERA_REWARD_PRODUCER = 200;
constexpr int32_t MODIFIER_ENTITY_SCOPE = 2;

} // namespace

std::shared_ptr<const RuntimeEraRewardView> NativeSimulationHost::latest_era_reward() const {
    return std::atomic_load(&_published_era_reward);
}

std::shared_ptr<const RuntimeEraRewardView> NativeSimulationHost::capture_era_reward() const {
    if (_effect_adapter_runtime == nullptr) return nullptr;
    auto view = std::make_shared<RuntimeEraRewardView>();
    view->offer = _effect_adapter_runtime->era_reward_offer_snapshot();
    view->needs_choice = _effect_adapter_runtime->era_reward_requires_choice();
    return view;
}

godot::Dictionary NativeSimulationHost::submit_era_reward_request(
        std::shared_ptr<RuntimeEraRewardRequest> request) {
    const auto available = [&] {
        const auto current = state();
        return effect_adapter_owned() && current != RuntimeWorkerState::FAULTED &&
            current != RuntimeWorkerState::STOPPING &&
            !_stop_requested.load(std::memory_order_acquire);
    };
    const auto reject = [](const char *code) {
        godot::Dictionary out;
        out["ok"] = false;
        out["admitted"] = false;
        out["code"] = code;
        out["reason"] = code;
        return out;
    };
    if (const char *command = request->command(); command != nullptr) {
        const auto kind = request->kind;
        int64_t day = std::max<int64_t>(0, request->effective_day);
        {
            auto admission = lock_command_admission(day);
            if (!admission.owns_lock() || !available()) return reject("effect_runtime_unavailable");
            std::lock_guard<std::mutex> control(_control_mutex);
            if (_era_reward_requests.size() == RUNTIME_COMMAND_QUEUE_CAPACITY)
                return reject("era_command_queue_full");
            if (kind == RuntimeEraRewardRequest::Kind::SELECT) {
                const auto view = latest_era_reward();
                if (!view || godot::String(view->offer.get("status", "")) != "OPEN" ||
                        int64_t(view->offer.get("offer_generation", 0)) != request->offer_generation ||
                        std::any_of(_era_reward_requests.begin(), _era_reward_requests.end(),
                            [kind](const auto &queued) { return queued->kind == kind; }))
                    return reject("era_reward_offer_generation_stale");
                if (request->choice < 0 || request->choice >= 3)
                    return reject("era_reward_choice_invalid");
            }
            request->effective_day = day;
            _era_reward_requests.push_back(request);
        }
        if (inline_daily_mode()) service_era_reward_requests();
        else _control_cv.notify_one();
        godot::Dictionary out;
        out["ok"] = true;
        out["admitted"] = true;
        out["pending"] = true;
        out["code"] = "queued";
        out["effective_day"] = day;
        return out;
    }
    // Session binding and restore complete before commands are enabled.
    std::unique_lock<std::mutex> control(_control_mutex);
    if (!available()) return reject("effect_runtime_unavailable");
    _era_reward_requests.push_back(request);
    if (inline_daily_mode()) {
        control.unlock();
        service_era_reward_requests();
        return request->result;
    }
    _control_cv.notify_all();
    _control_cv.wait(control, [&] { return request->done || !available(); });
    return request->done ? request->result : reject("effect_runtime_unavailable");
}

bool NativeSimulationHost::service_era_reward_requests() {
    std::deque<std::shared_ptr<RuntimeEraRewardRequest>> requests;
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        requests = _era_reward_requests;
    }
    if (requests.empty()) return false;
    {
        std::lock_guard<std::mutex> boundary(_economy_authority_boundary_mutex);
        auto &effect = *_effect_adapter_runtime;
        bool reward_changed = false;
        for (const auto &request : requests) {
            auto &reply = request->result;
            if (request->kind == RuntimeEraRewardRequest::Kind::BIND_PLAYER) {
                std::string error;
                const bool bound = effect.bind_era_reward_player_country_pod(
                    request->country_handle, error);
                reply["ok"] = bound;
                if (!bound) reply["reason"] = godot::String(error.c_str());
                continue;
            }

            if (request->kind != RuntimeEraRewardRequest::Kind::SELECT) {
                execute_era_advancement_request(*request);
                continue;
            }
            const int64_t day = request->effective_day;
            reply = effect.choose_era_reward(request->offer_generation, request->choice, day, true);
            if (!bool(reply.get("ok", false))) continue;
            reward_changed = true;
            std::vector<EffectRuntime::EraRewardModifierCommand> commands;
            std::string error;
            if (effect.era_reward_selected_modifier_commands(commands, error)) {
                std::vector<RuntimeCommandPacket> packets;
                packets.reserve(commands.size());
                for (const auto &source : commands) {
                    const auto definition = _modifier_definition_id_by_key_hash.find(
                        RuntimeEffectPodAuthority::hash_text(source.definition_key.c_str()));
                    if (definition == _modifier_definition_id_by_key_hash.end()) {
                        error = "era_reward_modifier_definition_missing";
                        break;
                    }
                    RuntimeModifierPodCommand command;
                    command.request_id = allocate_command_request_id();
                    command.producer_id = ERA_REWARD_PRODUCER;
                    command.sequence = allocate_producer_sequence(ERA_REWARD_PRODUCER);
                    command.requested_day = day;
                    command.effective_day = day;
                    command.opcode = static_cast<uint16_t>(RuntimeModifierPodOpcode::APPLY);
                    command.domain = static_cast<uint16_t>(source.domain);
                    command.definition_id = definition->second;
                    command.scope = MODIFIER_ENTITY_SCOPE;
                    command.entity_handle = source.target_handle;
                    command.source_type = EffectRuntime::ERA_REWARD_SOURCE_TYPE;
                    command.source_id = static_cast<uint64_t>(source.source_id);
                    command.duration_days = source.duration_days;
                    command.stacks = source.stacks;
                    command.magnitude_q16 = source.magnitude_q16;
                    command.target_generation = static_cast<uint32_t>(source.target_handle >> 32u);
                    packets.push_back(encode_modifier_packet(command));
                }
                if (error.empty() && !enqueue_batch_at(std::move(packets), nullptr, false))
                    error = "era_reward_modifier_submit_failed";
            }
            if (error.empty()) {
                reply["effective_day"] = day;
            } else {
                effect.settle_era_reward_selection_pod(false, error.c_str());
                reply["ok"] = false;
                reply["reason"] = godot::String(error.c_str());
            }
        }
        const auto committed = std::atomic_load(&_latest_commit);
        if (reward_changed && committed && committed->day_tail && committed->day_tail->golden) {
            auto updated = std::make_shared<RuntimeCommit>(*committed);
            auto tail = std::make_shared<RuntimeDayTail>(*committed->day_tail);
            tail->golden = std::make_shared<RuntimeGoldenSnapshot>(
                capture_golden_snapshot(committed->header.committed_day));
            updated->day_tail = std::move(tail);
            std::atomic_store(&_latest_commit, std::shared_ptr<const RuntimeCommit>(std::move(updated)));
        }
        std::atomic_store(&_published_era_reward, capture_era_reward());
    }
    for (const auto &request : requests) {
        if (const char *command = request->command())
            publish_boundary_command_result(command, request->advancement_sequence, request->result);
    }
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        for (const auto &request : requests) request->done = true;
        _era_reward_requests.erase(_era_reward_requests.begin(),
                                   _era_reward_requests.begin() + requests.size());
    }
    _control_cv.notify_all();
    return true;
}

const char *NativeSimulationHost::settle_era_rewards(DayExecution &day) {
    auto &effect = *_effect_adapter_runtime;
    if (effect.era_reward_host_selection_pending()) {
        std::vector<EffectRuntime::EraRewardModifierCommand> commands;
        std::string error;
        if (!effect.era_reward_selected_modifier_commands(commands, error))
            return "era_reward_selected_modifier_invalid";
        const auto &snapshot = _modifier_pod_authority.snapshot();
        const uint64_t generation = static_cast<uint64_t>(commands.front().source_id);
        const bool applied = std::all_of(commands.begin(), commands.end(), [&](const auto &command) {
            const auto definition = _modifier_definition_id_by_key_hash.find(
                RuntimeEffectPodAuthority::hash_text(command.definition_key.c_str()));
            return definition != _modifier_definition_id_by_key_hash.end() &&
                std::any_of(snapshot.entries.begin(), snapshot.entries.end(), [&](const auto &entry) {
                    return entry.modifier_handle != 0 && entry.domain == command.domain &&
                        entry.definition_id == definition->second &&
                        entry.scope == MODIFIER_ENTITY_SCOPE &&
                        entry.entity_handle == command.target_handle &&
                        entry.source_type == EffectRuntime::ERA_REWARD_SOURCE_TYPE &&
                        entry.source_id == generation;
                });
        });
        if (applied) {
            effect.settle_era_reward_selection_pod(true, "");
        } else {
            const bool due = std::any_of(day.day_commands.begin(), day.day_commands.end(),
                [generation](const RuntimeCommandPacket &packet) {
                    RuntimeModifierPodCommand command;
                    return packet.envelope.producer_id == ERA_REWARD_PRODUCER &&
                        decode_modifier_packet(packet, command) &&
                        command.source_type == EffectRuntime::ERA_REWARD_SOURCE_TYPE &&
                        command.source_id == generation;
                });
            if (due)
                effect.settle_era_reward_selection_pod(false, "era_reward_modifier_commit_missing");
        }
    }
    CountryWorkerNotification notification;
    while (poll_country_worker_notification(notification)) {
        if (notification.snapshot == nullptr || _effect_adapter_country == nullptr)
            return "era_reward_country_snapshot_unavailable";
        const auto &intent = notification.intent;
        const auto committed_view = country_api::copy_committed_read_view(
            *_effect_adapter_country, *notification.snapshot);
        if (!committed_view)
            return "era_reward_country_snapshot_invalid";
        std::string error;
        effect.set_era_reward_country_view(committed_view.get());
        const bool delivered = effect.notify_era_reward_technology_activated_pod(
            intent.target_handle, intent.technology, intent.day, error);
        effect.set_era_reward_country_view(nullptr);
        if (!delivered) {
            pk::log_error("[era-reward] milestone delivery failed: %s", error.c_str());
            return "era_reward_milestone_delivery_failed";
        }
    }
    return nullptr;
}

} // namespace pk
