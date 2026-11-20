#pragma once

#include <string>

#include <godot_cpp/variant/dictionary.hpp>

namespace pk {
// Isolated diagnostics: creates its own worlds and cannot modify a live runtime.
class EconomyInvariantProbe final {
public:
    static bool run(std::string &error);
    // R3: rebuild the smallest possible world from a `.pkinc` incident bundle
    // (incident.json + witness.json + cell.json merged into one dictionary) and
    // re-run the assertion point the incident names.
    //
    // Returns {"reproduced", "assert_id", "reason", "assert_id_actual",
    // "reason_actual", "assert_fired", "witness_before", "witness_after",
    // "diff": [{"field", "expected", "actual"}], "missing": [...],
    // "uncompared": [...], "fixture_notes": [...], "detail", "build_id"}.
    //
    // `fixture_notes` publishes every degradation of the rebuilt world (cell
    // remap, slot padding, synthesized merchant, unavailable merchant CSR), so a
    // replay that had to approximate is never mistaken for an exact one.
    // `uncompared` lists witness keys that the fired branch structurally cannot
    // record (the funds branch writes -1/0/0 into the stock branch's first_*
    // fields); everything else is compared field by field.
    //
    // Never throws and never touches a live runtime: a fixture that cannot be
    // built returns reproduced=false with `detail` naming what is missing, and
    // an empty/unknown incident returns reproduced=false instead of crashing.
    static godot::Dictionary replay_incident(const godot::Dictionary &incident);
};
}
