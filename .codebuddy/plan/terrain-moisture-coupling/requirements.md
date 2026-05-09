# 需求文档：地形—水汽循环耦合补强（Terrain–Moisture Coupling）

## 引言

当前世界生成系统中，地形对水汽循环的影响仅有"雨影 + 海岸湿度 + 山地正雨（仅河流）"三条窄通路，存在四大缺口：

1. 雨影使用的是 **理想纬度风**（`WindBelt.wind_at`），未利用已存在的 **地形扰动风**（`HexCell.wind_vector`），导致山脉绕流后真实上风方向被忽略；
2. **山地正雨**（`orographic_boost`）目前只回写到 `_compute_river_flow` 的河流流量，**不影响 `cell.moisture` / `base_moisture`**，因此迎风山坡在湿度/降水/植被 overlay 上看不到任何加湿；
3. **天气锋面 advection**（`weather_system.gd` 的 `world.sample_wind`）读的是纯纬度风基线 `wind_field_buffer`，与地形完全脱钩，锋面会"穿山而过"；
4. **植被反馈** 给邻居加湿的强度只看 biome 类型、不看海拔，"高山针叶林"与"低地针叶林"贡献相同，与现实物理不符。

本次改造的核心原则：**全部复用已有字段与 ClimateProfile 参数**（`cell.wind_vector`、`orographic_boost`、`rain_shadow_*`），**不新增任何子系统**，仅做 4 处定点接线 + 1 处可配置开关。所有改动需保持向后兼容（开关默认与现有行为等价或微弱增强），并能在 Data Overlay 的 Humidity/Precipitation/WIND_DIR overlay 上肉眼可见效果差异。

---

## 需求

### 需求 1 — 雨影改用地形扰动风

**用户故事：** 作为世界生成器维护者，我希望 `_apply_rain_shadow_per_cell` 优先采用 `cell.wind_vector` 作为上风方向，以便山脉绕流后形成的真实风向能正确决定背风面位置。

#### 验收标准

1. WHEN `_apply_rain_shadow_per_cell` 处理一个陆地 cell AND 该 cell 的 `wind_vector.length() > 0.01` THEN 系统 SHALL 使用 `cell.wind_vector.normalized()` 作为风向输入并交给 `WindBeltScript.upwind_hex_dir` 求上风邻居方向。
2. IF `cell.wind_vector.length() <= 0.01`（例如还未烘焙完成或 fallback） THEN 系统 SHALL 退回到原有 `WindBeltScript.wind_at(ny, season_phase, jitter)` 的纬度风基线，保证向后兼容。
3. WHEN 该改动同时被 bake 阶段（`map_generator.gd` 行 1076 入口）和每日 sim 阶段（行 2300 调用）调用 THEN 两处 SHALL 共享同一份风向选择逻辑（无需复制粘贴；通过新增私有函数 `_pick_upwind_dir(cell, ny, season_phase, jitter)` 复用）。
4. WHEN 改动落地后 THEN 在含有山脉的种子地图上，开启 Humidity overlay SHALL 能观察到背风面干带相对风向变化（不再是纯纬度走向）。

---

### 需求 2 — 山地正雨回写到 base_moisture

**用户故事：** 作为玩家，我希望迎风山坡在湿度/降水/植被 overlay 上明显比同纬度低地更湿润，以便地形对气候的塑造直观可见。

#### 验收标准

1. WHEN `_compute_moisture_base` 完成、`_apply_coastal_moisture_boost` 之后、`_apply_rain_shadow` 之前 THEN 系统 SHALL 新增一个 pass `_apply_orographic_moisture_boost(map, cfg)`，对每个陆地 cell 用与 `_compute_river_flow` 同源的公式 `boost = 1 + max(land_h - 0.30, 0) × orographic_boost` 增益 `cell.moisture`。
2. IF cell 不是陆地 OR `land_h <= 0.30` THEN 系统 SHALL 不修改其 moisture（不影响海洋/低地）。
3. WHEN 该 pass 完成后 THEN `cell.base_moisture = cell.moisture` 的赋值（行 643）SHALL 仍然在所有 moisture 修正 pass 之后执行，确保正雨增益被持久化到 `base_moisture`。
4. IF 增益后的 moisture 超过 1.0 THEN 系统 SHALL 调用 `clampf(..., 0.0, 1.0)` 将其裁剪。
5. WHEN 该 pass 与 `_apply_rain_shadow` 协同工作 THEN 顺序 SHALL 为：先正雨加湿（迎风+山顶），再雨影衰减（背风），保证两个 pass 物理上不互相覆盖。
6. IF `ClimateProfile.orographic_boost = 0` THEN 该 pass SHALL 等价于 no-op，保证旧 profile 行为不变。

---

### 需求 3 — 天气锋面 advection 接入地形扰动风

**用户故事：** 作为玩家，我希望天气锋面在山脉处会被绕流、堆积或减速，以便天气运动呈现地形敏感性。

#### 验收标准

