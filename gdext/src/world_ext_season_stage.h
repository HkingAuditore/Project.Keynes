#pragma once

#include "components/slot.h"

#include <functional>
#include <vector>
#include <godot_cpp/variant/dictionary.hpp>

namespace pk {

struct SeasonStageArrays {
    godot::PackedInt32Array neighbors, rows;
    godot::PackedFloat32Array latitude, season_offsets, jitter, donors, soil, growth_pressure;

    explicit SeasonStageArrays(const godot::Dictionary &knobs);
};

struct SeasonStageCounts {
    int touched;
    int snow_cells = 0;
};

struct PreparedSeasonStage {
    std::function<SeasonStageCounts()> compute;
    std::vector<int> slots;
    const char *reason = nullptr;
};

PreparedSeasonStage prepare_season_stage(
    const std::function<int(const char *)> &component, const std::function<Slot &(int)> &slot,
    const godot::Dictionary &knobs, SeasonStageArrays &arrays, int stage);
int season_kernel_stage(int round_stage);

} // namespace pk
