# 地块贸易载具可视化

## 数据与所有权

正式场景的 `WorldRoot/TradeActivityLayer`（z=9）位于选择、开拓反馈之下。
它只读 `EconomyFacade.trade_visual_snapshot()`，不建立逐载具节点，不订阅经济 trace，
不消费经济或建筑 dirty 队列，不写 MapData、订单、ETA、资金、库存或存档。

`NativeEconomyRuntime::trade_visual_cache` 是独立瞬态观察者。
主线程通过 mutex 提交最新视窗兴趣格和可见性，非阻塞尝试 Economy read boundary；
可安全读取时服务一片，否则等待 worker 的 `serve_read_view()` 提交边界。
发布使用原子 `shared_ptr<const View>`，主线程不访问 worker 可变订单和寻路数组。
时代取与建筑相同的 `country_query_runtime()` 已提交 Country 视图。
关闭远景订阅后两秒停止后台观察工作；reset/恢复清空请求、路径和发布视图。

## 有界路径与接口

- 每片最多检查 512 个订单、弹出 256 个寻路节点（过期 heap 节点也计数）。
- 路径缓存最多 128 条，每条最多 1024 点；单次搜索最多 65536 次 heap pop。
- 优先当前选中地块，再按稳定端点顺序显示；只输出最多 32 条路线。
- 路径按端点、来源国家、运输能力、贸易拓扑哈希和国家领土拓扑哈希复用。
- 独立六邻接 Dijkstra 复用现有陆路成本、水体分类及航行能力；将门户走廊展开为连续水格，
  水路每格成本 1、离水换装成本 2。河运段需已有河运能力且两端有河。
- 当前运输图允许的通行规则保持原样；视觉不引入新的关税、通行权或贸易模拟规则。
- 路径求解不足、超限或不可达时不显示，不退回穿越障碍的直线。
- 已交货而等待收款的订单不显示。缓存对代表订单 ID 做有界二分存活检查，
  不等待全量轮转扫描才发现到货；同一路线的其他订单可能在后续采样中补入。
- 搜索数组只在首次需要路径时分配；不存在贸易时没有路径纹理上传。

快照字段为 PackedArray：`source_cells/destination_cells/country_slots/era_indices/intensity/`
`capabilities/route_offsets/route_cells/edge_modes`。`route_offsets` 为 CSR，
`edge_modes` 与路径点对齐：0 陆运、1 水运，末点不代表一条额外边。
元数据包含 `serial/topology_hash/country_topology_hash/snapshot_day/vision_revision/`
`snapshot_source/scanned_orders/expanded_nodes/cache_hits/pending_routes/native_usec/memory_bytes`。
`ok=false, reason=trade_visual_pending` 时保留仍有效的前一帧。

`bake_trade_visual_paths(snapshot, width, hex_size)` 为纯数字上传烘焙器，
不访问模拟或 Godot Object，返回 1024×32 RGBAF 的固定 512KiB 路径像素、点数和路径长度。
RGBA 分别是展开后的世界 x/y、累计距离、`cell_index*4+mode`。
横向逐段采用最近圆柱副本；shader 再把载具移到距镜头最近的副本。

## 渲染和视野

一个固定 96 实例容量的 MultiMesh，由载具与阴影两个固定批次共享；近中景桌面最多 32 路线/96 载具，低画质、
mobile/web 最多 12/24。每路线 1–3 个，并按长度减少短路线上的重叠载具。
桌面最高 2Hz、低画质最高 1Hz 更新；相同路径只更新存活参数，不重新上传路径纹理。
新增路径、时代/强度变化、容量变化及失效才重建有界上传。

shader 用十次二分查找插值路径位置，并按路径方向旋转正俯视图集，无 CPU 逐载具动画或 Tween。
图集为 2 列 × 6 行，单个朝东的正交俯视资产保留 2:1 比例，避免斜视方向帧带来透视跳变。
动画按独立真实秒推进，暂停冻结、快进不加速。失去活动的路线最多两秒淡出。
缩放 0.35 以下隐藏并取消订阅，0.35–0.55 淡入；`reduce_motion` 保留静态载具。
时代外观按 11 时代归入六组，不解锁交通能力。

