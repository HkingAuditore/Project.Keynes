class_name NarrativeAiPromptBuilder
extends RefCounted

## Builds structured system and user prompts for OpenAI / DeepSeek compatible
## Chat Completions JSON mode, plus era-specific historical illustration prompts.

const DEFAULT_ALLOWED_GOODS := [
	"grain",
	"fish",
	"meat",
	"salt",
	"timber",
	"stone",
	"clay",
	"copper",
	"tin",
	"bronze",
	"iron",
	"coal",
	"tools",
	"cloth",
	"clothing",
	"pottery",
	"wine",
	"luxury",
	"livestock",
	"herbs",
	"paper",
]

const CITY_MODIFIER_KEYS := [
	"family.city.production_boost",
	"family.city.agriculture_output_boost",
	"family.city.extractive_output_boost",
	"family.city.manufacturing_output_boost",
	"family.city.energy_output_boost",
	"family.city.knowledge_output_boost",
	"family.city.birth_boost",
	"family.city.birth_cut",
	"family.city.trade_output_boost",
]

const COUNTRY_MODIFIER_KEYS := [
	"country.economic_mobilization",
	"ideology.country.output.agriculture_factor.gain",
	"ideology.country.output.extractive_factor.gain",
	"ideology.country.output.manufacturing_factor.gain",
	"ideology.country.output.energy_factor.gain",
	"ideology.country.output.knowledge_factor.gain",
	"ideology.country.trade.capacity_factor.gain",
]

const ERA_NAMES := [
	"石器时代",
	"农耕时代",
	"青铜与城邦时代",
	"古典王国时代",
	"帝国与封建时代",
	"文艺复兴与航海时代",
	"工场手工业时代",
	"蒸汽工业时代",
	"电气与钢铁时代",
	"原子与信息时代",
	"智能与生态时代",
]

const ERA_IMAGE_ART_DIRECTIONS := [
	"Prehistoric Stone Age cave wall ochre and charcoal painting, earth pigments on rough rock texture, primitive tribal storytelling, no text, no letters",
	"Ancient Agrarian Age painted pottery frieze and early mural art, warm mineral pigments on clay and plaster, classical agricultural motif, no text, no letters",
	"Bronze Age and City-State classical scroll and fresco painting, rich lapis and ochre pigments, carved relief aesthetics, monumental antiquity, no text, no letters",
	"Classical Kingdom Age illuminated historical manuscript and fresco painting, dignified composition, classical architecture and attire, no text, no letters",
	"Imperial and Feudal Age classical historical handscroll and tempera painting, fine brushwork, atmospheric landscape and courtly life, no text, no letters",
	"Renaissance and Age of Discovery classical oil painting on canvas, chiaroscuro lighting, rich brushwork, maritime and mercantile atmosphere, no text, no letters",
	"Early Modern Manufactory Age Dutch Golden Age style oil painting and hand-colored etching, detailed guild workshop and market realism, no text, no letters",
	"Victorian Steam Industrial Age copperplate engraving and academic historical oil painting, dramatic soot and steam atmosphere, 19th-century realism, no text, no letters",
	"Early 20th-Century Electric and Steel Age archival lithograph and early documentary illustration, industrial modernity, bold composition, no text, no letters",
	"Mid-20th-Century Atomic and Information Age archival editorial illustration and mid-century gouache painting, documentary realism, no text, no letters",
	"Near-Future Intelligent and Ecological Age architectural concept painting and solarpunk archival illustration, clean atmospheric lighting, no text, no letters",
]


static func build_messages(
		cell_ctx: Dictionary,
		recent_chronicle: Array = [],
		chain_hint: String = "",
		allowed_goods: PackedStringArray = PackedStringArray(),
		allowed_buildings: PackedStringArray = PackedStringArray(),
		fact_hint: String = "",
		state_hint: String = ""
) -> Array[Dictionary]:
	var goods_list := _resolve_goods_list(allowed_goods, cell_ctx)
	var buildings_list := _resolve_buildings_list(allowed_buildings, cell_ctx)
	var system_content := _build_system_prompt(goods_list, buildings_list)
	var user_content := _build_user_prompt(
		cell_ctx, recent_chronicle, chain_hint, goods_list, buildings_list, fact_hint, state_hint)
	var messages: Array[Dictionary] = [
		{
			"role": "system",
			"content": system_content,
		},
		{
			"role": "user",
			"content": user_content,
		},
	]
	return messages


