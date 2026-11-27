bool DCWorldExt::bind_map_data(Object *map_data) {
    if (map_data == nullptr) {
        UtilityFunctions::push_error("[DCWorldExt] bind_map_data: null map_data");
        return false;
    }
    if (_runtime_host && (_runtime_host->state() != RuntimeWorkerState::STOPPED ||
                          !_runtime_host->execution_has_stopped())) {
        UtilityFunctions::push_error("[DCWorldExt] bind_map_data requires a stopped executor");
        return false;
    }
    clear_runtime_map_lut_frame();
    _native_daily_visual_commit_pending = false;
    _pending_mark_dirty_all = false;
    _pending_visual_dirty_mask = PackedByteArray();
    _pending_visual_dirty_count = 0;
    _pending_visual_dirty_dense = false;
    _economy_resource_slot_resident.clear();
    _natural_resource_last_day.clear();
    _natural_resource_was_live.clear();
    _natural_resource_live_mark.clear();
    // A newly bound MapData may have a different restored canal mask even
    // when the DCWorldExt object itself is reused. Force one sparse topology
    // compilation before the next hydrology pass.
    _hydrology_canal.compiled_generation = std::numeric_limits<uint64_t>::max();
    _hydrology_canal.compiled_cell_count = -1;
    _hydrology_canal.cells.clear();
    _hydrology_canal.source_kind.clear();
    _hydrology_canal.strength.clear();
    _map_data = map_data;

    int bound_count = 0;
    int auto_registered = 0;
    for (int i = 0; i < BIND_TABLE_SIZE; ++i) {
        const BindEntry &e = BIND_TABLE[i];
        StringName slot_name(e.slot_name);
        StringName prop_name(e.property_name);

        int slot_id = component_id(slot_name);
        if (slot_id < 0) {
            // ─── Auto-register on first bind (Phase 3a self-contained ECS) ─
            // Earlier contract required callers to register every slot first
            // (mirroring the GDScript verifier in tmp/test_bind_alias.gd).
            // That made DCWorldExt non-self-contained: every production call
            // site (DataCore::_setup_sus, etc.) had to keep a parallel
            // GDScript copy of BIND_TABLE in sync. We now treat BIND_TABLE
            // itself as the single source of truth: any slot listed here is
            // auto-registered with stride=1 / track_prev=false (snapshot
            // model — double buffering belongs to the pass code, not to the
            // bind layer; see docs/architecture/current-state.md).
            slot_id = register_component(slot_name,
                                         static_cast<int>(e.dtype),
                                         /*stride=*/1,
                                         /*track_prev=*/false);
            if (slot_id < 0) {
                UtilityFunctions::push_warning(
                    "[DCWorldExt] bind: auto-register failed for ", slot_name);
                continue;
            }
            ++auto_registered;
        }
        Variant v = map_data->get(prop_name);
        if (v.get_type() == Variant::NIL) {
            // property absent — non-fatal, move on
            continue;
        }
        Slot &s = _slots.write[slot_id];
        switch (e.dtype) {
            case SlotDType::F32:
                if (v.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
                    UtilityFunctions::push_warning("[DCWorldExt] bind: ", prop_name, " is not PackedFloat32Array");
                    continue;
                }
                s.arr_f32      = v;
                s.external_ref = true;
                // ─── Snapshot + flush model (NOT two-way alias) ────────────
                // GDExtension ABI reality (verified by tmp/test_bind_alias.gd
                // T1/T2 and locked into docs/architecture/current-state.md):
                //   Every PackedArray that traverses the boundary is wrapped
                //   in a Variant. By the time we hold s.arr_f32 here, refcount
                //   is ≥ 2, so any subsequent ptrw() in the C++ hot loop will
                //   CoW-detach into a private buffer. That means we can never
                //   keep a true two-way zero-copy alias with the GDScript-side
                //   property — the contract is one-way snapshots:
                //     C++ → GDScript : write-then-set() at pass end (T1b)
                //     GDScript → C++ : world.write_f32 / write_f32_indexed
                //                      between passes (NOT in-place writes)
                // The set() below pre-establishes the same GDScript-visible
                // buffer right after bind, so the very first read on the
                // GDScript side already sees C++-owned memory. Subsequent
                // hot-loop writes are flushed by the pass code itself.
                // Boundary cost: ~14 µs / bind for the full 35-component
                // table — negligible (≈ 0.04% of a daily-tick budget).
                map_data->set(prop_name, s.arr_f32);
                break;
            case SlotDType::I32:
                if (v.get_type() != Variant::PACKED_INT32_ARRAY) {
                    UtilityFunctions::push_warning("[DCWorldExt] bind: ", prop_name, " is not PackedInt32Array");
                    continue;
                }
                s.arr_i32      = v;
                s.external_ref = true;
                map_data->set(prop_name, s.arr_i32);
                break;
            case SlotDType::U8:
                if (v.get_type() != Variant::PACKED_BYTE_ARRAY) {
                    UtilityFunctions::push_warning("[DCWorldExt] bind: ", prop_name, " is not PackedByteArray");
                    continue;
                }
                s.arr_u8       = v;
                s.external_ref = true;
                map_data->set(prop_name, s.arr_u8);
                break;
        }
        ++bound_count;
    }

    _bound = (bound_count > 0);
    if (_bound) pk::bind_map_overlay_input_reader(_map_data);
    if (_bound && _runtime_host) _runtime_host->reset_day_tail_for_world_change();
    UtilityFunctions::print("[DCWorldExt] bind_map_data: ", bound_count,
                            " components bound (auto-registered=", auto_registered,
                            "; snapshot model; see world_ext.cpp comment & charter §11)");
    return _bound;
}

