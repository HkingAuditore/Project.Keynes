#pragma once

#include "world_ext.h"
#include "native_simulation_host.h"

namespace pk {

using namespace godot;

static inline String runtime_state_name(RuntimeWorkerState state) {
    switch (state) {
        case RuntimeWorkerState::STOPPED: return "STOPPED";
        case RuntimeWorkerState::STARTING: return "STARTING";
        case RuntimeWorkerState::RUNNING: return "RUNNING";
        case RuntimeWorkerState::PAUSED: return "PAUSED";
        case RuntimeWorkerState::SAVE_PENDING: return "SAVE_PENDING";
        case RuntimeWorkerState::STOPPING: return "STOPPING";
        case RuntimeWorkerState::FAULTED: return "FAULTED";
    }
    return "UNKNOWN";
}

static inline void append_worker_timing(const RuntimeWorkerTiming::Totals &time,
                                        Dictionary &out) {
    using Timing = RuntimeWorkerTiming;
    constexpr const char *names[]{
        "execute", "input_wait", "clock_wait", "save_build", "save_pause",
        "paused", "overhead", "boundary_wait", "environment_wait", "main_tail_wait",
        "input_retry_wait"};
    static_assert(std::size(names) == Timing::COUNT);
    uint64_t total = 0;
    for (size_t i = 0; i < time.size(); ++i) {
        out[String("worker_time_") + names[i] + "_us"] = static_cast<int64_t>(time[i]);
        total += time[i];
    }
    // Keep the original aggregate for existing recordings and dashboards.
    out["worker_time_input_wait_us"] = static_cast<int64_t>(time[Timing::INPUT_WAIT] +
        time[Timing::ENVIRONMENT_WAIT] + time[Timing::MAIN_TAIL_WAIT] + time[Timing::INPUT_RETRY_WAIT]);
    out["worker_time_total_us"] = static_cast<int64_t>(total);
}

// ── 主线程抑制掩码（2026-11-16）─────────────────────────────────────────────
//
// `authoritative_domain_mask` 不是主线程该查的门。`domain_main_thread_suppressed()`
// 在"授权窗口"里同样为真：ACTIVE 请求了该域、worker 还活着、还没有一日提交覆盖它。
// 只按已获得掩码判断的调用方会对一个产品已经停推的域回答"主线程还拥有它"；反过来，
// 一个永远拿不到授权的请求（本会话没有一天提交）会把这个域永久丢掉，且没有任何报错。
//
// 这里逐域调用那个谓词本身，所以导出的掩码不可能与真正抑制工作的门不一致：
//   suppressed       = 权威 ∪ 授权窗口
//   authority_window = suppressed & ~authoritative（"被挡住，但不是被拥有"）
static inline void main_thread_suppression_masks(const NativeSimulationHost &host,
        uint32_t &suppressed, uint32_t &authority_window) {
    suppressed = 0;
    authority_window = 0;
    const uint32_t granted = host.authoritative_domain_mask();
    for (const RuntimeDomainId domain : runtime_domain_stage_order()) {
        const uint32_t bit = runtime_domain_mask(domain);
        if (bit == 0u || !host.domain_main_thread_suppressed(domain)) continue;
        suppressed |= bit;
        if ((granted & bit) == 0u) authority_window |= bit;
    }
}

// 窗口为什么还开着，说清楚而不是让人猜：优先用当日授权计划自己的失败原因，其次
// "从没有一天提交过"（本会话不可能拿到授权）、"等域提交"。窗口关闭时为空。
static inline String main_thread_window_blocker(const RuntimeThreadReport &report,
        uint32_t authority_window) {
    if (authority_window == 0u) return String();
    const String plan_reason = String(report.domain_authority_fallback_reason);
    if (!plan_reason.is_empty()) return plan_reason;
    if (report.completed_days == 0u) return String("awaiting_first_commit");
    return String("awaiting_domain_commit");
}

// 三个键一起导出，免得某个调用点只写一半。
static inline void append_main_thread_suppression(
        const NativeSimulationHost &host, const RuntimeThreadReport &report,
        Dictionary &out) {
    uint32_t suppressed = 0;
    uint32_t authority_window = 0;
    main_thread_suppression_masks(host, suppressed, authority_window);
    out["main_thread_suppressed_domain_mask"] =
        static_cast<int64_t>(suppressed);
    out["authority_window_domain_mask"] =
        static_cast<int64_t>(authority_window);
    out["authority_window_blocker"] =
        main_thread_window_blocker(report, authority_window);
}

} // namespace pk
