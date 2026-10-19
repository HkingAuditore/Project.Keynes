#pragma once

#include <cstdint>

namespace pk {

// The declarative half of EffectRuntime::submit_instances, factored out so the
// worker transport path can reject exactly the rows the main thread rejects.
//
// Why this exists: the worker batch path in DCWorldExt::submit_effect_instances
// never read the `source_kinds` column, so once ideology/family submissions are
// forwarded to the worker a submission the main thread refuses would have been
// accepted silently. Two hand-written copies of the rule is how main thread and
// worker drifted apart before (see EffectRuntime::pod_state_parity_self_test),
// so the rule lives here and both callers use it.
//
// Pure: no Godot types, no runtime state, no allocation.

struct EffectDeclarativeFacts {
    int32_t source_kind = 0;
    // Programs the runtime owns end to end. Family and ideology programs are
    // managed; technology programs are not.
    bool managed_declared = false;
};

enum class EffectDeclarativeReject : int32_t {
    NONE = 0,
    INVALID_IDENTITY,
    SOURCE_KIND_MISMATCH,
    DEACTIVATION_REQUIRES_RETIRE,
};

// `generation` is expected to be normalised to >= 1 by the caller (the batch
// path does `max(1, generations[i])` before reaching here). `kind_present` is
// false when the caller supplies no source_kinds column at all; for a managed
// program that is itself a mismatch, which is what the main thread has always
// done and what the worker path must now reproduce.
inline EffectDeclarativeReject validate_effect_declarative_row(
        const EffectDeclarativeFacts &facts, int64_t instance_id,
        uint32_t generation, bool kind_present, int32_t declared_kind,
        bool active) {
    if (instance_id <= 0 || generation == 0)
        return EffectDeclarativeReject::INVALID_IDENTITY;
    if (facts.managed_declared &&
        (!kind_present || declared_kind != facts.source_kind))
        return EffectDeclarativeReject::SOURCE_KIND_MISMATCH;
    if (facts.managed_declared && !active)
        return EffectDeclarativeReject::DEACTIVATION_REQUIRES_RETIRE;
    return EffectDeclarativeReject::NONE;
}

// Exact tokens existing tests and logs match on. Do not reword.
inline const char *effect_declarative_reject_token(EffectDeclarativeReject r) {
    switch (r) {
        case EffectDeclarativeReject::SOURCE_KIND_MISMATCH:
            return "effect_family_source_kind_mismatch";
        case EffectDeclarativeReject::DEACTIVATION_REQUIRES_RETIRE:
            return "effect_family_deactivation_requires_retire";
        case EffectDeclarativeReject::INVALID_IDENTITY:
            return "effect_instance_identity_invalid";
        case EffectDeclarativeReject::NONE:
        default:
            return "";
    }
}

} // namespace pk
