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

bool NativeSimulationHost::enqueue(RuntimeCommandPacket packet) {
    std::vector<RuntimeCommandPacket> packets;
    packets.reserve(1);
    packets.push_back(std::move(packet));
    return enqueue_batch(std::move(packets));
}

bool NativeSimulationHost::enqueue_batch(
        std::vector<RuntimeCommandPacket> packets) {
    if (packets.empty()) return false;
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current == RuntimeWorkerState::STOPPED ||
        current == RuntimeWorkerState::STOPPING ||
        current == RuntimeWorkerState::FAULTED) return false;

    // Serialise producers for the batch path. The consumer remains lock-free
    // and may advance dequeue_pos while this lock is held.
    std::lock_guard<std::mutex> lock(_command_enqueue_mutex);
    const auto admitted_state = _state.load(std::memory_order_acquire);
    if (admitted_state == RuntimeWorkerState::STOPPED ||
        admitted_state == RuntimeWorkerState::STOPPING ||
        admitted_state == RuntimeWorkerState::FAULTED ||
        _stop_requested.load(std::memory_order_acquire)) return false;
    const uint64_t write = _command_enqueue_pos.load(std::memory_order_relaxed);
    const uint64_t read = _command_dequeue_pos.load(std::memory_order_acquire);
    if (packets.size() > RUNTIME_COMMAND_QUEUE_CAPACITY ||
        write - read > RUNTIME_COMMAND_QUEUE_CAPACITY - packets.size()) {
        _command_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    for (size_t index = 0; index < packets.size(); ++index) {
        const uint64_t position = write + static_cast<uint64_t>(index);
        CommandQueueSlot &slot = _command_slots[
            position % RUNTIME_COMMAND_QUEUE_CAPACITY];
        const uint64_t sequence = slot.sequence.load(std::memory_order_acquire);
        if (sequence != position) {
            _command_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
    }
    for (size_t index = 0; index < packets.size(); ++index) {
        RuntimeCommandPacket &packet = packets[index];
        if (packet.submit_order == 0) {
            packet.submit_order = _command_submit_order.fetch_add(
                1u, std::memory_order_relaxed) + 1u;
        }
        const uint64_t position = write + static_cast<uint64_t>(index);
        CommandQueueSlot &slot = _command_slots[
            position % RUNTIME_COMMAND_QUEUE_CAPACITY];
        slot.packet = packet;
        slot.sequence.store(position + 1, std::memory_order_release);
    }
    // Country's typed lifecycle begins at Host admission. Keep this state
    // under the same transport mutex used by terminal publication so a save
    // boundary cannot observe a pending packet without its Accepted record.
    {
        std::lock_guard<std::mutex> country_lock(_country_transport_mutex);
        for (const RuntimeCommandPacket &packet : packets) {
            if (packet.envelope.domain !=
                    static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
                packet.envelope.request_id == 0) {
                continue;
            }
            if (_country_command_states.find(packet.envelope.request_id) !=
                    _country_command_states.end()) {
                continue;
            }
            CountryCommandReceipt receipt;
            receipt.request_id = packet.envelope.request_id;
            receipt.producer_id = packet.envelope.producer_id;
            receipt.sequence = packet.envelope.sequence;
            receipt.effective_day = packet.envelope.effective_day;
            receipt.generation = _generation.load(std::memory_order_acquire);
            receipt.code = CountryCommandReceiptCode::ACCEPTED;
            _country_command_states.emplace(receipt.request_id,
                                             std::move(receipt));
        }
    }
    _command_enqueue_pos.store(write + packets.size(),
                               std::memory_order_release);
    _last_command_admitted_us.store(now_us(), std::memory_order_release);
    _control_cv.notify_one();
    return true;
}

void NativeSimulationHost::reserve_command_request_ids_through(uint64_t maximum) noexcept {
    uint64_t observed = _command_request_id.load(std::memory_order_acquire);
    while (observed < maximum &&
           !_command_request_id.compare_exchange_weak(
               observed, maximum, std::memory_order_acq_rel,
               std::memory_order_acquire)) {}
}

uint64_t NativeSimulationHost::allocate_command_request_id() {
    uint64_t value = _command_request_id.fetch_add(
        1u, std::memory_order_relaxed) + 1u;
    if (value == 0) {
        value = _command_request_id.fetch_add(
            1u, std::memory_order_relaxed) + 1u;
    }
    return value;
}

bool NativeSimulationHost::enqueue_modifier_shadow(RuntimeCommandPacket packet) {
    if (packet.envelope.domain !=
            static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) return false;
    const auto modifier_enqueue_allowed = [this]() {
        const RuntimeSimulationMode mode =
            _mode.load(std::memory_order_acquire);
        if (mode == RuntimeSimulationMode::SHADOW) return true;
        // E8: ACTIVE Host is the sole Modifier writer once MODIFIER is
        // in the requested authority mask (grant may still be pending).
        if (mode == RuntimeSimulationMode::ACTIVE &&
            (_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u) {
            return true;
        }
        return false;
    };
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current != RuntimeWorkerState::STOPPED) {
        if (!modifier_enqueue_allowed()) return false;
        return enqueue(std::move(packet));
    }
    if (packet.submit_order == 0) {
        packet.submit_order = _command_submit_order.fetch_add(
            1u, std::memory_order_relaxed) + 1u;
    }
    std::lock_guard<std::mutex> lock(_control_mutex);
    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED) {
        if (!modifier_enqueue_allowed()) return false;
        return enqueue(std::move(packet));
    }
    if (_prestart_modifier_commands.size() >= RUNTIME_COMMAND_QUEUE_CAPACITY) {
        _command_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    _prestart_modifier_commands.push_back(std::move(packet));
    return true;
}

uint64_t NativeSimulationHost::allocate_producer_sequence(uint32_t producer_id) {
    if (producer_id < _producer_sequences.size()) {
        return _producer_sequences[producer_id].fetch_add(1, std::memory_order_relaxed) + 1;
    }
    return _fallback_producer_sequence.fetch_add(1, std::memory_order_relaxed) + 1;
}

bool NativeSimulationHost::pop_command(RuntimeCommandPacket &out) {
    uint64_t position = _command_dequeue_pos.load(std::memory_order_relaxed);
    CommandQueueSlot *slot = nullptr;
    for (;;) {
        slot = &_command_slots[position % RUNTIME_COMMAND_QUEUE_CAPACITY];
        const uint64_t sequence = slot->sequence.load(std::memory_order_acquire);
        const int64_t difference = static_cast<int64_t>(sequence - (position + 1));
        if (difference == 0) {
            if (_command_dequeue_pos.compare_exchange_weak(
                    position, position + 1, std::memory_order_relaxed,
                    std::memory_order_relaxed)) {
                break;
            }
        } else if (difference < 0) {
            return false;
        } else {
            position = _command_dequeue_pos.load(std::memory_order_relaxed);
        }
    }
    out = slot->packet;
    slot->sequence.store(position + RUNTIME_COMMAND_QUEUE_CAPACITY,
                         std::memory_order_release);
    return true;
}

bool NativeSimulationHost::next_command(RuntimeCommandPacket &out) const {
    const uint64_t position = _command_dequeue_pos.load(std::memory_order_relaxed);
    const CommandQueueSlot &slot = _command_slots[position % RUNTIME_COMMAND_QUEUE_CAPACITY];
    const uint64_t sequence = slot.sequence.load(std::memory_order_acquire);
    if (sequence != position + 1) return false;
    out = slot.packet;
    return true;
}

bool NativeSimulationHost::push_receipt(const RuntimeCommandReceipt &receipt) {
    const uint64_t write = _receipt_write.load(std::memory_order_relaxed);
    const uint64_t read = _receipt_read.load(std::memory_order_acquire);
    if (write - read >= RUNTIME_RECEIPT_QUEUE_CAPACITY) {
        _receipt_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    _receipts[write % RUNTIME_RECEIPT_QUEUE_CAPACITY] = receipt;
    _receipt_write.store(write + 1, std::memory_order_release);
    return true;
}

bool NativeSimulationHost::poll_receipt(RuntimeCommandReceipt &out) {
    const uint64_t read = _receipt_read.load(std::memory_order_relaxed);
    const uint64_t write = _receipt_write.load(std::memory_order_acquire);
    if (read == write) return false;
    out = _receipts[read % RUNTIME_RECEIPT_QUEUE_CAPACITY];
    _receipt_read.store(read + 1, std::memory_order_release);
    return true;
}

CountryAiRuntime *NativeSimulationHost::country_ai_for_worker() const noexcept {
    CountryAiRuntime *runtime = _country_ai_runtime.load(std::memory_order_acquire);
    if (runtime == nullptr) return nullptr;
    // SHADOW mirrors the synchronous adapter's AI commands; only ACTIVE with
    // Country authority plans on the worker.
    if (_mode.load(std::memory_order_acquire) != RuntimeSimulationMode::ACTIVE ||
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::COUNTRY)) == 0u)
        return nullptr;
    return runtime->active() ? runtime : nullptr;
}

