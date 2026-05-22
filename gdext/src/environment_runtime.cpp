#include "environment_runtime.h"

#include <algorithm>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/classes/time.hpp>

namespace pk {

using namespace godot;

EnvironmentRuntime::EnvironmentRuntime() = default;
EnvironmentRuntime::~EnvironmentRuntime() = default;

void EnvironmentRuntime::_resize_f32(std::vector<float> &v, int n, float fill) {
    v.assign(std::max(0, n), fill);
}

void EnvironmentRuntime::_resize_i32(std::vector<int32_t> &v, int n, int32_t fill) {
    v.assign(std::max(0, n), fill);
}

void EnvironmentRuntime::_resize_u8(std::vector<uint8_t> &v, int n, uint8_t fill) {
    v.assign(std::max(0, n), fill);
}

bool EnvironmentRuntime::_is_water_idx(int idx) const {
    return idx >= 0 && idx < (int)_terrain_mask.size() && _terrain_mask[idx] != 0;
}

void EnvironmentRuntime::_append_unique_dirty(int idx) {
    if (idx < 0 || idx >= _cell_count) return;
    if (idx >= (int)_climate_dirty_mask.size()) return;
    if (_climate_dirty_mask[idx] == 0) {
        _dirty_climate_indices.push_back(idx);
    }
    _climate_dirty_mask[idx] = 1;
}

void EnvironmentRuntime::_append_unique_weather_active(int idx) {
    if (idx < 0 || idx >= _cell_count) return;
    if (idx >= (int)_weather_dirty_mask.size()) return;
    if (_weather_dirty_mask[idx] == 0) {
        _active_weather_indices.push_back(idx);
    }
    _weather_dirty_mask[idx] = 1;
}

void EnvironmentRuntime::_allocate_buffers(int cell_count, int pixel_count) {
    _resize_f32(_elevation, cell_count);
    _resize_f32(_temperature, cell_count);
    _resize_f32(_moisture, cell_count);
    _resize_f32(_pressure, cell_count);
    _resize_f32(_wind_x, cell_count);
    _resize_f32(_wind_y, cell_count);
    _resize_f32(_wind_speed, cell_count);
    _resize_f32(_ocean_x, cell_count);
    _resize_f32(_ocean_y, cell_count);
    _resize_f32(_ocean_speed, cell_count);

    _resize_f32(_weather_vapor_a, cell_count);
    _resize_f32(_weather_vapor_b, cell_count);
    _resize_f32(_weather_cloud_a, cell_count);
    _resize_f32(_weather_cloud_b, cell_count);
    _resize_f32(_weather_precip_a, cell_count);
    _resize_f32(_weather_precip_b, cell_count);

    _resize_u8(_climate_dirty_mask, cell_count, 1);
    _resize_u8(_weather_dirty_mask, cell_count, 1);
    _resize_u8(_terrain_mask, cell_count, 0);

    _active_weather_indices.clear();
    _dirty_climate_indices.clear();
    _water_indices.clear();
    _coastal_indices.clear();
    _resize_i32(_neighbor_indices, cell_count * 6, -1);
    _resize_i32(_pixel_to_cell, pixel_count, -1);
}

void EnvironmentRuntime::_build_default_stages() {
    _stages.clear();
    StageState climate;
    climate.name = "climate_dirty_scan";
    climate.substage = _all_dirty ? "full" : "dirty_list";
    climate.total = _all_dirty ? _cell_count : (int)_dirty_climate_indices.size();
    climate.kind = 0;
    _stages.push_back(climate);

    StageState weather;
    weather.name = "weather_active_scan";
    weather.substage = _all_dirty ? "full" : "active_list";
    weather.total = _all_dirty ? _cell_count : (int)_active_weather_indices.size();
    weather.kind = 0;
    _stages.push_back(weather);

    StageState ocean;
    ocean.name = "ocean_water_scan";
    ocean.substage = "water_indices";
    ocean.total = (int)_water_indices.size();
    ocean.kind = 2;
    _stages.push_back(ocean);

    StageState raster;
    raster.name = "raster_dirty_scan";
    raster.substage = _pixel_to_cell.empty() ? "no_pixel_map" : "pixel_to_cell";
    raster.total = _pixel_to_cell.empty() ? _pixel_count : (int)_pixel_to_cell.size();
    raster.kind = 1;
    _stages.push_back(raster);

    _stage_index = 0;
}

void EnvironmentRuntime::_build_ocean_stages(bool include_raster) {
    _stages.clear();
    auto add_stage = [this](const char *name, const char *substage, int total, int kind) {
        StageState s;
        s.name = name;
        s.substage = substage;
        s.total = std::max(0, total);
        s.kind = kind;
        _stages.push_back(s);
    };
    int water_n = (int)_water_indices.size();
    int coastal_n = (int)_coastal_indices.size();
    add_stage("ocean_phys_slp", "water_indices", water_n, 2);
    add_stage("ocean_phys_wind", "water_and_coast", water_n + coastal_n, 2);
    add_stage("ocean_phys_psi_init", "water_indices", water_n, 2);
    add_stage("ocean_phys_psi_iters", "water_indices", water_n * 4, 2);
    add_stage("ocean_phys_psi_finalize", "water_indices", water_n, 2);
    add_stage("ocean_phys_upwelling", "water_indices", water_n, 2);
    if (include_raster) {
        add_stage("ocean_wind_raster", "pixel_range", _pixel_count, 1);
        add_stage("ocean_current_raster", "pixel_range", _pixel_count, 1);
    }
    add_stage("ocean_dirty_tiles", "tile_generation", std::max(1, (_pixel_count + _ocean_dirty_tile_size - 1) / _ocean_dirty_tile_size), 2);
    _stage_index = 0;
}

void EnvironmentRuntime::_build_weather_stages(bool use_active_list) {
    _stages.clear();
    auto add_stage = [this](const char *name, const char *substage, int total, int kind) {
        StageState s;
        s.name = name;
        s.substage = substage;
        s.total = std::max(0, total);
        s.kind = kind;
        _stages.push_back(s);
    };
    int active_n = use_active_list && !_active_weather_indices.empty() ? (int)_active_weather_indices.size() : _cell_count;
    add_stage("weather_active_prepare", use_active_list ? "active_indices" : "full", active_n, 0);
    add_stage("weather_field_solve", use_active_list ? "prev_next_active" : "prev_next_full", active_n, 0);
    add_stage("weather_halo_solve", "neighbor_halo", active_n, 0);
    add_stage("weather_summary_fronts", "tile_aggregate", std::max(1, active_n / 64), 2);
    add_stage("weather_publish", "swap_pingpong", 1, 2);
    _stage_index = 0;
}

void EnvironmentRuntime::_build_climate_stages(bool use_dirty_list) {
    _stages.clear();
    auto add_stage = [this](const char *name, const char *substage, int total, int kind) {
        StageState s;
        s.name = name;
        s.substage = substage;
        s.total = std::max(0, total);
        s.kind = kind;
        _stages.push_back(s);
    };
    int dirty_n = use_dirty_list && !_dirty_climate_indices.empty() ? (int)_dirty_climate_indices.size() : _cell_count;
    int water_n = (int)_water_indices.size();
    int coastal_n = (int)_coastal_indices.size();
    add_stage("climate_pass_a", use_dirty_list ? "dirty_or_full" : "full", dirty_n, 0);
    add_stage("climate_pass_b", use_dirty_list ? "dirty_halo" : "full", dirty_n, 0);
    add_stage("climate_ocean_water", "water_indices", water_n, 2);
    add_stage("climate_ocean_land", "coastal_indices", coastal_n, 2);
    add_stage("climate_sea_ice", "cold_water_candidates", water_n, 2);
    add_stage("climate_transpiration", use_dirty_list ? "dirty_or_full" : "full", dirty_n, 0);
    _stage_index = 0;
}

EnvironmentRuntime::StageState *EnvironmentRuntime::_current_stage() {
    if (_stage_index < 0 || _stage_index >= (int)_stages.size()) return nullptr;
    return &_stages[_stage_index];
}

const EnvironmentRuntime::StageState *EnvironmentRuntime::_current_stage() const {
    if (_stage_index < 0 || _stage_index >= (int)_stages.size()) return nullptr;
    return &_stages[_stage_index];
}

void EnvironmentRuntime::_reset_runtime_state(bool topology_changed) {
    _all_dirty = true;
    _topology_valid = !topology_changed && _topology_valid;
    _active_weather_indices.clear();
    _dirty_climate_indices.clear();
    if (topology_changed) {
        _water_indices.clear();
        _coastal_indices.clear();
        std::fill(_neighbor_indices.begin(), _neighbor_indices.end(), -1);
        std::fill(_pixel_to_cell.begin(), _pixel_to_cell.end(), -1);
    }
    reset_stage_progress();
}

void EnvironmentRuntime::initialize(int cell_count, int pixel_count) {
    rebuild(cell_count, pixel_count, true);
}

void EnvironmentRuntime::initialize_with_sizes(int cell_count, Vector2i pixel_size) {
    _pixel_size = pixel_size;
    int pixel_count = std::max(0, pixel_size.x) * std::max(0, pixel_size.y);
    rebuild(cell_count, pixel_count, true);
}

void EnvironmentRuntime::rebuild(int cell_count, int pixel_count, bool topology_changed) {
    if (cell_count < 0 || pixel_count < 0) {
        ERR_PRINT("[EnvironmentRuntime] rebuild received negative sizes");
        cell_count = std::max(0, cell_count);
        pixel_count = std::max(0, pixel_count);
    }
    _cell_count = cell_count;
    _pixel_count = pixel_count;
    if (_pixel_size.x <= 0 || _pixel_size.y <= 0 || (_pixel_size.x * _pixel_size.y) != pixel_count) {
        _pixel_size = Vector2i(pixel_count, pixel_count > 0 ? 1 : 0);
    }
    _allocate_buffers(_cell_count, _pixel_count);
    _reset_runtime_state(topology_changed);
    _initialized = true;
    _snapshot_version += 1;
    _rebuild_generation += 1;
}

void EnvironmentRuntime::rebuild_for_map(int width, int height, Vector2i pixel_size) {
    int cell_count = std::max(0, width) * std::max(0, height);
    _pixel_size = pixel_size;
    int pixel_count = std::max(0, pixel_size.x) * std::max(0, pixel_size.y);
    rebuild(cell_count, pixel_count, true);
}

void EnvironmentRuntime::clear() {
    _initialized = false;
    _cell_count = 0;
    _pixel_count = 0;
    _pixel_size = Vector2i();
    _snapshot_version += 1;
    _rebuild_generation += 1;
    _elevation.clear();
    _temperature.clear();
    _moisture.clear();
    _pressure.clear();
    _wind_x.clear();
    _wind_y.clear();
    _wind_speed.clear();
    _ocean_x.clear();
    _ocean_y.clear();
    _ocean_speed.clear();
    _weather_vapor_a.clear();
    _weather_vapor_b.clear();
    _weather_cloud_a.clear();
    _weather_cloud_b.clear();
    _weather_precip_a.clear();
    _weather_precip_b.clear();
    _climate_dirty_mask.clear();
    _weather_dirty_mask.clear();
    _terrain_mask.clear();
    _active_weather_indices.clear();
    _dirty_climate_indices.clear();
    _water_indices.clear();
    _coastal_indices.clear();
    _neighbor_indices.clear();
    _pixel_to_cell.clear();
    _topology_valid = false;
    _all_dirty = true;
}

void EnvironmentRuntime::bind_core_buffers(PackedFloat32Array elevation,
                                           PackedFloat32Array temperature,
                                           PackedFloat32Array moisture,
                                           PackedFloat32Array pressure,
                                           PackedFloat32Array wind_x,
                                           PackedFloat32Array wind_y,
                                           PackedFloat32Array ocean_x,
                                           PackedFloat32Array ocean_y) {
    int n = (int)elevation.size();
    n = std::max(n, (int)temperature.size());
    n = std::max(n, (int)moisture.size());
    n = std::max(n, (int)pressure.size());
    n = std::max(n, (int)wind_x.size());
    n = std::max(n, (int)wind_y.size());
    n = std::max(n, (int)ocean_x.size());
    n = std::max(n, (int)ocean_y.size());
    if (!_initialized || n != _cell_count) {
        rebuild(n, _pixel_count, false);
    }
    for (int i = 0; i < _cell_count; ++i) {
        _elevation[i] = i < elevation.size() ? elevation[i] : 0.0f;
        _temperature[i] = i < temperature.size() ? temperature[i] : 0.0f;
        _moisture[i] = i < moisture.size() ? moisture[i] : 0.0f;
        _pressure[i] = i < pressure.size() ? pressure[i] : 0.0f;
        _wind_x[i] = i < wind_x.size() ? wind_x[i] : 0.0f;
        _wind_y[i] = i < wind_y.size() ? wind_y[i] : 0.0f;
        _ocean_x[i] = i < ocean_x.size() ? ocean_x[i] : 0.0f;
        _ocean_y[i] = i < ocean_y.size() ? ocean_y[i] : 0.0f;
        _wind_speed[i] = 0.0f;
        _ocean_speed[i] = 0.0f;
    }
    mark_all_dirty();
}

void EnvironmentRuntime::bind_weather_buffers(PackedFloat32Array vapor,
                                              PackedFloat32Array cloud,
                                              PackedFloat32Array precip) {
    int n = (int)vapor.size();
    n = std::max(n, (int)cloud.size());
    n = std::max(n, (int)precip.size());
    if (!_initialized || n != _cell_count) {
        rebuild(n, _pixel_count, false);
    }
    for (int i = 0; i < _cell_count; ++i) {
        float v = i < vapor.size() ? vapor[i] : 0.0f;
        float c = i < cloud.size() ? cloud[i] : 0.0f;
        float p = i < precip.size() ? precip[i] : 0.0f;
        _weather_vapor_a[i] = v;
        _weather_vapor_b[i] = v;
        _weather_cloud_a[i] = c;
        _weather_cloud_b[i] = c;
        _weather_precip_a[i] = p;
        _weather_precip_b[i] = p;
    }
    _weather_pingpong_a_is_prev = true;
    mark_all_dirty();
}

void EnvironmentRuntime::build_topology_from_arrays(PackedInt32Array neighbors,
                                                    PackedByteArray is_water,
                                                    PackedByteArray terrain_mask,
                                                    PackedInt32Array pixel_to_cell) {
    int inferred_cells = (int)is_water.size();
    if (inferred_cells <= 0 && neighbors.size() >= 6) {
        inferred_cells = (int)neighbors.size() / 6;
    }
    if (!_initialized || inferred_cells != _cell_count) {
        rebuild(inferred_cells, pixel_to_cell.size() > 0 ? (int)pixel_to_cell.size() : _pixel_count, true);
    }
    if (neighbors.size() >= _cell_count * 6) {
        _neighbor_indices.resize(_cell_count * 6);
        for (int i = 0; i < _cell_count * 6; ++i) {
            _neighbor_indices[i] = (int32_t)neighbors[i];
        }
    } else {
        std::fill(_neighbor_indices.begin(), _neighbor_indices.end(), -1);
    }

    _terrain_mask.resize(_cell_count);
    for (int i = 0; i < _cell_count; ++i) {
        uint8_t water = 0;
        if (i < is_water.size()) {
            water = is_water[i] != 0 ? 1 : 0;
        } else if (i < terrain_mask.size()) {
            water = terrain_mask[i] != 0 ? 1 : 0;
        }
        _terrain_mask[i] = water;
    }

    _water_indices.clear();
    _coastal_indices.clear();
    for (int i = 0; i < _cell_count; ++i) {
        if (_terrain_mask[i] != 0) {
            _water_indices.push_back(i);
            continue;
        }
        bool touches_water = false;
        int base = i * 6;
        for (int d = 0; d < 6; ++d) {
            int nb = base + d < (int)_neighbor_indices.size() ? _neighbor_indices[base + d] : -1;
            if (_is_water_idx(nb)) {
                touches_water = true;
                break;
            }
        }
        if (touches_water) {
            _coastal_indices.push_back(i);
        }
    }

    if (pixel_to_cell.size() > 0) {
        _pixel_count = (int)pixel_to_cell.size();
        _pixel_to_cell.resize(_pixel_count);
        for (int i = 0; i < _pixel_count; ++i) {
            _pixel_to_cell[i] = (int32_t)pixel_to_cell[i];
        }
    }
    _topology_valid = true;
    mark_all_dirty();
}

void EnvironmentRuntime::mark_cells_dirty(PackedInt32Array indices, const String &reason) {
    if (!_initialized) return;
    for (int i = 0; i < indices.size(); ++i) {
        int idx = (int)indices[i];
        _append_unique_dirty(idx);
        _append_unique_weather_active(idx);
        int base = idx * 6;
        for (int d = 0; d < 6; ++d) {
            int nb = base + d < (int)_neighbor_indices.size() ? _neighbor_indices[base + d] : -1;
            _append_unique_weather_active(nb);
        }
    }
    if (!reason.is_empty()) {
        _all_dirty = false;
    }
}

void EnvironmentRuntime::mark_region_dirty(int start_idx, int end_idx, const String &reason) {
    if (!_initialized) return;
    int a = std::max(0, std::min(start_idx, end_idx));
    int b = std::min(_cell_count, std::max(start_idx, end_idx));
    for (int i = a; i < b; ++i) {
        _append_unique_dirty(i);
        _append_unique_weather_active(i);
    }
    if (!reason.is_empty()) {
        _all_dirty = false;
    }
}

void EnvironmentRuntime::begin_round(const String &round_name) {
    if (!_initialized) return;
    _round_name = round_name;
    _round_active = true;
    _last_processed = 0;
    _last_elapsed_ms = 0.0;
    _build_default_stages();
}

void EnvironmentRuntime::begin_ocean_round(bool include_raster) {
    if (!_initialized) return;
    _round_name = "ocean_native_pipeline";
    _round_active = true;
    _ocean_round_active = true;
    _ocean_include_raster = include_raster;
    _last_processed = 0;
    _last_elapsed_ms = 0.0;
    _ocean_dirty_tiles.clear();
    _build_ocean_stages(include_raster);
}

void EnvironmentRuntime::begin_weather_round(bool use_active_list) {
    if (!_initialized) return;
    _round_name = "weather_native_solver";
    _round_active = true;
    _weather_round_active = true;
    _weather_use_active_list = use_active_list;
    _last_processed = 0;
    _last_elapsed_ms = 0.0;
    _build_weather_stages(use_active_list);
}

void EnvironmentRuntime::begin_climate_round(bool use_dirty_list) {
    if (!_initialized) return;
    _round_name = "climate_native_daily";
    _round_active = true;
    _climate_round_active = true;
    _climate_use_dirty_list = use_dirty_list;
    _last_processed = 0;
    _last_elapsed_ms = 0.0;
    _build_climate_stages(use_dirty_list);
}

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

bool EnvironmentRuntime::is_round_done() const {
    return !_round_active;
}

void EnvironmentRuntime::reset_stage_progress() {
    _stages.clear();
    _stage_index = 0;
    _round_active = false;
    _ocean_round_active = false;
    _weather_round_active = false;
    _climate_round_active = false;
    _last_processed = 0;
    _last_elapsed_ms = 0.0;
}

void EnvironmentRuntime::publish_snapshot() {
    if (!_initialized) return;
    _snapshot_version += 1;
    _all_dirty = false;
}

void EnvironmentRuntime::mark_all_dirty() {
    if (!_initialized) return;
    std::fill(_climate_dirty_mask.begin(), _climate_dirty_mask.end(), 1);
    std::fill(_weather_dirty_mask.begin(), _weather_dirty_mask.end(), 1);
    _dirty_climate_indices.clear();
    _active_weather_indices.clear();
    _all_dirty = true;
}

void EnvironmentRuntime::clear_dirty() {
    std::fill(_climate_dirty_mask.begin(), _climate_dirty_mask.end(), 0);
    std::fill(_weather_dirty_mask.begin(), _weather_dirty_mask.end(), 0);
    _dirty_climate_indices.clear();
    _active_weather_indices.clear();
    _all_dirty = false;
}

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
    d["dirty_climate_indices"] = (int)_dirty_climate_indices.size();
    d["active_weather_indices"] = (int)_active_weather_indices.size();
    d["ocean_dirty_tiles"] = (int)_ocean_dirty_tiles.size();
    d["worker_threads_enabled"] = false;
    d["godot_object_access"] = "main_thread_only";
    d["runtime_thread_model"] = "single_thread_budgeted";
    return d;
}