static func build_era_image_prompt(era_index: int, raw_visual_prompt: String, cell_ctx: Dictionary = {}) -> String:
	var clamped_era := clampi(era_index, 0, ERA_IMAGE_ART_DIRECTIONS.size() - 1)
	if not cell_ctx.is_empty() and era_index < 0:
		clamped_era = clampi(int(cell_ctx.get("era_index", 0)), 0, ERA_IMAGE_ART_DIRECTIONS.size() - 1)
	var art_prefix: String = ERA_IMAGE_ART_DIRECTIONS[clamped_era]
	var cleaned_raw := raw_visual_prompt.strip_edges()
	var context_bits := PackedStringArray()
	if not cell_ctx.is_empty():
		var terrain_name := String(cell_ctx.get("terrain_name", "")).strip_edges()
		var landform_name := String(cell_ctx.get("landform_name", "")).strip_edges()
		var settlement_name := String(cell_ctx.get("settlement_name", "")).strip_edges()
		if not terrain_name.is_empty() or not landform_name.is_empty():
			context_bits.append("geography: %s %s" % [terrain_name, landform_name])
		if bool(cell_ctx.get("has_river", false)):
			context_bits.append("river valley")
		if bool(cell_ctx.get("is_coastal", false)):
			context_bits.append("coastal harbor")
		if float(cell_ctx.get("snow_cover", 0.0)) >= 0.35:
			context_bits.append("snow-covered winter")
		if not settlement_name.is_empty():
			context_bits.append("settlement scene")
	var geo_clause := ", ".join(context_bits)
	if cleaned_raw.is_empty():
		cleaned_raw = "Historical grand-strategy event scene depicting local economic life and natural environment"
	if not geo_clause.is_empty():
		return "%s. Scene: %s (%s). Strictly no text, no watermark, no UI frames, no letters." % [
			art_prefix, cleaned_raw, geo_clause
		]
	return "%s. Scene: %s. Strictly no text, no watermark, no UI frames, no letters." % [
		art_prefix, cleaned_raw
	]


static func _resolve_goods_list(allowed_goods: PackedStringArray, cell_ctx: Dictionary) -> PackedStringArray:
	if not allowed_goods.is_empty():
		return allowed_goods
	var out := PackedStringArray()
	var market_stocks: Variant = cell_ctx.get("market_stocks_by_id", cell_ctx.get("market_stocks", {}))
	if market_stocks is Dictionary:
		for k in (market_stocks as Dictionary).keys():
			var s := String(k).strip_edges()
			if not s.is_empty() and not out.has(s):
				out.append(s)
	for g in DEFAULT_ALLOWED_GOODS:
		if not out.has(g):
			out.append(g)
	return out


static func _resolve_buildings_list(allowed_buildings: PackedStringArray, cell_ctx: Dictionary) -> PackedStringArray:
	if not allowed_buildings.is_empty():
		return allowed_buildings
	var out := PackedStringArray()
	var b_counts: Variant = cell_ctx.get("building_counts_by_id", cell_ctx.get("building_counts", {}))
	if b_counts is Dictionary:
		for k in (b_counts as Dictionary).keys():
			var s := String(k).strip_edges()
			if not s.is_empty() and not out.has(s):
				out.append(s)
	return out


