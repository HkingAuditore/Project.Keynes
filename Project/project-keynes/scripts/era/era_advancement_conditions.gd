extends RefCounted

## Pure advancement condition rows from technology progress, economy totals, territory and sampled trade.

const CatalogScript = preload("res://scripts/era/era_advancement_catalog.gd")

static func _conditions(
		_tech: Dictionary,
		_summary: Dictionary,
		_territory: int,
		_trade_accumulated: int,
		_current: int,
		target: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var tech := _tech
	var tech_target := int(ceil(float(tech.total) * CatalogScript.TECH_COMPLETION_RATIO))
	var tech_met := int(tech.total) > 0 and int(tech.completed) >= tech_target
	out.append(_condition("tech", int(tech.completed), tech_target, tech_met,
		"%d / %d 项" % [int(tech.completed), tech_target]))
	out[out.size() - 1]["mandatory"] = true
	out[out.size() - 1]["tooltip"] = "本时代共 %d 项科技，需完成 %d%%（%d 项）；当前已完成 %d 项。" % [
		int(tech.total), int(round(CatalogScript.TECH_COMPLETION_RATIO * 100.0)),
		tech_target, int(tech.completed)]
	var summary := _summary
	var territory := _territory
	var population := int(summary.get("population", 0))
	var population_target := CatalogScript.population_threshold(target, territory)
	out.append(_condition("population", population, population_target,
		population >= population_target, "%d / %d 人" % [population, population_target]))
	var buildings := int(summary.get("building_units", 0))
	var building_target := CatalogScript.building_threshold(target, territory)
	out.append(_condition("buildings", buildings, building_target,
		buildings >= building_target, "%d / %d 座" % [buildings, building_target]))
	var trade_target := CatalogScript.trade_order_threshold(target, territory)
	out.append(_condition("trade", _trade_accumulated, trade_target,
		_trade_accumulated >= trade_target,
		"%d / %d 次" % [_trade_accumulated, trade_target]))
	for row in out:
		if String(row.key) != "tech":
			row["tooltip"] = "%s：需达到 %d；按当前持有的 %d 个地块计算，领土扩大时门槛同步提高。" % [
				String(row.label), int(row.target), territory]
	return out


static func _condition(key: String, current: int, target: int, met: bool,
		text: String) -> Dictionary:
	return {"key": key, "label": String(CatalogScript.CONDITION_LABELS.get(key, key)),
		"current": current, "target": target, "met": met, "text": text}
