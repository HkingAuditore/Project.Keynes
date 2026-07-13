# Country / Economy Native Bridge

经济运行时通过 `NativeCountryRuntime*` 窄桥读取国家状态，不经过 GDScript，也不复制为另一份
长期权威。

## 冻结边界

每个经济 sample day 在 `epoch_begin` 复制：

- `cell_country_slot`
- `country × technology` bitset
- country generation 与 state hash

该快照与人口、资金、价格、库存、环境和建筑上下文属于同一冻结周期。周期中提交的领土或科技
变化只影响下一周期。领土转移不会移动人口、建筑或当地商人库存。

商品、职业和建筑的技术门控统一执行 `cell → frozen country → technology bit`。无主地没有
科技。经济不再拥有科技授予命令或逐地块科技 bitset。

## 资产转移与守恒

现金命令携带国家句柄和 cohort 句柄；物资命令携带国家句柄、地块市场和 good dense ID。
双向转移按可用余额/库存及目标容量封顶，只移动既有资产，不征税、不付款、不铸币。

审计口径：

```text
total_money = all cohort funds + all country cash
total_goods = all market stock + all country treasury goods
```

显式 mint/burn、外部 stock delta、居民消费、建设投入、生产投入/产出和丢弃仍分别记账。
每次提交要求 population/money/goods error 精确为 `0/0/0`。经济 state hash 混入当前 PKCN
state hash；冻结报告公开 `country_schema_version`、`country_generation` 和
`country_state_hash`。

国家 `OFF`、目录数量不一致或快照 shape 不一致时返回 `country_runtime_required` /
`country_snapshot_shape_invalid`，经济不会恢复旧的全局国库或逐地块科技路径。
