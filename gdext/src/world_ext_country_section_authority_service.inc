Dictionary DCWorldExt::service_country_worker_peer_adapter(
        int max_intents, bool shadow_replay) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (max_intents <= 0 || max_intents > 4096) {
        out["ok"] = false;
        out["code"] = "country_worker_adapter_limit_invalid";
        return out;
    }
    if (_runtime_host->effect_adapter_owned()) {
        out["ok"] = true;
        out["code"] = "country_executor_owned";
        return out;
    }
    const RuntimeThreadReport host_report = _runtime_host->report();
    if (!shadow_replay &&
        (host_report.mode != RuntimeSimulationMode::ACTIVE ||
         (host_report.requested_authority_mask &
          runtime_domain_mask(RuntimeDomainId::COUNTRY)) == 0u)) {
        static int s_not_auth_left = 12;
        const NativeSimulationHost::CountryWorkerProtocolStatus diag_status =
            _runtime_host->country_worker_protocol_status();
        if (diag_status.queued_intents > 0 && s_not_auth_left-- > 0) {
            UtilityFunctions::print(vformat(
                "[tech-ack-diag/pump] REFUSED not_authoritative mode=%d mask=0x%x queued=%d",
                static_cast<int64_t>(host_report.mode),
                static_cast<int64_t>(host_report.requested_authority_mask),
                static_cast<int64_t>(diag_status.queued_intents)));
        }
        // A real peer write is legal only for a worker that was explicitly
        // admitted in ACTIVE Country mode. In particular, SHADOW callers
        // must never accidentally mutate the legacy peer stores.
        out["ok"] = false;
        out["code"] = "country_worker_real_peer_adapter_not_authoritative";
        return out;
    }
    if (!shadow_replay && _country_runtime == nullptr) {
        out["ok"] = false;
        out["code"] = "country_worker_real_peer_adapter_country_missing";
        return out;
    }
    {
        // Distinguishes "pump never reaches the drain loop" from "pump runs but
        // Country published no intents". Rate limited; diagnostic only.
        static int s_pump_left = 20;
        const NativeSimulationHost::CountryWorkerProtocolStatus pump_status =
            _runtime_host->country_worker_protocol_status();
        if (pump_status.queued_intents > 0 && s_pump_left-- > 0) {
            UtilityFunctions::print(vformat(
                "[tech-ack-diag/pump] entering drain shadow_replay=%d "
                "queued=%d pending=%d",
                shadow_replay ? 1 : 0,
                static_cast<int64_t>(pump_status.queued_intents),
                static_cast<int64_t>(pump_status.pending_intents)));
        }
    }

    int inspected = 0;
    int replayed = 0;
    int rejected = 0;
    String last_reason;
    while (inspected < max_intents) {
        CountryPeerIntent intent;
        if (!_runtime_host->poll_country_worker_intent(intent)) break;

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

        if (shadow_replay) {
            // This is deliberately a replay result, not an Effect/Modifier
            // call. It proves the transport while keeping SHADOW free of
            // peer side effects.
            switch (intent.opcode) {
            case CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT:
            case CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT:
                result.code = CountryPeerResultCode::READY;
                result.technology_flags = static_cast<uint8_t>(
                    COUNTRY_PEER_EFFECT_EXISTS | COUNTRY_PEER_EFFECT_FIRE_ACKED);
                country_peer_copy_reason(result.reason, "shadow_peer_replay");
                break;
            case CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER:
                result.code = CountryPeerResultCode::APPLIED;
                result.technology_flags = COUNTRY_PEER_MODIFIER_APPLIED;
                country_peer_copy_reason(result.reason, "shadow_peer_replay");
                break;
            case CountryPeerIntentCode::NOTIFY_ERA_REWARD:
            case CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE:
                result.code = CountryPeerResultCode::APPLIED;
                country_peer_copy_reason(result.reason, "shadow_peer_replay");
                break;
            default:
                result.code = CountryPeerResultCode::REJECTED;
                country_peer_copy_reason(result.reason,
                                         "country_worker_peer_opcode_invalid");
                break;
            }
        } else {
            result = country_runtime_from(_country_runtime)
                ->execute_peer_intent_from_worker(intent);
        }
        if (result.code == CountryPeerResultCode::REJECTED) ++rejected;
        if (shadow_replay)
            result.committed_peer_generation = intent.peer_generation;
        std::string error;
        if (!_runtime_host->submit_country_worker_result(result, error)) {
            static int s_submit_fail_left = 12;
            if (s_submit_fail_left-- > 0) {
                UtilityFunctions::print(vformat(
                    "[tech-ack-diag/pump] submit FAILED request=%d code=%d tech=%d err=%s",
                    static_cast<int64_t>(result.request_id),
                    static_cast<int64_t>(result.code),
                    static_cast<int64_t>(result.technology),
                    String(error.c_str())));
            }
            out["ok"] = false;
            out["code"] = error.empty()
                ? "country_worker_peer_replay_submit_failed" : error.c_str();
            out["inspected"] = inspected;
            out["replayed"] = replayed;
            out["rejected"] = rejected;
            return out;
        }
        last_reason = String(result.reason.data());
        ++inspected;
        if (result.code != CountryPeerResultCode::REJECTED) ++replayed;
    }
    int notified = 0;
    String notification_error;
    NativeSimulationHost::CountryWorkerNotification notification;
    while (notified < max_intents &&
           !_runtime_host->effect_adapter_owned() &&
           _runtime_host->poll_country_worker_notification(notification)) {
        ++notified;
        // SHADOW keeps planning on the sync store, which already notified.
        if (shadow_replay || notification.snapshot == nullptr) continue;
        NativeCountryRuntime *source = country_runtime_from(_country_runtime);
        NativeCountryRuntime committed_view(*source);
        if (!committed_view.apply_committed_read_snapshot(
                *notification.snapshot)) {
            notification_error = "country_worker_notification_view_rejected";
            continue;
        }
        auto *effect = static_cast<EffectRuntime *>(_effect_runtime);
        if (effect != nullptr) effect->set_era_reward_country_view(&committed_view);
        const CountryPeerResult result =
            source->execute_peer_intent_from_worker(notification.intent);
        if (effect != nullptr) effect->set_era_reward_country_view(nullptr);
        if (result.code == CountryPeerResultCode::REJECTED)
            notification_error = String(result.reason.data());
    }
    if (!notification_error.is_empty())
        UtilityFunctions::printerr(
            String("[era-reward] milestone notification failed: ") +
            notification_error);
    out["notified"] = notified;
    out["notification_error"] = notification_error;

    const NativeSimulationHost::CountryWorkerProtocolStatus status =
        _runtime_host->country_worker_protocol_status();
    out["ok"] = true;
    out["code"] = "ok";
    out["shadow_replay"] = shadow_replay;
    out["real_adapter"] = !shadow_replay;
    out["inspected"] = inspected;
    out["replayed"] = replayed;
    out["rejected"] = rejected;
    out["last_reason"] = last_reason;
    out["pending_intents"] = static_cast<int64_t>(status.pending_intents);
    out["queued_intents"] = static_cast<int64_t>(status.queued_intents);
    out["plan_active"] = status.plan_active;
    out["waiting_for_peer"] = status.waiting_for_peer;
    return out;
}

