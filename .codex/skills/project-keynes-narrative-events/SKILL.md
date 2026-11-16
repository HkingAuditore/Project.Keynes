---
name: project-keynes-narrative-events
description: Design, author, extend, review, or debug the Project.Keynes player-perspective Narrative Event System (事件叙事系统), including NarrativeEventDefinition/Option/Outcome/EffectSpec/Condition/WeightRule authoring, multi-dimensional context sampling (climate, temperature, ocean currents/upwelling, geography, market shortages/prices, buildings, population satisfaction, technology), event chains and dynamic probability weight biases, Chronicle history & PKSV pknr persistence, async AI API generation (LLM + era-styled image generation), and hand-drawn/papercut/torn-paper archival UI. Use whenever the user mentions 事件叙事, 叙事事件, 随机事件, 事件链, 事件选项, 编年史, AI生成事件, NarrativeEventService, NarrativeEventCatalog, NarrativeEventDialog, NarrativeChroniclePanel, or pknr.
---

# Project.Keynes Narrative Event System Skill

Use this skill whenever designing, authoring, extending, or debugging player-facing narrative events, event chains, probabilistic option outcomes, AI-generated events, or the narrative event/chronicle UI in `Project.Keynes`.

Also load:
- `project-keynes-narrative-event-writing` when writing or revising event content (prose, options, effects, labels).
- `project-keynes-ui-art-direction` when modifying event dialogs, chronicle panels, or visual styling.
- `project-keynes-player-controller` when changing `COMMAND_NARRATIVE_CHOOSE`, modal clock locks, or `player_view` persistence.
- `project-keynes-modifier-runtime` / `project-keynes-economy-runtime` / `project-keynes-country-runtime` when adding new effect primitives that dispatch commands to those authorities.

---

## 1. Architecture & Authority Boundaries

