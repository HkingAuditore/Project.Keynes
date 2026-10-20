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
//
// The offer row capacity lives here because both authorities size arrays with
// it AND the save format is derived from it. A second literal on either side is
// exactly the mirror constant that drifted three times already.
constexpr int32_t IDEOLOGY_OFFER_CHOICE_CAPACITY = 5;
constexpr int32_t IDEOLOGY_OFFER_CHOICE_BASE = 3;

struct IdeologyDrawCandidate {
    int32_t id = -1;
    int64_t weight = 0;
};

// decay_bp[0] is the card's own era (10000 = full weight); the last entry is
// reused for anything older. An empty table means "no decay at all", which is
// what a catalog authored before eras existed looks like.
//
// `decay_floor_bp` is a per-country floor applied AFTER the table lookup. It is
// the only lever that lets a card keep old ideas drawable without editing the
// global table: `era_decay_bp` ends in 0, so every card older than the last row
// weighs nothing, and because `draw_offer` only falls back to raw rarity weight
// when the WHOLE pool decays out, one live new card is enough to retire all the
// old ones permanently. A floor of 2000 keeps them at 20%.
inline int64_t ideology_draw_weight(int64_t rarity_weight, const int32_t *decay_bp,
        size_t decay_count, int32_t unlocked_era, int32_t era_index,
        int32_t decay_floor_bp) {
    if (rarity_weight <= 0) return 0;
    if (decay_count == 0) return rarity_weight * 10000;
    const int64_t age = static_cast<int64_t>(unlocked_era) - static_cast<int64_t>(era_index);
    // age < 0 means the card belongs to an era the player has not reached. The
    // era milestone technology gate is supposed to have removed it already; to
    // be safe we weight it out rather than silently offering a future card.
    // The floor is applied only after this branch: a floor must never resurrect
    // a card from an era the player has not reached.
    if (age < 0) return 0;
    const size_t row = age >= static_cast<int64_t>(decay_count)
        ? decay_count - 1 : static_cast<size_t>(age);
    const int64_t authored = static_cast<int64_t>(decay_bp[row]);
    const int64_t floor_bp = decay_floor_bp <= 0 ? 0
        : (decay_floor_bp > 10000 ? 10000 : decay_floor_bp);
    const int64_t decay = authored > floor_bp ? authored : floor_bp;
    if (decay <= 0) return 0;
    return rarity_weight * decay;
}

// Draws up to `count` distinct rows, guaranteeing at least one row flagged
// `recent` when such rows exist (当期保底: every row set contains at least one
// card from the current or previous era, so a deep pool cannot dilute the offer
// into pure old cards).
//
// The guarantee is a pool PARTITION, not an extra roll. Re-rolling until a
// recent card appears would advance the RNG a variable number of times, and
// both authorities have to consume the identical stream; partitioning costs one
// extra `next_random()` only when the guarantee actually fires, and that
// condition is a pure function of the pool, which both sides build identically.
template <typename NextRandom>
inline int32_t ideology_weighted_draw_recent_first(
        std::vector<IdeologyDrawCandidate> &pool,
        const std::vector<uint8_t> &recent, int32_t count,
        NextRandom &&next_random, int32_t *out) {
    int32_t drawn = 0;
    if (count <= 0) return 0;
    std::vector<IdeologyDrawCandidate> recent_pool;
    for (size_t index = 0; index < pool.size() && index < recent.size(); ++index) {
        if (recent[index] != 0) recent_pool.push_back(pool[index]);
    }
    if (!recent_pool.empty()) {
        int32_t picked = -1;
        ideology_weighted_draw(recent_pool, 1, next_random, &picked);
        if (picked >= 0) {
            for (size_t index = 0; index < pool.size(); ++index) {
                if (pool[index].id == picked) {
                    pool.erase(pool.begin() + static_cast<std::ptrdiff_t>(index));
                    break;
                }
            }
            out[drawn++] = picked;
        }
    }
    drawn += ideology_weighted_draw(pool, count - drawn, next_random, out + drawn);
    return drawn;
}

// A per-country basis-point value frozen into the opinion snapshot. A shorter
// array means "the host did not freeze this" (every caller before the field
// existed), which reads as 0 -- the floor's identity element -- rather than as
// 10000, which would silently disable era decay for everyone.
inline int32_t ideology_frozen_bp(const std::vector<int32_t> &values, uint32_t slot) {
    if (slot >= values.size()) return 0;
    const int32_t value = values[slot];
    if (value <= 0) return 0;
    return value > 10000 ? 10000 : value;
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

// ---------------------------------------------------------------------------
// Ideology multiplier maths.
//
// `country.ideology.*` stats are read live by NativeIdeologyRuntime and frozen
// into the opinion snapshot for the worker. Two authorities computing the same
// product with slightly different rounding is exactly the class of divergence
// this header exists to prevent, so the arithmetic lives here and both include
// it. Godot-free on purpose.
// ---------------------------------------------------------------------------

constexpr int64_t IDEOLOGY_Q16_ONE = 65536;
constexpr int64_t IDEOLOGY_FACTOR_MAX_Q16 = 4 * IDEOLOGY_Q16_ONE;
// The worker validates `reroll_cost_percent` against this ceiling, so a scaled
// value that exceeds it would make the two authorities disagree.
constexpr int64_t IDEOLOGY_REROLL_PERCENT_MAX = 400;

// A frozen per-country multiplier. A shorter array means "the host did not
// freeze this stat" (every caller before the field existed, plus any country
// the host skipped), which has to read as 1.0 rather than 0.
inline int32_t ideology_frozen_factor(const std::vector<int32_t> &values,
        uint32_t slot) {
    if (slot >= values.size()) return static_cast<int32_t>(IDEOLOGY_Q16_ONE);
    const int32_t value = values[slot];
    if (value <= 0) return 0;
    return value > static_cast<int32_t>(IDEOLOGY_FACTOR_MAX_Q16)
        ? static_cast<int32_t>(IDEOLOGY_FACTOR_MAX_Q16) : value;
}

// `daily * factor`. A factor of exactly 1.0 returns `daily` untouched: the
// pre-factor behaviour has to stay bit-identical or every existing save replays
// a few Q16 units differently per day. Both operands are non-negative here
// (a catalog level rate, and a factor clamped to [0, 4]), and int64 leaves room
// for a 2^31 rate.
inline int64_t ideology_scaled_daily(int64_t daily, int32_t factor_q16) {
    if (daily == 0 || factor_q16 == static_cast<int32_t>(IDEOLOGY_Q16_ONE))
        return daily;
    if (factor_q16 <= 0) return 0;
    return daily * factor_q16 / IDEOLOGY_Q16_ONE;
}

// The reroll share of the paid draw, scaled and capped.
inline int64_t ideology_reroll_percent(int32_t base_percent, int32_t factor_q16) {
    if (factor_q16 == static_cast<int32_t>(IDEOLOGY_Q16_ONE)) return base_percent;
    if (base_percent < 0) base_percent = 0;
    int64_t scaled = static_cast<int64_t>(base_percent) * factor_q16 /
        IDEOLOGY_Q16_ONE;
    if (scaled < 0) scaled = 0;
    return scaled > IDEOLOGY_REROLL_PERCENT_MAX ? IDEOLOGY_REROLL_PERCENT_MAX
                                                : scaled;
}

}  // namespace pk
