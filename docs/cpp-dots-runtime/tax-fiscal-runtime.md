# 税收与财政结算运行时

税收不是独立运行时。政策、国家级 Modifier 和现金国库归
`NativeCountryRuntime`；应税事件、冻结有效税率、财政托管与结算归
`NativeEconomyRuntime`。GDScript 只负责 stable ID 校验、命令打包和玩家界面。

## 政策模型

五类税种的 dense 编号固定为所得税、消费税、营业税、进口关税、出口关税。每国保存
`[-100,100]` 的整数默认率，并保存以下稀疏覆盖：

- 所得税：`profession_id`，即工匠、采集者、学徒、企业家等职业 cohort。
- 消费税：`good_id`。
- 营业税：`building_type_id`。
- 进口/出口关税：各自按 `good_id`。

负值表示补贴，覆盖清除后立即恢复继承当前默认率。`CountryFacade` 把 stable ID
转为 dense ID，提交 `SET_TAX_DEFAULT`、`SET_TAX_OVERRIDE` 或
`CLEAR_TAX_OVERRIDE`；`country_daily` 在命令的 effective day 原子提交，经济图随后
冻结本轮到期 cell 使用的政策。

地块级政策使用 `CellTaxPolicyStore` 的稀疏驻留行：每格只有一个 `u32` policy ID，
`0` 表示完全继承全国；驻留行保存五个可继承默认率和按 `(kind,item)` 排序的细项覆盖。
继承固定为“地块细项 → 地块税种默认 → 全国细项 → 全国税种默认”，最后统一应用
Country Modifier。显式本地值即使等于父级也不会自动消失，只有 clear/reset 命令恢复继承。
领土易主在同一原子提交中把该格 policy ID 置零。

Modifier stat key 由同一份排序后的 economy catalog 生成：

```text
country.tax.income.<profession>.rate_pct
country.tax.consumption.<good>.rate_pct
country.tax.business.<building>.rate_pct
country.tax.import.<good>.rate_pct
country.tax.export.<good>.rate_pct
```

每个 economy epoch 只编译实际出现的 `(country, policy)`。本地默认率按
`(country, kind, base_rate)` 共享连续有效率行，细项覆盖只编译自身条目；worker 查询为
逐格 bitmask → 短有序细项切片 → 共享默认率行 → 全国连续率。最终值按半值远离零量化为整数，
再 clamp 到 `[-100,100]`；worker 热路径只读连续数组，不做字符串、Variant、Godot API
调用或共享国库写入。

五类冻结税表同时生成 epoch active-tax bitmask。对应税种全零时，家庭订单、工资、商人所得、
建筑生产、招聘价值、投资价值和财政提交均走原有零税快路，不建立逐交易税务草案；因此默认
`0%` 政策不应为 worker 热路径引入字符串、分配或无意义的逐项税额计算。

PKCN v7 按 cell 和 stable item ID 的规范顺序保存稀疏地块政策及 pending 命令；内部
policy ID 不进入存档或确定性 hash。PKEC 保持 v31，并在恢复后从 PKCN v7 重新编译缓存。

## 行为价值判断

- 家庭购买直接使用消费税后的预算报价。正税压低同一预算可购买数量；负税只有在本 cell
  已取得财政预留后才降低报价。
- 建筑招聘保留既有生存物资和短缺优先级，再按各职业的税后/税前工资保留率比较岗位。
  零税率时该键完全相同，因此不改变既有招聘顺序；职业覆盖税率会改变相对岗位吸引力。
- 业主转岗使用扣除预期营业税和所得税后的日收入；内生投资使用税后经营收入计算生存门槛、
  目标利润率、回本期和创业者收入改善，因此高税率可以阻止税前可行但税后不可行的项目。
- 负税率不按名义全额进入预期。预期补贴按“本批财政预算 / 上批申请”确定性折算；首次启用
  消费税或营业税且没有历史申请时预期兑现为零。负所得税例外：已冻结的人口最低生活申请
  可在本批直接建立预留，因此零收入 cohort 不必等待一个历史批次。

## 税基和资金方向

统一税额公式为：

```text
floor(tax_base * abs(rate_percent) / 100)
```

计算使用 checked/saturating `int64` 定点助手。

- 正所得税的工资在入账时按 cohort 职业源头扣缴。建筑业主按实际经营回款减实际投入、工资和
  正营业税后的正向净所得计税；商人按家庭销售回款减经营流出后的正向净所得计税。亏损不
  跨批结转，补贴、转账、铸币、投资和资本本金不形成所得税税基。
