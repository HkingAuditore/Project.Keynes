# 气候 / 环境 / 天气 子系统 ≤2ms tick 预算优化

## 引言

本需求文档针对当前 ProjectKeynes 中三个 SUS Job 集合：`refresh_climate_daily`（6 个 sub-pass）、`weather_refresh`（advect/spawn/dist/cyclone + field solver）、`ocean_currents`，以及附属的 `enum_atlas_upload`、`sea_ice_atlas_upload`、`season_refresh`。

**当前实测耗时**（2400 cell 地图）：
- `refresh_climate_daily` 单 sub-pass 平均 11.87ms、p95 16.92ms、最大 22.52ms；整 round 6 sub-pass ≈ 80ms。
- `weather_refresh` 平均 16.73ms、p95 24.36ms（spawn 5.4 + adv 2.9 + dist 2.3 + commit/stage_b）。
- `ocean_currents` 平均 10.09ms。
- 单 fast tick `sus=30~33ms` 是常态，远超目标。

**优化目标**：
1. 单 fast tick 上述子系统总 CPU 时间的**平均值 ≤ 2.0ms**、**p95 ≤ 2.0ms**、**最大值 ≤ 2.5ms**（容忍 20% 抖动）。
2. **不降游戏内推进语义**：气候每 game-day 推进一次的语义不变；玩家在 x1/x5/x20 速度档下感知到的"云在动、温度在变"频率不变。
3. **移动平台兼容**：方案不能依赖桌面级 GPU 特性（如 SSBO 大容量、64-bit atomics、compute shader workgroup ≥ 1024）。GLES3 / Vulkan Mobile feature level 必须可跑。
4. **数值一致性**：6 sub-pass 之间因果依赖（pass_a → pass_b → ocean_water → ocean_land → sea_ice → transp）保持；跨段不出现"半套数据"导致的肉眼可见漂移。
5. **可回退**：所有新路径都有开关，关闭后回到现有 GDScript 实现。

## 需求

### 需求 1：SoA 化数据布局

**用户故事：** 作为引擎开发者，我希望气候/环境/天气计算读写的所有热字段从 `HexCell` 对象数组（AoS）迁移到平行 `PackedFloat32Array`/`PackedByteArray`（SoA），以便 CPU 缓存命中率提高、为 GPU 化做准备、并消除 GDScript Variant 装箱开销。

#### 验收标准
1. WHEN 系统初始化地图 THEN MapData SHALL 维护与 `_cells` 等长的 SoA 数组：`temp_arr`、`moisture_arr`、`snow_cover_arr`、`temp_baseline_arr`、`temp_30d_arr`、`temp_365d_arr`、`temp_anomaly_arr`、`sea_ice_frac_arr`、`weather_type_arr`(byte)、`weather_intensity_arr`、`weather_cloud_arr`、`weather_precip_arr`、`elevation_arr`、`base_moisture_arr`、`terrain_arr`(byte)、`landform_arr`(byte)、`vegetation_arr`(byte)、`cover_arr`(byte)、`is_water_arr`(byte)、`ocean_current_x_arr`、`ocean_current_y_arr`、`wind_x_arr`、`wind_y_arr`、`cell_pos_x_arr`、`cell_pos_y_arr`。
2. WHEN 任意 sub-pass 运行 THEN 它 SHALL 仅通过 SoA 数组与 `neighbor_indices_packed()` 的 PackedInt32Array 进行读写，禁止 `for cell: HexCell in map.all_cells()` 风格循环。
3. WHEN sub-pass 完成 round THEN MapData SHALL 提供一次性 `flush_soa_to_cells()` 把 SoA 回写到 `HexCell` 强类型成员，供 UI / Baker / Overlay 等只读消费者使用。回写也走 SoA → 一次循环 hash-free 赋值。
4. IF UI 选中某 cell THEN 该 cell 的实时字段 SHALL 直接从 SoA 索引读取，不依赖 `flush_soa_to_cells()` 节拍。
5. WHEN 地图重生成 / 加载存档 THEN 系统 SHALL 提供 `rebuild_soa_from_cells()` 一次性同步入口。

