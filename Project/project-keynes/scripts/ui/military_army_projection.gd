extends RefCounted

## Formats active army and logistics reports.


static func armies_model(owner: MilitaryViewModel, selected: int) -> Dictionary:
	var rows: Array = []
	var selected_handle := 0
	for raw in owner._armies:
		var row := owner.army_row(MilitaryViewModel._as_dict(raw))
		rows.append(row)
		if int(row.handle) == selected:
			selected_handle = int(row.handle)
	if selected_handle == 0 and not rows.is_empty():
		selected_handle = int((rows[0] as Dictionary).get("handle", 0))
	var spend := owner.spend_breakdown()
	return {
		"ok": true,
		"rows": rows,
		"selected": selected_handle,
		"convoys": owner.convoy_rows(MilitaryViewModel._as_array(owner._snapshot.get("convoys", null))),
		"spend": spend.segments,
		"spend_total": MilitaryViewModel._money_text(spend.total_raw),
		"procurement_text": owner._procurement_share_text(),
	}


## 快照没有采购占比时留空，由 UI 整行隐藏；不写一个看起来像真读数的缺省值。
static func _procurement_share_text(owner: MilitaryViewModel) -> String:
	if not owner._snapshot.has("procurement_share_bp"):
		return ""
	return "军需占军费 %s" % MilitaryViewModel._bp(int(owner._snapshot.get("procurement_share_bp", 0)))



static func army_row(owner: MilitaryViewModel, army: Dictionary) -> Dictionary:
	var morale := MilitaryViewModel._ratio(army.get("morale_q16", MilitaryViewModel.Q16))
	var supply := MilitaryViewModel._ratio(army.get("supply_ratio_q16", MilitaryViewModel.Q16))
	var warnings := owner.army_warnings(army)
	return {
		"handle": int(army.get("handle", 0)),
		"name": owner.army_name(army),
		"cell": int(army.get("cell", -1)),
		"cell_text": owner.cell_name(int(army.get("cell", -1))),
		"headcount": int(army.get("headcount", 0)),
		"attack": MilitaryViewModel._raw_q16(army.get("attack_q16", 0)),
		"defense": MilitaryViewModel._raw_q16(army.get("defense_q16", 0)),
		"morale": morale,
		"supply": supply,
		"mission": owner._mission_text(army),
		"warning": ", ".join(warnings.map(func(w): return String(w.label))),
		"critical": warnings.any(func(w): return String(w.tone) == "risk"),
	}


## Flag thresholds mirror get_military_render_snapshot (military-runtime.md §9).
static func army_warnings(owner: MilitaryViewModel, army: Dictionary) -> Array:
	var warnings: Array = []
	if int(army.get("engagement", -1)) >= 0:
		warnings.append({"label": "交战中", "tone": "risk"})
	if MilitaryViewModel._ratio(army.get("ration_ratio_q16", MilitaryViewModel.Q16)) < 0.25:
		warnings.append({"label": "缺粮", "tone": "risk"})
	elif MilitaryViewModel._ratio(army.get("supply_ratio_q16", MilitaryViewModel.Q16)) < 0.5:
		warnings.append({"label": "补给低", "tone": "warn"})
	if MilitaryViewModel._ratio(army.get("pay_ratio_q16", MilitaryViewModel.Q16)) < 0.6:
		warnings.append({"label": "欠饷", "tone": "risk"})
	if MilitaryViewModel._ratio(army.get("morale_q16", MilitaryViewModel.Q16)) < 0.4:
		warnings.append({"label": "士气低", "tone": "warn"})
	return warnings