The Narrative Event System operates at the **player-session boundary** (targeting the player's country and its owned territory cells):

```text
DataCore / DCWorldExt (Climate/Ocean/Geography) + CountryFacade + EconomyFacade + GameplayEventBus
   │  (Read-only snapshots & fact events sampled ONLY on player-owned territory cells)
   ▼
NarrativeEventService (scripts/narrative/narrative_event_service.gd)
   │  - Dual-channel trigger engine (Fact-Driven + Periodic Pulse Sampler)
   │  - AI ingress: pulse slot / fact-driven (`AI_FACT_HINTS`) / state probe / scheduled prefetch,
   │    situation-weighted chance, 60-day throttle, single in-flight request
   │  - `accept_ai_generation()`: staleness window + re-sample at arrival, else drop
   │  - State probes (`NarrativeStateProbe`, dwell-gated) + `_ai_event_pool` cache:
   │    re-validate the state on arrival, fire from pool when it returns
   │  - Narrative text avoids data readings (prompt-enforced); validator only rewrites
   │    `34.2℃` into `{temperature}` — numbers as narrative quantities are allowed
   │  - Event chains: story_flags, weight_biases, scheduled_events
   │  - Chronicle history log & PKSV `pknr` section persistence
   ├─► NarrativeAiClient (scripts/narrative/ai/narrative_ai_client.gd)
   │    - Async HTTPRequest for LLM JSON + Era-styled Image Generation + user:// cache
   ▼
NarrativeEventFlow (scripts/narrative/narrative_event_flow.gd)
   │  - Modal lock arbitration, WorldClock + Worker pause sync, map cell highlight/focus
   ▼
NarrativeEventDialog / NarrativeChroniclePanel (scripts/ui/components/)
   │  - Torn-paper (`torn_note_v1`), cut-tag (`cut_tag_v1`), papercut era art (`*_cutout.tres`)
   ▼
PlayerController.request_command(&"narrative.choose")
   │  - Deterministic Q16 weighted roll (`NarrativeRng`)
   ▼
NarrativeEffectAdapter (scripts/narrative/narrative_effect_adapter.gd)
   ├─► ModifierFacade.queue_apply()   (City/Country modifiers with dynamic magnitude_q16 & duration_days)
   ├─► EconomyFacade.submit()         (Conserved cash transfers & market/treasury goods transfers)
   └─► CountryFacade.submit()         (Research signal discovery)
```

### Non-Negotiable Invariants
1. **Conserved Ledgers Are Never Modifiers**: Cash, goods, and population must **never** be registered or modified as Modifier stats. Always use `NarrativeEffectSpec.Kind` conserved commands (`TREASURY_CASH_TO_COHORT`, `COHORT_CASH_TO_TREASURY`, `COUNTRY_GOOD_TO_MARKET`, `MARKET_GOOD_TO_COUNTRY`, `MARKET_ADD_STOCK`, `MARKET_REMOVE_STOCK`) which clamp against real-time available balances at `effective_day`.
2. **Never Mutate Native Catalog Hashes at Runtime**: Both static and AI-generated events must target already-compiled `ModifierCatalog` keys and pass dynamic strength via `magnitude_q16` and `duration_days`.
   - City percentage effects use the **ADD 1.0** family: `economy.city.building.<sector>_output_factor[.cut]`, `economy.city.good.<good>.output_factor[.cut]`, `economy.city.birth_factor[.cut]`, `economy.city.need.<need>.consumption_factor[.cut]`. `magnitude_q16 = _pct(N)` means exactly ±N%.
   - Country sector effects use `ideology.country.output.<sector>_factor.gain` (MULTIPLY 2.0; `magnitude_q16 = _pct(N)` means +N%).
   - **Do not use `family.city.*` for new content.** They are legacy MULTIPLY 1.02–1.05 definitions: a magnitude of 1.15 yields only +5.75%, and `family.city.trade_output_boost` points at a stat with **zero** native readers (pure no-op).
3. **Deterministic Q16 RNG Only**: Never call unseeded `randf()` / `randi()` for event sampling or option outcome rolls. Always use `NarrativeRng.roll_q16()` or `NarrativeRng.pick_weighted_index()` keyed by `(world_seed, day, player_country_handle, cell_idx, salt)` so save/load round-trips produce identical outcomes.
4. **Majority Deterministic Options, Minority Probabilistic Gambles**:
   - **Standard Options (80%+ of options)** must have **1 deterministic outcome** (`outcomes.size() == 1`, `probability_q16 = 65536`). The UI renders these cleanly with a `✦` effect summary and a `[准奏施行]` cut-tag button, **without** any `"100% 概率"` text clutter.
   - **High-Risk Gamble Options (Minority)** have **2–3 outcomes** whose `probability_q16` sum to `65536`. The UI automatically badges these with a cinnabar `[博弈抉择]` cut-paper tag, displays each branch's percentage and title, and labels the action button `[决意一搏]`.

---

## 2. File Inventory

- **Core Models & Catalog (`Project/project-keynes/scripts/narrative/`)**:
  - `narrative_rng.gd`: SplitMix64 63-bit deterministic hashing and Q16 weighted index selection.
  - `narrative_condition.gd`: 40 multi-dimensional condition operators (`Op.TEMP_GTE/LTE`, `MOISTURE_GTE/LTE`, `PRECIP_GTE/LTE`, `SNOW_GTE`, `ELEVATION_GTE/LTE`, `HAS_RIVER`, `IS_COASTAL`, `OCEAN_CURRENT_SPEED_GTE`, `OCEAN_UPWELLING_GTE`, `TERRAIN_IN`, `LANDFORM_IN`, `POPULATION_GTE/LTE`, `SATISFACTION_GTE/LTE`, `HAS_BUILDING_TYPE`, `BUILDING_COUNT_GTE`, `MARKET_GOOD_SHORTAGE`, `MARKET_GOOD_PRICE_RATIO_GTE`, `HAS_NATURAL_RESOURCE`, `HAS_TECHNOLOGY`, `TREASURY_CASH_GTE`, `ERA_GTE/LTE`, `HAS_STORY_FLAG`, plus the human-dimension operators `SUBSISTENCE_SHORTFALL_GTE` / `UNEMPLOYMENT_GTE` / `PROFESSION_SHARE_GTE` / `COHORT_SATISFACTION_LTE`).
  - `narrative_weight_rule.gd`: Conditional additive and Q16 multiplicative weight modifiers based on local environment/economy state.
  - `narrative_effect_spec.gd`: The 13 whitelisted effect kinds (`Kind`), `clamp_safe()`, and Chinese `describe()` formatter.
  - `narrative_outcome.gd` & `narrative_option.gd`: Option requirements (`require_treasury_cash`, `require_good_id`, `require_technology`) and Q16 probability normalization.
  - `narrative_event_definition.gd`: Event schema, `{settlement_name}` / `{landform_name}` / `{temperature}` / `{good_name}` interpolation, and `to_dict()` / `from_dict()`.
  - `narrative_event_catalog.gd`: Authored event registry and `build_default_catalog()`.
  - `narrative_state_probe.gd` + `narrative_state_probe_catalog.gd`: Engine-judged standing states (id, conditions, `dwell_days`, cooldown) that gate AI prefetch. AI never authors these conditions.
- **Runtime Service & Flow (`Project/project-keynes/scripts/narrative/`)**:
  - `narrative_context_sampler.gd`: Samples `MapData` / `DCViewAdapter` (including adjacent coastal water cells for `ocean_current_speed` and `ocean_upwelling`), `CountryFacade`, and `EconomyFacade` into a `NarrativeCellContext` dictionary.
  - `narrative_effect_adapter.gd`: Dispatches `NarrativeEffectSpec` to `ModifierFacade`, `EconomyFacade`, `CountryFacade`, and `NarrativeEventService`.
  - `narrative_event_service.gd`: Dual-channel trigger engine, AI ingress (`_request_ai_generation` / `accept_ai_generation`, situation weighting, fact whitelist), cooldowns, one-shots, `story_flags`, `weight_biases`, `scheduled_events`, Chronicle log, and `pknr` serialization.
  - `narrative_event_flow.gd`: Modal arbitration against `EraReward`, `FamilyFounding`, `IdeologyDraw`, and `AnnualReport`, plus `WorldClock` pause/restore sync.
- **AI Generation Pipeline (`Project/project-keynes/scripts/narrative/ai/`)**:
  - `narrative_ai_prompt_builder.gd`: Builds LLM system/user prompts and era-specific illustration prompts.
  - `narrative_ai_validator.gd`: Strips Markdown fences, validates JSON, maps unknown modifier keys to safe fallbacks, clamps values, and normalizes Q16 probabilities.
  - `narrative_ai_client.gd`: Async `HTTPRequest` for LLM and image generation, `user://ai_credentials.cfg` key storage, and `user://narrative_cache/images/` PNG texture caching.
- **Archival UI (`Project/project-keynes/scripts/ui/components/`)**:
  - `narrative_event_dialog.gd`: Hand-drawn/papercut/torn-paper event dialog.
  - `narrative_chronicle_panel.gd`: Chronicle history scroll only. AI configuration lives in **game settings** (pause menu → 设置 → AI 生成设置, `pause_menu.gd::_show_ai_settings`); never put a config entry back into the event/chronicle UI.

---

## 3. How to Author a New Static Event or Event Chain

Add new event definitions in `NarrativeEventCatalog.build_default_catalog()` (or register via `catalog.register_event(NarrativeEventDefinition.from_dict({...}))`):

### 3.1 Single Event Template (Majority Deterministic + Optional Gamble)
```gdscript
catalog.events.append(NarrativeEventDefinitionScript.from_dict({
	"event_id": "evt.ocean.warm_current_fishery",
	"title": "{settlement_name}·暖流鱼群汇聚",
	"body_text": "一股温暖洋流掠过{settlement_name}外海，引来大批洄游鱼群（当前气温 {temperature}）。渔民们摩拳擦掌，只待官府定夺捕捞方略。",
	"image_key": "hydrology.water",
	"ai_visual_prompt": "Coastal fishing vessels hauling nets in a warm ocean current",
	"tags": ["ocean", "maritime", "harvest"],
	"trigger_channel": NarrativeEventDefinitionScript.TriggerChannel.PULSE_SAMPLED,
	"base_weight": 110,
	"cooldown_days": 180,
	"conditions": [
		{"op": Op.IS_COASTAL, "bool_value": true},
		{"op": Op.OCEAN_CURRENT_SPEED_GTE, "float_value": 0.15},
		{"op": Op.POPULATION_GTE, "int_value": 5},
	],
	"weight_rules": [
		{
			"condition": {"op": Op.OCEAN_UPWELLING_GTE, "float_value": 0.20},
			"add_weight": 60,
			"multiplier_q16": 98304, # 1.5x
			"reason": "强上升流带来额外渔获",
		},
	],
	"options": [
		{
			"option_id": "steady_catch",
			"text": "组织近海围网捕捞，充实本地市集",
			"tooltip_hint": "稳妥补充本地鱼获并提升贸易活力。",
			"outcomes": [
				{
					"probability_q16": 65536, # 100% deterministic (no percentage badge shown)
					"outcome_title": "鱼虾满仓",
					"outcome_narrative": "近海渔船满载而归，{settlement_name}市集鱼获充盈。",
					"effects": [
						{
							"kind": Kind.MARKET_ADD_STOCK,
							"target_key": "fish",
							"int_value": 60000, # 原始单位：60000 = 60 单位；每人每日主食约 440
							"custom_label": "本地市场新增 60 单位鱼类库存",
						},
					],
				},
			],
		},
		{
			"option_id": "deep_sea_venture",
			"text": "乘洋流远航深海，追捕巨型鱼群",
			"tooltip_hint": "高风险博弈：可能大获全胜，也可能遭遇风浪无功而返。",
			"outcomes": [
				{
					"probability_q16": 45875, # 70%
					"outcome_title": "深海丰收，满载而归",
					"outcome_narrative": "船队顺洋流大获全胜，不仅鱼获倍增，更摸清了外海航道。",
					"effects": [
						{
							"kind": Kind.MARKET_ADD_STOCK,
							"target_key": "fish",
							"int_value": 12000,
							"custom_label": "本地市场新增 12.0 单位鱼获库存",
						},
						{
							"kind": Kind.CITY_MODIFIER,
							"target_key": "economy.city.building.manufacturing_output_factor",
							"magnitude_q16": _pct(20), # ADD 族：20 就是 +20%
							"duration_days": 120,
							"custom_label": "本地制造产出 +20%，120 日",
						},
					],
				},
				{
					"probability_q16": 19661, # 30%
					"outcome_title": "风浪阻途，损网折橹",
					"outcome_narrative": "外海风急浪高，船队被迫折返并耗费公库修缮船只。",
					"effects": [
						{
							"kind": Kind.TREASURY_CASH_TO_COHORT,
							"ratio_bp": 200,
							# 收款人是「人数最多的那一群」，不是船户；标签必须写清
							"custom_label": "国库拨付本地人数最多的{primary_profession}，占国库现金 2%",
						},
					],
				},
			],
		},
	],
}))
```

### 3.2 Linking Events into an Event Chain
There are three complementary ways to link Event A to Event B:
1. **Immediate Encounter Bias (`on_trigger_effects`)**: Simply encountering Event A boosts the probability of Event B or a tag family (even before choosing an option):
   ```gdscript
   "on_trigger_effects": [
       {
           "kind": Kind.ADD_EVENT_WEIGHT_BIAS,
           "tag_key": "prospecting",
           "int_value": 0,
           "magnitude_q16": 98304, # 1.5x multiplier
           "duration_days": 365,
           "custom_label": "勘探类事件权重 ×1.5，365 日",
       }
   ]
   ```
2. **Prerequisite Gates (`required_events_completed` & `required_story_flags`)**:
   - In Event A's option outcome: emit `Kind.SET_STORY_FLAG` with `"target_key": "flag_my_chain_step1"`.
   - In Event B's definition: set `"required_events_completed": ["evt.chain.step1"]` and `"required_story_flags": ["flag_my_chain_step1"]`.
3. **Timed Follow-up Scheduling (`Kind.SCHEDULE_FOLLOWUP_EVENT`)**:
   - In Event A's option outcome: emit `Kind.SCHEDULE_FOLLOWUP_EVENT` with `"target_key": "evt.chain.step2"`, `"duration_days": 15`. Event B will automatically fire on that cell 15 days later.

### 3.3 Authoring a State Probe (AI prefetch by standing condition)

Add to `NarrativeStateProbeCatalog.build_default_probes()` when the trigger is a **sustained situation** rather than a one-off fact:

```gdscript
NarrativeStateProbeScript.from_dict({
	"state_id": "state.market.food_shortage",
	"display_name": "粮食紧缺",
	"prompt_hint": "本地粮价持续高于常年，居民抢购囤积",   # 输入给模型的状态描述，不含数值
	"dwell_days": 10,      # 连续维持多少游戏日才预取
	"cooldown_days": 240,  # 同格同状态两次预取的最小间隔
	"conditions": [
		{"op": Op.MARKET_GOOD_PRICE_RATIO_GTE, "target_key": "grain", "float_value": 1.35},
		{"op": Op.POPULATION_GTE, "int_value": 5},
	],
})
```

Rules:
- Conditions are engine-judged only; the AI still cannot author `conditions`.
- Only pick states that **persist for weeks** (shortage, discontent, drought). A one-day cold snap would always fail the recheck and waste a call.
- Written events go to `_ai_event_pool` when the state has lapsed or the popup gate is closed, and fire from the pool when the same state returns — no second API call.
- Narrative text must avoid **data readings** (temperature, price, stock, population, percentages, dates) because pooled events are reused months later. That rule lives in the prompt; narrative quantities ("三人", "三成") are fine. The validator only rewrites `34.2℃` into `{temperature}`; it never deletes clauses. `custom_label` still carries the numbers.


### 3.4 接口有效性（写内容前先看）

- **条件**：`SUBSISTENCE_SHORTFALL_GTE` / `UNEMPLOYMENT_GTE` / `PROFESSION_SHARE_GTE` /
  `COHORT_SATISFACTION_LTE` 依赖 cohort 明细，只有 `include_cohort_details=true` 的扫描（脉冲/事实/状态探针）
  才算得出来；不要把它们塞进入队或结算路径。
- **现金转账**：`TREASURY_CASH_TO_COHORT` / `COHORT_CASH_TO_TREASURY` 永远只作用于**人数最多的那一群**
  cohort，不是全城、也不能指定职业。标签用 `{primary_profession}` 让引擎填入真实职业名。
- **物资**：`MARKET_ADD_STOCK` 直接增补本地市场库存，但**该格必须有商人**（否则原生整批拒绝）；
  数量按原始单位算（每人每日主食约 440）。`COUNTRY_GOOD_TO_MARKET` 需要国库真有该物资——
  玩家不能收购物资，国库通常没有，正常游戏里基本空转；要写「官府出粮」用 `MARKET_ADD_STOCK`。
- **`require_good_id`** 把「本地市场 + 国库」相加后判断；效果却只从各自来源扣。门槛通过不等于效果一定有货，
  用 `COUNTRY_GOOD_TO_MARKET` 时尤其明显。
- **范围效果**：`CITY_MODIFIER` 可带 `radius_cells`（0–2）与 `falloff`（0 均等 / 1 逐环 100%/60%/30%）。
  采样器写 `nearby_owned_cells_r1/r2`（只含己方领土、排除水面、去重升序）；适配器对每格各发一条修正。
  标签写「本地及周边 N 环……」，不要写「N 格」；`COUNTRY_MODIFIER` 忽略这两个字段。
- **字段语义**：`scope` 只决定冷却键的粒度（CELL/COUNTRY），不会把事件变成全国事件；
  `trigger_chance_q16` 只被脉冲与事实通道使用，排程直接入队；`version` 与 `image_key` 目前只做存档/档案元数据，
  没有运行时消费者；`{good_name}` 解析的是「当前价格比最高的商品」，不是事件指定的商品。
- **AI 接口**：`CITY_MODIFIER` 的 `magnitude_percent` 是 ADD 族百分比（15 = +15%），
  白名单已改到 `economy.city.building.*` / `economy.city.good.*` / `economy.city.birth_factor[.cut]`；
  不要再让模型输出 `family.city.*`（弱化 2~8 倍，trade 键空转）。


---

## 4. UI Art Direction Rules for Narrative UI

Never introduce flat `StyleBoxFlat` rectangles or dark gray default `LineEdit`/`CheckButton` boxes in narrative screens. Always preserve the **hand-drawn / papercut / torn-paper archival folio** language:
1. **Main Folio & Option Cards**: Use `res://assets/ui/era/era_note_style.tres` (`torn_note_v1.tres` nine-slice with deckled torn edges) plus an angled underlay sheet (`deg_to_rad(-0.75)`) and soft contact shadow.
2. **Buttons, Tags & Inputs**: Use `res://assets/ui/paper_aux_v1/cut_tag_v1.tres` (hand-cut paper slip with clipped diagonal corner) for top action buttons (`⌖ 寻访事发地`, `✦ 史册卷宗`), category tags (`天时`, `旱象`, `博弈抉择`), option confirm buttons (`准奏施行` / `决意一搏`), and `LineEdit`/`CheckButton` backgrounds.
3. **Illustrations & Shaders**:
   - Use `annual_chronicle/*_cutout.tres` colored-pencil papercut illustrations for default event art, or AI-generated textures when enabled.
   - Keep `annual_ink_bleed.gdshader` on the illustration for the opening ink-reveal tween (`bleed: 0.15 -> 1.2`) and `annual_cover_wash.gdshader` at the bottom edge so the illustration feathers into the paper instead of ending in a hard box.
4. **Typography**:
   - Main event title & outcome title: `UITokens.annual_font("display")` (`Muyao-Softbrush`).
   - Section kickers & dates: `UITokens.annual_font("label")` in `UITokens.DOSSIER_OXBLOOD`.
   - Narrative prose body: `UITokens.DOSSIER_SERIF` (`SourceHanSerifCN-Regular`) with `line_spacing = 5`.
   - Option titles & effect lines: `UITokens.dossier_font("sans_strong")` / `UITokens.dossier_font("sans")`.

---

## 5. Verification Checklist

Run both the headless contract test and the visual screenshot QA script after any change to the narrative event system:

```powershell
# 1. Headless unit, chain, save/restore round-trip, and AI sandbox test (expect 0 failures)
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" --headless --path Project/project-keynes --script tests/game/narrative_event_runtime_test.gd --quit

# 2. Visual screenshot QA (renders 5 PNGs: event offer / outcome / chronicle / pause settings / AI settings)
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" --rendering-driver opengl3 --path Project/project-keynes --script tests/qa/narrative_ui_screenshot_qa.gd

# 3. Settings & SaveRepository regression tests
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" --headless --path Project/project-keynes --script tests/game/game_settings_service_test.gd --quit
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" --headless --path Project/project-keynes --script tests/game/save_repository_test.gd --quit

# 4. AI configuration entry lives in game settings, not the event folio
& "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" --headless --path Project/project-keynes --script tests/ui/pause_menu_ai_settings_test.gd --quit
```
