#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>

#include <godot_cpp/variant/dictionary.hpp>

namespace pk {

class EffectRuntime;
class NativeSimulationHost;

// Single write path for declarative Effect instances.
//
// Before this class there were two hand-written implementations of the same
// decision: DCWorldExt::submit_effect_instances chose between "queue to the
// worker transport" and "write EffectRuntime, then best-effort mirror to the
// worker", and the mirror parsed the godot batch columns a second time. Any
// rule added on one side silently skipped the other -- `source_kinds` was read
// by the main thread and ignored by the worker path, so a submission the main
// thread refuses was accepted once EFFECT moved to the worker.
//
// Three rules keep a caller from ending up "half forwarded":
//
// 1. One path per call. `submit_batch` reads worker_authoritative() once and
//    drives the whole batch down that path. It reads it again at the end; if
//    the authority flipped mid-batch the result is ok=false with
//    AUTHORITY_CHANGED so the caller retries next tick instead of leaving half
//    the rows on the losing side.
// 2. Never fall back across paths. EFFECT owned by the worker but the transport
//    not configured returns WORKER_TRANSPORT_NOT_READY and writes nothing.
//    Writing legacy here would only be erased by the next worker snapshot,
//    which turns into "looked fine, then vanished".
// 3. Only the main thread touches this object. `refresh_catalog` and the
//    program-facts cache resolve through EffectRuntime/NativeSimulationHost on
//    the calling thread; the worker never reads them.
class EffectInstanceForwarder {
public:
    enum class Result : int32_t {
        OK = 0,
        NOT_ATTACHED,
        WORKER_TRANSPORT_NOT_READY,
        INVALID_IDENTITY,
        UNKNOWN_PROGRAM,
        SOURCE_KIND_MISMATCH,
        DEACTIVATION_REQUIRES_RETIRE,
        QUEUE_REJECTED,
        AUTHORITY_CHANGED,
    };

    struct ProgramFacts {
        int32_t program_id = -1;
        int32_t source_kind = 0;
        bool managed_declared = false;
        int32_t target_selector_kind = 0;
        int32_t target_selector_param[2] = {0, 0};
        bool resolved = false;
    };

    // Both pointers are borrowed and must outlive the forwarder. Either may be
    // null; callers then see NOT_ATTACHED instead of a silent legacy write.
    void attach(EffectRuntime *effect, NativeSimulationHost *host);
    void detach();
    bool attached() const { return _effect != nullptr; }

    // Call after configuring the Effect catalog. Drops cached program facts so
    // a reloaded catalog cannot keep resolving yesterday's program ids.
    void refresh_catalog();

    bool worker_authoritative() const;
    // Test seam: force which side this forwarder believes owns EFFECT.
    //
    // Production never needs it -- authority comes from the host's granted
    // domain mask. It exists because that mask is only granted after the
    // worker commits a full day, and a fresh ACTIVE start therefore cannot
    // exercise the worker branch at all (see the "A fresh ACTIVE start earns
    // its grant from the first fully committed day" comment in
    // native_simulation_host.cpp). Without the override the only reachable
    // branch in a headless fixture is the legacy one, which is precisely the
    // branch M2a-5 stopped the ideology runtime from using.
    //
    // -1 = follow the live host (default), 0 = force legacy, 1 = force worker.
    void set_authority_override_for_test(int32_t mode);
    int32_t authority_override_for_test() const { return _authority_override; }
    // Number of worker<->legacy flips observed for the EFFECT domain. Advances
    // only when authority_epoch() is called, which the reconcile entry point
    // does every tick; a caller that sees a new epoch must resubmit in full
    // because the worker snapshot already replaced whatever it wrote before.
    uint64_t authority_epoch();

    // Public entry points, shaped exactly like the DCWorldExt methods they
    // replace so the delegation is a one-liner and the returned dictionaries
    // stay field-for-field comparable with the pre-M2a behaviour.
    godot::Dictionary submit_batch(const godot::Dictionary &batch);
    godot::Dictionary retire(int64_t instance_id, int64_t generation,
                             int64_t effective_day);

    // ── Instance-level entry points ─────────────────────────────────────────
    // submit_batch covers declarative program rows, but the Economy family path
    // drives Effect instances one row at a time through upsert_instance_pod /
    // set_metric_pod / retire_instance_pod. Those need the same routing
    // decision without a Dictionary batch in between, otherwise family effects
    // keep writing EffectRuntime after EFFECT moved to the worker and get erased
    // by the next worker snapshot.
    struct InstanceRow {
        int64_t instance_id = 0;
        std::string program_key;
        uint32_t generation = 0;
        int32_t source_type = 0;
        int64_t source_id = 0;
        uint64_t source_handle = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int32_t level = 0;
        int64_t next_due_day = 0;
        // Absolute last live day, or -1 for "no scheduled expiry". Managed
        // duration instances must carry this on creation: the pod only derives
        // expires_day inside evaluate(), so an instance whose trigger never
        // fires would otherwise never expire on the worker side.
        int64_t expires_day = -1;
        bool active = true;
    };
    bool upsert_instance(const InstanceRow &row, std::string &error);
    bool set_metric(int64_t instance_id, uint32_t generation, int32_t metric_id,
                    int64_t revision, int64_t value, std::string &error);
    bool retire_instance(int64_t instance_id, uint32_t generation,
                         int64_t effective_day, std::string &error);
    // Presence probe with the same authority split the writers use.
    //
    // Economy keeps its own family-effect bindings and rebuilds them after a
    // load, which needs "is this instance still alive". Asking EffectRuntime
    // directly only answers for the legacy authority: under EFFECT worker
    // authority it is writeback-only, so every worker-owned instance reads as
    // absent and the binding was dropped -- which then also leaked the instance,
    // because clear_family_branch_effects retires by binding.
    //
    // A query cannot invalidate anything, so unlike the writers this does not
    // consult or advance the authority epoch: a mid-call flip only makes the
    // answer one tick stale, and the next reconcile overwrites it.
    bool instance_exists(int64_t instance_id, uint32_t generation, bool &exists,
                         std::string &error);
    // The other half of the same question: has this instance fired yet?
    //
    // Country's peer report, the ideology card report and the ideology restore
    // all gate on it. Same failure mode as instance_exists -- EffectRuntime only
    // answers for the legacy authority, so under EFFECT worker authority every
    // worker-owned instance reads as "never fired", which pins the country peer
    // at PENDING and (in the ideology restore) rejects a perfectly good save.
    bool instance_fire_acked(int64_t instance_id, uint32_t generation,
                             bool &acked, std::string &error);

    static const char *result_token(Result result);

private:
    const ProgramFacts *facts_for(const std::string &program_key);
    bool resolve_facts(const std::string &program_key, ProgramFacts &out);
    bool note_authority_change(std::string &code);

    EffectRuntime *_effect = nullptr;
    NativeSimulationHost *_host = nullptr;
    std::unordered_map<std::string, ProgramFacts> _programs;
    bool _last_worker_authoritative = false;
    uint64_t _authority_epoch = 0;
    int32_t _authority_override = -1;
};

} // namespace pk