void NativeSimulationHost::commit_country_ai_day(int64_t day) {
    CountryAiRuntime *runtime = country_ai_for_worker();
    if (runtime == nullptr) return;
    CountryAiCommitResult result = runtime->commit(day);
    if (_economy_production_runtime == nullptr) return;
    if (result.family_preferences_changed)
        _economy_production_runtime->set_country_ai_family_preferences(
            std::move(result.family_preferences));
    if (!result.colonization.empty())
        _economy_production_runtime->queue_country_ai_colonization(
            std::move(result.colonization));
}

void NativeSimulationHost::publish_country_command_terminals(
        const std::vector<RuntimeCountryCommand> &commands,
        CountryCommandReceiptCode code, uint64_t generation,
        const char *reason, bool include_superseded_ai) {
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    for (const RuntimeCountryCommand &command : commands) {
        // Worker-local AI has no admitted packet to retire. SHADOW's mirrored
        // sync AI does: keep its terminal internally so successful commands do
        // not repeat forever. poll_country_command_receipts filters AI from
        // the player stream independently of this transport lifecycle.
        if (command.producer_id == COUNTRY_AI_PRODUCER_ID &&
            !include_superseded_ai &&
            _country_command_states.find(command.request_id) ==
                _country_command_states.end()) continue;
        if (command.request_id == 0 ||
            _country_command_terminals.find(command.request_id) !=
                _country_command_terminals.end()) {
            continue;
        }
        CountryCommandReceipt receipt;
        receipt.request_id = command.request_id;
        receipt.producer_id = command.producer_id;
        receipt.sequence = command.sequence;
        receipt.effective_day = command.effective_day;
        receipt.generation = generation;
        receipt.code = code;
        if (reason != nullptr) receipt.reason = reason;
        _country_command_states[receipt.request_id] = receipt;
        _country_command_terminals.emplace(receipt.request_id,
                                           std::move(receipt));
    }
}