### 需求 2：增量稀疏更新（Dirty Mask）

**用户故事：** 作为系统设计者，我希望每个 sub-pass 只重算"上一日真正发生变化的 cell"集合，以便把每 tick 工作量从 O(N) 降到 O(K)，K ≪ N。

#### 验收标准
1. WHEN climate Pass A 写温度 THEN 系统 SHALL 用 `abs(new - old) > epsilon_temp`（epsilon_temp = 1/512）判定该 cell 为 dirty，写入 `climate_dirty_mask: PackedByteArray`。
2. WHEN climate Pass B 运行 THEN 它 SHALL 只遍历 `climate_dirty_mask` 为 1 的 cell **及其 1-跳邻居**（因为 Pass B 用邻居的 anomaly 做沿岸热泄漏）。
3. WHEN ocean_water_pass 运行 THEN 它 SHALL 只遍历 `is_water_arr=1 AND |ocean_current|² > 1e-6` 的 cell（典型为整张地图水域的 30~50%）。
4. WHEN weather_field_solver 运行 THEN 它 SHALL 用 `weather_dirty_mask` 限制 advect 与 distribute 只跑"有云/有锋面影响范围内"的 cell；该 mask 由当日 fronts 的 AABB 膨胀 N 跳生成。
5. WHEN 季节切换日（season_phase 跨过整数边界）THEN 系统 SHALL 强制全图 dirty 一次，避免稳态稀疏化吃掉缓变趋势。
6. WHEN dirty cell 数 < 50 OR > 0.8×N THEN 系统 SHALL 自动回退到全图遍历或单帧多片（避免极少 dirty 反而不划算 / 极多 dirty 反而开销翻倍）。
7. 系统 SHALL 在 SUS 调试日志中输出 `dirty_ratio` 字段，便于运行时调参。

### 需求 3：跨 fast-tick 摊匀（Cell-Granular Slicing）

**用户故事：** 作为调度者，我希望即使某日 dirty cell 集合较大，也能把它平均切到多个 fast tick 上，以便单 tick 峰值受控。

#### 验收标准
1. WHEN 任意 climate sub-pass 启动 THEN 它 SHALL 接受 `slice_us_budget`（微秒级软预算，默认 1500μs）参数；运行至预算耗尽时把进度（cell_cursor）保存到 Job 局部状态、返回 `done=false`。
2. WHEN sub-pass 跨 tick 切片期间 THEN 该 sub-pass 读写的 SoA 数组 SHALL 进入"双缓冲"状态：读上一日的 `_prev` 数组、写当前日的 `_next` 数组；只有整个 sub-pass 完成才 swap。
3. WHEN 某 sub-pass 还未完成而下一个 sub-pass 试图启动 THEN 调度器 SHALL 拒绝启动（保持现有 cursor 推进语义）。
4. WHEN 整 round 完成跨 ≤ 4 个 fast tick THEN 视为达标；跨 > 8 个 fast tick THEN 系统 SHALL 在日志输出 WARN，提示降低工作量或加 frame_budget。
5. IF 用户切到 x20 速度档（1 fast tick = 1 game-day 强 tick） THEN 系统 SHALL 自动把 climate stride 调到至少 4，并把每个 sub-pass slice_us_budget 升到 1800μs，让"高速档下也能整 round 在 4-6 tick 完成"。

### 需求 4：邻居循环 hot-loop 重写（Tight Loop）

**用户故事：** 作为性能工程师，我希望把每个 sub-pass 内层的 6-邻居循环改写为 SoA 索引 + 局部变量缓存的紧致循环，以便单 cell 处理时间从 ~5.66μs 降到 ~1.5μs。

