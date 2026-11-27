Dictionary DCWorldExt::get_country_class_opinion_snapshot() const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::COUNTRY_CLASS_OPINION_SNAPSHOT, {}),
        [&] { return runtime->country_class_opinion_snapshot_debug(); });
}

Dictionary DCWorldExt::get_population_cell_snapshot(
        int cell_idx, bool include_details) const {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return committed_read(_runtime_host.get(), runtime_from(_economy_runtime),
        read_key(ReadQuery::POPULATION_CELL_SNAPSHOT, {cell_idx, include_details ? 1 : 0}),
        [&] { return population_cell_snapshot_live(cell_idx, include_details); });
}

Dictionary DCWorldExt::population_cell_snapshot_live(
        int cell_idx, bool include_details) const {
    if (!include_details) {
        return runtime_from(_economy_runtime)->population_cell_snapshot(
            cell_idx, false);
    }
    const char *slot_names[4] = {
        "cell_temp", "cell_moisture", "cell_snow_cover", "cell_weather_intensity"
    };
    float values[4] = {0.5f, 0.5f, 0.0f, 0.0f};
    bool environment_ready = cell_idx >= 0;
    for (int32_t i = 0; i < 4; ++i) {
        const int sid = component_id(StringName(slot_names[i]));
        if (sid < 0 || sid >= _slots.size() || _slots[sid].dtype != SlotDType::F32 ||
            cell_idx >= _slots[sid].arr_f32.size()) {
            environment_ready = false;
            break;
        }
        values[i] = _slots[sid].arr_f32[cell_idx];
    }
    return runtime_from(_economy_runtime)->population_cell_snapshot(
        cell_idx, values[0], values[1], values[2], values[3], environment_ready);
}

Dictionary DCWorldExt::get_population_cell_summary(int cell_idx) const {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::POPULATION_CELL_SUMMARY, {cell_idx}),
        [&] { return runtime->population_cell_summary(cell_idx); });
}

Dictionary DCWorldExt::get_named_settlement_snapshot() const {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::NAMED_SETTLEMENT_SNAPSHOT, {}),
        [&] { return runtime->named_settlement_snapshot(); });
}

Dictionary DCWorldExt::get_settlement_delta(int64_t since_revision) const {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::SETTLEMENT_DELTA, {since_revision}),
        [&] { return runtime->settlement_delta(since_revision); });
}

Dictionary DCWorldExt::get_market_cell_snapshot(int cell_idx) const {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::MARKET_CELL_SNAPSHOT, {cell_idx}),
        [&] { return runtime->market_cell_snapshot(cell_idx); });
}

Dictionary DCWorldExt::get_cell_situation_snapshot(
        const PackedInt32Array &requested_cells) const {
    if (requested_cells.size() > 128) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "situation_cell_limit_exceeded";
        return out;
    }
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    ReadKey key = read_key(ReadQuery::SITUATION_VISUAL_SNAPSHOT, {});
    key.ints = requested_cells;
    return committed_read(_runtime_host.get(), runtime, key, [&] {
        return runtime->cell_situation_snapshot(requested_cells);
    });
}

Dictionary DCWorldExt::explain_cohort_satisfaction(int64_t cohort_handle) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::EXPLAIN_COHORT_SATISFACTION, {cohort_handle}),
        [&] { return runtime->explain_cohort_satisfaction(cohort_handle); });
}

Dictionary DCWorldExt::get_cell_satisfaction_attractiveness(int cell_idx) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    return committed_read(_runtime_host.get(), runtime,
        read_key(ReadQuery::CELL_SATISFACTION_ATTRACTIVENESS, {cell_idx}),
        [&] { return runtime->cell_satisfaction_attractiveness(cell_idx); });
}
