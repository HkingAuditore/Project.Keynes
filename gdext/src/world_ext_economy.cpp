#include "world_ext.h"

#include "economy_runtime.h"
#include "economy_csv_recorder.h"
#include "country_runtime.h"
#include "modifier_runtime.h"
#include "trigger_runtime.h"
#include "effect_runtime.h"
#include "native_simulation_host.h"
#include "runtime_economy_ecp2.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>

namespace pk {

namespace {
uint64_t ecp2_wire_hash(const godot::PackedByteArray &bytes) {
    uint64_t hash = 1469598103934665603ull;
    // The ECP2 content hash covers the bytes after the fixed 24-byte header.
    for (int64_t i = 24; i < bytes.size(); ++i) {
        hash ^= static_cast<uint64_t>(bytes[i]);
        hash *= 1099511628211ull;
    }
    return hash;
}
}

using namespace godot;

namespace {

using BridgeClock = std::chrono::steady_clock;

double bridge_elapsed_ms(BridgeClock::time_point started) {
    return std::chrono::duration<double, std::milli>(
        BridgeClock::now() - started).count();
}

NativeEconomyRuntime *runtime_from(void *opaque) {
    return static_cast<NativeEconomyRuntime *>(opaque);
}

Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "economy_not_configured";
    return out;
}

bool read_generation_u64(const Dictionary &generation, const char *key,
                         uint64_t &out, std::string &error) {
    const StringName field(key);
    if (!generation.has(field)) {
        out = 0;
        return true;
    }
    const Variant value = generation.get(field, Variant());
    if (value.get_type() != Variant::INT) {
        error = std::string("economy_input_generation_field_not_integer:") + key;
        return false;
    }
    const int64_t signed_value = static_cast<int64_t>(value);
    if (signed_value < 0) {
        error = std::string("economy_input_generation_field_negative:") + key;
        return false;
    }
    out = static_cast<uint64_t>(signed_value);
    return true;
}

bool read_generation_sample_day(const Dictionary &generation, int64_t day_index,
                                int64_t &out, std::string &error) {
    const StringName field("sample_day");
    if (!generation.has(field)) {
        out = day_index;
        return true;
    }
    const Variant value = generation.get(field, Variant());
    if (value.get_type() != Variant::INT) {
        error = "economy_input_generation_sample_day_not_integer";
        return false;
    }
    out = static_cast<int64_t>(value);
    if (out != day_index) {
        error = "economy_input_generation_sample_day_mismatch";
        return false;
    }
    return true;
}

bool parse_economy_input_generation(int64_t day_index,
                                    const Dictionary &generation,
                                    EconomyInputGeneration &out,
                                    std::string &error) {
    out = {};
    if (!read_generation_sample_day(generation, day_index, out.sample_day, error) ||
        !read_generation_u64(generation, "epoch_id", out.epoch_id, error) ||
        !read_generation_u64(generation,
            generation.has(StringName("map_generation"))
                ? "map_generation" : "topology_generation",
            out.map_generation, error) ||
        !read_generation_u64(generation, "building_generation",
                             out.building_generation, error) ||
        !read_generation_u64(generation, "country_generation",
                             out.country_generation, error) ||
        !read_generation_u64(generation, "resource_generation",
                             out.resource_generation, error)) {
        return false;
    }
    return true;
}

Dictionary economy_input_generation_dictionary(
        const EconomyInputGeneration &generation) {
    Dictionary out;
    out["sample_day"] = generation.sample_day;
    out["epoch_id"] = static_cast<int64_t>(generation.epoch_id);
    out["map_generation"] = static_cast<int64_t>(generation.map_generation);
    out["building_generation"] =
        static_cast<int64_t>(generation.building_generation);
    out["country_generation"] =
        static_cast<int64_t>(generation.country_generation);
    out["resource_generation"] =
        static_cast<int64_t>(generation.resource_generation);
    return out;
}

} // namespace

