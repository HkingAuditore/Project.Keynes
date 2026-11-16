#pragma once

// Catalog parsing for the material support model. Split from the arithmetic
// kernel so `runtime_ideology_incidence.h` stays Godot-free: the worker POD and
// the main-thread hot path both include that one, and neither may pull in
// godot::Dictionary.

#include <string>

#include <godot_cpp/variant/dictionary.hpp>

#include "runtime_ideology_incidence.h"

namespace pk {
struct RuntimeIdeologyOpinionSnapshot;
}

namespace pk::ideology_incidence {

// One evaluation. `delta_q16`/`stance_q16` are only filled when the caller asks
// for them (the explain path); the gate path passes nullptr so it never allocates.
struct SupportEvaluation {
    int32_t support_q16 = 0;
    int32_t blocking_class = -1;
    bool available = false;
};

// Reads Economy's published class shares and this level's compiled channel row.
// `class_influence` is per class, already built by the caller from the same
// snapshot (the vision of "who matters" is shared with the point accrual).
SupportEvaluation evaluate_material_support(
    const IdeologyIncidenceTable &table,
    const EconomyApi::CountryClassOpinionSnapshot &snapshot,
    const std::vector<int64_t> &class_influence, int32_t country_slot,
    int32_t level_index, int64_t total_influence,
    std::vector<int32_t> *out_delta_q16 = nullptr,
    std::vector<int32_t> *out_stance_q16 = nullptr);

// Per-class breakdown for the panel: one delta and the three directional stances
// for every class (not just the card's authored stance rows, which the material
// model no longer reads). `delta_q16` is one entry per class; the stance arrays
// have the same length. Directions only differ by sign for repeal.
void explain_breakdown(
    const IdeologyIncidenceTable &table,
    const EconomyApi::CountryClassOpinionSnapshot &snapshot,
    const std::vector<int64_t> &class_influence, int32_t country_slot,
    int32_t level_index, std::vector<int32_t> &delta_q16,
    std::vector<int32_t> &adopt_q16, std::vector<int32_t> &repeal_q16,
    std::vector<int32_t> &promote_q16);

// Reads `incidence_*` and the profile's support-model fields out of the compiled
// ideology catalog. Returns false with a named reason on any shape/range error:
// a table that does not match `level_count * channel_count` must never reach
// `level_delta()`, where it would read a neighbouring level's row.
bool configure_table(const godot::Dictionary &catalog, IdeologyIncidenceTable &out,
                     std::string &error);

}  // namespace pk::ideology_incidence
