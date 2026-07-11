#include "world_ext.h"

#include "economy_runtime.h"

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
    if (_economy_runtime == nullptr) _economy_runtime = new NativeEconomyRuntime();
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
    if (_economy_runtime == nullptr) {
        Dictionary out = unavailable();
        out["done"] = true;
        out["path"] = "ECONOMY_GRAPH";
        out["mode"] = "native";
        return out;
    }
    NativeEconomyRuntime *runtime = runtime_from(_economy_runtime);
    const int64_t day_index = ctx.has("day_index") ? static_cast<int64_t>(ctx["day_index"]) : 0;
    if (runtime->needs_environment_capture(day_index)) {
        const int sid_temp = component_id(StringName("cell_temp"));
        const int sid_moisture = component_id(StringName("cell_moisture"));
        const int sid_snow = component_id(StringName("cell_snow_cover"));
        const int sid_weather = component_id(StringName("cell_weather_intensity"));
        auto valid_f32 = [&](int sid) {
            return sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::F32;
        };
        if (!valid_f32(sid_temp) || !valid_f32(sid_moisture) || !valid_f32(sid_snow) ||
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
        if (_slots[sid_moisture].arr_f32.size() != count ||
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
                                          _slots[sid_moisture].arr_f32.ptr(),
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
        }
        const int temp_sid = component_id(StringName("cell_temp"));
        const int32_t count = temp_sid >= 0 && temp_sid < _slots.size()
            ? _slots[temp_sid].arr_f32.size() : 0;
        std::string error;
        if (!runtime->capture_building_context(
                day_index, f32_ptr("cell_elevation"), u8_ptr("cell_terrain"),
                u8_ptr("cell_landform"), u8_ptr("cell_vegetation"),
                u8_ptr("cell_is_water"), u8_ptr("cell_has_river"), resources,
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
    Dictionary result = runtime->run_slice(ctx);
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

Dictionary DCWorldExt::get_market_cell_snapshot(int cell_idx) const {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->market_cell_snapshot(cell_idx);
}

Dictionary DCWorldExt::get_building_cell_snapshot(int cell_idx) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->building_cell_snapshot(cell_idx);
}

Dictionary DCWorldExt::run_economy_fixed_math_probe(const Dictionary &vectors) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->fixed_math_probe(vectors);
}

int64_t DCWorldExt::get_economy_state_hash() const {
    return _economy_runtime == nullptr ? 0 : runtime_from(_economy_runtime)->state_hash();
}

Dictionary DCWorldExt::reset_economy(const String &reason) {
    if (_economy_runtime == nullptr) {
        Dictionary out;
        out["ok"] = true;
        out["reason"] = reason;
        return out;
    }
    return runtime_from(_economy_runtime)->reset(reason);
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

} // namespace pk
