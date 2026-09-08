# P3 findings — pass_b 合流完成，剩余分叉不是"再提取一个 pass"能解的

证据：`parity-30d-parity30.*`（tag 参数没被 probe 认，落在 `parity30` 名下）、
`divergence-matrix-parity30.csv`、`stage-cadence-parity30.csv`，
对照基线 `divergence-matrix-p3dist.csv`。

## 1. pass_b：四份实现合成一份，逐位中性

pass_b 此前有四份独立实现：

| 实现 | 位置 | 状态 |
|------|------|------|
| scalar `run_climate_pass_b` | `world_ext_climate.cpp` | 已改为调用共享内核 |
| `pass_b_land_compute_temp/_evap/_rain_shadow` + `pass_b_run_land_range`（`_simd` / `_thread` 用） | 同上 | 三个 helper 已删除，range 驱动改为薄适配器 |
| worker `_async_pass_b_kernel_pure` | `runtime_climate_passes.cpp` | 已改为调用共享内核 |
| 三份重复的海冰反照率尾循环 | 上述各处 | 合并为 `climate_pass_b_sea_ice_tail_pure` |

共享内核：`pk_async_climate::climate_pass_b_pure` / `_land_range_pure` /
`_sea_ice_tail_pure`（`runtime_climate_passes.h/.cpp`），per-land-cell body 一份。

**重要修正**：生产热路径不是 scalar `run_climate_pass_b`，而是
`run_climate_pass_b_thread`（`world_ext_daily_sim.cpp:1021` 与 `:2539`、
`system_schedule.cpp:100` 三个调用点）。只改 scalar 版对 parity 没有任何作用，
所以 `_thread` / `_simd` 走的那三个 helper 才是必须合并的对象。

逐行比对发现 worker 那份与生产只差一处：

```cpp
// worker 独有，生产 pass_b 没有
if (!is_water && in.cover[i] == 2 && snow_cover < 0.80f) snow_cover = 0.80f;
```

（`cover == 2` = GLACIER。albedo pass 与 weather_distribute 都有这一钳位，
worker pass_b 大概是照它们补的。）合流时按生产语义去掉。

结果：30 日对拍 `compared=30 matched=27 forced=3`，分叉矩阵与合流前
**逐字节相同**。也就是说这次重构可证明是行为中性的，同时那条 glacier 钳位在
这张图上是潜伏的（60x40 seed=20260906 没有同时满足 land + GLACIER +
snow_cover<0.80 的格子）。潜伏不等于无害——它换张图就会生效。

## 2. 剩余分叉的真实成因：worker 跑的是 weather solve 的另一个变体

分叉矩阵里 WEATHER 一组的 worker 值极有说服力：

| field | reference | worker |
|-------|-----------|--------|
| weather_precipitation | 0.0335 | **0** |
| weather_intensity | 0.0463 | **0** |
| cloud_water | 0.0246 | **0** |
| cloud_cover | 0.0888 | **0** |
| instability | 0.1231 | **0** |
| weather_target_type | 3 | **0** |
| weather_transition_alpha | 0.35 | **0** |
| vapor | 0.1254 | 0.0026 |

worker 侧成片的**字面零**，不是算法偏移。而 `stage-cadence` 显示
WEATHER `production_days=3 / worker_days=3 / missing=0`——stage 确实跑了。
跑了却写出零，指向输入/输出接线，不是内核数学。

根因线索（`runtime_climate_kernel.cpp:915`）：

```cpp
knobs.use_next_outputs = false;   // worker 硬编码
```

而生产的 `use_next_outputs` 是按 caller 是否提供 `out_*` buffer 推断的
（`world_ext_weather.cpp:570-574`），native daily staged 路径下为 true。两个分支
写的目标完全不同：

- `use_next_outputs = true`（生产 staged）：写调用方给的 next buffer，
  `OUT_TYP_I32` 写 int32 类型，而 `OUT_PREV_TYP` / `OUT_TARGET_TYP` /
  `OUT_ALPHA` / `OUT_FIN` 全是 **nullptr**。
- `use_next_outputs = false`（worker 强制）：写 slot，`OUT_TYP` 写 uint8，
  并写 transition 三条与 `field_init`。

于是 worker 与生产在同一个 stage 上跑的是同一个内核的**两条不同分支**。
`weather_target_type` / `weather_transition_alpha` 生产在 staged 分支里根本不写
（由别处写），worker 在 direct 分支里写——两边不可能对上。

另一处同类嫌疑：worker 每轮 `_weather_field_init_scratch.assign(cells, 0u)`
把 `field_init` 清零。它在 solve 里是纯输出（恒置 1），但在
`weather_distribute` 里是**读入**（`runtime_climate_passes.cpp:3666-3670`：
`field_init ? WT_[i] : wt_clear`、`intensity = field_init ? WI[i] : 0`）。
若 distribute 读到的是清零后的那份，天气会被当成"未初始化"，intensity 与
precip 直接取 0。

## 3. 结论：P3 剩下的不是提取工作

`run_sea_ice_daily_pass` 的提取（原 todo `p3-seaice`）仍值得做——它是同一套
配方、能消掉一份平行实现。但**它不会让 30 日转绿**：sea_ice 的
`worker=0.56 / ref=0.884` 很可能是 WEATHER 接线问题的下游（sea ice 读
snow_cover / temperature）。

## 4. 已做的 staged 改造（已落地，行为中性）

按上面的判断做了三件事，30 日仍是 `matched=27`，分叉矩阵逐字节不变：

1. `run_weather_field_commit_pass` 的计算体（118 行）提取为共享内核
   `pk_async_climate::weather_commit_pure`（knobs/lanes/stats 三段式），生产
   改为调用它。
2. worker 的 WEATHER stage 从 direct 分支切到 staged：新增
   `_wx_next_*` 一组 next buffer + `_wx_next_type`（int32），solve 时
   `use_next_outputs = true`、transition 三条与 `field_init` 置 nullptr
   （与生产 `world_ext_weather.cpp` 的 `use_next_outputs=true` 分支一致），
   随后调用 `weather_commit_pure`。
3. 修掉 `_weather_field_init_scratch` 每轮 `assign(cells, 0)`。它是"这张图的
   天气场是否已解算过"的长期标志，一置 1 就应保持；每轮清零会让 distribute
   侧永远读到"未初始化"。现在只在首次分配。

这三条是结构上正确的（worker 与生产终于跑同一条 staged 路径），但**没有**改变
任何 parity 数字。所以 direct/staged 分支差异不是 WEATHER 分叉的成因。

## 5. 实测到的真实边界（诊断输出，已从代码里摘除）

在 worker 的 WEATHER stage 前后打点，day 7（首个 weather 日）读到：

```
solve IN  store{vap=0 cld=0 cw=0 pre=0 cnv=0 ins=0}  rec{temp=1160.6 ...}
commit    nextpre_sum=0  store_pre_sum=0  store_vap_sum=102.1  trans=1 rate=0
knobs     evap=0.45 cond=0.45 advect=4 diff=0.025 precip_base=0.08
          conv_precip=1.95 lift_precip=0.45 syn_enh=0.45 syn_base=1.55
          anomaly=0 refresh_cnv=0
```

读法：

