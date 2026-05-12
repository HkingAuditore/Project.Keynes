// 新建 requirements.md - climate-data-core-migration

# 需求文档 — Climate 系统 DataCore 迁移（E 阶段）

> 上一期"DataCore 基石 + Weather 首次迁移"已 close-out（参见 `.codebuddy/plan/dots-foundation-and-weather-migration/`）。本期把 `refresh_climate_daily` 全链路（6 个 sub-pass）也迁到 DataCore，验证基石的 cell-level 双缓冲 + 多 sub-pass 切片能力。

---

## 1. 引言 / 背景

### 1.1 当前 Climate 现状

`refresh_climate_daily` 已经在上一阶段被 `RefreshClimateDailyJob` 切片化为 6 个 sub-pass：

| # | sub-pass | 现状 | 当前耗时（ms）| 数据形态 |
|---|---|---|---|---|
| 0 | climate_pass_a | 已 SoA（`_climate_pass_a_soa`，B1 LUT 已落）| ~3.5–4.5 | MapData PackedArray 直读直写 |
| 1 | climate_pass_b | 已 SoA（`_climate_pass_b_soa`）| ~5.7–6.8 | MapData PackedArray + 邻居 |
| 2 | ocean_water | 半 SoA（混读 HexCell）| ~3.5–7.0 | HexCell + ocean_current_arr |
| 3 | ocean_land | 半 SoA | ~3.0–5.0 | HexCell |
| 4 | sea_ice_daily | HexCell AoS | ~4.5–5.5 | HexCell.sea_ice_fraction |
| 5 | transpiration | HexCell AoS（默认关闭）| ~4.0 | HexCell.weather_intensity 等 |

整 round 总耗时（实测）：~9.5–10.5ms（C 阶段窗口数据），主要由 SUS frame_budget 摊薄到 2~3 个 tick。

### 1.2 上一期遗留 / 本期对接点

**上一期已就绪的基石**：
- `DCWorld.bind_map_data(map)` 已在 [map_generator.gd](../../Project/project-keynes/scripts/geography/map_generator.gd) `_setup_sus` 内调用（`use_data_core=true` 时）
- 25 个 cell-level component 已经按引用挂入 World（含 temp_arr / moisture_arr / sea_ice_fraction_arr / ocean_current_x_arr 等）
- `DCQuery` / `DCComponentView` / `topology()` API 全部就绪
- `bind_world` 已在 SusJob 基类落地

**本期对接点**：
- RefreshClimateDailyJob 已通过 `bind_world` 拿到 World 引用（但目前未使用）
- 6 个 sub-pass 当前直接调 `generator._climate_pass_a` 等私有方法，**不走 World**
- pass_a / pass_b 内部已经走 PackedArray，迁移成本最低；ocean / sea_ice / transp 还有 HexCell 残留

### 1.3 本期目标

把 climate 6 个 sub-pass 全部迁到 DataCore Query/View 形态，达到：

1. **架构同源**：weather + climate 两个最大模块共享同一套 World 数据视图与 Query API，证明基石可被多 system 复用
2. **零回归**：refresh_climate_daily round 平均耗时 ≤ 迁移前 110%（~11ms），p95 ≤ 14ms
3. **零行为漂移**：30 day A/B 对照（用 `--validate-climate` 类似机制）：temp_field_hash / moisture_sum / sea_ice_sum / transp_sum 与 legacy 路径在阈值内
4. **基石压力测试**：通过本次迁移暴露 DCWorld 在"6 个 sub-pass × 跨 tick × 多组件读写"场景下的所有真实问题

### 1.4 不在本期范围

- ❌ 引入 GDExtension / C++ 重写 hot loop
- ❌ Compute Shader / GPGPU
- ❌ 进一步切分 sub-pass（保持现有 6 段）
- ❌ archetype 物理重排（仅暴露 API，不实现）
- ❌ 把 weather climate 的子算法本身改写（仅做数据访问层迁移）

---

## 2. 名词约定（继承上一期）