void NativeSimulationHost::retire_country_ai_ingress(
        const std::vector<RuntimeCommandPacket> &packets) {
    if (country_ai_for_worker() == nullptr) return;
    std::vector<RuntimeCountryCommand> superseded;
    for (const RuntimeCommandPacket &packet : packets) {
        const auto &envelope = packet.envelope;
        if (envelope.domain != static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
            envelope.producer_id != COUNTRY_AI_PRODUCER_ID || envelope.request_id == 0)
            continue;
        RuntimeCountryCommand command;
        command.request_id = envelope.request_id;
        command.producer_id = envelope.producer_id;
        command.sequence = envelope.sequence;
        command.effective_day = envelope.effective_day;
        superseded.push_back(command);
    }
    if (superseded.empty()) return;
    // 主线程 AI 的旧包已被既有 worker 重规划路径取代，必须明确收尾。
    // 不伪造已执行，不让旧 ACCEPTED 包永久阻塞 OwnedState 的安全切换。
    publish_country_command_terminals(superseded,
        CountryCommandReceiptCode::REJECTED_AT_EXECUTION,
        _country_pod_authority.generation(), "country_ai_superseded_by_worker", true);
}

bool NativeSimulationHost::poll_country_command_receipts(
        uint64_t after_request_id, uint32_t limit,
        std::vector<CountryCommandReceipt> &out) {
    out.clear();
    const uint32_t bounded_limit = std::min<uint32_t>(limit, 4096u);
    if (bounded_limit == 0) return true;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    auto it = _country_command_terminals.upper_bound(after_request_id);
    for (; it != _country_command_terminals.end() &&
           out.size() < bounded_limit; ++it) {
        if (it->second.producer_id == COUNTRY_AI_PRODUCER_ID) continue;
        out.push_back(it->second);
    }
    return true;
}

bool NativeSimulationHost::try_country_command_terminal(
        uint64_t request_id, CountryCommandReceipt &out) {
    if (request_id == 0) return false;
    std::lock_guard<std::mutex> lock(_country_transport_mutex);
    const auto found = _country_command_terminals.find(request_id);
    if (found == _country_command_terminals.end()) return false;
    out = found->second;
    return true;
}

bool NativeSimulationHost::poll_commit(uint64_t after_generation, RuntimeCommit &out) {
    const uint64_t latest_generation = _generation.load(std::memory_order_acquire);
    uint32_t index = 0;
    if (_snapshots.try_acquire_latest(after_generation, index)) {
        RuntimeCommit candidate = _snapshots.read_buffer(index);
        _snapshots.release(index);
        // Visual publication is intentionally throttled.  A READY buffer may
        // therefore describe an older generation than the authoritative scalar
        // header. Never move the facade backwards just because the newest
        // visual buffer is still within the 20 Hz window; return the scalar
        // boundary below and let visual patch consumption remain generation
        // aware.
        if (candidate.header.generation >= latest_generation) {
            out = std::move(candidate);
            return true;
        }
    }
    // The visual ring is allowed to drop intents under backpressure, but a
    // dropped buffer must not erase the authoritative commit boundary.
    const uint64_t generation = _generation.load(std::memory_order_acquire);
    // A throttled visual publication still advances the authoritative
    // generation. Return the scalar header even when no READY buffer exists;
    // the caller can then observe progress while visual patch consumption
    // remains generation-aware and may legitimately report no intents.
    if (generation == 0 || generation <= after_generation) return false;
    out = RuntimeCommit{};
    out.header.generation = generation;
    out.header.from_day = _latest_from_day.load(std::memory_order_acquire);
    out.header.committed_day = _latest_committed_day.load(std::memory_order_acquire);
    out.header.produced_at_us = _latest_produced_at_us.load(std::memory_order_acquire);
    out.header.dirty_families = _latest_dirty_families.load(std::memory_order_acquire);
    out.header.state_hash = _state_hash.load(std::memory_order_acquire);
    out.header.command_receipt_count = _latest_receipt_count.load(std::memory_order_acquire);
    for (size_t family_index = 0; family_index < RUNTIME_DIRTY_FAMILY_COUNT; ++family_index) {
        out.header.dirty_family_generations[family_index] =
            _dirty_family_generations[family_index].load(std::memory_order_acquire);
    }
    return true;
}

