#include "effect_instance_forwarder.h"

#include "effect_runtime.h"
#include "effect_declarative_validation.h"
#include "native_simulation_host.h"
#include "runtime_effect_pod.h"

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
// Required for the implicit const char* -> Variant conversion that
// Dictionary::operator[] and Dictionary::get rely on. dictionary.hpp only
// forward-declares Variant, so without this every literal key fails to bind.
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <vector>

namespace pk {

using namespace godot;

namespace {

Dictionary unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "effect_runtime_unavailable";
    return out;
}

Dictionary forwarder_failure(const char *reason) {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = reason;
    return out;
}

int32_t i32_at(const PackedInt32Array &values, int32_t index, int32_t fallback) {
    return index < values.size() ? values[index] : fallback;
}

int64_t i64_at(const PackedInt64Array &values, int32_t index, int64_t fallback) {
    return index < values.size() ? values[index] : fallback;
}

} // namespace

const char *EffectInstanceForwarder::result_token(Result result) {
    switch (result) {
        case Result::OK: return "ok";
        case Result::NOT_ATTACHED: return "effect_forwarder_not_attached";
        case Result::WORKER_TRANSPORT_NOT_READY:
            return "effect_worker_transport_not_ready";
        case Result::INVALID_IDENTITY: return "effect_instance_identity_invalid";
        case Result::UNKNOWN_PROGRAM: return "effect_instance_program_unknown";
        case Result::SOURCE_KIND_MISMATCH:
            return "effect_family_source_kind_mismatch";
        case Result::DEACTIVATION_REQUIRES_RETIRE:
            return "effect_family_deactivation_requires_retire";
        case Result::QUEUE_REJECTED: return "effect_worker_queue_rejected";
        case Result::AUTHORITY_CHANGED: return "effect_worker_authority_changed";
    }
    return "effect_forwarder_unknown";
}

void EffectInstanceForwarder::attach(EffectRuntime *effect,
                                     NativeSimulationHost *host) {
    _effect = effect;
    _host = host;
    refresh_catalog();
}

void EffectInstanceForwarder::detach() {
    _effect = nullptr;
    _host = nullptr;
    refresh_catalog();
}

void EffectInstanceForwarder::refresh_catalog() {
    _programs.clear();
    // An attach/refresh is exactly the moment callers must forget what the
    // previous authority wrote, so start counting flips from a clean epoch.
    _last_worker_authoritative = worker_authoritative();
    _authority_epoch = 0;
}

void EffectInstanceForwarder::set_authority_override_for_test(int32_t mode) {
    _authority_override = mode < 0 ? -1 : (mode != 0 ? 1 : 0);
    // An override is a deliberate jump, not a flip a caller should be told to
    // retry: re-baseline so it costs no epoch. Otherwise flipping the override
    // between a submit and the epoch check would look like an authority race
    // and make the next reconcile drop every held ref.
    _last_worker_authoritative = worker_authoritative();
}

bool EffectInstanceForwarder::worker_authoritative() const {
    if (_authority_override >= 0) return _authority_override != 0;
    return _host != nullptr &&
        _host->domain_is_worker_authoritative(RuntimeDomainId::EFFECT);
}

uint64_t EffectInstanceForwarder::authority_epoch() {
    const bool authoritative = worker_authoritative();
    if (authoritative != _last_worker_authoritative) {
        _last_worker_authoritative = authoritative;
        ++_authority_epoch;
    }
    return _authority_epoch;
}

bool EffectInstanceForwarder::note_authority_change(std::string &code) {
    const bool authoritative = worker_authoritative();
    if (authoritative == _last_worker_authoritative) {
        code.clear();
        return false;
    }
    // Record the flip here so authority_epoch() advances exactly once for it.
    // Reporting it does not make *this* batch fail on the losing path -- the
    // batch ran end to end on one path -- but the result is downgraded because
    // the other side is now the writer of record.
    _last_worker_authoritative = authoritative;
    ++_authority_epoch;
    code = result_token(Result::AUTHORITY_CHANGED);
    return true;
}

