# M5-50 D4：claim 命令能提交，但领土没有变化

| 项目 | 内容 |
|---|---|
| 里程碑 | 用户 2026-10-28 的 D4 决策 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **达成一半**：第一次从 GDScript 打通 `COMMAND_CLAIM_UNOWNED_TERRITORY`；但领土未变 |

## 1. 做成了什么

在**真实生成的 200×200 世界**上（`generate_world`）跑了完整链路：

```
[d4] before: countries=3 widest=1 above_old_cap=0 total=3
[d4] growing from cell 9710, country handle 4294967296
[d4] claim attempts: accepted=48 rejected=22
[d4] country day advances completed: 3 (last_error=)
[d4] after: countries=3 widest=1 above_old_cap=0 total=3
[d4] plane: ok=true cell_count=40000 country_count=3
```

| 环节 | 结果 |
|---|---|
| 真实世界生成 + `DCWorldExt` 绑定 | ✅ |
| 找到玩家国的一个格与 handle（4294967296）| ✅ |
| `submit_country_commands` 提交 `CLAIM_UNOWNED_TERRITORY`(opcode 20) | ✅ **48 条被接收**，22 条被拒（水域等）|
| `run_country_slice` 推进 3 个国家日 | ✅ 全部 `done`，无错误 |
| **领土真的变大** | ❌ **`widest` 仍是 1、`total` 仍是 3** |

## 2. 这是本项目第一次从 GDScript 打通这条命令

之前只用过 `generate_world` 读结果。本轮确认了：

- 批量格式必须**含 `NativeCountryRuntime::submit_commands` 读的全部数组**，且长度都等于 `opcodes`；
  少一个就整批失败。我照 `country_facade.gd:83-137` 补齐后一次通过。
- `get_country_cell_summary(cell_idx)` 的参数是**格号**（不是 handle）。
- 国家日推进是 `run_country_slice({day_index, tick_index})`，不是 `advance_country_day`（后者不存在）。

## 3. 领土没变：三个候选原因（我没区分开）

| # | 候选 | 判据 |
|---|---|---|
| 1 | **claim 需要目标格与现有领土相邻**（compare-and-set 只在「中立」时接受，且可能另有邻接要求）| 我的候选格是 `owned_cell ± offset` 的线性扫描，**多数不相邻** |
| 2 | **提交 ≠ 提交后应用**：`accepted` 只表示批次被接收，可能还需要一次显式的应用/提交阶段 | `total` 完全没动，说明连相邻的那些也没生效 |
| 3 | 该世界里的国家运行时不在会应用命令的模式 | 未查 |

**我没有猜一个写上去。** 这三条各自都能解释「accepted 但 territory 不变」。

## 4. 成本现实

每次尝试要 **约 7-10 分钟**（真实世界生成）。剩余轮次只够 1-2 次尝试，所以我要先把原因区分开，
而不是盲目重跑。

**最省的下一步**（不需要重跑世界）：在一份**合成**世界上试同一条 claim 命令——
合成世界的 `bootstrap_country` 可控，能立刻看出「相邻」是否是条件。

## 5. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_d4_multi_cell_country_test.gd` | 9 checks / **1 failure**（失败的是「>32」这条真目标）；**未加入 `verify_delivery.py` 的期望表**，因为它现在会失败 |

## 6. 局限

- 只试了线性扫描的候选格，没试**相邻格**。
- 没查国家运行时的 mode。
- 没在合成世界上复现，所以「相邻是不是条件」未知。
- 本轮没有改变任何产品代码——`submit_country_commands` 与 claim 逻辑都是既有实现。