- **knobs 是生产真值，不是结构默认**（evap 默认 0.55 实测 0.45，advect 默认 3
  实测 4，diff 默认 0.04 实测 0.025）。knobs 记录链路是通的。
- **solve 之前 worker 的天气 store 全零**。这与冷启动一致：`vapor` /
  `convergence` 等在 parity 表里都是 comparable，冷启动 `ref_hash ==
  adopted_parity`，所以生产 day 1 的这几条本身也是零。两边同起点。
- solve 之后 worker 全图 precip 累加**恰好为 0**，vapor 累加 102.1（均值
  0.0425）。
- `rate=0`：`weather_transition_alpha_rate` 在记录到的 solve knobs 里是 0。

关于 `rate=0` 的一个反转：生产的 commit 读的是**同一个** dict
（`weather_system.gd:1057` 的 `_field_slice_native_knobs`，commit 前在 1073 行
重写该键），所以生产侧也应该拿到 0、算出 `alpha = rate * dt = 0`。可参考值是
0.35。也就是说 `weather_transition_alpha` 的 0.35 **不是** commit 的 transition
状态机写的，另有写者。这一条需要单独定位，不能按"worker 取错 dict"结案。

## 6. 分叉规模的重新读法（重要）

之前把 WEATHER 一组读成"worker 成片写零"是过度概括。按 `diverged_cells` 看：

- `weather_precipitation` / `weather_intensity` / `weather_target_type` /
  `weather_transition_alpha`：各 **7 格**。生产在这 7 格有天气，worker 没有。
- `cloud_cover` 1797 / `cloud_water` 1784 / `instability` 1807：约 3/4 图。
- `vapor`：**2400 格，全图**，max delta 恰好 0.150000017。
- `snow_cover` 236 / `snowpack` 234；`sea_ice` 1171。

`vapor` 全图分叉、且 max delta 与 `temperature` 的 0.150000036 同为 0.15 量级，
是最该先查的一条：全图一致的偏移通常来自单个标量或单条输入 lane，而不是逐格
算法差异。查清 vapor 后，cloud / instability / precip / sea_ice / snow 很可能
是它的下游。

## 7. 下一步

1. 定位 `vapor` 全图 0.15 偏移的来源（单标量或单 lane 嫌疑最大）。
2. 定位 `weather_transition_alpha` = 0.35 的真实写者（不是 commit 的状态机）。
3. 两条清掉后再复跑，重估 SEA_ICE / CLIMATE_FEEDBACK / RUNTIME_HYDROLOGY 残余。
4. `p3-seaice` 提取仍值得做（消掉一份平行实现），但它不是转绿的必要条件。

## 8. 回归测试

`runtime_climate_parity_test` / `runtime_climate_authority_test` /
`runtime_climate_save_roundtrip_test` 全通过。

`canal_runtime_test` 有 1/27 失败，**与本次改动无关，是既存的过期断言**：

```
restore debug saved=51 ... hash_before=1988562796112191413 hash_after=7815047916191338403
[FAIL] PKEC v42 restores an in-flight canal project exactly
```

测试断言 `schema == 43`，实际 PKEC schema 已是 **51**（经济侧序列化版本被别处推
进过），同时 `restored_buildings=0` 导致 restore 前后 economy hash 不等。本次改
的是 pass_b、weather commit、hydrology 运河成员改名三处，都在 climate 侧，且
`grep _canal_hydrology|_hydrology_canal` 确认改名没有任何序列化引用。这条应单独
立项（要么把断言更到 51，要么修 restore 丢 building 的真问题）。

## 9.5 wind_air / wind_surface / sea_ice 合流后的实测（本轮）

三个 pass 都从"生产一份 + worker 一份平行重写"合成了单一共享内核
（`wind_air_pure` / `wind_surface_pure` / `sea_ice_pure`）。合流过程中查出的
真实差异，按影响从大到小：

1. **worker 的风场恒为零。** `cell_wind_x/y/speed` 是 slot 产物，但
   `override_climate_round_input_from_slots` 的清单里没有它们，worker 侧一直是
   空 lane。风一零，air-mass 平流整段失效 → `ain` 偏 → 温度偏 → 天气与海冰全部
   跟着偏。同批补进清单的还有 `pos_x/y`、`insolation_dev`、
   `temperature_transport_anomaly`、`temp_baseline`、`air_mass_temp_anomaly`、
   `ocean_current_x/y`、`ocean_thermal_anomaly`、`upwelling_strength`、
   `insolation_now`、`sea_ice_frac`、`landform`、`vegetation`、`base_terrain`。
2. **worker 的 wind_air 缺轨迹表分支与 `isfinite` 回退**，baseline 也取错
   （用 `temp_baseline_year`，生产用 `_build_native_wind_baseline` 的缓存数组）。
   三者都不是 slot，新增 `WindAirInput` 记录并 overlay。风场本身也一并记录：
   physics 的解算跨 tick 分片，capture 抓快照的时刻与生产真正读 slot 的时刻不在
   同一片上，两边拿到的是同一 tick 内风向略有旋转的两份值。
3. **pass_b 的 `sea_ice_frac` lane 在 worker 侧是空的**（生产从
   `map.sea_ice_frac_arr` 取）。空 lane 让 pass_b 的水域尾循环整段静默跳过 ——
   而那是水格唯一的 LANOM 来源。新增 `ClimatePassBInput` 记录。
4. **worker 的 sea_ice 是 2026-06-16 那版算法的抄本**：单步
   `d_frac = clamp(rate) * dt_days`，solar_melt 用 `prev_frac` 算一次遮蔽。生产
   2026-06-28 已换成按日子步积分。`dt_days == 1` 时两者逐位等价，所以这个漂移
   只在加速档下暴露。

效果（30 日，60x40 seed=20260906，`matched` 仍是 27/30 —— 日级门是二值的，
不全绿就不动）：

| field | 合流前 cells | 合流后 cells |
|-------|-------------|-------------|
| temperature | 6729 | 3632 |
| moisture | 3537 | 1687 |
| sea_ice | 1171 | 126 |
| snow_cover | 236 | 79 |
| river_discharge | 1515 | 769 |
| runoff / groundwater | 1239 | 714 |

## 9.6 链头定论：`oanom` —— 而它是**分片 pass**，不是平行实现

用 `PK_WS_PROBE_CELL` 探针把 `wind_surface` 的温度分量在生产与 worker 侧并列
打出来（day 7，cell 79 = 分叉矩阵的第一格）：

```
生产   base=0.00824610516 oanom=-0.00620139297 ain=-0.00383240776 lanom=-0.00340265129
worker base=0.00824610516 oanom=0             ain=-0.00383240776 lanom=-0.00340265129
```

`base` / `ain` / `lanom` 三项**逐位相同**，唯一差的是 `oanom`。生产 `temperature`
的参考值是 0（`total < 0 → 0` 的下限钳出来的），worker 是 0.00101 —— 真实差只有
0.006 量级，被钳位放大成"首格分叉"。

`oanom` 为零的链路是清楚的：`pass_a_pure` 在末尾把
`ocean_thermal_anomaly` / `local_thermal_anomaly` 清零（开启新一日累加），之后
本该由 OCEAN_WATER / OCEAN_LAND 重新填。worker 的 round mask 里这两位是关的
（`overlay_production_round_scalars` 只放行生产记录过标量的 pass），所以清零之后
再没人填。