bool NativeSimulationHost::poll_commit_generation(uint64_t generation, RuntimeCommit &out) {
    uint32_t index = 0;
    if (_snapshots.try_acquire_generation(generation, index)) {
        out = _snapshots.read_buffer(index);
        _snapshots.release(index);
        return true;
    }
    // Exact lookup is only reconstructible for the newest scalar header. A
    // throttled generation has no visual buffer, but the current generation
    // is still a valid authoritative commit boundary.
    if (generation == 0 ||
        generation != _generation.load(std::memory_order_acquire)) return false;
    out = RuntimeCommit{};
    out.header.generation = generation;
    out.header.from_day = _latest_from_day.load(std::memory_order_acquire);
    out.header.committed_day = _latest_committed_day.load(std::memory_order_acquire);
    out.header.produced_at_us = _latest_produced_at_us.load(std::memory_order_acquire);
    out.header.dirty_families = _latest_dirty_families.load(std::memory_order_acquire);
    out.header.state_hash = _state_hash.load(std::memory_order_acquire);
    out.header.command_receipt_count = _latest_receipt_count.load(std::memory_order_acquire);
    for (size_t family_index = 0; family_index < RUNTIME_DIRTY_FAMILY_COUNT; ++family_index) {
        out.header.dirty_family_generations[family_index] =
            _dirty_family_generations[family_index].load(std::memory_order_acquire);
    }
    return true;
}

RuntimeDayPlan NativeSimulationHost::build_day_plan(
        int64_t day, double speed_scale,
        const RuntimeEnvironmentSnapshot *environment,
        uint64_t command_watermark) const {
    RuntimeDayPlan plan;
    plan.context.day = day;
    plan.context.season_phase = environment != nullptr
        ? environment->season_phase : 0.0;
    plan.context.speed_scale = speed_scale;
    plan.context.input_generation = environment != nullptr
        ? environment->generation : 0;
    plan.context.frozen_input.session_epoch = _country_worker_session_epoch;
    plan.context.frozen_input.day = day;
    plan.context.frozen_input.generation = plan.context.input_generation;
    plan.context.frozen_input.command_watermark = command_watermark;
    plan.context.frozen_input.committed = environment != nullptr ? 1u : 0u;
    plan.context.frozen_input.in_flight = 0u;
    plan.context.environment = environment;

    constexpr auto order = runtime_domain_stage_order();
    for (uint32_t i = 0; i < plan.stage_count; ++i)
        plan.stages[i].domain = order[i];
    return plan;
}

// Both executors retain accepted future commands and apply the same stable order.
// Inline keeps the backlog on the Host; worker owns its equivalent local vector.
void NativeSimulationHost::drain_inline_day_commands(
        int64_t day, std::vector<RuntimeCommandPacket> &day_commands,
        std::vector<RuntimeCommandReceipt> &day_receipts,
        uint64_t &admitted_submit_order) {
    day_commands.clear();
    day_receipts.clear();
    admitted_submit_order = 0;
    RuntimeCommandPacket incoming;
    while (pop_command(incoming)) _executor_pending_commands.push_back(std::move(incoming));
    std::stable_sort(_executor_pending_commands.begin(), _executor_pending_commands.end(),
                     command_packet_before);
    for (const auto &packet : _executor_pending_commands)
        admitted_submit_order = std::max(admitted_submit_order, packet.submit_order);
    size_t consumed = 0;
    for (; consumed < _executor_pending_commands.size(); ++consumed) {
        const auto &incoming = _executor_pending_commands[consumed];
        const RuntimeCommandEnvelope &envelope = incoming.envelope;
        if (envelope.effective_day > day) break;
        RuntimeCommandReceipt receipt;
        receipt.request_id = envelope.request_id;
        receipt.producer_id = envelope.producer_id;
        receipt.sequence = envelope.sequence;
        receipt.effective_day = std::max(envelope.effective_day, day);
        receipt.generation = _generation.load(std::memory_order_relaxed) + 1;
        const bool domain_valid =
            envelope.domain >= static_cast<uint16_t>(RuntimeDomainId::INPUT_CAPTURE) &&
            envelope.domain <= static_cast<uint16_t>(RuntimeDomainId::COMMIT);
        const bool events_probe = domain_valid &&
            static_cast<RuntimeDomainId>(envelope.domain) == RuntimeDomainId::EVENTS &&
            _events_probe_enabled.load(std::memory_order_acquire);
        // MODIFIER 的 SHADOW 影子解包只属于 SHADOW；内联恒为 ACTIVE。
        const bool modifier_shadow = false;
        const bool domain_implemented = domain_valid &&
            ((implemented_domain_mask() & runtime_domain_mask(
                static_cast<RuntimeDomainId>(envelope.domain))) != 0u ||
             events_probe || modifier_shadow);
        const bool payload_valid =
            envelope.payload_offset <= RUNTIME_MAX_COMMAND_PAYLOAD &&
            envelope.payload_size <= RUNTIME_MAX_COMMAND_PAYLOAD &&
            envelope.payload_offset + envelope.payload_size <=
                RUNTIME_MAX_COMMAND_PAYLOAD;
        if (!payload_valid) {
            receipt.code = RuntimeReceiptCode::INVALID_PAYLOAD;
        } else if (!domain_implemented || envelope.opcode == 0) {
            receipt.code = RuntimeReceiptCode::PREFLIGHT_REJECTED;
        } else {
            receipt.code = RuntimeReceiptCode::OK;
        }
        day_receipts.push_back(receipt);
        day_commands.push_back(incoming);
    }
    _executor_pending_commands.erase(_executor_pending_commands.begin(),
        _executor_pending_commands.begin() + static_cast<ptrdiff_t>(consumed));
    _economy_pending_command_count.store(static_cast<uint32_t>(
        _executor_pending_commands.size()), std::memory_order_release);
}

