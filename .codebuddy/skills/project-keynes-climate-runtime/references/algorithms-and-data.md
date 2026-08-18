# 气候算法与数据契约

## 目录

- 数值约定
- 核心字段与唯一写者
- Pass-A
- Pass-B
- Ocean heat
- Wind and temperature composition
- Sea ice
- Transpiration
- Albedo, vegetation, feedback, stage-b
- Weather field and fronts
- Runtime hydrology
- Physical ocean
- 生成期湿度纬带包络
- 时间尺度与镜像规则
- 下游经济接口

## 数值约定

- `temp`、`temp_baseline`、`moisture`、`snow_cover`、`sea_ice_frac` 等主要环境量使用 normalized 语义。
- `soil_moisture` 是约 `[-0.5, 0.5]` 的有符号水文异常；不要当绝对湿度。
- `weather_vapor` 的稳态量级约为 `0.15 * base_moisture`；Pass-A 使用 vapor anomaly，而非直接把 vapor 当湿度。
- `base_moisture` 自 zonal-envelope（2026-08-01）起带**纬度结构**：赤道带(eq_dist<0.2)陆地中位约 0.43-0.47、副热带干带中位约 0.08-0.20（含 <0.2 真荒漠格）、中纬回升（风暴路径湿带）、极地再降。不要再假设"全图同一半干分布（0.2-0.38）"的旧量级；纬带审计用 `tools/audit_veg_zonation.py`。
- `wind_x/y` 是单位方向；`wind_speed` 是强度。渲染 buffer 才使用 `dir * normalized_speed`。
- `ny=0` 是视觉北极，`ny=1` 是视觉南极；`lat_signed=(ny-0.5)*2` 正值为南半球。
- exact `temp==0` 是有效冻结值；只用 `isfinite` 判 fallback。

## 核心字段与唯一写者

| 字段 | 主要写者 | 语义 |
| --- | --- | --- |
| `cell_temp_baseline` | Pass-A | 辐射目标经热惯性后的 runtime baseline |
| `cell_temp_30d/365d/anomaly` | Pass-A | dt-aware EMA 与短长差 |
| `cell_moisture` | Pass-A/Pass-B/蒸腾链 | runtime 环境湿度；native daily 完成时原子可见 |
| `cell_local_thermal_anomaly` | Pass-B | 雪/植被反照率、沿海、地形、海冰局地异常 |
| `cell_ocean_thermal_anomaly` | ocean water/land | 当日 ocean heat contribution |
| `cell_air_mass_temp_anomaly` | wind-air/surface | 气团热异常 |
| `cell_temp` | wind-surface | daily climate chain 的最终温度唯一合成写者 |
| `cell_temperature_transport_anomaly` | ocean stabilization/finalizer | 独立低通 transport state |
| `cell_sea_ice_frac` | sea-ice pass | 海冰浓度 |
| weather vapor/cloud/precip/type | weather solve + commit | staged next buffers 经 commit 才可见 |
| soil/WB30/discharge/storage/runoff | feedback/hydrology | 水文与植被闭环 |
| vegetation vitality/stress/streak | vegetation dynamics | 演替候选的基础 |
| plant available water | climate vegetation dynamics | 经济生产气候的冻结输入 |

## Pass-A

入口：`run_climate_pass_a`、`run_climate_pass_a_thread`、async pure mirror。

主要步骤：

1. 根据纬度和 `season_phase` 算当前日照、昼长和相对年均日照差。
2. 从 `temp_baseline_year` 得到年均地理基线。
3. 计算 season offset，只压缩冷侧；不使用旧 `temp_land_continentality` 额外放大陆地季节强迫。
4. 对沿海陆地应用 `season_offset *= 1 - maritime_season_damp * maritime_factor`。
5. 计算 radiative target，并应用 climate Modifier 的 add/factor。
6. 按 land/water/snow/high-mountain 热惯性更新 `thermal_energy`，按 `thermal_daily_delta_cap * dt` 限幅。
7. 用真实水循环状态构造 moisture target，再以 dt-aware relax 更新 moisture。
8. 更新 30 日、365 日 EMA 和 temp anomaly。
9. 清零当日 ocean/local anomaly accumulator，供后续节点写入。

