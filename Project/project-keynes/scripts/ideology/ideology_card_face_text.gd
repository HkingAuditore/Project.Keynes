extends RefCounted

const IdeologyEffectCommandScript = preload("res://scripts/effect/effect_command.gd")

const IdeologyCatalogTextScript = preload("res://scripts/ideology/ideology_catalog_text.gd")
const GoodProfileRegistryScript = preload("res://scripts/data/good_profile_registry.gd")
const ResourceProfileRegistryScript = preload(
	"res://scripts/data/resource_profile_registry.gd")

static func _clean_card_face_text(host, raw: String) -> String:
	var text := raw.strip_edges()
	if text.is_empty():
		return ""
	# Normalize ASCII comparisons before phrase rules so every summary uses the
	# same "至少"/"至多" path and no spaces are stranded after symbols.
	text = text.replace(">=", "≥").replace("<=", "≤")
	text = _replace_unemployment_text(text)
	text = text.replace("（最多 32 格）", "（最多 32 个地块）")
	text = text.replace("最多 32 格", "最多 32 个地块")
	text = text.replace(" 产出 提高", "产出提高")
	text = text.replace(" 产出 降低", "产出降低")
	text = host._replace_source_count_text(text)
	text = text.replace("最多计算", "最多计入")
	text = _replace_chain_text(text)
	text = _replace_profession_text(text)
	text = _replace_tax_burden_text(text)
	text = _replace_reserve_ratio_text(text)
	text = _replace_policy_floor_text(text)
	text = _replace_domain_terms_text(text)
	text = text.replace("农业提高", "农业产出提高")
	text = text.replace("工业降低", "工业产出降低")
	text = text.replace("≥", "至少 ").replace("≤", "至多 ")
	text = text.replace("R1", "周围 1 格").replace("R2", "周围 2 格")
	text = text.replace("职业 至少 ", "职业至少 ")
	text = text.replace("占比 至少 ", "占比至少 ")
	text = text.replace("民意 至少 ", "民意至少 ")
	text = text.replace("人口 至少 ", "人口至少 ").replace("人口 至多 ", "人口至多 ")
	text = _replace_population_count_text(text)
	text = text.replace("相邻至少 2 个以农业为主的地块", "周围至少 2 个以农业为主的地块")
	text = text.replace("相邻至少 ", "周围至少 ")
	text = text.replace("  ", " ")
	text = text.replace("产出 提高", "产出提高").replace("产出 降低", "产出降低")
	text = _replace_multiplier_text(text)
	text = _replace_ceiling_text(text)
	text = _replace_signed_percent_text(text)
	text = _replace_percent_spacing(text)
	text = _replace_known_resource_ids(text)
	text = text.replace("建造成本", "建设成本")
	text = text.replace("边地农业地块：农业提高", "边地农业地块：农业产出提高")
	text = text.replace("、成本", "，成本")
	text = text.replace("、且", "，且")
	text = _normalize_card_face_punctuation(text)
	text = text.replace("符合条件 的地块", "符合条件的地块")
	# Two selectively conditioned phrases are expanded after the broad
	# production wording pass. Apply the narrow fixes at the end so their new
	# suffixes cannot bypass the earlier rules.
	text = text.replace("：工业降低 5%", "：工业产出降低 5%")
	text = text.replace("降水充足时农业提高", "降水充足时农业产出提高")
	text = text.replace("  ", " ")
	text = text.replace("+0%", "").replace("-0%", "")
	text = _collapse_colons(text)
	text = text.replace(" ：", "：").replace("： ", "：")
	return text.strip_edges().trim_suffix("，").trim_suffix("：")


static func _replace_source_count_text(host, text: String) -> String:
	return IdeologyCatalogTextScript.replace_source_count_text(host, text)


static func _replace_multiplier_text(text: String) -> String:
	var regex := RegEx.new()
	if regex.compile("×\\s*([0-9]+(?:\\.[0-9]+)?)") != OK:
		return text
	for found in regex.search_all(text):
		var multiplier := float(found.get_string(1))
		var percent := int(round((multiplier - 1.0) * 100.0))
		text = text.replace(found.get_string(0), "提高 %d%%" % percent)
	return text


static func _replace_ceiling_text(text: String) -> String:
	var regex := RegEx.new()
	if regex.compile("上限\\s*([+-])\\s*([0-9]+(?:\\.[0-9]+)?)%") != OK:
		return text
	for found in regex.search_all(text):
		var direction := "提高" if found.get_string(1) == "+" else "降低"
		var replacement := "最多%s %s%%" % [direction, found.get_string(2)]
		text = text.replace(found.get_string(0), replacement)
	return text


