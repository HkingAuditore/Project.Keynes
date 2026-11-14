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

bool NativeSimulationHost::publish_environment(
        const RuntimeEnvironmentSnapshot &snapshot, std::string &error) {
    error.clear();
    std::string validation_error;
    if (!validate_runtime_environment_snapshot(snapshot, validation_error)) {
        _invalid_environment_rejected.fetch_add(1, std::memory_order_relaxed);
        error = validation_error;
        return false;
    }
    std::lock_guard<std::mutex> publish_lock(_environment_publish_mutex);
    const bool preparing_restore_input = _has_pending_restore &&
        state() == RuntimeWorkerState::STOPPED && execution_has_stopped();
    const auto previous = preparing_restore_input
        ? std::atomic_load_explicit(&_environment_snapshot, std::memory_order_acquire)
        : _environment_ring.latest();
    if (previous == nullptr) {
        // Fall back to legacy single-slot pointer for the first publish of a
        // session that restored without going through the ring.
        const auto legacy = std::atomic_load_explicit(
            &_environment_snapshot, std::memory_order_acquire);
        if (legacy != nullptr && snapshot.generation <= legacy->generation) {
            _stale_environment_rejected.fetch_add(1, std::memory_order_relaxed);
            error = "runtime_input_stale";
            return false;
        }
    } else if (snapshot.generation <= previous->generation) {
        _stale_environment_rejected.fetch_add(1, std::memory_order_relaxed);
        error = "runtime_input_stale";
        return false;
    }
    const bool climate_authoritative_watermark =
        (authoritative_domain_mask() &
         runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
    const int64_t stale_watermark = preparing_restore_input
        ? _pending_restore_bundle.committed_day
        : (climate_authoritative_watermark
            ? _climate_committed_day.load(std::memory_order_acquire)
            : _committed_day.load(std::memory_order_acquire));
    if (snapshot.day < stale_watermark) {
        _stale_environment_rejected.fetch_add(1, std::memory_order_relaxed);
        error = "runtime_input_before_committed_day";
        return false;
    }
    const bool climate_authoritative =
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
    // The worker consumes inputs strictly day by day, so under authority a
    // skipped day can never be filled and the worker parks until the peer-stall
    // timeout. Refuse anything but the next day; callers publish from
    // next_environment_day().
    if (!preparing_restore_input && climate_authoritative &&
        snapshot.day != next_environment_day()) {
        error = "runtime_input_day_not_next";
        return false;
    }
    if (!preparing_restore_input && !climate_authoritative &&
        !_climate_trace.push(snapshot)) {
        error = "climate_trace_capacity_exceeded";
        return false;
    }
    auto copy = std::make_shared<RuntimeEnvironmentSnapshot>(snapshot);
    {
        EconomyCostProbe probe("environment.seal_input_hash", snapshot.day, snapshot.cell_count);
        copy->sealed_climate_input_hash = RuntimeClimateKernel::input_hash(*copy);
    }
    // Restore preparation stages the replacement input. start() retires the old
    // queue and seeds this snapshot; the stopped world's full queue cannot drain.
    if (!preparing_restore_input) {
        bool dropped = false;
        if (climate_authoritative) {
            // ACTIVE：满环拒绝，主线程 wait_climate_consumed(0) 等空位 —— 不静默丢天。
            if (!_environment_ring.has_capacity() || !_environment_ring.try_push(copy)) {
                error = "climate_environment_pending";
                return false;
            }
        } else {
            // SHADOW：允许 force 覆盖最旧未消费输入，计入 dropped（ring 溢出语义）。
            if (!_environment_ring.force_push(copy, dropped)) {
                error = "climate_environment_ring_push_failed";
                return false;
            }
            if (dropped) {
                _environment_dropped_days.fetch_add(1, std::memory_order_relaxed);
                _environment_superseded_days.fetch_add(1, std::memory_order_relaxed);
            }
        }
    }
    std::atomic_store_explicit(&_environment_snapshot,
        std::shared_ptr<const RuntimeEnvironmentSnapshot>(copy),
        std::memory_order_release);
    _environment_published_days.fetch_add(1, std::memory_order_relaxed);
    _environment_generation.store(snapshot.generation, std::memory_order_release);
    _environment_day.store(snapshot.day, std::memory_order_release);
    _environment_cell_count.store(snapshot.cell_count, std::memory_order_release);
    _environment_topology_validated.store(snapshot.topology_validated,
                                           std::memory_order_release);
    _control_cv.notify_all();
    _climate_wait_cv.notify_all();
    return true;
}

bool NativeSimulationHost::wait_climate_consumed(
        uint64_t after_generation, int64_t timeout_ms,
        uint64_t &consumed_generation, std::string &error) {
    error.clear();
    const uint64_t start_us = now_us();
    const uint64_t budget_us = timeout_ms < 0
        ? 0u : static_cast<uint64_t>(timeout_ms) * 1000u;
    // 每次返回都记等待统计：soak / perf 报告用 last/p95/max 判断背压是否打满
    // 主线程。等待总时长是"worker 没跟上"的直接证据，不是估算。
    const auto finish = [&](bool ok, const char *reason) {
        const uint64_t waited_ms = (now_us() - start_us) / 1000u;
        _climate_wait_last_ms.store(waited_ms, std::memory_order_relaxed);
        _climate_wait_total_ms.fetch_add(waited_ms, std::memory_order_relaxed);
        uint64_t previous_max =
            _climate_wait_max_ms.load(std::memory_order_relaxed);
        while (waited_ms > previous_max &&
               !_climate_wait_max_ms.compare_exchange_weak(
                   previous_max, waited_ms, std::memory_order_relaxed)) {
        }
        if (!ok && reason != nullptr) error = reason;
        return ok;
    };
    std::unique_lock<std::mutex> lock(_control_mutex);
    while (true) {
        consumed_generation =
            _climate_consumed_generation.load(std::memory_order_acquire);
        // native_daily_inline：内联日里没有任何"别处的线程"会推进消费游标 ——
        // 消费就发生在本线程的 run_inline_day()，而调用方此刻正卡在这里。等下去
        // 只能等到超时，而在浏览器主线程上"等 CV"既不能真阻塞又可能永不返回。
        // 所以显式快速失败，让调用方（map_generator 的 grant/writeback 等待循环）
        // 立刻拿到一个可读的原因，而不是每个切片烧 10ms。
        if (inline_daily_mode()) {
            return finish(false, "climate_wait_inline_no_worker");
        }
        // after_generation == 0：等 ring 有空位（流水线发布）。
        // after_generation  > 0：等该代次已被 worker 评估（serial_wait / soak）。
        const bool ready = after_generation == 0
            ? _environment_ring.has_capacity()
            : consumed_generation >= after_generation;
        if (ready) {
            return finish(true, nullptr);
        }
        const RuntimeWorkerState state = _state.load(std::memory_order_acquire);
        if (state == RuntimeWorkerState::FAULTED) {
            return finish(false, "climate_wait_worker_faulted");
        }
        if (state == RuntimeWorkerState::STOPPING ||
            state == RuntimeWorkerState::STOPPED) {
            return finish(false, "climate_wait_worker_stopped");
        }
        if (_stop_requested.load(std::memory_order_acquire)) {
            return finish(false, "climate_wait_stop_requested");
        }
        // 撤销 Climate 权威 = 调用方不再要求这个域。grant 之前 mask 仍可能是
        // 0，所以判据是 requested mask，而不是 authoritative mask。
        if ((_requested_authority_mask.load(std::memory_order_acquire) &
             runtime_domain_mask(RuntimeDomainId::CLIMATE)) == 0u) {
            return finish(false, "climate_wait_authority_revoked");
        }
        const uint64_t elapsed_us = now_us() - start_us;
        if (timeout_ms >= 0) {
            if (elapsed_us >= budget_us) {
                return finish(false, "climate_wait_timeout_slice");
            }
            const uint64_t remaining_us = budget_us - elapsed_us;
            _climate_wait_cv.wait_for(lock,
                                      std::chrono::microseconds(remaining_us));
        } else {
            // "无限等"用 100ms 长片等待实现：真正唤醒靠 worker 的
            // _climate_wait_cv.notify_all，长片只保证等待方周期性重查
            // FAULTED/STOPPED/撤销这些终止条件 —— 故障路径通知的是 _control_cv，
            // 漏掉一次 notify 就会让主线程永远挂着。10 次/秒唤醒不是忙等。
            _climate_wait_cv.wait_for(lock, std::chrono::milliseconds(100));
        }
    }
}

void NativeSimulationHost::publish_climate_parity_divergence(
        const RuntimeClimateParityReport &diff) {
    _climate_parity_stage.store(diff.stage, std::memory_order_release);
    _climate_parity_cell.store(diff.cell, std::memory_order_release);
    store_atomic_text(_climate_parity_field, diff.field);
    store_atomic_text(_climate_parity_reference_bits, diff.reference_bits);
    store_atomic_text(_climate_parity_worker_bits, diff.worker_bits);
}

void NativeSimulationHost::clear_climate_parity_divergence() {
    _climate_parity_stage.store(0, std::memory_order_release);
    _climate_parity_cell.store(0, std::memory_order_release);
    store_atomic_text(_climate_parity_field, "");
    store_atomic_text(_climate_parity_reference_bits, "");
    store_atomic_text(_climate_parity_worker_bits, "");
}

void NativeSimulationHost::accumulate_climate_parity_fields(
        int64_t day, const RuntimeClimateStore &reference,
        const RuntimeClimateStore &worker) {
    const size_t field_count = runtime_climate_parity_field_count();
    if (field_count > RUNTIME_CLIMATE_PARITY_MAX_FIELDS) return;
    // Reused across days so a 1000-day run does not allocate per day.
    static thread_local std::vector<RuntimeClimateParityFieldDiff> diffs;
    diffs.resize(RUNTIME_CLIMATE_PARITY_MAX_FIELDS);
    runtime_climate_parity_field_divergence(reference, worker, diffs.data(),
                                           diffs.size());
    const RuntimeClimateParityField *table = runtime_climate_parity_fields();
    for (size_t i = 0; i < field_count; ++i) {
        ClimateParityFieldAccumulator &slot = _climate_parity_field_stats[i];
        if (table[i].comparability !=
            RuntimeClimateParityComparability::COMPARABLE) {
            continue;
        }
        const RuntimeClimateParityFieldDiff &diff = diffs[i];
        slot.compared_days.fetch_add(1, std::memory_order_relaxed);
        slot.last_diverged_cells.store(diff.diverged_cells,
                                       std::memory_order_relaxed);
        slot.last_out_of_band_cells.store(diff.out_of_band_cells,
                                          std::memory_order_relaxed);
        if (diff.out_of_band_cells != 0) {
            slot.out_of_band_days.fetch_add(1, std::memory_order_relaxed);
            slot.out_of_band_cells.fetch_add(diff.out_of_band_cells,
                                             std::memory_order_relaxed);
            double previous_band = slot.max_out_of_band_delta.load(std::memory_order_relaxed);
            while (diff.max_abs_delta > previous_band &&
                   !slot.max_out_of_band_delta.compare_exchange_weak(
                       previous_band, diff.max_abs_delta,
                       std::memory_order_relaxed, std::memory_order_relaxed)) {
            }
            if (slot.first_out_of_band_day.load(std::memory_order_relaxed) < 0) {
                slot.first_out_of_band_day.store(day, std::memory_order_release);
            }
        }
        if (diff.diverged_cells == 0) continue;
        slot.diverged_days.fetch_add(1, std::memory_order_relaxed);
        slot.diverged_cells.fetch_add(diff.diverged_cells,
                                      std::memory_order_relaxed);
        double previous_delta = slot.max_abs_delta.load(std::memory_order_relaxed);
        while (diff.max_abs_delta > previous_delta &&
               !slot.max_abs_delta.compare_exchange_weak(
                   previous_delta, diff.max_abs_delta,
                   std::memory_order_relaxed, std::memory_order_relaxed)) {
        }
        // Only the first divergence carries diagnostic value: later days are
        // already downstream of it, so do not overwrite the evidence.
        if (slot.first_diverged_day.load(std::memory_order_relaxed) >= 0) continue;
        slot.first_cell.store(diff.first_cell, std::memory_order_relaxed);
        store_atomic_text(slot.first_reference_bits, diff.reference_bits);
        store_atomic_text(slot.first_worker_bits, diff.worker_bits);
        slot.first_diverged_day.store(day, std::memory_order_release);
    }
}

void NativeSimulationHost::reset_climate_parity_fields() {
    _climate_parity_forced_days.store(0, std::memory_order_release);
    for (ClimateParityFieldAccumulator &slot : _climate_parity_field_stats) {
        slot.diverged_days.store(0, std::memory_order_relaxed);
        slot.compared_days.store(0, std::memory_order_relaxed);
        slot.diverged_cells.store(0, std::memory_order_relaxed);
        slot.out_of_band_cells.store(0, std::memory_order_relaxed);
        slot.out_of_band_days.store(0, std::memory_order_relaxed);
        slot.first_out_of_band_day.store(-1, std::memory_order_relaxed);
        slot.first_cell.store(0, std::memory_order_relaxed);
        slot.last_diverged_cells.store(0, std::memory_order_relaxed);
        slot.last_out_of_band_cells.store(0, std::memory_order_relaxed);
        slot.max_abs_delta.store(0.0, std::memory_order_relaxed);
        slot.max_out_of_band_delta.store(0.0, std::memory_order_relaxed);
        store_atomic_text(slot.first_reference_bits, "");
        store_atomic_text(slot.first_worker_bits, "");
        slot.first_diverged_day.store(-1, std::memory_order_release);
    }
}

NativeSimulationHost::ClimateParityFieldStatus
NativeSimulationHost::climate_parity_field_status(size_t index) const {
    ClimateParityFieldStatus out;
    if (index >= _climate_parity_field_stats.size()) return out;
    const ClimateParityFieldAccumulator &slot = _climate_parity_field_stats[index];
    out.diverged_days = slot.diverged_days.load(std::memory_order_acquire);
    out.compared_days = slot.compared_days.load(std::memory_order_acquire);
    out.diverged_cells = slot.diverged_cells.load(std::memory_order_acquire);
    out.out_of_band_cells = slot.out_of_band_cells.load(std::memory_order_acquire);
    out.out_of_band_days = slot.out_of_band_days.load(std::memory_order_acquire);
    out.first_diverged_day = slot.first_diverged_day.load(std::memory_order_acquire);
    out.first_out_of_band_day =
        slot.first_out_of_band_day.load(std::memory_order_acquire);
    out.first_cell = slot.first_cell.load(std::memory_order_acquire);
    out.last_diverged_cells = slot.last_diverged_cells.load(std::memory_order_acquire);
    out.last_out_of_band_cells =
        slot.last_out_of_band_cells.load(std::memory_order_acquire);
    out.max_abs_delta = slot.max_abs_delta.load(std::memory_order_acquire);
    out.max_out_of_band_delta =
        slot.max_out_of_band_delta.load(std::memory_order_acquire);
    for (size_t i = 0; i < slot.first_reference_bits.size(); ++i) {
        out.first_reference_bits[i] =
            slot.first_reference_bits[i].load(std::memory_order_relaxed);
    }
    for (size_t i = 0; i < slot.first_worker_bits.size(); ++i) {
        out.first_worker_bits[i] =
            slot.first_worker_bits[i].load(std::memory_order_relaxed);
    }
    out.first_reference_bits[sizeof(out.first_reference_bits) - 1u] = '\0';
    out.first_worker_bits[sizeof(out.first_worker_bits) - 1u] = '\0';
    return out;
}

bool NativeSimulationHost::publish_climate_reference(
        int64_t day, uint64_t reference_state_hash,
        std::string &error,
        RuntimeClimateReferencePublish publish) {
    if (day < 0 || reference_state_hash == 0) {
        error = "climate_trace_reference_invalid";
        return false;
    }
    // A state whose own reduction disagrees with the published hash would make
    // every later comparison meaningless, so reject the pair rather than
    // storing an inconsistent frame.
    if (publish.reference_store != nullptr &&
        publish.reference_store->parity_hash() != reference_state_hash) {
        error = "climate_trace_reference_state_hash_inconsistent";
        return false;
    }
    uint64_t input_hash = 0;
    if (!_climate_trace.input_hash_for_day(day, input_hash)) {
        error = "climate_trace_reference_frame_missing";
        return false;
    }
    if (!_climate_trace.mark_reference_ready(
            day, input_hash, reference_state_hash, error, std::move(publish))) {
        return false;
    }
    const bool ready = _climate_trace.mark_consumable(day, error);
    if (ready) {
        _climate_trace_signal.fetch_add(1, std::memory_order_acq_rel);
        _control_cv.notify_all();
    }
    return ready;
}

} // namespace pk