bool EffectInstanceForwarder::resolve_facts(const std::string &program_key,
                                            ProgramFacts &out) {
    out = ProgramFacts{};
    if (_effect == nullptr) return false;
    int32_t program_id = -1;
    int32_t source_kind = 0;
    bool managed_declared = false;
    if (!_effect->declarative_facts_for_key(program_key, program_id, source_kind,
                                            managed_declared)) {
        // The pod catalog is compiled from the same definitions, so a key the
        // runtime does not know cannot be a pod program either.
        return false;
    }
    out.program_id = program_id;
    out.source_kind = source_kind;
    out.managed_declared = managed_declared;
    out.resolved = true;
    return true;
}

const EffectInstanceForwarder::ProgramFacts *EffectInstanceForwarder::facts_for(
        const std::string &program_key) {
    auto found = _programs.find(program_key);
    if (found != _programs.end()) return &found->second;
    // Cache misses too: a key that does not resolve today will not resolve
    // later within the same catalog, and re-asking costs a hash lookup and a
    // string scan on every submitted row.
    ProgramFacts &slot = _programs[program_key];
    resolve_facts(program_key, slot);
    return &slot;
}

Dictionary EffectInstanceForwarder::submit_batch(const Dictionary &batch) {
    if (_effect == nullptr) return unavailable();
    const bool worker_path = worker_authoritative();
    if (worker_path && _host == nullptr)
        return forwarder_failure(result_token(Result::WORKER_TRANSPORT_NOT_READY));

    const PackedInt64Array ids = batch.get("instance_ids", PackedInt64Array());
    const PackedStringArray program_keys = batch.get("program_keys",
                                                     PackedStringArray());
    const PackedInt32Array generations = batch.get("generations",
                                                    PackedInt32Array());
    const PackedInt32Array source_types = batch.get("source_types",
                                                     PackedInt32Array());
    const PackedInt32Array source_kinds = batch.get("source_kinds",
                                                     PackedInt32Array());
    const PackedInt64Array source_ids = batch.get("source_ids",
                                                  PackedInt64Array());
    const PackedInt64Array source_handles = batch.get("source_handles",
                                                      PackedInt64Array());
    const PackedInt64Array target_handles = batch.get("target_handles",
                                                      PackedInt64Array());
    const PackedInt32Array target_generations = batch.get(
        "target_generations", PackedInt32Array());
    const PackedInt32Array levels = batch.get("levels", PackedInt32Array());
    const PackedInt64Array next_due_days = batch.get("next_due_days",
                                                      PackedInt64Array());
    const PackedByteArray active = batch.get("active", PackedByteArray());

    if (!worker_path) {
        // Legacy authority keeps EffectRuntime as the writer of record.
        Dictionary result = _effect->submit_instances(batch);
        if (!bool(result.get("ok", false)) || _host == nullptr) return result;
        // SHADOW mirror: keep the worker snapshot roughly in step so a later
        // authority flip starts from something instead of an empty instance
        // list. Best effort -- a failure here never rolls back the production
        // write. Same BatchRow source as the worker path, so the mirror cannot
        // read different columns than the forwarding path.
        const PackedInt64Array accepted_ids = result.get("instance_ids",
                                                         PackedInt64Array());
        int32_t mirrored = 0;
        int32_t mirror_rejected = 0;
        for (int i = 0; i < ids.size() && i < program_keys.size(); ++i) {
            bool accepted = false;
            for (int a = 0; a < accepted_ids.size(); ++a) {
                if (accepted_ids[a] == ids[i]) { accepted = true; break; }
            }
            if (!accepted) continue;
            const ProgramFacts *facts = facts_for(program_keys[i].utf8().get_data());
            if (facts == nullptr || !facts->resolved) {
                ++mirror_rejected;
                continue;
            }
            RuntimeEffectPodInstanceInput input;
            input.instance_id = ids[i];
            input.generation = static_cast<uint32_t>(
                std::max(1, i32_at(generations, i, 1)));
            input.program_id = facts->program_id;
            input.source_type = i32_at(source_types, i, 0);
            input.source_id = i64_at(source_ids, i, 0);
            input.source_handle = static_cast<uint64_t>(
                i64_at(source_handles, i, 0));
            input.target_handle = static_cast<uint64_t>(
                i64_at(target_handles, i, 0));
            input.target_generation = static_cast<uint32_t>(
                std::max(0, i32_at(target_generations, i, 0)));
            input.level = i32_at(levels, i, 0);
            input.next_due_day = i64_at(next_due_days, i, 0);
            input.active = i >= active.size() || active[i] != 0;
            std::string mirror_error;
            if (_host->queue_effect_pod_instance(input, mirror_error))
                ++mirrored;
            else
                ++mirror_rejected;
        }
        result["effect_pod_mirrored"] = mirrored;
        result["effect_pod_mirror_rejected"] = mirror_rejected;
        // Rule 1 also applies to the legacy path: if EFFECT moved to the worker
        // while this batch was in flight, the caller must retry instead of
        // believing a write the next snapshot will erase.
        std::string authority_code;
        if (bool(result.get("ok", false)) &&
            note_authority_change(authority_code)) {
            result["ok"] = false;
            result["reason"] = authority_code.c_str();
            result["authority_epoch"] = static_cast<int64_t>(_authority_epoch);
        }
        return result;
    }

    if (!_host->effect_pod_transport_ready())
        return forwarder_failure(result_token(Result::WORKER_TRANSPORT_NOT_READY));

    PackedInt64Array accepted_ids;
    int32_t rejected = 0;
    const char *reject_reason = nullptr;
    std::string result_reason;
    for (int i = 0; i < ids.size() && i < program_keys.size(); ++i) {
        const ProgramFacts *facts = facts_for(program_keys[i].utf8().get_data());
        if (facts == nullptr || !facts->resolved) {
            ++rejected;
            reject_reason = result_token(Result::UNKNOWN_PROGRAM);
            continue;
        }
        const uint32_t generation = static_cast<uint32_t>(
            std::max(1, i32_at(generations, i, 1)));
        const bool row_active = i >= active.size() || active[i] != 0;
        // Same rule the main thread applies (effect_declarative_validation.h).
        // Without this the worker accepted "deactivate a managed instance"
        // submissions the main thread refuses, and the instance simply stayed.
        EffectDeclarativeFacts declarative;
        declarative.source_kind = facts->source_kind;
        declarative.managed_declared = facts->managed_declared;
        const EffectDeclarativeReject verdict = validate_effect_declarative_row(
            declarative, ids[i], generation, !source_kinds.is_empty(),
            i32_at(source_kinds, i, 0), row_active);
        if (verdict != EffectDeclarativeReject::NONE) {
            ++rejected;
            reject_reason = effect_declarative_reject_token(verdict);
            continue;
        }
        RuntimeEffectPodInstanceInput input;
        input.instance_id = ids[i];
        input.generation = generation;
        input.program_id = facts->program_id;
        input.source_type = i32_at(source_types, i, 0);
        input.source_id = i64_at(source_ids, i, 0);
        input.source_handle = static_cast<uint64_t>(i64_at(source_handles, i, 0));
        input.target_handle = static_cast<uint64_t>(
            i64_at(target_handles, i, 0));
        input.target_generation = static_cast<uint32_t>(
            std::max(0, i32_at(target_generations, i, 0)));
        input.level = i32_at(levels, i, 0);
        input.next_due_day = i64_at(next_due_days, i, 0);
        input.active = row_active;
        std::string queue_error;
        if (_host->queue_effect_pod_instance(input, queue_error)) {
            accepted_ids.push_back(ids[i]);
        } else {
            ++rejected;
            if (!queue_error.empty())
                result_reason = queue_error;
            else
                reject_reason = result_token(Result::QUEUE_REJECTED);
        }
    }

    Dictionary result;
    const bool batch_ok = rejected == 0 && accepted_ids.size() == ids.size();
    result["ok"] = batch_ok;
    result["instance_ids"] = accepted_ids;
    result["path"] = "EFFECT_WORKER";
    result["effect_pod_queued"] = accepted_ids.size();
    result["effect_pod_rejected"] = rejected;
    if (!batch_ok) {
        if (!result_reason.empty())
            result["reason"] = String(result_reason.c_str());
        else if (reject_reason != nullptr)
            result["reason"] = reject_reason;
    }
    // Rule 1: a flip mid-batch must not look like success.
    std::string authority_code;
    if (batch_ok && note_authority_change(authority_code)) {
        result["ok"] = false;
        result["reason"] = authority_code.c_str();
        result["authority_epoch"] = static_cast<int64_t>(_authority_epoch);
    }
    return result;
}

