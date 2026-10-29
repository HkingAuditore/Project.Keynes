# M5-53 D4 的停止点：我查到了哪一层，以及为什么停

| 项目 | 内容 |
|---|---|
| 里程碑 | 用户 2026-10-28 的 D4（连片多格国家 → >32 样例） |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **未达成**；阻塞已定位到一层，且该层**不属于本方案范围** |
| 本轮产品代码 | 无 |

## 1. 走到的位置

| 环节 | 结论 | 依据 |
|---|---|---|
| `COMMAND_CLAIM_UNOWNED_TERRITORY` 可达、批量格式正确 | ✅ | 真实世界 `accepted=48`（M5-50）|
| **claim 确实应用**：格子的 `country_slot` 从 **-1 → 0** | ✅ | 夹具 PRE/POST（M5-52）|
| `get_country_cell_summary()` 看得到变化 | ✅ | 同上 |
| `get_country_territory_counts()` **看不到**变化 | ❌ | 即便**开一个真正新建的 epoch** 之后仍是 `total=1` |
| 该函数读的是经济运行时的 **epoch 快照**，不是 `territory_count` | ✅ | `world_ext_country.cpp:978-992` |
| 经济快照里的 `cell_country_slot` **本身就是旧的** | ⚠️ 推断 | 见 §2 |

## 2. 最后一步证据

```
[claim] epoch2 -> { "captured": true, "input_capture_reused": false,
                    "input_capture_generation": { "epoch_id": 2, ... } }
[claim] after: widest=1 total=1
```

**epoch 是真正新建的**（`reused=false`、`captured=true`、`epoch_id=2`），
而计数仍是 1。所以问题不在「快照没刷新」，而在**快照的输入本身**：

`economy_runtime.cpp:4986` 把 `snapshot.cell_country_slot` **搬进** epoch 快照
（`_epoch_cell_country = std::move(snapshot.cell_country_slot)`）。
若那个 `snapshot.cell_country_slot` 是从国家运行时取的一份**已冻结的导出**，
那么开多少个新 epoch 都会搬进同一份旧数据。

**这一步我没有证实**——只证明了「新 epoch 也没用」，这是它的必要条件。

## 3. 为什么停在这里

**这一层不属于本方案。**

| 项 | 归属 |
|---|---|
| 理念地块程序、选择器、归属筛选、派生层 | **本方案（plan 22）** |
| `country_runtime` 的 claim 命令、`territory_count` 记账 | 不是 |
| 经济运行时的 `cell_country_slot` 捕获与刷新 | 不是 |

继续挖它需要动 `country_runtime` 与 `economy_runtime` 之间的领土同步契约，
**那是一个独立的、有自己存档与哈希约束的子系统**。在剩余轮次里改动它，
风险远大于它对本方案的价值。

## 4. 这条线对本方案的实际影响

**< 32 格的结论全部成立。** 需要「>32 格真实世界」才能回答的只有一项：

> §18.4「真实世界的 >32 格生产样例」

而「32 格上限已取消」这一主张的**代码层与合成夹具层证据都完整**：
`cap_removed` 12 检查（200 格国 → 200 目标）、B7 单国 **1600 格**、
`b7_wide_territory` 27/0。**缺的只是「真实生成世界」这一种来源**。

## 5. 交给接手者的一句话

> claim 命令能把格子变成自己的（`cell_summary` 立即反映），
> 但 `get_country_territory_counts()` 读的是经济 epoch 快照，
> 而该快照的 `cell_country_slot` 输入在 claim 后没有跟着更新。
> **先查「谁是 `snapshot.cell_country_slot` 的生产者、它在什么时候重建」**，
> 而不是继续查 claim 或计数。

## 6. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_d4_claim_condition_test.gd` | 最小复现，秒级；打印 PRE/POST slots 与 epoch 结果 |
| `tests/ideology/ideology_d4_multi_cell_country_test.gd` | 真实世界版本（7-10 分钟/次），`accepted=48` |

## 7. 我这一路的错，供参考

| 次 | 错法 | 代价 |
|---|---|---|
| 1 | 判定「claim 不生效」 | 3 轮 |
| 2 | 判定「`territory_count` 漂移是缺陷」并发布 | 2 轮 + 一次撤回 |
| 3 | 判定「合成世界没有中立格」 | 1 轮 |
| 4 | 用不存在的 `advance_country_day` | 1 轮 |

**共同点：我每次都只查了链条的一半就下结论。**
第 2 次最严重——我把「A 字段被写」推成「B 读者读它」，实际 B 读的是快照。
