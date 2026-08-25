# Native Country Runtime（PKCN v11）

PKCN v11 保留玩家时代奖励的最小交叉引用：plan ID、Offer 代际、里程碑科技和
`OPEN / SELECTED_PENDING / RESOLVED / ERROR` 状态。完整备选仍由 PKEF v10 持有；
PKEF 恢复时必须与该引用逐字段一致。PKCN v11 额外把科技/研究信号/Effect recipe 与
Modifier term identity、Trigger 定义摘要及完整内容绑定摘要混入国家 catalog hash。
旧 schema 或任一 identity 不一致统一返回 `catalog_hash_mismatch`。

PKCN v11 保留 Effect/POD `CLAIM_UNOWNED_TERRITORY` 与时代奖励引用。
`CLAIM_UNOWNED_TERRITORY` 只允许目标
当前为 neutral，供[家族远程开拓事务](./family-colonization-runtime.md)在
Country priority 255 提交；侵略、吞并与通行权不复用该 opcode。

> v7 adds the authoritative `CellTaxPolicyStore`: `cell_policy_id[cell]` uses
> `0` for full national inheritance, while identical non-empty policies are
> content-interned. Commands 15..19 stage only touched cells. Territory transfer
> clears the local policy atomically. Save/hash surfaces canonicalize by cell and
> stable item ID; transient policy IDs never cross the persistence boundary.

## Research signals

`NativeCountryRuntime` also owns country discovery evidence for the compiled
`ResearchSignalCatalog`. Static map signal CSR is not country state: when vision
first explores a cell, GDScript submits `DISCOVER_COUNTRY_SIGNAL` for the player
country at the next country boundary. Native storage uses a bitset for permanent
presence plus sparse sorted evidence for distinct observed cells, counts, and
first/last observation provenance. Technology condition IR reads these numeric
snapshots; it never queries map Resources, strings, or dictionaries in the daily
research loop.

The active command is `DISCOVER_COUNTRY_SIGNAL=14`; it is deduplicated by the sorted
`(signal_dense_id, cell_idx)` key before evidence and facts are published. The first native map
pass writes landform CSR only. After resource bootstrap, `run_bio_seed_pass` writes
`cell.bio_occupancy_bits`; resource facts are appended to the same CSR. First exploration submits
landform/resource CSR plus **current** occupancy bits. Occupancy 0→1 on an already-explored cell
submits `DISCOVER` again. Local extinction does not revoke country evidence. The cold snapshot exposes
signal IDs, distinct counts, first/last days, and first cells. A signal catalog mismatch, malformed
dense ID, invalid cell, or legacy PKCN schema is rejected rather than defaulted; schema/catalog
identity failures use `catalog_hash_mismatch`, while malformed commands keep their precise reason.

`NativeCountryRuntime` 是国家身份、领土、国家科技、税务政策与国家国库的唯一可变权威。它与
`NativeEconomyRuntime` 同级，由 `DCWorldExt` 组合持有；GDScript 不维护第二份国家状态。

## 数据布局

- `CountryStore` 为稠密 SoA：active、generation、stable ID、显示名、领土数、现金和状态版本。
- 外部句柄为 `(generation << 32) | slot`；存档身份使用 stable ID。
- `cell_country_slot:int32` 保存单一地块所有者，`-1` 为无主；国家到地块使用 CSR。
- 科技为 `country × technology` bitset；无主地没有科技。
- 国库物资为 `country × good` 稠密 `i64` 矩阵。现金使用 `MONEY_SCALE=10000`，物资使用
  `GOODS_SCALE=1000`。
- 税务政策为每国五个默认整数百分比及职业/物资/建筑 dense 覆盖矩阵，`127` 表示继承。
  存档和 UI 只公开稀疏例外；经济快照直接复制已展开的连续税率数组。
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

正式新游戏一次提交玩家与外国的完整启动包：玩家固定为 slot 0 / `country.player`，外国使用
`country.foreign.NNN`，每国初始拥有一个确定性选择的出生格。未被这些国家占有的陆地保持无主。

缺少国家记录时创建 `country.default / 默认国家`，占有全部非水地块，水域无主。全水地图
返回 `country_bootstrap_no_land`。允许飞地和无主陆地；活跃国家必须至少有一格。

## 命令与查询

命令包括国家/领土/科研操作及 `SET_TAX_DEFAULT`、`SET_TAX_OVERRIDE`、
`CLEAR_TAX_OVERRIDE`。命令按 `(effective_day, sequence, submit_order)` 确定性排序，先完整
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
- `get_country_tax_policy_snapshot(handle)`：默认率、稀疏覆盖、基础/Modifier 后有效率、
  政策版本和 economy catalog hash。
- `get_country_fiscal_snapshot(handle)`：由 Economy Runtime 发布的五税种财政结果。
- `poll_country_events(after_event_id, limit)`：已提交国家事件并行列。

热循环不得使用 Dictionary、Object、字符串查找或循环内分配；这些只出现在配置、命令边界、
查询、事件与存档冷路径。

## 权威模式

`ACTIVE` 是生产默认并发布 `cell.country_slot`；`PROBE` 运行原生状态但不发布该可见镜像；
`OFF` 明确禁用依赖国家科技/国库的经济，不恢复逐地块科技或全局国库。

经济侧国库资助建设通过内部 `spend_treasury_assets` 批量接口扣除多种物资与现金。接口先验证
handle、重复 good、非负数量和全部余额，再一次性提交并只递增一次国家版本；任何预检失败均不
改变国库。市场扣减和商人收款仍由 `NativeEconomyRuntime` 在同一经济事务路径负责。

## 国家视觉挂钩

`CountryFacade.country_committed` 是唯一广播点。`WorldRuntimeHost` 仅在报告的
`changed_cells > 0` 时重算视野和国界；纯证据、税务和国库 commit 不触发全图工作。
磁针导航 capability 首次完成会单独重算科研资格与迷雾 LUT，但不重建国界。

`DISCOVER_COUNTRY_SIGNAL` 的 observation-only 批次在 native 内按
`(signal << 32) | cell` sort/unique，再与已有有序 evidence 线性合并。每个
`(country, signal)` 只刷新一次 reveal condition，并只发一条携带
`evidence_delta` 与首格的聚合事件。标量命令仍走同一个国家日安全边界；不存在
第二份证据 authority 或绕过 barrier 的写入。

注意 Inspector 的国家摘要受迷雾门控：`FOG_UNEXPLORED` 的格子不展示任何国家信息，
即使 `get_country_cell_summary()` 能返回。自然资源检查器对 `FOG_VISIBLE` 格子使用观察者
国家已掌握科技认矿；无主地没有科技，但不能因此把全图已生成的储量显示成未配置。详见
[视野迷雾与国界线](./vision-fog-and-borders.md)。
> 科技树扩展说明见[科技树、科技值与科研经济运行时](./technology-tree-runtime.md)。当前
> PKCN v11 持久化 discovery/completed/pending bitset、稀疏研究进度、四领域队列与权重、
> 采购政策、暂缓科技值、研究信号证据和审计计数；旧版本明确拒绝恢复。