void EnvironmentRuntime::restore_runtime_state(const Dictionary &state) {
    _snapshot_version = int(state.get("snapshot_version", _snapshot_version));
    _weather_snapshot_version = int(state.get("weather_snapshot_version", _weather_snapshot_version));
    _climate_snapshot_version = int(state.get("climate_snapshot_version", _climate_snapshot_version));
    _rebuild_generation = int(state.get("rebuild_generation", _rebuild_generation));
    _all_dirty = bool(state.get("all_dirty", _all_dirty));
    _topology_valid = bool(state.get("topology_valid", _topology_valid));
    _ocean_round_active = bool(state.get("ocean_round_active", false));
    _weather_round_active = bool(state.get("weather_round_active", false));
    _climate_round_active = bool(state.get("climate_round_active", false));
    _round_active = bool(state.get("round_active", false));
    _round_name = String(state.get("round_name", String()));
    _stage_index = int(state.get("stage_index", 0));
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
    _stage_index = std::max(0, std::min(_stage_index, (int)_stages.size()));
    StageState *stage = _current_stage();
    if (stage != nullptr) {
        stage->cursor = std::max(0, std::min(int(state.get("stage_cursor", stage->cursor)), stage->total));
    }
}

void EnvironmentRuntime::_bind_methods() {
    ClassDB::bind_method(D_METHOD("initialize", "cell_count", "pixel_count"), &EnvironmentRuntime::initialize);
    ClassDB::bind_method(D_METHOD("initialize_with_sizes", "cell_count", "pixel_size"), &EnvironmentRuntime::initialize_with_sizes);
    ClassDB::bind_method(D_METHOD("rebuild", "cell_count", "pixel_count", "topology_changed"), &EnvironmentRuntime::rebuild, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("rebuild_for_map", "width", "height", "pixel_size"), &EnvironmentRuntime::rebuild_for_map);
    ClassDB::bind_method(D_METHOD("clear"), &EnvironmentRuntime::clear);
    ClassDB::bind_method(D_METHOD("is_initialized"), &EnvironmentRuntime::is_initialized);
    ClassDB::bind_method(D_METHOD("get_cell_count"), &EnvironmentRuntime::get_cell_count);
    ClassDB::bind_method(D_METHOD("get_pixel_count"), &EnvironmentRuntime::get_pixel_count);
    ClassDB::bind_method(D_METHOD("get_pixel_size"), &EnvironmentRuntime::get_pixel_size);
    ClassDB::bind_method(D_METHOD("get_snapshot_version"), &EnvironmentRuntime::get_snapshot_version);
    ClassDB::bind_method(D_METHOD("get_rebuild_generation"), &EnvironmentRuntime::get_rebuild_generation);
    ClassDB::bind_method(D_METHOD("bind_core_buffers", "elevation", "temperature", "moisture", "pressure", "wind_x", "wind_y", "ocean_x", "ocean_y"), &EnvironmentRuntime::bind_core_buffers);
    ClassDB::bind_method(D_METHOD("bind_weather_buffers", "vapor", "cloud", "precip"), &EnvironmentRuntime::bind_weather_buffers);
    ClassDB::bind_method(D_METHOD("build_topology_from_arrays", "neighbors", "is_water", "terrain_mask", "pixel_to_cell"), &EnvironmentRuntime::build_topology_from_arrays, DEFVAL(PackedInt32Array()));
    ClassDB::bind_method(D_METHOD("mark_cells_dirty", "indices", "reason"), &EnvironmentRuntime::mark_cells_dirty, DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("mark_region_dirty", "start_idx", "end_idx", "reason"), &EnvironmentRuntime::mark_region_dirty, DEFVAL(String()));
    ClassDB::bind_method(D_METHOD("begin_round", "round_name"), &EnvironmentRuntime::begin_round, DEFVAL(String("environment")));
    ClassDB::bind_method(D_METHOD("step_budgeted", "budget_ms", "max_cells", "max_pixels", "max_indices"), &EnvironmentRuntime::step_budgeted, DEFVAL(0.5), DEFVAL(0), DEFVAL(0), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("begin_ocean_round", "include_raster"), &EnvironmentRuntime::begin_ocean_round, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("step_ocean_budgeted", "budget_ms", "max_cells", "max_pixels", "max_indices"), &EnvironmentRuntime::step_ocean_budgeted, DEFVAL(0.75), DEFVAL(0), DEFVAL(0), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("consume_ocean_dirty_tiles"), &EnvironmentRuntime::consume_ocean_dirty_tiles);
    ClassDB::bind_method(D_METHOD("begin_weather_round", "use_active_list"), &EnvironmentRuntime::begin_weather_round, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("step_weather_budgeted", "budget_ms", "max_cells", "max_pixels", "max_indices"), &EnvironmentRuntime::step_weather_budgeted, DEFVAL(0.55), DEFVAL(0), DEFVAL(0), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("begin_climate_round", "use_dirty_list"), &EnvironmentRuntime::begin_climate_round, DEFVAL(true));
    ClassDB::bind_method(D_METHOD("step_climate_budgeted", "budget_ms", "max_cells", "max_pixels", "max_indices"), &EnvironmentRuntime::step_climate_budgeted, DEFVAL(0.75), DEFVAL(0), DEFVAL(0), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("is_round_done"), &EnvironmentRuntime::is_round_done);
    ClassDB::bind_method(D_METHOD("reset_stage_progress"), &EnvironmentRuntime::reset_stage_progress);
    ClassDB::bind_method(D_METHOD("publish_snapshot"), &EnvironmentRuntime::publish_snapshot);
    ClassDB::bind_method(D_METHOD("mark_all_dirty"), &EnvironmentRuntime::mark_all_dirty);
    ClassDB::bind_method(D_METHOD("clear_dirty"), &EnvironmentRuntime::clear_dirty);
    ClassDB::bind_method(D_METHOD("status"), &EnvironmentRuntime::status);
    ClassDB::bind_method(D_METHOD("buffer_summary"), &EnvironmentRuntime::buffer_summary);
    ClassDB::bind_method(D_METHOD("snapshot_summary"), &EnvironmentRuntime::snapshot_summary);
    ClassDB::bind_method(D_METHOD("topology_summary"), &EnvironmentRuntime::topology_summary);
    ClassDB::bind_method(D_METHOD("progress_summary"), &EnvironmentRuntime::progress_summary);
    ClassDB::bind_method(D_METHOD("export_runtime_state"), &EnvironmentRuntime::export_runtime_state);
    ClassDB::bind_method(D_METHOD("restore_runtime_state", "state"), &EnvironmentRuntime::restore_runtime_state);
}

} // namespace pk
