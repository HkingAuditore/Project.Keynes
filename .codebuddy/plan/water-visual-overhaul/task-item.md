# 实施计划

- [ ] 1. 梳理并收敛水体视觉参数链路
  - 检查 `scripts/main.gd`、`scripts/rendering/hex_renderer.gd`、`shaders/world_map.gdshader` 中现有水体导出参数、setter 与 shader uniform，删除重复语义或修正误导性注释。
  - 保持已有参数名兼容场景序列化，必要时只新增高层强度/开关，不破坏现有 `set_shader_parameter` 调用。
  - _需求：7.1、7.2、7.3、7.4、9.4_

- [ ] 2. 重调低频柔和水面扰动
  - 修改 `shaders/include/water.gdshaderinc` 与 `shaders/world_map.gdshader` 中水面波浪、低频 ripple、calm noise 的频率、振幅、时间速度和对比度默认值。
  - 确保 `water_effect_enabled=false` 与 `water_waves_enabled=false` 时能分别回退到基础水色或无动态波浪表现。
  - _需求：1.1、1.2、1.3、1.4、1.5、6.1、6.3、9.1_

- [ ] 3. 实现连续的近岸到深海水色梯度
  - 重构 `shaders/world_map.gdshader` 水体分支中的 `offshore` / 深浅色计算，使用更平滑的连续曲线替代突兀分段或过强对比。
  - 保持 `color_coast_water`、`color_mid_ocean`、`color_deep_ocean`、`deep_ocean_contrast` 等现有调参入口可用。
  - _需求：3.1、3.2、3.6、5.1、6.3、9.2_

- [ ] 4. 增强浅水、湖泊与近岸透明层次
  - 在 `shaders/world_map.gdshader` 中基于海拔差、离岸度和水体类型计算浅水透底权重，避免深海透底或陆地颜色污染水体。
  - 让 `shallow_transparency_enabled` 与 `shallow_transparency_factor` 控制透明层强弱，并对河流/狭窄湖泊保留可辨识水色。
  - _需求：2.1、2.2、2.3、2.4、2.5、5.1_

- [ ] 5. 改善湖泊、河流和特殊水体的统一风格化叠加
  - 调整 `B_LAKE`、`B_REEF`、`B_KELP`、`B_SEA_ICE` 等分支的特征色、噪声尺度和混合强度，使其共享统一水体语言但保留辨识度。
  - 优化河流颜色、轮廓和顺流明暗变化，避免小河在透明层或噪声层中消失。
  - _需求：3.3、3.4、3.5、2.5、6.2、9.2_

- [ ] 6. 重构水体类型软融合与边界域扭曲
  - 调整 `water_biome_weights`、`water_biome_blend_radius`、`water_domain_warp_strength` 的使用方式，让湖泊、礁石、海草、海冰与普通海洋交界更柔和。
  - 保留 `water_biome_blend_radius=0` 的硬切回退路径，并限制边界扰动不侵入陆地过多。
  - _需求：4.1、4.2、4.3、4.4、4.5、8.4_

- [ ] 7. 优化海岸线、河口和水陆过渡表现
  - 在 `shaders/world_map.gdshader` 中复用海拔差、邻域采样或现有 atlas 信息，为近岸、湖岸和河口增加柔和浅色过渡。
  - 检查山地、雪地、森林、草地等陆地类型旁的水陆边界，避免脏边、锯齿和过亮描边。
  - _需求：5.1、5.2、5.3、5.4、5.5、4.5_

- [ ] 8. 接入视觉质量分级与性能降级路径
  - 根据 `visual_quality` 对波浪法线、邻域采样、焦散、洋流纹理和特殊水体噪声做分级降级，低质量优先保留水色渐变与边界柔化。
  - 避免按水体类型重复执行昂贵计算，尽量复用 `wpw`、`offshore`、软权重和基础噪声结果。
  - _需求：6.5、8.1、8.2、8.3、8.4、1.3_

- [ ] 9. 补全调试开关、默认值和编辑器调参体验
  - 在 `scripts/main.gd` 与 `scripts/rendering/hex_renderer.gd` 中同步新增或调整水体参数默认值、导出范围、setter clamp 和 shader 写入。
  - 确保每个水体子效果可独立关闭，默认参数能直接改善当前截图中的密集波纹、硬边和脏色问题。
  - _需求：7.1、7.2、7.3、7.5、9.1、9.4_

- [ ] 10. 执行水体重构验证与回归修正
  - 在至少一张包含海洋、近岸、湖泊、河流、礁石、海草和海冰的地图上运行目视验证，检查波纹密度、透明层次、颜色渐变、边界融合和玩法信息可读性。
  - 验证 `water_effect_enabled`、`water_waves_enabled`、`shallow_transparency_enabled`、`water_biome_blend_radius=0`、不同 `visual_quality` 档位均无 shader 编译错误、闪烁或明显卡顿。
  - _需求：1.2、1.3、1.4、2.3、4.3、6.2、6.4、8.5、9.3、9.5_
