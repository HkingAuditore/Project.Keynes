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
#include "economy_hash.h"
#include "effect_magnitude.h"
#include "runtime_economy_ecp2.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"
#include "runtime_switch_registry.h"
#include "runtime_golden_diagnostics.h"
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

// Both executors retain accepted future commands and apply the same stable order.
// Inline keeps the backlog on the Host; worker owns its equivalent local vector.
void NativeSimulationHost::drain_inline_day_commands(
        int64_t day, std::vector<RuntimeCommandPacket> &day_commands,
        std::vector<RuntimeCommandReceipt> &day_receipts,
        uint64_t &admitted_submit_order) {
    day_commands.clear();
    day_receipts.clear();
    admitted_submit_order = 0;
    drain_command_inbox(_executor_pending_commands);
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
    service_economy_boundary_requests();
    service_era_reward_requests();
    service_player_confirmations();
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
    if (const char *block = player_confirmation_block()) {
        runtime_copy_text(out.reason, block);
        return out;
    }
    // An unfinished day keeps the same frozen frame across executor lifetimes.
    auto environment = _executor_day_environment;
    if (environment && environment->day != day) environment.reset();
    for (uint32_t peek = 0; !environment && peek < 4u; ++peek) {
        environment = executor_environment_for_day(day);
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
    const int64_t previous_seal = frozen_command_day();
    if (_world_environment && !try_freeze_command_inputs(day)) {
        runtime_copy_text(out.reason, "inline_daily_command_input_pending");
        return out;
    }
    prepare_narrative_day(day);
    if (state() == RuntimeWorkerState::FAULTED) {
        runtime_copy_text(out.reason, "narrative_choice_apply_failed");
        return out;
    }
    drain_inline_day_commands(day, day_commands, day_receipts, admitted_submit_order);
    const double speed = _speed_days_per_second.load(std::memory_order_acquire);
    _worker_timing.set(RuntimeWorkerTiming::EXECUTE);
    _day_waterfall.begin(day);
    const auto plan_build_started = std::chrono::steady_clock::now();
    RuntimeDayPlan day_plan = build_day_plan(
        day, speed, environment.get(), admitted_submit_order);
    _day_waterfall.mark(RuntimeDayWaterfall::BUILD_PLAN);
    out.plan_build_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - plan_build_started).count();
    const auto peer_signal = _country_peer_signal.load(std::memory_order_acquire);
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
    out.country_peer_progress =
        _country_peer_signal.load(std::memory_order_acquire) != peer_signal;
    if (_inline_budget_exceeded) {
        int64_t expected = day * 2;
        _command_seal.compare_exchange_strong(expected, previous_seal * 2,
            std::memory_order_acq_rel, std::memory_order_acquire);
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
        int64_t expected = day * 2;
        _command_seal.compare_exchange_strong(expected, previous_seal * 2,
            std::memory_order_acq_rel, std::memory_order_acquire);
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
        if (!_world_environment && (wanted & runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u) {
            const int64_t climate_day = _climate_authority.store().committed_day;
            uint32_t slot = 0;
            if (climate_day > _climate_writeback_last_day.load(
                    std::memory_order_relaxed) &&
                _climate_writeback.try_begin_write(slot)) {
                RuntimeClimateSnapshot &writeback =
                    _climate_writeback.write_buffer(slot);
                capture_climate_display(writeback);
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
    _completed_days.fetch_add(1, std::memory_order_relaxed);
    publish_day(from_day, day, day_commit, day_receipts);
    _inline_day_pending.store(false, std::memory_order_release);
    if (_economy_production_runtime != nullptr && economy_worker_owns_execution())
        _economy_production_runtime->serve_read_view();
    _day_waterfall.mark(RuntimeDayWaterfall::WORKER_PUBLISH_DAY);
    _day_waterfall.finish(true, day_commit.completed_domain_mask);
    _worker_timing.set(RuntimeWorkerTiming::OVERHEAD);
    out.committed = true;
    out.continuation_pending = false;
    out.commit_tail_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - commit_tail_started).count();
    runtime_copy_text(out.reason, "");
    return out;
}

} // namespace pk
