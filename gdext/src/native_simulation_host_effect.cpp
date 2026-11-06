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
        const RuntimeEffectPodInstanceInput &input, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    // Coalesce only with the queue tail, and only when that tail is still the
    // newest arrival. Re-ENSUREing the same identity several times per frame
    // must keep the newest payload (a stale level / next_due_day here is exactly
    // the "present=0, queued>0" class of bug). But if a retire landed after the
    // tail -- it lives in the *other* deque, so the tail alone cannot tell --
    // folding this upsert into the tail would replay it before the retire and
    // the instance would never come back.
    if (!_effect_instance_queue.empty()) {
        EffectPodInstanceQueueItem &tail = _effect_instance_queue.back();
        if (tail.sequence == _effect_transport_sequence &&
            tail.input.instance_id == input.instance_id &&
            tail.input.generation == input.generation) {
            tail.input = input;
            return true;
        }
    }
    if (_effect_instance_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_instance_capacity_exceeded";
        return false;
    }
    EffectPodInstanceQueueItem item;
    item.sequence = ++_effect_transport_sequence;
    item.input = input;
    _effect_instance_queue.push_back(item);
    return true;
}

bool NativeSimulationHost::queue_effect_pod_metric(
        int64_t instance_id, uint32_t generation, int32_t metric_id,
        int64_t revision, int64_t value, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_metric_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_metric_capacity_exceeded";
        return false;
    }
    EffectPodMetricQueueItem item;
    item.instance_id = instance_id;
    item.generation = generation;
    item.metric_id = metric_id;
    item.revision = revision;
    item.value = value;
    _effect_metric_queue.push_back(item);
    return true;
}

