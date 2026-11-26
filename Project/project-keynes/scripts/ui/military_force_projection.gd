extends RefCounted

## Builds the readiness and force roster chapters.


static func overview_model(owner: MilitaryViewModel) -> Dictionary:
	var soldiers := int(owner._snapshot.get("soldiers_total", 0))
	var militia := int(owner._snapshot.get("soldiers_militia", 0))
	var trained := int(owner._snapshot.get("soldiers_trained", 0))
	var training := int(owner._snapshot.get("soldiers_training", 0))
	var target := int(owner._snapshot.get("effective_target", 0))
	var deficit := maxi(0, target - soldiers - training)
	var spend := owner.spend_breakdown()
	var pay_ratio := MilitaryViewModel._ratio(owner._snapshot.get("pay_ratio_30_q16", 0))
	var readiness := owner.army_readiness()
	var kpis := [
		{"id": "soldiers", "title": "兵力", "value": float(soldiers), "kind": "count",
			"icon": &"military.unit.line",
			"caption": ("目标 %s · 缺 %s" % [MilitaryViewModel._count(target), MilitaryViewModel._count(deficit)]) if deficit > 0
				else "目标 %s · 已达成" % MilitaryViewModel._count(target),
			"tone": "warn" if deficit > 0 else ""},
		{"id": "spend", "title": "日军费", "value": float(spend.total), "kind": "money",
			"icon": &"military.army.pay", "caption": "军饷实付 %s" % MilitaryViewModel._percent(pay_ratio),
			"tone": "risk" if pay_ratio < 0.5 else ("warn" if pay_ratio < 0.8 else "")},
		{"id": "morale", "title": "士气", "value": float(readiness.morale), "kind": "percent",
			"icon": &"military.army.morale", "caption": readiness.morale_caption,
			"tone": "risk" if float(readiness.morale) < 0.4 and int(readiness.count) > 0 else ""},
		{"id": "supply", "title": "补给满足", "value": float(readiness.supply), "kind": "percent",
			"icon": &"military.army.supply", "caption": readiness.supply_caption,
			"tone": "risk" if float(readiness.supply) < 0.5 and int(readiness.count) > 0 else ""},
	]
	if int(readiness.count) == 0:
		kpis[2]["kind"] = "text"
		kpis[2]["text"] = "—"
		kpis[3]["kind"] = "text"
		kpis[3]["text"] = "—"
	var garrisoned := int(owner._snapshot.get("soldiers_garrisoned", 0))
	var field := int(owner._snapshot.get("soldiers_in_armies", 0))
	return {
		"ok": true,
		"kpis": kpis,
		"composition": [
			{"label": "正规军", "text": MilitaryViewModel._count(trained), "value": trained,
				"color": UITokens.DOSSIER_VERDIGRIS},
			{"label": "民兵", "text": MilitaryViewModel._count(militia), "value": militia,
				"color": UITokens.DOSSIER_UMBER},
			{"label": "训练中", "text": MilitaryViewModel._count(training), "value": training,
				"color": UITokens.DOSSIER_BRASS},
		],
		"composition_total": "%s 人" % MilitaryViewModel._count(soldiers + training),
		"deployment": [
			{"label": "驻防", "text": MilitaryViewModel._count(garrisoned), "value": garrisoned,
				"color": UITokens.DOSSIER_SLATE},
			{"label": "野战部队", "text": MilitaryViewModel._count(field), "value": field,
				"color": UITokens.DOSSIER_OXBLOOD},
		],
		"deployment_total": "%d 支部队" % owner._armies.size(),
		"spend": spend.segments,
		"spend_total": MilitaryViewModel._money_text(spend.total_raw),
		"wars": owner.war_cards(),
		"insights": owner._overview_insights(soldiers, deficit, pay_ratio, readiness),
	}



static func spend_breakdown(owner: MilitaryViewModel) -> Dictionary:
	var payroll := int(owner._snapshot.get("spend_payroll_30", 0)) / 30
	var procurement := int(owner._snapshot.get("spend_procurement_30", 0)) / 30
	var upkeep := int(owner._snapshot.get("spend_upkeep_30", 0)) / 30
	var total := payroll + procurement + upkeep
	return {
		"total": float(total) / MilitaryViewModel.MONEY_SCALE,
		"total_raw": total,
		"segments": [
			{"label": "军饷", "text": MilitaryViewModel._money_text(payroll), "value": payroll,
				"color": UITokens.DOSSIER_BRASS},
			{"label": "军需采购", "text": MilitaryViewModel._money_text(procurement), "value": procurement,
				"color": UITokens.DOSSIER_VERDIGRIS},
			{"label": "维护", "text": MilitaryViewModel._money_text(upkeep), "value": upkeep,
				"color": UITokens.DOSSIER_UMBER},
		],
	}