## `detail` is a get_military_army() dictionary (composition, supply_days, convoys);
## the list row is used as-is when the facade cannot provide it.
## `prefetched` lets the dossier page skip a second facade.army() round trip.
static func army_detail(owner: MilitaryViewModel, army: Dictionary, prefetched: Dictionary = {}) -> Dictionary:
	var detail := prefetched if not prefetched.is_empty() else army
	if prefetched.is_empty() and owner._facade != null and owner._facade.has_method("army"):
		var fetched = owner._facade.call("army", int(army.get("handle", 0)))
		if fetched is Dictionary and bool(fetched.get("ok", false)):
			detail = fetched
	var lots: Array = []
	var heads := maxf(1.0, float(detail.get("headcount", 0)))
	for raw in MilitaryViewModel._as_array(detail.get("composition", null)):
		var lot := MilitaryViewModel._as_dict(raw)
		var unit := int(lot.get("unit", -1))
		var quality := clampi(int(round(float(lot.get("quality_q8", 256)) / MilitaryViewModel.Q8)), 1, 5)
		lots.append({"id": unit * 10 + quality, "label": "%s %s" % [owner.unit_name(unit), MilitaryViewModel.QUALITY_NAMES[quality]],
			"icon": String(owner.unit_icon(unit)), "value": float(lot.get("count", 0)) / heads,
			"text": MilitaryViewModel._count(lot.get("count", 0)), "color": owner.class_color(unit)})
	var supply: Array = []
	var days = detail.get("supply_days", null)
	if days is PackedInt64Array or days is Array:
		for index in range(mini(days.size(), MilitaryViewModel.SUPPLY_CLASSES.size())):
			var value := float(days[index])
			var label := String(MilitaryViewModel.SUPPLY_CLASSES[index].label)
			if index == 3 and value <= 0.0:
				continue
			supply.append({"id": index, "label": label, "icon": MilitaryViewModel.SUPPLY_CLASSES[index].icon,
				"value": clampf(value / MilitaryViewModel.SUPPLY_HORIZON_DAYS, 0.0, 1.0),
				"text": "%d 日" % int(value), "marker": 7.0 / MilitaryViewModel.SUPPLY_HORIZON_DAYS,
				"color": UITokens.DOSSIER_OXBLOOD if value < 3.0 else (UITokens.DOSSIER_BRASS
					if value < 7.0 else UITokens.DOSSIER_VERDIGRIS),
				"tooltip": "%s 可支撑 %d 日" % [label, int(value)]})
	return {
		"handle": int(army.get("handle", 0)),
		"name": owner.army_name(army),
		"meta": "%s · %s · %s" % [owner.cell_name(int(detail.get("cell", -1))),
			String(MilitaryViewModel.STANCE_LABELS.get(int(detail.get("stance", 0)), "固守")), owner._mission_text(detail)],
		"cell": int(detail.get("cell", -1)),
		"lots": lots,
		"supply": supply,
		"warnings": owner.army_warnings(detail),
	}



static func _mission_text(owner: MilitaryViewModel, army: Dictionary) -> String:
	var exploration_text := owner._exploration_status_text(army)
	if not exploration_text.is_empty():
		return exploration_text
	var mission := int(army.get("mission", 0))
	# A cancelled row can still be attached to the snapshot until the next
	# order retires it. Never let that history row masquerade as a live mission.
	if mission == 3:
		return "待命"
	var label := String(MilitaryViewModel.MISSION_LABELS.get(mission, "待命"))
	var target := int(army.get("target_cell", -1))
	return "%s → %s" % [label, owner.cell_name(target)] if target >= 0 else label


## A cancelled/replaced task is history, not a mission state. Completed and
## failed rows remain visible until the next player order retires them.
static func _exploration_state(owner: MilitaryViewModel, army: Dictionary) -> Dictionary:
	var raw = army.get("exploration", null)
	if not raw is Dictionary or (raw as Dictionary).is_empty():
		return {}
	var data := raw as Dictionary
	if int(data.get("result", MilitaryViewModel.EXPLORATION_RESULT_NONE)) == MilitaryViewModel.EXPLORATION_RESULT_CANCELLED:
		return {}
	return data



