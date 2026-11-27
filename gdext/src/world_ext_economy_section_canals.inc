Dictionary DCWorldExt::get_canal_route_quote(
        int64_t country_handle, int start_cell, int end_cell,
        const PackedInt32Array &waypoints) {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    ReadKey key = read_key(ReadQuery::CANAL_ROUTE_QUOTE,
                           {country_handle, start_cell, end_cell});
    key.ints = waypoints;
    return committed_read(_runtime_host.get(), runtime, key, [&] {
        return runtime->canal_route_quote(country_handle, start_cell, end_cell, waypoints);
    });
}

Dictionary DCWorldExt::get_canal_route_quote_detail(
        int64_t country_handle, int64_t quote_token) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::CANAL_ROUTE_QUOTE_DETAIL, {country_handle, quote_token}),
        [&] { return runtime->canal_route_quote_detail(country_handle, quote_token); });
}

Dictionary DCWorldExt::queue_canal_construction(
        int64_t country_handle, int64_t quote_token,
        int64_t effective_day, int64_t sequence) {
    if (_economy_runtime == nullptr) return unavailable();
    if (_runtime_host && _runtime_host->vision_executor_active()) {
        RuntimeEconomyBoundaryRequest request;
        request.kind = RuntimeEconomyBoundaryRequest::Kind::BUILD_CANAL;
        request.country_handle = country_handle;
        request.quote_token = quote_token;
        request.effective_day = effective_day;
        request.sequence = sequence;
        return forward_economy_boundary_request(*_runtime_host, std::move(request));
    }
    auto admission = _runtime_host ? _runtime_host->admit_command(effective_day)
                                    : RuntimeCommandAdmission();
    if (_runtime_host && !admission.accepted()) return unavailable();
    return runtime_from(_economy_runtime)->queue_canal_construction(
        country_handle, quote_token, effective_day, sequence);
}

Dictionary DCWorldExt::get_canal_construction_receipts(
        int64_t country_handle, int64_t after_receipt_id, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::CANAL_CONSTRUCTION_RECEIPTS,
                 {country_handle, after_receipt_id, limit}),
        [&] {
            return runtime->canal_construction_receipts(
                country_handle, after_receipt_id, limit);
        });
}
