# 经济存档、catalog migration 与内容扩展 SOP

## PKEC v36（当前 writer）

v36 在 v35 的 cell 记录末尾追加 `support_ema_q16`（i32）：这是物资族盈余与阶层满意度
混合因子的慢 EMA（alpha ≈ 1/64 每日），生育读 EMA 以免单期丰收/歉收抖动。
`K_geo`、各族 cover、`K_eff` 都是派生诊断，不进存档、不进 `state_hash`。
v35 仍可读取，缺省 EMA=1；v34 及更早继续拒绝。`game_save_coordinator.gd` 的
`pkec` provider schema 为 36，兼容读取 `[35, 36]`。

格承载力三项混合 `K_eff = K_geo × EMA(mix(surplus)×mix(sat_cell))` 的公式见
[定点账本公式](./economy-fixed-point-ledger-formulas.md) 与
[原生经济运行时](./native-economy-runtime.md)。

## PKEC v35（历史 writer）

v35 在 v34 的运河 section 之后固定当前分组建材、ACTIVE/SUSPENDED_LOSS 建筑状态和
停产清算诊断。header 保存报价/项目数、quote/project/receipt 的 next-id，以及当前建筑
目录契约。v34 及更早版本不再读取或迁移；建筑目录和建材语义变化使旧存档明确不兼容。
详见[运河运行时](./canal-runtime.md)。
当前 reader 接受 v35（EMA 填 1）与 v36。

## 流式格式

存档只能在 committed boundary 开始。每个 chunk 是独立 section：

```text
u32 magic "PKEC"
u16 schema_version
u16 section
u32 record_count
u32 payload_bytes
payload
```

## PKEC v30（历史 writer）

PKEC v30 保留 v29 的全部 payload 与 section 集合（END 仍为 23），只扩展三个既有 section
的记录以持久化综合满意度权威列：

- `SAVE_SECTION_PAGES` 的 cohort 记录追加 `composite_satisfaction`(u16)、
  `worst_dimension_id`(u8)、`satisfaction_dims[SAT_DIM_COUNT]`(u16)、
  `income_baseline_ema`(i64)、`epoch_tax_paid`(i64)、`epoch_subsidy_received`(i64)；
- `SAVE_SECTION_FAMILY_INFLUENCES` 追加分支 `satisfaction_q16`；
- `SAVE_SECTION_CELLS` 追加已发布的社会压力等级，避免重载后重放已发过的等级跨越事件。

restore 校验每个维度值与 `worst_dimension_id` 的取值范围，越界即拒绝整个存档。全部新列
进 `state_hash`；need 分档/权重与 signature 阶层权重列进 `catalog_hash`。当前 reader
**只接受 v30**；v29 及更早统一返回 `economy_save_v29_or_earlier_unsupported`，
不提供隐式空状态迁移。`game_save_coordinator.gd` 的 `pkec` provider schema 同步为 30。
列语义见[综合满意度运行时](./satisfaction-runtime.md)。

## PKEC v29（历史 writer）

PKEC v29 保留 v28 的出生余数、人物、家族成员和建筑所有权，并新增家族特性运行时权威：

- section 20：`FamilyTraitRoll`，含 family handle、trait stable ID、Q16 强度及核心标志；
- section 21：generation-safe `FamilyCellInfluence`，含稳定分支 ID、三项份额、威望分/等级和评审状态；
- section 22：尚未到期的有序家族特性命令；
- section 23：END。

header 同时保存特性目录 version/hash、核心抽取范围和权威记录数。PKTR v2 单独保存动态分支
Trigger 累计，Modifier state v2 保存实例 `magnitude_q16`。v29 已被 v30 取代并被 reader
拒绝。完整联合存档仍必须先恢复 PKCN，再恢复 PKEC 和 PKTR/Modifier provider。

## PKEC v23（历史 writer）

PKEC v23 保留 v22 的生产气候、Modifier、科研采购、滚动经济、贸易、建筑、恢复和审计
payload，并在 cell record 追加上一批补贴申请及 generation-safe 国家 handle；财政 section
保存五类税种的上批与累计值，end section 后移。writer 仅写 v23。

