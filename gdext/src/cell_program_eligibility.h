#pragma once

// One program, one backend (plan 22 4.4 / 4.5 / I01).
//
// THE PROBLEM THIS SOLVES
//
// Whether a program can be expressed by the derived cell layer was previously
// decided inline, in two places that could drift: the instance collector and the
// derived materialiser. I01 ("one program, one backend") forbids a program from
// using both, and a drift between two copies of the rule is exactly how a program
// ends up double-applied -- which is a silent correctness bug, not a visible one.
//
// So the decision lives here, once, and BOTH callers ask it. The rollout gate is a
// SEPARATE question ("is this milestone allowed to enable that kind"), also here,
// because a milestone flip must not change what the backend can express.
//
// No Godot dependency: this is pure classification of already-gathered facts.

#include <cstdint>
#include <string>
#include <vector>

namespace pk {

enum class CellProgramBackend : uint8_t {
    EffectInstance = 0,
    DerivedCell = 1,
};

// Why a program stayed on the instance backend. Named so a coverage report can
// separate "not in scope" from "a defect", which is the difference between 47
// excluded programs and 47 broken ones.
enum class CellProgramLegacyReason : uint8_t {
    None = 0,
    NotCellDomain,        // target_domain is not 2 (cell) -- out of scope entirely
    NotPermanent,         // lifecycle != 0 -- a timed effect needs instance expiry
    DeadDurationField,    // permanent but authors duration_days (content defect)
    StateDependent,       // reads latched STATE -- history-dependent
    UnsupportedSelector,  // selector kind the derived layer cannot express
    NonConstantValueMode, // magnitude is neither constant nor a metric ramp
    Stacked,              // stacks != 1 -- instance path owns layer expiry
    UnresolvedDefinition, // the modifier catalog does not know the definition
    RampNotYetSupported,  // kept for report compatibility; M3 admits these
};

// Per-command facts. A program is classified from its commands, not from its
// metadata alone: two cards with identical metadata can differ in how their
// magnitude is produced, which is precisely what condition 4 turns on.
struct CellProgramCommandFacts {
    // 0 = VALUE_CONSTANT (magnitude inline), 1 = VALUE_STACK_TOP (from the VM).
    int32_t value_mode = 1;
    // True when the producing instruction is CONST, i.e. a stack-top value that is
    // still a compile-time constant. Rejecting stack-top unconditionally would fail
    // 262 of 288 programs for a property they all satisfy.
    bool stack_top_is_constant = false;
    // True when the program reads a metric and its magnitude is NOT constant --
    // i.e. a READ_METRIC ramp. M3 added the per-cell evaluator, so this is now
    // EXPRESSIBLE rather than deferred.
    bool has_metric_ramp = false;
    // The modifier catalog resolved every term of `definition_key`.
    bool definition_resolved = false;
    // Every resolved term is SUM. City stats are forced SUM by the catalog
    // validator, so a non-SUM term would be a catalog defect.
    bool all_terms_sum = false;
    int32_t stacks = 1;
    int32_t duration_days = -1;
};

// Everything the decision needs about one program.
struct CellProgramFacts {
    int32_t target_domain = 0;
    int32_t selector_kind = -1;
    int32_t lifecycle = 0;
    int32_t duration_days = -1;
    int32_t stack_policy = 0;
    int32_t max_stacks = 1;
    std::vector<CellProgramCommandFacts> commands;
};

struct CellProgramDecision {
    CellProgramBackend backend = CellProgramBackend::EffectInstance;
    CellProgramLegacyReason reason = CellProgramLegacyReason::None;
    // A qualifying program can still carry a dead `duration_days` field. Kept
    // separate from `reason` so it stays DerivedCell -- the field is a content
    // defect, not a blocker.
    bool dead_duration_field = false;
    // Human-readable detail for the coverage report. Never used for control flow.
    std::string detail;
};

// Selector kinds the DerivedCell backend can EXPRESS.
//
// Kept as a function rather than a set in each caller so 6.1's "one shared
// visitor" has one list to extend.
inline bool cell_program_selector_supported(int32_t selector_kind) {
    switch (selector_kind) {
        case 12:  // SELECTOR_OWN_TERRITORY
        case 14:  // SELECTOR_TAG_SOURCE_R1
        case 15:  // SELECTOR_TAG_SOURCE_R2
        case 16:  // SELECTOR_TAG_SOURCE_COUNT
            return true;
        default:
            return false;
    }
}

// The single eligibility decision. Order matters: the earliest applicable reason
// wins, so the report names the most fundamental blocker.
inline CellProgramDecision decide_cell_program_backend(
        const CellProgramFacts &facts) {
    CellProgramDecision out;

    // 1. Cell domain. Every other domain has no cell identity to key a row by.
    if (facts.target_domain != 2) {
        out.reason = CellProgramLegacyReason::NotCellDomain;
        out.detail = "target_domain is not the cell domain";
        return out;
    }
    // 2. Selector expressible at all.
    if (!cell_program_selector_supported(facts.selector_kind)) {
        out.reason = CellProgramLegacyReason::UnsupportedSelector;
        out.detail = "selector kind is not expressible by the derived layer";
        return out;
    }
    // 3. Permanent. A timed effect needs per-instance expiry, which the derived
    //    front has no field for.
    if (facts.lifecycle != 0) {
        out.reason = CellProgramLegacyReason::NotPermanent;
        out.detail = "lifecycle is timed; the instance path owns expiry";
        return out;
    }
    // 4. A permanent program that still authors a duration carries a dead field.
    //    Recorded, not rejected.
    if (facts.duration_days != -1 && facts.duration_days >= 0) {
        out.dead_duration_field = true;
    }
    // 5. Commands.
    if (facts.commands.empty()) {
        out.reason = CellProgramLegacyReason::UnresolvedDefinition;
        out.detail = "program has no modifier commands";
        return out;
    }
    for (const CellProgramCommandFacts &command : facts.commands) {
        // 6. Magnitude expressible.
        const bool magnitude_is_constant =
            command.value_mode == 0 ||
            (command.value_mode == 1 && command.stack_top_is_constant);
        // M3: a metric-fed ramp IS expressible. The question was never "is the
        // magnitude constant" but "can the derived layer produce it"; M3 added the
        // per-cell evaluator (the shipping stack machine, parameterised on a metric
        // accessor) plus a sampler, so the answer became yes.
        //
        // What still blocks is a magnitude that is neither constant nor a metric
        // ramp: the derived layer has nothing to evaluate, and admitting it would
        // silently apply 0.
        if (!magnitude_is_constant && !command.has_metric_ramp) {
            out.reason = CellProgramLegacyReason::NonConstantValueMode;
            out.detail = "command magnitude is neither constant nor a metric ramp";
            return out;
        }
        // 7. Single stack. ADD_STACK rows own one instance PER LAYER so layers can
        //    expire independently; the derived front is a snapshot with no expiry.
        if (command.stacks != 1) {
            out.reason = CellProgramLegacyReason::Stacked;
            out.detail = "command stacks != 1";
            return out;
        }
        // 8. Resolved definition.
        if (!command.definition_resolved) {
            out.reason = CellProgramLegacyReason::UnresolvedDefinition;
            out.detail = "modifier definition did not resolve";
            return out;
        }
        // 9. SUM terms only.
        if (!command.all_terms_sum) {
            out.reason = CellProgramLegacyReason::UnresolvedDefinition;
            out.detail = "definition has a non-SUM term";
            return out;
        }
    }

    out.backend = CellProgramBackend::DerivedCell;
    out.reason = CellProgramLegacyReason::None;
    out.detail = "derived";
    return out;
}

inline const char *cell_program_legacy_reason_name(
        CellProgramLegacyReason reason) {
    switch (reason) {
        case CellProgramLegacyReason::None: return "";
        case CellProgramLegacyReason::NotCellDomain: return "not_cell_domain";
        case CellProgramLegacyReason::NotPermanent: return "not_permanent";
        case CellProgramLegacyReason::DeadDurationField: return "dead_duration_field";
        case CellProgramLegacyReason::StateDependent: return "state_dependent";
        case CellProgramLegacyReason::UnsupportedSelector:
            return "unsupported_selector";
        case CellProgramLegacyReason::NonConstantValueMode:
            return "non_constant_value_mode";
        case CellProgramLegacyReason::Stacked: return "stacked";
        case CellProgramLegacyReason::UnresolvedDefinition:
            return "unresolved_definition";
        case CellProgramLegacyReason::RampNotYetSupported:
            return "ramp_not_yet_supported";
    }
    return "unknown";
}

// Rollout is COMPLETE (plan §15.7: "删除迁移期开关").
//
// The staged switch (`Off` -> `Constants` -> `Continuous` -> `Sources`) existed so each
// milestone could be reviewed before it changed production behaviour. All four stages
// have now been run and measured, so the switch has no remaining purpose: keeping it
// would mean the shipped behaviour still depends on a constant that nobody is going to
// flip again, and a reader would have to trace four enum values to learn what the
// runtime actually does.
//
// WHAT REPLACES IT
//
// One question, asked once: can this backend express this selector? That is
// `cell_program_selector_supported`. A supported program is derived; everything else
// stays on the instance path with a named reason. There is no second gate.
//
// WHAT WAS MEASURED AT EACH STAGE (kept because it is the evidence that the removal is
// safe, not decoration):
//
//   * `Off` -> `Constants` -> `Continuous`: 15-fixture regression unchanged.
//   * `Continuous` -> `Sources` BEFORE the I01 fix: `ideology_x1b_source_count_test`
//     went 142/0 -> 142/13, twelve of them numeric (1.23999 vs 1.12). The cause was
//     I01 -- a derived program ALSO created instances, so the fixture read the
//     surviving instance instead of the derived row.
//   * AFTER the I01 fix: 13 -> 4, all four instance-list assertions. Migrating those to
//     `_target_count()` (instances OR front cells) gave 142/0.
//   * Final state: B7 15/0, B8 18/0, B10 16/0, x1b 142/0, tag_snapshot_stress 38/0.
//
// `cell_program_rollout_enabled` is retained as a compile-time `true` predicate for
// supported kinds so the report keeps a field to name, and so a future reader can see
// that the answer is now unconditional rather than searching for a missing switch.
inline bool cell_program_rollout_enabled(int32_t selector_kind) {
    // No switch: expressible means enabled.
    return cell_program_selector_supported(selector_kind);
}

}  // namespace pk