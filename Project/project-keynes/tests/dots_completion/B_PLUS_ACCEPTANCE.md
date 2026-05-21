# Phase B+ 验收 SOP — season_refresh full-round single-call

> 本文档对应 `.codebuddy/plan/dots-final-frontier-b-plus/`（Phase B+ 计划）。
> 与既有 `README.md` 的 SAME_SOURCE / VS_LEGACY 验收套件**完全独立**，
> 走独立 hotkey / 验收脚本，不污染 30-tick / 1000-tick 通用矩阵。

## 1. 验收目标

把原 12-stage round 每 slice 跨界 12 次塌缩到整 round 跨界 3 次（start / run_slice × N / finish），
GDScript 端从"调度热点"退化为"薄包装"。验收门槛：

| 维度       | 阈值                          | 出处                                    |
| ---------- | ----------------------------- | --------------------------------------- |
| 等价性     | 长期均值 worst diff ≤ 0.01    | `dots_soak_ab_runner._evaluate_same_source` |
|            | 标量 worst diff ≤ 0.05        | 同上                                    |
| 性能 p95   | total_ms p95 ≤ 5ms            | `DCDotsFinalFrontierPerfVerdict.TOTAL_P95_THRESHOLD_MS` |
| 性能 p99   | total_ms p99 ≤ 10ms           | 同上                                    |
| SUS Job p95| 任一 job p95 ≤ 4ms            | 同上                                    |
| WARN 比例  | 2400 cells ≤ 0.2% / 6400 ≤ 1.5% | 同上                                  |
| B+ 健康   | fallback ratio ≤ 0.5%         | 同上                                    |
|            | slices/round ≤ 14（12 stage + 2 余量） | 同上                          |
|            | native_ms / wall_ms ≥ 90%     | 同上                                    |

## 2. 行为变更（用户已确认）

- **history.push 8→1/round**：B+ 路径下 `_sync_stage8_facade_fields_from_soa(map)`
  仅在 finish 末尾调一次，对应`push_biome_history` / `push_vegetation_history` 各 1 次/round。
  原路径每个 stage 2/3/4/5/6/7/swamp 都会触发，累计 7-8 次/round —— 实际上是
  环形 history buffer 的隐性污染。**B+ 修复后与"每季度一次状态快照"的产品语义一致。**
- **deadline 切片粒度 = b1**：以 stage 边界为最小单位，stage 中途不允许提前退。
  唯一例外是 stage 7（glacier）若实测单 stage 原子时长 > 3ms，按计划升 b2（in-stage cursor）。

## 3. 实跑步骤

### 步骤 A — 烟测（30 tick）

启动游戏 → 打开 Debug Console（`F1` 或编辑器内）→ 点击按钮 **"Soak A/B B+ 矩阵（30+1000 tick）"**。
等价命令（脚本/控制台）：

```gdscript
main.start_soak_ab_season_round_batch_debug()
```

会自动跑两段：

1. **30 tick 烟测**：A=`use_gdext_season_round=false` / B=`use_gdext_season_round=true`，
   两段都保持 `use_gdext_season_refresh=true`（B+ wrapper 内部 gate 依赖该总开关）。
2. **1000 tick 正式**：同上配置，正式 verdict 信号。

输出落在 `user://soak/last_report.txt`，**文件名前缀**为 `flags_*`（FLAG_PROFILE mode）。

### 步骤 B — 性能 verdict 评估

在 30 / 1000 tick **B 段（B+ on）跑完之后**立即手工调用：

```gdscript
# main 持有 _generator + perf_sampler；以下展示意图，具体取样接口按现有 hex_renderer
# 30s sampler / dots_soak_ab_runner 的方式拿 Array[float]
var verdict = DCDotsFinalFrontierPerfVerdict.evaluate(
    total_ms_samples,                            # Array[float]，1000 帧
    warn_count,                                  # int
    sus_job_stats,                               # Dict[String, {samples: Array[float]}]
    main._generator._last_cfg.cell_count,        # int
    main._generator.pop_b_plus_round_samples(),  # B+ 专属指标，一次性消费
)
for line in DCDotsFinalFrontierPerfVerdict.format_verdict_lines(verdict):
    print(line)
```

