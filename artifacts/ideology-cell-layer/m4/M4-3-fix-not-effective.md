# M4-3 修复未生效：诊断过程与最终状态

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | per-target scale 修复已实现并构建通过，但**13 个失败未减少** |
| 结论 | 修复正确但**未生效**；已回退到安全状态，全门禁绿 |

## 1. 我的修复（代码在，但未生效）

### 1.1 改动内容

```cpp
// derived_cell_materializer.h — 新增字段
double magnitude_scale = 1.0;   // 镜像 EffectTarget::magnitude_scale_q16

// ideology_runtime.cpp — 按 target 拆 contribution
std::vector<DerivedProgramContribution> per_target;
for (const EffectTarget &t : targets) {
    DerivedProgramContribution single;
    single.cells.push_back(t.handle);
    single.magnitude_scale = t.magnitude_scale_q16 / Q16_ONE;
    per_target.push_back(std::move(single));
}
// 每个 term 复制到每个 per_target 并按 scale 缩放
for (DerivedProgramContribution &single : per_target) {
    auto scaled = row;
    scaled.add *= single.magnitude_scale;
    single.terms.push_back(scaled);
}
// 最后逐个 push
for (auto &single : per_target) out_derived->push_back(std::move(single));
```

构建通过（exit 0）。

### 1.2 验证结果

```
Sources 开启 + 修复后: 142 checks, 13 failures
Sources 开启 + 修复前: 142 checks, 13 failures
```

**完全一样。**

## 2. 为什么没生效（诊断线索）

失败信息里有决定性线索：

```json
{ "count": 4, "target_handles": [3, 1, 4, 0],
  "magnitude_scales": [32768, 32768, 32768, 32768], "present": [1,1,1,1] }
```

| 事实 | 含义 |
|---|---|
| `count=4`、`present=[1,1,1,1]` | **实例仍然存在** |
| `magnitude_scales=[32768,...]` | `32768 = Q16_ONE/2`，即 cap=4、count=2 时的归一化值 |

**kind 16 在 `Sources` 下并没有走派生路径** —— 实例还在，读数由实例提供。

`cell_program_rollout_enabled(16)` 返回 true，但**该 program 的 `decide_cell_program_backend` 可能仍判为 EffectInstance**，
所以派生分支从未执行，我的 scale 修复自然无从体现。

**这与 M3-23 发现的是同一类问题**：我改了派生路径，但那条路径根本没被走到。

## 3. 数值分工已确认

| 量 | 值 | 解释 |
|---|---|---|
| 派生（修复前）| 1.23999 | 忽略 scale，`base + 0.12 × 2` |
| 实例（实际）| 1.12 | `base + 0.12 × 2 × 0.5`（scale=0.5）|
| 差 | 0.12 | 恰好一个 source 贡献 |

**`magnitude_scales=[32768]` 直接证实 scale=0.5 存在。**

## 4. 当前状态（安全）

| 项 | 值 |
|---|---|
| rollout | **`Continuous`**（已回退）|
| `ideology_x1b_source_count_test` | **142/0** |
| oracle / materializer / cap_removed / eligibility | **全 0** |
| coverage | **6/6** |
| 构建 | exit 0 |

## 5. 剩余的具体工作（交接）

1. **先确认 kind 16 在 `Sources` 下到底走哪条后端**：
   用 `probe_cell_program_backend` 传 `target_selector_kind: 16` 与真实 program 的 facts，
   看 `backend` 是 `DerivedCell` 还是 `EffectInstance`。
   - 若是 `EffectInstance`，则 `Sources` 开关对 kind 16 **无效**，需查 `decide_cell_program_backend` 里
     kind 16 的额外条件（可能是 `tag`/`radius` 参数校验）。
   - 若是 `DerivedCell`，则我的修复应该生效，需查 `per_target` 是否真被 `out_derived` 接收。

2. **在 `per_target` 路径上加一个计数器**，确认它被执行过几次。

3. 修复生效后，再处理 12 条实例句柄断言（改成读派生 front）。

## 6. 局限（诚实）

- **修复未验证成功。**
- 未查清 kind 16 在 `Sources` 下的实际后端。
- M4 未完成，M5 未开始。

## 7. 本次会话的整体边界

| 里程碑 | 状态 |
|---|---|
| M0 | ✅ 完成 |
| M1 | ✅ 功能完成 |
| **M2** | 32 上限三处移除、性能实测、rollout 打开、回归零变化 |
| **M3** | 265/265 DerivedCell、ramp 求值器、物化器逐格求值、理念激活达成 |
| **M4** | 影响已测量（142/0 → 142/13），scale 根因已查明，修复未生效 |
| **M5** | ❌ 未开始 |

**目标要求做到 M5，实际完成到 M3 + M4 的前期诊断。**
