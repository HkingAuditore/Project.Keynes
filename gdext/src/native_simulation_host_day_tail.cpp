#include "native_simulation_host.h"

#include "economy_runtime.h"

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

void NativeSimulationHost::reset_day_tail_for_world_change() {
    _world_environment.reset();
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
    take_resource_display_patch();
}

} // namespace pk
