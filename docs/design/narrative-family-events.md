# 家族事件第二批：设计稿

第一批（`family2`，10 条）已经能读家族快照、授/撤家族特质。第二批要解决的是**同质化**：不能再写“族里出钱/官府给不给”的同一种交易。本文先把家族运行时的可读可写面列清，再给 12 条新设计，其中 6 条现有桥就能写，6 条需要补一个最小的读条件。

- 桥接契约：[narrative-family-bridge.md](narrative-family-bridge.md)
- 现有内容：[narrative_event_catalog_family2.gd](../../Project/project-keynes/scripts/narrative/narrative_event_catalog_family2.gd)
- 运行时代码：`scripts/economy/economy_facade.gd`、`gdext/src/economy_runtime_queries_market_building.cpp`

---

## 0. 实施状态（2026-11-12）

- **A 层 6 条 + B 层 6 条均已落地**：`narrative_event_catalog_family3.gd`，已注册。
- **B 层前置已实现**：`HAS_FAMILY_TRAIT = 44`；采样器在家族快照之后多一次 `get_family_traits`，
  写 `primary_family_trait_keys` / `primary_family_trait_names`；只在 `include_cohort_details=true` 的路径读。
- **验证**：`narrative_event_web_test.gd` 14111 项 0 失败；`narrative_family_bridge_test.gd` 28 项 0 失败；
  runtime / waterworks / people / radius 四个既有测试全绿。
- **偏差**：① 十二条正文按 120–300 字扩写过一轮；② core 特质不能被 `remove` 撤掉——原生静默跳过，
  事件仍落经济效果，文案不要承诺“一定失去”；③ `family3.charter_guild` 的“给特许”改成 60/40 博弈，
  给包内补一个概率分支。

---

## 1. 第一批用掉了什么

| 杠杆 | 第一批用法 |
| --- | --- |
| `family_cell_snapshot` | 人口占比、威望档、拥有建筑数、名人数 |
| `FAMILY_*` 四条件 | 门槛：有族/威望/占比/建筑 |
| `GRANT/REMOVE_FAMILY_TRAIT` | 10 条各改一个身份/偏好特质 |
| `{family_name}` | 正文与标签 |

**没用到的读接口**：`get_family_traits`（这个族本来是什么）、`family_industries`（它拥有哪些产业）、`family_notable_people`（名人是谁）、`family_branches`（分支）。

这决定了第二批的方向：**从“官府与族做交易”转向“族本来是什么，因此这件事只能这样办”**。

## 2. 可读 / 可写清单（已核实）

**可读**

| 接口 | 返回 | 能支撑的事件 |
| --- | --- | --- |
| `family_cell_snapshot(cell,0,8)` | 句柄、族名、人口、现金、建筑数、名人数、威望档/分数 | 已有 |
| `get_family_traits(handle)` | `trait_keys`、`display_names`、`strength_q16`、`core` | **第二批核心**：按既有特质分支 |
| `family_industries(handle)` | 建筑句柄/格/类型/数量 | 第三批：族垄断某产业 |
| `family_notable_people(handle)` | 名人列表 | 第三批：具体的人 |
| `family_branches(handle)` | 分支 | 第三批：分家/内斗 |

**可写**

| 命令 | 语义 | 限制 |
| --- | --- | --- |
| `queue_family_trait_mutation` grant | 授特质；已存在则改强度 | core 特质跳过；前置/排斥强制 |
| 同上 remove | 撤特质 | 只删非 core |
| 同上 set_strength | 改强度 | 已存在才生效 |

**仍不可写**：家族现金、威望、名人、产业、分家、立族、殖民。第二批不碰这些。

## 3. 内容空间分三层

| 层 | 需要的接口 | 能写什么 | 本批 |
| --- | --- | --- | --- |
| A | 现有桥 | 族与官府的交易：认亲、祠堂、牌坊、包税、族丁、义庄 | 6 条 |
| B | + `HAS_FAMILY_TRAIT`（op 44）+ 采样器读 `get_family_traits` | 族本来是什么，决定事情怎么办：重农族抗圈地、商帮要特许、工匠族与行会决裂、书香门第被查、家大业大抗税、沿海资本转向 | 6 条 |
| C | 第二座桥（第二家族定位、产业、名人、现金/威望写入） | 家族内斗、名人传记、产业垄断、家族破产 | 暂不做 |

B 层只需加**一个条件算子 + 一次 traits 读取**，不新增效果种类，风险很小。

## 4. 第二批 12 条

### 4.1 A 层（6 条，现有桥即可）

