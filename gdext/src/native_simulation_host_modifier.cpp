#include "economy_authority_transfer.h"
#include "economy_invariant_probe.h"
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include "native_simulation_host.h"
#include "native_simulation_day_context.h"
#include "runtime_module_descriptor.h"
#include <cassert>
#include "country_core_apply.h"
#include "country_ai_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "effect_magnitude.h"
#include "runtime_economy_ecp2.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"
#include "runtime_switch_registry.h"
#include "pk_log.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <exception>
#include <limits>
#include <type_traits>
#include <unordered_set>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "native_simulation_host_support.h"

namespace pk {

bool NativeSimulationHost::encode_modifier_pod_save(
        std::vector<uint8_t> &bytes, std::string &error) const {
    if (!_modifier_pod_configured) { error = "modifier_pod_not_configured"; return false; }
    _modifier_pod_authority.serialize(bytes);
    return !bytes.empty();
}

bool NativeSimulationHost::restore_modifier_pod_save(
        const uint8_t *bytes, size_t size, std::string &error) {
    if (!_modifier_pod_configured) { error = "modifier_pod_not_configured"; return false; }
    return _modifier_pod_authority.restore(bytes, size, error);
}

bool NativeSimulationHost::try_acquire_modifier_snapshot(
        uint64_t after_generation, uint32_t &slot) {
    if (!_modifier_snapshots.try_acquire_latest(after_generation, slot)) return false;
    const RuntimeModifierPodSnapshot &snapshot =
        _modifier_snapshots.read_buffer(slot);
    bool valid = _modifier_pod_configured &&
        snapshot.abi_version == RUNTIME_MODIFIER_POD_ABI_VERSION &&
        snapshot.catalog_hash == _modifier_pod_catalog.catalog_hash;
    for (const RuntimeModifierPodEntry &entry : snapshot.entries)
        valid = valid && entry.domain < 4;
    for (const RuntimeModifierPodBucket &bucket : snapshot.buckets)
        valid = valid && bucket.domain < 4 && bucket.scope < 3;
    if (!valid) {
        _modifier_snapshots.release(slot);
        return false;
    }
    return true;
}

const RuntimeModifierPodSnapshot &NativeSimulationHost::modifier_snapshot_buffer(
        uint32_t slot) const { return _modifier_snapshots.read_buffer(slot); }

void NativeSimulationHost::release_modifier_snapshot(uint32_t slot) {
    _modifier_snapshots.release(slot);
}

bool NativeSimulationHost::try_acquire_effect_snapshot(
        uint64_t after_generation, uint32_t &slot) {
    if (!_effect_snapshots.try_acquire_latest(after_generation, slot)) return false;
    const RuntimeEffectPodSnapshot &snapshot =
        _effect_snapshots.read_buffer(slot);
    const bool valid = _effect_pod_configured &&
        snapshot.abi_version == RUNTIME_EFFECT_POD_ABI_VERSION &&
        snapshot.catalog_hash == _effect_pod_catalog.catalog_hash;
    if (!valid) {
        _effect_snapshots.release(slot);
        return false;
    }
    return true;
}

const RuntimeEffectPodSnapshot &NativeSimulationHost::effect_snapshot_buffer(
        uint32_t slot) const {
    return _effect_snapshots.read_buffer(slot);
}

void NativeSimulationHost::release_effect_snapshot(uint32_t slot) {
    _effect_snapshots.release(slot);
}

bool NativeSimulationHost::try_acquire_ideology_snapshot(
        uint64_t after_generation, uint32_t &slot) {
    if (!_ideology_snapshots.try_acquire_latest(after_generation, slot))
        return false;
    const RuntimeIdeologyPodSnapshot &snapshot =
        _ideology_snapshots.read_buffer(slot);
    const bool valid = _ideology_pod_configured &&
        snapshot.abi_version == RUNTIME_IDEOLOGY_POD_ABI_VERSION &&
        snapshot.catalog_hash == _ideology_pod_catalog.catalog_hash;
    if (!valid) {
        _ideology_snapshots.release(slot);
        return false;
    }
    return true;
}

const RuntimeIdeologyPodSnapshot &
NativeSimulationHost::ideology_snapshot_buffer(uint32_t slot) const {
    return _ideology_snapshots.read_buffer(slot);
}

void NativeSimulationHost::release_ideology_snapshot(uint32_t slot) {
    _ideology_snapshots.release(slot);
}

bool NativeSimulationHost::modifier_pod_self_test(std::string *out_error) const {
    const auto fail = [out_error](const char *reason) {
        if (out_error != nullptr) *out_error = reason;
        return false;
    };
    std::string authority_error;
    if (!RuntimeModifierPodAuthority::self_test(authority_error)) {
        if (out_error != nullptr) *out_error = authority_error;
        return false;
    }
    if (!RuntimeModifierSnapshotRing::self_test())
        return fail("modifier_pod_snapshot_ring_self_test_failed");
    RuntimeCommandPacket packet;
    packet.envelope.request_id = 11;
    packet.envelope.producer_id = 7;
    packet.envelope.sequence = 9;
    packet.envelope.requested_day = 3;
    packet.envelope.effective_day = 4;
    packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
    packet.envelope.opcode = static_cast<uint16_t>(RuntimeModifierPodOpcode::APPLY);
    packet.envelope.payload_size = RUNTIME_MODIFIER_POD_WIRE_SIZE;
    // Keep the protocol self-test coupled to the fixed little-endian payload ABI.
    size_t cursor = 0;
    const auto append = [&packet, &cursor](auto value) {
        using T = decltype(value);
        using U = std::make_unsigned_t<T>;
        U bits = static_cast<U>(value);
        for (size_t i = 0; i < sizeof(T); ++i) {
            packet.payload[cursor++] = static_cast<uint8_t>(bits & static_cast<U>(0xffu));
            bits >>= 8u;
        }
    };
    append(static_cast<uint32_t>(RUNTIME_MODIFIER_POD_WIRE_ABI_VERSION));
    append(static_cast<uint16_t>(2));
    append(static_cast<uint16_t>(2));
    append(static_cast<int32_t>(5));
    append(static_cast<uint64_t>(0x0000000300000004ull));
    append(static_cast<uint64_t>(6));
    append(static_cast<uint64_t>(7));
    append(static_cast<uint64_t>(8));
    append(static_cast<int32_t>(10));
    append(static_cast<int32_t>(2));
    append(static_cast<int32_t>(32768));
    append(static_cast<uint64_t>(0));
    append(static_cast<uint32_t>(3));
    append(static_cast<uint64_t>(12));
    RuntimeModifierPodCommand decoded;
    if (cursor != RUNTIME_MODIFIER_POD_WIRE_SIZE ||
        !decode_modifier_packet(packet, decoded) ||
        !modifier_packet_shape_valid(decoded) || decoded.request_id != 11 ||
        decoded.domain != 2 || decoded.scope != 2 || decoded.definition_id != 5 ||
        decoded.target_generation != 3 || decoded.input_generation != 12)
        return fail("modifier_pod_wire_decode_self_test_failed");
    RuntimeCommandPacket malformed = packet;
    --malformed.envelope.payload_size;
    if (decode_modifier_packet(malformed, decoded))
        return fail("modifier_pod_wire_size_self_test_failed");
    malformed = packet;
    malformed.payload[0] ^= 0xffu;
    if (decode_modifier_packet(malformed, decoded))
        return fail("modifier_pod_wire_abi_self_test_failed");
    malformed = packet;
    malformed.envelope.opcode = 0;
    if (!decode_modifier_packet(malformed, decoded) ||
        modifier_packet_shape_valid(decoded))
        return fail("modifier_pod_wire_opcode_self_test_failed");
    malformed = packet;
    malformed.payload[4] = 4;
    malformed.payload[5] = 0;
    if (!decode_modifier_packet(malformed, decoded) ||
        modifier_packet_shape_valid(decoded))
        return fail("modifier_pod_wire_domain_self_test_failed");
    if (out_error != nullptr) out_error->clear();
    return true;
}

std::shared_ptr<const RuntimeEnvironmentSnapshot>
NativeSimulationHost::environment_snapshot() const {
    // 诊断 / 物理派生读 latest；worker 日计划必须走 environment_input_for_plan。
    if (auto latest = _environment_ring.latest()) return latest;
    return std::atomic_load_explicit(&_environment_snapshot, std::memory_order_acquire);
}

std::shared_ptr<const RuntimeEnvironmentSnapshot>
NativeSimulationHost::environment_input_for_plan() const {
    if (auto oldest = _environment_ring.peek_oldest()) return oldest;
    // Under ACTIVE Climate authority the day plan must stay on the FIFO head.
    // Falling back to latest() after a drain left the ring empty hands the
    // worker a future Host day, which then mismatches forever and nails the
    // main thread on climate_input_capacity_day_barrier.
    const bool climate_active =
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
    if (climate_active) return nullptr;
    return environment_snapshot();
}

bool NativeSimulationHost::map_effect_intent_to_modifier_command(
        const RuntimeDomainIntent &intent, uint64_t input_generation,
        RuntimeModifierPodCommand &command) {
    // Single place that turns an Effect-produced intent into the Modifier
    // POD command. Extracted from execute_modifier_worker_stage so the
    // adapter mapping can be asserted without planning a day (planning one
    // feeds ACKs back into the Effect authority, which a mapping fixture has
    // no transactions for).
    // Returns false when the intent must be dropped instead of mapped.
    command.request_id =
        intent.request_id != 0 ? intent.request_id : intent.source_id;
    command.producer_id = intent.producer_id;
    command.sequence = intent.sequence;
    command.effective_day = intent.effective_day;
    command.requested_day = intent.effective_day;
    command.opcode = intent.opcode;
    command.domain = intent.payload[1] >= 0 && intent.payload[1] < 4
        ? static_cast<uint16_t>(intent.payload[1]) : 0;
    // Effect catalogs store the Modifier definition_key, not a dense id, in
    // command metadata. Resolve via key hash (with legacy payload[0] fallback).
    command.definition_id =
        resolve_modifier_definition_id_for_effect_intent(intent);
    command.entity_handle = intent.target_handle;
    command.target_generation = intent.target_generation;
    command.group_handle = intent.group_handle;
    command.modifier_handle = intent.modifier_handle;
    command.duration_days = intent.duration_days;
    command.stacks = intent.stacks > 0 ? intent.stacks : 1;
    // `magnitude_q16` is the already-scaled adapter value. A legitimately
    // emitted zero must survive; only intents without emitted Effect value
    // metadata use the legacy 1.0 default.
    const bool has_effect_value =
        (intent.reserved_effect_flags &
         RUNTIME_DOMAIN_INTENT_HAS_EFFECT_VALUE) != 0u;
    command.magnitude_q16 = has_effect_value ? intent.magnitude_q16 : 65536;
    command.input_generation = input_generation;
    // The POD carries the adapter EffectRuntime compiled for this command
    // in intent.reserved (low byte = adapter, next byte = the program's
    // target_domain). Guessing the adapter from the Modifier domain marked
    // ideology commands as TECHNOLOGY and clamped their magnitude to 1.0, so
    // an equipped card "worked" with the wrong weight.
    //
    // TECHNOLOGY / FAMILY / PERSON are still resolved from the Modifier
    // domain below: those three were already field-for-field equivalent to
    // their EffectRuntime branches, and re-routing them would rewrite a live
    // production path without new evidence. TRIGGER, FAMILY_EFFECT and
    // GENERIC were NOT equivalent and are handled explicitly.
    //
    // Only Effect-produced intents carry the adapter: runtime_effect_pod.cpp
    // stamps intent.reserved for every MODIFIER_COMMAND it emits, and the
    // Effect POD lists GENERIC as 0, so an ungated read would send every
    // non-Effect intent (the authority_plan path, whose reserved is always
    // zero) into the GENERIC branch and silently retire the domain
    // heuristic below. adapter_kind == -1 means "not an Effect intent".
    const int32_t adapter_kind =
        intent.source_domain == static_cast<uint16_t>(RuntimeDomainId::EFFECT)
        ? (intent.reserved & 0xFF) : -1;
    const int32_t adapter_target_domain = (intent.reserved >> 8) & 0xFF;
    // EffectRuntime's GENERIC adapter reads the instance row (its own
    // source_type / source_id), but the intent only carries the instance id
    // in source_id. Look the row up in the snapshot the Effect stage just
    // committed on this same thread.
    // Match EffectRuntime native adapter semantics (technology/family/person).
    // payload[2]==0 means "unset", not GLOBAL — defaulting to GLOBAL made
    // has_technology_effect miss ENTITY+TECH unique keys after a successful
    // apply, and wrong source_type blocked UNIQUE_SOURCE identity.
    if (adapter_kind == EFFECT_MODIFIER_TECHNOLOGY) {
        // Mirrors EffectRuntime's technology adapter: technology modifiers
        // represent an enabled capability, so their magnitude is always one
        // regardless of the effect program's sampled value.
        command.scope = 2; // ENTITY
        command.entity_handle = intent.target_handle;
        command.group_handle = 0;
        command.source_type = 0x54454348ULL; // TECH
        command.source_id = intent.source_id & 0xffffULL;
        command.magnitude_q16 = 65536;
    } else if (adapter_kind == EFFECT_MODIFIER_IDEOLOGY) {
        // Mirrors EffectRuntime's NATIVE_MODIFIER_IDEOLOGY branch:
        // effect_runtime.cpp:5317-5363.
        command.source_type = 0x4944454fULL; // IDEO
        command.source_id = intent.source_id;
        // Cell-scoped programs (settlement cell = 2, building/resource in a
        // cell = 5) bind GROUP; family programs (0) bind ENTITY on the stable
        // family handle. Never leave both handles populated: the Modifier
        // validates group_handle as a settlement before it looks at scope.
        command.scope = 1; // GROUP
        command.entity_handle = intent.target_handle;
        command.group_handle = intent.target_handle;
        if (adapter_target_domain != 2 && adapter_target_domain != 5) {
            command.scope = 2; // ENTITY
            command.group_handle = 0;
        }
        // The Effect POD stamps the program's target_domain in `reserved`.
        // payload[2] is Modifier command metadata, not a scope override.
    } else if (adapter_kind == EFFECT_MODIFIER_TRIGGER) {
        // effect_runtime.cpp:5279-5288. Binds ENTITY on the command's own
        // target handle and always tags TRIGGER. The old fallthrough tagged
        // these as EFFECT, which never matched a trigger-owned row.
        command.scope = 2; // ENTITY
        command.entity_handle = intent.target_handle;
        command.source_type = 0x54524947474552ULL; // TRIGGER
        command.source_id = intent.source_id;
    } else if (adapter_kind == EFFECT_MODIFIER_FAMILY_EFFECT) {
        // effect_runtime.cpp:5289-5316. Same target_domain split as the
        // ideology adapter, except EffectRuntime refuses an unknown
        // target_domain outright (supported=false) instead of defaulting to
        // ENTITY. Drop the command rather than invent a scope.
        int32_t scope = 0; // 0 = unsupported
        switch (adapter_target_domain) {
            case 0: // Family.
            case 1: // Branch.
            case 3: // Country.
            case 4: // Climate cell.
                scope = 2; // ENTITY
                break;
            case 2: // Settlement cell.
            case 5: // Building/resource selector within the cell.
                scope = 1; // GROUP
                break;
            default:
                break;
        }
        if (scope == 0) return false;
        command.scope = scope;
        command.entity_handle = intent.target_handle;
        command.group_handle = intent.target_handle;
        command.source_type = 0x46414d4546464543ULL; // FAMEFFEC
        command.source_id = intent.source_id;
    } else if (adapter_kind == EFFECT_MODIFIER_GENERIC) {
        // effect_runtime.cpp:5364-5374. This is the branch the old domain
        // heuristic got wrong: an ordinary declarative MODIFIER_COMMAND is
        // GENERIC, and EffectRuntime tags it with the INSTANCE's own
        // source_type / source_id -- not with RuntimeDomainId::EFFECT. A
        // generic program whose domain happened to be 1 was also being
        // relabelled TECH and pinned to magnitude 1.0.
        const auto effect_view = _effect_pod_authority.copy_committed_view(intent.source_id);
        assert(_effect_pod_authority.observe_committed_view(effect_view));
        const RuntimeEffectPodInstance *source = effect_view.found ? &effect_view.instance : nullptr;
        command.scope = 2; // ENTITY
        command.entity_handle = intent.target_handle;
        command.source_type = source != nullptr
            ? static_cast<uint64_t>(source->source_type)
            : static_cast<uint64_t>(RuntimeDomainId::EFFECT);
        command.source_id = source != nullptr
            ? static_cast<uint64_t>(source->source_id)
            : intent.source_id;
    } else if (command.domain == 1) {
        command.scope = 2; // ENTITY
        command.source_type = 0x54454348ULL; // TECH
        command.source_id = intent.source_id & 0xffffULL;
    } else if (command.domain == 2) {
        command.scope = 1; // GROUP
        command.group_handle = intent.target_generation;
        command.source_type = 0x46414d494c59ULL; // FAMILY
        command.source_id = intent.target_handle;
    } else if (command.domain == 3) {
        command.scope = 2; // ENTITY
        command.source_type = 0x504552534f4eULL; // PERSON
        command.source_id = intent.source_id;
    } else if (intent.payload[2] >= 1 && intent.payload[2] <= 2) {
        command.scope = static_cast<int32_t>(intent.payload[2]);
        command.source_type = static_cast<uint64_t>(RuntimeDomainId::EFFECT);
        command.source_id = intent.source_id;
    } else {
        command.scope = 2;
        command.source_type = static_cast<uint64_t>(RuntimeDomainId::EFFECT);
        command.source_id = intent.source_id;
    }
    return true;
}


bool NativeSimulationHost::execute_modifier_worker_stage(
        int64_t day, uint64_t input_generation,
        const std::vector<RuntimeCommandPacket> &day_commands,
        bool effect_upstream_ok,
        RuntimeDomainAuthorityPlan *authority_plan,
        std::string &authority_error,
        std::string &error) {
    error.clear();
    std::vector<RuntimeModifierPodCommand> modifier_commands;
    modifier_commands.reserve(day_commands.size());
    for (const RuntimeCommandPacket &packet : day_commands) {
        RuntimeModifierPodCommand command;
        if (decode_modifier_packet(packet, command))
            modifier_commands.push_back(command);
    }

    // Effect POD upstream (F7/E8): when Effect stage succeeded with a non-empty
    // catalog, Modifier consumes those intents. SHADOW fixture intents are
    // stripped by the caller when upstream is active. ACTIVE with an empty
    // Effect catalog uses empty intents (no fixture).
    const std::vector<RuntimeDomainIntent> empty_intents;
    const std::vector<RuntimeDomainIntent> &intent_source =
        effect_upstream_ok ? _effect_day_modifier_intents
                           : (authority_plan != nullptr ? authority_plan->intents
                                                       : empty_intents);
    std::vector<RuntimeModifierPodCommand> modifier_intents;
    modifier_intents.reserve(intent_source.size());
    for (const RuntimeDomainIntent &intent : intent_source) {
        if (intent.target_domain !=
            static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
            continue;
        }
        RuntimeModifierPodCommand command;
        if (!map_effect_intent_to_modifier_command(intent, input_generation,
                                                   command)) {
            continue;
        }
        if (command.definition_id < 0) {
            static int s_def_left = 12;
            if (s_def_left-- > 0) {
                pk::log_info(
                    "[tech-ack-diag/modifier] definition_id unresolved "
                    "request=%d seq=%d domain=%d payload0=%d hashes=%d",
                    static_cast<int64_t>(command.request_id),
                    static_cast<int64_t>(command.sequence),
                    static_cast<int64_t>(command.domain),
                    static_cast<int64_t>(intent.payload[0]),
                    static_cast<int64_t>(
                        _modifier_definition_id_by_key_hash.size()));
            }
        }
        modifier_intents.push_back(command);
    }

    auto publish_fallback = [this](const char *reason) {
        size_t i = 0;
        for (; i + 1 < _modifier_pod_fallback_reason.size() &&
                reason != nullptr && reason[i] != '\0'; ++i) {
            _modifier_pod_fallback_reason[i].store(
                reason[i], std::memory_order_release);
        }
        for (; i < _modifier_pod_fallback_reason.size(); ++i) {
            _modifier_pod_fallback_reason[i].store(
                '\0', std::memory_order_release);
        }
    };

    // SHADOW may run the diagnostic domain runner without a Modifier POD
    // catalog. ACTIVE always requires the POD when this stage is invoked.
    if (!_modifier_pod_configured) {
        if (!modifier_commands.empty() || !modifier_intents.empty()) {
            error = "modifier_pod_not_configured";
            publish_fallback(error.c_str());
            _modifier_pod_ready.store(false, std::memory_order_release);
            if (authority_plan != nullptr) {
                _domain_authority_runner.discard_plan();
                if (authority_error.empty()) authority_error = error;
            }
            return false;
        }
        _modifier_pod_ready.store(false, std::memory_order_release);
        publish_fallback("modifier_pod_not_configured");
        if (authority_plan != nullptr) {
            return _domain_authority_runner.commit_day(
                *authority_plan, authority_error);
        }
        error = "modifier_pod_not_configured";
        return false;
    }

    bool modifier_ok = true;
    std::string modifier_error;
    RuntimeModifierPodSnapshot modifier_snapshot;
    RuntimeModifierPodReport modifier_report;
    std::vector<RuntimeDomainAck> modifier_acks;
    double modifier_plan_ms = 0.0;
    const bool ideology_bridge = ideology_modifier_bridge_active();
    std::vector<uint8_t> ideology_batch_ok;
    if (ideology_bridge)
        stage_ideology_modifier_commands(day, input_generation);
    const auto plan_started = std::chrono::steady_clock::now();
    modifier_ok = _modifier_pod_authority.plan_day(
        day, input_generation, modifier_commands, modifier_intents,
        modifier_snapshot, modifier_acks, modifier_report, modifier_error,
        ideology_bridge && !_ideology_day_modifier_batches.empty()
            ? &_ideology_day_modifier_batches : nullptr,
        &ideology_batch_ok);
    modifier_plan_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - plan_started).count();
    if (!modifier_ok) {
        static int s_mod_fail_left = 12;
        if (s_mod_fail_left-- > 0 && !modifier_intents.empty()) {
            pk::log_info(
                "[tech-ack-diag/modifier] plan_day FAILED day=%d intents=%d "
                "reason=%s def0=%d scope0=%d src_type0=%d",
                day, static_cast<int64_t>(modifier_intents.size()),
                std::string(modifier_error.c_str()).c_str(),
                static_cast<int64_t>(modifier_intents.front().definition_id),
                static_cast<int64_t>(modifier_intents.front().scope),
                static_cast<int64_t>(modifier_intents.front().source_type));
        }
        _modifier_pod_authority.discard_plan();
    }

