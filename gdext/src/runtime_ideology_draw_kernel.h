#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace pk {

// Weighted non-replacement draw shared by NativeIdeologyRuntime (main thread)
// and RuntimeIdeologyPodAuthority (worker). Both authorities replay the same
// command log and assert an identical catalog hash, so the selection maths has
// to live in exactly one place: any divergence here shows up as a replay
// mismatch several hundred days later, which is miserable to debug.
//
// This header is deliberately Godot-free so it can be included from either
// runtime without dragging in godot-cpp.

// Decay is expressed on the same x10000 scale as the authored rarity weight, so
// dec_w = rarity_decay_bp * decay_bp stays integral: a rarity-1 card at 60%
// decay weighs 6000, not 0. Dividing down to `rarity_weight * decay / 10000`
// would truncate every low-rarity card out of the pool on its first old era.
struct IdeologyDrawCandidate {
    int32_t id = -1;
    int64_t weight = 0;
};

// decay_bp[0] is the card's own era (10000 = full weight); the last entry is
// reused for anything older. An empty table means "no decay at all", which is
// what a catalog authored before eras existed looks like.
inline int64_t ideology_draw_weight(int64_t rarity_weight, const int32_t *decay_bp,
        size_t decay_count, int32_t unlocked_era, int32_t era_index) {
    if (rarity_weight <= 0) return 0;
    if (decay_count == 0) return rarity_weight * 10000;
    const int64_t age = static_cast<int64_t>(unlocked_era) - static_cast<int64_t>(era_index);
    // age < 0 means the card belongs to an era the player has not reached. The
    // era milestone technology gate is supposed to have removed it already; to
    // be safe we weight it out rather than silently offering a future card.
    if (age < 0) return 0;
    const size_t row = age >= static_cast<int64_t>(decay_count)
        ? decay_count - 1 : static_cast<size_t>(age);
    const int64_t decay = static_cast<int64_t>(decay_bp[row]);
    if (decay <= 0) return 0;
    return rarity_weight * decay;
}

// Draws up to `count` distinct rows out of `pool`, mutating it as it goes. The
// RNG advances exactly once per successful draw, which is the pre-existing
// behaviour: keeping it identical matters for replay determinism.
template <typename NextRandom>
inline int32_t ideology_weighted_draw(std::vector<IdeologyDrawCandidate> &pool,
        int32_t count, NextRandom &&next_random, int32_t *out) {
    int32_t drawn = 0;
    while (drawn < count && !pool.empty()) {
        int64_t total = 0;
        for (const IdeologyDrawCandidate &candidate : pool) total += candidate.weight;
        // Every caller filters zero-weight rows first, so this is defence in
        // depth against a `% 0` (undefined behaviour, not a crash) in release.
        if (total <= 0) break;
        uint64_t roll = next_random() % static_cast<uint64_t>(total);
        size_t selected = 0;
        for (; selected + 1 < pool.size(); ++selected) {
            const uint64_t weight = static_cast<uint64_t>(pool[selected].weight);
            if (roll < weight) break;
            roll -= weight;
        }
        out[drawn++] = pool[selected].id;
        pool.erase(pool.begin() + static_cast<std::ptrdiff_t>(selected));
    }
    return drawn;
}

}  // namespace pk