| 术语 | 含义 |
|---|---|
| **Cell Entity** | World 中 idx ∈ [0, cell_count) 的 entity，对应 MapData 中一个 HexCell |
| **Climate Component** | cell-level component：temp / moisture / snow_cover / temp_baseline / temp_season_offset / temp_30d_mean / temp_365d_mean / temp_dev_from_annual / sea_ice_fraction / ocean_current_x / ocean_current_y / wind_x / wind_y |
| **PassCursor** | RefreshClimateDailyJob 的 sub-pass 进度游标（0..5） |
| **DriftStats** | Pass A 末尾计算的 `_dt_global_yesterday / _dm_global_yesterday / _ds_global_yesterday` 漂移补偿值 |

---

## 3. 需求

### 需求 1 — climate 注册 / bind 与组件清单

**用户故事**：作为 climate 模块作者，我希望本期开始时 World 已经把 climate 涉及的所有 cell-level 数组当作"标准 component"挂好，不需要在 sub-pass 内现场注册。

#### 验收标准
1. WHEN `DCWorld.bind_map_data(map)` 完成 THEN 系统 SHALL 已经把以下 PackedArray 按引用挂为 component：
   - 必有：`CELL_TEMP / CELL_MOISTURE / CELL_SNOW_COVER / CELL_SEA_ICE_FRACTION / CELL_OCEAN_CURRENT_X / CELL_OCEAN_CURRENT_Y / CELL_WIND_X / CELL_WIND_Y`
   - 已有但需补：`CELL_TEMP_BASELINE / CELL_TEMP_SEASON_OFFSET / CELL_TEMP_30D_MEAN / CELL_TEMP_365D_MEAN / CELL_TEMP_DEV_FROM_ANNUAL`
2. WHEN 任意上述数组在 MapData 上不存在或长度 ≠ cell_count THEN 系统 SHALL 在 bind 阶段 push_error 并阻止启动
3. WHEN climate 需要 dirty mask 标记 THEN 系统 SHALL 通过 `world.view_u8(CELL_DIRTY_MASK_CLIMATE)` 复用现有 `MapData.climate_dirty_mask`，不重复分配
4. IF 双缓冲启用（如 pass_a 写 temp 但下一 sub-pass 仍要读旧 temp）THEN 系统 SHALL 通过 `world.commit_round([CELL_TEMP, ...])` 在 round 末统一 swap；首版（本期）若不需要双缓冲（因为 sub-pass 之间是单向链）则 SHALL 不强制启用

---

### 需求 2 — Pass A SoA 迁到 Query

**用户故事**：作为 RefreshClimateDailyJob 的 pass_a 段维护者，我希望把 `_climate_pass_a_soa` 改造成"通过 World View 取数组、通过 Query 选 dirty 子集"的形式，与 weather 的 sub-pass 同款。

#### 验收标准
1. WHEN job 进入 pass_a sub-pass THEN 系统 SHALL 通过 `world.view_f32(CELL_TEMP)` / `world.view_f32(CELL_MOISTURE)` 等取得 PackedArray 引用，hot loop 内不调用 `MapData.temp_arr` 直接访问
2. WHEN dirty mask 启用 THEN 系统 SHALL 用 `world.query().with(CELL_TEMP).readwrite(CELL_TEMP).with_dirty_mask(mask).for_each_index(callback)` 来选目标 cell；callback 内仍走 hot-loop PackedArray 索引
3. WHEN dirty mask 不启用（B1 LUT 路径）THEN 系统 SHALL 走 `query().for_each_index(callback)` 全图遍历，行为与现有等价
4. WHEN pass_a 完成 THEN drift stats 的更新逻辑（`_dt_global_yesterday` 等）SHALL 与 legacy 数值完全一致（A/B hash 比对通过）
5. WHEN ClimateProfile.use_data_core_climate=false THEN 系统 SHALL 退回 `_climate_pass_a_soa` 直读 MapData 的 legacy 路径，零行为差异
6. WHEN 迁移完成 THEN pass_a 的耗时 SHALL ≤ 迁移前 110%（~5ms）

---

