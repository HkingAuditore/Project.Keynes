#include "country_runtime_peer_includes.inc"

namespace pk {

using namespace godot;

CountryPeerResult NativeCountryRuntime::execute_peer_intent_main_thread(
        const CountryPeerIntent &intent, bool validate_local_identity) {
    CountryPeerResult result;
    result.protocol_version = intent.protocol_version;
    result.opcode = intent.opcode;
    result.request_id = intent.request_id;
    result.session_epoch = intent.session_epoch;
    result.country_generation = intent.country_generation;
    result.peer_generation = intent.peer_generation;
    result.day = intent.day;
    result.continuation_index = intent.continuation_index;
    result.country_slot = intent.country_slot;
    result.technology = intent.technology;
    result.target_handle = intent.target_handle;

    auto reject = [&](const char *reason) {
        result.code = CountryPeerResultCode::REJECTED;
        country_peer_copy_reason(result.reason, reason);
        ++_peer_results_consumed;
        return result;
    };
    if (intent.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION ||
        intent.request_id == 0 || intent.day < 0 ||
        (validate_local_identity &&
         (intent.session_epoch != _session_epoch ||
          intent.country_generation == 0 ||
          intent.country_generation > _generation)))
        return reject("country_peer_adapter_identity_invalid");

    const bool effect_intent =
        intent.opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NOTIFY_ERA_REWARD;
    const bool modifier_intent =
        intent.opcode == CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER;
    const bool economy_intent =
        intent.opcode == CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE;
    if (!effect_intent && !modifier_intent && !economy_intent)
        return reject("country_peer_intent_opcode_invalid");

    if (intent.opcode == CountryPeerIntentCode::NOTIFY_ERA_REWARD) {
        if (!_effect_runtime_enabled || _effect_runtime == nullptr)
            return reject("country_peer_effect_runtime_unavailable");
        if (_effect_runtime->committed_generation() < intent.peer_generation)
            return reject("country_peer_adapter_effect_generation_regressed");
        std::string peer_error;
        if (!_effect_runtime->notify_era_reward_technology_activated_pod(
                intent.target_handle, intent.technology, intent.day,
                peer_error))
            return reject(peer_error.empty() ? "country_peer_era_reward_rejected"
                                             : peer_error.c_str());
        result.code = CountryPeerResultCode::APPLIED;
        result.committed_peer_generation = _effect_runtime->committed_generation();
        ++_peer_results_consumed;
        return result;
    }
    if (intent.opcode == CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE) {
        if (_economy_runtime == nullptr)
            return reject("country_peer_economy_runtime_unavailable");
        if (economy_api::committed_generation(*_economy_runtime) < intent.peer_generation)
            return reject("country_peer_adapter_economy_generation_regressed");
        economy_api::notify_era_milestone_activated(*_economy_runtime, intent.target_handle);
        result.code = CountryPeerResultCode::APPLIED;
        result.committed_peer_generation = economy_api::committed_generation(*_economy_runtime);
        ++_peer_results_consumed;
        return result;
    }

    int32_t validated_slot = -1;
    if (intent.country_slot < 0 || intent.technology < 0 ||
        intent.technology >= static_cast<int32_t>(_technology_ids.size()) ||
        !validate_handle(intent.target_handle, validated_slot) ||
        validated_slot != intent.country_slot)
        return reject("country_peer_intent_target_invalid");

    const std::string &modifier_key =
        intent.technology < static_cast<int32_t>(
            _technology_modifier_definition_keys.size())
        ? _technology_modifier_definition_keys[
              static_cast<size_t>(intent.technology)]
        : std::string{};
    uint8_t technology_flags = 0;
    if (_modifier_runtime != nullptr && modifier_api::configured(*_modifier_runtime) &&
        !modifier_key.empty() && modifier_api::has_technology_effect(*_modifier_runtime,
            intent.target_handle, modifier_key, intent.technology))
        technology_flags |= COUNTRY_PEER_MODIFIER_APPLIED;

    if (intent.opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT) {
        // Route onto the Effect POD both once the worker owns EFFECT and in
        // the ACTIVE grant-pending window before its first committed day.
        // In that window the sync EffectRuntime is no longer driven (the
        // worker Effect stage is), while resolve_pending_country_effect_peers
        // only promotes PENDING results from the POD snapshot. Registering on
        // the sync facade there left the instance unfired and the Country
        // plan waiting on the peer forever (day_wait_peer_stall_timeout),
        // e.g. for a GRANT_TECHNOLOGY submitted on the first game day.
        const bool effect_worker_authoritative = _simulation_host != nullptr &&
            _simulation_host->effect_pod_transport_ready() &&
            _simulation_host->domain_main_thread_suppressed(RuntimeDomainId::EFFECT);
        {
            // Unconditional entry probe: tells us the adapter actually ran and
            // which branch it picked. Rate limited.
            static int s_entry_left = 30;
            if (s_entry_left-- > 0) {
                UtilityFunctions::print(vformat(
                    "[tech-ack-diag/entry] tech=%d instance=%d eff_gen=%d "
                    "host=%d effect_worker_auth=%d effect_enabled=%d "
                    "effect_runtime=%d branch=%s",
                    intent.technology,
                    static_cast<int64_t>(intent.effect_instance_id),
                    static_cast<int64_t>(intent.effect_generation),
                    _simulation_host != nullptr ? 1 : 0,
                    effect_worker_authoritative ? 1 : 0,
                    _effect_runtime_enabled ? 1 : 0,
                    _effect_runtime != nullptr ? 1 : 0,
                    effect_worker_authoritative ? "pod" : "sync"));
            }
        }
        // F8 ACTIVE: sync EffectRuntime is writeback-only. Route technology
        // registration onto the Effect POD unique-writer and gate READY on
        // the published POD fire ACK — never mutate the sync facade here.
        if (effect_worker_authoritative) {
            if (intent.effect_generation == 0 ||
                intent.effect_generation != static_cast<uint32_t>(
                    intent.target_handle >> 32U) ||
                intent.effect_instance_id == 0)
                return reject("country_peer_effect_generation_invalid");
            const std::string program_key =
                std::string("technology.") +
                _technology_ids[static_cast<size_t>(intent.technology)];
            const int32_t program_id =
                _simulation_host->effect_pod_program_id_for_key(
                    program_key.c_str());
            if (program_id < 0) {
                // Catalog has no Effect program for this technology. Treat as
                // fire-acked so activation is not pinned forever.
                technology_flags |= COUNTRY_PEER_EFFECT_EXISTS |
                    COUNTRY_PEER_EFFECT_FIRE_ACKED;
                result.code = CountryPeerResultCode::READY;
                result.technology_flags = technology_flags;
                result.committed_peer_generation = intent.peer_generation;
                ++_peer_results_consumed;
                return result;
            }
            std::string peer_error;
            if (!_simulation_host->ensure_effect_pod_technology_instance(
                    static_cast<int64_t>(intent.effect_instance_id),
                    intent.effect_generation, program_id,
                    intent.target_handle, intent.effect_generation,
                    intent.day, peer_error)) {
                return reject(peer_error.empty()
                    ? "country_peer_effect_pod_queue_rejected"
                    : peer_error.c_str());
            }
            technology_flags |= COUNTRY_PEER_EFFECT_EXISTS;
            if (_simulation_host->effect_pod_instance_fire_acked(
                    static_cast<int64_t>(intent.effect_instance_id),
                    intent.effect_generation)) {
                technology_flags |= COUNTRY_PEER_EFFECT_FIRE_ACKED;
                result.code = CountryPeerResultCode::READY;
            } else {
                static int s_pod_left = 30;
                if (s_pod_left-- > 0) {
                    UtilityFunctions::print(vformat("[tech-ack-diag/pod] %s",
                        String(_simulation_host
                            ->describe_effect_pod_technology_state(
                                static_cast<int64_t>(intent.effect_instance_id),
                                intent.effect_generation, program_id,
                                intent.technology).c_str())));
                }
                result.code = CountryPeerResultCode::PENDING;
            }
            result.technology_flags = technology_flags;
            result.committed_peer_generation = intent.peer_generation;
            ++_peer_results_consumed;
            return result;
        }
        if (!_effect_runtime_enabled || _effect_runtime == nullptr)
            return reject("country_peer_effect_runtime_unavailable");
        if (_effect_runtime->committed_generation() < intent.peer_generation)
            return reject("country_peer_adapter_effect_generation_regressed");
        if (intent.effect_generation == 0 ||
            intent.effect_generation != static_cast<uint32_t>(
                intent.target_handle >> 32U) ||
            intent.effect_instance_id == 0)
            return reject("country_peer_effect_generation_invalid");
        // Ask whichever side owns EFFECT. The helper reports "unknown" through
        // its return value; unknown is treated as absent, which is what the old
        // unconditional `has_instance_pod` effectively did on every path and
        // keeps NUDGE's rejection token unchanged.
        bool exists = false;
        effect_pod_instance_exists(
            _effect_runtime, _effect_forwarder,
            static_cast<int64_t>(intent.effect_instance_id),
            intent.effect_generation, exists);
        if (!exists) {
            if (intent.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT)
                return reject("country_peer_effect_instance_missing");
            std::string peer_error;
            // Same door as the bootstrap install. On the legacy authority the
            // forwarder delegates to upsert_instance_pod (and shadow-mirrors to
            // the worker); if EFFECT flipped to the worker between the guard
            // above and here, the row still lands on the side that owns it
            // instead of being erased by the next snapshot.
            if (!effect_pod_upsert(
                    _effect_runtime, _effect_forwarder,
                    static_cast<int64_t>(intent.effect_instance_id),
                    std::string("technology.") +
                        _technology_ids[static_cast<size_t>(intent.technology)],
                    intent.effect_generation, 0x54454348,
                    intent.technology + 1, intent.target_handle,
                    intent.target_handle, intent.effect_generation, 0,
                    intent.day, -1, true, peer_error))
                return reject(peer_error.empty()
                    ? "country_peer_effect_upsert_rejected"
                    : peer_error.c_str());
        }
        if (!_effect_runtime->instance_fire_acked_pod(
                static_cast<int64_t>(intent.effect_instance_id),
                intent.effect_generation) &&
            !_effect_runtime->nudge_unacked_instance_pod(
                static_cast<int64_t>(intent.effect_instance_id),
                intent.effect_generation, intent.day))
            return reject("country_peer_effect_nudge_rejected");

        technology_flags |= COUNTRY_PEER_EFFECT_EXISTS;
        if (_effect_runtime->instance_fire_acked_pod(
                static_cast<int64_t>(intent.effect_instance_id),
                intent.effect_generation)) {
            technology_flags |= COUNTRY_PEER_EFFECT_FIRE_ACKED;
            result.code = CountryPeerResultCode::READY;
        } else {
            static int s_sync_left = 30;
            if (s_sync_left-- > 0) {
                UtilityFunctions::print(vformat(
                    "[tech-ack-diag/sync] tech=%d instance=%d gen=%d "
                    "existed=%d day=%d committed_gen=%d",
                    intent.technology,
                    static_cast<int64_t>(intent.effect_instance_id),
                    static_cast<int64_t>(intent.effect_generation),
                    exists ? 1 : 0, intent.day,
                    static_cast<int64_t>(
                        _effect_runtime->committed_generation())));
            }
            result.code = CountryPeerResultCode::PENDING;
        }
        result.technology_flags = technology_flags;
        result.committed_peer_generation = _effect_runtime->committed_generation();
        ++_peer_results_consumed;
        return result;
    }

    if (_modifier_runtime == nullptr || !modifier_api::configured(*_modifier_runtime) ||
        modifier_key.empty())
        return reject("country_peer_modifier_runtime_unavailable");
    if (modifier_api::domain_snapshot_version(*_modifier_runtime, ModifierApi::COUNTRY) <
        intent.peer_generation)
        return reject("country_peer_adapter_modifier_generation_regressed");
    if ((technology_flags & COUNTRY_PEER_MODIFIER_APPLIED) == 0) {
        std::string peer_error;
        if (!modifier_api::apply_technology_effect(*_modifier_runtime,
                intent.target_handle, modifier_key, intent.technology,
                intent.day, peer_error))
            return reject(peer_error.empty()
                ? "country_peer_modifier_apply_rejected"
                : peer_error.c_str());
        technology_flags |= COUNTRY_PEER_MODIFIER_APPLIED;
    }
    result.code = CountryPeerResultCode::APPLIED;
    result.technology_flags = technology_flags;
    result.committed_peer_generation =
        modifier_api::domain_snapshot_version(*_modifier_runtime, ModifierApi::COUNTRY);
    ++_peer_results_consumed;
    return result;
}

CountryPeerResult NativeCountryRuntime::execute_peer_intent_from_worker(
        const CountryPeerIntent &intent) {
    return execute_peer_intent_main_thread(intent, false);
}

bool NativeCountryRuntime::service_peer_intents_main_thread(
        int32_t max_intents, PeerAdapterServiceReport &out,
        std::string &error) {
    out = PeerAdapterServiceReport{};
    error.clear();
    drain_effect_host_command_receipts();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_peer_adapter_runtime_unavailable";
        return false;
    }
    if (!_peer_async_mode) {
        error = "country_peer_adapter_async_mode_required";
        return false;
    }
    if (max_intents <= 0 || max_intents > 4096) {
        error = "country_peer_adapter_limit_invalid";
        return false;
    }

