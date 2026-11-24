#pragma once

#include "economy_runtime.h"

#include <algorithm>
#include <vector>

namespace pk {

// Shared by the map batch and selected-cell population queries.
struct EconomyCellClassSatisfaction {
    static constexpr int64_t ONE = NativeEconomyRuntime::Q16_ONE;
    static constexpr int64_t DISCONTENT_THRESHOLD = ONE * 3 / 5;

    struct Worst {
        int32_t class_index = -1;
        int32_t severity_q16 = 0;

        bool discontent() const { return severity_q16 >= DISCONTENT_THRESHOLD; }
    };

    explicit EconomyCellClassSatisfaction(size_t count) : headcounts(count), weighted(count) {}

    void clear() {
        std::fill(headcounts.begin(), headcounts.end(), 0);
        std::fill(weighted.begin(), weighted.end(), 0);
    }

    template <typename Add, typename Multiply>
    void accumulate(int32_t profession, const std::vector<int32_t> &profession_classes,
                    int64_t people, int64_t satisfaction, int64_t &saturation,
                    Add add, Multiply multiply) {
        if (people <= 0 || profession < 0 ||
            static_cast<size_t>(profession) >= profession_classes.size()) return;
        const int32_t index = profession_classes[profession];
        if (index < 0 || static_cast<size_t>(index) >= headcounts.size()) return;
        headcounts[index] = add(headcounts[index], people, saturation);
        weighted[index] = add(weighted[index], multiply(people, satisfaction, saturation), saturation);
    }

    Worst worst() const {
        Worst result;
        int64_t lowest = ONE;
        for (size_t index = 0; index < headcounts.size(); ++index) {
            if (headcounts[index] <= 0) continue;
            const int64_t value = weighted[index] / headcounts[index];
            if (value < lowest) {
                lowest = value;
                result.class_index = static_cast<int32_t>(index);
            }
        }
        if (result.class_index >= 0)
            result.severity_q16 = static_cast<int32_t>(ONE - 1 - lowest);
        return result;
    }

    std::vector<int64_t> headcounts;

private:
    std::vector<int64_t> weighted;
};

} // namespace pk
