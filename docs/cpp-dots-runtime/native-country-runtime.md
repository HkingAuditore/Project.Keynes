# Native Country Runtime（PKCN v3）

`NativeCountryRuntime` 是国家身份、领土、国家科技与国家国库的唯一可变权威。它与
`NativeEconomyRuntime` 同级，由 `DCWorldExt` 组合持有；GDScript 不维护第二份国家状态。

## 数据布局

- `CountryStore` 为稠密 SoA：active、generation、stable ID、显示名、领土数、现金和状态版本。
- 外部句柄为 `(generation << 32) | slot`；存档身份使用 stable ID。
- `cell_country_slot:int32` 保存单一地块所有者，`-1` 为无主；国家到地块使用 CSR。
- 科技为 `country × technology` bitset；无主地没有科技。
- 国库物资为 `country × good` 稠密 `i64` 矩阵。现金使用 `MONEY_SCALE=10000`，物资使用
  `GOODS_SCALE=1000`。
- 只有 `cell.country_slot` 进入 DataCore/MapData。名称、科技、国库与 CSR 不进入 HexCell、
  Godot Object 或逐格 component。
- 视野迷雾与国界线**不属于本运行时**。它们只把 `cell.country_slot` 当只读输入：
  `VisionSolver` 以玩家领土为解算源，`CountryBorderLayer` 靠邻格归属差异生成 mesh。
  两者的状态存在 `MapData` 与 Godot 渲染层，不进 PKCN。

100k cells、512 countries、200 goods、4096 tech 的主要 POD 容量约 1.9MB；即使计入
CSR、元数据和分配器余量，也以 `<8MB` 为验收门槛。

## 启动不变量

显式启动包使用国家并行列及领土/科技/国库 CSR。启动前完整拒绝重复领土、水域归属、
未知 good/technology、空名称、重复 stable ID 和零领土国家。

缺少国家记录时创建 `country.default / 默认国家`，占有全部非水地块，水域无主。全水地图
返回 `country_bootstrap_no_land`。允许飞地和无主陆地；活跃国家必须至少有一格。

## 命令与查询

固定命令为 `CREATE_COUNTRY`、`RENAME_COUNTRY`、`TRANSFER_TERRITORY`、
`GRANT_TECHNOLOGY`。命令按 `(effective_day, sequence, submit_order)` 确定性排序，先完整
预检，再提交稀疏地块 delta。建国命令直接携带第一块领土，因此建国与领土获得原子完成；
科技复制该地原所有国，来自无主地时使用起始科技。当前版本不提供删除国家、灭国或撤销科技。

GM 的“点击地块接管领土”不新增 opcode：`WorldRuntimeHost` 在会话级模式开启时监听既有
选中回调，解析玩家国家 handle，并包装 `TRANSFER_TERRITORY` 到下一游戏日。水域、已归属和
同格重复排队在 host 边界提前返回；最后领土保护、handle 有效性、原子批次与经济冻结规则
仍由 native 预检决定。

冷查询为：

- `get_country_cell_summary(cell)`：国家句柄/ID/名称、领土数、现金、非零物资种类和科技数。
  无主格（`country_slot == -1`）返回 `owned=false`，`country_name` 固定为 UTF-8「无主之地」。
- `get_country_snapshot(handle)`：元数据、领土 CSR 切片和已解锁科技 stable IDs。
- `get_country_treasury_snapshot(handle)`：现金及非零物资 stable IDs/数量。
- `poll_country_events(after_event_id, limit)`：已提交国家事件并行列。

热循环不得使用 Dictionary、Object、字符串查找或循环内分配；这些只出现在配置、命令边界、
查询、事件与存档冷路径。

## 权威模式

`ACTIVE` 是生产默认并发布 `cell.country_slot`；`PROBE` 运行原生状态但不发布该可见镜像；
`OFF` 明确禁用依赖国家科技/国库的经济，不恢复逐地块科技或全局国库。

## 国家视觉挂钩

`CountryFacade.country_committed` 是领土变更的唯一广播点。`WorldRuntimeHost` 订阅它并
调用 `refresh_country_visuals()`，按顺序重算视野、强制重烘 `enum_lut`（迷雾知识度住在
它的 A 通道）、重建国界 mesh。领土变更极少，所以全量重建，不做增量。

注意 Inspector 的国家摘要受迷雾门控：`FOG_UNEXPLORED` 的格子不展示任何国家信息，
即使 `get_country_cell_summary()` 能返回。详见
[视野迷雾与国界线](./vision-fog-and-borders.md)。
> 科技树扩展说明见[科技树、科技值与科研经济运行时](./technology-tree-runtime.md)。PKCN v3
> 新增 discovery/completed/pending bitset、稀疏研究进度、四领域队列与权重、采购政策、暂缓
> 科技值和研究审计计数；旧版本明确拒绝恢复。