但**打开 mask 不能解决它**。生产的 ocean 两个 pass 是**跨 tick 分片**的
（`map_generator.gd:16618` `_run_ocean_water_pass_slice_impl`）：

- 跨 tick 常驻 `_climate_ocean_slice_state`，含游标 `water_cursor` 与一份持久
  `anomaly` buffer；
- 每片只算 `[start_idx, end_idx)`，区间由 `_ocean_slice_budget_cells()` 决定；
- **区间外的格子保留上一片的旧值**，可能是上一个仿真日的。

也就是说任一时刻生产的 `oanom` 是"本日新值 + 前几片/前一日旧值"的混合态。
worker 一次跑全图，无论内核多么一致，都复现不出这个混合态。

这与 §5 已记录的 WEATHER 情况是**同一个结构性错配的第二例**：生产把 pass 分片
摊到多个 tick，每片带自己的 knobs 与区间；worker 一次跑满量程。

### 补充证据：`prod_knobs` 恒为 0x72，ocean 两位从不置位

已有的 `[publish][cadence]` 诊断把每次 publish 的生产标量掩码打了出来。30 日里
每一个 round 日都是同一个值：

```
[publish][cadence] day=0  round_ran=1 prod_knobs=0x72 stages=0x0
[publish][cadence] day=7  round_ran=1 prod_knobs=0x72 stages=0x1F00
[publish][cadence] day=18 round_ran=1 prod_knobs=0x72 stages=0x1800
[publish][cadence] day=28 round_ran=1 prod_knobs=0x72 stages=0x1800
```

`0x72` = pass_b(0x02) | wind_air(0x10) | wind_surface(0x20) | sea_ice(0x40)。
**ocean_water(0x04) 与 ocean_land(0x08) 一次都没置位**，尽管
`run_ocean_water_pass` / `run_ocean_land_pass` 里都有
`record_production_round_scalars`。

同时 `run_climate_pass_a` 并**不**分片（`start_idx` / `end_idx` 在
`world_ext_climate.cpp` 里只有 ocean 两个 pass 用），所以生产的 pass_a 会把全图
`oanom` 清零。而 `[publish][self-delta]` 在所有非 round 日都是 `changed=0`，
排除了"日间有隐藏写者"。

三条放在一起是自相矛盾的：pass_a 清零全图、ocean 不跑、日间无写者，
生产的 `oanom[79]` 却是 -0.0062。唯一自洽的解释是**生产的 stage 执行跨 tick
被切开**（native daily graph 的 `_native_daily_slice_bundle`），
以致「day N 的 wind_surface」实际执行在「day N 的 pass_a」之前，读到的是上一日的
`oanom`。worker 的 round 是一次跑完的，不存在这种跨日错位。

顺带一个否证：为验证"把分片预算放到全图能否对齐"，给
`_ocean_slice_budget_cells()` 加了 `PK_CLIMATE_UNSLICED` 开关跑了一次 30 日 ——
结果与之前**逐字节相同**。原因是那个开关作用在 `map_generator.gd` 的 GDScript
分片路径上，而对拍探针走的是 native daily graph。开关已撤除。

### 由此对 `p3-green` 的判断

30 日 `matched=30 forced=0` **不是再提取一个内核能达到的**。剩余分叉的成因已
不是重复实现，而是 cadence/分片调度的差异。要在 SHADOW 下逐位对上，worker 必须
连生产的分片时序一起复刻（游标状态、每片区间、预算）—— 而这恰好是 P7 要拆掉的
东西：Climate 转 ACTIVE 之后 worker 自己就是权威，生产的分片路径整条消失，
"对一个分片生产路径逐位相等"这个目标本身也随之失效。

## 9.7 一个既存的测试断言错误（非本轮引入）

`native_sea_ice_state_machine_test` 的
`thick ice does not melt at the full daily cap under sun` 失败。手算与实测都是
**恰好 0.75**，而断言要求 `> 0.75`：

```
prev=0.8 t_eff=0.02 freeze_gate=0 solar_melt_base=0.48
exposure(0.8, 0.32)=0.32 → rate=-0.1536 → clamp(-0.05) → 0.8-0.05 = 0.75
```

用**未被本轮改动**的 `run_sea_ice_daily_pass_thread`（还是旧单步算法）跑同一组
knobs，也是 `0.750000000`。两套算法给同一个值，说明这条断言两边都不成立，
是既存的边界写错（与 §8 的 `canal_runtime_test` schema 断言同类）。

## 10. 一次未复现的崩溃

`days=12` 的一次运行在 day 4～5 之间以 `0xC0000005` 退出（`probe-wxdiag4.log`
末尾停在 day 4 的 boundary 行）。同一份 DLL 重跑三次未再现。worker 线程路径上
的偶发访问越界，值得单独立项排查，不要当噪声放过。

补一次同类观测：`probe-fin30.log` 在 day 17 附近无 summary 就终止，紧接着用同一份
DLL 重跑（`probe-fin30b.log`）exit=0 且跑满 30 日，结果逐位相同。同一现象第二次
出现，进一步支持"偶发"而非"确定性崩点"的判断。

## 11. 修正：分叉的主因不是分片调度，而是"权威归属"记错了

§9.6 把 `oanom` 的链头判成了「生产 stage 跨 tick 分片，worker 复刻不了」，
并由此推论 `matched=30` 不可达。前提对，结论跳步了。

前提确实成立：生产的 ocean stage 跑在 climate round 之外、按 `start_idx/end_idx`
跨 tick 分片。但由此该得出的不是「worker 必须复刻分片时序」，而是
**「在 SHADOW 下 worker 根本不是这些量的权威」**。对不属于自己的量，worker 该做的
是照 `WindAirInput` / `ClimatePassBInput` 的既有配方**在消费点抽生产的值**，
而不是自己算一遍再指望算得一样。

按这个思路连做三处，`temperature` 的分叉格数从 6729 掉到 9：

| 改动 | temperature 分叉格 | max_delta | 连带 |
|---|---|---|---|
| （本节之前） | 6729 | 0.1257 | moisture / 水文 / weather 全组 first_day=7 |
| ① `oanom` 归生产权威 | 536 | 0.0491 | sea_ice 126→40，snow 79→59 |
| ② `TTA` 归生产权威 | **9** | 0.0211 | moisture 与水文四项 first_day 7→**28** |
| ③ finalizer 合成 double 内核 | 9（逐位不变） | 0.0211 | 行为中性 |

### ① `ocean_thermal_anomaly`

pass_a 末尾清零 oanom 开启新一日累加，本该由 OCEAN_WATER/OCEAN_LAND 重新填，
但那两个 pass 在 round 之外分片跑（`prod_knobs` 恒 0x72，ocean 两位从不置位）。
于是生产的 wind_surface 读到的是一份跨日携带的值，worker 读到的是自己刚清的 0。

做法：`WindSurfaceInput` 在生产 `run_wind_surface_pass` 的**消费点**记下真正读到的
那份 oanom（不是 publish 时的 slot 快照 —— 两者时刻不同），worker 在 pass_a 之后
注回 `in` 与 `out` 两侧（wind_surface 取 `choose_field(out, in)`，只写一边会被另一边
的清零盖掉）。`lanom` 不在此列：它由 pass_b 在 round 内重新累加，worker 是它的权威。

