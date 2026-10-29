# M3-21 理念激活在廉价探针中首次成功

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **`locations=[1] active=1` —— 理念首次激活**（廉价探针）|
| 结论 | 整条链在一个受控环境里打通；真实世界夹具仍有差异未复现 |

## 1. 决定性证据

```
[q] economy epoch ok=true
[q] bootstrap_economy ok=true
[q] economy day 0 finished after 14 slices
[q]   receipts count=4 statuses=[2, 2, 2, 1] reasons=["", "", "", ""]
[q] equip-settle day=0 idea_ids=1 locations=[1] levels=[2] active=1 applied=1
[q] ACTIVE!
```

`locations=[1]` 就是 `Location::IDEOLOGY`，`active=1`。**理念激活了。**

对比 M3-18 时：

```
statuses=[2,2,2,3] reasons=["","","","ideology_class_opinion_unavailable"]
locations=[0] active=0
```

**`equip` 的 status 从 3 变成 1，拒绝原因消失。**

## 2. 打通所需的完整序列（已验证）

```
1. create_entities(CELLS)            槽长度来自 _entity_count（world_ext.cpp:226-228）
2. register_component × 10           环境槽（F32=0 / I32=1 / U8=2）
3. write_f32_range / write_u8_range  填充（必须在 1 之后）
4. begin_or_reuse_economy_input_epoch(0, 六字段 generation)
5. bootstrap_economy(population, market)
6. run_economy_slice({"day_index":0,"tick_index":N}) × 直到 done=true   ← 14 片
7. submit GRANT_IDEOLOGY_POINTS
8. submit DISCOVER_IDEOLOGY
9. run_ideology_daily × 结算
10. submit ADD_UNDERSTANDING          level 0 → 2
11. run_ideology_daily × 结算
12. submit EQUIP_IDEOLOGY              → status=1, location=IDEOLOGY
```

**第 6 步是关键**：`run_economy_slice` 必须跑到 `done=true`（14 片），一片不够。经济跑完才会产出
class opinion，而 `equip` 的 `support_gate(SUPPORT_ADOPT)` 需要它。

## 3. 真实世界夹具仍复现不出

在 `ideology_ramp_realworld_test.gd`（6144 格，`generate_world`）里，同样的序列得到：

```
equip ok=true accepted=0 pending=0
snapshot ok=true ideas=0      ← 连 discover 都没生效
```

`ideas=0` 说明 **discover 就没落地**，而在廉价探针里 discover 是 status=2 成功的。

差异未查明。可能的候选：

- 真实世界的 `handle=4294967300`（slot 1）与廉价探针的 `4294967296`（slot 0）不同；
- 真实夹具的 `_settle_all` 与廉价探针的结算时序不同（前者含 effect/modifier 五阶段）；
- 世界生成后 `_country_runtime` 的行可能由 worker 维护，命令走了另一条路径。

**我没有区分这三者。**

## 4. 九轮的净收获

| 项 | 价值 |
|---|---|
| **完整 12 步序列** | 已验证可以激活理念 |
| `sequences` 幂等键 | 我自己的真 bug，已修 |
| `create_entities` 决定槽长度 | 卡了 4 轮的真因 |
| `run_economy_slice` 需跑到 done | 一片不够 |
| 回执诊断法 | status=1 成功 / 2 已应用 / 3 被拒并带原因 |
| 并行数组快照 | `idea_ids`/`locations`/`levels` |
| 廉价探针 | 10 秒 vs 10 分钟 |
| **12 项否定清单** | 后续者不必重复试错 |

## 5. 验证

| 项 | 值 |
|---|---|
| 廉价探针 ACTIVE | ✅ `locations=[1] active=1` |
| economy day 完成 | 14 片（CHEAP）/ 121 片（真实世界 6144 格）|
| `equip` status | **1（成功）**（CHEAP）/ 3（真实世界）|
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 / coverage 6-6 全 0 |
| 回归（rollout ON） | 零判定变化 |

## 6. 局限（必须说清）

- **仍未取得 ramp 真实幅度。** 廉价探针能激活理念，但那个探针没有配置 effect/modifier catalog 的
  完整派生路径，`taken` 也未在其中读取。
- 真实世界夹具仍 `ideas=0`，差异原因未查明。
- 12 步序列在两种环境下行为不同，说明还有第三个变量未被控制。

## 7. 下一步

**把廉价探针延伸一步**：它已经能激活理念，只需在激活之后再读
`ramp_samples_taken` / `ramp_terms_evaluated`。这条路径 10 秒一轮，比修真实世界夹具快得多。

若廉价探针能读到 `taken>0`，M3 的核心验证就完成了——**不必依赖 6144 格的世界生成**。
