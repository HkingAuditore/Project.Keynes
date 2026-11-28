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
#include "effect_runtime.h"
#include "trigger_runtime.h"
#include "ideology_runtime.h"
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

void NativeSimulationHost::attach_effect_adapter(
        EffectRuntime *effect, NativeCountryRuntime *country, TriggerRuntime *trigger,
        NativeIdeologyRuntime *ideology) {
    _effect_adapter_runtime = effect;
    _effect_adapter_country = country;
    _trigger_delivery = {};
    _trigger_delivery.runtime = trigger;
    _trigger_delivery.ideology = ideology;
    if (trigger != nullptr) _trigger_delivery.initial_view = std::make_shared<TriggerRuntime>(*trigger);
    if (ideology != nullptr) {
        ideology->attach_modifier_runtime(_economy_modifier_view);
        _trigger_delivery.initial_ideology_view = capture_ideology_read_view();
    }
    if (effect != nullptr) {
        effect->begin_executor_transaction_namespace();
    }
    std::atomic_store(&_published_era_reward, capture_era_reward());
}

std::shared_ptr<const RuntimeEffectReadView>
NativeSimulationHost::latest_effect_read_view() const {
    const auto commit = std::atomic_load(&_latest_commit);
    return commit && commit->day_tail ? commit->day_tail->effect : nullptr;
}

const char *NativeSimulationHost::stage_effect_adapter(DayExecution &day) {
    if (_effect_adapter_runtime == nullptr) return nullptr;
    auto &effect = *_effect_adapter_runtime;
    const auto &snapshot = _effect_pod_authority.snapshot();
    std::string error;
    if (snapshot.generation > effect.pod_snapshot_generation() &&
        !effect.apply_pod_snapshot(snapshot, error)) {
        pk::log_error("[effect] executor adapter snapshot: %s", error.c_str());
        return "effect_executor_adapter_snapshot_failed";
    }
    RuntimeDomainIntent intent;
    while (poll_effect_pod_intent(intent)) {
        if (intent.target_domain == static_cast<uint16_t>(RuntimeDomainId::MODIFIER))
            continue;
        RuntimeDomainAck ack;
        ack.request_id = intent.request_id;
        ack.transaction_id = intent.request_id;
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.domain = intent.target_domain;
        ack.code = RuntimeDomainAckCode::OK;
        ack.effective_day = intent.effective_day;
        ack.producer_id = intent.producer_id;
        ack.sequence = intent.sequence;
        if (!submit_effect_pod_ack(ack, error)) return "effect_executor_adapter_ack_failed";
    }
    if (_effect_adapter_country != nullptr) {
        effect.dispatch_native_country(_effect_adapter_country);
        effect.ack_native_country(_effect_adapter_country);
        effect.settle_orphaned_native_country_acks();
    }
    if (_economy_production_runtime != nullptr) {
        effect.dispatch_native_economy(_economy_production_runtime);
        effect.ack_native_economy(_economy_production_runtime);
    }
    if (const char *error = settle_era_rewards(day)) return error;
    auto view = std::make_shared<RuntimeEffectReadView>();
    view->report = effect.report();
    const bool country_pending = _effect_adapter_country != nullptr &&
        _effect_adapter_country->has_pending_effect_commands();
    const bool economy_pending = _economy_production_runtime != nullptr &&
        _economy_production_runtime->has_pending_effect_commands();
    const bool colonization_pending = effect.has_pending_family_colonization_transactions();
    view->adapters["country_pending"] = country_pending;
    view->adapters["economy_pending"] = economy_pending;
    view->adapters["colonization_pending"] = colonization_pending;
    view->adapters["idle"] = !country_pending && !economy_pending && !colonization_pending;
    if (!_executor_day_tail) _executor_day_tail = std::make_shared<RuntimeDayTail>();
    _executor_day_tail->effect = std::move(view);
    _executor_day_tail->era_reward = capture_era_reward();
    return nullptr;
}

bool NativeSimulationHost::configure_modifier_pod(
        const RuntimeModifierPodCatalog &catalog, std::string &error) {
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        error = "modifier_pod_configure_while_running";
        return false;
    }
    if (!_modifier_pod_authority.configure(catalog, error)) {
        _modifier_pod_configured = false;
        return false;
    }
    _modifier_pod_catalog = catalog;
    _modifier_pod_catalog.catalog_hash = _modifier_pod_authority.catalog_hash();
    _modifier_pod_configured = true;
    // Key→id binding is installed by the caller after configure; drop any
    // previous catalog's hashes so a half-init cannot resolve to stale ids.
    _modifier_definition_id_by_key_hash.clear();
    return true;
}

