#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace pk::building_visual {

// Marks at most `cap` entries, lowest rank first; ties at the cutoff resolve
// in input order. Returns the kept count.
inline size_t select_by_rank(const std::vector<float> &ranks, size_t cap, std::vector<uint8_t> &keep) {
    keep.assign(ranks.size(), 1);
    if (ranks.size() <= cap) {
        return ranks.size();
    }
    std::vector<float> sorted = ranks;
    std::nth_element(sorted.begin(), sorted.begin() + static_cast<std::ptrdiff_t>(cap), sorted.end());
    const float cutoff = sorted[cap];
    size_t below = 0;
    for (float r : ranks) {
        if (r < cutoff) ++below;
    }
    size_t ties = cap - below;
    size_t kept = 0;
    for (size_t n = 0; n < ranks.size(); ++n) {
        bool take = ranks[n] < cutoff;
        if (!take && ranks[n] == cutoff && ties > 0) {
            take = true;
            --ties;
        }
        keep[n] = take ? 1 : 0;
        kept += take ? 1U : 0U;
    }
    return kept;
}

} // namespace pk::building_visual
