// 新建 task-item.md - climate-data-core-migration

# 实施计划 — Climate 系统 DataCore 迁移（E 阶段）

> 配套需求：[requirements.md](./requirements.md)  
> 上一期：`.codebuddy/plan/dots-foundation-and-weather-migration/`（已 close-out）  
> 主要目标文件：`scripts/simulation/sus/jobs/refresh_climate_daily_job.gd`、`scripts/geography/map_generator.gd`（_climate_pass_a_dc 等新版 sub-pass）、`scripts/data_core/world.gd`（仅补 component_id 常量）、`scripts/data_core/component_ids.gd`、`scripts/data/climate_profile.gd`、`scripts/main.gd`。

---

## 阶段划分

- **A 阶段**：调研 + 注册 + 单段迁移（Pass A），先建通管线
- **B 阶段**：剩余 5 段迁移 + 行为对照
- **C 阶段**：性能消化（若 B 阶段验收 +10% 红线突破）
- **D 阶段**：SOP / 文档 / close-out

---

## A 阶段：通管线（任务 1-3）

- [ ] 1. **调研 + Component 清单确认**
   - 用 grep_search / read_file 摸清 6 个 sub-pass 各自读写哪些 HexCell / MapData 字段
   - 确认 pass_a 写 temp / pass_b 读 temp 的时序：是否需要双缓冲（如需要，规划 `track_prev=true` 注册）
   - 确认 sea_ice / transp 当前 HexCell 字段哪些已经在 MapData SoA 镜像里、哪些需要补
   - 输出："climate-soa-coverage.md" 简表，挂在本计划目录下，列每个字段的 Coverage Y/N
   - 不写任何代码，只产生分析文档；后续任务 2/3 据此决策
   - _需求：1.1, 1.2, 1.3_

- [ ] 2. **补齐缺失 component 注册（如有）**
   - 基于任务 1 输出的简表，在 [component_ids.gd](../../Project/project-keynes/scripts/data_core/component_ids.gd) 补常量
   - 在 [world.gd](../../Project/project-keynes/scripts/data_core/world.gd) `bind_map_data` 内追加 `_bind_register_and_attach(...)` 调用
   - 若任意字段在 MapData 上缺 SoA 镜像，先在 [map_data.gd](../../Project/project-keynes/scripts/geography/map_data.gd) 补 PackedArray + rebuild_soa_from_cells / flush_soa_to_cells 维护
   - 启动期 `[SUS] world: bound=true entities=2400 components=N` 中 N 应在原 37 基础上 +ΔN（视任务 1 结果，预估 N 在 40~45 之间）
   - _需求：1.1, 1.2_

- [ ] 3. **Pass A 迁移（首段通管线）**
   - 在 [climate_profile.gd](../../Project/project-keynes/scripts/data/climate_profile.gd) 增加 `use_data_core_climate: bool = false`
   - 在 [refresh_climate_daily_job.gd](../../Project/project-keynes/scripts/simulation/sus/jobs/refresh_climate_daily_job.gd) `_PASS_A` 入口加 path 分发：`use_data_core_climate=true` 走 `_climate_pass_a_dc`，否则走 legacy `_climate_pass_a_soa`
   - 实现 `_climate_pass_a_dc(map, season_phase)`：内部用 `world.view_f32(CELL_TEMP) / view_f32(CELL_MOISTURE) / view_f32(CELL_SNOW_COVER) / view_f32(CELL_LAT_NORM)` 等取数组，循环外取一次，循环内仍走索引
   - drift stats 更新逻辑（`_dt_global_yesterday` 等）保持 1:1 与 legacy 等价（A/B hash 比对通过）
   - round 入口锁定 path 标记（`_round_climate_path: String`），整 round 共享
   - 给 RefreshClimateDailyJob 加 breakdown 末尾输出 `path=legacy | data_core`
   - _需求：2.1, 2.2, 2.3, 2.4, 2.5, 6.1, 6.2, 6.3, 6.4, 6.5_

---

## B 阶段：剩余 5 段 + 对照测试（任务 4-9）

- [ ] 4. **Pass B 迁移**
   - 实现 `_climate_pass_b_dc(map, season_phase)`：使用 `world.topology().neighbors_packed()` 取邻居索引、`view_f32` 取数组
   - 保留现有 sparse / full 自适应逻辑（dirty mask + visit_mask）
   - 输出 dirty_ratio / visited_ratio / pass_b_path 字段与 legacy 完全一致
   - _需求：3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

- [ ] 5. **Ocean water/land 双段迁移**
   - 实现 `_ocean_water_pass_dc / _ocean_land_pass_dc`
   - ocean_water → ocean_land 数据接力通过 World View 完成（不靠 HexCell 中转）
   - 守卫：ocean_land 入口检查 ocean_water 本 round 已运行（继承 legacy 逻辑）
   - _需求：4.1, 4.2, 4.3, 4.4, 4.5, 4.6_

- [ ] 6. **Sea ice 段迁移**
   - 实现 `_apply_sea_ice_daily_pass_dc(map, season_phase)`
   - HexCell.sea_ice_fraction 仅在 round 末由 `MapData.flush_soa_to_cells` 刷回（与 weather 同款）
   - 任务 1 调研若发现 sea_ice 相关字段 SoA 缺失，由任务 2 补齐前置依赖
   - _需求：5.1, 5.3, 5.4_

- [ ] 7. **Transpiration 段迁移**
   - 实现 `_apply_transpiration_pass_dc(map)`
   - `enable_local_climate_coupling=false` 时 SHALL 像 legacy 一样跳过
   - _需求：5.2, 5.3, 5.5_