### ② `temperature_transport_anomaly`

比 oanom 更隐蔽：它根本不是 slot，而是 `knobs["temp_transport_anomaly"]` —— GDScript
从 `map.temperature_transport_anomaly_arr` 传入，而那份数组同样由分片 ocean pass
逐片增量写（`map_generator.gd:16651`）。之前给 `cell_temperature_transport_anomaly`
加的 slot overlay 抽到的是**另一份**数据，所以一直没起作用。

pass_b 的 `d_coastal` 与 `d_evap` 两项都读邻居的 TTA，读错就让 LANOM 偏，再沿
wind_surface → temperature 传下去。改成随 `ClimatePassBInput` 在消费点抽之后，
day 7 的 moisture 与水文四项直接转绿（first_day 7 → 28）。

### ③ finalizer

生产 `run_native_daily_finalizer` 顶上写着：GDScript 的 float 是 64 位，
`clampf`/`absf` 都在 double 里算，只有存回 PackedFloat32 时才收窄；
「float32 内核会在 TTA clamp 上偏 ~1e-5 并传进下一轮的 ocean/weather/hydrology」。
worker 的 `_async_finalizer_kernel_pure` 全程 float，正踩这条。

合成 `finalizer_pure`（全程 double，只在写回收窄）后 30 日结果**逐位不变** ——
说明这一条在本图上是潜伏的，不是当前 9 格的成因。它的价值在防回归：第二份 float32
抄本消失了，往后两边不会再各自漂移。

## 12. 剩余分叉与重定义后的对拍口径

30 日：`compared=30 matched=27 forced=3`。day 7 剩余：

| 组 | 字段 | 格数 | 判定 |
|---|---|---|---|
| CLIMATE_FEEDBACK | temperature | 9 | 待查：wind_surface 出口已逐位相等，差在 ALBEDO/VEGETATION/FEEDBACK 三个 round 后 stage |
| RUNTIME_HYDROLOGY | plant_available_water / water_balance_30d | 1835 / 2271 | 待查 |
| WEATHER | vapor / cloud_water / cloud_cover / instability | 2400 / 1784 / 1797 / 1807 | **容差类**：生产按片跑、每片一套 knobs，worker 整图跑一次 |
| WEATHER | precipitation / intensity / target_type / transition_alpha | 7 | 同上，随 vapor |
| WEATHER | snow_cover / snowpack | 47 | 同上 |
| SEA_ICE | sea_ice | 39 | 同上（读 weather 与 temp） |

`temperature[1827]` 的 wind_surface 出口探针两边**全项相同**
（base / oanom / ain / lanom / transport / total_anom 逐字相同），所以这 9 格出在
round 之后的三个 stage，是下一个可查的具体目标 —— 不是分片问题。

### 重定义后的口径

- **非分片 stage 逐位相等**：PASS_A / PASS_B / WIND_AIR / WIND_SURFACE / SEA_ICE 的
  round 内输出、finalizer。现已基本达成（temperature 9/2400 = 0.4%）。
- **分片 stage（WEATHER、OCEAN_*）容差比较 + 分片对齐检查**：不要求逐位，改为比对
  分片游标与每片区间是否对齐、量级是否在容差内。理由是 P7 让 Climate 转 ACTIVE 之后
  生产的分片路径整条消失，"对一个分片生产路径逐位相等"这个目标本身会失效，
  为它复刻游标状态是纯浪费。
- 对"归生产权威"的量（oanom / TTA / wind 快照 / sea_ice_frac），在 P7 拆除同步路径时
  必须逐条回头确认 worker 能自产 —— 这是这批 overlay 的**偿还清单**，不是永久设计。

## 13. 回归确认（本轮全部改动之后）

| 测试 | 结果 |
|---|---|
| `runtime_climate_parity_test` | PASS |
| `runtime_climate_authority_test` | PASS |
| `runtime_climate_save_roundtrip_test` | PASS |
| `runtime_protocol_guard_test` | 8 checks, 0 failures |
| `runtime_thread_isolation_test` | 18 项全 PASS |

§9.7 的 `native_sea_ice_state_machine_test` 与 §8 的 `canal_runtime_test`
仍是既存断言错误，非本轮引入。

## 14. 再一次修正：ocean 其实一直在跑，`prod_knobs` 骗了我们

§9.6 和 §11 都建立在同一个观测上：「`prod_knobs` 恒为 0x72，ocean 两位一次都没置位，
所以生产不跑 ocean」。这个观测本身是真的，但**推论又错了**——而这次错得更有意思。

`prod_knobs` 不是"哪些 pass 跑了"，而是"哪些 pass 调了
`record_production_round_scalars`"。反证就在同一行日志里：`pass_a` 明明跑了
（有 `[pass_a][reference-boundary]`），可 0x01 同样不在 mask 里。

逐个 pass 变体查下来，漏记的有六个：

| 函数 | 应记 | 实际 |
|---|---|---|
| `run_ocean_water_pass_thread` | 0x04 | **NONE** |
| `run_ocean_land_pass_thread` | 0x08 | **NONE** |
| `run_ocean_water_pass_simd` | 0x04 | **NONE** |
| `run_ocean_land_pass_simd` | 0x08 | **NONE** |
| `run_climate_pass_b_simd` | 0x02 | **NONE** |
| `run_sea_ice_daily_pass_thread` | 0x40 | **NONE** |

而 native daily graph 默认走的**正是 thread 变体**（`native_daily_thread_variant_enabled`），
所以最常跑的那条路恰好是不记录的那条。后果有两层：worker 拿不到生产实际用的 ocean
标量、只能吃结构默认值；同时诊断位不置，看起来就像"这个 pass 根本没跑"。

补齐六处之后 `prod_knobs` 立刻变成 `0x7E`，ocean 两位亮了。

### 让 worker 真跑 ocean 之后

worker 的 round mask 跟随 `prod_knobs`，所以补齐记录的直接后果是 worker 开始跑
ocean 两个 pass。第一次跑 `temperature` 反而从 9 格涨回 2504 格 —— 因为旧抄本把
`baseline_arr` / `temp_before_arr` 擅自等同为 `temp_baseline_year` / `temp`，
并在注释里自认是"假设"。这与 wind_air 上被证伪过的那个假设是同一个。

改成随 `OceanWaterInput` 在消费点抽真值之后：

| 字段 | 之前 | 现在 |
|---|---|---|
| `moisture` | 1190 格 | **绿** |
| `runoff` / `groundwater` / `river_storage` / `river_discharge` | 698～721 格 | **全绿** |
| `plant_available_water` | 901 格 @ 0.64 | 901 格 @ **5e-6** |
| `water_balance_30d` | 1460 格 @ 0.0036 | 1460 格 @ **1.7e-5** |
| `temperature` | 2504 格 | 845 格 @ 0.0398 |

水文两项剩下的 1e-5 已是 float 累加噪声量级，不是算法分歧。

**这一步同时偿还了 oanom / TTA 的 overlay 债**：worker 现在自产这两个量，
不再靠抽生产值借。P7 的那个硬前提（ocean 内核零覆盖）也随之解除 —— 它现在每天
都在对拍里跑。

