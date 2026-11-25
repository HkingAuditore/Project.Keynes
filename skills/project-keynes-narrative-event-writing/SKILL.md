---
name: project-keynes-narrative-event-writing
description: Write player-facing Project.Keynes narrative event content — literary scene prose, 2-3 choice options, probabilistic outcomes, verified effects, and card labels. Use when the user asks to 写事件/写事件内容/事件文案/事件选项/效果设计/事件链, mentions 开渠、饥民、渠田、工匠、灾年、物价、工程, wants a new NarrativeEventCatalog entry, or asks to make an existing event more literary or mechanically grounded. This skill is the content-authoring companion to project-keynes-narrative-events (which covers the runtime/API); load that one for code changes.
---

# Project.Keynes 事件写作 Skill

写的是**玩家读到的事件**：一段场景、几个选项、每条选项的后果。不是系统文档，也不是数值表。

先读：

- `docs/design/narrative-event-authoring.md`：效果语义、接口有效性、校准表。
- `project-keynes-narrative-events` skill：事件系统 API、测试、UI。
- 现有内容：`scripts/narrative/narrative_event_catalog.gd`、
  `narrative_event_catalog_waterworks.gd`、`narrative_event_catalog_people.gd`。

---

## 1. 写作流程（六步）

1. **选一个具体的人**：名字、职业、一个身体动作、一个随身物件。
   例：管水的周德顺，靴子上的泥干成壳；粮行赵掌柜，铜戒指转来转去。
2. **选一个必须决断的时刻**：谁要什么，谁反对，拖下去会怎样。
3. **给 2–3 个选项**：每个选项的受益者和代价都不同；不要「好/坏/更坏」三连。
4. **先定效果，再写结果文本**：结果必须能解释效果，不能各说各话。
5. **每条效果手写 `custom_label`**：对象 + 幅度 + 时长；数字必须是引擎真会算出的。
6. **跑测试**：形状、标签、数值契约、弹窗截图。

---

## 2. 文风：白话、具体、有画面

### 要

- 短句。具体名词。动作。一个能看见的细节。
- 让细节承担判断：名册念错名字没人纠正；灰浆不够掺黄泥；井绳一年比一年长。
- 人物有自己的小算盘：赵掌柜关心磨坊，韩老四关心自家田，周德顺关心渠能不能过水。
- 结尾落在一个画面或动作上：把钱揣回怀里、把斗笠往头上一扣、把铁锹插在土里没带走。
- 同一个物件反复出现，承担变化：靴子、图、斗笠、驴、井绳、铜戒指。

### 不要

- 不要文言腔、四字成语堆叠、「之乎者也」。
- 不要「某某说：『……』」的引语块；`speaker` / `quote_text` 留空。
  要说话就揉进叙述：「他说，去凿吧。」
- 不要总结陈词：「这是一项仁政」「百姓欢欣鼓舞」。
- 不要数据读数：气温、价格、库存、人口、百分比、日期都不进正文。
  叙述数量可以：三人、三成、两亩、半袋种粮。
- 不要现代词、网络梗、翻译腔。

### 一段合格的开头

> 周德顺从上游回来，靴子上的泥已经干成壳。他蹲在门槛上刮泥，刮了两下，从怀里掏出一张图。
> 图是炭画的，角上被汗浸得发软。他说旧渠淤了大半，石堰塌了一角；现在修，还能赶在春耕前。
> 韩老四抱着胳膊站在旁边，看了一眼图，没说话。

合格的原因：有名字、有动作、有物件、有分歧，没有一句总结。

---

## 3. 选项设计

- **2–3 个选项**。常规选项确定性结果（`probability_q16 = 65536`）；
  只有「赌一把」的选项才给 2 个概率分支，概率和必须 65536。
- 每个选项至少让一方**真的受益**、一方**真的付代价**；不要给「全赢」选项。
- 一个选项最多 4 行效果（含标记/排程可到 5 行）。写不下就把次要效果留到下一幕。
- 结果文本 1–3 句，写「谁怎么了」，不要复述效果数字。

---

## 4. 真实可用的效果（2026-11 审计后）

### 4.1 本地产出 / 成本（ADD 1.0，`magnitude_q16 = _pct(N)` 就是 ±N%）

| 想写 | target_key |
| --- | --- |
| 农业（所有作物，不单列小麦） | `economy.city.building.agriculture_output_factor` / `.cut` |
| 制造、采掘、能源、知识 | `economy.city.building.<sector>_output_factor` / `.cut` |
| 某一具体商品 | `economy.city.good.<good_id>.output_factor` / `.cut` |
| 主食开销 | `economy.city.need.staple_food.consumption_factor`（涨价）/ `.cut`（省钱） |
| 工具开销 | `economy.city.need.work_equipment.consumption_factor` / `.cut` |
| 出生率 | `economy.city.birth_factor` / `.cut` |

### 4.2 全国

| 想写 | target_key | 幅度 |
| --- | --- | --- |
| 全国某部门产出 | `ideology.country.output.<sector>_factor.gain` | `_pct(N)` = +N% |
| 全国建筑产出 | `country.economic_mobilization` | 0.5 = +5%（基准 +10%） |
| 全国建设成本 | `ideology.country.construction.cost_factor.cut` | 0.05 = −5%（投资激励） |
| 全国军队补给消耗 | `narrative.military.supply_cut` | 1.0 = −10%（后勤结算真读） |

### 4.3 钱、粮、人