#### 验收标准
1. WHEN sub-pass 运行 THEN 内层循环 SHALL 不调用 `Time.get_ticks_usec()` / `is_water()` 函数 / `Vector2.length_squared()` 这类按调用计算的工具；改用提前缓存的 `is_water_arr[ni]` byte 查表与 `cur_x*cur_x + cur_y*cur_y` 内联展开。
2. WHEN 邻居取向量 THEN 代码 SHALL 用 `nb_x = cell_pos_x_arr[ni] - self_x` 而不是 `HexUtils.cube_to_world` 重算（位置数组在 map 加载时一次性 bake）。
3. WHEN clampf / lerpf 出现 THEN 优先内联为 `min(max(...))` 与 `a + (b - a) * t`，避免 Variant 装箱（GDScript 4.x 已部分优化但仍有开销）。
4. WHEN 内层循环 THEN 全部局部变量 SHALL 标 `:= float(...)` / `: int = ...` 以触发 GDScript 类型化路径。
5. WHEN 同一 round 内多个 sub-pass 都需要 `cell_pos`、`is_water`、`neighbor_indices` THEN 它们 SHALL 共享一份 round-local 缓存，由 Job round 入口一次性构造。

### 需求 5：天气 Spawn / Distribute / Advect 的算法降本

**用户故事：** 作为天气系统维护者，我希望 `weather_tick` 内的 `spawn=5.4ms`、`adv=2.9ms`、`dist=2.3ms` 三段被算法级压缩，以便不依赖切片就能把 weather_refresh 从 16ms 降到 ≤ 4ms。

#### 验收标准
1. WHEN `spawn` 阶段运行 THEN 它 SHALL 用 spatial-hash + 拒绝采样替代当前的全图 cell 候选扫描，候选集预筛后规模 ≤ 200 cell。
2. WHEN `advect` 阶段运行 THEN 它 SHALL 改为"基于 fronts 的稀疏 advect"：只对 fronts 周边 R=3 跳膨胀域内的 cell 推进 cloud/precip/vapor，其余 cell 仅做 vapor 衰减（O(N) 但无邻居访问）。
3. WHEN `distribute` 阶段运行 THEN 它 SHALL 用 separable kernel（先 q 方向、后 r 方向）替代当前的 6-邻居全卷积，缩减一半 memory traffic。
4. WHEN cyclone 路径 THEN 限制单 tick 至多处理 1 个 cyclone（多个 cyclone 跨 tick 轮转）。
5. WHEN front 数 ≤ 4 THEN 系统 SHALL 跳过 distribute 阶段（fronts 太少时其贡献可忽略）。
6. WHEN 天气场字段写入 SHALL 直接写 SoA 数组（`weather_*_arr`），不再写 `cell.weather_*` 强类型成员；`flush_soa_to_cells()` 在 round 结束时统一同步。

### 需求 6：洋流 ψ 求解的频率与精度妥协

**用户故事：** 作为模拟设计者，我希望 `ocean_currents` Job 的 SOR 迭代不再每日运行，以便它从 fast-tick 关键路径上彻底移走。

#### 验收标准
1. WHEN ocean_currents Job 启动 THEN 它 SHALL 默认 stride = 30（约一个游戏月一次），并在每次启动时把整个 SOR 求解限制到 ≤ 2 个 fast tick 完成（每片 ≤ 1ms）。
2. WHEN 季节切换日 THEN ocean_currents 立即触发一次 round（覆盖默认 stride）。
3. WHEN ocean_currents 在跑 THEN 下游 `ocean_water_pass` / `ocean_land_pass` 读取的 `ocean_current` 字段 SHALL 来自上一次完成的 round 结果（双缓冲），保证读到一致快照。
4. WHEN ocean_currents 完成 THEN 它 SHALL 在日志输出 `psi_iterations`、`max_residual`、`elapsed_ms_total`，便于观察收敛性。

### 需求 7：海冰 / 蒸腾 / 反馈的合并与降频

**用户故事：** 作为简化派维护者，我希望 sub-pass 4/5（sea_ice_daily / transpiration）合并为一个 fused pass 并把工作量进一步降低。

