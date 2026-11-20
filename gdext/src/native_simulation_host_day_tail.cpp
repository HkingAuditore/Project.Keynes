#include "native_simulation_host.h"

#include "economy_runtime.h"
#include "runtime_vision.h"
#include "runtime_world_environment.h"
#include "world_ext_internal_cell_luts.h"

#include <utility>

namespace pk {

const char *NativeSimulationHost::stage_natural_resource_recovery(DayExecution &) {
    auto *economy = _economy_production_runtime;
    if (economy == nullptr || !economy_worker_owns_execution() ||
        !economy->worker_natural_resources_configured()) return nullptr;
    if (!economy->worker_resource_seeded()) return "resource_day_tail_not_seeded";

    // Production reads the recovered stock in the Economy stage, which also
    // folds in its extraction and cultivation. Finish that day's resource
    // publication here without asking a view consumer to drain the deltas.
    std::vector<size_t> lanes;
    std::vector<int64_t> deltas;
    economy->drain_building_resource_deltas(lanes, deltas);
    _executor_day_tail = std::make_shared<RuntimeDayTail>();
    _executor_day_tail->resource_recovery_cells = economy->worker_resource_recovered_cells();
    economy->take_worker_resource_mirror_cells(_executor_resource_display_cells);
    return nullptr;
}

// Called from publish_day with the display lock held until the commit is visible.
void NativeSimulationHost::merge_resource_display_patch() {
    if (_executor_resource_display_cells.empty()) return;
    const auto *economy = _economy_production_runtime;
    const size_t count = static_cast<size_t>(economy->cell_count());
    const auto &reserve = economy->worker_resource_reserve_lanes();
    const auto &extra = economy->worker_resource_extra_lanes();
    const size_t resource_count = economy->building_resource_reserve_slots().size();
    auto &patch = _resource_display_patch;
    for (const int32_t cell : _executor_resource_display_cells) {
        const auto [entry, inserted] = patch.offsets.try_emplace(cell, patch.reserve.size());
        const size_t offset = entry->second;
        if (inserted) {
            patch.cells.push_back(cell);
            patch.reserve.resize(offset + resource_count);
            patch.extra.resize(offset + resource_count);
        }
        for (size_t resource = 0; resource < resource_count; ++resource) {
            const size_t lane = resource * count + cell;
            patch.reserve[offset + resource] = reserve[lane];
            patch.extra[offset + resource] = extra[lane];
        }
    }
    _executor_resource_display_cells.clear();
}

bool NativeSimulationHost::has_resource_display_patch() const {
    std::lock_guard<std::mutex> lock(_resource_display_mutex);
    return !_resource_display_patch.cells.empty();
}

RuntimeResourceDisplayPatch NativeSimulationHost::take_resource_display_patch() {
    std::lock_guard<std::mutex> lock(_resource_display_mutex);
    return std::exchange(_resource_display_patch, {});
}

std::shared_ptr<const RuntimeCommit> NativeSimulationHost::take_day_publications(
        uint64_t after, std::deque<RuntimeDayRecord> &records, RuntimeResourceDisplayPatch &resources,
        RuntimeCellLutDelta &delta) {
    std::shared_ptr<const RuntimeCommit> latest;
    std::vector<uint8_t> dirty_cells;
    {
        std::lock_guard<std::mutex> lock(_resource_display_mutex);
        latest = std::atomic_load(&_latest_commit);
        if (!latest || latest->header.generation <= after) return {};
        records.swap(_published_days);
        resources = std::exchange(_resource_display_patch, {});
        dirty_cells.swap(_cell_lut_pending);
        _display_consumed_day.store(latest->header.committed_day, std::memory_order_release);
    }
    for (size_t cell = 0; cell < dirty_cells.size(); ++cell) {
        if (dirty_cells[cell] & 1) delta.cells.push_back(static_cast<int32_t>(cell));
        if (dirty_cells[cell] & 2) delta.class_cells.push_back(static_cast<int32_t>(cell));
    }
    return latest;
}

std::shared_ptr<const RuntimeClimateSnapshot> NativeSimulationHost::latest_climate_display() const {
    const auto latest = std::atomic_load(&_latest_commit);
    return latest && latest->day_tail ? latest->day_tail->climate : nullptr;
}

void NativeSimulationHost::publish_cell_lut_changes(RuntimeDayTail &tail, const RuntimeDayTail *previous) {
    const auto &state = tail.climate->payload;
    const size_t count = state.cell_count;
    if (state.terrain.size() != count || state.vegetation.size() != count ||
        state.cover.size() != count || state.weather_type.size() != count) return;

    const auto &opening_landform = _world_environment->opening_landform();
    const auto &prior = previous && previous->climate ? &previous->climate->payload : nullptr;
    const auto &old_age = previous ? &previous->cell_luts.transition_age : nullptr;
    const bool initialized = _cell_lut_words.size() == count;
    _cell_lut_words.resize(count);
    _executor_cell_lut_pending.assign(count, 0);
    auto &frame = tail.cell_luts;
    frame.previous_vitality.resize(count);
    frame.transition_age.resize(count);
    const uint8_t *water = _world_environment->water_terrain_lookup();
    for (size_t cell = 0; cell < count; ++cell) {
        const uint8_t terrain = state.terrain[cell];
        const uint8_t vegetation = state.vegetation[cell];
        const uint8_t fog = tail.vision && tail.vision->fog_enabled ? tail.vision->fog[cell] : 255;
        const uint8_t landform = tail.climate->season && tail.climate->season->landform.size() == count
            ? tail.climate->season->landform[cell] : opening_landform[cell];
        const float temp = state.temperature[cell];
        const float moisture = state.moisture[cell];
        const float snow = state.snow_cover[cell];
        const float vitality = state.vegetation_vitality[cell];
        const auto cur_vitality = uint8_t(pk_q01_byte(vitality));
        const bool has_prior = prior && prior->vegetation.size() == count && old_age && old_age->size() == count;
        const uint8_t prev_veg = has_prior ? prior->vegetation[cell] : vegetation;
        const auto prev_vitality = has_prior
            ? uint8_t(pk_q01_byte(prior->vegetation_vitality[cell])) : cur_vitality;
        const auto age = uint8_t(prev_veg != vegetation ? 255 : has_prior
            ? std::max(0, int((*old_age)[cell]) - 18) : 0);
        frame.previous_vitality[cell] = prev_vitality;
        frame.transition_age[cell] = age;

        const uint32_t classes = uint32_t(terrain) | (uint32_t(vegetation) << 8) |
            (uint32_t(state.cover[cell]) << 16) | (uint32_t(fog) << 24);
        const uint32_t dynamics = pk_atlas_sig_dynamic(temp, moisture, snow, vitality,
            state.sea_ice[cell], water[terrain] != 0);
        const uint32_t ecology = pk_atlas_sig_ecology(temp, moisture, snow, vitality, vegetation,
            water[terrain] != 0, age, prev_vitality, 0);
        const uint32_t weather = uint32_t(state.weather_type[cell]) |
            (uint32_t(pk_q01_byte(state.weather_intensity[cell])) << 8) |
            (uint32_t(pk_q01_byte(state.cloud_cover[cell])) << 16) |
            (uint32_t(pk_q01_byte(state.vapor[cell])) << 24);
        const auto &season = previous && previous->climate ? previous->climate->season : nullptr;
        const uint8_t old_landform = season && season->landform.size() == count
            ? season->landform[cell] : opening_landform[cell];
        const std::array<uint32_t, 4> words{classes, dynamics, ecology, weather};
        if (!initialized || classes != _cell_lut_words[cell][0] || old_landform != landform)
            _executor_cell_lut_pending[cell] |= 3;
        else if (words != _cell_lut_words[cell] || age != 0)
            _executor_cell_lut_pending[cell] |= 1;
        _cell_lut_words[cell] = words;
    }
}

void NativeSimulationHost::reset_day_tail_for_world_change() {
    _world_environment.reset();
    _executor_narrative.reset();
    _restored_narrative = godot::Dictionary();
    std::atomic_store(&_published_narrative, std::shared_ptr<const RuntimeNarrativeView>());
    _clock_requested_day.store(-1, std::memory_order_release);
    _executor_bio.reset();
    _executor_vision.reset();
    if (const auto last = std::atomic_load(&_latest_commit); last && last->day_tail) {
        auto header = std::make_shared<RuntimeCommit>(*last);
        header->day_tail.reset();
        std::atomic_store(&_latest_commit, std::shared_ptr<const RuntimeCommit>(std::move(header)));
    }
    _executor_day_tail.reset();
    _executor_resource_display_cells.clear();
    _published_days.clear();
    _cell_lut_words.clear();
    _cell_lut_pending.clear();
    _executor_cell_lut_pending.clear();
    take_resource_display_patch();
}

} // namespace pk