关键公式：

```text
alpha_eff = 1 - (1 - alpha_daily)^dt_days
ema30_eff = 1 - (1 - 1/30)^dt_days
ema365_eff = 1 - (1 - annual_alpha)^dt_days
```

湿度规则：

- `base_moisture` 只是静态地理锚。
- weather vapor 使用 `weather_vapor - 0.15 * base_target` 异常。
- precip、正/负 soil、正/负 WB30 分开加权。
- 禁止重新引入 `season_phase` 或 `insolation_dev` 直接湿度乘数。

性能：

- 年均日照 16 样本积分已由 `(n, latitude bits, axial tilt, daylen)` 指纹缓存。
- native graph 使用 thread 变体；pass cell-local，可 deterministic 并行。
- 手写 AVX2、Pass-A/B 融合和 SFC 已因 compute/ROI 评估为 no-go，除非新证据推翻。

## Pass-B

读取 Pass-A/round-start快照、邻接、雪包、植被、地形、TTA 和海冰。

- 把 snow/vegetation albedo、coastal leak、landform/diurnal 等局地效应累加到 `local_thermal_anomaly`。
- 保持 moisture 的 evaporation/rain-shadow/邻域修正。
- 水域海冰反照率冷却也写 local anomaly，不直接写 `cell_temp`。
- 邻居只读稳定快照，own-cell 写 local anomaly/moisture，因此 thread 变体可逐位等价。
- native daily、retained state machine、async 和 fallback 必须保持 A→B→ocean 顺序。

所有海冰、snowpack、coastal、TTA knob 必须从 `ClimateProfile` 显式打包；不要让某条路径静默落到旧 C++ default。

## Ocean heat

`ocean_water`：

- 读取水格、current、baseline、旧 TTA 与 sea-ice。
- 沿洋流/邻接做 advect/mix，更新 ocean anomaly 与稳定化 TTA。
- 正向暖流 source 受海冰浓度与结冰/融冰阈值潜热门控，避免冰点附近长期暖偏锁死。

`ocean_land`：

- 把水域/邻域 anomaly 衰减传播到陆地。
- 只写 ocean anomaly/TTA，不直接写最终温度。

TTA 使用 source cap、blend、normal decay、zero-current decay；它是持久低通状态，不是每轮清零 scratch。

## Wind and temperature composition

`wind_air`：

- 从当前温度快照、单位风向、风速和邻居平流气团异常。
- 只发布 `air_mass_temp_anomaly`。
- 新 DLL 优先从 slot 读 current temp；旧 DLL 才接收 `temp_before_arr`。

`wind_surface`：

- 汇集 ocean anomaly、air anomaly 和 local anomaly。
- 对正向水体 transport 使用 sea-ice潜热门控。
- 以单一公式发布最终温度：

```text
transport = clamp(ocean_anomaly + air_anomaly, -budget, +budget)
temp = clamp(temp_baseline + transport + local_anomaly, 0, 1)
```

物理风场另由 SLP gradient、Coriolis、背景风带、synoptic扰动、沿海热力压差和地形摩擦构造。方向更新有最低 flux gate 和单日最大转角；风速独立存储。

## Sea ice

输入包括 water/terrain、temp、TTA残余、纬度/日照、邻居旧 fraction、dt 和 profile 阈值。

- 使用 form/melt 迟滞。
- freeze/melt rate、太阳 gate、太阳 melt、邻居 contagion、edge mix 与 daily delta cap 共同更新 fraction。
- edge mix 只在海洋型水邻域且已有冰种时工作，避免湖泊/低纬误扩散。
- `daily_delta_cap` 按真实 dt 放大，并受 profile 的 spread dt cap。
- thick ice 保留最低太阳暴露，避免完全屏蔽夏季消融。
- 计算 terrain flip 时使用阈值 + hysteresis；同步更新 terrain/water facade 和视觉 dirty。
- 有效暖流 TTA 要减去已在最终 temp 中体现的 ocean anomaly，避免重复计算同一 ocean heat。

