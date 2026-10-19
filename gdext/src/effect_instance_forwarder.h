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