bool NativeSimulationHost::queue_effect_pod_remove(
        int64_t instance_id, uint32_t generation, std::string &error) {
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    if (_effect_remove_queue.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "effect_remove_capacity_exceeded";
        return false;
    }
    EffectPodRemoveQueueItem item;
    item.sequence = ++_effect_transport_sequence;
    item.instance_id = instance_id;
    item.generation = generation;
    _effect_remove_queue.push_back(item);
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

int32_t NativeSimulationHost::effect_pod_program_id_for_key(
        const char *key) const {
    if (!_effect_pod_configured || key == nullptr || key[0] == '\0') return -1;
    const uint64_t hash = RuntimeEffectPodAuthority::hash_text(key);
    for (size_t i = 0; i < _effect_pod_catalog.definitions.size(); ++i) {
        if (_effect_pod_catalog.definitions[i].key_hash == hash)
            return static_cast<int32_t>(i);
    }
    return -1;
}

bool NativeSimulationHost::ensure_effect_pod_technology_instance(
        int64_t instance_id, uint32_t generation, int32_t program_id,
        uint64_t target_handle, uint32_t target_generation, int64_t day,
        std::string &error) {
    error.clear();
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    if (instance_id == 0 || generation == 0 || program_id < 0) {
        error = "effect_pod_technology_instance_invalid";
        return false;
    }
    // Already present in the committed POD snapshot — do not re-queue.
    {
        const auto &snapshot = _effect_pod_authority.snapshot();
        for (const auto &instance : snapshot.instances) {
            if (instance.instance_id == instance_id &&
                instance.generation == generation &&
                instance.active != 0) {
                return true;
            }
        }
    }
    RuntimeEffectPodInstanceInput input;
    input.instance_id = instance_id;
    input.generation = generation;
    input.program_id = program_id;
    input.source_type = 0x54454348; // 'TECH'
    input.source_id = instance_id;
    input.source_handle = target_handle;
    input.target_handle = target_handle;
    input.target_generation = target_generation;
    input.level = 0;
    // Effect often soft-skips the same calendar day Country seals. Schedule
    // the first fire for the next sequential Effect day (committed+1), never
    // the already-closed committed day — otherwise plan_day cannot see the
    // instance until a never-fired cadence retry (technology cadence is 3650).
    const int64_t effect_day = _effect_pod_authority.snapshot().committed_day;
    input.next_due_day = effect_day >= 0 ? effect_day + 1 : day;
    input.active = true;
    // Queue only. The main-thread Country peer adapter must never mutate the
    // Effect POD authority: worker plan_day/commit/ack run concurrently and a
    // same-turn upsert races them (instances stuck fire_seq=0 / never fire).
    // Effect stage drain_effect_transport_queues installs before plan/soft-skip.
    if (!queue_effect_pod_instance(input, error)) return false;
    return true;
}

bool NativeSimulationHost::effect_pod_instance_exists(int64_t instance_id,
                                                     uint32_t generation) const {
    if (!_effect_pod_configured || instance_id == 0 || generation == 0)
        return false;
    const auto &snapshot = _effect_pod_authority.snapshot();
    for (const auto &instance : snapshot.instances) {
        if (instance.instance_id != instance_id) continue;
        // Same rule as EffectRuntime::has_instance_pod: an inactive instance is
        // still a known identity, the generation is what makes it stale.
        return instance.generation == generation;
    }
    // Not installed yet, but a queued upsert is already a live identity: the
    // transport accepted the row and the worker will install it. Answering
    // "absent" here made every main-thread reader race the transport --
    // the ideology restore rejected a save whose instances were merely queued,
    // and register_person_effect re-upserted (each time with a fresh
    // next_due_day) on every call. A queued *retire* needs no special case: until
    // it drains the instance genuinely still exists, which is what the snapshot
    // branch above already reports.
    std::lock_guard<std::mutex> lock(_effect_transport_mutex);
    for (const EffectPodInstanceQueueItem &item : _effect_instance_queue) {
        if (item.input.instance_id == instance_id &&
            item.input.generation == generation)
            return true;
    }
    return false;
}

std::string NativeSimulationHost::describe_effect_pod_technology_state(
        int64_t instance_id, uint32_t generation, int32_t program_id,
        int32_t technology) const {
    char text[512]{};
    if (!_effect_pod_configured) return "effect_pod_not_configured";
    const auto &snapshot = _effect_pod_authority.snapshot();
    const RuntimeEffectPodInstance *found = nullptr;
    for (const auto &instance : snapshot.instances) {
        if (instance.instance_id == instance_id) { found = &instance; break; }
    }
    int transactions = 0;
    int last_status = -1;
    for (const auto &transaction : snapshot.transactions) {
        if (transaction.source_instance_id != instance_id) continue;
        ++transactions;
        last_status = static_cast<int>(transaction.status);
    }
    std::snprintf(text, sizeof(text),
        "tech=%d program_id=%d instance=%lld gen=%u "
        "present=%d inst_gen=%u active=%d fire_seq=%llu acked_seq=%llu "
        "next_due=%lld tx=%d last_tx_status=%d pod_gen=%llu pod_day=%lld "
        "instances=%zu queued=%zu",
        technology, program_id, static_cast<long long>(instance_id), generation,
        found != nullptr ? 1 : 0,
        found != nullptr ? found->generation : 0u,
        found != nullptr ? static_cast<int>(found->active) : -1,
        static_cast<unsigned long long>(found != nullptr ? found->fire_sequence : 0),
        static_cast<unsigned long long>(
            found != nullptr ? found->last_acked_fire_sequence : 0),
        static_cast<long long>(found != nullptr ? found->next_due_day : -1),
        transactions, last_status,
        static_cast<unsigned long long>(snapshot.generation),
        static_cast<long long>(snapshot.committed_day),
        snapshot.instances.size(), _effect_instance_queue.size());
    return text;
}

bool NativeSimulationHost::effect_pod_instance_fire_acked(
        int64_t instance_id, uint32_t generation) const {
    if (!_effect_pod_configured || instance_id == 0 || generation == 0)
        return false;
    const auto &snapshot = _effect_pod_authority.snapshot();
    const RuntimeEffectPodInstance *found = nullptr;
    for (const auto &instance : snapshot.instances) {
        if (instance.instance_id == instance_id &&
            instance.generation == generation) {
            found = &instance;
            break;
        }
    }
    if (found == nullptr || found->fire_sequence == 0) return false;
    if (found->last_acked_fire_sequence >= found->fire_sequence) return true;
    bool saw_acked = false;
    bool saw_rejected = false;
    for (const auto &transaction : snapshot.transactions) {
        if (transaction.source_instance_id != instance_id ||
            transaction.source_generation != generation) {
            continue;
        }
        if (transaction.status != RuntimeEffectPodTransactionStatus::ACKED &&
            transaction.status != RuntimeEffectPodTransactionStatus::REJECTED) {
            return false;
        }
        if (transaction.status == RuntimeEffectPodTransactionStatus::ACKED)
            saw_acked = true;
        else
            saw_rejected = true;
    }
    if (saw_acked) return true;
    if (saw_rejected) return false;
    return true;
}

uint32_t NativeSimulationHost::resolve_pending_country_effect_peers() {
    if (!_effect_pod_configured) return 0;
    uint32_t promoted = 0;
    {
        std::lock_guard<std::mutex> lock(_country_transport_mutex);
        for (auto &entry : _country_worker_results) {
            CountryPeerResult &result = entry.second;
            if (result.code != CountryPeerResultCode::PENDING) continue;
            if (result.opcode != CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT &&
                result.opcode != CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT) {
                continue;
            }
            const auto intent_it = _country_worker_intents.find(entry.first);
            if (intent_it == _country_worker_intents.end()) continue;
            const CountryPeerIntent &intent = intent_it->second;
            if (intent.effect_instance_id == 0 || intent.effect_generation == 0)
                continue;
            if (!effect_pod_instance_fire_acked(
                    static_cast<int64_t>(intent.effect_instance_id),
                    intent.effect_generation)) {
                static std::atomic<int> s_unacked_left{24};
                if (s_unacked_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
                    const auto &snap = _effect_pod_authority.snapshot();
                    int64_t fire_seq = -1, acked_seq = -1, next_due = -1;
                    for (const auto &inst : snap.instances) {
                        if (inst.instance_id == static_cast<int64_t>(
                                intent.effect_instance_id)) {
                            fire_seq = static_cast<int64_t>(inst.fire_sequence);
                            acked_seq = static_cast<int64_t>(
                                inst.last_acked_fire_sequence);
                            next_due = inst.next_due_day;
                        }
                    }
                    std::string tx;
                    for (const auto &t : snap.transactions) {
                        if (t.source_instance_id !=
                            static_cast<int64_t>(intent.effect_instance_id))
                            continue;
                        char buf[96];
                        std::snprintf(buf, sizeof(buf), " tx%lld:st=%d req=0x%x got=0x%x",
                            static_cast<long long>(t.transaction_id),
                            static_cast<int>(t.status), t.required_ack_mask,
                            t.received_ack_mask);
                        tx += buf;
                    }
                    pk::log_info("[tech-ack-diag/unacked] tech=%d fire_seq=%d "
                                 "acked_seq=%d next_due=%d pod_day=%d%s",
                                 static_cast<int64_t>(intent.technology),
                                 fire_seq, acked_seq, next_due,
                                 snap.committed_day, tx.c_str());
                }
                continue;
            }
            result.code = CountryPeerResultCode::READY;
            result.technology_flags = static_cast<uint8_t>(
                result.technology_flags | COUNTRY_PEER_EFFECT_EXISTS |
                COUNTRY_PEER_EFFECT_FIRE_ACKED);
            _country_worker_terminal_results[entry.first] = result;
            ++promoted;
        }
        if (promoted > 0u) {
            _country_peer_signal.fetch_add(1, std::memory_order_acq_rel);
            // P2：把"谁推进了 peer"变成可数量。worker 内闭环是目标形态；
            // 只要 by_main 还在涨，说明这条线仍然依赖主线程泵。
            if (on_worker_thread()) {
                _country_peer_resolved_in_worker.fetch_add(promoted,
                                                          std::memory_order_relaxed);
            } else {
                _country_peer_resolved_by_main.fetch_add(promoted,
                                                         std::memory_order_relaxed);
            }
        }
    }
    if (promoted > 0u) {
        _control_cv.notify_all();
        static int s_promote_left = 16;
        if (s_promote_left-- > 0) {
            pk::log_info(
                "[tech-ack-diag/promote] pending→READY count=%d stall=0x%x",
                static_cast<int64_t>(promoted),
                static_cast<int64_t>(day_stall_reason_mask()));
        }
    }
    return promoted;
}

bool NativeSimulationHost::drain_effect_transport_queues(std::string &error) {
    error.clear();
    if (!_effect_pod_configured) {
        error = "effect_pod_not_configured";
        return false;
    }
    std::deque<EffectPodInstanceQueueItem> instances;
    std::deque<EffectPodMetricQueueItem> metrics;
    std::deque<EffectPodRemoveQueueItem> removes;
    std::vector<RuntimeDomainAck> acks;
    {
        std::lock_guard<std::mutex> lock(_effect_transport_mutex);
        instances.swap(_effect_instance_queue);
        metrics.swap(_effect_metric_queue);
        removes.swap(_effect_remove_queue);
        acks.assign(_effect_acks.begin(), _effect_acks.end());
        _effect_acks.clear();
    }

    auto restore_remaining =
        [this](std::deque<EffectPodInstanceQueueItem> &left,
               std::deque<EffectPodMetricQueueItem> &metrics_left,
               std::deque<EffectPodRemoveQueueItem> &removes_left) {
            std::lock_guard<std::mutex> lock(_effect_transport_mutex);
            while (!left.empty()) {
                _effect_instance_queue.push_front(left.back());
                left.pop_back();
            }
            while (!metrics_left.empty()) {
                _effect_metric_queue.push_front(metrics_left.back());
                metrics_left.pop_back();
            }
            while (!removes_left.empty()) {
                _effect_remove_queue.push_front(removes_left.back());
                removes_left.pop_back();
            }
        };

    // Replay retires and upserts strictly in arrival order. Draining either
    // deque wholesale reorders "submit then retire" into "retire then submit",
    // and the retired instance comes back on the next plan.
    while (!removes.empty() || !instances.empty()) {
        const bool take_remove =
            !removes.empty() &&
            (instances.empty() ||
             removes.front().sequence < instances.front().sequence);
        if (take_remove) {
            const EffectPodRemoveQueueItem item = removes.front();
            removes.pop_front();
            if (_effect_pod_authority.remove_instance(item.instance_id,
                                                       item.generation, error)) {
                continue;
            }
            // EffectRuntime::retire_instance_pod returns true when no instance
            // matches: nothing was ever installed, so nothing Effect-owned can
            // be left behind. The worker authority reports "absent" and
            // "generation superseded" through the same token, and both are
            // benign here -- the queued retire simply has nothing to retire.
            if (error == "effect_pod_instance_stale_generation") {
                const auto &known = _effect_pod_authority.snapshot().instances;
                const bool id_present = std::any_of(
                    known.begin(), known.end(),
                    [&item](const RuntimeEffectPodInstance &instance) {
                        return instance.instance_id == item.instance_id;
                    });
                if (id_present)
                    _effect_retire_stale_count.fetch_add(
                        1, std::memory_order_release);
                else
                    _effect_retire_absent_count.fetch_add(
                        1, std::memory_order_release);
                error.clear();
                continue;
            }
            removes.push_front(item);
            restore_remaining(instances, metrics, removes);
            return false;
        }
        const EffectPodInstanceQueueItem queued = instances.front();
        instances.pop_front();
        RuntimeEffectPodInstanceInput input = queued.input;
        // Queue may have waited across Effect soft-skips / climate parks.
        // Never-fired technology installs must land on the next plan day.
        const int64_t committed = _effect_pod_authority.snapshot().committed_day;
        // 负数 due day 是「还没排期」，不是非法值：声明式注册在地图生成阶段就跑过
        // 一遍，那时主线程时钟还是 day -1，于是整批 ENSURE 带着 next_due_day=-1
        // 进队。validate_instance 只能拒绝它，而这个拒绝又会把 host 日钉死
        // （新开局冻在 day 2 的直接原因）。这里和其它「已过期」的情形一起归一到
        // 下一个计划日。
        if (input.next_due_day < 0) {
            input.next_due_day = std::max<int64_t>(0, committed + 1);
        } else if (committed >= 0 && input.next_due_day <= committed) {
            input.next_due_day = committed + 1;
        }
        if (!_effect_pod_authority.upsert_instance(input, error)) {
            // `effect_pod_instance_invalid` 是队列行自身的属性（program 越界 /
            // target_generation 为 0 / next_due_day 为负 / id 非正），排队再久也
            // 不会变合法。以前这里一律回插 + 返回 false：Effect 阶段每天在同一行
            // 失败，host 日再也提交不了，十二域 grant 一个都不授，新开局就冻在
            // 第 2 天。丢弃 + 记账 + 留字段快照，让游戏继续跑到能修产生端。
            // capacity / not_configured 仍然是暂态，保留回插。
            if (error == "effect_pod_instance_invalid") {
                _effect_instance_rejected_count.fetch_add(
                    1, std::memory_order_release);
                char detail[96];
                std::snprintf(detail, sizeof(detail),
                    "id=%lld gen=%u prog=%d th=%llu tg=%u due=%lld",
                    static_cast<long long>(input.instance_id),
                    static_cast<unsigned>(input.generation),
                    static_cast<int>(input.program_id),
                    static_cast<unsigned long long>(input.target_handle),
                    static_cast<unsigned>(input.target_generation),
                    static_cast<long long>(input.next_due_day));
                for (size_t i = 0; i + 1 < _effect_instance_reject_detail.size(); ++i) {
                    const char value = detail[i];
                    _effect_instance_reject_detail[i].store(
                        value, std::memory_order_release);
                    if (value == '\0') break;
                }
                _effect_instance_reject_detail[
                    _effect_instance_reject_detail.size() - 1].store(
                        '\0', std::memory_order_release);
                error.clear();
                continue;
            }
            EffectPodInstanceQueueItem retry = queued;
            retry.input = input;
            instances.push_front(retry);
            restore_remaining(instances, metrics, removes);
            return false;
        }
    }
    while (!metrics.empty()) {
        const EffectPodMetricQueueItem item = metrics.front();
        metrics.pop_front();
        if (!_effect_pod_authority.set_metric(
                item.instance_id, item.generation, item.metric_id,
                item.revision, item.value, error)) {
            // 实例已被换掉/丢弃，这条指标永远落不上去。回插会让 Effect 阶段
            // 每天同一处失败，与 ENSURE 的 effect_pod_instance_invalid 是同一类
            // 毒丸；丢弃并计数。
            if (error == "effect_pod_metric_stale_generation") {
                _effect_instance_rejected_count.fetch_add(
                    1, std::memory_order_release);
                error.clear();
                continue;
            }
            metrics.push_front(item);
            restore_remaining(instances, metrics, removes);
            return false;
        }
    }
    if (!acks.empty() &&
        !_effect_pod_authority.apply_acks(acks, error)) {
        return false;
    }
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

    if (!drain_effect_transport_queues(error)) return false;

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
