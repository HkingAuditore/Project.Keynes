#pragma once

#include <array>
#include <cstdint>
#include <vector>

namespace pk {
// Owned projection for the Economy input boundary; no live-store pointers.
struct RuntimeClimateCommittedView {
    uint64_t generation = 0;
    int64_t day = -1;
    bool committed = false;
    std::array<std::vector<float>, 8> fields;
    std::array<std::vector<uint8_t>, 4> categories;
};

// One consumer, one owner lifetime. Re-reading the same commit is allowed.
struct RuntimeClimateViewCursor {
    uint64_t generation = 0;
    int64_t day = -1;
    bool accepts(const RuntimeClimateCommittedView &view) const {
        return view.committed && view.generation >= generation && view.day >= day &&
            (view.generation != generation || view.day == day);
    }
    bool observe(const RuntimeClimateCommittedView &view) {
        if (!accepts(view)) return false;
        generation = view.generation;
        day = view.day;
        return true;
    }
};
} // namespace pk
