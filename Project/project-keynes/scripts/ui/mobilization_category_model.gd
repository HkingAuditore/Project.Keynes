class_name MobilizationCategoryModel
extends RefCounted

## 阶层组织（民情）读数的展示层换算。地块档案不再单列「民情」页签：
## 每个阶层的组织阶段直接挂在人口页的阶层行上，只有进入示威 / 叛乱时
## 才在页首加一条警示。Q16 只在这里换算成比例与文案。

const STAGE_LABELS := ["平息", "不满", "抗议", "示威", "叛乱"]
## 阶梯只画会升级的四级；「平息」是阶梯的零点。
const LADDER_STEPS := 4
const PROFESSION_NAMES := {
	"soldier": "军士", "farmer": "农户", "subsistence_farmer": "小农",
	"tenant_farmer": "佃户", "sharecropper": "分成佃农",
	"agricultural_worker": "农工", "artisan": "匠户",
	"apprentice": "学徒", "journeyman": "帮工", "guild_master": "行会师傅",
	"miner": "矿工", "industrial_worker": "工厂工人", "worker": "工人",
	"merchant": "商人", "scholar": "读书人", "scribe": "书吏",
	"serf": "农奴", "unemployed": "失业者", "landlord": "地主",
	"industrialist": "厂主",
}


## 本格各阶层的组织状态，按职业稳定 id 索引。读不到或没有组织活动时返回空字典，
## 调用方据此整段不渲染。
static func by_profession(economy_facade, cell_idx: int) -> Dictionary:
	var out := {}
	if economy_facade == null or cell_idx < 0 or not economy_facade.has_method(
			"cell_mobilization_snapshot"):
		return out
	var snapshot: Dictionary = economy_facade.cell_mobilization_snapshot(cell_idx)
	if not bool(snapshot.get("ok", false)):
		return out
	var rows: Array = snapshot.get("rows", [])
	if rows.is_empty():
		return out
	var ids: PackedStringArray = economy_facade.profession_ids() \
		if economy_facade.has_method("profession_ids") else PackedStringArray()
	for raw in rows:
		var row: Dictionary = raw
		var profession := int(row.get("profession", -1))
		if profession < 0 or profession >= ids.size():
			continue
		var stage := clampi(int(row.get("stage", 0)), 0, 4)
		var org := clampf(float(clampi(int(row.get("mobilization_q16", 0)), 0, 65536))
			/ 65536.0, 0.0, 1.0)
		var key := String(ids[profession])
		# 同一职业理论上每格一行；若出现重复取更激烈的一行。
		if out.has(key) and int((out[key] as Dictionary).get("stage", 0)) > stage:
			continue
		out[key] = {
			"stage": stage,
			"stage_label": STAGE_LABELS[stage],
			"organization": org,
			"organization_text": "%d%%" % int(round(org * 100.0)),
			"accent": stage_accent(stage),
			"tooltip": _tooltip(stage, org),
		}
	return out


static func stage_accent(stage: int) -> Color:
	if stage >= 3:
		return UITokens.RISK
	if stage >= 1:
		return UITokens.WARN
	return UITokens.ACCENT


static func _tooltip(stage: int, org: float) -> String:
	var ladder := PackedStringArray()
	for i in range(STAGE_LABELS.size()):
		ladder.append("【%s】" % STAGE_LABELS[i] if i == stage else STAGE_LABELS[i])
	var lines := PackedStringArray([
		"组织阶段：%s" % "、".join(ladder),
		"组织度 %d%%：越高越容易升级到下一阶段。" % int(round(org * 100.0)),
	])
	if stage >= 3:
		lines.append("若继续恶化，此地可能脱离本国。")
	elif stage >= 1:
		lines.append("改善这一阶层的生活水平与满意度可让组织逐渐平息。")
	return "\n".join(lines)


## 页首警示：只在有阶层进入示威 / 叛乱时给一条，点名最激烈的阶层。
static func escalation_insight(names_by_stage: Dictionary) -> Dictionary:
	for stage in [4, 3]:
		var names: PackedStringArray = names_by_stage.get(stage, PackedStringArray())
		if names.is_empty():
			continue
		return {"id": "mobilization_warning",
			"text": "%s已%s；若继续恶化，此地可能脱离本国。" % [
				"、".join(names), "起事叛乱" if stage == 4 else "上街示威"],
			"icon": "status.warning", "accent": UITokens.RISK}
	return {}


static func profession_label(economy_facade, profession: int) -> String:
	if economy_facade == null:
		return "阶层"
	var ids: PackedStringArray = economy_facade.profession_ids()
	if profession < 0 or profession >= ids.size():
		return "阶层"
	var key := String(ids[profession])
	return String(PROFESSION_NAMES.get(key, key))


## Count of owned cells at 示威/叛乱 for the top-bar badge. 0 means hide it.
static func unrest_count(economy_facade, country_handle: int) -> int:
	if economy_facade == null or not economy_facade.has_method(
			"country_mobilization_summary"):
		return 0
	var slot := int(country_handle & 0xFFFFFFFF) - 1
	if slot < 0:
		return 0
	var summary: Dictionary = economy_facade.country_mobilization_summary(slot)
	if not bool(summary.get("ok", false)):
		return 0
	var counts: PackedInt32Array = summary.get(
		"stage_counts", PackedInt32Array())
	if counts.size() < 5:
		return 0
	return int(counts[3]) + int(counts[4])