- `TREASURY_CASH_TO_COHORT`：国库 → **人数最多的那一群**。标签用
  `国库拨付本地人数最多的{primary_profession}，占国库现金 X%`。
- `COHORT_CASH_TO_TREASURY`：同一群 → 国库。标签用
  `向本地人数最多的{primary_profession}征收其现金的 X%`。
- `MARKET_ADD_STOCK`：本地市场增补库存。**该格必须有商人**，否则原生整批拒绝；
  数量按原始单位，每人每日主食约 440（0.44 单位）。写 300 单位 ≈ 40 人 17 天。
- `MARKET_GOOD_TO_COUNTRY`：市场 → 国库，受实存截断；入库后没有玩家用途，别当奖励。
- `COUNTRY_GOOD_TO_MARKET`：需要国库真有货；玩家不能收购物资，正常游戏基本空转。不要用。

### 4.4 范围

`CITY_MODIFIER` 支持：

- `radius_cells`：0 / 1 / 2，当前格 + 1 环或 2 环；
- `falloff`：0 均等；1 逐环 100% / 60% / 30%；
- 只作用己方领土内的陆地，水面与外国格跳过。

标签写「本地及周边 N 环……」；不要写「N 格」。

### 4.5 标记与排程

- `SET_STORY_FLAG` / `CLEAR_STORY_FLAG`：真实持久化，但**只有被门槛读取才算机制**。
  纯档案标记不要写进卡面承诺。
- `SCHEDULE_FOLLOWUP_EVENT`：定时入队，不复核条件/标记；分支必须排不同的 `event_id`。

---

## 5. 绝对不能写

| 不要写 | 原因 | 替代 |
| --- | --- | --- |
| 直接改价格 / 平抑粮价 | 没有价格效果；价格由市场结算 | 只写供需动作（投放/征调） |
| 减税 / 抵扣赋税 | 没有减税效果 | 国库 → 人群现金；或建设成本 |
| 把粮直接发给饥民 | 没有物资→人群效果 | `MARKET_ADD_STOCK` + 商人条件 |
| 「最穷的一群人」 | 没有可读收款对象 | 人数最多的职业（标签写清） |
| 单列小麦 +X% | 作物不止一种 | 农业部门整体 +X% |
| 写死「6 单位」 | 实存可能只有 0.6 | 比例，或写「至多」 |
| `family.city.*` | 弱化 2–8 倍；trade 键零读取 | `economy.city.building.*` + `_pct` |
| 全国经济 +X% | 实际是全国建筑产出 | 「全国建筑产出 +X%」 |
| 家族投资/就业意愿 | 家族系统有效，但叙事事件没有桥 | 建设成本；不要假写 |

---

## 6. 标签写法

```
"custom_label": "本地及周边 2 环农业 +8%（逐环递减），360 日"
"custom_label": "全国军队补给消耗 -10%，730 日"
"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 2.5%"
"custom_label": "向本地人数最多的{primary_profession}征收其现金的 1.5%"
```

- 幅度带正负号；时长写「N 日」。
- 范围写「本地及周边 N 环」，不要写「N 格」。
- 全国产出写「全国建筑产出」，不要写「全国经济」。

---

## 7. 自检清单

- [ ] 正文有没有一个具体的人、一个具体物件、一个动作？
- [ ] 有没有引语块、文言腔、总结句？
- [ ] 每个选项是否 2–4 行效果，受益者/代价是否不同？
- [ ] 每条效果是否真实可跑（对照第 4 节）？
- [ ] 标签数字是否与 `magnitude_q16` 对得上？
- [ ] 范围效果是否只写己方陆地？标签是否写「N 环」？
- [ ] 结果文本能否解释效果，而不是各说各话？
- [ ] 契约测试是否 0 失败？

测试：

```powershell
& "<GODOT_BIN>" `
  --headless --path Project/project-keynes `
  --script tests/game/narrative_event_waterworks_chain_test.gd
```

同目录还有 `narrative_event_people_test.gd`、`narrative_effect_radius_test.gd`、
`narrative_event_runtime_test.gd`；弹窗改动再跑 `tests/qa/narrative_ui_screenshot_qa.gd`。

---

## 8. 最小模板

```gdscript
catalog.register_event(NarrativeEventDefinitionScript.from_dict({
	"event_id": "evt.example.somewhere",
	"title": "{settlement_name}·短标题",
	"body_text": "一个具体的人在做一件具体的事。一个物件。一个分歧。一句不总结的结尾。",
	"image_key": "hydrology.water",
	"tags": ["economy", "local"],
	"trigger_channel": Ch.PULSE_SAMPLED,
	"base_weight": 100,
	"cooldown_days": 240,
	"conditions": [
		{"op": Op.POPULATION_GTE, "int_value": 8},
	],
	"options": [
		{
			"option_id": "do_the_thing",
			"text": "动词 + 对象（4–16 字）",
			"outcomes": [{
				"probability_q16": 65536,
				"outcome_title": "结果标题",
				"outcome_narrative": "谁怎么了。一句画面。",
				"effects": [{
					"kind": Kind.CITY_MODIFIER,
					"target_key": "economy.city.building.agriculture_output_factor",
					"magnitude_q16": _pct(6),
					"duration_days": 360,
					"radius_cells": 2,
					"falloff": 1,
					"custom_label": "本地及周边 2 环农业 +6%（逐环递减），360 日",
				}],
			}],
		},
	],
}))
```