Dictionary EffectInstanceForwarder::retire(int64_t instance_id, int64_t generation,
                                           int64_t effective_day) {    if (_effect == nullptr) return unavailable();
    const bool worker_path = worker_authoritative();
    if (worker_path && _host == nullptr)
        return forwarder_failure(result_token(Result::WORKER_TRANSPORT_NOT_READY));
    if (worker_path) {
        if (generation <= 0) {
            // Pre-M2a token for this exact path. Kept verbatim so a caller that
            // matched on it keeps working; the declarative validator's own
            // identity token is used everywhere else.
            Dictionary invalid;
            invalid["ok"] = false;
            invalid["reason"] = "effect_worker_retire_invalid";
            return invalid;
        }
        Dictionary out;
        std::string queue_error;
        const bool ok = _host->queue_effect_pod_remove(
            instance_id, static_cast<uint32_t>(generation), queue_error);
        out["ok"] = ok;
        out["path"] = "EFFECT_WORKER";
        if (!ok) out["reason"] = String(queue_error.c_str());
        // Retire carries no declarative row of its own, so a flip here only
        // means the caller should re-check next tick; report it the same way.
        std::string authority_code;
        if (note_authority_change(authority_code)) {
            out["ok"] = false;
            out["reason"] = authority_code.c_str();
            out["authority_epoch"] = static_cast<int64_t>(_authority_epoch);
        }
        return out;
    }
    Dictionary out;
    std::string error;
    const bool ok = generation > 0 && _effect->retire_instance_pod(
        instance_id, static_cast<uint32_t>(generation), effective_day, error);
    out["ok"] = ok;
    if (!ok) out["reason"] = String(error.c_str());
    if (ok && _host != nullptr) {
        std::string mirror_error;
        out["effect_pod_mirrored"] = _host->queue_effect_pod_remove(
            instance_id, static_cast<uint32_t>(generation), mirror_error);
        if (!bool(out["effect_pod_mirrored"]))
            out["effect_pod_mirror_reason"] = String(mirror_error.c_str());
    }
    return out;
}