reader 显式接受 v23，以及唯一的 v22→v23 税务迁移。v22 恢复为空补贴历史；对应 PKCN v3
先迁移为全零税率与空覆盖。新增 tax stat 导致的 Modifier catalog 差异只在该迁移中接受，
且旧 definition version、stat key 和 term payload 必须逐项匹配。其他 schema 或 catalog
差异仍按原有精确错误拒绝。

## PKEC v22（历史）

PKEC v22 keeps the complete modifier, technology-procurement, rolling economy,
trade, building, recovery, and audit payload. Its cell record is 76 bytes and
stores current temperature, 30-day temperature, ambient moisture,
plant-available water, snow, weather, settlement/generation lanes, and stable
rolling phase. Its building record adds four signed i64 diagnostics immediately
after total capacity: temperature fit, water fit, climate capacity, and
climate-lost output.

The six environment columns share a recomputed restore hash. Fit and capacity
must be in `[0,Q16_ONE]`; climate-lost output must be nonnegative. The four
building diagnostics enter the authoritative state hash. Truncated records,
invalid ranges, or an environment hash mismatch fail restore and the target does
not become bootstrapped.

The historical v22 writer and reader accepted schema 22 only. Any other schema, including v21,
returns `legacy_climate_production_save_unsupported`. There is no implicit
default for the two new frozen environment columns and no legacy climate
production migration.

历史 v16 在建筑记录中加入聚合商人债务本金/溢价、期限、逾期周期、恢复失败审查数、三态运行状态和
上一期自产生活价值；待建记录保存本金、溢价和期限。上述字段全部进入状态哈希、合法性检查、
内存统计和选中格快照。当前 reader 的兼容范围以上述 v18-v20 规则为准。

section 顺序：

0. header：尺度、cell/market/good/page/cohort 数、市场周期 N、seed、catalog hash、next submit
   order、稳定职业/民族/goods/plan ID 表、PKCN schema/generation/hash，以及建筑/施工/审计/信号/
   贸易计数、next trade order ID 和已解析贸易配置。
1. page records：page chain metadata 和每页 64 lane 完整 SoA/generation。
2. market records：所有 goods 的 stock/price/demand EMA/last shortage。
3. cell records：恒等 `cell_to_market`、当日六类 Q16 环境快照与 rolling generation。
4. pending commands。
5. building owner-lot records。
6. pending construction records。
7. audit history。
8. sparse market signal records。
9. sparse labor signal records。
10. trade order records：订单头、物资行 CSR 与卖方快照 CSR。
11. trade flow records：稀疏 `(cell, good)` 进出口 EMA/本周期流量。
12. Modifier records：BuildingIdentityStore 与 Economy Modifier domain。
13. fiscal history（v23）：逐国家五类税种的上批与累计财政值。
14. end（v23；v22 的 end 为 section 13）。

`read_economy_save_chunk(max_bytes)` 直接从当前 native vectors 编码本 section 的
record range，不构造巨型 Dictionary 或整份 byte buffer。page/market record 不会被
拆跨 chunk；请求 4–16MB 是生产建议，测试可使用 64KB。

restore 要先配置并完整恢复 PKCN v4，再用当前资源 catalog 调 `configure_economy()` 和
`begin_economy_restore()`。每个 feed 立即解析并写恢复存储；end 时验证：

- schema、尺度、catalog hash 和稳定 ID 表
- section 完整计数
- page next/cell、唯一 head、无环、无不可达页
- active count、generation、population/funds、signature range
- 同 cell signature 唯一
- 一地块一市场恒等映射、stock/price/EMA/shortage range、六列环境 snapshot/hash
- 建筑温度 fit、水分 fit、气候能力范围与非负气候减产量
- pending command opcode、handle generation 和 target range
- 已恢复 PKCN 的 schema、generation 和 state hash
- 贸易订单端点/状态/到达日、物资行/卖方 CSR、托管数量和稳定 next ID
- 贸易流 key 唯一有序且 `(cell, good)` 在 catalog 范围内
- 每个 cohort 的八个满意度维度值与 `worst_dimension_id` 落在 `[0, SAT_DIM_COUNT)` 范围内

