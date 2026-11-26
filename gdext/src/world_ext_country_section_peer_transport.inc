namespace {

int64_t country_peer_i64(const Dictionary &value, const char *key,
                         int64_t fallback = 0) {
    const StringName name(key);
    return value.has(name) ? static_cast<int64_t>(value[name]) : fallback;
}

uint32_t country_peer_u32(const Dictionary &value, const char *key,
                          uint32_t fallback = 0) {
    const int64_t parsed = country_peer_i64(value, key,
                                             static_cast<int64_t>(fallback));
    return parsed < 0 ? fallback : static_cast<uint32_t>(parsed);
}

uint64_t country_peer_u64(const Dictionary &value, const char *key,
                          uint64_t fallback = 0) {
    const int64_t parsed = country_peer_i64(value, key,
                                             static_cast<int64_t>(fallback));
    return parsed < 0 ? fallback : static_cast<uint64_t>(parsed);
}

int32_t country_peer_i32(const Dictionary &value, const char *key,
                         int32_t fallback = -1) {
    return static_cast<int32_t>(country_peer_i64(value, key, fallback));
}

String country_peer_string(const Dictionary &value, const char *key) {
    const StringName name(key);
    return value.has(name) ? String(value[name]) : String();
}

Dictionary country_peer_status_dictionary(
        const CountryPeerProtocolStatus &status) {
    Dictionary out;
    out["protocol_version"] = static_cast<int64_t>(status.protocol_version);
    out["async_mode"] = status.async_mode != 0;
    out["pending_intents"] = static_cast<int64_t>(status.pending_intents);
    out["queued_intents"] = static_cast<int64_t>(status.queued_intents);
    out["rejected_intents"] = static_cast<int64_t>(status.rejected_intents);
    out["has_unreported_rejection"] = status.has_unreported_rejection != 0;
    out["retry_day"] = status.retry_day;
    out["rejected_request_id"] = static_cast<int64_t>(status.rejected_request_id);
    out["rejected_opcode"] = static_cast<int64_t>(status.rejected_opcode);
    out["rejection_reason"] = String(status.rejection_reason.data());
    out["has_save_barrier"] = status.has_save_barrier();
    return out;
}

Dictionary country_peer_intent_dictionary(const CountryPeerIntent &intent) {
    Dictionary out;
    out["protocol_version"] = static_cast<int64_t>(intent.protocol_version);
    out["opcode"] = static_cast<int64_t>(intent.opcode);
    out["request_id"] = static_cast<int64_t>(intent.request_id);
    out["session_epoch"] = static_cast<int64_t>(intent.session_epoch);
    out["country_generation"] = static_cast<int64_t>(intent.country_generation);
    out["peer_generation"] = static_cast<int64_t>(intent.peer_generation);
    out["day"] = intent.day;
    out["continuation_index"] = static_cast<int64_t>(intent.continuation_index);
    out["country_slot"] = intent.country_slot;
    out["technology"] = intent.technology;
    out["target_handle"] = static_cast<int64_t>(intent.target_handle);
    out["effect_instance_id"] = static_cast<int64_t>(intent.effect_instance_id);
    out["effect_generation"] = static_cast<int64_t>(intent.effect_generation);
    out["idempotency_key"] = static_cast<int64_t>(intent.idempotency_key);
    return out;
}

const char *country_economy_asset_operation_name(
        RuntimeEconomyAssetOperation operation) {
    switch (operation) {
    case RuntimeEconomyAssetOperation::RESEARCH_PURCHASE: return "research_purchase";
    case RuntimeEconomyAssetOperation::FISCAL_RESERVE: return "fiscal_reserve";
    case RuntimeEconomyAssetOperation::FISCAL_RETURN: return "fiscal_return";
    case RuntimeEconomyAssetOperation::FISCAL_COLLECT: return "fiscal_collect";
    case RuntimeEconomyAssetOperation::CASH_TO_COHORT: return "cash_to_cohort";
    case RuntimeEconomyAssetOperation::CASH_FROM_COHORT: return "cash_from_cohort";
    case RuntimeEconomyAssetOperation::GOOD_TO_MARKET: return "good_to_market";
    case RuntimeEconomyAssetOperation::GOOD_FROM_MARKET: return "good_from_market";
    case RuntimeEconomyAssetOperation::TREASURY_SPEND: return "treasury_spend";
    default: return "unknown";
    }
}

const char *country_economy_asset_state_name(RuntimeEconomyAssetState state) {
    // External reports use the stage-5 D7 vocabulary; wire values stay as-is.
    return runtime_d7_reservation_state_name(
        runtime_d7_reservation_state_from_asset(state));
}

const char *country_economy_asset_state_name(
        RuntimeEconomyAssetState state,
        RuntimeEconomyAssetResultCode code,
        const char *reason) {
    return runtime_d7_reservation_state_name(
        runtime_d7_reservation_state_from_asset(state, code, reason));
}

const char *country_economy_asset_result_code_name(
        RuntimeEconomyAssetResultCode code) {
    switch (code) {
    case RuntimeEconomyAssetResultCode::ACCEPTED: return "accepted";
    case RuntimeEconomyAssetResultCode::PENDING: return "pending";
    case RuntimeEconomyAssetResultCode::PEER_PREPARED: return "peer_prepared";
    case RuntimeEconomyAssetResultCode::COMMIT_DECIDED: return "commit_decided";
    case RuntimeEconomyAssetResultCode::PEER_APPLIED: return "peer_applied";
    case RuntimeEconomyAssetResultCode::COMPLETED: return "completed";
    case RuntimeEconomyAssetResultCode::REJECTED: return "rejected";
    case RuntimeEconomyAssetResultCode::FAULTED: return "faulted";
    default: return "unknown";
    }
}

const char *country_economy_asset_protocol_error_name(
        RuntimeEconomyAssetProtocolError error) {
    switch (error) {
    case RuntimeEconomyAssetProtocolError::NONE: return "none";
    case RuntimeEconomyAssetProtocolError::PROTOCOL_MISMATCH:
        return "protocol_mismatch";
    case RuntimeEconomyAssetProtocolError::REQUEST_INVALID:
        return "request_invalid";
    case RuntimeEconomyAssetProtocolError::REQUEST_UNKNOWN:
        return "request_unknown";
    case RuntimeEconomyAssetProtocolError::REQUEST_DUPLICATE_MISMATCH:
        return "request_duplicate_mismatch";
    case RuntimeEconomyAssetProtocolError::RESULT_IDENTITY_MISMATCH:
        return "result_identity_mismatch";
    case RuntimeEconomyAssetProtocolError::RESULT_STATE_INVALID:
        return "result_state_invalid";
    case RuntimeEconomyAssetProtocolError::RESULT_DUPLICATE_MISMATCH:
        return "result_duplicate_mismatch";
    case RuntimeEconomyAssetProtocolError::SESSION_MISMATCH:
        return "session_mismatch";
    case RuntimeEconomyAssetProtocolError::GENERATION_MISMATCH:
        return "generation_mismatch";
    case RuntimeEconomyAssetProtocolError::CAPACITY_EXCEEDED:
        return "capacity_exceeded";
    default: return "unknown";
    }
}

Dictionary country_economy_asset_request_dictionary(
        const RuntimeEconomyAssetRequest &request) {
    Dictionary out;
    out["protocol_version"] = static_cast<int64_t>(request.protocol_version);
    out["operation"] = static_cast<int64_t>(request.operation);
    out["operation_name"] = country_economy_asset_operation_name(request.operation);
    out["state"] = static_cast<int64_t>(request.state);
    out["state_name"] = country_economy_asset_state_name(request.state);
    out["reservation_state"] = static_cast<int64_t>(
        runtime_d7_reservation_state_from_asset(request.state));
    out["reservation_state_name"] = String(country_economy_asset_state_name(
        request.state));
    out["all_or_nothing"] = request.all_or_nothing != 0;
    out["session_epoch"] = static_cast<int64_t>(request.session_epoch);
    out["transaction_id"] = static_cast<int64_t>(request.transaction_id);
    out["request_id"] = static_cast<int64_t>(request.request_id);
    out["origin_domain"] = static_cast<int64_t>(request.origin_domain);
    out["origin_epoch"] = request.origin_epoch;
    out["origin_stage"] = request.origin_stage;
    out["continuation_index"] = static_cast<int64_t>(request.continuation_index);
    out["day"] = request.day;
    out["operation_sequence"] = static_cast<int64_t>(request.operation_sequence);
    out["country_generation"] = static_cast<int64_t>(request.country_generation);
    out["peer_generation"] = static_cast<int64_t>(request.peer_generation);
    out["country_handle"] = static_cast<int64_t>(request.country_handle);
    out["country_slot"] = request.country_slot;
    out["target_slot"] = request.target_slot;
    out["target_handle"] = static_cast<int64_t>(request.target_handle);
    out["good_id"] = request.good_id;
    out["good_count"] = static_cast<int>(request.good_count);
    PackedInt32Array good_ids;
    PackedInt64Array good_quantities;
    good_ids.resize(static_cast<int64_t>(request.good_count));
    good_quantities.resize(static_cast<int64_t>(request.good_count));
    for (int64_t i = 0; i < good_ids.size(); ++i) {
        good_ids.set(i, request.good_ids[static_cast<size_t>(i)]);
        good_quantities.set(i, request.good_quantities[static_cast<size_t>(i)]);
    }
    out["good_ids"] = good_ids;
    out["good_quantities"] = good_quantities;
    out["requested_quantity"] = request.requested_quantity;
    out["prepared_quantity"] = request.prepared_quantity;
    out["requested_cash"] = request.requested_cash;
    out["reserved_cash"] = request.reserved_cash;
    out["requested_goods_total"] = request.requested_goods_total;
    out["reserved_goods_total"] = request.reserved_goods_total;
    return out;
}

Dictionary country_economy_asset_result_dictionary(
        const RuntimeEconomyAssetResult &result) {
    Dictionary out;
    out["protocol_version"] = static_cast<int64_t>(result.protocol_version);
    out["code"] = static_cast<int64_t>(result.code);
    out["result_code"] = country_economy_asset_result_code_name(result.code);
    out["state"] = static_cast<int64_t>(result.state);
    out["state_name"] = country_economy_asset_state_name(
        result.state, result.code, result.reason.data());
    out["reservation_state"] = static_cast<int64_t>(
        runtime_d7_reservation_state_from_asset(
            result.state, result.code, result.reason.data()));
    out["reservation_state_name"] = String(country_economy_asset_state_name(
        result.state, result.code, result.reason.data()));
    out["terminal_result"] = static_cast<int64_t>(
        runtime_d7_terminal_result_from_asset(
            result.code, result.state, result.reason.data()));
    out["terminal_result_name"] = String(runtime_d7_terminal_result_name(
        runtime_d7_terminal_result_from_asset(
            result.code, result.state, result.reason.data())));
    out["accepted"] = result.accepted != 0;
    out["session_epoch"] = static_cast<int64_t>(result.session_epoch);
    out["transaction_id"] = static_cast<int64_t>(result.transaction_id);
    out["request_id"] = static_cast<int64_t>(result.request_id);
    out["operation"] = static_cast<int64_t>(result.operation);
    out["operation_name"] = country_economy_asset_operation_name(result.operation);
    out["continuation_index"] = static_cast<int64_t>(result.continuation_index);
    out["day"] = result.day;
    out["country_generation"] = static_cast<int64_t>(result.country_generation);
    out["peer_generation"] = static_cast<int64_t>(result.peer_generation);
    out["committed_peer_generation"] = static_cast<int64_t>(
        result.committed_peer_generation);
    out["country_slot"] = result.country_slot;
    out["target_slot"] = result.target_slot;
    out["committed_quantity"] = result.committed_quantity;
    out["committed_cash"] = result.committed_cash;
    out["committed_goods_total"] = result.committed_goods_total;
    out["reason"] = String(result.reason.data());
    return out;
}

Dictionary country_economy_asset_protocol_status_dictionary(
        const RuntimeEconomyAssetProtocolStatus &status) {
    Dictionary out;
    out["protocol_version"] = static_cast<int64_t>(status.protocol_version);
    out["queued_requests"] = static_cast<int64_t>(status.queued_requests);
    out["pending_requests"] = static_cast<int64_t>(status.pending_requests);
    out["terminal_requests"] = static_cast<int64_t>(status.terminal_requests);
    out["rejected_results"] = static_cast<int64_t>(status.rejected_results);
    out["faulted_transactions"] = static_cast<int64_t>(
        status.faulted_transactions);
    out["recovered_transactions"] = static_cast<int64_t>(
        status.recovered_transactions);
    out["duplicate_messages"] = static_cast<int64_t>(
        status.duplicate_messages);
    out["session_epoch"] = static_cast<int64_t>(status.session_epoch);
    out["last_transaction_id"] = static_cast<int64_t>(status.last_transaction_id);
    out["last_request_id"] = static_cast<int64_t>(status.last_request_id);
    out["last_error"] = static_cast<int64_t>(status.last_error);
    out["last_error_name"] = country_economy_asset_protocol_error_name(
        status.last_error);
    out["last_reason"] = String(status.last_reason.data());
    out["has_save_barrier"] = status.pending_requests != 0 ||
        status.queued_requests != 0;
    return out;
}

} // namespace