static func _build_system_prompt(goods_list: PackedStringArray, buildings_list: PackedStringArray) -> String:
	var goods_joined := ", ".join(goods_list)
	var city_mods_joined := ", ".join(PackedStringArray(CITY_MODIFIER_KEYS))
	var country_mods_joined := ", ".join(PackedStringArray(COUNTRY_MODIFIER_KEYS))
	var buildings_note := (", ".join(buildings_list)) if not buildings_list.is_empty() else "无特定建筑限制"

	var lines := PackedStringArray([
		"你是《Project.Keynes》的大战略事件设计师。",
		"根据地块地理、气候、海洋、产业、市场、人口、国库与近期事件记录，生成一条可直接决策的事件。",
		"",
		"【输出格式要求】",
		"必须且只能输出严格的 JSON 对象，严格遵循以下 Schema：",
		"""{
  "title": "事件标题（4-10字）",
  "body_text": "触发事实（20-50字：只写条件、现状与影响，不写场景与修辞）",
  "ai_visual_prompt": "English visual prompt for period-appropriate historical illustration, no text/letters",
  "tags": ["climate", "economy"],
  "options": [
    {
      "text": "选项动作（4-12字）",
      "require_treasury_cash": 0,
      "outcomes": [
        {
          "probability_percent": 70,
          "outcome_title": "结果（4-8字）",
          "effects": [
            {
              "kind": "CITY_MODIFIER",
              "target_key": "family.city.production_boost",
              "magnitude_percent": 15,
              "duration_days": 90,
              "custom_label": "本地综合生产效率 +15%，90 日"
            }
          ]
        }
      ]
    }
  ]
}""",
		"",
		"【设计规范与安全白名单】",
		"1. 每个事件提供 2 到 3 个具有真实权衡的选项（`options`）。绝大多数常规选项应当是**确定性结果**（即 `outcomes` 数组只有 1 项，`probability_percent: 100`）；仅当某个选项确实属于「高风险博弈/勘探奇遇/强行弹压」时，才为该选项设计 2 个概率分支结果（同一选项下所有 `outcomes` 的 `probability_percent` 之和必须等于 100）。",
		"2. 所有 `custom_label` 必须是「对象 + 幅度 + 时长」的短句，例如：`本地农业产出 +15%，90 日`、`国库转出 4% 资金给本地居民`、`标记「凛冬考验」，90 日`。不得写文学化描述。",
		"3. 允许使用的 `effects[].kind` 及其合法 `target_key` 白名单如下：",
		"   - `CITY_MODIFIER`（本地城市修正）：",
		"     允许的 `target_key`：%s, `family.city.Birth_cut`（或 `family.city.birth_cut`），或者单品产出修正 `economy.city.good.<good_id>.output_factor` 与减益 `economy.city.good.<good_id>.output_factor.cut`（其中 `<good_id>` 必须来自允许商品列表）。" % city_mods_joined,
		"     参数：`magnitude_percent`（5 到 50 之间的整数，代表增减百分比）和 `duration_days`（15 到 365 之间的整数）。",
		"   - `COUNTRY_MODIFIER`（全国修正）：",
		"     允许的 `target_key`：%s。" % country_mods_joined,
		"     参数：`magnitude_percent`（5 到 50）和 `duration_days`（15 到 365）。",
		"   - `TREASURY_CASH_TO_COHORT`（国库拨款赈济本地民众）与 `COHORT_CASH_TO_TREASURY`（本地民间筹款上缴国库）：",
		"     参数：可使用 `ratio_bp`（100..2000，代表 1%..20% 资金比例）或 `int_value`（正整数金额）。",
		"   - `COUNTRY_GOOD_TO_MARKET`（国家储备投放本地市场）、`MARKET_GOOD_TO_COUNTRY`（本地市场征调入国库）、`MARKET_ADD_STOCK`（本地市场新增商品库存）、`MARKET_REMOVE_STOCK`（本地市场损耗商品库存）：",
		"     允许的 `target_key` 必须严格属于 `allowed_goods`：[%s]。" % goods_joined,
		"     参数：`int_value`（正整数数量）或 `ratio_bp`（100..2000）。",
		"   - `SET_STORY_FLAG`（记录叙事态势标记）：`target_key` 为英文蛇形命名标记（如 `grain_relief_promised`），`duration_days` 为持续天数（15..365）。",
		"   - `ADD_EVENT_WEIGHT_BIAS`（调整后续同类事件触发权重）：设置 `tag_key`（如 `famine`, `trade`, `unrest`, `harvest`, `plague`, `climate`）、`int_value`（-200..400）及 `duration_days`（30..365）。",
		"   - `SCHEDULE_FOLLOWUP_EVENT`（预约多阶段后续事件链）：设置 `target_key`（后续事件标识或链条名）、`duration_days`（多少日后触发，15..180）以及 `ai_followup_prompt`（后续事件的走向要点）。",
		"4. 可参考的建筑类型列表：[%s]。" % buildings_note,
		"5. **叙事文本只写处境与后果，不写可测的数据读数**：`title`、`body_text`、`options[].text`、`outcomes[].outcome_title` 里禁止写气温、降水量、价格、库存、人口、满意度、百分比起伏、金额、具体日期或持续天数这类读取值——这些事件会被缓存数月后复用，读数一定过期。叙述需要的泛指数量照常写：三人、数十户、三成、半数都可以。确实要指代气温时写占位符 `{temperature}`（已含单位，不要再补 ℃ 或「度」）。`custom_label` 是唯一例外，按第 2 条写「对象 + 幅度 + 时长」。",
		"6. 文风要求：只写事实与后果，用最短句子；不得使用修辞、比喻、典故、感叹、场景铺陈与人物对白；不得出现超越当前时代的现代词汇；严禁输出 JSON 之外的任何文本。",
	])
	return "\n".join(lines)