## 15. 偶发 `0xC0000005` 的根因：八处回写缺 in 侧守卫

§10 记的那个"未复现的崩溃"找到了，而且不是玄学。

`run_climate_round_passes` 每个 pass 跑完都要把 `out` 回写进 `in`，供后续 pass 读。
八处回写的守卫都只检查了 out 侧尺寸：

```cpp
// 错：in.moisture 为空时 .data() 是野指针
if ((int)out.moisture.size() == n_pb) {
    std::memcpy(in.moisture.data(), out.moisture.data(), n_pb * sizeof(float));
}
```

崩不崩取决于当天哪条 in lane 恰好没被填满（slot 缺失、overlay 没命中、mask 让上游
pass 没跑），所以表现为"偶发"。涉及 `moisture`、`local_thermal_anomaly`、
`ocean_thermal_anomaly`（两处）、`air_mass_temp_anomaly`（两处）、
`sea_ice_frac_inout`、`terrain`。

八处统一补上 in 侧尺寸检查后，同一 seed 连跑三次全部 `exit=0`，且三次
`compared=30 matched=27` 逐位一致。此前 `probe-ow30.log` 是 `EXIT=-1073741819`。

## 16. 对拍探针本身是不确定的 —— 前面若干条结论要打折

这一条推翻的是**方法**，不是某个 pass，所以放在最前面读。

`climate_parity_probe.gd` 的"单步 worker"实际是「取消暂停 → 轮询 consumed 计数 →
重新暂停」。而 worker 按自己的 wall clock 推进：

| 量 | 值 |
|---|---|
| `WORKER_SPEED_DAYS_PER_SECOND` | 400 → 一天 2.5ms |
| `WORKER_POLL_MSEC` | 2ms |

放行窗口和"一天"几乎等长，于是**worker 在一次放行里跑完 1 天还是 2 天，完全由 CPU
抖动决定**。跑多了那一天，生产与 worker 的日对齐就错开，"生产哪几天跑了 Climate
round"随之改变 —— 而这会整体改写分叉表。

实证：同一 seed、同一 DLL，`probe-guard30-*`（三次一致）与 `probe-rev30-*`（两次一致）
给出两套完全不同的结果：

| | guard30 | rev30 |
|---|---|---|
| day 7 | `matched=1`，ref 仍是 cold-start 哈希（生产没跑 round） | `matched=0`，ref 已变 |
| 首次分叉日 | 8 | 7 |
| `moisture` | 绿 | 1190 格 |
| 水文四项 | 全绿 | 700 格 |
| `plant_available_water` | 901 格 @ **5e-6** | 1968 格 @ **0.64** |

**所以 §14 里那张"水文全绿"的表是 overshot 状态下的偶然结果，不是真实改进。**
同理，此前任何"改了 X 之后分叉变少了"的判读，只要没核对过对齐，都不能当结论。

修法两条：把速度降到 50 天/秒（一天 20ms，检测延迟约占 10%，放行窗口不可能跨两天），
并把跳日显式暴露为 `overshot_ticks`，连同 `uncompared_ticks`（生产推进但 worker 未
比较的 tick 数）一起进 summary 与 stdout。

修后同 seed 连跑三次：`overshot_ticks=0`、`uncompared_ticks=13`（稳定）、
二十行分叉表逐位一致。

### 确定基线（自此以后的对比都以这份为准）

```
compared_days=30 matched_days=27 forced_days=3  alignment_clean=true
day 7  首分叉：temperature 847 @ 0.0397、plant_available_water 1968 @ 0.64、
                water_balance_30d 2448 @ 0.0036、WEATHER 组、snow_cover/snowpack 63、
                sea_ice 39
day 28 首分叉：moisture 1190、runoff/groundwater/river_storage/river_discharge ~700、
                vegetation_growth_pressure 1164
```

`uncompared_ticks=13` 是第二个对齐漂移源（生产推进而 worker 无比较），目前稳定，
但 P4 跑长天数前应该先弄清它是否随天数线性增长。

## 17. 又一个既存的断言漂移

`native_daily_graph_order_test` 的
`transpiration subtracts donor outflow before neighbor distribution` 失败。
它断言 `climate_daily_system.gd` 里存在 `D[i] += self_share - transported` 与
`transported / float(valid_land_neighbors)` 两段源码文本，但该文件 git 状态干净、
两段文本都不在其中 —— transpiration 早已搬到 C++，源码文本断言没跟着更新。

与 §8 的 `canal_runtime_test`（schema 43 vs 实际 51）、§9.7 的
`native_sea_ice_state_machine_test`（0.75 边界）同类：三个都是测试追不上重构，
不是运行时缺陷。建议一起立项清理，否则它们会持续消耗每次回归的判读成本。

## 18. `matched_days=27/30` 一直是虚数：真实样本只有三天，且三天全分叉

改口径之前，探针报的 `matched_days=27 / 30` 被当成了进度指标。加上 stage 掩码逐日
输出之后才看清：

| day | production_stage_mask | worker_stage_mask | matched |
|----|----|----|----|
| 1..6, 8..17, 19..27, 29..30 | `0x0` | `0x0` | true |
| 7 | `0x1FFF` | `0x1FFF` | **false** |
| 18 | `0x18FF` | `0x18FF` | **false** |
| 28 | `0x18FF` | `0x18FF` | **false** |

那 27 个"匹配日"里，生产一个 climate stage 都没跑，worker 也没跑（cadence gate 是
对的），所以两边都没变化、parity 自然通过。**真实对拍样本是 3 天，通过率 0/3。**

生产在 60x40 上大约每十天跑一次完整 climate round，并靠 `dt_days` 补偿（`thermal_dt_days`
实测为 10 和 8）。这也解释了 `weather_transition_alpha` 的分叉幅度恰好是 0.35 ——
`native_dt_compensation_probe_test` 里的 `rate=0.35`，一边过渡完成一边没有。

后果：所有以 `matched_days` 为分母的历史结论都要按"跑过 stage 的天数"重算。P4 的
1000 日对拍按这个节拍只有约 100 个真实样本，评审时必须报 `production_stage_mask != 0`
的天数，而不是 `compared_days`。

## 19. `_production_stage_mask` 的低八位从来没被置位（第二个 `prod_knobs` 级别的记录缺失）

`_production_stage_mask` 只在 ALBEDO / VEGETATION_DYNAMICS / CLIMATE_FEEDBACK /
WEATHER / RUNTIME_HYDROLOGY 五处 `|=`，PASS_A..TRANSPIRATION 这低八位一次都没有。
于是分叉矩阵上，生产在**每一天**都显示成"没跑 round"，而 worker 显示成跑了 ——
"worker 缺实现"和"生产本来也没跑"这两件事因此完全无法区分。这与 §14 的
`prod_knobs` 恒 `0x72` 是同一类 bug。

修法：round 的 `pass_bit` 编码与 `RuntimeClimateStage` 的低八位本来就同源
（`0x02` = pass_b = stage 1，一路对齐到 `0x40` = sea_ice = stage 6），所以
`record_production_round_scalars` 里一句 `_production_stage_mask |= pass_bit` 就够；
`CLIMATE_STAGE_BIT_PASS_A..TRANSPIRATION` 补齐成常量，并在 `runtime_climate_kernel.h`
加 `static_assert` 把这个对齐钉死。pass_a 与 transpiration 没有 scalars 记录点，
在两个 pass_a 变体与 `run_transpiration_pass` 入口各置一次位。