bool EffectInstanceForwarder::upsert_instance(const InstanceRow &row,
                                              std::string &error) {
    error.clear();
    if (_effect == nullptr) {
        error = result_token(Result::NOT_ATTACHED);
        return false;
    }
    if (row.instance_id <= 0 || row.generation == 0) {
        error = result_token(Result::INVALID_IDENTITY);
        return false;
    }
    const bool worker_path = worker_authoritative();
    if (worker_path) {
        // Rule 2: never fall back across paths. A legacy write here would be
        // erased by the next worker snapshot, which reads as "looked fine, then
        // vanished".
        if (_host == nullptr || !_host->effect_pod_transport_ready()) {
            error = result_token(Result::WORKER_TRANSPORT_NOT_READY);
            return false;
        }
        const ProgramFacts *facts = facts_for(row.program_key);
        if (facts == nullptr || !facts->resolved) {
            error = result_token(Result::UNKNOWN_PROGRAM);
            return false;
        }
        RuntimeEffectPodInstanceInput input;
        input.instance_id = row.instance_id;
        input.generation = row.generation;
        input.program_id = facts->program_id;
        input.source_type = row.source_type;
        input.source_id = row.source_id;
        input.source_handle = row.source_handle;
        input.target_handle = row.target_handle;
        input.target_generation = row.target_generation;
        input.level = row.level;
        input.next_due_day = row.next_due_day;
        input.expires_day = row.expires_day;
        input.active = row.active;
        if (!_host->queue_effect_pod_instance(input, error)) return false;
    } else {
        if (!_effect->upsert_instance_pod(
                row.instance_id, row.program_key, row.generation,
                row.source_type, row.source_id, row.source_handle,
                row.target_handle, row.target_generation, row.level,
                row.next_due_day, row.active, error)) {
            return false;
        }
        if (row.expires_day >= 0 &&
            !_effect->set_instance_expiry_pod(row.instance_id, row.generation,
                                              row.expires_day)) {
            // The row landed but its expiry did not. Reporting success here
            // would leave a managed-duration instance alive forever, which is
            // exactly the divergence expires_day exists to prevent.
            error = "effect_instance_expiry_write_failed";
            return false;
        }
        if (_host != nullptr) {
            // SHADOW mirror, same best-effort rule as submit_batch: a failure
            // here never rolls back the production write.
            const ProgramFacts *facts = facts_for(row.program_key);
            if (facts != nullptr && facts->resolved) {
                RuntimeEffectPodInstanceInput input;
                input.instance_id = row.instance_id;
                input.generation = row.generation;
                input.program_id = facts->program_id;
                input.source_type = row.source_type;
                input.source_id = row.source_id;
                input.source_handle = row.source_handle;
                input.target_handle = row.target_handle;
                input.target_generation = row.target_generation;
                input.level = row.level;
                input.next_due_day = row.next_due_day;
                input.expires_day = row.expires_day;
                input.active = row.active;
                std::string mirror_error;
                _host->queue_effect_pod_instance(input, mirror_error);
            }
        }
    }
    // Rule 1: a flip mid-call must not look like success. The row landed on one
    // path, but the other side is now the writer of record, so the caller has to
    // resubmit next tick instead of believing it.
    std::string authority_code;
    if (note_authority_change(authority_code)) {
        error = authority_code;
        return false;
    }
    return true;
}

