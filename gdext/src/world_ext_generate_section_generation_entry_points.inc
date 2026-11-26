Dictionary DCWorldExt::run_native_world_generate_pass(int seed,
                                                      const Dictionary &cfg,
                                                      const Dictionary &profile) {
    Dictionary out = _run_native_generation_publish_pass(seed, cfg, profile, Dictionary());
    _native_generation_active = false;
    _native_generation_seed = seed;
    _native_generation_cfg = cfg.duplicate(true);
    _native_generation_profile = profile.duplicate(true);
    _native_generation_report = out.duplicate(true);
    return out;
}

// dots-total-cpp step4（2026-06-25）：base + post_base 融合单次驱动。
// base 的 10×n_cells SoA bundle 在 C++ 进程内直接喂给 post_base，不出语言边界。
Dictionary DCWorldExt::run_native_world_generate_full_pass(int seed,
                                                           const Dictionary &cfg,
                                                           const Dictionary &profile) {
    using godot::String;
    Dictionary base_res = run_native_world_generate_base_pass(seed, cfg, profile);
    if (int(base_res.get("rc", -1)) != 0 || bool(base_res.get("fallback", true))) {
        // base 失败：透传 base 结果（含 rc/fallback_reason），由 GDScript 中止。
        return base_res;
    }
    Dictionary post_res = run_native_world_generate_post_base_pass(seed, cfg, profile, base_res);
    // 合并 base 诊断键（GDScript 打印 base path 用），不覆盖 post_base 已有键。
    if (!post_res.has("native_algorithm") && base_res.has("native_algorithm")) {
        post_res["native_algorithm"] = base_res.get("native_algorithm", String("unknown"));
    }
    post_res["base_water_count"] = base_res.get("water_count", 0);
    post_res["base_land_count"] = base_res.get("land_count", 0);
    post_res["base_native_ms"] = base_res.get("native_ms", base_res.get("elapsed_ms", 0.0));
    post_res["base_n_cells"] = base_res.get("n_cells", 0);
    // [zonal-envelope 2026-08-01] 透传 base 期纬带湿度统计，供 headless 回归/审计断言。
    {
        static const char *kZonalKeys[] = {
            "zonal_moist_mean_eq", "zonal_moist_mean_subtrop",
            "zonal_moist_mean_midlat", "zonal_moist_mean_polar",
            "zonal_moist_min_subtrop",
            "zonal_land_cells_eq", "zonal_land_cells_subtrop",
            "zonal_land_cells_midlat", "zonal_land_cells_polar",
            "ridge_budget_scale", "ridge_base_scale", "ridge_tail_cells",
            "ridge_land_cells", "ridge_elevation_cap",
        };
        for (const char *key : kZonalKeys) {
            if (base_res.has(key) && !post_res.has(key)) {
                post_res[key] = base_res.get(key, Variant());
            }
        }
    }
    post_res["fused_base_post"] = true;
    return post_res;
}