static func _replace_population_count_text(text: String) -> String:
	# Population selectors are authored as integer thresholds. Add a count noun
	# and make the comparator read like ordinary Chinese.
	var regex := RegEx.new()
	if regex.compile("人口(至少|至多)\\s*([0-9]+)\\s*的地块") != OK:
		return text
	var result := text
	for found in regex.search_all(text):
		var replacement := "人口数量%s %s 人的地块" % [
			found.get_string(1), found.get_string(2)]
		result = result.replace(found.get_string(0), replacement)
	return result


static func _format_card_face_number(value: float) -> String:
	var text := "%.4f" % value
	while text.ends_with("0"):
		text = text.left(text.length() - 1)
	if text.ends_with("."):
		text = text.left(text.length() - 1)
	return text


static func _replace_unemployment_text(text: String) -> String:
	text = text.replace("（最多 32 格）", "（最多 32 个地块）")
	# Authored rows still spell the sector subject before the selector. Normalize
	# this compact form independently of the later pillar-cell wording pass.
	text = text.replace("工业支柱地块（最多 32 格）：", "以工业为主的地块：")
	text = text.replace("农业支柱地块（最多 32 格）：", "以农业为主的地块：")
	text = text.replace("知识支柱地块（最多 32 格）：", "以知识业为主的地块：")
	text = text.replace("能源支柱地块（最多 32 格）：", "以能源业为主的地块：")
	text = text.replace("矿业支柱地块（最多 32 格）：", "以矿业为主的地块：")
	text = text.replace("采掘业支柱地块（最多 32 格）：", "以采掘业为主的地块：")
	text = text.replace("失业率每点工业 +", "失业率每提高 1 个百分点，工业产出 +")
	text = text.replace("失业率每点知识 +", "失业率每提高 1 个百分点，知识产出 +")
	text = text.replace("失业率每点全部产出 +", "失业率每提高 1 个百分点，全部产出 +")
	text = text.replace("失业率每点工业提高", "失业率每提高 1 个百分点，工业产出提高")
	text = text.replace("失业率每点知识提高", "失业率每提高 1 个百分点，知识产出提高")
	text = text.replace("失业率每点全部产出提高", "失业率每提高 1 个百分点，全部产出提高")
	return text


static func _replace_chain_text(text: String) -> String:
	var result := text
	var chain_label := "至少已建成 1 条完整建筑升级链（同一升级系列的各等级建筑均已建成）的地块"
	# Rewrite the authored shape before the generic `成链地块` substitution.
	# The source may carry ASCII signed percentages (`+2%`).
	var chained_ramp := RegEx.new()
	if chained_ramp.compile(
			"每个成链地块使成链地块的(.+?)产出\\s*([+\\-])\\s*([0-9]+(?:\\.[0-9]+)?)%\\s*[（(]\\s*(?:上限|最多)\\s*\\+?([0-9]+(?:\\.[0-9]+)?)%\\s*[）)]"
			) == OK:
		for found in chained_ramp.search_all(result):
			var direction := "提高" if found.get_string(2) == "+" else "降低"
			result = result.replace(found.get_string(0),
				"当地%s：全国每有 1 个这样的地块，这些目标地块的%s产出%s %s%%；最高%s %s%%" % [
					chain_label, found.get_string(1), direction,
					found.get_string(3), direction, found.get_string(4)])
	var chain_count := RegEx.new()
	if chain_count.compile(
			"成链\\s*(?:≥|>=|至少)?\\s*([0-9]+)\\s*的地块"
			) == OK:
		for found in chain_count.search_all(result):
			result = result.replace(found.get_string(0),
				"当地%s的地块" % chain_label)
	result = result.replace("成链地块", "当地%s的地块" % chain_label)
	return result