`pop_b_plus_round_samples()` 是 `MapGenerator` 上的累计采集器，
每个 `finish_season_round_b_plus` 完成时 append 一条记录，
调用即清零，可以重复使用做多次验收。

### 步骤 C — 等价性 verdict 解读

`user://soak/last_report.txt` 末段会有：

```
=================== DCSoakABRunner Report ===================
  mode: FLAG_PROFILE
  ...
  --- Top-15 fields by max mean_diff ---
    *** cell.temp_30d                          0.012345     ← 长期均值字段超阈值 = FAIL
        cell.temp                              0.001234     ← 标量小差异 = PASS
```

**Pass 判定**（人工核对，FLAG_PROFILE 默认 threshold=0.5 仅是 console 打印，实际人工对照阈值）：

- 长期均值（`temp_30d` / `temp_365d` / `temp_anomaly`）worst diff ≤ 0.01
- 普通标量 worst diff ≤ 0.05
- 白名单字段（`weather_type` / `weather_intensity` / ...）忽略

> **注意**：FLAG_PROFILE mode 不会自动触发 SAME_SOURCE 多阈值评估。
> 1000-tick 跑完后用户**必须**人眼核对 Top-15。
> 后续若需自动化判定，建议给 `_evaluate_same_source` 增加 `_FLAG_PROFILE_USE_SAME_SOURCE_RULES`
> opt-in（不在本次 B+ 计划范围内）。

## 4. 故障排查

### B+ 路径未生效（fallback ratio > 0%）

控制台搜索：

```
[season_refresh] gdext b_plus gdscript_fallback: <reason>
```

常见 reason：

- `gate fail (cp/ext/method)` — `use_gdext_season_round` 没翻 true，或 dots_ext 旧版本没新方法
- `soil/vg arr size mismatch with n_cells` — `bake_lat_temp_year_lut` 或 `_ensure_row_tables` 失效
- `round_knobs build failed (cfg/map/row_table)` — climate_profile 字段缺失
- `start_season_round returned fallback: <C++ reason>` — C++ 端 `pk::SeasonRoundState` 持久化异常

### slices/round 异常 > 14（b1 切片不达标）

stage 7（glacier）若单 stage 原子时长 > 3ms，会让单 slice 内只跑得起 1-2 stage，
slices/round 飙到 18-20。处理：升级 b2 切片（in-stage cursor），需要修改 C++ 端
`run_season_round_slice` 在 stage 7 内部按 cell 区间分块退出。该升级**不在 B+1/B+2 范围内**，
落在 `dots_final_frontier_perf_verdict` 报告 FAIL → 触发独立 PR。

### native_ms / wall_ms < 90%（C++ 占比偏低）

跨界 / GDScript 包装仍是热点。诊断：

```gdscript
# 在 finish 之后 dump：
print(generator._last_season_refresh_breakdown)
# 关注：b_plus_native_ms vs (Time.get_ticks_usec() - round_start) / 1000.0
```

可能原因：

- `_build_season_round_knobs` 的 PackedArray 复制（应保持引用）
- `_sync_stage8_facade_fields_from_soa` 在 finish 末尾的 GDScript 拷贝（这部分按计划保留）
- A/B 跑动时 dump 自身耗时（与 `dots_soak_dump` 并发，建议跑验收时关闭其他 overlay）

## 5. 历史归档

| 日期       | 阶段     | 结果 | 备注                                            |
| ---------- | -------- | ---- | ----------------------------------------------- |
| 2026-05-21 | B+1/B+2  | -    | C++ + GDScript 实现完成，尚未实跑              |
| 2026-05-?? | B+3 烟测 | -    | 30 tick A/B + verdict format_lines             |
| 2026-05-?? | B+3 正式 | -    | 1000 tick A/B + verdict overall=PASS / FAIL    |

跑完 1000 tick 验收后请把：

- `user://soak/last_report.txt` 复制到 `tests/dots_completion/b_plus_acceptance_<date>.txt`
- `verdict.format_verdict_lines(...)` 输出复制到同目录 `b_plus_perf_verdict_<date>.txt`

便于后续 PR 回归对照。