#### 验收标准
1. WHEN sea_ice_daily 运行 THEN 它 SHALL 只对 `is_water_arr=1 AND temp_arr < 0.45` 的 cell 进入主循环（典型为 < 30% 水域）。
2. WHEN transpiration 运行 THEN 它 SHALL 只对 `vegetation_foliage_density > 0.15` 的 cell 进入主循环（典型为 < 50% 陆域）。
3. WHEN 两段融合执行 THEN 它们 SHALL 共享 round-local `is_water_arr` / `cell_pos` 缓存，避免重复构造。
4. IF feedback（weather → climate slow buffer）也合并 THEN 它 SHALL 复用同一遍 cell 扫描，三合一摊到 ≤ 1.5ms。
5. WHEN 合并后单段超过 1.5ms THEN 系统 SHALL 启用 cell-granular slicing（与需求 3 一致）。

### 需求 8：Atlas Upload 的零成本化

**用户故事：** 作为渲染对接维护者，我希望 `enum_atlas_upload` / `sea_ice_atlas_upload` 不再上传整张纹理，以便它们的 fast-tick 成本降到 ≤ 0.3ms 且在移动 GPU 上稳定。

#### 验收标准
1. WHEN atlas 上传运行 THEN 它 SHALL 维护一个 `tile_dirty_mask`（按 32×32 tile 粒度），只上传当 tick 真正变化的 tile。
2. WHEN 单 tick dirty tile 数 > 8 THEN 上传跨多 tick 切片完成（每 tick 上限 8 tile）。
3. IF 设备为移动 GPU（`OS.has_feature("mobile")` true）THEN 上传 SHALL 使用 `RenderingDevice.texture_update_partial`（如可用）或回退到分块 `Image.blit_rect` 路径。
4. WHEN tile 内无变化 THEN 该 tile SHALL 跳过 GPU command（不调用 RD update）。

### 需求 9：移动平台兼容性约束

**用户故事：** 作为移动版发行者，我希望所有优化在中端 Android（Adreno 640 / Mali-G77 级别）上跑得动，且不引入额外的能耗热点。

#### 验收标准
1. WHEN 任何新数据结构 THEN 它 SHALL 仅使用 `PackedByteArray` / `PackedFloat32Array` / `PackedInt32Array` / `PackedVector2Array`，禁止 `Array[Variant]` 在热路径出现。
2. IF 任何步骤考虑 GPU compute THEN 它 SHALL 使用 Godot 4 `RenderingDevice` 的 compute pipeline，且 workgroup ≤ 64、buffer ≤ 4MB、不依赖 64-bit atomic 或 subgroup 操作。
3. WHEN 启用任何 SIMD-like 优化（如把 6 邻居展平到 PackedFloat32Array 一次读 6 个 float） THEN 实现 SHALL 完全用 GDScript 原生数组操作，不依赖 GDExtension 或平台特定 intrinsic。
4. WHEN 移动平台启动 THEN 系统 SHALL 通过 `OS.has_feature("mobile")` 自动调高 stride（climate ×1.5、weather ×1.5、ocean ×2）、降低 weather field slice cell budget（500 → 240），把目标移动 tick 预算定为 **3.0ms**（而非 2.0ms）。
5. WHEN 移动平台运行 THEN 系统 SHALL 不主动触发 GPU compute 路径，除非 `Engine.has_singleton("GodotMobileGPUCompute")` 这类显式开关启用。

### 需求 10：观测、回退与开关治理

**用户故事：** 作为运维者，我希望所有新路径都可观测、可逐项关闭、可对照旧路径输出做数值校验。