Dictionary DCWorldExt::run_research_signal_generation_pass(const Dictionary &knobs) {
    using godot::PackedByteArray;
    using godot::PackedFloat32Array;
    using godot::PackedInt32Array;
    Dictionary out;
    out["ok"] = false;
    const String mode = knobs.get("mode", String("static"));
    if (mode == String("resources")) {
        const int n = int(knobs.get("cell_count", 0));
        const PackedInt32Array old_offsets = knobs.get(
            "cell_signal_offsets", PackedInt32Array());
        const PackedInt32Array old_ids = knobs.get(
            "cell_signal_ids", PackedInt32Array());
        const PackedInt32Array old_values = knobs.get(
            "cell_signal_values", PackedInt32Array());
        const PackedInt32Array resource_signal_ids = knobs.get(
            "resource_signal_ids", PackedInt32Array());
        const Array reserve_columns = knobs.get("resource_reserves", Array());
        if (n <= 0 || old_offsets.size() != n + 1 || old_ids.size() != old_values.size() ||
            old_offsets[0] != 0 || old_offsets[n] != old_ids.size() ||
            resource_signal_ids.is_empty() ||
            reserve_columns.size() != resource_signal_ids.size()) {
            out["reason"] = String("research_resource_signal_input_shape_invalid");
            return out;
        }
        std::vector<PackedFloat32Array> reserves;
        reserves.reserve(size_t(reserve_columns.size()));
        for (int resource = 0; resource < reserve_columns.size(); ++resource) {
            const PackedFloat32Array column = reserve_columns[resource];
            if (column.size() != n) {
                out["reason"] = String("research_resource_signal_reserve_shape_invalid");
                return out;
            }
            reserves.push_back(column);
        }
        PackedInt32Array offsets;
        PackedInt32Array ids;
        PackedInt32Array values;
        offsets.resize(n + 1);
        int32_t *offset = offsets.ptrw();
        std::vector<std::pair<int32_t, int32_t>> scratch;
        scratch.reserve(size_t(resource_signal_ids.size()) + 16U);
        int32_t cursor = 0;
        for (int cell = 0; cell < n; ++cell) {
            offset[cell] = cursor;
            scratch.clear();
            const int32_t begin = old_offsets[cell];
            const int32_t end = old_offsets[cell + 1];
            if (begin < 0 || end < begin || end > old_ids.size()) {
                out["reason"] = String("research_resource_signal_csr_invalid");
                return out;
            }
            for (int32_t edge = begin; edge < end; ++edge)
                scratch.emplace_back(old_ids[edge], old_values[edge]);
            for (int resource = 0; resource < resource_signal_ids.size(); ++resource) {
                if (reserves[size_t(resource)][cell] > 0.0001f)
                    scratch.emplace_back(resource_signal_ids[resource], 1);
            }
            std::sort(scratch.begin(), scratch.end(),
                      [](const auto &a, const auto &b) { return a.first < b.first; });
            for (const auto &entry : scratch) {
                if (entry.first < 0) continue;
                if (!ids.is_empty() && cursor > offset[cell] && ids[cursor - 1] == entry.first) {
                    values.set(cursor - 1, std::max(values[cursor - 1], entry.second));
                    continue;
                }
                ids.push_back(entry.first);
                values.push_back(entry.second);
                ++cursor;
            }
        }
        offset[n] = cursor;
        out["ok"] = true;
        out["path"] = String("gdext_resource_merge");
        out["cell_signal_offsets"] = offsets;
        out["cell_signal_ids"] = ids;
        out["cell_signal_values"] = values;
        return out;
    }
    const int width = int(knobs.get("width", 0));
    const int height = int(knobs.get("height", 0));
    const int seed = int(knobs.get("seed", 0));
    const int64_t n64 = int64_t(width) * int64_t(height);
    if (width <= 0 || height <= 0 || n64 <= 0 || n64 > 1000000) {
        out["reason"] = String("research_signal_generation_dimensions_invalid");
        return out;
    }
    const int n = int(n64);
    (void)seed;
    const PackedByteArray vegetation = knobs.get("generation_vegetation", PackedByteArray());
    const PackedByteArray landform = knobs.get("landform", PackedByteArray());
    const PackedByteArray rivers = knobs.get("has_river", PackedByteArray());
    const PackedByteArray volcanoes = knobs.get("has_volcano", PackedByteArray());
    const PackedByteArray water = knobs.get("is_water", PackedByteArray());
    const PackedFloat32Array temperature = knobs.get("temperature", PackedFloat32Array());
    const PackedFloat32Array moisture = knobs.get("moisture", PackedFloat32Array());
    const PackedFloat32Array elevation = knobs.get("elevation", PackedFloat32Array());
    const PackedInt32Array signal_ids = knobs.get("signal_ids", PackedInt32Array());
    if (vegetation.size() != n || landform.size() != n || rivers.size() != n ||
        volcanoes.size() != n || water.size() != n || temperature.size() != n ||
        moisture.size() != n || elevation.size() != n || signal_ids.size() != 21) {
        out["reason"] = String("research_signal_generation_input_shape_invalid");
        return out;
    }
    // Landform-only CSR. Bio occupancy is seeded after resource bootstrap.
    const uint8_t *veg = vegetation.ptr();
    const uint8_t *lf = landform.ptr();
    const uint8_t *riv = rivers.ptr();
    const uint8_t *volc = volcanoes.ptr();
    const uint8_t *is_water = water.ptr();
    const float *temp = temperature.ptr();
    const float *moist = moisture.ptr();
    const float *elev = elevation.ptr();
    const int32_t *sid = signal_ids.ptr();
    PackedByteArray realms;
    realms.resize(n);
    uint8_t *realm = realms.ptrw();
    std::memset(realm, 0, size_t(n));
    PackedInt32Array offsets;
    offsets.resize(n + 1);
    int32_t *offset = offsets.ptrw();
    PackedInt32Array ids;
    PackedInt32Array values;
    ids.resize(0); values.resize(0);
    std::vector<int32_t> scratch;
    scratch.reserve(24);
    auto has_water_neighbor = [&](int cell) {
        const int row = cell / width;
        const int col = cell - row * width;
        const int left = row * width + ((col + width - 1) % width);
        const int right = row * width + ((col + 1) % width);
        const int up = row > 0 ? cell - width : -1;
        const int down = row + 1 < height ? cell + width : -1;
        return is_water[left] || is_water[right] || (up >= 0 && is_water[up]) ||
               (down >= 0 && is_water[down]);
    };
    int32_t cursor = 0;
    for (int cell = 0; cell < n; ++cell) {
        offset[cell] = cursor;
        scratch.clear();
        if (is_water[cell] == 0) {
            const bool grass = veg[cell] == 4 || veg[cell] == 9 || veg[cell] == 10 ||
                               veg[cell] == 13;
            const bool forest = veg[cell] == 5 || veg[cell] == 7 || veg[cell] == 8 ||
                                veg[cell] == 12 || veg[cell] == 14 || veg[cell] == 15 ||
                                veg[cell] == 24 || veg[cell] == 25;
            const bool wetland = veg[cell] == 19 || veg[cell] == 20 ||
                                 veg[cell] == 21 || veg[cell] == 27 || lf[cell] == 9;
            const bool arid = veg[cell] == 16 || veg[cell] == 17 ||
                              lf[cell] == 10 || lf[cell] == 11;
            const bool coast = has_water_neighbor(cell);
            const bool cold = temp[cell] <= 0.34f;
            const bool warm = temp[cell] >= 0.62f;
            const bool moist_land = moist[cell] >= 0.58f;
            const bool dry_land = moist[cell] <= 0.38f;
            const bool highland = elev[cell] >= 0.62f ||
                                  lf[cell] == 7 || lf[cell] == 8 || lf[cell] == 13;
            if (riv[cell] != 0 || wetland) scratch.push_back(sid[0]);
            if (riv[cell] != 0) scratch.push_back(sid[1]);
            if (volc[cell] != 0 || lf[cell] == 12) scratch.push_back(sid[2]);
            if (lf[cell] == 13) scratch.push_back(sid[3]);
            if (riv[cell] != 0 && coast) scratch.push_back(sid[4]);
            if (coast) scratch.push_back(sid[5]);
            if (arid) scratch.push_back(sid[6]);
            if (wetland) scratch.push_back(sid[7]);
            if (forest) scratch.push_back(sid[8]);
            if (grass) scratch.push_back(sid[9]);
            if (lf[cell] == 7 || lf[cell] == 8 || lf[cell] == 13)
                scratch.push_back(sid[10]);
            if (riv[cell] != 0 && coast) scratch.push_back(sid[11]);
            if (riv[cell] != 0 && moist_land && elev[cell] <= 0.48f)
                scratch.push_back(sid[12]);
            if (warm && moist_land) scratch.push_back(sid[13]);
            if (grass && !arid && moist[cell] <= 0.56f) scratch.push_back(sid[14]);
            if (grass && dry_land) scratch.push_back(sid[15]);
            if (cold && !forest) scratch.push_back(sid[16]);
            if (cold && forest) scratch.push_back(sid[17]);
            if (arid && (riv[cell] != 0 || wetland)) scratch.push_back(sid[18]);
            if (highland) scratch.push_back(sid[19]);
            if ((coast || highland) && !forest) scratch.push_back(sid[20]);
        }
        std::sort(scratch.begin(), scratch.end());
        scratch.erase(std::unique(scratch.begin(), scratch.end()), scratch.end());
        for (int32_t signal : scratch) {
            if (signal < 0) continue;
            ids.push_back(signal);
            values.push_back(1);
            ++cursor;
        }
    }
    offset[n] = cursor;
    out["ok"] = true;
    out["path"] = String("gdext");
    out["generation_vegetation"] = vegetation;
    out["cell_biogeographic_realm"] = realms;
    out["cell_signal_offsets"] = offsets;
    out["cell_signal_ids"] = ids;
    out["cell_signal_values"] = values;
    return out;
}

