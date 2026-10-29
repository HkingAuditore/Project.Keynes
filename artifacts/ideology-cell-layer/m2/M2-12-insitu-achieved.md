# M2-12 in-situ measurement achieved — the real cost

| 项目 | 内容 |
|---|---|
| 里程碑 | [M2](../22-cell-program-cap-removal-plan-v3.md) §14.3 / §14.4 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 交付 | 累计计时 `city_factor_epoch_ms` / `_slices` / `_cells`，**首次取得真实 in-situ 数据** |
| 结果 | **2000 格 / 32 片 / 14.376 ms；每格 7.19 us** |
| 结论 | M2-6 模型的误差只有 **20%**；单 slice 门禁 0.914 ms **通过但很紧** |

## 1. 关键突破：计时口径

前几轮反复拿不到真实数字，根因是**计时覆盖范围**：

```cpp
// economy_runtime.cpp:5542
_epoch_begin_city_factor_ms = elapsed_ms(city_factor_started);
```

这行在 `capture_country_epoch` 里，每次调用都被**覆盖**。而一次完整构建要调用 `refresh_city_modifier_factors` 32 次（2000 格 / 64 格每片），所以该字段留下的是**最后一片**——通常只有 16 格。

于是出现了「2000 格只用 0.003 ms」这种物理上不可能的读数（M2-10/M2-11 两轮都在追这个）。

修法：新增三个累计字段，在首次分片时清零、每片累加：

| 字段 | 含义 |
|---|---|
| `city_factor_epoch_ms` | 本 epoch **所有分片**的累计耗时 |
| `city_factor_epoch_slices` | 分片调用次数 |
| `city_factor_epoch_cells` | 处理的格数合计 |

## 2. 实测数据

```
work_cells=2000  collected=2000  processed=16  cursor=-1
epoch_ms=14.376  slices=32  epoch_cells=2000
```

| 量 | 值 |
|---|---|
| 工作集 | 2000 格 |
| 分片数 | **32**（= ⌈2000/64⌉，与设计完全一致）|
| 累计耗时 | **14.376 ms** |
| 每格成本 | **7.19 us** |
| 每片耗时 | **0.449 ms** |

对比上一轮那个误导读数 `city=0.003 ms`：**差 4790 倍**。

## 3. 与 M2-6 模型对比

| 项 | M2-6 推算 | 本轮实测 | 误差 |
|---|---:|---:|---:|
| 每格成本 | 6.0 us | **7.19 us** | **+20%** |
| 每片耗时 | 0.38 ms | 0.449 ms | +18% |
| 6400 格外推 | 38.4 ms | **46.0 ms** | +20% |

**模型基本可信**：O2 微基准的 6.0 us 与真实 debug 运行时的 7.19 us 只差 20%。这是一个少见的结果——微基准外推通常差一个量级。

## 4. §14.3 门禁判定

### 单 slice 预算：✅ 通过，但余量很小

```
city 因子每片       0.449 ms   （本轮实测）
+ epoch-open 其他开销 0.465 ms   （M1-6 实测，2400 地图）
= 0.914 ms  <  1.0 ms
```

**余量只有 8.6%。** 这需要写进方案：任何小幅变慢都会击穿门禁。

### 总延迟：需要产品确认

| 场景 | 分片数 | 总墙钟（city 因子） |
|---|---:|---:|
| 2000 格（本轮实测） | 32 | **14.4 ms** |
| 6400 格（外推） | 100 | **46.0 ms** |

46 ms 跨 100 帧完成，不是单帧卡顿。但这仍属于玩法验收问题（§597 要求不能把覆盖扩大混同于延迟已获接受）。

## 5. 这一轮纠正了三次错误结论

| 轮次 | 当时的结论 | 实际 |
|---|---|---|
| M2-9 | 「注入行被 snapshot 抹掉，测不到」 | 测得到，只是计时看错了片 |
| M2-10 | 「2000 格只需 0.003 ms，模型快 4000 倍」 | 那是 16 格收尾片的耗时 |
| M2-11 | 「`processed=16` 意味着 `total=16`」 | `collected=2000`，分片正常走完 |

三次都是我自己的推断被自己的实证推翻。**共同教训：先加可观测字段，再下结论。**

## 6. 验证

| 项 | 值 |
|---|---|
| 构建 | `scons: done building targets.`，exit 0 |
| 分片数 | 32，与 ⌈2000/64⌉ 一致 |
| `epoch_cells` | 2000，等于工作集 |
| 纯核门禁 | cap_removed 12 / cost_model 28 / ceiling 35 / materializer 65 / shard 56 |

## 7. 局限

- **只测了一个规模（2000 格）**。每格成本来自单点，未验证线性度。
- **`epoch_ms` 包含 `refresh_city_output_modifier_factors` 吗？** 不包含——两者都在 `capture_country_epoch` 里但分开计时，本字段只覆盖 city 因子。
- 未测 6400 格实测值，46.0 ms 是线性外推。
- 未测 `shared` 行变化时另加的 `map_cells × 155`（§14.1 记录的第二个成本项）。
- debug DLL 数字；release 会更快，但比例未知。
- 单次运行、`n=2` 样本（harness 丢弃 warmup）。

## 8. 复算方式

```powershell
$exe = 'D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe'
Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru `
  -ArgumentList '--headless','--path','Project/project-keynes',
    '-s','tests/ideology/ideology_cell_layer_m0_realworld_cost_test.gd'
# => epoch_ms=14.376 slices=32 epoch_cells=2000  (2000 格工作集)
```

关键代码：

| 项 | 位置 |
|---|---|
| 旧计时（单次调用） | `economy_runtime.cpp:5542` |
| 新累计计时（每片） | `economy_runtime.cpp:7182-7195` |
| 分片大小 64 | `economy_runtime.h` `CITY_FACTOR_SHARD_CELLS` |
