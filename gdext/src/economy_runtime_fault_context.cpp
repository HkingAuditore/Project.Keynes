#include "economy_runtime.h"
#include "fault_taxonomy.h"

#include <string>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

namespace pk {

using namespace godot;

// Assertion identity for the reason the runtime last stopped on (R1-7).
//
// The ledger (docs/runtime/invariants.json) owns the definition; fault_taxonomy.h
// holds the compile-time reason -> id pairs. An unregistered reason returns an
// empty string on purpose: a fabricated id would silently group different stops
// under one ledger entry.
//
// The construction row carries its own reason string because
// commit_preflighted_build_command() records it before fail() runs, which is how
// a fatal-context report taken before the stop still names the assertion.
String NativeEconomyRuntime::fatal_assert_id() const {
    const char *reason = !_fatal_context.reason.empty()
        ? _fatal_context.reason.c_str()
        : (!_construction_fatal_row.reason.empty()
            ? _construction_fatal_row.reason.c_str() : "");
    return String::utf8(pk::fault_assert_id(reason));
}

Dictionary NativeEconomyRuntime::fatal_witness_report() const {
    // Typed witness for the ledger entry named by fatal_assert_id() (R1-8).
    // Field names match docs/runtime/invariants.json and the C++ rows one to one;
    // the flat `investment_row` / `construction_row` objects are still emitted
    // unchanged because existing logs and fixtures read them.
    //
    // Emitted even while _fatal_context.valid is false: the rows are recorded by
    // the failing stage before fail() marks the context valid, so a reporter that
    // runs early (or the invariant probe) still sees the witness.
    const auto construction_witness = [](const ConstructionFatalRow &row) {
        Dictionary witness;
        witness["reason"] = String::utf8(row.reason.c_str());
        witness["cell"] = row.cell;
        witness["type_id"] = row.type_id;
        witness["allocated_count"] = row.allocated_count;
        witness["total_cost"] = row.total_cost;
        witness["owner_slot"] = row.owner_slot;
        witness["owner_funds"] = row.owner_funds;
        witness["funding_gap"] = row.funding_gap;
        witness["debt_principal"] = row.debt_principal;
        witness["material_feasible"] = row.material_feasible;
        witness["good_count"] = row.good_count;
        witness["first_good_id"] = row.first_good_id;
        witness["first_required"] = row.first_required;
        witness["first_stock"] = row.first_stock;
        witness["portfolio_index"] = row.portfolio_index;
        witness["portfolio_size"] = row.portfolio_size;
        return witness;
    };
    const std::string &reason = !_fatal_context.reason.empty()
        ? _fatal_context.reason
        : _construction_fatal_row.reason;
    // The reason decides which row is the failure scene; when it is empty (the
    // report runs before fail()) a valid construction row wins because it is only
    // written by the stage that is already unwinding.
    const bool construction_first = _construction_fatal_row.valid &&
        (reason.empty() || reason.rfind("building_construction_", 0) == 0);
    if (construction_first) return construction_witness(_construction_fatal_row);
    if (_investment_fatal_row.valid) {
        const InvestmentFatalRow &row = _investment_fatal_row;
        Dictionary witness;
        witness["branch"] = row.branch;
        witness["cell"] = row.cell;
        witness["type_id"] = row.type_id;
        witness["portfolio_index"] = row.portfolio_index;
        witness["portfolio_size"] = row.portfolio_size;
        witness["allocated_count"] = row.allocated_count;
        witness["owner_population"] = row.owner_population;
        witness["funding_capital"] = row.funding_capital;
        witness["merchant_credit"] = row.merchant_credit;
        witness["required_capital"] = row.required_capital;
        witness["carried"] = row.carried;
        witness["correction"] = row.correction;
        witness["sponsor_slot"] = row.sponsor_slot;
        witness["sponsor_population"] = row.sponsor_population;
        witness["sponsor_funds"] = row.sponsor_funds;
        witness["owner_slot"] = row.owner_slot;
        witness["owner_funds"] = row.owner_funds;
        witness["source_drained"] = row.source_drained;
        return witness;
    }
    // Unknown reason with only a construction row left: never hide the scene.
    if (_construction_fatal_row.valid) return construction_witness(_construction_fatal_row);
    return Dictionary();
}

void NativeEconomyRuntime::write_save_identity_report(Dictionary &out) const {
    // R4-2: begin_save() returned only ok / chunk_bytes / schema_version /
    // catalog_hash / committed_day, so runtime_forensics.gd read
    // begun.get("generation", 0) and begun.get("state_hash", 0) and every fatal
    // snapshot recorded native_generation=0, native_state_hash=0 while the paired
    // country.pkcn recorded generation=1 and a real hash. Both values are live
    // runtime identity, not missing header segments:
    //   * the committed generation is persisted in the PKEC CADENCE_STATE footer
    //     (schema >= 52, economy_runtime_persistence_write.cpp) and restored from
    //     it (_restore.restored_committed_generation);
    //   * PKEC stores no Economy state hash at all -- its header carries the
    //     Country generation/hash that pairs the archive, and the Economy hash is
    //     recomputed on demand. So `state_hash` here is the live hash and
    //     `state_hash_source` says so instead of implying it came from a file.
    //
    // `restore_eligible` is the one bit callers need before trying: the stream is
    // produced at a committed boundary (not a half-open epoch) and every shape /
    // continuation gate in begin_save already passed, so the archive starts with
    // SAVE_SECTION_HEADER and the production restore path can read it back to its
    // END chunk. A mid-epoch capture is deliberately not eligible: restore rejects
    // an ECP2 epoch-resume bundle with `ecp2_mid_epoch_resume_unsupported`.
    // Country pairing (PKCN generation/hash recorded in the PKEC header) is
    // checked by the restore path, not here.
    out["generation"] = static_cast<int64_t>(_committed_generation);
    out["state_hash"] = _bootstrapped ? state_hash() : 0;
    out["state_hash_source"] = "live_economy_state_hash";
    out["epoch_active"] = _epoch_active;
    out["fatal"] = _fatal;
    const bool committed_boundary = !_epoch_active;
    out["restore_eligible"] = committed_boundary;
    out["restore_blocked_reason"] =
        committed_boundary ? String() : String("half_open_epoch");
}

} // namespace pk
