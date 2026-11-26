Dictionary DCWorldExt::get_building_cell_snapshot(int cell_idx) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    Dictionary out = committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::BUILDING_CELL_SNAPSHOT, {cell_idx}),
        [&] { return runtime->building_cell_snapshot(cell_idx); });
    if (!static_cast<bool>(out.get("ok", false))) return out;
    PackedInt64Array reserves;
    PackedInt64Array pending_changes;
    PackedInt64Array effective;
    PackedInt64Array accessible_reserves;
    PackedInt64Array accessible_pending_changes;
    PackedInt64Array accessible_effective;
    const size_t count = runtime->building_resource_reserve_slots().size();
    reserves.resize(static_cast<int64_t>(count));
    pending_changes.resize(static_cast<int64_t>(count));
    effective.resize(static_cast<int64_t>(count));
    accessible_reserves.resize(static_cast<int64_t>(count));
    accessible_pending_changes.resize(static_cast<int64_t>(count));
    accessible_effective.resize(static_cast<int64_t>(count));
    auto fixed_value = [](double value) -> int64_t {
        if (!std::isfinite(value)) return 0;
        const double scaled = static_cast<double>(value) *
                              static_cast<double>(NativeEconomyRuntime::GOODS_SCALE);
        return static_cast<int64_t>(std::clamp<double>(
            scaled, static_cast<double>(std::numeric_limits<int64_t>::min()),
            static_cast<double>(std::numeric_limits<int64_t>::max())));
    };
    for (size_t r = 0; r < count; ++r) {
        const int reserve_sid = component_id(StringName(
            runtime->building_resource_reserve_slots()[r].c_str()));
        const int extra_sid = component_id(StringName(
            runtime->building_resource_extra_slots()[r].c_str()));
        const float reserve = reserve_sid >= 0 && reserve_sid < _slots.size() &&
                _slots[reserve_sid].dtype == SlotDType::F32 && cell_idx >= 0 &&
                cell_idx < _slots[reserve_sid].arr_f32.size()
            ? _slots[reserve_sid].arr_f32[cell_idx] : 0.0f;
        const float pending = extra_sid >= 0 && extra_sid < _slots.size() &&
                _slots[extra_sid].dtype == SlotDType::F32 && cell_idx >= 0 &&
                cell_idx < _slots[extra_sid].arr_f32.size()
            ? _slots[extra_sid].arr_f32[cell_idx] : 0.0f;
        reserves.set(static_cast<int64_t>(r), fixed_value(reserve));
        pending_changes.set(static_cast<int64_t>(r), fixed_value(pending));
        effective.set(static_cast<int64_t>(r), fixed_value(
            std::max(0.0f, reserve + std::min(0.0f, pending))));
        int32_t source_cells[7];
        const int32_t source_count = runtime->building_resource_access_cells(
            cell_idx, static_cast<int32_t>(r), source_cells, 7);
        double accessible_reserve = 0.0;
        double accessible_pending = 0.0;
        double accessible_value = 0.0;
        for (int32_t i = 0; i < source_count; ++i) {
            const int32_t source = source_cells[i];
            const float source_reserve = reserve_sid >= 0 && reserve_sid < _slots.size() &&
                    _slots[reserve_sid].dtype == SlotDType::F32 && source >= 0 &&
                    source < _slots[reserve_sid].arr_f32.size()
                ? _slots[reserve_sid].arr_f32[source] : 0.0f;
            const float source_pending = extra_sid >= 0 && extra_sid < _slots.size() &&
                    _slots[extra_sid].dtype == SlotDType::F32 && source >= 0 &&
                    source < _slots[extra_sid].arr_f32.size()
                ? _slots[extra_sid].arr_f32[source] : 0.0f;
            accessible_reserve += std::isfinite(source_reserve) ? source_reserve : 0.0;
            accessible_pending += std::isfinite(source_pending) ? source_pending : 0.0;
            accessible_value += std::max(0.0f, source_reserve + std::min(0.0f, source_pending));
        }
        accessible_reserves.set(static_cast<int64_t>(r), fixed_value(accessible_reserve));
        accessible_pending_changes.set(static_cast<int64_t>(r), fixed_value(accessible_pending));
        accessible_effective.set(static_cast<int64_t>(r), fixed_value(accessible_value));
    }
    out["building_resource_current_reserve"] = reserves;
    out["building_resource_pending_change"] = pending_changes;
    out["building_resource_effective_reserve"] = effective;
    out["building_resource_accessible_current_reserve"] = accessible_reserves;
    out["building_resource_accessible_pending_change"] = accessible_pending_changes;
    out["building_resource_accessible_effective_reserve"] = accessible_effective;
    return out;
}