static func _replace_profession_text(text: String) -> String:
	var result := text
	# These summaries are generated from cell metrics, so "占比" is a share of
	# the local workforce rather than a national or sector share.
	var profession_count := RegEx.new()
	if profession_count.compile("职业\\s*≥\\s*([0-9]+)\\s*种") == OK:
		for found in profession_count.search_all(result):
			result = result.replace(found.get_string(0),
				"劳动力至少包含 %s 种职业" % found.get_string(1))
	var sole_share := RegEx.new()
	if sole_share.compile("单一职业占比\\s*≥\\s*([0-9]+(?:\\.[0-9]+)?)%") == OK:
		for found in sole_share.search_all(result):
			result = result.replace(found.get_string(0),
				"单一职业占劳动力至少 %s%%" % found.get_string(1))
	var industrial_share := RegEx.new()
	if industrial_share.compile(
			"工业职业占比\\s*≥\\s*([0-9]+(?:\\.[0-9]+)?)%"
			) == OK:
		for found in industrial_share.search_all(result):
			result = result.replace(found.get_string(0),
				"工业职业占劳动力至少 %s%%" % found.get_string(1))
	var cooperative_share := RegEx.new()
	if cooperative_share.compile(
			"合作社职业占比\\s*≥\\s*([0-9]+(?:\\.[0-9]+)?)%"
			) == OK:
		for found in cooperative_share.search_all(result):
			result = result.replace(found.get_string(0),
				"合作社职业占劳动力至少 %s%%" % found.get_string(1))
	var worker_opinion := RegEx.new()
	if worker_opinion.compile(
			"工人阶层民意\\s*(<|≥)\\s*([0-9]+(?:\\.[0-9]+)?)"
			) == OK:
		for found in worker_opinion.search_all(result):
			var ratio := float(found.get_string(2))
			var percent := int(round(ratio * 100.0))
			var replacement := "工人阶层支持度低于 %d%%" % percent
			if found.get_string(1) == "≥":
				replacement = "工人阶层支持度不低于 %d%%" % percent
			result = result.replace(found.get_string(0), replacement)
	return result


static func _replace_tax_burden_text(text: String) -> String:
	var result := text
	var at_most := RegEx.new()
	if at_most.compile(
			"实测净税负\\s*(?:至多|<=|≤)\\s*([0-9]+(?:\\.[0-9]+)?)%"
			) == OK:
		for found in at_most.search_all(result):
			result = result.replace(found.get_string(0),
				"实际净纳税额不超过税前收入的 %s%%" % found.get_string(1))
	var zero := RegEx.new()
	if zero.compile("实测净税负\\s*=\\s*0") == OK:
		for found in zero.search_all(result):
			result = result.replace(found.get_string(0), "实际净纳税额为 0")
	return result


static func _replace_reserve_ratio_text(text: String) -> String:
	# `country.treasury_reserve_ratio_pct` is measured in percentage points.
	# Ramp.per is the effect fraction per one such point: per=0.01 => 1% per
	# point, while `excise` authors per=0.005 => 0.5% per point. Preserve that
	# authored rate and ceiling exactly.
	var result := text
	# Older summaries used "每档"; treat that word as one percentage point only
	# after normalizing it to the explicit reserve ratio metric.
	result = result.replace("国库储备率每档", "国库储备率每 1 档")
	var reserve := RegEx.new()
	if reserve.compile(
			"国库储备率每\\s*([0-9]+(?:\\.[0-9]+)?)\\s*档\\s*([^0-9+\\-（(]+?)\\s*([+\\-])\\s*([0-9]+(?:\\.[0-9]+)?)%\\s*[（(]\\s*(?:上限|最多)\\s*([+\\-])\\s*([0-9]+(?:\\.[0-9]+)?)%\\s*[）)]"
			) != OK:
		return result
	for found in reserve.search_all(result):
		var band := found.get_string(1)
		var label := found.get_string(2).strip_edges()
		var per_direction := "提高" if found.get_string(3) == "+" else "降低"
		var cap_direction := "提高" if found.get_string(5) == "+" else "降低"
		var replacement := "按“国库现金 ÷ 全国人口一年收入总额”计算，该比例每提高 %s 个百分点，%s%s %s%%（最多%s %s%%）" % [
			band, label, per_direction, found.get_string(4),
			cap_direction, found.get_string(6)]
		result = result.replace(found.get_string(0), replacement)
	var band_word := RegEx.new()
	if band_word.compile(
			"国库储备率每\\s*([0-9]+(?:\\.[0-9]+)?)\\s*档\\s*([^0-9+\\-（(]+?)\\s*([+\\-])\\s*([0-9]+(?:\\.[0-9]+)?)%"
			) == OK:
		for found in band_word.search_all(result):
			var replacement := "按“国库现金 ÷ 全国人口一年收入总额”计算，该比例每提高 %s 个百分点，%s%s %s%%" % [
				found.get_string(1), found.get_string(2).strip_edges(),
				"提高" if found.get_string(3) == "+" else "降低",
				found.get_string(4)]
			result = result.replace(found.get_string(0), replacement)
	return result


