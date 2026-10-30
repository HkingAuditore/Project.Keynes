extends RefCounted
class_name HudStatusViewModel

## 顶栏纸签的悬浮卡模型：国库看「当日收支结构」，人口看「职业构成与各职业福祉」。
##
## 数据只读已提交快照，不新增原生查询口径：
## - 收支复用 `EconomyDossierViewModel.build_cashflow()`，与「国家经济 · 总览」的
##   构成条/明细是同一份口径，玩家点进去看到的数字与悬浮卡一致；
## - 人口按「职业」逐项列出（采集者、矿工、工匠、猎人……）而不是先并成少数社会
##   阶层：顶栏要回答的是「谁、有多少人、过得如何」，粒度粗到「产业工人」就丢掉
##   了玩家真正会去关心的职业差异。排序按人口降序，尾部并为「其他职业」；
## - 生活档来自原生 population-weighted `living_standard_level_q16`，这里只做
##   0..6 的命名与图标映射，不在 GDScript 里重算档位阈值；
## - 金额只给数值本体：货币单位由纸贴金币图标承担（见 MoneyDisplay），卡里任何
##   文案都不再写「¥」，避免和金币图标重复。

const Q16 := 65536.0
const MONEY_SCALE := 10000.0
## 悬浮卡只列人口最多的前几项；其余并成「其他职业」，构成条仍覆盖全国人口。
const MAX_ROWS := 5
const LIVING_NAMES: Array[String] = ["赤贫", "挣扎", "贫困", "温饱", "小康", "富裕", "奢华"]
## 与 LIVING_NAMES 同序的纸贴图标；等级 → 图标只在视图模型里映射一次。
const LIVING_ICONS: Array[String] = ["population.living.destitute",
	"population.living.struggling", "population.living.poor",
	"population.living.secure", "population.living.comfortable",
	"population.living.affluent", "population.living.luxury"]
## 名次色板：人口越多颜色越深，构成条与行色签一一对应。
const ROW_COLORS: Array[Color] = [
	Color(0.34, 0.48, 0.31, 1.0),
	Color(0.31, 0.43, 0.53, 1.0),
	Color(0.62, 0.36, 0.19, 1.0),
	Color(0.69, 0.49, 0.24, 1.0),
	Color(0.55, 0.19, 0.13, 1.0),
]
const OTHER_ROW_COLOR := Color(0.47, 0.37, 0.27, 1.0)
const OTHER_ROW_NAME := "其他职业"


static func build_treasury(cash_valid: bool, cash: int, fiscal: Dictionary) -> Dictionary:
	var flow: Dictionary = EconomyDossierViewModel.build_cashflow(fiscal)
	var model := {
		"kind": "treasury",
		"title": "国库",
		"icon": "metric.treasury",
		"value": _money_text(float(cash) / MONEY_SCALE) if cash_valid else "—",
		## 国库读数与净额都是货币：卡片据此在数值左边放金币图标（见 MoneyDisplay）。
		"value_money": cash_valid,
		"meta": "",
		"ok": false,
		"note": "",
		"income_bar": {},
		"expense_bar": {},
		"net_text": "",
		"net_positive": true,
		"footer": "点击查看国家经济 · 总览",
	}
	if not bool(flow.get("ok", false)):
		model["note"] = "本日结算尚未发布，收支明细稍后可见。"
		return model
	model["ok"] = true
	model["meta"] = String(flow.get("day_text", ""))
	var income_segments: Array = flow.get("income_segments", [])
	var expense_segments: Array = flow.get("expense_segments", [])
	if income_segments.is_empty() and expense_segments.is_empty():
		model["note"] = "本日没有税收入账，也没有补贴或科研采购支出。"
	model["income_bar"] = {
		"title": "收入构成", "total": String(flow.get("income_text", "0")),
		"segments": _money_segments(income_segments),
	}
	model["expense_bar"] = {
		"title": "支出构成", "total": String(flow.get("expense_text", "0")),
		"segments": _money_segments(expense_segments),
	}
	model["net_text"] = MoneyDisplay.strip_unit(String(flow.get("net_text", "0")))
	model["net_positive"] = bool(flow.get("net_positive", true))
	return model