修完之后三个分叉日的两个掩码**完全相等**（day 7 双方 `0x1FFF`，day 18/28 双方
`0x18FF`）。这是本轮最重要的口径修正：剩下的分歧不能再归因于 cadence 或分片时序，
只能是算法或输入。

## 20. 标量边界已清零，但一个分歧数字都没变

新增 `PK_CLIMATE_SCALAR_DIAG=1`：在 `overlay_production_round_scalars` 里比较
overlay 前的 worker 值、overlay 后的值、生产记录值，报告"两边不同且 overlay 没覆盖"
的标量。字段名由 `tools/runtime/gen_round_scalar_fields.py` 从
`ClimateRoundScalars` 生成成 `.inc`（86 个字段）—— 手写清单正是 overlay 漏字段能
长期存活的原因。

首跑报出 19 个缺口，全部集中在 pass_a 段（`thermal_dt_days` worker=10 / prod=1、
`insol_amp` 0.32/0.2、`season_phase` 0.0109/0 ...）。根因是
`record_production_round_scalars` 的 switch 没有 pass_a 的 case，`_production_round_scalars`
里这 25 个字段一直是结构默认值 —— 也就是说 **pass_a 的标量边界从来没有被验证过**，
诊断报的"prod"值是默认值而不是生产实际用的值。

补法：pass_a 在内部就把标量组装成 `kin.scalars` 了，直接抄那一份
（`record_production_pass_a_scalars`）比再解析一遍 Dictionary 可靠。补完后诊断输出
为空。

但三天的分叉字段与格数**一字未变**。结论：worker 的 pass_a 标量本来就等于生产用的
值（`overlay_production_pass_a` 早就在覆盖这批 scalars），这一步补的是缺失的验证能力，
不是 bug 修复。标量层从此可以从嫌疑名单里划掉。

## 21. 分歧查不到根的结构性原因：生产侧不存在"完整的 round 输入"这一份数据

新增 `PK_CLIMATE_LANE_DIAG=1`，在 `overlay_production_pass_a` 末尾比较 worker 与生产
两份 `ClimateInputBuf` 的全部 53 条 per-cell lane（字段表由
`tools/runtime/gen_input_lane_fields.py` 生成）。首轮（day 7，此前没有任何 stage 跑过，
所以不存在历史污染）的输出是：

```
[lane-diag] landform prod-empty worker=2400
[lane-diag] wind_x prod-empty worker=2400
[lane-diag] ocean_current_x prod-empty worker=2400
[lane-diag] ocean_thermal_anomaly prod-empty worker=2400
[lane-diag] sea_ice_frac prod-empty worker=2400
[lane-diag] upwelling_strength prod-empty worker=2400
[lane-diag] insolation_now prod-empty worker=2400
... 共 25 条 prod-empty
```

`_production_round_input` 是生产 pass_a 时刻保存的 `kin`，而 pass_a 只填它自己要用的
那 22 条 lane。后续的 ocean / wind / sea_ice 各自从 GDScript 收 `PackedFloat32Array`
组装局部输入，**从不写回一份共享的 round 输入**。所以生产侧压根没有"这一天 round
的完整输入"这份数据，而 worker 的这 25 条 lane 全部来自 slot 快照或 kick 字典，
一致性没有任何验证机制。

这 25 条里包含 `wind_x/y`、`ocean_current_x/y`、`ocean_thermal_anomaly`、
`sea_ice_frac`、`temp_baseline`、`upwelling_strength`、`insolation_now`、
`cell_temperature_arr` —— 正是 `temperature` → `sea_ice` → `snow_*` 这条分叉链的
全部输入。§11 用 `WindSurfaceInput` / `OceanWaterInput` / `SeaIceInput` /
`ClimatePassBInput` / `WindAirInput` 逐个补消费点记录，走的方向是对的，但那五个
struct 各自独立、不进 `_production_round_input`，所以覆盖到哪里、还差什么，一直没有
可查的账。

结论：要让三个分叉日真绿，得让生产的每个 round pass 把它实际读到的 lane 写进同一份
生产 round 输入，overlay 与诊断都以它为准。在那之前，逐个字段猜输入来源的做法都会
继续像 §11..§14 那样反复。

### 本轮新增的可复用工具

| 路径 | 作用 |
|----|----|
| `tools/runtime/run_climate_parity.ps1` | 跑探针并把完整日志留在 artifacts（管道过滤会提前杀掉 Godot） |
| `tools/runtime/build_gdext.ps1` | 编译并先清掉占用 DLL 的残留 Godot 进程 |
| `tools/runtime/gen_round_scalar_fields.py` | 从 `ClimateRoundScalars` 生成标量诊断字段表 |
| `tools/runtime/gen_input_lane_fields.py` | 从 `ClimateInputBuf` 生成 lane 诊断字段表 |
| `PK_CLIMATE_SCALAR_DIAG=1` | 报告 overlay 没覆盖的标量 |
| `PK_CLIMATE_LANE_DIAG=1` | 报告 round 输入边界上仍不一致 / 生产侧缺失的 lane |

## 22. Lane 非零计数诊断：找出六处真实漏接（本轮最大一次收敛）

把 lane 诊断从 “worker vs prod” 改成 “overlay 前/后 + 两侧非零格数”，立即暴露了九条
capture_nz=0 且 overlay 也修不了的 lane。“全零”比“两边不等”信息量大得多：它直接说明
这条 lane 在 capture 时刻根本没被填，而不是“填了但值陈旧”。

修掉的六处（均为真 bug，不是对拍口径问题）：

| # | 根因 | 效果 |
|---|------|------|
| 1 | round 内少了 cp_if_size(in.insolation_now, out.insolation_now)，sea_ice 的 solar gate 整场按“永夜”跑 | sea_ice 39→38 |
| 2 | worker 没复刻 ield_solver.gd:204 的 spin-up 分支（field_init==0 的格用 moisture*0.15 起步） | vapor 2398→1137、max 0.15→0.055；cloud_water 1678→686；cloud_cover 1720→751；instability 1803→1014；weather_* 小字段 7→3 |
| 3 | 生产 oanom 的注入点在 pass_a 后，而 ocean_water/ocean_land 是**累加**它的 —— wind_surface 读到的 oanom 正好是生产的两倍；同时 worker 的 pass_b 也提前读到了非零值 | **temperature 424→6 格、3天→1天**；snow_cover 56→42、snowpack 55→41（同样 3天→1天） |
| 4 | TTA 在 round 内只活在 work.ocean_tta_inout，从不回写 in.temp_transport_anomaly，wind_surface 与 sea_ice 读到的是 kick 时刻的初值 | **sea_ice 整行消失**；matched_days 27→28、forced_days 3→2；**day 18 成为第一个逐位全绿的对拍日** |
| 5 | sea_ice 的起始冰量取 capture 快照而不是生产 pass_b 消费点记录的那份 | 无变化（两份值相同），但语义上更正确，保留 |
| 6 | climate_anomaly 是季节系统的全局量，生产每 tick 由 environment 提供，worker 的 store 只在 day%365==0 改写 | 中性（不在字段表里，只进 parity_hash），语义上正确，保留 |

