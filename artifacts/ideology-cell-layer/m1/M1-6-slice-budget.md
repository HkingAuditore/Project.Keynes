# M1-6 slice budget & sharding — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M1](../22-cell-program-cap-removal-plan-v3.md) §14.3 / §15.3 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | `refresh_city_modifier_factors` 分片化、`capture_country_epoch` 的 pending 出口、`gdext/tests/city_factor_shard_test.cpp`、分片诊断字段 |
| 证据 | 分片状态机 **47 checks 0 failures**；切片测量 2 checks 0 failures；构建成功 |
| 结论 | 6400 格基线本就超过 1 ms 门槛；分片已实现但**集成验证未完成**，原因见 §5 |

## 1. 测量：1 ms 门槛按规模成立或不成立

`epoch_begin_city_factor_ms`，debug DLL，3 次 p50：

| 地图格数 | p50 | 与本门槛的关系 |
|---:|---:|---|
| 2400（生产默认） | **0.415–0.465 ms** | 余量约 0.53 ms，约 89–97 个覆盖格 |
| 6400（单国全国） | **1.264–1.362 ms** | **基线本身已超 1 ms** |

**为什么这必须现在答：** 读源码即可确认这条链路没有分片点：

```
refresh_city_modifier_factors()      void，无 resume 游标
  ← capture_country_epoch()          economy_runtime.cpp:5530
    ← start_epoch()                  economy_runtime.cpp:15273
      ← run_economy_slice()          一次调用
```

所以派生层的成本会叠加在同一段不可分割的窗口里。6400 格规模上 1 ms 门槛**当前不成立且与本迁移无关**；本方案只能承诺不使其更糟。已写入方案 §14.3。

## 2. 实现的分片

`refresh_city_modifier_factors` 改为返回 `bool done`，每 `CITY_FACTOR_SHARD_CELLS = 64` 格 yield 一次：

```cpp
const int32_t shard_start = _city_factor_shard_cursor;
while (cursor < total) {
    <处理第 cursor 格>; ++cursor;
    if (cursor < total && (cursor - shard_start) >= CITY_FACTOR_SHARD_CELLS)
        return false;
}
_city_factor_shard_cursor = -1;
return true;
```

三个决定：

1. **固定格数而非墙钟。** §14.4 警告墙钟分片只是把工作挪成延迟，不会证明任何事；固定格数可断言、可复现。64 格按 M1-6 的 6.0 us/格约 0.38 ms。
2. **在处理好一格之后才检查。** 分片是 slice 预算而非单格预算；在已经开始的那一格上花掉预算是正确的，而「还没干活就退出」会让调用方活锁。
3. **版本变化则丢弃重来。** 半成品被新版本覆盖，继续做完只是为没人读的结果计费。

`capture_country_epoch` 增加 `bool *out_pending_city_factors`，`start_epoch` 把 yield 传成 `city_factor_shard_pending`，复用**既有的** soft-barrier 约定（`economy_runtime.cpp:15277-15290` 的 `same_day_environment_not_captured`）：

- 返回 `true` 会让 `start_epoch` 继续建 workset，发布半张因子矩阵；
- 返回普通错误会致命；
- soft barrier 让调用方 park 并在下一个 slice 重入。

## 3. 一个必须修的真实 bug

首版把版本门写成：

```cpp
if (_epoch_city_factor_valid && shape_valid && version == 上次)
    return true;
```

**这会让未完成的分片永远停住。** 部分绘制后 `_epoch_city_factor_valid` 仍是上一次的值，版本也没变，于是第二次进入直接早退，只有前几片被应用。

修正为 `_city_factor_shard_cursor < 0 && ...`——有分片在飞时必须继续续跑。

## 4. 分片状态机测试（47 checks）

因为集成路径不可达（见 §5），状态机用纯 C++ 直接测：

| 断言组 | 覆盖 |
|---|---|
| A | 256 格不会一次完成，恰好处理一个 shard |
| B | 游标单调推进且不超界 |
| C | 重复调用能完成、游标归 -1、每格恰好处理一次、无重复 |
| D | 完成时报告 done |
| E | 空工作集立即完成；shard=1 时每片一格且必然推进 |
| **F** | **最后一格一定被处理**（`work ∈ {1,63,64,65,128,129,256}`） |
| — | 工作集恰为 shard 倍数时不产生空的额外一片 |

**F 是最容易出错的一条**：循环条件写错成 `cursor <= total`、或 yield 检查放在自增之前，都会静默跳过最后一格——而跳过的格保留旧因子，不会有任何报错。

## 5. 集成验证未完成（必须如实记录）

`ideology_cell_layer_shard_test.gd` 尝试用真实 `run_economy_slice` 驱动分片，**失败**：

| 现象 | 根因 |
|---|---|
| `work_cells=0` 而 `painted=255 of 256` | 夹具测的是一个从未进入 collect 分支的读者 |
| `stage=environment_snapshot`, `country_ms=0.0` | `start_epoch` 卡在 `needs_environment_capture`（`economy_runtime.cpp:4220`） |
| 补 `bind_map_data` + `capture_economy_day_inputs(1)` 后 | `capture ok=false, reason=""` —— 空 reason 说明失败发生在更早的解析层 |

这条依赖链（MapData → input generation → environment capture → epoch open）在裸 `SceneTree` 里没有走通。**这与 M0-7c 记录的 worker 夹具缺口是同一类问题。**

所以本轮的分片正确性来自**状态机测试**，不是端到端验证。这一点必须随任何「分片已实现」的说法一起引用。

## 6. 构建与回归

| 项 | 值 |
|---|---|
| 构建 | `scons: done building targets.`，exit 0 |
| 分片状态机 | 47 checks, 0 failures |
| 切片测量 | 2 checks, 0 failures |
| 新增诊断字段 | `city_factor_shard_cursor` / `city_factor_shard_cells` / `city_factor_work_cells` |

## 7. 局限

- **分片未做端到端验证**（§5）。状态机对，但「真实 epoch 打开时确实按 64 格 yield」尚未观测到。
- **`city_factor_work_cells` 是诊断辅助**，只记录最后一次真正 collect 的规模；版本门早退时不更新，读它必须结合 `city_factor_shard_cursor`。
- 未测分片对既有 reader 的性能影响（每片多一次函数调用返回，64 格分摊，应可忽略但未测）。
- `refresh_city_output_modifier_factors` **仍未分片**，且它现在只在 city 因子完成那一片才被调用——若 city 因子跨多片，output 因子会被推迟到最后一并，第 2 片到倒数第 2 片之间它都不更新。**这是一个已知的时序副作用，M1 退出前必须处理。**

## 8. 复算方式

```powershell
cd gdext
$vcvars = 'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat'
cmd /c "call `"$vcvars`" >nul 2>&1 && cl /std:c++17 /O2 /EHsc /W4 /I src tests\city_factor_shard_test.cpp /Fe:..\.codex-tmp\shard_test.exe /Fo:..\.codex-tmp\"
& ..\.codex-tmp\shard_test.exe    # => 47 checks, 0 failures

$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_slice_budget_test.gd'
```