通过后重建 committed summary；`get_economy_state_hash()` 应与保存前一致。

当前写出 schema 为 PKEC v31，并与 PKCN v7 交叉绑定。PKEC v30 及更早版本按当前兼容表处理；后文旧版本章节
只记录历史格式演进，不代表当前 reader 仍接受这些版本。拓扑和未完成规划从不存档，加载后重建；联合存档
只允许在国家命令图 idle 且经济位于 committed boundary 时开始。

## catalog 身份

资源文件发现顺序不是身份。`GoodProfileRegistry` 与 `EconomyCatalog` 都按稳定 `id`
排序，canonical columns 经 SHA-256 截取为正 `catalog_hash`。移动/重命名 `.tres`
文件而不改 stable ID 不影响索引。

当前 PKEC v31 与 PKCN v7 要求 save 的稳定 ID 表（含 technology IDs）与当前 catalog 完全一致，
并要求姓氏 `family_catalog_hash`、人物 `person_catalog_hash` 和特性
`family_trait_catalog_hash` 一致。不存在当前 reader 可用的 append-only 迁移例外。
本轮明确不提供旧 187-building/152-good 目录迁移，旧存档按现有 catalog mismatch 路径拒绝。
未来新增/删除/改 ID 若要兼容，必须提供显式迁移器；不能静默把缺失 profession/good 映射到第 0 项。未来 alias
迁移器应：

1. 读取旧 ID 表。
2. 应用版本化 `old_id -> new_id` alias。
3. 重写 signature/good 索引。
4. 对 stock/funds/population 做守恒审计。
5. 生成新 catalog hash 的 save。

need/variant/component、环境曲线与价格参数包含在 catalog canonical data。变更这些
数据会改变 catalog hash；确定性 replay 要求 hash 完全一致，不能无提示继续旧 replay。

## 新增 good

1. 在 `data/goods/` 新建 `GoodProfile.tres`。
2. 设置稳定 `id`、显示信息、定点 default/min/max price、initial stock、
   EMA、目标库存、压力权重、单日涨跌幅、`trade_enabled` 与正数
   `transport_load_per_unit_q16`；`cycle_flow` 必须禁运。
3. 在 need variant component 中引用 stable good ID。
4. 运行 catalog/native economy test。

不要修改 `MapData`、`component_ids.gd`、`component_schema.gd` 或 bind table。

## 新增职业或民族

职业资源设置 stable ID 与默认 plan；必须保留可解析的 merchant 职业。
民族资源设置 stable ID 与稀疏 need modifiers。`EconomyCatalog` 按职业×民族生成
signature table；历史 bootstrap provider 用 `EconomyFacade.signature_id()` 取得稠密
索引，不持久化资源文件顺序。

若增加宗教、法律身份、雇主等维度，应先提升 signature schema/version，再扩展
catalog compiler；不要给每个 cohort lane 预留空字段。

## 新增消费计划/need/bundle

plan 通过 stable need IDs 编译为 CSR；need 数 ≤32。每个 need 的 variants 是替代品，
每个 variant 的 components 是互补 bundle。新增内容优先修改 `.tres`；若新增 native
数学/字段，必须提升 schema/version，写定点 golden、worker/scalar hash 和 microbench，
重编所有目标平台并更新 replay compatibility。

## 旧 goods slot 迁移

下列链路已删除：

- `DCComponentIds.CELL_GOODS_*`
- `component_schema.gd` 的 8 条 `economy.goods` 行
- `MapData.goods_*_(qty|price)_arr`
- generated C++ bind entries
- `GoodProfile.quantity_component/price_component`
- map 默认 goods slot 初始化与旧 schema test

旧 Dictionary 世界存档中多余 `cell_goods_*` key 会被现有反序列化自然忽略；自然
资源 `cell.res_*` 完全不变。经济 runtime state 使用独立 PKEC stream，不从旧占位
slot 猜测库存。
# PKEC v3 建筑迁移

