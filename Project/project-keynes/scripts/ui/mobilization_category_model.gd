class_name MobilizationCategoryModel
extends RefCounted

## Builds the "民情" inspector category from the committed sparse
## mobilization rows. Kept out of CellInspectorViewModel so the already
## over-limit view-model file does not grow.

const STAGE_LABELS := ["平息", "不满", "抗议", "示威", "叛乱"]
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


static func build(economy_facade, cell_idx: int) -> Dictionary:
	if economy_facade == null or not economy_facade.has_method(
			"cell_mobilization_snapshot"):
		return {"insights": [{"id": "mobilization_unavailable",
			"text": "民情数据暂不可用", "icon": "status.warning",
			"accent": UITokens.ARCHIVE_INK_MUTED}]}
	var snapshot: Dictionary = economy_facade.cell_mobilization_snapshot(cell_idx)
	if not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "mobilization_unavailable",
			"text": "民情数据暂不可用", "icon": "status.warning",
			"accent": UITokens.ARCHIVE_INK_MUTED}]}
	var rows: Array = snapshot.get("rows", [])
	if rows.is_empty():
		return {"insights": [{"id": "mobilization_calm",
			"text": "本格各阶层暂时没有成形的组织活动。",
			"icon": "status.ok", "accent": UITokens.ARCHIVE_INK_MUTED}]}
	var gauges: Array = []
	var highest_stage := 0
	var highest_org := 0
	var lowest_local_sat := 65536
	for raw in rows:
		var row: Dictionary = raw
		var profession := int(row.get("profession", -1))
		var stage := clampi(int(row.get("stage", 0)), 0, 4)
		var org := clampi(int(row.get("mobilization_q16", 0)), 0, 65535)
		var local_sat := clampi(int(row.get("local_sat_q16", 65536)), 0, 65536)
		highest_stage = maxi(highest_stage, stage)
		highest_org = maxi(highest_org, org)
		lowest_local_sat = mini(lowest_local_sat, local_sat)
		var accent: Color = UITokens.RISK if stage >= 3 else (
			UITokens.GOOD if stage == 2 else UITokens.ACCENT)
		gauges.append({
			"id": "mobilization_%d" % profession,
			"label": "%s · %s" % [profession_label(economy_facade, profession),
				STAGE_LABELS[stage]],
			"value": clampf(float(org) / 65536.0, 0.0, 1.0),
			"value_text": "%d%%" % int(round(float(org) * 100.0 / 65536.0)),
			"accent": accent,
		})
	var metrics: Array = [
		{"id": "mobilization_stage", "title": "最高阶段",
			"value": STAGE_LABELS[highest_stage],
			"subtitle": "%d 个阶层有组织活动" % rows.size(),
			"accent": UITokens.RISK if highest_stage >= 3 else UITokens.ACCENT,
			"icon": "warning"},
		{"id": "mobilization_org", "title": "最高组织度",
			"value": "%d%%" % int(round(float(highest_org) * 100.0 / 65536.0)),
			"subtitle": "", "accent": UITokens.ACCENT, "icon": "status.warning"},
		{"id": "mobilization_local_sat", "title": "其余阶层满意度",
			"value": "%d%%" % int(round(float(lowest_local_sat) * 100.0 / 65536.0)),
			"subtitle": "不含起事阶层", "accent": UITokens.ACCENT,
			"icon": "growth"},
	]
	var insights: Array = []
	if highest_stage >= 3:
		insights.append({"id": "mobilization_warning",
			"text": "此地已进入%s阶段；若继续恶化，可能脱离本国。"
				% STAGE_LABELS[highest_stage],
			"icon": "status.warning", "accent": UITokens.RISK})
	return {"metrics": metrics, "gauges": gauges, "insights": insights}


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