// 内联日单日墙钟预算（微秒）。默认 30s；PK_INLINE_DAY_BUDGET_MS=0 关闭预算。
// 返回 0 表示"不设预算"：桌面 headless 的长种子/大图可以用它关掉看门狗。
// 静态缓存：每天都要读，但环境变量不会在进程内变。
int64_t NativeSimulationHost::inline_day_budget_us() {
    static const int64_t budget = []() -> int64_t {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_INLINE_DAY_BUDGET_MS);
        if (value == nullptr || *value == '\0') return int64_t{30000} * 1000;
        const long long parsed = std::strtoll(value, nullptr, 10);
        return parsed <= 0 ? int64_t{0} : static_cast<int64_t>(parsed) * 1000;
    }();
    return budget;
}

NativeSimulationHost::InlineDayOutcome NativeSimulationHost::run_inline_day() {
    InlineDayOutcome out;
    if (!inline_daily_mode()) {
        runtime_copy_text(out.reason, "inline_daily_disabled");
        return out;
    }
    if (_mode.load(std::memory_order_acquire) != RuntimeSimulationMode::ACTIVE) {
        runtime_copy_text(out.reason, "inline_daily_requires_active");
        return out;
    }
    if (_state.load(std::memory_order_acquire) == RuntimeWorkerState::FAULTED) {
        runtime_copy_text(out.reason, "inline_daily_host_faulted");
        return out;
    }
    if (_stop_requested.load(std::memory_order_acquire)) {
        runtime_copy_text(out.reason, "inline_daily_stop_requested");
        return out;
    }
    // 与 worker 日事务同一把边界锁。内联模式下执行者就是调用线程，这把锁在
    // 这里只是"一天一个事务"的互斥，不会再有人跨线程等它。
    std::unique_lock<std::mutex> boundary_lock(_economy_authority_boundary_mutex);
    // Both executors use the same scoped identity and domain routing. Leaving
    // the call (including an early return) restores the caller's context.
    AtomicCounterScope day_scope(_worker_day_inflight);
    const RuntimeExecutionContext execution_context(this,
        _requested_authority_mask.load(std::memory_order_acquire));
    const int64_t from_day = _committed_day.load(std::memory_order_acquire);
    const int64_t day = from_day + 1;
    out.from_day = from_day;
    out.day = day;
    // An unfinished day keeps the same frozen frame across executor lifetimes.
    auto environment = _executor_day_environment;
    if (environment && environment->day != day) environment.reset();
    for (uint32_t peek = 0; !environment && peek < 4u; ++peek) {
        environment = environment_input_for_plan();
        if (environment == nullptr || environment->day >= day) break;
        const size_t popped = _environment_ring.pop_while_day_at_most(environment->day);
        if (popped == 0u) break;
        _climate_wait_cv.notify_all();
        environment = nullptr;
    }
    if (environment == nullptr) {
        runtime_copy_text(out.reason, "inline_daily_environment_missing");
        return out;
    }
    out.environment_day = environment->day;
    if (environment->day != day) {
        // 未来的帧不是滞后，不能丢：内联日必须先由调用方补齐输入。
        runtime_copy_text(out.reason, "inline_daily_environment_day_mismatch");
        return out;
    }
    std::vector<RuntimeCommandPacket> day_commands;
    _executor_day_environment = environment;
    day_commands.reserve(16u);
    std::vector<RuntimeCommandReceipt> day_receipts;
    uint64_t admitted_submit_order = 0;
    drain_inline_day_commands(day, day_commands, day_receipts,
                              admitted_submit_order);
    const double speed = _speed_days_per_second.load(std::memory_order_acquire);
    _worker_timing.set(RuntimeWorkerTiming::EXECUTE);
    _day_waterfall.begin(day);
    const auto plan_build_started = std::chrono::steady_clock::now();
    RuntimeDayPlan day_plan = build_day_plan(
        day, speed, environment.get(), admitted_submit_order);
    _day_waterfall.mark(RuntimeDayWaterfall::BUILD_PLAN);
    out.plan_build_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - plan_build_started).count();
    _inline_day_pending.store(true, std::memory_order_release);
    const RuntimeDayCommit day_commit = execute_day_plan(
        day_plan, environment.get(), day_commands, day_receipts,
        admitted_submit_order);
    _day_waterfall.mark(RuntimeDayWaterfall::POST_LOOP);
    // 分域耗时：execute_day_plan 在内联模式下把每一 stage 累加进这个数组。
    // 无论这次尝试成功还是被预算掐断，都把已有账目抄出来 —— 失败的那次往往
    // 正是需要看账的那次。
    for (uint32_t i = 0; i < RUNTIME_DOMAIN_STAGE_COUNT; ++i)
        out.stage_ms[i] = _inline_stage_ms[i];
    out.pre_stage_ms = _inline_pre_stage_ms;
    out.climate_ms = _inline_climate_ms;
    out.executor_serial_only = parallel_serial_only() ? 1u : 0u;
    out.completed_domain_mask = day_commit.completed_domain_mask;
    out.completed_stage_count = day_commit.completed_stage_count;
    out.stage_count = day_plan.stage_count;
    out.dirty_families = day_commit.dirty_families;
    out.work_units = day_commit.work_units;
    out.continuation_pending = day_commit.continuation_pending != 0;
    if (_inline_budget_exceeded) {
        // 看门狗掐断：这一天没有提交，也不该被当成"缺 peer"再重试 —— 重试只
        // 会再花一次同样的预算。调用方看到的是可上报的一次明确失败。
        runtime_copy_text(out.reason, "inline_daily_day_budget_exceeded");
        out.budget_exceeded = true;
        out.continuation_pending = false;
        _executor_pending_commands.insert(_executor_pending_commands.begin(),
            day_commands.begin(), day_commands.end());
        _economy_pending_command_count.store(static_cast<uint32_t>(
            _executor_pending_commands.size()), std::memory_order_release);
        _day_waterfall.mark(RuntimeDayWaterfall::WORKER_RECEIPTS);
        _day_waterfall.finish(false, day_commit.completed_domain_mask);
        _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
        return out;
    }
    if (day_commit.preflight_ok == 0) {
        // 没提交：收据与命令都退回，等调用方泵完 peer 再试同一天。
        _executor_pending_commands.insert(_executor_pending_commands.begin(),
            day_commands.begin(), day_commands.end());
        _economy_pending_command_count.store(static_cast<uint32_t>(
            _executor_pending_commands.size()), std::memory_order_release);
        // 原因链固定顺序：Country peer → Economy → Climate。这三个覆盖了内联
        // 日屏障的全部真实阻塞点，其余域在自己的 stage 里 soft-complete。
        char reason[64]{};
        const auto read_reason = [](const auto &lane, char (&dst)[64]) {
            size_t i = 0;
            for (; i + 1 < sizeof(dst); ++i) {
                const char value = lane[i].load(std::memory_order_acquire);
                if (value == '\0') break;
                dst[i] = value;
            }
            dst[i] = '\0';
        };
        read_reason(_country_pod_fallback_reason, reason);
        if (reason[0] == '\0') read_reason(_economy_yield_reason, reason);
        if (reason[0] == '\0') read_reason(_climate_pod_fallback_reason, reason);
        if (reason[0] == '\0')
            runtime_copy_text(reason, "inline_daily_barrier_incomplete");
        runtime_copy_text(out.reason, reason);
        _last_day_stage_count.store(day_plan.stage_count,
                                    std::memory_order_release);
        _last_day_completed_stages.store(day_commit.completed_stage_count,
                                         std::memory_order_release);
        _last_day_work_units.store(day_commit.work_units,
                                   std::memory_order_release);
        _day_waterfall.mark(RuntimeDayWaterfall::WORKER_RECEIPTS);
        _day_waterfall.finish(false, day_commit.completed_domain_mask);
        _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
        return out;
    }
    for (const RuntimeCommandReceipt &receipt : day_receipts)
        push_receipt(receipt);
    if (day_commit.completed_stage_count == day_plan.stage_count &&
        day_plan.stage_count == RUNTIME_DOMAIN_STAGE_COUNT &&
        day_commit.completed_domain_mask == RUNTIME_ALL_DOMAIN_MASK &&
        implemented_domain_mask() == RUNTIME_ALL_DOMAIN_MASK) {
        _graph_coverage_complete.store(true, std::memory_order_release);
        _authority_control.mark_graph_ready();
    }
    // 日尾与 worker 完全同序：per-domain grant → Climate writeback →
    // 提交水印 → publish_day → 读视图。少任何一步都会让主线程的
    // "worker 权威" 消费端拿到空快照。
    // 日尾单独计时：首日如果在这里花掉大量时间，问题在发布/快照，不在 12 域。
    const auto commit_tail_started = std::chrono::steady_clock::now();
    if (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE) {
        const uint32_t wanted =
            _requested_authority_mask.load(std::memory_order_acquire);
        if (wanted != 0u &&
            (day_commit.completed_domain_mask & wanted) == wanted) {
            publish_authority_grant(wanted);
        }
        if ((wanted & runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u) {
            const int64_t climate_day = _climate_authority.store().committed_day;
            uint32_t slot = 0;
            if (climate_day > _climate_writeback_last_day.load(
                    std::memory_order_relaxed) &&
                _climate_writeback.try_begin_write(slot)) {
                RuntimeClimateSnapshot &writeback =
                    _climate_writeback.write_buffer(slot);
                _climate_authority.snapshot_into(writeback, true);
                writeback.generation = _climate_writeback_sequence.fetch_add(
                    1, std::memory_order_relaxed) + 1u;
                writeback.committed_day = climate_day;
                writeback.dirty_families = day_commit.dirty_families;
                _climate_writeback.publish(slot);
                _climate_writeback_last_day.store(climate_day,
                                                  std::memory_order_relaxed);
            }
        }
    }
    _day_waterfall.mark(RuntimeDayWaterfall::WORKER_CLIMATE_WRITEBACK);
    _last_day_stage_count.store(day_plan.stage_count, std::memory_order_release);
    _last_day_completed_stages.store(day_commit.completed_stage_count,
                                     std::memory_order_release);
    _last_day_work_units.store(day_commit.work_units, std::memory_order_release);
    _committed_day.store(day, std::memory_order_release);
    _completed_days.fetch_add(1, std::memory_order_relaxed);
    publish_day(from_day, day, day_commit, day_receipts);
    _inline_day_pending.store(false, std::memory_order_release);
    if (_economy_production_runtime != nullptr && economy_worker_owns_execution())
        _economy_production_runtime->serve_read_view();
    _day_waterfall.mark(RuntimeDayWaterfall::WORKER_PUBLISH_DAY);
    _day_waterfall.finish(true, day_commit.completed_domain_mask);
    _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
    // 内联模式没有等待者；保留这一行是为了让"提交后唤醒"的语义与 worker 一致，
    // 将来若有人在 CV 上等一天完成也不会漏唤醒。
    _control_cv.notify_all();
    out.committed = true;
    out.continuation_pending = false;
    out.commit_tail_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - commit_tail_started).count();
    runtime_copy_text(out.reason, "");
    return out;
}

