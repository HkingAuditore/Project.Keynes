#pragma once

// Selector cell ceilings (plan 22 M2-1 / M2-2 / M2-5).
//
// `EffectRuntime::SELECTOR_MAX_CELLS = 32` used to serve TWO unrelated purposes:
// a GEOMETRIC bound (how many cells a radial walk reaches) and a CONTENT POLICY
// bound (how many of a country's own cells a permanent card may cover). Plan 22
// removes the second and keeps the first. Conflating them is why "remove the 32
// cap" looked like a one-line change while needing three layers changed in order.
//
// No Godot dependency on purpose: pure integer logic, unit-testable without
// linking godot_cpp.

#include <algorithm>
#include <cstdint>
#include <limits>

namespace pk {

// Mirrored from EffectRuntime's selector enum so this header stays Godot-free.
// `effect_runtime.h` static_asserts that the two agree.
inline constexpr int32_t CAP_SELECTOR_NEIGHBORS_R1 = 6;
inline constexpr int32_t CAP_SELECTOR_NEIGHBORS_R2 = 7;
inline constexpr int32_t CAP_SELECTOR_OWN_TERRITORY = 12;
inline constexpr int32_t CAP_SELECTOR_TAG_ANY_CELL = 13;
inline constexpr int32_t CAP_SELECTOR_TAG_SOURCE_R1 = 14;
inline constexpr int32_t CAP_SELECTOR_TAG_SOURCE_R2 = 15;
inline constexpr int32_t CAP_SELECTOR_TAG_SOURCE_COUNT = 16;
inline constexpr int32_t CAP_SELECTOR_FAMILY_OWNED = 17;

// "No POLICY cap". Callers must still respect the map size: unbounded by policy,
// NOT infinite memory -- the reader side still meters and shards (plan 1.1).
inline constexpr int32_t kSelectorNoCellCap = std::numeric_limits<int32_t>::max();

enum SelectorKindForCap : int32_t {
    CAP_KIND_NEIGHBORS_R1 = CAP_SELECTOR_NEIGHBORS_R1,
    CAP_KIND_NEIGHBORS_R2 = CAP_SELECTOR_NEIGHBORS_R2,
    CAP_KIND_OWN_TERRITORY = CAP_SELECTOR_OWN_TERRITORY,
    CAP_KIND_TAG_ANY_CELL = CAP_SELECTOR_TAG_ANY_CELL,
    CAP_KIND_TAG_SOURCE_R1 = CAP_SELECTOR_TAG_SOURCE_R1,
    CAP_KIND_TAG_SOURCE_R2 = CAP_SELECTOR_TAG_SOURCE_R2,
    CAP_KIND_TAG_SOURCE_COUNT = CAP_SELECTOR_TAG_SOURCE_COUNT,
    CAP_KIND_FAMILY_OWNED = CAP_SELECTOR_FAMILY_OWNED,
};

// Geometric reach of one selector kind.
//
// R1/R2 return 6 and 18 -- the count EXCLUDING the centre cell, matching the
// selector's own convention (pinned by
// economy_runtime_effect_selector_tests.cpp). The textbook 7/19 includes the
// centre; using 18 for R1 would widen it three-fold.
//
// Territory/source/family kinds have no geometric reach: their target set comes
// from the ownership index or a tag scan, so they report "no policy cap".
inline constexpr int32_t selector_cell_ceiling(int32_t selector_kind) {
    switch (selector_kind) {
        case CAP_SELECTOR_NEIGHBORS_R1:
            return 6;
        case CAP_SELECTOR_NEIGHBORS_R2:
            return 18;
        case CAP_SELECTOR_TAG_ANY_CELL:
        case CAP_SELECTOR_OWN_TERRITORY:
        case CAP_SELECTOR_TAG_SOURCE_R1:
        case CAP_SELECTOR_TAG_SOURCE_R2:
        case CAP_SELECTOR_TAG_SOURCE_COUNT:
        case CAP_SELECTOR_FAMILY_OWNED:
            return kSelectorNoCellCap;
        default:
            // An unknown kind must not silently become "unbounded": that would
            // turn a renamed selector into a country-sized sweep.
            return 0;
    }
}

inline constexpr bool selector_cell_cap_is_unbounded(int32_t selector_kind) {
    return selector_cell_ceiling(selector_kind) == kSelectorNoCellCap;
}

// The largest `target_selector_param[0]` a card may AUTHOR for this kind.
//
// Stays at the legacy 32 for every bounded kind. Shipped content authors 8 for R1
// whose walk yields 6; validating `param[0] <= ceiling` rejected that content and
// broke the catalog. Unbounded kinds accept any non-negative value.
inline constexpr int32_t selector_authored_cell_ceiling(int32_t selector_kind) {
    if (selector_cell_cap_is_unbounded(selector_kind)) return kSelectorNoCellCap;
    return 32;
}

inline constexpr bool selector_authored_cap_is_unbounded(int32_t selector_kind) {
    return selector_authored_cell_ceiling(selector_kind) == kSelectorNoCellCap;
}

// The effective cap for one query.
//
//   `authored == 0`  means "the kind's own default". For an unbounded kind that is
//                    now the WHOLE territory: the map size is the only bound.
//   `authored > 0`   still wins, so a card that explicitly authors 32 keeps 32 and
//                    content/behaviour stay separately reviewable.
//
// `map_cells <= 0` yields 0: an unbounded kind with no map is a misconfigured
// runtime, not a licence to return everything.
inline constexpr int32_t resolve_selector_cell_cap(int32_t selector_kind,
                                                   int32_t authored,
                                                   int32_t map_cells) {
    const int32_t ceiling = selector_cell_ceiling(selector_kind);
    const int32_t outer = map_cells > 0 ? map_cells : 0;
    if (ceiling == kSelectorNoCellCap) {
        if (outer == 0) return 0;
        return authored > 0 ? std::min(authored, outer) : outer;
    }
    const int32_t bounded = authored > 0 ? std::min(authored, ceiling) : ceiling;
    return outer > 0 ? std::min(bounded, outer) : bounded;
}

}  // namespace pk