- [ ] 8. **`--validate-climate` 单进程 A/B 采样**
   - 在 [main.gd](../../Project/project-keynes/scripts/main.gd) 复用 weather validator 框架，新增 climate 桶：`temp_hash_sum / moisture_sum / sea_ice_sum / transp_sum / round_avg_ms`
   - 阈值：≤1% / ≤3% / ≤3% / ≤3% / ≤10%
   - F8 热键切 use_data_core_climate（与 F9 切 weather 同模式）
   - 启动期 CLI：`--data-core-climate / --no-data-core-climate / --validate-climate`
   - F11 状态打印追加 climate 标记
   - _需求：7.1, 7.2, 7.3, 7.4, 7.5, 7.6_

- [ ] 9. **B 阶段实测 + 验收**
   - 同条件 30 game day，抓 4 个 30-tick 汇总窗口（legacy / data_core 两路径各 ≥30 个采样）
   - 对照表：refresh_climate_daily round avg、p95、各 sub-pass 段 elapsed
   - 行为对照：`--validate-climate` diff 表 PASS
   - 写回 task-item.md 末尾"B 阶段验收记录"小节
   - 若 PASS → 直接进 D 阶段；若 +10% 红线突破 → 进 C 阶段
   - _需求：8.1, 8.2, 8.3, 8.4, 9.1, 9.2, 9.3, 9.4, 9.5_

---

## C 阶段（条件触发）：性能消化

> 只在 B-09 实测出现 ≥+10% 回归时启动；否则跳过

- [ ] C-01. 定位主要回归来源（按上一期经验，最可能是某个 view 取地址在循环内反复调用、或 dirty mask 多写）
- [ ] C-02. 三档优化（dirty short-circuit / 强类型快路径 / 循环外取地址）
- [ ] C-03. 实测 + 写回验收

---

## D 阶段：SOP / 文档 / close-out（任务 10-12）

- [ ] 10. **SOP 文档落盘**
   - 新建 `.codebuddy/plan/climate-data-core-migration/SOP.md`，参照 weather SOP 模板
   - 上一期 weather SOP §3 灰度推进流程图同步更新加入 climate 推进步骤
   - 包含 §1 启动开关 / §2 F8 / F9 / F10 / F11 热键速查 / §3 灰度推进 / §4 `--validate-climate` 流程 / §5 SUS 字段速查 / §6 回滚 / §7 验收门槛 / §8 FAQ
   - _需求：10.1, 10.2, 10.3_

- [ ] 11. **本期 close-out 记录**
   - 写本期 close-out 决策小节到 task-item.md 末尾
   - 总结基石复用情况：本期是否新增了 DataCore API（理想情况：不新增，全部复用上一期）
   - 评估下一期候选：`ocean_currents 独立 job` / `vegetation_dynamics` / `season_refresh stages 全图迁移` 三选一

- [ ] 12. **统一 SOP 收口**
   - 把上一期 weather SOP + 本期 climate SOP 合并入门索引 `.codebuddy/plan/SOP.md`（如有需要），方便新成员一站查
   - 可选项：若 main.gd validator 框架现在覆盖 weather + climate 两类，则在主 SOP 中加"validator 通用接口"章节

---

## 风险登记 / 关键决策点

| 风险 | 缓解 |
|---|---|
| pass_a 写 temp / pass_b 读 temp 时序需双缓冲 | 任务 1 调研产出明确结论；如需要，A 阶段就开 `track_prev=true`，避免 B 阶段返工 |
| ocean_water → ocean_land 中转语义难维持 | 首版采用 in-place 写入（与 legacy 同语义），不做 swap；validator 阈值卡得严，触发即回滚 |
| sea_ice / transp 的 HexCell 字段未在 MapData 有 SoA 镜像 | 任务 2 补齐 SoA + rebuild/flush 双向维护，再迁 hot loop |
| 6 个 sub-pass 每个都要 path 分发 → 代码膨胀 | 用同一个 `_round_climate_path` 状态变量在 round 入口锁一次，sub-pass 内只读不写 |
| weather 已默认开 use_data_core_weather，本期 climate 默认开关需配套联动 | 阶段 D-10 SOP 中明确：use_data_core_climate 默认 false；通过 30 day validator PASS 后 tres 改 true |
| 上一期 +8% 余量本期可能再加上 → 总累积超阈 | 每段 sub-pass 单独验收 ≤ legacy * 1.15；总 round ≤ legacy * 1.10 |

---

## 与上一期的对比清单

| 项目 | 上一期 weather | 本期 climate |
|---|---|---|
| sub-pass 数 | 4 | 6 |
| 任务总数 | 10 | 12（含可选 C 阶段 +3）|
| 是否需要新增基石 API | 是（World/Query/CommandBuffer 全新建）| 否（全部复用） |
| validator 阈值 | fronts ≤5%, cloud/precip ≤3% | temp_hash ≤1%, moisture/sea_ice ≤3% |
| 默认开关初始值 | weather 现已 true | climate 默认 false，PASS 后再开 |
| 热键 | F9 weather / F10 master / F11 status / F12 validator | 增加 F8 climate（与 F9 同模式）|
| CLI | `--data-core` / `--data-core-weather` / `--validate-weather` | 增加 `--data-core-climate` / `--validate-climate` |
| SOP 章节数 | 9 | 8（复用上一期框架，删去基石介绍） |

---

## 进度追踪

> 每完成一个任务都按 `[x] N. ...` 改写；C 阶段如未触发则保留 `[ ]` 注明 "skipped: B-09 verdict PASS"。