1. WHEN `weather_system.gd` 的 `_advect_fronts` / spawn 流程读取风向（行 108、270、795 三处 `world.sample_wind(pos)`） THEN 系统 SHALL 改为通过新私有助手 `_sample_terrain_wind(world, map, world_pos)` 取风：先按 `world_pos` 反查 `HexCell`，若 `cell.wind_vector.length() > 0.01` 则返回 `cell.wind_vector`，否则 fallback 到 `world.sample_wind(world_pos)`。
2. WHEN fallback 路径被命中 THEN 系统 SHALL 仍然叠加 `WindBelt.monsoon_offset_at(ny, _season_phase)`，与现有逻辑一致；走 wind_vector 路径时 SHALL **不再叠加 monsoon offset**（因为 wind_vector 已是 per-cell 实际风，避免双重季风偏移）。
3. IF 反查 `HexCell` 失败（坐标越界） THEN 系统 SHALL 退回 `world.sample_wind(world_pos) + WindBelt.monsoon_offset_at(ny, _season_phase)`。
4. WHEN 改动落地后 THEN 在沿山脉外推的天气云团 SHALL 显示出绕流/减速行为（可在 WIND_DIR overlay 与 weather front 调试可视化中肉眼对比）。
5. IF `ClimateProfile.weather_advect_use_wind_vector = false`（新增可选开关，默认 `true`） THEN 系统 SHALL 完全使用旧路径，便于回滚验证。

---

### 需求 4 — 植被反馈按海拔衰减

**用户故事：** 作为世界生成器维护者，我希望森林/草原对邻居的湿度贡献按 elevation 衰减，以便高山植被不会与低地植被一样大幅影响周围水汽。

#### 验收标准

1. WHEN `_apply_vegetation_feedback`（map_generator.gd 中的植被反馈 pass）枚举一个植被 cell 的湿度贡献 THEN 系统 SHALL 将贡献量乘以 `(1.0 - elevation × veg_feedback_elev_decay)` 的因子，其中 `veg_feedback_elev_decay` 为新增 ClimateProfile 字段，默认 `0.5`。
2. IF `elevation × veg_feedback_elev_decay >= 1.0` THEN 系统 SHALL 将因子下限裁剪为 `0.1`（避免完全无贡献）。
3. IF cell 不是植被类型（FOREST / GRASSLAND / 其他既有植被列表 / 沙漠负反馈也包含在内 / 与现有 `_apply_vegetation_feedback` 已枚举集合一致） THEN 系统 SHALL 不应用此衰减（保持现有跳过逻辑）。
4. IF `veg_feedback_elev_decay = 0` THEN 改动 SHALL 等价于现状（旧 profile 兼容）。

---

### 需求 5 — Data Overlay 与文档同步

**用户故事：** 作为玩家/调试者，我希望在现有 overlay（Humidity / Precipitation / WIND_DIR / VEGETATION_VITALITY）上立刻看到上述改动效果，并理解物理含义。

#### 验收标准

1. WHEN 上述需求 1–4 全部实现 THEN 现有 overlay SHALL 无需修改任何 shader / baker 即可反映新数据（因为它们读 `moisture` / `precipitation` / `wind_vector`，这些字段由本次改动直接刷新）。
2. WHEN 改动落地后 THEN 项目 README 或 `scripts/map_generator.gd` 顶部注释 SHALL 增加一段 "Terrain ↔ Moisture coupling v11" 的说明，列出新增 pass 的名字、调用顺序、新 ClimateProfile 字段。
3. IF 用户在 ClimateProfile inspector 中查看 THEN 新增字段 `weather_advect_use_wind_vector`（bool）和 `veg_feedback_elev_decay`（float）SHALL 各有 `## ` 文档注释说明用途与默认值。

---

### 需求 6 — 性能与稳定性约束

**用户故事：** 作为世界生成器维护者，我希望本次改动不引入新的逐帧大循环或 O(N²) 操作，以便保持现有 daily sim 性能。

#### 验收标准

1. WHEN `_apply_orographic_moisture_boost` 执行 THEN 它 SHALL 是一次 `O(cells)` 的单 pass，无嵌套循环。
2. WHEN `_sample_terrain_wind` 在 weather sim 中被调用 THEN 反查 cell 的代价 SHALL 不超过一次 `MapData.get_cell_by_world_pos`（或等价的 `pos → axial` 哈希），不引入图遍历。
3. IF 在 bake 阶段 cell.wind_vector 尚未写入（极端 race） THEN 所有依赖它的 pass SHALL 通过 length 阈值检测优雅 fallback，**不得**导致 `NaN` 或 `INF` 进入 moisture/precipitation 字段。
4. WHEN 完整 bake 完成后 THEN 在与改动前同种子的对比中，cell 字段（moisture / base_moisture / precipitation / vegetation_vitality）SHALL 不出现非有限数值（验证手段：临时 print 统计）。

---

## 不在本次范围

以下条目明确**不在本次实施范围内**，避免范围蔓延：

- 真正的多步水汽 advection（湿气团从海上沿风一路输送、随距离衰减）：需要新加 `cell.atmospheric_moisture` 与多步 pass，留作后续迭代。
- Foehn/焚风 现象（背风下沉增温）：温度耦合不在本次。
- 改造 wind_field_buffer 烘焙本身（仍为纬度风基线）：本次不动 baker，只在 weather sim 端做 per-cell 替换。
- 修改 `_compute_river_flow` 已有的 orographic 路径：本次只新增对 `moisture` 的回写，不动河流。
