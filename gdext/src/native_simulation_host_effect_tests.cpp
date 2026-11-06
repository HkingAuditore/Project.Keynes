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

bool NativeSimulationHost::effect_pod_self_test(std::string *out_error) {
    std::string error;
    const bool ok = RuntimeEffectPodAuthority::self_test(error);
    if (!ok && out_error != nullptr) *out_error = error;
    return ok;
}

bool NativeSimulationHost::effect_pod_host_stage_self_test(std::string *out_error) {
    const auto fail = [out_error](const char *reason) {
        if (out_error != nullptr) *out_error = reason;
        return false;
    };
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        return fail("effect_host_stage_requires_stopped");
    }

    RuntimeEffectPodCatalog catalog;
    catalog.metric_key_hashes = {RuntimeEffectPodAuthority::hash_text("metric")};
    RuntimeEffectPodDefinition definition;
    definition.key_hash = RuntimeEffectPodAuthority::hash_text("f7.fixture");
    definition.cadence_days = 1;
    definition.max_work = 64;
    definition.instruction_begin = 0;
    definition.instruction_count = 2;
    definition.command_begin = 0;
    definition.command_count = 1;
    catalog.definitions.push_back(definition);
    RuntimeEffectPodCommandDefinition command_definition;
    command_definition.action = RuntimeEffectPodAction::MODIFIER_COMMAND;
    command_definition.domain = 0;
    command_definition.opcode = 1;
    command_definition.target_resolver =
        RuntimeEffectPodTargetResolver::INSTANCE;
    command_definition.value_mode = RuntimeEffectPodValueMode::STACK_TOP;
    command_definition.duration_days = -1;
    command_definition.stacks = 1;
    command_definition.command_key_hash =
        RuntimeEffectPodAuthority::hash_text("f7.modifier");
    command_definition.payload = {0, 0, 2, 0};
    catalog.commands.push_back(command_definition);
    RuntimeEffectPodInstruction constant;
    // Windows headers may define CONST as a macro; avoid the bare enumerator.
    constant.op = static_cast<RuntimeEffectPodInstructionOp>(1); // CONST
    constant.value = 65536;
    catalog.instructions.push_back(constant);
    RuntimeEffectPodInstruction emit;
    emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
    emit.arg0 = 0;
    catalog.instructions.push_back(emit);

    std::string error;
    if (!configure_effect_pod(catalog, error)) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "effect_host_stage_configure_failed" : error;
        return false;
    }

    RuntimeEffectPodInstanceInput input;
    input.instance_id = 42;
    input.generation = 1;
    input.program_id = 0;
    input.source_handle = 7;
    input.target_handle = 99;
    input.target_generation = 3;
    input.next_due_day = 0;
    input.active = true;
    if (!queue_effect_pod_instance(input, error)) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "effect_host_stage_queue_failed" : error;
        return false;
    }
    if (!queue_effect_pod_metric(42, 1, 0, 1, 7, error)) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "effect_host_stage_metric_failed" : error;
        return false;
    }

    RuntimeDayCommit commit;
    if (!execute_effect_worker_stage(0, 1, commit, error) || !_effect_day_stage_ok) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "effect_host_stage_plan_failed" : error;
        return false;
    }
    if (_effect_day_modifier_intents.empty())
        return fail("effect_host_stage_missing_modifier_intent");
    if (_effect_pod_intent_count.load(std::memory_order_acquire) == 0)
        return fail("effect_host_stage_intent_count_zero");
    if (_effect_pod_snapshot_generation.load(std::memory_order_acquire) == 0)
        return fail("effect_host_stage_generation_unchanged");

    const RuntimeDomainIntent &intent = _effect_day_modifier_intents.front();
    RuntimeDomainAck ack;
    ack.request_id = intent.request_id;
    ack.transaction_id = intent.request_id;
    ack.target_handle = intent.target_handle;
    ack.target_generation = intent.target_generation;
    ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
    ack.code = RuntimeDomainAckCode::OK;
    ack.effective_day = intent.effective_day;
    ack.producer_id = intent.producer_id;
    ack.sequence = intent.sequence;
    if (!_effect_pod_authority.apply_ack(ack, error)) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "effect_host_stage_ack_failed" : error;
        return false;
    }
    const auto &snapshot = _effect_pod_authority.snapshot();
    if (snapshot.transactions.empty() ||
        snapshot.transactions.front().status !=
        RuntimeEffectPodTransactionStatus::ACKED) {
        return fail("effect_host_stage_not_acked");
    }
    // M3 end-to-end pin: an ACKED Effect transaction must publish one typed
    // event through the same Events authority used by the worker stage. This
    // deliberately exercises the real APPEND_BATCH wire instead of merely
    // checking that the two POD self-tests pass independently.
    {
        RuntimeEventsRecord event;
        event.tick = 0;
        event.phase = 7;
        event.type = 900; // effect transaction publication fixture
        event.source = 1;
        event.entity_handle = static_cast<uint64_t>(
            snapshot.transactions.front().source_instance_id);
        event.payload_schema = 1;
        event.value_i64 = snapshot.transactions.front().transaction_id;
        std::vector<uint8_t> payload;
        const auto put_u32 = [&payload](uint32_t value) {
            for (int i = 0; i < 4; ++i)
                payload.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
        };
        const auto put_i32 = [&put_u32](int32_t value) {
            put_u32(static_cast<uint32_t>(value));
        };
        const auto put_u64 = [&payload](uint64_t value) {
            for (int i = 0; i < 8; ++i)
                payload.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
        };
        const auto put_i64 = [&put_u64](int64_t value) {
            put_u64(static_cast<uint64_t>(value));
        };
        put_u32(RUNTIME_EVENTS_ABI_VERSION);
        put_u32(1u);
        put_i64(event.tick);
        put_i32(event.phase);
        put_i32(event.type);
        put_i32(event.source);
        put_i32(event.flags);
        put_u64(event.entity_handle);
        put_i32(event.entity_id);
        put_i32(event.cell_idx);
        put_i32(event.payload_schema);
        put_i64(event.value_i64);
        put_i32(event.payload_i0);
        put_i32(event.payload_i1);
        put_i32(event.payload_i2);
        put_i32(event.payload_i3);
        put_u64(static_cast<uint64_t>(event.value_i64));
        RuntimeCommandPacket event_packet{};
        event_packet.envelope.request_id = 0xEFFE0001u;
        event_packet.envelope.producer_id = 77u;
        event_packet.envelope.sequence = 1u;
        event_packet.envelope.requested_day = 0;
        event_packet.envelope.effective_day = 0;
        event_packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
        event_packet.envelope.opcode = static_cast<uint16_t>(RuntimeEventsCommand::APPEND_BATCH);
        event_packet.envelope.payload_size = static_cast<uint32_t>(payload.size());
        std::memcpy(event_packet.payload.data(), payload.data(), payload.size());
        std::vector<RuntimeCommandPacket> event_commands{event_packet};
        RuntimeEventsSnapshot planned_events;
        std::vector<RuntimeCommandReceipt> event_receipts;
        RuntimeEventsReport event_report;
        if (!_events_authority.plan_day(0, event_commands, planned_events,
                                        event_receipts, event_report, error) ||
            !event_report.preflight_ok || event_report.appended_events != 1u ||
            !_events_authority.commit_day(planned_events, error) ||
            _events_authority.snapshot().events.empty() ||
            _events_authority.snapshot().events.back().type != event.type) {
            return fail("effect_host_stage_events_publication_failed");
        }
    }
    // M5 pin: every protocol stage is now represented by the implementation
    // capability mask, including input capture, gameplay effects and visual
    // intent publication.
    if (implemented_domain_mask() != RUNTIME_ALL_DOMAIN_MASK) {
        return fail("effect_host_stage_mask_changed");
    }
    return true;
}

