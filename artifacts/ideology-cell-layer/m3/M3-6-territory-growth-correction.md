# M3-6 修正 M3-5 的错误结论：领土增长机制存在

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md)；修正 M3-5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **M3-5 的「没有任何代码发出领土命令」结论是错的** |
| 当前状态 | 领土增长机制**存在且完整**；但我在无头夹具里未能通过它的前置门 |
| 结论 | 32 上限有无生产场景**仍未知**，不能再用 M3-5 的说法 |

## 1. M3-5 错在哪里

M3-5 我写下：

> `COMMAND_CLAIM_UNOWNED_TERRITORY` 在 `country_runtime.cpp` 有完整处理，但**全仓库无任何发出方**。

**这是错的。** 实际存在的发出链是：

```
start_family_colonization          world_ext_bind_methods.cpp:901（已绑定 GDScript）
  -> enqueue_family_colonization_pod   effect_runtime.cpp:3630
    -> claim.opcode = COMMAND_CLAIM_UNOWNED_TERRITORY
                                        effect_runtime.cpp:3680
```

我的搜索漏掉了它，因为我只搜了「直接给 `opcode` 赋值且在一行内出现 `COMMAND_CLAIM_UNOWNED_TERRITORY`」，而这里是通过 `NativeCountryRuntime::COMMAND_CLAIM_UNOWNED_TERRITORY` 全限定名写的。

**教训：一次「没找到」不等于「不存在」。** 我在 M3-5 里把一个搜索空结果写成了「机制不存在」的断言，这是超出证据的结论。

## 2. 机制是完整的

| 环节 | 位置 | 状态 |
|---|---|---|
| 报价查询 | `family_colonization_quotes` | ✅ 有 6 道前置校验 |
| 启动殖民 | `start_family_colonization` | ✅ 已绑定 |
| 发出 claim | `enqueue_family_colonization_pod` | ✅ |
| 执行 claim | `country_runtime.cpp:1424` | ✅ |
| 结算 | `apply_settle_family_expedition` | ✅ |

**所以领土可以增长，只是需要有人发起殖民。**

## 3. 我在夹具里没走通的部分

用真实生成世界调 `get_family_colonization_quotes`，逐步排除了自己的错误：

| # | 我的错误 | 报错 | 修正 |
|---|---|---|---|
| 1 | 传 country **slot 索引**，而 API 要 **handle** | `colonization_country_invalid` | 从 `get_country_cell_summary` 取 handle |
| 2 | 只扫前 200 格找本国格 | `handle = 0`（看着像「国家不存在」） | 扫全部 6144 格 → 得到 `4294967296` |
| 3 | 探测固定格 0..3 | `colonization_target_invalid` | 改用 24 个 `owned == false` 的候选格 |
| 4 | 仍然 `colonization_target_invalid` | — | **未解决** |

第 4 步的失败指向**可见性门**：bridge 要求 `MapData.visible_arr` 非空且长度等于格数，而 `family_colonization_quotes` 里 `visible[target_cell] == 0` 会直接返回 `colonization_target_invalid`。

在无头开局世界里，视野大概率是空的或全 0，所以任何目标都判无效。

**我没有验证这一点**，所以只能说「疑似可见性门」，不能说「原因是视野」。

## 4. 因此 32 上限有没有生产场景，仍然未知

| 问题 | 答案 |
|---|---|
| 领土增长机制存在吗？ | ✅ 存在（本轮证实） |
| 无头夹具里能触发吗？ | ❌ 未走通（疑似可见性门） |
| 玩家实际游戏里能超过 32 格吗？ | ❓ **未知** |

我不能再用 M3-5 的「从未触发」说法。正确的说法是：

> 领土增长依赖家族殖民，而殖民需要可见的无主目标。在无头夹具里我没能满足这个前置，所以**无法判定 32 格上限在真实玩法中是否会被触发**。

## 5. 一个反复出现的模式，值得单独记

这一轮加上 M3-5，我在同一个问题上连续给出过两次错误结论：

| 轮次 | 我的结论 | 实际 |
|---|---|---|
| M3-5 | 「没有代码发出领土命令」 | 有，在 `effect_runtime.cpp:3680` |
| M3-6 中途 | 「殖民系统不存在」 | 存在，6 道校验都在 |
| M3-6 中途 | 「quote 返回 0」 | 是 `ok=false` 被我 `continue` 掉了，掩盖了错误码 |

三次都是**把「我的探测失败」读成「功能不存在」**。

具体到可操作的改进：
1. 任何 `ok == false` 都不能静默 `continue`，必须至少打印一次错误码（本轮补上了，才看到 `colonization_country_invalid`）；
2. 「搜索无结果」不能写成「不存在」，只能写成「本次搜索未找到」；
3. 用错 API 的报错（`_invalid`、`_unavailable`）与功能缺失长得一样，必须区分。

## 6. 本轮实际交付

| 产出 | 价值 |
|---|---|
| 修正 M3-5 的错误结论 | 避免了把「机制不存在」写进交接文档 |
| 完整的殖民链路位置 | 后续接手者不必再搜 |
| 3 个自己的调用错误与修正 | 可复用的调用范式 |
| `ideology_territory_colonization_probe.gd` | 探针骨架，卡在可见性门 |

## 7. 下一步建议

要判断 32 上限的真实场景，需要让殖民在夹具里可行。两条路：

1. **补视野**：在夹具里先跑出让 `visible_arr` 有值的状态（可能需要 `reveal`/视野系统在无头下的初始化）；
2. **绕过视野**：加一个测试专用的「临时全可见」开关，仅用于验收夹具。

第 2 条更可控，且与既有的 `set_effect_metric_override_for_test` 是同一种模式。

## 8. 局限

- 未验证可见性是不是真的原因。
- 未跑通殖民，因此没有「领土超过 32 格」的证据。
- 增长探测只到 day 30（每 checkpoint 一次 `run_daily_tick`，很慢）。
- 未验证 AI 是否会自己发起殖民（若不会，则玩家必须手动操作，32 上限的实际影响更小）。

## 9. 复算方式

```powershell
# 机制存在性
Select-String -Path 'gdext/src/effect_runtime.cpp' -Pattern 'claim.opcode = NativeCountryRuntime::COMMAND_CLAIM_UNOWNED_TERRITORY'
# => effect_runtime.cpp:3680

# 探针（当前卡在 colonization_target_invalid）
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_territory_colonization_probe.gd'
```
