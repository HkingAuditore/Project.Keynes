# M1-12 end-to-end pass & the tag requirement — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §13.1 第 4 层 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | e2e 夹具 **18 checks 0 failures**、`cell_layer_rebuild_*` 计数器、目标解析断点定位 |
| 结论 | e2e 已通过；**发现派生路径还依赖内容侧的 tag 选择器，之前完全没意识到** |

## 1. 上一轮的错误断言

M1-11 断言「`programs_seen > 0`，物化器必须看到卡」，结果失败。

**那条断言是错的。** `kCellProgramRollout = Off` 时，`cell_program_rollout_enabled()` 返回 false，派生分支不进入，所以物化器收到空列表——这是**闸门按设计工作**，不是缺陷。

我加了两级诊断才确认这一点：

```
[derived] countries=1  handle=4294967296  ideas=1
[derived]   idea id=60  loc=1 (IDEOLOGY)  level=0
```

遍历确实到达了卡。断言改为：

- 物化器**已运行**（`cell_layer_rebuild_visits > 0`）；
- 卡**是活的**（`managed_idea_count > 0`）；
- `Off` 下 `programs_seen == 0` 是**正确结果**。

## 2. 新增计数器（本轮的主要工程产出）

| 计数器 | 语义 |
|---|---|
| `cell_layer_rebuild_visits` | `rebuild_derived_cell_layer` 的**调用次数** |
| `cell_layer_rebuild_skips` | 内容相同被跳过的次数（I13） |
| `cell_layer_rebuild_ms` | 累计耗时 |

**命名必须区别于既有的 `_derived_rebuild_visits`**（`ideology_runtime.h:979`）——那是一个**无关的 idea 迭代计数器**。我第一次复用了同名成员，两个计数器静默共用一个字段。这属于「错误能编译、语义已损坏」的类型。

这三个计数器的价值在于：能区分「跑了但没找到」和「压根没跑」。上一轮正是无法区分二者，才多花一整轮定位 `last_error`。

## 3. 决定性发现：`targets_ok=0`

临时诊断打出了完整的判定链：

```
[prog] key=ideology.effect.kin_hearth_l1  domain=2  selector=12
       targets_ok=0  n=0   rollout=1  derived=1
```

`derived=1` 且 `rollout=1` 说明**判定器与闸门都正确**，卡确实是派生卡。断点在**目标格解析**：`resolve_effect_targets` 返回 false，贡献从未生成。

继续追到内容侧：

```
target_domain       = 2
target_selector_kind = 12          (OWN_TERRITORY)
target_selector_param = (32, 0)    ← 32 正是要取消的那个上限
target_selector_tag   = &"cell.clan"
```

**这条卡的派生路径要求格上有 `cell.clan` tag。** 我的 stub 世界没有，所以 `collect_effect_target_cells` 返回空。

## 4. 这对方案的含义

这是本迁移的一个**此前完全没有记录的前提**：

> 派生路径生效不仅取决于「卡是常数 + 永久 + cell 域」，还取决于**目标选择器能在真实世界里解析出非空格集**。

`target_selector_param = (32, 0)` 也说明内容侧确实把 32 硬编码进了选择器参数。取消上限不只是删代码，**内容里的 `32` 也需要随批次更新**，否则即使派生路径通了，选择器本身仍会截断到 32。

M0-1 记录的「selector 自身硬上限」与这里是同一件事。

## 5. 已加但未验证成功的一步

我尝试用 `set_cell_tag_override_for_test("cell.clan", cell, true)` 给全部格打标，**仍未使 `targets_ok` 变真**。可能原因（未证实）：

- override 只在 economy 采样 effect metrics 期间生效，理念运行时的解析路径读的是另一份 tag 快照；
- 或 `selector_param[1]`（tag 索引 0）与 `target_selector_tag` 字符串的映射在 stub 世界里未建立。

这条留给下一轮，**不猜测结论**。

## 6. 构建与验证

| 项 | 值 |
|---|---|
| 构建 | `scons: done building targets.`，exit 0 |
| e2e | **18 checks, 0 failures** |
| 物化器 | 65 checks, 0 failures |
| 判定器 | 56 checks, 0 failures |
| 分片 | 56 checks, 0 failures |
| 派生层 | 51 checks, 0 failures |
| 覆盖率门禁 | 6/6 |
| `kCellProgramRollout` | **恢复为 `Off`**（临时 ON 实验已还原） |

临时诊断（`PK_DEBUG_DERIVED` / `PK_DEBUG_PROGRAM`）**已全部移除**。

## 7. 局限

- **e2e 通过的是 `Off` 分支。** 它证明了「管线完整、闸门有效」，**没有**证明「ON 后行真的产生」——后者仍被 §3 的 tag 问题挡住。
- `set_cell_tag_override_for_test` 未生效，原因未证实。
- e2e 未纳入 15 fixture 基线（需完整 catalog 编译，单次约 30 s）。
- `ROLLOUT_OFF_EXPECTED` 与 `kCellProgramRollout` 手工同步，漏改会误报。

## 8. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_e2e_test.gd' `
  -RedirectStandardOutput artifacts/ideology-cell-layer/e2e.log `
  -RedirectStandardError  artifacts/ideology-cell-layer/e2e.err.log
# => 18 checks, 0 failures
```
