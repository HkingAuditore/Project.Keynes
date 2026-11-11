# 军事维修配方与固定点需求折算表（内容契约）

> 归属角色：内容/目录（`data/military/military_catalog.json` +
> `scripts/military/military_catalog_compiler.gd`）。
> 上游方案：`docs/plans/military-physical-maintenance.md`（S2-1 / S2-2 / S2-3）。
> 本文冻结**内容侧**的数值与单位；原生侧只读编译产物，不得二次折算。

## 0. 速览

| 项 | 值 |
| --- | --- |
| 带配方的建筑 | 17 / 17（`state_buildings` 全部） |
| 带配方的兵种 | 23 / 24（`militia` 为空配方，零维护） |
| 配方总条目 | 98 条 `(good, rate_q32)`（建筑 43 + 兵种 55） |
| 每条配方材料数 | 2–3（硬上限 4，等于原生 `repair_materials` 槽位） |
| `rate_q32` 取值范围 | 42 949 672 960 … 14 641 933 963 636（int64 余量 ≈ 63 万倍） |
| 目录字段 | 行内 `repair`（作者写入）→ 编译后 `repair_goods` / `repair_rate_q32` |

## 1. 口径（先读这一节，否则数值差 10^7）

| 量 | 单位 | 出处 |
| --- | --- | --- |
| `default_price` | **货币分** / 1.0 商品（`MONEY_SCALE = 10000` 分 = 1 货币） | `scripts/data/good_profile.gd:44` |
| 建筑 `upkeep` | 货币 / 日（如 `0.15` = 1500 分/日） | `military_catalog.json` |
| 兵种 `supply_idle.upkeep` | **商品单位** / 100 人 / 日（不是货币） | `military_catalog.json` |
| `rate_q32` | q32 的**每日千分之一商品**（milli-good/day）；`2^32` = 1 milli-good/日 = 0.001 商品/日 | 本文 §5 |
| 原生商品定点 | `GOODS_SCALE = 1000`（1.0 商品 = 1000 内部单位 = 1000 milli-good） | `economy` 目录 |

`rate_q32` 与 `GOODS_SCALE` 天然对齐：`acc_q32 >> 32` 直接得到原生商品内部单位，
不需要再乘 1000。

## 2. 两条公式

作者只写**整数权重**（不要求和为 1，编译器按 `sum_weights` 归一化），
编译器一次性折算成 `rate_q32`。

### 2.1 建筑（闲置 upkeep，按日）

```
daily_goods_g = upkeep × (weight_g / Σweight) × 10000 / default_price_g
rate_q32[g]   = round(daily_goods_g × 1000 × 2^32)      # ≥ 0
```

算例：`garrison_barracks`（`upkeep = 0.15`，权重 `bricks:2, lumber:2, wrought_iron:1`，Σ = 5）

- `bricks`：`0.15 × 2/5 × 10000 / 22000 = 0.02727272727` 商品/日；
  `× 1000 × 4294967296 = 117135471709.09` → **`117135471709`**
- `lumber`：`0.15 × 2/5 × 10000 / 18000 = 0.03333333333`；
  `× 1000 × 2^32 = 143165576533.33` → **`143165576533`**
- `wrought_iron`：`0.15 × 1/5 × 10000 / 28000 = 0.01071428571`；
  `× 1000 × 2^32 = 46017506742.86` → **`46017506743`**

反向验算（用 `default_price` 折回货币）：
`0.0272727×2.20 + 0.0333333×1.80 + 0.0107143×2.80 = 0.06 + 0.06 + 0.03 = 0.15` 货币/日，
恰好等于作者写的 `upkeep`。**这条恒等式是建筑配方的唯一正确性判据。**

### 2.2 兵种（闲置强度，每百人按日）

```
daily_goods_g = idle_upkeep × (weight_g / Σweight)     # 已经是商品单位，不再除价格
rate_q32[g]   = round(daily_goods_g × 1000 × 2^32)      # ≥ 0
```

算例：`bronze_spearmen`（`supply_idle.upkeep = 0.05`，权重 `bronze_tools:1, lumber:1`，Σ = 2）

- `bronze_tools`：`0.05 × 1/2 = 0.025` 商品/百人/日；
  `× 1000 × 2^32 = 107374182400` → **`107374182400`**
- `lumber`：同上 → **`107374182400`**

价格不参与兵种折算（强度本身就是实物），但编译器仍会**校验价格存在且 > 0**：
一个没有价格的商品在整个经济里也无法被维护采购定价，属于内容错误。

