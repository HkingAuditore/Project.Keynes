Dictionary DCWorldExt::diagnose_colonization_target(
        int64_t country_handle, int target_cell) const {
    Dictionary out;
    out["ok"] = true;
    out["target_cell"] = target_cell;
    out["country_handle"] = country_handle;
    if (_economy_runtime == nullptr || _map_data == nullptr) {
        out["ok"] = false;
        out["code"] = "economy_not_available";
        return out;
    }
    const auto *economy = runtime_from(_economy_runtime);

    // Gate 1: the visibility plane the quotes path consumes.
    const Variant visible_variant = _map_data->get(StringName("visible_arr"));
    const bool visible_is_byte_array =
        visible_variant.get_type() == Variant::PACKED_BYTE_ARRAY;
    out["visible_is_byte_array"] = visible_is_byte_array;
    int32_t visible_size = 0;
    int32_t visible_nonzero = 0;
    bool target_visible = false;
    if (visible_is_byte_array) {
        const PackedByteArray visible = visible_variant;
        visible_size = visible.size();
        for (int32_t i = 0; i < visible.size(); ++i) {
            if (visible[i] != 0) {
                ++visible_nonzero;
                if (i == target_cell) target_visible = true;
            }
        }
    }
    out["visible_size"] = visible_size;
    out["visible_nonzero"] = visible_nonzero;
    out["target_visible"] = target_visible;
    out["cell_count_known"] = visible_size > 0;

    // Gate 2: ownership. `colonization_target_owner_allowed` accepts unowned or
    // already-mine (economy_runtime_colonization.cpp:283-289).
    if (_country_runtime != nullptr) {
        // `country_runtime_from()` is not visible in this translation unit.
        const auto *country = static_cast<const NativeCountryRuntime *>(_country_runtime);
        const int64_t owner = country->country_handle_for_cell(target_cell);
        out["owner_handle"] = owner;
        out["owner_allows"] = owner == 0 || owner == country_handle;
    } else {
        out["owner_handle"] = -1;
        out["owner_allows"] = false;
    }

    // Gates 3-5, the ones this bridge originally OMITTED -- and omitting them is
    // exactly how it reported "all clear" while `family_colonization_quotes` kept
    // returning `colonization_target_invalid`. `:496` rejects a cell with
    // `passable == 0` unless an epoch is active, and neither input was visible.
    out["topology_ready"] = economy_api::trade_topology_ready_for_test(*economy);
    out["target_passable"] = economy_api::trade_passable_for_test(*economy, target_cell);
    out["epoch_active"] = economy_api::epoch_active_for_test(*economy);
    // The single verdict a caller actually needs.
    out["would_accept_target"] =
        target_visible && bool(out["owner_allows"]) &&
        bool(out["topology_ready"]) &&
        (bool(out["target_passable"]) || bool(out["epoch_active"]));
    return out;
}

Dictionary DCWorldExt::get_family_colonization_quotes(
        int64_t country_handle, int target_cell, int64_t family_filter,
        int source_filter, int offset, int limit) {
    if (_runtime_host && _runtime_host->vision_executor_active()) {
        RuntimeEconomyBoundaryRequest request;
        request.country_handle = country_handle;
        request.family_handle = family_filter;
        request.source_cell = source_filter;
        request.target_cell = target_cell;
        request.offset = offset;
        request.limit = limit;
        return forward_economy_boundary_request(*_runtime_host, std::move(request));
    }
    if (_economy_runtime == nullptr || _map_data == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "economy_not_available";
        out["busy"] = false;
        out["committed"] = false;
        out["nonbinding"] = false;
        return out;
    }
    const Variant visible_variant = _map_data->get(StringName("visible_arr"));
    if (visible_variant.get_type() != Variant::PACKED_BYTE_ARRAY) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "colonization_visibility_unavailable";
        runtime_from(_economy_runtime)->fill_colonization_query_flags(out);
        return out;
    }
    const PackedByteArray visible = visible_variant;
    const uint64_t revision = static_cast<uint64_t>(static_cast<int64_t>(
        _map_data->get(StringName("vision_revision"))));
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    ReadKey key = read_key(ReadQuery::FAMILY_COLONIZATION_QUOTES,
        {country_handle, target_cell, family_filter, source_filter, offset, limit,
         static_cast<int64_t>(revision)});
    key.bytes = visible;
    return committed_read(_runtime_host.get(), runtime, key, [&] {
        return runtime->family_colonization_quotes(
            country_handle, target_cell, family_filter, source_filter, offset,
            limit, visible.ptr(), visible.size(), revision);
    });
}

