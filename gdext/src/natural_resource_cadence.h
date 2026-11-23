#pragma once

#include <algorithm>
#include <cstdint>
#include <vector>

namespace pk {

struct NaturalResourceRecoveryPlan {
    std::vector<int32_t> cells;
    std::vector<int32_t> elapsed_days;
    size_t live_count = 0;
};

inline constexpr int32_t NATURAL_RESOURCE_WILDERNESS_STRIDE = 60;
inline constexpr int32_t NATURAL_RESOURCE_LIVE_CATCHUP_LIMIT = 5;

inline NaturalResourceRecoveryPlan plan_natural_resource_recovery(
        int32_t day, const int32_t *live, size_t live_count, bool include_wilderness,
        const std::vector<int32_t> &last_day, const std::vector<uint8_t> &was_live,
        std::vector<uint8_t> &live_mark) {
    const auto count = static_cast<int32_t>(last_day.size());
    NaturalResourceRecoveryPlan plan;
    plan.cells.reserve(live_count + (include_wilderness ? count / NATURAL_RESOURCE_WILDERNESS_STRIDE + 1 : 0));
    plan.elapsed_days.reserve(plan.cells.capacity());
    auto add = [&](int32_t cell, int32_t limit) {
        if (last_day[cell] >= day) return;
        plan.cells.push_back(cell);
        plan.elapsed_days.push_back(std::clamp(day - last_day[cell], 1, limit));
    };
    for (size_t i = 0; i < live_count; ++i) {
        const int32_t cell = live[i];
        if (cell < 0 || cell >= count) continue;
        live_mark[cell] = 1;
        add(cell, was_live[cell] ? NATURAL_RESOURCE_LIVE_CATCHUP_LIMIT :
            NATURAL_RESOURCE_WILDERNESS_STRIDE);
    }
    plan.live_count = plan.cells.size();
    if (include_wilderness) {
        for (int32_t cell = day % NATURAL_RESOURCE_WILDERNESS_STRIDE; cell < count;
             cell += NATURAL_RESOURCE_WILDERNESS_STRIDE) {
            if (!live_mark[cell]) add(cell, NATURAL_RESOURCE_WILDERNESS_STRIDE);
        }
    }
    for (size_t i = 0; i < live_count; ++i) {
        const int32_t cell = live[i];
        if (cell >= 0 && cell < count) live_mark[cell] = 0;
    }
    return plan;
}

inline void commit_natural_resource_recovery(int32_t day, const NaturalResourceRecoveryPlan &plan,
        std::vector<int32_t> &last_day, std::vector<uint8_t> &was_live) {
    for (size_t i = 0; i < plan.cells.size(); ++i) {
        last_day[plan.cells[i]] = day;
        was_live[plan.cells[i]] = i < plan.live_count;
    }
}

} // namespace pk
