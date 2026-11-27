Dictionary DCWorldExt::begin_or_reuse_economy_input_epoch(
        int64_t day_index, const Dictionary &generation) {
    EconomyInputGeneration input_generation;
    std::string generation_error;
    if (!parse_economy_input_generation(day_index, generation,
                                        input_generation, generation_error)) {
        Dictionary out;
        out["ok"] = false;
        out["fatal"] = true;
        out["fatal_reason"] = String(generation_error.c_str());
        out["stage"] = "economy_input_generation";
        out["captured"] = false;
        out["input_capture_reused"] = false;
        out["input_capture_generation"] =
            economy_input_generation_dictionary(input_generation);
        out["input_capture_count"] = static_cast<int64_t>(_economy_capture_count);
        out["input_capture_reuse_count"] =
            static_cast<int64_t>(_economy_capture_reuse_count);
        out["path"] = "ECONOMY_GRAPH";
        return out;
    }
    const bool has_cached_generation =
        _economy_capture_cached && _economy_capture_generation_valid;
    if (has_cached_generation &&
        _economy_capture_generation == input_generation) {
        Dictionary reused = _economy_capture_cached_report;
        reused["captured"] = false;
        reused["input_capture_reused"] = true;
        reused["input_capture_generation"] =
            economy_input_generation_dictionary(input_generation);
        reused["input_capture_count"] = static_cast<int64_t>(_economy_capture_count);
        reused["input_capture_reuse_count"] = static_cast<int64_t>(
            ++_economy_capture_reuse_count);
        return reused;
    }
    Dictionary out;
    out["ok"] = false;
    out["fatal"] = false;
    out["fatal_reason"] = "";
    out["stage"] = "";
    out["captured"] = false;
    out["input_capture_reused"] = false;
    out["input_capture_generation"] =
        economy_input_generation_dictionary(input_generation);
    out["input_capture_count"] = static_cast<int64_t>(_economy_capture_count);
    out["input_capture_reuse_count"] = static_cast<int64_t>(_economy_capture_reuse_count);
    out["path"] = "ECONOMY_GRAPH";
    if (_economy_runtime == nullptr) {
        out["fatal"] = true;
        out["fatal_reason"] = "economy_not_configured";
        out["stage"] = "capture_economy_day_inputs";
        return out;
    }
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    const bool epoch_active = runtime->epoch_active();
    const bool force_full = _economy_capture_force_full;
    const bool sample_day_changed = !has_cached_generation ||
        _economy_capture_generation.sample_day != input_generation.sample_day;
    const bool map_generation_changed = !has_cached_generation ||
        _economy_capture_generation.map_generation != input_generation.map_generation;
    const bool building_generation_changed = !has_cached_generation ||
        _economy_capture_generation.building_generation !=
            input_generation.building_generation;
    const bool resource_generation_changed = !has_cached_generation ||
        _economy_capture_generation.resource_generation !=
            input_generation.resource_generation;
    // Country and epoch generations identify the frozen workset but do not
    // change the MapData lanes captured by this boundary. They can therefore
    // re-key the cache without rewriting an active epoch's inputs.
    const bool capture_topology = !epoch_active &&
        (force_full || !has_cached_generation || map_generation_changed);
    const bool capture_environment = !epoch_active &&
        (force_full || runtime->needs_environment_capture(day_index) ||
         !has_cached_generation || sample_day_changed || map_generation_changed);
    const bool capture_building = !epoch_active &&
        (force_full || runtime->needs_building_context_capture(day_index) ||
         !has_cached_generation || sample_day_changed || map_generation_changed ||
         building_generation_changed || resource_generation_changed);
    bool captured_any = false;
    if (capture_topology && _map_data != nullptr &&
        _map_data->has_method(StringName("neighbor_indices_packed")) &&
        _map_data->has_method(StringName("economy_trade_passable_lut")) &&
        _map_data->has_method(StringName("economy_trade_move_cost_lut"))) {
        // Trade routes follow the generated geography, not the climate-owned
        // dynamic terrain lane.  In particular, seasonal sea-ice flips must
        // not invalidate and rebuild the route plan every economy cycle.
        const int terrain_sid = component_id(StringName("cell_base_terrain"));
        const int landform_sid = component_id(StringName("cell_base_landform"));
        const int river_sid = component_id(StringName("cell_has_river"));
        const int canal_mask_sid = component_id(StringName("cell_canal_edge_mask"));
        const int canal_water_sid = component_id(StringName("cell_canal_water"));
        const Variant neighbor_variant = _map_data->call(
            StringName("neighbor_indices_packed"));
        const Variant passable_variant = _map_data->call(
            StringName("economy_trade_passable_lut"));
        const Variant cost_variant = _map_data->call(
            StringName("economy_trade_move_cost_lut"));
        if (terrain_sid >= 0 && terrain_sid < _slots.size() &&
            canal_mask_sid >= 0 && canal_mask_sid < _slots.size() &&
            canal_water_sid >= 0 && canal_water_sid < _slots.size() &&
            _slots[terrain_sid].dtype == SlotDType::U8 &&
            _slots[canal_mask_sid].dtype == SlotDType::U8 &&
            _slots[canal_water_sid].dtype == SlotDType::F32 &&
            neighbor_variant.get_type() == Variant::PACKED_INT32_ARRAY &&
            passable_variant.get_type() == Variant::PACKED_BYTE_ARRAY &&
            cost_variant.get_type() == Variant::PACKED_INT32_ARRAY) {
            const PackedInt32Array neighbors = neighbor_variant;
            const PackedByteArray passable = passable_variant;
            const PackedInt32Array costs = cost_variant;
            const int32_t count = _slots[terrain_sid].arr_u8.size();
            const uint8_t *landform_ptr = nullptr;
            const uint8_t *has_river_ptr = nullptr;
            if (landform_sid >= 0 && landform_sid < _slots.size() &&
                _slots[landform_sid].dtype == SlotDType::U8 &&
                _slots[landform_sid].arr_u8.size() == count)
                landform_ptr = _slots[landform_sid].arr_u8.ptr();
            if (river_sid >= 0 && river_sid < _slots.size() &&
                _slots[river_sid].dtype == SlotDType::U8 &&
                _slots[river_sid].arr_u8.size() == count)
                has_river_ptr = _slots[river_sid].arr_u8.ptr();
            if (neighbors.size() == count * 6 && passable.size() == 256 &&
                costs.size() == 256) {
                std::string topology_error;
                if (!runtime->capture_trade_topology(neighbors.ptr(),
                        _slots[terrain_sid].arr_u8.ptr(),
                        _slots[canal_mask_sid].arr_u8.ptr(),
                        _slots[canal_water_sid].arr_f32.ptr(),
                        passable.ptr(), costs.ptr(),
                        count, 0, topology_error, landform_ptr, has_river_ptr)) {
                    out["fatal"] = true;
                    out["path"] = "ECONOMY_GRAPH";
                    out["stage"] = "trade_topology_snapshot";
                    out["fatal_reason"] = String(topology_error.c_str());
                    return out;
                }
                captured_any = true;
                if (_canal_topology_generation == 0) {
                    const PackedByteArray &mask = _slots[canal_mask_sid].arr_u8;
                    for (int32_t cell = 0; cell < mask.size(); ++cell) {
                        if ((mask[cell] & 0x3fU) != 0)
                            _canal_visual_dirty_cells.push_back(cell);
                    }
                    _canal_topology_generation = 1;
                }
            }
        }
    }
    if (capture_environment) {
        const int sid_temp = component_id(StringName("cell_temp"));
        const int sid_temp_30d = component_id(StringName("cell_temp_30d"));
        const int sid_moisture = component_id(StringName("cell_moisture"));
        const int sid_plant_water = component_id(StringName("cell_plant_available_water"));
        const int sid_precip = component_id(StringName("cell_weather_precip"));
        const int sid_snow = component_id(StringName("cell_snow_cover"));
        const int sid_weather = component_id(StringName("cell_weather_intensity"));
        const int sid_temp_365d = component_id(StringName("cell_temp_365d"));
        const int sid_weather_type = component_id(StringName("cell_weather_type"));
        const int sid_cover = component_id(StringName("cell_cover"));
        auto valid_f32 = [&](int sid) {
            return sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::F32;
        };
        auto valid_u8 = [&](int sid) {
            return sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::U8;
        };
        if (!valid_f32(sid_temp) || !valid_f32(sid_temp_30d) ||
            !valid_f32(sid_moisture) || !valid_f32(sid_plant_water) || !valid_f32(sid_snow) ||
            !valid_f32(sid_precip) || !valid_f32(sid_weather) ||
            !valid_f32(sid_temp_365d) || !valid_u8(sid_weather_type) ||
            !valid_u8(sid_cover)) {
            out["fatal"] = true;
            out["path"] = "ECONOMY_GRAPH";
            out["stage"] = "environment_snapshot";
            out["fatal_reason"] = "required_environment_slot_missing";
            return out;
        }
        const int32_t count = _slots[sid_temp].arr_f32.size();
        if (_slots[sid_temp_30d].arr_f32.size() != count ||
            _slots[sid_moisture].arr_f32.size() != count ||
            _slots[sid_plant_water].arr_f32.size() != count ||
            _slots[sid_precip].arr_f32.size() != count ||
            _slots[sid_snow].arr_f32.size() != count ||
            _slots[sid_weather].arr_f32.size() != count ||
            _slots[sid_temp_365d].arr_f32.size() != count ||
            _slots[sid_weather_type].arr_u8.size() != count ||
            _slots[sid_cover].arr_u8.size() != count) {
            out["fatal"] = true;
            out["path"] = "ECONOMY_GRAPH";
            out["stage"] = "environment_snapshot";
            out["fatal_reason"] = "environment_slot_size_mismatch";
            return out;
        }
        std::string error;
        if (!runtime->capture_environment(day_index,
                                          _slots[sid_temp].arr_f32.ptr(),
                                          _slots[sid_temp_30d].arr_f32.ptr(),
                                          _slots[sid_moisture].arr_f32.ptr(),
                                          _slots[sid_plant_water].arr_f32.ptr(),
                                          _slots[sid_precip].arr_f32.ptr(),
                                          _slots[sid_snow].arr_f32.ptr(),
                                          _slots[sid_weather].arr_f32.ptr(),
                                          _slots[sid_temp_365d].arr_f32.ptr(),
                                          _slots[sid_weather_type].arr_u8.ptr(),
                                          _slots[sid_cover].arr_u8.ptr(),
                                          count, error)) {
            out["fatal"] = true;
            out["path"] = "ECONOMY_GRAPH";
            out["stage"] = "environment_snapshot";
            out["fatal_reason"] = String(error.c_str());
            return out;
        }
        captured_any = true;
        bool fog_solved = false;
        PackedByteArray visible_bytes;
        const uint8_t *visible_ptr = nullptr;
        int32_t visible_count = 0;
        if (_map_data != nullptr) {
            const Variant fog_variant = _map_data->get(StringName("fog_solved"));
            fog_solved = fog_variant.get_type() == Variant::BOOL &&
                static_cast<bool>(fog_variant);
            if (fog_solved) {
                const Variant visible_variant =
                    _map_data->get(StringName("physical_visible_arr"));
                if (visible_variant.get_type() == Variant::PACKED_BYTE_ARRAY) {
                    visible_bytes = visible_variant;
                    visible_ptr = visible_bytes.ptr();
                    visible_count = visible_bytes.size();
                }
            }
        }
        if (fog_solved || !runtime->trade_visibility_manual()) {
            std::string vis_error;
            if (!runtime->capture_trade_visibility(visible_ptr, visible_count,
                    fog_solved, true, vis_error)) {
                out["fatal"] = true;
                out["path"] = "ECONOMY_GRAPH";
                out["stage"] = "trade_visibility_snapshot";
                out["fatal_reason"] = String(vis_error.c_str());
                return out;
            }
            captured_any = true;
        }
    }
    if (capture_building) {
        auto f32_ptr = [&](const char *name) -> const float * {
            const int sid = component_id(StringName(name));
            return sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::F32 &&
                   _slots[sid].arr_f32.size() == _slots[component_id(StringName("cell_temp"))].arr_f32.size()
                       ? _slots[sid].arr_f32.ptr() : nullptr;
        };
        auto u8_ptr = [&](const char *name) -> const uint8_t * {
            const int sid = component_id(StringName(name));
            return sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::U8 &&
                   _slots[sid].arr_u8.size() == _slots[component_id(StringName("cell_temp"))].arr_f32.size()
                       ? _slots[sid].arr_u8.ptr() : nullptr;
        };
        std::vector<const float *> resources;
        std::vector<const float *> resource_changes;
        for (size_t r = 0; r < runtime->building_resource_reserve_slots().size(); ++r) {
            const float *reserve = f32_ptr(runtime->building_resource_reserve_slots()[r].c_str());
            const float *extra = f32_ptr(runtime->building_resource_extra_slots()[r].c_str());
            if (reserve != nullptr && extra == nullptr) {
                out["fatal"] = true;
                out["path"] = "BUILDING_GRAPH";
                out["stage"] = "building_context_snapshot";
                out["fatal_reason"] = "building_resource_extra_slot_missing";
                return out;
            }
            resources.push_back(reserve);
            resource_changes.push_back(extra);
        }
        const int temp_sid = component_id(StringName("cell_temp"));
        const int32_t count = temp_sid >= 0 && temp_sid < _slots.size()
            ? _slots[temp_sid].arr_f32.size() : 0;
        PackedInt32Array neighbor_indices;
        if (_map_data != nullptr && _map_data->has_method(StringName("neighbor_indices_packed"))) {
            const Variant neighbors = _map_data->call(StringName("neighbor_indices_packed"));
            if (neighbors.get_type() == Variant::PACKED_INT32_ARRAY) {
                neighbor_indices = neighbors;
            }
        }
        const int32_t *neighbor_ptr = neighbor_indices.size() == count * 6
            ? neighbor_indices.ptr() : nullptr;
        std::string error;
        if (!runtime->capture_building_context(
                day_index, f32_ptr("cell_elevation"), u8_ptr("cell_terrain"),
                u8_ptr("cell_landform"), u8_ptr("cell_vegetation"),
                u8_ptr("cell_is_water"), u8_ptr("cell_has_river"), neighbor_ptr, resources,
                resource_changes,
                count, error)) {
            out["fatal"] = true;
            out["path"] = "BUILDING_GRAPH";
            out["stage"] = "building_context_snapshot";
            out["fatal_reason"] = String(error.c_str());
            return out;
        }
        captured_any = true;
    }
    out["ok"] = true;
    out["captured"] = captured_any;
    out["stage"] = captured_any ? "economy_day_inputs" : "economy_day_inputs_idle";
    // A country/epoch-only change can legitimately leave the input arrays
    // untouched. Once the runtime is outside an active epoch, remember the
    // new complete key so subsequent slices do not repeatedly miss the cache.
    const bool can_cache_key = !epoch_active &&
        (captured_any || (!runtime->needs_environment_capture(day_index) &&
                          !runtime->needs_building_context_capture(day_index)));
    if (can_cache_key) {
        _economy_capture_generation = input_generation;
        _economy_capture_generation_valid = true;
        _economy_capture_cached = true;
        if (captured_any) {
            ++_economy_capture_count;
            _economy_capture_force_full = false;
        }
    }
    out["input_capture_count"] = static_cast<int64_t>(_economy_capture_count);
    out["input_capture_reuse_count"] = static_cast<int64_t>(_economy_capture_reuse_count);
    if (can_cache_key)
        _economy_capture_cached_report = out;
    return out;
}

