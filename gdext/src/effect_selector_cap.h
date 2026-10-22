#pragma once
#include <algorithm>
#include <cstdint>
#include <vector>

namespace pk {

// What a selector did, for the diagnostics report. `matched_total` is how many
// cells the predicate accepted BEFORE the cap; without it a truncated card is
// indistinguishable from a card that genuinely only matches 32 cells.
struct EffectSelectorStats {
    int32_t matched_total = 0;
    uint8_t truncated = 0;
};

// SplitMix64-finalised key over (anchor, cell, salt).
//
// Why not "the lowest ids": that is replayable but geographically arbitrary, and
// it makes every card in the game prefer the same corner of the map -- a
// country with 200 matching cells always buffs the same 32, so the other 168 can
// never be affected no matter what the content says. Keying on the cell makes
// the kept subset a stable pseudo-random sample instead, and salting with the
// program hash keeps two cards from sampling the same subset.
inline uint64_t effect_selection_key(uint64_t anchor, int32_t cell, uint64_t salt) {
    uint64_t z = anchor * 0x9e3779b97f4a7c15ULL;
    z ^= static_cast<uint64_t>(static_cast<uint32_t>(cell)) * 0xbf58476d1ce4e5b9ULL;
    z ^= salt;
    z += 0x9e3779b97f4a7c15ULL;
    z = (z ^ (z >> 30U)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27U)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31U);
}

// Keeps `cap` of `cells`, chosen by key, and restores ascending cell order so
// every downstream consumer keeps the ordering it already assumes. A negative
// cap means "no limit". `stats` is optional and only used for the report.
inline void effect_stable_cap(std::vector<int32_t> &cells, int32_t cap,
                              uint64_t anchor, uint64_t salt,
                              EffectSelectorStats *stats = nullptr) {
    if (stats != nullptr)
        stats->matched_total = static_cast<int32_t>(cells.size());
    if (cap < 0 || static_cast<int32_t>(cells.size()) <= cap) return;
    if (stats != nullptr) stats->truncated = 1;
    std::sort(cells.begin(), cells.end(), [anchor, salt](int32_t a, int32_t b) {
        const uint64_t ka = effect_selection_key(anchor, a, salt);
        const uint64_t kb = effect_selection_key(anchor, b, salt);
        // Cell id breaks the tie so the order is total: two cells with equal
        // keys must not be able to swap between runs.
        return ka != kb ? ka < kb : a < b;
    });
    cells.resize(static_cast<size_t>(cap));
    std::sort(cells.begin(), cells.end());
}

} // namespace pk