void DCWorldExt::invalidate_economy_input_capture_cache(bool force_full) {
    _economy_capture_generation = {};
    _economy_capture_generation_valid = false;
    _economy_capture_cached = false;
    _economy_capture_force_full = force_full;
    _economy_capture_cached_report.clear();
}

Dictionary DCWorldExt::configure_economy(const Dictionary &catalog,
                                         const Dictionary &profile,
                                         int cell_count,
                                         int64_t seed) {
    invalidate_economy_input_capture_cache(true);
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
        if (_effect_runtime != nullptr)
            static_cast<NativeCountryRuntime *>(_country_runtime)->attach_effect_runtime(
                static_cast<EffectRuntime *>(_effect_runtime));
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
    if (_modifier_runtime != nullptr)
        static_cast<ModifierRuntime *>(_modifier_runtime)->attach_economy_runtime(
            runtime_from(_economy_runtime));
    runtime_from(_economy_runtime)->attach_country_runtime(
        static_cast<NativeCountryRuntime *>(_country_runtime));
    if (_country_runtime != nullptr)
        static_cast<NativeCountryRuntime *>(_country_runtime)->attach_economy_runtime(
            runtime_from(_economy_runtime));
    runtime_from(_economy_runtime)->attach_modifier_runtime(
        static_cast<ModifierRuntime *>(_modifier_runtime));
    runtime_from(_economy_runtime)->attach_trigger_runtime(
        static_cast<TriggerRuntime *>(_trigger_runtime));
    if (_effect_runtime != nullptr)
        runtime_from(_economy_runtime)->attach_effect_runtime(
            static_cast<EffectRuntime *>(_effect_runtime));
    _economy_last_notified_event_id = 0;
    return runtime_from(_economy_runtime)->configure(catalog, profile, cell_count, seed);
}

Dictionary DCWorldExt::bootstrap_economy(const Dictionary &population_packet,
                                         const Dictionary &market_packet) {
    invalidate_economy_input_capture_cache(true);
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    return runtime_from(_economy_runtime)->bootstrap(population_packet, market_packet);
}

Dictionary DCWorldExt::submit_economy_commands(const Dictionary &packed_batch) {
    // Phase-2.4.5: refuse legacy ingress whenever StageOps is the effective
    // production writer, even before economy is configured.
    if (_runtime_host != nullptr &&
        _runtime_host->economy_production_writer_effective() ==
            EconomyProductionWriter::STAGE_OPS) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "economy_legacy_ingress_disabled";
        return out;
    }
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    // Production opcode admission stays on NativeEconomyRuntime until the full
    // 23-opcode POD extraction lands. Host POD queue is Phase 4 scaffolding.
    return runtime_from(_economy_runtime)->submit_commands(packed_batch);
}