static func _exploration_status_text(owner: MilitaryViewModel, army: Dictionary) -> String:
	var data := owner._exploration_state(army)
	if data.is_empty():
		return ""
	var selected := maxi(0, int(data.get("selected", 0)))
	var resolved := clampi(int(data.get("resolved", 0)), 0, selected)
	var blocked := maxi(0, int(data.get("blocked", 0)))
	var phase := int(data.get("phase", MilitaryViewModel.EXPLORATION_PHASE_ACTIVE))
	var result := int(data.get("result", MilitaryViewModel.EXPLORATION_RESULT_NONE))
	match phase:
		MilitaryViewModel.EXPLORATION_PHASE_ACTIVE:
			return "探路 %d/%d" % [resolved, selected]
		MilitaryViewModel.EXPLORATION_PHASE_RETURNING:
			return "探路 %d/%d · 返程中" % [resolved, selected]
		MilitaryViewModel.EXPLORATION_PHASE_PAUSED_BATTLE:
			return "探路暂停 · 交战中"
		MilitaryViewModel.EXPLORATION_PHASE_COMPLETE:
			if result == MilitaryViewModel.EXPLORATION_RESULT_SEEN_WITH_UNOBSERVABLE and blocked > 0:
				return "探查结束 · %d 格无法探明 · 已返回" % blocked
			return "探路完成 · 已返回"
		MilitaryViewModel.EXPLORATION_PHASE_FAILED_NO_RETURN:
			return "探路完成 · 无法返回 · 原地待命"
	return ""



static func _exploration_has_live_order(owner: MilitaryViewModel, army: Dictionary) -> bool:
	var data := owner._exploration_state(army)
	if data.is_empty():
		return false
	var phase := int(data.get("phase", MilitaryViewModel.EXPLORATION_PHASE_ACTIVE))
	return phase == MilitaryViewModel.EXPLORATION_PHASE_ACTIVE or phase == MilitaryViewModel.EXPLORATION_PHASE_RETURNING \
		or phase == MilitaryViewModel.EXPLORATION_PHASE_PAUSED_BATTLE


## ── 军务档案（右栏页面，见 docs/ui/military-dossier.md）─────────────────
## 部队档案：KPI 4 格 + 编成 + 补给 + 战备环 + 徽记 + 同格名录。
## `same_cell` 是渲染快照里同格的部队行（{handle, owner_slot, headcount}）。
static func army_dossier(owner: MilitaryViewModel, handle: int, same_cell: Array = []) -> Dictionary:
	return MilitaryViewModel.MilitaryDossiers.army_dossier(owner, handle, same_cell)


## 战线档案：双方在同一组指标上并排对比 + 交战段名录。
## 扇区由 MilitaryMapLayers.front_sector() 聚合；每侧的攻击/防御/士气/补给由
## 扇区内**可见**部队的 facade.army() 汇总（攻防求和，士气/补给按兵力加权）。
static func front_dossier(owner: MilitaryViewModel, sector: Dictionary) -> Dictionary:
	return MilitaryViewModel.MilitaryDossiers.front_dossier(owner, sector)


## 一侧的汇总：兵力来自渲染快照（受迷雾门控），攻防/士气/补给来自每支部队的
## facade.army()。单侧最多读 12 支部队，其余只计入兵力，避免一次刷新打爆原生调用。
static func _side_totals(owner: MilitaryViewModel, sides: Array, slot: int) -> Dictionary:
	return MilitaryViewModel.MilitaryDossiers._side_totals(owner, sides, slot)



static func _dossier_army(owner: MilitaryViewModel, handle: int) -> Dictionary:
	return MilitaryViewModel.MilitaryDossiers._dossier_army(owner, handle)



static func _versus_row(label: String, own_value: float, enemy_value: float,
		own_text: String, enemy_text: String) -> Dictionary:
	return {"label": label, "own_value": own_value, "enemy_value": enemy_value,
		"own_text": own_text, "enemy_text": enemy_text}


## 「在场部队」名录：把一侧的可见部队逐支列出（番号 / 兵力 / 攻击 / 归属）。
## 详情来自 front_dossier 已经读过的缓存，不会为名录再多打一次原生调用。
static func _append_side_army_rows(owner: MilitaryViewModel, out: Array, sides: Array, slot: int) -> void:
	MilitaryViewModel.MilitaryDossiers._append_side_army_rows(owner, out, sides, slot)



static func _pair_key_for(cell_a: int, cell_b: int) -> int:
	return mini(cell_a, cell_b) * 131072 + maxi(cell_a, cell_b)



static func convoy_rows(owner: MilitaryViewModel, convoys: Array) -> Array:
	return MilitaryViewModel.MilitaryLogisticsProjection.convoy_rows(owner._day, owner._model, owner.cell_name, convoys)



static func _good_label(owner: MilitaryViewModel, dense_id: int) -> String:
	return MilitaryViewModel.MilitaryLogisticsProjection._good_label(owner._model, dense_id)
