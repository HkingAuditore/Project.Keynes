# Simulation Computation Pipelines

## Modifier pipelines

```text
WorldClock day
  -> modifier_daily: expiry -> stable command merge -> bucket/snapshot publish
  -> climate Pass-A: base radiative target -> frozen cell modifier -> clamp -> inertia
  -> country snapshot: country output factor -> Q16
  -> economy freeze: country Q16 * building factor -> effective output helper
  -> production / wage quote / survival / investment / recovery -> existing ledgers
```

Gameplay 使用独立 identity/base SoA，查询时组合 Gameplay store；对象注销只清 entity scope。
跨域不直接写 store。完整数据结构和存档见
[`native-modifier-runtime.md`](./native-modifier-runtime.md)。

## Effect pipeline

```text
committed trigger/fact boundary
  -> EffectRuntime frozen instance + metric snapshot
  -> dense condition/value IR or registered C++ BehaviorFn
  -> deterministic plan hash + idempotent typed commands
  -> adapter preflight
  -> domain safe-boundary commit
  -> per-domain ACK; pending transaction remains in PKEF until complete
```

EffectRuntime is an orchestration/transaction authority only. Modifier, Country,
Economy, Gameplay and conserved ledgers remain the sole writers of their own
state. Configuration programs use fixed Q16 arithmetic and a bounded value
stack. Open-ended algorithms use a compile-time C++ behavior with a preallocated
bounded command buffer; the callback reads frozen inputs and returns commands,
never mutating a domain. Technology completion, family branch reconciliation,
and native person promotion/`PERSON_COMMIT` now register native Effect
instances; their known Modifier commands are batched in C++ into
`ModifierRuntime` and ACKed at the Modifier daily boundary. The current person
producer applies only `gameplay.generic.bonus`; PersonStore remains authority
for every person ledger and structural field.

At scale, eligible declarative candidates are planned against frozen native slabs
in worker-local output rows, then merged in candidate order by one C++ writer.
This parallelizes arithmetic without allowing a worker to mutate a transaction
store or a domain. The serial fallback uses the same planning shape. Behavior
callbacks keep the serial route until their owner can prove thread safety.

经济 scratch/cache 与 native daily 可见发布的 2026-07 调整见
[运行时性能优化契约](runtime-performance-optimization-2026-07.md)。

本文按游戏机制整理当前计算链路、算法概要、C++/DOTS 化状态、输入输出和性能风险。它用于回答两个问题：

- 某个机制现在到底跑在 C++、DataCore 还是 GDScript？
- 继续推进 total C++/DOTS 化时，下一步应该迁移哪一段？

## Economy pipeline（PKEC v30 当前，v24 历史基础）

经济图仍由 `NativeEconomyRuntime` 权威执行，未增加 DataCore slot 或 GDScript fallback。
`building_plan` 生成恢复/授信额度，`building_employment` 允许已融资 RECOVERY_PROBE 招募，
`building_production` 原子提款并采购投入且按工资后债务前奖金结算，household 将实际自产消费
价值归属建筑，`building_commit` 完成复产/清算/建设债务转移。贸易派单使用代际复核和批次共享
库存/缺口仲裁。CSV v23 暴露债务、恢复、贸易事件、边际驱动商品、选中地块逐投资候选指标、商人流动性闭环字段、分层采购字段、投资组合、employee-to-owner 转岗及气候诊断。

恢复探针只有在实际发生投入、产出、资源消耗或资源生成且现金/经济利润条件同时通过时才计为成功；
空执行探针写入 pending suspension，并在下一 due-cell frozen boundary 提交。提交周期及其后一个完整
due-cell 周期不再探测，避免 state 2/state 1 和就业关系隔 epoch 闪烁。

`building_commit` 的内生投资复核现在维护固定四项 portfolio：候选扫描与最终建筑数量解耦，
共享人口/资本/信用/建材/缺口预算后，每种类型只提交一条聚合 BUILD 命令。收入改善率一次计算
愿意转职的人口，最多填补 25% 的持续缺口；多类型组合把单类型新增业主岗位占比限制在 50%。
清算沿用既有恢复资格，但每次最多退出 group 的 25%，债务按退出比例转坏账。CSV v23 包含
组合开工、迁移人口、集中度、约束来源和部分/完全清算计数。

`building_commit.review_prepare` 生成当前 rolling/review phase 的升序正人口 cell
列表，投资 finance/pending/existing/resource 聚合和 96-cell continuation 只消费该列表。
候选评估目前仍是 scalar native 路径；尚未把只读 evaluate 与稳定主线程 commit 拆成 worker
两阶段。`aggregate_publish` 的 closing audit 支持 FULL/PROBE/INCREMENTAL，并以
generation-stamped 首触 shadow delta 计算增量 totals。PROBE 每日全量复核且以全量结果权威；
200 日每日双审计零 mismatch 后，生产默认已切到 INCREMENTAL，每 25 日及 restore/异常边界
仍执行完整复核。除 v23 明确保存的生产气候冻结值、建筑气候诊断、补贴权重与财政累计外，
列表、shadow、stamp 和运行期诊断均为 transient，不进入 PKEC v30/hash。

## 状态总览

| 机制 | 当前状态 | 主要 C++ 入口 | GDScript 仍负责 |
| --- | --- | --- | --- |
| Season refresh | 部分 C++/gdext | stage 2 / B+ path 相关 helper | 日历/轨道相位调度、慢变量刷新、atlas queue。 |
| Climate Pass-A | C++ hot-loop | `run_climate_pass_a`, `run_climate_pass_a_thread` | knobs 构造、fallback、round 管理。 |
| Climate Pass-B | 部分 C++ / DataCore 写路径 | pass-b helper / system schedule 节点 | 部分 sparse/dirty orchestration、A/B ground-truth。 |
| Ocean water | C++ | `run_ocean_water_pass`, SIMD/thread variants | dispatch gate、fallback、slice wrapper。 |
| Ocean land | C++ | `run_ocean_land_pass`, thread variants | dispatch gate、fallback、baseline/cache 管理。 |
| Wind / air mass | C++ | `run_wind_air_mass_pass`, `run_wind_surface_pass`, `run_wind_field_pass` | terrain-aware knobs、stage orchestration。 |
| Transpiration | C++ compute + GDScript orchestration | `run_transpiration_pass` | donor table/dirty sync、slice state、fallback apply。 |
| Sea ice daily | C++ | `run_sea_ice_daily_pass` 等 native helper | terrain flip policy、job wrapper、atlas upload。 |
| Weather field | C++ sub-passes | `run_weather_field_solve_pass`, distribute/summary/stage-b helpers | begin/commit state machine、front object compatibility。 |
| Runtime hydrology | C++ full-map pass + weather job stage | `run_runtime_hydrology_pass` | `weather_refresh` stage 编排、ClimateProfile knobs、后续慢频视觉重烘策略。 |
| Natural resources（自然资源每日生成/衰减） | C++ full-map pass + GDScript orchestration | `run_natural_resource_pass` | knobs 构造（`ResourceProfileRegistry.build_pass_knobs`）、初始储量 bootstrap、`natural_resource_daily` system 调度、GDScript fallback。 |
| CountryStore / territory / technology / treasury / tax policy | C++ ACTIVE authority | `country_daily` | 独立国家 SoA、领土 CSR、国家科技、国库与五类税表；仅 `cell.country_slot` 发布到 DataCore，PKCN v5 持久化。 |
| Static research signals | C++ generation pass + native country evidence | `run_research_signal_generation_pass` / `country_daily` | Generation writes deterministic cell-indexed CSR (`offsets`, dense IDs, values); vision submits idempotent country discovery commands, while technology conditions consume only dense country evidence. |
| ModifierStore | C++ ACTIVE authority | `modifier_daily` | 四域隔离 SoA/bucket；不写 base，发布冻结 effective 聚合与 journal。 |
| PopulationCohort / MarketStore / fiscal escrow | C++ Market V2 ACTIVE | `economy_daily` | 独立 chunk/market vectors、冻结国家税率、N 日 need/bundle 清算、源头扣缴与补贴托管；worker 写独占 cell lane，财政提交统一更新国库并发布 PKEC v30。 |
| 综合满意度（八维度 composite） | C++ ACTIVE authority，寄生在既有归约循环 | `economy_daily` 的 household market 归约 + `refresh_epoch_development()` | 四档需求累加器零额外遍历；收入增长/储蓄/税负三维读 cohort 账本，社会发展维度在 epoch 边界缓存为 `_epoch_cell_development_q16` 后热循环 O(1) 只读。详见[综合满意度运行时](./satisfaction-runtime.md)。 |
| Weather fronts | 部分 DOTS/packed | native snapshots / packed fronts | object layer、UI/debug、spawn/advect orchestration 部分保留。 |
| Ocean currents physical | C++ kernels + **生成期一次性 C++ orchestrator** + 运行期 GDScript stage machine | `run_physical_solve_pass`（生成期）, `run_slp_field_pass`, `run_wind_field_pass`, `run_psi_solver_pass`, upwelling/raster helpers | 生成期 `_physical_solve_for_phase` 优先走 `run_physical_solve_pass`（SLP→wind→PSI→upwelling 全 C++ 串完）；运行期 `_phys_stage` 逐帧状态机不变；NaN 守门 + 风场 raster + fallback 保留。 |
| Enum atlas upload | C++ cached patch + GDScript GPU upload | cached patch/raster helpers | Image/ImageTexture/RID upload。 |
| Weather LUT upload | GDScript upload + C++/GDScript byte source | `encode_cell_luts`（初始/完整 LUT 字节来源） | `weather_refresh` 提交点从 weather SoA 直接编码 RGBA8 并维护 prev/current 双缓冲。 |

| Dynamic visual atlas | 部分 C++ patch/stride | raster/patch helpers | smooth prep、dirty queue、GPU upload；不再负责 weather_lut 发布。 |

| Debug data overlay bake | C++ pixel fan-out + GDScript 采样/GPU upload（ImageTexture/PackedByteArray 持久化复用，day-dirty + skip_day 节流） | `encode_overlay_atlas` | `DataOverlayBaker.bake` 逐通道 per-cell 采样、`tex.update`、stats、fallback。详见本文 "Debug Data Overlay bake" 节。 |
| Native world generation base + post-base + publish（生成期） | **ACTIVE 默认（dots-total-cpp 2026-06-18，唯一路径，无 GDScript fallback）**：C++ base SoA generation + C++ post-base 地貌/生态/河流处理；bind 后 C++ slot publish。**base+post_base 已融合为单次 `run_native_world_generate_full_pass`（step4，2026-06-25）** | `run_native_world_generate_full_pass`（融合优先）, `run_native_world_generate_base_pass`, `run_native_world_generate_post_base_pass`, `run_native_world_generate_pass`, `start_native_generation`, `run_native_generation_slice`, `finish_native_generation` | 发送请求、校验、装配 HexCell/MapData；native 失败硬中止 push_error。 |
| Bake-time static texture encoders（生成期） | C++ byte payload + GDScript GPU upload | `encode_bake_height_tex_data`, `encode_bake_terrain_normal_tex_data`, `encode_bake_horizon_tex_data`, `encode_bake_enum_atlas_payload`, `encode_bake_flow_tex_data`, `encode_bake_r8_tex_data`, `encode_bake_upwelling_tex_data` | `Image.create_from_data`、`ImageTexture.update/create_from_image`、ext 缺失时 debug fallback。 |
| Bake-time 几何场编排（生成期 terrain-index/erosion/river SDF/latitude/coast SDF） | **C++ 单次融合驱动 `run_bake_geometry_fields_pass`（融合优先 + 旧 per-pass 回退）** | 内部串 `run_bake_terrain_index_pass`/`run_bake_erosion_pass`/`run_bake_river_sdf_pass`/`run_bake_latitude_field_pass`/`run_bake_coast_sdf_pass` | GDScript 一次请求→解包到 `world.*`+重建 lookup；河流图遍历读 ext 暂存拓扑（零再传输）；river/coast carve 就地作用 height_final；GPU 上传。中间 height buffer 不跨语言往返。 |
| Native daily sim | Partial ACTIVE continuation | `run_native_daily_slice`, debug `run_native_daily_tick`, shadow `run_native_sim_tick` | SUS shell、round-start bundle、fallback/debug、front objects、weather LUT/Godot visual intents。 |
| Temp baseline year bake（生成期） | C++ 权威 + GDScript fallback | `run_temp_baseline_year_bake` | `cell_lat_norm` 几何量烘焙、ext 未就绪时 fallback。 |

> `cell_temp_baseline_year`（海冰 + 显示温度的运行期年 baseline）权威计算已收回 C++，见下文 "Temp baseline year bake" 节。注意它与 pass_a 每日写的运行期 `cell_temp_baseline`（辐射 + 热惯性积分）是两个不同字段。

## Static research-signal generation

`run_research_signal_generation_pass` is a post-assembly native map pass. It receives generation
vegetation, landform/river/volcano/water arrays, dimensions, seed, and the catalog's dense static
signal IDs. It emits `generation_vegetation`, `cell_biogeographic_realm`, and a cell-indexed CSR
(`cell_signal_offsets`, `cell_signal_ids`, `cell_signal_values`). No new DataCore component or
per-cell Godot object is created.

The pass currently derives maize/wheat/potato/horse from deterministic realm + generation habitat,
and derives freshwater, river valley, volcanic, high plateau, and coastal estuary from static map
fields. `MapGenerator` validates only CSR shape and publishes it to `MapData`. On vision's first
exploration of a cell, `WorldRuntimeHost` submits a country command; C++ country state—not MapData—
records the discovery. Runtime vegetation evolution and cover do not revoke knowledge.

## Native world generation base + post-base + publish（生成期）

主要入口：

- `DCWorldExt::run_native_world_generate_base_pass`（无 bind 的 C++ base SoA 生成结果包）
- `DCWorldExt::run_native_world_generate_post_base_pass`（无 bind 的 C++ post-base SoA 结果包）
- `DCWorldExt::run_native_world_generate_full_pass`（**step4 融合**：进程内串 base→post_base，base bundle 不出语言边界）
- `DCWorldExt::run_native_world_generate_pass`（单调用生成期 publish）
- `DCWorldExt::start_native_generation` / `run_native_generation_slice` / `finish_native_generation`（同一 publish pass 的切片 API 外壳）
- `map_generator.gd::_generate_cells_native_base`（ACTIVE 编排：发 cfg/profile 请求，接收 PackedArray 结果并装配 `MapData`）
- `map_generator.gd::_publish_native_generation_from_slots`（bind 后 publish：`DCWorldExt.bind_map_data` + `configure_native_world` 后调用）

**迁移状态（dots-total-cpp 2026-06-18 完成）**：`native_generation_mode` 默认 `ACTIVE(2)`。经逐字段 A/B parity（seed=10086，base+post_base 全字段 `mismatch=0`）+ 运行期同 seed 地形直方图一致验证后，**GDScript 生成实现已删除，C++ 是唯一生成路径，无 GDScript fallback**。

调用方必须 `await MapGenerator.generate()`。它调 `_generate_cells_native_base(cfg, seed)`，后者经 `_ensure_generation_world_ext()` 拿到（必要时临时实例化）未绑定的 `DCWorldExt`，调用 `run_native_world_generate_base_pass(seed, cfg, profile)`，由 C++ 直接生成基础地图 SoA 结果包：cube 坐标、elevation、moisture/base_moisture、初始 temperature、terrain/is_water、lat/temp_year、landform/vegetation/cover 等 PackedArrays。随后 `run_native_world_generate_post_base_pass(seed, cfg, profile, base_res)` 在 C++ 内完成 Priority-Flood 水文修正、湖盆筛选、parent graph flow accumulation 河流，并输出 `has_river_arr / river_downstream_arr / river_flow_arr` 供 Baker 追踪主流/支流和可变河宽；之后继续完成河岸/植被反馈、过渡生态、地标和水体变种。GDScript（`TerrainGeneratorScript.assemble_native_result`）只负责校验返回数组尺寸并装配成 `MapData`/`HexCell`。生成器和 Baker 在重阶段边界协作式让出主循环帧，但单个 native pass 仍不可抢占。**若 ext 缺失、方法缺失或结果非法，`_generate_cells_native_base` 返回 null，`generate()` 硬中止并 `push_error`（旧 `_generate_cells` fallback 已删除）。**

Post-base 地形/生态契约：`river_flow_arr` 只表达视觉河宽；post-base 内部保留不出境的 `river_ecology_flow`，沿用旧 `0.15 + raw_norm*0.85` 标尺驱动大河源、三角洲和泛滥平原阈值，避免细支流视觉调参改变生态。低地或强径流河道不再保持 `DESERT/SALT_FLAT/BADLANDS/COLD_DESERT/MESA`，而会转为 `FLOODPLAIN`、暖干高地强河转 `OASIS`、较小暖干河道转 `STEPPE`；`FLOODPLAIN` 的 landform 统一派生为 `PLAIN`。三角洲、泛滥平原、高原和裂谷的触发门槛由 post-base 统一控制，`stage_counts` 暴露 `river_desert_repaired`、`river_floodplain_channel`、`final_climate_redecide`、`delta`、`plateau`、`rift_valley` 等计数用于 CSV/日志诊断。

**裂谷自然候选（2026-07-31）**：`RIFT_VALLEY` 不再按 `min(48, land/140)` 截断，也不再强制候选格相隔两格。post-base 先以对置断崖高差确定横断面，再只沿断崖之间的谷轴连接候选；所有达到 `rift_min_length_cells` 连续物理长度的构造带完整保留。`rift_min_wall`、`rift_min_axis` 随固定世界的采样分辨率缩放，`rift_min_length_cells` 按线性分辨率换算。该长度门槛只排除孤立洼点和短沟槽，不构成全图数量或面积配额。报告发布候选数、连通分量数、碎片拒绝数、最大分量和有效最小长度。

**荒原自然候选（2026-07-28，2026-07-31）**：`BADLANDS` 不再由所有达到单一高差门槛的 `DESERT/COLD_DESERT` 直接改写。post-base 先按 `badlands_min_relief`、`badlands_min_rugged_neighbors` 和远离海/湖/河条件构建候选，再按连通分量从最高侵蚀分数格向邻格生长；默认不启用总量或斑块硬配额，候选连通区自身决定荒原范围。`badlands_max_land_ratio`、`badlands_max_arid_ratio`（默认均 1.0）和 `badlands_max_patch_cells`（默认 0）仅作为调试/极端地图安全阀，显式收紧时才截断；未入选候选保持原 `DESERT/COLD_DESERT`。报告保留 `badlands_arid_source_count`、`badlands_candidate_count`、`badlands_candidate_components`、`badlands_selected_count`、`badlands_budget`、`badlands_budget_rejected`、`badlands_largest_component`，`qa_metrics` 同时发布陆地/干旱占比。

**大地图河流密度自适应（2026-06-30，2026-07-30 修订为双向）**：`river_channel_init_cells`、`river_headwater_init_cells`、`hydro_river_min_length` 仍保留 profile/UI 的相对密度语义，但 post-base C++ 会以 150×100（15000 cells，`ClimateProfile` 注释中的经验基准）为基准，按 `pow(n_cells / 15000, 1.0)` 线性缩放汇水格数阈值；短河最小长度按该 scale 的 1.0 次方缩放（与河道阈值同步）。这样 200×150 不再用中图的固定 16 格汇水阈值切出过密支流，而会得到约 `river_channel_init_effective=32`、`river_headwater_init_effective=20`、`hydro_river_min_length_effective=10` 的有效值。`run_native_world_generate_post_base_pass` 返回 `river_map_scale` 与三个 effective/base 字段用于诊断。**2026-07-30 修订**：原 `max(1.0, …)` clamp（"小于等于 15000 cells 的地图不降低阈值"）改为双向缩放（下限 0.25 仅防极端小图阈值归零）——诊断发现世界是固定大小的行星（噪声在归一化圆柱坐标采样，经度恒 2π、纬度恒 [0,1]），同源点汇流格数 ∝ N，旧 clamp 使小图（如 64×100=6400 cells）阈值相对流域面积偏高 ~2.3×，支流发不出来，"小图河稀"反衬出"大图河多"；双向缩放后任意分辨率河网物理密度一致。

**生成期分辨率归一（scale-fix，2026-07-30）**：根因——世界是**固定大小的行星**：base/post_base 全部噪声在归一化圆柱坐标采样（`lon=col/width`、`ny=row/height`，经度恒跨 2π、纬度恒跨 [0,1]），与格数无关；改变地图尺寸不是"更大的世界"而是"同一世界的更密采样"，1 格的物理尺寸 ∝ 1/√N。凡"以格数标定的物理距离/比率"参数都必须随分辨率换算，否则同一星球在不同分辨率下气候/地貌系统性漂移（实测：150×200 大陆腹地因湿度场崩缩几乎全沙漠、河流反衬性偏多、山体采样更完整显得更高）。基准为 15000 cells（150×100，`ClimateProfile` 调参基准），线性分辨率比 `s = sqrt(max(0.0625, N/15000))`。四处修复（均在 `world_ext_generate.cpp` 内部，无绑定/接口改动）：

1. **湿度模型格距归一（base pass）**：`coastal_temp_scale`、`moisture_coastal_scale`、副热带干旱带 interior 饱和距离（`dd/8` 的 8）×s；每格保留率类换成每物理距离保留率 `(1-r)^(1/s)`——`moisture_rainout_base`、`moisture_continental_dry`（纬向平流湿气每格 `×(1-rainout)×(1-dry)` 的指数衰减此前随穿越格数无限叠加，是"大图内陆全沙漠"的主因）；加性 `moisture_wind_evap` ÷s（cap 饱和使长距离海上穿越本就不敏感）。地形增雨 `upslope×gain` 刻意不动：相邻格 ΔE 自带 1/s，与"坡面格数 ∝ s"相消天然自洽。`moisture_land_base`/噪声幅度/湿度地板值是湿度量纲不是距离，不动。诊断输出 `hydro_dist_scale` + 各 `*_effective` 字段。
2. **雨影探针距离（post_base）**：`rain_shadow_lookback` ×s 取整（0 仍是"关闭雨影"语义），保持雨影物理到达距离恒定。注：**运行期**季节雨影（`climate_daily_system.pb_rs_lookback` → `world_ext_climate.cpp`、runtime stage_1）仍传原始 profile 值，本次只归一生成期；如需运行期一致需另行处理。
3. **RFLOW 归一化改基准等效流量（post_base）**：`flow_eq = flow × (15000/N)`——同源点汇流量 ∝ N（单位面积产流率 size-invariant × 流域格数 ∝ N）→ flow_eq 跨分辨率不变；min（≈channel-init 处流量 `river_threshold`）与 max（最大流域出口）同乘该系数后 log min-max 两端缩放一致，消除旧法"大图 log 区间更宽、中流归一流量系统性偏高 → 同一条河在大图偏宽"的不对称。等效流量保持 15000 格量级，log1p 动态压缩特性不变。下游 `PK_RIVER_INCISE` 下切、floodplain `RFLOW≥0.45`、河岸生态 `RFLOW≥0.55` 等全部 RFLOW 消费者自动变为分辨率无关。诊断输出 `flow_eq_scale`。
4. **结构地貌高度与 relief 阈值缩放（post_base）**：地貌分类不再用 `(elevation-sea_level)/(1-sea_level)` 作为高度门控；它统一调用 `pk_geomorph_h=(elevation-sea_level)/(1-0.42)`，以 `0.42` 参考海平面固定陆地高度跨度。实际海平面仍决定水陆边界，气候雪线、水文和生态继续使用原实际海平面归一化；因此低海平面 profile 不会再把最高山压到 MOUNTAIN/PEAK 门槛以下。`mountain_min_relief`、`badlands_min_relief`、rift wall/axis 按 `(15000/N)^k` 双向缩放，profile knob `relief_thresh_scale_exp` 默认 `0.25`，避免 60x40 等小地图因 `k=0.5` 将局部高差门槛放大到候选集之外。`peak_min_prominence` 维持不缩（PEAK 有 `land/120` 数量上限主控）。诊断除 `gen_dist_scale`、`relief_thresh_scale` 和 effective 阈值外，还输出 `mountain_height_candidates`、`mountain_relief_candidates`、`mountain_kept`、`peak_candidate_count`、`plateau_candidate_count`，并同步写入相关 `stage_counts`。

**大地图高原密度控制（2026-06-30，density-fix）**：诊断发现 PLATEAU 是唯一没有密度上限的特征地貌（PEAK 按 `land/120` 限量、RIFT 按 `land/140` 限量，唯独 PLATEAU 所有满足阈值的平坦中高海拔区全部标记），导致大地图上高原铺满。修复为四层：(1) 新增 `plateau_max_land_ratio`（默认 0.25）面积占比上限——post_base 在高原标记+山地降级完成后，按连通分量面积从大到小累计，保留至 `land × ratio` 为止，较小连通分量整体降级为 HILL（保留大高原、清理碎片）；(2) `plateau_max_relief` 按 `pow(15000/N, 0.25)` 随大地图收紧——精细 cell 采样使 per-cell relief 自然变小（同梯度高分辨率采样→更小逐格高差），固定阈值会放过过多候选，故按此因子收紧（N≤15000 时 scale=1.0 不变）；(3) `plateau_min_land_h` 默认 0.25→0.35，收紧下界排除低地"伪高原"（原区间 `land_h∈[0.25,0.90]` 对应 `E∈[0.565,0.942]` 覆盖陆地大部分中高段）；(4) `PK_PLATFORM_UNDULATE` 0.03→0.04，略增大陆地台起伏，减少完美平坦的中等海拔区。配套河流侧：`river_headwater_init_cells` 默认 6→10，减少用更低阈值主动 trace 的支流补充。`stage_counts` 新增 `plateau_demoted_to_hill` 计数。

**河流相邻末端可视合并（river-confluence-snap，2026-06-26）**：河流线由 `run_bake_river_sdf_pass` 只沿"下游父边"(`river_downstream`/RDOWN) 逐段 stamp，**网格相邻 ≠ 会画连接线**——两个直接相邻的 river cell 若不构成父子关系，中间不绘段 → 渲染出"末端/起点贴边却不合并"的干缝。post_base 在 river-lake-snap 之后、河流下切 E 之前新增一道 snap：对 `RDOWN<0` 的**可视悬空末端**（其水文父非河/水，trace 在它处断链），若 1 格邻居有 river cell 且接它不成环（沿邻居 RDOWN ≤64 步回到自身则跳过），把 RDOWN 接到最佳邻居（优先：其链能抵达终端水体 > `river_flow` 更大 > 高程更低），让 trace 多画一段缝合两链。**仅改 `RDOWN<0` 的悬空末端、不重路由已有下游的河格 → 不改动既有河链/流域**；两条各自抵达自身出海口的独立流域（双方 `RDOWN>=0`）刻意不合并（水文学上是分水岭两侧的独立盆，正确行为）。**RDOWN 仅供 SDF trace + `cell.river_downstream`（可视）消费；运行期日级汇流路由走 `hydro_parent`（独立无环），本 snap 完全不触碰运行期语义**。计数：`stage_counts["river_confluence_snap"]` / `out["river_confluence_snap_count"]`。

**湖泊水下深度场（lake-bathymetry，2026-06-26）**：海洋洋底由 base pass 两段距岸 BFS（§2.55 ocean-bathymetry + water-tuning「距岸距离驱动洋底深度」）刻出"大陆架→坡→深渊"的真实 `elevation` 梯度；而湖泊只在 post_base 被打 `TERR=18` 标志，湖底高程一直停留在洼地填充后的近似平面，渲染端只能靠 shader 邻域代理（`water_pipeline.gdshaderinc::compute_lake_shore_proxy`）凑深浅，大湖中央一片均一（用户反馈"湖泊没有像海洋那样的深度/海拔变化"）。post_base 在**所有 LAKE 最终确定后（depression-flood 湖 + isolated-water 转湖都已落定）、`sync_axes` 之前**新增一道湖泊 bathymetry pass（对标海洋 BFS）：逐个湖泊连通域，从湖岸（湖内紧邻非湖/出界的格=dist0）向湖心做多源 BFS 得每格离岸 hex 距离，按归一化距离把湖底 `E` 压向"以该格水面 `hydro_fill` 为深度=0 基准"的碗形梯度（`pk_smoothstep(PK_LAKE_SHELF_T,1,t)`，近岸浅滩带 + 湖心深），湖深随湖体半径 `max_dist` 自适应（`PK_LAKE_DEPTH_PER_CELL`，clamp 于 `PK_LAKE_MIN/MAX_DEPTH`）并叠确定性低频噪声（经度环绕采样）造湖底浅丘/深潭。**只下切（`E=min(E,floor)`）、绝不抬升 → 不会把水翻到陆上；不改 `TERR` → LAKE 分类/landform 不受影响（`pk_derive_landform` 对 `terrain==18` 恒返回 LAKE）**。结果经既有 `out["elevation_arr"]` 导出，GDScript 仍只解包进 `HexCell.elevation`（无 wrapper 改动）；下游 height 纹理 → shader `lake_bathy`（`(sea_level+0.08-elev)/0.42`）/relief/hillshade 全部拿到真实湖盆深度。一键回退：profile `lake_bathymetry_scale=0`。计数：`out["lake_bathymetry_components"]` / `out["lake_bathymetry_cells_carved"]`。

**统一水深纹理 water_depth_tex（water-depth-tex，2026-06-26）**：起因——shader 海/湖深浅是两套独立采样：海洋 `compute_offshore_depth` 采 5×5/plus height 邻域（desktop q2 = 9 次），湖泊额外 `compute_lake_shore_proxy` 采 **map_index_atlas（biome 图，另一张纹理）多半径**（q2 = 16 次）→ 一个湖泊像素 ≈ 25 次采样，且湖岸距离只是粗代理（注释明言"真正的 lake SDF 没有由 baker 输出"）。既然 lake-bathymetry 已把真实湖盆深度刻进 `elevation`，把深浅信号统一**烘成一张 R8**、shader 每水像素仅 1 次采样：① **post_base C++** 算 per-cell `water_depth01 ∈ [0,1]`（海洋/海岸/礁/海草/海冰 = `clamp(1-E/sea_level)`，E 已含洋底距岸 BFS 梯度；湖泊 = 上面 bathymetry 的碗形 ramp × 湖体尺寸因子 `depth_amp/PK_LAKE_MAX_DEPTH`，小塘浅/大湖深；非水格 0），经 `out["water_depth_arr"]` 导出；② **assemble** 解包到新字段 `HexCell.water_depth`（简单 var，bake-time only，不走 SoA facade）；③ **bake** `_bake_geometry_fields_native` 把 `cell.water_depth` 收进 `cell_water_depth` knob，**fused 几何 pass `run_bake_geometry_fields_pass` 用 terrain-index 产出的 `pixel_to_cell_index` 扇出成 R8 `water_depth_buffer`**（零额外像素级计算，与 enum_atlas 同 CSR 机制），`encode_r8_tex` → `world.water_depth_tex`；④ **hex_renderer** 绑 `water_depth_tex` + `has_water_depth_tex`；⑤ **water_pipeline.gdshaderinc** `compute_offshore_depth` 开头新增快速路径：`has_water_depth_tex` 时单次采样 `water_depth_tex.r` 直接填 `depth_t/offshore/offshore_depth/deep_layer_w/lake_depth_proxy`，`lake_shore_w` 由水深反推（免多半径 biome 采样），`return` 跳过两套旧邻域估算。**采样数：湖泊 25→1、海洋 9→1**；旧路径作 `has_water_depth_tex=false`（未烘焙/fused 失败/旧存档）的 fallback 保留（uniform bool 分支 GPU 无 divergence）。一键回退：bake 产出空 buffer → `water_depth_tex=null` → 自动走旧路径。

> **最终实现修订（2026-06-26，per-pixel 真实高程）**：上述 ①/③ 的 per-cell ramp 方案在巨湖上失效——湖深按湖半径归一（`t=sdist/max_dist`）时圆盘里绝大多数格靠岸 → `depth01≈0`，调试灰度图几乎全黑。最终改为**用逐像素高程图驱动**：① **post_base** `cell_water_depth` 不再存 ramp，而是存 **per-cell「水面高度 level」**（湖=该湖 `hydro_fill` 水位、海/海岸/礁/海草/海冰=`sea_level`、陆=0）；③ **fused pass** 逐像素算真实水深 `draw = surface − height_final[px]`（`height_final` 含 lake-bathymetry carve 的湖盆 + 洋底 BFS + 侵蚀细节），再按水体类型归一化（湖用 `LAKE_DEPTH_NORM=0.16`、海用 `sea_level` → 湖也吃满 [0,1] 对比，不会比深海更黑），`clamp01×255` 写 R8。这样水色与真实地形起伏/relief **逐像素对齐**（不再是 cell 级粗块），小湖按真实浅度显示。湖深不足/对比不够时调 `LAKE_DEPTH_NORM`（`world_ext_bake.cpp`，调小=加深）或 `PK_LAKE_MAX_DEPTH`（`world_ext_generate.cpp`，加大=湖盆 carve 更深）。lake-bathymetry 的 `PK_LAKE_SHELF_T/PK_LAKE_DEPTH_PER_CELL` 同步改为绝对离岸距离常量 `PK_LAKE_SHELF_CELLS=1.5/PK_LAKE_DEEP_CELLS=7.0`。



bind 后仍保留 `run_native_world_generate_pass` publish 层：在 `MapData.init_soa_from_bake()` 和 `bake_lat_temp_year_lut()` 后，`DCWorldExt` 读取已绑定的 `cell_lat_norm`、`cell_elevation`、`cell_terrain` 等 slot，以 C++ SAME_SOURCE 公式重算并发布初始 runtime 字段。这一层用于 slot/MapData 同步和窄 fallback，不再代表完整基础生成算法。

输出 slot：

- `cell_temp_baseline_year`：`pk_lat_temp_bell((ny - 0.5) * 2)`。
- `cell_temp` / `cell_temp_baseline` / `cell_temp_30d` / `cell_temp_365d` / `cell_thermal_energy`：`pk_compute_temperature(ny, elevation, sea_level)` 冷启动值，海拔惩罚基于 `lerp(land_h, elevation, 0.25)`。
- `cell_temp_anomaly`：0。
- `cell_ema_initialized`：1。
- `cell_is_water`：由 `pk_is_water_terrain(cell_terrain)` 派生。

发布契约：C++ 写 slot 后逐项 `_flush_slot_to_map` 回 `MapData`，返回 `path=gdext`、`published_to_slot=true`、`published_slots`、`n_cells`、`compute_ms`、`flush_ms`、`elapsed_ms`。GDScript wrapper 成功后调用 `flush_pending_mark_dirty_all()`，并重绑 GDScript `DCWorld`，避免 C++ flush 后 `MapData` PackedArray reseat 而 DataCore GDScript world 仍持有旧引用。

Fallback（仅指 bind 后的 republish 层 `run_native_world_generate_pass`，**不是基础生成**）：未 bind、缺 slot、slot dtype/size 不匹配时返回 `path=gdscript_fallback`、`fallback=true`、`fallback_reason`。此时保留 `map.bake_lat_temp_year_lut()` 与既有 SoA 值（来自 C++ 基础生成），并继续调用专用 `run_temp_baseline_year_bake` 作为更窄的 C++ baseline fallback。注意：基础生成（base+post_base）本身已无 GDScript fallback，失败即硬中止。

**base+post_base 融合（dots-total-cpp step4，2026-06-25）**：原先 `_generate_cells_native_base` 先调 `run_native_world_generate_base_pass` 拿到 base bundle（10×n_cells SoA：q/r/elevation/moisture/base_moisture/temp/terrain/landform/vegetation/cover），在 GDScript 侧校验后再 `run_native_world_generate_post_base_pass(…, base_res)` 传回——base bundle 经历一次 `C++→GDScript→C++` round-trip。新增 `run_native_world_generate_full_pass(seed,cfg,profile)` 在 C++ 进程内先跑 base、再用其结果跑 post_base，**base bundle 全程留在 C++ 不出语言边界**，一次返回 post_base 最终 bundle（合并 `base_water_count/base_land_count/base_native_ms/native_algorithm` 诊断键供 GDScript 打印）。`_generate_cells_native_base` 为**融合优先 + 旧两次调用回退**（`has_method("run_native_world_generate_full_pass")` 探测；DLL 未 rebuild 时退回旧路径）。base 失败 → full_pass 透传 base 结果（rc/fallback），GDScript 据此中止。

**bind 后 republish 保留（step4 刻意未删）**：`run_native_world_generate_pass`（bind 后读 bound slot 重算初始温度仿真场 `cell_temp/temp_baseline/temp_30d/temp_baseline_year`）**本身已是 C++**——它不是 GDScript 计算，删它不会减少跨语言计算，只会重构 `bind_map_data` → C++ flush（`set()` reseat）→ `rebind_map_data` 的脆弱时序（该 rebind 专门防 flush reseat 后 scheduler/facade 持悬垂 PackedArray 引用）。收益边际、风险高，故 step4 **仅做 base+post_base 融合，保留 republish 不动**。



## Bake-time static texture encoders（生成期）

生成期 `MapBaker.bake_world()` 的静态纹理编码现在采用 C++ byte payload + GDScript GPU upload 分层：`DCAtlasEncoders` 只负责 dispatcher 和 `ImageTexture` 创建/更新，逐像素量化与字节打包由 `DCWorldExt` 执行。

C++ 入口：

- `encode_bake_height_tex_data`：`height_buffer` F32 `[0,1]` → RG8 16-bit，高字节/低字节与旧 GDScript `round(v*65535)` bit-equivalent。Legacy 上传时由 `DCAtlasEncoders.encode_height_flow_tex` 再与 flow 拼成 RGBA8（B=flow）。
- `encode_bake_terrain_normal_tex_data`：**生成期烘焙"总体地形法线"**（2026-06-25）。`height_buffer` → 宽半径（`coarse_radius` texel）中心差分得平滑梯度，按参考增益 `slope_gain` 构 `N=normalize(-sx,-sy,1)`，存 `nx,ny`→RG8（`nz` shader 重建）；X 圆柱环绕、Y clamp；按行 `pk::parallel_for_range` 并行。地形是静态的，这张图烘一次、之后不变；运行期 shader 1 次采样即得宏观山脉走向，替代每帧宽半径 4-tap。GDScript 侧 `DCAtlasEncoders.encode_terrain_normal_tex` 提供等价 debug fallback。
- `encode_bake_horizon_tex_data`：**生成期烘焙 8 方向地形遮蔽角**（2026-07-03，2026-08-02 低频化）。`height_buffer` 先在 Horizon 派生路径内做独立 3×3 `1-2-1` 高斯低通（不回写侵蚀/河流/法线使用的权威高度），再沿 E/NE/N/NW/W/SW/S/SE trace；marching 距离为 `step_px·(s + 0.5·step_growth·s·(s-1))`，近处密采样、远处渐增，避免固定步长形成规则梳状阴影。取最大 `atan2(dh*height_world_scale, dist_world)`，按 `max_horizon_angle` 量化为 4-bit；RGBA8 每通道 high/low nibble 存两个方向（R=E/NE, G=N/NW, B=W/SW, A=S/SE）。默认 `height_scale_hex=16`、`step_growth=0.35`、`lowpass_radius=1`。采样坐标 X 圆柱环绕、Y clamp；遮挡距离按射线实际行进距离计算，不取圆柱最短经度距离。低通与 trace 均按行 `pk::parallel_for_range` 并行。因 nibble-packed byte 不能硬件线性过滤，运行期 shader 用 NEAREST 采样并在解码后手动双线性插值，再按 TOD 太阳方位插值。GDScript 侧无热循环 fallback；ext 缺失时返回 null/旧纹理，shader 自动关闭。**可选 `emit_occluder_cells=true` + `map_index_data`（全局 map-index RGBA8）时顺带产出 `occluder_data`**（terrain-gi 2026-07-31）：同一次 trace 记录每个方向的最强遮挡落点，取量化角最大的两个方向，把落点的 `cell.index`（map-index 的 G/B 通道）打包成 RGBA8（RG=主源、BA=次源，低字节在前，`0xFFFF` 为无效哨兵）。它是 tiled compute 路径 `gi_occluder` 的 legacy 等价物，独立降级——不传 map_index 就只出 horizon，AO/bent normal 不受影响、只关闭弹射。
- `encode_bake_enum_atlas_payload`：map-index atlas RGBA8，`R=biome`、`G/B=cell.index low/high`、`A=landform`；输入使用 `WorldData` 的 CSR 像素反向索引与按 `cell.index` 排列的 landform byte。
- `encode_bake_flow_tex_data`：river SDF/flow F32 `[0,1]` → L8。Legacy/Tiled 均打进 height 纹理的 B 通道，不再单独建 `flow_tex` / `visual_flow_tiles`。
- `encode_bake_r8_tex_data`：通用 U8 → L8，支持缺失输入时按 `default_byte` 填充（火山场默认 0、upwelling buffer 默认 128）。
- `encode_bake_upwelling_tex_data`：F6 debug upwelling 纹理，读取已绑定 SoA 的 `cell_terrain` 和 `cell_upwelling_strength`，通过 pixel→cell index 表编码 L8；未 bind 时保留 GDScript debug fallback。

GPU 上传仍在 GDScript：`Image.create_from_data`、同尺寸 `ImageTexture.update`、新尺寸 `ImageTexture.create_from_image`。因此 C++ 迁移目标是消除 CPU 字节循环，不把 Godot 渲染对象生命周期迁入 native。`patch_enum_atlas_axes` 已统一为当前 map-index RGBA8 契约：只 patch `R=biome`，不再把 vegetation/cover 写入 G/B；vegetation/cover 变化只更新 per-cell LUT/buffer，不触发 map-index atlas upload。

### 高分视觉 Tile 静态链路（2026-07-30）

`MapBaker._bake_visual_tiles()` 在全局几何基线完成后把真实 `hex_size` 交给
`VisualTileLayout`。layout 由平台/画质档位的 `texels_per_hex` 先确定单个 512 interior 可覆盖的
世界范围，再按 `visual_domain` 面积推导 grid/N；整图 MP 只是结果，设备 layer/显存超限时降低
密度重算。随后复用一次构造的
cell SoA 和全局 height/flow/water buffers，逐层调用
`run_bake_visual_tile_layer_pass`。C++ 返回 height、normal、map-index、flow、water-depth、
detail 和 edge 两字段的 byte bundle/hash；每层立即上传到 `Texture2DArray` 并释放 staging，
不创建高分 `pixel_to_cell_lookup` 或 CSR。静态全层成功后才发布 `WorldData.visual_tiles.ready`。
其中 normal 用 X/Y 独立的世界空间中心差分，并以全局基线 texel 校准强度和平滑半径；
river/coast SDF 截断距离与 shore-carve band 也按 Tile/基线 texel 比例换算，halo 覆盖换算后范围。
cell edge distance 保持 `hex_size` 归一的世界距离单位，高分辨率只提高量化精度；shader 的 8x8
Bayer DitherUV 则锚定全局基线 texel 的世界尺寸。因此视觉预算或 Tile 数量变化不会系统性
压平宏观坡度，也不会缩窄距离场或改变 dither 的世界尺度。

随后 `VisualTileHorizonBaker` 用 RenderingDevice 构建跨 layer max-height pyramid；decode 只在
horizon 派生场把 bathymetry 抬到 `sea_level`，并做同样的 3×3 高斯低通，再以 8 方向 hierarchical trace 生成
nibble-packed horizon。主 traversal 超限后用方向局部的 conservative tail 完成剩余射线，避免
全图最高点形成无关长影。周期 X 查询必须先按 level-0 logical width 环绕再缩减到 mip cell；
shader 中包括低通邻域在内的负向 X 采样必须使用非负操作数的 `wrap_column`，不能直接对负数
使用 GLSL `%`，否则不同驱动会把接缝左邻列映射到错误位置并经 pyramid 放大为纵向阴影带。
跨接缝 span 显式覆盖首尾 coarse cell，保证非 2 次幂逻辑宽度下的局部上界连续。compute 失败时
`run_resample_visual_horizon_layer_pass` 把全局 horizon 重采样为相同布局；任一静态字段失败则
整个世界回退 legacy。完整字段、寻址、预算、diagnostic 和验证契约见
[Visual Tile Rendering](./visual-tile-rendering.md)。

## Terrain-index bake pass（生成期权威主归属 + 独立视觉边界场）

主要入口：

- `DCWorldExt::run_bake_terrain_index_pass`（C++ 权威）
- `rendering/bakers/terrain_index_baker.gd::DCTerrainIndexBaker`（wrapper：构 knobs / 调用 / 解包 / 重建对象侧反向索引 / edge texture 编码）；`MapBaker` 仅保留 facade 调度。旧 `_bake_terrain_index_native_legacy` 仅用于 stale-DLL/A-B 诊断，不是生产 authority。
- `terrain_baker.gd::DCTerrainBaker.bake_height_biome_moisture`（GDScript ground-truth，A/B + ext 缺失 fallback；无 dither），共享几何 helper 由 `terrain_geometry_utils.gd::DCTerrainGeometryUtils` 提供
- `terrain_baker.gd::DCTerrainBaker.rebake_terrain_detail_texture` 负责 detail noise → R8 raster 和 encoder 调用；`MapBaker` 仅负责 `WorldData.terrain_detail_tex` 赋值与时序。

链路：`bake_world()` 的核心逐像素循环（warp 双频 + `cube_round` 几何归属 + sextant 两邻居 barycentric + per-biome detail/ridge noise）已下移 C++。pass 全程经 knobs 传参（不依赖 bound slot —— bake 发生在 generation 期、bind 时机不定，与 `encode_bake_*` 同范式）：输入 W/H、world_bounds、hex_size、wrap_period_x、seed，以及 cell SoA（`cell_elevation/moisture/terrain/vegetation/cover` by cell.index）与 `offset_to_index` 映射；GDScript wrapper 现场从 `HexCell` 属性构建这些数组（~n_cells 次）。C++ 内用 `Ref<FastNoiseLite>` 复刻 `map_baker._init_noise`（seed+71/+233/+503/+977），并复刻 `_cyl_noise` 2D 接缝包裹。所有带 x 偏移或频率缩放的噪声调用都必须把相位原点同步传给 cylindrical helper（如 `x+31.7`、`x+91.1`、`x*CRAG_FREQ_MUL+17.9`），否则 `fposmod` seam 会被搬进地图内部。

**权威索引与视觉边界解耦**：`biome(R)`、CSR 桶（驱动编码器
`G/B=cell.index`、`A=landform`）、`vegetation`、`cover` 与
`pixel_to_cell_index` 全部跟随 warp 后的硬 `cube_round` 主格，不再由
Bayer 改派。pass 同时输出 RG8 副索引和 R8 主/副中心距离差，供渲染器按档位
处理视觉过渡。桌面地表把连续距离场与 atlas-texel 8×8 Bayer DitherUV 混合，
但 Dither 只用于远景并在近景完全淡出；桌面战争迷雾和天气保持连续距离场。移动端使用
DitherUV 在主/副视觉 cell 间二选一，以保留远景颗粒与单 LUT 采样成本，同样在最
近景完全淡出，避免放大的 atlas texel 棋盘。Dither
只存在于 shader consumer，不会改变权威 cell、CSR、交互或动态状态的归属。
三套 8×8 Bayer consumer 都把原始 `[0,1]` rank 压缩到 `[0.18,0.82]`；
边界处仍保持精确 50% 覆盖，但极低 rank 不会穿过大半个宽距离场形成单 texel
长刺。X 相位按 `wrap_period_x` 对齐到 8 texel
整数周期。`height`/`moisture` 仍走几何 barycentric，`height` 再叠 per-pixel
relief（见下 “P0 relief”）。

输出：`height_buffer`(F32) / `biome_buffer` / `vegetation_buffer` / `cover_buffer`(U8) / `moisture_buffer`(F32) + CSR 三件套（`cell_first_px`/`cell_px_count`/`flat_px_indices`，counting-sort by cell.index，直接喂 `encode_bake_enum_atlas_payload`）+ `pixel_to_cell_index`（wrapper 据此重建 `world.pixel_to_cell_lookup` 与 `cell_pixel_lists`）。

**P0 per-pixel relief 重做（2026-06-25）**：旧实现按 `terrain==MOUNTAIN/HILL/其他`**硬分档**叠**各向同性** ridged FBM（`MOUNTAIN_RIDGE_AMP/HILL_AMP/PLAIN_AMP`），山地呈无走向"脑沟"鼓包、边界突兀、平原不平。现替换为地形模拟式 relief（C++ `run_bake_terrain_index_pass` step7 + GDScript `DCTerrainBaker.bake_height_biome_moisture` 镜像，逐位对齐）：

1. **per-cell 梯度/relief 预计算**（像素循环前，O(n_cells×6)）：六邻居有限差分（2×2 最小二乘）得世界空间高程梯度 `CGX/CGY`，及邻格最大高差 `CREL`。C++ 走 offset 网格 + `cell_at_cube`，GDScript 走 `map.all_cells()` + `_get_wrapped_cell_by_cube`；用 unwrapped cube 世界坐标算偏移（接缝处连续，梯度为求和故顺序无关）→ 两侧结果一致。
2. **各向异性脊线**：脊线方向 = 梯度的垂直方向（沿等高线）；沿该方向 3-tap `cyl()`/`_cyl_noise` smear（步长 `RIDGE_SMEAR_HEX`）→ 山脊沿走势拉长，治"无走向"。每 tap 单独经接缝包裹，圆柱无缝。
3. **连续振幅门控**：`amp = RELIEF_AMP * smooth01(RELIEF_LO, RELIEF_HI, relief)`，由局地起伏连续驱动、**不再绑 terrain 类别**；平原 relief→0 ⇒ amp→0（视觉真平），丘陵→山地平滑过渡无硬边。
4. **山脊/山谷不对称**：`shaped = pow(ridge01, K_CREST)`（尖脊 + 缓谷）；`(shaped - VALLEY_BIAS) * amp` 使谷底负偏置 → 河道天然落低处，与下游 `run_bake_erosion_pass`（droplet）/ `run_bake_river_sdf_pass` 自洽。
5. **气候耦合**：`crag * CRAG_AMP * (0.4 + 0.6*dryness) * gate`，干燥（低 moisture）→更多高频岩屑、湿润→圆滑；仅在有起伏处出现。

总振幅量级（谷 ≈ −0.09 ~ 峰 ≈ +0.17）与旧 `MOUNTAIN_RIDGE_AMP=0.26` 同档，下游 erosion/SDF 行为不被打乱。常量先以文件内 `constexpr`/`const` 落地（C++↔GDScript 同名同值），稳定后可按需提升到 `ClimateProfile`。

下游收益：权威主索引固定为 warp 后的 `cube_round`，`dyn_lut`、`eco_lut`、天气、迷雾和交互状态均使用同一个 NEAREST 主格，不再通过图集空间 Dither 改派归属。静态地表边界由独立的 RG8 副索引与 R8 距离纹理在屏幕空间窄带内处理；边界数据缺失时直接退化为硬主索引。C++ 单 pass 与 fused pass 应逐字节一致，并由 headless parity 测试覆盖。

**分层地形法线（2026-06-25）**：渲染端 `hillshade_tod.gdshaderinc::compute_terrain_normal(uv, quality, biome)` 改为三层结构，解决"细节法线过强 → 山密密麻麻、走向不清晰"：① **粗法线**优先采样生成期烘焙的 `terrain_normal_tex`（1 fetch 拿宏观山脉走向；未绑定时回退运行期宽半径 `hillshade_coarse_radius` 4-tap）；② **细节法线**为运行期 1-texel 中心差分（4 fetch），作切向扰动叠到粗法线上，强度 = `hillshade_detail_strength × terrain_detail_factor(biome) × qf`，`terrain_detail_factor` 按 biome 分档（山地/方山满量、丘陵/荒地次之、平原/湿地系趋零）；③ **性能分档**：`MOBILE_QUALITY_LOW/MID` 与 desktop `visual_quality==0` 只算粗法线、跳过细节 4-tap。控制 uniform：`terrain_normal_tex_bound`（hex_renderer 据 `world.terrain_normal_tex` 是否存在设置）、`hillshade_coarse_strength`、`hillshade_detail_enabled`、`hillshade_detail_strength`。调用方 `land_pipeline`/`apply_tod_pbr` 已同步传 `biome`。

**P1 高程 hypsometric 重映射（2026-06-25，治平原/阶梯）**：在 normalize 之后对 `land_h=(E-sea)/(1-sea)` 施一条**单调三段曲线**——低地压平（出真平原）、中段柔和台地（可辨非硬 staircase）、高段陡升（拉开起伏、山更挺拔），治 P0 遗留 #3（平原不平 / 整体起伏弱）与半个 #2（连续高程驱动、取消按类别硬分档）。曲线为 PCHIP（Fritsch–Carlson 单调限幅）C1 + 单调（不倒置高程序），控制点 `PK_HYPSO_XS/YS` 以 `constexpr`/`const` 落地（C++↔GDScript 同名同值），共享 helper `PkHypsoCurve`/`pk_hypso_remap_elev`（C++）与 `_hypso_make_tangents`/`_hypso_eval`/`_hypso_remap_elev`（GDScript）。**两层施加（方案 C）**：
- **Layer B（仿真高程 E，定结构，C++ 唯一路径）**：`run_native_world_generate_base_pass` 在 normalize + 侵蚀(SPL/droplet/thermal) 之后、湖判/分类之前，对陆地段（`E>sea_level`）以 `mix=1.0` 施全曲线；锚定 sea_level → below-sea(海洋/湖种) 不变、海陆边界与 ocean/coast 分类不破坏；置于侵蚀之后 → 保留河谷网络与台地保形。**因生成已 100% C++（dots-total-cpp，GDScript 生成 fallback 已删），Layer B 无 GDScript 镜像**。下游湖判/气候/分类/landform 全部看到重塑后的 E（biome 分布随之变化，符合"三级阶梯成真实结构"预期）。
- **Layer A（bake 期 per-pixel 视觉高程，精修）**：`run_bake_terrain_index_pass` step7 在 `elev_blend`（已被 Layer B 重塑的 cell E 的 barycentric 插值）上以小 `mix=PK_HYPSO_LAYER_A_MIX(0.25)` 残差再施同曲线，重锐化被插值抹软的台地边缘；GDScript `DCTerrainBaker.bake_height_biome_moisture` 逐位镜像。`sea_level` 经 knobs 由 `DCTerrainIndexBaker` / `_bake_geometry_fields_native` 传入（`world.sea_level`，C++ 默认 0.64）。relief 随后叠在重塑基底上。
- **可调旋钮**：控制点 `PK_HYPSO_XS/YS`（分段点/各段斜率，改后需重新生成；C++ 改动需 rebuild DLL）、`PK_HYPSO_LAYER_A_MIX`（bake 残差强度，0=关）。曲线纯逐格/逐像素 ALU、无空间采样 → 天然 seam-safe、热循环开销可忽略。

**岸线法线 + 海洋深度（2026-06-25，治"海岸/河岸/护岸无法线 + 海洋全是近海"）**：起因——预烘焙 `terrain_normal_tex` 纯从 `height_buffer` 宽差分梯度算，全图一视同仁；河流是独立 SDF overlay（`flow_buffer`，从不进高度场）→ 河岸无几何落差、法线为 0；海岸落差被"平原去噪"(细节门控 + 宽差分摊平 + P1 近岸压平)抹掉；海洋 raw 起伏项全乘 `dist_field`、离岸趋 0，唯一向下力量是极地 `edge_falloff` → 只有极地有深海。三项修复：
- **#1 海岸滩坡法线（shader + bake 双管）**：① shader `compute_terrain_normal` 近岸窄带 boost（`shore_detail_strength`/`shore_band_height` uniform）补运行期细节法线；② **因 P1 后内陆平原也贴 sea_level、`elev-sea` 无法区分海岸/内陆**，海岸的真实法线改由 **bake 海滩 carve** 提供（`run_bake_terrain_index_pass` step6.6 + GDScript `DCTerrainBaker.bake_height_biome_moisture` 镜像）：用 **barycentric 水邻居权重**（`pk_is_water_terrain` 的 nb 权重和）作亚格距水近度，对近岸陆地按 `smoothstep(water_w)` 下压成海滩坡（`PK_COAST_BEACH/COAST_BEACH=0.05`，止于水线不越过）→ 写进 `height_buffer` → `terrain_normal_tex` 拿到 crisp 海岸法线，与河岸 #2a 同法。`B_COAST` 是水体不入陆地法线，故用水邻居权重而非 biome。
- **#2 河流切进高度场（方案 C 两层）**：① **#2b 仿真高程 E（cell 级，C++ 唯一路径）**：`run_native_world_generate_post_base_pass` 在河网最终化 + lake-snap 之后、河岸生态/floodplain 分类之前，沿河道按 `RFLOW` 下切 E（`PK_RIVER_INCISE=0.018`，河道保持 `>= sea_level+0.004` 不反转成海）+ 两侧非河陆地邻居抬升成堤（`PK_RIVER_BANK=0.008`）；下切后 `land_h` 降低 → 下游 floodplain/canyon/delta 分类自洽在河谷成形。② **#2a bake height_buffer（per-pixel，crisp 河岸）**：`run_bake_geometry_fields_pass` 在 river SDF(`flow_buffer`)算完后、bundle 前，按 `flow`（河心=1→远=0）以 `notch=smoothstep(flow)` 对 `height_final` 逐像素刻 V 形河谷（`PK_BAKE_RIVER_INCISE=0.045`），SDF 衰减天然形成河岸坡 → `terrain_normal_tex`/`height_tex`/relief 都读得到 crisp 河岸；仅陆地段（`height>sea_level`）。GDScript legacy(fused 失败)路径镜像 `_carve_river_into_height`（`BAKE_RIVER_INCISE` 同值；height=hm_size、flow=derived_size 不同分辨率时按归一化坐标取 flow）。fused 成功即 C++ 内 carve 并跳过 legacy → 无双重施加。
- **#2c 水域波蚀（coast-erosion，2026-06-26，cell 级，C++ 唯一路径）**：让水体（海/湖）也"介入侵蚀"——`run_native_world_generate_post_base_pass` 在 #2b 河流下切之后，对每个邻接水体的陆地 cell 按"波浪能量"下蚀 E，向海蚀台地收敛（`E -= coast_wave_erosion·wave·(E-sea_level)` → 高于水线越多蚀得越快、渐近水线成平台）。波能 = 邻接水体的 `深度代理(1-E_nb/sea，深海=大风区=强浪)·类型权重(湖×0.35)` 平均 × 岸线包围度（`0.45+0.55·water_neighbors/6`）。**与河流下切并列**：河流沿河道切，水域沿岸线切。只下蚀、clamp 在 `sea_level+0.004` 之上（不把陆地翻成海、不引发海岸级联）；仅读邻居水体 E（本 pass 不改水格）→ 顺序无关；下蚀后 `land_h` 降低 → 下游 floodplain/beach 分类自洽。计数 `stage_counts["coast_wave_erosion"]`。一键回退：profile `coast_wave_erosion=0`（默认 0.30）。注：base pass §2.4/2.5 的 SPL/液滴/热力侵蚀在分类前跑、地形无关；#2c 是分类后、水体驱动的专门海岸侵蚀，二者互补。
- **#3 海洋深度自然化（仿真高程 E，C++ 唯一路径）**：`run_native_world_generate_base_pass` 在 normalize 之后、侵蚀/分类之前，对 below-sea 段（`E<sea_level`）按"距岸 hex 距离"重塑海底——多源 BFS（陆地为源，`index_for_qr` 东西环绕邻接）求每个海洋格距岸距离 → 大陆架（`PK_OCEAN_SHELF_CELLS=2` 内浅）经 smoothstep ramp 到深渊（`PK_OCEAN_DEEP_CELLS=11`、最深 `sea*PK_OCEAN_ABYSS_FRAC(0.96)`），叠低频盆地噪声（`PK_OCEAN_BASIN_AMP=0.30`，仅深水生效，造海沟/海岭）。`DEEP_CELLS` 越小 → 离岸更快到深渊 → **深海面积越大**（2026-06-25b 迭代：20→11、ABYSS 0.92→0.96 扩大并加深深海）。锚定 sea_level：陆地完全不动。下游 `DEEP_OCEAN/OCEAN/COAST` 分类（`pk_decide_terrain_ex`：`sea-0.06`/`sea*0.55`/`sea*0.92` 门槛）、距海气候、水面深浅色全部看到自然海底（远海变深蓝、近岸大陆架）。原极地 `edge_falloff` 保留（仍产极地低地→冰盖/海），但其"唯一深海来源"的角色被本重塑取代。**base pass 已 100% C++（生成 fallback 已删）→ #2b/#3 无 GDScript 镜像**。
- **可调旋钮**：`shore_detail_strength`/`shore_band_height`（运行期 uniform，可在 .tres / 调试面板实时调，无需 rebuild）；`PK_COAST_BEACH`+`COAST_BEACH`（海岸海滩坡下压，两份同步）、`PK_RIVER_INCISE`/`PK_RIVER_BANK`（河谷/堤强度）、`PK_BAKE_RIVER_INCISE`+`BAKE_RIVER_INCISE`（bake 河道下切，两份同步）、`PK_OCEAN_SHELF_CELLS/DEEP_CELLS/ABYSS_FRAC/BASIN_AMP`（海底形态/深海面积）—— 后几项 C++ constexpr，改后需 rebuild DLL + 重新生成地图。#2b/#3 改仿真 E → **必须重新生成**；#1 海滩 carve/#2a 改 bake → 重烘即可；#1 shader boost → 重载 shader 即可。

**水体系统性影响（water-bodies systemic，2026-06-26）**：让海/湖/河统一驱动地形、气候、生态，海岸/湖岸获得与河岸同级的连续岸坡法线。架构铁律落地——所有 O(n) 中间数据留 C++，改动经既有导出（`moisture_arr`/`terrain_arr`/`height_buffer`）自然下传，**无新增跨语言 ext 成员/导出**。四层：
- **① 统一距水场（post_base，纯内部中间场）**：`run_native_world_generate_post_base_pass` 在 lake/river 最终判定后、水缘生态 pass 之前，做海/湖/河流**多源 BFS**：`water_dist[i]`=到最近水体格距（`water_dist_max` 截断），`water_src_kind[i]`=最近水源类型（0=海洋性 / 1=湖 / 2=河流），并把生态流量随最近河源传播。海洋 source = `pk_is_water_terrain` 的 ocean-connected 水格；湖 = `LAKE(18)`；所有 `RIV` 成形河道（含支流）都作为窄河岸带 source，不读取视觉宽度 `river_flow_arr`。`water_big_river_flow_min` 只作为河岸湿度流量加成达到上限的标尺。`std::vector` 局部量仅供下面 ②③ 消费，不出境。
- **② 气候回灌与最终重判**：用距水场只补 base 阶段不存在的湖/河近邻湿润带——湖滨增湿地板 `M=max(M, lake_moist_floor·exp(-wd/lake_moist_scale))`（kind=1）；河谷一环应用约 `0.36..0.42` 的 `river_riparian_floor`，一、二环叠加 `river_riparian_gain·exp(-wd/scale)`，三环外不加湿。海洋调温/沿海湿度地板/`land_continentality` 由 base pass 维持，**这里不重做避免双重计算**。回灌后以同一个 `gen_temp + pk_decide_terrain_ex` 对普通陆地做一次受保护的全图最终重判；跳过水体、河道、MOUNTAIN/SNOW/TUNDRA 和永久特征地形，禁止陆地重判为水。特征 pass 随后覆盖 oasis/floodplain/badlands 等类别，因此不会恢复旧 vegetation-feedback 正反馈，也不会抹掉专用地形。湖泊**温度**调节因 `TEMP[]` 只读 + bind 后 republish 会重算而**本期延后**（需专门 temp-adjust 通道）。
- **③ 生态强化**：`swamp` pass 的"近水"从 1 格邻接扩展为湖/大河 graded 距水带（`swamp_water_band`，0=仅邻接），让湿地沿湖滨/河谷成连续带（高 M(0.75)+低地+暖温三道既有闸门仍在，不会泛滥）；其余水缘 pass（mangrove/glacier/oasis/delta/floodplain）经回灌后的 `M[]` 间接强化。河岸林复用既有 river_ecology 的 `FLOODPLAIN(29)/SWAMP(10)` 分类（不新增 enum）。
- **④ bake 岸坡 carve（per-pixel，对标河流 #2a 真实落位）**：见上文 coast SDF sub-pass——独立 `run_bake_coast_sdf_pass`（chamfer DT）+ `run_bake_geometry_fields_pass` 在 **river carve 之后**对 erosion 后的 `height_final` 刻连续岸坡（**不塞进 terrain_index_pass**：其为 ~517ms 单线程最大热点、且 carve 在 erosion 前会被抹平）。与旧 barycentric beach carve(`PK_COAST_BEACH`)加性叠加。
- **可调旋钮**（均经 `map_generator.gd::_native_generation_cfg_dict` / `map_baker.gd` 常量暴露，默认值 C++/GDScript 两侧对齐，置 0/负即关闭对应项一键回退）：cfg 侧 `water_dist_max(8)`/`water_big_river_flow_min(0.55，流量加成标尺)`/`lake_moist_floor(0.55)`/`lake_moist_scale(2.5)`/`river_riparian_floor(0.36)`/`river_riparian_gain(0.12)`/`river_riparian_scale(2.0)`/`swamp_water_band(2)`；profile 的 `moisture_subtropical_dry_strength` 默认 `0.30`（zonal-envelope 2026-08-01 起副热带扣湿**移到**沿海湿度地板之后应用，副热带海岸也能成真荒漠），`rain_shadow_factor` 默认 `0.65`，只让明确背风坡覆盖沿海保护；bake 侧 `shore_carve_amp(0.06)`+`SHORE_CARVE_AMP`/`shore_carve_band(6)`+`SHORE_CARVE_BAND`/`coast_sdf_max_dist_px(8.0)`+`COAST_SDF_MAX_DIST_PX`/`coast_sdf_wrap_x(true)`。①②③ 改仿真 → 需重新生成地图；④ 改 bake → 重烘即可。改 C++ 后须 rebuild DLL + 重启 Godot。

**水陆形态调参（water-bodies tuning，2026-06-26 第二轮，CSV/视觉反馈驱动）**：针对"陆地偏多、浅海占 99%、近海/深海≈0、高纬温带草原、山脉不显眼"的生成期修正，全部在 `run_native_world_generate_base_pass` / `pk_decide_terrain_ex`（改 C++ 须 `scons -c` 全量重编 + 重启 Godot + 重新生成；GDExtension 不热重载）：
- **距岸距离驱动洋底深度（根治深海缺失）**：双峰模型原用大陆性噪声 `C` 给洋底深度（`wt=(0.5-C)*2`），陆地铺满、缺开阔洋面时 `wt` 到不了 1 → 洋底卡在大陆架深度（实测 min elev≈0.286、shader `depth_t=1-elev/sea_level` 仅 0.32 → 浅海 99%）。改为在 `dist_ocean` BFS 之后**再做源=陆地(`E≥sea_level`)的多源 BFS** 得 `shore_dist`（水格到最近陆地步数，复用 `index_for_qr(Q/R+DQ/DR)`），按 smoothstep 单调加深：贴岸=大陆架浅(`PK_SHELF_DEPTH=0.03`)，离岸 ≥`PK_SHORE_DEEP_DIST(=7)` 格=深海平原满深度(`sea_level·PK_OCEAN_DEPTH_FRAC`，elev≈0.04，depth_t≈0.9)。仅重写水格 `E[]`（恒<sea_level）、海岸线/陆地不动；双峰水侧 `wt` 退化为占位（供 `dist_ocean`/mask 播种，BFS 关闭时合理回退）。任何够宽内海中心自然成深海，不依赖随机大陆布局；窄海峡仍浅（物理正确）。post_base @~15356 用同一 E 重判 OCEAN/COAST，分类与渲染深度一致。
- **`PK_CONT_THRESH` 0.16→0.22→0.19**：海陆阈值。0.22 减陆地但副作用是内陆抬升 `lt=(C-0.5)*2` 整体变缓 → 造山带 `orogeny` 被 lt 乘后高差变小、达 MOUNTAIN 阈值的格变少 → **山脉变矮变不显眼**。深海已由上面距岸 BFS 兜底、不再依赖高阈值开放洋面，故回调 0.19（仍比原 0.16 略减陆地）恢复山脉。
- **`PK_OROGENY_AMP` 0.42→0.48**：与陆地占比(`CONT_THRESH`)**解耦**地增强山脉显眼度。`platform_max=PLATFORM_H+UNDULATE+AMP=0.58`，`e_out_max=sea_level(0.42)+lt(≤1)·0.58=1.0` 恰好不触发 clamp 削峰。
- **STEPPE 温度门限（C++/GDScript 双同步）**：`pk_decide_terrain_ex` 凉温带(temp 0.20-0.38)原 `moist>0.22→STEPPE`，32.8% 落 temp<0.30 → 高纬温带草原。改为仅 `temp>0.30` 保留 STEPPE，更冷按湿度回落 `TAIGA(13)/TUNDRA(8)/COLD_DESERT(26)`；`map_generator.gd::_decide_terrain` 同步。

**生物群系决策树重标定（climate-zone-fix P1，2026-06-28，C++ 权威 + GDScript 1:1 镜像）**：解决"MEDIT 泛滥 21%、热带雨林 1%、亚热带林死支、savanna 缺失"——气候场有足够暖湿格但硬决策树阈值挡住（land moist 运行期 p50≈0.38/p90≈0.56，远低于旧阈）。改动点（`pk_decide_terrain_ex` / `pk_derive_vegetation` / `pk_whittaker_vegetation` in `world_ext_internal.h` + `map_generator.gd` 三函数逐位镜像 + `world_ext_generate.cpp` shrubland/chaparral pass）：
- **热带/亚热带温度带拆分**：原单一 `temp>0.55` 热带带拆为真热带 `temp>0.66` 与亚热带/暖温带 `0.55–0.66`，让后者的 FOREST terrain 正确路由到 `SUBTROPICAL_FOREST(12)`（修死分支）。
- **热带湿端再平衡（2026-07-22）**：实测新地图雨林已扩张到陆地约 11.6%，因此把 JUNGLE 门收紧到 `moist>0.54`；`pk_derive_vegetation` 的雨林/季风林/云雾林门调整为 `0.58/0.48/0.60`；`pk_whittaker_vegetation` 的雨林/热带干林/savanna 门调整为 `0.58/0.38/0.20`。目标是让雨林落在湿度分布的湿尾，同时保留可达的季雨林过渡带。
- **Biome/vegetation 一致性修正（2026-08-01）**：SAVANNA 的生成期季风林门与 JUNGLE biome 边界统一为 `moist>0.54`，消除 `0.48..0.54` 的必然错配；运行期 `VegetationType.biome_envelope_weight` / `pk_vegetation_biome_weight` 将气候 biome 作为软生态先验，纳入生成与 vegetation dynamics 的 suitability。严重跨 biome 错配（envelope `<=0.50`）在目标适配低于 high threshold 时开始累计演替 streak，保留历史滞后但不再长期停留在明显不相容的植被。
- **收窄 shrubland/chaparral 特征 pass**（MEDIT 21% 主因）：shrubland(生成 pass + stage5 季节刷新)加温度上限 `temp<0.58` + 湿度收窄到 `[0.20,0.44]`；chaparral 上限 `0.62→0.58`、`[0.20,0.46]`，止住"任意暖区沿海中湿格→MEDIT"的 catch-all。
- **headless 验证（`tests/tmp_biome_eval.gd`，60×40/sea_level0.42/2 陆块 + 60d warmup + 120d sample，镜像 CSV 聚合法）**：MEDIT_SHRUB 21.0→7.3%、TROP_RAINFOREST 1.0→4.0%、SUBTROPICAL_FOREST 0.1→7.7%、SAVANNA 0.6→3.6%、MONSOON_FOREST 16.0→7.3%（更接近地球分布）。完整 Köppen 生物群系直方图复核需用新 DLL 录加速 CSV 跑 `tmp/wx_koppen.py`。
- **新增/调整 constexpr 旋钮**：`PK_SHORE_DEEP_DIST(7，调小→深海更普遍)`、`PK_SHELF_DEPTH(0.03)`、`PK_CONT_THRESH(0.19，调大→大陆更小/海洋更宽)`、`PK_OROGENY_AMP(0.48，调大→山脉更高，上限 0.48 防削峰)`。**验证硬指标**：重生成后洋底 min elev 应从 0.286 骤降到 ~0.04，深度分档出现近海/深海；OCEAN(0) terrain 占比上升、COAST(1) 下降；STEPPE 的 temp<0.30 占比≈0；山脉高差恢复。

**生物群系纬度格局修复（zonal-envelope，2026-08-01，C++ 权威 + GDScript 1:1 镜像）**：解决"草原/稀树草原占 48% 陆地、赤道核心 40% 是稀树草原而雨林仅 18%、全图荒漠 0.1%"的行星尺度地带性缺陷。根因是 `base_moisture` 无纬度结构（67% 陆地挤在 0.2–0.38 半干窗口、<0.2 为 0 格）叠加分类器半干带宽恰好罩住分布主体。改动：
- **湿度模型加纬带包络（`world_ext_generate.cpp` 湿度扫描，唯一公式站点）**：纬向扫描内注入与 wind belt 同一 `ny/eq_dist` 坐标系的降水乘数包络——ITCZ 赤道湿带（`moisture_itcz_wet_strength 0.9`/`center 0.05`/`width 0.10`）、中纬风暴路径湿带（`moisture_stormtrack_wet_strength 0.6`/`center 0.55`/`width 0.15`）、极地干（`moisture_polar_dry_strength 0.35`）；热带洋面蒸发增强 `moisture_tropical_evap_boost 1.0`（赤道洋面 ×2 供水，湿带的水汽源头）；ITCZ 降水再循环 `moisture_itcz_recycle_strength 0.62`（雨林蒸散回气柱比例，亚马逊型 ~0.5）+ 辐合注入 `moisture_itcz_convergence 0.05`——后二者让赤道湿带深入大陆内部，否则气柱沿程枯竭、赤道内陆必然干旱。顺序：纬带包络 → 平流雨影扫描 → 海岸/噪声细节。
- **副热带干带加深并移序**：`moisture_subtropical_dry_strength 0.22→0.30`、`center 0.33→0.36`（width 0.18 不变），且从海岸 guard 之前移到之后生效——副热带海岸也能成**真荒漠**（base_moisture<0.2）；center 极移避免高斯尾触达赤道带（实测 0.30/0.20/0.33 时部分种子赤道林率跌破草率）。
- **分类阈值按新分布再校准（`world_ext_internal.h` 三函数 + `map_generator.gd` 逐位镜像）**：真热带温度带 `t>0.66→0.80`（旧边界实测对应距赤道约 49°，把温带漏斗进热带干端）；JUNGLE/雨林湿门 `0.54→0.56`、whittaker 雨林门 `0.58→0.56` 对齐；亚热带 FOREST 湿门 `0.36→0.40`、暖温带 FOREST `0.55→0.48`（温带森林回归）；SAVANNA 湿端 MONSOON 门随 JUNGLE 边界同步 `0.54→0.56`；SEAGRASS 温度窗同步 `0.74→0.82` 上缘。
- **验证硬指标（`tests/generation_zonal_moisture_test.gd`，3 种子 150×100，35 checks）**：赤道带(eq<0.2) bm 中位数 0.43-0.44 > 副热带带 0.08-0.19、副热带带存在 bm<0.2 格（每种子 900-1600 格真荒漠）、中纬带 > 副热带带、赤道核心森林系(46-61%) > 草原系(35-45%)、全图森林 33.7-35.5%、草原 26.2-27.1%、荒漠 6.0-9.8%。生产路径（WorldRuntimeHost，高地形种子）730 天 soak：草原系 47.9→36.8%、荒漠 0.1→4.7%、赤道核心 F55.6>G37.6、植被演替迁移 12.3%/2yr（修复前 0.7%/10.7yr），SAVANNA→季雨林链 83 格打通、gates 无需调参；瞬时湿度漂移 +0.058 为**蒸腾再循环平衡瞬态**（首 91 天 +0.086 后同季年际回落，非失控，森林格漂移最大 = donor 共位），timescale 分离后不影响 biome。工具：`tools/audit_veg_zonation.py`（输入 tile CSV 输出纬带审计 + 7 项硬指标核对）。赤道带残留的 TEMPERATE_STEPPE 经归因 57.5% 位于 elev>0.7 的高原格（东非高原式 elevation-cooled 分类，物理合理）。
- **knob 键名单同步**：`climate_profile.gd`（@export + 注释）、`map_generator.gd::_native_generation_cfg_dict` 转发白名单、`main.gd::_GENERATION_KNOB_WHITELIST`、`new_game_config.gd::derive_climate` 与 `world_setup.gd` 的 wetness 滑条映射（仅 4 个 strength 类旋钮参与：itcz_wet 0.6-1.2 / stormtrack 0.3-0.7 / polar_dry 0.5-0.25 反向 / tropical_evap 0.6-1.4，保持"越湿越多林"单调；center/width/recycle/convergence 几何与机理旋钮不随滑条）。

**大陆-海洋双峰测高(地台)模型（2026-06-26，权威高程模型）**：取代旧"径向穹顶"（`radial_raw = dist_field*(...)`，elev∝离大陆中心距离 → 大陆是穹顶、平原鼓、海岸只是缓坡无坡折）。新模型复现地球**双峰 hypsographic 曲线**：平坦大陆地台 + 平坦深海平原 + 又窄又陡的大陆坡折。位于 `run_native_world_generate_base_pass` 的 `// 1. coords + elevation` 循环内（C++ 唯一路径，无 GDScript 镜像）：
- **大陆性 mask**：`cont = dist_field(线性 mask 种子) × PK_CONT_RADIAL_W + 大陆形状 fBm × PK_CONT_NOISE_W + offshore(岛)`，乘极地衰减 `(1 - edge_t × PK_POLAR_OCEAN)`，再 `C = smoothstep(THRESH±MARGIN, cont)` 锐化 → `MARGIN` 小则海陆过渡窄 = **大陆坡陡 = 海岸落差/法线强**。
- **双峰合成**（锚定 sea_level、直接产 [0,1]，**本路径跳过 min/max normalize** 以保住海平面位置）：海岸线定在 `C=0.5`——`C≥0.5` 陆地从海岸(sea)沿 `(C-0.5)×2` 抬到内陆平台 `platform = PK_PLATFORM_H + macro×PK_PLATFORM_UNDULATE + orogeny`（margin 内成海岸上坡→海岸法线，之后是平坦地台+造山）；`C<0.5` 水侧仅占位(确保 E<sea)，**真实海洋深度由下面 #3 距岸 BFS 重塑**出大陆架(近海浅水)→大陆坡→深海平原（基于距岸 hex 距离，不受海岸线噪声打散）。
- **造山带（成脉山系）**：`orogeny = ridged^PK_OROG_SHARP × belt × PK_OROGENY_AMP`，`ridged=1-|n|`（两倍频，沿零交叉成脉）、`belt=smoothstep(低频噪声)`（成带）→ 山脉成脉成带而非各向同性，仅在陆地随 `(C-0.5)` 出现。
- **分工**：双峰负责**陆地平台 + 海陆 mask + 海岸位置**；**#3 距岸 BFS（常开）负责海洋这一半的剖面**（大陆架/坡/深渊，`PK_OCEAN_SHELF_CELLS/DEEP_CELLS/SHELF_D01/ABYSS_FRAC/BASIN_AMP`）。P1 hypso Layer A/B 仍由 `PK_BIMODAL_ENABLED` 关闭（被平台吸收）。`PK_BIMODAL_ENABLED=false` 一键回退旧径向穹顶+P1+原 #3。海岸海滩 carve(#1)、河流 carve(#2a/#2b) 保留叠加。
- **可调旋钮**（C++ constexpr，改后 rebuild + 重新生成）：`PK_CONT_THRESH`（海陆比例/大陆大小，**小→大陆更大更整、内陆更干→生态更多样**）、`PK_CONT_MARGIN`（海岸坡陡度/法线强度）、`PK_PLATFORM_H`（地台高出海面）、`PK_OROGENY_AMP/OROG_SHARP/OROG_BELT_*`（山系）、`PK_POLAR_OCEAN`（极地偏海）；海洋侧 `PK_OCEAN_SHELF_CELLS`（近海大陆架宽）/`DEEP_CELLS`/`SHELF_D01`/`ABYSS_FRAC`。

## 生成期 per-pixel 几何场 buffer-encoder（dots-total-cpp 续，2026-06-25）


`MapBaker.bake_world` 内四个生成期烘焙的全部计算已下沉 C++，与 `encode_bake_*` / `run_bake_terrain_index_pass` 同范式：纯 buffer-encoder，不读 `_slots` / 不要求 `_bound`，所有输入经 knobs PackedArray 喂入。**dots-total-cpp 原则：C++ 是唯一计算路径，已删除 GDScript 计算 fallback**——ext / 方法缺失或返回非法时 `push_error` 并返回空 buffer（不静默降级，与生成期 native world-gen 一致）。设计目标：跨语言只传极少量"请求参数 / 低维输入"，所有 O(n_pixels) 热循环与中间 buffer（dense polyline / mask / 侵蚀工作缓冲）全部在 C++ 内自算、不跨语言往返。

主要入口：

- `DCWorldExt::run_bake_geometry_fields_pass` / `map_baker.gd::_bake_geometry_fields_native`（**step2 融合编排**）
- `DCWorldExt::run_bake_latitude_field_pass` / `map_baker.gd::_bake_latitude_buffer`
- `DCWorldExt::run_bake_river_sdf_pass` / `terrain_baker.gd::DCTerrainBaker.bake_river_sdf`
- `DCWorldExt::run_bake_coast_sdf_pass`（water-bodies systemic：海/湖统一离岸距离场 + 岸坡 carve）
- `DCWorldExt::run_bake_erosion_pass` / `terrain_baker.gd::DCTerrainBaker.bake_hydraulic_erosion`

**bake 期几何场编排下沉 C++（dots-total-cpp step2，2026-06-25）**：`run_bake_geometry_fields_pass` 是单次驱动——GDScript 在 `bake_world` 里只发**一次请求**（一个 knobs 含 terrain-index 所需 cell SoA + 几何参数 + erosion 常量），C++ 在进程内依次串起 terrain-index → erosion → river SDF → latitude sub-pass，**中间 buffer（尤其 height_buffer）全部留在 C++、不跨语言往返**（原 height 在 terrain→erosion→encode 间往返 4 次，现仅最终一次随 bundle 返回），一次返回完整几何 bundle（`height_buffer/biome_buffer/moisture_buffer/vegetation_buffer/cover_buffer` + `flow_buffer` + `latitude_buffer` + CSR `cell_first_px/cell_px_count/flat_px_indices` + `pixel_to_cell_index` + 各 stage `*_ms`/`*_ok` 诊断）。GDScript `_bake_geometry_fields_native` 只解包到 `world.*`，`DCTerrainIndexBaker.apply_result()` 负责共享的 terrain buffers、edge textures 和对象侧 `pixel_to_cell_lookup`/`cell_pixel_lists`。`bake_world` 为**融合优先 + 旧 per-pass 回退**：融合 pass 缺失（DLL 未 rebuild）或 terrain sub-pass fallback 时，退回 `DCTerrainIndexBaker.bake()` / GDScript ground-truth + 各单 pass，行为同迁移前。废弃的 volcano field 已从几何 bundle 与 GPU 上传路径删除；火山视觉继续由 `landform == LF_VOLCANO` + height/normal 表现。

**bake 分辨率平台档（2026-08-06）**：`MapBaker._hm_max_dim()` 决定 `hm_size`/`derived_size` 长边。桌面 1024；**mobile 与 web 同档 512**（~155k px，约为桌面 620k 的 1/4）。Web 此前只认 `mobile` feature、浏览器会静默落到 1024，在 nothreads WASM 上把 terrain-index/encode/horizon 的 O(像素) 成本放大约 4×；现用 `OS.has_feature("web")` 与 mobile 共用 `HM_MAX_DIM_MOBILE`。日志 `MapBaker v6: hm=` 在 web 上应约为 `(512, 300)` 量级（随地图宽高比变化）。

**terrain horizon 平台分流（2026-08-06）**：GPU horizon 在 web/mobile 默认关（`DCFeatureFlags.terrain_horizon_gpu_bake_active`）。`bake_world` encode 段此前只把 `mobile` 映射到「跳过 → `terrain_horizon_tex=null`」，web 会落到桌面 CPU `encode_horizon_tex`（`steps=1024`×8 向），nothreads WASM 上可拖垮生成。现 **mobile 与 web 同走 skip**；仅桌面在 GPU 关时保留 CPU C++ fallback。shader 侧 `terrain_horizon_tex_bound=false` → 无投射阴影回退。

**主地形退役 eco_lut、Web 启用材质贴图（2026-08-06）**：`world_map` 不再声明/采样 `eco_lut`（叶量/胁迫/物候与 `dyn_lut.A` vitality 高度重叠；mobile 本就编译期跳过）。腾出的 Compatibility 预算槽接入 `terrain_material_tex`。植被实例层（`shrub_layer`）仍可独立绑 `eco_lut`。

**height+flow 合并（2026-08-06）**：Legacy `height_tex` 与 Tiled `visual_height_tiles` 均为 RGBA8（RG=16-bit height，B=flow，A=0）；独立 `flow_tex` / `visual_flow_tiles` 退役。CPU 仍保留分离 buffer。旧 DLL 若仍返回 `height=N*2`+`flow=N`，`VisualTileSet.normalize_height_flow_bundle` 会在上传前拼包。`BYTES_PER_PHYSICAL_TEXEL`=23。`PK_WEB_TEXTURE_BUDGET` 下现为 height/horizon/map_index/noise/enum/dyn/**material** = **7**（留 1 裕量）。

**Web shader 质量档（2026-08-06）**：与 mobile 共用 `MOBILE_QUALITY_LOW/MID/HIGH` 编译期 define + 运行期 `visual_quality`。`DCFeatureFlags.uses_shader_quality_tier()` = mobile|web；设置 `render_quality=auto` 在 web 上默认 LOW（不再误用桌面 HIGH）。高档仍叠加 `PK_WEB_TEXTURE_BUDGET`（纹理单元硬裁剪与分档正交）。日志 `[hex_renderer/variant] quality=MOBILE_QUALITY_* web_texture_budget=true`。

各 sub-pass 链路与 I/O（被 `run_bake_geometry_fields_pass` 内部调用，也可单独调用）：



- **latitude field**：复刻 `_bake_latitude_buffer`。逐像素 `ny = y / max(H-1,1)` → F32。输入 `width/height`，输出 `latitude_buffer`（F32）。
- **river SDF**：`terrain_baker.gd::DCTerrainBaker.bake_river_sdf` 只发送显式几何 knobs 并校验 `out_buf`。`run_bake_river_sdf_pass` 在 C++ 内完成拓扑 trace、跨经度展开、Catmull-Rom、warp、可变宽度 stamp、3-4 chamfer SDT、端点 taper 和归一化；河流拓扑由 post-base 暂存于 `DCWorldExt::_gen_river_*`，不跨语言传输。
- **erosion（droplet 水力侵蚀）**：`terrain_baker.gd::DCTerrainBaker.bake_hydraulic_erosion` 只发送 `height_buffer`、seed 和显式 erosion knobs，并校验 `height_out` 尺寸。`run_bake_erosion_pass` 在 C++ 内完成 droplet 侵蚀、沉积、蒸发和 [0,1] clamp；GDScript 不保留计算 fallback。
- **coast SDF（海/湖统一离岸距离场，water-bodies systemic）**：从 per-pixel terrain（`biome_buffer`）的 land-water 边界做 **chamfer 3-4 双通距离变换**（X 向可环绕 `coast_sdf_wrap_x`），产出每像素到最近水体的像素距离（水体=0，向内陆递增，clamp 于 `coast_sdf_max_dist_px`）。水集合与 `terrain_index` `is_water` / `pk_is_water_terrain` 一致 = `{0,1,18,19,20,21}`。`run_bake_geometry_fields_pass` 在 **river carve 之后、bundle 之前**用此距离对 `height_final` 逐像素刻"陆侧上坡、止于水线"的连续岸坡（`notch=smoothstep(1-d/band)`，`shore_carve_amp`/`shore_carve_band`）→ `terrain_normal_tex` 拿到 crisp 海岸/湖岸法线，与河岸 #2a 同法、与旧 barycentric beach carve 加性叠加（均向水线单调下压、clamp `sea_level`，无冲突）。`shore_carve_amp<=0` → 关闭回退旧法。输入 `width/height/biome_buffer/coast_sdf_max_dist_px/coast_sdf_wrap_x`，输出 `out_buf`（F32 离岸像素距离）。chamfer 两遍光栅扫描有行间依赖，单线程 O(n_pixels)（如需并行可换 jump-flood）。

**海岸线视觉平滑（coast-smooth，2026-06-26，纯 shader、不动烘焙/分类）**：起因——河流边缘由连续 SDF（`flow_tex`）驱动 → 平滑有机；而水陆边界是 **per-cell 六边形枚举硬边**（`is_water` 取自 `enum_lut`，烘焙期 Bayer dither 刻意跳过水陆边界护硬边）→ 海岸呈六边形阶梯，远丑于河流。**踩坑历程**：① 首版用 `height_tex` 的 `elev` 跨 `sea_level` 当海岸 SDF → 失败（近岸陆地 beach-carve 钳在 `sea_level` 不过线；P1 后内陆平原也贴 sea_level 无法区分海岸/内陆）；② 改用 `water_depth_tex` 覆盖场 → 浅水体/小湖 `water_depth` 整体偏低，过渡色糊满全湖发灰。**最终方案**：用 `shore_halo_r.shore_w`（`sample_shore_neighborhood` 的邻域水/陆接触度，已 `smoothstep`）作为**对称定位+粗细**场——陆侧=贴水接触度、水侧=贴陆接触度，内陆与开阔水/浅湖内部恒 0 → 不误染。两侧统一把颜色混向 `mix(color_coast_water, color_lowland, coast_shore_land_bias)`（**水色与陆色的混合**，默认 0.5 → muted 青绿，非灰褐），形成一条跨岸的柔和过渡带掩盖六边形硬边。`band = smoothstep(0,1, clamp(shore_w * coast_smooth_width, 0,1))`。可调 uniform（纯运行期，重载即生效）：`coast_smooth_strength`（默认 0.65，0=关回退旧硬边）、`coast_smooth_width`（默认 1.8，**越大过渡带越粗**）、`coast_shore_land_bias`（默认 0.5，0=全水色/1=全陆色 lowland）。注：`shore_common::coast_water_coverage`（water_depth 多 tap，前版用）已弃用不再调用。Mobile LOW/MID 无 halo 分支，coast-smooth 亦随之旁路。

返回 report 统一为 `{ fallback, reason, path, elapsed_ms, data|latitude_buffer|out_buf|height_out, width, height, format }`。GPU 上传（height/flow ImageTexture）仍在 GDScript/Godot 对象层，C++ 只产 CPU buffer。

parity 说明：用户不要求 bit-equal（迁移后人工验证）。latitude 为确定性写、应 bit-equal；river SDF 与 erosion 的几何用 float 复刻 Godot `Vector2` real_t、scalar 用 double，warp/RNG 用 Godot 同引擎实例（`FastNoiseLite` / `RandomNumberGenerator` 同 seed），整体接近一致，按聚合视觉验收。

**River SDF GDScript extraction status**: the old trace/stamp/chamfer helpers have been deleted from `map_baker.gd`. `terrain_baker.gd::DCTerrainBaker.bake_river_sdf` now owns the explicit native request and output validation; all river geometry computation remains in C++.



### Terrain hard-index, edge material data, and near-detail LOD (2026-07-28)

`DCWorldExt::run_bake_terrain_index_pass` no longer uses atlas-space Bayer
dithering to reassign pixel ownership. After warp and `cube_round`, the hard
primary cell is authoritative for `biome_buffer`, `vegetation_buffer`,
`cover_buffer`, `pixel_to_cell_index`, CSR, enum atlas GB, dynamic LUT lookup,
fog, ecology, weather, interaction, and incremental raster updates. Height and
moisture retain their existing barycentric interpolation.

The terrain pass and the fused `run_bake_geometry_fields_pass` additionally
return two transient visual buffers:

- `edge_secondary_index_buffer`: RG8 little-endian cell index; `0xFFFF` means
  no blendable neighbor.
- `edge_distance_buffer`: R8 normalized primary/secondary center-distance gap;
  zero is the equidistance boundary and 255 is the saturated cell interior.

The secondary candidate is selected deterministically from the two sextant
neighbors, with lower cell index as the tie break. It is emitted for every
valid cell boundary, including equal-biome and land/water neighbors, so the
same field can drive terrain, fog and weather presentation. The terrain shader
performs its own primary/secondary water-domain check and rejects cross-domain
material mixing, so coasts never leak land material into water; fog knowledge
and continuous weather-cloud quantities may still transition across a coast.
`map_baker.gd` only validates and uploads these buffers to
`WorldData.terrain_edge_neighbor_tex` and
`terrain_edge_distance_tex`; invalid or absent buffers produce a warning and
a hard-primary fallback, never the retired Bayer path.

On desktop, `world_map.gdshader` combines a 1--1.75 screen-pixel `fwidth()`
inner AA band with a noise-modulated material ecotone. The R8 field saturates at a
`0.90-hex` center-distance gap; the default width is `0.84`, producing a
high-quality transition about `0.76 hex` wide across both sides. The static
biome color/roughness/micro strength blend first. A distance-field-gated
DitherUV visual cell then supplies the complete static
biome/vegetation/cover axes to later material stages, preventing climate gates,
vegetation tint and cover overlays from redrawing the hard primary silhouette.
Temperature, moisture, vitality, snow amount, landform, dynamic LUT authority,
topology and interaction remain primary-only. Desktop terrain also mixes a
zoom-aware amount of map-anchored 8×8 DitherUV into the continuous
distance-field weight. Its raw Bayer rank is compressed from `[0,1]` to
`[0.18,0.82]`, preserving 50% boundary coverage while preventing near-zero
ranks from surviving most of the broad ecotone as elongated one-texel teeth.
The far view retains stronger ordered coverage, while
the close view converges completely to the continuous distance field. The same
fade gates the visual biome/vegetation/cover selection so later material stages
cannot retain enlarged Dither blocks. MID/HIGH water uses the same distance
field as a continuous primary/secondary static-material weight and accepts only
another water cell. The weight feeds lake/reef/kelp/coast material features,
roughness, waves, foam, caustics and static cover without evaluating the water
pipeline twice. Ordinary sea depth is derived from the already barycentrically
interpolated height field, while lakes retain the basin-size-aware baked depth;
this removes per-cell R8 depth plateaus with no additional texture fetch. Ice
fraction, temperature, current, wind and all other dynamic state stay
primary-owned, and water/land branch ownership never changes. Mobile LOW
compiles out the secondary water lookup and retains the hard-primary path;
mobile MID/HIGH use the continuous edge pair but keep the expensive desktop
3x3 water-biome neighborhood disabled. Desktop keeps that neighborhood and
anchors it to the exact distance-field pair near the boundary.
On mobile, `world_map.gdshader` uses the shared wrap-safe 8×8 DitherUV threshold
to select one visual land cell before the relevant LUT lookup in distant and
medium views, then fades that selection to zero before the closest view.
`fog_of_war.gdshader` and `weather_overlay.gdshader` retain their mobile
single-cell Dither path. Desktop fog/weather retain continuous primary/secondary
mixing. All variants fall back to hard-primary sampling when edge textures are
absent.
`terrain_detail_tex` stores one continuous,
biome-independent world-space macro signal; the shader applies material-class
amplitude after sampling, preventing a hard biome outline from being baked
back into the linear texture. Near-surface detail is one mipmapped sample from
the deterministic offline `terrain_micro_data.png`. The texture is generated
from periodic multi-scale value noise rather than directional sine bands,
using world coordinates and an integer horizontal repeat count so the
cylindrical seam closes. Camera zoom is pushed through
`MapCamera.zoom_changed -> HexRenderer.set_camera_zoom`; the same signal
updates existing `ShrubLayer` materials and visibility only. It does not
rebuild or redistribute MultiMesh instances.

Camera detail LOD treats the original profile population as the far-view
baseline. `lod_near_density_multiplier` only pre-generates an additional nearby
pool (trees 1.75×, shrubs 1.60×, rocks 1.40×, fine details 1.35× by default).
Each chunk is deterministically repacked into cell-stratified layers: one stable
sample from every occupied cell first, then second samples, followed by
near-only surplus. Consequently `visible_instance_count` cannot erase whole
hexes merely because of buffer order. Candidate discs also overlap adjacent
hexes (`seamless_spawn_radius_floor`) so the continuous world-noise field is not
clipped into visible cell-shaped patches. Zoom changes only the visible prefix;
alpha stays at the original value and no MultiMesh is rebuilt or redistributed.
The renderer-wide instance budget remains an independent upper bound.

Validation entry points:

- `tests/terrain_index_edge_bake_test.gd`
- `tests/bake_encoder_cpp_parity_test.gd`
- `tests/terrain_shader_variant_test.gd`
- `tests/terrain_detail_continuity_test.gd`
- `tests/camera_detail_lod_test.gd`
- `tests/overlay_edge_transition_shader_test.gd`

## Runtime hydrology


主要入口：

- `DCWorldExt::run_runtime_hydrology_pass`
- `map_generator.gd::run_hydrology_discharge_pass_native`
- `WeatherRefreshJob.run_slice()` 的 `hydrology_discharge` stage

链路：天气场 commit 后，`weather_refresh` 在 stage-b 前可选运行 `hydrology_discharge`。C++ pass 读取 `cell_hydro_parent` 静态排水拓扑、`neighbor_indices` 邻接表，以及 `cell_weather_precip`、`cell_snowpack`、`cell_soil_moisture`、`cell_water_balance_30d`、`cell_vegetation_vitality` 等运行期状态；先计算本地产流、入渗、地下水基流，再用 parent graph 做上游到下游路由。输出 `cell_river_discharge`、`cell_river_discharge_30d`、`cell_river_storage`、`cell_groundwater_storage`、`cell_surface_runoff`，并回写 `cell_moisture`、`cell_soil_moisture` 和 `cell_water_balance_30d`。河道湿度目标为 `hydro_river_moisture_floor(0.66)`，一环非河道陆地目标为 `hydro_riparian_moisture_floor(0.38)`；`hydro_river_evap_gain` 再按 30 日流量给目标小幅加成。pass 先聚合每格收到的最高目标，再以 `alpha=1-(1-hydro_moisture_response_rate)^dt_days`（默认每日 `0.08`）只更新一次，禁止硬下限瞬移和多河邻接重复推进。土壤/WB30 仍使用原有 `hydro_bank_moisture_gain`，因此季节地形分类与植被水分都消费同一条河岸补给链。

`dt_days` 必须等于本次天气/权威采样跨过的真实游戏天数；降水与融雪累计量按 dt 积分，soil/WB30/Q30、地下水衰减和河道释放使用 `1-(1-rate)^dt`（或等价幂衰减）换算，不能在 `native_daily_sim_stride>1` 时仍只推进一天。

调度原因：它读取当天已提交的 `weather_precip`，所以不放在 `refresh_climate_daily`；它又会影响 stage-b 的植被动态与反馈，所以放在 `weather_summary` 之后、`refresh_daily_stage_b` 之前。默认 `ClimateProfile.runtime_hydrology_enabled=false`，关闭时保留静态生成期河流行为。

返回 report：`path=gdext`、`published_to_slot=true`、`native_ms`、`compute_ms`、`flush_ms`、`refresh_ms`、`n_cells`、`water_budget_error`、`river_discharge_p95`、`river_discharge_max`、`riparian_neighbor_touches`、`river_moisture_floor_touches`、`riparian_moisture_floor_touches`、`moisture_response_alpha`、`river_moisture_max_delta`、`riparian_moisture_max_delta`、`flood_candidate_count`。若 slot 缺失或 size 不匹配，返回 `published_to_slot=false` 和 `fallback_reason`，旧静态河流仍可继续显示。

Native daily continuation 内，水文仍立即写 C++ slots，但在
`is_native_daily_visual_commit_pending()==true` 时不把 `cell_moisture` 中间值 flush 到
`MapData`，report 标记 `visible_publish_deferred=true`。独立调用水文 pass 时默认仍立即
flush；native round 的最终湿度由 `map_generator.gd::_native_daily_apply_finalizer()` 发布，
随后调用 `complete_native_daily_visual_commit()` 解除视觉快照屏障。

## Temp baseline year bake（生成期 cell_temp_baseline_year）

主要入口：

- `DCWorldExt::run_temp_baseline_year_bake`（C++ 权威）
- `map_generator.gd::_bake_temp_baseline_year_native`（窄兜底：native generation publish 失败后调一次）
- `map_data.gd::bake_lat_temp_year_lut`（GDScript fallback + 几何量 `cell_lat_norm` 烘焙）

背景：`cell_temp_baseline_year`（每 cell 年均纬度温度钟形）是海冰判定与显示温度的运行期 baseline，被 C++ pass_a（`TEMP_YEAR_BASE`）、GDScript pass-A fallback、`climate_daily_system`、debug overlay 共同消费。它原本由 GDScript `bake_lat_temp_year_lut` 就地 `pow(cos(lat·π/2), exp)` 烤出来再经 `refresh_slots_from_map` 推给 slot——仿真量的权威落在 GDScript，逼着 GDScript / C++ / Shader 三处镜像同一条 `lat_temp_bell`。

链路（temp-baseline-authority-2026-06 之后）：

1. 生成期 `bake_lat_temp_year_lut` 烤 `cell_lat_norm`（依赖地图几何 `cube_row_norm`，权威留在 GDScript），并用 `DCClimateMath.lat_temp_bell_from_ny` 填一份 `temp_baseline_year` 作为 **fallback**。
2. `_data_core_world_ext` bind + `configure_native_world` 完成后，首选 `run_native_world_generate_pass` 发布包含 `cell_temp_baseline_year` 在内的生成期初始仿真 slots。
3. 若 native generation publish 失败，`_bake_temp_baseline_year_native` 把 `cell_lat_norm_arr` 作为 `lat_norm` knob 传入 `run_temp_baseline_year_bake`，只补 `cell_temp_baseline_year` 这一个字段。
4. C++ 用唯一实现 `pk_lat_temp_bell` 算 `temp = clamp01(bell((ny-0.5)·2))` 写满 `cell_temp_baseline_year` slot，`_flush_slot_to_map` 回 `MapData.temp_baseline_year_arr`，返回 `path=gdext / published_to_slot=true / n_cells / elapsed_ms`。
5. ext 未编译 / 未 bind / 缺 slot / 缺 knob → 返回 `fallback=true`，保留步骤 1 的 GDScript 值。

I/O：

- 输入：`knobs["lat_norm"]`（`PackedFloat32Array`，ny∈[0,1]）。走 knob 而非 slot，因为本 pass 在 `cell_lat_norm` slot refresh 之前调用。
- 输出：`cell_temp_baseline_year` slot + `MapData.temp_baseline_year_arr`（flush 同步）。

权威：C++ slot（ext 可用时）；GDScript `lat_temp_bell` 仅作 fallback 与纯 GDScript 生成期 `_compute_temperature` / 地形决策使用。公式跨语言仍是 SAME_SOURCE 镜像（`DCClimateMath.lat_temp_bell` ↔ `pk_lat_temp_bell` ↔ shader `lat_temp_bell`），改指数须三处同步并重编 gdext。

## Season refresh

主要入口：

- `simulation/systems/season_refresh_system.gd`
- `map_generator.gd` season helper
- `DCWorldExt` 中日历/路径相关 helper

链路：

1. scheduler 触发 `season_refresh`。
2. GDScript stage machine 推进日历/轨道相位和相关缓存。
3. B+ path 可走 `gdext`，日志中会出现 `b_plus_path=gdext`。
4. 末尾可能排队 atlas/visual 更新。

`season_phase` 在当前 runtime 中只表示年内轨道相位，用于计算太阳直射点、日照和昼长；它不再作为独立的季节魔法因子直接改变温度、湿度、降水或风向。`refresh_seasonal()` 也不再执行旧的按季节重置湿度/雨影/风向逻辑，只保留慢层与 atlas 边界维护。

性能特征：

- 当前通常很低，例如 `avg=0.03ms` 到 `0.06ms`。
- 不是主要 hot path，但它产生的 season phase 会驱动 climate/weather/ocean 输入。

风险：

- 如果 season phase 与 climate round 锁相位不一致，会导致验证日志里的 phase 差异。
- `seasonal_redecide_terrain` 只能在陆地生物群系/雪线之间重判，不能把当前非水地块判回 `OCEAN/COAST`。生成期排干/回填的内陆低洼地可能仍保留低于 `sea_level` 的原始 elevation，运行期必须用 base/current land terrain 兜底。
- stage 2 和 stage 4 的生物群系分类使用慢时间尺度输入：`cell_temp_365d` 作为年均温度，`cell_base_moisture` 加上带符号的 `cell_water_balance_30d` 贡献作为分类湿度；不再用瞬时 `cell_moisture` 直接重判。stage 4 仍会把 donor delta 写入瞬时 moisture，供实时气候和 vegetation 使用。vegetation 则由 stage B 的 vitality/可用水量/演替状态独立更新，因此二者允许短期不相等但不会因季节湿度瞬时跳变而产生语义错位。
- 不应为了极低耗时再做复杂线程化。


## Climate daily round

### Emergent climate modes (2026-08)

The climate runtime now exposes three bounded, approximate modes without adding a
per-cell DataCore component:

```text
physical wind refresh -> coast BFS + signed land/sea thermal contrast
                      -> _phys_monsoon_thermal scratch field
ocean water slice     -> up to three tropical basin caches
                      -> bounded Jin-style recharge oscillator
                      -> existing ocean anomaly buffers
weather field solve   -> bounded native cyclone pool
                      -> generation-stamped radial/tangential forcing
                      -> precipitation/instability/front classification
```

Monsoon is a thermal contrast signal, not a scripted seasonal wind direction. Its
sign can reverse between onshore and offshore flow as the previous temperature
field changes. Physical circulation refreshes it at its existing cadence (normally
every few simulation days); daily weather consumes the latest field. `wind_surface`
remains the sole `cell_temp` writer.

ENSO selects connected tropical water regions deterministically, reduces them to at
most three basins, and integrates a low-order recharge oscillator with bounded Heun
substeps. Basin scalars feed existing thermal/transport anomaly buffers. Topology is
cached by signature and state restores by signature; maps without a valid basin
produce zero ENSO forcing.

Cyclones are resident native entities with profile capacity and per-commit birth
budgets. Entities advance from local warm-water/moisture/instability and wind
steering, then stamp generation-tagged forcing arrays. Weather consumes that
forcing before condensation and precipitation. The legacy front wake path remains
available when native mode is disabled; WeatherFront/LUT is still the visual
boundary.

Native reports expose `monsoon_eligible_cells`, `monsoon_onshore_cells`,
`monsoon_offshore_cells`, `monsoon_contrast_abs_max`, `enso_basin_count`,
`enso_cache_hit`, basin `temp_index`/`recharge_index`, `cyclone_active_count`,
and `cyclone_touched_cells`; cyclone births/decay are in the daily breakdown as
`cyclone_n_injected`/`cyclone_n_decayed`.
These are transient diagnostics; only bounded mode state is persisted.

主要入口：

- `simulation/systems/climate_daily_system.gd`
- `map_generator.gd` 中 climate helper
- `gdext/src/world_ext.cpp` climate/ocean/wind/transpiration pass

调度形态：

`refresh_climate_daily` 是一个跨 sub-stage 的 round。它可能在多个 tick 内推进，也可能在 native fast path 下单 tick 完成多个子段。

典型 stage：

1. Pass-A：基础温度、纬度、海拔、太阳几何、日照/昼长、热惯性。
2. Pass-B：平滑/扩散/湿度等后续修正。
3. Ocean water：海洋热输运。
4. Ocean land：陆地邻域/异常传播。
5. Wind / air mass：风与气团热输运。
6. Sea ice hook / ice bake。
7. Transpiration。
8. Integrity diagnostics。

视觉层约束：

- `shaders/include/climate_season.gdshaderinc` 的温度偏移与 `DCClimateMath` / `dc_insolation_*` 同源：日照年均值、当前日照和高纬受限相对差使用同一公式。
- `true_insolation_enabled` 只保留为旧材质/旧 UI 参数兼容；shader 统一入口不再切回 legacy 独立余弦季节温度项。
- 植被色相仍可使用 `hemi_phase()` 做纯视觉年内 tint，但它不参与温度、湿度、降水或风场计算。

### Climate Pass-A

C++ 入口：

- `run_climate_pass_a(cp_struct, phase, season_phase)`
- `run_climate_pass_a_thread(...)`

输入：

- temperature/elevation/latitude/neighbors/terrain/water/solar geometry and thermal-inertia knobs。
- 部分 scalar 来自 `ClimateProfile`。
- 气候自然性修复（2026-06-27，2026-07-17 单位修正，2026-07-24 涌现湿度）：`cell_moisture` 不再每日硬回填到 `base_moisture`，也不再使用 `base_moisture * (1 + 0.2 * insolation_dev)` 直接制造季节湿度。`base_moisture` 只保留静态地理锚点；太阳直射变化先影响温度、蒸发、海温/洋流、风场、水汽输送与降水，再由既有 `weather_vapor`、`weather_precip`、`soil_moisture`、`water_balance_30d` 状态进入 Pass-A target。默认水汽/降水/正土壤/正水量收支权重为 `0.12 / 0.78 / 1.82 / 1.04`；负土壤和负水量收支分别使用 `2.21 / 1.30`，相对上一档统一放大约 30%，只放大真实水循环异常。耦合配置上限为 `2.5`，最终湿度仍钳在 `[0,1]`。`runtime_moisture_base_relax_rate=0.24`；不新增持久 slot，scalar native、threaded native、async worker 与 GDScript fallback 保持同一公式。这里 `weather_vapor` 是量级约为 `0.15 * base_moisture` 的大气水汽，因此只允许把 `weather_vapor - 0.15 * base_target` 作为异常量；`soil_moisture` 是 `[-0.5,0.5]` 的有符号水文异常。禁止把这些字段当绝对湿度做 `lerp`，也禁止重新引入任何基于 `season_phase` / `insolation_dev` 的直接湿度乘数。

公式约束（2026-06-27 legacy parity）：

- `season_offset` 必须贴合迁移前 AoS 行为：`season_temp_amp * insolation_season_gain * surface_absorbed_factor * insolation_dev`，然后只对冷侧做 `compress_season_cooling`。
- `temp_land_continentality` 仅作为旧资源兼容字段保留，不再参与 pass-A 温度公式；native/SoA 不得额外放大陆地夏季强迫，否则副极地极昼陆格会被推到迁移前不存在的高温。
- **沿海海洋性调温（climate-zone-fix P2，2026-06-28）**：在 `pk_season_offset_continental` 之后、`radiative_target` 之前，对陆地 cell 施 `season_offset *= (1 - maritime_season_damp * maritime_factor[i])`，用"距海指数衰减"的 `maritime_factor`（per-cell 静态数组，海岸≈1/内陆→0，由 `MapGenerator._ensure_maritime_factor` BFS 缓存）缩小沿海年较差（冬暖夏凉）→ 温带海洋性(Cfb)在中纬沿海涌现。这是独立于上面 legacy `temp_land_continentality` 的新机制（后者仍被忽略）。`run_climate_pass_a` / `run_climate_pass_a_thread` / `_async_pass_a_kernel_pure` 三路在同一调用点同改、读同一缓存数组 + 同一 `maritime_decay_cells`，A/B 逐位一致；`maritime_season_damp=0`（或数组缺省）时三路均跳过缩放，与历史逐位一致。旋钮 `ClimateProfile.maritime_season_damp`(默认 0.45) / `maritime_decay_cells`(默认 4.0)。
  - **Köppen 复核（2026-06-28夜，CSV `tile_data_record_20260628_222157`）**：温带海洋性 Cfb 已涌现 **9 格(0.6%)**——年较差仅 0.126、全年均匀降水(swet 0.51)、中纬沿海(lat 0.38–0.59)，即西欧/新西兰式海洋性。注意 `tmp/wx_koppen.py` 旧分类器只按冬温把它们误并进 Cfa，已改为按 Köppen 正解「凉夏(Twarm<0.58)+低年较差+全年湿润=Cfb」（夏凉而非冬温才是 Cfb≠Cfa 的判据）。**`maritime_season_damp` 维持 0.45**：headless A/B(`tmp_maritime_eval.gd`)证实温度侧已饱和——0.45 已使 ~48 个沿海格达「凉夏+低年较差」，加到 0.55 仅 +1 格、沿海年较差只再降 5.8%。扩 Cfb 占比的真正杠杆是**降水型**（那 ~48 格里仅 9 格同时全年均匀降水，其余夏旱/夏雨），应走 P3 冬雨均匀化 CSV 标定，而非加大阻尼。

输出：

- `cell_temp_baseline`（runtime baseline = radiative + 热惯性积分；A 修复 2026-06，原来写 `cell_temp` 已下放给 `wind_surface` 合成阶段）
- `cell_ocean_thermal_anomaly` / `cell_local_thermal_anomaly`（在 pass_a 末尾清零，开启新一日的累加；wind_surface 末端用这两个 + `cell_air_mass_temp_anomaly` 与 baseline 合成回 `cell_temp`）
- `cell_temp_30d` / `cell_temp_365d` / `cell_temp_anomaly`（30 日 / 年长温度 EMA 及其差 = `temp_anomaly`）
- thermal/insolation/moisture base 相关 slots
- dirty mask / DataCore writes 视具体路径而定

`temp_anomaly` 的 EMA dt-aware（2026-06-28，`tile_data_record_20260628_145729.csv`）：`temp_30d`/`temp_365d`
原本固定用 `1/30`、`1/365` 的"每日"alpha，但 pass_a 在加速/跳日档下每次只调一次却推进 ~`thermal_dt`(dt_days) 天
→两个 EMA 窗口实际膨胀到 `30·dt`/`365·dt` 天，`temp_30d` 跟不上季节循环、与 `temp_365d` 一起趋年均
→`temp_anomaly` 坍缩到≈0（实测陆地 max 仅 0.037 < DROUGHT 0.05 / HEATWAVE 0.04 门 → 两类结构性不可达）。
修复与 pass_a 热惯性 `α_eff=1-(1-α)^dt` 同源：EMA alpha 也换算为等效多日 alpha（`a30=1-(1-1/30)^dt`、
`a365=1-(1-annual_ema_alpha)^dt`），`dt≤1` 时逐位等价（无回归）。C++（`run_climate_pass_a` 单/多线程）与
GDScript 镜像（`map_generator._climate_pass_a` legacy 与 `_climate_pass_a_soa`）锁步同改。dt>1 直测探针
`native_dt_compensation_probe_test.gd` 验证 dt=9 距平幅度保持 ~0.123（旧固定 alpha 坍缩到 ~0.031）。

性能：

- 设计目标是 C++ scalar tight-loop。
- 日志中 `climate path=data_core dc=data_core` 表示 DataCore 路径，而不是纯 GDScript。
- **年均日照缓存（2026-06，与 `run_slp_field_pass` 的纬度 LUT 同类优化）**：主循环里
  `dc_insolation_annual_mean(ny, axial_tilt, daylen)` 是 16 样本年均积分（~144 trig/cell），但只取决于
  cell 纬度 + 行星 `axial_tilt`/`daylen`，**跨日不变**——历史上却每日每 cell 重算（2464×16 trig/日 ≈ 1.38ms）。
  又因 `run_climate_pass_a` 末尾 `return 0.0`（无内部计时），这笔成本被藏在 `climate_ms≈0` 之外，breakdown
  长期看不到（排查时务必区分"pass 返回的 ms"与"pass 实际 wall"）。现按 cell 记忆该年均值
  （`DCWorldExt::ensure_insol_annual_mean_cache`，用 (n, 纬度位, tilt, daylen) 的 FNV-1a 指纹失效，几乎只在
  建图/改行星参数时重建一次），`run_climate_pass_a` 与 `run_climate_pass_a_thread` 主循环改查缓存（与内联
  `dc_insolation_annual_mean(dc_clamp01f(lat[i]), …)` 同函数同入参，**bit-equal**）。实测稳态 pass_a
  ~1.7→0.38ms，原子 `round_native_call_ms` 3.69→2.37ms。worker 版纯核 `_async_pass_a_kernel_pure` 仍内联
  原算法（不碰成员缓存，线程安全；值相同不破坏 A/B）。剩余每日不变项（`dc_insolation_now`/`dc_day_length_norm`，
  ~13 trig/cell）随 season_phase 变，仍需逐日算。
- **多核接图（2026-07，bit-equal）**：native daily 图（slice `exec_slice_node` + `SCHEDULE_GRAPH` +
  legacy if-chain）此前调单线程 `run_climate_pass_a`，现统一改调 `run_climate_pass_a_thread(...,0)`（`pk::parallel_for_range`
  自适应 task 数）。pass_a 纯 cell-local（无邻居 gather）→ 多核逐位等价。`tests/climate_pass_bench.gd`：
  49k cell 2.83→0.61ms（4.7x）、110k cell 5.05x，随 N 仍升 → compute-bound、近线性。**手写 AVX2 评估为 no-go**：
  pass_a compute 被 transcendental（insolation/day-length/pow）主导，矢量化到 ulp≤4 需 SVML 级超越函数、可向量化
  纯算术子段占比小 ROI 低；in-core 轴由多核兜住（数据见 `tmp/climate_bench_phase0_summary.md`）。
- `climate_pass_a` node-range 不是低风险配置项：它一次写 temp/baseline/EMA/thermal/snow 等多组 slots，
  中间 chunk 需要 `defer_flush` 并保证后续节点绝不读到半发布状态。若 perf 继续显示
  `native_daily_sim/climate_pass_a` 是单片 p95 owner，应先补真实内部分段计时，再做 PROBE
  range 实现和 SAME_SOURCE/A-B，而不是直接加入默认 `native_daily_node_range_nodes`。

排查：

- 如果 `largest=refresh_climate_daily/pass_a/native_or_gd path=data_core` 出现 spike，需要看 stage breakdown 内 A 的细分和是否有 `cpp_taken_over=true` 等诊断。
- `path=data_core` 不是失败；要看是否有 fallback reason 或 native method missing。

#### Async parity（plan §async-stage-2，2026-06-14）

`pk_async_climate::_async_pass_a_kernel_pure` 是 `run_climate_pass_a` 的纯
`std::vector` 镜像（worker thread 跑、零 Godot API）：
- 算法逐行 1:1 (run_climate_pass_a line 2293-2417 的 run_range lambda body)
- 24 个 input field + 16 个 output field（与 sync 路径末尾 16 个 `_flush_slot_to_map`
  一一对应）
- 复用现有 `dc_insolation_now` / `dc_insolation_annual_mean` / `dc_clamp01f` 等
  inline helper（它们已是 pure function，worker 安全）
- pass_a cell-local 无邻居依赖，分 in/out buffer 不影响 bit-equal

A-B 验证 hot key：游戏运行时按 `V` 键触发
`MapGenerator.run_async_climate_round_bench("pass_a")`：跑一次 sync
`_climate_pass_a` 拿 16 字段参考，再跑 async path（`passes_mask=0x01`），对比
全部 16 输出字段是否 bit-equal，print `[async/bench pass_a] === A-B verification ===`
报告（total_diff_count_f32 / total_diff_count_u8 应为 0）。

### Climate Pass-B

入口：

- `simulation/climate/pass_b.gd`
- `climate_daily_system.gd`
- `map_generator.gd` pass-b helper
- C++ system schedule / pass-b 相关 helper

职责：

- 基于 Pass-A 结果进行后续气候平滑、湿度、异常修正。
- 通过 `write_f32_indexed` / dense 写回 DataCore，减少单点 setter。
- **A 修复（2026-06）**：原来直接覆盖 `cell_temp = clamp(snapshot + d_albedo + d_coastal + d_landform)`；现在累加到 `cell_local_thermal_anomaly` slot，由 `wind_surface` 末端合成。海冰反照率反馈 (`sea_ice_albedo_cooling`) 也对应累加为水域 cell 的负 local anomaly，不再就地改 cell_temp。`cell_moisture` 写权不变。
- **2026-06-27 海冰相位修复**：CSV 显示厚冰水域 `cell_local_thermal_anomaly≈-0.05`
  会让春季日照已经回升时仍继续锁冷，海冰峰值相对日照低谷滞后 2-3 个月。
  `sea_ice_albedo_cooling` 默认从 0.06 降到 0.01；sync/native daily/async 输入、
  GDScript fallback 与 C++ 默认必须一致。
- 迁移等价性约束（2026-06-27）：native daily bundle 与 async kick 必须显式传
  `sea_ice_albedo_cooling`、`sea_ice_frac`、`snowpack_cover_low/full`，缺省值 mirror
  `ClimateProfile`。不要依赖 C++ optional knobs 的 0 值兜底，否则水域海冰反照率反馈会在
  native/async 路径被静默关闭。

性能：

- **多核接图（2026-07，bit-equal）**：native daily 图三路（slice / `SCHEDULE_GRAPH` / legacy if-chain）
  此前调单线程 `run_climate_pass_b`，现统一改调 `run_climate_pass_b_thread(...,0)`（为此放宽其原
  `n_tasks<1→1` 钳制，使 `n_tasks<=0`=`pk::parallel_for_range` 自适应）。安全性：pass_b own-cell 写
  `local_thermal_anomaly`/`moisture`，邻居只读 round-start 快照 + 预拍 `temp_snapshot` → 无跨 cell 写依赖、
  多核逐位等价。`tests/climate_pass_bench.gd`：49k cell 1.72→0.34ms（5.1x）、110k cell 5.57x、compute-bound。
- **`pass_b_thread` 海冰尾循环 bug 修复（2026-07）**：`run_climate_pass_b_thread` 此前**漏写**了 scalar/simd
  版都有的「`sea_ice_albedo_cooling>0` 时 water cell 的反照率制冷尾循环」与对应 `sea_ice_frac` knob 读取——
  因该变体一直未接图而长期休眠。`tests/sim_2ms_ulp_tolerant_test.gd`（scalar↔thread 逐 cell A/B）首次接图前
  捕获此分叉（thread 0.0 vs scalar −0.00332）并修复，现 worst=0 逐位等价。
- **融合 / SFC 评估为 no-go**：pass_b 与 pass_a 均 compute-bound（~2–3 GB/s 远未触 DRAM），融合省内存流量、
  SFC 改 cache 局部性收益≈0 且高风险，故不实施（数据见 `tmp/climate_bench_phase0_summary.md`）。

风险：

- sparse runtime 如果触发，但 C++ 仍跑全图，结果应保持等价。
- Pass-B 仍是未来 total C++ 化的重点候选之一，特别是 GDScript sparse apply 或 dirty sync 变成窗口 spike 时。
- retained `ClimateDailySystem`、native daily ACTIVE slice graph 与 debug/full-run
  helper 必须保持同一日气候顺序：`pass_a -> pass_b -> ocean_* -> wind_*`。`pass_b`
  的 `cell_moisture` 蒸发/雨影项读取 `temperature_transport_anomaly`，因此不能把
  `ocean_*` 提前到 `pass_b` 之前，否则会把当天新 TTA 反馈进当天湿度，造成沿海/邻水格湿度跳变。

## Ocean water / land

主要入口：

- `simulation/ocean/water_pass.gd`
- `simulation/ocean/land_pass.gd`
- `map_generator.gd::run_ocean_water_pass_slice`
- `DCWorldExt::run_ocean_water_pass`
- `DCWorldExt::run_ocean_land_pass`

Ocean water 算法概要：

- 读取 water cells、ocean current、baseline temperature、transport anomaly。
- 沿 ocean current / 邻接方向做 advect/mix。
- 生成或更新 temperature transport anomaly。对水格的正向暖流 source，`ocean_water`
  会先按 `sea_ice_frac` 和 `sea_ice_form_threshold → sea_ice_melt_threshold` 做潜热门控，
  并且在 baseline 低于 melt 阈值时限制 source 不能把水面推过 `sea_ice_melt_threshold`；
  这样冰点附近无冰水面不会积累成长期 `TTA≈0.2` 的暖流记忆。

Ocean land 算法概要：

- 读取邻居 anomaly、baseline fallback、terrain/water mask。
- 对非水格应用邻域异常传播和衰减。
- 更新 land temperature / anomaly。

数据契约：

- C++ 读取 C++ slot 或 knobs PackedArray。
- **A 修复（2026-06）**：ocean_water / ocean_land **不再写 `cell_temp`**——它们的洋流 advect & 邻接渗透结果累加到 `cell_ocean_thermal_anomaly` slot，由 `wind_surface` 末端的合成阶段统一发布回 `cell_temp`。`cell_temperature_transport_anomaly` 这条独立的低通 anomaly（由 `dc_stabilize_tta` 维护）保持不变，供 weather field reader / pass_b coastal-leak 消费。
- `cold_transport_form_threshold` / `cold_transport_melt_threshold` 必须来自
  `ClimateProfile.sea_ice_form_threshold/melt_threshold` 并传入所有 sync/native/async
  ocean-water 入口；不要让某个路径落到 C++ 的硬编码兜底。
- 如果 GDScript fallback 后下一个 C++ stage 依赖结果，需要 `refresh_slots_from_map()`。

风险：

- ocean current slot stale 会导致 advect 方向退化。
- baseline fallback 错误会造成 temp clamp 后永久卡 0。
- 如果 slice path 与 full path 混用，要保证未处理区间不会读到半新半旧异常。
- GDScript fallback 仍是旧语义风险面：若 C++ ocean pass 失败，fallback 可能直接写
  `cell_temp` 而不是 `cell_ocean_thermal_anomaly`。生产目标是 fallback 命中率趋近 0；
  真要保留 fallback parity，需要单独 A/B 后改写 fallback。
- 后续 `ocean_water` slot-input 优化只应以 PROBE 方式推进：当前 perf 显示 compute 很低、
  slice wall 更像 knobs/边界税，但 `ocean_water` 必须读取 pass-A/B 之后的最新温度/TTA。
  直接把所有 PackedArray 输入替换为 slot 读取前，要先证明 slot freshness、fallback flush
  和 `MapData` 可见性与现有 JIT patch bit-equal。

## Wind / air mass

主要入口：

- `simulation/climate/wind_heat_transport.gd`
- `map_generator.gd::run_wind_air_mass_pass_native`
- `map_baker.gd` physical wind field stage
- `DCWorldExt::run_wind_air_mass_pass`
- `DCWorldExt::run_wind_surface_pass`
- `DCWorldExt::run_wind_field_pass`

职责：

- climate daily 中的气团/热输运。
- ocean currents physical chain 中的 wind vector / wind speed field。
- terrain-aware wind、纬度背景风带、SLP 压力梯度/科氏偏转、天气尺度波动、山脉绕流、沿海热力压差响应等计算。
- SLP 压力梯度在方向合成前先归一化：`-∇slp` 决定高压到低压/地转偏转方向，梯度幅度只控制压力项权重和风速增强，避免弱梯度数值被纬向背景风带完全压制。
- 气候自然性修复（2026-06-27）：`run_wind_field_pass` 在 flux blend 后加入方向稳定层。`wind_min_flux_for_dir_update` 以下保留旧方向，正常强度下用 `wind_max_turn_deg_per_day` 限制单日最大转角；`cell_wind_x/y` 仍保持单位方向语义，速度仍只写 `cell_wind_speed`。report/CSV 通过 `wind_dir_delta_p95` 与 `wind_dir_flip_count` 单独观察方向跳变，不再只用混合了速度变化的 `wind_delta_p95`。
- NS 化准动量风场（2026-08-04，plan/NS化气候动力学四方向深化）：诊断风合成后新增四个可选准动量阶段，全部 `ClimateProfile` gate、默认全关（缺省与旧诊断风逐位一致）：
  1. **动量自平流 + 扩散**（Phase 1）：写回段改为 `V_new = r·V_diag + (1-r)·(SL(V_old) + w_d·Laplacian(V_old))` 松弛形式，即动量方程 `dV/dt = -(V·∇)V + ν∇²V - r(V-V_force)` 的半隐式离散。旧通量快照驻留成员（`_phys_wind_snap_fx/fy`，首切片重建后续复用 → 任意切片 ≡ 全量逐位一致）；`w_d` 按 `wind_elapsed_days` 与 `s²= N/15000` 格距归一、上限 0.5（6 邻居显式扩散无条件稳定域）。旋钮 `wind_momentum_advect_w`（≤0.5）、`wind_momentum_diffuse_w_daily`。
  2. **回溯轨迹表 + 真半拉格朗日平流**（Phase 0/2）：wind pass 末对最终风场构建 `_phys_wind_traj_*`（每 cell 3×i32 索引 + 3×f32 权重 = 24B/cell；回溯长度 `|flux|·wind_traj_pos_scale·s·wind_traj_dt_days`，`s=√(N/15000)` 格距归一；walk ≤12 hop + 六分扇形 barycentric，wrap 最小映像折叠）。指纹 `pk_wind_state_fp`（64 降采样 FNV）随表快照；`run_weather_field_solve_pass`（vapor/cloud）与 `run_wind_air_mass_pass`（气团热）消费端复算比对，失配落旧 hopping 并 `stale_count++` 上报。消费总闸 `wind_traj_weather_share`（false = 仅构建供动量，不共享 weather）。**契约**：NB 表东西环绕（`_build_indices` posmod）时 `wrap_period_x` 必须按地图几何传入（生产两路径均满足）；`wrap=0` + 环绕 NB 是契约违规，回溯 walk 会把环绕邻居当远端真方向。
  3. **散度阻尼 L1**（Phase 3）：wind pass 末 `div=∇·V`、`V += α·∇div`（与 SLP 段同 `(1/3)ΣΔ·NB_DIR` 离散），`α_eff = min(α·s², 0.3)`（硬上限，超了 push_warning）。**符号取 +**：`∂(½∫div²)/∂t = -α∫|∇div|² ≤ 0`，是 div 的扩散；`-` 号为反扩散。初版按方案文本写成 `-=`，2026-08-04 DIV-only A/B 实测暴露（div p95 +10.5%、风速 +3.8%），翻转为 `+=` 后复测 div p95 −9.6%/div_max −11.5%、风速 −3.5%、雨带质心偏移 ≤0.021，公式测试新增"脉冲场 Σdiv² 严格下降"性质断言防回归。谱选择性压制网格级散度噪声，几乎不触行星尺度辐合。两趟只读/写分离 sweep，bit-equal 并行。旋钮 `wind_div_damp_alpha`。L2 散度投影（复用 PSI SOR/warm-start 解 `∇²χ = div - div_target`）按方案"仅在 A/B 证明 L1 不足时推进"条款**不推进**：修正后 L1 单档已达上述阻尼效果且无翻转率/雨带副作用。
  4. **洋流深度耦合 + 地形转向**（Phase 4）：`run_psi_solver_pass` 风应力旋度源项按深度衰减（`ocean_depth_curl_damp`，深度来自 `cell_elevation` slot + `sea_level`/`ocean_depth_ref` 换算）；current-from-PSI 步加 `k_topo·(∇h × k)` 等深线偏转分量（`ocean_topo_steer_w`）。60 tick cadence，成本无感。可选洋流涡度 SL 默认关闭留待 A/B。
  - 诊断键（ knobs 回填，`MapBaker` phys diag / daily_wind_diag 常驻，经 `get_sim_breakdowns` 的 `ocean` 组进 perf CSV `bd_ocean_*` 列；`headless_perf_record.gd ns_gates=ON|WIND` A/B）：`momentum_advect_diffuse_delta_p95`、`momentum_advect_w_eff`、`momentum_diffuse_w_eff`、`div_damp_alpha_eff`、`wind_traj_gen`、`wind_traj_stale_count`、`ocean_topo_steer_w` / `ocean_depth_curl_damp`(PSI out)。功能探针 `tests/headless_ns_climate_probe.gd`（同 harness，输出降水/雨带质心/水汽云总量/风散度统计紧凑 CSV，`ns_gates` 另支持 `DIV`=L1 隔离档）。
  - 镜像策略：`physical_circulation_solver.gd::solve_wind_field` 结构镜像动量两项（近似级 stale-DLL fallback，不逐位）；`field_solver.gd` 定位**隔离 fallback**（生产 profile 已退休 legacy weather 注册，保留旧 hopping 语义，不进 SAME_SOURCE 严格镜像清单）。
  - 公式测试 `tests/native_wind_traj_momentum_test.gd`（25 checks）：均匀场恒等、Laplacian/散度复刻逐 cell 精确、脉冲场 Σdiv² 严格下降（防 L1 符号回归）、切片≡全量 bit-equal、线性场 SL 精确 + 跨接缝 + 顶点夹逼（无 overshoot）、指纹 stale 回退。
  - A/B 验收快照（2026-08-04，60x40=2400 格 120 天季节窗口 + 150x100=15000 格 30 天）：`stale_count=0`、轨迹表每 wind pass 重建、weather 场求解持平略快（−4%）；wind pass 增量 +0.44~0.55ms/轮 @2400、+1.37ms/轮 @15000（摊薄 ≈0.09/0.23 ms/tick @period6）；风向 delta p95 +3~7%、翻转数 +22%（动量惯性预期内上行，评审关注项）；DIV 修正档 div p95 −10%、降水带质心 |Δ|≤0.02、总水量（汽+云+降水）守恒 ±0.1%；PSI 迭代 16→16、残差 0.0021→0.0022、洋流 preclamp −0.3~−4.4%、PSI native +9%（方案上限 +20% 内）。

输出：

- `cell_wind_x`
- `cell_wind_y`
- `cell_wind_speed`
- `cell_air_mass_temp_anomaly`（air-mass pass 唯一输出；surface pass 在累加邻接 anomaly 后也把 air anomaly 写回这个 slot）
- `cell_temp` — **A 修复（2026-06）：climate-daily 链条中 `wind_surface` 是唯一写者**。末端公式：
  `transport = clamp(cell_ocean_thermal_anomaly[i] + air_anom_after_advect[i], -0.08, 0.08)`，
  `cell_temp[i] = clamp(cell_temp_baseline[i] + transport + cell_local_thermal_anomaly[i], 0, 1)`。
  对水格且 `transport > 0` 时，`wind_surface` 还会按 `sea_ice_form_threshold → sea_ice_melt_threshold`
  对冰点附近的正向横向输运做潜热门控，避免无冰边缘水面被固定抬高到融冰阈值以上而无法重新结冰。
  baseline / ocean_anom / local_anom 分别由 pass_a / ocean_water+ocean_land / pass_b 写入；air_anom 由 wind_air_mass 注入、wind_surface 在邻接平流后更新。

数据契约：

- `cell_wind_x/y` 是单位方向向量，不存速度。
- `cell_wind_speed` 是物理化强度，weather field、wind heat transport、surface injection、PSI/upwelling 都应读它做强度权重。
- `wind_field_buffer` / vector atlas 的 BA 通道是渲染速度向量：`dir * clamp(wind_speed / 1.7, 0, 1)`。shader 对 BA 求 `length()` 得到的是归一化风速，不是恒定 1 的方向模长。
- `run_wind_air_mass_pass` / `_wind_air_mass_pass` 只发布
  `cell_air_mass_temp_anomaly`。它们不再直接覆盖 `cell_temp`；后续
  `run_wind_surface_pass` / `_wind_surface_pass` 是 **climate-daily 链条中 `cell_temp` 唯一的写者**
  （A 修复 2026-06），通过 baseline + shared lateral transport(ocean+air) + local_anom 的合成把全部贡献汇总成单点写。
  排查局部温度 ping-pong 时先确认 pass_a / pass_b / ocean_* 都没再获得 `cell_temp` 写权。
- native daily wind-air 节点在新 DLL 上优先走 `read_temp_from_slot=true`：
  `run_wind_air_mass_pass` 直接读取 `cell_temp` slot 作为 `temp_before` 快照来源，并只把静态
  `baseline_arr` 作为非有限值兜底传入。旧 DLL 没有 `supports_wind_air_slot_temp()` 时，
  `MapGenerator` 才回退到构建 `temp_before_arr` 的兼容路径。该优化不改风热输运公式，
  只消除每轮 wind-air JIT patch 里的全图当前温度打包。
- `enable_wind_heat_transport=false` 时，sync/native daily/async 都必须跳过 wind_air 与
  wind_surface。async `passes_mask` 需要清掉 bit 4/5，避免 worker 继续写
  `cell_air_mass_temp_anomaly` 或最终 `cell_temp`。

风险：

- wind field 既被 climate/weather 使用，也被 ocean physical chain 使用。不要把单位方向 `cell_wind_x/y` 当作风速；否则天气平流、降水 carryover、风向 overlay 和 shader 都会表现为全图恒定强风。
- `path=gdscript` 需要看是 wind stage fallback，还是只是 early report 默认值。
- GDScript wind fallback 仍是旧合成模型（直接在当前温度上加 anomaly，缺少 C++ 的
  `cell_wind_speed` 权重、shared transport budget 与冷水潜热门控）。当前修复策略是监控并降低
  fallback 命中，而不是在无 A/B 的情况下重写 fallback。

## Natural resources（自然资源每日生成/衰减）

主要入口：

- `DCWorldExt::run_natural_resource_pass(knobs)`（C++ full-map pass，slot 权威 + flush 回 MapData）— [`gdext/src/world_ext_resource.cpp`](../../gdext/src/world_ext_resource.cpp)
- `map_generator.gd::run_natural_resource_pass_native(map)`（守门员 refresh + native dispatch + GDScript fallback）
- `map_generator.gd::_bootstrap_natural_resource_deposits(map, cfg)`（生成期一次性写初始储量）
- `NaturalResourceDailySystem`（`natural_resource_daily`，每日 DCSystem，按 Profile 读取即时/30 日温度与环境湿度/植物可用水 → 拓扑自动排在 climate 之后）— [`scripts/simulation/systems/natural_resource_daily_system.gd`](../../Project/project-keynes/scripts/simulation/systems/natural_resource_daily_system.gd)
- 数据驱动配置：`ResourceProfile`（.tres）+ `ResourceProfileRegistry`（`build_pass_knobs` 组装系数数组）。

**模型（统一 profile，可选线性或种群生态动态）**：普通资源每 tick、每 cell、每资源 r
采用**半隐式（IMEX）积分** —— 把生成/衰减拆成「常数生产项 P」与「线性损失率 L」，
损失项隐式求解，故对任意系数（含极端自系数）都**无条件稳定**，单调趋近均衡、不过冲：

`temp`、`temp_lo`、`temp_hi` 的权威单位统一为地图气候温度 `[0,1]`；不得在
`ResourceProfile` 中混入摄氏范围。2026-07-16 前资源目录曾保留 `-30..45` 一类摄氏式范围，
但运行时实际传入 `[0,1]`，会把热带格的 `tn` 压到接近 0，进而错误压低林木、野生动物、
肥沃土壤等所有启用温度适宜度的资源承载量。目录、默认 codegen 与回归测试现共同守住该契约。

Profile 还编译 `runtime_temperature_signal` 与 `runtime_moisture_signal` 两列。肥沃土壤、林木和
野生动物使用 `temp_30d + plant_available_water`，淡水/海洋鱼使用
`temp_30d + ambient moisture`，地质资源使用 `current temp + ambient moisture`。C++ scalar/SIMD/
worker 在循环外解析选择列，GDScript fallback 使用同一选择；静态土地 capacity 不随短期信号
改写储量。

```text
tn            = clamp((temp - temp_lo[r]) / (temp_hi[r] - temp_lo[r]), 0, 1)
m             = moisture
climate_fit   = temp_fit * moisture_fit
runtime_fit   = lerp(1.0, climate_fit, runtime_climate_fit_weight[r])
gen_climate   = gen_base[r]   + gen_temp[r]*tn   + gen_moisture[r]*m
decay_climate = decay_base[r] + decay_temp[r]*tn + decay_moisture[r]*m
P             = gen_climate + gen_self[r]*runtime_fit
              - decay_climate - decay_stress[r]*(1-runtime_fit)
L             = max(0, decay_self[r])
reserve_ext   = max(0, reserve + extra_change[r,i])
reserve'      = max(0, (reserve_ext + P) / (1 + L))       # dt_days=1
```

当 `P > 0` 且 `decay_self > 0` 时，动态平衡点 `reserve* = P/decay_self`。`extra_change`
是每 cell 每资源的一次性外部增减量：先应用一次，再按 `dt_days` 对自然 P/L 做闭式 catchup，
因此五日 stride 不会把一次采收重复五遍；pass 消费后清零。**历史问题**：旧式
`reserve' = clamp(reserve + gen − decay)` 对旧 `capacity` 模型下刚性配置会被硬上限
clamp 成横跳；当前模型改为无硬上限的半隐式线性自衰减。

`ecology_capacity > 0` 的动物种群与林木改走稳定的离散 Beverton-Holt 密度增长：

```text
runtime_capacity = ecology_capacity * runtime_fit
seeded           = reserve_ext + ecology_immigration * runtime_fit
growth_factor    = 1 + ecology_growth_rate * runtime_fit
reserve'         = growth_factor * seeded /
                   (1 + (growth_factor - 1) * seeded / runtime_capacity)
acute_stress     = clamp((0.25 - raw_climate_fit) / 0.25, 0, 1)
reserve'        /= 1 + ecology_stress_mortality_rate * acute_stress
```

低密度种群自然恢复，接近承载量时增长趋零，超过承载量时自然下降；迁入项允许适生地
从零缓慢恢复。普通非理想气候已经通过较低承载量表达，不再重复承受压力死亡；显式死亡只作用于
原始温湿适生度最低 25% 的急性气候压力。非线性生态分支在 `dt_days > 1` 时逐日迭代，外部变化
仍只应用一次。

`habitat_modes[r]` 将储量限定为 `any / land / marine_water / freshwater / coastal_land / coastal_or_marine`。
`marine_fish` 同时使用沿海陆格与海洋水格，但每个 cell 只保存自己的储量；淡水鱼恢复为 DataCore
经济资源，位于湖泊水格及湖岸陆格。habitat 外储量为 0。所有建筑资源边只允许读取本格；公共供水以后
另行设计，不进入食品/饮料配方。
当前目录含 31 种注册自然资源；小麦、水稻、玉米、土豆、棉花、亚麻、橡胶、香料、药材均已从
自然资源移出，只作为农场/种植园产出的 goods。旱作耕地、水田容量、种植园容量、牧场容量和肥沃土壤
是农业 capacity 条件，不会被每日生产扣减。矿产通常 `gen_* / decay_* = 0`；土壤
沿用线性 IMEX，野生动物、林木与海鱼启用密度制约生态分支。`fertile_soil` 的最差适宜度净自然项保持为正，
其省级面积缩放后的长期储量下限为 5000；`wild_game` 使用 1200×100 的理想承载量、0.065% 日增长、
`0.01×100` 日迁入，并关闭季节性急性压力死亡；气候仍通过承载量表达长期适生差异，适生地可从零恢复，并以真实的
`24 × 0.715 × 5 = 85.8` 每周期采收量通过理想/普通气候五年高位回归。`timber` 使用
`100000×100` 理想承载量、1% 日增长与
正迁入；生成期排除沙漠/寒漠/极旱荒漠，剩余非沙漠陆地有 `1000×100` 的基础林木 floor，
最适生 30% 陆地初始储量不低于 3,000,000；湿度最适点/容差为 `0.70/0.55`，使高温高湿
雨林不会落入原始适宜度低于 `0.25` 的急性压力死亡区。林木急性压力死亡率为 `0.0001`（最大
`0.01%/日`），避免把每日气候异常按动物级 `1%/日` 复利成森林崩溃；低适宜度回归只验证低于
气候调整承载量时仍可正增长，不规定长期库存必须保持某个承载量百分比。
`marine_fish` 在沿海陆格与海洋水格的联合 habitat 中按适生度保留约 72% 的有效格，初始平均
`1800×100`，不再给全海域灌入同一最低值。适生度综合温度、海域深浅、洋流速度、上升流、河口营养
扩散和连续空间噪声；以 `5000×100` 为理想承载量，日增长率为 0.15%，迁入为 `0.01×100`。

**初始储量（bootstrap，多因子「地块自身情况」适宜度）**：`_bootstrap_natural_resource_deposits(map, cfg)`
在 `init_soa_from_bake` 与生成期物理环流 flush 之后、经济 bootstrap 之前跑一次。随后显式把 habitat
mask 与所有 reserve 数组推送到 GDScript DataCore 和 C++ snapshot slots，确保三者读取同一初值。
每资源、每 cell 算一个适宜度 `suit`，直接作为无上限初值。所有因子均**数据驱动**（`ResourceProfile`），
缺省 0 / `{}` 即不参与 ⇒ 不配置时与旧「仅温度+湿度」公式逐位一致（向后兼容）：

```text
tn   = clamp((temp - temp_lo[r]) / (temp_hi[r] - temp_lo[r]), 0, 1)
suit = init_base[r] + init_temp[r]*tn + init_moisture[r]*m
     + init_elevation[r] * clamp(elevation, 0, 1)
     + init_landform_weights[r][landform]              # Dictionary，缺键按 0
     + init_vegetation_weights[r][vegetation]          # Dictionary，缺键按 0
     + init_river[r]   * (has_river 或 is_lake_seed ? 1 : 0)
     + init_volcano[r] * (has_volcano ? 1 : 0)
     + init_ocean_current[r] * clamp(length(ocean_current), 0, 1)
     + init_upwelling[r] * clamp(upwelling_strength, 0, 1)
     + init_estuary[r] * estuary_strength
     + init_noise[r]   * noise01(cell_pos, init_noise_scale[r])   # noise01 ∈ [0,1]
     + init_climate_fit[r] * climate_fit                # 可选最适温湿区间
     + init_province[r] * 2*(province01(family)-0.55)   # 同族共享大尺度地质省
     + init_belt[r]     * 2*(ridge(family)-0.72)        # 同族共享狭长矿带
reserve0 = max(max(0, suit) * init_reserve_scale[r], init_floor_reserve[r])
           * CELL_AREA_RESOURCE_SCALE                   # 当前为 100；habitat/exclusion 不可用时为 0
```

可选 `init_excluded_terrain_ids/init_excluded_vegetation_ids` 在 habitat 之后进一步排除某些
terrain/vegetation；排除命中时初值强制为 0，也不参与覆盖率排序。可选 `init_floor_reserve`
对所有未排除的有效 habitat cell 提供逐格基础储量，适合林木这类“广泛存在但丰度由森林、气候、
噪声继续拉开”的资源；默认 0 保持旧资源逐位兼容。

有限地图还可配置 `init_min_coverage/init_min_reserve`：完成全图 suit 计算后，仅对有效且未排除的
habitat 按原始 suit 降序排序，在最适宜的前 N 个地块确保最低储量。该保底用于避免关键
资源整图缺失，默认 0 保持旧行为。

需要同时控制矿区、富集、小微矿点和世界总量的不可再生矿产使用四组独立约束：

- `init_target_coverage`：有效 habitat 中富集核心的比例；按原始 suitability 排名选区，所以
  地貌、局部噪声、共享地质省和矿带仍决定主要矿区。
- `init_richness_exponent`：只改变入选矿区内部的富集曲线；值越高，储量越集中在最优矿带。
  每个入选格仍至少获得 `init_min_reserve`，避免省级矿区只有象征性储量。
- `init_micro_coverage/init_micro_reserve_share/init_micro_min_reserve`：在富集核心之外增加确定性的
  小微矿点。第一轮选点要求与任何核心/小微矿格至少间隔一格，候选不足时才按 suitability
  稳定回填；其储量从同一世界总量中划拨而不是额外生成，因此只提高地区可达性，不制造资源。
- `init_target_reserve_density`：每个有效 habitat 格对应的世界储量密度。世界总储量严格归一化为
  `valid_cell_count × init_target_reserve_density × CELL_AREA_RESOURCE_SCALE`，因此覆盖率调整只改变
  集中程度，不会意外改变世界总量；世界尺寸扩大时总量按面积线性增加。生态资源可改用
  `init_target_mean_reserve`，让总量跟随实际占用 habitat，而不是整个候选 habitat。

当前富集核心覆盖率为：金矿 6%、银矿 15%、稀土/铅/锌/锰/硫/锡 3%、铝土矿/磷矿 4%、
石灰岩 5%。核心之外另配置 5%–12% 的小微矿点，总储量份额为 5%–20%；因此工业中心仍由
大矿区决定，但缺少富集核心的其他地区仍可能获得较低产能的本地采矿入口。

`ResourceProfileRegistry.CELL_AREA_RESOURCE_SCALE = 100.0` 表示一个战略地图格约为珠三角
量级面积。它统一缩放所有资源的初始储量、最低矿床、世界储量密度、线性模型绝对生成/衰减量，以及
生态模型的承载量/迁入量；无量纲增长率、线性损失率、气候适宜度、分布拓扑和建筑开采量
不缩放。因此新地图的资源数量与长期可再生平衡量均至少是基础 profile 标定的 100 倍。

- 数据源全部来自 bake/物理环流 flush 后已就位的 SoA：
  `temp/moisture/is_water/terrain/elevation/landform/vegetation/has_river/river_flow/river_downstream/`
  `is_lake_seed/has_volcano/ocean_current_x,y/upwelling_strength/cell_pos_x,y`。河口强度标记河流出口
  陆格、出口海格与较弱的一环近岸羽流；它只影响各格自己的初始化适生度，不授权跨格采集。
- **斑块化 / 矿脉化**：资源局部噪声按 stable id 独立；矿产另以 `geology_family_id` 共享
  `province` 与 ridge-shaped `belt` 场。两种共享场均中心化，省外/矿带外产生负贡献，避免每块陆地
  同时拥有大多数矿物；同族矿物仍在大尺度上相关。所有场由 map seed 派生，可确定性重放。
- 可选最适区间：
  `climate_fit = temp_fit * moisture_fit`，其中 `temp_fit/moisture_fit` 按归一化温度/湿度到 `climate_*_opt` 的距离线性衰减。`init_climate_fit` 控制生成期适宜度；`runtime_climate_fit_weight` 控制每日动态受适宜度削弱；线性模型用 `decay_stress`，生态模型可用 `ecology_stress_mortality_rate` 表达原始适生度低于 0.25 的急性气候比例死亡。野生动物将该项设为 0，避免把季节气候波动复利成异常死亡；生态参数默认全 0，旧资源行为不变。
- `init_reserve_scale` 在 suitability、地质省和矿带全部求值后统一缩放正储量，只改变数量而不改变
  资源出现位置。当前地质/不可再生资源通常为 `8×`、农业 capacity 为 `1×`、林木为 `40×`、
  海鱼为 `2×`、野生动物为 `3×`；最低覆盖/储量在缩放后独立应用。旧档已有
  reserve 不回填倍率，新建地图才应用。
- 现有 .tres 调参示例：金属矿按 mafic/felsic/hydrothermal/sedimentary 等 family 共享地质省和矿带；
  `clay` 偏三角洲/河流；`timber` 用 exclusion 排除沙漠/寒漠/极旱荒漠，用 floor 保证非沙漠陆地基础林木，再由森林植被和温湿适宜度拉开区域差异；三类农业容量与 `pasture`
  由地形、水系和气候决定；`marine_fish` 由沿海陆地或海洋水格 habitat 门控，并由温度、海域类型、
  洋流、上升流、河口与噪声共同决定初始分布。
- Earth-like 60×40（2400-cell）固定 seed 回归还验证所有生产资源全局存在、目标矿区覆盖率、
  世界总储量归一化、富集带差异、农业容量中位承载、
  林木/海鱼覆盖和种植园选择性，见 `tests/natural_resource_distribution_capacity_test.gd`。

**输入 / 输出**：

- 读 slot：`cell_temp` / `cell_moisture` / `cell_is_water` / `cell_resource_habitat_mask` 以及每个 `extra_change_slots[r]`。
- 写 slot：每个 `reserve_slots[r]`（如 `cell_res_timber_reserve` / `cell_res_iron_ore_reserve`）与对应 `extra_change_slots[r]`，逐资源 `_flush_slot_to_map`。动态资源消费后清零 external delta；静态省域矿床若本次小额扣减低于大储量的 float32 ULP，则把未能落入 reserve 的精确余量保留在原 extra slot，后续周期累计到可表示后再扣减，避免大矿床实际不可耗尽。
- knobs：`n_cells`、`dt_days`、`resource_count`、`reserve_slots`/`extra_change_slots`、
  `habitat_modes/habitat_mask_slot`、`temp_lo/temp_hi`、`gen_*`/`decay_*`、`climate_*_opt/tol`、
  `runtime_climate_fit_weight`、`decay_stress`、`ecology_capacity`、`ecology_growth_rate`、
  `ecology_immigration`、`ecology_stress_mortality_rate`（平行数组按资源索引对齐）。
- 返回 Dictionary：`{ done, path, published_to_slot, published_slots, resource_count, published_resource_count, input_resource_count, n_cells, total_delta, native_ms, compute_ms, loop_ms, flush_ms, skipped_static_resources, fallback_reason? }`，其中 `resource_count` 保持为输入资源总数以兼容测试，`published_resource_count` 是实际 loop/flush 的动态资源数；其余契约同 `run_runtime_hydrology_pass`。
- refresh 边界：`run_natural_resource_pass_native` 把 `cell_temp` / `cell_moisture` / `cell_is_water` 与 `extra_change_slots` 从 `MapData` 回拉到 C++ slots；旧 DLL 无 `refresh_slots_from_map_keys()` 时才退回全量 refresh。

**权威 / fallback**：native pass 是 reserve slot 权威。`published_to_slot=false`（含 native 不可用 / 无可发布资源）时 `run_natural_resource_pass_native` 退回 GDScript fallback（`_run_natural_resource_pass_gdscript`，同模板直接读写 `MapData.*_arr`）。两路逐 cell 逐资源 A/B 对拍一致（见 `tests/natural_resource_pass_test.gd`，≥20 cell 覆盖 SIMD body+尾段+陆/水混合）。

**性能路径（多核 + SIMD）**：因 `L`、`inv_denom=1/(1+L)` 与 `P=C0+C1·tn+C2·m` 的系数都是「每资源常数」，per-cell 除法被提到资源外，内层只剩 clamp + 2×FMA + 1×乘。native pass 据此：
- **多核**：先预筛动态资源，再走一次 `pk::parallel_for_range_with_emit`（`WorkerThreadPool`，自适应每 task ~1024 cell、clamp [1,16]）按 cell range 分块；每个 task 内循环全部动态资源，避免 2400-cell 小图上“每资源一次 WTP dispatch”的固定开销。小图继续走同一 fused body 的 single-thread SIMD（当前阈值 `n_cells < 100000`），大图才进 WTP。`total_delta` 经 thread-local `DeltaEmit` 串行 reduce；无线程池自动降级为单线程，且与多线程 bit-equal。
- **SIMD**：`PK_HAVE_AVX2` 构建下内层 8 cell/iter（`loadu`/`fmadd`/`max`；`land_only` 经 `blendv` 让水面格保持原值），尾段与非 AVX2 构建共用同一标量 helper，lane/tail/标量三路数值一致。带 `extra_change`、气候适宜度或非线性生态动态的资源走标量精确路径；其他资源继续走原 SIMD 路径。数据保持 SoA、无 cell 间依赖和邻居 gather。
- **静态资源跳过**：运行期系数 `gen_*` / `decay_*` 全为 0 且 `extra_change` 全为 0 的资源是恒等更新（例如静态矿物储量），C++ pass 不再每日全图 loop 或 flush 这些 reserve slots；若外部系统写入 `extra_change`，该资源进入本 tick 热循环。可表示部分落入 reserve，低于 float32 ULP 的余量继续留在 extra slot 累计。
- **基准**：`tests/natural_resource_pass_bench.gd` 用 `bench_force_scalar` / `bench_force_seq` 两个旁路 knob（默认 false，生产不受影响）在同一构建上隔离两轴对比 scalar/SIMD × 单/多核，并先做四档等价性交叉校验。当前生产路径返回 `loop_layout=cell_range_fused_seq|cell_range_fused_mt`、`loop_dispatches=0|1`；2400-cell 移动图预期走 `cell_range_fused_seq`，大图才走 `cell_range_fused_mt`。

**新增一种资源 SOP**：component_ids.gd reserve/extra 常量 + map_data.gd reserve/extra 数组（`_alloc_soa` resize + `rebuild_soa_from_cells` 置 0）+ component_schema.gd 两行（`owner="economy.resources"`）→ 跑 codegen → 新建 .tres + 登记 `ResourceProfileRegistry._PROFILE_PATHS` → 重 build GDExtension。

风险：

- 储量字段进永久存档（`world.gd` 按 schema 序列化），新增资源后旧档加载缺该字段时按 0 处理 + bootstrap 不会回填运行期已存在的存档（仅生成期写一次）。
- `path=gdscript` 说明 native 未发布；检查 `fallback_reason`（missing_climate_slot / knob_array_size_mismatch / no_publishable_resource）。

## Native PopulationCohort / MarketStore

Goods 已退出 per-cell component schema。当前链路：

```text
EconomyDailySystem (SUS shell)
  -> DCWorldExt.run_economy_slice
  -> ECONOMY_GRAPH
  -> PopulationStore pages + MarketStore matrix
  -> fixed survival_required + need/wealth/environment demand + budget
  -> domestic trade settle / dispatch (ACTIVE only)
  -> bundle clear + one substitution fallback + merchant settlement
  -> demand EMA / next-day price
  -> structural ECB
  -> committed cell summary + audit report
```

生成期的 `MapGenerator._setup_economy_runtime()` 先把玩家与配置数量的外国编译为单个多国
CSR 包并 bootstrap country authority，再配置 economy；随后把每国 20 人聚落、首都创始家族及
具名业主代表声明聚合为一次人口/市场/建筑 bootstrap，并在此之前一次性调用
`capture_economy_trade_topology(neighbors, terrain, passable_lut, move_cost_lut, generation)`。
默认 ACTIVE 模式只有在 `trade_topology_ready=true` 后才继续注册 `economy_daily`。
显式测试经济夹具会先按可见资源生成候选建筑；collector 的 24 仅是资源支持上限，随后
`_balance_basic_capacity()` 以 `min(岗位容量, 净食物承载人数, 净衣着承载人数, 300)` 为每格目标
人口；商栈岗位包含在容量需求内。平衡器在每种已投放建筑至少保留一栋的条件下，只删除超过目标
所需的重复建筑，再由剩余岗位反推初始人口。贫瘠格可以为 0，资源丰富格最多为 300。

Market V2 固定一地块一市场。周期起点读取温度/湿度/积雪/天气 Q16 snapshot，
按 plan→need→variant→component CSR 从冻结状态计算 N 日连续财富、民族和环境需求；同一
variant 的 components 作为互补 bundle 清算，不同 variants 做一次替代 fallback。
主食、蛋白质、蔬果和衣着先从 `survival_household` 计算无财富/价格弹性的冻结下限；普通需求仍
使用原弹性核，实际生存品订单取两者最大值，自留和死亡复用该下限。所有业主还可按普通 desired quantity 与正常 variant 份额自用自产物资；复合 variant 按组件分别判定（自家产出的组件自留、未产出的走市场），自用计入实物收入和实际出库 EMA。
买方资金直接按商人人口进入 merchant cohorts，不存在 market cash。不同 market 可由
WorkerThreadPool 并行；结果按 market index 归并，和 scalar 顺序逐位一致。

成功 `aggregate_publish` 后存在一个独立的 debug-only CSV v23 尾部：`world_ext_economy.cpp`
先把 building resource delta 发布到 DataCore reserve slot，再由 `EconomyCsvRecorder` 线性复制
本次 committed 五表快照。两个预分配 buffer 按 `FREE→FILLING→READY→WRITING→FREE`
流转；主线程不编码文本、不调用 `FileAccess`，长期 worker 用 `std::to_chars` 和标准库文件流
分块写入。达到全局行数上限时仍在 epoch 边界停止；两个 buffer 同时占用时则等待 writer
释放一个 buffer，保留全部 committed epoch，并通过背压指标报告快进延迟。两种路径都不产生
部分 epoch，也不改变 ECONOMY_GRAPH cadence、audit、save 或 hash。

`projected_rows` 与批次填充使用相同的建筑行集合：已提交建筑、pending construction，以及
选中地块当前发布的逐投资候选诊断。投资诊断存在时，每个候选占一行并计入 epoch 原子行数，
因此不会因投影遗漏而触发 `projected_row_count_changed`。

录制范围在 start 时冻结：空 `cell_indices` 使用 `cell_stride`，显式 indices 则排序去重并覆盖
stride。单地块模式只为该 cell 预留 cohort/building/resource/market 行和贸易流 scratch；全局
summary 仍每个 commit 输出一行。切换地图选区不会改变正在进行的录制。

输入/输出、定点尺度、账本和存档详见：

- [Native Economy Runtime](./native-economy-runtime.md)
- [Domestic Trade Runtime](./domestic-trade-runtime.md)
- [综合满意度运行时](./satisfaction-runtime.md)
- [Economy Fixed Point / Ledger / Formula](./economy-fixed-point-ledger-formulas.md)
- [Economy Graph / Scheduling](./economy-graph-scheduling.md)
- [Economy Save / Migration / SOP](./economy-save-migration-sop.md)

household Market V2 热循环本身不包含生产、就业、工资、税或一般自然人口变化。生产/就业由集成的
BUILDING_GRAPH 在居民清算前处理，居民阶段只追加缺乏食品/气候衣着造成的确定性死亡；国内贸易由
同一 NativeEconomyRuntime 的独立 Trade V1 阶段处理。Trade V1 的 multi-target Dijkstra heap
由 native `TradePlanStore` 持有，可跨 slice 续跑，并以每片 256 次有效扩展的确定性配额推进。
外部系统
仍只能通过批量 ledger/stock command 供货或转账，不得直接写 MarketStore vector。自然资源
`cell.res_*` 仍由 `NaturalResourceDailySystem` 独立推进。

## Transpiration

主要入口：

- `simulation/biology/transpiration_pass.gd`
- `climate_daily_system.gd::_run_transpiration_pass_slice`
- `map_generator.gd::run_transpiration_pass_native`
- `DCWorldExt::run_transpiration_pass`

算法概要：

- 根据植被、水分、donor/outflow/self rate 计算水分再分配。
- C++ 部分负责主要 compute/apply。
- GDScript 负责 donor table、round state、dirty sync 和 fallback。

日志字段：

```text
transp/native breakdown source=current diagnostic_wall_ms=0.35 refresh_ms=... native_call_ms=... native_ms=0.029 native_compute_ms=... native_apply_ms=... native_flush_ms=... sync_total_ms=... sync_write_ms=... sync_mark_ms=... dirty_count=...
```

解释：

- `native_ms` / `native_compute_ms` 很低时，说明 C++ 算法本体不是瓶颈。
- `sync_total_ms`、`refresh_ms`、`sync_write_ms`、`sync_mark_ms` 变高时，问题在边界同步或 dirty。
- `largest=...transp/apply path=gdscript_sliced 28ms` 可能是旧窗口 spike，不一定代表当前 tick 仍在 GDScript compute。

风险：

- GDScript sliced apply 的旧路径仍可能进入统计窗口。
- 如果 C++ pass 已发布，caller 应避免重复 dense/indexed 写。

### Async parity（plan §async-stage-1，2026-06-14）

Stage 1 落地的异步 climate round 框架已经把 transpiration 移植成 pure
`std::vector` kernel（`pk_async_climate::_async_transp_kernel_pure`），
跑在长驻 worker thread 上，主线程只 kick + poll。算法本体逐行 1:1 镜像
`run_transpiration_pass`：

- 输入：`landform`(U8) / `vegetation`(U8) / `moisture`(F32) per cell + 静态
  `neighbor_indices`(I32) + `donor_table`(F32) + scalar `outflow_rate`/`self_rate`
- 输出：`moisture` per cell + `dirty_indices/values` 列表
- 误差：bit-equal（同样 float32 顺序计算，无 reduction reorder）

A-B 验证 hot key：在游戏运行时按 `B` 键触发
`MapGenerator.run_async_climate_round_bench("transp")`，会跑一次 sync
`run_transpiration_pass_native` 拿参考结果，然后跑 async path，对比 moisture
是否 bit-equal，print `[async/bench transp]` 报告（diff_count 应为 0）。

Stage 2（plan §async-stage-2，2026-06-14）扩展：
- pass_a pure kernel 已移植（`_async_pass_a_kernel_pure`，16 字段输出）
- pass_b pure kernel 已移植（`_async_pass_b_kernel_pure`，写 moisture + local_thermal_anomaly + 海冰反照率尾循环）
- ocean_water + ocean_land pure kernel 已移植（`_async_ocean_water_kernel_pure` / `_async_ocean_land_kernel_pure`，写 ocean_thermal_anomaly + work scratch buffer ocean_tta_inout）
- wind_air + wind_surface pure kernel 已移植（`_async_wind_air_kernel_pure` / `_async_wind_surface_kernel_pure`，wind_surface 是 climate round 唯一写 cell_temp 的 pass）
- sea_ice pure kernel 已移植（`_async_sea_ice_kernel_pure`，输出 sea_ice_frac + terrain + flip events list）
- kick `passes_mask` (int) 控制 worker 跑哪些 pass：bit 0=pass_a, 1=pass_b, 2=ocean_water, 3=ocean_land, 4=wind_air, 5=wind_surface, 6=sea_ice, 7=transp
- A-B 验证 hot key `V` 触发 pass_a bench（`run_async_climate_round_bench("pass_a")`）
- Stage 2 范围内每个 pass 单独验证 bit-equal；round 模式（mask=0xFF）的数据流
  整合在 Stage 3 处理（pass_a → transp 的 moisture 传递；ocean_water → ocean_land
  的 work.ocean_tta_inout 共享；wind_air → wind_surface 的 air_anom 传递）

Stage 1+2 完成范围：**全部 8 个 climate pass 都已实装 pure std::vector kernel**。

Stage 3（plan §async-stage-3，2026-06-14）GDScript orchestration 整合：
- `climate_daily_system.gd::run_slice` 顶部加 async 分支：`cp.use_climate_round_async=true` +
  `ext.has_method("async_climate_round_kick/poll")` 时走 worker 模式
- 状态机：`_round_active=false` → kick → `_async_round_kicked=true` → poll →
  完成 → `_finalize_round()` 走原逻辑（埋点 / breakdown / annual log）
- `_build_async_kick_input` 一次性 dump 全部 22 个 PackedArray 输入字段 + ~40 个 scalar
- `_handle_async_sea_ice_flips` 在 poll 完成时调 `map.mark_all_climate_dirty()`
  让 atlas pipeline 在下个 stride 看到 terrain 翻转
- Worker 内 round-internal data flow：每 pass 跑完后 `std::memcpy(in.field, out.field, n*sizeof(float))`
  让后续 pass 读到 fresh 值（pass_a 写 moisture/snow_cover/temp_baseline →
  pass_b 读；pass_b 写 moisture/local_thermal_anomaly → 后续读；ocean_water 写
  ocean_thermal_anomaly → ocean_land 读；wind_air 写 air_mass_temp_anomaly →
  wind_surface 读；wind_surface 写 cell_temp → sea_ice 读 cell_temperature_arr）

切换方式：把 ClimateProfile 资源里的 `use_climate_round_async` 翻到 true，restart
游戏即可。**dev 期建议先用 KEY_B / KEY_V 跑 bench 验证 bit-equal**，再翻开本 flag。

#### Stage 3 字段名修复（2026-06-14）

**关键教训：** `_build_async_kick_input` 里所有 `cp.xxx` 字段名必须与 sync 路径里
inline 构造的 knobs dict **逐字对照**——不能凭直觉命名。Stage 3 落地时发现一批
字段名拼错，导致 daily round 异步路径的输出偏离 sync 路径：

| 错误命名（已修） | 正确命名（sync 用） | 出现位置 |
|---|---|---|
| `cp.snow_cool` | `cp.snow_albedo_cooling` | pass_b |
| `cp.veg_cool` | `cp.vegetation_cooling` | pass_b |
| `cp.diurnal_amp` | `cp.landform_diurnal_amp` | pass_b |
| `cp.evap_gain` | `cp.evaporation_gain` | pass_b |
| `cp.rs_threshold/factor/lookback` | `cp.rain_shadow_*` | pass_b |
| `cp.t_freeze` | `cp.sea_ice_form_threshold` | pass_b |
| `cp.coupling_gain` | `cp.ocean_moisture_coupling_gain` | pass_b |
| `cp.coast_leak` | `_last_cfg.COASTAL_HEAT_LEAK`（**不在 cp**） | pass_b, ocean_land |
| `cp.sea_ice_k_freeze` | `cp.sea_ice_freeze_rate` | sea_ice |
| `cp.sea_ice_k_melt` | `cp.sea_ice_melt_rate` | sea_ice |
| `cp.sea_ice_t_form` | `cp.sea_ice_form_threshold` | sea_ice |
| `cp.sea_ice_t_melt` | `cp.sea_ice_melt_threshold` | sea_ice |
| `cp.sea_ice_threshold` | `cp.sea_ice_terrain_threshold` | sea_ice |
| `cp.sea_ice_hysteresis` | `cp.sea_ice_terrain_hysteresis` | sea_ice |
| `_last_cfg.WIND_HEAT_ADVECT_STEPS` | `_last_cfg.OCEAN_HEAT_ADVECT_STEPS` | ocean_water |
| 缺少 | `cp.sea_ice_neighbor_contagion` | sea_ice |
| 缺少 | `cp.sea_ice_solar_gate_enabled` | sea_ice |
| 缺少 | `cp.sea_ice_freeze_insol_low/high` | sea_ice |
| 缺少 | `cp.sea_ice_solar_melt_start/gain` | sea_ice |
| 缺少 | `cp.sea_ice_daily_delta_cap` / `cp.sea_ice_edge_mix_rate` | sea_ice |
| 缺少 | `_last_cfg.OCEAN_CURRENT_ICE_DELAY` | sea_ice |
| 缺少 | `_last_cfg.enable_ocean_heat_transport` | sea_ice |
| 缺少 | `generator._consume_sea_ice_dt_days()` | sea_ice（必须 mirror sync 的 stride 补偿） |
| 缺少 | TTA 4 个 scalar（source_cap/blend_rate/decay_rate/zero_current_decay） | ocean_water/ocean_land |
| 缺少 | climate_anomaly 阈值 shift（sea_ice t_form/t_melt） | sea_ice |
| 缺少 | `cp.sea_ice_albedo_cooling` + `sea_ice_frac` | pass_b |
| 缺少 | `cp.snowpack_cover_low/full` | pass_b |
| 缺少 | `cp.enable_wind_heat_transport` → `passes_mask` bit 4/5 gate | wind_air/wind_surface |

**当前约束（2026-06-27）**：`thermal_inertia_*`、`thermal_daily_delta_cap`、
`snowpack_cover_*`、`insol_dev_*` 已经是 Pass-A sync/native daily/async 的显式
knob，必须从 `ClimateProfile` 通过 `_build_native_daily_climate_pass_a_struct` 与
`_build_async_kick_input` 一致打包。不要再回到早期“C++ 内部默认值”为权威的旧契约。

bench helper（`run_async_climate_round_bench` in `map_generator.gd`）跟实际
`_build_async_kick_input` 共享同一份契约：bench 与生产 async 都应使用同一批
`ClimateProfile`/`MapConfig` scalar；任何字段新增或改名都要同时更新 sync knobs、
async kick input、native daily bundle/patch 和文档表。

bench 互斥保护：`run_async_climate_round_bench` 入口临时关 `use_climate_round_async`
flag，bench 完成后恢复——避免 daily round async 路径跟 bench 都用同一个 global
worker singleton 互相污染（`worker_compute_us=1700` 而非 ≈1400 即是症状）。

#### Stage 3 sea_ice independent job 互斥（2026-06-14）

SUS scheduler 注册了 `sea_ice_daily` 独立 job（`SeaIceDailySystem`，priority=115），
跟 `refresh_climate_daily` 平行跑。它调 `generator.run_climate_pass_slice("sea_ice")`
路由到 sync `_apply_sea_ice_daily_pass`。

`use_climate_round_async=true` 时 worker 内部 sea_ice pass 也跑——**两边同时存在
就会**：
- 每 tick 调两次 `_consume_sea_ice_dt_days()`，第二次拿到的 dt_days 偏移（已实测
  `[sea_ice/dt] call#2 ... call#2` 同 tick 出现）。
- terrain 翻转两遍——sync 翻一次写 `_slots[cell_terrain]`，async worker 也翻一次写
  output 然后 poll 时再写 slot，结果取决于谁先 mark dirty。

解决：`SeaIceDailySystem::_enabled_from_profile` 检查 `cp.use_climate_round_async`，
true 时 return false（job 整个 short-circuit）。回退路径（async flag false）走原
独立 job。

#### Stage 3 真异步修复（2026-06-14 真机验证后）

桌面 desktop 跑出来 SUS budget `largest=refresh_climate_daily/async_round_done/pass_count=8`
12ms 看起来好；移动端真机（Adreno 830）跑出来 `34ms`，**比 sync 旧路径还慢**。

**根因：** SUS scheduler 在同 tick 内**反复调 `run_slice` 直到 done=true 或 budget exhausted**
（`sus_scheduler_ext.cpp:558` 的 `while(true)` 循环）。

之前 async 路径 kick 完报 `done=false progress_ratio=0.0`，下一秒 SUS 立刻 re-entry
调 `run_slice` → 进入 poll 分支 → worker 还在跑 → `poll_result.is_empty()` →
再 return partial → SUS 又 re-entry → ... 直到 worker 完成 poll 拿到结果。

效果是**主线程 busy-wait 在一个 SUS slice 里 30+ms**。worker 跑得快，但主线程跟它
绑在同一 SUS tick 里转完，atlas / weather / ocean 完全拿不到 budget → 视觉冻结。

修复：kick 完返回 `done=true progress_ratio=1.0`，让 SUS **不**同 tick re-entry。
下一 tick `should_run` 因 `_round_active=true` 仍返回 true，那时 worker 已经在后台
跑完，poll 直接拿结果。Worker thread 才真的 **off-thread** 跟主线程并行。

代价：climate round 跨 2-3 个 tick（kick → idle → poll），每 tick 占主线程 ~0.5ms。
实际 climate 视觉延迟从"每秒一轮"变成"每 2-3 秒一轮"——可接受，因 climate 状态本身
是 game-day 量级，2-3 tick 不可见。

## Sea ice daily

主要入口：

- `simulation/systems/sea_ice_daily_system.gd`
- `simulation/sea_ice/daily_pass.gd`
- `map_generator.gd` sea ice helper
- `DCWorldExt` sea ice pass

算法概要：

- 根据温度、水体、纬度/季节、邻域和阈值更新 `sea_ice_frac`。
- 可触发 terrain flip 或 ice bake。
- 结果影响 climate、render atlas 和 ocean physical mask。
- Earth-like 默认值降低 `sea_ice_freeze_rate` / `sea_ice_neighbor_contagion`，
  同时提高太阳融化响应并收紧 `sea_ice_daily_delta_cap`，用来减弱暖季残冰和
  海冰边界的突变扩散；这些都是 `ClimateProfile` profile knob。
- 气候自然性修复（2026-06-27）：默认 `sea_ice_terrain_threshold=0.72`、
  `sea_ice_terrain_hysteresis=0.18`、`sea_ice_daily_delta_cap=0.070`，并新增
  `sea_ice_edge_mix_rate`。daily pass 会先复制上一日 `sea_ice_frac` 快照，冷邻居判定和
  边缘混合都读这份快照；混合只在水域非湖泊邻域、且本格或邻居已有少量海冰时把
  `new_frac` 轻微拉向邻域平均，避免向赤道或湖泊扩散误冰。
- 坐标契约：`ny=0` 是视觉北极、`ny=1` 是视觉南极；`lat_signed=(ny-0.5)*2`
  正值表示南半球。`dc_insolation_now` / `DCClimateMath.compute_daily_insolation`
  按这个契约计算，因此北半球 6-7 月日照高、南半球 1 月日照高。若 CSV 中看似南北反相，
  先确认分析脚本是否把 `cell_lat_norm_arr > 0.5` 误当北半球。
- `dt_days` 是 pass 调用间隔补偿。legacy `sea_ice_daily`、debug/full-run helper 和
  native daily sliced ACTIVE 都允许最多 30 天补偿。原因是移动端或大地图上
  `native_daily_sim` 可能被 `frame_budget_exhausted` 拖过多个 game day；如果 sea-ice
  节点仍压到 1 天，`sea_ice_frac` 会按真实日历显著慢跑。若 CSV 中看到
  `sea_ice_frac` 只在十几天一次的 `sea_ice` 节点成批台阶变化，优先检查 native daily
  transaction budget / `max_slices_per_tick` 和 `skipped[frame_budget_exhausted]`，不要先调冻结或融化公式。
- 太阳融化项会按当前 `sea_ice_frac` 做厚冰/高反照率保护：低浓度薄冰仍可被夏季日照快速清退，
  厚冰仍受保护但最小太阳曝光由 `sea_ice_min_thick_ice_solar_exposure` 控制，默认 32%。
  2026-06-27 `tile_data_record_20260627_201214.csv` 显示 25% shielding、0.03 反照率冷却和
  `thermal_inertia_water=0.025` 仍让 66-80° 边缘冰峰值拖到春季。新默认配合
  `sea_ice_freeze_insol_low/high=0.22/0.45`、`sea_ice_solar_melt_start=0.28`、
  `sea_ice_daily_delta_cap=0.070` 与 `thermal_inertia_water=0.045`，目标是让季节性
  边缘冰更贴近日照低谷后不久达峰、夏季高日照期更快退缩，同时保留极点附近多年冰核心。
- **海冰冻融重标定（2026-06-28，`tile_data_record_20260628_145729.csv`）**：实测冷水最暗桶
  `mean_ice` 仅 0.49 且全盆地在 0↔0.98 双稳跳变。诊断为冻融严重不对称 + 滞回带过窄：旧
  `sea_ice_freeze_rate=0.40` ≪ `sea_ice_melt_rate=1.45`，且 `form=0.06`/`melt=0.11` 仅留 0.05 中性带。
  新默认 `sea_ice_freeze_rate=1.0`、`sea_ice_melt_rate=0.95`、`sea_ice_form_threshold=0.14`、
  `sea_ice_melt_threshold=0.22`（中性带拉到 [0.14,0.22]）、`sea_ice_solar_melt_gain=0.90`，
  目标"极地核心常年饱和(>0.9)+海冰边缘季节进退"。dt>1 直测探针
  [`native_dt_compensation_probe_test.gd`](../../Project/project-keynes/tests/native_dt_compensation_probe_test.gd)
  验证 dt=9 下冷暗极地数次 pass 内饱和到 1.0、单 pass `|Δ|≤daily_delta_cap·dt_days`、暖水(temp=0.5)
  携冰 0.80→0.17 不结冰。子步积分(B2)保留不动。
- **海冰阈值相位再标定（2026-06-28 夜，`tile_data_record_20260628_164054.csv`）**：上轮重标定
  把范围/双稳修好后，按季节相位折叠极地水格实测：相位滞后本身≈现实（最冷→冰峰 ~3 个月、
  最暖→冰谷 ~2.5 个月，同真实北极 3 月冰峰 / 9 月冰谷），但**极地夏季气温天花板仅 0.135(北)/0.170(南)
  远低于 `t_melt=0.22`** → 热融化项 `k_melt·(temp−t_melt)` 全年恒为 0，夏季融化只剩缓慢太阳消融
  → 融化偏晚、不彻底（南极只融到 0.34，现实近乎融光）。修法是把阈值下移到极地夏季气温区间：
  `sea_ice_form_threshold 0.14→0.08`、`sea_ice_melt_threshold 0.22→0.13`（保留 0.05 迟滞窗
  [0.08,0.13] 防双稳）。冬季 `temp≈0` 仍触 `freeze drive≈0.07/天 cap`，极核照常饱和（探针冷极地
  仍 6×dt=9 内到 1.0）；夏季 `temp` 可跨过 melt 阈使热融化生效（探针暖水 0.80→0.17 melt 更彻底）。
  纯 profile knob、不重编 DLL；待 fresh 录制验证南极夏季退冰是否到位、冰缘是否稳定。
- sea-ice 的有效温度读 wind-surface 发布后的 `cell_temp`。由于该温度已经包含
  `cell_ocean_thermal_anomaly`，`temperature_transport_anomaly` 的正向暖流延迟只使用
  `max(0, TTA - max(0, ocean_thermal_anomaly))` 的剩余部分，避免把同一份 ocean heat
  在温度合成和海冰判定中重复计算。
- native daily ACTIVE 的 sea-ice 节点仍位于 wind-surface 之后、climate finalizer
  之前，保持旧 sliced round 顺序。round 完成时 `MapGenerator` 会执行 finalizer，
  用 round-start `temp` / `temperature_transport_anomaly` snapshot 应用
  `thermal_daily_delta_cap` 与 `temperature_transport_anomaly_daily_cap`，并把
  `thermal_finalizer_applied=true` 写入 climate/native breakdown。CSV 中若极地海水
  长期停在 `temp_baseline + 0.15` 左右且 `climate_thermal_finalizer_applied=false`，
  优先检查 native daily ACTIVE 是否漏接 finalizer，而不是先调海冰冻结阈值或热输运系数。

输出：

- `cell_sea_ice_frac`
- terrain/water mask 相关字段，视 `apply_terrain_flips` 而定。

风险：

- C++ 写了 `sea_ice_frac` 但 terrain flip 没同步，会让后续 pass 对 water/ice 判断不一致。
- atlas upload 是另一条 GPU 路径，海冰计算快不代表海冰可视化立即完成。
- CSV 中若看到 `sea_ice_frac` 在少数 tick 里成片从 `1.0` 跳到约 `0.4/0.2`，
  且 `temp` / `temperature_transport_anomaly` 同 tick 未突变，优先检查 native daily
  slice cadence 和 `dt_days` 是否被 graph round 间隔放大，而不是先调低融化率。

## Weather field / fronts

主要入口：

- `weather/weather_system.gd`
- `weather/field_solver.gd`
- `simulation/sus/jobs/weather_refresh_job.gd`
- `simulation/systems/weather_system.gd`
- `DCWorldExt::run_weather_field_solve_pass`
- weather distribute / summary / stage-b native helpers

### 气候真实度修复 (climate-realism Stage 0–4, 2026-06-23)

针对离线 tile_data 复盘暴露的六个问题（海洋几乎不下雨、纬向只有单一赤道峰、HEATWAVE
死类型、单一 ITCZ 雨带季节摆动无温带过境系统、雪盖先于降雪）做的一组镜像改动。**天气物理双份
镜像铁律照旧**：`field_solver.gd` 与 `world_ext.cpp::run_weather_field_solve_pass` 改动必须逐项同步，
改后跑 `set_field_verify_mode(true)` 对账。

- **Stage 0（纯旋钮，无需重编）**：`ClimateProfile.weather_ocean_precip_suppression` 0.95→0.60、
  `weather_frontogenesis_gain` 0.42→0.70。两者经 knobs dict 流向 C++、经 `configure_weather_field`
  流向 GDScript member，单点修改两侧自动同步。
- **Stage 1（keystone，重编）**：新增 Hadley/Ferrel 垂直运动项 `omega`。`field_solver.begin_slice`
  每 tick 按 zonal-max 基准温度算出「热赤道」纬度 `lat_te_norm`（24 桶 argmax + 抛物线细化），
  存 `_field_slice_lat_te_norm`，经**新 knob `weather_lat_te_norm`** 传给 C++（缺省 0.5）。hot loop
  里按本格纬度距热赤道度数 `dlat` 构造：ITCZ(|dlat|<~12°)/风暴轴(|dlat|~48-62°)上升带增雨，
  副热带(|dlat|~22-34°)下沉带抑制凝结+降水；`omega_ascent` 并入 `ocean_drive` 让海上 ITCZ 释放
  降水抑制。键在「热赤道」相对纬度→随季迁移、不产生沿绝对纬线的直线条带。
- **Stage 2（重编）**：`humidity_front_gate` 下限 0.38→0.25（冷湿锋面也能成雨→温带过境雨团/
  冷区降雪）；`BLIZZARD_WIND_GATE` 1.15→1.0（过渡带冷降水不再被误判冷雨）。
- **Stage 3（重编）**：HEATWAVE 重定义。旧判据 `hot(temp>0.64) + effective_cloud<0.30` 在本模型
  永不满足（最热区=赤道湿区恒有云），实测 HEATWAVE 恒为 0。改气象学定义：暖季陆地 + 显著正
  温度距平(`temp_anom>0.06`，旋钮 `HEATWAVE_ANOM_GATE`) + 少雨；并把 DROUGHT 判据提到 HEATWAVE
  之前，bone-dry 强距平先归旱灾、其余暖距平少雨格归热浪。删除已无用的 `hot` 局部。
- **Stage 4（重编）**：`_snowline_floor_for_cell` / C++ 同名 lambda 的返回值用 `smoothstep(0.30,0.80)`
  门控——雪线 floor 只为深冻区自动铺白，雪线边缘交给 snowpack-from-snowfall，使降雪可见地先于
  积雪。climate-daily pass（`world_ext` ~2490 / `map_generator.gd:8533`）本就是纯 snowpack 派生、
  无 floor，自动继承。
- **Stage 5（已撤销）**：曾加"两支东传经向行波"硬调制 `precip_target` 来破带。**已删除**——它是 prescribed 确定性
  波，非涌现（用户明确要求自发涌现），且实测使 largest-blob 0.47→0.91 更糟。相关 knob `weather_solve_tick` 一并移除。
- **Stage 6（重编，第三轮 2026-06-23，替代 Stage 5）**：湿度充放电 recharge-discharge——**真涌现**。深查
  （tile_data_record_20260623_133100，633 ticks）确认雨团不消散/只往复、海上不生成的根因是 **湿度系统没有放电**：
  `corr(precip, Δvapor)≈+0.04`（下雨完全不消耗水汽）、`precip` 时间自相关 lag20=0.74（雨团极持久），且现有
  `post_rain_subsidence` 被 `×(1-smoothstep(dynamic_forcing))` 在辐合带豁免（雨带处自抑=0）。**另诊断**：环流是
  纯诊断的（`solve_slp_field`=纬度模板+温度+海陆+冰雪，wind=风带模板+地转 `-∇slp`，无预报量），故无自带行波。
  修法两点（双侧镜像）：(a) 降水"放电"——精确降水格 `vapor_after_precip -= precip × VAPOR_DISCHARGE`(0.65)，气柱
  下雨失水→RH 降→自发停雨→需蒸发/平流充电恢复；(b) `post_rain_subsidence` 强强迫豁免改留 45% 残余
  （`×(1-0.55·smoothstep)`），辐合带雨团下完也进不应期。**涌现结果**：雨团有 生成-盛-消 生命周期、活动中心沿
  上风新鲜水汽自发移动、海面快充电自生成系统。`VAPOR_DISCHARGE` 为关键旋钮（过大全局抽干、过小不消散），需用
  新录制 + `tmp/wx_emerge.py`（corr(precip,Δvapor) 应转负、precip 自相关该降、海上 onset 该升）标定。
- **Stage 6b（重编，2026-06-23）**：实测 Stage 6 把雨段中位 37 天→2 天、largest-blob 0.91→0.28，但 34% 雨段仍≥7 天
  （强辐合/地形区平流补给 > 均匀放电），且海上 onset 比掉到 0.04。两点定点修正：(a) **持续降水放电翻倍**
  `discharge *= 1 + DISCHARGE_SUSTAIN(1.3)·smoothstep(0.04,0.10,prev_precip)`——`prev_precip` 高(连下多久)才放大，
  专砍长尾、不动新生短雨段；(b) `weather_ocean_precip_suppression` 0.60→0.45（放电已自限海上过湿，放开让海面
  有足够降水形成充放电系统，修海上不生成）。`tmp/wx_persist.py` 量化雨段长度分布(ticks→天气日，按 commit 节律 ÷2)。
- **Stage 6c（重编，2026-06-23）**：实测 Stage 6b 海上 onset 0.04→0.06、share 5.2%→9.8%、largest-blob 0.28→0.16，
  但 ≥7 天长尾仍 34%、且偏干(precip 0.0111→0.0080)。诊断定论：**长尾格是强迫主导(常驻辐合/地形抬升)而非水汽
  主导**——抽干水汽只饿死弱短系统(全局变干)，强迫格仍持续成雨。改用**对流抑制记忆**(真·充放电极限环)：
  solver-resident `_convective_inhib[i]`(per-cell，跨 tick 持久，经 knob `convective_inhib` 以 in/out 传 C++，CoW 回传
  仿 `out_*`)随降水累积(`+precip·INHIB_GAIN 1.6`)、缓慢衰减(`×INHIB_DECAY 0.82`，恢复≈5-6步)，按 `INHIB_STRENGTH 0.9`
  压低 precip——**与强迫/水汽无关，定点封顶长尾，且只作用于刚下过雨的格(干区 inhib=0，不会全局压垮)**。同时把
  `VAPOR_DISCHARGE` 0.65→0.45、`DISCHARGE_SUSTAIN`→0（持久控制改由 inhib 承担，缓解过干）。
  **注意**：inhib 经 const Dictionary knob 的 CoW 回传未离线验证；最坏情形=回传失败→inhib 恒 0→无效(但无回退，
  放电调小仍修过干)。需新录制 + `tmp/wx_persist.py` 验证 ≥7 天比例下降、precip 回升、海上 onset 比维持。
- **Stage 6c-fix + 6d（重编，2026-06-23）**：fresh 录制(161718)证实上面的最坏情形成真——**inhib 的 knob CoW 回传
  失败、抑制 no-op**（STORM 雨段中位 8→10 天、雨段 ≥7 天 58%、比放电调小前更持久）。改法：**对流抑制记忆改存为
  `DCWorldExt::_wx_conv_inhib`(std::vector<float> ext 成员)**——C++ 端权威路径直接读写、跨 tick/slice 持久、
  无边界穿越，保证生效；尺寸变化(换地图)清零。GDScript fallback 仍用 `_convective_inhib` 成员(同进程无边界)。
  knob `convective_inhib` 及其回传已删。**Stage 6d**：修首帧暴雨暴雪——`begin_slice` 未初始化格 `prev_vapor`
  由 `moisture`(满饱和)改 `0.15×moisture`(稳态量级)，消除 spin-up(实测首 tick 86%降水/21%暴雪→8.7%/0%)；纯
  GDScript、不重编。待 fresh 录制验证 STORM/雨段中位是否回落到 1-3 天。
- **Stage 6e（重编，2026-06-23）**：fresh 录制(163635)证实 C++ 成员 round-trip **成功**（海上降水占比 12%→28%、
  onset 比 0.16→0.70），**但持久性反而更糟**（雨段中位 9→16.5 天、≥7 天 58%→78%）。根因=抑制记忆的**设计**错：
  线性反馈 `precip×(1-inhib·k)` 只把降水压到**稳态弱雨**(~0.05>湿阈 0.02)→雨永不停、只是变弱→雨段更长。
  改为**双稳弛豫振子**(真·充放电极限环)：累积抑制过 `INHIB_TRIGGER(0.5)` → 最终降水(EMA 后、分类前)砍到
  ×0.05 → 转干转晴(CLEAR) → inhib 由被压制的降水衰减落回 → 释放再积累。无中间稳态→真正 开/关 循环→封顶雨段。
  旋钮 `INHIB_TRIGGER/STRENGTH(0.95)/GAIN(2.5)/DECAY(0.85)`：GAIN 定积累到触发的步数(≈雨段长)、DECAY 定不应期长度。
  需 fresh 录制验证雨段中位是否回落、是否过碎/过干。
- **Stage 6f（重编，2026-06-23，6e 调参）**：6e(GAIN2.5/DECAY0.85/STR0.95)实测**矫枉过正**——持久性修好(雨段中位
  1天/≥7天0.8%)但降水崩塌(meanP 0.0103→0.0029、CLEAR 97%、内陆/MONSOON 几乎消失)。根因：GAIN 太高→inhib 3 tick
  就过阈、DECAY 太慢→不应期没清空就重触发→降水永远被砍在 ~0、来不及涨到 target。调为 GAIN 1.2/DECAY 0.78/
  STR 0.90：① 仅"持续较重降水"(稳态 inhib=precip·gain/(1-decay)>0.5，约 precip≳0.065)才触发→封长尾；
  ② 弱雨/内陆(precip≲0.06)稳态 inhib<0.5 **永不触发**→照常下雨；③ 不应期更快清空→降水更快回归。
  目标 meanP 回到 ~0.012-0.018、CLEAR 回到 ~88-90%、内陆/类型多样恢复，同时雨段中位保持 ~2-3 天。
- **Stage 6g（重编，2026-06-23）**：6f(GAIN1.2)恢复了雨量/多样/内陆(meanP 0.0094、CLEAR 85%)，**但长尾回来了**
  (≥7 天 18%)。诊断定论：长尾格 precip p50=**0.065（中等雨）**，magnitude 版稳态 inhib≈0.35<阈→**永不触发**→
  中等雨永续。**magnitude 路线本质两难**：调高 GAIN 封中等雨就掐死全部降水(6e)、调低就留中等长尾(6f)。
  改为**按【时长】充放电(强度无关)**：`inhib∈[0,1)` 充能期，每个降水 tick `+0.18`(干 tick `×0.88` 泄放)，连下 ~6 tick
  充满 → 跳 `2.0` 进不应期；不应期 `inhib≥1` 把 precip ×0.08(转干判 CLEAR)、每 tick `-0.55`，落回 <1 清零重启。
  **任意强度连下 ~6 tick 都封顶**(中等雨长尾也治)、**充能期满强度照下**(不伤雨量/多样)。物理=对流耗尽本地不稳定度
  需特征"时长"。旋钮 `INHIB_CHARGE`(雨段长)、`INHIB_REFRAC`(不应期长)、`INHIB_STRENGTH`。需 fresh 录制验证
  ≥7 天 → ~0、meanP/CLEAR/内陆/多样 保持、雨段中位 ~3 天且不过碎。
- **Stage 6h（重编+旋钮，2026-06-23）**：6g 后实测 **STORM/RAIN=1.32**(雷暴比普通雨还多)、且单格在 RAIN↔STORM
  逐 tick 横跳(1838 次/7% 的切换)。双根因：① STORM 门 `instability>0.50` 被 **47% 的 RAIN 格**满足→STORM≈RAIN
  数量且二者在 0.50 阈两侧密集重叠→横跳；② **`weather_transition_enabled` 竟是 false**——离散类型稳定化(注释称
  可把 RAIN↔STORM 横跳 24%→9%)一直没开。修：① STORM 门提到 `instability>0.70`(RAIN p90=0.76→仅最强对流)、
  `precip>0.065`(暖洋核心 0.64/0.060)→雷暴变少数强对流、边界移出密集区；② `weather_transition_enabled`→true
  (⌈1/0.35⌉≈3 步确认才切换类型，吸收 1-tick 横跳)。需 fresh 录制验证 STORM/RAIN<<1、RAIN↔STORM 横跳骤降。
- **HEATWAVE 仍未解决（实测 0）**：诊断证实**运行期 `target_type=6` 恒为 0**——分类器运行期收到的 `temp_anom`
  （knobs `temp_anomaly`）与录制 `temp_anomaly_arr` 不一致（疑似 `cell_temp_anomaly` 由 climate-daily 在 weather
  之后/异步更新，或 `climate_anomaly` 标量冷偏压低 `temp`）。已改判为 STORM/MONSOON 同款可达的
  `warm(temp>0.55)+晴(eff_cloud<0.24)+干(vapor<0.12)+少雨`，去掉不可达的 `temp_anom`。**根因需运行期插桩确认**。
- **未做**：问题④（次要）未改；阈值常量均为离线估值。**可选更深一步**：若充放电仍不够"会移动"，给环流加预报性
  （简化涡度/斜压扰动），让风场自身涌现行波——但属大改，建议先验证 Stage 6。
- **降水季节性多样化（climate-zone-fix P3，2026-06-28，导出旋钮 + 保守 rebalance）**：目标降低暖季对流主导（~76% 降水来自 `temp>0.48` 大陆对流）、增强冷季锋面/层状，使"雨热不同期/全年均匀"气候态（配合 P2 的 Cfb）可形成。把四个原 C++-only/`constexpr` 降水参数导出为 `ClimateProfile` 旋钮并双侧接线（C++ `world_ext_weather.cpp` 读 `knobs` ↔ GDScript `field_solver.gd` 读 `weather_system` 成员，`weather_system._sync_profile_weather_knobs` 从 profile 同步、`_build_field_knobs` 经 dynamic+fallback 两路注入）：① `weather_field_thermal_conv_precip`(暖季对流降水权重，0.30→默认 0.24)；② `weather_field_stratiform_gain`(冷季层状降水增益，1.0→1.15)；③ `weather_field_omega_ascent_gain`(`OMEGA_ASCENT_GAIN` 由 `constexpr 0.40`→knob，默认 0.34)；④ `weather_cool_season_vapor_floor`(冷季蒸发/水汽地板，`surface_vapor_source` 的 `temp_evap=max(floor, smoothstep(...))`，0→0.10，给冷季 stratiform 基础水汽)。同步修 `field_solver.gd` 的 `PRECIP_BASE_FRAC` 0.12↔C++ 0.08 漂移。A/B 验证（`tests/tmp_wx_eval.gd` 加 `p3off=1` 还原历史默认对照）：暖地 r(precip,temp) 0.286→0.258（对流偏置降）、never-change 59.1→57.8%、frozen 36.3→35.1% 均改善。**夏雨中位回落到≈0.5 + 出现 winter-wet 尾部需用户多轮 CSV 标定**（water budget 易级联）跑 `tmp/wx_koppen.py`+`tmp/wx_phase.py` 复核。
- **非降水云量保留（2026-06-29）**：`tile_data_record_20260629_201247.csv` 显示 `weather_cloud_arr` 中位≈0.026、`cloud>0.14` 仅≈8.5%，且 90%+ 样本为晴且无降水；根因是 `weather_field_cloud_reevap=0.38` 与低 `clear_cap≈0.04` 把静稳非降水格云水清得过快。C++ 权威路径与 `field_solver.gd` fallback 同步改为：`weather_field_cloud_reevap` 默认 0.28，非降水清云 cap 提到 `0.065 + dynamic_forcing*0.12`（低动力海面 cap `0.070 + ocean_drive*0.18`），并在 `quiet_non_precip` 下加入 RH 驱动的 fair-weather cloud floor（`smoothstep(0.34,0.56,RH)`，最高约 0.12）。该 floor 只抬 `cloud` 可视/分类输入，不直接抬 `precip`，目标是恢复层云/薄积云而不回到弥漫弱雨。
- **天气可视权重校准（2026-06-29）**：`tile_data_record_20260629_213350.csv` 复核显示原始 `cloud>0.14` 约 8.6%，但 shader 映射后 `w.cloud>0.14` 仅约 4.4%；同时 cell 雨幕曾位于云层之上，违反“云盖住雨”的层级契约。`weather_overlay.gdshader` 将 cloud 映射从 `cloud/0.72 + smoothstep(0.14,0.72)` 调为 `cloud/0.46 + smoothstep(0.07,0.46)`，让非降水薄云进入可见区；`WeatherLayer` 将 cell curtain 放到云层下方。该组只改视觉层级/云显形，不改变雨幕 alpha、`weather_precip`、distribute 或 hydrology。

Stage-A 链路：

1. begin：准备 field snapshot、fronts、cell budget。
2. solve：计算 vapor/cloud/precip/instability/convergence 等 field。
3. commit：写回 DataCore/HexCell/weather arrays。
4. summary：把 cell field 汇总成 fronts。

Stage-B 链路：

- 根据 field/fronts 更新 albedo、vegetation dynamics、feedback、snow/soil/water balance 等。
- 雪盖入口同时受 `snowpack_*`、`snowline_*` 和
  `ClimateProfile.snow_accum_days_req` 控制。`MapGenerator` 将该值注入
  `WeatherSystem.configure_weather_field()`，GDScript fallback、resident knobs 和
  `DCWorldExt::run_weather_distribute_pass` 的 `snow_accum_days_req` 必须保持同源。
- 陆地雪盖 / 雪线 floor / 洪涝覆盖物的 water gate 必须同时读取
  `LandformType.is_water(cell.landform)` 和 terrain water 语义
  (`OCEAN/COAST/LAKE/REEF/SEA_ICE/KELP`)。原因是 sea-ice daily pass 会把
  `cell_terrain` 翻成 `SEA_ICE`，而 landform 可能在同一 tick 或 fallback
  路径中滞后；此时 `SEA_ICE`/`LAKE` 仍必须按水体处理，不得获得陆地
  snowpack、snow_cover 或 FLOODING cover。C++ `run_weather_distribute_pass`
  必须 mirror 这个组合谓词。
- `cell_weather_precip` 是天气场诊断/可视化量，不等同于水文有效降水。
  `run_weather_field_solve_pass` 在最终分类后会把非降水天气
  (`CLEAR/FOG/HEATWAVE/DROUGHT`) 的残余灰区 `precip` 回流到 vapor 并写 0；
  `run_weather_distribute_pass` 与 `run_runtime_hydrology_pass` 仍必须再按天气类型
  gate 一次，只允许 `RAIN/STORM/BLIZZARD/MONSOON` 的 precip 进入 snowpack、
  water_balance、soil_moisture、runoff/river discharge。这个双保险用于防止旧提交、
  fallback 或旧 DLL 中的隐藏小雨继续污染水文和植被反馈。

Merged native 路径：

- `weather_refresh_job.gd` 中存在 merged transaction gate。
- 当前默认关闭，必须由 `MapGenerator.weather_native_daily_available()` 显式放行。
  原因是可见天气权威仍是 staged
  `begin_weather_field_solve -> run_weather_field_solve_slice ->
  commit_weather_field_solve -> stage_b`。单纯探测到
  `run_weather_refresh_daily_pass` 存在不能证明它已经把 staged `out_*`
  buffers 发布到 `MapData.weather_*_arr`。
- 若未来重新打开 merged/native-daily weather，`DCWorldExt::run_weather_refresh_daily_pass`
  必须在 `run_weather_field_solve_pass` 后调用
  `run_weather_field_commit_pass`。因为天气 solve 在 combined path 中使用
  `out_vapor/out_cloud/out_precip/...` staging buffers；distribute、summary
  和 stage-b 读取的是 weather slots/MapData，可见发布缺失会表现为
  cadence 前进但 `weather_field_init_arr` 和全部 weather field 数组为 0。
- fallback 时回到 begin/solve/commit/stage-b staged path。

输出：

- weather cell components：vapor、cloud、precip、instability、intensity 等。
- environment components：snow_cover、snowpack、soil moisture、water balance 等。
- fronts packed snapshot / object compatibility layer。
- transition components：`weather_type`、`weather_prev_type`、
  `weather_target_type`、`weather_transition_alpha`。当 alpha 到达 1.0 时，
  native 与 fallback commit 都必须提交为稳定态：`type=target`、
  `prev_type=target`、`alpha=0`，避免 CSV 中长期出现 `alpha=1` 或
  `prev_type` 滞后造成的假 transition。稳定格（`prev_type == target_type`
  或 display 已等于 target）不得继续累加 alpha；否则 CSV 会把没有实际天气
  切换的格子统计为 transitioning。
- **过渡机 dt-aware（2026-06-28，`tile_data_record_20260628_145729.csv`）**：旧实现 alpha 每次
  求解固定 `+weather_transition_alpha_rate`（0.35），与 `dt_days` 无关。加速档下每次求解推进 ~9 天，
  过渡需 ~4 次求解≈36 天才完成，致短暂强天气（实测分类器产出 STORM 602/FOG 13/MONSOON 94 例）
  永远累不满 alpha、display 全被压成 prev(CLEAR)，且 72.6% 格永不换型。修复：新增 knob
  `weather_transition_dt_days`（缺省 1.0），native（`run_weather_field_solve_pass` /
  `run_weather_field_commit_pass`）与 GDScript 镜像（`field_solver.gd`）都把 alpha 累加与目标切换的
  起步值改为 `rate·dt_days`，使 `dt≥~1/rate`（≈3）时当次求解即切换、`dt=1` 仍保留 ~3 次求解平滑。
  dt 来源 `map_generator._consume_weather_dt_days()`（独立游标、同-tick 缓存、clamp[0,30]），
  在 unified native daily 路径经 `WeatherSystem.set_weather_transition_dt_days()` 注入三处 weather knobs。
  probe 见 `native_dt_compensation_probe_test.gd`（dt=3/9 单次切换、dt=1≥3 次）。

Weather commit publish guard (2026-06-22):

- `DCWorldExt::run_weather_field_commit_pass` remains the native authority for
  full-field weather commit when the solver produced `next_*` buffers. After a
  native commit, `field_solver.gd::commit()` now verifies that the visible
  `MapData.weather_field_init_arr` has `n_cells` initialized entries and samples
  visible `vapor/cloud/cloud_water/precip/type` against the just-solved
  `next_*` buffers.
- If native slot flush is invisible to `MapData` (for example CSV shows
  `weather_field_init_arr=0` and `weather_type_arr=CLEAR` for every cell),
  the same existing GDScript commit loop republishes the already-computed
  `next_*` buffers into `MapData` and `DCWorld`; this is reported as
  `field_commit_path=gdext_commit_repaired_gdscript_publish`.
- CSV/weather breakdown fields
  `weather_field_commit_publish_verified`,
  `weather_field_commit_publish_repaired`,
  `weather_field_commit_init_count`, and
  `weather_field_commit_publish_reason` diagnose this boundary. No schema or
  weather enum is added; this is only a publish-contract guard.
- The combined native weather path is not allowed to skip this commit boundary.
  It may only be considered visible-weather-authoritative when
  `weather_field_commit_path` is non-empty, `weather_field_commit_init_count`
  reaches `n_cells`, and `weather_field_commit_publish_verified=true`.

风险：

- weather fronts 数量低，但对象层复杂；不应盲目 SIMD。
- field solve 是 hot-loop，适合 C++。
- GDScript object unpack 仍可能造成 commit/sync 长尾。
- `weather_field_slice_cells()` 的配置上限当前为 `6400`，默认 `2400`；
  profile 在 `100..6400` 间调度 field solve cell budget。GDExtension 可用且
  `n_cells <= 6400` 时，`map_generator.weather_field_slice_cells()` 优先返回
  `n_cells`，让 field solve 走 full-map native pass。目标是每 1-2 个模拟日完成
  一次 `gdext_commit`；CSV 中用 `weather_commit_tick_delta` 和
  `weather_last_commit_tick` 按 commit tick 分析天气生命周期，而不是按渲染帧或
  partial slice tick 误判。

Weather field geometry contract (2026-06-23):

- Weather field advection and convergence use cylindrical east-west shortest
  vectors. `MapData.cell_pos_x_arr/y_arr` are cached in size=1 hex units, so
  `WeatherSystem._build_weather_field_knobs()` passes `weather_wrap_width_x`
  and `weather_cell_pos_scale` into `DCWorldExt::run_weather_field_solve_pass`.
  Both the C++ pass and `weather/field_solver.gd` use those values for
  upstream/downwind selection and wind convergence. Do not use `hex_size`
  directly as the cone threshold when `cell_pos` is unit-scale; that recreates
  stationary seam rain bands on ocean wrap cells.

### 气候真实度修复 Stage 7–10 (2026-06-23, 续)

- **Stage 7–8（重编）**：对流抑制（relaxation oscillator，C++ member `_wx_conv_inhib`，
  旋钮 INHIB_CHARGE/REFRAC/LEAK/STRENGTH/WET）破连下长尾；地形降水阻尼方向修正
  （`wf_precip_terrain_damping_factor`：LAKE 0.50 / DELTA 0.40 / SWAMP 0.30 / JUNGLE 0 / HILL 0，
  原先山地/雨林被错误重压）；洪泛非门控退水（moist<0.5 且 precip<0.04 → 退 FLOODING）。
- **Stage 9（重编，#5 雨热不同期）**：预报性斜压涡旋场 **ψ**（C++ member `_wx_synoptic`/`_prev`，
  逐 tick 平流+斜压增长+hash 种子+耗散+扩散，**仅 C++，GDScript 无镜像**）。耦合**受斜压门控**
  `baroclinic_gate=smoothstep(0.04,0.16,temp_gradient)`：ψ>0 在中纬冷季锋区 `dynamic_forcing +=
  psi*syn_front_force*gate`、`precip *= 1+psi*(syn_enh+syn_front_enh*gate)`；热带 gate≈0 不增雨
  （避免 7a 热带暴雨回归）→ 地中海/海洋性雨热不同期气候。湖泊 over-water 抑制 0.70→0.35。
  实测雨热不同期+海洋型占比 5%→18%。
- **Stage 10（重编，#5b 跳变平滑）**：实测空间 |Δprecip|=181%、时间=100% 的格点噪声。两处镜像
  改动（`world_ext.cpp` 与 `field_solver.gd`）：① 不应期 `*=(1-INHIB_STRENGTH)` 从 EMA **后**移到
  `precip_target`（EMA **前**）→降水随惯性平滑衰减，不再瞬间砍断（去时间跳变）；② 最终降水向
  邻域（上一 tick）均值轻混（旋钮 `field_precip_spatial_smooth` 默认 0.30，复用
  `wf_neighbor_average_vapor_idx`）→削单格棋盘噪声，连片风暴邻格相近≈不变（保暴雨）。
  **未解（下一轮）**：#2 暴雨/大雨概率偏低、#3/#4 河湖蒸发源不足+湖区少雨（over-water 抑制非
  瓶颈，缺辐合/抬升）、#5a 雪区少雨、#6 山地少雨——属同一「冷/高/水区过干」簇。

### 让天气真实+移动 Stage 11–15 + 渲染帧间插值 (2026-06-24)

接 Stage 7–10。**天气物理改动均在 C++ 权威路径 `run_weather_field_solve_pass`；ψ/stratiform/水汽抽吸等无 GDScript 镜像**（见末尾「GDScript fallback 现状」）。

- **Stage 11 stratiform 层状降水**：对流被暖门(temp>0.48)挡死的冷/高/水区水汽足却无触发。补不需浮力的层状成雨 `strat = smoothstep(0.32,0.62,rh) × cool_weight × strat_drive`：cool_weight 暖→0/冷→1（与对流互补）；strat_drive = 高地形抬升 `smoothstep(0.45,0.82,ELEV)` + 辐合 + 锋面 + 海面(lake-effect)。进 cond_force(×0.75)+trig(×0.80) 旁路 autoconv。修湖/雪/山区少雨。

- **Stage 12–13 ψ 架构重构（让天气移动）**：ψ 从切片内逐格演化 → **内联进 solve pass、每轮 `start_idx==0` 全场推进一次**（脱离切片稀释 + 不依赖 GDScript 调度挂钩，因合并 native 路径会绕过 stage 钩子，见 scheduling 文档）。平流改半拉格朗日（沿平滑引导流=风邻域平均取上风格 ψ_prev）。修复：① cell_temp(实际量纲)误用致 `smoothstep` 恒 1 → ψ 指数爆炸 → 改用归一化温度 `TR` + 斜压增长随振幅饱和 `×(1+baroclinic·g·(1-|ψ|))`；② 稀疏化（seed_rate 0.015 / damp 0.90 / diffuse 0.05 / 阈值清零 0.05）防铺满全场。

- **Stage 14 ψ 主导降水 + 水汽抽吸**：根因——ψ 的 base_lift 之前误加进 `dynamic_forcing`（**不驱动 cond_force/trig**，所以怎么调都无效）。改为 ψ 直接进凝结/降水 `psi_lift = psi×(base_lift+front×gate)`，ψ<0 压制 `psi_supp`。再加**气旋水汽辐合抽吸**（ψ>0 向邻域较湿处靠拢），突破「降水=抬升×水汽、水汽被固定蒸发源锚定」的瓶颈。结果雨热不同期 5%→18%；移动仍是弱平移（水汽锚定=架构极限）。

- **Stage 14e 湖山冷区**：湖泊 over-water 抑制 cap 0.35→0.10 + 删湖泊额外对流压制(`drv_hc×0.60`) + 湖泊不刮 marine_scour；山地 `field_oro_precip_gain` 0.10→0.30、`field_lift_precip_gain` 0.25→0.45；湖泊蒸发 `weather_lake_evap_scale` 0.35→0.85（ClimateProfile + weather_system 双侧）。

- **Stage 15 云量时间 EMA**：`cloud = cloud_water×1.1 + condensation×0.25 + max(cloud_floor)` 混入瞬时项(condensation/cloud_floor 无时间惯性)→渲染阈值附近抖闪。用上帧云量 EMA(`field_cloud_inertia`，默认 0.74，读 slot `s_wcld` 上帧值)平滑。2026-06-27 后提高跟手系数，避免云层在 cloud_water 已清退后仍长期挂背景云。

- **precip 时空平滑**：不应期(inhib≥1)抑制从 EMA 后移到 `precip_target`(EMA 前)→随惯性平滑收敛；最终 precip 非对称邻域填洞(`field_precip_spatial_smooth` 0.30，强填洞、削峰×0.30 保暴雨)。

**渲染帧间插值（时间连续性；GDScript + shader，不动 C++ 物理）**：
- 问题：仿真每 commit(~2-3 tick)更新 weather LUT，渲染每帧画 → 两次更新间云/雨范围/浓度横跳。
- 方案：`world.weather_lut_prev_tex` 双缓冲(map_baker，~32KB)+ shader `weather_lut_prev` uniform + `weather_lerp`；shader 标量层 `mix(prev,curr,weather_lerp)`（type 离散不插）。`weather_lerp` 由 `weather_layer._process` 按 `world.weather_lut_update_usec`(map_baker 每次烘焙打戳) + 自适应 commit 间隔(IIR)独立推进 0→1，与 prev/curr 严格对齐。
- 性能分区：删 shader 4-tap 双线性 + cloud_blur（空间柔化），weather_lut 采样 19/11 → **2~3 次**（桌面移动统一）。
- 频闪修复：`weather_layer.process_priority=1000` 让其 _process 最晚执行 → 同帧检测到 LUT 换帧并归零 lerp，消除「curr 已换、lerp 未重置」的一帧错位频闪。

**GDScript fallback 现状（重要）**：ψ、stratiform、水汽抽吸、Stage 14 耦合均为 **C++-only**（`run_weather_field_solve_pass` 内）。`field_solver.gd` fallback 仅含 Stage 11 前物理 + precip 平滑镜像，**不含 ψ 相关**。C++ DLL 不可用时天气退化为「无移动系统、无层状降水」的旧版——C++ 权威路径罕见失效，可接受；严格双镜像（IRON RULE）此处**有意未做**，因 ψ 架构复杂度高、收益(fallback 罕用)低。`run_synoptic_advance_pass`（C++ 方法 + weather_system/map_generator 转发）是 ψ 内联化前的独立 pass 实现，现为**死代码保留**（备用，未接调度）。

- **Stage 16 方案③ vapor 平流主导（atmospheric river，2026-06-24，⚠ water budget 重标定起点）**：突破「降水 = 抬升 × 水汽、水汽锚定固定蒸发源」的架构极限。把 vapor 从半诊断场改为**平流主导的预报量**（水汽连续方程 ∂q/∂t = −∇·(q·v) + E − P 的一阶迎风工程实现）：`field_advect_vapor` 0.82→0.95、平流权重 `adv_w_v` floor 0.55→0.75、`field_advect_steps` 4→6（clamp 全链 4→8：climate_profile / map_generator / weather_system 三处）。效果：水汽主要由上风输送决定、蒸发源退化为「注入点」、降水/凝结为汇 → 水汽随风成河（atmospheric river），移动的 ψ 涡旋在水汽河上沿途有水可榨成雨 → **降水随系统移动**（物理涌现，最真实）。**代价**：这是 water budget 的重标定起点——内陆湿度、雨热相位、季节、湖山冷区可能随之变化，需录 CSV 迭代标定（vapor 随风成河?移动 lag 位移增大?内陆是否失控?）。

- **Stage 16b 压静止 lift + ψ 主导（移动落地，2026-06-24）**：方案③ 打通水汽锚定后(vapor 成河→处处有水)，移动的最后一公里:压低**静止** lift 让**移动的 ψ** 主导降水空间分布。压静止:`OMEGA_ASCENT_GAIN` 0.65→0.40(ITCZ 雨带弱化但保留)、`field_thermal_conv_precip` 1.10→0.75(按温度锚定的对流雨弱化);提 ψ:`syn_base_lift` 1.15→1.55、psi_lift 进 cond 0.90→1.20 / trig 1.10→1.50。**结果:云距平位移首次明显非零(lag8 ≈2.36 格、lag12 27% 帧非零)——天气真正随系统移动**(多系统生消+平流混合,非单向平移,接近真实大气)。气候保持健康:赤道带/全球降水比 **1.68**(ITCZ 保留)、雨热 71/14/15、陆wet ~25%、mean ≈0.011。收尾标定:`weather_extreme_precip_softness` 0.32→0.45(恢复方案③ 后偏低的暴雨,只放大峰值不增频率)、`syn_base_lift` 1.70→1.55(缓过湿)。

**「让天气真实+移动」收官状态(Stage 9–16b)**:雨热多样(同期 71%/不同期 14%/海洋型 15%)、湖山冷区有雨、暴雨恢复、空间/时间平滑(云量 EMA + 渲染帧间插值)、**天气随移动系统平移**(ψ 内联全场推进 + vapor 平流主导/atmospheric river + 压静止 lift)。全部为 **C++ 权威路径 + GDScript/shader 渲染**;ψ/stratiform/水汽抽吸/平流主导均 **C++-only**(fallback 退化为旧天气)。

### 半真实大气模型（2026-06-19）

> ⚠ **历史调参演进（19a/b/c）**：本节记录 2026-06-19 三次 CSV 标定的演进过程，其中相当
> 一部分参数与机制已被 **2026-06-20 根因重构**替换（carryover→EMA、去纬度门/季节分类、
> vapor_precip_sink / vapor_transport_gain / precip_rh 重新标定）。**当前真实状态以本节末
> 「根因重构（2026-06-20）」小节为准**；下面 19a/b/c 仅作演进参考、不要据此改代码。

目标：内陆形成随风移动的雨云带、各类天气由温度/风场/洋流/地形自然涌现分布（不再硬编码
纬度/季节）。改动同时落在 GDScript hot-loop (`field_solver.gd::run_slice`) 与 C++ 镜像
(`DCWorldExt::run_weather_field_solve_pass`)，两边公式必须逐行一致。

水汽动态化（让 vapor 成为随风搬运的预报量，而非静态气候湿度场的平滑版）：

- `vapor_memory` 对静态 `base_m`(气候湿度)的锚定由 `0.18 → 0.06`，vapor 主要由
  跨日 `prev_vapor` + 上风平流决定，parcel 随风迁移深入内陆。
- `weather_ocean_evap_gain 0.20 → 0.55`：海洋成为强水汽源，喂给上风平流。
- `weather_land_evapotranspiration_gain 0.70 → 0.85`：内陆植被/土壤水汽再循环。
- `weather_vapor_precip_sink 0.95 → 0.70`：下雨不再抽干整层水汽，下风格继承水汽 →
  雨带向内陆推进（与 `weather_field_solver_test` 早已配置/验证的 0.70 对齐）。
- `weather_precip_carryover_max 0.02 → 0.08`：降水跨日/跨格随风延续。
- carryover/平流接力门槛与 RH 触发阈解耦：`relative_humidity >= max(0.45, rh_threshold-0.12)`，
  `vapor_floor_factor=(rh-0.45)/0.40`，让随风迁移的雨带进入略干下风格后仍维持一段。
- `weather_precip_rh_threshold 0.68 → 0.60`：降水触发门槛适度下调。
- `weather_field_advect_steps` 上限 `2 → 4`、默认 `3`：同日上风采样更远。
- 凝结云水 `cloud_water` 随风从上风格平流（`lerp(self, upstream, wind_mag*0.7)`），
  与既有 `precip` 沿风 carryover 配合 → 云团整体随风飘动，而非原格生灭。

天气类型分类重排（`_classify_field_weather_core` / `wf_classify_field_weather_at`）：

- 引入 `lat_signed ∈ [-1,1]`（地图顶部=北半球<0）与 `season_idx`→`local_summer`
  的半球感知季节强度（南半球季节相反）。
- 判定顺序：BLIZZARD → STORM → MONSOON → RAIN → FOG → HEATWAVE → DROUGHT → CLEAR。
- STORM：中低纬 (`lat_abs<0.70`)，夏季降低门槛 (`inst/precip` 随 `local_summer` 插值)，
  暖海核心阈值相对旧版只降不升（保证既有 STORM 用例仍成立）。
- MONSOON：低纬 (`lat_abs<0.42`) + `local_summer>0.5` + `precip>0.06`。
- FOG 紧接 RAIN 且 precip 阈值衔接（`precip<0.030` vs RAIN 的 `>0.030`），不再被判定顺序饿死。
- HEATWAVE：副热带 (`lat_abs<0.62`) + 夏季 + 高温干燥；DROUGHT：持续干燥（暖/寒流偏置）。

parity 检查点（改任一侧务必同步另一侧）：`vapor_memory` 锚定系数、`cloud_water`
上风平流、carryover RH gate / vapor_floor_factor、分类阈值与判定顺序、以及
`climate_profile.gd` / `weather_system.gd` 默认值与 C++ knob fallback 默认值。

### 海面降水抑制 + 类型阈值标定（2026-06-19b 调参）

首版改完后实测（CSV）发现海面 96% 在降水、且 STORM/MONSOON/HEATWAVE/DROUGHT 全为 0%
（全图过湿）。据此二次标定：

- **海面降水抑制**：海洋仍是强水汽源（`surface_vapor_source` 不变，内陆雨带不削弱），
  但海面**降水**按 instability 门控——平静/冷洋面只保留 `1-ocean_precip_suppression`（≈15%）
  几乎不降水，强对流暖洋面（`instability` 高，热带风暴带/ITCZ）保留全量。公式：
  `ocean_conv=clamp((instability-0.45)/0.45,0,1); precip *= lerp(1-suppression, 1, ocean_conv)`。
  作用在 `precip` 最终值上（覆盖 `precip_raw` 与 `cloud_water_rain` 两条来源），
  替代原先只乘 `precip_raw` 的写法。GDScript 与 C++ 镜像一致。
- **类型阈值按实测场范围下调**（land inst p95≈0.67 / precip p95≈0.089 / temp p95≈0.69）：
  STORM gate `inst 0.70→0.62..0.54、precip 0.105→0.090..0.062`（随 local_summer 插值）；
  warm_ocean_core `inst>0.70 precip>0.07 cloud>0.28`；MONSOON `precip>0.055`；
  HEATWAVE `temp>0.66 vapor<0.30 cloud<0.18`；DROUGHT `vapor<0.22 cloud<0.12 temp>0.45`。
  目的是让 STORM/MONSOON/HEATWAVE/DROUGHT 在对应纬度/季节真正可达，不再被 RAIN/CLEAR 垄断。

### 第三次标定（2026-06-19c，依据 CSV 实测分布）

首两版后实测仍偏雨：海面 60% 在降水、STORM/MONSOON/HEATWAVE/DROUGHT 仍 ~0%。逐项归因：
- 海面 `ocean_an(tta)` 实测几乎全 ≈0，但 `instability` 普遍 ~0.47 → 用 instability 门控海面降水
  几乎无效。改为 **`ocean_drive = max(clamp(ocean_an/0.16), clamp((instability-0.74)/0.18))`**：
  仅暖洋流异常或极强对流(ITCZ 级)放开海面降水，其余海面 `precip *= 1-ocean_precip_suppression`。
- STORM：中纬风暴带候选(inst>0.54 & precip>0.062)确实存在却全被季节门(winter gate 0.62/0.090)挡掉。
  门改为弱季节依赖：`inst 0.56→0.50、precip 0.068→0.056`（风暴非夏季独有）。
- HEATWAVE：实测最热陆地恰最湿(hot 格 vapor p50≈0.42)，`vapor<0.30` 永不可达。
  改为以"高温(temp>0.70)+少云(cloud<0.30)+无降水"为准，去掉强制低 vapor。
- DROUGHT：即便 vapor<0.22 的格 cloud 仍 p50≈0.27（冷格低 vapor 但高 RH）。改以
  `cloud<0.22 & precip<0.020 & temp>0.48 & vapor<0.34` 为主（低云暖区）。

离线回代验证（用上一轮 CSV 场值套新逻辑）：RAIN 38%→~24%、CLEAR 49%→~67%、
STORM 0→2~3%、FOG 0.1%→~4.7%(冷洋面海雾)、BLIZZARD 13%→~1.4%、DROUGHT/HEATWAVE 由 0 转正。

### 根因重构（2026-06-20）：降水惯性化 + 打破水汽稳态 + 去纬度门

针对"天气逐 tick 横跳/不连续 + 海量永雨永旱 + 纬向直线条带"的根因重构，三阶段落地。
GDScript (`field_solver.gd::run_slice`) 与 C++ (`run_weather_field_solve_pass`) 仍双份镜像。

**阶段1 — 降水惯性化（消除横跳/不连续）**：
- `precip` 改为带时间状态的 EMA：`precip = lerp(prev_precip, precip_target, weather_precip_inertia)`。
  初版默认 `0.30`，2026-06-22 生命周期修复后当前默认为 `0.40`；
  `precip < 0.003` 归零。
- **删除**脉冲放大三件套：carryover `precip_floor` 跨日叠加、`precip_cls` 拖尾、
  `precip_gate`/`fog_cloud_gate` 分类滞回。时间连续性统一由 EMA 提供，分类回归**单阈值**。
- `precip_target = max(precip_raw, cloud_water_rain)`（不再叠加 carryover floor）；
  云水降水消耗率 `0.42 → 0.22`，削弱"积累-暴耗"自激振荡。

**阶段2 — 打破水汽稳态（消除永雨永旱）**：
- `weather_vapor_transport_gain 0.92 → 0.75`：vapor 不再被平流摊平锁成稳态，本地蒸发-降水收支更主导。
- `weather_vapor_precip_sink 0.70 → 0.85`：下雨更快耗尽本地水汽 → "雨→变干→再积累"松弛循环。
- `weather_precip_rh_threshold 0.60 → 0.70`：凝结只在真正高湿(RH>0.70)发生，拉开干湿对比、还原晴空。
- `weather_ocean_precip_suppression 0.85 → 0.95`：静洋面压到阈下，降水集中到 convergence /
  frontogenesis / 暖流异常 的空间强迫带（`ocean_drive = max(ocean_an/0.16, (inst-0.90)/0.10,
  (conv-0.38)/0.16, fronto/0.16)`），其余洋面转晴。`vapor_memory` 锚定保持 `0.18`（19a 的 0.06 未采用）。

**阶段3 — 去纬度门 + 做减法**：
- 分类 `_classify_field_weather_core` / `wf_classify_field_weather_at` **删除 `lat_norm` /
  `lat_signed` / `season_idx` / `local_summer`**：类型边界由温度/湿度等弯曲物理场涌现，消除沿纬线的
  直线天气带。2026-06-22 后签名扩展为
  `(temp, vapor, cloud, cloud_water, precip, instability, ocean_an, wind_speed, temp_anom, monsoon_flux, is_water)`。
- 判定顺序：BLIZZARD → STORM → MONSOON → RAIN → FOG → HEATWAVE → DROUGHT → CLEAR。
  阈值按海陆分别标定：`meaningful_precip` 在水域为
  `precip>0.032` 或 `precip>0.022 & effective_cloud>0.22 & precip_cloud_mass>0.077 & vapor>0.28`，
  在陆地为 `precip>0.040` 或
  `precip>0.030 & effective_cloud>0.12 & precip_cloud_mass>0.042 & vapor>0.09`。
  STORM 要求暖湿、高不稳定和有效云水，暖海核心要求 `is_water & ocean_an>0.05`；
  MONSOON 额外读取 `monsoon_flux`/上岸湿通量；HEATWAVE/DROUGHT 仅陆地可触发。
- 清理 `lat_norm` 僵尸链（`cell_lat_norm` knob、`LATN` 指针、`soa_lat_norm` 等）与死代码
  （GDScript `_run_weather_field_gdscript_loop_inplace`、cell 版 `_classify_field_weather`）。
- `field_precip_decay` / `field_precip_carryover_max` 已成**僵尸 knob**（C++/GDScript hot-loop 均
  不再读），仅 ClimateProfile/knobs 链路尚存传递，待后续删除。

**parity 检查点**（改任一侧务必同步另一侧）：`vapor_memory` 锚定系数、`vapor_transport_gain`、
precip EMA(`weather_precip_inertia`)、`ocean_drive` 海面抑制、`precip_rh` 阈、分类阈值与判定顺序、
以及 `climate_profile.gd` / `weather_system.gd` 默认值与 C++ knob fallback 默认值。

### 天气生命周期修复（2026-06-22，当前真实状态）

本轮针对 CSV 暴露的“大陆弱降雨泛滥、雨云拖尾、锋面/季风/台风弱代理、天气对生态反馈弱”
做增量修复。权威热路径仍是 `DCWorldExt::run_weather_field_solve_pass`，GDScript
`weather/field_solver.gd` 作为 fallback / verify mirror；不新增 DataCore schema，不新增
天气 enum。

**Cadence**：

- `ClimateProfile.weather_field_slice_cells` 默认 `2400`、上限 `6400`；
  `map_generator.weather_field_slice_cells()` clamp 同步为 `100..6400`。
- full-map native 条件为 GDExtension 可用、`run_weather_field_solve_pass` 存在、
  weather field 启用且 `n_cells <= 6400`。命中时单次 solve 覆盖全图，降低长时间 partial
  phase 造成的“天气不生成/不消失”错觉。
- `WeatherSystem` 在每次 commit 后写 `weather_commit_tick_delta` / `weather_last_commit_tick`；
  `tile_data_recorder.gd` 直接导出这两个字段。生命周期统计应按 commit tick 计算。

**云雨生命周期与永雨修复**：

- `weather_precip_inertia` 默认由 `0.30` 提到 `0.58`；2026-06-27 复核
  `tile_data_record_20260627_192522.csv` 后曾将 `weather_field_cloud_reevap` 提到
  `0.38` 以加快雨后清云。2026-06-29 复核发现静稳非降水薄云被清得过快，默认回调到
  `0.28`；`weather_field_cloud_inertia` 仍显式 profile 化且默认 `0.74`。C++ fallback 默认、
  `weather_system.gd` 默认值和 `climate_profile.gd` 三处必须保持一致。
- 2026-06-27 `tile_data_record_20260627_201214.csv` 显示 49% 格几乎永晴、20% 格几乎全年多云，
  cloud lag-8 自相关仍约 0.97。为恢复“雨云会下完并随风过境”的设计，默认把
  `weather_field_advect_steps=8`、`weather_field_diffusion=0.025`、`weather_field_precip_base_frac=0.08`；
  C++/GDScript hot loop 同步降低静态热力对流和山地云底，减少 `precip_cloud_reserve`，
  并恢复持续降水的 vapor discharge（`VAPOR_DISCHARGE=0.70`、`DISCHARGE_SUSTAIN=0.65`）。
  这使固定地形/温度源不再单独锁成永雨，移动 ψ 和上风水汽成为云雨主要时变来源。
- hot loop 增加 `post_rain_subsidence`：上一轮 `prev_precip` 高、当前
  `frontogenesis/convergence/convective/ocean_convective` 低时，降低凝结、提高再蒸发，并增强
  低动力海面的 `marine_scour`。效果是雨后下沉清云，避免雨区原地拖尾。
- 河流陆地新增 `river_recycle_lock`：仅在 `has_river`、上一轮降水较高、而辐合/抬升等动力
  forcing 低时触发。它会同时压低河流额外蒸发源、降低河流蒸发 floor，把一部分
  `cloud_water` 回流为 vapor，并降低 `precip_target`。这针对 CSV 中“河流格自身水汽循环
  锁住永雨”的根因，不影响有真实锋面/地形抬升穿过河谷时的降水。
- `frontogenesis` 改为 `convergence * temp_gradient * humidity` 联合门控。低湿温度梯度不再凭空
  产雨；真实锋生会直接提高 `cloud_water` 与 `precip_target`。
- 海洋不再只保留极端深对流：`ocean_drive` 现在由暖流异常、较高 instability、辐合、锋生、
  沿岸季风湿通量，以及暖湿海面中等云水驱动共同取最大值。2026-06-23 的
  `tile_data_record_20260623_021536.csv` 显示海面 `RH > 0.46` 已达约 96%，但
  `precip > 0.014` 只有约 0.2%，说明海上水汽存在而释放门控过紧；因此暖湿海面触发项改为
  `smoothstep(0.42,0.64,RH) * smoothstep(0.025,0.075,cloud_water) *
  smoothstep(0.50,0.72,temp) * 0.80`，开阔海面的有效 suppression clamp 从 `0.80` 放宽到
  `0.72`。2026-06-27 后低动力 `marine_scour` 进一步增强，quiet ocean 云水上限收紧为
  `0.045 + ocean_drive * 0.20`；2026-06-29 为恢复薄层云，quiet ocean cap 放宽为
  `0.070 + ocean_drive * 0.18`。目标是恢复暖湿海面上的零散风暴/季风雨带，同时保留
  post-rain subsidence 和低动力清扫，避免回到全海弱雨。
- CLEAR/FOG 的静稳格不允许继承强成雨云水：`precip < 0.003` 且 `dynamic_forcing` 低时，
  `cloud_water` 被压到 `clear_cap`（当前默认 `0.065 + dynamic_forcing * 0.12`，低动力海面
  使用上面的 quiet ocean cap），多余云水按比例回流为 vapor。最终 `cloud` 还会在
  `quiet_non_precip` 下读取 RH 驱动的 fair-weather floor，用于保留湿润但不下雨的层云/薄积云。
- 最终分类后再次执行 hydrological precip gate：如果分类结果不是
  `RAIN/STORM/BLIZZARD/MONSOON`，残余 `precip` 回流为 vapor 并清零。这样
  CSV 不再出现大量 CLEAR/FOG/HEATWAVE/DROUGHT 携带可被水文消费的小雨量；即便
  诊断或视觉层读取旧 `weather_precip`，distribute/hydrology pass 也不会把它当成降雨。
- `frontal_convergence_boost` 也服从同一语义：它只能在水汽足够时抬升 precip；
  若抬升后达到有效降水阈值，必须同步把类型改为 `RAIN`，否则保持非降水类型并清掉
  precip。禁止后处理在分类之后制造“CLEAR/FOG 带雨”的灰区状态。
- 分类以 `cloud_water + precip + instability` 为主，视觉 `cloud` 只作为辅助。
  `meaningful_precip` 要求中等降水同时有有效云水，STORM 要求暖湿、高不稳定且云水足够；
  MONSOON 要求 `onshore_moist_flux` 或高湿驱动加上 sustained precip。这样避免
  “薄云强雨”与“厚云晴天”互相污染。

**锋面、季风、台风诊断**：

- 冷锋/暖锋不新增 enum。summary front 通过沿风温度平流诊断：
  `front_temperature_advection > 0.015` 记为 cold front，`< -0.015` 记为 warm front；
  字段进入 dict/SoA、`WeatherFront` transient fields、breakdown 和 CSV
  (`weather_cold_front_count` / `weather_warm_front_count`)。
- MONSOON 不再只靠局部高湿强雨。分类额外读取 `onshore_moist_flux`，允许近岸陆地与沿岸水域
  在暖湿上岸风、持续降水和厚云共同满足时形成连续季风雨带。
- `cyclone_wake_step` 只从暖海 STORM cluster 注入尾迹：中心必须是水体，`temp >= 0.56`、
  `precip >= 0.05`、`cloud >= 0.22`，且 `instability >= 0.48` 或 `convergence >= 0.30`，
  再加风速/强度门控。普通陆地雷暴不再生成台风尾迹。

**植被/水文闭环**：

- 天气仍先影响 `soil_moisture` / `water_balance_30d`，植被动态再通过
  `_plant_available_water(base_moisture, water_balance_30d, soil_moisture)` 读取长期水分。
  不把单日降水硬写成植被增益。
- `weather_to_vegetation_gain` 默认 `0.012`，仅作为小权重写入
  `vegetation_growth_pressure`；stage-b 的 `target - prev_vitality` 仍由兼容度、天气惩罚、
  stress 和 regen 综合决定。
- `vitality_high_streak` 不再表示“当前植被很健康”本身，而表示 `next_richer` 在当前
  `temp_30d + plant_available_water` 下比当前植被至少高出
  `succession_min_compat_gain`，且下一阶兼容度达到 `vitality_high_threshold`。这样 UI
  的升级倒计时只对应真实可触发的演替候选，湿润后的荒漠/灌丛可在中期向下一阶迁移。
- drought stress 与 heat stress 分开：`vegetation_drought_stress` 来自长期
  `plant_water` 低于植被理想水分的程度，天气类型为 DROUGHT 时只额外抬高；HEATWAVE 只进入
  heat stress。降水不应正向提高 drought stress。
- 热带 JUNGLE 地形门为 `moisture > 0.64`，连续热带雨林植被门为 `> 0.66`；中间湿度带由
  季风林和热带季雨林承接。雨林 profile 当前为 `ideal_temp=0.86`、`ideal_moist=0.72`、
  `temp_tolerance=0.20`、`moist_tolerance=0.24`，湿生植被只保留四分之一的过湿距离惩罚，
  但缺水惩罚不变，因此新生成的高温高湿雨林不会从第一天就被判定为严重失配。
- 退化 streak 不再等待“当前 vitality 与 target 同时低于 0.25”。现在只有在全体允许陆生候选中的
  最佳适生类型比当前类型至少高出 `succession_min_compat_gain`，且当前 target 持续低于
  `vitality_low_threshold=0.45` 时才累计；earth-like 的退化/升级门均为 200 游戏日，匹配每次约
  100 游戏日的原生 vegetation cadence，避免单次采样立即翻转，也保证多年气候漂移能产生实际演替。
- 原生 stage-b 返回的 `succession_indices/succession_to_veg` 只是候选结果。ACTIVE native daily、
  merged weather 与 legacy combined 三条边界统一调用
  `_apply_vegetation_succession_candidates()`，显式写回 `HexCell`、`MapData.vegetation_arr /
  base_vegetation_arr`、DataCore/WorldExt 的 `cell_vegetation/cell_base_vegetation` 槽位，再触发
  enum atlas 与 detail scatter dirty。候选未发布不得计作已完成演替。
- `weather_vegetation_dynamics_stride` 是 stage-b 调用次数，`native_daily_sim_stride` 是每次
  native graph 跨过的游戏日；native 路径的 vitality/streak `day_scale` 使用两者乘积，避免
  例如 `10 × 10` cadence 实际跨过 100 日却只累计 10 日。

**验收指标**：

- 开启 `set_field_verify_mode(true)` 时，C++ 与 GDScript field 输出误差应 `<= 1e-4`。
- `gdext_commit` 间隔 p50 <= 2，p90 <= 3。
- 河流陆地 wet>=90% 的格子应显著低于当前诊断的 `63/94`，并且最大 streak 不应继续贴着整段
  录制长度；若仍锁住，优先看 `river_recycle_lock` 是否被真实动力 forcing 持续解除。
- 水域 wet ratio 应明显高于 `0.0017`，但不能回到海面大范围弱雨；暖湿海域应出现局部
  STORM/MONSOON cluster，而冷静洋面保持 CLEAR/FOG 为主。
- 湿天气 >=90% 的格子 < 64；RAIN 平均持续 < 40 commit-days，FOG 平均持续 < 50 commit-days。
- `cloud_water_vs_precip` > 0.45；CLEAR 的 `cloud_water` p50 < 0.08。
- front wet overlap 应在 35%-60%；MONSOON 占比 0.5%-3%，水域/沿岸不应恒为 0。
- 暖海 STORM cluster 应能形成 5-30 格规模，并伴随低压、强风和移动路径。
- 非极区陆地 `water_balance_vs_veg_vitality` > 0.25；`precip_vs_drought_stress`
  应接近 0 或转负。







## Ocean currents physical chain

主要入口：

- `simulation/sus/jobs/ocean_currents_job.gd`
- `rendering/map_baker.gd`
- `DCWorldExt::run_slp_field_pass`
- `DCWorldExt::run_wind_field_pass`
- `DCWorldExt::run_psi_solver_pass`
- upwelling/raster/native helpers

Cadence contract:
- One tick is one game day. `OceanCurrentsJob` keeps the registered SUS policy
  always-on so the job can enter every day.
- On due ticks selected by `ocean_daily_wind_period_ticks`, the job starts with
  a lightweight C++ wind prepass:
  `MapBaker.run_daily_wind_field_update(map, world, cfg, hex_size, season_phase,
  sim_day, stage)` calls `run_slp_field_pass` and/or `run_wind_field_pass`,
  publishing `cell_slp`, `cell_wind_x/y`, and `cell_wind_speed` back to the C++
  slots / `MapData` mirror.
- Before the prepass, `MapBaker` refreshes only the wind/SLP input slots
  (`cell_pos_x/y`, terrain/landform, temp/anomaly/snow/sea-ice, vapor/cloud,
  SLP and wind vectors). Older DLLs without `refresh_slots_from_map_keys()` fall
  back to the full `refresh_slots_from_map()` path.
- 2-tick SLP/wind split (`plan/daily-wind-stage-split`, profile flag
  `ClimateProfile.daily_wind_split_passes`, default `true`): the `stage`
  argument selects which kernels run this tick — `"slp"`, `"wind"`, or `"both"`.
  `OceanCurrentsJob` alternates by the actual due-occurrence counter, not
  calendar-day parity, so `wind_period_ticks>1` cannot pin the split to only one
  kernel. The first prepass after a reset (and any cold start where
  `map.slp_arr` size is stale) runs `"both"` as a safety net so wind never reads
  an empty/old SLP. This drops the single-tick SUS peak from ~5ms (SLP+wind
  together) to ~3ms, freeing budget for the starved atlas upload. Set the flag
  `false` to restore the merged path (regression / low-speed precision).
- The prepass report splits the two kernels for attribution: `slp_ms` /
  `wind_ms` plus `slp_stage_name=daily_wind_slp` / `wind_stage_name=
  daily_wind_wind`, `slp_ran` / `wind_ran`, `stage_requested`, and
  `dominant_stage` / `dominant_stage_ms`. `path` reflects the stage actually run
  (`gdext_daily_wind`, `gdext_daily_wind_slp`, or `gdext_daily_wind_wind`). The
  ocean job surfaces these on the slice report (and `substage=dominant_stage` on
  wind-only days) so the scheduler log attributes the budget to SLP vs wind
  without changing the kernels. See `scheduling-and-job-graph.md` for the report
  shape.
- SLP-internal instrumentation: `run_slp_field_pass` returns `slp_passA_ms`
  (per-cell baseline build), `slp_passB_ms` (6-neighbor smoothing), `slp_norm_ms`
  (recenter + p95 sort + scale), and `slp_marshall_ms` (prev-blend + recenter +
  delta + slot publish). `elapsed_ms` (= `slp_ms`) excludes the trailing
  diagnostic-stats sort, matching historical behaviour. These flow through the
  prepass report and the ocean breakdown so the `daily_wind/slp_internal` log
  line shows where the SLP cost lands.
- Latitude LUT (`plan/slp-lat-lut`): passA's baseline used to call
  `dc_insolation_now` (~9 transcendentals) and `dc_insolation_annual_mean`
  (a 16-sample annual integral, ~144 transcendentals) plus `base_lat`/`s_lat`
  trig **per cell** — ~155 transcendentals × `n_cells` (~1M for 6400 cells) every
  pass. All of these are functions of latitude `ny` only (the annual mean is even
  season-independent), so `run_slp_field_pass` now precomputes `base_lat(ny)` and
  `solar_heat(ny)` into a `slp_lat_lut_bins`-entry LUT (default 1024, clamp
  16–8192) once per pass and the cell loop does a single linear interpolation.
  Only the genuinely per-cell `synoptic` term (uses cell index `i`) keeps its two
  transcendentals. This drops passA from ~2.9ms to a few tenths of a ms. Set
  `slp_lat_lut_bins=8192` for a near-exact A/B reference; interp error at 1024
  bins (~0.18° latitude) is far below the natural day-to-day `slp_delta_p95`.
- 让天气流动 phase 1 (2026-06-21) — mobile low-pressure systems: `run_slp_field_pass`
  adds an optional `mobile_low` term to each cell's SLP — `N` Gaussian low-pressure
  centers `−amp·exp(−r²/2σ²)` whose normalized centers drift west→east (mid-latitude
  westerly steering), wrap in x once per `slp_mobile_low_period_days`, with a slow
  latitude wobble. Centers are hashed deterministically from `(world_seed, j)` and
  precomputed **outside** the cell loop; the hot loop only evaluates the Gaussian
  falloff, reusing the C-feature `cell_pos_x`-normalized coords + bounds. Knobs (from
  `ClimateProfile` via `map_baker`): `slp_mobile_low_count` (default 3, clamp 0–8),
  `slp_mobile_low_amp` (default 0.10), `slp_mobile_low_sigma` (default 0.16 of map
  width), `slp_mobile_low_period_days` (default 38). `count=0` / `amp=0` / missing
  knob / missing `cell_pos_x` slot all degrade to off (backward compatible with old
  DLLs). Purpose: inject a **moving convergence source** so the existing downstream
  chain (wind reads the SLP gradient → convergence → `cloud_source`/frontogenesis →
  cloud-water advection) carries rain bands across the map and breaks the steady-state
  permanent-rain / permanent-drought pattern, without touching the bit-equal vapor
  mirror. C++-only: the SLP GDScript fallback has already diverged (no synoptic/moist
  terms) and production always runs the gdext path. `mobile_low` flows through Pass B
  smoothing, p95 normalization, and the `prev_slp` inertia like any other SLP term.
- The prepass uses `SusTickContext.day_index` as C++ `sim_day`. `main.gd`
  forwards the `day_changed(day_idx)` signal value rather than re-reading the
  final `WorldClock.day_index()`, so catch-up ticks still advance wind one day
  at a time.
- `wind_circulation_period_ticks` is not used to slow this daily wind prepass;
  `MapGenerator` configures the job from
  `ClimateProfile.ocean_daily_wind_period_ticks` (default 3). Raising that value
  means accepting lower-frequency SLP/wind authority updates in exchange for
  fewer spike frames.
- The heavier ocean chain remains sliced: `PSI -> upwelling -> raster -> GPU
  commit` is gated inside the job by the internal continuous slice policy and
  by `ocean_currents_period_ticks` / `ocean_currents_slice_count`.
- When a slow ocean round starts after a successful daily wind prepass,
  `prime_physical_solve_from_current_wind()` starts the physical stage machine
  at `PSI_INIT` so SLP/wind are not recomputed in the same tick.

Stage 概览：

| Stage | 典型名称 | C++ 化状态 |
| --- | --- | --- |
| 1 | SLP field | `run_slp_field_pass`，可 `published_to_slot=true`。 |
| 2 | Wind field | `run_wind_field_pass`。C++ 内综合纬向环流、归一化 SLP 压力梯度方向、科氏偏转、天气尺度波/涡、沿海热力压差响应和地形摩擦；输出单位方向 + `cell_wind_speed`。 |
| 3-4 | PSI solver | `run_psi_solver_pass`，可发布 `cell_ocean_current_x/y`。 |
| 5-6 | Upwelling / currents apply | C++ helper + GDScript state machine。 |
| 7 | Wind/ocean raster | `gdext_raster` / pixel slices。 |
| 8 | Pixel commit | GDScript/Godot image/atlas commit。 |

圆柱周期契约（2026-08-02）：`run_slp_field_pass` 与 `run_wind_field_pass` 的天气尺度二维波
统一读取 `wrap_origin_x` / `wrap_period_x`（当前地图域为 `0` / `HexUtils.wrap_period_x(...)`），
用正模把 `cell_pos_x` 映射到 `[0,1)`；经向波数只允许 seed 选择的整数谐波，seed 仍控制相位、
纬向波数和谐波阶数。这样压力场、压力梯度和风的直接 synoptic 扰动在东西接缝都连续；不得再用
含 padding 的 `world_bounds.size.x` 或 cell-center 的 `min/max` 作为经度周期。移动低压沿用周期最短
距离，同样消费该真实经度坐标。

> **Cell-range slicing（2026-07，inert-by-default）**：四个 leaf pass（`run_slp_field_pass`
> / `run_wind_field_pass` / `run_psi_solver_pass` / `run_physical_circulation_pass` 的 upwelling
> 部分）现接受 `start_idx`/`end_idx` knob，主循环在 `[start_idx, end_idx)` 区间执行；省略时默认
> `0`/`n_cells`，行为与旧版整图调用**完全等价**。SLP 的 Pass A 写入持久化缓冲 `_phys_slp_buf`
> （外加 `_phys_slp_thermal_abs` 供末切片诊断），recenter/p95/response-rate 融合/slot 发布等
> **全局归约只在末切片（`end_idx == n_cells`）执行**，中间切片只写 `slp_buf` 对应区间；每次调用
> 仍返回全长 `slp_out`（中间切片为缓冲当前部分态），保证 GDScript 的 `size == n_cells` 写回门控始终成立。
> WIND 的 coast/sea BFS 经 `_phys_ensure_wind_coast`（FNV-1a 指纹失效）缓存进成员，per-cell 风场体
> 依赖完整 `slp_arr` + 完整 coast 距离、无扩散，可直接切片无 halo，`wind_speed_out` 在末切片重建为全长数组。
> UPWELLING 直接按区间写 `upwelling` slot，无归约故无 gating。**PSI 的 Gauss-Seidel 迭代需全扫掠，
> 按设计不做 cell-range 切片**，沿用既有 GDScript INIT/ITERS/FINALIZE 迭代切片 + Item 1 的 slot-id/LUT 缓存。
> 此外四个 leaf pass 顶部经 `_phys_resolve_static` 把 `cell_*` slot id、`is_water_lut[256]`、
> `neighbor_indices` 指纹缓存进 `DCWorldExt` 成员（Item 1），砍掉每调用固定开销，零接口变更、fallback 不变。
> 运行期 `OceanCurrentsJob._physical_solve_step_one` 增加 stage 内 cell cursor（`_phys_slp_cursor`
> / `_phys_wind_cursor` / `_phys_upwelling_cursor`），开启后把每 stage 摊到多 tick；cursor 仅在每轮
> solve 的 `_PHYS_STAGE_NONE → SLP` 边界归零，stage 名与全部 `fail()` fallback 路径不变。该切片
> **默认关闭**（`_phys_cell_slice_enabled = false`），开启前须本地 rebuild DLL 并跑 30+ tick PROBE：
> ①切片开/关最终 `cell_slp`/`cell_wind_*`/`cell_ocean_current_*` 场 bit-equal；②任意切片 `fallback`
> 计数恒为 0；③每切片 p95/max < 1ms；④连续多轮 solve 无轨迹漂移。

**生成期一次性 C++ orchestrator（dots-total-cpp step3，2026-06-25）**：`_physical_solve_for_phase`（原子完成入口：`bake_world` 初始物理、deferred refresh、`rebake_ocean_currents` 都走它）现**优先调用 `DCWorldExt::run_physical_solve_pass`**——单次 C++ 调用在进程内按序串起 SLP → wind → PSI → upwelling 四个已验证 kernel（均读 bound slot + `published_to_slot`），中间量在 C++ 内串联（SLP `slp_out` → wind 的 `slp_arr`；wind 写 `cell_wind_x/y/speed` slot → orchestrator 读出注入 PSI 的 `wind_x_arr/y/speed`；upwelling 直接读 wind slot），**stage 间零跨语言往返**。GDScript wrapper `_physical_solve_native_oneshot` 只构造一次 combined knobs（四 stage 输入并集 + `heat_transport/solve_ocean/terrain_aware` 标志；chained 键 `slp_arr/wind_*_arr/stage` 由 C++ 注入），调用后用 `phys_field_nan_guard` 复刻 WIND_RASTER 的 NaN 守门；风场 RG8 光栅化仍由后续 `_bake_initial_vector_buffers` 完成。任一 sub-pass fallback / `!heat_transport`（需 GDScript ocean fallback）/ 未 bind / NaN → 整体 fallback，回退到原 `_physical_solve_step_one` 逐 stage loop。**仅迁生成期（A1）**：运行期季节切换的逐帧分摊路径（`ocean_currents_job.gd` 驱动 `_physical_solve_step_one`）**完全不动**，零运行期回归。

`ocean_currents_job.gd` 维护 `_phys_stage`，每次 `run_slice()` 推进一个 stage 或 pixel range。日志可能出现：

```text
largest=ocean_currents/ocean_pixel_slice/pixels_49536_50048 path=gdext_raster 1.07ms
psi_path=gdscript
```

解释：

- `path=gdext_raster` 表示 pixel raster slice 使用 C++ raster path。
- `psi_path=gdscript` 如果出现在 PSI stage 执行前，可能只是默认/上一阶段报告；需要看后续 `stage_psi_path=gdext` 或 `published=true`。
- SLP/PSI `published_to_slot=true` 表示 C++ 已把输出写入 slot，GDScript caller 应跳过重复 array copy。

风险：

- 物理 stage 和 pixel raster 是两类工作；前者影响模拟，后者影响可视化。
- pixel upload 可被 budget skip，但 physical solve 长期 skip 会造成 ocean/wind 冻结。

## Atlas upload

### Enum atlas

入口：

- `simulation/systems/enum_atlas_upload_system.gd`
- atlas encoder / map baker helper

职责：

- cover/vegetation/enum 等离散 atlas dirty patch。
- C++ cached patch 可减少 CPU packing。
- Godot `Image` / `ImageTexture` upload 仍在 GDScript/Godot 对象层。

日志：

```text
enum_atlas_upload axis= path=cpp_cached_patch elapsed=0.01 patch=0.42 img=0.00 upload=1.39 dirty=1411px/6cells cache=true
```

解释：

- `patch` 是 patch 构造或 C++ cached patch 成本。
- `upload` 是 GPU texture update 成本。
- `dirty=1411px/6cells` 表示 dirty cell 少但像素覆盖可能大。

### Dynamic visual atlas

入口：

- `simulation/systems/dynamic_visual_atlas_upload_system.gd`

职责：

- smooth prep、dilate、collect、stride commit。
- dynamic smooth atlas / ice state texture 等。

风险：

- `frame_budget_exhausted` 可导致上传滞后，但不一定影响模拟权威。
- `_cpp_stride_in_progress` 表示 C++/patch stride 跨 tick 推进中。
- cell-indirection LUT 不得读取 native daily continuation 的中间 slots。系统先查询
  `is_native_daily_visual_commit_pending()`；若事务尚未提交，保留 `_lut_refresh_pending` 并返回
  `path=cell_indirection_lut_commit_deferred`，finalizer 解除屏障后的下一次调度立即 catch-up。

### Cell-index 间接寻址（province-ID indirection，唯一动态视觉路径）

plan: *cell-index atlas indirection*。把"hex 内恒定"的视觉 atlas 改为
**静态 cell 索引图 + per-cell LUT** 间接寻址，让 shader 自己做 pixel→cell 解析，
把 fan-out 目标从 `n_pix`（~62 万）压到 `n_cells`（~2400），消除每日数 MB 的
per-pixel GPU 上传。

`cell_indirection_active()` 现在恒为 true。旧 per-pixel dynamic/ecology/smooth/ice atlas
不再作为 A/B fallback；bake / upload / render 都走 `map_index_atlas + enum_lut + dyn_lut + eco_lut`。

数据结构（`WorldData`）：

| 字段 | 格式 / 滤波 | 内容 | 更新频率 |
| --- | --- | --- | --- |
| `map_index_atlas`（`WorldData.enum_atlas_tex`） | RGBA8 / **NEAREST** / derived_size | R=biome；G/B=cell.index 低/高字节；`0xFFFF`=map 外哨兵；A=landform | `bake_world` + biome dirty |
| `enum_lut_tex` | **RGBA8** / NEAREST / lut_dims | R=biome / G=veg / B=cover / **A=迷雾知识度 `fog_k`**（0=未探索，128=已探索不可见，255=可见；中间值是 blur 过渡带） | daily 全量重烘（~0.1-0.3ms）+ 视野变化时 `refresh_country_visuals()` 强制重烘 |
| `dyn_lut_tex` | RGBA8 / NEAREST / lut_dims | per-cell temp/wet/snow/(ice\|vitality) | daily |
| `eco_lut_tex` | RGBA8 / NEAREST / lut_dims | per-cell foliage/stress/transition/growth | daily |
| `weather_lut_tex` | RGBA8 / NEAREST / lut_dims | per-cell R=weather_type / G=intensity / B=cloud / A=vapor；雨/雪视觉用 G=intensity 作为降水门控 | daily（软依赖：天气未就绪时整段 0 → 无云） |
| `lut_dims` | Vector2i | `(min(n_cells,2048), ceil(n_cells/lut_w))` | bake_world |

入口：

- 烘焙：`map_baker.gd::_encode_enum_atlas` 产出 map-index atlas；`bake_cell_luts` 产出四张 LUT（enum/dyn/eco/weather）。
  **首烘时机推迟到 bind 之后**（2026-07-27）：`encode_cell_luts` 读 `DCWorldExt` 的绑定 slot，
  而 `bind_map_data` 要等 `bake_world` 返回、`init_soa_from_bake` 跑完才发生，在 `bake_world`
  内部就地烘 100% 会退回 GDScript。现在 `bake_world` 只设 `_initial_cell_luts_deferred`，
  由 `_setup_sus` 内 `run_deferred_initial_cell_luts()` 补烘（紧跟
  `run_deferred_initial_physical_circulation`，与物理环流同一套 defer 模式）。
  该点已过 `_publish_native_generation_from_slots`，因此 LUT 编码到的是原生温度场
  publish 之后的权威气候值，而不是 bake 期的 bootstrap 值；仍在 `generate()` 内，
  早于渲染器绑定 LUT 纹理。gdext 整个类不存在时没有可等的 bind，就地烘作为无 DLL 兜底。
  补烘后若仍未走成 C++ 会 `push_error`（dots-total-cpp 不降级纪律）。
- daily 刷新：`map_baker.gd::refresh_cell_luts_daily`，由
  `dynamic_visual_atlas_upload_system.gd::tick` 每 stride 调用一次（flag 开时该 tick
  跑完 LUT 重烘即 **early-return**，整段 4-phase / C++ `run_atlas_pipeline_step` 逐像素
  上传被跳过，见下方"单一间接寻址路径"）。stride 节奏由 `StridePolicy` 控制，刷新频率
  与旧路径等价。
- **编码权威路径**：map-index atlas 由 GDScript baker 在 `_encode_enum_atlas` 里一次 fan-out；
  独立 `encode_cell_index_tex` 已退役。LUT 仍优先走 C++：
  - `DCWorldExt::encode_cell_luts(opts)`：读 8 个 SoA slot（temp/moist/snow/vit/sea_ice/
    terrain/vegetation/cover）→ per-cell enum/dyn/eco LUT（scalar tight loop，n_cells≈2400）。
    enum 缓冲是 `slots_total * 4` 字节（RGBA8），A 通道来自**可选入参 `fog_k_arr`**
    （`PackedByteArray`，`VisionSolver` 产出）。显式传数组而不是读 slot，理由与
    `snow_cover_arr` 相同：`refresh_slots_from_map()` 会把所有 slot 从 MapData 拉一遍，
    可能用陈旧镜像覆盖 native-only 的气候值。**未提供时 A 恒为 255（全知）**，
    保证迷雾未接线时视觉不变。`map_baker.gd` 的 GDScript fallback 路径必须写同一份
    `fog_k`，两条路径漏一条就会在 C++ 不可用时闪回全亮。
    **是否传这个数组由 `MapData.fog_solved` 决定，不能用数组大小判断**：
    `init_soa_from_bake` 会把 `fog_k_arr` 分配成全 0，尺寸够了但内容是"未解算"，
    与"全图未探索"在字节上无法区分。解算前传下去会让 A 通道全 0、首帧整张地图变黑
    （LUT 首烘推迟到 bind 之后即触发过这个回归）。`VisionSolver.solve()` 与
    `mark_all_visible()` 置位该标志，`rebuild_soa_from_cells()` 清位。
    另读 4 个 weather slot（`cell_weather_type/intensity/cloud/precip`）→ weather LUT；weather slot
    **软依赖**：未初始化（size < n_cells）时该段全 0（云不显示），enum/dyn/eco 仍正常、不整张回退 GDScript。
    复用 `pk_atlas_sig_dynamic` / `pk_atlas_sig_ecology`（与 fan-out 编码器同一公式 → bit-equivalent）。
    eco `transition_age` 由 `AtlasPipelineState::lut_prev_veg/lut_prev_vit/lut_transition_age`
    自维护（与 4-phase pipeline 的 eco 状态相互独立；`cache_valid=false` / 首帧 / `invalidate_atlas_csr_cache`
    后冷启归零）。返回 `path`/`elapsed_ms`/`published_to_slot=false`（LUT 是渲染产物，不进 slot）。
  - `bounce_lut`（terrain-gi 2026-07-31）：**不由 C++ 编码**。`map_baker._publish_bounce_lut`
    从已编码好的 enum/dyn 字节直接派生（`enum.R`=terrain 查 `_BOUNCE_ALBEDO`
    代表色表，`dyn.B`=雪盖覆盖到雪白、`dyn.A`=植被活力向干黄褪色，水体写 `A=0` 排除弹射），
    因此 C++ 与 GDScript 两条 LUT 路径自动共用同一公式，新增地形也不需要 rebuild DLL——
    只需在 `_BOUNCE_ALBEDO` 尾部追加一项（`terrain_gi_test.gd` 会断言表长与 TERRAIN 一致）。
    它随 `refresh_cell_luts_daily` 每日刷新，所以地形 GI 的弹射色自动跟随季节与天气，
    不触发任何重烘。代表色是近似量，刻意不与 `land_pipeline` 的 fragment albedo 做镜像，
    理由见 `terrain-gi-bake.md`。
- shader：`shaders/include/cell_indirect.gdshaderinc`（`decode_cell_index` / `cell_lut_uv`
  / `sample_dyn_lut_smooth` / `sample_eco_lut_smooth`），由 `world_map.gdshader` SETUP 消费。
  `weather_overlay.gdshader` 内联同款 `decode_cell_index`/`cell_lut_uv`（避免引入 dyn/eco 依赖），
  在 `sample_field_weather` 经 cell-index 间接寻址读 `weather_lut` 逐格驱动云分布（当前只做
  prev/current 时间平滑：G=intensity、B=cloud、A=vapor，type 取中心 cell）；旧 `weather_front_*[]` 椭圆云通路已删除。
- 绑定：`hex_renderer.gd::_apply_uniforms`（`map_index_atlas` + enum/dyn/eco LUT + `lut_dims`）；
  `weather_lut` + `lut_dims` 由 `_weather_layer.setup` 绑给 weather_overlay 材质。

shader 路径（`world_map.gdshader` fragment SETUP）：

- **enum**（Stage B）：`enum_lut[decode_cell_index(uv)]`；邻域 biome 直接采 `map_index_atlas.r`。
  该次采样现在按 `vec4` 读取，`.a` 即 `fog_k`：主地形据此做已探索区去饱和灰化，
  并在 `fog_early_out_enabled` 时对完全未探索像素整段跳过陆地/水体/BRDF/hillshade
  管线（`canvas_item` 的 fragment 禁用 `return`，所以是把整个 fragment 体包进 `if` 块）。
  **零新增 texture sample** —— 只是多读一个已有采样的第四分量。厚云本身由
  `FogOfWarLayer` 在更高的 z 序绘制，主地形只负责灰化与早退。
  注意早退**只在迷雾最低质量档放行**：它要求迷雾层输出与地形无关的常量色，而
  q1 以上的体积云着色随位置和时间变化，早退那块常量色会露成死斑。门控在
  `HexRenderer._effective_fog_early_out()`，细节见 `vision-fog-and-borders.md`。
- **dyn/eco/ice**（Stage C）：desktop 4-tap 双线性（在索引图 bilinear footprint 上取
  4 个 cell 的 LUT 值按子像素权重混合，补回跨 cell 边界平滑，替代旧 CPU box-blur 的 LINEAR
  消边）；mobile 三档退单点 NEAREST（接受轻微 hex 阶梯，省 fetch）。`dyn_lut.B`
  是雪盖阈值型通道，desktop 平滑采样时也必须保留中心 cell 值，不能跟 R/G/A 一起邻格平均，
  否则雪线会在季节/上传 cadence 边界出现半雪插值、闪烁和滞后。海冰随 `dyn_lut.a` 一并迁移。
- **season transition overlay** 只负责旧地表颜色 dissolve。主层已经用当前 `dyn_lut.B`
  绘制雪盖，过渡层在 `dyn_snow` 较高的像素应降低 alpha，避免旧地表噪声 alpha 覆盖当前雪线。
- **scalar 退役**（Stage D）：moisture 取 `dyn_lut.g`、latitude 用 `uv.y` 解析重建；
  `scalar_atlas` 不再生成、绑定或采样。旧 `flow` 河流 SDF 视觉层退化为 0。

**单一间接寻址路径（2026-06-18）**：贴图按"是否被间接寻址替代"分两类处理：

- **保留贴图（各自独立更新路径，与退役的 DVA 逐像素动态 atlas 路径无关）**——
  注意它们**并非都"静态"**，只是其更新通道不是间接寻址要替代的那条：
  - `map_index_atlas`：**biome 变化时更新 R 通道**。veg/cover 不再写入 per-pixel atlas，
    由 `enum_lut` 提供。主 shader
    中心 enum 读已走 `enum_lut`，但 `shore_common` / `water` / `weather_overlay` 在邻居
    偏移 UV **逐像素采样邻居 biome**，仍需整张 per-pixel atlas，故保留。
  - `scalar_atlas` 已退役：shader 中性化 `flow=0`，moisture/latitude 由 LUT/uv 取代。
  - `vector_atlas` 已退役：`world_map` 使用中性零向量，`weather_overlay` 风向走 axis-only 近似（云分布另经 `weather_lut` 逐格驱动）。
  `scalar_atlas` / `vector_atlas` 不再生成、绑定或采样。

**洋流/风场逐像素视觉退役（`ocean_current_visual_enabled`，2026-06-18）**：
`DCFeatureFlags.ocean_current_visual_active()` 恒为 false。`vector_atlas` 的逐像素光栅、
encode、GPU 上传和 shader fetch 均被删除；只保留 per-cell 风/洋流求解。
  1. `map_baker.gd::_bake_initial_vector_buffers` 清空像素 buffer 提前返回
     （per-cell solve 已在前一行 `_bake_initial_physical_circulation` / 物理 solve 写入 `HexCell`）；
     `bake_world` / 延迟物理 / `rebake_ocean_currents` 都直接保持 `vector_atlas_tex=null`；
     `commit_ocean_buffers` 跳过 `vector_atlas_tex` 重建/更新（防御性，正常走不到）。
  2. `ocean_currents_job.gd` 强制 `_phys_need_visual=false` → 求解完成即 `round_done`，
     跳过 stage 7 `WIND_RASTER` + pixel slices + `commit_ocean_buffers`；per-cell SLP/风/洋流
     solve（上方 stages + `run_daily_wind_field_update` daily_wind prepass）照常跑。
  3. 着色器侧：`world_map` 固定 `vects=vec4(0.5)`，`weather_overlay` 风向回退 axis-only 漂移（云分布走 `weather_lut`）。
- **动态逐像素 atlas 已退役（不烤、不每日刷新）**：`dynamic_cell_atlas` /
  `dyn_atlas_smooth` / `ecology_visual_atlas` / `ice_state_atlas` 已被 `dyn_lut` / `eco_lut`
  （海冰走 `dyn_lut.a`）完全替代，flag 开时无任何 shader 消费者。收敛在两个 choke point：
  1. `map_baker.gd` 的 4 个 `rebake_*`（`rebake_dynamic_cell_atlas_only` /
     `rebake_ecology_visual_atlas_only` / `rebake_dyn_atlas_smooth` / `rebake_ice_state_atlas`）
     在 `cell_indirection_active()` 时返回 `_indirection_skip_atlas_report()`（no-op）。
     覆盖 `bake_world` 初始烘 + DVA `_tick_oneshot`。旧 `SeaIceAtlasUploadSystem|Job`
     已删除。
  2. `dynamic_visual_atlas_upload_system.gd::tick` flag 开时跑完 `refresh_cell_luts_daily`
     立即 early-return，跳过 C++ `run_atlas_pipeline_step` 与 4-phase 逐像素上传。
  这 4 张贴图的 `*_tex` 保持 null，`hex_renderer` 不再绑定对应 shader parameter；
  省每日 GPU 上传 + 4 张 derived RGBA8 显存。`hex_renderer` 的旧 per-pixel 海冰探针已退役。

旧 per-pixel 编码器代码仍可能作为历史 fallback 残留，但当前运行路径不再触达。

**`sea_ice_tex`（R8）退役开关（`sea_ice_atlas_enabled`，2026-06-16）**：与 cell-indirection 正交。
`sea_ice_tex` 是**已死贴图**——任何着色器都不 `texture()` 它（主海冰视觉由水路径 shader 按
水温/纬度/水深派生，indirection 开时走 `dyn_lut.a`），运行时 `SeaIceAtlasUploadSystem|Job`
已删除（`map_generator` 只保留 disabled report），`bake_sea_ice_fraction_only`
也无 live 调用者。`DCFeatureFlags.sea_ice_atlas_active()`（Engine meta，默认缺失=**false 退役**），
由 `main.gd` 的 `@export var sea_ice_atlas_enabled`（默认 `false`）推送，**改勾选后需重新生成地图**。
当前行为：`bake_world` 不再 encode 那张全零 R8（省 ~0.6MB 显存 + 编码）、不分配
`sea_ice_fraction_buffer`；`prepare_sea_ice_fraction_atlas` / `upload_prepared_sea_ice_fraction_atlas` /
`bake_sea_ice_fraction_only` 全部 no-op。`hex_renderer` 绑 `sea_ice_tex=null` 安全（uniform 从不被采样）。
开为 `true` 仅为兼容旧调试/数据通道（`dots_soak_dump` 读 `sea_ice_fraction_buffer` 做哈希；
关时该 buffer 为空，dump 走 `n==0` 兜底）。**不影响任何海冰仿真**（仿真读 `cell.sea_ice_frac`）。

## Native daily / EnvironmentRuntime

主要入口：

- `DCWorldExt::run_native_daily_slice`
- `DCWorldExt::run_native_daily_tick`（debug/full-run helper）
- `DCWorldExt::run_native_sim_tick`（SHADOW/A-B/hash diff）
- `EnvironmentRuntime`
- `native_daily_sim_job.gd`
- `native_environment_runtime_system.gd`

状态：

- 当前是 partial ACTIVE continuation，不是所有 legacy/Godot 边界的完全替代。
- ACTIVE hot path 由 `native_daily_sim_job.gd` 调 `MapGenerator.run_native_daily_slice_from_job()`，再进入 `DCWorldExt::run_native_daily_slice()`。`NativeDailySimJob` 不再把 `run_native_daily_tick_from_job()` 或 `run_native_sim_tick_from_job()` 作为候选热路径；前者只用于 debug/full-run probe，后者只用于 SHADOW/A-B/hash diff。C++ 保存 native daily round state、当前 lightweight slice graph node cursor、progress 和累计 breakdown；每个 SUS tick 执行一个或一批存在的 native node，返回 `done=false` 让下个 tick 继续。`ClimateProfile.native_daily_split_weather_node_enabled` 可把 native daily 的 weather transaction 从旧的一体化 `run_weather_refresh_daily_pass` 拆为 `weather_field`、`weather_commit`、`weather_distribute`、`weather_summary`、`weather_cyclone`、`weather_stage_b` 六个 graph 子节点；默认 false 保留 monolithic pass，移动复杂 profile 开启以压低单帧 weather 峰值。
- `ClimateProfile.native_daily_node_range_enabled` 默认 false；打开后 `native_daily_node_range_cells` 控制每次 C++ call 最多处理的 cell 数，`native_daily_node_range_nodes` 控制白名单。C++ 只接受已经有 `start_idx/end_idx` 语义的节点：`ocean_water`、`ocean_land`、`wind_air`、`wind_surface`、split weather 下的 `weather_field`。首批 profile 默认列表只含 `ocean_water/ocean_land`；wind/weather field 应在 bit-equal 与 perf 数据确认后再加入 profile。中间 chunk 注入 `defer_flush=true`，只写 C++ slots；末 chunk 才 flush 到 `MapData`，因此后续 graph node 不会读到半发布状态。
- `native_daily_finalizer_slice_enabled` 默认 false；打开后 round completion 先返回 `native_daily_finalizer/pending done=false`，下一次 SUS slice 运行 `_native_daily_apply_finalizer()` 并返回 `native_daily_complete`。这是低风险 pseudo-node：先把 finalizer 从 C++ graph done slice 中拆出，若 `finalizer_write_dense_ms` / `finalizer_sparse_write_ms` 仍超预算，再继续把 DataCore 写回细切。移动端若配合 `native_daily_sim_stride=N` 做 N 日权威采样，finalizer slice 必须计入 `native_daily_commit_lag_budget_days`；提交延迟通过 `native_daily_sample_day/current_day/commit_day/age_days/commit_over_budget` report 字段公开，不能隐式跨周期累积。
- GDScript 只在 round 起点构建 `native_daily_bundle`，后续 continuation tick 发轻量 knobs。`total_ms/native_ms` 表示当前 slice 墙钟，`round_native_ms` 表示 round 累计墙钟。
- active gate 不应只看 C++ 方法存在，还要看 schema、fronts、schedule graph、fallback 差异报告。
- `runtime_hydrology_enabled=true` 不再是 ACTIVE 硬阻断条件。`MapGenerator` 必须在 native daily bundle 中提供 `weather_knobs` 与 `runtime_hydrology_knobs`；slice graph 会按 `weather -> weather split subnodes(optional) -> runtime_hydrology -> stage_b_after_hydrology` 执行（stage-b 仍按 cadence 可选）。如果 probe 缺少必需 key、hydrology slots 不可发布、或 weather readiness 未通过，则 `native_daily_sim_mode=ACTIVE` 必须回落到 legacy SUS 注册。
- 当 weather field 启用且 `MapGenerator.weather_native_daily_available()`
  返回 `false` 时，`native_daily_sim_mode=ACTIVE` 必须回落到 legacy SUS job
  注册，确保独立 `weather_refresh` staged path 仍然运行。`native_daily_bundle`
  也不得嵌入 `weather_knobs`；否则 `native_daily_sim` 会绕过 visible
  weather authority，造成全晴朗/全零天气场。
- `weather_native_daily_available()` 不再是硬编码 false，而是读取
  `weather_native_daily_readiness_report()`：要求 ext 暴露
  `run_weather_refresh_daily_pass` / `run_weather_field_commit_pass`，
  `WeatherSystem` 暴露 unified knobs/apply 入口，GDScript 有 weather LUT
  发布 facade，并且最近一次 staged weather commit 已证明
  `field_commit_publish_verified=true`、`field_commit_init_count == n_cells`、
  且没有走 `field_commit_publish_repaired`。这只是放行条件；native daily
  执行失败仍必须通过 `fail_stage` / `fallback_reason` 回落。
- `NativeDailyReport` 暴露 `published_slots`、scheduler-level `published_to_slot`、
  `visual_dirty_intents`、`retained_gdscript_authority`、`retained_boundaries`、
  `native_state_snapshot` 和 `graph_coverage_complete`。`retained_boundaries`
  单独列出计划保留的 Godot/presentation 边界，不再阻塞 simulation graph complete。
- `NativeDailyReport` 还会暴露 `authority_report`、`authority_blockers` 和
  `graph_coverage_state`。这是权威迁移的机器可读仪表：`authority_report`
  按 climate/sea_ice/weather/runtime_hydrology/ocean/season/visual/fallback 分组记录 owner、phase、
  simulation blockers、retained boundaries 与 publish 预期；顶层
  `authority_blockers` 只放阻止 daily simulation graph complete 的项。
  `graph_coverage_state=partial` 表示 native graph
  可运行但仍未达到完整 DOTS authority 或 production fallback 尚未退休。后续不能只凭 C++ pass 成功或
  `authoritative_ready=true` 判断 fallback 可退休。
- Weather 的 native-ready gate 由 `weather_native_daily_readiness_report()`
  注入 `native_daily_bundle.weather_native_daily_readiness`。只有该 report
  `ready=true`（staged commit 已验证 visible publish、result apply 与 weather
  LUT publish 入口存在）时，`authority_report.weather_transaction.owner` 才会从
  `gdscript_retained` 提升为 `native_ready`。`ClimateProfile.native_weather_transaction_active_owner_enabled=true`
  时，ready tick 可进一步报告 `native_active` / `simulation_authority=true`；
  native execution 会用 `field_commit_publish_verified` 把 phase 升为
  `native_active_verified`。ACTIVE `fronts_changed` 来自真实
  `weather_lut_changed || fronts_count > 0`。`MapGenerator` 会在统一 helper 中消费
  `visual_dirty_intents`，执行 weather LUT publish、front signature diff、
  enum/detail dirty intent。`front_objects_gdscript` 与
  `weather_lut_upload_godot_boundary` 作为 `retained_boundaries` 保留。
- Ocean physical 现在通过 `OceanCurrentsJob.ocean_physical_state_snapshot()` 注入
  `native_daily_bundle.ocean_physical_state_snapshot`。`NativeDailyReport` 会输出
  `native_state_snapshot.ocean_physical_state` 与
  `authority_report.ocean_physical.state`，包括 physical round id、phase lock、
  visual round/cursor、last native diag、native lifecycle facade state、以及
  `native_owned_output_slots`。新 DLL 暴露 `native_ocean_physical_begin/step/finish/reset/get`
  facade；GDScript job 调用它们同步 round/stage/cursor 权威，owner 可从
  `native_ready_probe` 提升为 `native_ready`，并在 `native_ocean_physical_active_owner_enabled`
  gate 打开后报告 `native_active`，并从顶层 simulation blockers 移除。
  visual raster 与 texture commit 仍作为 `retained_boundaries` 保留。
- Season refresh / stage-b cadence 通过 `season_refresh_state_snapshot()` 注入
  `native_daily_bundle.season_refresh_state_snapshot`。report 暴露 period counter、
  stage/cursor、B+ native round 状态、`simulation_slot_dirty_intents` 和
  `visual_dirty_intents`。`native_daily_bundle.season_cadence_policy` 进一步报告
  stage-b `call_index`、albedo/vegetation/feedback stride、should-run 决策和
  season period policy；C++ authority report 会把它作为 `cadence_policy` 透出。
  `native_season_refresh_active_owner_enabled=true` 且 B+ state 可证明时，owner
  可升为 `native_active`。atlas queue/detail scatter 仍是 `retained_boundaries`。
- `MapGenerator._native_daily_required_pass_keys()` 在风温传输开启时要求
  `wind_air_knobs` / `wind_surface_knobs`。native daily bundle 现在构造这两个
  key，`system_schedule.cpp` 也有对应 `wind_air` / `wind_surface` 节点；
  `wind_surface` 是 climate daily 链中 `cell_temp` 的最终合成发布点，因此这两
  个节点必须通过 SHADOW/A-B soak 后，climate partial ACTIVE 才能被视为有效。
- `runtime_hydrology` 已是 `SCHEDULE_GRAPH` 节点，但只在 bundle 含
  `runtime_hydrology_knobs` 时运行。`runtime_hydrology_enabled=true` 时，
  `MapGenerator._native_daily_required_pass_keys()` 要求 `weather_knobs` 与
  `runtime_hydrology_knobs`，并把 stage-b 改挂到可选的
  `stage_b_after_hydrology_knobs`，确保水文更新先于 stage-b 植被/反馈读取。
  publish 成功后 `authority_report.runtime_hydrology.phase` 升为
  `native_active_verified`；只有 bundle 缺少 hydrology knobs 时，
  `authority_blockers` 才会列出 `runtime_hydrology`。
- `tests/native_daily_shadow_runtime_test.gd` 是真实小地图 SHADOW smoke：
  生成 10x8 map，跑一个 legacy-authoritative SUS day，确认 shadow probe
  `bundle_pass_keys` 包含 `wind_air_knobs` / `wind_surface_knobs` 且
  `missing_pass_keys` 为空。它不替代长窗 A/B，只锁定 graph 覆盖不会回退。
- `tests/native_daily_hydrology_graph_test.gd` 是 hydrology graph smoke：
  以 `runtime_hydrology_enabled=true` 跑小地图 SHADOW/probe，确认
  `runtime_hydrology_knobs` 进入 bundle、`authority_report.runtime_hydrology`
  出现、hydrology 不再作为 blocker，并执行一次 explicit native daily tick
  检查 `hydrology_published_to_slot`、`native_active_verified` phase、
  stage-b-after-hydrology 关系、river/water-balance published slots，以及
  hydrology SoA 数组没有 NaN/Inf。
- `tests/native_daily_shadow_soak_test.gd` 是 32-day 小地图 SHADOW soak：
  每天仍走 legacy-authoritative SUS + `probe=true` readiness check；最后额外跑
  一个显式 `run_native_daily_tick_from_job()` execution sample，检查
  `published_slots` 含 `cell_temp` / 三条 anomaly slot，且 `breakdown` 含
  `wind_air_ms` / `wind_surface_ms`。注意：SHADOW probe 本身不执行 graph，不应从
  probe report 读取 timing 或 publish 证据。
- Legacy production path 删除前的 soak 矩阵必须覆盖：
  - SHADOW：hydrology 关/开各跑小图与大图，要求 `missing_pass_keys=[]`、
    `authority_report` 覆盖 `climate_round/sea_ice/weather_transaction/runtime_hydrology/ocean_physical/season_refresh`。
  - A/B：对比 `soil_moisture`、`water_balance_30d`、`river_discharge*`、
    weather slots、sea-ice fraction/terrain flip intents、ocean physical slots 和 visual dirty intents。
  - ACTIVE smoke：小图至少 16 daily ticks，大图至少 30 daily ticks，长窗至少 300 daily ticks；
    hydrology 关/开都要观察 `frame_budget_exhausted`、`policy_gated`、`dep_pending`、
    `published_to_slot`、`fallback_reason`、`native_ms`、`round_native_ms`。
  - 可见性：weather fronts、weather LUT、sea-ice terrain flip、ocean wind/current、
    vegetation/stage-b、dynamic visual atlas 都必须有 renderer/MapData 可见验证。
- `native_state_snapshot` 是状态机迁移的 guard rail：只要
  `weather_transaction_state_owner`、
  `ocean_physical_state_owner` 或 `season_refresh_state_owner` 仍显示
  `gdscript_retained`，对应系统就仍是 GDScript 状态机权威，不能因为 C++ pass
  成功而收敛 fallback。`climate_round_state_owner=native_ready` 表示 native lifecycle/facade/intents
  contract 已齐、可进入 ACTIVE 评估；它不等于 `simulation_authority=true`，也不表示 Godot 边界动作
  或 fallback 已退休。`ClimateProfile.native_climate_round_active_owner_enabled=true` 时，
  snapshot 会在 native-ready 基础上报告 `climate_round_state_owner=native_active`，并把
  `native_probe_state.simulation_authority=true` / `authority=native_active_owner` 写入 report；
  `remaining_gdscript_simulation_authority` 在 active mirror 下清空，表示 climate round
  状态机生产权威已归 native；`remaining_gdscript_authority` 只保留
  `godot_mapdata_boundary_execution` / `reset_abort_boundary_execution` 这类 Godot 边界，
  `fallback_mode=explicit_failure_only` 表示 sync sliced path 只作为失败兜底。
- Climate round state 目前以 PROBE mirror 进入 `native_state_snapshot`：
  `MapGenerator` 把 `ClimateDailySystem.climate_round_state_snapshot()` 注入
  `native_daily_bundle`，native report 透出 `_round_active`、`_pass_cursor`、
  `_phase_locked`、async kick/poll、finalizer pending、pass token 等字段。`ClimateDailySystem`
  的 snapshot owner 会在 `native_probe_state.climate_round_authority_ready=true` 时标为
  `native_ready`，active owner gate 打开时标为 `native_active`，并继续携带 GDScript mirror fields
  供 debug/compat 读取。
- `DCWorldExt` 现在暴露 `get_native_climate_round_state_report()` 与
  `reset_native_climate_round_state(reason)`。它们复用现有
  `AsyncClimateRoundState` worker 生命周期，报告 `request_pending`、
  `result_ready`、per-pass us、`total_rounds`、`total_reused` 等 native 侧状态；
  `simulation_authority=false` 表示这不是 ACTIVE simulation authority。state report 现在显式给出
  `climate_round_authority_ready=true`、空的 `climate_round_authority_blockers` 与
  `remaining_gdscript_authority`，并细分为 `remaining_gdscript_simulation_authority`
  与 `remaining_godot_boundary_authority`。默认 native-ready probe 仍列出
  `should_run_stride_policy` / `sync_sliced_fallback`；active owner gate 打开后，GDScript mirror
  会把 simulation authority 列表清空，只保留 Godot/MapData 与 reset/abort 边界。
  `reset_native_climate_round_state(reason)` 还会返回 `reset_boundary_intents`，当前包括
  `abort_active_pass`、`abort_all_climate_passes`、`reset_round_local_state`、
  `reset_async_lifecycle_local_state`、`reset_round_timings`、`reset_start_snapshots`、
  `reset_last_diagnostics`、`reset_transpiration_state`、`reset_dirty_season_state`、
  `seed_full_sweep_counter`。`ClimateDailySystem.reset_progress()` 按这些 intents 执行脚本侧
  reset/abort 边界动作，并在下次 async round 重新 register。
- `ClimateDailySystem` 的 async path 现在优先调用
  `native_climate_round_begin(static_knobs)`、`native_climate_round_kick(input)`、
  `native_climate_round_poll()`，旧 DLL 才 fallback 到
  `async_climate_round_register/set_static/kick/poll`。这些 facade 只集中 native
  worker lifecycle/report，不改变 GDScript 的 `_round_active` / `_phase_locked`
  owner。
- `native_climate_round_poll()` 的 facade 顶层会透出 `published_slots`、
  `published_slot_count`、`visual_dirty_intents`、`breakdown` 和 worker timing；同名字段也保留在
  `result` 内。`breakdown` 使用 ms 单位，字段对齐 daily/scheduler 日志
  (`pass_a_ms`、`wind_ms`、`worker_total_ms` 等)，因此 `ClimateDailySystem`
  不再需要从 `*_us` 原始字段重复拼装 pass 汇总。`published_slots` 来自 native poll 端实际
  `_flush_slot_to_map()` 成功的 slot，`visual_dirty_intents` 目前用于 sea-ice terrain flip
  的 render/upload 意图。这只是 publish/visibility report 下沉，GDScript 仍负责 atlas/Godot
  object 操作。
- Native climate lifecycle 现在增加 `native_climate_round_begin_round(ctx)` 与
  `native_climate_round_finish_round(ctx)`。它们在 `DCWorldExt.AsyncClimateRoundState`
  中记录 `lifecycle_round_active`、`phase_locked`、`lifecycle_async_kicked`、
  `lifecycle_poll_attempts` 和 `lifecycle_stage`。这是 climate round state-machine
  migration 的 PROBE/partial-authority 步骤：phase lock/lifecycle report 已由 native 记录。
  async wrapper 在 round start 时只计算 phase candidate 和诊断计时，随后调用 native begin-round，
  再从 native state 同步 `_round_active`、`_pass_cursor`、`_async_round_kicked`、
  `_async_round_poll_attempts` 和 `_async_round_kick_tick`；旧 DLL 没有 begin-round facade 时才回落到
  GDScript 本地预写。kick/poll 边界也继续优先同步这份 native lifecycle state；但 GDScript
  仍执行 round-start terrain sync、SoA transaction、finalize、dirty mark 和 Godot
  object/render upload。
- `native_climate_round_begin_round(ctx)` 会声明 `start_state_intents`，当前包括
  `set_round_active`、`set_phase_locked`、`set_pass_cursor`、`reset_async_kicked`、
  `reset_poll_attempts`、`record_tick_index`。这些 intent 描述 native 在 begin-round 时已经写入的
  lifecycle state；GDScript 只 mirror 这些状态。
- `native_climate_round_begin_round(ctx)` 同时声明 `boundary_intents`，当前包括
  `sync_runtime_terrain_views`、`begin_round_pass_state`、
  `soa_begin_climate_transaction`。这把 round-start boundary scheduling 的决策下沉到
  native lifecycle report；GDScript 只按 intents 执行仍必须留在脚本/MapData/Godot 侧的
  操作，并把耗时写回 `round_start_*` diagnostics。
- `native_climate_round_poll()` 在 `done=true` 时声明 `finish_boundary_intents`，当前包括
  `apply_sea_ice_flips`、`finalize_round`、`finish_native_lifecycle`。`ClimateDailySystem`
  通过 `_execute_async_round_finish_boundary_intents()` 执行这些动作，并继续把 flip/finalize/
  finish timing 写回 scheduler report。这样 round-finish boundary scheduling 已进入 native
  report，实际 Godot/MapData 操作仍由 GDScript 执行。
- `finalize_round` 内部动作也开始拆分为 native-declared
  `finalize_tail_boundary_intents`：`use_worker_finalizer_diag` 或
  `apply_gdscript_finalizer_fallback`、`advance_full_sweep_counter`、
  `publish_climate_breakdown`、`annual_log`、`soa_noop`、`soak_dump`、`integrity_check`、`finish_active_pass`、
  `reset_transpiration_state`、`reset_round_local_state`、`flush_pending_mark_dirty_all`、
  `mark_round_slots_stale`、`dump_round_slot_stats`。同步 fallback 不传该字段时仍走同一默认列表，
  因此行为保持一致。GDScript 仍执行这些 Godot/MapData/debug 侧动作，但顺序与存在性已由
  native lifecycle report 声明。

迁移方向：

- 把 job graph、read/write masks、stride policy、front packed snapshot、dirty lists 继续下移到 C++。
- GDScript fast tick 最终只调用 `run_native_sim_tick(ctx)` 并消费结构化 report。

## Player Map Overlay（cell-index + per-cell LUT）

玩家地图信息层复用 `DataOverlayLayer`，不建立第二套 overlay 子系统：

- `WorldRuntimeHost.set_map_overlay({mode, resource_id})` 接收统一请求。
- `DataOverlayBaker.bake_cell_lut()` 只遍历 `n_cells`，按 `cell.index` 向
  `WorldData.lut_dims` 写一个 RGBA8 texel；buffer、`Image` 对应的 texture 句柄在世界生命周期内复用，
  同尺寸使用 `ImageTexture.update()`。
- `data_overlay.gdshader` 先从静态 `enum_atlas_tex.GB` 解码 cell ID，再以 NEAREST 读取
  `overlay_lut`。无效索引、透明 texel、地图外区域直接透明。
- 世界生成/拓扑变化时才重绑 atlas、LUT 尺寸、bounds 和 wrap；普通 tick 不重建 quad 或静态索引图。
- daily graph 完成并 flush 后只置 dirty；同帧/连续事件合并，最多 10 Hz。首次开启、切换 mode/resource
  和世界重建后的显式请求立即刷新；关闭后停止 `_process`，不再编码或上传。
- 玩家路径禁止调用 `encode_overlay_atlas`、`cell_pixel_lists` 或构造 derived-size RGBA buffer。
  2400 cells、`lut_dims=(2048,2)` 时上传固定 16384 bytes（若 LUT 紧排为 2400 texel 则有效数据约
  9.4 KiB）；诊断通过 `map_overlay_diagnostics()` 暴露刷新、合并、耗时和 upload bytes。
- 资源储量读取 flush 后的 `MapData` reserve array；固定归一化参考值来自
  `ResourceProfileRegistry.reference_reserve(profile)`，与 Inspector 共用。零储量和 habitat 不匹配
  cell 透明，UI discovery 过滤不改变物理储量或经济权威。

这条链路是玩家信息遮罩的唯一动态路径。下面的 derived-resolution 路径保留给旧 debug 工具。

## Debug Data Overlay bake

主要入口：

- GDScript orchestration：`main.gd::_refresh_overlay_data` → `scripts/rendering/data_overlay_baker.gd::DataOverlayBaker.bake`
- C++ pixel fan-out：`gdext/src/world_ext.cpp::DCWorldExt::encode_overlay_atlas`
- 触发：`_on_day_changed` 顶部置 `_overlay_dirty=true`；fast tick 末尾消费。
- 不属于 SUS scheduler job，不计入 `sus/render/ui`，但同步阻塞主线程。

当前状态：**混合 C++/GDScript**（debug-overlay-perf v2，2026-06-12）。18 个 overlay mode 的 per-cell 采样（含 `latitude_buffer` / `atan2` / 非 schema 字段）留在 GDScript（仅 ~n_cells 次，分支重、零 bit-divergence 风险）；O(n_pixels) 的内层像素 fan-out（典型 ~62 万次写）+ buffer 清零下沉 `encode_overlay_atlas`。ext 缺失 / 旧 DLL / SoA 未建 / C++ 返回 fallback 时透明回退到 GDScript fan-out（`gdscript_fanout` / `gdscript_fanout_soa`）。

输入 / 输出：

| 项 | 来源 | 备注 |
| --- | --- | --- |
| cell SoA / facade 值 | `DCViewAdapter`（World 优先，Cell 兜底） | 与 info_panel 同一 adapter 实例避免 drift。 |
| `world.cell_pixel_lists` | MapBaker | 每 cell 覆盖像素 idx 列表（GDScript Dict fan-out 兜底用）。 |
| `world.cell_first_px_arr` / `cell_px_count_arr` / `flat_px_indices_arr` | MapBaker `_ensure_world_cell_pixel_csr` | 持久 SoA pixel CSR（按 `cell.index` 索引，整图一次性构建）；`encode_overlay_atlas` 零拷贝复用。 |
| `world.latitude_buffer` | MapBaker | CLIMATE_ZONE 通道用真实 ny。 |
| `world_ext: DCWorldExt` | main `get_data_core_world_ext()` | 提供 `encode_overlay_atlas`；缺失/旧 DLL 时透明回退。 |
| `existing_tex: ImageTexture` | main `_overlay_tex` 持久化 | size 匹配走 `update(img)`，不匹配 fallback 新建。 |
| `existing_buf: PackedByteArray` | main `_overlay_buf` 持久化 | 复用，避免每帧 2.4MB resize。 |
| `texture` + `buf` + `path` | 返回值 | caller 缓存复用；`path` ∈ {gdext_fanout, gdscript_fanout, gdscript_fanout_soa}。 |

关键性能契约（debug-overlay-perf v1 + v2）：

- **必须**持久化 `_overlay_tex` 跨调用。直接 `ImageTexture.create_from_image()` 每帧重建会触发 GPU 资源销毁 + VRAM 重分配，单次 5-15ms。
- **必须**让 buf 跨调用复用。每帧 `PackedByteArray.resize(N*4)` 触发 GC 抖动。
- **必须**用 dirty + skip_day 双 gate 节流。x20 倍速下 day_changed 每秒可触发 20-40 次；跳日帧 climate/weather 字段不变，重 bake 无意义。
- **应当**走 `encode_overlay_atlas`：cpp_path 下 GDScript 不再做 O(n_pixels) 内层像素写，buffer 清零由 C++ memset 承担；GDScript 仅清零用于兜底路径。

C++ fan-out 协议（debug-overlay-perf v2，2026-06-12，已实现）：

- GDScript 端 per-cell 采样产出三组 per-cell（按 `cell.index`）数组：`cell_r` / `cell_g`（RGBA8 的 R/G byte）+ `cell_valid`（0/1）。B 恒 0、有效 cell A=255。
- `encode_overlay_atlas` 复用 `world.cell_first_px_arr` / `cell_px_count_arr` / `flat_px_indices_arr`（整图 flat，first/count 直接索引，与 4 张视觉 atlas 共用语义），把每个有效 cell 的 `(R,G,0,255)` 扇出写到它覆盖的全部像素，并 `memset` 清零。
- 该 pass 不读 `_slots` / 不要求 `_bound`：overlay 数据全部由 GDScript 预采样喂入，地图刚生成 / climate slot 未绑定也能工作。
- bit-equal 由 `_fanout_cell_bytes_soa`（GDScript 等价兜底）保证；C++ 返回 `fallback=true`（仅参数非法）时调用它。

诊断字段：

- `main.get_overlay_last_bake_ms()` 暴露最近一次 bake 耗时；> 5ms 应警觉。
- `main.get_overlay_bake_path()` 暴露 fan-out 路径，确认 C++ 是否生效（应为 `gdext_fanout`）。
- `_overlay_stats` 内部含 `count / invalid_count / near_zero_count / buckets`，DebugConsole Telemetry 读取。

## Detail scatter（vegetation / 点缀散布，vegetation-visual-pcg 阶段 A）

主要入口：

- GDScript orchestration：`scripts/rendering/hex_renderer.gd`（按 `DecorationManifest` 或默认 grass/shrub/tree 生成 N 个 `ShrubLayer`）→ `scripts/rendering/shrub_layer.gd::_rebuild_instances` → `_rebuild_via_native`
- C++ per-instance fan-out：`gdext/src/world_ext.cpp::DCWorldExt::encode_detail_scatter`
- 触发：地图生成 / regenerate / 质量档切换时 `layer.setup()` → `_rebuild_instances()`（非每 tick，冷路径）。
- 不属于 SUS scheduler job，不计入 `sus/render/ui`。

当前状态：**混合 C++/GDScript + gameplay event bus 首个生产用例**。GDScript 只做 per-cell（N≤2400）廉价预计算（suitability / attempts / climate_presence / 基础色 / size_density）；O(Σattempts) 的逐候选热循环（jitter+warp、world_noise/micro_gap 门、water/river 拒绝、acceptance、score cap）+ MultiMesh buffer 组装下沉 `encode_detail_scatter`。`_world_ext` 缺失 / 旧 DLL 无该方法 / C++ 返回 `fallback=true` 时透明回退到 `shrub_layer.gd` 的 GDScript 逐实例路径（`_last_scatter_path` 暴露实际路径 `gdext` / `gdscript`）。

2026-06-26 起，vegetation succession 额外发布到 `DCWorldExt` 的 gameplay event bus：

- Native 发布点：`run_vegetation_dynamics_pass`、thread variant、`run_stage_b_pass` 在继续回填旧 `succession_indices/to_veg` 的同时发布 `VEGETATION_SUCCESSION`。
- GDScript 消费：`GameplayEventBus.poll_succession_cells(&"detail_renderer", ...)` 以独立 consumer cursor 读取事件，`MapGenerator.consume_pending_detail_scatter_refresh_indices()` 将 event bus dirty cells 与旧 pending indices 合并去重。
- 持久化/回放：`snapshot_gameplay_event_journal()` / `restore_gameplay_event_journal()` 只保存 POD/packed arrays，不保存 Godot Object；`replay_gameplay_events()` 可按 tick/type/source 过滤。
- 溢出诊断：`get_gameplay_event_bus_report()` 暴露 `event_count`、`dropped_event_count`、`oldest_event_id`、`newest_event_id`、`consumer_lag`、`native_ms`、`fallback_reason`。

### Economy event journal pipeline

`ECONOMY_GRAPH` 在 ledger、market、structure 和 BUILDING_GRAPH 语义提交点生成事件。market worker
只写 `MarketResult` 的 summary/detail fragment；主线程稳定 reduce 后写 native staging journal。
`aggregate_publish` 通过三项守恒审计才发布 committed batch。默认 SELECTIVE 不为未选中的
cohort/good 生成 delta legs，避免 10M cohort 的全量事件放大；PKEJ archive 直接按 committed
batch 流式编码，不先构造全量 Dictionary。

Chunked MultiMesh 路径：

- `HexRenderer.detail_scatter_chunked_multimesh_enabled=true` 时，每个 `ShrubLayer` 以固定 offset-grid chunk（默认 `detail_scatter_chunk_size_cells=16`）维护 `chunk_id -> MultiMeshInstance2D`。
- 全量 rebuild 成功路径为 `gdext_chunked`：`encode_detail_scatter` 返回整层 buffer 后 GDScript 按 `cell_indices` 拆分到 chunk MultiMesh。
- succession event refresh 路径为 `gdext_event_chunk`：dirty cells 先聚合为 dirty chunks，每个 dirty chunk 只把 `sample_cell_indices`、MapData/WorldData packed arrays 和 profile knobs 传给 `encode_detail_scatter_delta`；C++ 内部完成 per-cell state/profile suitability 采样、attempts/color 派生和 scatter buffer 生成，GDScript 只替换对应 chunk 的 `multimesh.buffer`。
- LOD 前缀排序同样下沉 encode（knob `lod_order_enabled` + `lod_near_density_multiplier`，SAME_SOURCE: `shrub_layer.gd::_lod_order_sources`）：C++ 在 buffer 组装前按 (cell_idx, seed) 排序、链式同 seed cluster（wrap 副本原子）+ 跨 cell rank 轮转排出远场前缀，返回 `lod_ordered=true` 与 `far_count`；`_apply_chunk_payload_direct` 收到后免 GDScript 排序、免整段 buffer 重排直接上传。旧 DLL / knob 关闭时透明回退 GDScript 复刻排序，两条路径语义同一契约（`tests/detail_scatter_lod_order_test.gd` 平价验证 far_count、远场前缀多重集与 wrap cluster 原子性）。A-B 开关：`ShrubLayer.native_lod_order_enabled`。
- `HexRenderer` 将 dirty batch 预拆成 `(layer, chunk_id)` task，按 `detail_scatter_refresh_chunks_per_frame` 与 `detail_scatter_refresh_apply_budget_ms` 分帧提交；全局实例预算通过 `apply_visible_instance_fraction()` 分摊到每个 chunk 的 `visible_instance_count`。
- chunk 的 cell index 列表和 world bounds 属于地图期稳定几何，`ShrubLayer` 按 `chunk_id` 缓存；仅在地图、`hex_size` 或 chunk size 改变时失效。相机/LOD 变化只失效 active-instance 汇总，不再重复执行 offset/cube 转换和逐 cell bounds 扫描。
- 全局实例预算总数采用 dirty-driven 汇总：普通帧复用 `_detail_budget_cached_total`，只在相机/LOD/画质、chunk 内容、family upload 或驻留淘汰改变可见实例集合后重扫各层。预算 fraction 仍按层切片下发，避免一次同步所有 MultiMesh 的 `visible_instance_count`。
- 单 chunk apply 会复用既有 `MultiMesh`，并对 native delta 返回的单 chunk buffer 直接赋值（原生序直通时零重排拷贝），避免重新分配 `MultiMesh` 和再复制一遍 `buffer`。
- 慢日志字段包含 `cells`、`chunks`、`sampled`、`active`、`water`、`ctx`、`knobs`、`native`、`apply`、`remaining`，预期 `[detail_scatter/SLOW_CHUNK]` 不再出现 dirty cells 累积到数百且单层 50ms+ 的全层 rebuild 模式；`sampled/active` 用于确认 native sampling 命中并区分“chunk 内采样 cell 数”和“真正参与散布的活跃 cell 数”。`water` 应主要由共享 offset-water cache 首次构建承担，后续 layer 应接近 0。
- `detail_scatter_budget_report()` 暴露 `budget_total_scan_count`、`budget_total_scan_ms`、`budget_total_dirty`；层级 `get_scatter_diagnostics()` 暴露 `chunk_cell_cache_entries/builds`、`chunk_bounds_cache_entries/builds` 和 `active_instance_count_scans`。稳态无变化帧应保持 `budget_total_scan_ms=0`，scan count 只在 dirty 事件后的下一次预算应用时增长。

输入 / 输出：

| 项 | 来源 | 备注 |
| --- | --- | --- |
| `keys` / `center_x,y` / `suitability` / `attempts` / `vitality` / `size_density` / `color_r,g,b,a` | `shrub_layer.gd` per-cell 预计算 | 仅"活跃 cell"（suitability>0 且 climate_presence>0.02）；长度 = K。 |
| `offset_is_water`（PackedByteArray，`grid_w*grid_h`，odd-r） | `shrub_layer.gd` 从 `_map` 栅格化 | C++ 复刻 `world_to_cube → cube_to_offset` 精确 `_is_water_position`；空位 / 越界置 1（拒绝）。 |
| `flow_buffer` + `flow_w,h` + `river_clear_threshold` | `WorldData.flow_buffer` / `derived_size` | C++ 复刻 `_bilinear_float` 做 river-body 拒绝。 |
| PCG / size / vitality 标量 | `ShrubVisualProfile`（质量档已解算的 `instance_cap` / `size_scale`） | 逐位对齐 GDScript fallback 同名公式。 |
| `buffer` + `instance_count` + `path` + `elapsed_ms` | 返回值 Dict | `buffer` = 每实例 16 float（transform2d 8 + color 4 + custom 4）；GDScript `multimesh.buffer = buf` 一次赋值。 |

关键契约：

- 纯 **buffer-encoder**：不读 `_slots`、不写 slot、不要求 `_bound`——散布是 render product，所有输入由 knobs flat PackedArray 喂入，地图刚生成 / climate slot 未绑定也能工作（同 `encode_overlay_atlas`）。
- `hash01` / `hash2i` / `value_noise2` / `smoothstep` 与 `shrub_layer.gd` 同公式同 64-bit 整型语义（GDScript `float`=double，`>>` 算术移位），native 与 fallback 输出近 bit-一致（仅 libm `sin` 末位差异）；这是确定性 stochastic 场，验收按聚合密度而非 bit-equal。
- MultiMesh 2D buffer 布局：`[xx, yx, 0, ox, xy, yy, 0, oy, r,g,b,a, u,v,seed,variant]`，与 `set_instance_transform_2d/color/custom_data` 等价。

## 后续迁移优先级

1. 消除仍会进入 `largest` 的 GDScript sliced apply，例如 transp/apply、weather commit object unpack、Pass-B sparse apply。
2. 对所有已发布 slot 的 C++ pass，确认 caller 不再重复 unpack/copy。
3. 把临时 knobs PackedArray 输入补成 schema slot，减少每 tick packing。
4. 将 ocean physical stage 状态机中可纯数据化的部分移入 C++ schedule graph。
5. 保留 GDScript object/UI/debug 层，但确保它们只读已发布 snapshot，不参与 hot-loop authority。
6. **Debug overlay bake**（已落地 v2）：pixel fan-out 已下沉 `encode_overlay_atlas`。后续可选项是把热门连续通道（TEMPERATURE/HUMIDITY/PRECIPITATION）的 per-cell 采样也搬到 C++（直读 schema slot），进一步消除 GDScript 的 ~n_cells 次 Dictionary 采样；收益边际，仅在长时间停留 Debug 通道时有意义。

## Climate / weather / ocean stability notes

This section records the current runtime contract for the climate stability
work landed from `docs/plans/climate-weather-ocean-stability-plan.md`.

### Weather field diagnostics and cold precipitation

- `main.gd` tile-data samples must carry `sample["weather"]` separately from
  `sample["climate"]`. CSV weather fields such as `weather_dirty_count`,
  `active_weather_ratio`, `field_commit_path`, and convergence diagnostics are
  authored by the weather breakdown, not by the climate daily breakdown.
- `WeatherSystem` passes cold-precipitation knobs into the field solve path:
  `cold_precip_as_blizzard`, `snow_classification_margin`, and the diagnostic
  `snow_cover_read_arr`. Both GDScript classification and
  `DCWorldExt::run_weather_field_solve_pass` use the same guard so meaningful
  precipitation below the snow band becomes `BLIZZARD` instead of cold `RAIN`.
  On land, existing snow cover >= 0.25 also lets cold precipitation below the
  melt band classify as `BLIZZARD` without the high-wind gate; water cells keep
  the wind-gated transition rule so snowy sea/lake diagnostics do not force
  low-wind ocean rain into blizzard.
- Warm ocean cores use the same exception in GDScript and
  `DCWorldExt::run_weather_field_solve_pass`: a warm/humid cell with
  `ocean_an > 0.12`, `instability > 0.80`, `precip > 0.10`, and `cloud > 0.26`
  classifies as `STORM` even if high-tail precipitation damping has pulled
  precip below the ordinary `0.16` storm threshold. This keeps tropical warm
  water convection from being downgraded to ordinary rain after the damping
  stage.
- Field precipitation now has a shared high-tail stability step in both
  `weather/field_solver.gd` and `DCWorldExt::run_weather_field_solve_pass`.
  `ClimateProfile` owns the tuning knobs:
  `weather_wet_terrain_precip_damping`, `weather_lake_precip_damping`,
  `weather_lake_evap_scale`,
  `weather_extreme_precip_soft_cap`, and
  `weather_extreme_precip_softness`. The damping is applied after
  `precip_raw / precip_floor / cloud_water_rain` are merged and clamped, before
  cloud-water and vapor sinks consume the rain amount. `weather_lake_evap_scale`
  is applied earlier at the evaporation source so lakes do not behave like open
  ocean vapor pumps before the lake precipitation damping tail step. Keep these
  positions synchronized across native and fallback paths.
- Rain-cloud consistency is enforced in both field solvers: cloud is recomputed
  after precipitation, marine cloud-water scour, and re-evaporation, with cloud
  floors for active rain cores, frontogenesis, land convection, and warm-ocean
  convection. Ocean cloud-water is also scavenged when no dynamic ocean drive is
  present. Keep these formulas synchronized with classification thresholds in
  `weather_system.gd::_classify_field_weather_core` and
  `wf_classify_field_weather_at` so weak drizzle/fog does not dominate land.
- Marine warm-humid rain release is deliberately gated by stronger humidity,
  cloud-water mass, and temperature support than the land convective path, but
  the warm/humid seed must remain broad enough to admit ordinary open-ocean
  rain. Current balanced thresholds are mirrored in C++ and GDScript:
  `warm_humid_marine=smoothstep(0.54,0.74,temp) *
  smoothstep(0.47,0.69,rh) * open_water`, seed weight
  `0.20 + wind_mag * 0.36`; the ocean release term `drv_hc` uses
  `rh 0.47..0.69`, `cloud_water 0.040..0.105`, `temp 0.54..0.74`, and final
  weight `0.68` (`0.60` multiplier on lakes). `run_weather_field_solve_pass`
  and `weather/field_solver.gd` still apply a post-rain marine relief/drying
  step when prior rain is high but `ocean_drive` is low. This is the root guard
  against stationary equatorial ocean rain locks: warm open water may seed
  mobile rain, but rain cells without sustained
  convergence/frontogenesis/monsoon/warm-current support should lose cloud water
  and vapor instead of oscillating indefinitely. CSV acceptance should show
  materially more ocean wet cells than the over-dry regression
  (`ocean wet014 p50=10` on `20260623_031330`) while keeping
  `locked_ocean_90pct` near zero.
- `MapData.weather_classification_temp_arr` and
  `MapData.weather_classification_moisture_arr` are recorder-only diagnostic
  mirrors of the field solver read snapshot. They are not DataCore schema
  slots. Use them to compare weather classification input against current
  `temp_arr` / `moisture_arr` when investigating cold rain or warm blizzard
  reports.
- `DCWorldExt::run_weather_field_commit_pass` reports convergence refresh
  data only for ticks where `refresh_convergence=true`. A flat convergence
  array on other ticks is expected cadence behavior, not a stale-write bug.
- Earth-like defaults now strengthen weather convergence cadence and gain
  (`weather_convergence_gain=0.50`,
  `weather_convergence_refresh_stride=2`) while reducing broad snow cover
  (`snowpack_accum_gain=0.08`, stronger melt, `snowpack_cover_full=0.32`,
  `snowline_temp_threshold=0.29`, `snowline_band=0.27`,
  `snow_accum_days_req=2`). This is intended to keep cold/elevated land snowy
  without letting lowland/plain snow coverage dominate the CSV distribution.

### Ocean current vector limits

- `PhysicalCirculationSolver.psi_to_ocean_current()` and
  `DCWorldExt::run_psi_solver_pass` apply the same final vector-magnitude
  clamp after response blending. `ocean_current_scale` controls PSI-gradient
  conversion; `ocean_current_max_magnitude` controls the final vector length.
- Current defaults keep the physical field below the old near-unit plateau:
  `ocean_psi_source_scale=0.06`, `ocean_current_scale=0.13`,
  `ocean_current_max_magnitude=0.65`, `ocean_thermal_current_weight=0.12`,
  `ocean_density_cold_weight=0.22`, and `ocean_density_ice_weight=0.12`.
  These are profile knobs, so existing saved resources may still override them.
- Per-component safety clamping may still exist as a guard, but the expected
  physical limit is the vector magnitude, not independent `x/y` saturation.
  Water-cell current magnitudes should therefore be bounded by
  `ocean_current_max_magnitude` in normal runs.
- `run_psi_solver_pass` reports `ocean_current_preclamp_p95`,
  `ocean_current_preclamp_max`, `ocean_current_clamp_count`,
  `ocean_current_clamp_ratio`, and `ocean_current_max_magnitude`. The same
  fields are cached by `MapBaker`, forwarded through `OceanCurrentsJob`, and
  exported by `TileDataRecorder` as `phys_ocean_current_*` columns.

### PSI solver SOR warm-start (plan/psi-warm-start, 2026-06-17)

- `run_psi_solver_pass` solves the ocean stream-function ψ with SOR
  (Gauss-Seidel + over-relaxation, `psi_sor_omega≈1.4`). The cost is roughly
  `n_water × 6 × psi_total_iters`; with ~2200 water cells the old 40-iteration
  cold start was the dominant ~1ms inside the recurring `phys_psi_init` peak
  (SLP prepass + PSI stacking on the same tick).
- The stream-function changes only slightly day-to-day (the daily delta is just
  the wind-stress-curl increment), so the previous tick's converged ψ is an
  excellent initial guess. The kernel now **warm-starts** by default: at pass
  start it seeds `psi[k]` from the last value published to the `cell_ocean_psi`
  slot (mapped via `water_to_cell[k]`) instead of zero. SOR then starts from a
  near-converged state and only needs to absorb the small daily residual.
- Knob `psi_warm_start` (default `true`) gates this. With warm-start on,
  `psi_total_iters` was lowered `40 → 16` (`MapBaker._PHYS_PSI_TOTAL_ITERS`),
  cutting the PSI stage from ~1ms to ~0.3ms while *improving* convergence
  quality versus a 40-iteration cold start. Set `psi_warm_start=false` (and
  raise iterations) only for cold-start A/B comparison.
- Knob `psi_early_exit_mode=off|balanced|perf` gates residual early exit.
  `balanced` uses `min_iters=8/residual_epsilon=0.00035`; `perf` uses
  `min_iters=6/residual_epsilon=0.00075`; both check every 2 iterations and
  cold-start adds 4 minimum iterations. The pass reports `psi_iters_run`,
  `psi_residual_final`, `psi_early_exit`, and `psi_mode`, and still respects
  `psi_total_iters` as the hard maximum.
- Cold-start safety: on the very first solve (or whenever the slot is missing /
  size-mismatched / warm-start disabled) `PSI_PREV` is null and ψ falls back to
  the zero initial guess, so behavior degrades gracefully. The initial bake's
  physical solve already publishes ψ to the slot, so SUS round 1 is normally
  warm too.
- Validation: watch `phys_slice`'s `ocean_delta_p95` — it should stay smooth
  (no large per-tick jumps). A sudden increase after lowering iterations means
  under-convergence; raise `psi_total_iters` or re-check that warm-start is
  engaging.

### Ocean physical / visual split

- `OceanCurrentsJob` owns two internal state machines. The physical authority
  round advances SLP, wind, PSI, currents, and upwelling. The visual round
  rasterizes and commits the pixel atlas from the latest published fields.
- A visual raster or pending visual commit must not keep the physical round
  alive. Physical solves can finish and start again while a visual raster is
  still catching up.
- With `ocean_visual_rebake_drop_stale=true`, a stale visual raster may be
  dropped and restarted from the newest physical snapshot. This preserves
  simulation authority at the cost of a temporarily stale atlas.

### Temperature transport anomaly state

- `cell_temperature_transport_anomaly` and
  `MapData.temperature_transport_anomaly_arr` are the authoritative low-pass
  TTA state. No schema change is required for the current plan.
- Ocean water and land paths no longer treat TTA as a scratch value that is
  reset to zero each round. The source anomaly is capped by
  `temperature_transport_anomaly_source_cap`, blended by
  `temperature_transport_anomaly_blend_rate`, and decayed by either
  `temperature_transport_anomaly_decay_rate` or
  `temperature_transport_anomaly_zero_current_decay`.
- Native scalar, SIMD, and threaded ocean water/land variants must use the same
  TTA knobs as the GDScript fallback path so A/B checks compare formulas rather
  than different stabilization policies.
- Runtime temperature values at exactly `0.0` are valid frozen-cell readings.
  Climate/ocean/wind paths must only fall back to geometric baseline when a
  temperature is NaN or infinite; using `temp > 0.0` as a validity check creates
  discontinuous jumps near the lower clamp.
## 建筑生产管线

### 家族分支影响管线

`FamilyTraitCatalog selector compile → deterministic FamilyTraitRoll → local sparse branch context →
FAMILY_COMMIT prestige review → Economy Modifier bucket / Trigger branch binding`。核心特性在成立时按
seed 与 stable family ID 无放回抽取；行为偏好直接参与合法投资、职业和 cohort variant 评分，
但不跳过硬门槛。威望只缩放分档效果，不缩放行为偏好。每个分支以人口/现金/本地建筑资产
25/35/40 加权，并使用 30 日错峰、80% 降级线和双评审滞回。

消费路径先计算 market-invariant base variant score，再用 family membership 人口权重和冻结 city
good factor 形成 cohort-local 最多 8 项栈上分数；普通需求量乘调整/基础分数比，生存下限不下降。
自然资源再生在 Modifier snapshot 变化时冻结为连续 POD，由 native pass 与 fallback 共同消费。
完成建筑和跨 cell 贸易事实只发布一次；TriggerRuntime 通过本地稀疏索引扇出，奖励回到下一次
Economy 安全边界。

`BuildingProfile → EconomyCatalog CSR → NativeEconomyRuntime BUILDING_GRAPH → committed building/
population/market snapshots`。岗位按本地 profession 匹配，owner lot 先占 owner job，employee
需求按 profession 使用稳定 prefix quotient 分配。采购意图容量取 owner/各 employee role 的最小
到岗比例，再受业主输入资金和 sample-day 有效 resource reserve 限制；实际产能额外受每项本地
输入库存限制。周期开始时仍存活人口先参与就业，不以前一周期满足度缩减岗位供给；连续三周期
严重负利润的 owner-lot 进入 `SUSPENDED_LOSS`，停产时不分配岗位、不采购、不生产、不贡献企业需求。
多个建筑组共享 owner signature 时，owner fill 总和按盈利/利用率优先级受该 cohort 存活人口约束；
household demography 和 structural commit 后再做一次只裁不招的 committed 对账，避免死亡后出现
建筑组幽灵填充。补招仍只发生在下一次 `building_employment`，不会改变已经完成的生产与工资结算。
`building_employment` 内部先完成失业池招聘，再对剩余 ACTIVE 非服务业主空缺执行一次冻结匹配：
目标按预期业主日收入降序、来源按收入升序，同民族且目标收入更高时使用
`seed/day/cell/target_group/source_group` 的确定性概率。同职业只改组填充，跨职业复用 cohort 迁移；
每个目标/来源组每周期最多成功一次。调度阶段、五日 cadence、DataCore slots 与 GDScript 权威边界不变。
有效可采储量合入尚未消费的负 pending
extra，避免跨经济周期重复超采。资源配方 CSR 额外编译 mode：`extract` 以有效储量限制产能并
发布负 delta；`capacity` 以 `reserve / (building_count × requirement)` 限产，但不写资源 delta。
小麦/玉米等农场走农业 capacity → crop goods，只有真正的采集/采矿/渔业边执行 extract。
资源边仍编译对齐的 access-mode 列，但当前契约只接受 `local/0`。GDScript catalog 与 native
configure 双重拒绝非零值；产能检查、扣减和 Inspector 可达储量都直接读取建筑本格，生产热循环
不再执行邻格 gather。

目录同时编译 `upgrade_family_id/upgrade_tier`。BUILD 在冻结国家科技下计算同族最高可用档，
旧档只拒绝新建；既有 owner-lot 的生产路径仍只检查自身科技。该规则不增加生产 stage 或存档
owner-lot 字段，快照仅发布 family/tier/highest/construction-available 冷查询列。

employee role 使用 `adaptive/fixed/none` role ABI。adaptive 工资取当地基础与岗位生活成本
上限，并向本地岗位合同工资 EMA 按周期涨跌幅收敛。生产前不支付工资；同一 owner 的基础工资
义务在产品出售后汇总，再按销售后现金稳定比例分配。仍未付清的 owner-lot 记录欠薪并取消奖金，
但不追溯停止本期生产。超过目标业主利润的 25% 形成奖金池。
基础工资和奖金均按本地同职业 `employee_employed` 权重分配，只在 cohort funds 间转账。

每个建筑 owner-lot 同时记录权威 `operating_state`、严重亏损/恢复连续数、采购意图容量、实际利润率，
以及本周期 `last_input_cost`、`last_wages_paid`、`last_wages_due`、
`last_base_wages_*`、`last_bonus_*`、`wage_suspended`、
`last_expected_revenue`、`last_operating_cost`、`last_margin_gap_q16`、计划利用率与
`last_resource_generated`，并与
`last_revenue` 一起通过选中地块的有界快照发布。UI 利润严格使用三者相减；这些字段不进入
MapData/DataCore，也不产生全局建筑财务矩阵。
建筑快照同时发布最近结算的 `period_days`，Inspector 将实际投入/产出总量按建筑数和周期天数
归一化为“单位/栋/日”；该值反映到岗、库存、资金和资源约束后的实际效率，不展示理论配方。
岗位 UI 使用 `owner_required` 和 `owner_openings`。`owner_capacity` 是物理 owner 槽位，
ACTIVE 组的 `owner_required` 始终等于完整物理容量；RECOVERY 组才按 recovery probe capacity
与 planned utilization 缩放，亏损停产/不可用组为零。`planned_owner_equivalent` 只表示利用率
折算后的生产等效人数，不是岗位需求。employee required 与产量仍按 planned utilization 缩放，
因此降低计划生产会降低每栋产量，而不会把仍在经营的自营业主迁入失业池。
UI 不再用建筑数量推断招聘空缺。
`projected_owner_income_per_day` 以 `max(owner_required, filled_owner)` 为分母，并把已结算的
自留物资生活价值计入经济收入。自留价值只抵扣生活成本，不产生现金或 money-audit delta。

生产 output 先按 owner 当前消费计划预留可直接满足的单组件 variant 商品，再把余量形成
cell-local offers。商人按 `max(可行日需求, 实际出库 EMA) + 出口 EMA` 和 target inventory days 计算库存缺口，冻结期初现金并
保留 12.5%，库存基线取 30 日并乘 good-specific 比例（必需品更高、奢侈品更低）。`producer price = retail price × merchant_buy_price_factor_q16`，默认系数 `62259/65536≈95%` 且为硬上限；短缺不会再把它抬到 100%。采购按 `缺口 × producer price` 的价值权重及稳定
good/group 顺序采购；库存达到目标时不再
收购。商人现金不足时，20% 零售价的生产者托底也只补足剩余目标缺口，超目标余量计入 discarded。household market 先用

国内贸易的目的地预算在派单批次内冻结为
`max(0, merchant_cash - existing_order_reserved_cash - 12.5% operating_floor)`，
并由候选裁量、利润裁剪和最终扣款共同消费；优先路线不能突破底线。CSV v19 的
summary 与 market 行追加 `merchant_cash`、库存零售/清算价值、总商业资产、采购
毛利、贸易买卖现金、经营流出、流动性覆盖率及采购金额加权有效收购系数。无经营
流出时覆盖率为 `Q16_ONE`，字段均为冻结边界上的派生观测，不参与保存或状态哈希。
留用品填充 owner need，不扣资金；未消费余量按来源建筑回记 discarded。所有热循环只访问
POD/vector/raw scalar，不访问 Godot Object 或 Dictionary。

现代目录把建筑显式编译为 `collector=0` 或 `industrial=1`。collector 必须有 resource CSR，
industrial 的 resource CSR 必须为空；两者都可有多个 goods input/output。30 个资源 reserve 与
extra-change slot 由 ResourceProfileRegistry 顺序驱动 natural-resource pass，经济 runtime 仍只
在 sample boundary 读取 raw slot pointers 并向 extra-change 发布 delta。

电力生产者由 output 的 `good_storage_modes=cycle_flow` 判定并在同一 cell 的普通生产前执行。
家庭需求不消费 cycle-flow 电力。金银 output 由 `good_monetary_issue_values` 进入实物锚定发行
分支并累计 `bullion_money_issued`；其余 offer 走缺口加权预算和商人现金保留规则。merchant owner
只允许两个无商品投入、无雇员、消耗匹配矿藏且单产金/银的早期 collector。

两相生产完成后，将受就业/资金/资源约束的可行采购意图、实际 offer（含 discarded、排除业主留用）
和输出单位成本聚合进稀疏 `MarketSignalStore`；居民消费、企业输入和建设消费另聚合为
`realized_withdrawal_ema`。多输出建筑可配置 Q16 cost shares；未配置时按冻结参考产值稳定分摊。
成本单位价包含实际原料、应付合同工资和目标营业利润；生活成本通过 adaptive 合同工资进入，
不额外重复叠加。这些信号只反馈下一周期 Price V3，不在本周期形成代数环。

滚动 PKEC v22 下，building plan 的业主生存利用率下限使用 cell-local 线性聚合，market signal
临时量只分配该 cell 的稀疏 CSR lane；investment 复用 epoch-transient `(cell,type)` 与
`(cell,resource)` 索引，并在 `building_commit_phase` 中按 cell range continuation。投资只处理
新增建筑：业主空缺仍由 employment 填补；资金充足 cohort 按“目标业主日收入高于当前人均
`income_ema`”进入确定性概率抽样，中签后才迁入建筑目录指定的业主职业。生产阶段则在
当前 `market_id == cell_id` 契约下按 due cell 并行：worker 直接写互不重叠的 cohort、building、
market、resource-delta 和 signal lane，把跨 cell 诊断、留用品、现金流及 trace 写入每 cell 的
`ProductionResult`。主线程按原 cursor 顺序归并后才推进 stage，因此 scalar/worker 的权威状态与
事件顺序一致。`building_production_worker_tasks` 报告实际选择的任务数，
`building_production_merge_ms` 报告包含在 `building_production_ms` 内的归并成本。结果 lane 由
runtime 长期持有，range 开始只重置逻辑长度和标量，保留 retained-output/cashflow/trace 容量；
`production_result_allocation_growth_count/bytes` 用于验证热稳态不再扩容。这个 scratch 不进入
PKEC v22 或 state hash。

2026-07-26 起，production 不再以 `cell_count >= worker_market_threshold` 作为并行前提。
每个 cell 按建筑组、输入候选、输出、岗位和资源边估算只读 work weight，再切成稳定连续
range；building-plan evaluate 采用同一方式，把饱和、信用、恢复和利用率计数留在 task-local
`BuildingPlanResult`，wait 后按 task id 归并。household market 的权重同时计入每市场固定商品
扫描、cohort 和建筑组成本。三条路径统一受 `economy_worker_task_cap` 限制，默认 12；cap 只改变
执行分区，不改变 cell/group/market 顺序、归并顺序或权威数据。生产的
`worker_weight_total/task_weight_min/task_weight_max/imbalance_q16_max/worker_cpu_ms`，
plan 的 `building_plan_worker_*` 和 closing market audit 的 `audit_worker_*` 是 transient
诊断，不进入存档/hash。

### Production climate capacity (PKEC v22)

`ProductionClimateProfile` is compiled by stable ID into fixed Q16 columns.
For a due building group, native prepare reads the cell's frozen 30-day
temperature and plant-available water:

```text
temp_fit  = clamp(1 - abs(temp_30d - temp_opt) / temp_tolerance, 0, 1)
water_fit = clamp(1 - abs(plant_water - water_opt) / water_tolerance, 0, 1)
raw       = min(temp_fit, water_fit)
capacity  = 1 - exposure * (1 - max(floor, raw))
```

An empty profile returns `Q16_ONE`; capacity never exceeds it. Building plan,
expected revenue, survival retention offers, investment prospective quantities,
and settlement reuse the same capacity helper. Employment reads the pre-climate
plan so climate does not cancel filled jobs or base contract wages. Input,
funding, and resource capacities are resolved before the climate cap; actual
input/resource withdrawals therefore fall with output. The existing global
output factor and Modifier factor remain in their prior order.

`last_capacity_q16` remains total executable capacity. The group additionally
publishes temperature fit, water fit, climate capacity, and climate-lost output.
Production reports count profiled/limited groups and average climate capacity.
Worker tasks write disjoint due cells and reduce in stable order, preserving the
scalar state hash.

Opening audit 在非校验日复用上一个精确 committed close，并单独刷新 native country cash/goods
贡献；`economy_full_audit_verify_interval_days`（默认 25 个模拟日，即 5 个经济周期）定期恢复完整 opening scan。closing
population/market/transit/escrow/country audit 和三项守恒检查仍每个 rolling transaction 完整
执行，因此这不是抽样审计，也没有放宽 `population/money/goods error == 0`。

The 2026-07-21 correction keeps this pipeline and authority unchanged. Building plan
uses a separate full-health subsistence target for food and cold-weather clothing.
Production emits source-group retained goods; household settlement returns sparse
frozen-value credits, and the main-thread merge recomputes realized margins before
investment. Household settlement is the sole working-capital protection point, while
production retains only the uncovered wage reserve. Employment releases a suspended
Investment candidate evaluation mirrors that split conceptually: survival food/clothing is bounded
by prospective owner livelihood, removed from merchant-sellable quantity, and valued at frozen retail
only as an in-kind offset. It does not write goods, cash, or audit state before construction exists.
The lifecycle uses the same economic split for owner-only self-employment: positive cash plus in-kind
business surplus prevents suspension, while any uncovered livelihood remains a household welfare and
demography outcome. This avoids whole-group owner release/recovery oscillation without creating jobs,
goods, or money.
owner only when an active non-service owner vacancy can receive that person through the
existing unemployed-pool path. Investment reads actual offered-supply EMA and caps its
output-deficit utilization by input stock/supply coverage instead of nameplate capacity.
No stage, bridge, slot, save, hash, or cadence contract changes.

The current investment scan admits every output driver with positive marginal
deficit and positive projected utilization into the existing viability path.
Shortage pressure and utilization rank candidates directly. Historical
sell-through discounts projected merchant cash revenue, while discard remains
an output/utilization diagnostic; neither is a hard profitability gate. The
legacy minimum-shortage and minimum-utilization policy fields remain serialized
for PKEC compatibility but do not filter or normalize candidates. Target margin,
payback, sponsor capital, materials, input coverage, conditions, and natural
resources remain authoritative approval checks.

Price V3 now forks two transient calculations from the same frozen market signals. The
merchant branch keeps the full good-specific inventory horizon for procurement and
trade. The price branch caps its safety-stock horizon at the five-day settlement period,
then combines flow imbalance, short inventory, realized shortage, production cost, and
inactive-price reversion. The result is rate-limited and guarded only to positive
`int32`; legacy catalog price bounds do not feed back into settlement or trade relief.
`price_inventory_target` is snapshot diagnostics only. This adds no authority, stage,
save field, or hash input.

The 2026-07-22 lifecycle correction excludes service buildings from producer profit states.
An owner-occupied producer with no settled production advances toward suspension and then
releases every owner into the unemployment pool. Suspended input users retain only a 1/6 or
1/32 unfunded demand probe. Failed liquidation reviews advance only for physically and
financially executable probes whose counterfactual margin is still below the restart
threshold; blockage resets the review streak. Both new lanes are transient and preserve the
existing graph and save layout.

## CSV writer backpressure (current)

The debug-only economy recorder keeps its two preallocated POD batches. If both
are occupied, committed capture waits for the worker to return one to `FREE`;
temporary writer saturation no longer terminates recording with `queue_full`.
This preserves every committed epoch without allocating a third world-sized
snapshot. `backpressure_wait_count` and `backpressure_wait_ms_total` expose the
resulting fast-forward delay. Row limits and real file/flush failures remain
terminal with whole-epoch rollback. Economy state, CSV columns, PKEC, hash, and
schedule are unchanged.

## Native moisture stability transaction (2026-07-24)

Climate moisture remains authoritative in the C++ `cell_moisture` slot. Pass-A's
default generated-background relaxation remains `0.24/day`; at the 10-day
native cadence its effective response is about `0.936`. Large completed-round
changes are intentional climate behavior. Stability comes from freezing visible
moisture between slices and publishing once per completed round, not from
over-damping the response. Weather distribute continues to update precipitation,
soil moisture, water balance, snowpack, cover, and temperature, but
`weather_direct_moisture_enabled=false` by default prevents a second direct
write into climate moisture. Pass-A is therefore the default weather/hydrology
integration point.

Pass-A no longer multiplies land moisture by `1 + 0.2 * insolation_dev`.
The generated `base_moisture` is static; seasonal moisture now emerges through
the existing chain `solar geometry -> temperature/ocean heat -> evaporation ->
wind transport/convergence -> precipitation -> soil/water balance -> moisture`.
The default vapor/precipitation/soil/water-balance weights are respectively
`0.12 / 0.78 / 1.82 / 1.04`. Negative soil and rolling-water-balance
anomalies use separate `2.21 / 1.30` weights, deepening drought minima without
changing positive hydrology gains or adding direct seasonal forcing. The earlier
`tile_data_record_20260724_203555.csv` replay established the symmetric-weight
baseline only; a new post-build recording is required to quantify the asymmetric
drought minima and low-end clipping distribution.

Transpiration now treats `output * transpiration_outflow_rate` as transport:
the donor subtracts the transported amount and valid land neighbors receive the
same total. `transpiration_self_rate` remains the vegetation moisture source.
Standalone and fallback passes retain their existing immediate-publish behavior.
### Initial vegetation ecology bundle (2026-07-31)

`run_native_world_generate_full_pass` remains the sole generation authority. Its post-base order is `base geography -> final elevation/landform -> priority-flood/lakes/river graph -> riparian and floodplain moisture -> final moisture -> one whole-map ecological vegetation pass -> continuous-state initialization`. The pass uses the coastal-adjusted generation temperature shared with terrain, the VegetationProfile Gaussian climate fit, and the bounded `pk_vegetation_terrain_weight` soft prior. Ordinary terrain/landform is never a hard vegetation mapping; physical substrate gates alone may reject candidates. No vegetation, desert, badlands, rift, patch, or area quota is applied.

The returned bundle must contain `vegetation_arr`, `vegetation_vitality_arr`, `plant_available_water_arr`, `soil_moisture_arr`, `water_balance_30d_arr`, `vegetation_growth_pressure_arr`, `vegetation_heat_stress_arr`, `vegetation_drought_stress_arr`, `vegetation_cold_stress_arr`, and `vegetation_regen_score_arr`, each exactly `n_cells`. Suitability is a transient scratch value and is not a DataCore component. GDScript only validates and assembles the arrays; `MapData.set_pending_generation_ecology()` applies them after the generic `init_soa_from_bake()` bootstrap so zero-filled initialization cannot erase native generation state. Missing arrays are a hard generation error.

Runtime vegetation dynamics (`run_vegetation_dynamics_pass`, threaded path, merged `run_stage_b_pass`, and GDScript fallback) consume the same climate score multiplied by terrain/landform soft weight for vitality targets and succession candidates. Streak, cooldown, and weather-stress contracts remain unchanged. Generation diagnostics publish `vegetation_native_ms`, candidate/none counts, score min/mean/max, plant-water nonzero land count, river-adjacent and coastal-highland desert counts, and soft-weight min/max.

### Vegetation distribution rebalance (2026-08-02)

The generation/runtime authority remains the native full pass with a GDScript mirror. The temperate forest moisture gate is `0.42` (previously `0.48`), while the tropical JUNGLE/rainforest wet-tail gate is `0.64` (previously `0.56`); monsoon and tropical dry forest occupy the intermediate shoulder. Wet forest and wetland profiles use an asymmetric moisture fit: deficit is penalized normally, while surplus moisture retains only `0.25` of the Gaussian distance as a waterlogging cost. Explicit saturated substrates (`SWAMP`, `MANGROVE`, `DELTA`, `FLOODPLAIN`) reject the continuous tropical-rainforest candidate and compete through marsh, swamp, mangrove, or monsoon profiles. Runtime low-vitality succession scans all allowed terrestrial profiles for the best climate/terrain suitability instead of only the two succession-graph neighbors, while preserving compatibility gain, streak, and cooldown gates. This prevents low-fit rainforest or grassland from becoming trapped by a locally incomplete succession chain.
