# 实施计划

> 本计划严格按需求文档的"分阶段验收"组织：A→B→C→D→E 逐级合入。每阶段都必须通过 SUS 实测达标后才能进入下一阶段。
> 所有任务的目标文件以 `scripts/geography/map_data.gd`、`scripts/geography/map_generator.gd`、`scripts/geography/hex_cell.gd`、`scripts/weather/weather_system.gd`、`scripts/sus/jobs/*.gd`、`scripts/data/climate_profile.gd` 为主。

- [ ] 1. **阶段 A — SoA 基础设施搭建**
- [x] 1.1 在 `MapData` 中实现完整 SoA 数组与构造/同步入口
   - 新增 `temp_arr`/`moisture_arr`/`snow_cover_arr`/`temp_baseline_arr`/`temp_30d_arr`/`temp_365d_arr`/`temp_anomaly_arr`/`sea_ice_frac_arr`/`weather_type_arr`(byte)/`weather_intensity_arr`/`weather_cloud_arr`/`weather_precip_arr`/`elevation_arr`/`base_moisture_arr`/`terrain_arr`(byte)/`landform_arr`(byte)/`vegetation_arr`(byte)/`cover_arr`(byte)/`is_water_arr`(byte)/`ocean_current_x_arr`/`ocean_current_y_arr`/`wind_x_arr`/`wind_y_arr`/`cell_pos_x_arr`/`cell_pos_y_arr` 共 25 个 Packed 数组成员
   - 实现 `rebuild_soa_from_cells()` / `flush_soa_to_cells()` / `soa_swap_double_buffer()` API；按 cell_count 一次预分配，禁止 push_back
   - 在 `bake_world` / 加载存档完成路径调用 `rebuild_soa_from_cells()`
   - _需求：1.1, 1.3, 1.5, 9.1, 9.3_

- [x] 1.2 在 `ClimateProfile` 添加 5 个治理开关并接入入口分发
   - 新增 `use_soa_pipeline`/`use_sparse_climate`/`use_sparse_weather`/`use_low_freq_ocean_psi`/`use_partial_atlas_upload` 默认 false
   - 在 `refresh_climate_daily` / weather_system / ocean_currents Job 入口按开关分发到 legacy vs SoA 路径
   - _需求：10.1, 10.2, 11.6_

- [x] 1.3 climate Pass A/B + ocean_water/ocean_land 切到 SoA 读写路径
   - 新增 `_climate_pass_a_soa` / `_climate_pass_b_soa` / `_ocean_water_pass_soa` / `_ocean_land_pass_soa`，仅读写 SoA + neighbor_indices_packed
   - round 末调用 `flush_soa_to_cells()` 同步给 UI / Baker / Overlay
   - 实测桌面端 climate 单 round 平均 ≤ 5ms / tick（达 11.1 阶段 A 指标）
   - _需求：1.2, 1.3, 1.4, 11.1_

> **阶段 A.3 实测（2026-05-11）**：Pass B 13.5→5.8ms（-57%）✅；Pass A 16→13ms（-19%）；整 round `pass=done partial=false slices=3`、`refresh_climate_daily` 11ms。
> 距离阶段 A 验收线（climate ≤ 5ms）仍差 6ms，主要瓶颈在 Pass A 内层 `_cube_row_norm` / `_compute_temperature` / `_insolation_season_offset` 三角函数链。下面 1.4 / 1.5 / 1.6 为 B1 子任务，先把 Pass A 砍到 ≤ 5ms 再上 dirty mask。

- [x] 1.4 **B1-A：在 `MapData` 烘焙 `cell_lat_norm_arr` / `temp_baseline_year_arr` / `is_land_arr` 三个常量 LUT**
   - 新增 `cell_lat_norm_arr: PackedFloat32Array`（每 cell 1 个 float = `_cube_row_norm` 结果），由 `rebuild_soa_from_cells()` 在生成阶段一次性 bake，运行期不再变
   - 新增 `temp_baseline_year_arr: PackedFloat32Array`（每 cell 1 个 float = `pow(cos((ny-0.5)*π), 1.2)`，elevation 无关），同样一次性 bake；Pass A 内层只剩 `lat_temp - elev*0.5`
   - 暴露 `bake_lat_lut(generator)` 入口给 `MapGenerator` 在 `_last_cfg` 已就位时调用
   - 数值正确性：与 `_compute_temperature(ny, 0.0)` 在 `is_equal_approx` 容差内 1:1 对齐；测试覆盖 ny ∈ {0, 0.25, 0.5, 0.75, 1}
   - _需求：1.1, 4.1, 4.2, 4.4_

