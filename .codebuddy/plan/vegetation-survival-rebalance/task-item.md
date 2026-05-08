# 实施计划

- [ ] 1. 在 `vegetation_type.gd` 中新增 `_WEATHER_RESISTANCE` 静态抗性表
   - 在文件顶部 `VEG` 枚举定义之后，新增 `const _WEATHER_RESISTANCE: Dictionary`，结构为 `{VEG.<type>: {WeatherType.WT.<weather>: float}}`
   - 覆盖 DROUGHT / BLIZZARD / HEATWAVE / STORM / MONSOON 五类灾害，按需求 3.4–3.7 中列出的映射填充关键植被的抗性数值
   - 未显式声明的植被/天气组合保持缺省（后续方法会返回 0.0）
   - _需求：3.1、3.4、3.5、3.6、3.7_

- [ ] 2. 在 `vegetation_type.gd` 中新增 `weather_resistance` 静态查询方法
   - 实现 `static func weather_resistance(v: int, wt: int) -> float`（形参 `v` 为 VEG 枚举值，`wt` 为 WeatherType.WT 枚举值）
   - 若 `_WEATHER_RESISTANCE` 不含 `v` 键或其子字典不含 `wt` 键，返回 `0.0`
   - 否则返回对应的 [0, 1] 抗性值
   - _需求：3.2、3.8_

- [ ] 3. 更新 `map_generator.gd` 顶部的植被动力学数值常量
   - 将 `VITALITY_CHANGE_RATE` 由 `0.02` 改为 `0.012`
   - 将 `VITALITY_LOW_THRESHOLD` 由 `0.30` 改为 `0.20`
   - 将 `SUCCESSION_DEGRADE_DAYS` 由 `30` 改为 `90`，`SUCCESSION_UPGRADE_DAYS` 由 `60` 改为 `120`
   - 新增常量 `COMPAT_HARSHNESS = 1.2`，供非对称漂移使用
   - _需求：1.1、1.3、1.4、1.5、1.6_

- [ ] 4. 按 40% 比例缩放 `WEATHER_VITALITY_PENALTY` 字典
   - 在 `map_generator.gd` 的 `WEATHER_VITALITY_PENALTY` 字典中更新：DROUGHT `0.030→0.012`、BLIZZARD `0.012→0.005`、HEATWAVE `0.018→0.007`、STORM `0.005→0.002`、MONSOON `0.005→0.002`
   - 保留其它天气类型不变（若有）
   - _需求：1.2_

- [ ] 5. 改造 `_apply_vegetation_dynamics` 的基础漂移公式为非对称 + 死区
   - 在计算 `compat` 之后替换原 `dv = (compat - 0.5) * 2 * rate`：
     - `compat >= 0.6` → `dv = (compat - 0.5) * 2.0 * VITALITY_CHANGE_RATE`
     - `compat <= 0.4` → `dv = -(0.5 - compat) * 2.0 * VITALITY_CHANGE_RATE * COMPAT_HARSHNESS`
     - 其它（死区）→ `dv = 0.0`
   - 当 `cell.vegetation == VegetationType.VEG.NONE` 时跳过基础漂移计算（`dv` 直接置 0），但后续天气惩罚与 streak 判定照常
   - _需求：2.1、2.2、2.3、2.4_

- [ ] 6. 在天气惩罚计算中引入植被抗性系数
   - 在 `_apply_vegetation_dynamics` 枚举当前 cell 天气时，调用 `VegetationType.weather_resistance(cell.vegetation, wt)` 取得 `resistance`
   - 将 `penalty = base_penalty * wi` 改为 `penalty = base_penalty * wi * (1.0 - resistance)`
   - 最终 `cell.vegetation_vitality = clampf(vitality + dv - penalty, 0.0, 1.0)`
   - _需求：2.5、3.3_

- [ ] 7. 修复 `_trigger_succession` 中退化后的 vitality 起点
   - 将退化分支里 `cell.vegetation_vitality = 0.5` 改为 `0.65`
   - 保持升级分支的 `0.7` 不变
   - 保持演替后同时清零 `_vitality_low_streak` 和 `_vitality_high_streak` 的原有逻辑
   - _需求：4.1、4.2、4.3、4.4_

- [ ] 8. 本地烟雾测试与签名兼容性验证
   - 在 Godot 编辑器中运行项目，确认 `map_generator.gd` / `vegetation_type.gd` 无解析错误、无 `nil` 访问
   - 跑一次完整地图生成 + 若干天推进，检查日志中演替事件频率显著降低、不出现连锁退化
   - 确认 `_apply_vegetation_dynamics` 返回类型仍为 `bool`，`hex_cell.gd` / `weather_type.gd` 未被修改
   - _需求：5.1、5.2、5.3、5.4、5.5_
