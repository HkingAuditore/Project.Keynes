extends RefCounted
class_name EraIndicatorViewModel

const Catalog = preload("res://scripts/economy/technology_catalog.gd")
var _eras: Array[Dictionary] = Catalog.public_era_metadata()
var _catalog: Dictionary = Catalog.compile_native_catalog()

func build_overview(country_facade, economy_facade, handle: int, ledger: EconomyGdpLedger) -> Dictionary:
	var model := {
		"country_name": "国家概况",
		"gdp": "—", "per_capita_gdp": "—", "territory": "—", "cpi": "—", "ppi": "—",
		"satisfaction": "—", "living_standard": "—", "alerts": [],
		"gdp_tooltip": "年度 GDP：本年累计产值",
		"per_capita_gdp_tooltip": "人均 GDP：年度 GDP ÷ 全国人口；与年度 GDP 同口径（读数前的金币图标即单位）。",
		"territory_tooltip": "领土：当前国家持有的有效地块数",
		"cpi_tooltip": "居民消费价格指数：食品、纺织与消费品按居民需求量加权的现价／成本锚；1.00× 表示等于成本锚。",
		"ppi_tooltip": "生产者价格指数：按有效生产供给量加权的现价／成本锚；1.00× 表示等于成本锚。",
		"satisfaction_tooltip": "人民平均满意度：全国人口加权的「综合满意度」（八维加权，按生存与基本生活封顶）；生存维度另见民生告警。",
		"living_standard_tooltip": "人民生活水平：按人口加权的生活水平等级均值（0 赤贫至 6 奢华）。",
	}
	if country_facade == null or handle == 0:
		return model
	# section_mask=0 只取国家摘要，不构建科技/贸易/税务工作区快照。
	var shell: Dictionary = country_facade.ui_snapshot(handle, 0)
	if bool(shell.get("ok", false)):
		var summary: Dictionary = shell.get("summary", {})
		model.country_name = String(summary.get("country_name", "国家概况"))
		model.territory = UITokens.format_compact_number_cn(float(summary.get("territory_count", 0)), 0)
	if ledger != null and ledger.ready():
		model.gdp = UITokens.format_compact_number_cn(ledger.national_ytd() / 10000.0, 2)
		var national_per_capita := ledger.national_per_capita()
		if not is_nan(national_per_capita) and national_per_capita >= 0.0:
			model.per_capita_gdp = UITokens.format_compact_number_cn(
				national_per_capita / 10000.0, 2)
	if economy_facade != null:
		var economy: Dictionary = economy_facade.country_economy_overview(handle, "summary")
		if bool(economy.get("ok", false)):
			var population := int(economy.get("population", 0))
			if bool(economy.get("consumer_price_index_valid", false)):
				model.cpi = _format_index(int(economy.get("consumer_price_index_q16", 0)))
			if bool(economy.get("producer_price_index_valid", false)):
				model.ppi = _format_index(int(economy.get("producer_price_index_q16", 0)))
			if population > 0:
				model.satisfaction = _format_percent(float(
					economy.get("satisfaction_q16", 0)) / 65536.0, 1)
			if bool(economy.get("living_standard_level_valid", false)):
				model.living_standard = _format_living_standard(
					int(economy.get("living_standard_level_q16", 0)))
			model.alerts = build_alerts(economy)
	return model


static func build_alerts(economy: Dictionary) -> Array[Dictionary]:
	var alerts: Array[Dictionary] = []
	var population := int(economy.get("population", 0))
	var unemployed := int(economy.get("unemployed", 0))
	if population > 0 and unemployed * 10 >= population:
		alerts.append(_alert("unemployment", "situation.unemployment", "失业率偏高",
			float(unemployed) / float(population), 0.10,
			"失业人口 ÷ 全国人口；触发线 10%。"))
	if population > 0 and int(economy.get("survival_satisfaction_q16", -1)) >= 0 \
			and int(economy.get("survival_satisfaction_q16", -1)) <= 49152:
		alerts.append(_alert("survival", "situation.food_shortage", "生存满意度不足",
			float(economy.get("survival_satisfaction_q16", 0)) / 65536.0, 0.75,
			"全国人口加权生存满意度；低于或等于 75% 时提示。"))
	if bool(economy.get("consumer_shortage_valid", false)):
		var shortage := int(economy.get("consumer_shortage_q16", 0))
		if shortage >= 16384:
			alerts.append(_alert("consumer_shortage", "situation.consumer_shortage",
				"纺织与消费品短缺", float(shortage) / 65536.0, 0.25,
				"纺织与消费品按居民需求量加权的短缺率；触发线 25%。"))
	if bool(economy.get("industrial_shortage_valid", false)):
		var shortage := int(economy.get("industrial_shortage_q16", 0))
		if shortage >= 16384:
			alerts.append(_alert("industrial_shortage", "situation.industry_shortage",
				"工业物资短缺", float(shortage) / 65536.0, 0.25,
				"生产物资按企业需求量加权的短缺率；触发线 25%。"))
	var job_capacity := int(economy.get("job_capacity", 0))
	var job_openings := int(economy.get("job_openings", 0))
	if job_capacity > 0 and job_openings * 10 >= job_capacity:
		alerts.append(_alert("vacancies", "situation.vacant_jobs", "岗位空缺严重",
			float(job_openings) / float(job_capacity), 0.10,
			"空缺岗位 ÷ 岗位容量；触发线 10%。"))
	return alerts