### 需求 3 — Pass B SoA 迁到 Query + 邻居遍历

**用户故事**：作为 pass_b 段维护者，pass_b 涉及邻居访问（局部气候耦合的 6 邻居平均），我希望它通过 `world.topology()` 取邻居索引，hot loop 内仍是单层 PackedArray 索引。

#### 验收标准
1. WHEN job 进入 pass_b sub-pass THEN 系统 SHALL 通过 `world.topology().neighbors_packed()` 取得邻居 PackedInt32Array（首版直接复用 MapData.\_neighbor\_indices 的同一份引用）
2. WHEN 进入内层循环 THEN 系统 SHALL 在循环外取一次 `var temp_view = world.view_f32(CELL_TEMP)` 等，循环内通过 `temp_view[neighbor_idx]` 访问，零反射
3. WHEN sparse 路径启用（dirty_ratio ∈ [50/N, 0.8]）THEN 系统 SHALL 通过 `query().with_dirty_mask(visit_mask).for_each_index(...)` 遍历，等价于现有 `_pass_b_visit_mask` 路径
4. WHEN pass_b 完成 THEN 输出 dirty_ratio / visited_ratio / pass_b_path 字段 SHALL 与 legacy 完全一致
5. WHEN 迁移完成 THEN pass_b 耗时 SHALL ≤ 迁移前 110%（~7.5ms）
6. WHEN ClimateProfile.use_data_core_climate=false THEN 系统 SHALL 走 legacy 路径

---

### 需求 4 — Ocean water/land 双段迁移

**用户故事**：作为 ocean_water / ocean_land 维护者，这两段对 ocean_current_x / ocean_current_y 的读取目前混合 HexCell + PackedArray，我希望统一走 World View。

#### 验收标准
1. WHEN job 进入 ocean_water sub-pass THEN 系统 SHALL 通过 `world.view_f32(CELL_OCEAN_CURRENT_X) / view_f32(CELL_OCEAN_CURRENT_Y) / view_f32(CELL_TEMP)` 拿数据
2. WHEN ocean_water 内部读 cell.is_water THEN 系统 SHALL 通过 `world.view_u8(CELL_TERRAIN_FLAGS)` 或现有 `is_water_arr` 机制（按当前 MapData 的 SoA 扩展） —— 若该字段尚未挂为 component，本期 SHALL 顺手补挂
3. WHEN ocean_water 写 temp 时 THEN 系统 SHALL 通过 view 直接写 PackedArray，**写后由调用方负责 dirty mask 更新**（与 pass_a 行为一致）
4. WHEN ocean_land 紧跟 ocean_water 调用 THEN 数据接力 SHALL 通过 World View 完成（不再依赖 HexCell.temperature 中转）
5. IF ClimateProfile.enable_ocean_heat_transport=false THEN 系统 SHALL 像 legacy 一样跳过两段
6. WHEN 迁移完成 THEN ocean 两段总耗时 SHALL ≤ 迁移前 110%（~7ms）

---

### 需求 5 — sea_ice / transpiration 段迁移

**用户故事**：作为 sea_ice / transpiration 维护者，这两段是 climate round 末尾的 HexCell 慢路径，我希望也走 PackedArray。

#### 验收标准
1. WHEN sea_ice_daily sub-pass 运行 THEN 系统 SHALL 通过 `world.view_f32(CELL_SEA_ICE_FRACTION) / view_f32(CELL_TEMP)` 等读写，HexCell.sea_ice_fraction 仅在 round 末由 `MapData.flush_soa_to_cells` 刷回（行为与 weather 迁移一致）
2. WHEN transpiration sub-pass 运行 THEN 系统 SHALL 通过 `world.view_f32(CELL_MOISTURE) / view_f32(CELL_WEATHER_INTENSITY)` 等读写
3. WHEN 这两段任意字段尚未在 MapData 上有 SoA 镜像 THEN 系统 SHALL 在本期补出 SoA 字段（参照 weather 迁移的"先建 SoA、再绑 component、最后改 hot loop"三步法）
4. WHEN 迁移完成 THEN 两段总耗时 SHALL ≤ 迁移前 110%（~10ms）
5. WHEN ClimateProfile.enable_local_climate_coupling=false THEN transp SHALL 像 legacy 一样跳过

