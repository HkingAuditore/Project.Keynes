#pragma once

// Economy / Country / Ideology -> Effect instance access, through one authority
// decision.
//
// The Economy family path creates, reweights and retires Effect instances one
// row at a time (reconcile, branch clear, founding pool grant, ancestral
// precept, event-once fire, person registration). Every one of those writes has
// to make the same worker/legacy decision the declarative batch path makes --
// otherwise family effects keep writing EffectRuntime after EFFECT moved to the
// worker and get erased by the next worker snapshot.
//
// The same applies to the *reads* those owners make afterwards. Country's peer
// report, the ideology card report and the ideology restore all derive
// "instance exists" / "instance fired" from EffectRuntime, which is
// writeback-only under worker authority -- so they read every worker-owned
// instance as absent and never fired. That is the query half of the same bug:
// a binding or a save gets rejected for an instance that is perfectly alive.
//
// These live in a header rather than in one translation unit because the call
// sites are spread over economy_runtime.cpp, economy_runtime_family_buff.cpp,
// country_runtime.cpp and ideology_runtime.cpp.
//
// The routing decision is "is there an attached forwarder", not "is there a
// forwarder object". DCWorldExt creates the forwarder with the world and only
// attach()es it once the Effect catalog exists, so an attached-pointer check
// would hand family writes to a forwarder whose upsert_instance() can only
// answer NOT_ATTACHED -- silently losing every effect created in that window.
// A null or unattached forwarder keeps the pre-M2b behaviour (write
// EffectRuntime directly), which is exactly the authority split at that moment.

#include "effect_instance_forwarder.h"
#include "effect_runtime.h"

#include <string>

namespace pk {

inline bool effect_pod_upsert(EffectRuntime *effect,
                              EffectInstanceForwarder *forwarder,
                              int64_t instance_id,
                              const std::string &program_key,
                              uint32_t generation, int32_t source_type,
                              int64_t source_id, uint64_t source_handle,
                              uint64_t target_handle, uint32_t target_generation,
                              int32_t level, int64_t next_due_day,
                              int64_t expires_day, bool active,
                              std::string &error) {
    if (forwarder != nullptr && forwarder->attached()) {
        EffectInstanceForwarder::InstanceRow row;
        row.instance_id = instance_id;
        row.program_key = program_key;
        row.generation = generation;
        row.source_type = source_type;
        row.source_id = source_id;
        row.source_handle = source_handle;
        row.target_handle = target_handle;
        row.target_generation = target_generation;
        row.level = level;
        row.next_due_day = next_due_day;
        row.expires_day = expires_day;
        row.active = active;
        return forwarder->upsert_instance(row, error);
    }
    if (!effect->upsert_instance_pod(instance_id, program_key, generation,
            source_type, source_id, source_handle, target_handle,
            target_generation, level, next_due_day, active, error)) {
        return false;
    }
    // The worker receives expires_day inside the row; the legacy path has to be
    // told separately or the two authorities would disagree about lifetime.
    return expires_day < 0 ||
        effect->set_instance_expiry_pod(instance_id, generation, expires_day);
}

inline bool effect_pod_metric(EffectRuntime *effect,
                              EffectInstanceForwarder *forwarder,
                              int64_t instance_id, uint32_t generation,
                              int32_t metric_id, int64_t revision, int64_t value,
                              std::string &error) {
    if (forwarder != nullptr && forwarder->attached())
        return forwarder->set_metric(instance_id, generation, metric_id,
                                     revision, value, error);
    return effect->set_metric_pod(instance_id, metric_id, revision, value, error);
}

inline bool effect_pod_retire(EffectRuntime *effect,
                              EffectInstanceForwarder *forwarder,
                              int64_t instance_id, uint32_t generation,
                              int64_t effective_day, std::string &error) {
    if (forwarder != nullptr && forwarder->attached())
        return forwarder->retire_instance(instance_id, generation,
                                          effective_day, error);
    return effect->retire_instance_pod(instance_id, generation, effective_day,
                                       error);
}

// Authority-aware "does this instance still exist". Returns false only when the
// question could not be answered (no attached forwarder path available or the
// worker transport is not ready); `exists` is then meaningless and callers treat
// it as "unknown", not as "absent".
inline bool effect_pod_instance_exists(EffectRuntime *effect,
                                       EffectInstanceForwarder *forwarder,
                                       int64_t instance_id, uint32_t generation,
                                       bool &exists) {
    exists = false;
    if (forwarder != nullptr && forwarder->attached()) {
        std::string error;
        return forwarder->instance_exists(instance_id, generation, exists, error);
    }
    exists = effect != nullptr && effect->has_instance_pod(instance_id, generation);
    return true;
}

// Authority-aware "has this instance fired". Same contract as the existence
// probe: false means "could not answer", and `acked` is then meaningless.
//
// Every main-thread owner that reports on Effect instances needs this, because
// EffectRuntime is writeback-only under EFFECT worker authority: a worker-owned
// instance reads as "never existed, never fired", which makes the country peer
// report pessimistic and makes the ideology restore reject a healthy save.
inline bool effect_pod_instance_fire_acked(EffectRuntime *effect,
                                           EffectInstanceForwarder *forwarder,
                                           int64_t instance_id,
                                           uint32_t generation, bool &acked) {
    acked = false;
    if (forwarder != nullptr && forwarder->attached()) {
        std::string error;
        return forwarder->instance_fire_acked(instance_id, generation, acked,
                                              error);
    }
    acked = effect != nullptr &&
        effect->instance_fire_acked_pod(instance_id, generation);
    return true;
}

} // namespace pk