## Headcount-weighted morale and supply across field armies.
static func army_readiness(owner: MilitaryViewModel) -> Dictionary:
	var heads := 0.0
	var morale := 0.0
	var supply := 0.0
	var worst_supply := 2.0
	var worst_name := ""
	var low_morale := 0
	for raw in owner._armies:
		var army := MilitaryViewModel._as_dict(raw)
		var count := float(maxi(0, int(army.get("headcount", 0))))
		var army_morale := MilitaryViewModel._ratio(army.get("morale_q16", MilitaryViewModel.Q16))
		var army_supply := MilitaryViewModel._ratio(army.get("supply_ratio_q16", MilitaryViewModel.Q16))
		heads += count
		morale += army_morale * count
		supply += army_supply * count
		if army_morale < 0.4:
			low_morale += 1
		if army_supply < worst_supply:
			worst_supply = army_supply
			worst_name = owner.army_name(army)
	var weighted_morale := morale / heads if heads > 0.0 else 0.0
	var weighted_supply := supply / heads if heads > 0.0 else 0.0
	return {
		"count": owner._armies.size(),
		"morale": weighted_morale,
		"supply": weighted_supply,
		"low_morale": low_morale,
		"worst_supply": worst_supply if worst_supply <= 1.0 else 0.0,
		"morale_caption": ("%d 支部队士气低落" % low_morale) if low_morale > 0
			else "",
		"supply_caption": ("最低 %s %s" % [worst_name, MilitaryViewModel._percent(worst_supply)])
			if not worst_name.is_empty() else "尚无野战部队",
	}



static func _overview_insights(owner: MilitaryViewModel, soldiers: int, deficit: int, pay_ratio: float,
		readiness: Dictionary) -> Array:
	var insights: Array = []
	if soldiers <= 0:
		insights.append(MilitaryViewModel._insight("no_soldiers", "尚无兵员：先在领土上建兵营，再设定目标兵力。",
			"military.building.barracks", UITokens.DOSSIER_OXBLOOD))
	elif deficit > 0:
		insights.append(MilitaryViewModel._insight("deficit",
			"距目标还缺 %s 人，兵营会在每次经济结算后继续征召。" % MilitaryViewModel._count(deficit),
			"military.plan.target", UITokens.DOSSIER_BRASS))
	if pay_ratio > 0.0 and pay_ratio < 0.8:
		insights.append(MilitaryViewModel._insight("low_pay", "近 30 日军饷只实付 %s，士气会持续下滑。" % MilitaryViewModel._percent(pay_ratio),
			"military.army.pay", UITokens.DOSSIER_OXBLOOD))
	if int(readiness.count) > 0 and float(readiness.worst_supply) < 0.5:
		insights.append(MilitaryViewModel._insight("supply", "%s。补给不足的部队会掉组织度。" % String(readiness.supply_caption),
			"military.army.supply", UITokens.DOSSIER_OXBLOOD))
	var waiting := 0
	for raw in MilitaryViewModel._as_array(owner._snapshot.get("training", null)):
		if not bool(MilitaryViewModel._as_dict(raw).get("equipment_ready", false)):
			waiting += 1
	if waiting > 0:
		insights.append(MilitaryViewModel._insight("equipment", "%d 笔训练订单在等装备到货。" % waiting,
			"military.plan.training", UITokens.DOSSIER_BRASS))
	return insights.slice(0, 4)



static func _insight(id: String, text: String, icon: String, accent: Color) -> Dictionary:
	return {"id": id, "text": text, "icon": icon, "accent": accent}