Dictionary DCWorldExt::restore_country_runtime_checkpoint(
        const PackedByteArray &canonical_pkcn) {
    Dictionary out;
    if (_runtime_host == nullptr || _country_runtime == nullptr) {
        out["ok"] = false;
        out["available"] = false;
        out["code"] = "country_checkpoint_not_pending";
        return out;
    }
    CountryCoreCheckpoint checkpoint;
    std::string error;
    if (!_runtime_host->pending_country_checkpoint(checkpoint, error)) {
        out["ok"] = false;
        out["available"] = false;
        out["code"] = String(error.c_str());
        return out;
    }
    out["available"] = true;
    if (canonical_pkcn.size() !=
            static_cast<int64_t>(checkpoint.canonical_pkcn.size()) ||
        (!checkpoint.canonical_pkcn.empty() &&
         std::memcmp(canonical_pkcn.ptr(), checkpoint.canonical_pkcn.data(),
                     checkpoint.canonical_pkcn.size()) != 0)) {
        out["ok"] = false;
        out["code"] = "country_checkpoint_pkcn_mismatch";
        return out;
    }
    if (!country_runtime_from(_country_runtime)->restore_core_checkpoint(
            checkpoint, error)) {
        out["ok"] = false;
        out["code"] = String(error.empty()
            ? "country_checkpoint_restore_failed" : error.c_str());
        return out;
    }
    country_runtime_from(_country_runtime)->restore_effect_adapter(checkpoint.effect_adapter);
    out["ok"] = true;
    out["code"] = "ok";
    publish_restored_country_territory(out);
    out["generation"] = static_cast<int64_t>(checkpoint.generation);
    out["committed_day"] = checkpoint.committed_day;
    out["business_state_hash"] =
        static_cast<int64_t>(checkpoint.business_state_hash);
    return out;
}

bool DCWorldExt::runtime_country_core_protocol_self_test() {
    if (_country_runtime == nullptr) return false;
    std::string error;
    return country_runtime_from(_country_runtime)->protocol_contract_self_test(error);
}

bool DCWorldExt::runtime_country_peer_protocol_self_test() {
    if (_country_runtime == nullptr) return false;
    std::string error;
    return country_runtime_from(_country_runtime)->peer_protocol_self_test(error);
}

Dictionary DCWorldExt::configure_country_reference_trace(bool enabled,
                                                           int max_frames) {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->configure_reference_trace(
            enabled, max_frames);
}

Dictionary DCWorldExt::poll_country_reference_trace(int64_t after_frame_id,
                                                      int limit) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->poll_reference_trace(
            after_frame_id, limit);
}

Dictionary DCWorldExt::capture_country_reference_checkpoint() const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->capture_reference_checkpoint();
}

void DCWorldExt::set_country_sync_store_writes_forbidden(bool forbidden) {
    if (_country_runtime != nullptr)
        country_runtime_from(_country_runtime)->set_sync_store_writes_forbidden(
            forbidden);
}

