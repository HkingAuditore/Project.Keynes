# M2-14 repeated-measurement attempt — blocked on version control

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §14.4 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | harness 支持 `PK_REPEAT_BUILDS`，但**版本 bump 未生效** |
| 结果 | 仍只有 n=2 的同一构建读数，**分位数仍无法给出** |
| 结论 | 阻塞点具体且可命名：版本未变，读者不重建 |

## 1. 想解决什么

M2-13 发现同一规模两次读数差 1.8 倍（14.376 vs 7.799）。根因是**每规模只有一次有效读数**，无法报分位数。

所以本轮要做的，是让 harness 在同一次运行内取到多个**独立**的构建样本。

## 2. 为什么之前只有 n=2

`city_factor_epoch_ms` 只在构建真正执行时变化。而构建完成后，读者每天都会走版本早退：

```cpp
// economy_runtime.cpp:7035-7038
if (_city_factor_shard_cursor < 0 && _epoch_city_factor_valid &&
    shape_valid && _epoch_city_factor_stat_version == version) {
    return true;                       // 没进格子循环，epoch_ms 不动
}
```

所以 6 个采样日读到的是**同一次构建**的冻结值。`n=2` 是两个稳态日，不是两个样本。

## 3. 尝试的修法：主动 bump 版本

`apply_modifier_commands` 会 `++store.stat_versions[stat_id]`（`modifier_runtime.cpp:887`），而 `stat_bucket_version` 把它混进哈希。所以提交一条新行应当强制重建。

harness 新增 `PK_REPEAT_BUILDS=1`：每个采样日在 `run_daily_tick` **之前**提交一条同 stat 的行（cell 取 `900000+seq`，落在任何工作集之外）。

## 4. 修法失败，证据明确

新增 `version_probe`（直接读 `modifier_stat_bucket_version`）后：

```
version_probe=-6659680016542916120 day=1
version_probe=-6659680016542916120 day=2
version_probe=-6659680016542916120 day=3
version_probe=-6659680016542916120 day=4
version_probe=-6659680016542916120 day=5
```

**五天完全相同。** 版本没变，所以读者从未重建，`epoch_ms` 一直是 4.698。

（中间换过一次 stat：首版用了 `housing.consumption_factor`，它不在读者的请求集里；改成 `birth_factor` 后仍未生效，说明问题不是 stat 选错。）

## 5. 具体原因（已定位，未修复）

`submit_modifier_commands` 在 worker shadow 路径下是**入队**而非立即应用：

```cpp
// world_ext_modifier.cpp:141
!_runtime_host->enqueue_modifier_shadow(std::move(packet))
```

我在 `_bump_stat_version` 里随后调用了 `ext.run_modifier_daily(_day)`，但 `_day` 在调用点已经递增过（`_day = int(_day) + 1` 在前），行可能被 stamp 到错误的日，因而在当天边界不被应用。

**这是一个具体的、可在下一轮修掉的缺陷**，不是原理性障碍。

## 6. 这一轮的实际产出

| 项 | 状态 |
|---|---|
| `PK_REPEAT_BUILDS` 开关 | ✅ 已实现 |
| `version_probe` 观测 | ✅ 已实现，并**立即证伪了我的假设** |
| 独立样本 | ❌ 未取得 |
| 分位数 | ❌ 仍缺 |

价值在于：**版本不变这件事现在是可观测的**，而不是从「时间重复」反推。前几轮我正是在反推上连续错了三次（M2-9/M2-10/M2-11）。

## 6.1 修了日戳仍然无效

按 §5 的定位改了日戳（`run_modifier_daily(_day)` → `maxi(0, _day - 1)`），重跑：

```
version_probe=-6659680016542916120 day=1..5   （仍然完全相同）
epoch_ms=2.942 恒定
```

**版本仍未变。** 所以日戳不是原因。

## 6.2 新的、更有力的判断

第一次注入的 800 行**确实被读取到了**（`collected=800`、`slices=13`、`epoch_ms=2.942`）。所以 `submit_modifier_commands` 在主线程权威下是**能生效的**。

那为什么后续的 bump 不生效？

最可能的解释是**时机**：一天的 epoch 只打开一次，而我的 bump 发生在 `run_daily_tick` 之前但仍在**同一天**内。若读者在该 epoch 的第一次 `capture_country_epoch` 时已经收集完工作集，之后再 bump 的行只能等到**下一个** epoch——而下一天又会因为上一次已完成的构建而早退……除非版本真的变了。

这形成循环依赖：**要 bump 才能重建，要重建才能读取 bump**。

## 6.3 我不再继续深挖

本轮在这里用完了整轮时间，得到的是「日戳不是原因」这一个否定结论。继续猜测的边际收益在下降，而前几轮反复证明：**在缺少可靠观测时继续调整，只会产生新的错误结论**。

正确的下一步不是再试一个猜测，而是**换测量机制**：不再依赖「让版本变化来触发重建」，而是**在每次测量前重建整个世界**（`configure_session` + `generate_world`），用「冷启动」代替「重复热构建」。

代价是每次约 5 分钟，取 5 个样本需要 25 分钟——但结果是**独立的、可信的**，而不是继续在同一个 epoch 上试图作弊。

## 7. 下一步（明确且有限）

1. 修 `_bump_stat_version` 的日戳：用**递增后**的 `_day` 作为 `run_modifier_daily` 参数，或先 bump 再 `_day += 1`。
2. 若仍无效，改走**直接调用** `apply_modifier_commands`（绕过 shadow 入队），因为测量夹具不需要 worker 语义。
3. 拿到 ≥5 个独立样本后，报 p50 / p95 / max，替换掉现在的单点数字。

## 8. 局限

- 本轮**没有改善性能数据的可信度**，只是把阻塞点从「猜测」变成「可观测」。
- `version_probe` 是临时观测，未决定是否长期保留。
- 未验证 `run_modifier_daily` 的日戳语义，§5 的定位来自代码阅读而非实验。

## 9. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
$env:PK_COVER_CELLS = '800'
$env:PK_REPEAT_BUILDS = '1'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_m0_realworld_cost_test.gd'
# => version_probe 五天相同；epoch_ms 恒为 4.698
```