## 3. 建筑全表

| 建筑 id | 名称 | 闲置 upkeep（货币/日） | 材料 | 权重 | 日耗（商品单位/日） | rate_q32 |
| --- | --- | --- | --- | --- | --- | --- |
| `warrior_lodge` | 战士营地 | 0.02 | `logs`, `turf_block` | 1, 1 | 0.01, 0.02 | 42949672960, 85899345920 |
| `palisade_barracks` | 木栅兵营 | 0.05 | `lumber`, `adobe_brick` | 1, 1 | 0.01388889, 0.04166667 | 59652323556, 178956970667 |
| `garrison_barracks` | 戍卫营 | 0.15 | `bricks`, `lumber`, `wrought_iron` | 2, 2, 1 | 0.02727273, 0.03333333, 0.01071429 | 117135471709, 143165576533, 46017506743 |
| `legion_fort` | 军团营寨 | 0.4 | `bricks`, `raw_stone` | 1, 1 | 0.09090909, 0.2 | 390451572364, 858993459200 |
| `drill_depot` | 操练营 | 1 | `bricks`, `glass`, `tools` | 2, 1, 1 | 0.22727273, 0.11363636, 0.04807692 | 976128930909, 488064465455, 206488812308 |
| `army_depot` | 兵站 | 2.5 | `steel`, `cement`, `tools` | 2, 2, 1 | 0.27777778, 0.45454545, 0.09615385 | 1193046471111, 1952257861818, 412977624615 |
| `military_base` | 军事基地 | 6 | `concrete`, `steel`, `electrical_equipment` | 2, 2, 1 | 1.09090909, 0.66666667, 0.23076923 | 4685418868364, 2863311530667, 991146299077 |
| `training_complex` | 联合训练中心 | 15 | `concrete`, `computers`, `telecom_equipment` | 2, 1, 1 | 3.40909091, 0.72115385, 0.72115385 | 14641933963636, 3097332184615, 3097332184615 |
| `earthen_rampart` | 夯土城垣 | 0.05 | `logs`, `turf_block` | 1, 1 | 0.025, 0.05 | 107374182400, 214748364800 |
| `stone_walls` | 石砌城墙 | 0.15 | `raw_stone`, `bricks` | 2, 1 | 0.1, 0.02272727 | 429496729600, 97612893091 |
| `citadel` | 城堡要塞 | 0.3 | `raw_stone`, `bricks` | 2, 1 | 0.2, 0.04545455 | 858993459200, 195225786182 |
| `star_fort` | 棱堡 | 0.5 | `bricks`, `raw_stone`, `tools` | 2, 2, 1 | 0.09090909, 0.2, 0.01923077 | 390451572364, 858993459200, 82595524923 |
| `bunker_line` | 碉堡防线 | 1 | `concrete`, `steel`, `tools` | 2, 2, 1 | 0.18181818, 0.11111111, 0.03846154 | 780903144727, 477218588444, 165191049846 |
| `hardened_defense_network` | 加固防御网 | 3 | `concrete`, `military_electronics`, `electrical_equipment` | 2, 1, 1 | 0.68181818, 0.04464286, 0.14423077 | 2928386792727, 191739611429, 619466436923 |
| `martial_academy` | 武学馆 | 0.2 | `bricks`, `lumber` | 1, 1 | 0.04545455, 0.05555556 | 195225786182, 238609294222 |
| `military_academy` | 军事学院 | 0.5 | `bricks`, `glass`, `tools` | 2, 1, 1 | 0.11363636, 0.05681818, 0.02403846 | 488064465455, 244032232727, 103244406154 |
| `war_simulation_center` | 兵棋推演中心 | 8 | `concrete`, `computers` | 1, 1 | 1.81818182, 0.76923077 | 7809031447273, 3303820996923 |

> 四列（材料 / 权重 / 日耗 / rate_q32）**按位置一一对应**，顺序即
> `repair_goods` / `repair_rate_q32` 的作者顺序。`state_buildings` 的稠密索引 =
> JSON 作者顺序，本表行序与之相同（不是字典序）。

## 4. 兵种全表（按 `id` 稳定排序）