    std::vector<uint64_t> request_ids;
    request_ids.reserve(_peer_pending_intents.size());
    for (const auto &entry : _peer_pending_intents)
        request_ids.push_back(entry.first);
    std::sort(request_ids.begin(), request_ids.end());
    if (request_ids.size() > static_cast<size_t>(max_intents))
        request_ids.resize(static_cast<size_t>(max_intents));

    for (const uint64_t request_id : request_ids) {
        const auto found = _peer_pending_intents.find(request_id);
        if (found == _peer_pending_intents.end()) continue;
        const CountryPeerIntent intent = found->second;
        _peer_intent_queue.erase(std::remove(_peer_intent_queue.begin(),
                                            _peer_intent_queue.end(), request_id),
                                 _peer_intent_queue.end());
        ++out.inspected;
        out.last_request_id = request_id;
        switch (intent.opcode) {
        case CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT:
        case CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT:
        case CountryPeerIntentCode::NOTIFY_ERA_REWARD:
            ++out.effect_intents;
            break;
        case CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER:
            ++out.modifier_intents;
            break;
        case CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE:
            ++out.economy_intents;
            break;
        }

        const CountryPeerResult result = execute_peer_intent_main_thread(intent);
        out.last_reason = result.reason.data();
        switch (result.code) {
        case CountryPeerResultCode::READY:
        case CountryPeerResultCode::APPLIED:
            ++out.completed;
            break;
        case CountryPeerResultCode::PENDING:
            ++out.pending;
            break;
        case CountryPeerResultCode::REJECTED:
        case CountryPeerResultCode::STALE:
            ++out.rejected;
            break;
        }
        std::string submit_error;
        if (!submit_peer_result(result, submit_error)) {
            error = submit_error.empty()
                ? "country_peer_adapter_result_submit_failed"
                : submit_error;
            return false;
        }
        if (_simulation_host != nullptr && !_sync_store_writes_forbidden &&
            _simulation_host->country_pod_configured() &&
            result.code != CountryPeerResultCode::PENDING) {
            std::string mirror_error;
            _simulation_host->mirror_country_peer_result(result, mirror_error);
        }
    }
    return true;
}

} // namespace pk