Dictionary DCWorldExt::submit_economy_pod_commands(const Dictionary &packed_batch) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const PackedInt64Array request_ids =
        packed_batch.get("request_ids", PackedInt64Array());
    const PackedInt32Array opcodes =
        packed_batch.get("opcodes", PackedInt32Array());
    const PackedInt64Array transactions =
        packed_batch.get("transaction_ids", PackedInt64Array());
    const PackedInt64Array session_epochs =
        packed_batch.get("session_epochs", PackedInt64Array());
    const PackedInt64Array economy_generations =
        packed_batch.get("economy_generations", PackedInt64Array());
    const PackedInt64Array payload0s =
        packed_batch.get("payload0s", PackedInt64Array());
    const PackedInt64Array payload1s =
        packed_batch.get("payload1s", PackedInt64Array());
    const PackedInt64Array payload2s =
        packed_batch.get("payload2s", PackedInt64Array());
    const PackedInt32Array target_cells =
        packed_batch.get("target_cells", PackedInt32Array());
    const PackedInt64Array target_countries =
        packed_batch.get("target_countries", PackedInt64Array());
    const PackedInt64Array target_cohorts =
        packed_batch.get("target_cohorts", PackedInt64Array());
    const PackedInt64Array target_buildings =
        packed_batch.get("target_buildings", PackedInt64Array());
    const int64_t n = request_ids.size();
    if (opcodes.size() != n) {
        out["ok"] = false;
        out["code"] = "economy_pod_command_batch_size_mismatch";
        return out;
    }
    PackedInt64Array accepted_ids;
    for (int64_t i = 0; i < n; ++i) {
        RuntimeEconomyPodCommand command;
        command.request_id = static_cast<uint64_t>(request_ids[i]);
        command.opcode = opcodes[static_cast<int>(i)];
        if (i < transactions.size())
            command.transaction_id = static_cast<uint64_t>(transactions[i]);
        if (i < session_epochs.size())
            command.session_epoch = static_cast<uint64_t>(session_epochs[i]);
        if (i < economy_generations.size())
            command.economy_generation =
                static_cast<uint64_t>(economy_generations[i]);
        if (i < payload0s.size()) command.payload0 = payload0s[static_cast<int>(i)];
        if (i < payload1s.size()) command.payload1 = payload1s[static_cast<int>(i)];
        if (i < payload2s.size()) command.payload2 = payload2s[static_cast<int>(i)];
        if (i < target_cells.size())
            command.target_cell = target_cells[static_cast<int>(i)];
        if (i < target_countries.size())
            command.target_country = target_countries[static_cast<int>(i)];
        if (i < target_cohorts.size())
            command.target_cohort = target_cohorts[static_cast<int>(i)];
        if (i < target_buildings.size())
            command.target_building = target_buildings[static_cast<int>(i)];
        std::string error;
        if (!_runtime_host->submit_economy_pod_command(command, error)) {
            out["ok"] = false;
            out["code"] = error.empty() ? "economy_pod_command_rejected"
                                        : error.c_str();
            out["accepted_request_ids"] = accepted_ids;
            return out;
        }
        accepted_ids.push_back(request_ids[i]);
    }
    out["ok"] = true;
    out["accepted_request_ids"] = accepted_ids;
    return out;
}

Dictionary DCWorldExt::poll_economy_pod_receipts(int max_items) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    const int limit = std::clamp(max_items, 0, 4096);
    Array rows;
    for (int i = 0; i < limit; ++i) {
        RuntimeEconomyPodReceipt receipt;
        if (!_runtime_host->poll_economy_pod_receipt(receipt)) break;
        Dictionary row;
        row["request_id"] = static_cast<int64_t>(receipt.request_id);
        row["transaction_id"] = static_cast<int64_t>(receipt.transaction_id);
        row["session_epoch"] = static_cast<int64_t>(receipt.session_epoch);
        row["economy_generation"] =
            static_cast<int64_t>(receipt.economy_generation);
        row["opcode"] = receipt.opcode;
        row["code"] = static_cast<int>(receipt.code);
        row["reason"] = String(receipt.reason);
        rows.push_back(row);
    }
    out["ok"] = true;
    out["receipts"] = rows;
    return out;
}

Dictionary DCWorldExt::run_economy_slice(const Dictionary &ctx) {
    return run_economy_slice_internal(ctx, false);
}

Dictionary DCWorldExt::run_economy_slice_compact(const Dictionary &ctx) {
    return run_economy_slice_internal(ctx, true);
}

