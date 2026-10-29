# M4-1 Sources 批次打开：测出派生路径与实例路径的精度分歧

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `kCellProgramRollout: Continuous → Sources`，构建通过，**影响已精确测量** |
| 结果 | `ideology_x1b_source_count_test`: **142/0 → 142/13** |
| 结论 | M4 不是"翻一个开关"，而是**必须迁移断言**；且发现了一处真实的数值分歧 |

## 1. M4 的规模（已核查）

| selector kind | 程序数 | 族 |
|---|---:|---|
| 12（OWN_TERRITORY）| 194 | A–D（M2/M3 已开）|
| **16（TAG_SOURCE_COUNT）** | **66** | **E** |
| **14（TAG_SOURCE_R1）** | **5** | **F** |
| 15（TAG_SOURCE_R2）| 0 | F |
| 合计 | 265 | A–F |

`cell_program_eligibility.h:216-218` **早已支持 14/15/16**，所以 M4 的代码侧只需翻开关。

## 2. 影响已测量（不是假设）

```
改前（Continuous）: === ideology x1b source count: 142 checks, 0 failures ===
改后（Sources）   : === ideology x1b source count: 142 checks, 13 failures ===
```

**这正是 `cell_program_eligibility.h:153-158` 警告过的场景**，现在有了确切数字。

## 3. 13 个失败的分类

| 类 | 例子 | 含义 |
|---|---|---|
| **实例句柄消失** | `T1 two sources bracket the middle cell (targets=[1, 3])` | 该 fixture 断言实例的 target_handles，改写后路径不再创建实例 |
| **数值精度分歧** | `T1 target cell reads two sources of magnitude (value=1.23999)`<br>`T7 cell stat shows exactly one owned source (value=1.12000)` | **派生路径算出 1.23999，实例路径算出的不同** |

## 4. 精度分歧：这是 §13.1 第 2 层要抓的问题

失败值全部长这样：

```
value=1.23999
before=1.23999  after=1.17999
value=1.12000
```

**都带有 Q16 量化痕迹。** 实例路径与派生路径对同一个 program 给出了略有不同的结果。

这正是方案 §13.1 **第 2 层「同输入对照」**存在的理由——两条路径必须逐格一致。我在 M2-18
写的 `derived_layer_oracle_test`（735 checks）比较的是「派生实现 vs 独立参考折叠」，
**不是「派生 vs 实例」**，所以没覆盖这个分歧。

**这是一个真实缺口，且现在有了具体的失败值。**

## 5. 我做的处置

**回退到 `Continuous`。** 理由：

1. 13 个失败需要逐条迁移断言（改断言 / 改 fixture 的读取方式），**剩余轮次不足**；
2. 留着 13 个红色失败会让基线失去意义；
3. 但**影响已经测出来并记录**，M4 的下一步不再需要猜。

## 6. 验证

| 项 | 值 |
|---|---|
| M4 程序数 | **71**（66 个 kind 16 + 5 个 kind 14）|
| `Sources` 下的失败 | **13**（精确列表已记录）|
| 分类 | 实例句柄断言 + **数值精度分歧** |
| 回退后 | 142/0（保持基线绿）|
| 纯核门禁 | oracle 735 / materializer 65 / cap_removed 12 全 0 |

## 7. 局限

- **未完成 M4**：71 个 program 的 rollout 未打开。
- 精度分歧的**根因未查**（是 Q16 折叠顺序差异？还是 `stacks` 处理不同？）。
- 未逐条列出 13 个断言各自该改成什么。

## 8. M4 的具体下一步

1. **先查精度分歧**：取 `T1 two sources` 这一条，对比两条路径对同一 program 的计算过程。
   若派生路径的 `add`/`factor` 折叠顺序与实例路径不同，§5.1 的公式就需要在派生侧对齐。
2. 再迁移 12 条实例句柄断言（改成读派生层的 front，或不依赖实例）。
3. 重跑 `Sources`，直到 142/0。
4. 然后才是 M4 的其余任务（stamp/scratch、边境外溢、多国共同影响、per-tag changed words）。

**第 1 条最重要**：它是 §13.1 第 2 层的实质缺口，且影响 A–D 全部 265 个 program 的可信度。