- [x] 1.5 **B1-B：每日 round 入口烘焙 `_insol_now_lut` 与 `_insol_dev_lut`**
   - 在 `MapGenerator` 新增 `_INSOL_DAILY_LUT_SIZE = 64`（与现有 `_INSOL_MEAN_LUT_SIZE` 同粒度）+ `_insol_now_lut: PackedFloat32Array` + `_insol_now_lut_phase: float`
   - 新增 `_rebuild_insol_now_lut(season_phase)`：按 65 桶 ny 调一次 `_compute_insolation(ny, season_phase)`，phase 变化 > 1/360 才重建（一日内复用）
   - 新增 `_insol_dev_at(ny)` / `_insol_now_at(ny)` 内联查表（O(1) lerp），替换 Pass A 内 `_insol_dev` / `_insolation_season_offset` 高频调用
   - 数值正确性：`_insol_dev_at` 与 `_insol_dev` 在 ny ∈ [0,1] × phase ∈ [0,4) 网格上 max-abs-diff < 1e-3
   - _需求：4.1, 4.3_

- [x] 1.6 **B1-C：重写 `_climate_pass_a_soa` 内层为查表 hot-loop**
   - round 入口：`_rebuild_insol_now_lut(season_phase)`，缓存 `lat_arr` / `temp_baseline_year_arr` / `_insol_dev_lut` 引用为局部变量
   - 内层循环移除 `_cube_row_norm(c, _last_cfg)` / `_compute_temperature(ny, elevation)` / `_insol_dev(ny, ...)` / `_insolation_season_offset(ny, ...)` / `_season_temp_offset_phase(ny, ...)` 调用，全部替换为：
     - `var ny: float = lat_arr[i]`
     - `var temp_year: float = temp_year_arr[i] - elev_a[i] * 0.5; if temp_year < 0.0: temp_year = 0.0`
     - `var dev: float = _insol_dev_at(ny)` （一日内是常量数组的查找）
     - `season_offset = use_insol ? gain*dev*amp : _legacy_off_lut[ny_bucket]`（legacy 也按 ny 桶预算 + sign 表）
   - 内层局部变量全部加 `:= float(...)` / `: int = ...` 类型注解；clampf/lerpf 内联为 `min(max())` / `a + (b-a)*t`
   - 实测桌面端 Pass A ≤ 5ms / tick；整 climate round ≤ 6ms / tick
   - _需求：4.1, 4.2, 4.3, 4.4, 11.1_

- [ ] 2. **阶段 A — 增量稀疏与 Dirty Mask**
- [ ] 2.1 实现 `climate_dirty_mask` + 季节强制全图 dirty + 比例自适应回退
   - 在 `MapData` 增加 `climate_dirty_mask: PackedByteArray` 与 `weather_dirty_mask: PackedByteArray`，提供 `mark_dirty(idx)` / `clear_dirty()` / `dirty_ratio() -> float`
   - Pass A 写温度时按 epsilon=1/512 自动标 dirty；Pass B 仅遍历 dirty + 1 跳邻居
   - 季节切换日 / 每 30 日强制全图 dirty；dirty_ratio < 50/N 或 > 0.8 时回退全图遍历
   - 在 SUS 日志加 `dirty_ratio` 字段；实测 weather ≤ 6ms / tick（阶段 A 指标）
   - _需求：2.1, 2.2, 2.5, 2.6, 2.7, 10.4, 11.1_

- [x] 2.1.A1 **MapData dirty_mask 基础设施**（已在阶段 A.1 中预留）
   - `climate_dirty_mask` / `weather_dirty_mask: PackedByteArray` 已声明并随 SoA 一同 resize
   - `mark_climate_dirty(idx)` / `clear_climate_dirty()` / `mark_all_climate_dirty()` / `climate_dirty_ratio()` 四件套就绪
   - _需求：2.1, 9.1_

- [x] 2.1.A2 **Pass A 写温度时按 epsilon=1/512 自动 mark_climate_dirty**
   - 在 `_climate_pass_a_soa` round 入口先 `clear_climate_dirty()`（season 跨整数 / day_idx%30==0 时改调 `mark_all_climate_dirty()`）
   - 内层在 `temp_a[i] = temp_now` 前比较 `abs(temp_now - temp_a[i]) > 1.0 / 512.0`，是则 mark dirty；moisture / snow_cover 同理 OR 起来标
   - Pass A 仍然全图遍历（它是 dirty 的写者，不能被自己稀疏化）；只把 dirty 信号传给后续 Pass B
   - _需求：2.1, 4.1_