bool NativeSimulationHost::effect_pod_transport_queue_self_test(
        std::string *out_error) {
    const auto fail = [out_error](const char *reason) {
        if (out_error != nullptr) *out_error = reason;
        return false;
    };
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        return fail("effect_transport_requires_stopped");
    }

    // Minimal fixture: identities and levels only, no commands emitted. The
    // contract under test lives in the transport queues, not in planning.
    RuntimeEffectPodCatalog catalog;
    catalog.metric_key_hashes = {RuntimeEffectPodAuthority::hash_text("metric")};
    RuntimeEffectPodDefinition definition;
    definition.key_hash = RuntimeEffectPodAuthority::hash_text("f7.transport");
    definition.cadence_days = 1;
    definition.max_work = 64;
    definition.instruction_begin = 0;
    definition.instruction_count = 0;
    definition.command_begin = 0;
    definition.command_count = 0;
    catalog.definitions.push_back(definition);

    std::string error;
    const auto reset = [&]() { return configure_effect_pod(catalog, error); };
    const auto make_input = [](int64_t instance_id, uint32_t generation,
                               int32_t level) {
        RuntimeEffectPodInstanceInput input;
        input.instance_id = instance_id;
        input.generation = generation;
        input.program_id = 0;
        input.source_handle = 7;
        input.target_handle = 99;
        input.target_generation = 3;
        input.next_due_day = 0;
        input.level = level;
        input.active = true;
        return input;
    };
    const auto find_instance = [this](int64_t instance_id, uint32_t generation) {
        const auto &known = _effect_pod_authority.snapshot().instances;
        for (const auto &instance : known) {
            if (instance.instance_id == instance_id &&
                instance.generation == generation) {
                return &instance;
            }
        }
        return static_cast<const RuntimeEffectPodInstance *>(nullptr);
    };
    const auto absent_count = [this]() {
        return _effect_retire_absent_count.load(std::memory_order_acquire);
    };
    const auto stale_count = [this]() {
        return _effect_retire_stale_count.load(std::memory_order_acquire);
    };

    // A. Re-ENSURE of the same (id, generation) carries the newest payload.
    // A stale level here is the "present=0, queued>0" class of bug: the Effect
    // stage keeps re-queueing the same identity and the old payload wins.
    if (!reset()) return fail("effect_transport_configure_failed");
    if (!queue_effect_pod_instance(make_input(11, 1, 1), error) ||
        !queue_effect_pod_instance(make_input(11, 1, 4), error)) {
        return fail("effect_transport_upsert_queue_failed");
    }
    if (!drain_effect_transport_queues(error))
        return fail("effect_transport_upsert_drain_failed");
    {
        const RuntimeEffectPodInstance *instance = find_instance(11, 1);
        if (instance == nullptr) return fail("effect_transport_upsert_missing");
        if (instance->level != 4) return fail("effect_transport_upsert_stale_level");
        if (instance->active == 0) return fail("effect_transport_upsert_not_active");
        if (_effect_pod_authority.snapshot().instances.size() != 1u)
            return fail("effect_transport_upsert_duplicated");
    }

    // B. Upsert followed by retire must net retired. Draining the retire queue
    // first would upsert again after the retire and resurrect the instance.
    if (!reset()) return fail("effect_transport_configure_failed");
    if (!queue_effect_pod_instance(make_input(21, 1, 2), error) ||
        !queue_effect_pod_remove(21, 1, error)) {
        return fail("effect_transport_retire_queue_failed");
    }
    if (!drain_effect_transport_queues(error))
        return fail("effect_transport_retire_drain_failed");
    {
        const RuntimeEffectPodInstance *instance = find_instance(21, 1);
        if (instance == nullptr) return fail("effect_transport_retire_missing");
        if (instance->active != 0) return fail("effect_transport_retire_resurrected");
        if (instance->retire_requested == 0)
            return fail("effect_transport_retire_not_requested");
    }

    // C. Retire/upsert/upsert ordering: the trailing upsert must not be folded
    // into the head entry, otherwise retire wins and the card never installs.
    if (!reset()) return fail("effect_transport_configure_failed");
    if (!queue_effect_pod_instance(make_input(31, 1, 1), error) ||
        !queue_effect_pod_remove(31, 1, error) ||
        !queue_effect_pod_instance(make_input(31, 1, 7), error)) {
        return fail("effect_transport_reinstall_queue_failed");
    }
    if (!drain_effect_transport_queues(error))
        return fail("effect_transport_reinstall_drain_failed");
    {
        const RuntimeEffectPodInstance *instance = find_instance(31, 1);
        if (instance == nullptr) return fail("effect_transport_reinstall_missing");
        if (instance->active == 0) return fail("effect_transport_reinstall_retired");
        if (instance->level != 7) return fail("effect_transport_reinstall_stale_level");
    }

    // D. Retiring an identity that was never installed is a benign no-op, the
    // same way EffectRuntime::retire_instance_pod returns true for it.
    if (!reset()) return fail("effect_transport_configure_failed");
    {
        const uint64_t absent_before = absent_count();
        const uint64_t stale_before = stale_count();
        if (!queue_effect_pod_remove(41, 1, error))
            return fail("effect_transport_absent_queue_failed");
        if (!drain_effect_transport_queues(error))
            return fail("effect_transport_absent_drain_failed");
        if (absent_count() != absent_before + 1u)
            return fail("effect_transport_absent_not_counted");
        if (stale_count() != stale_before)
            return fail("effect_transport_absent_counted_as_stale");
        if (!_effect_pod_authority.snapshot().instances.empty())
            return fail("effect_transport_absent_created_instance");
    }

    // E. Retiring a superseded generation must leave the live generation alone
    // and be reported separately, so a raced install stays visible.
    if (!reset()) return fail("effect_transport_configure_failed");
    {
        const uint64_t absent_before = absent_count();
        const uint64_t stale_before = stale_count();
        if (!queue_effect_pod_instance(make_input(51, 2, 3), error) ||
            !queue_effect_pod_remove(51, 1, error)) {
            return fail("effect_transport_stale_queue_failed");
        }
        if (!drain_effect_transport_queues(error))
            return fail("effect_transport_stale_drain_failed");
        if (stale_count() != stale_before + 1u)
            return fail("effect_transport_stale_not_counted");
        if (absent_count() != absent_before)
            return fail("effect_transport_stale_counted_as_absent");
        const RuntimeEffectPodInstance *instance = find_instance(51, 2);
        if (instance == nullptr) return fail("effect_transport_stale_lost_newer");
        if (instance->active == 0) return fail("effect_transport_stale_retired_newer");
    }

    return true;
}

