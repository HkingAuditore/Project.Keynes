# S3 实测结论：共享 pass 提取与 30 日对拍

对应 plan「Climate 对拍可比性修复路线」的 S3。本文只记录**跑出来的结果**，不记录设想。

复现命令（GODOT_BIN 见 §5）：

```
godot --headless --path Project/project-keynes -s tests/climate_parity_probe.gd \
    -- days=30 seed=20260906 label=<tag> out=<repo>/artifacts/runtime/s3-shared-passes
```

DLL 溯源见同目录 `build-manifest.json`（git HEAD `c3255fcc`，工作树有未提交改动）。

---

## 1. 当前对拍状态

固定 60×40、seed 20260906、30 日：

| 指标 | 值 |
| --- | --- |
| compared_days | 30 |
| matched_days | 26 |
| forced_days | 4（day 2 / 7 / 18 / 28） |
| 分叉字段数 | 28 / 34（其中 3 个标为不可比） |

**S3 的完成定义（30 日全绿）未达成。** 但四个失配日不是随机分布的，它与生产的
round 节拍严格重合，这一点是本轮最重要的可用信息。

## 2. 生产 Climate 的真实节拍（首次测出）

`[publish][cadence]` 诊断显示，30 日窗口内生产只在 **day 0 / 7 / 18 / 28** 跑
climate round，albedo 段只在 **day 7** 跑过一次：

```
day=0  round_ran=1 albedo_ran=0
day=1..6  round_ran=0
day=7  round_ran=1 albedo_ran=1
day=8..17 round_ran=0
day=18 round_ran=1 albedo_ran=0
day=28 round_ran=1 albedo_ran=0
```

间隔 7 / 11 / 10 天，不规则。成因是三层 cadence 叠加，全部在生产侧：

- weather bucket：`sim_stagger_bucket_stride`=8 + `sim_stagger_weather_phase`=4
  （`dc_system_scheduler.gd`、`sus_policy.gd::StridePolicy.should_run`）
- stage_b 子 stride：albedo 10 / vegetation 5 / feedback 10，按 weather 调用次数计
  （`map_generator.gd::_build_native_daily_stage_b_knobs`）
- hydrology 的 `dt_days` 取 `_native_daily_contract_stride_days()`

**推论：失配全部落在生产真的算过东西的那几天。**其余 26 天两边都没动，"全绿"里
只有 4 天是真正被比较过算法的。所以 30 日窗口的信息量远低于日历天数所暗示的，
S4 的 1000 日窗口实际只会包含约 130 个有效比较日。

## 3. 本轮修掉的三个真实缺陷

### 3.1 生产侧存在三份逐字重复的 albedo 实现

`run_albedo_pass` / `run_albedo_pass_thread` / `run_stage_b_pass` 的 ① 段，三个主
循环逐行相同。已全部下沉到 `pk_async_climate::albedo_apply_pure`，`_thread` 变体
按 `run_climate_pass_a_thread` 的先例直接转发。

albedo 是一个仿真日内 `temp_arr` 的**最后一个写者**（round 末尾定温之后再叠一层
反照率反馈），这也解释了为什么 S2 矩阵把 `temperature` 的 stage 标成
CLIMATE_FEEDBACK —— parity 的 stage 标签记的是"日内最后写者"，而 feedback pass 本身
并不写 temp。

### 3.2 worker 的 round 输入只有 pass_a 的 lane，后 7 个 pass 静默跳过

`_production_round_input` 是在 `run_climate_pass_a` 里留存的 `kin`，只含 pass_a 自己
的 lane。`mark_reference_ready` 原先用它**整体覆盖** capture 侧的缓冲，于是
pass_b→sea_ice 全部撞上 `run_climate_round_passes` 的尺寸守卫被跳过，`out.temp` /
`out.sea_ice_frac` / `out.moisture` 留空，而 kernel 的 scatter 只做长度检查 ——
**整段变成 no-op，并且没有任何回报**。

表现出来就是"worker 跑了 round 但温度场停在昨天"，与算法分叉在分叉矩阵里长得一模
一样。实测 day 7 worker 的 `temp[60]` 恰好等于 day 2 的 reference 值。

修法是分层而不是二选一（`pk_async_climate::overlay_production_pass_a`）：capture 侧
缓冲提供全 9 pass 的 lane，生产缓冲覆盖 pass_a 的权威输入与标量子集。标量必须逐字段
覆盖 —— 生产那份只填了 pass_a 段，整体覆盖等于把后续 pass 的 knobs 全清成默认值。

**反向验证做过**：只用 capture 那份（不叠加）时，PASS_A 的
`temperature_baseline` / `temperature_30d_ema` 从 0 个分叉日恶化到 3 个，
`thermal_energy` / `temperature_365d_ema` 从 1 恶化到 4。叠加后全部恢复。

### 3.3 "静默跳过"本身不可观测

已给 `ClimateRoundPassTiming` 加 `passes_ran` / `passes_starved` 两个 bit mask，9 个
pass 全部插桩，并经 `RuntimeClimateKernelReport` 上报。starved（被 mask 启用但输入
lane 不足）与算法分叉是两类问题，混在一起会让分叉矩阵完全误导。

修完后实测：`ran=0x1BF starved=0x40` —— 9 个 pass 里 8 个真的在跑，只剩 sea_ice 饿死。

### 3.4 pass_b→sea_ice 吃的是结构默认 knobs，不是生产的 knobs（已修）

lane 级诊断先把 sea_ice 的饿死缩到一条 `water_terrain_ids=0`（其余 7 条都是 2400），
顺着这一条查出的是更大的问题：