| 兵种 id | 名称 | 闲置强度（商品/百人/日） | 材料 | 权重 | 日耗（商品/百人/日） | rate_q32 |
| --- | --- | --- | --- | --- | --- | --- |
| `bronze_spearmen` | 青铜矛兵 | 0.05 | `bronze_tools`, `lumber` | 1, 1 | 0.025, 0.025 | 107374182400, 107374182400 |
| `cavalry` | 骑兵 | 0.05 | `bronze_tools`, `lumber`, `leather` | 2, 1, 1 | 0.025, 0.0125, 0.0125 | 107374182400, 53687091200, 53687091200 |
| `chariot_troops` | 战车兵 | 0.05 | `bronze_tools`, `lumber`, `leather` | 2, 1, 1 | 0.025, 0.0125, 0.0125 | 107374182400, 53687091200, 53687091200 |
| `combined_arms` | 合成部队 | 0.05 | `precision_tools`, `steel`, `military_electronics` | 2, 2, 1 | 0.02, 0.02, 0.01 | 85899345920, 85899345920, 42949672960 |
| `dragoons` | 龙骑兵 | 0.03 | `tools`, `leather` | 1, 1 | 0.015, 0.015 | 64424509440, 64424509440 |
| `drone_swarm` | 无人作战集群 | 0.05 | `precision_tools`, `military_electronics`, `electrical_equipment` | 2, 1, 2 | 0.02, 0.01, 0.02 | 85899345920, 42949672960, 85899345920 |
| `early_armor` | 早期装甲 | 0.05 | `tools`, `steel` | 1, 1 | 0.025, 0.025 | 107374182400, 107374182400 |
| `exo_infantry` | 外骨骼步兵 | 0.05 | `precision_tools`, `military_electronics`, `electrical_equipment` | 2, 1, 2 | 0.02, 0.01, 0.02 | 85899345920, 42949672960, 85899345920 |
| `field_artillery` | 野战炮兵 | 0.05 | `tools`, `wrought_iron` | 1, 1 | 0.025, 0.025 | 107374182400, 107374182400 |
| `heavy_artillery` | 重炮兵 | 0.05 | `tools`, `wrought_iron` | 1, 1 | 0.025, 0.025 | 107374182400, 107374182400 |
| `heavy_cavalry` | 甲骑具装 | 0.05 | `tools`, `leather` | 1, 1 | 0.025, 0.025 | 107374182400, 107374182400 |
| `iron_infantry` | 铁甲步兵 | 0.05 | `tools`, `wrought_iron` | 1, 1 | 0.025, 0.025 | 107374182400, 107374182400 |
| `legionaries` | 军团步兵 | 0.05 | `tools`, `wrought_iron` | 1, 1 | 0.025, 0.025 | 107374182400, 107374182400 |
| `line_infantry` | 线列步兵 | 0.03 | `tools`, `wrought_iron` | 1, 1 | 0.015, 0.015 | 64424509440, 64424509440 |
| `machine_gunners` | 机枪步兵 | 0.03 | `tools`, `wrought_iron` | 1, 1 | 0.015, 0.015 | 64424509440, 64424509440 |
| `mechanized_infantry` | 机械化步兵 | 0.05 | `precision_tools`, `steel`, `electrical_equipment` | 2, 2, 1 | 0.02, 0.02, 0.01 | 85899345920, 85899345920, 42949672960 |
| `militia` | 民兵 | 0 | （空配方） | — | 0 | 0（空列） |
| `missile_artillery` | 导弹炮兵 | 0.05 | `precision_tools`, `steel`, `military_electronics` | 2, 2, 1 | 0.02, 0.02, 0.01 | 85899345920, 85899345920, 42949672960 |
| `musketeers` | 火枪兵 | 0.03 | `tools`, `wrought_iron` | 1, 1 | 0.015, 0.015 | 64424509440, 64424509440 |
| `riflemen` | 步枪兵 | 0.03 | `tools`, `wrought_iron` | 1, 1 | 0.015, 0.015 | 64424509440, 64424509440 |
| `siege_train` | 攻城营 | 0.05 | `tools`, `lumber` | 1, 1 | 0.025, 0.025 | 107374182400, 107374182400 |
| `sp_artillery` | 自行火炮 | 0.05 | `precision_tools`, `steel`, `electrical_equipment` | 2, 2, 1 | 0.02, 0.02, 0.01 | 85899345920, 85899345920, 42949672960 |
| `tank_corps` | 坦克部队 | 0.05 | `precision_tools`, `steel`, `electrical_equipment` | 2, 2, 1 | 0.02, 0.02, 0.01 | 85899345920, 85899345920, 42949672960 |
| `tribal_warriors` | 部落战士 | 0.05 | `chipped_stone_tools`, `logs` | 1, 1 | 0.025, 0.025 | 107374182400, 107374182400 |

