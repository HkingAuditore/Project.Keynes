class_name NarrativeStateProbe
extends Resource

## 玩家国家的一个「持续状态」：条件成立并维持 dwell_days 天后，才允许为它预取 AI 事件。
##
## 状态永远由引擎判定（NarrativeCondition），AI 只负责写叙事与选项。
## 这条边界不能破：`NarrativeAiValidator` 会清空 AI 自带的 conditions，
## 因此状态探针是唯一能让 AI 事件「有触发条件」的合法通道。

const NarrativeConditionScript = preload("res://scripts/narrative/narrative_condition.gd")

@export var state_id: StringName = &""
@export var display_name: String = ""
## 给模型的状态描述（不含数值）。运行期数值由服务层拼进 state_hint。
@export var prompt_hint: String = ""
## 状态需要连续维持多少游戏日才值得预取一次 AI 事件。
@export var dwell_days: int = 7
## 同一格同一状态两次预取之间的冷却，防止反复烧 API。
@export var cooldown_days: int = 240
@export var min_era_index: int = 0
@export var max_era_index: int = 10
@export var conditions: Array[Resource] = []


func matches(cell_ctx: Dictionary) -> bool:
	if state_id == &"" or conditions.is_empty():
		return false
	var era_idx := int(cell_ctx.get("era_index", 0))
	if era_idx < min_era_index or era_idx > max_era_index:
		return false
	for cond in conditions:
		if cond == null or not cond.has_method("evaluate"):
			continue
		if not bool(cond.evaluate(cell_ctx)):
			return false
	return true


func to_dict() -> Dictionary:
	var conds: Array[Dictionary] = []
	for cond in conditions:
		if cond != null and cond.has_method("to_dict"):
			conds.append(cond.to_dict())
	return {
		"state_id": String(state_id),
		"display_name": display_name,
		"prompt_hint": prompt_hint,
		"dwell_days": dwell_days,
		"cooldown_days": cooldown_days,
		"min_era_index": min_era_index,
		"max_era_index": max_era_index,
		"conditions": conds,
	}


static func from_dict(d: Dictionary) -> NarrativeStateProbe:
	var probe := NarrativeStateProbe.new()
	if d.is_empty():
		return probe
	probe.state_id = StringName(String(d.get("state_id", "")))
	probe.display_name = String(d.get("display_name", ""))
	probe.prompt_hint = String(d.get("prompt_hint", ""))
	probe.dwell_days = maxi(0, int(d.get("dwell_days", 7)))
	probe.cooldown_days = maxi(0, int(d.get("cooldown_days", 240)))
	probe.min_era_index = clampi(int(d.get("min_era_index", 0)), 0, 10)
	probe.max_era_index = clampi(int(d.get("max_era_index", 10)), 0, 10)
	for raw in d.get("conditions", []):
		if raw is Dictionary:
			probe.conditions.append(NarrativeConditionScript.from_dict(raw))
		elif raw is Resource:
			probe.conditions.append(raw)
	return probe