bool NativeSimulationHost::modifier_effect_adapter_self_test(
        std::string *out_error) {
    const auto fail = [out_error](const char *reason) {
        if (out_error != nullptr) *out_error = reason;
        return false;
    };
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        return fail("modifier_adapter_requires_stopped");
    }

    // --- Modifier fixture -------------------------------------------------
    // Four domains, one APPLY definition each, POLICY_INDEPENDENT so every
    // command materialises its own entry and no case can be masked by a
    // stack refresh. Definitions are addressed through intent.payload[0], the
    // legacy dense-id lane, because that keeps this fixture free of Effect
    // transaction plumbing. payload[0] == 0 means "unset", so definition 0 is
    // unreachable and index i carries domain i-1.
    // 0 = POLICY_INDEPENDENT (runtime_modifier_pod.cpp:24); that constant is
    // file-local there, so the value is spelled out like the tag constants
    // below rather than widening the pod header's surface.
    constexpr int32_t kPolicyIndependent = 0;
    RuntimeModifierPodCatalog modifier_catalog;
    for (int32_t domain = 0; domain < 4; ++domain)
        modifier_catalog.stats.push_back(
            {domain, -100000.0, 100000.0, static_cast<uint8_t>(1)});
    for (int32_t domain = 0; domain < 4; ++domain)
        modifier_catalog.terms.push_back({domain, 1.0, 1.0});
    for (int32_t domain = -1; domain < 4; ++domain) {
        RuntimeModifierPodDefinition definition;
        definition.version = 1;
        // The spare at index 0 reuses domain 0; it is never referenced.
        definition.domain = domain < 0 ? 0 : domain;
        definition.policy = kPolicyIndependent;
        definition.max_stacks = 4;
        definition.default_duration = -1;
        definition.term_begin = static_cast<uint32_t>(
            definition.domain);
        definition.term_count = 1;
        modifier_catalog.definitions.push_back(definition);
    }

    std::string error;
    if (!configure_modifier_pod(modifier_catalog, error)) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "modifier_adapter_configure_failed" : error;
        return false;
    }

    // --- Effect instance for the GENERIC adapter ---------------------------
    // GENERIC is the only branch that reads the instance row instead of the
    // intent, so it needs one committed instance with a distinctive identity.
    constexpr int64_t kGenericInstanceId = 42;
    constexpr int64_t kGenericSourceType = 0x1234;
    constexpr int64_t kGenericSourceId = 0x5678;
    {
        RuntimeEffectPodCatalog effect_catalog;
        RuntimeEffectPodDefinition definition;
        definition.key_hash = RuntimeEffectPodAuthority::hash_text(
            "m2b.adapter.fixture");
        definition.cadence_days = 1;
        definition.max_work = 64;
        definition.instruction_begin = 0;
        definition.instruction_count = 0;
        definition.command_begin = 0;
        definition.command_count = 0;
        effect_catalog.definitions.push_back(definition);
        if (!configure_effect_pod(effect_catalog, error))
            return fail("modifier_adapter_effect_configure_failed");
        RuntimeEffectPodInstanceInput input;
        input.instance_id = kGenericInstanceId;
        input.generation = 1;
        input.program_id = 0;
        input.source_type = static_cast<int32_t>(kGenericSourceType);
        input.source_id = kGenericSourceId;
        input.source_handle = 7;
        input.target_handle = 9001;
        input.target_generation = 1;
        input.next_due_day = 0;
        input.active = true;
        if (!queue_effect_pod_instance(input, error))
            return fail("modifier_adapter_effect_queue_failed");
        if (!drain_effect_transport_queues(error))
            return fail("modifier_adapter_effect_drain_failed");
    }
    constexpr int32_t kAdapterGeneric = 0;
    constexpr int32_t kAdapterTechnology = 1;
    constexpr int32_t kAdapterFamily = 2;
    constexpr int32_t kAdapterPerson = 3;
    constexpr int32_t kAdapterTrigger = 4;
    constexpr int32_t kAdapterFamilyEffect = 5;
    constexpr int32_t kAdapterIdeology = 6;
    constexpr int32_t kMagnitude = 200000;  // < MAX_MAGNITUDE_Q16 (262144)
    constexpr uint64_t kTagTech = 0x54454348ULL;         // "TECH"
    constexpr uint64_t kTagFamily = 0x46414d494c59ULL;   // "FAMILY"
    constexpr uint64_t kTagPerson = 0x504552534f4eULL;   // "PERSON"
    constexpr uint64_t kTagTrigger = 0x54524947474552ULL;      // "TRIGGER"
    constexpr uint64_t kTagFamilyEffect = 0x46414d4546464543ULL; // "FAMEFFEC"
    constexpr uint64_t kTagIdeology = 0x4944454fULL;           // "IDEO"

    struct AdapterCase {
        int32_t adapter;
        int32_t program_target_domain;
        int32_t modifier_domain;
        int64_t payload2;
        uint64_t source_id;
        uint64_t target_handle;
        uint32_t target_generation;
        // Expected entry. scope == -1 means "the command must be dropped".
        int32_t scope;
        uint64_t entity_handle;
        uint64_t group_handle;
        uint64_t source_type;
        uint64_t expected_source_id;
        int32_t magnitude_q16;
        const char *failure;
    };
    const AdapterCase cases[] = {
        // effect_runtime.cpp GENERIC branch: ENTITY on the command target,
        // tagged with the INSTANCE's own source_type / source_id.
        {kAdapterGeneric, 0, 0, 0, kGenericInstanceId, 1001, 1,
         /*scope=*/2, /*entity=*/1001, /*group=*/0,
         static_cast<uint64_t>(kGenericSourceType),
         static_cast<uint64_t>(kGenericSourceId), kMagnitude,
         "modifier_adapter_generic"},
        // TECHNOLOGY: magnitude is pinned to Q16_ONE and source_id is the low
        // 16 bits of the instance id.
        {kAdapterTechnology, 0, 1, 0, 5001, 1002, 1,
         /*scope=*/2, /*entity=*/1002, /*group=*/0, kTagTech,
         /*source_id=*/5001, 65536, "modifier_adapter_technology"},
        // FAMILY: GROUP on target_generation, source_id is the target handle.
        {kAdapterFamily, 0, 2, 0, 1003, 1003, 77,
         /*scope=*/1, /*entity=*/1003, /*group=*/77, kTagFamily,
         /*source_id=*/1003, kMagnitude, "modifier_adapter_family"},
        // PERSON: ENTITY, magnitude has a floor of 1 (unreachable through this
        // path because the intent translation already substitutes 65536).
        {kAdapterPerson, 0, 3, 0, 5003, 1004, 1,
         /*scope=*/2, /*entity=*/1004, /*group=*/0, kTagPerson,
         /*source_id=*/5003, kMagnitude, "modifier_adapter_person"},
        // TRIGGER: always ENTITY, always tagged TRIGGER.
        {kAdapterTrigger, 0, 0, 0, 5004, 1005, 1,
         /*scope=*/2, /*entity=*/1005, /*group=*/0, kTagTrigger,
         /*source_id=*/5004, kMagnitude, "modifier_adapter_trigger"},
        // FAMILY_EFFECT with a cell target_domain binds GROUP.
        {kAdapterFamilyEffect, 2, 0, 0, 5005, 1006, 1,
         /*scope=*/1, /*entity=*/1006, /*group=*/1006, kTagFamilyEffect,
         /*source_id=*/5005, kMagnitude, "modifier_adapter_family_effect_group"},
        // FAMILY_EFFECT with an unknown target_domain must be dropped, not
        // defaulted to ENTITY like the ideology adapter does.
        {kAdapterFamilyEffect, 9, 0, 0, 5009, 1009, 1,
         /*scope=*/-1, 0, 0, 0, 0, 0,
         "modifier_adapter_family_effect_unknown"},
        // IDEOLOGY with a cell target_domain binds GROUP.
        {kAdapterIdeology, 2, 0, 0, 5006, 1007, 1,
         /*scope=*/1, /*entity=*/1007, /*group=*/1007, kTagIdeology,
         /*source_id=*/5006, kMagnitude, "modifier_adapter_ideology_group"},
        // IDEOLOGY defaults to ENTITY for a country target_domain...
        {kAdapterIdeology, 3, 0, 0, 5007, 1008, 1,
         /*scope=*/2, /*entity=*/1008, /*group=*/1008, kTagIdeology,
         /*source_id=*/5007, kMagnitude, "modifier_adapter_ideology_entity"},
        // payload[2] is Modifier command metadata. It must not override the
        // program's resolved target domain; doing so turned a cell row into an
        // ENTITY command and left the applied Modifier behind on unequip.
        {kAdapterIdeology, 3, 0, 1, 5008, 1010, 1,
         /*scope=*/2, /*entity=*/1010, /*group=*/1010, kTagIdeology,
         /*source_id=*/5008, kMagnitude,
         "modifier_adapter_ideology_payload_scope_ignored"},
    };

    std::vector<RuntimeDomainIntent> intents;
    intents.reserve(sizeof(cases) / sizeof(cases[0]));
    uint64_t sequence = 1;
    for (const AdapterCase &test : cases) {
        RuntimeDomainIntent intent;
        intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
        intent.target_domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        intent.opcode = 1;  // APPLY
        intent.effect_action = 2;  // MODIFIER_COMMAND
        // request_id stays 0 so the definition resolves through payload[0]
        // instead of a live Effect transaction this fixture does not have.
        intent.source_id = test.source_id;
        intent.target_handle = test.target_handle;
        intent.target_generation = test.target_generation;
        intent.effective_day = 3;
        intent.sequence = sequence++;
        intent.idempotency_key = sequence;
        intent.duration_days = -1;
        intent.stacks = 1;
        intent.magnitude_q16 = kMagnitude;
        intent.reserved_effect_flags |=
            RUNTIME_DOMAIN_INTENT_HAS_EFFECT_VALUE;
        intent.payload[0] = static_cast<int64_t>(test.modifier_domain) + 1;
        intent.payload[1] = test.modifier_domain;
        intent.payload[2] = test.payload2;
        intent.reserved = test.adapter | ((test.program_target_domain & 0xFF) << 8);
        intents.push_back(intent);
    }

    // --- Stage 1: adapter mapping, no POD involved -------------------------
    // "Adapter parity" means every field EffectRuntime's
    // dispatch_native_modifier would have written comes out identical. This is
    // executed without planning a day because planning one feeds Modifier ACKs
    // back into the Effect authority (the effect_upstream_ok branch below), and
    // a pure mapping fixture has no Effect transactions for those ACKs to
    // settle against — it used to fail with
    // effect_pod_ack_transaction_unknown before the assertions ran.
    std::vector<RuntimeModifierPodCommand> mapped;
    mapped.reserve(intents.size());
    for (size_t index = 0; index < intents.size(); ++index) {
        const AdapterCase &test = cases[index];
        RuntimeModifierPodCommand command;
        const bool applied =
            map_effect_intent_to_modifier_command(intents[index], 1, command);
        if (test.scope < 0) {
            if (applied) return fail(test.failure);
            continue;
        }
        if (!applied) return fail(test.failure);
        if (command.scope != test.scope) return fail(test.failure);
        if (command.entity_handle != test.entity_handle)
            return fail(test.failure);
        if (test.scope == 1 && command.group_handle != test.group_handle)
            return fail(test.failure);
        if (command.source_type != test.source_type) return fail(test.failure);
        if (command.source_id != test.expected_source_id)
            return fail(test.failure);
        if (command.magnitude_q16 != test.magnitude_q16)
            return fail(test.failure);
        mapped.push_back(command);
    }

    // --- Stage 2: the mapped commands must survive the POD -----------------
    // Stage 1 only proves the translation. This proves the translated command
    // is actually accepted and materialises the same scope / handle / weight,
    // so an adapter cannot "pass" by emitting something the POD discards.
    RuntimeModifierPodSnapshot planned_snapshot;
    RuntimeModifierPodReport plan_report;
    std::vector<RuntimeDomainAck> plan_acks;
    if (!_modifier_pod_authority.plan_day(
            3, 1, {}, mapped, planned_snapshot, plan_acks, plan_report, error)) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "modifier_adapter_plan_failed" : error;
        return false;
    }
    for (const AdapterCase &test : cases) {
        if (test.scope < 0) continue;
        const RuntimeModifierPodEntry *entry = nullptr;
        for (const RuntimeModifierPodEntry &candidate : planned_snapshot.entries) {
            if (candidate.source_id == test.expected_source_id) {
                entry = &candidate;
                break;
            }
        }
        if (entry == nullptr) return fail(test.failure);
        if (entry->scope != test.scope) return fail(test.failure);
        if (entry->entity_handle != test.entity_handle)
            return fail(test.failure);
        if (test.scope == 1 && entry->group_handle != test.group_handle)
            return fail(test.failure);
        if (entry->source_type != test.source_type) return fail(test.failure);
        if (entry->magnitude_q16 != test.magnitude_q16)
            return fail(test.failure);
    }
    if (!_modifier_pod_authority.commit_day(planned_snapshot, error)) {
        if (out_error != nullptr)
            *out_error = error.empty() ? "modifier_adapter_commit_failed" : error;
        return false;
    }
    return true;
}

} // namespace pk
