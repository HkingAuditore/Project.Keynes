#pragma once

// Material support: the shared support kernel used by BOTH ideology authorities.
//
// The main-thread runtime and the worker POD must agree bit for bit, so the
// arithmetic lives here once and neither side is allowed its own copy. See
// docs/plans/ideology-material-support-incidence.md.
//
// Model: a class's stance for a card is the relative change in its real income
// that the card's compiled effect would cause,
//
//     delta_u_c = sum_ch  share[c][ch] * delta[ch]           (both Q16)
//     stance_c  = clamp(gain * delta_u_c, -1, +1)
//     support   = sum_c influence_c * stance_c / sum_c influence_c
//
// `share` is published by Economy (share of that class's income/expense in each
// channel); `delta` is compiled from the card's stat keys by IdeologyCatalog.
// Nothing here reads a string, allocates, or looks at a Godot type.

#include <algorithm>
#include <cstdint>
#include <vector>

#include "economy_api.h"

namespace pk {

struct RuntimeIdeologyOpinionSnapshot;

namespace ideology_incidence {

constexpr int32_t kQ16One = 65536;
// Defaults; overridden by IdeologyProfile and frozen into the catalog.
constexpr int32_t kDefaultGainQ16 = 5 * kQ16One;
constexpr int32_t kDefaultVetoQ16 = -13107;          // -0.20 relative income
constexpr int32_t kDefaultVetoMinInfluenceQ16 = 1311;  // 2% of influence

enum SupportModel : int32_t {
    // Authored per-class stance rows: the pre-material behaviour. Kept as a
    // switch so a balance regression can be rolled back without a rebuild of
    // the content, and so the two models can be A/B'd on one save.
    SUPPORT_MODEL_AUTHORED = 0,
    SUPPORT_MODEL_MATERIAL = 1,
};

// Compiled, immutable part of the model: one dense Q16 channel row per card
// level, indexed by the same global level index the catalog already uses.
struct IdeologyIncidenceTable {
    int32_t channel_count = 0;
    int32_t level_count = 0;
    int32_t model = SUPPORT_MODEL_MATERIAL;
    int32_t gain_q16 = kDefaultGainQ16;
    int32_t veto_q16 = kDefaultVetoQ16;
    int32_t veto_min_influence_q16 = kDefaultVetoMinInfluenceQ16;
    // Calibration knob for the generated thresholds: see IdeologyProfile.
    int32_t threshold_scale_q16 = kQ16One;
    std::vector<int32_t> level_channels_q16;
    // 1 = this level has at least one economic channel. 0 means the card's
    // effects are not expressible in the material model yet (family buffs,
    // unmapped stat families), so the gate must not treat "no data" as "nobody
    // supports this".
    std::vector<uint8_t> level_measured;

    const int32_t *level_delta(int32_t level_index) const {
        if (channel_count <= 0 || level_index < 0 || level_index >= level_count)
            return nullptr;
        const size_t offset = static_cast<size_t>(level_index) *
            static_cast<size_t>(channel_count);
        if (offset + static_cast<size_t>(channel_count) > level_channels_q16.size())
            return nullptr;
        return &level_channels_q16[offset];
    }

    bool level_has_effect(int32_t level_index) const {
        if (level_index < 0 || level_index >= level_count) return false;
        if (level_measured.empty()) return true;
        return level_measured[static_cast<size_t>(level_index)] != 0;
    }

    // Authored thresholds were calibrated against the old authored stances; the
    // material distribution is narrower, so the comparison uses the scaled value.
    int32_t scaled_threshold(int32_t threshold_q16) const {
        return static_cast<int32_t>(std::clamp<int64_t>(
            static_cast<int64_t>(threshold_q16) * threshold_scale_q16 / kQ16One,
            -kQ16One, kQ16One));
    }
};

// One country's published shares for one class: `channel_count` Q16 entries.
// `delta` is one card level's compiled row over the SAME channel layout.
inline int32_t material_delta_q16(const int32_t *shares, const int32_t *delta,
                                  int32_t channel_count) {
    if (shares == nullptr || delta == nullptr || channel_count <= 0) return 0;
    int64_t acc = 0;  // Q32: Q16 share * Q16 delta
    for (int32_t channel = 0; channel < channel_count; ++channel) {
        const int64_t share = shares[channel];
        const int64_t value = delta[channel];
        if (share == 0 || value == 0) continue;
        acc += share * value;
    }
    const int64_t delta_u = acc / kQ16One;
    return static_cast<int32_t>(
        std::clamp<int64_t>(delta_u, -kQ16One, kQ16One));
}

inline int32_t stance_from_delta_q16(int32_t delta_u_q16, int32_t gain_q16) {
    const int64_t scaled = static_cast<int64_t>(delta_u_q16) * gain_q16 / kQ16One;
    return static_cast<int32_t>(std::clamp<int64_t>(scaled, -kQ16One, kQ16One));
}

// The authored row model. `stance` points at this card's stance row for the
// direction (dense class table), `classes` is the catalog's class count.
inline int32_t authored_stance_q16(const int32_t *stance_q16, int32_t classes,
                                   int32_t class_index) {
    if (stance_q16 == nullptr || class_index < 0 || class_index >= classes)
        return 0;
    return stance_q16[class_index];
}

// Weighted average of per-class stances by class influence.
inline int32_t weighted_support_q16(const int64_t *influence,
                                    const int32_t *stance_q16, int32_t classes) {
    if (influence == nullptr || stance_q16 == nullptr || classes <= 0) return 0;
    int64_t total = 0;
    int64_t weighted = 0;
    for (int32_t class_index = 0; class_index < classes; ++class_index) {
        const int64_t weight = std::max<int64_t>(0, influence[class_index]);
        if (weight <= 0) continue;
        total += weight;
        weighted += weight * stance_q16[class_index];
    }
    if (total <= 0) return 0;
    return static_cast<int32_t>(
        std::clamp<int64_t>(weighted / total, -kQ16One, kQ16One));
}

// Worker-side gate. Implemented next to the kernel so the POD authority stays a
// thin caller: both authorities must run the SAME arithmetic.
bool support_allows_material(
    const IdeologyIncidenceTable &table,
    const RuntimeIdeologyOpinionSnapshot &opinion, uint32_t country_slot,
    uint32_t class_count, uint32_t level, int32_t threshold_q16,
    int32_t owner_influence_weight, int64_t funds_per_influence);

// Is this class big enough to veto, and did it lose enough?
inline bool class_vetoes(int32_t delta_u_q16, int64_t class_influence,
                         int64_t total_influence, int32_t veto_q16,
                         int32_t veto_min_influence_q16) {
    if (total_influence <= 0 || class_influence <= 0) return false;
    if (veto_min_influence_q16 > 0 &&
        class_influence * kQ16One / total_influence < veto_min_influence_q16)
        return false;
    return delta_u_q16 <= veto_q16;
}

}  // namespace ideology_incidence
}  // namespace pk