---

### 需求 6 — RefreshClimateDailyJob 接入 World

**用户故事**：作为 SUS Job 调度者，我希望 RefreshClimateDailyJob 在 `bind_world` 后能复用 weather job 已有的"按 use_data_core_climate 开关分发到 legacy / data_core 路径"模式。

#### 验收标准
1. WHEN job._init 完成且 SusScheduler.bind_world 注入 World THEN job SHALL 持有 `_world: DCWorld`（不阻断 legacy 路径，仅当 path=data_core 时使用）
2. WHEN sub-pass 入口检查 `ClimateProfile.use_data_core_climate` 为 true 且 World 已 bind THEN job SHALL 调用 data_core 版 sub-pass 实现（如 `_climate_pass_a_dc`）
3. WHEN use_data_core_climate=false THEN job SHALL 调用现有 `generator._climate_pass_a` 等 legacy 实现
4. WHEN 同一 round 内两路径不能混用 THEN job SHALL 在 round 入口锁定一次 path 标记，整 round 共享（防 mid-round 切换导致状态半成品）
5. WHEN job 完成一 round THEN breakdown 末尾 SHALL 输出 `climate path=legacy | data_core`（参照 weather breakdown 的格式）

---

### 需求 7 — 治理开关 / CLI / 热键

**用户故事**：作为运维，我希望 climate 迁移与 weather 迁移共享同一套灰度策略（CLI / 热键 / SOP）。

#### 验收标准
1. WHEN ClimateProfile 增加 `use_data_core_climate: bool = false` THEN 系统 SHALL 提供独立开关；依赖 `use_data_core=true`，否则自动短路到 legacy
2. WHEN 启动时加 `--data-core-climate` / `--no-data-core-climate` THEN 系统 SHALL 覆盖 ClimateProfile 默认值
3. WHEN 运行期按 F8 热键 THEN 系统 SHALL 切换 use_data_core_climate（与 F9 切 weather 同模式）
4. WHEN 启动时加 `--validate-climate` THEN 系统 SHALL 启用 climate 单进程 A/B 采样：每 round 采集 `temp_hash_sum / moisture_sum / sea_ice_sum / transp_sum / round_avg_ms`，按 path 分桶、满 30 桶打 diff 表（≤1% / ≤3% / ≤3% / ≤3% / ≤10% 阈值）
5. WHEN climate breakdown 输出 THEN 系统 SHALL 在已有 `A=.. B=.. ocean=.. sea_ice=.. transp=..` 后追加 `path=legacy | data_core`
6. WHEN F11 打印 DataCore 状态 THEN 系统 SHALL 同时显示 use_data_core_climate 当前值

---

### 需求 8 — 行为零回归对照

**用户故事**：作为 QA，我希望迁移前后 climate 行为零漂移。

#### 验收标准
1. WHEN 同种子 30 day legacy + 30 day data_core THEN：
   - `temp_hash_sum diff ≤ 1%`
   - `moisture_sum diff ≤ 3%`
   - `sea_ice_sum diff ≤ 3%`
   - `ocean_current_field_hash 距离 ≤ 标定阈值`
2. WHEN 任一阈值失败 THEN 系统 SHALL 通过 `--validate-climate` 报告 FAIL，记录 round 序列与 sub-pass 详情
3. WHEN 迁移期间出现行为漂移（即使过 hash 阈值但用户肉眼看到天气面板异常）THEN 必须先修语义再上线
4. WHEN 测试通过 THEN 文档化推进 SOP 时 SHALL 把 climate 加入灰度推进流程

---

### 需求 9 — 性能验收