# ── forces ───────────────────────────────────────────────────────────────
static func forces_model(owner: MilitaryViewModel) -> Dictionary:
	var shares := owner.shares_by_unit()
	var barracks := MilitaryViewModel._as_array(owner._snapshot.get("barracks", null))
	var rows := owner.unit_share_rows(shares)
	return {
		"ok": true,
		"target_mode": int(owner._snapshot.get("target_mode", 0)),
		"target_value": int(owner._snapshot.get("target_value", 0)),
		"per_soldier_cost": int(owner._snapshot.get("per_soldier_cost", 0)),
		"daily_wage": float(owner._daily_wage) / MilitaryViewModel.MONEY_SCALE,
		"shares": owner.share_segments(shares),
		"share_total": owner._share_total(shares),
		"units": rows,
		"unlocked_count": owner.unlocked_unit_count(),
		"quality_policy": int(owner._snapshot.get("quality_policy", 0)),
		"auto_retrain": bool(owner._snapshot.get("auto_retrain", true)),
		"levy_enabled": bool(owner._snapshot.get("levy_enabled", true)),
		"auto_discharge": bool(owner._snapshot.get("auto_discharge", false)),
		"barracks": owner.barracks_rows(barracks),
		"barracks_caption": "%d 座 · 兵额 %s" % [barracks.size(),
			MilitaryViewModel._count(owner._snapshot.get("post_count", 0))],
		"training": owner.training_rows(),
		"training_caption": "在训 %s 人" % MilitaryViewModel._count(owner._snapshot.get("soldiers_training", 0)),
	}


## config_share_bp is a dense array indexed by unit; keyed by stable id here.
static func shares_by_unit(owner: MilitaryViewModel) -> Dictionary:
	var raw = owner._snapshot.get("config_share_bp", PackedInt32Array())
	var shares := {}
	if not (raw is PackedInt32Array or raw is Array):
		return shares
	for index in range(raw.size()):
		var unit_id := String(owner.unit_row(index).get("id", ""))
		if int(raw[index]) > 0 and not unit_id.is_empty():
			shares[unit_id] = int(raw[index])
	return shares



static func share_segments(owner: MilitaryViewModel, shares: Dictionary) -> Array:
	var segments: Array = []
	var assigned := 0
	for index in range(owner._unit_rows.size()):
		var unit_id := String(owner.unit_row(index).get("id", ""))
		var bp := int(shares.get(unit_id, 0))
		if bp <= 0:
			continue
		assigned += bp
		segments.append({"id": unit_id, "label": owner.unit_name(index), "text": MilitaryViewModel._bp(bp),
			"value": bp, "color": MilitaryViewModel._shade(owner.class_color(index), segments.size())})
	var remainder := maxi(0, 10000 - assigned)
	segments.append({"id": "militia", "label": "民兵", "text": MilitaryViewModel._bp(remainder),
		"value": remainder, "color": Color(0.62, 0.55, 0.44)})
	return segments


## Neighbouring segments of one class get alternating lightness so they stay distinct.
static func _shade(color: Color, ordinal: int) -> Color:
	return color.lightened(0.18) if ordinal % 2 == 1 else color



static func _share_total(owner: MilitaryViewModel, shares: Dictionary) -> int:
	var total := 0
	for unit_id in shares:
		total += maxi(0, int(shares[unit_id]))
	return total


## Roster rows. Only units the country can actually field are offered: a locked
## unit is shown solely when it already holds a share, so a lost gate can always
## be lowered instead of becoming an invisible, un-cancellable allocation.
## The militia closes the list: it is a real unit type and owns every unassigned
## point, so the player reads the remainder as a row instead of a caption.
static func unit_share_rows(owner: MilitaryViewModel, shares: Dictionary) -> Array:
	var rows: Array = []
	var total := owner._share_total(shares)
	for index in range(owner._unit_rows.size()):
		if owner.is_militia(index):
			continue
		var unit_id := String(owner.unit_row(index).get("id", ""))
		if unit_id.is_empty():
			continue
		var bp := int(shares.get(unit_id, 0))
		var facts := owner.unit_facts(index)
		var locked := not bool(facts.unlocked)
		if locked and bp <= 0:
			continue
		facts["label"] = facts.name
		facts["bp"] = bp
		facts["locked"] = locked
		facts["can_raise"] = total < 10000 and not locked
		facts["color"] = owner.class_color(index)
		rows.append(facts)
	rows.sort_custom(func(a, b):
		if int(a.era_index) != int(b.era_index):
			return int(a.era_index) < int(b.era_index)
		if not is_equal_approx(float(a.attack), float(b.attack)):
			return float(a.attack) > float(b.attack)
		return String(a.id) < String(b.id))
	var militia := owner._militia_row(total)
	if not militia.is_empty():
		rows.append(militia)
	MilitaryViewModel._normalize_stats(rows)
	return rows


## 民兵行：占满剩余份额，永远排最后，不能加份额（它本来就是剩下的部分）。
static func _militia_row(owner: MilitaryViewModel, total: int) -> Dictionary:
	var index := owner.militia_index()
	if index < 0:
		return {}
	var row := owner.unit_facts(index)
	row["label"] = row.name
	row["bp"] = maxi(0, 10000 - total)
	row["locked"] = false
	row["can_raise"] = false
	row["color"] = owner.class_color(index)
	row["is_militia_row"] = true
	return row



