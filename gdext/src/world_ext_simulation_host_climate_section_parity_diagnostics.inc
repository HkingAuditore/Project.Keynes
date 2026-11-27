Dictionary DCWorldExt::compute_runtime_climate_parity_hash(
        const Dictionary &fields) {
    Dictionary out;
    RuntimeClimateStore store;
    String error;
    Array missing;
    if (!build_climate_store_from_fields(fields, store, error, &missing)) {
        out["ok"] = false;
        // 缺字段与"字段有问题"是两种不同的 code：前者调用方能直接读出缺哪几条，
        // 后者要看 field 里的 name(dtype|size)。
        out["code"] = missing.is_empty()
            ? String("climate_reference_fields_invalid") : error;
        out["field"] = error;
        out["missing_fields"] = missing;
        return out;
    }
    out["ok"] = true;
    out["code"] = "ok";
    out["cell_count"] = static_cast<int64_t>(store.cell_count);
    // 用与 worker 完全相同的那一个归约函数。两侧"按约定各算一遍"是这条对拍最早的
    // 失效方式，所以这里刻意不复制哈希逻辑。
    out["parity_hash"] =
        static_cast<int64_t>(runtime_climate_parity_hash(store));
    out["parity_version"] =
        static_cast<int64_t>(RUNTIME_CLIMATE_PARITY_VERSION);
    out["fields_hashed"] =
        static_cast<int64_t>(runtime_climate_parity_comparable_count());
    return out;
}

Dictionary DCWorldExt::publish_runtime_climate_reference_state(
        int64_t day, const Dictionary &fields) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    if (day < 0) {
        out["ok"] = false;
        out["code"] = "climate_trace_reference_invalid";
        return out;
    }
    auto store = std::make_shared<RuntimeClimateStore>();
    String error;
    Array missing;
    if (!build_climate_store_from_fields(fields, *store, error, &missing)) {
        out["ok"] = false;
        out["code"] = missing.is_empty()
            ? String("climate_reference_fields_invalid") : error;
        out["field"] = error;
        out["missing_fields"] = missing;
        return out;
    }
    // 哈希在这里从 state 派生，所以两者不可能互相矛盾 —— 这正是这个绑定存在的理由
    // （另一个只收哈希的版本做不到按字段/格子定位分叉）。
    const uint64_t state_hash = runtime_climate_parity_hash(*store);

    RuntimeClimateReferencePublish publish;
    publish.reference_store = store;
    publish.round_input = _production_round_input;
    publish.round_ran = static_cast<bool>(_production_round_input);
    publish.round_scalars = &_production_round_scalars;
    publish.round_scalar_mask = _production_round_scalar_mask;
    publish.pass_b = _production_pass_b;
    publish.sea_ice = _production_sea_ice;
    publish.wind_surface = _production_wind_surface;
    publish.ocean_water = _production_ocean_water;
    publish.wind_air = _production_wind_air;
    publish.albedo = _production_albedo;
    publish.vegetation = _production_vegetation;
    publish.feedback = _production_feedback;
    publish.weather = _production_weather;
    publish.hydrology = _production_hydrology;
    publish.weather_distribute = _production_weather_distribute;
    publish.production_stage_mask = _production_stage_mask;
    publish.seasonal_feedback_ran = _production_seasonal_feedback_ran;
    publish.seasonal_feedback_decay = _production_seasonal_feedback_decay;
    publish.season_refresh_ran = _production_season_refresh_ran;

    std::string host_error;
    const bool ok = _runtime_host->publish_climate_reference(
        day, state_hash, host_error, publish);

    // 节拍诊断：配错一天会表现成"算法分叉"，所以前若干天照实把 round_ran 与 stage
    // mask 打出来。这比从分叉矩阵反推直接得多。
    if (_publish_cadence_reports_left > 0) {
        --_publish_cadence_reports_left;
        UtilityFunctions::print(vformat(
            "[climate][publish] day=%d round_ran=%d prod_stage=0x%x "
            "scalar_mask=0x%x alb=%d veg=%d fb=%d weather=%d sr=%d ok=%d",
            static_cast<int64_t>(day), publish.round_ran ? 1 : 0,
            publish.production_stage_mask, publish.round_scalar_mask,
            publish.albedo.ran ? 1 : 0,
            static_cast<bool>(publish.vegetation) ? 1 : 0,
            static_cast<bool>(publish.feedback) ? 1 : 0,
            static_cast<bool>(publish.weather) ? 1 : 0,
            publish.season_refresh_ran ? 1 : 0, ok ? 1 : 0));
    }

    // 全部 per-day 记录在这里复位。少了这一步，"生产这一天没跑某个 stage"会继承上
    // 一天的记录，而那正是这些字段用来区分的两种情况之一。
    _last_published_climate_reference = store;
    _production_round_input.reset();
    _production_round_scalar_mask = 0;
    _production_pass_b.reset();
    _production_sea_ice.reset();
    _production_wind_surface.reset();
    _production_ocean_water.reset();
    _production_wind_air.reset();
    _production_albedo = pk_async_climate::ClimateAlbedoKnobs{};
    _production_vegetation.reset();
    _production_feedback.reset();
    _production_weather.reset();
    _production_hydrology.reset();
    _production_weather_distribute.reset();
    _production_stage_mask = 0;
    _production_seasonal_feedback_ran = false;
    _production_seasonal_feedback_decay = 1.0f;
    _production_season_refresh_ran = false;

    if (!ok) {
        out["ok"] = false;
        out["code"] = String(host_error.c_str());
        out["day"] = day;
        out["parity_hash"] = static_cast<int64_t>(state_hash);
        return out;
    }
    out["ok"] = true;
    out["pending"] = false;
    out["code"] = "ok";
    out["day"] = day;
    // 键名是 parity_hash：调用方（map_generator.gd:2548）按它取值，取到 0 会判成
    // "归约什么都没算出来"并把这一天整个作废。
    out["parity_hash"] = static_cast<int64_t>(state_hash);
    out["cell_count"] = static_cast<int64_t>(store->cell_count);
    return out;
}

