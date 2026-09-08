# S3 证据：Climate pass 共享化（60x40，seed 20260906，30 日）

DLL / commit 见 `build-manifest.json`。原始输出：`probe-30d-shared-round.log`、
`divergence-matrix-after-shared-round.csv`、`parity-30d-after-shared-round.{csv,json}`、
`runtime_*_test.log`（10/10 干净）。

## 这一轮改了什么

1. **9 个 pass 内核 + round 编排都成了唯一实现。**内核先前已在
   `runtime_climate_passes.cpp`；这次把 `world_ext_climate.cpp` worker main 里那 283 行
   round 编排（passes_mask 门控、尺寸守卫、逐 pass 的 in←out 接力）也搬进同一个 TU，
   生产 worker 与 SHADOW worker 现在调 `run_climate_round_passes` 同一个函数。
   编排本身必须共享：pass 顺序和接力字段差一条，分叉矩阵就会把它报成算法分叉。
2. **节拍门禁。**生产 Climate round 按 stride 跑（本地图约每 10 日一轮，实测 day
   0/7/18/28），worker 原先每天都跑。新增 `RuntimeEnvironmentSnapshot::climate_round_ran`，
   由 reference publish 按生产真实情况回填，worker 在非 round 日一个 stage 都不跑。
3. **冷启动基线。**worker store 是全零，而它拿到的第一帧 reference 已带着整个世界
   生成期的结果。第一帧改为 `adopt_reference_baseline`（收作起点，不计入对拍），
   之后每天才真的从与生产同一基线往前推。
4. **首差异槽位补进 `get_runtime_thread_report`。**先前只有 `get_runtime_perf_snapshot`
   带 `climate_parity_day/field/cell/bits`，harness 读的是前者，所以逐日 CSV 的
   day 列全是 -1、field 列全空——能说"这天红"，说不出红在哪。

5. **`run_transpiration_pass` 改为委派共享内核。**`_async_transp_kernel_pure` 与 sync
   体本来就逐行相同，所以这次委派是纯搬迁。验证方式就是它：委派前后 30 日分叉矩阵
   **逐格完全一致**（`divergence-matrix-after-shared-round.csv` vs
   `divergence-matrix-after-transp-delegation.csv`），10 个运行时测试 0 失败。
   零行为变更 + 少一份重复实现，这正是 S3 委派应有的形状，也是后续 6 个 sync 入口
   可以照抄的验收方式。

## 结果

30 日 / 2400 cell：`compared_days=30 matched_days=26 forced_days=4`。
4 个不匹配日就是生产真的跑了 round 的 4 天（day 2 是 day-0 那轮的延迟落盘，day 7/18/28
与节拍标记对齐）。**26 个非 round 日全绿**，先前是逐日全红。

PASS_A 字段（stage 0）：

| 字段 | 分叉日 | 说明 |
|---|---|---|
| `temperature_baseline` | 0/30 | 逐位相等 |
| `temperature_30d_ema` | 0/30 | 逐位相等 |
| `thermal_energy` | 1/30 | 只在 day 2 |
| `temperature_365d_ema` | 1/30 | 只在 day 2，max delta 0.0023 |

这四条在 S2 首测时是 1~4 日分叉、max delta 到 0.97。**PASS_A 已可判定为等价实现。**

## 还红的部分，以及为什么

红的字段分两类，都不是"同一份代码算出不同结果"：

1. **round 内 pass_a 之后的输出**（`sea_ice`、`convergence`、`vegetation_growth_pressure`、
   stage 13 的 `moisture`）。worker 走的是共享内核，但生产在这些天走的是
   `world_ext_climate.cpp` 里各自独立的 **sync** 子 pass（   `run_climate_pass_b`、
   ocean/wind/sea_ice），它们还没像 `run_climate_pass_a` / `run_transpiration_pass`
   那样改为委派共享内核。所以这仍是"两套实现比结果"。修法已验证两遍：把 sync 入口的
   算法体换成 建 buffer → 调纯内核 → 散射回 slot。**剩 6 个入口**（pass_b、
   ocean_water、ocean_land、wind_air、wind_surface、sea_ice）。
2. **worker 完全没有实现的 stage**：ALBEDO(8)、VEGETATION_DYNAMICS(9)、
   CLIMATE_FEEDBACK(10)、WEATHER(11)、RUNTIME_HYDROLOGY(12)、
   STAGE_B_AFTER_HYDROLOGY(13)。这些在生产侧仍是 Dictionary/MapData 耦合的大 pass
   （`run_weather_*_pass`、`run_runtime_hydrology_pass`、`_exec_node_vegetation_dynamics`），
   不具备可直接搬迁的 POD 形态。worker 在共享 round 模式下刻意让这些 lane 停在昨天的
   值，不填近似——填了会把"未实现"伪装成算法分叉。

所以 s3-green（30 日全绿）的剩余工作量是明确的两段：6 个 sync 入口的委派，加 6 个
stage 的 POD 化提取。前者是重复已验证的配方（验收标准：委派前后分叉矩阵逐格不变），
后者是本 domain 剩下的真实工作量。

在 s3-green 达成之前**不要开 S4**（1000 日）：现在跑只会得到 1000 行里约 100 行红、
且红因已知的数据。同理，块 B 的六个 domain 应等 Climate 这条链走完再开，但块 B 的前置
（把 `RuntimeClimateTrace` 的 `CAPTURED → REFERENCE_READY → CONSUMABLE → CONSUMED`
状态机抽成 domain 无关模板）与 Climate 的剩余工作无依赖，可以并行做。

## 不可放松的约束（对块 B 六个 domain 同样成立）

- `runtime_climate_passes.{h,cpp}` 与 `runtime_climate_pass_math.h` 不得 include
  godot_cpp，也不得触 `DCWorldExt` 成员。这一条就是"worker 可用"的全部含义。
- buffer 结构新增字段时，生产 kick 的提取代码与 worker 的 snapshot→buf 映射必须同步改；
  只改一边会直接表现为对拍分叉。
- `climate_round_ran` 默认 true。默认 false 会让任何没显式设过它的 fixture 静默变成
  整域 no-op —— 这次就撞上了：`runtime_domain_pod_test` 与 `runtime_climate_authority_test`
  的 self-test fixture 因此零工作量而失败。