void NativeSimulationHost::publish_day(
        int64_t from_day, int64_t day,
        const RuntimeDayCommit &day_commit,
        const std::vector<RuntimeCommandReceipt> &day_receipts) {
    if (try_fault_injection("day.commit.before")) {
        return;
    }
    commit_annual_worker_day(day);
    const uint64_t next_hash = mix_hash(
        _state_hash.load(std::memory_order_relaxed), static_cast<uint64_t>(day));
    _state_hash.store(next_hash, std::memory_order_release);
    std::FILE *day_trace = sim_day_trace_file();
    if (day_trace != nullptr) {
        SimTraceLock trace_lock(day_trace);
        std::fprintf(day_trace,
            "[sim-day-trace] day=%lld input_day=%lld input_hash=%llu env_day=%lld "
            "econ_day=%lld econ_sample=%lld econ_hash=%llu climate_hash=%llu "
            "trigger_hash=%llu modifier_hash=%llu effect_hash=%llu\n",
            static_cast<long long>(day),
            static_cast<long long>(_input_capture_day.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_input_capture_hash.load(std::memory_order_acquire)),
            static_cast<long long>(_environment_day.load(std::memory_order_acquire)),
            static_cast<long long>(_economy_pod_committed_day.load(std::memory_order_acquire)),
            static_cast<long long>(_economy_pod_epoch_sample_day.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_economy_pod_state_hash.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_climate_pod_state_hash.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_trigger_pod_state_hash.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_modifier_pod_state_hash.load(std::memory_order_acquire)),
            static_cast<unsigned long long>(_effect_pod_state_hash.load(std::memory_order_acquire)));
        const auto &econ_state = _economy_pod_authority.state();
        std::fprintf(day_trace,
            "[econ-data] day=%lld gen=%llu pop=%llu funds=%llu active=%llu stock=%llu price=%llu demand=%llu resource=%llu\n",
            static_cast<long long>(day),
            static_cast<unsigned long long>(econ_state.state_generation),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.population.population)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.population.funds)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.population.active)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.market.stock)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.market.price)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.market.demand_ema)),
            static_cast<unsigned long long>(sim_trace_vector_hash(econ_state.resources.stock)));
        std::fflush(day_trace);
    }
    // Publish scalar header fields before the generation release store. A
    // non-blocking reader that observes this generation therefore cannot see
    // metadata from the preceding day even when the visual ring is saturated.
    const uint64_t generation = _generation.load(std::memory_order_relaxed) + 1;
    constexpr std::array<uint32_t, RUNTIME_DIRTY_FAMILY_COUNT> FAMILY_BITS{
        RUNTIME_DIRTY_CLOCK,
        RUNTIME_DIRTY_COUNTRY_STATE,
        RUNTIME_DIRTY_COUNTRY_TERRITORY,
        RUNTIME_DIRTY_COUNTRY_VISUAL_ERA,
        RUNTIME_DIRTY_CLIMATE_FIELDS,
        RUNTIME_DIRTY_WEATHER,
        RUNTIME_DIRTY_ECONOMY_UI,
        RUNTIME_DIRTY_EVENTS,
        RUNTIME_DIRTY_OVERLAY,
    };
    for (size_t family_index = 0; family_index < FAMILY_BITS.size(); ++family_index) {
        if ((day_commit.dirty_families & FAMILY_BITS[family_index]) != 0) {
            _dirty_family_generations[family_index].store(
                generation, std::memory_order_relaxed);
        }
    }
    _latest_from_day.store(from_day, std::memory_order_relaxed);
    _latest_committed_day.store(day, std::memory_order_relaxed);
    _latest_dirty_families.store(day_commit.dirty_families, std::memory_order_relaxed);
    _latest_receipt_count.store(static_cast<uint32_t>(
        std::min<size_t>(day_receipts.size(), std::numeric_limits<uint32_t>::max())),
        std::memory_order_relaxed);
    const uint64_t produced_at_us = now_us();
    _latest_produced_at_us.store(produced_at_us, std::memory_order_release);
    _generation.store(generation, std::memory_order_release);
    _last_commit_produced_at_us.store(produced_at_us, std::memory_order_release);
    const uint64_t last_visual = _last_visual_publish_us.load(std::memory_order_relaxed);
    // Visual state is capped at 20 Hz. Commands and non-clock dirty families
    // bypass the cap so a user action or major event is visible immediately.
    const bool force_visual = !day_receipts.empty() ||
        (day_commit.dirty_families & ~RUNTIME_DIRTY_CLOCK) != 0;
    if (!force_visual && last_visual != 0 && produced_at_us - last_visual < 50000u) {
        _snapshot_publish_throttled_count.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    uint32_t index = 0;
    if (!_snapshots.try_begin_write(index)) return;
    RuntimeCommit &commit = _snapshots.write_buffer(index);
    commit.header = RuntimeCommitHeader{};
    commit.header.generation = generation;
    commit.header.from_day = from_day;
    commit.header.committed_day = day;
    commit.header.produced_at_us = produced_at_us;
    commit.header.dirty_families = day_commit.dirty_families;
    commit.header.state_hash = _state_hash.load(std::memory_order_acquire);
    commit.header.command_receipt_count = static_cast<uint32_t>(
        std::min<size_t>(day_receipts.size(), std::numeric_limits<uint32_t>::max()));
    for (size_t family_index = 0; family_index < FAMILY_BITS.size(); ++family_index) {
        commit.header.dirty_family_generations[family_index] =
            _dirty_family_generations[family_index].load(std::memory_order_acquire);
    }
    // VISUAL is a committed intent boundary. Sort and deduplicate worker
    // intents before exposing them, so consumers never observe order that
    // depends on worker traversal or a half-built batch.
    std::stable_sort(_pod_visual_intents.begin(), _pod_visual_intents.end(),
        [](const RuntimeVisualIntent &a, const RuntimeVisualIntent &b) {
            if (a.family != b.family) return a.family < b.family;
            if (a.cell_index != b.cell_index) return a.cell_index < b.cell_index;
            return a.field_id < b.field_id;
        });
    _pod_visual_intents.erase(std::unique(_pod_visual_intents.begin(),
        _pod_visual_intents.end(), [](const RuntimeVisualIntent &a,
                                      const RuntimeVisualIntent &b) {
            return a.family == b.family && a.cell_index == b.cell_index &&
                   a.field_id == b.field_id && a.value_i32 == b.value_i32 &&
                   a.value_f32 == b.value_f32;
        }), _pod_visual_intents.end());
    _visual_intent_generation.store(generation, std::memory_order_release);
    _visual_intent_count.store(static_cast<uint32_t>(
        std::min<size_t>(_pod_visual_intents.size(),
                         std::numeric_limits<uint32_t>::max())),
        std::memory_order_release);
    _visual_full_refresh.store(_snapshots.publish_drop_count() != 0,
                               std::memory_order_release);
    commit.visual_intents.clear();
    commit.visual_intents.reserve(_pod_visual_intents.size());
    commit.visual_intents.insert(commit.visual_intents.end(),
                                 _pod_visual_intents.begin(),
                                 _pod_visual_intents.end());
    commit.receipts.clear();
    commit.receipts.reserve(day_receipts.size());
    for (const RuntimeCommandReceipt &receipt : day_receipts) {
        commit.receipts.push_back(receipt);
    }
    _snapshots.publish(index);
    _last_visual_publish_us.store(produced_at_us, std::memory_order_release);
    _last_commit_produced_at_us.store(commit.header.produced_at_us,
                                      std::memory_order_release);
    try_fault_injection("day.commit.after");
}

