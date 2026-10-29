# M3-5 端到端夹具打通 + 一个关于领土的重大发现

| 项目 | 内容 |
|---|---|
| 里程碑 | [M3](../22-cell-program-cap-removal-plan-v3.md) §15.5；同时回答贯穿 M1–M3 的夹具缺口 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `get_country_territory_counts()` 桥、`ideology_territory_growth_probe.gd`、e2e 夹具骨架 |
| 结果 | **世界生成成功**（6144 格 / 3 国）；**发现领土在生成世界里只有 1 格且不增长** |
| 结论 | 端到端数据链路首次打通；但**「32 格上限」在当前游戏内容下没有生产场景** |

## 1. 端到端链路首次打通

六轮未解的夹具缺口（M1-8 / M1-13 / M2-9 / M2-14 / M2-17 / M3-4）**本轮通了**：

```
[loading-substep] ideology_facade.configure( 194.8ms
[economy] ACTIVE native graph cells=6144 goods=134 cohorts=12 ...
[country] ACTIVE native authority countries=3 cells=6144 generation=1
[loading-visual-substep] start_worker 40.9ms
```

`host.generate_world(SEED)` → `generator.get_data_core_world_ext()` 可用，`ext` 上的所有桥都能调。

**这是 M3-4 报告里我列为「第 6 次撞同一缺口」的那件事，现在解决了。**

## 2. 但立刻发现了更根本的问题

我新增 `get_country_territory_counts()` 桥后，读到的第一手数据是：

```
[e2e] countries=3 widest=1 above_old_cap=0 total_cells=3
```

**每个国家只有 1 格。**

我以为是领土需要时间扩张，于是写了 `ideology_territory_growth_probe.gd` 推进 500 天：

```
[growth] day,total,widest,above32
[growth] 0,6,1,0
[growth] 1,6,1,0
[growth] 5,6,1,0
[growth] 10,6,1,0
[growth] 20,6,1,0
```

**20 天里领土一个格都没变。**

## 3. 根因：没有任何代码发出领土命令

```cpp
// country_runtime.cpp:1361 — 处理
if (command.opcode > COMMAND_CLAIM_UNOWNED_TERRITORY) { ... }

// country_runtime.cpp:1424 — 处理
if (command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY && ...)

// country_runtime.cpp:3173 — 处理
if (command.opcode == COMMAND_CLAIM_UNOWNED_TERRITORY) { ... }
```

全仓库搜索 `CLAIM_UNOWNED` 的结果：**只有 `country_runtime.cpp` 内部的校验与处理，没有任何发出方**——GDScript 侧没有，其他 C++ 文件也没有。

领土由 `StarterSettlementBootstrap` 在开局设定成 1 格，之后**没有任何机制让它增长**。

## 4. 这对本方案意味着什么

方案 §1.1 的前提是：

> 理念永久地块效果在命中 31/32/33/200 或全国全部格时，不再以 32 截断。

**而当前游戏里，一个国家的领土永远是 1 格。**

| 推论 | 影响 |
|---|---|
| 32 上限从未在生产中被触发 | 移除它不影响任何现有玩法 |
| 200/1000 格场景只存在于测试 | M2/M3 的性能测量都是外推 |
| `unbounded` 的退出条件无真实场景 | 只能靠合成夹具证明 |

**这不是本方案的缺陷，而是方案依赖的上游能力缺失。** 但必须如实报告：**「取消 32 格限制」在今天的游戏里是一个零可见收益的改动**，除非领土扩张先被实现。

## 5. 我没有把它当成 bug 修

`COMMAND_CLAIM_UNOWNED_TERRITORY` 已经实现完整（校验、执行、拒绝路径都有），缺的只是一个**发出它的系统**（AI 扩张、殖民、战争割让之类）。

这属于**玩法设计范畴**，不是本方案的范围，也不是我能替用户决定的。我的处置是：

1. 记录为一项明确的交接事项；
2. 在 e2e 夹具里把「领土 > 32」作为**断言而非假设**，让它失败并留下记录，而不是悄悄跳过。

## 6. 验证

| 项 | 值 |
|---|---|
| 世界生成 | ✅ 6144 格、3 国、`country_daily` ACTIVE |
| `get_country_territory_counts` | ✅ 返回 `widest=1 above_old_cap=0 total=3` |
| 领土增长探测 | ✅ 0/1/5/10/20 天均无变化 |
| 构建 | exit 0 |

## 7. 局限

- e2e 夹具因 B 组断言（领土 > 32）失败而**未通过**。这是**如实反映现实**，不是夹具缺陷。
- 增长探测只跑到 day 20（每 checkpoint 一次 `run_daily_tick`，慢）。500 天的完整结论没有跑到。
- 未验证 `run_economy_slice` 的正确调用形式（需要 Dictionary 参数）。
- 未确认是否真的没有扩张系统——只确认了没有代码发出 `CLAIM_UNOWNED`；可能存在我没找到的其他路径（例如直接写 `cell_country_slot` 槽）。

## 8. 交付建议

**这是一项必须让用户知道的结论：**

> 方案 22 的 32 格上限，在当前游戏内容里从未被触发过，因为国家领土不会超过 1 格。
> 要实现「取消 32 格限制」的实际收益，需要先有一个让领土增长的玩法系统。

建议把它作为 D4 决策项提交：是继续按计划完成 M4/M5（让机制就绪，等领土系统落地后自然生效），还是先补领土扩张。

## 9. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_territory_growth_probe.gd'
# => [growth] 0,6,1,0 ... [growth] 20,6,1,0   （widest 恒为 1）

# 全仓库搜索：
#   Select-String -Path 'gdext/src/*.cpp','Project/project-keynes/scripts/**/*.gd' -Pattern 'CLAIM_UNOWNED'
# => 只有 country_runtime.cpp 的校验/处理，无发出方
```
