# M3-12 rollout 首次打开 + 真实世界验证受阻

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | **`kCellProgramRollout` 从 `Off` 改为 `Continuous`**；`ideology_ramp_realworld_test.gd` |
| 结果 | rollout 已开；但真实世界验证被**三层前置**挡住，未取得 ramp 实际值 |
| 结论 | 打开 rollout 是本轮实质进展；验证缺口仍在 |

## 1. rollout 首次打开

```cpp
// 改前
inline constexpr CellProgramRollout kCellProgramRollout = CellProgramRollout::Off;

// 改后
inline constexpr CellProgramRollout kCellProgramRollout =
    CellProgramRollout::Continuous;
```

`Continuous` 只开放 `selector_kind == 12`（`OWN_TERRITORY`），正是 M2/M3 拥有的 A–F 批次。

**这是自 M1 以来第一次让派生层真正驱动生产路径。** 之前 265 个 program 只是「具备能力」。

## 2. 但 `seen=0`，派生层仍然是空的

真实世界测试跑 3 天后：

```
[ramp-rw] visits=3 taken=0 memoised=0 evaluated=0 deferred=0
[ramp-rw] materialise seen=0 derived=0 legacy=0 truncated=0
```

`visits=3` 说明重建在跑，但 `seen=0` 说明**贡献列表为空**。

根因（读代码确认）：

```cpp
// ideology_runtime.cpp:6692-6693
for (const IdeaState &state : country.ideas) {
    if (state.location == INACTIVE || state.level < 0) continue;
```

**生成世界的国家没有任何已采纳的理念**，所以循环立即跳过。这不是缺陷——开局本来就没有卡。

## 3. 我尝试补上理念，撞到三个 API 缺失

要验证必须先在夹具里授予一张 ramp 卡。协议从 `ideology_card_content_test.gd:651-688` 读到（`op 1` discover / `op 5` equip / `op 8` understanding，且必须 day 0 提交并从 day 0 结算，否则永远 PENDING）。

| 我的调用 | 结果 |
|---|---|
| `ext.get_ideology_catalog()` | `Nonexistent function` |
| `ext.get_ideology_catalog_ids()` | 不存在 |

理念 id 的实际格式是 `idea.<key>`（`ideology_card_content_test.gd:215`），但**没有桥把编译后目录的 ids 暴露给 GDScript**。

## 4. 我停在这里的理由

每次真实世界运行需要 **约 10 分钟**（`generate_world` 6144 格占绝大部分）。这一轮我跑了 3 次，其中 2 次因 API 名称猜错而浪费。

**继续猜测的成本太高。** 正确的下一步是：

1. 先读清楚「GDScript 侧如何拿到理念 dense id」——`ideology_card_content_test.gd` 是通过 catalog 的 `ids` 数组（GDScript 侧的 Resource，不是 native 桥）；
2. 在本探针里用同样的方式构造 catalog，或者加一个最小的 `get_ideology_catalog_ids()` 桥；
3. 再跑一次。

**这不是"再试一次"能解决的**，需要先补一个桥或换一条取 id 的路径。

## 5. 本轮实质进展

| 项 | 值 |
|---|---|
| rollout 状态 | **`Off` → `Continuous`** |
| 首次让派生层驱动生产 | ✅ |
| 构建 | exit 0 |
| 真实世界重建运行 | ✅ `visits=3` |
| 真实世界派生贡献 | ❌ `seen=0`（无已采纳理念）|

## 6. 必须标注的风险

**打开 rollout 是有行为后果的。** `cell_program_eligibility.h:153-158` 的注释明确警告：

> 提前打开某个 kind 不是 no-op：该 kind 的每个 program 都停止创建实例，而现有测试正是断言这些实例。

我尚未跑完整回归确认影响。**这是本轮欠下的最重要一项验证。**

## 7. 局限

- 未取得 24 个 ramp 的真实数值。
- **未跑回归**，rollout 打开的行为后果未知。
- `ideology_ramp_realworld_test.gd` 仍会在 dense < 0 时提前退出。
- 未验证 `Continuous` 是否让 M2 的常数 program 也切换（`Constants` 与 `Continuous` 当前开放同一 kind，所以**是的**——这一点需要在回归里确认无损）。

## 8. 下一步（明确）

1. **先跑完整回归**，确认 rollout `Continuous` 没有破坏既有断言——这是打开开关后必须做的第一件事；
2. 再补理念 id 的获取路径，取得 ramp 真实值；
3. 若回归有损，评估回退到 `Constants` 或修断言。

## 9. 复算方式

```powershell
Select-String -Path 'gdext/src/cell_program_eligibility.h' -Pattern 'kCellProgramRollout ='
# => CellProgramRollout::Continuous
```