    bool authority_ok = true;
    if (modifier_ok) {
        if (effect_upstream_ok) {
            if (!modifier_acks.empty() &&
                !_effect_pod_authority.apply_acks(
                    modifier_acks, modifier_error)) {
                modifier_ok = false;
            } else {
                _effect_pod_ack_count.store(
                    static_cast<uint32_t>(modifier_acks.size()),
                    std::memory_order_release);
                _effect_pod_state_hash.store(
                    _effect_pod_authority.snapshot().deterministic_state_hash,
                    std::memory_order_release);
            }
        } else if (authority_plan != nullptr) {
            modifier_ok = _domain_authority_runner.accept_modifier_acks(
                *authority_plan, modifier_acks, modifier_error);
        }
    }

    uint32_t modifier_slot = 0;
    bool modifier_slot_reserved = false;
    if (modifier_ok) {
        if (!_modifier_snapshots.try_begin_write(modifier_slot)) {
            modifier_ok = false;
            modifier_error = "modifier_snapshot_ring_full";
        } else {
            _modifier_snapshots.write_buffer(modifier_slot) = modifier_snapshot;
            modifier_slot_reserved = true;
        }
    }

    const auto replay_started = std::chrono::steady_clock::now();
    if (modifier_ok) {
        modifier_ok = _modifier_pod_authority.commit_day(
            modifier_snapshot, modifier_error);
        if (modifier_ok && authority_plan != nullptr) {
            authority_ok = _domain_authority_runner.commit_day(
                *authority_plan, authority_error);
        }
        if (modifier_ok && authority_ok && modifier_slot_reserved) {
            _modifier_snapshots.publish(modifier_slot);
            modifier_slot_reserved = false;
            _modifier_pod_snapshot_generation.store(
                modifier_snapshot.generation, std::memory_order_release);
        }
    } else {
        authority_ok = false;
        _modifier_pod_authority.discard_plan();
        if (authority_plan != nullptr) {
            _domain_authority_runner.discard_plan();
            if (authority_error.empty()) authority_error = modifier_error;
        }
    }
    if ((!modifier_ok || !authority_ok) && modifier_slot_reserved)
        _modifier_snapshots.release(modifier_slot);
    const double modifier_replay_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - replay_started).count();

    const bool modifier_committed = modifier_ok && authority_ok;
    _modifier_pod_ready.store(modifier_committed, std::memory_order_release);
    _modifier_pod_plan_ms.store(modifier_plan_ms, std::memory_order_release);
    _modifier_pod_replay_ms.store(modifier_replay_ms, std::memory_order_release);
    _modifier_pod_work_units.store(modifier_report.work_units,
                                   std::memory_order_release);
    _modifier_pod_state_hash.store(
        modifier_committed ? modifier_snapshot.state_hash
                           : _modifier_pod_authority.snapshot().state_hash,
        std::memory_order_release);
    _modifier_pod_ack_count.store(
        modifier_committed ? static_cast<uint32_t>(modifier_acks.size()) : 0u,
        std::memory_order_release);
    const char *reason = modifier_committed ? "" :
        (modifier_error.empty() ? "modifier_pod_plan_failed"
                                : modifier_error.c_str());
    publish_fallback(reason);
    if (ideology_bridge)
        settle_ideology_modifier_acks(ideology_batch_ok, modifier_committed);
    if (!modifier_committed) {
        error = reason;
        return false;
    }
    return true;
}