void NativeSimulationHost::set_modifier_definition_key_hashes(
        const std::vector<std::pair<uint64_t, int32_t>> &entries) {
    _modifier_definition_id_by_key_hash.clear();
    _modifier_definition_id_by_key_hash.reserve(entries.size());
    for (const auto &entry : entries) {
        if (entry.first == 0 || entry.second < 0) continue;
        _modifier_definition_id_by_key_hash.emplace(entry.first, entry.second);
    }
}

int32_t NativeSimulationHost::resolve_modifier_definition_id_for_effect_intent(
        const RuntimeDomainIntent &intent) const {
    // Preferred: Effect command definition_key_hash → Modifier catalog id.
    if (_effect_pod_configured && intent.request_id != 0) {
        const auto &snapshot = _effect_pod_authority.snapshot();
        for (const auto &transaction : snapshot.transactions) {
            if (static_cast<uint64_t>(transaction.transaction_id) !=
                intent.request_id) {
                continue;
            }
            const uint32_t ordinal =
                static_cast<uint32_t>(intent.sequence & 15u);
            if (ordinal >= transaction.command_count) break;
            const size_t command_index =
                static_cast<size_t>(transaction.command_begin) + ordinal;
            if (command_index >= snapshot.command_arena.size()) break;
            const auto &command = snapshot.command_arena[command_index];
            if (command.action != RuntimeEffectPodAction::MODIFIER_COMMAND)
                break;
            if (command.definition_key_hash != 0) {
                const auto found = _modifier_definition_id_by_key_hash.find(
                    command.definition_key_hash);
                if (found != _modifier_definition_id_by_key_hash.end())
                    return found->second;
            }
            break;
        }
    }
    // Legacy: payload[0] already carries a dense Modifier definition_id.
    if (intent.payload[0] > 0 &&
        intent.payload[0] <= static_cast<int64_t>(
            std::numeric_limits<int32_t>::max())) {
        return static_cast<int32_t>(intent.payload[0]);
    }
    return -1;
}

void NativeSimulationHost::reemit_effect_committed_pending_intents(int64_t day) {
    if (!_effect_pod_configured) return;
    const auto &snapshot = _effect_pod_authority.snapshot();
    for (const auto &transaction : snapshot.transactions) {
        if (transaction.status !=
            RuntimeEffectPodTransactionStatus::COMMITTED) {
            continue;
        }
        for (uint32_t ordinal = 0; ordinal < transaction.command_count;
             ++ordinal) {
            const size_t command_index =
                static_cast<size_t>(transaction.command_begin) + ordinal;
            if (command_index >= snapshot.command_arena.size()) break;
            const auto &command = snapshot.command_arena[command_index];
            const uint32_t bit =
                RuntimeEffectPodAuthority::adapter_ack_bit(command.action);
            if (bit != 0u &&
                (transaction.received_ack_mask & bit) == bit) {
                continue;
            }
            RuntimeDomainIntent intent;
            intent.source_domain =
                static_cast<uint16_t>(RuntimeDomainId::EFFECT);
            intent.target_domain =
                RuntimeEffectPodAuthority::adapter_domain(command.action);
            intent.opcode = static_cast<uint16_t>(command.opcode);
            intent.effect_action = static_cast<uint16_t>(command.action);
            intent.source_id =
                static_cast<uint64_t>(command.source_instance_id);
            intent.target_handle = command.target_handle;
            intent.target_generation = command.target_generation;
            intent.value = command.value;
            intent.reserved_effect_flags |=
                RUNTIME_DOMAIN_INTENT_HAS_EFFECT_VALUE;
            intent.effective_day = command.effective_day >= 0
                ? command.effective_day : day;
            intent.payload = command.payload;
            intent.request_id =
                static_cast<uint64_t>(transaction.transaction_id);
            intent.producer_id =
                static_cast<uint32_t>(RuntimeDomainId::EFFECT);
            intent.sequence =
                transaction.fire_sequence * 16u + ordinal;
            intent.idempotency_key = command.idempotency_key;
            intent.duration_days = command.duration_days;
            intent.stacks = command.stacks;
            const int32_t instance_index =
                _effect_pod_authority.instance_index_for_id(
                    command.source_instance_id);
            const int32_t magnitude_scale_q16 = instance_index >= 0
                ? _effect_pod_authority.snapshot().instances[
                    static_cast<size_t>(instance_index)].magnitude_scale_q16
                : EFFECT_MAGNITUDE_Q16_ONE;
            intent.magnitude_q16 = effect_scaled_magnitude_q16(
                command.value, magnitude_scale_q16);
            if (command.action == RuntimeEffectPodAction::MODIFIER_COMMAND &&
                intent.payload[1] == 0 && command.domain >= 0 &&
                command.domain < 4) {
                intent.payload[1] = command.domain;
            }
            if (command.action == RuntimeEffectPodAction::MODIFIER_COMMAND &&
                intent.payload[0] <= 0 &&
                command.definition_key_hash != 0) {
                const auto found = _modifier_definition_id_by_key_hash.find(
                    command.definition_key_hash);
                if (found != _modifier_definition_id_by_key_hash.end())
                    intent.payload[0] = found->second;
            }
            _effect_day_intents.push_back(intent);
            if (intent.target_domain ==
                static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
                _effect_day_modifier_intents.push_back(intent);
            }
        }
    }
}