static func build_population(professions: Dictionary, summary: Dictionary) -> Dictionary:
	var model := {
		"kind": "population",
		"title": "人口",
		"icon": "population.heart",
		"value": "—",
		## 人口是人数不是金额：卡片不在这张纸签的读数前放金币图标。
		"value_money": false,
		"meta": "",
		"ok": false,
		"note": "",
		"share_bar": {},
		"rows": [],
		"footer": "点击查看国家经济 · 阶层民生",
	}
	if not bool(professions.get("ok", false)):
		model["note"] = String(professions.get("reason", "人口快照暂不可用"))
		return model
	var stable_ids: PackedStringArray = professions.get(
		"profession_stable_ids", PackedStringArray())
	var names: PackedStringArray = professions.get("profession_display_names", stable_ids)
	var population = professions.get("population", PackedInt64Array())
	var satisfaction = professions.get("satisfaction_q16", PackedInt32Array())
	var living = professions.get("living_standard_level_q16", PackedInt32Array())
	var entries: Array = []
	for row in range(stable_ids.size()):
		var people := float(_at(population, row))
		if people <= 0.0:
			continue
		var stable_id := String(stable_ids[row])
		entries.append({
			"id": stable_id,
			"name": String(names[row]) if row < names.size() else stable_id,
			"icon": "profession." + stable_id,
			"population": people,
			"satisfaction": clampf(_at(satisfaction, row), 0.0, Q16) / Q16,
			"living": _at(living, row) / Q16,
		})
	if entries.is_empty():
		model["note"] = "当前还没有人口。"
		return model
	entries.sort_custom(func(a, b): return float(a.population) > float(b.population))
	var total := 0.0
	for entry in entries:
		total += float(entry.population)
	var rows: Array = []
	for index in range(mini(MAX_ROWS, entries.size())):
		rows.append(_population_row(entries[index], total, false,
			ROW_COLORS[index % ROW_COLORS.size()]))
	if entries.size() > MAX_ROWS:
		var folded_population := 0.0
		var folded_satisfaction := 0.0
		var folded_living := 0.0
		for index in range(MAX_ROWS, entries.size()):
			var entry: Dictionary = entries[index]
			var people := float(entry.population)
			folded_population += people
			folded_satisfaction += float(entry.satisfaction) * people
			folded_living += float(entry.living) * people
		if folded_population > 0.0:
			rows.append(_population_row({
				"id": "other",
				"name": OTHER_ROW_NAME,
				"icon": "population.heart",
				"population": folded_population,
				"satisfaction": folded_satisfaction / folded_population,
				"living": folded_living / folded_population,
			}, total, true, OTHER_ROW_COLOR))
	var segments: Array = []
	for row in rows:
		segments.append({
			"label": String(row.name),
			"value": float(row.population),
			"text": String(row.share_text),
			"color": row.color,
		})
	model["ok"] = true
	model["value"] = UITokens.format_compact_number_cn(total, 0)
	model["meta"] = _satisfaction_meta(summary)
	model["share_bar"] = {"segments": segments}
	model["rows"] = rows
	return model


static func _population_row(entry: Dictionary, total: float, folded: bool,
		color: Color) -> Dictionary:
	var people := float(entry.population)
	var share := people / total if total > 0.0 else 0.0
	var satisfaction := clampf(float(entry.satisfaction), 0.0, 1.0)
	var living := float(entry.living)
	var living_level := clampi(roundi(living), 0, LIVING_NAMES.size() - 1)
	return {
		"id": String(entry.id),
		"name": String(entry.name),
		"icon": String(entry.icon),
		"color": color,
		"folded": folded,
		"population": people,
		"population_text": UITokens.format_compact_number_cn(people, 0),
		"share_text": _share_text(share),
		"satisfaction": satisfaction,
		"satisfaction_text": "%d%%" % roundi(satisfaction * 100.0),
		"satisfaction_color": _satisfaction_color(satisfaction),
		"living": living,
		"living_level": living_level,
		"living_text": LIVING_NAMES[living_level],
		"living_icon": LIVING_ICONS[living_level],
	}


static func _share_text(share: float) -> String:
	return "%.1f%%" % (share * 100.0) if share < 0.1 else "%d%%" % roundi(share * 100.0)


static func _satisfaction_color(satisfaction: float) -> Color:
	if satisfaction >= 0.75:
		return UITokens.DOSSIER_VERDIGRIS
	if satisfaction >= 0.5:
		return UITokens.DOSSIER_BRASS
	return UITokens.DOSSIER_OXBLOOD


static func _satisfaction_meta(summary: Dictionary) -> String:
	if summary.is_empty() or not bool(summary.get("ok", false)):
		return ""
	if int(summary.get("population", 0)) <= 0:
		return ""
	return "满意度 %d%%" % roundi(float(summary.get("satisfaction_q16", 0)) / Q16 * 100.0)


## 金额只出数字：单位由悬浮卡读数左边那枚金币图标承担（见 MoneyDisplay）。
static func _money_text(value: float) -> String:
	return UITokens.format_compact_number_cn(value, 2)


## 构成段的数值同样只剩数字；图标由 DossierStackedBar 的 money_icon 开关统一画，
## 这样右侧总额与各段读数用的是同一枚金币，不会一段带符号一段不带。
static func _money_segments(segments: Array) -> Array:
	var out: Array = []
	for raw in segments:
		out.append((raw as Dictionary).duplicate())
	return out


static func _at(values, index: int) -> float:
	if values == null or index < 0 or index >= values.size():
		return 0.0
	return float(values[index])
