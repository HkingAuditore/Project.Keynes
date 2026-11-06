#include "native_simulation_day_context.h"
#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {

void NativeSimulationHost::prepare_climate_day(DayExecution &day) {
    auto &plan = day.plan;
    auto &environment = day.environment;
    auto &climate_hashed_input = day.climate_hashed_input;
    auto &climate_hashed_input_hash = day.climate_hashed_input_hash;
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    climate_authority_requested =
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) &
         runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
    active_climate_ok = false;
    if (climate_authority_requested) {
        if (environment == nullptr || !plan.context.freeze_reads.register_read(
                runtime_domain_mask(RuntimeDomainId::CLIMATE), plan.context.frozen_input,
                plan.context.day, plan.context.input_generation)) {
            const char *reason = "climate_freeze_input_version_invalid";
            for (size_t i = 0; i < _climate_pod_fallback_reason.size(); ++i) {
                _climate_pod_fallback_reason[i].store(
                    i < std::strlen(reason) ? reason[i] : '\0',
                    std::memory_order_release);
                if (i >= std::strlen(reason)) break;
            }
            return;
        }
        // 与 build_day_plan 使用同一不可变输入，重试不能重新读取 latest。
        RuntimeClimateVerticalReport climate_report{};
        // The environment day, not plan.context.day. Under authority the
        // published environment is Climate's only input and arrives one per
        // main-thread tick, whereas plan.context.day is `_committed_day + 1`
        // off this worker's own clock. Those two advance independently, and
        // `_committed_day` only moves when the day succeeds — so a single
        // mismatch used to be terminal: the worker stayed pinned on its day
        // while the environment ran ahead, and `environment.day != day` held
        // forever after. Climate then silently stopped computing while the
        // write-back kept publishing the stale store.
        const int64_t climate_day = environment != nullptr ? environment->day : -1;
        const int64_t climate_committed = _climate_authority.store().committed_day;
        // Whether this day actually ran the kernel. The worker retries the next
        // day immediately after a successful one and parks on the missing
        // environment, so an unconditional diagnostic store would overwrite the
        // day that computed with the empty report of the park that followed it —
        // which is why stage_work/state_hash/stage_mask all read as zero while
        // the kernel was demonstrably running.
        bool climate_day_computed = false;
        // Only drop ring slots the worker has truly finished with. Popping a
        // future day while the Host clock is pinned (later domain failed M5
        // after Climate already committed) permanently desyncs 0xFFF grants:
        // the original env is gone and every newer publish mismatches forever.
        bool consume_environment = false;
        // Holds a refreshed ring head after drain so `environment` never dangles.
        std::shared_ptr<const RuntimeEnvironmentSnapshot> environment_holder;
        if (plan.context.day <= climate_committed) {
            // Idempotent retry: Climate already advanced this worker day (or
            // past it) before a later domain failed the atomic COMMIT gate.
            // Reuse without requiring the original env generation — Country
            // has the same shape via committed_day skip.
            active_climate_ok = true;
            // Only drop envs at or behind the worker day. Popping through
            // climate_committed when it is ahead of plan.day erases futures
            // Host already published for the catch-up days and desyncs the
            // FIFO (worker then sees latest-or-empty and parks forever).
            const int64_t drain_through =
                climate_committed < plan.context.day ? climate_committed
                                                     : plan.context.day;
            const size_t drained =
                _environment_ring.pop_while_day_at_most(drain_through);
            if (drained > 0u) {
                environment_holder = _environment_ring.peek_oldest();
                environment = environment_holder.get();
                _climate_wait_cv.notify_all();
            }
            if (environment != nullptr && environment->day <= plan.context.day) {
                consume_environment = true;
            }
        } else if (environment == nullptr) {
            runtime_copy_text(climate_report.error, "climate_environment_missing");
        } else if (plan.context.day != climate_day ||
                   plan.context.input_generation != environment->generation) {
            runtime_copy_text(climate_report.error,
                              "climate_environment_day_mismatch");
            // Stale only. Keep newer days queued for when the worker advances.
            if (climate_day < plan.context.day) {
                consume_environment = true;
            }
        } else if (climate_day == climate_committed &&
                   environment->generation == _climate_committed_input_generation.load(
                       std::memory_order_acquire)) {
            // Country/Effect continuation 重试只复用同日同代成功提交，不重跑 Climate。
            active_climate_ok = true;
            consume_environment = true;
        } else if (climate_day <= climate_committed) {
            runtime_copy_text(climate_report.error, "climate_input_commit_mismatch");
            consume_environment = true;
        } else if (_climate_authority.plan_day(climate_day, *environment,
                                               climate_report,
                                               /*compute_hashes=*/false,
                                               /*validate_input=*/false)) {
            climate_day_computed = true;
            active_climate_ok = _climate_authority.commit_day(climate_day,
                                                              climate_report);
            if (active_climate_ok) {
                climate_hashed_input = environment;
                climate_hashed_input_hash = climate_report.input_hash;
                _climate_committed_input_generation.store(environment->generation,
                                                          std::memory_order_release);
                _climate_committed_day.store(climate_day,
                                             std::memory_order_release);
                consume_environment = true;
            } else {
                _climate_authority.discard_plan();
                // Keep the matching env for an immediate kernel retry.
            }
        } else {
            climate_day_computed = true;
            _climate_authority.discard_plan();
            // Plan rejected the matching frame; keep it so a corrected retry
            // (or diagnostic) can still observe the same generation.
        }
        // B8 P0：消费游标只在真正处理完该代输入时前进。提前弹出未来日会让
        // 主线程以为已送达，worker 却永远对不上 pinned 的 plan.day。
        if (environment != nullptr && consume_environment) {
            _climate_consumed_generation.store(environment->generation,
                                               std::memory_order_release);
            // B8 P3：FIFO 弹出已评估的最旧输入，给主线程腾出 ring 空位。
            _environment_ring.pop_generation(environment->generation);
            // 只有"第一次看到这一代"才算消费了一天；失败/挂起天的重试会反复评估
            // 同一份环境，把它们计数会把 delivered 指标变成重试计数器。
            uint64_t last_counted =
                _climate_last_counted_generation.load(std::memory_order_relaxed);
            while (environment->generation > last_counted &&
                   !_climate_last_counted_generation.compare_exchange_weak(
                       last_counted, environment->generation,
                       std::memory_order_relaxed)) {
            }
            if (environment->generation > last_counted) {
                _environment_consumed_days.fetch_add(1,
                                                     std::memory_order_relaxed);
            }
            // 等待方在 _climate_wait_cv 上等这个游标，必须显式唤醒。用专用 CV：
            // _control_cv 上还挂着 worker 自己的 preflight 重试等待。
            _climate_wait_cv.notify_all();
        }
        if (climate_day_computed) {
            if (!active_climate_ok) {
                set_fault(climate_report.error[0] != '\0'
                    ? climate_report.error : "climate_commit_failed");
            }
            _climate_pod_ready.store(active_climate_ok, std::memory_order_release);
            _climate_pod_plan_ms.store(climate_report.plan_ms,
                                       std::memory_order_release);
            _climate_pod_replay_ms.store(climate_report.replay_ms,
                                         std::memory_order_release);
            _climate_pod_work_units.store(climate_report.work_units,
                                          std::memory_order_release);
            _climate_pod_changed_cells.store(climate_report.changed_cells,
                                             std::memory_order_release);
            _climate_pod_state_hash.store(climate_report.state_hash,
                                          std::memory_order_release);
            for (size_t s = 0; s < _climate_stage_ms.size() &&
                               s < climate_report.stage_ms.size(); ++s) {
                _climate_stage_ms[s].store(climate_report.stage_ms[s],
                                           std::memory_order_relaxed);
                _climate_stage_work[s].store(climate_report.stage_work[s],
                                             std::memory_order_relaxed);
            }
            _climate_worker_stage_mask.store(climate_report.worker_stage_mask,
                                            std::memory_order_release);
            _climate_cyclone_alive.store(climate_report.cyclone_alive,
                                         std::memory_order_release);
            _climate_cyclone_injected.store(climate_report.cyclone_injected,
                                            std::memory_order_release);
            _climate_cyclone_replaced.store(climate_report.cyclone_replaced,
                                            std::memory_order_release);
            _climate_cyclone_decayed.store(climate_report.cyclone_decayed,
                                           std::memory_order_release);
            _climate_cyclone_touched.store(climate_report.cyclone_touched,
                                           std::memory_order_release);
        }
        // Nothing to compare against under authority; keep the parity slots
        // explicitly empty rather than leaving the last SHADOW day's verdict
        // sitting in the report as if it still applied.
        _climate_production_stage_mask.store(0, std::memory_order_release);
        _climate_pod_parity_compared.store(false, std::memory_order_release);
        _climate_pod_parity_matched.store(false, std::memory_order_release);
        // Parking on an unpublished environment is the steady state between two
        // main-thread ticks, not a fault. Reporting it here would bury the last
        // real kernel error under a reason that is present on almost every day.
        if (climate_day_computed) {
            for (size_t s = 0; s < _climate_pod_fallback_reason.size(); ++s) {
                _climate_pod_fallback_reason[s].store(climate_report.error[s],
                                                      std::memory_order_release);
                if (climate_report.error[s] == '\0') break;
            }
        }
    }
}

bool NativeSimulationHost::stage_climate(DayExecution &day, RuntimeDomainPlan &stage) {
    auto &commit = day.commit;
    auto &active_climate_ok = day.active_climate_ok;
    if (stage.domain == RuntimeDomainId::CLIMATE && active_climate_ok) {
        stage.dirty_families = RUNTIME_DIRTY_CLIMATE_FIELDS | RUNTIME_DIRTY_WEATHER;
        stage.work_units = _climate_pod_work_units.load(std::memory_order_relaxed);
        stage.completed = 1;
        commit.dirty_families |= stage.dirty_families;
        commit.work_units += stage.work_units;
        commit.completed_domain_mask |= runtime_domain_mask(stage.domain);
        ++commit.completed_stage_count;
        return true;
    }
    return true;
}
} // namespace pk
