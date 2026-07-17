# Project.Keynes 经济数值工作台

这是一个零依赖、只读、可离线打开的内容校准工具。它直接扫描当前项目中的 Godot 文本资源，
不读取经济 CSV，也不复制一套运行时状态。

## 使用

1. 用 Chrome 或 Edge 打开 `index.html`。
2. 选择包含 `Project/` 与 `tools/` 的仓库根目录。
3. 打开“数值预计算”，调整时代、建筑数量、利用率、商人承接率和岗位人口倍率。

浏览器只获得所选目录的读取权限。支持 File System Access API 的浏览器会记住目录句柄，并在下次
打开时重新扫描最新资源。

## 预计算口径

- 数量使用游戏的 `GOODS_SCALE=1000`，金额使用 `MONEY_SCALE=10000`。
- 采用当前 `GoodProfile.default_price`。
- 建筑显式、类目和配方局部候选投入使用与内容审计一致的“价格 ÷ Q16 效率”最低成本候选。
- 建筑收入使用每种产出的 `merchant_buy_price_factor_q16`，并乘用户输入的商人承接/售出率。
- 员工成本使用 `employee_reference_wages_per_day`。
- 业主生活费只累计 `NeedProfile.living_cost_weight_q16` 加权的消费计划部分；目标利润率按
  `max(运营成本/(1-target margin), 运营成本+业主生活费)` 检查。
- 居民消费在默认价格、财富/环境/族群系数为 1、库存充足的参考点展开；同一 need 的 variants
  按 `variant_preference_q16` 分摊，variant 内 components 作为互补品一起计入。
- 供给使用建筑产出乘利用率与承接率；需求由建筑物理投入和建筑岗位人口的居民消费组成。
- 金银等 `monetary_issue_value > 0` 的建筑标记为货币发行例外，不纳入普通亏损计数。

这是设计时 reference scenario。运行时的资金约束、库存短缺、冻结价格、财富弹性、环境曲线、
民族修正、生产者自留、托底入库、实际就业和动态利用率仍由 `NativeEconomyRuntime` 权威处理。

## 验证

```powershell
node --check tools/supply-chain-explorer/parser.js
node --check tools/supply-chain-explorer/app.js
node tools/supply-chain-explorer/parser.test.js
node tools/supply-chain-explorer/current_data.test.js
node tools/supply-chain-explorer/balance_report.js --summary
```

`parser.test.js` 覆盖居民替代品分摊、类目投入效率选择和建筑盈亏公式；
`current_data.test.js` 直接扫描当前游戏资源并验证全量预计算结果有限且可生成；
`balance_report.js` 按时代输出 80% 承接率下的亏损建筑与最高覆盖物资，便于提交前比较数值改动。