uint32_t NativeSimulationHost::ack_effect_events_intents_in_worker(
        const std::vector<RuntimeDomainIntent> &intents) {
    if (!_effect_pod_configured || intents.empty()) return 0;
    std::vector<RuntimeDomainAck> acks;
    acks.reserve(intents.size());
    for (const RuntimeDomainIntent &intent : intents) {
        if (intent.target_domain !=
            static_cast<uint16_t>(RuntimeDomainId::EVENTS)) {
            continue;
        }
        RuntimeDomainAck ack;
        ack.request_id =
            intent.request_id != 0 ? intent.request_id : intent.source_id;
        ack.transaction_id = ack.request_id;
        ack.target_handle = intent.target_handle;
        ack.target_generation = intent.target_generation;
        ack.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
        ack.code = RuntimeDomainAckCode::OK;
        ack.effective_day = intent.effective_day;
        ack.producer_id = intent.producer_id;
        ack.sequence = intent.sequence;
        acks.push_back(ack);
    }
    if (acks.empty()) return 0;
    std::string error;
    if (!_effect_pod_authority.apply_acks(acks, error)) {
        // Soft: leave Events bit for the main-thread pump / next retry.
        return 0;
    }
    _effect_pod_ack_count.store(
        _effect_pod_ack_count.load(std::memory_order_relaxed) +
            static_cast<uint32_t>(acks.size()),
        std::memory_order_release);
    _effect_pod_state_hash.store(
        _effect_pod_authority.snapshot().deterministic_state_hash,
        std::memory_order_release);
    return static_cast<uint32_t>(acks.size());
}

bool NativeSimulationHost::configure_effect_pod(
        const RuntimeEffectPodCatalog &catalog, std::string &error) {
    const RuntimeWorkerState worker_state = state();
    if (worker_state != RuntimeWorkerState::STOPPED &&
        worker_state != RuntimeWorkerState::FAULTED) {
        error = "effect_pod_configure_while_running";
        return false;
    }
    RuntimeEffectPodAuthority candidate;
    if (!candidate.configure(catalog, error)) {
        return false;
    }
    _effect_pod_authority = std::move(candidate);
    _effect_pod_catalog = catalog;
    _effect_pod_catalog.catalog_hash = _effect_pod_authority.catalog_hash();
    _effect_pod_configured = true;
    {
        std::lock_guard<std::mutex> lock(_effect_transport_mutex);
        _effect_instance_queue.clear();
        _effect_metric_queue.clear();
        _effect_remove_queue.clear();
        _effect_intents.clear();
        _effect_acks.clear();
    }
    _effect_day_modifier_intents.clear();
    _effect_day_stage_ok = false;
    return true;
}

bool NativeSimulationHost::encode_effect_pod_save(
        std::vector<uint8_t> &bytes, std::string &error) const {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    _effect_pod_authority.serialize(bytes);
    if (bytes.empty()) {
        error = "effect_pod_save_encode_failed";
        return false;
    }
    return true;
}

