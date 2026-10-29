# M2-11 retraction & the real mechanism

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../docs/../22-cell-program-cap-removal-plan-v3.md) §14.4 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 性质 | **撤回上一稿的结论**，并给出经实证的机制 |
| 结论 | `processed=16` 是**收尾分片**，不是 `total=16`；分片确实在推进 |

## 1. 我上一稿的推理是错的

我论证：`processed=16 < shard_size=64`，所以循环必然以 `cursor >= total` 结束，因此 `total = 16`，因此注入行被 snapshot 抹掉。

为把推理变成事实，我加了 `_city_factor_collected_cells`（只在本次 collect 后立即记录）。实测：

```
work_cells=2000  collected=2000  processed=16  cursor=-1
```

**`collected=2000`。** 这次 collect 确实返回了 2000 格。我的「total=16」推断**被自己的实证推翻**。

## 2. 正确的机制

`processed` 是**本次 pass** 处理的格数，而 `cursor` 是**跨 pass 持久**的：

```
pass 1: cursor 0    -> 64    processed=64   yields (cursor<total)
pass 2: cursor 64   -> 128   processed=64   yields
...
pass 31: cursor 1920 -> 1984 processed=64   yields
pass 32: cursor 1984 -> 2000 processed=16   cursor=-1  ← 收尾
```

**`processed=16` 是最后一片。** 2000 格的总成本被分摊在约 32 次调用里，而我读的 `epoch_begin_city_factor_ms` 只覆盖**其中一次**。

所以：
- 分片**工作正常**（32 片走完 2000 格）；
- 但 `city=0.002 ms` 只对应 16 格，**不能代表 2000 格**；
- 我之前「分片被版本打断、永远重启」的判断**也是错的**。

## 3. 那注入行为什么只测到 16 格？

它没有只测到 16 格——是**计时只覆盖了收尾那一片**。

`_epoch_begin_city_factor_ms` 在 `capture_country_epoch` 里测的是**一次 `refresh_city_modifier_factors()` 调用的耗时**，而一次调用只推进一个分片。整个 epoch-open 期间该函数被调用 32 次，但计时器每次都被覆盖，最后留下的是**最后一次**（收尾 16 格）。

**这是计时口径的问题，不是数据来源的问题。**

## 4. 这意味着什么

| 之前以为 | 实际 |
|---|---|
| 注入行被 snapshot 抹掉，测不到大工作集 | ❌ 错。`collected=2000` 证明行在 |
| 分片被版本打断，永远重启 | ❌ 错。32 片走完了 2000 格 |
| 需要 worker 协作才能测 | ⚠️ **不一定**。也许只需把计时改成累计 |

**最后一条是本轮最有价值的产出**：前几轮我断定「必须 worker 脚手架」，现在看可能只需要改计时口径——把 `_epoch_begin_city_factor_ms` 从「最后一次调用」改成「本 epoch 累计」。

## 5. 立即可做的事

`refresh_city_modifier_factors` 已经有 `_city_factor_cells_processed` 和累计的 `_cell_layer_rebuild_ms` 模式可循。给 city 因子加一个：

```
_city_factor_epoch_ms   // 本 epoch 所有分片的累计耗时
_city_factor_epoch_slices
```

在 `capture_country_epoch` 的首次调用时清零，每片累加。这样 `epoch_begin_city_factor_ms` 就是**整次构建**的成本，而不是最后一片的。

**这比搭 worker 脚手架便宜得多，且能立刻回答 §14.3 的问题。**

## 6. 局限

- 本轮**再次没有拿到可用的 2000 格成本**。
- `processed=16` 的「收尾」解释仍是从 `collected=2000 + cursor=-1` 反推的，**尚未逐片打印验证**。下一轮应打印每片的 `cursor/processed` 以坐实。
- 未验证版本是否真的稳定（若中途版本变化，分片会重启，`processed` 会重新从 0 开始，也不会出现 collected=2000 与 processed=16 的组合……但这一点值得实测）。
- 累计计时方案未实现。

## 7. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_m0_realworld_cost_test.gd'
# => work_cells=2000 collected=2000 processed=16 cursor=-1 city=0.002~0.282 ms
```

`collected=2000` 与 `processed=16` 同时出现，是「分片走完、计时只覆盖最后一片」的直接证据。