Dictionary DCWorldExt::capture_economy_day_inputs(int64_t day_index) {
    return begin_or_reuse_economy_input_epoch(day_index, Dictionary());
}

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
        auto valid_f32 = [&](int sid) {
            return sid >= 0 && sid < _slots.size() && _slots[sid].dtype == SlotDType::F32;
        };
        if (!valid_f32(sid_temp) || !valid_f32(sid_temp_30d) ||
            !valid_f32(sid_moisture) || !valid_f32(sid_plant_water) || !valid_f32(sid_snow) ||
            !valid_f32(sid_precip) || !valid_f32(sid_weather)) {
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
            _slots[sid_weather].arr_f32.size() != count) {
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
                                          _slots[sid_weather].arr_f32.ptr(), count, error)) {
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
                    _map_data->get(StringName("visible_arr"));
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
            if (fact.kind == NativeEconomyRuntime::GAMEPLAY_FACT_CONSTRUCTION_COMPLETED) {
                event_type = 6;
                payload_schema = 3;
                if (_modifier_runtime != nullptr) {
                    fact.entity_handle = static_cast<ModifierRuntime *>(
                        _modifier_runtime)->ensure_building_identity(
                            fact.cell, fact.payload[1], fact.payload[2]);
                }
            } else if (fact.kind == NativeEconomyRuntime::GAMEPLAY_FACT_TRADE_ARRIVED) {
                event_type = 7;
                payload_schema = 8;
            } else if (fact.kind ==
                    NativeEconomyRuntime::GAMEPLAY_FACT_TARIFF_SUBSIDY_INTENT) {
                event_type = 15;
                payload_schema = 8;
            } else if (fact.kind ==
                    NativeEconomyRuntime::GAMEPLAY_FACT_SOCIAL_PRESSURE) {
                event_type = 8;
                payload_schema = 5;
            } else if (fact.kind ==
                    NativeEconomyRuntime::GAMEPLAY_FACT_TECHNOLOGY_PRACTICE) {
                event_type = 14;
                payload_schema = 7;
            } else if (fact.kind ==
                    NativeEconomyRuntime::GAMEPLAY_FACT_TECHNOLOGY_CONTACT) {
                event_type = 16;
                payload_schema = 7;
            } else if (fact.kind ==
                    NativeEconomyRuntime::GAMEPLAY_FACT_REPEATED_CROP_FAILURE) {
                event_type = 11;
                payload_schema = 9;
            } else if (fact.kind ==
                    NativeEconomyRuntime::GAMEPLAY_FACT_COUNTRY_DEVELOPMENT_METRIC) {
                event_type = 17;
                payload_schema = 10;
            }
            if (event_type == 0) continue;
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

PackedInt32Array DCWorldExt::get_economy_live_cells() {
    if (_economy_runtime == nullptr) return PackedInt32Array();
    return runtime_from(_economy_runtime)->economy_live_cells_query();
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

Dictionary DCWorldExt::get_country_class_opinion_snapshot() const {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->
            country_class_opinion_snapshot_debug();
}

Dictionary DCWorldExt::get_population_cell_snapshot(
        int cell_idx, bool include_details) const {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    if (!include_details) {
        return runtime_from(_economy_runtime)->population_cell_snapshot(
            cell_idx, false);
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

Dictionary DCWorldExt::explain_cohort_satisfaction(int64_t cohort_handle) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->explain_cohort_satisfaction(
        cohort_handle);
}

Dictionary DCWorldExt::get_cell_satisfaction_attractiveness(int cell_idx) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->cell_satisfaction_attractiveness(
        cell_idx);
}

Dictionary DCWorldExt::get_country_fiscal_snapshot(int64_t handle) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->fiscal_snapshot(handle);
}

Dictionary DCWorldExt::get_country_trade_snapshot(
        int64_t handle, const String &view, int offset, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->country_trade_snapshot(
        handle, view, offset, limit);
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
        const PackedInt32Array &trade_move_cost_lut, int64_t generation,
        const PackedByteArray &landform, const PackedByteArray &has_river) {
    if (_economy_runtime == nullptr) return unavailable();
    Dictionary out;
    if (neighbor_indices.size() != terrain.size() * 6 ||
        trade_passable_lut.size() != 256 || trade_move_cost_lut.size() != 256) {
        out["ok"] = false;
        out["reason"] = "trade_topology_column_size_mismatch";
        return out;
    }
    std::string error;
    std::vector<uint8_t> empty_canal(static_cast<size_t>(terrain.size()), 0);
    std::vector<float> empty_water(static_cast<size_t>(terrain.size()), 0.0f);
    const uint8_t *landform_ptr = landform.size() == terrain.size() ? landform.ptr() : nullptr;
    const uint8_t *river_ptr = has_river.size() == terrain.size() ? has_river.ptr() : nullptr;
    const bool ok = runtime_from(_economy_runtime)->capture_trade_topology(
        neighbor_indices.ptr(), terrain.ptr(), empty_canal.data(), empty_water.data(),
        trade_passable_lut.ptr(),
        trade_move_cost_lut.ptr(), terrain.size(), static_cast<uint64_t>(generation),
        error, landform_ptr, river_ptr);
    out["ok"] = ok;
    if (!ok) out["reason"] = String(error.c_str());
    return out;
}

Dictionary DCWorldExt::capture_economy_trade_visibility(
        const PackedByteArray &visible, bool fog_solved) {
    if (_economy_runtime == nullptr) return unavailable();
    Dictionary out;
    std::string error;
    const bool ok = runtime_from(_economy_runtime)->capture_trade_visibility(
        visible.ptr(), visible.size(), fog_solved, false, error);
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

Dictionary DCWorldExt::get_building_visual_snapshot(
        const PackedInt32Array &requested_cells) const {
    if (_economy_runtime == nullptr) return unavailable();
    Dictionary out = runtime_from(_economy_runtime)->building_visual_snapshot(
        requested_cells);
    if (!static_cast<bool>(out.get("ok", false))) return out;
    PackedInt32Array cells = out["cell_indices"];
    PackedInt32Array country_slots;
    PackedInt32Array era_indices;
    country_slots.resize(cells.size());
    era_indices.resize(cells.size());
    uint64_t era_generation = 0;
    NativeCountryRuntime *countries = _country_runtime == nullptr
        ? nullptr : static_cast<NativeCountryRuntime *>(_country_runtime);
    if (countries != nullptr) era_generation = countries->visual_era_generation();
    for (int64_t i = 0; i < cells.size(); ++i) {
        const int32_t slot = countries == nullptr
            ? -1 : countries->country_slot_for_cell(cells[i]);
        country_slots.set(i, slot);
        era_indices.set(i, countries == nullptr
            ? -1 : countries->visual_era_index_for_slot(slot));
    }
    out["country_slots"] = country_slots;
    out["era_indices"] = era_indices;
    out["country_era_generation"] = static_cast<int64_t>(era_generation);
    return out;
}

Dictionary DCWorldExt::consume_building_visual_dirty_cells() {
    return _economy_runtime == nullptr ? unavailable()
        : runtime_from(_economy_runtime)->consume_building_visual_dirty_cells();
}

Dictionary DCWorldExt::get_treasury_construction_quotes(
        int64_t country_handle, int cell_idx,
        const PackedInt32Array &type_ids) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->treasury_construction_quotes(
        country_handle, cell_idx, type_ids);
}

Dictionary DCWorldExt::get_construction_command_receipts(
        int64_t after_receipt_id, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->construction_command_receipts(
        after_receipt_id, limit);
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

Dictionary DCWorldExt::get_canal_route_quote(
        int64_t country_handle, int start_cell, int end_cell,
        const PackedInt32Array &waypoints) {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->canal_route_quote(
        country_handle, start_cell, end_cell, waypoints);
}

Dictionary DCWorldExt::get_canal_route_quote_detail(
        int64_t country_handle, int64_t quote_token) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->canal_route_quote_detail(
        country_handle, quote_token);
}

Dictionary DCWorldExt::queue_canal_construction(
        int64_t country_handle, int64_t quote_token,
        int64_t effective_day, int64_t sequence) {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->queue_canal_construction(
        country_handle, quote_token, effective_day, sequence);
}

Dictionary DCWorldExt::get_canal_construction_receipts(
        int64_t country_handle, int64_t after_receipt_id, int limit) const {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->canal_construction_receipts(
        country_handle, after_receipt_id, limit);
}

Dictionary DCWorldExt::get_family_colonization_quotes(
        int64_t country_handle, int target_cell, int64_t family_filter,
        int source_filter, int offset, int limit) {
    if (_economy_runtime == nullptr || _map_data == nullptr) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "economy_not_available";
        out["busy"] = false;
        out["committed"] = false;
        out["nonbinding"] = false;
        return out;
    }
    const Variant visible_variant = _map_data->get(StringName("visible_arr"));
    if (visible_variant.get_type() != Variant::PACKED_BYTE_ARRAY) {
        Dictionary out;
        out["ok"] = false;
        out["code"] = "colonization_visibility_unavailable";
        runtime_from(_economy_runtime)->fill_colonization_query_flags(out);
        return out;
    }
    const PackedByteArray visible = visible_variant;
    const uint64_t revision = static_cast<uint64_t>(static_cast<int64_t>(
        _map_data->get(StringName("vision_revision"))));
    return runtime_from(_economy_runtime)->family_colonization_quotes(
        country_handle, target_cell, family_filter, source_filter, offset,
        limit, visible.ptr(), visible.size(), revision);
}