`militia` 的 `supply_idle.upkeep == 0`，编译结果为**空** `repair_goods` /
`repair_rate_q32`（零维护），不是“零速率行”。同理，任何强度为 0 的行都编译成空列。

## 5. 精度契约（原生侧必须按此实现）

1. `rate_q32` 是 **q32 的“每日千分之一商品”**：`2^32` 对应 1 milli-good/日
   = 0.001 商品/日 = 1 个原生商品内部单位/日（`GOODS_SCALE = 1000`）。
2. 累积方式固定为：

   ```
   acc_q32 += rate_q32[g] * units;          // units = 座数；兵种行按人头/100 口径
   need_milli = acc_q32 >> 32;              // 毫商品
   acc_q32 -= need_milli << 32;             // 余量保留，不丢
   ```

3. `>> 32` 的结果可以直接当商品内部单位用，**不要再乘 1000**；也不要再乘一次 2^32。
4. 余量必须持久化（进 PKMI 与新 save section）。若每行每天直接向下取整，
   最多丢 1 milli-good/日，100 天累计可达 100 milli-goods（0.1 商品），
   小规模长局会明显少消耗。方案见 `military-physical-maintenance.md` D2/D3。
5. 允许 `rate_q32 == 0`（正权重但不足一个 milli-good/日）：原生按余量累积，
   不需要“每天至少一件”的兜底。**当前 98 条发布数据没有一条是 0**。
6. 兵种行强度分母是 100 人：内容只冻结“每百人每日”速率，按人头换算（`units/100`
   或等价口径）由原生累积器负责，不能在内容侧再除一次。
7. `rate_q32` 最大值 14 641 933 963 636（约 2^43.7），`rate_q32 × units` 在
   int64 内可支持 63 万倍座数/人头，正常规模无溢出风险。

## 6. 禁止事项（违反即口径分叉）

- **禁止**运行期用现金 `upkeep` 反推消耗：`upkeep` 仍留在行里只是给现金遗留路径用，
  它与 `rate_q32` 的关系只在编译期成立一次。
- **禁止**用建造材料（`materials` / `material_goods` / `material_qty`）反推维修配方。
  两者只是“碰巧同源”（如 `legion_fort` 都是砖石），比例、数量级、用途都不同。
- **禁止**把维护材料追加进 `supply.upkeep`：该候选表已 12 条 = 编译上限
  （`SUPPLY_CLASS_COUNT * 2`），且维护材料不得参与口粮/弹药/燃料补给循环。
- **禁止**在 Economy 官营建筑 `.tres` 里写 `maintenance_*`：`economy_catalog.gd:1641`
  对 `kind == "state"` 硬拒绝，会直接编译失败。
- **禁止**运行期重算或“动态调整”速率：`rate_q32` 是**冻结内容**。改动即内容变更 →
  `catalog_hash` 变更 → 旧 PKMI 存档被明确拒绝（这是预期行为，不是 bug）。

## 7. 编译期校验（`_compile_repair`，失败即整目录编译失败）

| 错误码 | 触发条件 |
| --- | --- |
| `military_repair_not_object` | `repair` 不是对象 |
| `military_repair_goods_not_array` | `repair.goods` 不是数组 |
| `military_repair_overflow: <id> (<n>)` | 材料数 > 4（原生槽位上限） |
| `military_repair_good_unknown: <id>:<good>` | 商品 id 不在经济目录 |
| `military_repair_good_duplicate: <id>:<good>` | 同一配方重复商品 |
| `military_repair_weight_invalid: <id>:<good> (<w>)` | 权重 ≤ 0（或非数值） |
| `military_repair_price_missing: <id>:<good>` | `default_price` 列缺失、越界或 ≤ 0 |

`repair` 键缺失 / `{}` / `null` 均视为“无配方”，编译成空列（向后兼容旧目录）。

## 8. 与既有方案文档的口径差异（需原生侧对齐）

