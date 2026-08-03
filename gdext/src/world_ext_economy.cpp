#include "world_ext.h"

#include "economy_runtime.h"
#include "economy_csv_recorder.h"
#include "country_runtime.h"
#include "modifier_runtime.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace pk {

using namespace godot;

namespace {

NativeEconomyRuntime *runtime_from(void *opaque) {
    return static_cast<NativeEconomyRuntime *>(opaque);
}

Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "economy_not_configured";
    return out;
}

} // namespace

Dictionary DCWorldExt::configure_economy(const Dictionary &catalog,
                                         const Dictionary &profile,
                                         int cell_count,
                                         int64_t seed) {
    // Headless/focused callers that have no explicit country package still
    // receive the same default-country bootstrap as production. MapGenerator
    // configures country first with the real water mask, so this path is only
    // the documented missing-country-data fallback.
    if (_country_runtime == nullptr) {
        _country_runtime = new NativeCountryRuntime();
        Dictionary country_profile;
        country_profile["country_runtime_mode"] = "ACTIVE";
        PackedStringArray starting;
        const PackedStringArray technologies = catalog.get("technology_ids", PackedStringArray());
        for (const char *id : {"tech.hunting", "tech.gathering", "tech.stone_knapping", "tech.fire_control"})
            if (technologies.has(id)) starting.push_back(id);
        country_profile["starting_technology_ids"] = starting;
        Dictionary configured = static_cast<NativeCountryRuntime *>(_country_runtime)->configure(
            catalog, country_profile, cell_count, seed);
        if (!static_cast<bool>(configured.get("ok", false))) return configured;
        PackedByteArray all_land;
        all_land.resize(cell_count);
        all_land.fill(0);
        Dictionary bootstrapped = static_cast<NativeCountryRuntime *>(_country_runtime)->bootstrap(
            Dictionary(), all_land);
        if (!static_cast<bool>(bootstrapped.get("ok", false))) return bootstrapped;
    }
    if (_economy_csv_recorder != nullptr)
        static_cast<EconomyCsvRecorder *>(_economy_csv_recorder)->request_stop();
    if (_economy_runtime == nullptr) _economy_runtime = new NativeEconomyRuntime();
    runtime_from(_economy_runtime)->attach_country_runtime(
        static_cast<NativeCountryRuntime *>(_country_runtime));
    runtime_from(_economy_runtime)->attach_modifier_runtime(
        static_cast<ModifierRuntime *>(_modifier_runtime));
    _economy_last_notified_event_id = 0;
    return runtime_from(_economy_runtime)->configure(catalog, profile, cell_count, seed);
}

Dictionary DCWorldExt::bootstrap_economy(const Dictionary &population_packet,
                                         const Dictionary &market_packet) {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->bootstrap(population_packet, market_packet);
}

Dictionary DCWorldExt::submit_economy_commands(const Dictionary &packed_batch) {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->submit_commands(packed_batch);
}

Dictionary DCWorldExt::run_economy_slice(const Dictionary &ctx) {
    return run_economy_slice_internal(ctx, false);
}

Dictionary DCWorldExt::run_economy_slice_compact(const Dictionary &ctx) {
    return run_economy_slice_internal(ctx, true);
}

