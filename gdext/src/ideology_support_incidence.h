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

// Reads `incidence_*` and the profile's support-model fields out of the compiled
// ideology catalog. Returns false with a named reason on any shape/range error:
// a table that does not match `level_count * channel_count` must never reach
// `level_delta()`, where it would read a neighbouring level's row.
bool configure_table(const godot::Dictionary &catalog, IdeologyIncidenceTable &out,
                     std::string &error);

}  // namespace pk::ideology_incidence