#### 验收标准
1. WHEN 优化路径启用 THEN `ClimateProfile` SHALL 新增独立开关：`use_soa_pipeline`、`use_sparse_climate`、`use_sparse_weather`、`use_low_freq_ocean_psi`、`use_partial_atlas_upload`，默认全部 false（项目首次接入时保持 legacy 行为）。
2. WHEN 任何开关从 true → false THEN 系统 SHALL 在下一次 round 入口安全切回 legacy GDScript 路径，不出现半新半旧的混合状态。
3. WHEN 调试模式（`OS.is_debug_build()` 或显式 `--validate-climate`）启用 THEN 系统 SHALL 每 N 日（默认 30）做一次"新路径 vs 旧路径"对照运行，比较 SoA 数组与 HexCell 字段的逐 cell 数值差，若 |Δtemp|/|Δmoisture|/|Δsnow_cover| 超 0.5% THEN WARN。
4. WHEN SUS 日志输出 THEN `[SUS] last 30 ticks` 段 SHALL 增加 `dirty_ratio` / `slice_count` / `path=soa|legacy` 三列。
5. WHEN 目标未达成 THEN 系统 SHALL 通过 `_last_climate_breakdown` / `_last_weather_breakdown` 暴露最慢 sub-pass 名称，便于针对性继续优化。
6. WHEN 任何子系统单 fast tick > 4ms（移动平台 > 6ms）THEN 系统 SHALL 在日志触发"perf budget exceeded"信号，便于自动化测试集成。

### 需求 11：分阶段验收

**用户故事：** 作为项目经理，我希望优化按阶段交付而非一次性大爆炸，以便每阶段都可独立合入主干。

#### 验收标准
1. **阶段 A（SoA 基础设施 + Dirty Mask）**：完成需求 1、2 后，桌面端 climate 平均耗时 SHALL 降到 ≤ 5ms/tick，weather ≤ 6ms/tick；不动调度策略，仅做数据布局与稀疏化。
2. **阶段 B（细切片 + 紧致循环）**：完成需求 3、4 后，桌面端单 tick 峰值 SHALL ≤ 3ms。
3. **阶段 C（算法降本 + ocean 降频）**：完成需求 5、6、7 后，桌面端平均 ≤ 2ms / 峰值 ≤ 2.5ms（达标）。
4. **阶段 D（Atlas + 移动适配）**：完成需求 8、9 后，移动端目标平均 ≤ 3ms / 峰值 ≤ 4ms 达标。
5. **阶段 E（治理与回退）**：完成需求 10、11 后，所有开关与对照测试就绪，可以默认开启新路径。
6. WHEN 任一阶段未达指标 THEN 该阶段 SHALL 不合入主干，回到该阶段的子任务继续打磨；不允许"跳级合入"。

## 非目标（明确不在本次范围）

- **GPU compute 化**：本方案在桌面与移动端都坚持 CPU SoA + 稀疏 + 紧致循环；GPU compute 作为未来 *选项* 保留接口（需求 9.2 限定其形态），但不属于"达成 2ms"的承诺路径。
- **算法物理意义重构**：现有气候/天气模型的物理常量、季节相位、Ekman/SOR 数值方法本身不动，只动数据布局、调度与稀疏域。
- **跨地图尺寸通用性证明**：本目标仅承诺当前 2400 cell 量级；对 8000+ cell 大图需另立项。

## 风险与对策

| 风险 | 对策 |
|---|---|
| SoA ↔ HexCell 双向同步引入新一致性 bug | 强制单向：sub-pass 只写 SoA，round 末 flush；UI 通过 SoA 直读，不允许 sub-pass 期间读 HexCell 字段 |
| Dirty mask 在长时间稳态下漏更新 | 季节交界强制全图 dirty + 每 30 日强制 full sweep |
| 跨 tick 切片导致下游 weather 读到半套 climate | 双缓冲 `_prev`/`_next`，sub-pass 期间下游始终读 `_prev` |
| 移动 GPU 上 PackedArray 内存压力 | 数组按 cell_count 一次预分配，不 push_back；bytes 字段优先使用 PackedByteArray 节省 4× |
| 玩家在 x20 速度档感知到的"动得变慢" | 在高速档下自动调高 stride 而不是慢速档；x1 档保持最敏感的更新频率 |
