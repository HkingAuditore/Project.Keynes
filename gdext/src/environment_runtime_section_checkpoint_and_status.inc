Dictionary EnvironmentRuntime::status() const {
    Dictionary d;
    d["initialized"] = _initialized;
    d["cell_count"] = _cell_count;
    d["pixel_count"] = _pixel_count;
    d["pixel_width"] = _pixel_size.x;
    d["pixel_height"] = _pixel_size.y;
    d["snapshot_version"] = _snapshot_version;
    d["rebuild_generation"] = _rebuild_generation;
    d["topology_valid"] = _topology_valid;
    d["all_dirty"] = _all_dirty;
    d["dirty_climate_capacity"] = (int)_climate_dirty_mask.size();
    d["dirty_weather_capacity"] = (int)_weather_dirty_mask.size();
    d["active_weather_indices"] = (int)_active_weather_indices.size();
    d["dirty_climate_indices"] = (int)_dirty_climate_indices.size();
    d["ocean_dirty_tiles"] = (int)_ocean_dirty_tiles.size();
    d["weather_snapshot_version"] = _weather_snapshot_version;
    d["climate_snapshot_version"] = _climate_snapshot_version;
    d["worker_threads_enabled"] = false;
    d["godot_object_access"] = "main_thread_only";
    d["runtime_thread_model"] = "single_thread_budgeted";
    return d;
}

Dictionary EnvironmentRuntime::buffer_summary() const {
    Dictionary d;
    d["cell_count"] = _cell_count;
    d["pixel_count"] = _pixel_count;
    d["cell_float_buffers"] = 16;
    d["weather_pingpong_buffers"] = 6;
    d["neighbor_slots"] = (int)_neighbor_indices.size();
    d["pixel_to_cell_slots"] = (int)_pixel_to_cell.size();
    d["water_indices"] = (int)_water_indices.size();
    d["coastal_indices"] = (int)_coastal_indices.size();
    d["estimated_cell_float_bytes"] = (int)(_cell_count * 16 * (int)sizeof(float));
    d["estimated_weather_bytes"] = (int)(_cell_count * 6 * (int)sizeof(float));
    d["estimated_topology_bytes"] = (int)((_neighbor_indices.size() + _pixel_to_cell.size()) * sizeof(int32_t));
    return d;
}

Dictionary EnvironmentRuntime::snapshot_summary() const {
    Dictionary d;
    d["snapshot_version"] = _snapshot_version;
    d["rebuild_generation"] = _rebuild_generation;
    d["stable_for_readers"] = _initialized && !_all_dirty;
    d["all_dirty"] = _all_dirty;
    d["topology_valid"] = _topology_valid;
    return d;
}

Dictionary EnvironmentRuntime::topology_summary() const {
    Dictionary d;
    d["topology_valid"] = _topology_valid;
    d["cell_count"] = _cell_count;
    d["neighbor_slots"] = (int)_neighbor_indices.size();
    d["water_indices"] = (int)_water_indices.size();
    d["coastal_indices"] = (int)_coastal_indices.size();
    d["pixel_to_cell_slots"] = (int)_pixel_to_cell.size();
    d["terrain_mask_slots"] = (int)_terrain_mask.size();
    d["climate_dirty_indices"] = (int)_dirty_climate_indices.size();
    d["weather_active_indices"] = (int)_active_weather_indices.size();
    d["ocean_dirty_tiles"] = (int)_ocean_dirty_tiles.size();
    return d;
}