| id | 标题 | 时代 | 门槛 | 三个选项与代价 | 特质变化 |
| --- | --- | --- | --- | --- | --- |
| `family3.wet_nurse` | 乳母 | 1–6 | 威望≥1、人口≥10 | 认这门亲（出生+3，宫廷风险×1.15）／赏钱打发（cash_out 1.0）／不认（动荡×1.2） | 认亲授 `j017_loyal`（老实） |
| `family3.ancestral_hall` | 祠堂 | 2–7 | 拥建筑≥1、威望≥2 | 准他扩（建设成本−3%，动荡×1.15）／缩一半（制造−2，cash_in 1.0）／不许（知识−2，动荡×1.25） | 准他授 `j020_gentry`（士绅门第） |
| `family3.scholar_board` | 牌坊 | 3–8 | 威望≥3、学者≥1% | 立牌坊（知识+3，cash_out 1.0）／折现（cash_in 1.5）／不立（知识−2，动荡×1.15） | 立牌坊授 `j009_letters`（书香门第） |
| `family3.tax_farm` | 包税 | 3–8 | 威望≥4、商人≥2% | 包给他（cash_in 2.0，动荡×1.3）／官收（cash_in 1.0，制造−2）／不包（动荡×1.1） | 包税授 `i019_trade`（商路人脉） |
| `family3.private_arm` | 族丁 | 3–8 | 威望≥4、拥建筑≥2 | 准他养（军粮−8%，动荡×1.3）／遣散（cash_out 1.5，授老实）／收编（军粮−8%，动荡×1.2） | 准他授 `j016_shrewd`（精明） |
| `family3.charity_estate` | 义庄 | 2–9 | 威望≥2、人口≥15 | 准他设（主食−4%，cash_out 1.0）／官府配一半（cash_out 2.0，主食−3%，知识+2）／不许（动荡×1.2，主食+3） | 准他授 `j017_loyal`（老实） |

### 4.2 B 层（6 条，需要 `HAS_FAMILY_TRAIT`）

| id | 标题 | 时代 | 门槛 | 三个选项与代价 | 特质变化 |
| --- | --- | --- | --- | --- | --- |
| `family3.enclosure_resist` | 重农族 | 6–8 | 有 `i001_agrarian`、威望≥2 | 强圈（农业+5，动荡×1.35）／换地（cash_out 2.0，农业+2）／作罢（制造−3，动荡×0.9） | 强圈撤 `i001_agrarian`；换地授 `i025_pioneer` |
| `family3.charter_guild` | 商帮要特许 | 4–7 | 有 `i019_trade`、商人≥3% | 给特许（贸易+6，cash_in 1.0）／公开招标（cash_in 2.0，动荡×1.15）／驳回（制造−3，动荡×1.1） | 给特许授 `i026_magnate` |
| `family3.craft_split` | 工匠族 | 4–8 | 有 `j004_craft`、工匠≥10% | 支持族（制造+4，工具+5）／支持行会（制造−4，动荡×0.9）／调停（cash_out 1.5，动荡×1.1） | 支持族授 `i003_manufacturing`；支持行会撤 `j004_craft` |
| `family3.letters_raid` | 查书 | 3–8 | 有 `j009_letters`、学者≥1% | 保他（知识+5，动荡×1.3）／交书（知识−4，动荡×0.9）／烧一半（知识−2，cash_out 1.0） | 保他授 `i005_knowledge`；交书撤 `j009_letters` |
| `family3.magnate_tax` | 抗税 | 5–9 | 有 `i026_magnate`、威望≥4 | 加税（cash_in 2.5，动荡×1.35）／谈判（cash_in 1.0，贸易+3）／免（制造+2，动荡×1.2） | 谈判授 `i019_trade` |
| `family3.coastal_shift` | 转产 | 6–9 | 有 `i029_coastal`、沿海 | 支持转（制造+5，cash_out 2.0）／维持船队（贸易+4，制造−2）／两头下注（cash_out 2.0，动荡×1.1） | 支持转授 `i003_manufacturing` |

**设计约束**（每条都遵守）：

1. 一条只改一个特质，不同时授两个；
2. 三个选项的代价货币必须不同（现金 / 产出 / 人口 / 风险）；
3. 门槛至少一个家族维度 + 一个非家族维度（建筑/职业/价格/地理），避免“只有家族数据在说话”；
4. 撤特质只用于“这件事让这个族不再是原来的族”，不做惩罚性撤销；
5. 文案写“在这一带”，不写“天下”；不写“该族出钱/得钱”。

## 5. 需要的最小扩展（只为 B 层）

| 项 | 内容 | 成本 |
| --- | --- | --- |
| 条件 | `HAS_FAMILY_TRAIT = 44`：`target_key` = trait key，`bool_value` = 期望值；无族/无该特质 → false | 一个枚举分支 |
| 采样 | `_sample_primary_family` 里多一次 `get_family_traits(handle)`，写 `primary_family_trait_keys`、`primary_family_trait_names` | 每格多一次 committed read |
| 适配器 | 不改 | — |
| 测试 | 新条件真/假、无族、trait 目录为空；trait key 存在性 | ~8 项 |

`get_family_traits` 返回 `trait_keys`（稳定 id）与 `display_names`（中文），两者都缓存进 ctx；条件只匹配稳定 id，文案可选用中文名。

## 6. 验收

- `narrative_event_web_test.gd`：130 → 142 条，约 14000 项，0 失败；
- `narrative_family_bridge_test.gd`：新增 trait 条件行为断言；
- 覆盖率：`family` 相关 tag ≥ 22 条；e2–e8 每代家族事件 ≥ 4 条；
- 抽样检查：每条事件至少一个选项会让某一族“变得不一样”（授或撤），且文案能看出是哪一族。

## 7. 非目标

- 不改家族内部算法；
- 不做第二家族定位、产业、名人、家族现金/威望写入（C 层）；
- 不做家族殖民/立族事件；
- 不新增 story flag。

## 8. 落地顺序

1. A 层 6 条（不动运行时，先写内容）；
2. B 层前置：op 44 + traits 采样 + 测试；
3. B 层 6 条；
4. 更新 web/coverage/family-bridge 三份文档。

> 已按 A+B 一起落地（见 §0）：A 层 6 条不改运行时，B 层补了 `HAS_FAMILY_TRAIT` 与一次 traits 读取。