bool NativeSimulationHost::restore_effect_pod_save(
        const uint8_t *bytes, size_t size, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    RuntimeEffectPodAuthority candidate;
    if (!candidate.configure(_effect_pod_catalog, error)) return false;
    if (!candidate.restore(bytes, size, error)) return false;
    _effect_pod_authority = std::move(candidate);
    return true;
}

bool NativeSimulationHost::queue_effect_pod_instance(
        const RuntimeEffectPodInstanceInput &input, std::string &error,
        int64_t worker_effective_day) {
    return queue_effect_pod_instance_batch({input}, error, worker_effective_day);
}

bool NativeSimulationHost::queue_effect_pod_instance_batch(
        const std::vector<RuntimeEffectPodInstanceInput> &inputs,
        std::string &error,
        int64_t worker_effective_day) {
    error.clear();
    if (!_effect_pod_configured) { error = "effect_pod_not_configured"; return false; }
    if (inputs.empty()) return true;
    const bool from_worker = on_worker_thread();
    const bool seal_active =
        _world_environment != nullptr ||
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE;
    int64_t admitted_day =
        (from_worker || !seal_active) ? 0 : std::max<int64_t>(0, command_seal_day());
    const RuntimeCommandAdmission admission =
        from_worker ? RuntimeCommandAdmission(true) : admit_command(admitted_day);
    if (!admission.accepted()) { error = "effect_transport_not_admitted"; return false; }
    if (!from_worker && seal_active)
        admitted_day = std::max<int64_t>(admitted_day, command_seal_day());
    const auto resolve_day = [&](const RuntimeEffectPodInstanceInput &in) -> int64_t {
        if (!from_worker) return admitted_day;
        return worker_effective_day >= 0 ? worker_effective_day
                                         : std::max<int64_t>(0, in.next_due_day);
    };
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    bool first_coalesces = false;
    if (!_effect_instance_queue.empty()) {
        const auto &tail = _effect_instance_queue.back();
        const int64_t first_day = resolve_day(inputs.front());
        first_coalesces = tail.sequence == _effect_transport_sequence && tail.effective_day == first_day &&
            tail.input.instance_id == inputs.front().instance_id && tail.input.generation == inputs.front().generation;
    }
    const size_t additions = inputs.size() - (first_coalesces ? 1u : 0u);
    if (additions > RUNTIME_COMMAND_QUEUE_CAPACITY ||
        _effect_instance_queue.size() > RUNTIME_COMMAND_QUEUE_CAPACITY - additions) {
        error = "effect_instance_capacity_exceeded";
        return false;
    }
    for (RuntimeEffectPodInstanceInput input : inputs) {
        const int64_t effective_day = resolve_day(input);
        if (!from_worker) input.next_due_day = std::max(input.next_due_day, admitted_day);
        // Coalesce only with the queue tail when it is the newest arrival and shares effective_day.
        if (!_effect_instance_queue.empty()) {
            auto &tail = _effect_instance_queue.back();
            if (tail.sequence == _effect_transport_sequence && tail.effective_day == effective_day &&
                tail.input.instance_id == input.instance_id && tail.input.generation == input.generation) {
                tail.input = input;
                continue;
            }
        }
        _effect_instance_queue.push_back({++_effect_transport_sequence, effective_day, input});
    }
    return true;
}

bool NativeSimulationHost::queue_effect_pod_metric(
        int64_t instance_id, uint32_t generation, int32_t metric_id,
        int64_t revision, int64_t value, std::string &error) {
    error.clear();
    if (!_effect_pod_configured) { error = "effect_pod_not_configured"; return false; }
    const bool from_worker = on_worker_thread();
    const bool seal_active =
        _world_environment != nullptr ||
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE;
    int64_t effective_day =
        (from_worker || !seal_active) ? 0 : std::max<int64_t>(0, command_seal_day());
    const RuntimeCommandAdmission admission =
        from_worker ? RuntimeCommandAdmission(true) : admit_command(effective_day);
    if (!admission.accepted()) { error = "effect_transport_not_admitted"; return false; }
    if (!from_worker && seal_active)
        effective_day = std::max<int64_t>(effective_day, command_seal_day());
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_metric_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_metric_capacity_exceeded";
        return false;
    }
    _effect_metric_queue.push_back(
        {++_effect_transport_sequence, effective_day, instance_id, generation, metric_id, revision, value});
    return true;
}

