
Dictionary DCWorldExt::get_country_economy_asset_protocol_status() const {
    if (_runtime_host == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    Dictionary out = country_economy_asset_protocol_status_dictionary(
        _runtime_host->country_economy_asset_protocol_status());
    out["ok"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::poll_country_economy_asset_request() {
    if (_runtime_host == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    RuntimeEconomyAssetRequest request;
    if (!_runtime_host->poll_country_economy_asset_request(request)) {
        Dictionary out = country_economy_asset_protocol_status_dictionary(
            _runtime_host->country_economy_asset_protocol_status());
        out["ok"] = true;
        out["available"] = false;
        out["code"] = "country_economy_asset_request_empty";
        return out;
    }
    Dictionary out = country_economy_asset_request_dictionary(request);
    out["ok"] = true;
    out["available"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::submit_country_economy_asset_result(
        const Dictionary &input) {
    if (_runtime_host == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    RuntimeEconomyAssetResult result;
    result.protocol_version = country_peer_u32(
        input, "protocol_version", RUNTIME_ECONOMY_ASSET_PROTOCOL_VERSION);
    result.code = static_cast<RuntimeEconomyAssetResultCode>(
        country_peer_u32(input, "code"));
    result.state = static_cast<RuntimeEconomyAssetState>(
        country_peer_u32(input, "state"));
    result.accepted = static_cast<uint8_t>(country_peer_u32(
        input, "accepted"));
    result.session_epoch = country_peer_u64(input, "session_epoch");
    result.transaction_id = country_peer_u64(input, "transaction_id");
    result.request_id = country_peer_u64(input, "request_id");
    result.operation = static_cast<RuntimeEconomyAssetOperation>(
        country_peer_u32(input, "operation"));
    result.continuation_index = country_peer_u32(input, "continuation_index");
    result.day = country_peer_i64(input, "day", -1);
    result.country_generation = country_peer_u64(input, "country_generation");
    result.peer_generation = country_peer_u64(input, "peer_generation");
    result.committed_peer_generation = country_peer_u64(
        input, "committed_peer_generation");
    result.country_slot = country_peer_i32(input, "country_slot");
    result.target_slot = country_peer_i32(input, "target_slot");
    result.committed_quantity = country_peer_i64(
        input, "committed_quantity");
    result.committed_cash = country_peer_i64(input, "committed_cash");
    result.committed_goods_total = country_peer_i64(
        input, "committed_goods_total");
    const std::string reason = country_peer_string(input, "reason")
        .utf8().get_data();
    country_peer_copy_reason(result.reason, reason.c_str());

    std::string error;
    if (!_runtime_host->submit_country_economy_asset_result(result, error)) {
        Dictionary out = country_economy_asset_protocol_status_dictionary(
            _runtime_host->country_economy_asset_protocol_status());
        out["ok"] = false;
        out["code"] = error.empty()
            ? "country_economy_asset_result_rejected" : error.c_str();
        out["request_id"] = static_cast<int64_t>(result.request_id);
        out["transaction_id"] = static_cast<int64_t>(result.transaction_id);
        return out;
    }
    Dictionary out = country_economy_asset_result_dictionary(result);
    out["ok"] = true;
    out["code"] = "ok";
    return out;
}

bool DCWorldExt::runtime_country_host_economy_protocol_self_test() const {
    if (_runtime_host == nullptr) return false;
    std::string error;
    return _runtime_host->country_economy_asset_protocol_self_test(error);
}

bool DCWorldExt::runtime_country_host_handoff_self_test() const {
    if (_runtime_host == nullptr) return false;
    std::string error;
    const bool ok = _runtime_host->country_authority_handoff_self_test(error);
    if (!ok) {
        UtilityFunctions::printerr(
            String("[country handoff self-test] ") + String(error.c_str()));
    }
    return ok;
}

Dictionary DCWorldExt::prepare_country_authority_handoff(int target_owner) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (_country_runtime != nullptr) {
        const Dictionary ledger =
            country_runtime_from(_country_runtime)->economy_asset_transaction_report();
        if (int64_t(ledger.get("in_flight", 0)) > 0) {
            out["ok"] = false;
            out["code"] = "country_authority_handoff_busy";
            out["in_flight"] = ledger.get("in_flight", 0);
            return out;
        }
    }
    std::string error;
    const auto target = target_owner == 1
        ? NativeSimulationHost::CountryAuthorityOwner::WORKER
        : NativeSimulationHost::CountryAuthorityOwner::SYNC;
    const bool ok = _runtime_host->prepare_country_authority_handoff(target, error);
    out["ok"] = ok;
    out["code"] = ok ? "ok" : (error.empty() ? "country_authority_handoff_failed" : error.c_str());
    return out;
}

Dictionary DCWorldExt::install_country_authority_handoff() {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const auto before = _runtime_host->country_authority_handoff_status();
    if (!before.prepare_pending) {
        out["ok"] = false;
        out["code"] = "country_authority_handoff_not_prepared";
        return out;
    }
    // SYNC→WORKER: publish the live sync store as the handoff checkpoint before
    // flipping unique-writer ownership. Missing capture fails closed in Host.
    if (before.prepared_target ==
            NativeSimulationHost::CountryAuthorityOwner::WORKER &&
        _country_runtime != nullptr) {
        const Dictionary captured = capture_country_runtime_snapshot();
        if (!bool(captured.get("ok", false))) {
            out["ok"] = false;
            out["code"] = String(captured.get("code",
                "country_authority_handoff_checkpoint_missing"));
            std::string abort_error;
            _runtime_host->abort_country_authority_handoff(abort_error);
            return out;
        }
        out["checkpoint_generation"] = captured.get("generation", 0);
        out["checkpoint_state_hash"] = captured.get("state_hash", 0);
    }
    std::string error;
    const bool ok = _runtime_host->install_country_authority_handoff(error);
    if (!ok) {
        out["ok"] = false;
        out["code"] = error.empty() ? "country_authority_handoff_failed" : error.c_str();
        return out;
    }
    const auto after = _runtime_host->country_authority_handoff_status();
    if (_country_runtime != nullptr) {
        country_runtime_from(_country_runtime)->set_sync_store_writes_forbidden(
            after.owner == NativeSimulationHost::CountryAuthorityOwner::WORKER);
    }
    // The handoff can happen after Economy was attached. Re-run the ownership
    // mirror so Country ACTIVE + Economy sync opens the market purchase legs
    // immediately instead of leaving D7 at the research-only mask.
    sync_runtime_domain_ownership();
    out["ok"] = true;
    out["code"] = "ok";
    out["owner"] = static_cast<int>(after.owner);
    out["session_epoch"] = static_cast<int64_t>(after.session_epoch);
    out["implemented_domain_mask"] = static_cast<int64_t>(
        _runtime_host->implemented_domain_mask());
    return out;
}

Dictionary DCWorldExt::abort_country_authority_handoff() {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    std::string error;
    const bool ok = _runtime_host->abort_country_authority_handoff(error);
    const auto status = _runtime_host->country_authority_handoff_status();
    out["ok"] = ok;
    out["code"] = ok ? "ok" : (error.empty() ? "country_authority_handoff_failed" : error.c_str());
    out["owner"] = static_cast<int>(status.owner);
    out["prepare_pending"] = status.prepare_pending;
    out["reason"] = String(status.last_reason);
    return out;
}

Dictionary DCWorldExt::get_country_authority_handoff_status() const {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const auto status = _runtime_host->country_authority_handoff_status();
    out["ok"] = true;
    out["owner"] = static_cast<int>(status.owner);
    out["prepared_target"] = static_cast<int>(status.prepared_target);
    out["prepare_pending"] = status.prepare_pending;
    out["session_epoch"] = static_cast<int64_t>(status.session_epoch);
    out["reason"] = String(status.last_reason);
    return out;
}