probe 走 native_daily 路径时 `ClimateDailySystem` **根本没注册**
（`map_generator.gd::_build_runtime_climate_round_input` 会打出
`no ClimateDailySystem; SHADOW capture carries no shared pass input` 并返回空字典）。
per-cell lane 因为 `prefer_slot_lanes=true` 从 `_slots` 兜底填满了，所以表面看不出问题；
但**标量与非 per-cell 的 LUT 没有兜底来源**：pass_a 段靠 §3.2 的 overlay 拿到了生产真值
（所以 PASS_A 全绿，掩盖了问题），而 `pb_*` `ow_*` `ol_*` `wa_*` `ws_*` `si_*` 全是
`ClimateRoundScalars` 的结构默认值。

修法是把 §3.2 的"生产如实留存自己用过的输入"从 pass_a 推广到其余 6 个 sync pass：新增
`DCWorldExt::record_production_round_scalars(pass_bit, knobs)`，在每个 pass 拉完标量之后
调用，读的就是那个 pass 自己用的 Dictionary，所以不产生第二个取值来源。发布侧走
`overlay_production_round_scalars`。`water_terrain_ids` 是静态 LUT，改走
`ClimateRoundStaticKnobs`。

这一步顺带测出一件事：**生产在本地图根本不跑 ocean_water / ocean_land**
（`prod_knobs=0x72`，缺 0x04|0x08）。overlay 会据此把它们从 worker 的 `passes_mask` 里
摘掉（`0x1FF` → `0x1F3`），否则 worker 会用默认 knobs 单方面跑两个生产没跑的 pass。

修完后 `ran=0x1F3 starved=0x0` —— 生产启用的 pass worker 全跑，一个不饿死。

---

## 4. 剩余阻塞点

### 4.1 stage 9–13 在 worker 侧完全没有实现（唯一剩余原因）

生产侧主体全在 C++（不在 GDScript），位置已查清：

| stage | 生产实现 | 规模 |
| --- | --- | --- |
| 9 VEGETATION_DYNAMICS | `world_ext_climate.cpp::run_vegetation_dynamics_pass` L4413–5074 + `run_stage_b_pass` ② 段 | 中，cell-local + 6 张 LUT |
| 10 CLIMATE_FEEDBACK | `run_climate_feedback_pass` L5085–5272（写 base_moisture / soil / veg_pressure，**不写 temp**） | 中，需 neighbor_indices |
| 11 WEATHER | `world_ext_weather.cpp` field_solve L245–1607 + commit + distribute + fronts | **大**，约 1400 行 solve，fronts 产 `Array[Dictionary]`，Godot 耦合高 |
| 12 RUNTIME_HYDROLOGY | `run_runtime_hydrology_pass` L3616–4103 | 大，河网 DAG + canal 编译态 + defer publish |
| 13 STAGE_B_AFTER_HYDROLOGY | 非独立算法，是 graph 里 hydrology 之后再跑 `run_stage_b_pass` 的调度节点 | 编排 |

提取难度排序（易→难）：albedo（**已完成**）→ climate_feedback → vegetation_dynamics
→ weather field core → hydrology → stage_b_after 编排。

分叉矩阵里 stage 9 / 11 / 12 的字段 worker 侧大量为 0，就是"完全没跑"的直接体现，
不是数值分叉。`temperature` / `moisture` / `sea_ice` 的残余分叉是这些 stage 缺失的下游
效应（它们的输入被上游未实现的 stage 污染），不是 stage 0–8 本身的算法差异。

**输入边界侧已经没有已知缺口。**`starved=0x0`、`prod_knobs` 覆盖生产实际跑过的每个
pass、cadence 按 `climate_round_ran` + `climate_albedo.ran` 双独立门控。所以现在分叉矩阵
上的每一条都能一对一映射到"哪个 stage 还没提取"，这正是 S2 矩阵原本要提供而当时提供不了
的东西。

## 4.2 最终矩阵状态（label=s3seaice）

| 指标 | S2 首测 | 现在 |
| --- | --- | --- |
| 分叉字段数 | 28 | 28 |
| 分叉 cell 累计 | 78504 | 78532 |
| 分叉日 | 4 | 4 |
| round pass 实跑 | 1（仅 pass_a） | 0x1F3（生产启用的全部） |
| round pass 饿死 | 未可观测 | 0x0 |

字段数没降是预期的：本轮修的是**输入边界与归因**，不是新增 stage 实现。唯一新增的
stage 实现是 albedo（stage 8），它只影响 `temperature`。字段数要降必须等 stage 9–13。

## 5. 环境约定

`GODOT_BIN` = `D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe`

## 6. 对 S4 与块 B 的估算影响

- **S4 应在 stage 9–13 提取完成后启动。** 输入边界的混淆因素已经清掉，但现在跑 1000 日
  只会把同一批"stage 未实现"重复 130 次。plan §2.1 批评原文档直接跑 1000 日的理由仍然
  成立，只是原因从"三类混在一起"收敛成了一类。
- **块 B 的方法复用性得到了正面验证**，但要复用的不止 parity hash：
  「生产如实留存自己用过的输入 → 随 reference 发布 → worker 吃同一份」这套输入边界
  机制，以及 `passes_ran` / `passes_starved` 这种"跳过必须可观测"的约束，同样是每个
  domain 都要重做一遍的地基。
- **`stage_hash[14]` 仍然不需要做。** 本轮所有定位都靠 field/cell 首差异 + lane 级
  长度回报完成，零 ABI 成本。
