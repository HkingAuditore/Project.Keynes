# Project.Keynes 经济数值工作台

这是一个只读的离线内容校准工具。它直接扫描当前项目中的 Godot 文本资源，
不读取经济 CSV，不启动 Godot，也不复制一套运行时状态。

工具包含两层：

- 浏览器工作台：零依赖查看产业链、目录实体和固定参数参考场景。
- 数学验证器：Node.js 复用同一 `.tres` 解析器编译模型，Python/SciPy 求解供需、建筑、
  阶层和本格自然资源的设计时稳态，并输出 JSON/HTML 报告。

## 使用

1. 用 Chrome 或 Edge 打开 `index.html`。
2. 选择包含 `Project/` 与 `tools/` 的仓库根目录。
3. 打开“数值预计算”，调整时代、建筑数量、利用率、商人承接率和岗位人口倍率。

浏览器只获得所选目录的读取权限。支持 File System Access API 的浏览器会记住目录句柄，并在下次
打开时重新扫描最新资源。

## 离线数学验证器

### 环境

- Node.js 18 或更新版本。
- Python 3.10 或更新版本。
- `numpy` 与 `scipy`，可用 `python -m pip install -r tools/supply-chain-explorer/requirements.txt` 安装。

### 运行

Windows 最简单的方式：在仓库根目录双击 `打开经济校验器.cmd`。它会直接执行并在完成后自动打开
`balance_report.html`。也可以把自己的场景 JSON 直接拖到这个 `.cmd` 文件上执行。

macOS 使用仓库根目录的 `打开经济校验器_mac.command`。首次使用如果提示没有执行权限，在 Terminal
中执行一次：

```bash
chmod +x ./打开经济校验器_mac.command
```

之后可以直接双击；也可以从 Terminal 执行且不需要修改权限：

```bash
bash ./打开经济校验器_mac.command
```

macOS 启动器优先使用 `python3`，完成后通过系统 `open` 命令打开同一份 HTML 报告。

如需查看命令输出或接入自动化，再从仓库根目录执行：

```powershell
& .\tools\supply-chain-explorer\run_balance_validator.ps1
```

命令行方式也可以自动打开报告：

```powershell
& .\tools\supply-chain-explorer\run_balance_validator.ps1 -OpenReport
```

指定自己的场景和输出目录：

```powershell
& .\tools\supply-chain-explorer\run_balance_validator.ps1 `
  -Scenario .\tmp\my_cell_scenario.json `
  -OutputDir .\tmp\my_balance_report
```

入口会执行以下只读流程：

1. `export_model.js` 扫描 `Project/project-keynes/data/**/*.tres`、时代表和资源面积倍率。
2. 编译 `compiled_model.json`，其中包含当前建筑、商品、资源、职业、需求和 EconomyProfile。
3. `balance_validator.py` 按场景求解建筑利用率参考点。
4. 输出 `balance_report.json` 与 `balance_report.html`。

报告为 `FAIL` 时命令返回非零退出码，便于接入提交前检查；报告仍会完整写出。

### 场景输入

复制 `scenario.stone_age.example.json` 后修改。重要字段：

```json
{
  "era": "stone",
  "default_building_count": 0,
  "building_counts": {
    "stone_age_hunting_camp": 3,
    "flint_quarry": 1
  },
  "solve_utilization": true,
  "target_utilization": 0.65,
  "sell_through": 0.8,
  "profession_populations": {
    "hunter": 8,
    "miner": 3
  },
  "resource_context": {
    "wild_game": {
      "reserve": 12065,
      "temperature": 0.52,
      "moisture": 0.55
    }
  },
  "projection_days": [365, 730, 3650]
}
```

- `default_building_count`：未单独列出的可用建筑数量；校验具体地块时建议设为 `0`。
- `building_counts`：本格建筑数量。
- `profession_populations`：可选；缺省时由建筑 owner/employee 岗位推导。
- `resource_context`：本格资源储量与温湿度。动物/林木等可从承载力推导参考储量；矿产无法从
  目录参数唯一推导具体格储量，未填写时会给出警告而不是伪造数值。
- `solve_utilization`：为 `true` 时使用有界非线性最小二乘寻找供需/资源压力较低的参考利用率；
  为 `false` 时严格使用输入的 `utilization`/`building_utilization`。
- `sell_through`：生产者产出被本格商人承接的比例；求解器不会为了平衡擅自缩小库存目标。

### 数学口径

- 商品：承接产出 = 建筑数量 × 利用率 × 日产出 × `sell_through`；需求包含生产投入与居民篮子。
- 建筑：收入使用当前价格与 `merchant_buy_price_factor_q16`，成本包含投入、员工工资和业主必要生活费。
- 阶层：收入来自员工工资和记录到建筑的业主可分配盈余；不增加预防性现金储备。
- 自然资源：逐日复刻当前 profile 的 IMEX 或 Beverton–Holt 公式，建筑采集和人工生成均只作用于本格。
- 市场稳定性：对目录参数构造的本格“库存—价格”二状态参考模型做局部线性化并报告谱半径。

这是一套设计时数学模型，不宣称逐周期复刻 `NativeEconomyRuntime`。固定点取整、冻结周期、EMA
历史、商人现金上限、实际就业、生产者自留和真实贸易拓扑仍属于运行时权威。报告会在
`method.limitations` 中保留这一边界。

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
node --check tools/supply-chain-explorer/export_model.js
node tools/supply-chain-explorer/parser.test.js
node tools/supply-chain-explorer/current_data.test.js
node tools/supply-chain-explorer/balance_report.js --summary
python tools/supply-chain-explorer/balance_validator_test.py
```

`parser.test.js` 覆盖居民替代品分摊、类目投入效率选择和建筑盈亏公式；
`current_data.test.js` 直接扫描当前游戏资源并验证全量预计算结果有限且可生成；
`balance_report.js` 按时代输出 80% 承接率下的亏损建筑与最高覆盖物资，便于提交前比较数值改动。
