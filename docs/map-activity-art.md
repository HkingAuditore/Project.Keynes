# 地图开拓与发展反馈

贸易另由 `WorldRoot/TradeActivityLayer` 常驻承载：真实在途订单驱动随时代切换的
商队、货车、船只；正俯视图集随路径旋转，载具/阴影批次共享一个固定容量 MultiMesh。
统一接入地图 TOD，高画质按中心采地形法线和 Horizon GI，并生成太阳投影；近中景显示、远景淡出。
源/目的及当前路径边都受实时视野约束。路径、预算、接口与验证见
[贸易载具运行时](cpp-dots-runtime/trade-visual-runtime.md)。它不消费本层的反馈事件，
也不改变开拓、建造、人口反馈的名额或生命周期。

正式玩家场景挂载 `WorldRoot/MapActivityLayer`。开拓队从
`PlayerController.command_settled` 的 `STARTED / CLAIMED / RELOCATED` 正式回执
产生一次性反馈；不根据命令已排队、预计抵达日或建筑突然出现推断开拓成功。
`CLAIMED` 可等待最多 1.5 秒，让同帧稍后提交的领土与视野先发布。

## 视觉层级

- 开拓：出发印记、移动旗标与尘迹、流动路径；落地后有 2.8 秒地块描金、
  金色尘光、扩散光圈和成功印记，同时附近国界短暂提亮。
- 建造：正式建造回执显示「开始建造」；安装建筑数量增加后显示「扩建完成」。
  局部扬尘、细圈与锤形印记持续 2.2 秒，可替换同格增长／开工提示。
- 人口正增长：绿色微粒、细圈与人数，持续 1.8 秒。
- 国界：细墨线、明暗色带、生成纹理的颗粒颜料晕边与稀疏内侧刻线。
  国色色相仍只由稳定国家 slot 决定；玩家使用黄铜色。

地图、迷雾、国界拓扑、人口、建筑及开拓状态仍归原有原生运行时所有。
人口只读 `EconomyFacade.population_cell_summary()`；建筑只读
`BuildingVisualIntelCache` 已提交、受视野过滤的 CSR 行。不会消费渲染器的
原生 dirty 队列，不启用全量 trace，不新增模拟字段或存档字段。

## 密度与成本

监听正式后台 `simulation_committed` 与旧入口 `daily_tick_completed`；
`BuildingVisualIntelCache.visible_rows_updated` 只在可见的实时行成功发布后通知，
静态 apply／读档不发此通知。通知、镜头移动与缩放只置 dirty。
墙钟每 0.65 秒最多访问视窗内 96 个格位、查询 12 个可见己方格摘要。
优先查询选中地块、刚发布的建筑行和已经观察的聚居地，并保留四个查询名额
发现新地块；不会因大视窗扫描超过四秒而不断丢弃旧基线。人口增长不依赖该格
已经有建筑情报；摘要未就绪会保留重试。

普通地图缩放（zoom ≥ 0.35）即可显示日常反馈；zoom ≥ 0.9 显示日常文字，
选中格始终显示文字。首次观察、远景与读档只建立基线；离屏或失去当前视野即
删除观察基线，不补播屏幕外历史变化。只有安装建筑总数增加／人口正增长会
触发完成反馈；同格扩建优先，选中地块也有播放名额优先级。

日常效果同时最多 3 个（移动端 1 个），同格增长冷却 9 秒、扩建冷却 5 秒；
开拓最多同时 3 个。缓存最多 256 格。离屏事件不排队回放，失去当前视野
立即结束。开拓队只取玩家列表前 64 条中最多 4 条在途路线（移动端 2 条）；
规划路线可见时隐藏背景路线，避免叠画。

动画使用真实秒，最多 30 次／秒重绘，与模拟倍速分离。沿线装饰保持屏幕线宽，
路径坐标缓存，镜头跨圆柱接缝时整体平移到最近副本。`reduce_motion` 保留静态
印记与淡入淡出，关闭粒子、扩圈、浮升、沿线流动和国界提亮。低画质国界跳过
纹理与噪声采样。

## 位图与生成记录

使用内置 `imagegen` 生成，原始透明度保留，项目资源在
`Project/project-keynes/assets/vfx/`，提示词见同目录 `README.md`。
`settlement_dust.png` 用于落地、扩建及行进尘迹；`frontier_grain.png` 用于
国界颜料微纹理。图标复用现有 Font Awesome 授权字体，由 `IconCatalog` 集中映射。

## 验证

- `tests/map_activity_layer_test.gd`：首次观察、正负增长、扩建优先、冷却、密度、
  视野延迟、旧回执、己方读取、有界采样、路线与重绑清理，以及仅后台提交、
  普通缩放、大视窗、没有建筑时增长、建造回执、摘要延迟和订阅重绑回归。
- `tests/map_activity_runtime_integration_test.gd`：启动正式玩家场景和 ACTIVE worker，
  使用真实原生经济的自然人口增长／建筑完工验证效果触发，不手动调用播放接口。
  图形模式可传 `capture_dir=res://tmp/map_activity_runtime_qa` 捕获真实场景。
- `tests/country_border_mesh_test.gd`：原有边界拓扑、折角、双侧国界、三副本、
  国色，以及生成材质、局部提亮参数。
- `tests/map_activity_visual_harness.tscn`：复用实际 BuildingVisualLayer 与原生
  建筑规划器，输出 before / peak / reduced_motion / fade 截图。该夹具用于
  美术验证，地面是测试用色块，不代替正式地图的地形材质。

运行示例：

```powershell
& $godot --headless --path Project/project-keynes --script tests/map_activity_layer_test.gd
& $godot --headless --path Project/project-keynes --script tests/country_border_mesh_test.gd
& $godot --path Project/project-keynes --rendering-method gl_compatibility res://tests/map_activity_visual_harness.tscn -- res://tmp/map_activity_qa
```

2026-10-18 验证结果：活动专项 17 项、国界专项 20 项全部通过；
`player_controller_contract_test`、`technology_workspace_smoke_test`、
`colonization_workbench_ui_test` 通过。正式场景烟测可完成启动且没有新增脚本错误，
但 `player_country_ui_smoke_test` 的两个科技树节点断言，以及
`player_map_overlay_smoke_test` 的一个未识别资源名称断言未通过；本次没有修改
它们对应的科技树／资源显示逻辑。测试退出仍记录项目资源／RID 释放警告。
实际 OpenGL 建筑夹具的四张截图位于 `Project/project-keynes/tmp/map_activity_qa/`。

同日用户反馈修复：活动专项扩至 29 项并通过，建筑情报原有 21 项通过；正式场景
ACTIVE 原生自然增长／完工集成检查通过。另在人工命令探测中观察到
`economy_legacy_ingress_disabled`：当前原生生产写入边界拒绝旧建造提交入口。
没有为播放特效绕过此拒绝或重开旧写入通道；只有正式成功的回执才播放开工。
