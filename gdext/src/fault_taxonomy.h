#pragma once

// Static reason -> assert id bridge (R1-7).
//
// The authoritative ledger is docs/runtime/invariants.json (id, reason, kind,
// stage, witness schema, playbook). This table is the compile-time side of that
// contract so a player log or a `.pkinc` can be matched to a ledger entry
// without shipping the ledger: fatal_context_report() emits the id next to the
// reason, and the offline replay entry point resolves an id back to its reason.
//
// Rules:
//   * Ids are never reused. A merged reason keeps its old id as a tombstone in
//     the ledger, not here.
//   * Every pair must exist in the ledger with the same reason string. New fatal
//     reasons stay unregistered (empty id) until the ledger gains an entry,
//     which is what check_fault_taxonomy.py enforces.
//   * Pure std:: strings: this header is included from runtime code and must not
//     pull in Godot types.
#include <cstring>

namespace pk {

struct FaultRegistration {
    const char *reason;
    const char *assert_id;
};

// Reason strings registered for the 2026-11-19 player batch, ordered by id.
inline constexpr FaultRegistration kFaultRegistrations[] = {
    // Invariant: a funded investment leg carries enough capital to cover the
    // material invoice it is about to commit.
    {"building_investment_capital_preflight_drift", "INV-ECON-0040"},
    // Invariant: allocated market stock >= planned construction quantity.
    {"building_construction_preflight_stock_drift", "INV-ECON-0041"},
    // Invariant: owner funds >= material plan total_cost at invoice time.
    {"building_construction_preflight_funds_drift", "INV-ECON-0042"},
    // Invariant: every PKEC family expedition names a live person handle.
    {"save_family_expedition_person_invalid", "INV-SAVE-0001"},
};
inline constexpr int kFaultRegistrationCount =
    static_cast<int>(sizeof(kFaultRegistrations) / sizeof(kFaultRegistrations[0]));

// Empty string when the reason is not registered yet (never a fabricated id).
inline const char *fault_assert_id(const char *reason) {
    if (reason == nullptr || *reason == '\0') return "";
    for (int i = 0; i < kFaultRegistrationCount; ++i) {
        if (std::strcmp(kFaultRegistrations[i].reason, reason) == 0)
            return kFaultRegistrations[i].assert_id;
    }
    return "";
}

// Reverse lookup used by offline replay: a `.pkinc` normally carries both an id
// and a reason, and a hand-written incident may carry only the id.
inline const char *fault_reason_for_assert_id(const char *assert_id) {
    if (assert_id == nullptr || *assert_id == '\0') return "";
    for (int i = 0; i < kFaultRegistrationCount; ++i) {
        if (std::strcmp(kFaultRegistrations[i].assert_id, assert_id) == 0)
            return kFaultRegistrations[i].reason;
    }
    return "";
}

} // namespace pk