bool NativeSimulationHost::queue_effect_pod_remove(
        int64_t instance_id, uint32_t generation, std::string &error) {
    error.clear();
    if (!_effect_pod_configured) { error = "effect_pod_not_configured"; return false; }
    const bool from_worker = on_worker_thread();
    const bool seal_active =
        _world_environment != nullptr ||
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE;
    int64_t effective_day =
        (from_worker || !seal_active) ? 0 : std::max<int64_t>(0, command_seal_day());
    const RuntimeCommandAdmission admission =
        from_worker ? RuntimeCommandAdmission(true) : admit_command(effective_day);
    if (!admission.accepted()) { error = "effect_transport_not_admitted"; return false; }
    if (!from_worker && seal_active)
        effective_day = std::max<int64_t>(effective_day, command_seal_day());
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_remove_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_remove_capacity_exceeded";
        return false;
    }
    _effect_remove_queue.push_back({++_effect_transport_sequence, effective_day, instance_id, generation});
    return true;
}

bool NativeSimulationHost::poll_effect_pod_intent(RuntimeDomainIntent &intent) {
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_intents.empty()) return false;
    intent = _effect_intents.front();
    _effect_intents.pop_front();
    return true;
}

bool NativeSimulationHost::submit_effect_pod_ack(
        const RuntimeDomainAck &ack, std::string &error) {
    if (ack.transaction_id == 0 && ack.request_id == 0) {
        error = "effect_ack_invalid";
        return false;
    }
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
        error = "effect_ack_capacity_exceeded";
        return false;
    }
    _effect_acks.push_back(ack);
    {
        std::lock_guard<std::mutex> control_lock(_control_mutex);
        _country_peer_signal.fetch_add(1, std::memory_order_release);
    }
    _control_cv.notify_all();
    return true;
}

#include "native_simulation_host_effect_section_country_peers.inc"