Dictionary DCWorldExt::start_native_generation(int seed,
                                               const Dictionary &cfg,
                                               const Dictionary &profile) {
    _native_generation_active = true;
    _native_generation_seed = seed;
    _native_generation_cfg = cfg.duplicate(true);
    _native_generation_profile = profile.duplicate(true);
    _native_generation_report.clear();
    _native_generation_report["rc"] = 0;
    _native_generation_report["status"] = String("started");
    _native_generation_report["path"] = String("gdext");
    _native_generation_report["seed"] = seed;
    _native_generation_report["has_config"] = !cfg.is_empty();
    _native_generation_report["has_profile"] = !profile.is_empty();
    _native_generation_report["generation_progress"] = 0.0;
    _native_generation_report["implemented"] = true;
    _native_generation_report["published_to_slot"] = false;
    _native_generation_report["fallback"] = false;
    _native_generation_report["fallback_reason"] = String();
    _native_generation_report["fail_stage"] = String();
    return _native_generation_report.duplicate(true);
}

Dictionary DCWorldExt::run_native_generation_slice(const Dictionary &budget) {
    if (!_native_generation_active) {
        Dictionary out;
        out["rc"] = -1;
        out["status"] = String("idle");
        out["path"] = String("gdscript_fallback");
        out["fallback"] = true;
        out["fallback_reason"] = String("generation_not_started");
        out["reason"] = String("generation_not_started");
        out["seed"] = _native_generation_seed;
        out["budget"] = budget.duplicate(true);
        out["generation_progress"] = 0.0;
        out["implemented"] = true;
        out["published_to_slot"] = false;
        _native_generation_report = out.duplicate(true);
        return out;
    }
    Dictionary out = _run_native_generation_publish_pass(
        _native_generation_seed,
        _native_generation_cfg,
        _native_generation_profile,
        budget);
    _native_generation_active = false;
    _native_generation_report = out.duplicate(true);
    return out;
}

Dictionary DCWorldExt::finish_native_generation() {
    if (_native_generation_active) {
        Dictionary out = _run_native_generation_publish_pass(
            _native_generation_seed,
            _native_generation_cfg,
            _native_generation_profile,
            Dictionary());
        _native_generation_active = false;
        _native_generation_report = out.duplicate(true);
        return out;
    }
    if (!_native_generation_report.is_empty()) {
        return _native_generation_report.duplicate(true);
    }
    Dictionary out;
    out["rc"] = -1;
    out["status"] = String("idle");
    out["path"] = String("gdscript_fallback");
    out["fallback"] = true;
    out["fallback_reason"] = String("generation_not_started");
    out["reason"] = String("generation_not_started");
    out["seed"] = _native_generation_seed;
    out["generation_progress"] = 0.0;
    out["implemented"] = true;
    out["published_to_slot"] = false;
    _native_generation_report = out.duplicate(true);
    return out;
}