bool EffectInstanceForwarder::set_metric(int64_t instance_id, uint32_t generation,
                                         int32_t metric_id, int64_t revision,
                                         int64_t value, std::string &error) {
    error.clear();
    if (_effect == nullptr) {
        error = result_token(Result::NOT_ATTACHED);
        return false;
    }
    if (worker_authoritative()) {
        if (_host == nullptr || !_host->effect_pod_transport_ready()) {
            error = result_token(Result::WORKER_TRANSPORT_NOT_READY);
            return false;
        }
        if (!_host->queue_effect_pod_metric(instance_id, generation, metric_id,
                                            revision, value, error)) {
            return false;
        }
    } else {
        if (!_effect->set_metric_pod(instance_id, metric_id, revision, value,
                                     error)) {
            return false;
        }
        if (_host != nullptr) {
            std::string mirror_error;
            _host->queue_effect_pod_metric(instance_id, generation, metric_id,
                                           revision, value, mirror_error);
        }
    }
    std::string authority_code;
    if (note_authority_change(authority_code)) {
        error = authority_code;
        return false;
    }
    return true;
}

bool EffectInstanceForwarder::instance_exists(int64_t instance_id,
                                              uint32_t generation,
                                              bool &exists,
                                              std::string &error) {
    error.clear();
    exists = false;
    if (_effect == nullptr) {
        error = result_token(Result::NOT_ATTACHED);
        return false;
    }
    if (worker_authoritative()) {
        // The worker owns the instance list; EffectRuntime is writeback-only and
        // refreshes on its own pump, so it must not be asked here.
        if (_host == nullptr || !_host->effect_pod_transport_ready()) {
            error = result_token(Result::WORKER_TRANSPORT_NOT_READY);
            return false;
        }
        exists = _host->effect_pod_instance_exists(instance_id, generation);
        return true;
    }
    exists = _effect->has_instance_pod(instance_id, generation);
    return true;
}

bool EffectInstanceForwarder::instance_fire_acked(int64_t instance_id,
                                                  uint32_t generation,
                                                  bool &acked,
                                                  std::string &error) {
    error.clear();
    acked = false;
    if (_effect == nullptr) {
        error = result_token(Result::NOT_ATTACHED);
        return false;
    }
    if (worker_authoritative()) {
        // Same rule as instance_exists: the worker owns fire_seq/ack, and the
        // main thread's copy only catches up on its own writeback pump.
        if (_host == nullptr || !_host->effect_pod_transport_ready()) {
            error = result_token(Result::WORKER_TRANSPORT_NOT_READY);
            return false;
        }
        acked = _host->effect_pod_instance_fire_acked(instance_id, generation);
        return true;
    }
    acked = _effect->instance_fire_acked_pod(instance_id, generation);
    return true;
}

bool EffectInstanceForwarder::retire_instance(int64_t instance_id,
                                              uint32_t generation,
                                              int64_t effective_day,
                                              std::string &error) {
    error.clear();
    // Delegates so both entry points share one routing decision and the same
    // authority-flip handling.
    const Dictionary out = retire(instance_id, static_cast<int64_t>(generation),
                                  effective_day);
    if (bool(out.get("ok", false))) return true;
    const String reason = out.get("reason", String());
    if (reason.is_empty()) {
        error = result_token(Result::QUEUE_REJECTED);
    } else {
        error = reason.utf8().get_data();
        if (error.empty()) error = result_token(Result::QUEUE_REJECTED);
    }
    return false;
}

} // namespace pk
