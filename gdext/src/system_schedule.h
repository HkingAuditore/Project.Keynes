#pragma once
//
// Phase C.1（dots-total-cpp roadmap）：System schedule graph（静态 DAG）
//
// 目标 ─────────────────────────────────────────────────────────────────────
// 把 DCWorldExt::run_native_daily_tick 内部 line 960-1063 的 11 段手写
// `if (bundle.has("<X>_knobs")) { ms = run_<X>_pass(...); breakdown[...]=...; }`
// 模板代码抽象为：
//   1. 一份静态 SystemNode[] 数组（"调度图"），编译期决定节点集合与执行顺序
//   2. 一段通用执行 loop，遍历 SCHEDULE_GRAPH，逐节点 dispatch 到节点自带的
//      exec_fn 成员函数指针上
//
// 这次重构**不改**任何 pass 的算法、读写字段、breakdown 字段语义，因此输出
// dict 与原线性 if-chain 必须 bit-equal（A/B 1000-tick SAME_SOURCE 验证）。
//
// 双轨控制 ──────────────────────────────────────────────────────────────────
// GDScript 在 native_daily_bundle 中注入 "use_system_schedule": bool（默认
// false）。run_native_daily_tick 入口处取这个 flag：
//   - true  → 走 dispatch_system_schedule(this, bundle, tick_knobs, breakdown)
//   - false → 走 line 960-1063 原 11 段手写块（保留作为 Phase C.1 fallback）
// 任何 pass 内部 ms<0（fallback 触发）→ caller 调 finish_with_failure。
//
// 设计取舍 ──────────────────────────────────────────────────────────────────
// 1. 节点签名为 `bool (DCWorldExt::*)(bundle, tick_knobs, breakdown)`：
//    - 让每个 exec_fn 自洽（自己读 bundle key、自己累加 breakdown、自己写
//      side-effect 如 _native_fronts_snapshot）
//    - 避免在 SystemNode 里加大量"额外参数列表"（如 climate_pass_a 的 phase /
//      sea_ice 的 phase / weather 的 fronts 副作用 / stage_b 的 4 个 breakdown
//      回填）—— 5 个不规则点全部由节点自己处理，调度层零特例
//    - 失败约定：返回 false → caller finish_with_failure(node.fail_stage, ...)
// 2. SCHEDULE_GRAPH 是 static const POD 数组（编译期初始化）：
//    - 零运行期分配；C.3 job_graph 可直接基于这个数组做拓扑序 + 并行分组
//    - 顺序 = 当前线性 if-chain 顺序（climate_pass_a → ocean_water →
//      ocean_land → climate_pass_b → sea_ice → transpiration → albedo →
//      vegetation_dynamics → climate_feedback → stage_b → weather）
//    - in_mask / out_mask 暂用粗粒度"breakdown 分类"标签（climate / ocean /
//      stage_b / weather）；C.3 才用得上，C.1 不做并行所以暂不写
// 3. 不引入 World 字段级别的 mask 表：那是 C.3 真正并行化时的事；C.1 只是
//    "把 if-chain 数据驱动化"，避免过度设计
//
// 后续接力 ──────────────────────────────────────────────────────────────────
// - C.2 SoA chunk：每个 exec_fn 内的 run_<X>_pass 改 chunk 迭代器
// - C.3 job graph：在本文件加 in_mask / out_mask 字段，遍历 SCHEDULE_GRAPH
//   分组到 WorkerThreadPool

#include <godot_cpp/variant/dictionary.hpp>

namespace pk {

class DCWorldExt; // forward

struct SystemNode {
    const char* name;        // 调试日志用："climate_pass_a"
    const char* bundle_key;  // 在 native_daily_bundle 内的 key，如 "climate_pass_a_struct"
    const char* fail_stage;  // 失败时 finish_with_failure 第一参，如 "climate_pass_a"
    // 节点执行函数（DCWorldExt 成员指针）。返回 true=成功；false=触发 fallback。
    // 节点 *自己负责*：读 bundle[bundle_key]、调 run_<X>_pass、累加 breakdown、
    // 写 side-effect（如 _native_fronts_snapshot）。
    bool (DCWorldExt::*exec_fn)(const godot::Dictionary& bundle,
                                const godot::Dictionary& tick_knobs,
                                godot::Dictionary& breakdown);
};

// 静态调度图。定义在 system_schedule.cpp。节点顺序与 run_native_daily_tick
// line 960-1063 的原线性 if-chain 严格一致。
extern const SystemNode SCHEDULE_GRAPH[];
extern const int SCHEDULE_GRAPH_SIZE;

// 通用执行 loop。遍历 SCHEDULE_GRAPH，对每个 bundle.has(bundle_key) 的节点
// 调 exec_fn。返回值：
//   - rc = 0  → 全部节点成功（或被跳过），调用方继续 flush_slots_to_map 等
//   - rc = -1 → 某节点失败；fail_stage 写入 out_fail_stage（caller 用于
//               finish_with_failure 第一参）；out_any_pass_ran 已记录失败前
//               是否有节点成功跑过（caller 决定后续逻辑）
// 与原 line 960-1063 行为对齐：任意 pass 失败立即短路返回 -1。
int dispatch_system_schedule(DCWorldExt* self,
                             const godot::Dictionary& bundle,
                             const godot::Dictionary& tick_knobs,
                             godot::Dictionary& breakdown,
                             bool& out_any_pass_ran,
                             const char*& out_fail_stage);

} // namespace pk