Dictionary DCWorldExt::run_economy_slice_internal(const Dictionary &ctx, bool compact) {
    if (_economy_runtime == nullptr) {
        Dictionary out = unavailable();
        out["done"] = true;
        out["path"] = "ECONOMY_GRAPH";
        out["mode"] = "native";
        return out;
    }
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    const int64_t day_index = ctx.has("day_index") ? static_cast<int64_t>(ctx["day_index"]) : 0;
    const bool capture_cycle_context = runtime->needs_environment_capture(day_index);
    if (capture_cycle_context && _map_data != nullptr &&
        _map_data->has_method(StringName("neighbor_indices_packed")) &&
        _map_data->has_method(StringName("economy_trade_passable_lut")) &&
        _map_data->has_method(StringName("economy_trade_move_cost_lut"))) {
        // Trade routes follow the generated geography, not the climate-owned
        // dynamic terrain lane.  In particular, seasonal sea-ice flips must
        // not invalidate and rebuild the route plan every economy cycle.
        const int terrain_sid = component_id(StringName("cell_base_terrain"));
        const Variant neighbor_variant = _map_data->call(
            StringName("neighbor_indices_packed"));
        const Variant passable_variant = _map_data->call(
            StringName("economy_trade_passable_lut"));
        const Variant cost_variant = _map_data->call(
            StringName("economy_trade_move_cost_lut"));
        if (terrain_sid >= 0 && terrain_sid < _slots.size() &&
            _slots[terrain_sid].dtype == SlotDType::U8 &&
            neighbor_variant.get_type() == Variant::PACKED_INT32_ARRAY &&
            passable_variant.get_type() == Variant::PACKED_BYTE_ARRAY &&
            cost_variant.get_type() == Variant::PACKED_INT32_ARRAY) {
            const PackedInt32Array neighbors = neighbor_variant;
            const PackedByteArray passable = passable_variant;
            const PackedInt32Array costs = cost_variant;
            const int32_t count = _slots[terrain_sid].arr_u8.size();
            if (neighbors.size() == count * 6 && passable.size() == 256 &&
                costs.size() == 256) {
                std::string topology_error;
                if (!runtime->capture_trade_topology(neighbors.ptr(),
                        _slots[terrain_sid].arr_u8.ptr(), passable.ptr(), costs.ptr(),
                        count, 0, topology_error)) {
                    Dictionary out;
                    out["ok"] = false;
                    out["done"] = true;
                    out["fatal"] = true;
                    out["path"] = "ECONOMY_GRAPH";
                    out["stage"] = "trade_topology_snapshot";
                    out["fatal_reason"] = String(topology_error.c_str());
                    return out;
                }
            }
        }
    }
    if (runtime->needs_environment_capture(day_index)) {
        const int sid_temp = component_id(StringName("cell_temp"));
        const int sid_temp_30d = component_id(StringName("cell_temp_30d"));
        const int sid_moisture = component_id(StringName("cell_moisture"));
        const int sid_plant_water = component_id(StringName("cell_plant_available_water"));
        const int sid_snow = component_id(StringName("cell_snow_cover"));
        const int sid_weather = component_id(StringName("cell_weather_intensity"));
        auto valid_f32 = [&](int sid) {
            return sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::F32;
        };
        if (!valid_f32(sid_temp) || !valid_f32(sid_temp_30d) ||
            !valid_f32(sid_moisture) || !valid_f32(sid_plant_water) || !valid_f32(sid_snow) ||
            !valid_f32(sid_weather)) {
            Dictionary out;
            out["ok"] = false;
            out["done"] = true;
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
            _slots[sid_snow].arr_f32.size() != count ||
            _slots[sid_weather].arr_f32.size() != count) {
            Dictionary out;
            out["ok"] = false;
            out["done"] = true;
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
                                          _slots[sid_snow].arr_f32.ptr(),
                                          _slots[sid_weather].arr_f32.ptr(), count, error)) {
            Dictionary out;
            out["ok"] = false;
            out["done"] = true;
            out["fatal"] = true;
            out["path"] = "ECONOMY_GRAPH";
            out["stage"] = "environment_snapshot";
            out["fatal_reason"] = String(error.c_str());
            return out;
        }
    }
    if (runtime->needs_building_context_capture(day_index)) {
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
                Dictionary out;
                out["ok"] = false;
                out["done"] = true;
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
            Dictionary out;
            out["ok"] = false;
            out["done"] = true;
            out["fatal"] = true;
            out["path"] = "BUILDING_GRAPH";
            out["stage"] = "building_context_snapshot";
            out["fatal_reason"] = String(error.c_str());
            return out;
        }
    }
    Dictionary result = compact
        ? runtime->run_slice_compact(ctx)
        : runtime->run_slice(ctx);
    std::vector<int64_t> resource_deltas;
    if (runtime->drain_building_resource_deltas(resource_deltas)) {
        const int32_t count = runtime->building_resource_extra_slots().empty()
            ? 0 : static_cast<int32_t>(resource_deltas.size() /
                  runtime->building_resource_extra_slots().size());
        int64_t changed = 0;
        for (size_t r = 0; r < runtime->building_resource_extra_slots().size(); ++r) {
            const int sid = component_id(StringName(runtime->building_resource_extra_slots()[r].c_str()));
            if (sid < 0 || sid >= _slots.size() || _slots[sid].dtype != SlotDType::F32 ||
                _slots[sid].arr_f32.size() != count) continue;
            Slot &slot = _slots.write[sid];
            float *dst = slot.arr_f32.ptrw();
            bool slot_changed = false;
            for (int32_t cell = 0; cell < count; ++cell) {
                const int64_t delta = resource_deltas[r * static_cast<size_t>(count) + cell];
                if (delta == 0) continue;
                dst[cell] += static_cast<float>(delta) /
                             static_cast<float>(NativeEconomyRuntime::GOODS_SCALE);
                slot_changed = true;
                ++changed;
            }
            if (slot_changed) _flush_slot_to_map(sid);
        }
        result["building_resource_delta_cells"] = changed;
        result["published_to_slot"] = changed > 0;
    }
    // The recorder observes only a fully published epoch. Resource slots have
    // already received building deltas above, so all five tables share one
    // committed boundary.
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
    const int64_t newest_event_id = static_cast<int64_t>(
        result.get("economy_event_newest_id", int64_t{0}));
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
        _emit_gameplay_event(day_index, 9, 5, 1, 0, -1, -1, 2,
                             epoch, newest, count, 0);
        _economy_last_notified_event_id = newest_event_id;
        result["economy_event_batch_published"] = true;
    }
    return result;
}

