Dictionary DCWorldExt::run_bio_occupancy_slice(const Dictionary &knobs) {
    const auto total_started = std::chrono::steady_clock::now();
    const auto elapsed_ms = [](const auto &started) -> double {
        return std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
    };
    Dictionary out;
    out["ok"] = false;
    const int n = int(knobs.get("cell_count", 0));
    const int seed = int(knobs.get("seed", 0));
    const int day_index = int(knobs.get("day_index", 0));
    const bool run_diffusion = bool(knobs.get("run_diffusion", false));
    const int requested_slice_cells = int(knobs.get("bio_slice_cells", 1024));
    const int slice_cells = std::clamp(requested_slice_cells, 64, 32768);
    auto fail = [&](const String &reason, const char *stage) {
        out["reason"] = reason;
        out["fallback_reason"] = reason;
        out["fail_stage"] = String(stage);
        out["path"] = String("gdext_sliced_failed");
        if (_bio_occupancy_slice_state != nullptr) {
            destroy_bio_occupancy_slice_state(_bio_occupancy_slice_state);
            _bio_occupancy_slice_state = nullptr;
        }
        return out;
    };
    BioOccupancySliceState *state =
        static_cast<BioOccupancySliceState *>(_bio_occupancy_slice_state);
    if (n <= 0 || n > 1000000)
        return fail(String("bio_occupancy_cell_count_invalid"), "validate");
    const bool new_state = state == nullptr || state->n != n ||
        state->seed != seed || state->day_index != day_index ||
        state->run_diffusion != run_diffusion;
    const auto bridge_started = std::chrono::steady_clock::now();
    if (new_state) {
        if (state != nullptr) {
            destroy_bio_occupancy_slice_state(state);
            state = nullptr;
            _bio_occupancy_slice_state = nullptr;
        }
        state = new BioOccupancySliceState();
        state->n = n;
        state->seed = seed;
        state->day_index = day_index;
        state->run_diffusion = run_diffusion;
        BioNativeConfigState *native_config =
            static_cast<BioNativeConfigState *>(_bio_native_config_state);
        state->slot_mode = bool(knobs.get("use_configured_slots", false)) &&
            native_config != nullptr && native_config->cell_count == n;
        PackedInt32Array occupancy;
        if (state->slot_mode) {
            state->water = _slots[native_config->water_slot].arr_u8;
            state->veg = _slots[native_config->vegetation_slot].arr_u8;
            state->lf = _slots[native_config->landform_slot].arr_u8;
            state->river = _slots[native_config->river_slot].arr_u8;
            state->temp = _slots[native_config->temperature_slot].arr_f32;
            state->moist = _slots[native_config->moisture_slot].arr_f32;
            state->elev = _slots[native_config->elevation_slot].arr_f32;
            state->province = _slots[native_config->province_slot].arr_i32;
            state->neighbors = native_config->neighbors;
            state->occupancy_slot_id = native_config->occupancy_slot;
            occupancy = _slots[state->occupancy_slot_id].arr_i32;
            state->species = native_config->species;
            state->reserves.reserve(native_config->reserve_slot_ids.size());
            for (int32_t slot_id : native_config->reserve_slot_ids)
                state->reserves.push_back(_slots[slot_id].arr_f32);
        } else {
            state->water = knobs.get("is_water", PackedByteArray());
            state->veg = knobs.get("vegetation", PackedByteArray());
            state->lf = knobs.get("landform", PackedByteArray());
            state->river = knobs.get("has_river", PackedByteArray());
            state->temp = knobs.get("temperature", PackedFloat32Array());
            state->moist = knobs.get("moisture", PackedFloat32Array());
            state->elev = knobs.get("elevation", PackedFloat32Array());
            state->province = knobs.get("province_ids", PackedInt32Array());
            state->neighbors = knobs.get("neighbor_indices", PackedInt32Array());
            occupancy = knobs.get("occupancy_bits", PackedInt32Array());
        }
        if (state->water.size() != n || state->veg.size() != n ||
            state->lf.size() != n || state->river.size() != n ||
            state->temp.size() != n || state->moist.size() != n ||
            state->elev.size() != n || state->province.size() != n ||
            state->neighbors.size() != n * 6 || occupancy.size() != n) {
            return fail(String("bio_occupancy_input_shape_invalid"), "validate");
        }
        String reason;
        if (!state->slot_mode) {
            if (!load_species(knobs, state->species, reason))
                return fail(reason, "species");
            if (!load_reserve_columns(knobs, n, state->species.count,
                                      state->species, state->reserves, reason))
                return fail(reason, "reserve");
        } else {
            for (const PackedFloat32Array &reserve : state->reserves) {
                if (reserve.size() != n)
                    return fail(String("bio_configured_reserve_shape_invalid"), "reserve");
            }
        }
        state->introduce_cells = knobs.get("introduce_cells", PackedInt32Array());
        state->introduce_bits = knobs.get("introduce_bits", PackedInt32Array());
        if (state->introduce_cells.size() != state->introduce_bits.size())
            return fail(String("bio_introduce_shape_invalid"), "validate");

        copy_packed(occupancy, state->previous);
        state->begin();
        state->bridge_ms = elapsed_ms(bridge_started);
        _bio_occupancy_slice_state = state;
    }

    const auto compute_started = std::chrono::steady_clock::now();
    const int start = state->cursor;
    const int end = std::min(n, start + slice_cells);
    const auto inputs = freeze_bio_inputs(*state);
    advance_bio_slice(state, inputs, slice_cells);

    const bool done = state->phase == 3 && state->cursor >= n;
    const double compute_ms = elapsed_ms(compute_started);
    out["ok"] = true;
    out["path"] = "gdext_sliced";
    out["done"] = done;
    out["slice_done"] = done;
    out["slice_phase"] = state->phase;
    out["slice_cursor"] = state->cursor;
    out["slice_cursor_start"] = start;
    out["slice_cursor_end"] = end;
    out["slice_cursor_total"] = n;
    out["processed_cells"] = end - start;
    out["native_compute_ms"] = compute_ms;
    out["bio_slice_native_ms"] = compute_ms;
    out["bridge_ms"] = new_state ? state->bridge_ms : 0.0;
    out["publish_ms"] = 0.0;
    out["bio_slice_publish_ms"] = 0.0;
    out["native_ms"] = elapsed_ms(total_started);
    out["published_to_slot"] = false;
    out["slice_enabled"] = true;
    out["progress_ratio"] = done ? 1.0 :
        float(state->phase * n + state->cursor) / float(4 * n);
    if (!done) return out;

    const auto publish_started = std::chrono::steady_clock::now();
    PackedInt32Array occupancy_out;
    if (state->slot_mode) {
        int32_t *occupancy_slot_ptr =
            _slots.write[state->occupancy_slot_id].arr_i32.ptrw();
        std::memcpy(occupancy_slot_ptr, state->output.data(),
                    static_cast<size_t>(n) * sizeof(int32_t));
        _flush_slot_to_map(state->occupancy_slot_id);
    } else {
        occupancy_out.resize(n);
        std::memcpy(occupancy_out.ptrw(), state->output.data(),
                    static_cast<size_t>(n) * sizeof(int32_t));
    }
    PackedInt32Array newly_cells;
    PackedInt32Array newly_signals;
    newly_cells.resize(static_cast<int64_t>(state->newly_cells.size()));
    newly_signals.resize(static_cast<int64_t>(state->newly_signals.size()));
    for (size_t i = 0; i < state->newly_cells.size(); ++i) {
        newly_cells.ptrw()[i] = state->newly_cells[i];
        newly_signals.ptrw()[i] = state->newly_signals[i];
    }
    const double publish_ms = elapsed_ms(publish_started);
    if (!state->slot_mode) out["occupancy_bits"] = occupancy_out;
    out["newly_occupied_cells"] = newly_cells;
    out["newly_occupied_signal_ids"] = newly_signals;
    out["publish_ms"] = publish_ms;
    out["bio_slice_publish_ms"] = publish_ms;
    out["native_ms"] = elapsed_ms(total_started);
    out["published_to_slot"] = state->slot_mode;
    out["configured_slot_fastpath"] = state->slot_mode;
    const int64_t observation_handle = int64_t(
        knobs.get("observation_country_handle", int64_t(0)));
    if (observation_handle != 0) {
        const Dictionary evidence = _queue_bio_observations(
            observation_handle,
            int64_t(knobs.get("observation_effective_day", int64_t(0))),
            newly_cells, newly_signals);
        out["native_evidence_submission"] = bool(evidence.get("ok", false));
        out["native_evidence_submitted"] = int64_t(evidence.get("submitted", 0));
    }
    destroy_bio_occupancy_slice_state(state);
    _bio_occupancy_slice_state = nullptr;
    return out;
}