static func _replace_policy_floor_text(text: String) -> String:
	text = text.replace("民意对理念点获取的加成保底降低 10%",
		"理念点获取的民意加成下限降低 10 个百分点")
	var regex := RegEx.new()
	if regex.compile(
			"民意系数下限\\s*降低\\s*([0-9]+(?:\\.[0-9]+)?)%"
			) != OK:
		return text
	for found in regex.search_all(text):
		text = text.replace(found.get_string(0),
			"理念点获取的民意加成下限降低 %s 个百分点" % found.get_string(1))
	return text


static func _replace_domain_terms_text(text: String) -> String:
	text = text.replace("农业提高", "农业产出提高")
	text = text.replace("工业降低", "工业产出降低")
	text = text.replace("知识占比 至少 ", "以知识业为主且知识业占比至少 ")
	text = text.replace("知识占比至少", "以知识业为主且知识业占比至少")
	text = text.replace("知识占比 ≥", "知识业占比至少 ")
	text = text.replace("知识占比≥", "知识业占比至少 ")
	text = text.replace("非多元的工业支柱地块", "经济部门少于 3 个的工业支柱地块")
	text = text.replace("专精的粮作地块",
		"主导产出为小麦、稻米、玉米、马铃薯或谷物，且单一货物产出占当地全部产出至少 60% 的地块")
	text = text.replace("高度专精的农业支柱地块",
		"农业产出占当地总产出至少 50%，且单一货物产出占当地全部产出至少 80% 的地块")
	text = text.replace("高度专精地块",
		"单一货物产出占当地全部产出至少 80% 的地块")
	text = text.replace("多元地块", "当地至少有 3 个经济部门有产出的地块")
	text = text.replace("非多元地块", "当地至多有 2 个经济部门有产出的地块")
	text = text.replace("大邑地块", "人口至少 1200 的地块")
	text = text.replace("大邑周围", "人口至少 1200 的地块周围")
	text = text.replace("暑地繁市周围",
		"当地贸易事件至少达到 24 次的炎热地区地块周围")
	text = text.replace("寒地繁市周围",
		"当地贸易事件至少达到 24 次的寒冷地区地块周围")
	text = text.replace("繁市地块", "当地贸易事件至少达到 24 次的地块")
	text = text.replace("贸易繁荣的城市", "当地贸易事件至少达到 24 次的地块")
	text = text.replace("贸易繁荣的地块", "当地贸易事件至少达到 24 次的地块")
	text = text.replace("通衢路线", "交通路线")
	text = text.replace("名门地块", "显赫家族所在地块")
	text = text.replace("聚落地块", "人口至少 400 的地块")
	text = text.replace("工业支柱地块", "以工业为主的地块")
	text = text.replace("农业支柱地块", "以农业为主的地块")
	text = text.replace("知识支柱地块", "以知识业为主的地块")
	text = text.replace("能源支柱地块", "以能源业为主的地块")
	text = text.replace("矿业支柱地块", "以矿业为主的地块")
	text = text.replace("采掘业支柱地块", "以采掘业为主的地块")
	text = text.replace("有人居住的地块", "人口至少 400 的地块")
	text = text.replace("富饶的", "资源丰度至少 80% 的")
	text = text.replace("资源再生", "各类自然资源恢复速度")
	text = text.replace("管护再生", "自然恢复速度")
	text = text.replace("时农业提高", "时农业产出提高")
	text = text.replace("：工业降低", "：工业产出降低")
	text = text.replace("农业提高", "农业产出提高")
	text = text.replace("工业降低", "工业产出降低")
	text = text.replace("国库现金每相当于", "国库现金每增加相当于")
	text = text.replace("的地块的地块", "的地块")
	return text


static func _replace_signed_percent_text(text: String) -> String:
	text = text.replace("+0%", "").replace("-0%", "")
	var regex := RegEx.new()
	if regex.compile("([^+\\-])\\s*([+\\-])\\s*([0-9]+(?:\\.[0-9]+)?)%") != OK:
		return text
	for found in regex.search_all(text):
		var percent := float(found.get_string(3))
		if is_zero_approx(percent):
			text = text.replace(found.get_string(0), found.get_string(1))
			continue
		var direction := "提高" if found.get_string(2) == "+" else "降低"
		var replacement := "%s%s %s%%" % [found.get_string(1), direction,
			found.get_string(3)]
		text = text.replace(found.get_string(0), replacement)
	return text