static func militia_index(owner: MilitaryViewModel) -> int:
	var declared := int(owner._catalog.get("militia_unit", -1))
	if declared >= 0 and declared < owner._unit_rows.size() and owner.is_militia(declared):
		return declared
	for index in range(owner._unit_rows.size()):
		if owner.is_militia(index):
			return index
	return -1


## Stat bars compare units against each other, so each ratio is scaled by the best
## value in the visible set. The printed number stays the raw catalog value.
static func _normalize_stats(rows: Array) -> void:
	var best := {"attack": 0.0, "defense": 0.0, "speed": 0.0}
	for row in rows:
		for field in best:
			best[field] = maxf(float(best[field]), float(row[field]))
	for row in rows:
		for field in best:
			var peak := float(best[field])
			var ratio := 0.0
			if peak > 0.0001:
				ratio = clampf(float(row[field]) / peak, 0.0, 1.0)
			row["%s_ratio" % field] = ratio



static func locked_unit_count(owner: MilitaryViewModel) -> int:
	var count := 0
	for index in range(owner._unit_rows.size()):
		if not owner.is_militia(index) and not owner.unit_unlocked(index):
			count += 1
	return count



static func unlocked_unit_count(owner: MilitaryViewModel) -> int:
	var count := 0
	for index in range(owner._unit_rows.size()):
		if not owner.is_militia(index) and owner.unit_unlocked(index):
			count += 1
	return count



static func barracks_rows(owner: MilitaryViewModel, barracks: Array) -> Array:
	var rows: Array = []
	for raw in barracks:
		var entry := MilitaryViewModel._as_dict(raw)
		var cell := int(entry.get("cell", -1))
		var posts := int(entry.get("post_count", 0))
		var present := int(entry.get("present", 0))
		var paused := bool(entry.get("paused", false))
		var disrepair := bool(entry.get("disrepair", false))
		rows.append({
			"cell": cell,
			"name": owner.cell_name(cell),
			"posts": posts,
			"present": present,
			"fill": clampf(float(present) / float(posts), 0.0, 1.0) if posts > 0 else 0.0,
			"open": maxi(0, int(entry.get("open", 0))),
			"quota": int(entry.get("quota", 0)),
			"pending": int(entry.get("pending_enlist", 0)),
			"paused": paused,
			"disrepair": disrepair,
			"status": "失修" if disrepair else ("暂停" if paused else "招募中"),
			"icon": String(IconCatalog.military_building_semantic(
				"", "barracks", MilitaryViewModel._barracks_tier(posts))),
		})
	rows.sort_custom(func(a, b): return int(a.posts) > int(b.posts))
	return rows



static func _barracks_tier(posts: int) -> int:
	if posts <= 4:
		return 0
	if posts <= 10:
		return 1
	if posts <= 25:
		return 2
	if posts <= 50:
		return 3
	if posts <= 100:
		return 4
	if posts <= 200:
		return 5
	if posts <= 400:
		return 6
	return 7



static func training_rows(owner: MilitaryViewModel) -> Array:
	var rows: Array = []
	for raw in MilitaryViewModel._as_array(owner._snapshot.get("training", null)):
		var order := MilitaryViewModel._as_dict(raw)
		var done := int(order.get("days_done", 0))
		var total := maxi(1, int(order.get("days_total", 1)))
		var from_unit := int(order.get("from_unit", -1))
		var to_unit := int(order.get("to_unit", -1))
		var quality := clampi(int(round(float(order.get("quality_q8", 256)) / MilitaryViewModel.Q8)), 1, 5)
		rows.append({
			"id": int(order.get("id", 0)),
			"cell": int(order.get("cell", -1)),
			"cell_text": owner.cell_name(int(order.get("cell", -1))),
			"from_label": "民兵" if from_unit < 0 or owner.is_militia(from_unit) else owner.unit_name(from_unit),
			"to_label": owner.unit_name(to_unit),
			"icon": String(owner.unit_icon(to_unit)),
			"count": int(order.get("count", 0)),
			"quality_text": MilitaryViewModel.QUALITY_NAMES[quality],
			"ready": bool(order.get("equipment_ready", false)),
			"progress": clampf(float(done) / float(total), 0.0, 1.0),
			"progress_text": "%d/%d 日" % [done, total],
		})
	rows.sort_custom(func(a, b): return float(a.progress) > float(b.progress))
	return rows