Dictionary DCWorldExt::run_bio_occupancy_pass(const Dictionary &knobs) {
    if (_bio_occupancy_slice_state != nullptr) {
        destroy_bio_occupancy_slice_state(_bio_occupancy_slice_state);
        _bio_occupancy_slice_state = nullptr;
    }
    const auto total_started = std::chrono::steady_clock::now();
    const auto elapsed_ms = [](const auto &started) -> double {
        return std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
    };
    const auto bridge_started = std::chrono::steady_clock::now();
    Dictionary out;
    out["ok"] = false;
    const int n = int(knobs.get("cell_count", 0));
    const int seed = int(knobs.get("seed", 0));
    const int day_index = int(knobs.get("day_index", 0));
    const bool run_diffusion = bool(knobs.get("run_diffusion", false));
    if (n <= 0 || n > 1000000) {
        out["reason"] = String("bio_occupancy_cell_count_invalid");
        return out;
    }
    BioNativeConfigState *native_config =
        static_cast<BioNativeConfigState *>(_bio_native_config_state);
    const bool slot_mode = bool(knobs.get("use_configured_slots", false)) &&
        native_config != nullptr && native_config->cell_count == n;
    PackedByteArray water_arr;
    PackedByteArray veg_arr;
    PackedByteArray lf_arr;
    PackedByteArray river_arr;
    PackedFloat32Array temp_arr;
    PackedFloat32Array moist_arr;
    PackedFloat32Array elev_arr;
    PackedInt32Array province_arr;
    PackedInt32Array neighbors;
    PackedInt32Array occupancy;
    SpeciesView legacy_species;
    const SpeciesView *species_view = nullptr;
    std::vector<PackedFloat32Array> reserves;
    int32_t occupancy_slot_id = -1;
    if (slot_mode) {
        water_arr = _slots[native_config->water_slot].arr_u8;
        veg_arr = _slots[native_config->vegetation_slot].arr_u8;
        lf_arr = _slots[native_config->landform_slot].arr_u8;
        river_arr = _slots[native_config->river_slot].arr_u8;
        temp_arr = _slots[native_config->temperature_slot].arr_f32;
        moist_arr = _slots[native_config->moisture_slot].arr_f32;
        elev_arr = _slots[native_config->elevation_slot].arr_f32;
        province_arr = _slots[native_config->province_slot].arr_i32;
        neighbors = native_config->neighbors;
        occupancy_slot_id = native_config->occupancy_slot;
        occupancy = _slots[occupancy_slot_id].arr_i32;
        species_view = &native_config->species;
        reserves.reserve(native_config->reserve_slot_ids.size());
        for (int32_t slot_id : native_config->reserve_slot_ids)
            reserves.push_back(_slots[slot_id].arr_f32);
    } else {
        water_arr = knobs.get("is_water", PackedByteArray());
        veg_arr = knobs.get("vegetation", PackedByteArray());
        lf_arr = knobs.get("landform", PackedByteArray());
        river_arr = knobs.get("has_river", PackedByteArray());
        temp_arr = knobs.get("temperature", PackedFloat32Array());
        moist_arr = knobs.get("moisture", PackedFloat32Array());
        elev_arr = knobs.get("elevation", PackedFloat32Array());
        province_arr = knobs.get("province_ids", PackedInt32Array());
        neighbors = knobs.get("neighbor_indices", PackedInt32Array());
        occupancy = knobs.get("occupancy_bits", PackedInt32Array());
    }
    if (water_arr.size() != n || veg_arr.size() != n || lf_arr.size() != n ||
        river_arr.size() != n || temp_arr.size() != n || moist_arr.size() != n ||
        elev_arr.size() != n || province_arr.size() != n || neighbors.size() != n * 6 ||
        occupancy.size() != n) {
        out["reason"] = String("bio_occupancy_input_shape_invalid");
        return out;
    }
    String reason;
    if (!slot_mode) {
        if (!load_species(knobs, legacy_species, reason)) {
            out["reason"] = reason;
            return out;
        }
        species_view = &legacy_species;
        if (!load_reserve_columns(knobs, n, legacy_species.count,
                                  legacy_species, reserves, reason)) {
            out["reason"] = reason;
            return out;
        }
    } else {
        for (const PackedFloat32Array &reserve : reserves) {
            if (reserve.size() != n) {
                out["reason"] = String("bio_configured_reserve_shape_invalid");
                return out;
            }
        }
    }
    const SpeciesView &sp = *species_view;
    PackedInt32Array intro_cells = knobs.get("introduce_cells", PackedInt32Array());
    PackedInt32Array intro_bits = knobs.get("introduce_bits", PackedInt32Array());
    if (intro_cells.size() != intro_bits.size()) {
        out["reason"] = String("bio_introduce_shape_invalid");
        return out;
    }

    const double bridge_ms = elapsed_ms(bridge_started);

    const uint8_t *water = water_arr.ptr();
    const uint8_t *veg = veg_arr.ptr();
    const uint8_t *lf = lf_arr.ptr();
    const uint8_t *river = river_arr.ptr();
    const float *temp = temp_arr.ptr();
    const float *moist = moist_arr.ptr();
    const float *elev = elev_arr.ptr();
    const int32_t *province = province_arr.ptr();
    const int32_t *nb = neighbors.ptr();
    const auto compute_started = std::chrono::steady_clock::now();
    _bio_occupancy_bits_staging.resize(static_cast<size_t>(n));
    _bio_occupancy_previous.resize(static_cast<size_t>(n));
    for (int cell = 0; cell < n; ++cell) {
        const int32_t value = occupancy[cell];
        _bio_occupancy_bits_staging[static_cast<size_t>(cell)] = value;
        _bio_occupancy_previous[static_cast<size_t>(cell)] = value;
    }

    auto persistence_range = [&](int begin, int end) {
        for (int cell = begin; cell < end; ++cell) {
            int32_t bits = _bio_occupancy_bits_staging[static_cast<size_t>(cell)];
            if (bits == 0) continue;
            uint32_t scan = static_cast<uint32_t>(bits);
            while (scan != 0u) {
                const int32_t bit = lowest_bit_index(scan);
                scan &= scan - 1u;
                const int32_t species = species_index_for_bit(sp, bit);
                if (species >= 0 && !persist_ok(
                        cell, species, sp, water, temp, moist, elev))
                    bits = int32_t(static_cast<uint32_t>(bits) &
                                   ~(uint32_t(1) << bit));
            }
            _bio_occupancy_bits_staging[static_cast<size_t>(cell)] = bits;
        }
    };
    parallel_for_range("pk_bio_persistence", n, 0, 16384, persistence_range);

    for (int i = 0; i < intro_cells.size(); ++i) {
        const int32_t cell = intro_cells[i];
        const int32_t bit = intro_bits[i];
        if (cell < 0 || cell >= n || bit < 0 || bit >= 32) continue;
        const int32_t s = species_index_for_bit(sp, bit);
        if (s < 0) continue;
        if (!envelope_ok(cell, s, sp, water, veg, lf, river, temp, moist, elev)) continue;
        if (!carrier_ok(cell, s, sp, reserves)) continue;
        const uint32_t mask = uint32_t(1) << bit;
        const int32_t current = _bio_occupancy_bits_staging[static_cast<size_t>(cell)];
        if ((static_cast<uint32_t>(current) & mask) != 0u ||
            occupancy_count(current) < kMaxNewOccupancyPerCell)
            _bio_occupancy_bits_staging[static_cast<size_t>(cell)] =
                int32_t(static_cast<uint32_t>(current) | mask);
    }

    if (run_diffusion) {
        _bio_occupancy_additions.resize(static_cast<size_t>(n));
        std::fill(_bio_occupancy_additions.begin(),
                  _bio_occupancy_additions.end(), 0);
        // Target-owned proposal lanes avoid atomic OR and thread-local n-cell
        // buffers: every worker reads the frozen persistence result and writes
        // exactly one additions[target] lane.
        auto proposal_range = [&](int begin, int end) {
            for (int target = begin; target < end; ++target) {
                const int32_t pid = province[target];
                if (pid <= 0) continue;
                uint32_t candidates = 0u;
                const uint32_t current = static_cast<uint32_t>(
                    _bio_occupancy_bits_staging[static_cast<size_t>(target)]);
                const int32_t base = target * 6;
                for (int d = 0; d < 6; ++d) {
                    const int32_t source = nb[base + d];
                    if (source < 0 || source >= n || province[source] != pid) continue;
                    uint32_t scan = static_cast<uint32_t>(
                        _bio_occupancy_bits_staging[static_cast<size_t>(source)]);
                    while (scan != 0u) {
                        const int32_t bit = lowest_bit_index(scan);
                        scan &= scan - 1u;
                        const uint32_t mask = uint32_t(1) << bit;
                        if ((current & mask) != 0u || (candidates & mask) != 0u) continue;
                        const int32_t s = species_index_for_bit(sp, bit);
                        if (s < 0 || !envelope_ok(target, s, sp, water, veg, lf,
                                river, temp, moist, elev) ||
                            !carrier_ok(target, s, sp, reserves))
                            continue;
                        if (bio_unit(bio_hash(uint32_t(seed),
                                uint32_t(day_index * 17 + s + 3),
                                uint32_t(target))) < kDiffusionKeep)
                            candidates |= mask;
                    }
                }
                _bio_occupancy_additions[static_cast<size_t>(target)] =
                    int32_t(candidates);
            }
        };
        parallel_for_range("pk_bio_proposals", n, 0, 16384, proposal_range);
        auto merge_range = [&](int begin, int end) {
            for (int cell = begin; cell < end; ++cell) {
                _bio_occupancy_bits_staging[static_cast<size_t>(cell)] =
                    merge_natural_candidates(
                        cell, _bio_occupancy_bits_staging[static_cast<size_t>(cell)],
                        _bio_occupancy_additions[static_cast<size_t>(cell)], sp,
                        seed, day_index);
            }
        };
        parallel_for_range("pk_bio_merge", n, 0, 16384, merge_range);
    }

    const double native_compute_ms = elapsed_ms(compute_started);
    const auto publish_started = std::chrono::steady_clock::now();
    PackedInt32Array occupancy_out;
    int32_t *occupancy_out_ptr = nullptr;
    if (slot_mode) {
        occupancy_out_ptr = _slots.write[occupancy_slot_id].arr_i32.ptrw();
    } else {
        occupancy_out.resize(n);
        occupancy_out_ptr = occupancy_out.ptrw();
    }
    BioDiscoveryEmit discoveries;
    auto publish_range = [&](int begin, int end, BioDiscoveryEmit &local) {
        for (int cell = begin; cell < end; ++cell) {
            const int32_t next_bits =
                _bio_occupancy_bits_staging[static_cast<size_t>(cell)];
            const uint32_t added = static_cast<uint32_t>(next_bits) &
                ~static_cast<uint32_t>(
                    _bio_occupancy_previous[static_cast<size_t>(cell)]);
            occupancy_out_ptr[cell] = next_bits;
            uint32_t scan = added;
            while (scan != 0u) {
                const int32_t bit = lowest_bit_index(scan);
                scan &= scan - 1u;
                const int32_t s = species_index_for_bit(sp, bit);
                if (s < 0) continue;
                local.cells.push_back(cell);
                local.signals.push_back(sp.signal_ids[size_t(s)]);
            }
        }
    };
    parallel_for_range_with_emit<BioDiscoveryEmit>(
        "pk_bio_publish", n, 0, 16384, discoveries, publish_range);
    _bio_newly_occupied_cells.resize(int64_t(discoveries.cells.size()));
    _bio_newly_occupied_signals.resize(int64_t(discoveries.signals.size()));
    for (size_t i = 0; i < discoveries.cells.size(); ++i) {
        _bio_newly_occupied_cells.ptrw()[i] = discoveries.cells[i];
        _bio_newly_occupied_signals.ptrw()[i] = discoveries.signals[i];
    }

    const double publish_ms = elapsed_ms(publish_started);
    out["ok"] = true;
    out["path"] = String("gdext");
    if (slot_mode) {
        _flush_slot_to_map(occupancy_slot_id);
    } else {
        out["occupancy_bits"] = occupancy_out;
    }
    out["newly_occupied_cells"] = _bio_newly_occupied_cells;
    out["newly_occupied_signal_ids"] = _bio_newly_occupied_signals;
    out["processed_cells"] = n;
    out["native_compute_ms"] = native_compute_ms;
    out["bio_slice_native_ms"] = native_compute_ms;
    out["bridge_ms"] = bridge_ms;
    out["publish_ms"] = publish_ms;
    out["bio_slice_publish_ms"] = publish_ms;
    out["native_ms"] = elapsed_ms(total_started);
    out["published_to_slot"] = slot_mode;
    out["configured_slot_fastpath"] = slot_mode;
    const int64_t observation_handle = int64_t(
        knobs.get("observation_country_handle", int64_t(0)));
    if (observation_handle != 0) {
        const Dictionary evidence = _queue_bio_observations(
            observation_handle,
            int64_t(knobs.get("observation_effective_day", int64_t(0))),
            _bio_newly_occupied_cells, _bio_newly_occupied_signals);
        out["native_evidence_submission"] = bool(evidence.get("ok", false));
        out["native_evidence_submitted"] = int64_t(evidence.get("submitted", 0));
    }
    out["slice_enabled"] = bool(knobs.get("slice_enabled", false));
    out["slice_done"] = true;
    out["slice_cursor"] = n;
    return out;
}