static func _alert(key: String, icon: String, label: String, ratio: float,
		threshold: float, method: String) -> Dictionary:
	return {
		"key": key, "icon": icon, "label": label,
		"value": _format_percent(ratio, 1),
		"tooltip": "%s：%s\n%s" % [label, _format_percent(ratio, 2), method],
		"threshold": _format_percent(threshold, 0),
	}


static func _format_index(q16: int) -> String:
	return "%.2f×" % (float(q16) / 65536.0)


static func _format_living_standard(q16: int) -> String:
	var level := clampf(float(q16) / 65536.0, 0.0, 6.0)
	var whole := clampi(int(floor(level + 0.5)), 0, 6)
	var names := ["赤贫", "挣扎", "贫困", "温饱", "小康", "富裕", "奢华"]
	return "%.2f级·%s" % [level, names[whole]]


static func _format_percent(ratio: float, digits: int) -> String:
	var number := String.num(ratio * 100.0, digits)
	if digits > 0:
		if not number.contains("."):
			number += "."
		var decimal_count := number.length() - number.find(".") - 1
		while decimal_count < digits:
			number += "0"
			decimal_count += 1
	return number + "%"

# 只读已提交快照：已生效（state 5）的最高时代令牌就是当前时代。
# 里程碑不再由玩家研究（时代改由「时代晋升」授予），所以这里不再读研究队列/进度；
# 纸徽的金色漫溢改由 apply_advancement() 的收购进度驱动。
func build(research: Dictionary) -> Dictionary:
	var states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
	if states.is_empty() or _eras.is_empty():
		return {}
	var milestones: PackedInt32Array = _catalog.get("technology_era_milestone_indices", PackedInt32Array())
	var current := 0
	for i in range(mini(milestones.size(), _eras.size())):
		var tech := int(milestones[i])
		if tech >= 0 and tech < states.size() and states[tech] >= 5:
			current = i
	return {"era_index": current, "era_id": String(_eras[current].id),
		"era_name": String(_eras[current].display_name)}


func era_id_for(index: int) -> String:
	return String(_eras[index].id) if index >= 0 and index < _eras.size() else ""


func era_name_for(index: int) -> String:
	return String(_eras[index].display_name) if index >= 0 and index < _eras.size() else ""


const GOODS_SCALE := 1000.0
const MONEY_SCALE := 10000.0
const STATUS_TEXT := {
	"locked": "条件未满足", "ready": "可以开始晋升", "purchasing": "正在补足晋升物资",
	"paused": "升级已暂停", "completing": "晋升确认中", "max": "已至最高时代",
}
const STATUS_CHIP := {
	"locked": "条件未满足", "ready": "可开始", "purchasing": "升级中",
	"paused": "已暂停", "completing": "已完成", "max": "已达最高时代",
}
const CONDITION_ICONS := {
	"tech": &"country.technology", "population": &"population.heart",
	"buildings": &"economy.building", "trade": &"economy.building.market",
}
const CONDITION_UNITS := {"tech": "项", "population": "人", "buildings": "座", "trade": "次"}
const CONDITION_GAP := {
	"tech": "差 %s 项本时代科技", "population": "差 %s 人口",
	"buildings": "差 %s 座建筑", "trade": "差 %s 次贸易",
}
const ERA_FLAVOR := {
	"stone": "火与石，部落的黎明", "agrarian": "禾黍盈仓，定居成邦",
	"kingdom": "王旗初立，城邑相望", "empire": "车同轨，书同文",
	"exploration": "帆指远洋，海图徐展", "enlightenment": "理性之光照彻长夜",
	"steam": "汽笛长鸣，机杼轰响", "electrical": "电光点亮万家灯火",
	"atomic": "原子之力，举世瞩目", "information": "比特如潮，天涯咫尺",
	"intelligent": "心智新生，万象更新",
}