void NativeSimulationHost::publish_economy_tax_diag(
        const std::string &yield_reason, uint32_t slices) {
    const auto store_text = [](auto &dst, const char *text) {
        const char *value = text != nullptr ? text : "";
        size_t i = 0;
        for (; i + 1 < dst.size() && value[i] != '\0'; ++i)
            dst[i].store(value[i], std::memory_order_relaxed);
        for (; i < dst.size(); ++i)
            dst[i].store('\0', std::memory_order_relaxed);
    };
    NativeEconomyRuntime::TaxSchedDiag diag;
    char stage[32] = {};
    char substage[40] = {};
    if (_economy_production_runtime != nullptr) {
        _economy_production_runtime->copy_tax_sched_diag(
            diag, stage, sizeof(stage), substage, sizeof(substage));
    }
    store_text(_economy_yield_reason, yield_reason.c_str());
    store_text(_economy_stage_name, stage);
    store_text(_economy_substage_name, substage);
    _economy_epoch_fiscal_ms.store(diag.epoch_fiscal_ms, std::memory_order_relaxed);
    _economy_fiscal_settlement_ms.store(
        diag.fiscal_settlement_ms, std::memory_order_relaxed);
    _economy_income_subsidy_ms.store(
        diag.income_subsidy_ms, std::memory_order_relaxed);
    _economy_negative_tax_mask.store(diag.negative_tax_mask, std::memory_order_relaxed);
    _economy_active_tax_mask.store(diag.active_tax_mask, std::memory_order_relaxed);
    _economy_attempt_slices.store(slices, std::memory_order_relaxed);
}

} // namespace pk
