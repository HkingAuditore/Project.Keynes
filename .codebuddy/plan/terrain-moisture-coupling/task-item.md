# 实施计划：地形—水汽循环耦合补强

> 范围对应 `.codebuddy/plan/terrain-moisture-coupling/requirements.md`。所有任务均为编码任务，按顺序逐步推进；每项都是在前一项基础上可独立验证的最小步骤。

- [ ] 1. 扩展 `ClimateProfile` 配置字段
   - 在 `scripts/data/climate_profile.gd` 新增两个 `@export` 字段并附 `## ` 文档注释：
     - `weather_advect_use_wind_vector: bool = true`
     - `veg_feedback_elev_decay: float = 0.5`
   - 不修改任何已有字段默认值，确保旧 profile 资源不被破坏
   - _需求：3.5、4.1、5.3_

- [ ] 2. 在 `map_generator.gd` 新增 `_pick_upwind_dir` 共享助手
   - 实现签名 `_pick_upwind_dir(cell: HexCell, ny: float, season_phase: float, jitter: float) -> int`
   - 内部逻辑：若 `cell.wind_vector.length() > 0.01` → `WindBeltScript.upwind_hex_dir(cell.wind_vector.normalized())`；否则 fallback 到 `WindBeltScript.wind_at(...)` + `upwind_hex_dir`
   - 暂不接线，仅准备好可复用函数（便于第 3 项原子替换）
   - _需求：1.1、1.2、1.3、6.3_

- [ ] 3. 雨影 pass 接线到 `_pick_upwind_dir`
   - 修改 `_apply_rain_shadow_per_cell`：将原本计算上风方向的代码替换为 `_pick_upwind_dir(...)`
   - 同时在 bake 入口（约行 1076）和 daily sim 调用点（约行 2300）确认走的都是该 helper；如有重复路径则统一
   - 跑一次完整 bake，确认 Humidity overlay 在山脉背风面表现出与风向一致的干带
   - _需求：1.1、1.2、1.3、1.4_

- [ ] 4. 新增 `_apply_orographic_moisture_boost` pass
   - 在 `map_generator.gd` 实现新 pass：遍历陆地 cell，公式 `boost = 1 + max(land_h - 0.30, 0) * orographic_boost`，对 `cell.moisture` 乘后 `clampf(0, 1)`
   - 海洋/`land_h <= 0.30` 跳过；`orographic_boost == 0` 时整体 no-op
   - O(cells) 单 pass，无嵌套循环
   - _需求：2.1、2.2、2.4、2.6、6.1_

- [ ] 5. 调整 bake 流水线顺序，固化到 `base_moisture`
   - 在主 bake 函数中的调用顺序改为：`_compute_moisture_base` → `_apply_coastal_moisture_boost` → **`_apply_orographic_moisture_boost`** → `_apply_rain_shadow` → `cell.base_moisture = cell.moisture`
   - 对照需求 2.3、2.5 的顺序约束验证；临时 print 统计 moisture/base_moisture min/max/NaN 计数
   - _需求：2.3、2.5、6.4_

- [ ] 6. 在 `weather_system.gd` 新增 `_sample_terrain_wind` 助手
   - 实现签名 `_sample_terrain_wind(world, map, world_pos, ny) -> Vector2`
   - 逻辑：若 `cfg.weather_advect_use_wind_vector` 且能通过 `MapData.get_cell_by_world_pos`（或等价 axial 哈希）反查到 cell 且 `cell.wind_vector.length() > 0.01` → 直接返回 `cell.wind_vector`（不再叠加 monsoon offset）；否则返回 `world.sample_wind(world_pos) + WindBelt.monsoon_offset_at(ny, _season_phase)`
   - 越界 / 反查失败 → 严格走 fallback 分支，确保不返回 NaN
   - _需求：3.1、3.2、3.3、3.5、6.2、6.3_

- [ ] 7. 替换 `weather_system.gd` 三处 `world.sample_wind` 调用
   - 将行 108、270、795（实际行号以当前文件为准）的 `world.sample_wind(...)` 调用统一替换为 `_sample_terrain_wind(world, map, ..., ny)`
   - 保持原本的下游逻辑（速度缩放、随机扰动等）不变
   - _需求：3.1、3.4_

- [ ] 8. `_apply_vegetation_feedback` 加入海拔衰减
   - 在已有的植被→邻居湿度贡献处，将贡献量乘以 `clampf(1.0 - cell.elevation * cfg.veg_feedback_elev_decay, 0.1, 1.0)`
   - 不修改植被类型枚举集合，保留现有 skip 逻辑；`veg_feedback_elev_decay == 0` 时退化为现状
   - _需求：4.1、4.2、4.3、4.4_

- [ ] 9. 文档同步与开发者注释
   - 在 `scripts/map_generator.gd` 顶部注释块追加 "Terrain ↔ Moisture coupling v11" 段落，列出新增 pass 名、调用顺序、新 `ClimateProfile` 字段
   - 在新 pass 函数体上方写一段简短 docstring，说明物理含义与回滚开关
   - _需求：5.2、5.3_

- [ ] 10. QA 验证与性能回归
   - 用同一种子在改动前后各跑一次 bake，对 `moisture / base_moisture / precipitation / vegetation_vitality` 做 `is_finite` 全量校验（临时 print min/max/NaN/INF 计数，验证后删除）
   - 在含山脉的种子上分别打开 Humidity / Precipitation / WIND_DIR / VEGETATION_VITALITY overlay 截图对比，确认背风干带、迎风加湿、锋面绕流、植被衰减肉眼可见
   - 对比 daily sim 单帧耗时，确认无明显回归（>10% 视为不达标）
   - _需求：1.4、2.1、3.4、5.1、6.1、6.2、6.4_
