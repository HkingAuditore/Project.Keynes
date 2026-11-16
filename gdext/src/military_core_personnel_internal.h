#pragma once

#include "military_core_internal.h"

namespace pk {
namespace mil {

inline int32_t barracks_speed_index_matches(const MilitaryCatalog &c, int32_t tier, int32_t *out) {
    int32_t best = MILITARY_Q16;
    bool found = false;
    for (const MilitaryStateBuilding &b : c.state_buildings) {
        if (b.role != (uint8_t)MILITARY_STATE_WAR_COLLEGE) continue;
        if ((int32_t)b.tier != tier) continue;
        found = true;
        if (b.training_speed_q16 > best) best = b.training_speed_q16;
    }
    if (out) *out = best;
    return found ? 1 : 0;
}

inline int32_t kind_factor_q16(uint8_t from_class, uint8_t to_class, bool same_unit) {
    if (same_unit) return MILITARY_Q16 / 4;   // re-equip 0.25
    if (from_class == to_class) return 26214; // same category retrain 0.4
    return 52429;                             // cross category retrain 0.8
}

inline int64_t garrison_heads_for_unit(const MilitaryLotStore &lots, int32_t cell, int32_t country_slot,
                                int16_t unit) {
    int64_t total = 0;
    for (size_t i = 0; i < lots.active.size(); ++i) {
        if (!lots.active[i]) continue;
        if (lots.location_kind[i] != (uint8_t)MILITARY_LOT_GARRISON) continue;
        if (lots.location[i] != cell) continue;
        if (country_slot >= 0 && lots.country_slot[i] != country_slot) continue;
        if (unit >= 0 && lots.unit_type[i] != unit) continue;
        total += lots.count[i];
    }
    return total;
}

} // namespace mil
} // namespace pk