bool DCWorldExt::economy_should_run(int64_t day_index) const {
    return _economy_runtime != nullptr &&
           runtime_from(_economy_runtime)->should_run(day_index);
}

Dictionary DCWorldExt::get_economy_report() const {
    if (_economy_runtime == nullptr) {
        Dictionary out;
        out["configured"] = false;
        out["bootstrapped"] = false;
        out["path"] = "ECONOMY_GRAPH";
        out["mode"] = "native";
        return out;
    }
    return runtime_from(_economy_runtime)->report();
}

Dictionary DCWorldExt::get_population_cell_snapshot(int cell_idx) const {
    if (_economy_runtime == nullptr) {
        return unavailable();
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
    return runtime_from(_economy_runtime)->population_cell_summary(cell_idx);
}

Dictionary DCWorldExt::get_named_settlement_snapshot() const {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->named_settlement_snapshot();
}

Dictionary DCWorldExt::get_settlement_delta(int64_t since_revision) const {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->settlement_delta(since_revision);
}

Dictionary DCWorldExt::get_market_cell_snapshot(int cell_idx) const {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->market_cell_snapshot(cell_idx);
}

Dictionary DCWorldExt::get_country_fiscal_snapshot(int64_t handle) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->fiscal_snapshot(handle);
}

Dictionary DCWorldExt::get_trade_orders_for_cell(
        int cell_idx, int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->trade_orders_for_cell(
        cell_idx, offset, limit);
}

Dictionary DCWorldExt::capture_economy_trade_topology(
        const PackedInt32Array &neighbor_indices, const PackedByteArray &terrain,
        const PackedByteArray &trade_passable_lut,
        const PackedInt32Array &trade_move_cost_lut, int64_t generation) {
    if (_economy_runtime == nullptr) return unavailable();
    Dictionary out;
    if (neighbor_indices.size() != terrain.size() * 6 ||
        trade_passable_lut.size() != 256 || trade_move_cost_lut.size() != 256) {
        out["ok"] = false;
        out["reason"] = "trade_topology_column_size_mismatch";
        return out;
    }
    std::string error;
    const bool ok = runtime_from(_economy_runtime)->capture_trade_topology(
        neighbor_indices.ptr(), terrain.ptr(), trade_passable_lut.ptr(),
        trade_move_cost_lut.ptr(), terrain.size(), static_cast<uint64_t>(generation), error);
    out["ok"] = ok;
    if (!ok) out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::get_building_cell_snapshot(int cell_idx) const {
    if (_economy_runtime == nullptr) return unavailable();
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    Dictionary out = runtime->building_cell_snapshot(cell_idx);
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

Dictionary DCWorldExt::get_family_cell_snapshot(
        int cell_idx, int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->family_cell_snapshot(
        cell_idx, offset, limit);
}

Dictionary DCWorldExt::get_family_snapshot(int64_t family_handle) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->family_snapshot(family_handle);
}

Dictionary DCWorldExt::get_family_traits(int64_t family_handle) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->family_traits(family_handle);
}

Dictionary DCWorldExt::get_family_branches(
        int64_t family_handle, int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->family_branches(
        family_handle, offset, limit);
}

Dictionary DCWorldExt::get_family_branch_effects(
        int64_t family_handle, int cell_idx) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->family_branch_effects(
        family_handle, cell_idx);
}

