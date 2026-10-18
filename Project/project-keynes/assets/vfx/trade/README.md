# 贸易载具图集

当前游戏使用 `vehicles_topdown_v2.png`，由内置 imagegen 原创生成，RGBA 透明背景。
视角为相机垂直向下 90° 的正交俯视，只画头顶、背筐、马背、车顶、甲板；
没有透视侧墙、地平线或烘焙投影。原始输出保留在 Codex generated_images。

1024×1536，2 列 × 6 行，每格 512×256；左陆运、右水运：
搬运队／独木舟、古代货队／木船、篷车／帆船、蒸汽时代货队／蒸汽船、
早期货车／机动船、现代货车／集装箱货轮。

全部朝东，shader 保持每格 2:1 比例，按路径方向旋转载具和投影。
严格俯视无需切换斜视方向帧，支持连续转向。保留原始 alpha；过滤接近透明的生成噪声，
导入启用 mipmap 和 alpha border 修复。旧 `vehicles.png` 保留为历史来源，已不被游戏引用。

生成提示要点：strict 90-degree overhead orthographic view, no isometric or three-quarter view,
2 columns by 6 rows, every vehicle points east, muted wood/canvas/metal palette,
flat diffuse albedo, no cast shadows, transparent background, no text/grid/scenery/glow。

光照由 `earth_daylight.gdshaderinc` 计算；高画质在每个载具中心采地形法线和 Horizon GI，
独立固定批次生成随太阳方向变化的投影。时代映射由 `TradeActivityLayer.ERA_ROWS`
统一管理；位图只改变外观，不授予通行科技。
