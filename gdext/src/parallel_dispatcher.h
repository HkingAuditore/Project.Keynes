#pragma once
//
// Phase C.3 — ParallelDispatcher (dots-total-cpp roadmap)
//
// 统一封装现有 5 个手写 _thread 模板（pass_a_full / pass_a_indexed / pass_b /
// ocean_water / ocean_land）的样板代码：
//   1. 计算 n_tasks（自适应或 caller 指定）
//   2. 小规模降级（n < seq_thresh 直接顺序，避免固定池调度开销）
//   3. 固定 NativeParallelExecutor 缺失/交互限流时的顺序 fallback
//   4. 固定线程池 group barrier + 确定性 task index 归并
//
// 设计约束（非常重要）：
//   - 必须 header-only template，hot path 零 std::function / virtual 开销
//   - run_range 闭包接受 (begin, end)；分块策略 chunk = ceil(n / n_tasks)
//     与现有 pass_b_land_worker / ocean_water_worker 完全一致（line 4054-4056 等）
//   - WTP 缺失时仍调用闭包，确保 single-threaded fallback 与多线程 bit-equal
//   - 顺序 fallback 路径：begin=0, end=n（与 pass_b_run_land_range(0, n_land)
//     等单线程入口完全一致；不分段，避免 chunk 边界引入差异）
//
// 与现有手写实现的对应关系：
//   - pass_b_thread (line 4310-4350)        → parallel_for_range("pk_pass_b_land", n_land, ..., run)
//   - ocean_water_thread (line 4625-4665)   → parallel_for_range("pk_ocean_water", n_water, ..., run)
//   - ocean_land_thread (line 4905-4940)    → parallel_for_range("pk_ocean_land", n_land, ..., run)
//   - bench_pass_a_full_thread (line 13134) → parallel_for_range("pk_pass_a_full", count, ..., run)
//   - bench_pass_a_indexed_thread (line 13208) → parallel_for_range("pk_pass_a_idx", n_dirty, ..., run)
//
// 非目标：
//   - 不处理 thread-local emit list（C.3d 单独扩展，sea_ice flip / veg_dyn succession）
//   - 不处理 scatter（C.3 不动 transpiration）

#include <algorithm>
#include <cstdint>
#include <type_traits>
#include <utility>
#include <vector>

#include "native_parallel_executor.h"