Dictionary EnvironmentRuntime::progress_summary() const {
    Dictionary d;
    int total = 0;
    int done = 0;
    for (const StageState &stage : _stages) {
        total += stage.total;
        done += std::min(stage.cursor, stage.total);
    }
    const StageState *stage = _current_stage();
    d["round"] = _round_name;
    d["round_active"] = _round_active;
    d["stage_index"] = _stage_index;
    d["stage_count"] = (int)_stages.size();
    d["stage"] = stage != nullptr ? stage->name : String();
    d["substage"] = stage != nullptr ? stage->substage : String();
    d["cursor"] = stage != nullptr ? stage->cursor : 0;
    d["stage_total"] = stage != nullptr ? stage->total : 0;
    d["total_work"] = total;
    d["completed_work"] = done;
    d["remaining_work"] = std::max(0, total - done);
    d["progress_ratio"] = total > 0 ? (double)done / (double)total : 1.0;
    d["last_processed"] = _last_processed;
    d["last_elapsed_ms"] = _last_elapsed_ms;
    d["ocean_round_active"] = _ocean_round_active;
    d["weather_round_active"] = _weather_round_active;
    d["weather_snapshot_version"] = _weather_snapshot_version;
    d["climate_round_active"] = _climate_round_active;
    d["climate_snapshot_version"] = _climate_snapshot_version;
    return d;
}

Dictionary EnvironmentRuntime::export_runtime_state() const {
    Dictionary d;
    d["schema"] = "PKEnvironmentRuntime";
    d["schema_version"] = ENVIRONMENT_STATE_SCHEMA_VERSION;
    d["initialized"] = _initialized;
    d["cell_count"] = _cell_count;
    d["pixel_count"] = _pixel_count;
    d["pixel_width"] = _pixel_size.x;
    d["pixel_height"] = _pixel_size.y;
    d["snapshot_version"] = _snapshot_version;
    d["weather_snapshot_version"] = _weather_snapshot_version;
    d["climate_snapshot_version"] = _climate_snapshot_version;
    d["rebuild_generation"] = _rebuild_generation;
    d["round_name"] = _round_name;
    d["round_active"] = _round_active;
    d["stage_index"] = _stage_index;
    d["stage_count"] = (int)_stages.size();
    const StageState *stage = _current_stage();
    d["stage"] = stage != nullptr ? stage->name : String();
    d["substage"] = stage != nullptr ? stage->substage : String();
    d["stage_cursor"] = stage != nullptr ? stage->cursor : 0;
    d["stage_total"] = stage != nullptr ? stage->total : 0;
    d["all_dirty"] = _all_dirty;
    d["topology_valid"] = _topology_valid;
    d["ocean_round_active"] = _ocean_round_active;
    d["weather_round_active"] = _weather_round_active;
    d["climate_round_active"] = _climate_round_active;
    d["ocean_include_raster"] = _ocean_include_raster;
    d["ocean_dirty_tile_size"] = _ocean_dirty_tile_size;
    d["weather_use_active_list"] = _weather_use_active_list;
    d["weather_pingpong_a_is_prev"] = _weather_pingpong_a_is_prev;
    d["climate_use_dirty_list"] = _climate_use_dirty_list;
    d["last_processed"] = _last_processed;
    d["last_elapsed_ms"] = _last_elapsed_ms;

    d["elevation"] = pack_f32(_elevation);
    d["temperature"] = pack_f32(_temperature);
    d["moisture"] = pack_f32(_moisture);
    d["pressure"] = pack_f32(_pressure);
    d["wind_x"] = pack_f32(_wind_x);
    d["wind_y"] = pack_f32(_wind_y);
    d["wind_speed"] = pack_f32(_wind_speed);
    d["ocean_x"] = pack_f32(_ocean_x);
    d["ocean_y"] = pack_f32(_ocean_y);
    d["ocean_speed"] = pack_f32(_ocean_speed);
    d["weather_vapor_a"] = pack_f32(_weather_vapor_a);
    d["weather_vapor_b"] = pack_f32(_weather_vapor_b);
    d["weather_cloud_a"] = pack_f32(_weather_cloud_a);
    d["weather_cloud_b"] = pack_f32(_weather_cloud_b);
    d["weather_precip_a"] = pack_f32(_weather_precip_a);
    d["weather_precip_b"] = pack_f32(_weather_precip_b);
    d["climate_dirty_mask"] = pack_u8(_climate_dirty_mask);
    d["weather_dirty_mask"] = pack_u8(_weather_dirty_mask);
    d["terrain_mask"] = pack_u8(_terrain_mask);
    d["active_weather_indices"] = pack_i32(_active_weather_indices);
    d["dirty_climate_indices"] = pack_i32(_dirty_climate_indices);
    d["water_indices"] = pack_i32(_water_indices);
    d["coastal_indices"] = pack_i32(_coastal_indices);
    d["neighbor_indices"] = pack_i32(_neighbor_indices);
    d["pixel_to_cell"] = pack_i32(_pixel_to_cell);
    d["ocean_dirty_tiles"] = pack_i32(_ocean_dirty_tiles);
    PackedInt32Array stage_cursors;
    stage_cursors.resize((int)_stages.size());
    for (int i = 0; i < (int)_stages.size(); ++i) stage_cursors.set(i, _stages[i].cursor);
    d["stage_cursors"] = stage_cursors;
    d["worker_threads_enabled"] = false;
    d["godot_object_access"] = "main_thread_only";
    d["runtime_thread_model"] = "single_thread_budgeted";
    return d;
}