Dictionary DCWorldExt::set_country_peer_async_mode(bool enabled) {
    if (_country_runtime == nullptr) return country_unavailable();
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    runtime->set_peer_async_mode(enabled);
    Dictionary out = country_peer_status_dictionary(
        runtime->peer_protocol_status());
    out["ok"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::get_country_peer_protocol_status() const {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_peer_status_dictionary(
        country_runtime_from(_country_runtime)->peer_protocol_status());
}

Dictionary DCWorldExt::poll_country_peer_intent() {
    if (_country_runtime == nullptr) return country_unavailable();
    CountryPeerIntent intent;
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    if (!runtime->poll_peer_intent(intent)) {
        Dictionary out = country_peer_status_dictionary(
            runtime->peer_protocol_status());
        out["ok"] = true;
        out["available"] = false;
        out["code"] = "country_peer_intent_empty";
        return out;
    }
    Dictionary out = country_peer_intent_dictionary(intent);
    out["ok"] = true;
    out["available"] = true;
    out["code"] = "ok";
    return out;
}

Dictionary DCWorldExt::submit_country_peer_result(const Dictionary &input) {
    if (_country_runtime == nullptr) return country_unavailable();
    CountryPeerResult result;
    result.protocol_version = country_peer_u32(input, "protocol_version",
                                                COUNTRY_PEER_PROTOCOL_VERSION);
    result.code = static_cast<CountryPeerResultCode>(
        country_peer_u32(input, "code"));
    result.opcode = static_cast<CountryPeerIntentCode>(
        country_peer_u32(input, "opcode"));
    result.request_id = country_peer_u64(input, "request_id");
    result.session_epoch = country_peer_u64(input, "session_epoch");
    result.country_generation = country_peer_u64(input, "country_generation");
    result.committed_peer_generation = country_peer_u64(
        input, "committed_peer_generation");
    result.peer_generation = country_peer_u64(input, "peer_generation");
    result.day = country_peer_i64(input, "day", -1);
    result.continuation_index = country_peer_u32(input, "continuation_index");
    result.country_slot = country_peer_i32(input, "country_slot");
    result.technology = country_peer_i32(input, "technology");
    result.target_handle = country_peer_u64(input, "target_handle");
    result.technology_flags = static_cast<uint8_t>(country_peer_u32(
        input, "technology_flags"));
    const std::string reason = country_peer_string(input, "reason")
        .utf8().get_data();
    country_peer_copy_reason(result.reason, reason.c_str());

    std::string error;
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    if (!runtime->submit_peer_result(result, error)) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = error.empty() ? "country_peer_result_rejected" : error.c_str();
        return out;
    }
    Dictionary out = country_peer_status_dictionary(
        runtime->peer_protocol_status());
    out["ok"] = true;
    out["code"] = "ok";
    out["request_id"] = static_cast<int64_t>(result.request_id);
    return out;
}

Dictionary DCWorldExt::service_country_peer_adapter(int max_intents) {
    if (_country_runtime == nullptr) return country_unavailable();
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    NativeCountryRuntime::PeerAdapterServiceReport report;
    std::string error;
    if (!runtime->service_peer_intents_main_thread(max_intents, report, error)) {
        Dictionary out = country_peer_status_dictionary(
            runtime->peer_protocol_status());
        out["ok"] = false;
        out["code"] = error.empty()
            ? "country_peer_adapter_service_failed" : error.c_str();
        return out;
    }
    Dictionary out = country_peer_status_dictionary(
        runtime->peer_protocol_status());
    out["ok"] = true;
    out["code"] = "ok";
    out["inspected"] = static_cast<int64_t>(report.inspected);
    out["completed"] = static_cast<int64_t>(report.completed);
    out["pending"] = static_cast<int64_t>(report.pending);
    out["rejected"] = static_cast<int64_t>(report.rejected);
    out["effect_intents"] = static_cast<int64_t>(report.effect_intents);
    out["modifier_intents"] = static_cast<int64_t>(report.modifier_intents);
    out["economy_intents"] = static_cast<int64_t>(report.economy_intents);
    out["last_request_id"] = static_cast<int64_t>(report.last_request_id);
    out["last_reason"] = String(report.last_reason.c_str());
    return out;
}

Dictionary DCWorldExt::begin_country_economy_treasury_spend(
        int64_t country_handle, const PackedInt32Array &good_ids,
        const PackedInt64Array &quantities, int64_t cash,
        int64_t origin_epoch, int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_treasury_spend(
        country_handle, good_ids, quantities, cash, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_fiscal_reserve(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_fiscal_reserve(
        country_handle, requested, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_fiscal_return(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_fiscal_return(
        country_handle, offered, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_fiscal_collect(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_fiscal_collect(
        country_handle, offered, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_cash_to_cohort(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_cash_to_cohort(
        country_handle, requested, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_cash_from_cohort(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_cash_from_cohort(
        country_handle, offered, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_good_to_market(
        int64_t country_handle, int good_id, int64_t requested,
        int64_t origin_epoch, int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_good_to_market(
        country_handle, good_id, requested, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_good_from_market(
        int64_t country_handle, int good_id, int64_t offered,
        int64_t origin_epoch, int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_good_from_market(
        country_handle, good_id, offered, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::begin_country_economy_research_purchase(
        int64_t country_handle, int64_t quantity, int64_t total_cost,
        int64_t origin_epoch, int origin_stage, int64_t request_id) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_economy_research_purchase(
        country_handle, quantity, total_cost, origin_epoch, origin_stage,
        request_id <= 0 ? 0u : static_cast<uint64_t>(request_id));
}

Dictionary DCWorldExt::ack_country_economy_asset_peer_prepared(
        int64_t transaction_id, int64_t session_epoch,
        int64_t country_generation, int64_t peer_generation, bool accepted,
        const String &reason) {
    if (_country_runtime == nullptr) return country_unavailable();
    if (transaction_id <= 0 || session_epoch <= 0 || country_generation <= 0 ||
        peer_generation <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->
        acknowledge_economy_asset_peer_prepared(
            static_cast<uint64_t>(transaction_id),
            static_cast<uint64_t>(session_epoch),
            static_cast<uint64_t>(country_generation),
            static_cast<uint64_t>(peer_generation), accepted, reason);
}

Dictionary DCWorldExt::commit_country_economy_treasury_spend(
        int64_t transaction_id) {
    if (_country_runtime == nullptr || transaction_id <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->
        commit_economy_treasury_spend(static_cast<uint64_t>(transaction_id));
}

Dictionary DCWorldExt::commit_country_economy_fiscal_reserve(
        int64_t transaction_id) {
    if (_country_runtime == nullptr || transaction_id <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->commit_economy_asset_transaction(
        static_cast<uint64_t>(transaction_id));
}

Dictionary DCWorldExt::commit_country_economy_asset_transaction(
        int64_t transaction_id) {
    if (_country_runtime == nullptr || transaction_id <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->commit_economy_asset_transaction(
        static_cast<uint64_t>(transaction_id));
}

Dictionary DCWorldExt::ack_country_economy_asset_peer_applied(
        int64_t transaction_id, int64_t session_epoch,
        int64_t country_generation, int64_t peer_generation, bool accepted,
        const String &reason) {
    if (_country_runtime == nullptr) return country_unavailable();
    if (transaction_id <= 0 || session_epoch <= 0 || country_generation <= 0 ||
        peer_generation <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->
        acknowledge_economy_asset_peer_applied(
            static_cast<uint64_t>(transaction_id),
            static_cast<uint64_t>(session_epoch),
            static_cast<uint64_t>(country_generation),
            static_cast<uint64_t>(peer_generation), accepted, reason);
}

Dictionary DCWorldExt::get_country_economy_asset_transaction(
        int64_t transaction_id) const {
    if (_country_runtime == nullptr || transaction_id <= 0)
        return country_unavailable();
    return country_runtime_from(_country_runtime)->
        economy_asset_transaction_snapshot(static_cast<uint64_t>(transaction_id));
}