Dictionary DCWorldExt::get_building_visual_snapshot(
        const PackedInt32Array &requested_cells) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    const NativeSimulationHost *host = _runtime_host.get();
    Dictionary out;
    if (host != nullptr && host->economy_worker_owns_execution()) {
        PackedInt32Array cells = requested_cells;
        cells.append_array(_building_visual_pending_cells);
        const auto view = runtime->building_visual_view();
        if (view == nullptr) {
            _runtime_host->request_economy_read_view();
            // Newly visible cells are consumed by the caller; keep them for the
            // first call that has a committed view.
            _building_visual_pending_cells = cells;
            return read_view_pending();
        }
        _building_visual_pending_cells.clear();
        out = NativeEconomyRuntime::building_visual_rows(*view, cells);
    } else {
        out = runtime->building_visual_snapshot(requested_cells);
    }
    if (!static_cast<bool>(out.get("ok", false))) return out;
    PackedInt32Array cells = out["cell_indices"];
    PackedInt32Array country_slots;
    PackedInt32Array era_indices;
    country_slots.resize(cells.size());
    era_indices.resize(cells.size());
    uint64_t era_generation = 0;
    // Worker mode freezes the sync Country store; use the committed query view.
    NativeCountryRuntime *countries = _country_runtime == nullptr
        ? nullptr : country_query_runtime();
    if (countries != nullptr) era_generation = countries->visual_era_generation();
    for (int64_t i = 0; i < cells.size(); ++i) {
        const int32_t slot = countries == nullptr
            ? -1 : countries->country_slot_for_cell(cells[i]);
        country_slots.set(i, slot);
        era_indices.set(i, countries == nullptr
            ? -1 : countries->visual_era_index_for_slot(slot));
    }
    out["country_slots"] = country_slots;
    out["era_indices"] = era_indices;
    out["country_era_generation"] = static_cast<int64_t>(era_generation);
    return out;
}

Dictionary DCWorldExt::consume_building_visual_dirty_cells() {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    const NativeSimulationHost *host = _runtime_host.get();
    if (host == nullptr || !host->economy_worker_owns_execution())
        return runtime->consume_building_visual_dirty_cells();
    const auto view = runtime->building_visual_view();
    Dictionary out;
    out["ok"] = true;
    out["building_generation"] = view != nullptr
        ? static_cast<int64_t>(view->generation) : int64_t{0};
    out["dirty_cells"] = runtime->drain_building_visual_outbox();
    return out;
}

Dictionary DCWorldExt::get_treasury_construction_quotes(
        int64_t country_handle, int cell_idx,
        const PackedInt32Array &type_ids) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    ReadKey key = read_key(ReadQuery::TREASURY_CONSTRUCTION_QUOTES,
                           {country_handle, cell_idx});
    key.ints = type_ids;
    return committed_read(_runtime_host.get(), runtime, key, [&] {
        return runtime->treasury_construction_quotes(country_handle, cell_idx, type_ids);
    });
}

Dictionary DCWorldExt::get_construction_command_receipts(
        int64_t after_receipt_id, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::CONSTRUCTION_COMMAND_RECEIPTS, {after_receipt_id, limit}),
        [&] { return runtime->construction_command_receipts(after_receipt_id, limit); });
}


Dictionary DCWorldExt::queue_treasury_sponsored_build(
        int64_t country_handle, int cell_idx, int type_id,
        int64_t effective_day, int64_t sequence) {
    if (_economy_runtime == nullptr) return unavailable();
    const bool worker_owned = _runtime_host != nullptr &&
        _runtime_host->economy_worker_owns_execution();
    auto admission = worker_owned ? _runtime_host->admit_command(effective_day)
                                  : RuntimeCommandAdmission();
    if (worker_owned && !admission.accepted()) return unavailable();
    return economy_api::queue_treasury_sponsored_build(*runtime_from(_economy_runtime),
        country_handle, cell_idx, type_id, effective_day, sequence,
        worker_owned);
}

Dictionary DCWorldExt::queue_treasury_sponsored_demolish(
        int64_t country_handle, int cell_idx, int type_id, int64_t count,
        int64_t effective_day, int64_t sequence) {
    if (_economy_runtime == nullptr) return unavailable();
    const bool worker_owned = _runtime_host != nullptr &&
        _runtime_host->economy_worker_owns_execution();
    auto admission = worker_owned ? _runtime_host->admit_command(effective_day)
                                  : RuntimeCommandAdmission();
    if (worker_owned && !admission.accepted()) return unavailable();
    return economy_api::queue_treasury_sponsored_demolish(*runtime_from(_economy_runtime),
        country_handle, cell_idx, type_id, count, effective_day, sequence,
        worker_owned);
}