v3 在 page lane 后追加 `owner_employed`/`employee_employed`，并新增 BUILDINGS 与
CONSTRUCTION section。header 追加 building catalog hash、owner-lot 数和在建记录数。
restore 必须验证岗位不超过人口/建筑容量、owner profession 与建筑类型一致，并把建筑 cell
CSR 重建后才发布。

v2 chunk 仍可读取：沿用旧 page 宽度与 section end=5，新增就业字段置零，建筑与在建表为空。
v2 迁移以 profession/ethnicity/good/plan stable-ID 表和 numeric scale 为准，不要求旧 combined
catalog hash 等于加入建筑字段后的新 hash。

# PKEC v4 建筑财务快照迁移

v4 在每个 BUILDINGS 记录中追加 `last_input_cost` 与 `last_wages_paid`。两者均为
`MONEY_SCALE=10000` 的本结算周期实际值，用于选中地块 Inspector 按建筑 owner-lot 计算
`profit = last_revenue - last_input_cost - last_wages_paid`。v2/v3 仍可读取；迁移时这两个展示账本
字段置零，下一次 BUILDING_GRAPH 生产结算后刷新为实际值。字段参与确定性状态哈希，保存往返
必须保持完全一致。

# PKEC v5 建筑资源培育快照迁移

v5 在每个 BUILDINGS 记录中于 `last_resource` 后追加 `last_resource_generated`，单位为
`GOODS_SCALE=1000`，表示该 owner-lot 最近结算周期发布到自然资源 extra-change 通道的正培育量。
字段参与确定性状态哈希并供选中地块 Inspector 计算培育、采收与净变化。v2/v3/v4 继续可读；
迁移时该字段置零，下一次 BUILDING_GRAPH 生产结算后刷新。资源 reserve 与 pending extra 仍由
世界/DataCore 存档负责，不重复写入 PKEC stream。

# PKEC v6 事件审计摘要迁移

v6 header 在 pending-command count 后追加 `audit_frame_count`、`next_event_id` 与
`event_stream_hash`，新增 section 7 `AUDIT_HISTORY`，原 end section 移到 8。每个 audit record
保存 epoch/sample/commit day、event/leg count、population/money/goods error 和 stream hash。

主存档只带最近 `economy_trace_retention_epochs` 个审计帧与连续 ID 游标，不包含可能很大的
event/delta ring。详细历史通过独立 PKEJ v1 chunk stream 归档；读入 v2-v5 时初始化空审计历史、
`next_event_id=1`，并在成功 restore 后发布新的 `RESTORE_BOUNDARY`。核心 economy state hash
不包含 trace 配置、consumer cursor 或 event journal，因此 v5→v6 恢复仍保持权威状态 hash。

## 现代目录兼容边界

142-good/174-building/32-profession 跨时代目录的 good/building/profession/need、升级族与档位、
存储模式、货币锚、劳动岗位与 Price V3 参数均进入 catalog hash。2026-07-14 的服务/轨道链删除、
自给升级族与核燃料链改变了稳定目录；旧目录存档会以明确的 catalog mismatch 拒绝恢复，本期不做
跨目录库存、signature 或建筑 type remap。周期流电力在 committed boundary 恒为零，发行累计只通过已提交 cohort
funds/market stock 与 audit history 体现，不新增独立持久账户。

# PKEC v7 自适应价格与建筑经济计划迁移

v7 在 BUILDINGS 记录追加 `last_wages_due`、`last_expected_revenue`、`last_operating_cost`、
`last_margin_gap_q16`、`planned_utilization_q16` 与冻结 `sample_unit_input_cost`。新增 section 8
保存按 `(cell, good)` 稳定排序的 `business_demand_ema`、`offered_supply_ema` 和
`cost_anchor_price`，end 移到 section 9；header 追加 signal count。

