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

0. header：尺度、cell/market/good/page/cohort 数、市场周期 N、treasury、seed、catalog
   hash、next submit order、稳定职业/民族/goods/plan ID 表。
1. page records：page chain metadata 和每页 64 lane 完整 SoA/generation。
2. market records：所有 goods 的 stock/price/demand EMA/last shortage。
3. cell records：恒等 `cell_to_market` 与当日四类 Q16 环境快照。
4. pending commands。
5. end。

`read_economy_save_chunk(max_bytes)` 直接从当前 native vectors 编码本 section 的
record range，不构造巨型 Dictionary 或整份 byte buffer。page/market record 不会被
拆跨 chunk；请求 4–16MB 是生产建议，测试可使用 64KB。

restore 要先用当前资源 catalog 调 `configure_economy()`，再
`begin_economy_restore()`。每个 feed 立即解析并写恢复存储；end 时验证：

- schema、尺度、catalog hash 和稳定 ID 表
- section 完整计数
- page next/cell、唯一 head、无环、无不可达页
- active count、generation、population/funds、signature range
- 同 cell signature 唯一
- 一地块一市场恒等映射、stock/price/EMA/shortage range 与环境 snapshot
- pending command opcode、handle generation 和 target range

通过后重建 committed summary；`get_economy_state_hash()` 应与保存前一致。

存档仍为 schema v2：冻结周期没有增加 lane/matrix 字段，`epoch_days` 原字段现在解释为
`market_cycle_days`。会计惰性清零复用 `flags` 保留 parity bit，已包含在既有 lane record。
从旧每日 V2 档恢复后可继续运行，但重放语义因近似版本变化而不兼容；普通存档状态守恒。

## catalog 身份

资源文件发现顺序不是身份。`GoodProfileRegistry` 与 `EconomyCatalog` 都按稳定 `id`
排序，canonical columns 经 SHA-256 截取为正 `catalog_hash`。移动/重命名 `.tres`
文件而不改 stable ID 不影响索引。

当前 schema v2 要求 save 的稳定 ID 表与当前 catalog 完全一致。新增/删除/改 ID
时必须提供显式迁移器；不能静默把缺失 profession/good 映射到第 0 项。未来 alias
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
2. 设置稳定 `id`、显示信息、定点 default/min/max price、initial stock 和
   EMA、目标库存、压力权重和单日涨跌幅。
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