## Transpiration

根据 vegetation、moisture、neighbor donor table、outflow/self rate 做水分再分配。

- native pass 负责主要 compute/apply。
- GDScript 保留 donor table、round state、dirty/fallback。
- async pure kernel 使用 `std::vector` 输入输出并保持计算顺序。
- native 已发布时 caller 不得再次 dense 写全部 moisture。

## Albedo, vegetation, feedback, stage-b

`albedo`：

- 根据 terrain/cover/snow/vegetation 等计算 surface albedo 或相关反馈量。

`vegetation_dynamics`：

- 从 temperature、plant water、weather、水分平衡等计算 vitality。
- 维护 heat/drought/cold stress、regen score 和 high/low streak。
- 按真实累计天数判断 degrade/upgrade，生成 succession candidates。
- C++ 不直接管理 HexCell/MultiMesh；GDScript按稳定索引应用 candidate并标 atlas/scatter dirty。

`climate_feedback`：

- 将 weather precip/temp transport 等弱耦合进 soil moisture、WB30、growth pressure/TTA 等慢状态。
- 保持增益小、cap 明确，避免单日天气重写气候基线。

`stage_b`：

- 聚合 albedo、vegetation、feedback、snow/soil/water 等后段。
- 其 stride 影响 vegetation实际累计 day scale；native daily stride 和 stage-b stride 必须共同计入。
- hydrology 启用时只运行 after-hydrology 版本。

## Weather field and fronts

核心 weather state 是 vapor、cloud water、cloud、precip、convergence、instability、type/target/prev/alpha。

主要流程：

1. `field solve`：按风做上游 vapor/cloud-water 平流；叠加 diffusion、海洋蒸发、陆地蒸散、地形抬升、辐合、frontogenesis、Hadley/Ferrel `omega` 和 synoptic扰动。
2. `phase change`：vapor凝结为cloud water，降水消耗cloud water/vapor，re-evap与高尾稳定控制极端值。
3. `classification`：按温度、湿度、云水、降水、风、instability、雪盖与地表类型分类。
4. `transition`：用 dt-aware alpha 平滑 target→display type。
5. `commit`：把 staged next buffers 原子发布到 weather slots/MapData。
6. `distribute/summary`：更新 snowpack/有效降水影响并汇总 fronts。

约束：

- `field_solver.gd` 与 `world_ext_weather.cpp` 是 SAME_SOURCE 镜像。
- 非降水类型的残余 precip 在 solve 后回流 vapor 并归零；distribute/hydrology 再按 RAIN/STORM/BLIZZARD/MONSOON gate。
- cold precip、land snow-cover、water wind gate 必须在 native/fallback 一致。
- transition alpha 使用 `rate * dt_days`，稳定态必须归一为 `type=target`、`prev=target`、`alpha=0`。
- combined/native 路径必须包含 commit；方法存在不等于 visible publish ready。
- commit 后验证 `weather_field_init` 和样本；repair path 表示 native publish 尚不能单独证明权威。
- WeatherFront 是由 cell field 汇总的低 N 兼容/视觉对象，不是另一套天气模拟。

## Runtime hydrology

输入：

- 生成期 `hydro_parent` 排水拓扑与邻接。
- 有效 weather precip、snowpack/melt、soil、WB30、vegetation vitality、河湖地形。

步骤：

1. 计算本地产流、入渗、土壤变化和地下水补给。
2. 计算地下水基流与河道 storage release。
3. 按 parent graph 从上游向下游路由。
4. 更新 discharge、30 日 discharge、river/groundwater storage、surface runoff。
5. 给河道和相邻陆格施加受控 riparian moisture。

所有积累和衰减按真实 `dt_days` 换算。`water_budget_error` 是轻量诊断，不是严格物理守恒闭合。hydrology读取天气有效降水，必须位于 weather commit 后、stage-b 前。

## Physical ocean

链：

```text
SLP -> wind field -> wind stress curl -> PSI(SOR) -> current -> upwelling
     -> visual raster -> Godot texture commit
```