static func _build_user_prompt(
		cell_ctx: Dictionary,
		recent_chronicle: Array,
		chain_hint: String,
		goods_list: PackedStringArray,
		buildings_list: PackedStringArray,
		fact_hint: String = "",
		state_hint: String = ""
) -> String:
	var day := int(cell_ctx.get("day", 1))
	var country_name := String(cell_ctx.get("country_name", "我国"))
	var settlement_name := String(cell_ctx.get("settlement_name", "当地聚落"))
	var era_idx := clampi(int(cell_ctx.get("era_index", 0)), 0, ERA_NAMES.size() - 1)
	var era_name := String(cell_ctx.get("era_name", ERA_NAMES[era_idx]))
	var terrain_name := String(cell_ctx.get("terrain_name", "平原"))
	var landform_name := String(cell_ctx.get("landform_name", "平地"))
	var temp_c := float(cell_ctx.get("temperature_c", cell_ctx.get("temperature", 18.0)))
	var moisture := float(cell_ctx.get("moisture", 0.5))
	var precip := float(cell_ctx.get("precipitation", cell_ctx.get("weather_precip", 0.0)))
	var snow := float(cell_ctx.get("snow_cover", 0.0))
	var elevation := float(cell_ctx.get("elevation", 0.5))
	var has_river := bool(cell_ctx.get("has_river", false))
	var is_coastal := bool(cell_ctx.get("is_coastal", false))
	var current_speed := float(cell_ctx.get("ocean_current_speed", 0.0))
	var upwelling := float(cell_ctx.get("ocean_upwelling", 0.0))
	var population := int(cell_ctx.get("population", 0))
	var satisfaction := float(cell_ctx.get("satisfaction_norm", cell_ctx.get("satisfaction", 0.65)))
	var treasury_cash := int(cell_ctx.get("treasury_cash", 0))
	var cohort_cash := int(cell_ctx.get("primary_cohort_cash", 0))

	var lines := PackedStringArray([
		"【当前世界与聚落状态快照】",
		"- 纪年日：第 %d 日 | 国家：%s | 时代：%s（era_index=%d）" % [day, country_name, era_name, era_idx],
		"- 聚落名称：%s（地块 #%d）" % [settlement_name, int(cell_ctx.get("cell_idx", 0))],
		"- 自然地理：地形=%s，地貌=%s，海拔=%.2f，河流=%s，沿海=%s" % [
			terrain_name, landform_name, elevation,
			"有" if has_river else "无",
			"是" if is_coastal else "否",
		],
		"- 气候与海洋：气温=%.1f°C，湿度=%.2f，降水=%.2f，积雪=%.2f，洋流流速=%.2f，上升流强度=%.2f" % [
			temp_c, moisture, precip, snow, current_speed, upwelling,
		],
		"- 人口与财政：聚落人口=%d，民众满意度=%.0f%%，国库可用资金=%d，本地民间资金=%d" % [
			population, satisfaction * 100.0, treasury_cash, cohort_cash,
		],
	])

	var b_counts: Variant = cell_ctx.get("building_counts_by_id", cell_ctx.get("building_counts", {}))
	if b_counts is Dictionary and not (b_counts as Dictionary).is_empty():
		var b_parts := PackedStringArray()
		for k in (b_counts as Dictionary).keys():
			b_parts.append("%s×%d" % [String(k), int((b_counts as Dictionary)[k])])
		lines.append("- 本地产业建筑：%s" % ", ".join(b_parts))

	var shortages: Variant = cell_ctx.get("shortage_good_ids", cell_ctx.get("shortage_goods", PackedStringArray()))
	if (shortages is PackedStringArray or shortages is Array) and shortages.size() > 0:
		var s_parts := PackedStringArray()
		for item in shortages:
			s_parts.append(String(item))
		lines.append("- 市场紧缺商品：%s" % ", ".join(s_parts))

	var ratios: Variant = cell_ctx.get("market_price_ratios_by_id", cell_ctx.get("market_price_ratios", {}))
	var stocks: Variant = cell_ctx.get("market_stocks_by_id", cell_ctx.get("market_stocks", {}))
	if ratios is Dictionary and not (ratios as Dictionary).is_empty():
		var m_parts := PackedStringArray()
		for k in (ratios as Dictionary).keys():
			var gid := String(k)
			var r_val := float((ratios as Dictionary)[k])
			var st_val := int((stocks as Dictionary).get(k, 0)) if stocks is Dictionary else 0
			if st_val > 0 or absf(r_val - 1.0) >= 0.15:
				m_parts.append("%s(库存:%d, 价格比:%.2f)" % [gid, st_val, r_val])
		if not m_parts.is_empty():
			lines.append("- 本地市场行情：%s" % ", ".join(m_parts))

	var nat_res: Variant = cell_ctx.get("natural_resources_by_id", cell_ctx.get("natural_resources", {}))
	if nat_res is Dictionary and not (nat_res as Dictionary).is_empty():
		var r_parts := PackedStringArray()
		for k in (nat_res as Dictionary).keys():
			r_parts.append("%s:%d" % [String(k), int((nat_res as Dictionary)[k])])
		lines.append("- 自然资源储量：%s" % ", ".join(r_parts))

	var flags: Variant = cell_ctx.get("story_flags", {})
	if flags is Dictionary and not (flags as Dictionary).is_empty():
		var f_parts := PackedStringArray()
		for k in (flags as Dictionary).keys():
			var ks := String(k)
			if not ks.begins_with("cell:") and not ks.begins_with("country:"):
				f_parts.append(ks)
		if not f_parts.is_empty():
			lines.append("- 当前活跃叙事标记（story_flags）：%s" % ", ".join(f_parts))

	if not recent_chronicle.is_empty():
		lines.append("")
		lines.append("【近期编年史事件回顾（请避免重复雷同，可呼应前事）】")
		var start_idx := maxi(0, recent_chronicle.size() - 5)
		for i in range(start_idx, recent_chronicle.size()):
			var rec: Variant = recent_chronicle[i]
			if rec is Dictionary:
				var rd: Dictionary = rec
				var r_day := int(rd.get("day", 0))
				var r_title := String(rd.get("title", rd.get("event_title", "历史事件")))
				var r_outcome := String(rd.get("outcome_title", rd.get("choice_text", "")))
				lines.append("  * 第 %d 日：《%s》 -> %s" % [r_day, r_title, r_outcome])
			else:
				lines.append("  * %s" % String(rec))

	if not state_hint.strip_edges().is_empty():
		lines.append("")
		lines.append("【当前长期状态（事件必须回应这个状态，不要写成一次性偶发）】")
		lines.append(state_hint.strip_edges())
		lines.append("这类事件会被缓存、在该状态再次出现时才展示：只写处境与后果，不写当日读数（数量词可用）。")

	if not fact_hint.strip_edges().is_empty():
		lines.append("")
		lines.append("【本次触发事实（事件必须直接回应该事实，不要另起场景）】")
		lines.append(fact_hint.strip_edges())

	if not chain_hint.strip_edges().is_empty():
		lines.append("")
		lines.append("【事件链续写指引（Chain Hint）】")
		lines.append("本次事件是先前事件预约的后续回响，请务必承接以下脉络展开：%s" % chain_hint.strip_edges())

	lines.append("")
	lines.append("允许使用的商品 ID（allowed_goods）：[%s]" % ", ".join(goods_list))
	if not buildings_list.is_empty():
		lines.append("允许参考的建筑 ID（allowed_buildings）：[%s]" % ", ".join(buildings_list))
	lines.append("请直接输出符合 Schema 的 JSON 对象。")
	return "\n".join(lines)