第 1 与第 4 是同一类错误：**pass 内部算出的值没回写给下游 pass 读的那条 lane**。生产侧
因为共享同一堆 MapData 数组而天然没有这个问题，worker 的 in/out 双缓冲则必须逐条手接。
**这类错误的通用检查手段就是 lane 非零计数诊断（PK_CLIMATE_LANE_DIAG=1）。**

## 23. 两个 hash 不是同一个算法 —— 探针的 hash 对比是误导项


eference_hash 取的是 	race_frame.reference_state_hash（含 generation / rng_state / cursor 等
worker 内部状态），worker_parity_hash 是只含物理字段的 parity_hash。**两者永远不会相等**，
它们在所有运行里的差值也是稳定的。切勿把“hash 不等”当成分歧信号 —— P4 写证据时
要以字段级 itwise_diverged_cells 为准。探针输出应该把这两列改名或加注。

## 24. 字段表覆盖度已核实：35/36

store 有 36 条 per-cell lane，35 条在对拍表内，唯一缺席的是 	emperature_history
（365 日环形缓冲，不对拍合理）。不可比的只有两条：
iparian_moisture（NO_REF，但它是
每天由 PAW 覆写的派生量，不会独立漂移）与 egetation_succession_candidate（MISMATCH）。
所以 “P4 全绿” 的覆盖面是可信的，不存在大片未对拍字段。

## 25. 当前精确残留（seed=20260906, 60x40, 30 日，3 个真实 round）

- **day 7（首轮）**：temperature 6 格 @ 0.021；WEATHER 组 vapor 1137 / cloud_water 686 /
  cloud_cover 751 / instability 1014 / 四个小字段各 3 格；snow_cover 42 / snowpack 41。
  残留形状与 spin-up 一致 —— 首轮的弱惯性初值还有未复刻的分支。
- **day 18**：**逐位全绿**（bitwise_diverged_cells=0）。
- **day 28**：首分叉 moisture[95] 差 6.6e-4，但 max 达 0.78；下游 PAW/runoff/groundwater/
  river_storage/river_discharge/vegetation_growth_pressure 全线。temperature 在 day 28 是绿的，
  所以 pass_a 温度链正确。已排除：hydrology 输入 lane（全部来自生产记录，soil/q30
  每天从生产初值重填）、stride（=1 不分片）、riparian（派生量）、字段表覆盖度。
  下一步需要 per-day lane diff（现有诊断只在首轮打一次）。

## 26. day 28 根因定论：生产有一个未记入 stage mask 的 growth_pressure 衰减

新建了两个诊断工具才把它钉住：

- PK_CLIMATE_FIELD_DIAG=1 —— 每个超容差字段打 irst_cell **与最大分歧格**。
  first_cell 往往只是舍入级的差（day 28 是 6.6e-4），而最坏格才说明是不是整条
  分支走反了。正是它暴露了 moisture/plant_available_water 在 worker 侧顶到饱和 1.0。
- PK_CLIMATE_TRACE_CELL=<idx> —— 打一格在这一天 advance **前后**的值。
  “进来就已经是两倍”与“这一天变成两倍”是完全不同的两条线索，而分叉矩阵只给得出后者的结果。

cell 2071 的轨迹：

| day | worker growth_pressure 进 → 出 | 对拍结果 |
|-----|-------------------------------|---------|
| 7  | 0.0506805778 → **-0.798802972** | 当天不在分叉列表里（两边一致） |
| 18 | -0.798802972 → -0.798802972    | 逐位全绿 |
| 28 | -0.798802972 → -0.798802972    | 生产变成 **-0.399401486**，恰好一半 |

两边 mask 在 day 18 与 day 28 **完全相同**（都是 0x18FF，且不含 stage 9
VEGETATION_DYNAMICS 与 stage 10 CLIMATE_FEEDBACK），而生产在 day 28 把这个值减半了。
生产的 transpiration（stage 7）只写 out.moisture，不写 growth_pressure；写它的两处是
egetation_dynamics_apply_pure（赋值）与 climate_feedback_apply_pure（累加），两者都不在
day 28 的 mask 里。

**结论：生产在 day 28 跑了一个会衰减 growth_pressure 的 pass，但它没有把自己记进
stage mask。** 这和本轮已经修过六次的“pass 变体漏记 
ecord_production_round_scalars”
是同一类 bug 的第七个实例。修它需要先找到那个 pass（候选：GDScript 侧的 vitality /
succession 周期性刷新，或 stage_b_after_hydrology 的未记录变体）。

moisture / PAW / runoff / groundwater / river_* 那一整组都在它下游：growth_pressure 进
plant_available_water 的水分支出（current.paw + inflow - growth_pressure * 0.015），
也进 water_balance_30d。所以 day 28 大概是一个根因带出的七个字段，不是七个问题。

## 27. 本轮新增的可复用诊断开关

| 环境变量 | 作用 |
|---------|------|
| PK_CLIMATE_LANE_DIAG=1 | 每个 round 日打全部 54 条 input lane 的 capture_nz / overlaid_nz / changed，带 day 号。“全零”直接指向缺 capture，“changed 很大”指向 capture 陈旧 |
| PK_CLIMATE_SCALAR_DIAG=1 | 报未被生产记录覆盖的 round 标量（现为 0） |
| PK_CLIMATE_FIELD_DIAG=1 | 每个超容差字段打 first_cell 与最大分歧格的两侧值 |
| PK_CLIMATE_TRACE_CELL=<idx> | 打一格在每天 advance 前后的 growth_pressure / PAW / moisture |
| PK_CLIMATE_STAGE_TRACE=1 | round 内逐 stage 面包屑（崩溃定位用） |

## 28. 生产 ocean thread/simd 合流 + sea_ice overlay 收窄（2026-09-07）

证据：`ocean30-d30-s20260906.log`，`matched_days=28 forced_days=2`。
真对拍日仍是 3 天（7 / 18 / 28）。**day 18 已匹配；sea_ice 整行转绿。**

生产 native daily 默认走 `run_ocean_water_pass_thread` / `run_ocean_land_pass_thread`，
此前热循环仍是 `ocean_water_compute_one` / `ocean_land_compute_one`，与 worker 的
`ocean_water_pure` / `ocean_land_pure` 平行。simd 变体同样。四条入口现已接到
`pk_run_ocean_water_pure` / `pk_run_ocean_land_pure`；ENSO slice 仍挂在 ocean_water
之后，由 `production_ocean_anomaly` 在 wind_surface 前注回。

同时收窄 `overlay_production_sea_ice`：不再把 terrain / sif / insolation / upwelling
写进更早 pass 的共享 lane。sea_ice 的 oanom/TTA 继续走专用字段。
`wind_surface` 之后无条件 `resize`+拷贝合成温度到 `cell_temperature_arr`。

对照上一份 `land9`（同一 seed，专用 lane 但 ocean 仍平行、overlay 过宽）：

