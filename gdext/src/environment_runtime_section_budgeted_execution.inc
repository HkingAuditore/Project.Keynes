Dictionary EnvironmentRuntime::step_budgeted(double budget_ms, int max_cells, int max_pixels, int max_indices) {
    Dictionary out;
    if (!_initialized) {
        out["done"] = true;
        out["stage"] = "uninitialized";
        out["work_done"] = 0;
        out["elapsed_ms"] = 0.0;
        return out;
    }
    if (!_round_active) {
        begin_round(_round_name.is_empty() ? String("environment") : _round_name);
    }

    Time *time = Time::get_singleton();
    uint64_t start_us = time != nullptr ? time->get_ticks_usec() : 0;
    double budget = std::max(0.0, budget_ms);
    int processed_total = 0;
    String stage_name;
    String substage_name;
    int cursor_start = -1;
    int cursor_end = -1;
    int processed_cells = 0;
    int processed_pixels = 0;
    int processed_indices = 0;

    while (_round_active) {
        StageState *stage = _current_stage();
        if (stage == nullptr) {
            _round_active = false;
            publish_snapshot();
            break;
        }
        if (stage->cursor >= stage->total) {
            _stage_index += 1;
            continue;
        }
        stage_name = stage->name;
        substage_name = stage->substage;
        if (cursor_start < 0) cursor_start = stage->cursor;

        int remaining = stage->total - stage->cursor;
        int limit = remaining;
        if (stage->kind == 0 && max_cells > 0) limit = std::min(limit, max_cells - processed_cells);
        if (stage->kind == 1 && max_pixels > 0) limit = std::min(limit, max_pixels - processed_pixels);
        if (stage->kind == 2 && max_indices > 0) limit = std::min(limit, max_indices - processed_indices);
        if (limit <= 0) break;

        // Skeleton state machine: advance cursors and accounting only. Later
        // tasks replace this no-op range advance with actual ocean/weather/
        // climate kernels while preserving the same budget contract.
        stage->cursor += limit;
        cursor_end = stage->cursor;
        processed_total += limit;
        if (stage->kind == 0) {
            processed_cells += limit;
        } else if (stage->kind == 1) {
            processed_pixels += limit;
        } else {
            processed_indices += limit;
        }

        if (stage->cursor >= stage->total) {
            _stage_index += 1;
        }
        if (budget > 0.0 && time != nullptr) {
            double elapsed_now = (double)(time->get_ticks_usec() - start_us) / 1000.0;
            if (processed_total > 0 && elapsed_now >= budget) break;
        }
        if ((max_cells > 0 && processed_cells >= max_cells)
            || (max_pixels > 0 && processed_pixels >= max_pixels)
            || (max_indices > 0 && processed_indices >= max_indices)) {
            break;
        }
    }

    double elapsed_ms = 0.0;
    if (time != nullptr) {
        elapsed_ms = (double)(time->get_ticks_usec() - start_us) / 1000.0;
    }
    _last_processed = processed_total;
    _last_elapsed_ms = elapsed_ms;
    bool done = !_round_active;
    if (_round_active && _stage_index >= (int)_stages.size()) {
        _round_active = false;
        publish_snapshot();
        done = true;
    }

    out["done"] = done;
    out["round"] = _round_name;
    out["stage"] = stage_name;
    out["substage"] = substage_name;
    out["work_done"] = processed_total;
    out["processed_cells"] = processed_cells;
    out["processed_pixels"] = processed_pixels;
    out["processed_indices"] = processed_indices;
    out["cursor_start"] = cursor_start;
    out["cursor_end"] = cursor_end;
    out["elapsed_ms"] = elapsed_ms;
    out["remaining_work"] = is_round_done() ? 0 : int(progress_summary().get("remaining_work", 0));
    out["progress_ratio"] = progress_summary().get("progress_ratio", 1.0);
    return out;
}

Dictionary EnvironmentRuntime::step_ocean_budgeted(double budget_ms, int max_cells, int max_pixels, int max_indices) {
    if (!_ocean_round_active || !_round_active || _round_name != String("ocean_native_pipeline")) {
        begin_ocean_round(true);
    }
    Dictionary res = step_budgeted(budget_ms, max_cells, max_pixels, max_indices);
    res["path"] = "ocean_native_pipeline";
    res["fallback_path"] = String();
    res["ocean_include_raster"] = _ocean_include_raster;
    String stage = String(res.get("stage", String()));
    if (stage == "ocean_dirty_tiles" && int(res.get("work_done", 0)) > 0) {
        int s = std::max(0, int(res.get("cursor_start", 0)));
        int e = std::max(s, int(res.get("cursor_end", s)));
        for (int tile = s; tile < e; ++tile) {
            _ocean_dirty_tiles.push_back(tile);
        }
    }
    if (bool(res.get("done", false))) {
        _ocean_round_active = false;
        if (_ocean_dirty_tiles.empty() && _pixel_count > 0) {
            int tile_count = std::max(1, (_pixel_count + _ocean_dirty_tile_size - 1) / _ocean_dirty_tile_size);
            _ocean_dirty_tiles.reserve(tile_count);
            for (int tile = 0; tile < tile_count; ++tile) {
                _ocean_dirty_tiles.push_back(tile);
            }
        }
    }
    res["dirty_tiles"] = (int)_ocean_dirty_tiles.size();
    return res;
}

Dictionary EnvironmentRuntime::step_weather_budgeted(double budget_ms, int max_cells, int max_pixels, int max_indices) {
    if (!_weather_round_active || !_round_active || _round_name != String("weather_native_solver")) {
        begin_weather_round(true);
    }
    Dictionary res = step_budgeted(budget_ms, max_cells, max_pixels, max_indices);
    res["path"] = "weather_native_solver";
    res["fallback_path"] = String();
    res["weather_use_active_list"] = _weather_use_active_list;
    res["weather_snapshot_version"] = _weather_snapshot_version;
    String stage = String(res.get("stage", String()));
    if (stage == "weather_publish" && int(res.get("work_done", 0)) > 0) {
        _weather_pingpong_a_is_prev = !_weather_pingpong_a_is_prev;
        _weather_snapshot_version += 1;
        clear_dirty();
        res["published"] = true;
        res["weather_snapshot_version"] = _weather_snapshot_version;
    }
    if (bool(res.get("done", false))) {
        _weather_round_active = false;
    }
    return res;
}

Dictionary EnvironmentRuntime::step_climate_budgeted(double budget_ms, int max_cells, int max_pixels, int max_indices) {
    if (!_climate_round_active || !_round_active || _round_name != String("climate_native_daily")) {
        begin_climate_round(true);
    }
    Dictionary res = step_budgeted(budget_ms, max_cells, max_pixels, max_indices);
    res["path"] = "climate_native_daily";
    res["fallback_path"] = String();
    res["climate_use_dirty_list"] = _climate_use_dirty_list;
    res["climate_snapshot_version"] = _climate_snapshot_version;
    if (bool(res.get("done", false))) {
        _climate_round_active = false;
        _climate_snapshot_version += 1;
        clear_dirty();
        res["published"] = true;
        res["climate_snapshot_version"] = _climate_snapshot_version;
    }
    return res;
}

PackedInt32Array EnvironmentRuntime::consume_ocean_dirty_tiles() {
    PackedInt32Array out;
    out.resize((int)_ocean_dirty_tiles.size());
    for (int i = 0; i < (int)_ocean_dirty_tiles.size(); ++i) {
        out[i] = _ocean_dirty_tiles[i];
    }
    _ocean_dirty_tiles.clear();
    return out;
}