bool NativeSimulationHost::drain_effect_transport_queues(int64_t day,
                                                         std::string &error) {
    error.clear();
    if (!_effect_pod_configured) { error = "effect_pod_not_configured"; return false; }
    std::vector<EffectPodInstanceQueueItem> instances;
    std::vector<EffectPodMetricQueueItem> metrics;
    std::vector<EffectPodRemoveQueueItem> removes;
    std::vector<RuntimeDomainAck> acks;
    const auto split_due = [day](auto &queue, auto &due) {
        std::remove_reference_t<decltype(queue)> deferred;
        while (!queue.empty()) {
            auto item = queue.front();
            queue.pop_front();
            if (item.effective_day <= day) due.push_back(item);
            else deferred.push_back(item);
        }
        queue.swap(deferred);
    };
    {
        std::lock_guard<std::mutex> lock(_effect_transport_mutex);
        split_due(_effect_instance_queue, instances);
        split_due(_effect_metric_queue, metrics);
        split_due(_effect_remove_queue, removes);
        acks.assign(_effect_acks.begin(), _effect_acks.end());
        _effect_acks.clear();
    }

    struct LifecycleOp {
        bool is_remove = false;
        int64_t effective_day = 0;
        int64_t instance_id = 0;
        uint64_t sequence = 0;
        size_t index = 0;
    };
    std::vector<LifecycleOp> ops;
    ops.reserve(instances.size() + removes.size());
    for (size_t i = 0; i < instances.size(); ++i)
        ops.push_back({false, instances[i].effective_day, instances[i].input.instance_id, instances[i].sequence, i});
    for (size_t i = 0; i < removes.size(); ++i)
        ops.push_back({true, removes[i].effective_day, removes[i].instance_id, removes[i].sequence, i});
    // K3/K4 canonical replay order: (effective_day, instance_id, sequence).
    const auto by_canonical = [](const auto &a, const auto &b) {
        if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
        if (a.instance_id != b.instance_id) return a.instance_id < b.instance_id;
        return a.sequence < b.sequence;
    };
    std::stable_sort(ops.begin(), ops.end(), by_canonical);
    std::stable_sort(metrics.begin(), metrics.end(), by_canonical);

    auto restore_remaining = [&](size_t op_pos, size_t metric_pos) {
        std::lock_guard<std::mutex> lock(_effect_transport_mutex);
        for (size_t i = ops.size(); i > op_pos; --i) {
            const LifecycleOp &op = ops[i - 1];
            if (op.is_remove) _effect_remove_queue.push_front(removes[op.index]);
            else _effect_instance_queue.push_front(instances[op.index]);
        }
        for (size_t i = metrics.size(); i > metric_pos; --i)
            _effect_metric_queue.push_front(metrics[i - 1]);
    };

    for (size_t op_pos = 0; op_pos < ops.size(); ++op_pos) {
        const LifecycleOp &op = ops[op_pos];
        if (op.is_remove) {
            const auto &item = removes[op.index];
            if (_effect_pod_authority.remove_instance(item.instance_id, item.generation, error))
                continue;
            if (error == "effect_pod_instance_stale_generation") {
                const auto &known = _effect_pod_authority.snapshot().instances;
                const bool id_present = std::any_of(known.begin(), known.end(),
                    [&item](const RuntimeEffectPodInstance &inst) { return inst.instance_id == item.instance_id; });
                (id_present ? _effect_retire_stale_count : _effect_retire_absent_count)
                    .fetch_add(1, std::memory_order_release);
                error.clear();
                continue;
            }
            restore_remaining(op_pos, 0);
            return false;
        }
        auto &queued = instances[op.index];
        RuntimeEffectPodInstanceInput input = queued.input;
        const int64_t committed = _effect_pod_authority.snapshot().committed_day;
        if (input.next_due_day < 0) input.next_due_day = std::max<int64_t>(0, committed + 1);
        else if (committed >= 0 && input.next_due_day <= committed) input.next_due_day = committed + 1;
        if (!_effect_pod_authority.upsert_instance(input, error)) {
            if (error == "effect_pod_instance_invalid") {
                _effect_instance_rejected_count.fetch_add(1, std::memory_order_release);
                char detail[96];
                std::snprintf(detail, sizeof(detail), "id=%lld gen=%u prog=%d th=%llu tg=%u due=%lld",
                    static_cast<long long>(input.instance_id), static_cast<unsigned>(input.generation),
                    static_cast<int>(input.program_id), static_cast<unsigned long long>(input.target_handle),
                    static_cast<unsigned>(input.target_generation), static_cast<long long>(input.next_due_day));
                for (size_t i = 0; i + 1 < _effect_instance_reject_detail.size(); ++i) {
                    _effect_instance_reject_detail[i].store(detail[i], std::memory_order_release);
                    if (detail[i] == '\0') break;
                }
                _effect_instance_reject_detail.back().store('\0', std::memory_order_release);
                error.clear();
                continue;
            }
            queued.input = input;
            restore_remaining(op_pos, 0);
            return false;
        }
    }
    for (size_t metric_pos = 0; metric_pos < metrics.size(); ++metric_pos) {
        const auto &item = metrics[metric_pos];
        if (!_effect_pod_authority.set_metric(
                item.instance_id, item.generation, item.metric_id, item.revision, item.value, error)) {
            if (error == "effect_pod_metric_stale_generation") {
                _effect_instance_rejected_count.fetch_add(1, std::memory_order_release);
                error.clear();
                continue;
            }
            restore_remaining(ops.size(), metric_pos);
            return false;
        }
    }
    if (!acks.empty() && !_effect_pod_authority.apply_acks(acks, error)) return false;
    return true;
}

