Dictionary DCWorldExt::get_country_fiscal_snapshot(int64_t handle) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::FISCAL_SNAPSHOT, {handle}),
        [&] { return runtime->fiscal_snapshot(handle); });
}

Dictionary DCWorldExt::get_country_trade_snapshot(
        int64_t handle, const String &view, int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    ReadKey key = read_key(ReadQuery::COUNTRY_TRADE_SNAPSHOT, {handle, offset, limit});
    key.text = view;
    return committed_read(_runtime_host.get(), runtime, key,
        [&] { return runtime->country_trade_snapshot(handle, view, offset, limit); });
}

Dictionary DCWorldExt::get_country_economy_overview(
        int64_t handle, const String &view, int scope_cell, int filter_id,
        int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    ReadKey key = read_key(ReadQuery::COUNTRY_ECONOMY_OVERVIEW,
        {handle, scope_cell, filter_id, offset, limit});
    key.text = view;
    return committed_read(_runtime_host.get(), runtime, key, [&] {
        return runtime->country_economy_overview(
            handle, view, scope_cell, filter_id, offset, limit);
    });
}

Dictionary DCWorldExt::get_trade_orders_for_cell(
        int cell_idx, int offset, int limit, int good_index) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::TRADE_ORDERS_FOR_CELL,
                 {cell_idx, offset, limit, good_index}),
        [&] { return runtime->trade_orders_for_cell(
            cell_idx, offset, limit, good_index); });
}

Dictionary DCWorldExt::get_trade_visual_snapshot(
        const PackedInt32Array &cells, const PackedByteArray &visible,
        int64_t vision_revision, int selected_cell, bool enabled) const {
    if (_economy_runtime == nullptr) return unavailable();
    auto *runtime = runtime_from(_economy_runtime);
    runtime->trade_visual_cache.request(cells, visible, vision_revision, selected_cell, enabled);
    if (enabled) {
        if (_runtime_host == nullptr || !_runtime_host->economy_worker_owns_execution())
            runtime->trade_visual_cache.step(*runtime);
        else
            _runtime_host->request_economy_read_view();
    }
    Dictionary out = runtime->trade_visual_cache.snapshot();
    if (!static_cast<bool>(out.get("ok", false))) return out;
    const PackedInt32Array slots = out["country_slots"];
    PackedInt32Array eras;
    eras.resize(slots.size());
    // Same immutable Country query view as the building visual bridge.
    NativeCountryRuntime *countries = _country_runtime == nullptr ? nullptr : country_query_runtime();
    for (int64_t i = 0; i < slots.size(); ++i)
        eras.set(i, countries ? std::max(0, countries->visual_era_index_for_slot(slots[i])) : 0);
    out["era_indices"] = eras;
    return out;
}
