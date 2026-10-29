# M1-11 end-to-end harness — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §13.1 第 4 层 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `ideology_cell_layer_e2e_test.gd`（可运行）、`get_derived_materialize_report` 桥、`derived_rebuild_visits` 计数器缺失的诊断 |
| 结果 | **14 checks, 1 failure** —— 链路推进到最后一个前置条件 |
| 结论 | 端到端夹具已可用，但缺少 opinion 模块导致理念运行时提前失败 |

## 1. 六轮同一缺口的进展

M1-6 到 M1-10 连续报告「分片/物化只有状态机证据，缺端到端验证」。每轮都卡在 **ECONOMY epoch 无法在裸 `SceneTree` 里打开**（M1-8 诊断确认需要真实 `generate_world()` 的 MapData）。

本轮的**关键转折**：派生层由**理念运行时**拥有，而 `run_ideology_daily` 驱动四阶段卡牌事务（`ideology → effect → dispatch → modifier → ack`），**完全不需要 economy epoch**。`run_daily` 又调用 `rebuild_derived_cell_layer`，它只需要卡集。

所以端到端路径存在，只是之前一直在错的地方找。

## 2. 逐阶段打通过程（每一条都是实际踩到的）

| 阶段 | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | `submit ok=false` `ideology_runtime_unavailable` | 只配了 modifiers，没配完整链 | 补 `configure_economy` → `configure_effects` → `configure_ideologies` |
| 2 | 报告可读，但卡不存在（113 条里找不到） | **`kin_hearth_l1` 是等级内效果程序名，不是理念 id** | 用 `idea.kin_hearth`（dense id 从 `ideology_ids.find()` 取） |
| 3 | `discover`/`equip` 被拒且 reason 为空 | 协议需 **11 列**，且 `ideology_ids` 是 **`PackedInt32Array` dense id**，不是 `idea_keys` 字符串 | 照 `ideology_card_content_test.gd:973-987` 补齐全部列 |

第 3 点尤其值得记：错误 reason 为空让你以为「没反应」，实际是列不合法。

## 3. 当前状态：链路跑到最后一步

装备与 discover **均被接受**（`commands_applied: 1`、`levels_advanced: 1`），但：

```
last_error            = "ideology_class_opinion_unavailable"
commands_rejected     = 1
managed_idea_count    = 0
derived_rebuild_visits = 0     ← 物化器一次都没被调用
```

两条结论：

1. **`rebuild_derived_cell_layer` 从未执行。** 理念运行时因缺少 opinion 桥（`ideology_opinion_bridge` 未 attach）在日循环里提前失败，`run_daily` 后面的物化挂点没走到。
2. `programs_seen = 0` 因此是**正确结果**，不是物化器缺陷。

## 4. 新增可观测项

| 桥 | 用途 |
|---|---|
| `get_derived_materialize_report()` | `programs_seen` / `rows_emitted` / **`truncated`** / `missing_stat` |

`truncated` 现在是一个**可直接断言的观测值**，而不是从行数反推的推断值。§12.4 的硬条件「派生路径绝不截断」因此有了直接证据通道。

## 5. 为什么本轮停在这里

补 opinion 桥意味着再造一个 `attach_*` 链（`ideology_opinion_bridge`、可能的 political class 提供者），而**这与 M0-7c 的 worker 夹具缺口是同一类基础设施工作**。

本轮的实际价值是把「端到端不可行」这个结论**推翻**了：路径存在，夹具已能跑，只剩一个明确的、可命名的前置条件。

## 6. 局限

- **`derived_rebuild_visits` 计数器不存在。** 排查时想直接确认物化器调用次数，但报告里没有这个字段；靠 `programs_seen` 反推。建议补一个 `derived_rebuild_visits` 与 `derived_rebuild_ms`。
- 测试文件目前硬编码 `ROLLOUT_OFF_EXPECTED := true`，与 `kCellProgramRollout` 手工同步。若将来漏改，会在 ON 之后误报失败。
- 未验证 ON 状态下的行为（需要先解决 opinion 前置）。
- 未把该夹具纳入 15 fixture 基线（它需要完整 catalog 编译，单次约 30 s）。

## 7. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_e2e_test.gd' `
  -RedirectStandardOutput artifacts/ideology-cell-layer/e2e.log `
  -RedirectStandardError  artifacts/ideology-cell-layer/e2e.err.log
# => 14 checks, 1 failure; last_error = ideology_class_opinion_unavailable
```