Array DCWorldExt::get_runtime_climate_parity_divergence() const {
    Array out;
    if (!_runtime_host) return out;
    const size_t count = runtime_climate_parity_field_count();
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    for (size_t i = 0; i < count; ++i) {
        const auto st = _runtime_host->climate_parity_field_status(i);
        // 没比过的字段也要出现在表里：缺行和"零分叉"是两件事，而分叉矩阵是用来
        // 排迁移顺序的，一行的缺席会被读成"这个 stage 已经对齐了"。
        Dictionary row;
        row["name"] = String(table[i].name);
        row["stage"] = static_cast<int>(table[i].stage);
        row["stage_name"] = String(runtime_climate_stage_name(table[i].stage));
        // 与 get_runtime_climate_parity_fields 同一口径：字符串而不是枚举序号。
        row["tolerance"] = String(pk_parity_tolerance_name(table[i].tolerance));
        row["tolerance_band"] =
            runtime_climate_parity_tolerance_band(table[i].tolerance);
        row["comparability"] =
            String(pk_parity_comparability_name(table[i].comparability));
        row["compared_days"] = static_cast<int64_t>(st.compared_days);
        row["diverged_days"] = static_cast<int64_t>(st.diverged_days);
        row["diverged_cells"] = static_cast<int64_t>(st.diverged_cells);
        row["out_of_band_days"] = static_cast<int64_t>(st.out_of_band_days);
        row["out_of_band_cells"] = static_cast<int64_t>(st.out_of_band_cells);
        row["first_diverged_day"] = st.first_diverged_day;
        row["first_out_of_band_day"] = st.first_out_of_band_day;
        row["first_cell"] = static_cast<int64_t>(st.first_cell);
        row["last_diverged_cells"] =
            static_cast<int64_t>(st.last_diverged_cells);
        row["last_out_of_band_cells"] =
            static_cast<int64_t>(st.last_out_of_band_cells);
        row["max_abs_delta"] = st.max_abs_delta;
        row["max_out_of_band_delta"] = st.max_out_of_band_delta;
        row["first_reference_bits"] = String(st.first_reference_bits);
        row["first_worker_bits"] = String(st.first_worker_bits);
        out.push_back(row);
    }
    return out;
}
