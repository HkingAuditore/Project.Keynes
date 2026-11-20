#include "world_ext.h"

#include "economy_api.h"
#include "native_simulation_host.h"

#include <array>
#include <utility>

namespace pk {

using namespace godot;

Dictionary DCWorldExt::configure_economy_natural_resources(const Dictionary &knobs) {
    Dictionary out;
    out["ok"] = false;
    if (_runtime_host && (_runtime_host->state() != RuntimeWorkerState::STOPPED ||
                          !_runtime_host->execution_has_stopped())) {
        out["code"] = "natural_resource_configuration_requires_stopped_executor";
        return out;
    }
    if (_economy_runtime == nullptr) {
        out["code"] = "economy_runtime_unavailable";
        return out;
    }
    NativeEconomyRuntime *runtime = static_cast<NativeEconomyRuntime *>(_economy_runtime);
    const PackedStringArray resource_ids = knobs.get("resource_ids", PackedStringArray());
    const PackedStringArray reserve_slots = knobs.get("reserve_slots", PackedStringArray());
    const PackedStringArray extra_slots = knobs.get("extra_change_slots", PackedStringArray());
    const PackedInt32Array habitat_modes = knobs.get("habitat_modes", PackedInt32Array());
    const PackedInt32Array temperature_signals =
        knobs.get("temperature_signals", PackedInt32Array());
    const PackedInt32Array moisture_signals = knobs.get("moisture_signals", PackedInt32Array());
    const char *float_keys[] = {"temp_lo", "temp_hi", "gen_base", "gen_temp", "gen_moisture",
        "gen_self", "decay_base", "decay_temp", "decay_moisture", "decay_self",
        "climate_temp_opt", "climate_temp_tol", "climate_moisture_opt",
        "climate_moisture_tol", "runtime_climate_fit_weight", "decay_stress",
        "ecology_capacity", "ecology_growth_rate", "ecology_immigration",
        "ecology_stress_mortality_rate"};
    constexpr size_t FLOAT_KEY_COUNT = sizeof(float_keys) / sizeof(float_keys[0]);
    std::array<PackedFloat32Array, FLOAT_KEY_COUNT> values;
    const int32_t knob_count = reserve_slots.size();
    if (resource_ids.size() != knob_count || extra_slots.size() != knob_count ||
        habitat_modes.size() != knob_count || temperature_signals.size() != knob_count ||
        moisture_signals.size() != knob_count) {
        out["code"] = "natural_resource_knob_size_mismatch";
        return out;
    }
    for (size_t k = 0; k < FLOAT_KEY_COUNT; ++k) {
        values[k] = knobs.get(float_keys[k], PackedFloat32Array());
        if (values[k].size() != knob_count) {
            out["code"] = "natural_resource_knob_size_mismatch";
            out["key"] = float_keys[k];
            return out;
        }
    }
    const auto [economy_ids, economy_slots, economy_extra_slots] =
        economy_api::natural_resource_catalog(*runtime);
    if (economy_ids.size() != static_cast<size_t>(knob_count)) {
        out["code"] = "natural_resource_catalog_size_mismatch";
        out["catalog_count"] = static_cast<int64_t>(economy_ids.size());
        out["profile_count"] = knob_count;
        return out;
    }
    std::vector<EconomyNaturalResourceProfile> resources(economy_slots.size());
    PackedStringArray missing;
    for (size_t r = 0; r < economy_slots.size(); ++r) {
        int32_t k = -1;
        for (int32_t i = 0; i < knob_count; ++i) {
            if (resource_ids[i] == String(economy_ids[r].c_str()) &&
                reserve_slots[i] == String(economy_slots[r].c_str()) &&
                extra_slots[i] == String(economy_extra_slots[r].c_str())) {
                k = i;
                break;
            }
        }
        if (k < 0) {
            missing.push_back(String(economy_slots[r].c_str()));
            continue;
        }
        auto &resource = resources[r];
        static_assert(FLOAT_KEY_COUNT == std::tuple_size_v<decltype(resource.coefficients)>);
        for (size_t coefficient = 0; coefficient < FLOAT_KEY_COUNT; ++coefficient)
            resource.coefficients[coefficient] = values[coefficient][k];
        resource.habitat_mode = habitat_modes[k];
        resource.temperature_signal = temperature_signals[k];
        resource.moisture_signal = moisture_signals[k];
    }
    if (!missing.is_empty()) {
        out["code"] = "natural_resource_knob_missing_resource";
        out["missing"] = missing;
        return out;
    }
    economy_api::configure_natural_resources(*runtime, resources);
    out["ok"] = true;
    out["resource_count"] = static_cast<int64_t>(economy_slots.size());
    return out;
}

bool DCWorldExt::economy_worker_owns_natural_resources() const {
    return _economy_runtime != nullptr && _runtime_host != nullptr &&
        _runtime_host->economy_worker_owns_execution() &&
        economy_api::natural_resources_configured(*static_cast<NativeEconomyRuntime *>(_economy_runtime));
}

bool DCWorldExt::seed_runtime_resource_reserves(NativeEconomyRuntime &runtime, int64_t day) {
    if (economy_api::natural_resources_seeded(runtime)) return true;
    const int32_t count = economy_api::cell_count(runtime);
    auto column = [&](const std::string &name) -> const float * {
        const int id = component_id(StringName(name.c_str()));
        if (id < 0 || id >= _slots.size() || _slots[id].dtype != SlotDType::F32 ||
            _slots[id].arr_f32.size() != count) return nullptr;
        return _slots[id].arr_f32.ptr();
    };
    const auto catalog = economy_api::natural_resource_catalog(runtime);
    const auto &reserves = catalog.reserve_slots;
    const auto &changes = catalog.change_slots;
    std::vector<const float *> reserve_columns, extra_columns;
    for (size_t r = 0; r < reserves.size(); ++r) {
        const float *reserve = column(reserves[r]);
        const float *extra = column(changes[r]);
        if (reserve == nullptr || extra == nullptr) return false;
        reserve_columns.push_back(reserve);
        extra_columns.push_back(extra);
    }
    return economy_api::seed_natural_resources(runtime, day, reserve_columns, extra_columns);
}

Dictionary DCWorldExt::apply_runtime_economy_resource_writeback() {
    Dictionary out;
    out["ok"] = true;
    out["applied"] = false;
    if (!_runtime_host || (!_runtime_display_resources &&
            (_runtime_display_commit.day_tail || !_runtime_host->has_resource_display_patch()))) return out;
    const auto *economy = static_cast<NativeEconomyRuntime *>(_economy_runtime);
    const int32_t count = economy_api::cell_count(*economy);
    const auto catalog = economy_api::natural_resource_catalog(*economy);
    const auto &reserves = catalog.reserve_slots;
    const auto &changes = catalog.change_slots;
    std::vector<int> reserve_slots;
    std::vector<int> extra_slots;
    auto resolve = [&](const std::string &name, std::vector<int> &slots) {
        const int id = component_id(StringName(name.c_str()));
        if (id < 0 || id >= _slots.size() || _slots[id].dtype != SlotDType::F32 ||
            _slots[id].arr_f32.size() != count) return false;
        slots.push_back(id);
        return true;
    };
    for (size_t resource = 0; resource < reserves.size(); ++resource) {
        if (!resolve(reserves[resource], reserve_slots) ||
            !resolve(changes[resource], extra_slots)) {
            out["ok"] = false;
            out["code"] = "resource_writeback_slot_shape_invalid";
            out["resource"] = String(catalog.ids[resource].c_str());
            return out;
        }
    }
    // Leave pending values available if the display slots were not ready.
    auto published = std::exchange(_runtime_display_resources, {});
    const auto patch = published ? std::move(*published) : _runtime_host->take_resource_display_patch();
    if (patch.cells.empty()) return out;
    std::vector<uint8_t> changed(patch.cells.size());
    auto install = [&](int id, size_t resource, const std::vector<float> &values, bool reserve) {
        const float *old = _slots[id].arr_f32.ptr();
        bool differs = false;
        for (size_t row = 0; row < patch.cells.size(); ++row) {
            if (old[patch.cells[row]] == values[row * reserves.size() + resource]) continue;
            differs = true;
            if (reserve) changed[row] = 1;
        }
        if (!differs) return;
        float *dst = _slots.write[id].arr_f32.ptrw();
        for (size_t row = 0; row < patch.cells.size(); ++row)
            dst[patch.cells[row]] = values[row * reserves.size() + resource];
        _flush_slot_to_map(id, false);
    };
    for (size_t resource = 0; resource < reserves.size(); ++resource) {
        install(reserve_slots[resource], resource, patch.reserve, true);
        install(extra_slots[resource], resource, patch.extra, false);
    }
    PackedInt32Array cells;
    for (size_t row = 0; row < patch.cells.size(); ++row)
        if (changed[row]) cells.append(patch.cells[row]);
    if (!cells.is_empty() && _map_data && _map_data->has_signal(StringName("resource_visual_inputs_changed")))
        _map_data->emit_signal(StringName("resource_visual_inputs_changed"), 1, cells);
    out["applied"] = true;
    out["cells"] = static_cast<int64_t>(patch.cells.size());
    return out;
}

} // namespace pk