Dictionary DCWorldExt::run_economy_slice_internal(const Dictionary &ctx, bool compact) {
    std::unique_lock<std::mutex> execution_boundary;
    if (_runtime_host != nullptr) {
        execution_boundary = _runtime_host->try_lock_economy_input_capture();
        if (!execution_boundary.owns_lock() || _runtime_host->economy_worker_owns_execution()) {
            Dictionary pending;
            pending["ok"] = true;
            pending["done"] = false;
            pending["fatal"] = false;
            pending["pending_input"] = true;
            pending["yield_reason"] = "economy_worker_execution_owned";
            pending["work_done"] = int64_t{0};
            return pending;
        }
    }
    if (_economy_runtime == nullptr) {
        Dictionary out = unavailable();
        out["done"] = true;
        out["path"] = "ECONOMY_GRAPH";
        out["mode"] = "native";
        return out;
    }
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    const int64_t day_index = ctx.has("day_index") ? static_cast<int64_t>(ctx["day_index"]) : 0;
    Dictionary input_generation;
    if (ctx.has("input_generation")) {
        const Variant raw_generation = ctx.get("input_generation", Variant());
        if (raw_generation.get_type() != Variant::DICTIONARY) {
            Dictionary out;
            out["ok"] = false;
            out["done"] = true;
            out["fatal"] = true;
            out["path"] = "ECONOMY_GRAPH";
            out["stage"] = "economy_input_generation";
            out["fatal_reason"] = "economy_input_generation_not_dictionary";
            out["mode"] = "native";
            return out;
        }
        input_generation = raw_generation;
    }
    const Dictionary cap = begin_or_reuse_economy_input_epoch(
        day_index, input_generation);
    if (bool(cap.get("fatal", false))) {
        Dictionary out;
        out["ok"] = false;
        out["done"] = true;
        out["fatal"] = true;
        out["path"] = String(cap.get("path", "ECONOMY_GRAPH"));
        out["stage"] = String(cap.get("stage", "economy_day_inputs"));
        out["fatal_reason"] = String(cap.get("fatal_reason", "economy_day_input_capture_failed"));
        out["mode"] = "native";
        return out;
    }
    Dictionary result = compact
        ? runtime->run_slice_compact(ctx)
        : runtime->run_slice(ctx);
    result["input_capture_reused"] = cap.get("input_capture_reused", false);
    result["input_capture_generation"] = cap.get(
        "input_capture_generation", Dictionary());
    result["input_capture_count"] = cap.get("input_capture_count", int64_t{0});
    result["input_capture_reuse_count"] = cap.get(
        "input_capture_reuse_count", int64_t{0});
    result["input_captured"] = cap.get("captured", false);
    result["published_to_slot"] = false;
    double resource_flush_ms = 0.0;
    double csv_capture_ms = 0.0;
    double gameplay_publish_ms = 0.0;
    double event_publish_ms = 0.0;
    const auto resource_flush_started = BridgeClock::now();
    std::vector<size_t> resource_delta_lanes;
    std::vector<int64_t> resource_deltas;
    // Resource MapData mirror is deferred until AGGREGATE_PUBLISH sets
    // _resource_deltas_ready. Incomplete slices never flush half-built deltas.
    if (runtime->drain_building_resource_deltas(
            resource_delta_lanes, resource_deltas)) {
        const int32_t count = runtime->cell_count();
        const auto &extra_slots = runtime->building_resource_extra_slots();
        std::vector<int32_t> slot_ids(extra_slots.size(), -1);
        for (size_t r = 0; r < extra_slots.size(); ++r)
            slot_ids[r] = component_id(StringName(extra_slots[r].c_str()));
        if (_economy_resource_slot_resident.size() < _slots.size())
            _economy_resource_slot_resident.resize(_slots.size(), 0);
        int64_t changed = 0;
        int32_t resident_slots = 0;
        for (size_t cursor = 0; cursor < resource_delta_lanes.size(); ++cursor) {
            const size_t flat = resource_delta_lanes[cursor];
            const size_t r = count > 0 ? flat / static_cast<size_t>(count) : 0;
            if (count <= 0 || r >= extra_slots.size()) continue;
            const int sid = slot_ids[r];
            if (sid < 0 || sid >= _slots.size() || _slots[sid].dtype != SlotDType::F32 ||
                _slots[sid].arr_f32.size() != count) continue;
            Slot &slot = _slots.write[sid];
            float *dst = slot.arr_f32.ptrw();
            const int32_t cell = static_cast<int32_t>(
                flat % static_cast<size_t>(count));
            dst[cell] += static_cast<float>(resource_deltas[cursor]) /
                         static_cast<float>(NativeEconomyRuntime::GOODS_SCALE);
            if (_economy_resource_slot_resident[static_cast<size_t>(sid)] == 0) {
                _economy_resource_slot_resident[static_cast<size_t>(sid)] = 1;
                ++resident_slots;
            }
            ++changed;
        }
        result["building_resource_delta_cells"] = changed;
        result["building_resource_resident_slots"] = resident_slots;
        result["building_resource_mirror_deferred"] = resident_slots > 0;
        result["building_resource_mirror_committed"] = true;
        result["published_to_slot"] = changed > 0;
    } else {
        result["building_resource_mirror_committed"] = false;
    }
    resource_flush_ms = bridge_elapsed_ms(resource_flush_started);
    // The recorder observes only a fully published epoch. Resource slots have
    // already received building deltas above, so all five tables share one
    // committed boundary.
    const auto csv_capture_started = BridgeClock::now();
    if (_economy_csv_recorder != nullptr) {
        EconomyCsvRecorder *recorder =
            static_cast<EconomyCsvRecorder *>(_economy_csv_recorder);
        if (recorder->wants_capture()) {
            std::vector<const float *> resource_arrays;
            resource_arrays.reserve(recorder->resource_slot_ids().size());
            for (int32_t sid : recorder->resource_slot_ids()) {
                const bool valid = sid >= 0 && sid < _slots.size() &&
                    _slots[sid].dtype == SlotDType::F32 &&
                    _slots[sid].arr_f32.size() == recorder->configured_cell_count();
                resource_arrays.push_back(valid ? _slots[sid].arr_f32.ptr() : nullptr);
            }
            std::string capture_reason;
            const bool captured = recorder->capture_committed(
                *runtime, resource_arrays, capture_reason);
            result["economy_csv_captured"] = captured;
            if (!capture_reason.empty())
                result["economy_csv_capture_reason"] = String(capture_reason.c_str());
        }
    }
    csv_capture_ms = bridge_elapsed_ms(csv_capture_started);
    const int64_t newest_event_id = static_cast<int64_t>(
        result.get("economy_event_newest_id", int64_t{0}));
    const auto gameplay_publish_started = BridgeClock::now();
    std::vector<NativeEconomyRuntime::CommittedGameplayFact> gameplay_facts;
    if (runtime->drain_committed_gameplay_facts(gameplay_facts)) {
        int32_t published_facts = 0;
        for (NativeEconomyRuntime::CommittedGameplayFact &fact : gameplay_facts) {
            int32_t event_type = 0;
            int32_t payload_schema = 0;
            if (!NativeEconomyRuntime::gameplay_fact_event(fact.kind, event_type,
                                                           payload_schema))
                continue;
            if (_emit_gameplay_event(day_index, 9, event_type, 1, fact.flags,
                    fact.entity_handle, fact.entity_id, fact.cell, payload_schema,
                    fact.value, fact.payload[0], fact.payload[1], fact.payload[2],
                    fact.payload[3]) > 0) {
                ++published_facts;
            }
        }
        result["economy_gameplay_facts_published"] = published_facts;
    }
    gameplay_publish_ms = bridge_elapsed_ms(gameplay_publish_started);
    const auto event_publish_started = BridgeClock::now();
    if (static_cast<bool>(result.get("done", false)) &&
        newest_event_id > _economy_last_notified_event_id) {
        const int32_t epoch = static_cast<int32_t>(std::clamp<int64_t>(
            static_cast<int64_t>(result.get("epoch_id", int64_t{0})),
            0, std::numeric_limits<int32_t>::max()));
        const int32_t newest = static_cast<int32_t>(std::clamp<int64_t>(
            newest_event_id, 0, std::numeric_limits<int32_t>::max()));
        const int32_t count = static_cast<int32_t>(std::clamp<int64_t>(
            static_cast<int64_t>(result.get("economy_event_last_batch_count", int64_t{0})),
            0, std::numeric_limits<int32_t>::max()));
        _emit_gameplay_event(day_index, 9, 5, 1, 0, 0, -1, -1, 2,
                             count, epoch, newest, count, 0);
        _economy_last_notified_event_id = newest_event_id;
        result["economy_event_batch_published"] = true;
    }
    event_publish_ms = bridge_elapsed_ms(event_publish_started);
    if (String(result.get("executed_stage", "")) == "aggregate_publish") {
        result["world_resource_flush_ms"] = resource_flush_ms;
        result["world_csv_capture_ms"] = csv_capture_ms;
        result["world_gameplay_publish_ms"] = gameplay_publish_ms;
        result["world_event_publish_ms"] = event_publish_ms;
    }
    return result;
}

bool DCWorldExt::economy_should_run(int64_t day_index) const {
    // Suppress main-thread production only when the worker both owns ECONOMY
    // and has an attached production runtime. Fail open to sync otherwise so a
    // missing attach cannot freeze the economy.
    if (_runtime_host != nullptr &&
        _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY) &&
        _runtime_host->economy_production_runtime_attached()) {
        return false;
    }
    return _economy_runtime != nullptr &&
           runtime_from(_economy_runtime)->should_run(day_index);
}

bool DCWorldExt::economy_deadline_critical(int64_t day_index) const {
    return _economy_runtime != nullptr &&
           runtime_from(_economy_runtime)->deadline_critical(day_index);
}