- 负所得税改在全部应税来源完成后按 cohort 汇总结算。每个 cohort 的最低生活税基为
  `survival_household` 生存篮子的冻结本地每日成本乘人口和批次天数；补贴税基为
  `max(工资 + 正向业主净经营所得 + 正向商人家庭销售净所得, 最低生活税基)`。因此零收入
  cohort 仍按最低生活税基申请，高收入 cohort 继续按实际应税收入申请。最低生活税基仅用于
  负税，正税绝不对推定收入征收。
- 消费税只作用于人口 cohort 的家庭订单。正税进入预算报价，商人仍只取得商品基准成交价；
  负税按本 cell 已预留额度和稳定订单顺序降低预算价，实际成交才扣用托管额度。
- 营业税按建筑本批实际取得的生产者回款计税，多输出建筑汇总实际回款。正税源头扣除并可
  从业主经营所得税基扣除；负税付给业主且不形成新的应税所得。
- 当前国内贸易不产生关税事件。进口、出口政策和 Modifier 已可配置、保存和查询，财政快照
  的关税事件与金额保持零，等待未来外贸结算明确 importer/exporter。

税款在财政提交阶段进入征税 cell 所属国家国库，且只能参与下一批补贴预算。所有税和补贴
都是主体间转移；货币审计包含财政托管，因此 population/money/goods 三项误差必须始终为零。

## 财政托管

每个五日滚动桶开始时，经济运行时读取同一 `(generation-safe country, tax kind, cell)`
上一批的补贴申请。消费税和营业税使用上一批申请作为权重；所得税 lane 使用
`max(previous_request, current_minimum_living_request)`，其中当前最低生活申请可由冻结人口和
生存篮子在批次开始时确定。国家先预留 `min(cash, reservation_request)` 到 fiscal escrow，
再执行科研采购。额度按国家内预留权重比例分配，整数余数通过“税种、cell”稳定前缀分配。

工资、业主经营所得和商人家庭销售净所得先写入各自 slot 的临时应税收入列；全部 household
market 完成后，`household_market/income_subsidy` 子阶段按 cohort 汇总申请。同一 cell 的负
所得税在预算不足时按申请额同比例分配，稳定前缀处理整数余数。消费税和营业税仍由 worker
只修改自己 cell 的申请、预算和实付 lane；这两类补贴首次启用且没有历史申请时本批实付为零。提交时
未用托管款退回国库、正税统一入库、托管清零；领土转移导致 generation-safe 国家 handle
不匹配时，旧 cell 权重自动失效，但当前最低生活申请仍可建立新的所得补贴预留。

`fiscal_snapshot()` 按五类税种返回上批税基、应征、实收、补贴申请、预留、实付、未满足额、
兑现率及累计值。进口/出口项当前固定为零。

## 存档与迁移

- PKCN v4 保存五类默认率、稀疏覆盖、政策版本和 Country Modifier domain。
- PKEC v24 保存逐 cell 上批补贴权重、generation-safe 国家 handle、财政累计值和确定性 hash。
- PKCN v3/PKEC v22 有且只有一条显式迁移：基础税率全零、覆盖为空、补贴历史为空。新增税率
  stat 的 Modifier catalog 扩展仅在这条迁移中接受，并逐项验证旧 definition version、
  stat key 和 term payload；其他 catalog mismatch 仍拒绝。
- 保存只允许在既有 committed safe boundary；PKCN 必须先于 PKEC 恢复。

## UI 与验证

税务页位于国家“经济”工作区内部，包含国库、所得税、消费税、营业税和关税分页；关税
页按物资合并展示同一物资的进口、出口两档税率。分页以卡片网格渲染：页签带税种图标与
“已解锁 X/Y”提示，卡片内名称与税率输入相邻。CountryViewModel 的 `present_tax_policy`
按国家已完成科技过滤条目：profile `technology_tags` 中的可执行 `tech.*` 要求全部满足
才列入，未解锁的职业、物资和建筑不渲染；显示名来自各 profile 的中文 `display_name`，
图标来自 IconCatalog 语义键。输入即覆盖：输入与默认不同的税率即提交次日生效的覆盖命
令，输回默认值或点重置按钮则清除覆盖；继承默认的输入暗色显示，覆盖项黄铜高亮。修正
后有效率与基础率不同时卡片附注“修正后 X%”。卡片节点复用，每日刷新不重建树。关税页
可编辑，但显示“待跨国贸易接入”。

最低验证集为 country、economy rolling、building、modifier、game-save 和玩家国家 UI
focused suites，加 debug/release 构建及 50 日 production-path benchmark。确定性测试必须
覆盖 worker 数、slice budget、continuation、保存恢复和财政 hash。