Dictionary DCWorldExt::get_family_colonization_quote_detail(
        int64_t quote_token, int64_t population) const {
    if (_runtime_host && _runtime_host->vision_executor_active()) {
        RuntimeEconomyBoundaryRequest request;
        request.kind = RuntimeEconomyBoundaryRequest::Kind::QUOTE_DETAIL;
        request.quote_token = quote_token;
        request.population = population;
        return forward_economy_boundary_request(*_runtime_host, std::move(request));
    }
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_COLONIZATION_QUOTE_DETAIL, {quote_token, population}),
        [&] { return runtime->family_colonization_quote_detail(quote_token, population); });
}

Dictionary DCWorldExt::start_family_colonization(
        int64_t country_handle, int64_t family_handle, int source_cell,
        int target_cell, int64_t population, int64_t quote_token,
        int64_t effective_day, int64_t sequence) {
    if (_runtime_host && _runtime_host->vision_executor_active()) {
        RuntimeEconomyBoundaryRequest request;
        request.kind = RuntimeEconomyBoundaryRequest::Kind::START;
        request.country_handle = country_handle;
        request.family_handle = family_handle;
        request.source_cell = source_cell;
        request.target_cell = target_cell;
        request.population = population;
        request.quote_token = quote_token;
        request.effective_day = effective_day;
        request.sequence = sequence;
        return forward_economy_boundary_request(*_runtime_host, std::move(request));
    }
    if (_economy_runtime == nullptr || _map_data == nullptr) return unavailable();
    const Variant visible_variant = _map_data->get(StringName("visible_arr"));
    if (visible_variant.get_type() != Variant::PACKED_BYTE_ARRAY) {
        Dictionary out; out["ok"] = false;
        out["code"] = "colonization_visibility_unavailable"; return out;
    }
    const PackedByteArray visible = visible_variant;
    const uint64_t revision = static_cast<uint64_t>(static_cast<int64_t>(
        _map_data->get(StringName("vision_revision"))));
    // A running worker rarely yields the economy boundary to this thread, so
    // the command goes through the runtime's worker inbox instead of waiting.
    const bool worker_owned = _runtime_host != nullptr &&
        _runtime_host->economy_worker_owns_execution();
    return runtime_from(_economy_runtime)->submit_family_colonization_start(
        country_handle, family_handle, source_cell, target_cell, population,
        quote_token, effective_day, sequence, visible.ptr(), visible.size(),
        revision, worker_owned);
}

Dictionary DCWorldExt::cancel_family_colonization(
        int64_t country_handle, int64_t expedition_handle,
        int64_t effective_day, int64_t sequence) {
    if (_economy_runtime == nullptr) return unavailable();
    if (_runtime_host && _runtime_host->vision_executor_active()) {
        RuntimeEconomyBoundaryRequest request;
        request.kind = RuntimeEconomyBoundaryRequest::Kind::CANCEL;
        request.country_handle = country_handle;
        request.subject_id = expedition_handle;
        request.effective_day = effective_day;
        request.sequence = sequence;
        return forward_economy_boundary_request(*_runtime_host, std::move(request));
    }
    const bool worker_owned = _runtime_host != nullptr &&
        _runtime_host->economy_worker_owns_execution();
    auto admission = worker_owned ? _runtime_host->admit_command(effective_day)
                                  : RuntimeCommandAdmission();
    if (worker_owned && !admission.accepted()) return unavailable();
    return runtime_from(_economy_runtime)->submit_family_colonization_cancel(
        country_handle, expedition_handle, effective_day, sequence,
        worker_owned);
}

Dictionary DCWorldExt::get_family_expeditions(
        int64_t country_handle, int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FAMILY_EXPEDITIONS, {country_handle, offset, limit}),
        [&] { return runtime->family_expeditions(country_handle, offset, limit); });
}
