# 实施计划：系统化洋流系统

- [ ] 1. 扩展数据契约：`HexCell` 与 `WorldData`
   - 在 `hex_cell.gd` 新增 `upwelling_strength: float`（默认 0.0，范围 [-1, 1]）与 `temperature_transport_anomaly: float`（默认 0.0）两个字段
   - 在 `world_data.gd` 新增 `ocean_upwelling_buffer: PackedByteArray`（R8），加入序列化槽位，与 `ocean_current_buffer` 同生命周期
   - 提供 `WorldData.sample_upwelling(uv: Vector2) -> float` 采样器，参考 `wind_field_buffer` 的采样实现
   - _需求：9.1、9.2、9.3、9.4_

- [ ] 2. 配置与回退开关
   - 在 `MapConfig` 新增 `enable_ocean_heat_transport: bool`（默认 true）、`THERMOHALINE_WEIGHT`、`COLD_SINK_TEMP`、`OCEAN_HEAT_ADVECT_STEPS`（默认 3）、`OCEAN_HEAT_MIX`（默认 0.25）、`COASTAL_HEAT_LEAK`（默认 0.35）、`OCEAN_CURRENT_ICE_DELAY`（默认 1.0）、`CYCLONE_WAKE_DAYS`（默认 3）等常量
   - 确保当 `enable_ocean_heat_transport = false` 时，任务 5、6、7 的热输运/海冰/生物反馈路径全部提前 return
   - _需求：8.3、8.4_

- [ ] 3. 烘焙层：洋流热盐驱动项与上升/下沉流识别
   - 在 `map_baker.gd._bake_ocean_currents` 中采样 `baked_temperature_buffer`，计算经向温度梯度 `dT/dlat`，按 `THERMOHALINE_WEIGHT` 叠加经向分量
   - 新增 `_bake_ocean_upwelling(world, cfg)` pass：高纬冷水点写 128（下沉）、沿岸风致 Ekman 抽吸点写 255（上升）、其他写 0，产出 `ocean_upwelling_buffer`
   - 沿岸判定复用 `_is_coastal_cell` / 邻接水陆关系；科里奥利方向沿用现有 ±45° 规则
   - _需求：2.1、2.2、2.3、2.4_

- [ ] 4. 洋流场季节化重烘与回填
   - 在 `map_baker.gd` 新增 `rebake_ocean_currents(world, season_idx)` 入口，使用 `weather_system` 的"夏季基线 + 季风 offset"融合规则合成当季风场后重跑 `_bake_ocean_currents` 与 `_bake_ocean_upwelling`
   - 在 `map_generator.gd.refresh_seasonal` 尾部（`_apply_sea_ice_pass` 之前）调用上述入口，并同步调用 `_compute_ocean_currents` 回填所有 water `HexCell.ocean_current` 与 `upwelling_strength`
   - 通过 `HexRenderer.set_shader_parameter` 推送新 buffer；`refresh_climate_daily` 不重烘
   - _需求：1.1、1.2、1.3、1.4_

- [ ] 5. 洋流→温度反馈：热量输运 pass
   - 在 `map_generator.gd` 新增 `_apply_ocean_heat_transport_pass(map, season_phase)`：对每个 water cell 沿 `-ocean_current` 回溯最多 `OCEAN_HEAT_ADVECT_STEPS` cell，按 `OCEAN_HEAT_MIX` 混合上游 `base_temperature`，结果写入该 cell 的 `current_state.temperature` 与 `temperature_transport_anomaly`
   - 对每个陆地 cell 遍历相邻水 cell，按 `max(0, dot(邻接方向, 水 cell ocean_current))` 加权平均邻接水 cell 的温度异常，按 `COASTAL_HEAT_LEAK` 注入陆地 `current_state.temperature`；冬季相位（phase ≈ 2.0）时权重 × 1.5
   - 在 `refresh_climate_daily` 的温度写回前调用该 pass；由 `enable_ocean_heat_transport` 控制
   - _需求：3.1、3.2、3.3、3.4、3.5_

- [ ] 6. 洋流→海冰耦合
   - 修改 `_apply_sea_ice_pass`：判定时使用 `effective_temperature = temperature + OCEAN_CURRENT_ICE_DELAY * max(0, temperature_transport_anomaly) - 0.5 * max(0, upwelling_strength if upwelling_strength > 0.3 else 0.0)`
   - 确保在 `refresh_seasonal` 中被调用时 `temperature_transport_anomaly` 已由任务 5 当季首次 `refresh_climate_daily` 填充；若未填充则按 0 处理
   - _需求：4.1、4.2、4.3_

- [ ] 7. 洋流→海洋生物耦合
   - 修改 `map_generator.gd` 中决策 REEF / KELP 的分支：读取 `HexCell.upwelling_strength`，当 `> 0.4` 且为 shallow water 时温度阈值窗口两侧各放宽 0.08
   - 当 `> 0.6` 且为 deep water 时，在 `cover_type.gd` 新增 `PELAGIC_BLOOM` 枚举值并允许生成；shader 端在 `world_map.gdshader` 给 `PELAGIC_BLOOM` 叠加淡绿色 tint（权重由 upwelling 决定）
   - 无 `ocean_upwelling_buffer` 数据时回退到原纯温度判定
   - _需求：5.1、5.2、5.3、5.4_

- [ ] 8. 天气事件瞬时扰动（可选实现，默认关闭）
   - 在 `weather_system.gd` 新增 `ocean_current_perturbation: Dictionary` 与 `_tick_cyclone_wake(dt)`，tropical_cyclone 事件触发时注入旋转向量，`CYCLONE_WAKE_DAYS` 天内线性衰减
   - 新增 RG8 overlay buffer 通过 `set_shader_parameter("ocean_current_overlay", ...)` 推送；shader 在采样主流场后相加
   - 通过 `MapConfig.enable_cyclone_wake` 开关控制，默认 false
   - _需求：6.1、6.2、6.3_

- [ ] 9. 调试可视化：上升流与热输运异常
   - 扩展 `world_map.gdshader` 现有 F6 `ocean_current_debug` 分支：采样 `ocean_upwelling_buffer`，上升流黄色、下沉流紫色叠加到水面
   - 新增 F7 开关（`main.gd` 输入处理 + shader uniform `ocean_heat_debug`）：在陆地 cell 上按 `temperature_transport_anomaly` 以红-蓝渐变叠加，±5°C 映射满饱和；需要在 `HexRenderer` 侧把 per-cell 异常值打包进已有的 debug 贴图或新增一张 R8 buffer
   - 调试开关关闭时 shader 主路径必须提前 return，保证零额外开销
   - _需求：7.1、7.2、7.3_

- [ ] 10. 性能打点与回归验证
   - 在 `rebake_ocean_currents` 与 `_apply_ocean_heat_transport_pass` 加入 `Time.get_ticks_msec()` 打点，沿用现有 `print("refresh_climate_daily #%d: %dms ...")` 风格
   - 在 4096×2048 测试地图上验证：季节重烘耗时 ≤ 原 `bake_world` 的 15%；热输运 pass 耗时 ≤ `refresh_climate_daily` 的 30%
   - 对比 `enable_ocean_heat_transport = false` 的温度 / 海冰 / 生物快照与主分支一致
   - _需求：8.1、8.2、8.3、8.4_