Dictionary DCWorldExt::configure_native_world(const Dictionary &knobs) {
    Dictionary out;
    _native_world_configured = false;
    _native_world_cell_count = 0;
    _native_daily_tick_count = 0;
    _native_daily_slice_active = false;
    _native_daily_visual_commit_pending = false;
    _pending_mark_dirty_all = false;
    _pending_visual_dirty_mask = PackedByteArray();
    _pending_visual_dirty_count = 0;
    _pending_visual_dirty_dense = false;
    _economy_resource_slot_resident.clear();
    _native_fronts_snapshot.clear();
    _native_dirty_report.clear();
    _native_runtime_config.clear();
    _phys_wind_coast_valid = false;
    _phys_wind_coast_last_hit = false;
    _phys_monsoon_thermal.clear();
    _enso_cache_valid = false;
    _enso_cache_last_hit = false;
    _enso_basin_id.clear();
    _enso_eastness.clear();
    _enso_prev_forcing.clear();
    _enso_members.clear();
    _enso_basins.clear();
    _enso_states.clear();
    _enso_wind_sum.clear();
    _enso_wind_count.clear();
    _cyclone_perturbations.clear();
    _cyclone_force_tag.clear();
    _cyclone_visit_tag.clear();
    _cyclone_force_x.clear();
    _cyclone_force_y.clear();
    _cyclone_force_lift.clear();
    _cyclone_force_generation = 0;
    _cyclone_next_stable_id = 1;
    _cyclone_last_touched_cells = 0;
    _cyclone_total_genesis = 0;
    _cyclone_total_decay = 0;
    _climate_modes_pending_restore.clear();

    if (!_bound || _map_data == nullptr) {
        out["rc"] = -1;
        out["reason"] = String("not_bound");
        return out;
    }

    _native_world_cell_count = int(knobs.get("cell_count", _entity_count));
    if (_native_world_cell_count <= 0) {
        _native_world_cell_count = _entity_count;
    }
    _native_daily_perf_target_ms = double(knobs.get("native_daily_perf_target_ms", 1.0));
    // seam-advection-fix：环绕周期常驻。GDScript 直接给 wrap_period_x；缺省时用
    // map_width·√3 重算；都拿不到则留 0 → 平流内核退化为裸差分（旧行为，接缝伪影
    // 仍在，但不改变既有调用方语义）。
    //
    // 单位是 size=1.0 的单位六边形空间，**不含 hex_size**：内核比较的是 cell_pos_x
    // slot，而它由 map_data.gd 用 cube_to_world(q, r, 1.0) 填充，列距恰为 √3/2。
    double cfg_wrap_period_x = double(knobs.get("wrap_period_x", 0.0));
    if (!(cfg_wrap_period_x > 0.0)) {
        const int cfg_map_width = int(knobs.get("map_width", 0));
        if (cfg_map_width > 0) {
            cfg_wrap_period_x = double(cfg_map_width) * 1.7320508075688772;
        }
    }
    _native_wrap_period_x = (cfg_wrap_period_x > 0.0) ? cfg_wrap_period_x : 0.0;
    _native_world_configured = true;
    _native_runtime_config = knobs.duplicate(true);
    Array resident_keys;
    Array knob_keys = knobs.keys();
    for (int i = 0; i < knob_keys.size(); ++i) {
        resident_keys.append(knob_keys[i]);
    }
    _native_runtime_config["resident_config_keys"] = resident_keys;
    _native_runtime_config["resident_config_key_count"] = resident_keys.size();
    _native_runtime_config["configured_at_tick"] = _native_daily_tick_count;

    _native_dirty_report["atlas_dirty"] = false;
    _native_dirty_report["enum_atlas_dirty"] = false;
    _native_dirty_report["sea_ice_atlas_dirty"] = false;
    _native_dirty_report["dirty_cell_count"] = 0;
    _native_dirty_report["configured_cell_count"] = _native_world_cell_count;

    out["rc"] = 0;
    out["reason"] = String("configured");
    out["cell_count"] = _native_world_cell_count;
    out["component_count"] = component_count();
    out["entity_count"] = entity_count();
    out["native_daily_perf_target_ms"] = _native_daily_perf_target_ms;
    out["wrap_period_x"] = _native_wrap_period_x;
    out["resident_config_keys"] = resident_keys;
    out["resident_config_key_count"] = resident_keys.size();
    return out;
}
