Dictionary DCWorldExt::set_runtime_ideology_parity_enabled(bool enabled) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    _runtime_host->set_ideology_parity_enabled(enabled);
    out["ok"] = true;
    out["code"] = "ok";
    out["enabled"] = _runtime_host->ideology_parity_enabled();
    return out;
}

Dictionary DCWorldExt::set_runtime_climate_parity_forcing(bool enabled) {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    _runtime_host->set_climate_parity_forcing(enabled);
    out["ok"] = true;
    out["code"] = "ok";
    out["enabled"] = _runtime_host->climate_parity_forcing();
    out["forced_days"] =
        static_cast<int64_t>(_runtime_host->climate_parity_forced_days());
    return out;
}

// 这三条枚举跨边界时给的是字符串而不是序号：GDScript 侧一律用 String() 包装它们
// （map_generator.gd:2434 的 != "comparable"、runtime_climate_parity_test 的
// in ["f32","i32","u8"]），而 Godot 4 的 String() 构造不接受 int —— 给序号会在那一行
// 抛 "Nonexistent 'String' constructor"，把 _collect_runtime_climate_parity_fields
// 整个打断，于是 reference publish 永远 pending、SHADOW 对拍一天都比不上。
static const char *pk_parity_kind_name(RuntimeClimateParityKind kind) {
    switch (kind) {
        case RuntimeClimateParityKind::F32: return "f32";
        case RuntimeClimateParityKind::I32: return "i32";
        case RuntimeClimateParityKind::U8:  return "u8";
    }
    return "f32";
}

static const char *pk_parity_comparability_name(
        RuntimeClimateParityComparability c) {
    switch (c) {
        case RuntimeClimateParityComparability::COMPARABLE: return "comparable";
        case RuntimeClimateParityComparability::TYPE_MISMATCH:
            return "type_mismatch";
        case RuntimeClimateParityComparability::NO_REFERENCE:
            return "no_reference";
    }
    return "no_reference";
}

static const char *pk_parity_tolerance_name(RuntimeClimateParityTolerance t) {
    switch (t) {
        case RuntimeClimateParityTolerance::BITWISE: return "bitwise";
        case RuntimeClimateParityTolerance::SLICED:  return "sliced";
        case RuntimeClimateParityTolerance::CHAINED: return "chained";
    }
    return "bitwise";
}

Array DCWorldExt::get_runtime_climate_parity_fields() const {
    Array out;
    const size_t count = runtime_climate_parity_field_count();
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    for (size_t i = 0; i < count; ++i) {
        const RuntimeClimateParityField &f = table[i];
        Dictionary row;
        row["name"] = String(f.name);
        row["map_data_array"] = String(f.map_data_array);
        row["kind"] = String(pk_parity_kind_name(f.kind));
        row["comparability"] = String(pk_parity_comparability_name(f.comparability));
        row["tolerance"] = String(pk_parity_tolerance_name(f.tolerance));
        row["tolerance_band"] =
            runtime_climate_parity_tolerance_band(f.tolerance);
        row["stage"] = static_cast<int>(f.stage);
        row["stage_name"] = String(runtime_climate_stage_name(f.stage));
        row["note"] = String(f.note != nullptr ? f.note : "");
        out.push_back(row);
    }
    return out;
}
