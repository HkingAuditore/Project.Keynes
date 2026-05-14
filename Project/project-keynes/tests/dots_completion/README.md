# DOTS 化收官验收套件（dots_completion/）

本目录承载"全面 DOTS 化收官"的所有验收脚本。规划见 `.codebuddy/plan/full-dots-completion/`。

## 设计原则：复用现有基础设施

项目已有完整的 SAME_SOURCE / VS_LEGACY 双 mode A/B 框架，**本套件不再重复实现**：

- `scripts/tools/dots_soak_dump.gd`（`DCSoakDump`）— 每 tick 把 cell SoA 字段以 SUMMARY/FULL 模式落 TSV/JSONL
- `scripts/tools/dots_soak_ab_runner.gd`（`DCSoakABRunner`）— 自动跑 A 段 + B 段 + 配对 diff + verdict
- 现有 hotkey：F3 = SAME_SOURCE A/B（30 tick），Shift+F3 = VS_LEGACY A/B（30 tick）

本目录只补两块：

1. **基线快照**：`baseline.json` — 翻 flag 之前的"参考 stat"（fast-tick 平均 ms / generate_world 后关键字段 stat），后续 PR 用作"不退化"的对比。
2. **门禁脚本**：`completion_gate.gd`（任务 10 才创建）— 把 4 巨石行数门禁、grep 直写残留、flag 注册表完整性、A/B verdict 串成 single-shot CLI。

## 验收流程模板

每个 PR 在合入前都应跑：

### 步骤 A — 100/1000 tick SAME_SOURCE A/B（runtime 路径）

```text
# 项目内启动 → F3 → 选 100 tick or 1000 tick → 等结果
# 或在代码中调用：
DCSoakABRunner.instance.start(main, 100, DCSoakABRunner.Mode.SAME_SOURCE)
```

判定：
- mode=SAME_SOURCE，**verdict=PASS** 且 `cell.temp_30d / temp_365d / temp_anomaly` 长期均值字段 worst diff ≤ 0.01
- 离散随机字段（`weather_type / weather_intensity / weather_cloud / weather_precip` 等）走白名单豁免，仅观察

### 步骤 B — 帧时间不退化对比

```text
# 翻 flag 之前 + 之后各跑 100 tick，记录：
main.get_last_fast_tick_ms()  # 每 tick 末刷新；多次取均值
```

对比 `tests/dots_completion/baseline.json` 中 `fast_tick_ms_p50/p95`：
- 翻 flag 后 p50 不得 > baseline.fast_tick_ms_p50 × 1.05（即不退化超过 5%）
- 任务 5 全部 7 个 use_gdext_* 启用后，p50 应 ≤ baseline.fast_tick_ms_p50 × 0.40（下降 ≥ 60%）

## 文件清单（按任务推进逐步补齐）

| 文件 | 任务 | 用途 |
|---|---|---|
| `README.md` | 1 | 本文件 |
| `baseline.json` | 1 | 翻 flag 前的参考 stat（人工录入或 record_baseline.gd 跑出） |
| `record_baseline.gd` | 1 | 启动游戏 → 跑 100 tick → 录平均 fast_tick_ms 到 baseline.json |
| `flag_rollout_log.md` | 5 | 7 个 use_gdext_* flag 灰度过程的 A/B 数据归档 |
| `completion_gate.gd` | 10 | 收官 single-shot 验收门禁 |

## 现有 SAME_SOURCE 字段分类（来自 `dots_soak_ab_runner.gd`）

**长期均值（threshold = 0.01，A/B 必须接近）**：
- `cell.temp_30d`, `cell.temp_365d`, `cell.temp_anomaly`

**普通标量（threshold = 0.05）**：
- `cell.temp`, `cell.temp_baseline`, `cell.sea_ice_frac`, `cell.weather_convergence`...

**白名单豁免（不计入 verdict，仅观察）**：
- `cell.weather_type`, `cell.weather_intensity`, `cell.weather_cloud`, `cell.weather_precip`
- `cell.weather_vapor`, `cell.weather_instability`, `cell.temp_season_offset`
- `cell.moisture`, `cell.snow_cover`

收官期任何"翻 flag"PR 必须：
1. **不引入** 长期均值字段 worst diff > 0.01 的退化（否则 storage / pass 实现有 bug）
2. **不引入** 普通标量字段 worst diff > 0.05 的退化
3. 白名单字段允许有差异但需肉眼比对趋势，无系统性偏移