static var _good_names: Dictionary = {}


static var _id_like := RegEx.create_from_string("^[A-Za-z0-9_ ]*$")


## 快照名称为空或形如内部 id（无经济门面时服务只给 id）时，回落到 GoodProfile.display_name。
static func _good_name(good_id: String, name: String) -> String:
	var trimmed := name.strip_edges()
	if not trimmed.is_empty() and _id_like.search(trimmed) == null:
		return trimmed
	if not _good_names.has(good_id):
		var path := "res://data/goods/%s.tres" % good_id
		var profile: Resource = load(path) if ResourceLoader.exists(path) else null
		var display := String(profile.get("display_name")) if profile != null else ""
		_good_names[good_id] = display if not display.is_empty() else good_id
	return String(_good_names[good_id])


static func era_flavor(era_id: String) -> String:
	return String(ERA_FLAVOR.get(era_id, "文明翻开新的一页"))


## 把 PlayerController.get_era_advancement_snapshot() 转成面板读数。
## 只做格式化与按钮决策；条件判定、成本与状态机都以快照为准，不在 UI 重算。
func present_advancement(snapshot: Dictionary) -> Dictionary:
	if not bool(snapshot.get("ok", false)):
		return {"ok": false, "status": "unavailable", "status_text": "时代晋升数据暂不可用",
			"action": {"kind": "none", "visible": false}}
	var current_index := int(snapshot.get("current_era_index", 0))
	var next_index := int(snapshot.get("next_era_index", -1))
	var status := String(snapshot.get("status", "locked"))
	if next_index < 0:
		status = "max"
	var current_name := String(snapshot.get("current_era_name", era_name_for(current_index)))
	var next_name := String(snapshot.get("next_era_name", era_name_for(next_index)))
	var conditions: Array[Dictionary] = []
	for raw in snapshot.get("conditions", []):
		var row: Dictionary = raw
		var current := float(row.get("current", 0))
		var target := float(row.get("target", 0))
		var key := String(row.get("key", ""))
		var text := String(row.get("text", ""))
		if text.is_empty():
			text = "%s / %s" % [UITokens.format_compact_number_cn(current, 1),
				UITokens.format_compact_number_cn(target, 1)]
		var value_text := "%s / %s" % [UITokens.format_compact_number_cn(current, 1),
			UITokens.format_compact_number_cn(target, 1)]
		if CONDITION_UNITS.has(key):
			value_text += " " + String(CONDITION_UNITS[key])
		conditions.append({
			"key": key, "label": String(row.get("label", key)), "text": text,
			"value_text": value_text, "current": current, "target": target,
			"tooltip": String(row.get("tooltip", "")),
			"met": bool(row.get("met", false)),
			"ratio": 1.0 if target <= 0.0 else clampf(current / target, 0.0, 1.0),
			"icon": CONDITION_ICONS.get(key, &"technology.milestone"),
		})
	var met := int(snapshot.get("conditions_met", 0))
	var required := maxi(1, int(snapshot.get("conditions_required", 2)))
	var costs: Array[Dictionary] = []
	for raw in snapshot.get("costs", []):
		var row: Dictionary = raw
		var need := float(row.get("required", 0)) / GOODS_SCALE
		var have := float(row.get("in_treasury", 0)) / GOODS_SCALE
		var ratio := float(row.get("ratio", have / need if need > 0.0 else 1.0))
		var good_id := String(row.get("good_id", ""))
		costs.append({
			"good_id": good_id, "icon": IconCatalog.good_semantic(good_id),
			"name": _good_name(good_id, String(row.get("name", ""))),
			"required_text": UITokens.format_compact_number_cn(need, 1),
			"stock_text": UITokens.format_compact_number_cn(minf(have, need), 1),
			"value_text": "%s / %s" % [UITokens.format_compact_number_cn(minf(have, need), 1),
				UITokens.format_compact_number_cn(need, 1)],
			"ratio": clampf(ratio, 0.0, 1.0), "done": ratio >= 1.0,
		})
	var frozen := int(snapshot.get("frozen_territory_count", 0))
	var territory := int(snapshot.get("territory_count", 0))
	var territory_note := ""
	if frozen > 0:
		territory_note = "按 %d 个地块计价" % frozen
	elif territory > 0:
		territory_note = "按当前 %d 个地块预估 · 开始后冻结" % territory
	var budget: Dictionary = snapshot.get("budget", {})
	var share_bp := int(budget.get("treasury_share_bp", 0))
	var progress := clampf(float(snapshot.get("progress", 0.0)), 0.0, 1.0)
	# 进度百分比只在标题行的状态 chip 上写一次；环是同一件事的图形表达。
	var chip := String(STATUS_CHIP.get(status, status))
	if status in ["purchasing", "paused", "completing"]:
		chip += " %d%%" % int(floor(progress * 100.0))
	var delta := delta_hint(status, conditions, met, required)
	var action := _advancement_action(status, bool(snapshot.get("can_start", false)),
		frozen if frozen > 0 else territory)
	if String(action.get("kind", "")) == "start" and bool(action.get("disabled", false)):
		action["tooltip"] = delta if not delta.is_empty() else chip
	return {
		"ok": true, "status": status,
		"status_text": String(STATUS_TEXT.get(status, status)),
		"status_chip": chip, "delta_hint": delta,
		"current": {"index": current_index, "id": era_id_for(current_index), "name": current_name},
		"next": {} if next_index < 0 else {"index": next_index, "id": era_id_for(next_index),
			"name": next_name},
		"conditions": conditions, "conditions_met": met, "conditions_required": required,
		"conditions_text": "已满足 %d/%d" % [mini(met, required), required],
		"costs": costs, "territory_note": territory_note,
		"progress": progress, "progress_text": "%d%%" % int(floor(progress * 100.0)),
		"budget_enabled": share_bp > 0,
		"era_daily": float(budget.get("era_daily", 0)) / MONEY_SCALE,
		"national_daily": float(budget.get("national_daily", 0)) / MONEY_SCALE,
		"treasury_share_text": "%.1f%%" % (float(share_bp) / 100.0),
		"buffs": PackedStringArray(snapshot.get("buffs_preview", PackedStringArray())),
		"action": action,
	}