- SLP 使用纬度 LUT 缓存年均/当前日照相关基线，并叠加 thermal、synoptic、mobile-low 等。
- wind 输出单位方向 + speed。
- PSI 使用 Gauss-Seidel/SOR，默认 warm start，支持残差 early exit；全扫迭代不做 cell-range slicing。
- current 最终按向量 magnitude clamp，而非分别钳 x/y。
- physical authority 与 visual raster/commit 分离；视觉可丢弃陈旧 round 并从最新物理快照重启。
- SLP/wind/upwelling leaf pass 可做 range slicing；全局归约与发布只在末 slice。

## 生成期湿度纬带包络

zonal-envelope（2026-08-01）修复"草原系 48%、赤道无雨林、全图零荒漠"。`base_moisture` 生成公式站点唯一（`world_ext_generate.cpp` 湿度扫描，无 GDScript 镜像公式），顺序：纬带包络 → 平流雨影扫描 → 海岸/噪声细节：

- **ITCZ 赤道湿带**：降水乘数 `moisture_itcz_wet_strength(0.9)`/`center(0.05)`/`width(0.10)` + 热带洋面蒸发 `moisture_tropical_evap_boost(1.0)`（赤道洋面 ×2 供水）+ 降水再循环 `moisture_itcz_recycle_strength(0.62)`（雨林蒸散回气柱）+ 辐合注入 `moisture_itcz_convergence(0.05)`。后二者让湿带深入大陆内部，否则气柱沿程枯竭、赤道内陆必然干旱。
- **副热带干带**：`moisture_subtropical_dry_strength(0.30)`/`center(0.36)`/`width(0.18)` 大陆度门控减法，**移到海岸 guard 之后**生效 → 副热带海岸也能成真荒漠（<0.2）；center 极移避免高斯尾触达赤道带。
- **中纬风暴路径湿带** `moisture_stormtrack_wet_strength(0.6)`/`center(0.55)`/`width(0.15)`（温带森林湿线可达）与**极地干** `moisture_polar_dry_strength(0.35)`。
- 分类阈值随新分布再校准（C++/GDScript 双镜像）：真热带 `t>0.80`（旧 0.66 实测对应 ~49° 过宽）、JUNGLE/雨林湿门 0.56、亚热带 FOREST 0.40、暖温带 FOREST 0.48。
- 硬指标验收 `tests/generation_zonal_moisture_test.gd`（3 种子 35 checks）：赤道 bm 中位 > 副热带、副热带存在 <0.2 格、中纬 > 副热带、赤道核心森林 > 草原、全图森林 25-36%、草原 <30%、荒漠 ≥2%。
- 运行期演替随湿度结构解冻（soak 12.3%/2yr 迁移，SAVANNA→季雨林链打通）；瞬时湿度漂移 +0.06/2yr 为蒸腾再循环平衡瞬态（首季冲高后同季年际回落，donor 与森林格共位），timescale 分离后不影响 biome，不归因于失控正反馈。

## 时间尺度与镜像规则

每个 rate/EMA/cap 明确其单位：

- 每日 rate：用 `1-(1-rate)^dt`。
- 每日线性 cap：通常乘 `dt`，再受合理最大 dt 限制。
- transition：`alpha += rate * dt`。
- cadence state：使用实际 sample/commit day，不用调用次数冒充天数。
- stage-b vegetation：`native_daily_stride * vegetation_stage_stride`。

同步检查路径：

- C++ scalar
- C++ thread/SIMD/range
- native daily slice
- debug full-run/SHADOW
- async climate pure kernel
- GDScript fallback
- weather staged and combined/split
- production profile knobs and base defaults

## 下游经济接口

气候只发布环境能力，不结算经济：

- `cell_plant_available_water` 由 climate slot 权威发布。
- 经济在 sample day 冻结 `temp_30d` 与 plant water，按 `ProductionClimateProfile` 算 capacity。
- capacity 影响 plan、投资、预期收入与生产，但所有账本仍由 `NativeEconomyRuntime` 权威结算。
- 不为经济气候新增平行 GDScript state 或逐建筑 climate slot。