Dictionary DCWorldExt::get_family_colonization_quote_detail(
        int64_t quote_token, int64_t population) const {
    return _economy_runtime == nullptr ? unavailable() :
        runtime_from(_economy_runtime)->family_colonization_quote_detail(
            quote_token, population);
}

Dictionary DCWorldExt::start_family_colonization(
        int64_t country_handle, int64_t family_handle, int source_cell,
        int target_cell, int64_t population, int64_t quote_token,
        int64_t effective_day, int64_t sequence) {
    if (_economy_runtime == nullptr || _map_data == nullptr) return unavailable();
    const Variant visible_variant = _map_data->get(StringName("visible_arr"));
    if (visible_variant.get_type() != Variant::PACKED_BYTE_ARRAY) {
        Dictionary out; out["ok"] = false;
        out["code"] = "colonization_visibility_unavailable"; return out;
    }
    const PackedByteArray visible = visible_variant;
    const uint64_t revision = static_cast<uint64_t>(static_cast<int64_t>(
        _map_data->get(StringName("vision_revision"))));
    return runtime_from(_economy_runtime)->submit_family_colonization_start(
        country_handle, family_handle, source_cell, target_cell, population,
        quote_token, effective_day, sequence, visible.ptr(), visible.size(),
        revision);
}

Dictionary DCWorldExt::cancel_family_colonization(
        int64_t country_handle, int64_t expedition_handle,
        int64_t effective_day, int64_t sequence) {
    return _economy_runtime == nullptr ? unavailable() :
        runtime_from(_economy_runtime)->submit_family_colonization_cancel(
            country_handle, expedition_handle, effective_day, sequence);
}