端点必须当前可见；shader 同时检查源、目的和当前路径边的两个地块。
共享 R8 可见性纹理随 `vision_revision` 更新，0/1 字节归一化后用 0.001 阈值判断。
缺失或尺寸错误的可见性阵列 fail closed。未探索/仅探索不显示实时贸易；
与项目既有约定一致，未解算 fog 或 GM 关闭 fog 时使用全知视图。

## 昼夜与地形光照

`player_game` 装配后调用 `HexRenderer.configure_trade_visuals(layer)`。地图渲染器在季节、
日相位、昼夜总开关、曝光、太阳调试参数变化时推送 `set_daylight_parameters`；
载具层缓存参数，仅把变化值写给两个材质。地形烘焙发布与 Horizon 异步完成时，
经 `set_terrain_lighting(world, source)` 同步地图边界、圆柱周期、纹理和 GI 参数。

所有画质复用 `earth_daylight.gdshaderinc` 的地理日照和天空 SH；高画质才读取
`visual_tile_sampling.gdshaderinc` 的地形法线与 `terrain_horizon.gdshaderinc` 的
直射可见度、天空可见度和 bent normal。计算位于 vertex 阶段，同一载具的四个顶点
使用同一个中心点采样，flat varying 传递整车光照，fragment 不采地形或计算 TOD。
这表示按中心近似整车光照，不是宣称 GPU 每实例仅执行一次 vertex shader。
支持 legacy Texture2D 及 tiled Texture2DArray，Vulkan RG16 / Compatibility RGBA8
Horizon 格式、地图环绕与地形使用相同解码。

高画质的阴影批次共享 MultiMesh、路径和可见性纹理，每辆载具只画一个柔边椭圆，
与树木的粗略阴影表现一致。基础椭圆按 12 种外观各自的图像占地与 UV 中心定位，
排除精灵格透明留白；搬运队、马车、篷车与货车不再共用整格尺寸和高度。
`TRADE_SHADOW_SHAPES` / `TRADE_SHADOW_HEIGHTS` 为静态美术元数据，只在装配时上传；
不在运行期扫描图片。太阳低垂时仍按高度伸长、偏移椭圆，投影长度上限按对象高度缩放。
高度和上限都相对当前载具尺寸计算，近景屏幕尺寸封顶时同步缩放。
fragment 用解析椭圆距离计算透明度，不采载具图集、不叠加轮廓副本。Horizon 挡光时减弱，
太阳落下时消失。低/中画质关闭阴影并跳过地形采样，仍保留昼夜着色。
配置集中在 `UITokens.TRADE_*`；清理/重绑会解除旧地形纹理引用，防止串用前一张地图。

## 验证入口

- `tests/trade_visual_runtime_test.gd`：真实陆运/水运、合法连续路径、预算、视野、
  拓扑失效、禁用、纯上传参数校验，以及 24 日效果开关权威 hash/守恒 A/B。
- `tests/trade_activity_layer_test.gd`：固定节点/容量、低画质、选择、暂停、倍速、
  远景、可见性、淡出、时代映射和重绑；图形模式可传 `capture_dir=...`。
- `tests/trade_visual_worker_test.gd`：真实在途订单、Country/Economy ACTIVE authority、
  正式 facade、批量渲染与后续提交的不可变视觉视图。
- `tests/trade_activity_lighting_test.gd`：真实 GPU 像素检查昼夜、法线坡向、直射遮挡、
  天空 GI、legacy/tiled 一致性、画质门控、投影和清理；需图形模式。
- `tests/trade_activity_runtime_integration_test.gd`：正式 player_game 与完整 0xFFF worker。
  单地块新局可能没有贸易；此时必须保持空场景，不伪造运输。
- `tests/trade_activity_perf.gd`：500×400 地址空间、32×1024 点、96 载具的渲染/上传压力，
  使用 viewport GPU 计时比较开启/关闭。它不代表 20 万市场的完整经济仿真压力。

性能结果和限制见同目录 `trade-visual-validation.md`。