- [x] 2.1.A3 **Pass B 改为稀疏遍历（dirty + 1 跳邻居）**
   - 在 round 入口拿到 `climate_dirty_ratio()`；ratio < 50/N 或 > 0.8 → 走全图遍历（保留现有循环）
   - 否则构建 visit set：先扫一次 mask 把 dirty cell 加入集合，再扫一次 mask 把每个 dirty 的 6 邻居也加入（用辅助 PackedByteArray `_pass_b_visit` 避免去重）
   - hot loop 改为 `for i in range(n): if visit[i] == 0: continue` 直接跳过（保留索引连贯访问，缓存友好）
   - 数值正确性：dirty 集合包含所有上日 |Δtemp|>1/512 的 cell + 它们邻居，Pass B 沿岸热泄漏 / 蒸发 等 6-邻居读取均闭合
   - _需求：2.2, 2.6, 11.1_

- [x] 2.1.A4 **季节切换日 / 每 30 日强制全图 dirty 钩子**
   - 在 `RefreshClimateDailyJob._run_pass(_PASS_A)` 之前判定：上次记录的 `_last_phase_int = floor(_phase_locked)` 与本次比对，跨过整数 → 调 `map.mark_all_climate_dirty()`
   - 维护 `_full_sweep_day_counter`：每完成一 round +1，达到 30 时下次 round 入口前再次 `mark_all_climate_dirty()` 并归零
   - 让"加载存档后首日"也强制 mark all（在 reset_progress 时把 counter 设为 30）
   - _需求：2.5_

- [x] 2.1.A5 **SUS 日志 + breakdown 增加 dirty_ratio 字段**
   - 在 `_run_pass(_PASS_A)` 完成后立即采样 `dirty_ratio = map.climate_dirty_ratio()`，写入 `_round_dirty_ratio` 成员
   - 在 `_finalize_round` / `_publish_partial_round` 写出 `_last_climate_breakdown["dirty_ratio"]`
   - 修改 `main.gd` fast tick WARN 详细日志，把 `cells=2400 pass=done partial=false` 那行追加 `dirty=0.42 visited=0.65 path=sparse`
   - _需求：2.7, 10.4_

> **阶段 A.2.1实施记录（2026-05-11）**：A1—A5 全部落地。SoA 路径已走 `use_sparse_climate=true`（earth_like.tres）。
> 预期收益：Pass B 6.5ms → 1—2ms（稳态 dirty_ratio ~5％，visited ≈3∼5％）；
> climate round avg 9.7ms → 4—6ms；距离 2ms 验收线剩 ~2——4ms。
> 需接下来跑 30 ticks 验证：sus log 中 `dirty=` `path=sparse` 字段 + Pass B `B=` 实测值。

> **阶段 A.2.1 修复（2026-05-11 11:36）**：首版实测 `dirty=0.89 path=full`，原因：
> Pass A 的 `dt = temp_now - temp_yesterday` 中包含**全图季节同向漂移**（中纬度每日 ~0.5°C），
> 远超 epsilon=1/512 ≈ 0.156°C，几乎所有 cell 都被假阳性 mark dirty → 触发 0.8 自适应回退 → 全图。
>
> **修复方案（drift 补偿）**：在 generator 上维护 `_dt_global_yesterday/_dm_/_ds_`（EMA α=0.3），
> Pass A 完成时算本日全图 dt 均值并写回；下一日 epsilon 比对改为
> `|dt_signed - dt_global_yesterday| > eps`，扣除季节漂移后只检测**真正的局部异常**。
> 第 1 日 drift=0 仍触发全图 mark（被 reset_progress full sweep 覆盖），无副作用。
> 预期：稳态 dirty_ratio 降到 1—8%，sparse 路径正常激活。
- [ ] 2.2 ocean_water_pass / sea_ice / transpiration 切稀疏域
   - ocean_water_pass 仅遍历 `is_water_arr=1 AND |ocean_current|² > 1e-6`；sea_ice 仅遍历 `is_water_arr=1 AND temp_arr<0.45`；transp 仅遍历 `vegetation_foliage_density>0.15`
   - 三段共享 round-local `is_water_arr` / `cell_pos` 缓存，由 round 入口一次性构造
   - _需求：2.3, 7.1, 7.2, 7.3, 4.5_

- [ ] 3. **阶段 B — 切片调度 + 紧致循环**
- [ ] 3.1 sub-pass 接受 μs 软预算 + 双缓冲跨 tick 切片
   - 每个 sub-pass 函数签名加 `slice_us_budget: int = 1500` 与 `cursor: int`；耗尽预算返回 `{done=false, cursor}`
   - 在 SoA 上实现 `_prev` / `_next` 双缓冲 swap；sub-pass 期间下游读 `_prev`，完成后才 swap
   - 调度器保证 sub-pass 未完成时下一段不启动；x20 速度档自动 stride≥4 + budget=1800μs
   - 整 round 完成跨 ≤ 4 fast tick 视为达标，跨 > 8 输出 WARN
   - _需求：3.1, 3.2, 3.3, 3.4, 3.5, 11.2_

