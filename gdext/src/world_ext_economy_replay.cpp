#include "world_ext.h"
#include "economy_invariant_probe.h"
#include "pk_build_id.h"

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace pk {

using namespace godot;

// R1-6: build identity for any session stage.
//
// This binding exists because "which binary is the player running?" used to be
// answerable only from an Economy report, i.e. only after the native economy had
// been configured and bootstrapped. A cold `DCWorldExt` (what a taxonomy test, a
// crash handler or a failed startup has) returned nothing, so a bug report could
// name no build at all. The value is a compile-time constant from SConstruct.
String DCWorldExt::get_build_id() const {
    return String::utf8(pk::pk_build_id());
}

Dictionary DCWorldExt::economy_unavailable_report() const {
    // Shape of `get_economy_report()` before an Economy runtime exists, plus the
    // build id (the only field that is meaningful without a runtime).
    Dictionary out;
    out["configured"] = false;
    out["bootstrapped"] = false;
    out["path"] = "ECONOMY_GRAPH";
    out["mode"] = "native";
    out["build_id"] = String::utf8(pk::pk_build_id());
    return out;
}

// R3: `.pkinc` offline replay entry point (plan §6.3).
//
// Deliberately independent of the live economy: EconomyInvariantProbe owns its
// own isolated runtime, so a replay can never mutate a player's session and it
// works headless with no world loaded (tests/runtime/incident_replay.gd).
//
// The heavy lifting lives with the probe (economy_invariant_probe.cpp) so the
// fixture builders stay next to the invariant tests that already own them; this
// file exists so the binding has a definition in the economy module instead of
// growing world_ext_economy.cpp, which is at its size-ratchet baseline.
Dictionary DCWorldExt::economy_replay_incident(const Dictionary &incident) {
    return EconomyInvariantProbe::replay_incident(incident);
}

} // namespace pk