## 未满足时只说还缺什么：差 1 项时点名最接近达成的那一项。
static func delta_hint(status: String, conditions: Array, met: int, required: int) -> String:
	if status != "locked":
		return ""
	var missing := required - met
	if missing > 1:
		return "还差 %d 项条件" % missing
	if missing < 1:
		return ""
	var best: Dictionary = {}
	for row: Dictionary in conditions:
		if bool(row.get("met", false)) or not CONDITION_GAP.has(String(row.get("key", ""))):
			continue
		if best.is_empty() or float(row.get("ratio", 0.0)) > float(best.get("ratio", 0.0)):
			best = row
	if best.is_empty():
		return "还差 1 项条件"
	var gap := maxf(1.0, ceilf(float(best.get("target", 0.0)) - float(best.get("current", 0.0))))
	return String(CONDITION_GAP[String(best.key)]) % UITokens.format_compact_number_cn(gap, 1)


static func _advancement_action(status: String, can_start: bool, territory: int) -> Dictionary:
	match status:
		"ready", "locked":
			var enabled := can_start and status == "ready"
			return {"kind": "start", "visible": true, "text": "开始晋升",
				"command": &"era.advance.start", "disabled": not enabled,
				"tooltip": "锁定当前 %d 个地块的物资需求，按国家购买预算逐日补足。" % territory if enabled
					else ""}
		"purchasing":
			return {"kind": "pause", "visible": true, "text": "暂停升级",
				"command": &"era.advance.pause", "disabled": false,
				"tooltip": "暂停后不再动用国库现金；已备好的物资保留在国库。"}
		"paused":
			return {"kind": "resume", "visible": true, "text": "继续升级",
				"command": &"era.advance.resume", "disabled": false,
				"tooltip": "按锁定的需求继续补足剩余物资。"}
		"completing":
			return {"kind": "completing", "visible": true, "text": "晋升中…",
				"command": &"", "disabled": true, "tooltip": "物资已齐，正在等待国家确认晋升。"}
	return {"kind": "none", "visible": false, "text": "", "command": &"", "disabled": true,
		"tooltip": ""}