Dictionary EnvironmentRuntime::restore_runtime_state(const Dictionary &state) {
    if (String(state.get("schema", String())) != String("PKEnvironmentRuntime") ||
            int(state.get("schema_version", -1)) != ENVIRONMENT_STATE_SCHEMA_VERSION) {
        return restore_result(false, "environment_schema_incompatible",
                              "Environment runtime save schema is incompatible.");
    }
    const int saved_cells = int(state.get("cell_count", -1));
    const int saved_pixels = int(state.get("pixel_count", -1));
    if (!_initialized || saved_cells != _cell_count || saved_pixels != _pixel_count) {
        return restore_result(false, "environment_dimensions_mismatch",
                              "Environment runtime dimensions do not match the regenerated world.");
    }

    std::vector<float> elevation, temperature, moisture, pressure;
    std::vector<float> wind_x, wind_y, wind_speed, ocean_x, ocean_y, ocean_speed;
    std::vector<float> vapor_a, vapor_b, cloud_a, cloud_b, precip_a, precip_b;
    std::vector<uint8_t> climate_mask, weather_mask, terrain_mask;
    std::vector<int32_t> neighbors, pixel_to_cell;
    if (!unpack_f32(state, "elevation", saved_cells, elevation) ||
            !unpack_f32(state, "temperature", saved_cells, temperature) ||
            !unpack_f32(state, "moisture", saved_cells, moisture) ||
            !unpack_f32(state, "pressure", saved_cells, pressure) ||
            !unpack_f32(state, "wind_x", saved_cells, wind_x) ||
            !unpack_f32(state, "wind_y", saved_cells, wind_y) ||
            !unpack_f32(state, "wind_speed", saved_cells, wind_speed) ||
            !unpack_f32(state, "ocean_x", saved_cells, ocean_x) ||
            !unpack_f32(state, "ocean_y", saved_cells, ocean_y) ||
            !unpack_f32(state, "ocean_speed", saved_cells, ocean_speed) ||
            !unpack_f32(state, "weather_vapor_a", saved_cells, vapor_a) ||
            !unpack_f32(state, "weather_vapor_b", saved_cells, vapor_b) ||
            !unpack_f32(state, "weather_cloud_a", saved_cells, cloud_a) ||
            !unpack_f32(state, "weather_cloud_b", saved_cells, cloud_b) ||
            !unpack_f32(state, "weather_precip_a", saved_cells, precip_a) ||
            !unpack_f32(state, "weather_precip_b", saved_cells, precip_b) ||
            !unpack_u8(state, "climate_dirty_mask", saved_cells, climate_mask) ||
            !unpack_u8(state, "weather_dirty_mask", saved_cells, weather_mask) ||
            !unpack_u8(state, "terrain_mask", saved_cells, terrain_mask) ||
            !unpack_i32(state, "neighbor_indices", saved_cells * 6, neighbors) ||
            !unpack_i32(state, "pixel_to_cell", saved_pixels, pixel_to_cell)) {
        return restore_result(false, "environment_array_size_mismatch",
                              "Environment runtime save contains incomplete arrays.");
    }

    _elevation.swap(elevation);
    _temperature.swap(temperature);
    _moisture.swap(moisture);
    _pressure.swap(pressure);
    _wind_x.swap(wind_x);
    _wind_y.swap(wind_y);
    _wind_speed.swap(wind_speed);
    _ocean_x.swap(ocean_x);
    _ocean_y.swap(ocean_y);
    _ocean_speed.swap(ocean_speed);
    _weather_vapor_a.swap(vapor_a);
    _weather_vapor_b.swap(vapor_b);
    _weather_cloud_a.swap(cloud_a);
    _weather_cloud_b.swap(cloud_b);
    _weather_precip_a.swap(precip_a);
    _weather_precip_b.swap(precip_b);
    _climate_dirty_mask.swap(climate_mask);
    _weather_dirty_mask.swap(weather_mask);
    _terrain_mask.swap(terrain_mask);
    _neighbor_indices.swap(neighbors);
    _pixel_to_cell.swap(pixel_to_cell);
    unpack_i32_variable(state, "active_weather_indices", _active_weather_indices);
    unpack_i32_variable(state, "dirty_climate_indices", _dirty_climate_indices);
    unpack_i32_variable(state, "water_indices", _water_indices);
    unpack_i32_variable(state, "coastal_indices", _coastal_indices);
    unpack_i32_variable(state, "ocean_dirty_tiles", _ocean_dirty_tiles);

    _snapshot_version = int(state.get("snapshot_version", _snapshot_version));
    _weather_snapshot_version = int(state.get("weather_snapshot_version", _weather_snapshot_version));
    _climate_snapshot_version = int(state.get("climate_snapshot_version", _climate_snapshot_version));
    _rebuild_generation = int(state.get("rebuild_generation", _rebuild_generation));
    _all_dirty = bool(state.get("all_dirty", _all_dirty));
    _topology_valid = bool(state.get("topology_valid", _topology_valid));
    _ocean_round_active = bool(state.get("ocean_round_active", false));
    _weather_round_active = bool(state.get("weather_round_active", false));
    _climate_round_active = bool(state.get("climate_round_active", false));
    _ocean_include_raster = bool(state.get("ocean_include_raster", true));
    _ocean_dirty_tile_size = std::max(1, int(state.get("ocean_dirty_tile_size", 64)));
    _weather_use_active_list = bool(state.get("weather_use_active_list", true));
    _weather_pingpong_a_is_prev = bool(state.get("weather_pingpong_a_is_prev", true));
    _climate_use_dirty_list = bool(state.get("climate_use_dirty_list", true));
    _last_processed = int(state.get("last_processed", 0));
    _last_elapsed_ms = double(state.get("last_elapsed_ms", 0.0));
    _round_active = bool(state.get("round_active", false));
    _round_name = String(state.get("round_name", String()));
    const int saved_stage_index = int(state.get("stage_index", 0));
    // Stage layout depends on the active round. Recreate the matching stage
    // list, then restore the current cursor if it still fits.
    if (_round_name == String("ocean_native_pipeline")) {
        _build_ocean_stages(_ocean_include_raster);
    } else if (_round_name == String("weather_native_solver")) {
        _build_weather_stages(_weather_use_active_list);
    } else if (_round_name == String("climate_native_daily")) {
        _build_climate_stages(_climate_use_dirty_list);
    } else if (_round_active) {
        _build_default_stages();
    }
    _stage_index = std::max(0, std::min(saved_stage_index, (int)_stages.size()));
    PackedInt32Array stage_cursors = state.get("stage_cursors", PackedInt32Array());
    if (stage_cursors.size() != (int)_stages.size()) {
        return restore_result(false, "environment_stage_layout_mismatch",
                              "Environment runtime stage layout is incompatible.");
    }
    for (int i = 0; i < (int)_stages.size(); ++i) {
        _stages[i].cursor = std::max(0, std::min((int)stage_cursors[i], _stages[i].total));
    }
    return restore_result(true, "ok", String());
}