v2-v6 restore 时建筑计划字段使用安全默认值，随后以当前建筑边重建稀疏 key 集；不存在的
历史信号从零开始。为允许仅新增 v7 目录字段的同内容存档迁移，编译器同时提供排除新字段的
v6-compatible market/building hash。v7 round-trip 必须保持完整 state hash；signal key 必须唯一、
按 cell/good 排序且引用范围合法。

# PKEC v8 自适应生活工资迁移

v8 在 BUILDINGS 记录追加 owner-lot 的基础工资、奖金和欠薪停产字段，并为每个编译 role
保存合同工资、两类生活成本、当地均薪及基础/奖金 due/paid。section 9
`LABOR_SIGNALS` 保存按 `(cell, profession)` 排序的生活成本、合同/实付工资 EMA、
job-days 与支付率；END 移至 section 10，header 追加 labor signal count。

v7 restore 使用 role reference wage 初始化合同工资，劳动市场信号在下一冻结周期重建。
编译器同时发布排除 v8 新目录列的 v7-compatible market/building hash。v8 round-trip
必须保持 group、role、LaborMarketStore 和其 CSR offsets 的完整 state hash。

# PKEC v12 企业停产、库存目标与实际出库迁移

v12 header 在 v11 贸易参数后追加严重亏损阈值/周期、恢复阈值/周期、商人现金保留率和冷启动
做市天数。BUILDINGS 记录追加 `purchase_intent_capacity_q16`、`realized_profit_margin_q16`、
`severe_loss_cycles`、`recovery_cycles` 与 `operating_state`；MARKET SIGNALS 记录追加
`realized_withdrawal_ema`。这些字段均参与权威 state hash。

v11 ACTIVE 迁移把新增企业字段初始化为 ACTIVE/0，并把实际出库 EMA 初始化为 0；只有当前六项
策略参数等于 v12 默认值时允许迁移。v11 PROBE 在 ACTIVE 配置下以
`save_trade_profile_mismatch` 拒绝；v10 在 ACTIVE 配置下以
`active_trade_rejects_v10_economy_save` 拒绝。v12 round-trip 必须保存停产连续数、采购意图和
实际出库历史，避免加载后企业或商人预算发生无提示跳变。
## PKEC v14

PKEC v14 persists the new behavior configuration and validates it at restore:
trade export days/fractions, import fill fraction, response days, investment
review/shortage/utilization/payback/operating cycles, resource reserve and safe
harvest ratios, resource horizon, bullion issue cap, and producer support cap.
The compiled resource generation, decay, ecology, climate-window, and growth
columns participate in the catalog and building hashes.

PKEC v13 is accepted only through the compiled v13 compatibility hashes. At the
commit boundary it receives the v14 default behavior values; desired/funded
demand, working-capital allocations, trade candidates, sparse response clocks,
investment scores, and rejection diagnostics are reconstructed transient state.
PKEC v10 and mismatched legacy ACTIVE/PROBE trade policies retain their explicit
rejection paths. PKCN must still restore before PKEC.

## PKEC v15 (historical)

PKEC v15 adds per-cell `last_settlement_day`, settlement generation, stable
phase validation, and the price/stock, owner-cash, population, building,
technology, resource, and trade dirty generations. Save is allowed only after
the daily local bucket, trade transactions, stable reduction, and publish have
completed.

PKEC v14 is migrated at restore by assigning phase `cell_id % 5` and deriving a
logical last settlement day no later than the saved committed day. The first
post-restore transaction still uses `dt=5`. Restore reports
`v14_rolling_phase_bootstrap` and immediately performs catalog/country binding,
state hash, and full conservation validation. The bootstrap itself creates no
cash, goods, population, buildings, escrow, or resource delta.

## PKEC v24

PKEC v24 adds tier index, prosperity generation, and name-roll generation to
the fixed cell record plus a sparse settlement-name section. Sparse records use
pack/prefix/root/suffix stable IDs and a disambiguator. The prosperity profile
hash must match. Name packs may add components; existing IDs resolve directly
or through aliases. Missing components fail explicitly.

PKEC v22/v23 remain readable. After population restore they rebuild tiers and
allocate names deterministically in ascending cell order with
`name_roll_generation=0`. PKCN still restores before PKEC.

