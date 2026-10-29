# 里程碑总览 — M0..M5 实际进度

| 里程碑 | 状态 | 说明 |
|---|---|---|
| **M0** 基线/可重建性 | ✅ 完成 | 11 份报告；288/272/265/325 计数；5 个 SHA-256 字节一致 |
| **M1** 共享 IR / 求值核 / 派生层 | ✅ **功能完成**（性能验证见下） | 13 份报告；判定器 56、容器 51、物化器 65、oracle 735、分片 56 |
| **M2** A/B 141 program | 🟡 **部分完成** | 32 上限三处移除、性能实测、3/11 集成测试 |
| **M3** C/D 194 program | 🟡 **已开工** | ramp 结构已就位；采样与求值未接 |
| **M4** E/F 265 program | ❌ 未开始 | 71 个来源类 program |
| **M5** 生产切换/清理 | ❌ 未开始 | rollout ON、旧平面删除、最终证据 |

## M2 的准确状态

| 项 | 状态 |
|---|---|
| 代码常量拆分 | ✅ `selector_cell_cap_test` 35 checks |
| 194 处内容改 `(0,0)` | ✅ `cap_removed` 12 checks |
| 两层校验放宽 | ✅ `ceiling_test` 19 checks |
| 性能实测 | ✅ 800 格 p50 4.516 ms / 2000 格 p50 11.982 ms |
| §14.3 单 slice | ✅ 0.841 ms < 1.0，余量 15.9% |
| **rollout ON** | ❌ 仍 `Off`，运行时行为未变 |
| **§13.4 集成测试** | 🟡 3/11（catalog、unbounded、numeric） |

## M3 已完成的（本轮）

`derived_cell_materializer.h` 增加：

```cpp
enum class MagnitudeSource : uint8_t { Constant = 0, RampMetric = 1 };
struct Term {
    ...
    MagnitudeSource magnitude_source = MagnitudeSource::Constant;
    int32_t metric_id = -1;       // < 0 = none (0 is a legal metric id)
    double ramp_scale = 1.0;
    double ramp_floor = 0.0;
    double ramp_ceil = 0.0;
    bool ramp_has_ceil = false;
};
inline double evaluate_ramp_magnitude(const Term&, double metric_value);
```

构建通过，5 项门禁无回归。

## M3 尚未完成的

| 项 | 阻塞/说明 |
|---|---|
| `collect_effect_activations` 生成 ramp term | 需要把指令序列解析成 `metric_id` + 上下限 |
| 物化器的 metric 采样接线 | `sample_effect_metrics` 可能要求 epoch；**未验证** |
| 逐格求值替换常数折叠 | 核心改动，未做 |
| 国家级 metric 的每国一次优化 | 未设计 |
| M3 的 6 个退出条件 | 全部未验证 |

## M4 / M5 的范围（已读，未做）

**M4**：E=66 来源计数、F=5 来源环并集，要求「100+ 来源与 r=1–4、重叠、count cap、跨国边境、所有生产 program 数值通过；逐来源整图清零消失」。

**M5**：生产切换、清理、最终证据 —— 包括 rollout ON、删除旧 `_ideology_cell_programs` 平面、以及 §13/§14 全门禁。

## 需要如实说明的依赖

M3 的「逐格 ramp 数值不同且正确」（§15.5 退出条件）需要**按格采样 metric**，而 `sample_effect_metrics` 依赖经济的逐格状态（失业率、制造业建筑数）。这些状态在无 epoch 时为空。

**这与贯穿 M1..M2 的端到端缺口是同一件事**：真实 `generate_world` + worker 协作夹具。

M4 的「跨国边境、逐来源整图清零」同样依赖真实多国领土。

所以：**M3/M4 的可验证性高度依赖那个尚未建成的夹具。** 我可以继续实现代码路径，但退出条件可能无法验证。