RuntimeCommandPacket make_effect_intent_events_packet(
        const RuntimeDomainIntent &intent, int64_t day) {
    RuntimeCommandPacket event_packet{};
    event_packet.envelope.request_id = intent.request_id != 0
        ? intent.request_id
        : (0xEFFE0000ull ^ static_cast<uint64_t>(intent.sequence));
    event_packet.envelope.producer_id = intent.producer_id != 0
        ? intent.producer_id : 77u;
    event_packet.envelope.sequence = intent.sequence != 0 ? intent.sequence : 1u;
    event_packet.envelope.requested_day = day;
    event_packet.envelope.effective_day =
        intent.effective_day >= 0 ? intent.effective_day : day;
    event_packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
    event_packet.envelope.opcode =
        static_cast<uint16_t>(RuntimeEventsCommand::APPEND_BATCH);
    std::vector<uint8_t> payload;
    payload.reserve(96u);
    const auto put_u32 = [&payload](uint32_t value) {
        for (int i = 0; i < 4; ++i)
            payload.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
    };
    const auto put_u64 = [&payload](uint64_t value) {
        for (int i = 0; i < 8; ++i)
            payload.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
    };
    const auto put_i32 = [&put_u32](int32_t value) {
        put_u32(static_cast<uint32_t>(value));
    };
    const auto put_i64 = [&put_u64](int64_t value) {
        put_u64(static_cast<uint64_t>(value));
    };
    const uint64_t idempotency =
        intent.idempotency_key != 0
            ? intent.idempotency_key
            : (intent.request_id != 0
                   ? intent.request_id
                   : (static_cast<uint64_t>(intent.producer_id) << 32) ^
                         static_cast<uint64_t>(intent.sequence) ^
                         static_cast<uint64_t>(intent.effective_day));
    put_u32(RUNTIME_EVENTS_ABI_VERSION);
    put_u32(1u);
    put_i64(event_packet.envelope.effective_day);
    put_i32(7); // effect transaction publication phase
    put_i32(900); // effect typed intent publication
    put_i32(4); // PK_EVENT_SOURCE_EFFECT
    put_i32(0);
    put_u64(intent.target_handle);
    put_i32(0);
    put_i32(0);
    put_i32(1);
    put_i64(static_cast<int64_t>(intent.request_id));
    put_i32(static_cast<int32_t>(intent.target_domain));
    put_i32(static_cast<int32_t>(intent.opcode));
    put_i32(0);
    put_i32(0);
    put_u64(idempotency);
    event_packet.envelope.payload_size = static_cast<uint32_t>(payload.size());
    if (payload.size() <= event_packet.payload.size())
        std::memcpy(event_packet.payload.data(), payload.data(), payload.size());
    return event_packet;
}

// Worker twin of the synchronous economy fact bridge. Construction facts need a
// Modifier building identity that only the main thread can mint, so they are
// not published from the worker.


} // namespace pk