Dictionary DCWorldExt::submit_family_trait_commands(
        const Dictionary &packed_batch) {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->submit_family_trait_commands(
        packed_batch);
}

Dictionary DCWorldExt::get_family_industries(
        int64_t family_handle, int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->family_industries(
        family_handle, offset, limit);
}

Dictionary DCWorldExt::get_family_notable_people(
        int64_t family_handle, int offset, int limit) const {
    if (_economy_runtime == nullptr) return Dictionary();
    return runtime_from(_economy_runtime)->family_notable_people(
        family_handle, offset, limit);
}

Dictionary DCWorldExt::get_notable_person_snapshot(
        int64_t person_handle) const {
    if (_economy_runtime == nullptr) return Dictionary();
    return runtime_from(_economy_runtime)->notable_person_snapshot(person_handle);
}

Dictionary DCWorldExt::get_notable_person_needs(
        int64_t person_handle, int offset, int limit) const {
    if (_economy_runtime == nullptr) return Dictionary();
    return runtime_from(_economy_runtime)->notable_person_needs(
        person_handle, offset, limit);
}

Dictionary DCWorldExt::get_building_notable_people(
        int64_t building_handle, int offset, int limit) const {
    if (_economy_runtime == nullptr) return Dictionary();
    return runtime_from(_economy_runtime)->building_notable_people(
        building_handle, offset, limit);
}

Dictionary DCWorldExt::run_economy_fixed_math_probe(const Dictionary &vectors) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->fixed_math_probe(vectors);
}

Dictionary DCWorldExt::run_economy_production_climate_math_probe(
        const Dictionary &vectors) const {
    if (_economy_runtime == nullptr) {
        NativeEconomyRuntime probe_runtime;
        return probe_runtime.production_climate_math_probe(vectors);
    }
    return runtime_from(_economy_runtime)->production_climate_math_probe(vectors);
}

int64_t DCWorldExt::get_economy_state_hash() const {
    return _economy_runtime == nullptr ? 0 : runtime_from(_economy_runtime)->state_hash();
}

Dictionary DCWorldExt::reset_economy(const String &reason) {
    if (_economy_csv_recorder != nullptr)
        static_cast<EconomyCsvRecorder *>(_economy_csv_recorder)->request_stop();
    if (_economy_runtime == nullptr) {
        Dictionary out;
        out["ok"] = true;
        out["reason"] = reason;
        return out;
    }
    _economy_last_notified_event_id = 0;
    return runtime_from(_economy_runtime)->reset(reason);
}