static func _replace_percent_spacing(text: String) -> String:
	var regex := RegEx.new()
	if regex.compile("([0-9])%\\s+([\\x{4e00}-\\x{9fff}])") != OK:
		return text
	for found in regex.search_all(text):
		text = text.replace(found.get_string(0),
			"%s%%%s" % [found.get_string(1), found.get_string(2)])
	return text


static func _replace_known_resource_ids(text: String) -> String:
	# Ideology card views are sometimes built before EconomyFacade has registered
	# display names. Resolve the authoritative profile catalogs first; the small
	# table below is only a bootstrap fallback and for climate-profile IDs that
	# are not part of either registry.
	const CLIMATE_DISPLAY_NAMES := {
		"dryland_crop": "旱作作物",
		"paddy_crop": "水田作物",
	}
	var regex := RegEx.new()
	if regex.compile("(?<![a-z0-9_])([a-z][a-z0-9_]*)(?![a-z0-9_])") != OK:
		return text
	# Replace from the end so each match offset remains valid.
	var matches := regex.search_all(text)
	for index in range(matches.size() - 1, -1, -1):
		var found := matches[index]
		var stable_id := found.get_string(1)
		var display_name := _resource_display_name(stable_id, CLIMATE_DISPLAY_NAMES)
		if display_name.is_empty() or display_name == stable_id:
			continue
		text = text.substr(0, found.get_start()) + display_name \
			+ text.substr(found.get_end())
	return text


static func _resource_display_name(stable_id: String,
		climate_display_names: Dictionary) -> String:
	if climate_display_names.has(stable_id):
		return String(climate_display_names[stable_id])
	var good: Resource = GoodProfileRegistryScript.profile_by_id(stable_id)
	if good != null:
		var good_name := String(good.get("display_name")).strip_edges()
		if not good_name.is_empty():
			return good_name
	for resource_value in ResourceProfileRegistryScript.ordered():
		var resource: Resource = resource_value
		if resource == null or String(resource.get("id")) != stable_id:
			continue
		var resource_name := String(resource.get("display_name")).strip_edges()
		if not resource_name.is_empty():
			return resource_name
	return ""


static func _normalize_card_face_punctuation(text: String) -> String:
	# Keep one stable style across migrated and legacy rows. This deliberately
	# touches only spacing around the player-facing labels, not the stat values.
	text = text.replace(" 耗用", "耗用").replace(" 管护再生", "管护再生")
	text = text.replace(" 全国产出", "全国产出").replace(" 城市产出", "城市产出")
	text = text.replace(" 产出", "产出").replace(" 提升", "提升")
	text = text.replace("产出 提高", "产出提高").replace("产出 降低", "产出降低")
	text = text.replace("人口 至多", "人口至多").replace("人口 至少", "人口至少")
	text = text.replace("%的地块", "% 的地块")
	return text.strip_edges()


static func _collapse_colons(text: String) -> String:
	var out := text
	while out.contains("：："):
		out = out.replace("：：", "：")
	return out


static func _present_on_enter_effect(effect: Resource, modifier_catalog = null) -> String:
	if effect == null or not effect is IdeologyEffectCommandScript:
		return ""
	if effect.action == 1 and effect.opcode == 1 and modifier_catalog != null \
			and modifier_catalog.has_method("present_definition_for_ideology"):
		var lines: PackedStringArray = modifier_catalog.present_definition_for_ideology(
			effect.definition_key, int(effect.value_q16))
		if not lines.is_empty():
			var joined := "；".join(lines)
			if int(effect.duration_days) > 0:
				return "首次推行冲击（持续 %d 天）：%s" % [int(effect.duration_days), joined]
			return "首次推行时：%s" % joined
	# The only authored one-shot today is the native free-draw adapter. Keep the
	# mapping explicit so a future on-enter write cannot silently acquire a
	# player-facing promise the runtime does not implement.
	if effect.action == 6 and effect.domain == 6 and effect.opcode == 3:
		var count := int(effect.value_q16)
		if count == 1:
			return "首次达到化育等级时：免费获得 1 次理念抽取。该奖励只能领取一次。"
		if count > 1:
			return "首次达到化育等级时：免费获得 %d 次理念抽取。该奖励只能领取一次。" % count
	return ""