Dictionary DCWorldExt::run_country_slice(const Dictionary &ctx) {
    if (_country_runtime == nullptr) return country_unavailable();
    if (_runtime_host != nullptr && _runtime_host->domain_main_thread_suppressed(
            RuntimeDomainId::COUNTRY)) {
        Dictionary out;
        out["ok"] = false;
        out["done"] = true;
        out["code"] = "country_worker_authoritative";
        out["path"] = "native_country_worker";
        out["authoritative"] = true;
        return out;
    }
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    const int64_t ai_day = static_cast<int64_t>(ctx.get("day_index", -1));
    country_ai_sync_plan(ai_day);
    Dictionary out = runtime->run_slice(ctx);
    if (static_cast<bool>(out.get("done", true)))
        country_ai_sync_finish(ai_day, static_cast<bool>(out.get("ok", false)), out);
    if (static_cast<bool>(out.get("ok", false)) &&
        static_cast<bool>(out.get("published_to_slot", false)) &&
        static_cast<int64_t>(out.get("changed_cells", 0)) > 0) {
        const int slot = component_id(StringName("cell_country_slot"));
        const auto publish_start = std::chrono::steady_clock::now();
        if (slot >= 0) {
            const PackedInt32Array indices = out.get("_changed_cell_indices", PackedInt32Array());
            const PackedInt32Array owners = out.get("_changed_cell_owners", PackedInt32Array());
            if (!indices.is_empty() && indices.size() == owners.size())
                write_i32_indexed(slot, indices, owners);
            else
                write_i32_range(slot, 0, runtime->cell_country_snapshot());
            _flush_slot_to_map(slot);
            ++_runtime_graph_flush_slot_count;
            _runtime_graph_visual_diff_cell_count += static_cast<uint64_t>(
                !indices.is_empty() ? indices.size() :
                static_cast<int64_t>(out.get("cell_count", 0)));
            const double publish_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - publish_start).count();
            runtime->mark_slot_publication(true, publish_ms);
            out["published_to_slot"] = true;
            out["slot_publish_ms"] = publish_ms;
            out["elapsed_ms"] = static_cast<double>(out.get("elapsed_ms", 0.0)) + publish_ms;
        } else {
            const double publish_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - publish_start).count();
            runtime->mark_slot_publication(false, publish_ms, "country_slot_unavailable");
            out["published_to_slot"] = false;
            out["publish_reason"] = "country_slot_unavailable";
        }
    }
    if (static_cast<bool>(out.get("ok", false)) &&
        static_cast<bool>(out.get("done", false)) &&
        _runtime_host != nullptr &&
        _runtime_host->country_pod_configured()) {
        RuntimeCountryPodSnapshot snapshot;
        std::string error;
        if (runtime->export_pod_snapshot(snapshot, error) && snapshot.state_hash != 0) {
            std::string publish_error;
            if (!_runtime_host->publish_country_reference(
                    snapshot.committed_day, snapshot.state_hash,
                    publish_error, &snapshot)) {
                out["country_reference_ok"] = false;
                out["country_reference_code"] = String(publish_error.c_str());
            } else {
                out["country_reference_ok"] = true;
                out["country_reference_hash"] = static_cast<int64_t>(snapshot.state_hash);
            }
        }
    }
    out.erase("_changed_cell_indices");
    out.erase("_changed_cell_owners");
    return out;
}

Dictionary DCWorldExt::sync_country_territory_to_map() {
    Dictionary out;
    out["ok"] = false;
    if (_country_runtime == nullptr) {
        out["reason"] = "country_runtime_unavailable";
        return out;
    }
    if (_map_data == nullptr) {
        out["reason"] = "map_data_unbound";
        return out;
    }
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    const int slot = component_id(StringName("cell_country_slot"));
    if (slot < 0) {
        out["reason"] = "country_slot_unavailable";
        return out;
    }
    const auto publish_start = std::chrono::steady_clock::now();
    const PackedInt32Array snapshot = runtime->cell_country_snapshot();
    write_i32_range(slot, 0, snapshot);
    _flush_slot_to_map(slot);
    const double publish_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - publish_start).count();
    ++_runtime_graph_flush_slot_count;
    _runtime_graph_visual_diff_cell_count +=
        static_cast<uint64_t>(snapshot.size());
    _runtime_graph_country_territory_sync_ms = publish_ms;
    runtime->mark_slot_publication(true, publish_ms);
    out["ok"] = true;
    out["cells"] = snapshot.size();
    out["slot_publish_ms"] = publish_ms;
    return out;
}

bool DCWorldExt::country_should_run(int64_t day_index) const {
    return _country_runtime != nullptr &&
        (country_runtime_from(_country_runtime)->should_run(day_index) ||
         country_ai_sync_due(day_index));
}

Dictionary DCWorldExt::get_country_report() const {
    // ACTIVE Country UI revision clocks must track the worker-committed
    // replica, not the frozen sync store.
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->report();
}

int64_t DCWorldExt::get_country_state_hash() const {
    return _country_runtime == nullptr ? 0 : country_runtime_from(_country_runtime)->state_hash();
}