| 位置 | 方案原写法 | 实际发布口径（本文为准） |
| --- | --- | --- |
| `military-physical-maintenance.md` S2-1 | “15 类建筑 + 13 类兵种” | 实际目录是 **17 建筑 + 24 兵种**（23 个非空配方）；配方表已全覆盖，无遗漏行 |
| 同文件 D3 建筑公式 | `round(upkeep × weight / base_price × 2^32)` | 把 `default_price` 当成货币单位（实为**货币分**，差 10^4），且 `>>32` 得到的是“商品”而不是本表的“毫商品”（再差 10^3）。若原生仍按原式实现累积却读本表速率 → **多消耗 1000 倍**；若按原式重算速率 → **少算 10^7 倍**。以本文 §2.1 / §5 为准 |
| 同文件 S2-2 | “权重和 = 1（兵种）” | 作者写整数权重，编译器按 `Σweight` 归一化，**不要求和为 1** |
| 同文件 S2-2 | “`rate_q32 > 0`” | 正权重允许舍入到 0（当前数据无此情形）；强度为 0 则整行空列 |

## 9. 复算方式

下面的 Python 片段可从 JSON 直接复算本表（`price` 取 §10 的 20 个值）：

```python
import json
from fractions import Fraction
cat = json.load(open("Project/project-keynes/data/military/military_catalog.json",
                     encoding="utf-8"))
Q32 = 4294967296
price = {...}   # 见 §10 表
for row in cat["state_buildings"] + cat["units"]:
    goods = row["repair"]["goods"]
    total = sum(g["weight"] for g in goods)
    intensity = (row["upkeep"] if "upkeep" in row
                 else row["supply_idle"]["upkeep"])
    building = "upkeep" in row
    for g in goods:
        d = Fraction(intensity) * Fraction(g["weight"], total)
        if building:
            d *= Fraction(10000, price[g["good"]])
        print(row["id"], g["good"], round(d * 1000 * Q32))
```

用 `Fraction` 复算与编译器浮点结果**逐条一致**（已核对 98/98）；
所有商的分母都不落在 `.5` 舍入边界上（最近距离 0.045），
因此 `round()` 的浮点/精确两种实现不会产生分歧。

## 10. 附录：本表用到的 20 个商品与生效 `default_price`

| 商品 id | `default_price`（货币分/1.0 商品） | 货币/1.0 商品 | 来源 |
| --- | --- | --- | --- |
| `adobe_brick` | 6000 | 0.60 | `.tres` 序列化值 |
| `bricks` | 22000 | 2.20 | `.tres` 序列化值 |
| `bronze_tools` | 26000 | 2.60 | `.tres` 序列化值 |
| `cement` | 22000 | 2.20 | `.tres` 序列化值 |
| `chipped_stone_tools` | 75000 | 7.50 | `.tres` 序列化值 |
| `computers` | 52000 | 5.20 | `.tres` 序列化值 |
| `concrete` | 22000 | 2.20 | `.tres` 序列化值 |
| `electrical_equipment` | 52000 | 5.20 | `.tres` 序列化值 |
| `glass` | 22000 | 2.20 | `.tres` 序列化值 |
| `leather` | 24000 | 2.40 | `.tres` 序列化值 |
| `logs` | 10000 | 1.00 | `.tres` **未序列化**，取 `good_profile.gd` 默认值 |
| `lumber` | 18000 | 1.80 | `.tres` 序列化值 |
| `military_electronics` | 168000 | 16.80 | `.tres` 序列化值 |
| `precision_tools` | 52000 | 5.20 | `.tres` 序列化值 |
| `raw_stone` | 10000 | 1.00 | `.tres` **未序列化**，取 `good_profile.gd` 默认值 |
| `steel` | 36000 | 3.60 | `.tres` 序列化值 |
| `telecom_equipment` | 52000 | 5.20 | `.tres` 序列化值 |
| `tools` | 52000 | 5.20 | `.tres` 序列化值 |
| `turf_block` | 5000 | 0.50 | `.tres` 序列化值 |
| `wrought_iron` | 28000 | 2.80 | `.tres` 序列化值 |

**风险提示（原生侧须知）**：`default_price` 是本表唯一的外部输入。本表用到的
20 个商品里，`logs` / `raw_stone` 的 `.tres` **没有序列化**该字段，生效值来自
`scripts/data/good_profile.gd:44` 的 `@export var default_price: int = 10000`
（全目录 167 个商品中共 36 个同样省略，均为 `10000`）。**没有任何商品的价格
为 0 或缺失**，因此 98 条速率全部可解析；编译期仍会对缺失/≤0 的价格硬失败。
一旦有人改脚本默认值，这些（以及所有引用它们的目录行）的维修速率会**静默**
按反比例偏移，`.tres` 里看不到任何痕迹。建议后续给 `logs` / `raw_stone`
显式写入 `default_price = 10000`（本次不改商品资产，仅记录）。