namespace pk {

// The executor is intentionally independent of Godot's WorkerThreadPool. This
// keeps the native simulation path free of Godot thread-affinity assumptions
// and makes the same deterministic fallback available on small/unsupported
// targets.
inline bool parallel_has_real_worker_threads() {
    return NativeParallelExecutor::instance().has_workers();
}

// 自适应 n_tasks：每 task ~1024 cells，clamp [1, 16]。
// 与 ocean_water_thread (line 4631) / ocean_land_thread (line 4908) 公式 1:1。
inline int parallel_default_n_tasks(int n) {
    if (n <= 0) return 1;
    int t = (n + 1023) / 1024;
    if (t < 1) t = 1;
    if (t > 16) t = 16;
    return t;
}

// run_range: void(int begin, int end) — 处理 [begin, end) 区间内的工作单元。
// label: diagnostic group name (not used by the native executor).
// n_tasks_hint: 0 = 自适应（推荐），>0 = caller 指定（兼容 bench_pass_a_*_thread 行为）
// seq_threshold: n < threshold 时直接同线程顺序跑（与 pass_b line 4324 / ocean_water line 4634 一致）
template <typename F>
inline void parallel_for_range(const char *label,
                               int n,
                               int n_tasks_hint,
                               int seq_threshold,
                               F &&run_range) {
    if (n <= 0) {
        return;
    }

    // 1) 计算 n_tasks
    int n_tasks = (n_tasks_hint > 0)
                      ? n_tasks_hint
                      : parallel_default_n_tasks(n);
    if (n_tasks < 1) n_tasks = 1;

    // 2) 小规模降级 / 单 task 直接顺序（与 ocean_water_thread line 4634 一致）
    if (n < seq_threshold || n_tasks == 1) {
        run_range(0, n);
        return;
    }

    // 3) WTP 缺失 / 无真实 worker 线程 fallback：按 task_idx 顺序在调用线程内跑
    //    （与 pass_b line 4336 "in-thread loop over the would-be tasks" 一致），
    //    保持调度等价。见 parallel_has_real_worker_threads() 顶部注释——Web
    //    nothreads 下 wtp 非空但没有线程消费任务，必须同等走这条回退路径，
    //    否则下面的 native group barrier 会在无 worker 目标上永久等待。
    NativeParallelExecutor &executor = NativeParallelExecutor::instance();
    if (!executor.has_workers()) {
        const int chunk = (n + n_tasks - 1) / n_tasks;
        for (int t = 0; t < n_tasks; ++t) {
            const int begin = t * chunk;
            const int end = std::min(begin + chunk, n);
            if (begin >= end) break;
            run_range(begin, end);
        }
        return;
    }

    // 4) 真并行：NativeParallelExecutor group + wait
    //    Trampoline：把 lambda 通过 userdata 传进 C ABI worker 函数。
    //    F 由 hot path 调用方持有（栈上），整个 parallel_for_range 期间存活，
    //    group barrier 返回后才出栈，无生命周期风险。
    //    注：当传入的是 lvalue lambda 时 F 推导为 lambda& 引用类型，
    //    Userdata 不能持有"指向引用的指针"，必须用 remove_reference_t 取裸类型。
    using FnT = std::remove_reference_t<F>;
    struct Userdata {
        FnT *fn;
        int n;
        int n_tasks;
    };
    Userdata ud{&run_range, n, n_tasks};

    auto worker = +[](void *userdata, uint32_t task_idx) {
        auto *u = static_cast<Userdata *>(userdata);
        const int chunk = (u->n + u->n_tasks - 1) / u->n_tasks;
        const int begin = static_cast<int>(task_idx) * chunk;
        const int end = std::min(begin + chunk, u->n);
        if (begin >= end) return;
        (*u->fn)(begin, end);
    };

    (void)label;
    executor.run_group(static_cast<uint32_t>(n_tasks), worker, &ud);
}

// 默认 seq_threshold=256（与现有手写实现一致）
template <typename F>
inline void parallel_for_range(const char *label, int n, F &&run_range) {
    parallel_for_range(label, n, /*n_tasks_hint=*/0, /*seq_threshold=*/256,
                       std::forward<F>(run_range));
}

// ─── Phase C.3d: parallel_for_range_with_emit ────────────────────────────
// 扩展 parallel_for_range，支持 thread-local emit + 串行 reduce。
// 适用于 sea_ice 的 flip lists（PackedInt32/ByteArray append + counter）和
// vegetation_dynamics 的 succession lists（std::vector push_back）。
//
// 顺序契约：每个 task 内部按 cell idx 升序遍历 → emit 自然有序；
// reduce 阶段按 task_idx (0, 1, 2, ...) 升序串行调用 Emit::merge_into，
// 最终全局 emit 顺序与 scalar 单线程版本完全一致 (bit-equal)。
//
// Emit 类型契约：
//   - 默认可构造（每个 task 启动时构造一个 thread-local 实例）
//   - 拥有成员：void merge_into(Emit &dst) const  // 把自己 append 到 dst
//   - 任意可拷贝/可移动字段（vectors / counters / etc.）
//
// run_range 闭包签名：void(int begin, int end, Emit &local_emit)
//   - 在 [begin, end) 区间内做 cell-local 计算 + 向 local_emit 写
//   - 不可访问 global_emit（保证无 race）
//
// global_emit 由 caller 传入，初始内容会被 task 0 的 merge_into 之前保留，
// 之后被各 task 顺序追加。seq fallback 路径直接跑一次 run_range(0, n, global)。
template <typename Emit, typename F>
inline void parallel_for_range_with_emit(const char *label,
                                         int n,
                                         int n_tasks_hint,
                                         int seq_threshold,
                                         Emit &global_emit,
                                         F &&run_range) {
    if (n <= 0) {
        return;
    }

    int n_tasks = (n_tasks_hint > 0)
                      ? n_tasks_hint
                      : parallel_default_n_tasks(n);
    if (n_tasks < 1) n_tasks = 1;

    // 小规模降级：直接在 caller 线程上跑一次 run_range，emit 直写 global。
    if (n < seq_threshold || n_tasks == 1) {
        run_range(0, n, global_emit);
        return;
    }

    // WTP 缺失 / 无真实 worker 线程 fallback（同上，见 parallel_has_real_worker_
    // threads() 顶部注释）：按 task_idx 顺序在调用线程内跑，每段一个 local emit
    // 然后串行 merge_into。与真并行路径 bit-equal。
    NativeParallelExecutor &executor = NativeParallelExecutor::instance();
    if (!executor.has_workers()) {
        const int chunk = (n + n_tasks - 1) / n_tasks;
        for (int t = 0; t < n_tasks; ++t) {
            const int begin = t * chunk;
            const int end = std::min(begin + chunk, n);
            if (begin >= end) break;
            Emit local;
            run_range(begin, end, local);
            local.merge_into(global_emit);
        }
        return;
    }

    // 真并行：每个 task 拥有独立 Emit，跑完后串行 reduce。
    // locals 数组在 caller 栈上，wait 完成前不出栈，无生命周期风险。
    using FnT = std::remove_reference_t<F>;
    struct Userdata {
        FnT *fn;
        Emit *locals;
        int n;
        int n_tasks;
    };

    // 用 std::vector<Emit> 承载 thread-local 实例（默认构造）。
    // n_tasks 上限为 16，分配开销可忽略。
    std::vector<Emit> locals(static_cast<size_t>(n_tasks));
    Userdata ud{&run_range, locals.data(), n, n_tasks};

    auto worker = +[](void *userdata, uint32_t task_idx) {
        auto *u = static_cast<Userdata *>(userdata);
        const int chunk = (u->n + u->n_tasks - 1) / u->n_tasks;
        const int begin = static_cast<int>(task_idx) * chunk;
        const int end = std::min(begin + chunk, u->n);
        if (begin >= end) return;
        Emit &local = u->locals[task_idx];
        (*u->fn)(begin, end, local);
    };

    (void)label;
    executor.run_group(static_cast<uint32_t>(n_tasks), worker, &ud);

    // 串行 reduce（task_idx 升序）— 与 cell idx 升序兼容，输出顺序 bit-equal。
    for (int t = 0; t < n_tasks; ++t) {
        locals[t].merge_into(global_emit);
    }
}

// 默认 seq_threshold=256
template <typename Emit, typename F>
inline void parallel_for_range_with_emit(const char *label,
                                         int n,
                                         Emit &global_emit,
                                         F &&run_range) {
    parallel_for_range_with_emit<Emit>(
        label, n, /*n_tasks_hint=*/0, /*seq_threshold=*/256,
        global_emit, std::forward<F>(run_range));
}

} // namespace pk