#### 验收标准
1. WHEN 迁移完成（path=data_core）THEN refresh_climate_daily round avg SHALL ≤ legacy * 1.10（~11ms 红线）
2. WHEN p95 度量 THEN data_core 路径 SHALL ≤ 14ms
3. WHEN 单 sub-pass 度量 THEN 各段单独 ≤ legacy * 1.15（允许稍宽，以容纳 view 取地址 + dirty mask 路径开销）
4. IF 任一指标超阈值 THEN 进入 climate-C 阶段消化（参照上期 weather C 阶段 dirty short-circuit 思路）
5. WHEN 迁移完成 THEN 整 fast tick 总耗时 SHALL 不增加 > 1ms（与 weather 迁移 +8% 的趋势对齐）

---

### 需求 10 — 文档与 SOP

#### 验收标准
1. WHEN 迁移完成 THEN 在 `.codebuddy/plan/climate-data-core-migration/SOP.md` 写完整 SOP（参照 weather SOP 模板）
2. WHEN SOP 编写完毕 THEN 上一期 weather SOP 的 §3 灰度推进流程图 SHALL 同步更新加入 climate 推进步骤
3. WHEN task-item.md 收尾 THEN 写本期 close-out 决策与下一期建议（候选：ocean_currents 独立 job / vegetation_dynamics）

---

## 4. 边界场景与失败模式

| 场景 | 处理 |
|---|---|
| `use_data_core=false` 但 `use_data_core_climate=true` | 启动期自动拉起 master，并打 print 提醒（与 weather 同款依赖守卫） |
| Round 跨 tick 中途用户按 F8 切 path | round 入口锁定 path，运行期切换不立即生效，下一 round 才生效 |
| Pass A 写完 temp 后 dirty mask 标错（漂移补偿 bug）| 通过 `--validate-climate` 的 temp_hash_sum 自动捕捉 |
| ocean_water 跳过、ocean_land 跑了 | 守卫：ocean_land 入口检查 ocean_water 本 round 已运行（已存在于 legacy job），data_core 路径继承同样守卫 |
| sea_ice SoA 字段未挂 component | bind_map_data 阶段 push_error，阻止启动 |
| 加载存档后首日 | 复用 weather 迁移的"World 不持久化、bind_map_data 后 rebuild_soa"机制，无新增风险 |

---

## 5. 成功标准（与验收完全对齐）

| 维度 | 指标 |
|---|---|
| **架构同源** | climate 6 sub-pass 全走 World View，与 weather 共享 API |
| **零性能回归** | refresh_climate_daily round avg ≤ legacy * 1.10 |
| **零行为回归** | 30 day temp_hash / moisture_sum / sea_ice_sum diff 全过阈值 |
| **可灰度回滚** | F8 / `--no-data-core-climate` / tres 三档全部可即时回滚 |
| **复用基石** | 本期不新增 DataCore 基石 API，全部用上一期就绪能力 |

---

## 6. 与上一期的差异 / 风险

| 维度 | weather 迁移（上一期）| climate 迁移（本期）|
|---|---|---|
| sub-pass 数 | 4 | 6 |
| 是否需要双缓冲 | 否（单 round 内单向链）| 可能需要（pass_a 写 temp，pass_b 读 temp 旧值？需调研） |
| 邻居访问 | 否（front-level）| 是（pass_b 6 邻居） |
| 跨 round 状态 | 单 round 自闭合 | drift stats 跨 round 携带 |
| 主要回归来源（预期）| sync 镜像开销 | View 取地址 / dirty mask 路径 / drift stats 一致性 |
| 估算工作量 | 中（约 10 个任务）| 中偏大（约 12 个任务，含 sea_ice / transp 的 SoA 补齐）|

**关键风险**：
- pass_a/b 之间是否存在"读旧 temp"语义（即 pass_a 写后 pass_b 读 pass_a 写的值还是上一日值？）—— 需在任务 1 调研中确认；若需要双缓冲，本期 SHALL 启用 World 的 `track_prev=true` 路径
- ocean_water → ocean_land 中转：legacy 通过 HexCell.temperature；迁移到 World View 后必须确保 ocean_water 的 commit 在 ocean_land 启动前可见（首版可在两段之间不做 swap，靠原地写入维持语义）
