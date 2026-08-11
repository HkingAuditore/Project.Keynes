# 运河运行时（API-ready，PlayerController 未注册）

## 边界与状态

运河是永久地理设施，但施工属于 `NativeEconomyRuntime`。DataCore 的
`cell.canal_edge_mask`（U8，低六位、相邻位互反）和
`cell.canal_water`（F32）是地图权威状态；实现不得改写 terrain、is_water、天然河流
SDF、`cell.hydro_parent` 或自然排水 DAG。Economy 保存报价、项目、路线和回执序列；
Effect 只携带项目 handle，成功 ACK 后 Economy 才归档路线。

`EconomyFacade` 已提供：

- `get_canal_route_quote(country_handle, start_cell, end_cell, waypoints)`
- `get_canal_route_quote_detail(country_handle, quote_token)`
- `queue_canal_construction(country_handle, quote_token, effective_day, sequence)`
- `infrastructure_command_settled(result)`

报价 token 绑定国家、日期、领土代次、价格快照、路线和运河拓扑 hash。正式施工只接受
token，不接受客户端路线回传。路线由原生确定性 Dijkstra 生成，最多 32 边，支持 X
环绕和 waypoints；科技、领土、水源、山峰/火山/冰川、单边高差和累计逆坡均在报价时
验证，执行与 Effect commit 时再验证。

## 施工与跨域提交

每条新边默认消耗 lumber 6750、bricks 6750、5 日；坡度及困难地貌将材料和工期提高，
上限 2 倍。国库物资优先，缺口从起点市场购买，现金由国库支付并记入现有守恒审计。
已存在的互反运河边免费复用。开工后领土易主不取消项目。

完成链路固定为：

`InfrastructureProjectStore -> gameplay fact(handle only) -> PKEF built-in -2 ->`
`geography.canal.commit -> DataCore atomic mask publish -> Effect ACK -> route archive`。

commit 从 Economy 读取最多 33 格的只读载荷，复验格号、方向、真实六邻接、互反方向、
拓扑 hash 和幂等键，再以一次 PackedByteArray 赋值发布整条路线。任何失败都不会暴露半条
运河。

## 寻路、气候与画面

`TradeTopologyStore.edge_cost[cell*6+dir]` 是方向边成本；互反运河边将贸易和殖民运输
成本减半。mask 纳入拓扑 hash，只有实际运河拓扑变化或恢复时才清空路线计划/cache。

`runtime_hydrology` 的天然水预算完成后运行运河阶段。运河拓扑代次变化或 MapData
重新绑定时才扫描全图并编译稀疏运河格表；普通日结只访问运河格及一圈邻格。水分沿
互反边以 4%/边衰减传播。淡水运河对运河格/一圈邻格分别使用河岸增湿强度的
60%/50%，写 soil、WB30、plant water、moisture；咸水只应用 20% 蒸发/湿度作用，不向
soil 或 plant water 注水。该阶段不从天然河流扣流量。

Visual Tile `height` RGBA8 固定为 RG=视觉高程、B=天然河流 SDF、A=运河 SDF。沟槽
最大只下压半个 8-bit 高度量化单位，不触发 horizon/GI。commit 只排队路线及一圈 halo
覆盖的 tile；C++ 返回 height/terrain_normal，Godot 协程每帧至多上传一个 array layer。
失败 layer 留在队列中重试。shader 复用现有 height sampler，不增加 Web sampler。

## 存档与玩家控制契约

PKEC v34 新增 canal quote/project sections 和三个 next-id；v33 恢复为空报价、空项目，
DataCore dynamic-world 字段迁移为零。PKEF 保存未 ACK 的 `program_id=-2` 事务。恢复顺序
仍为 DataCore/PKCN -> PKEF -> PKEC -> topology recapture -> scheduler；纹理不保存，
由恢复后的 mask 重新标脏。

当前明确不注册 `infrastructure.canal.build`：`PlayerController.SUPPORTED_COMMANDS`、
InputMap、MapCamera、player_view、player_game.tscn 和 UI 均不包含运河。未来 Controller
包装器只接收 `quote_token`，自动注入玩家国家，通过会话/国家/token 格式验证后才分配
sequence，并以次日为 effective_day；Controller 不持有路线。
