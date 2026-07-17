# 经济存档、catalog migration 与内容扩展 SOP

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

section 顺序：

0. header：尺度、cell/market/good/page/cohort 数、市场周期 N、seed、catalog hash、next submit
   order、稳定职业/民族/goods/plan ID 表、PKCN schema/generation/hash，以及建筑/施工/审计/信号/
   贸易计数、next trade order ID 和已解析贸易配置。
1. page records：page chain metadata 和每页 64 lane 完整 SoA/generation。
2. market records：所有 goods 的 stock/price/demand EMA/last shortage。
3. cell records：恒等 `cell_to_market` 与当日四类 Q16 环境快照。
4. pending commands。
5. building owner-lot records。
6. pending construction records。
7. audit history。
8. sparse market signal records。
9. sparse labor signal records。
10. trade order records：订单头、物资行 CSR 与卖方快照 CSR。
11. trade flow records：稀疏 `(cell, good)` 进出口 EMA/本周期流量。
12. end。

`read_economy_save_chunk(max_bytes)` 直接从当前 native vectors 编码本 section 的
record range，不构造巨型 Dictionary 或整份 byte buffer。page/market record 不会被
拆跨 chunk；请求 4–16MB 是生产建议，测试可使用 64KB。

restore 要先配置并完整恢复 PKCN v1，再用当前资源 catalog 调 `configure_economy()` 和
`begin_economy_restore()`。每个 feed 立即解析并写恢复存储；end 时验证：

- schema、尺度、catalog hash 和稳定 ID 表
- section 完整计数
- page next/cell、唯一 head、无环、无不可达页
- active count、generation、population/funds、signature range
- 同 cell signature 唯一
- 一地块一市场恒等映射、stock/price/EMA/shortage range 与环境 snapshot
- pending command opcode、handle generation 和 target range
- 已恢复 PKCN 的 schema、generation 和 state hash
- 贸易订单端点/状态/到达日、物资行/卖方 CSR、托管数量和稳定 next ID
- 贸易流 key 唯一有序且 `(cell, good)` 在 catalog 范围内

通过后重建 committed summary；`get_economy_state_hash()` 应与保存前一致。

当前写出 schema 为 PKEC v13，并与 PKCN v1 交叉绑定。只有参数一致的 v11 ACTIVE 可迁移；
旧默认 v11 的 25%/1 日商人策略与当前 12.5%/30 日分档库存基线不一致，返回
`save_business_policy_profile_mismatch`；
ACTIVE 配置拒绝 v11 PROBE 和 v10。拓扑和未完成规划从不存档，加载后重建。PKEC v2-v9 缺少国家权威状态，读取时
精确返回 `legacy_countryless_economy_save_unsupported`；不再通过默认国家、全解锁科技或全局
国库静默迁移。联合存档只允许在国家命令图 idle 且经济位于 committed boundary 时开始。

## catalog 身份

资源文件发现顺序不是身份。`GoodProfileRegistry` 与 `EconomyCatalog` 都按稳定 `id`
排序，canonical columns 经 SHA-256 截取为正 `catalog_hash`。移动/重命名 `.tres`
文件而不改 stable ID 不影响索引。

当前 PKEC v12 与 PKCN v1 要求 save 的稳定 ID 表（含 technology IDs）与当前 catalog 完全一致。
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