| 字段 | land9 | ocean30 |
|------|-------|---------|
| matched / forced | 27 / 3 | **28 / 2** |
| temperature | 3 天 525 格 @ 0.053 | **1 天 6 格 @ 0.021** |
| sea_ice | 3 天 30 格 | **0** |
| moisture 首超容差日 | day 7 | **day 28** |
| snow_* | 3 天 | **1 天（day 7）** |

剩余真分叉：

- **day 7**：weather 组（vapor 1137 / cloud_* / 3 格 discrete alpha=0.35）+ temperature 6 格 + snow 42/41。形状仍是首轮 spin-up / dt 补偿。
- **day 18**：匹配。
- **day 28**：moisture / PAW / 河网链。`season-refresh` 已在当天 publish（`round_ran=1`），growth_pressure 已绿。下一步看 refresh 后、round 前的 moisture 权威是否被 capture 时刻的旧值盖掉。

P6：`implemented_domain_mask` 现为 `COMMIT|CLIMATE`（0x802）。`generate_world` 在 capture 之后启动 SHADOW。ACTIVE 门仍被其余十个域挡住。

## 29. Season refresh 调查与一次未改数字的接线（2026-09-07）

生产 12-stage refresh（SUS priority 50）先于 native_daily（210）。
`cell_moisture` 的权威写者是 **stage 0 从 base 重设**，再加上 1/3/4；
stage 11 只衰减 soil / VGP / 抬升 base，**不改 cell_moisture**。
`runoff` / `groundwater` / `river_*` 没有 season 写者。

已把 worker 的 VGP decay 从“全部 stage 之后”挪到 climate round 之前，
并把 refresh 日的 moisture 采纳从 capture 快照改成 production pass_a 输入。
`season28` 与 `ocean30` **逐字段数字相同**（moisture 仍 1140 格 @ 0.782491）。
共享 `hydrology_pass_pure` 的 lane 表里没有 VGP，所以这次时序调整碰不到
day 28 的水分链。下一步应对 day 28 开 `PK_CLIMATE_FIELD_DIAG=1`，看 hydrology
入口的 moisture / base / soil 哪一条在 overlay 之后仍是 refresh 前的值。

## 30. 90 日双 seed：稳态已绿，残留是钉在特定日的结构性偏差（2026-09-07）

30 日窗口只有 3 个真对拍日，样本太小，读不出"残留会不会长大"。跑两份 90 日：

| | `long90` seed=20260906 | `long90b` seed=424242 |
|---|---|---|
| compared / matched / forced | 90 / 87 / 3 | 90 / 87 / 3 |
| alignment | overshot=0 clean=true | overshot=0 clean=true |
| 真对拍日 | 9 | 9 |
| 绿 | **6 / 9** | **6 / 9** |

两个 seed 的真对拍日完全同构：

```
day  7  分叉 11 字段   ← 唯一跑满 13 stage 的一天（mask 0x1FFF）
day 18  绿
day 28  分叉  6 字段   ← 首次季末刷新
day 38  分叉  1 字段   ← temperature 4~6 格
day 48/58/68/78/88  全绿
```

三条结论：

**一、稳态已绿，且覆盖了第二次及以后的季末刷新。** day 58 / 88 都是季末日
（周期 30）却全绿，所以 day 28 的分叉不是"季末刷新这件事"本身，而是"第一次"。
最后 5 个连续对拍日零分叉。

**二、残留不累积。** 分叉表里每个字段的 `out_of_band_days` 都是 1
（`temperature` 是 2：day 7 + day 38）。没有任何字段在两个不同的日子分叉后又继续。

**三、stage 8/9/10 自己的输出从未分叉。** `albedo` / `vegetation_vitality` /
`vegetation_*_stress` / `vegetation_*_streak` 全部 `out_of_band_days=0`。
这三个 stage 在 90 日里只跑过一次（day 7），一次就绿。day 7 的分叉全部落在
WEATHER 组和 `temperature` 上。

### 但这不是随机 spin-up

跨 seed 比对否掉了"暂态噪声"的解释。分叉日与 seed 无关，`max_out_of_band_delta`
在两份跑里几乎逐位相同：

| 字段 | seed 20260906 | seed 424242 |
|---|---|---|
| `weather_transition_alpha` | 0.349999994 | 0.349999994 |
| `plant_available_water` | 0.642824471 | 0.642921716 |
| `moisture` | 0.782491356 | 0.780535907 |
| `vapor` | 0.055130467 | 0.054853514 |
| `snowpack` | 0.021776438 | 0.021795109 |

地图不同、格数不同（`vapor` 1137 vs 1001），偏差幅度却一致到 4~6 位小数。
累积误差不会这样；这是**确定性的结构性偏差**，根因单一且可定位。
`weather_transition_alpha` 恒差 0.35 尤其明显——0.35 是 alpha 自己的一个固定值，
说明那 3~5 格在一侧取到了状态机的某个分支而另一侧没有。

`temperature` 的 day 38 分叉是另一回事：格数随 seed 变（4 vs 6），
max 0.028 / 0.031，量级和形状都是数值噪声，归容差口径。

### 对 P7 顺序的影响

day 7 / day 28 都在"某条路径的首次执行"上，而这条路径的形态由 SHADOW 的
bootstrap 语义决定：worker 现在从生产 capture 快照起步，第一次推进跨 tick 状态时
拿的是主线程的历史累积值。P7 把 climate 转成 ACTIVE 权威之后，worker 不再从
生产快照起步，day 7 / day 28 这两处的输入来源整个改变。

所以先修这两条、再做 P7 是白工。顺序改为：**先落 per-domain 权威门 + 回灌 +
滞后一日，然后在 ACTIVE 语义下重跑 90 日双 seed**，届时 day 7 / day 28
若仍以同样的恒定 delta 分叉，才是需要单独追的物理分叉。

## 31. ACTIVE 语义重测：SHADOW 残留不再是这条分叉（2026-09-07）

探针：`tests/climate_active_parity_probe.gd`，两份同 seed 世界，
`writeback_last_day == N` 对齐。证据：
`artifacts/runtime/s4-evidence/active-parity-active40-s20260906.*`。

| day | temperature oob | moisture oob | vapor oob | 与 SHADOW 90 日对照 |
|---|---:|---:|---:|---|
| 7 | 2202 @ 0.174 | 1204 @ 0.690 | 0 | SHADOW 是 6 格 @ 0.021 |
| 18 | 2180 @ 0.169 | 1187 @ 0.971 | 2400 | SHADOW 全绿 |
| 28 | 2162 @ 0.214 | 830 @ 0.971 | 2400 | SHADOW 水分链 6 字段 |
| 38 | 2123 @ 0.219 | 1165 @ 0.785 | 2398 | SHADOW 4~6 格噪声 |

这不是同一条分叉。SHADOW 比的是「同一天 overlay 输入下的两份内核」；
ACTIVE 比的是「stride-10 主线程气候」对「每日 worker 权威」。生产默认
`native_daily_sim_stride=10`，worker 每天都 commit，日历日 N 的 MapData
本来就不该逐格相等。day 7 的 vapor/snowpack/paw 仍是 0 差，说明生成初值
一致，后面的差是节奏，不是 bootstrap 常数 0.35。

**准入线改到 ACTIVE 自己的契约**：回灌健康、50 日 soak 无 fatal、可回退、
CLM2 可存。SHADOW day 7 / day 28 不再挡 Climate 单域落地。