Dictionary DCWorldExt::get_family_expeditions(
        int64_t country_handle, int offset, int limit) const {
    return _economy_runtime == nullptr ? unavailable() :
        runtime_from(_economy_runtime)->family_expeditions(
            country_handle, offset, limit);
}

Dictionary DCWorldExt::get_family_expedition_snapshot(
        int64_t country_handle, int64_t expedition_handle) const {
    return _economy_runtime == nullptr ? unavailable() :
        runtime_from(_economy_runtime)->family_expedition_snapshot(
            country_handle, expedition_handle);
}

Dictionary DCWorldExt::get_family_colonization_receipts(
        int64_t country_handle, int64_t after_receipt_id, int limit) const {
    return _economy_runtime == nullptr ? unavailable() :
        runtime_from(_economy_runtime)->family_colonization_receipts(
            country_handle, after_receipt_id, limit);
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

Dictionary DCWorldExt::run_economy_stage_ops_day(int64_t day_index) {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    // Match run_economy_slice_internal: same-day env/building capture must land
    // before epoch open, or prelude parks as pending_input forever.
    const Dictionary cap =
        begin_or_reuse_economy_input_epoch(day_index, Dictionary());
    if (bool(cap.get("fatal", false))) {
        out["ok"] = false;
        out["done"] = true;
        out["fatal"] = true;
        out["day_index"] = day_index;
        out["reason"] = String(
            cap.get("fatal_reason", "economy_day_input_capture_failed"));
        out["message"] = out["reason"];
        out["stage"] = String(cap.get("stage", "economy_day_inputs"));
        return out;
    }
    std::string error;
    const bool ok =
        runtime_from(_economy_runtime)->run_stage_ops_day(day_index, error);
    out["ok"] = ok;
    out["done"] = ok;
    out["fatal"] = !ok;
    out["day_index"] = day_index;
    out["input_capture_reused"] = cap.get("input_capture_reused", false);
    out["input_captured"] = cap.get("captured", false);
    if (!ok) {
        out["reason"] = String(error.c_str());
        out["message"] = String(error.c_str());
    }
    return out;
}

void DCWorldExt::set_economy_stage_ops_soak_parity_ok(bool ok) {
    if (!_runtime_host) {
        _runtime_host = std::make_unique<NativeSimulationHost>();
    }
    _runtime_host->set_economy_stage_ops_soak_parity_ok(ok);
}

bool DCWorldExt::get_economy_stage_ops_soak_parity_ok() const {
    return _runtime_host != nullptr &&
           _runtime_host->economy_stage_ops_soak_parity_ok();
}

Dictionary DCWorldExt::inject_economy_cadence_timing(double market_cycle_ms,
                                                     double slow_cycle_ms,
                                                     double investment_cycle_ms) {
    if (_economy_runtime == nullptr) return unavailable();
    return runtime_from(_economy_runtime)->inject_cadence_timing(
        market_cycle_ms, slow_cycle_ms, investment_cycle_ms);
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
    Dictionary out = runtime_from(_economy_runtime)->reset(reason);
    if (static_cast<bool>(out.get("ok", false)))
        invalidate_economy_input_capture_cache(true);
    return out;
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

Dictionary DCWorldExt::capture_economy_ecp2(int flags) const {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "economy_runtime_unavailable";
        return out;
    }
    RuntimeEconomyEcp2State state;
    std::string error;
    if (!runtime_from(_economy_runtime)->capture_ecp2_authority(
            state, error, static_cast<uint32_t>(std::max(0, flags)))) {
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    std::vector<uint8_t> encoded;
    if (!encode_ecp2(state, encoded, error)) {
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    PackedByteArray bytes;
    bytes.resize(static_cast<int64_t>(encoded.size()));
    if (!encoded.empty()) std::memcpy(bytes.ptrw(), encoded.data(), encoded.size());
    out["ok"] = true;
    out["schema_version"] = state.schema_version;
    out["format"] = "ECP2";
    out["authority"] = "economy_owned_state_soa";
    out["authority_domain_mask"] = static_cast<int64_t>(state.authority_domain_mask);
    out["content_hash"] = static_cast<int64_t>(ecp2_wire_hash(bytes));
    out["catalog_hash"] = state.envelope.catalog_hash;
    out["committed_generation"] = static_cast<int64_t>(state.envelope.committed_generation);
    out["committed_day"] = state.envelope.last_committed_day;
    out["current_day"] = state.envelope.current_day;
    out["mid_epoch"] = (state.authority_domain_mask & ECP2_DOMAIN_EPOCH_RESUME) != 0;
    out["resume_stage"] = state.resume.native_stage;
    out["resume_cell_cursor"] = static_cast<int64_t>(state.resume.cell_cursor);
    out["bytes"] = bytes;
    out["byte_count"] = bytes.size();
    return out;
}

Dictionary DCWorldExt::restore_economy_ecp2(const PackedByteArray &bytes) {
    Dictionary out;
    if (_economy_runtime == nullptr) {
        out["ok"] = false;
        out["reason"] = "economy_runtime_unavailable";
        return out;
    }
    // Reject bare PKEC / ECP1 payloads at the host boundary.
    if (bytes.size() >= 4) {
        const uint32_t marker = static_cast<uint32_t>(bytes[0]) |
            (static_cast<uint32_t>(bytes[1]) << 8u) |
            (static_cast<uint32_t>(bytes[2]) << 16u) |
            (static_cast<uint32_t>(bytes[3]) << 24u);
        if (marker != RUNTIME_ECONOMY_ECP2_MARKER) {
            out["ok"] = false;
            if (marker == 0x31504345u) // "ECP1"
                out["reason"] = "restore_rejects_ecp1";
            else if (marker == 0x43454b50u) // "PKEC"
                out["reason"] = "restore_rejects_pkec";
            else
                out["reason"] = "restore_requires_ecp2";
            out["restore_rejected_reason"] = out["reason"];
            return out;
        }
    } else {
        out["ok"] = false;
        out["reason"] = "restore_requires_ecp2";
        out["restore_rejected_reason"] = out["reason"];
        return out;
    }
    RuntimeEconomyEcp2State state;
    std::string error;
    if (!decode_ecp2(bytes.ptr(), static_cast<size_t>(bytes.size()), state, error)) {
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        out["restore_rejected_reason"] = out["reason"];
        return out;
    }
    if (!runtime_from(_economy_runtime)->apply_ecp2_authority(state, error)) {
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        out["restore_rejected_reason"] = String(
            runtime_from(_economy_runtime)->restore_rejected_reason().c_str());
        return out;
    }
    invalidate_economy_input_capture_cache(true);
    out["ok"] = true;
    out["schema_version"] = state.schema_version;
    out["format"] = "ECP2";
    out["authority"] = "economy_owned_state_soa";
    out["authority_domain_mask"] = static_cast<int64_t>(state.authority_domain_mask);
    // The decoder has already verified this hash; expose it for audit and
    // save/restore continuity diagnostics.
    out["content_hash"] = static_cast<int64_t>(state.content_hash);
    out["committed_day"] = state.envelope.last_committed_day;
    out["current_day"] = state.envelope.current_day;
    out["mid_epoch"] = (state.authority_domain_mask & ECP2_DOMAIN_EPOCH_RESUME) != 0;
    out["restore_rejected_reason"] = "";
    return out;
}

Dictionary DCWorldExt::begin_economy_restore() {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    // Public streaming restore is ECP2-gated: begin_restore no longer clears
    // live state, and feed rejects until an ECP2/migrate path prepares scratch.
    Dictionary out = runtime_from(_economy_runtime)->begin_restore();
    if (static_cast<bool>(out.get("ok", false)))
        invalidate_economy_input_capture_cache(true);
    return out;
}

Dictionary DCWorldExt::begin_economy_restore_pkec_migrate() {
    if (_economy_runtime == nullptr) {
        return unavailable();
    }
    Dictionary out =
        runtime_from(_economy_runtime)->begin_restore_pkec_migrate();
    if (static_cast<bool>(out.get("ok", false)))
        invalidate_economy_input_capture_cache(true);
    return out;
}

String DCWorldExt::get_economy_restore_rejected_reason() const {
    if (_economy_runtime == nullptr) return String();
    return String(
        runtime_from(_economy_runtime)->restore_rejected_reason().c_str());
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
    Dictionary out = runtime_from(_economy_runtime)->end_restore();
    if (static_cast<bool>(out.get("ok", false)))
        invalidate_economy_input_capture_cache(true);
    return out;
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