bool NativeSimulationHost::execute_effect_worker_stage(
        int64_t day, uint64_t input_generation, RuntimeDayCommit &commit,
        std::string &error) {
    (void)commit;
    error.clear();
    _effect_day_modifier_intents.clear();
    _effect_day_intents.clear();
    _effect_day_stage_ok = false;
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }

    if (!drain_effect_transport_queues(day, error)) return false;

    const auto plan_started = std::chrono::steady_clock::now();
    RuntimeEffectPodPlan plan;
    if (!_effect_pod_authority.plan_day(day, input_generation, plan, error)) {
        _effect_pod_authority.discard_plan();
        return false;
    }

    uint32_t emitted = 0;
    uint32_t managed_emitted = 0;
    uint32_t unmanaged_emitted = 0;
    std::array<int32_t, RUNTIME_EFFECT_INTENT_PROGRAM_REPORT_CAPACITY>
        emitted_program_ids{};
    emitted_program_ids.fill(-1);
    uint32_t emitted_program_count = 0;
    uint32_t modifier_targeted = 0;
    {
        std::lock_guard<std::mutex> lock(_effect_transport_mutex);
        for (const RuntimeDomainIntent &intent : plan.intents) {
            if (_effect_intents.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
                _effect_pod_authority.discard_plan();
                error = "effect_intent_capacity_exceeded";
                return false;
            }
            _effect_intents.push_back(intent);
            _effect_day_intents.push_back(intent);
            const int32_t source_instance_index =
                _effect_pod_authority.instance_index_for_id(
                    static_cast<int64_t>(intent.source_id));
            const auto &source_instances =
                _effect_pod_authority.snapshot().instances;
            const int32_t source_program_id =
                source_instance_index >= 0 &&
                    static_cast<size_t>(source_instance_index) <
                        source_instances.size()
                ? source_instances[static_cast<size_t>(source_instance_index)]
                    .program_id
                : -1;
            if (_effect_pod_authority.definition_is_managed(
                    source_program_id)) {
                ++managed_emitted;
            } else {
                ++unmanaged_emitted;
            }
            if (emitted_program_count < emitted_program_ids.size()) {
                emitted_program_ids[emitted_program_count++] =
                    source_program_id;
            }
            ++emitted;
            if (intent.target_domain ==
                static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
                _effect_day_modifier_intents.push_back(intent);
                ++modifier_targeted;
            }
        }
    }
    (void)modifier_targeted;

    const auto replay_started = std::chrono::steady_clock::now();
    if (!_effect_pod_authority.commit_day(plan, error)) {
        _effect_pod_authority.discard_plan();
        return false;
    }
    // After commit the transaction arena is published; resolve Modifier
    // definition ids so the same-day Modifier stage (and soft-skip reemit)
    // see a dense payload[0] even when the Effect catalog left it unset.
    for (RuntimeDomainIntent &intent : _effect_day_modifier_intents) {
        if (intent.payload[0] > 0) continue;
        const int32_t definition_id =
            resolve_modifier_definition_id_for_effect_intent(intent);
        if (definition_id >= 0) intent.payload[0] = definition_id;
    }
    for (RuntimeDomainIntent &intent : _effect_day_intents) {
        if (intent.target_domain !=
                static_cast<uint16_t>(RuntimeDomainId::MODIFIER) ||
            intent.payload[0] > 0) {
            continue;
        }
        const int32_t definition_id =
            resolve_modifier_definition_id_for_effect_intent(intent);
        if (definition_id >= 0) intent.payload[0] = definition_id;
    }
    // PUBLISH_EVENT (technology.adopted) is published by the Events stage but
    // never ACKed there. Settle the Events bit in-worker so technology fire
    // does not wait on the main-thread Effect pump.
    ack_effect_events_intents_in_worker(_effect_day_intents);
    const double replay_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - replay_started).count();
    const RuntimeEffectPodSnapshot &snapshot = _effect_pod_authority.snapshot();
    _effect_pod_plan_ms.store(
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - plan_started).count(),
        std::memory_order_release);
    _effect_pod_replay_ms.store(replay_ms, std::memory_order_release);
    _effect_pod_state_hash.store(snapshot.deterministic_state_hash,
                                 std::memory_order_release);
    _effect_pod_snapshot_generation.store(snapshot.generation,
                                          std::memory_order_release);
    _effect_pod_intent_count.store(emitted, std::memory_order_release);
    _effect_pod_managed_intent_count.store(
        managed_emitted, std::memory_order_release);
    _effect_pod_unmanaged_intent_count.store(
        unmanaged_emitted, std::memory_order_release);
    _effect_pod_program_intent_count.store(
        emitted_program_count, std::memory_order_release);
    for (uint32_t index = 0; index < emitted_program_ids.size(); ++index) {
        _effect_pod_intent_program_ids[index].store(
            index < emitted_program_count ? emitted_program_ids[index] : -1,
            std::memory_order_relaxed);
    }
    _effect_pod_transaction_count.store(
        static_cast<uint32_t>(snapshot.transactions.size()),
        std::memory_order_release);
    // ACKs are applied at the top of this stage via drain_effect_transport_queues.
    _effect_pod_ack_count.store(0u, std::memory_order_release);
    // F8: publish immutable snapshot for main-thread EffectRuntime write-back.
    uint32_t effect_slot = 0;
    if (_effect_snapshots.try_begin_write(effect_slot)) {
        _effect_snapshots.write_buffer(effect_slot) = snapshot;
        _effect_snapshots.publish(effect_slot);
    }
    _effect_day_stage_ok = true;
    return true;
}

} // namespace pk