Dictionary DCWorldExt::start_economy_csv_recording(const Dictionary &config) {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["error_code"] = "economy_unavailable";
        return out;
    }
    EconomyCsvRecorder::Config native;
    native.enabled[EconomyCsvRecorder::SUMMARY] = config.get("record_summary", true);
    native.enabled[EconomyCsvRecorder::COHORTS] = config.get("record_cohorts", true);
    native.enabled[EconomyCsvRecorder::BUILDINGS] = config.get("record_buildings", true);
    native.enabled[EconomyCsvRecorder::RESOURCES] = config.get("record_resources", true);
    native.enabled[EconomyCsvRecorder::MARKET] = config.get("record_market", true);
    native.cell_stride = static_cast<int32_t>(config.get("cell_stride", 1));
    native.max_rows = static_cast<int64_t>(config.get("max_rows", int64_t{5'000'000}));
    native.test_write_delay_ms = std::clamp<int32_t>(
        static_cast<int32_t>(config.get("test_write_delay_ms", 0)), 0, 5000);
    native.test_fail_after_bytes = std::max<int64_t>(
        -1, static_cast<int64_t>(config.get("test_fail_after_bytes", int64_t{-1})));

    auto copy_i32 = [](const PackedInt32Array &src, std::vector<int32_t> &dst) {
        dst.resize(static_cast<size_t>(src.size()));
        if (src.size() > 0) std::copy(src.ptr(), src.ptr() + src.size(), dst.begin());
    };
    copy_i32(config.get("q_arr", PackedInt32Array()), native.q);
    copy_i32(config.get("r_arr", PackedInt32Array()), native.r);
    copy_i32(config.get("s_arr", PackedInt32Array()), native.s);
    copy_i32(config.get("cell_indices", PackedInt32Array()), native.cell_indices);
    copy_i32(config.get("resource_slot_ids", PackedInt32Array()), native.resource_slot_ids);

    const PackedStringArray resource_ids = config.get("resource_ids", PackedStringArray());
    for (int64_t i = 0; i < resource_ids.size(); ++i) {
        const auto bytes = String(resource_ids[i]).utf8();
        native.resource_ids.emplace_back(bytes.get_data(), static_cast<size_t>(bytes.length()));
    }
    const Dictionary paths = config.get("paths", Dictionary());
    static constexpr const char *keys[EconomyCsvRecorder::DIM_COUNT] = {
        "summary", "cohorts", "buildings", "resources", "market"
    };
    for (int32_t dim = 0; dim < EconomyCsvRecorder::DIM_COUNT; ++dim) {
        const String path = paths.get(keys[dim], String());
        const auto bytes = path.utf8();
        native.paths[dim].assign(bytes.get_data(), static_cast<size_t>(bytes.length()));
    }

    if (_economy_csv_recorder == nullptr)
        _economy_csv_recorder = new EconomyCsvRecorder();
    std::string error;
    EconomyCsvRecorder *recorder =
        static_cast<EconomyCsvRecorder *>(_economy_csv_recorder);
    const bool ok = recorder->start(native, *runtime_from(_economy_runtime), error);
    out = recorder->status();
    out["ok"] = ok;
    if (!ok && !error.empty()) out["error_message"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::request_stop_economy_csv_recording() {
    if (_economy_csv_recorder == nullptr) return get_economy_csv_recording_status();
    EconomyCsvRecorder *recorder =
        static_cast<EconomyCsvRecorder *>(_economy_csv_recorder);
    recorder->request_stop();
    return recorder->status();
}

Dictionary DCWorldExt::get_economy_csv_recording_status() const {
    if (_economy_csv_recorder != nullptr)
        return static_cast<EconomyCsvRecorder *>(_economy_csv_recorder)->status();
    Dictionary out;
    out["state"] = "idle";
    out["schema_version"] = EconomyCsvRecorder::SCHEMA_VERSION;
    out["recording"] = false;
    out["draining"] = false;
    out["captured_epochs"] = 0;
    out["written_epochs"] = 0;
    out["captured_rows"] = 0;
    out["written_rows"] = 0;
    out["bytes_written"] = 0;
    out["paths"] = PackedStringArray();
    return out;
}

Dictionary DCWorldExt::begin_economy_save(int chunk_bytes) {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->begin_save(chunk_bytes);
}

PackedByteArray DCWorldExt::read_economy_save_chunk(int max_bytes) {
    if (_economy_runtime == nullptr) return {};
    return runtime_from(_economy_runtime)->read_save_chunk(max_bytes);
}

Dictionary DCWorldExt::end_economy_save() {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->end_save();
}

Dictionary DCWorldExt::begin_economy_restore() {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->begin_restore();
}

Dictionary DCWorldExt::feed_economy_restore_chunk(const PackedByteArray &chunk) {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->feed_restore_chunk(chunk);
}

Dictionary DCWorldExt::end_economy_restore() {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->end_restore();
}

Dictionary DCWorldExt::get_economy_event_schema() const {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->event_schema();
}

Dictionary DCWorldExt::set_economy_trace_filter(const Dictionary &filter) {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->set_trace_filter(filter);
}

Dictionary DCWorldExt::set_economy_inspector_trace_cell(int cell_idx) {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->set_inspector_trace_cell(cell_idx);
}

Dictionary DCWorldExt::poll_economy_events(const Dictionary &opts) const {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->poll_events(opts);
}

Dictionary DCWorldExt::ack_economy_events(StringName consumer_id,
                                          int64_t up_to_event_id) {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->ack_events(consumer_id, up_to_event_id);
}

Dictionary DCWorldExt::get_economy_trace_report() const {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->trace_report();
}

Dictionary DCWorldExt::begin_economy_event_archive(int chunk_bytes) {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->begin_event_archive(chunk_bytes);
}

PackedByteArray DCWorldExt::read_economy_event_archive_chunk(int max_bytes) {
    return _economy_runtime == nullptr ? PackedByteArray()
        : runtime_from(_economy_runtime)->read_event_archive_chunk(max_bytes);
}

Dictionary DCWorldExt::end_economy_event_archive() {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->end_event_archive();
}

} // namespace pk