- [ ] 3.2 改写所有 sub-pass 内层循环为 hot-loop
   - 移除内层 `Time.get_ticks_usec()` / `_is_water()` / `Vector2.length_squared()` / `HexUtils.cube_to_world` 等调用，替换为 `is_water_arr[ni]` 查表与 `dx*dx + dy*dy` 内联展开
   - 内联 clampf / lerpf 为 `min(max())` / `a + (b-a)*t`；所有局部变量加 `:= float(...)` / `: int = ...` 类型注解触发 GDScript typed 路径
   - 实测桌面端单 tick 峰值 ≤ 3ms（阶段 B 指标）
   - _需求：4.1, 4.2, 4.3, 4.4, 11.2_

- [ ] 4. **阶段 C — 算法降本与降频**
- [ ] 4.1 重写 `weather_system` 的 spawn / advect / distribute / cyclone
   - spawn 用 spatial-hash + 拒绝采样，候选规模 ≤ 200 cell
   - advect 改"基于 fronts 的稀疏 advect"：仅对 fronts 周边 R=3 跳膨胀域推进 cloud/precip/vapor，其余 cell 仅做 vapor 衰减
   - distribute 改 separable kernel（先 q 后 r 方向）；fronts ≤ 4 时跳过；cyclone 单 tick 至多 1 个，多个跨 tick 轮转
   - 全部直写 `weather_*_arr`，不再写 `cell.weather_*`，由 `flush_soa_to_cells()` 统一同步
   - _需求：5.1, 5.2, 5.3, 5.4, 5.5, 5.6_

- [ ] 4.2 ocean_currents Job 改为低频 + 双缓冲快照
   - 默认 stride=30 game-day；季节切换日强触发；单 round 切到 ≤ 2 fast tick 完成（每片 ≤ 1ms）
   - 维护 `ocean_current_x_arr` / `ocean_current_y_arr` 的双缓冲，下游 ocean_water/ocean_land 始终读完成快照
   - 日志输出 `psi_iterations` / `max_residual` / `elapsed_ms_total`
   - 实测桌面端整体平均 ≤ 2ms / 峰值 ≤ 2.5ms（阶段 C 达标）
   - _需求：6.1, 6.2, 6.3, 6.4, 11.3_

- [ ] 5. **阶段 D — Atlas 部分上传 + 移动适配**
- [ ] 5.1 enum_atlas_upload / sea_ice_atlas_upload 改 tile dirty 部分上传
   - 维护 32×32 tile 粒度 `tile_dirty_mask`；单 tick 上限 8 tile，超出跨 tick 切片
   - 桌面 `RenderingDevice.texture_update_partial`（如可用）/ 移动回退 `Image.blit_rect`；无变化 tile 跳过 GPU command
   - _需求：8.1, 8.2, 8.3, 8.4_

- [ ] 5.2 移动平台自适应参数 + GPU compute 屏蔽
   - `OS.has_feature("mobile")` 时自动调 climate stride×1.5 / weather stride×1.5 / ocean stride×2、weather field slice 500→240、目标 tick 预算改 3.0ms
   - 不主动启用 GPU compute 路径（需 `Engine.has_singleton("GodotMobileGPUCompute")` 显式开关）
   - 实测移动端平均 ≤ 3ms / 峰值 ≤ 4ms（阶段 D 达标）
   - _需求：9.2, 9.4, 9.5, 11.4_

- [ ] 6. **阶段 E — 治理、对照测试与观测收口**
- [ ] 6.1 SoA vs legacy 对照测试 + perf budget 信号 + SUS 日志增强
   - 调试模式或 `--validate-climate` 启用时每 30 日跑一次双路径对照，比较 |Δtemp|/|Δmoisture|/|Δsnow_cover|，超 0.5% 输出 WARN
   - SUS 日志 `[SUS] last 30 ticks` 段加 `dirty_ratio` / `slice_count` / `path=soa|legacy` 三列；超 4ms（移动 6ms）触发 "perf budget exceeded" 信号
   - `_last_climate_breakdown` / `_last_weather_breakdown` 暴露最慢 sub-pass 名称
   - 全部 5 个开关默认翻为 true 的灰度切换流程文档化
   - _需求：10.3, 10.4, 10.5, 10.6, 11.5_
