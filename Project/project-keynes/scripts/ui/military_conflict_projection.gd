extends RefCounted

## Builds war, front, and peace views from published reports.


static func war_cards(owner: MilitaryViewModel) -> Array:
	var cards: Array = []
	for raw in MilitaryViewModel._as_array(owner._snapshot.get("wars", null)):
		cards.append(owner.war_card(MilitaryViewModel._as_dict(raw)))
	return cards


## 战争章节只放索引：在打谁、打了多久、战争分怎么来的、周边有哪些邻国可以开战。
## 条款草稿与占领格勾选在议和面板自己的模型里（MilitaryPeaceViewModel），
## 会战记录在军务档案里，所以这里不再预取 ceded / log。
static func war_model(owner: MilitaryViewModel, selected: int) -> Dictionary:
	var wars := owner.war_cards()
	var current: Dictionary = {}
	for war in wars:
		if int(war.id) == selected:
			current = war
	if current.is_empty() and not wars.is_empty():
		current = wars[0]
	return {
		"ok": true,
		"wars": wars,
		"selected": int(current.get("id", 0)),
		"declare": owner.declare_candidates(),
		"fronts": owner.front_rows(),
		"front_source": owner._front_queried,
	}



static func war_card(owner: MilitaryViewModel, war: Dictionary) -> Dictionary:
	var my_slot := int(owner._snapshot.get("country_slot", -1))
	# A card without the country slot (older fixture shapes) is the player's own
	# war as the attacker; anything else is compared against the slot only, so a
	# missing slot never silently flips which side is "us".
	var attacker := int(war.get("attacker_slot", -1)) == my_slot
	if my_slot < 0 and not war.has("attacker_slot"):
		attacker = bool(war.get("attacker", true))
	var enemy_slot := int(war.get("defender_slot" if attacker else "attacker_slot",
		war.get("enemy_slot", -1)))
	var score := float(war.get("score_q16", 0)) / MilitaryViewModel.Q16 * 100.0
	var parts: Array = []
	var raw_parts := MilitaryViewModel._as_dict(war.get("score_parts", null))
	if not raw_parts.is_empty():
		for spec in [["battle", "会战", &"military.war.battle"],
				["occupation", "占领", &"military.plan.target"],
				["annihilation", "歼灭", &"military.army.attack"],
				["attrition", "损耗", &"military.army.defense"]]:
			var value := float(raw_parts.get(String(spec[0]), 0.0))
			parts.append({"id": String(spec[0]), "label": String(spec[1]), "icon": spec[2],
				"value": clampf(value / 40.0, -1.0, 1.0), "text": "%+.0f" % value})
	var days := maxi(0, owner._day - int(war.get("start_day", owner._day)))
	var our_losses := int(war.get("attacker_losses" if attacker else "defender_losses", 0))
	var enemy_losses := int(war.get("defender_losses" if attacker else "attacker_losses", 0))
	var our_slot := int(war.get("attacker_slot" if attacker else "defender_slot", -1))
	var engagement := owner.engagement_between(our_slot, int(enemy_slot))
	return {
		"id": int(war.get("war_id", 0)),
		"enemy_name": owner.country_name(enemy_slot),
		"role": "进攻方" if attacker else "防守方",
		"days": days,
		"score": score,
		"score_text": "%+.0f" % score,
		"score_parts": parts,
		"our_losses": our_losses,
		"enemy_losses": enemy_losses,
		"losses_text": "我方伤亡 %s · 敌方伤亡 %s" % [MilitaryViewModel._count(our_losses), MilitaryViewModel._count(enemy_losses)],
		"fully_occupied": bool(war.get("fully_occupied", false)),
		"engagement": engagement,
		"battle": not engagement.is_empty() and bool(engagement.get("battle", false)),
	}


## ── fronts & battles (military_core engagements / front_edges) ───────────

## Live engagements as rows. `zone_a`/`zone_b` come from the probe in the
## controller (the native table is not exported), region names from Country.
static func engagement_rows(owner: MilitaryViewModel) -> Array:
	var rows: Array = []
	for raw in MilitaryViewModel._as_array(owner._snapshot.get("engagements", null)):
		var row := MilitaryViewModel._as_dict(raw)
		var progress := MilitaryViewModel._ratio(row.get("progress_q16", MilitaryViewModel.Q16 / 2))
		var days := maxi(0, owner._day - int(row.get("start_day", owner._day)))
		var attacker := int(row.get("attacker_slot", -1))
		var label := String(row.get("battle_label", ""))
		rows.append({
			"cell_a": int(row.get("cell_a", -1)),
			"cell_b": int(row.get("cell_b", -1)),
			"attacker_slot": attacker,
			"defender_slot": int(row.get("defender_slot", -1)),
			"progress": progress,
			"progress_text": "%d%%" % int(round(progress * 100.0)),
			"days": days,
			"days_text": "已接战 %d 日" % days if days > 0 else "今日接战",
			"battle": bool(row.get("battle", false)),
			"label": label if not label.is_empty() else "%s ↔ %s" % [
				String(row.get("zone_a", owner.cell_name(int(row.get("cell_a", -1))))),
				String(row.get("zone_b", owner.cell_name(int(row.get("cell_b", -1)))))],
			"attacker_name": owner.country_name(attacker),
			"zone_a": String(row.get("zone_a", owner.cell_name(int(row.get("cell_a", -1))))),
			"zone_b": String(row.get("zone_b", owner.cell_name(int(row.get("cell_b", -1))))),
		})
	return rows



static func engagement_between(owner: MilitaryViewModel, slot_a: int, slot_b: int) -> Dictionary:
	for row in owner.engagement_rows():
		var attacker := int(row.attacker_slot)
		var defender := int(row.defender_slot)
		if (attacker == slot_a and defender == slot_b) \
				or (attacker == slot_b and defender == slot_a):
			return row
	return {}


## Front-edge keys (cell * 6 + direction) collapsed into per-cell counts: the UI
## cannot draw a ribbon, but it can say which sectors are contested.
static func front_rows(owner: MilitaryViewModel) -> Array:
	# The render snapshot carries the per-edge progress byte but not the keys
	# (they only feed MilitaryFrontLayer), so the controller hands both over.
	var keys = owner._snapshot.get("front_edge_keys", PackedInt32Array())
	if not (keys is PackedInt32Array) and owner._player_controller != null \
			and owner._player_controller.has_method("military_front_probe"):
		var probe = owner._player_controller.call("military_front_probe")
		if probe is Dictionary:
			keys = (probe as Dictionary).get("keys", PackedInt32Array())
			owner._snapshot["front_edge_progress"] = (probe as Dictionary).get(
				"progress", PackedByteArray())
	if not (keys is PackedInt32Array):
		return []
	owner._front_queried = true
	var counts := {}
	var progress = owner._snapshot.get("front_edge_progress", PackedByteArray())
	for i in range(keys.size()):
		var cell := int(keys[i]) / 6
		var entry: Dictionary = counts.get(cell, {"count": 0, "progress": -1})
		entry["count"] = int(entry["count"]) + 1
		if progress is PackedByteArray and i < progress.size() and int(progress[i]) != 255:
			entry["progress"] = int(progress[i])
		counts[cell] = entry
	var rows: Array = []
	for cell in counts.keys():
		var entry: Dictionary = counts[cell]
		var zone := owner.zone_name(int(cell))
		var zone_row: Dictionary = {}
		for row in rows:
			if String(row.zone) == zone:
				zone_row = row
				break
		if zone_row.is_empty():
			zone_row = {"zone": zone, "cell": int(cell), "edges": [], "count": 0,
				"progress": -1}
			rows.append(zone_row)
		(zone_row.edges as Array).append(int(cell))
	var out: Array = []
	for row in rows:
		var best := -1
		for cell in row.edges:
			best = maxi(best, int((counts[cell] as Dictionary).get("progress", -1)))
		out.append({
			"id": String(row.zone),
			"zone": String(row.zone),
			"cell": int(row.cell),
			"edges": (row.edges as Array).size(),
			"progress": maxf(0.0, float(best) / 254.0),
			"progress_text": "交战中" if best >= 0 else "—",
			"text": "交战中" if best >= 0 else "对峙",
		})
	out.sort_custom(func(a, b): return int(a.edges) > int(b.edges))
	return out.slice(0, MilitaryViewModel.MAX_FRONT_ROWS)


## ── battle log (native event ring 40–47) ─────────────────────────────────
static func war_log(owner: MilitaryViewModel) -> Array:
	if owner._event_rows.is_empty():
		owner._event_rows = owner._read_events()
	var rows: Array = []
	for raw in owner._event_rows:
		var event := MilitaryViewModel._as_dict(raw)
		var event_type := int(event.type)
		var is_battle := event_type in [MilitaryViewModel.EVENT_BATTLE_RESOLVED, MilitaryViewModel.EVENT_ARMY_DESTROYED,
			MilitaryViewModel.EVENT_CELL_CONTROL_CHANGED, MilitaryViewModel.EVENT_CONVOY_INTERCEPTED]
		if not is_battle:
			continue
		var scored := owner._battle_log_label(int(event.get("cell", -1)), int(event.get("war_id", -1)))
		if not scored.is_empty():
			event["scored"] = scored
		rows.append(owner._event_row(event))
	rows.reverse()
	return rows.slice(0, MilitaryViewModel.MAX_LOG_ROWS)


## True when the native military event ring (types 40-47) can be read at all. The
## workspace says "战报需要军事运行时的事件流" only when this is false.
## True when the core's scored battle log (MilitaryBattleLogRow, saved in PKMI) is
## readable. The bridge exports no accessor yet, so this reports false and the
## event ring carries the log.
static func _read_events(owner: MilitaryViewModel) -> Array:
	var batch = null
	if owner._facade != null and owner._facade.has_method("poll_events"):
		batch = owner._facade.call("poll_events", 0, 512)
	elif owner._player_controller != null and owner._player_controller.has_method("military_events_probe"):
		# Production path: CountryViewModel does not hand the façade down, so the
		# controller forwards the military event ring (same native ring).
		batch = owner._player_controller.call("military_events_probe", 512)
	return batch if batch is Array else []


## MilitaryBattleLogRow (last 64 battles, core-owned, saved in PKMI) is not
## exported by the bridge. The probe reports "cell|war|day" of the newest row so
## the newest matching event can be marked as scored until it is. The second
## element is the row count, so an empty log counts as a resolved probe.
static func _battle_log_label(owner: MilitaryViewModel, cell: int, war_id: int) -> String:
	if owner._player_controller == null or not owner._player_controller.has_method("battle_log_probe"):
		return ""
	var probe = owner._player_controller.call("battle_log_probe")
	if not (probe is Dictionary) or not bool((probe as Dictionary).get("available", false)):
		return ""
	var newest := String((probe as Dictionary).get("newest", ""))
	var count := int((probe as Dictionary).get("count", 0))
	if count > 0 and newest == "%d|%d" % [cell, war_id]:
		return "已计分"
	return ""



static func _event_row(owner: MilitaryViewModel, event: Dictionary) -> Dictionary:
	var event_type := int(event.type)
	var cell := int(event.cell)
	var team := ""
	var text := ""
	match event_type:
		MilitaryViewModel.EVENT_WAR_DECLARED:
			text = "%s 向 %s 宣战" % [owner.country_name(int(event.i0)), owner.country_name(int(event.i1))]
		MilitaryViewModel.EVENT_WAR_ENDED:
			text = "战争结束：%s" % ("吞并" if int(event.i0) == 2 else "和约")
			if int(event.i1) > 0:
				text += "，割地 %d 格" % int(event.i1)
		MilitaryViewModel.EVENT_BATTLE_RESOLVED:
			var winner := int(event.i0)
			var loser := int(event.i1)
			team = "我方" if winner == int(owner._snapshot.get("country_slot", -1)) else "敌方"
			text = "%s 于 %s 击退 %s，损失 %s 人" % [owner.country_name(winner), owner.zone_name(cell),
				owner.country_name(loser), MilitaryViewModel._count(event.value)]
		MilitaryViewModel.EVENT_CELL_CONTROL_CHANGED:
			text = "%s 被 %s 占领" % [owner.zone_name(cell), owner.country_name(int(event.i0))]
		MilitaryViewModel.EVENT_ARMY_DESTROYED:
			text = "%s 的部队在 %s 被歼灭（%s 人）" % [owner.country_name(int(event.i1)),
				owner.zone_name(cell), MilitaryViewModel._count(event.value)]
		MilitaryViewModel.EVENT_CONVOY_INTERCEPTED:
			text = "%s 的车队在 %s 被截（货值 %s）" % [owner.country_name(int(event.i1)),
				owner.zone_name(cell), MilitaryViewModel._money_text(event.value)]
		_:
			text = String(event.get("text", ""))
	return {
		"id": int(event.get("id", 0)),
		"day": int(event.get("day", 0)),
		"type": event_type,
		"text": text,
		"detail": String(event.get("scored", "")),
		"team": team,
		"kind": {"42": "会战", "43": "占领", "44": "歼灭", "46": "截击"}.get(str(event_type), "战事"),
		"cell": cell,
	}


## ── declare war (neighbouring countries from the live territory map) ─────
static func declare_candidates(owner: MilitaryViewModel) -> Array:
	var rows: Array = []
	var regions := owner._region_map()
	var my_slot := int(owner._snapshot.get("country_slot", -1))
	for slot in regions.keys():
		if int(slot) == my_slot:
			continue
		var region: Dictionary = regions[slot]
		var handle := owner._handle_for_slot(int(slot))
		var status := owner._war_status(int(slot))
		var reason := String(status.reason)
		# A country without a Country handle cannot be addressed by war.declare;
		# saying so beats sending a command that the runtime rejects.
		if handle == 0 and reason.is_empty():
			reason = "暂时无法对这个国家宣战"
		rows.append({
			"id": handle if handle != 0 else -1 - int(slot),
			"slot": int(slot),
			"handle": handle,
			"name": owner.country_name(int(slot)),
			"cells": int(region.cells),
			"capital": owner._capital_name(handle),
			"war": bool(status.war),
			"truce_until": int(status.truce_until),
			"can_declare": reason.is_empty(),
			"reason": reason,
		})
	rows.sort_custom(func(a, b):
		if bool(a.can_declare) != bool(b.can_declare):
			return bool(a.can_declare)
		return int(a.cells) > int(b.cells))
	return rows


## slot -> {cells}: how many cells of each foreign country touch the player's
## territory. 1 = one hex ring, 2 = inside the widest command radius.
static func _region_map(owner: MilitaryViewModel) -> Dictionary:
	var key := "%d" % int(owner._country_handle)
	if owner._neighbor_cache.has(key):
		return owner._neighbor_cache[key]
	var regions := {}
	if owner._map() != null:
		regions = owner._scan_regions()
	owner._neighbor_cache[key] = regions
	return regions


## 会话地图：模型显式给的优先，其次 fixture 的 `current_map()`。
static func _map(owner: MilitaryViewModel):
	if owner._map_obj != null:
		return owner._map_obj
	return CountryMapQuery.map_of(owner._generator)


## Neighbour scan over the territory mirror. Returns {} when the session does not
## expose a map (fixture/offline mount). The owner array comes from
## `CountryMapQuery`, i.e. `MapData.country_slot_arr` first — the same mirror the
## borders and the fog are solved from.
static func _scan_regions(owner: MilitaryViewModel) -> Dictionary:
	var regions := {}
	var owners := CountryMapQuery.owner_map(owner._generator, owner._model, owner._map())
	var neighbors := CountryMapQuery.neighbors_of(owner._generator, owner._map())
	if owners.is_empty() or neighbors.size() < owners.size() * 6:
		return regions
	var my_slot := owner._player_slot()
	var frontier: Array = []
	for cell in range(owners.size()):
		if int(owners[cell]) == my_slot:
			frontier.append(cell)
	var seen := PackedByteArray()
	seen.resize(owners.size())
	# Ring 1 is real adjacency; ring 2 exists only so the radius picker can show
	# targets it would reach. `adjoining` keeps the two apart.
	for ring in range(1, 3):
		var next: Array = []
		for cell in frontier:
			for offset_value in owner._neighbor_offsets(neighbors, int(cell)):
				var neighbor := int(cell) + int(offset_value)
				if neighbor < 0 or neighbor >= owners.size() or int(seen[neighbor]) != 0:
					continue
				seen[neighbor] = 1
				next.append(neighbor)
				var slot := int(owners[neighbor])
				if slot < 0 or slot == my_slot:
					continue
				var entry: Dictionary = regions.get(slot, {"cells": 0, "adjoining": false})
				entry.cells = int(entry.cells) + 1
				entry.adjoining = bool(entry.adjoining) or ring == 1
				regions[slot] = entry
		frontier = next
	return regions


## The six neighbour indices of a cell (seam wrapped). MapData owns the layout;
## military_front_layer uses the same packed array (cell * 6 + direction).
static func _neighbor_offsets(owner: MilitaryViewModel, neighbors: PackedInt32Array, cell: int) -> Array:
	var offsets: Array = []
	var base := cell * 6
	if neighbors.size() < base + 6:
		return offsets
	for direction in range(6):
		var neighbor := int(neighbors[base + direction])
		if neighbor >= 0:
			offsets.append(neighbor - cell)
	return offsets


## A war with this country blocks a declaration until the truce expires.
static func _war_status(owner: MilitaryViewModel, slot: int) -> Dictionary:
	for war in MilitaryViewModel._as_array(owner._snapshot.get("wars", null)):
		var row := MilitaryViewModel._as_dict(war)
		if int(row.get("attacker_slot", -1)) == slot \
				or int(row.get("defender_slot", -1)) == slot:
			return {"war": true, "truce_until": -1, "reason": "正在交战"}
	if owner._player_controller != null and owner._player_controller.has_method("military_truce_until"):
		var until := int(owner._player_controller.call("military_truce_until", slot))
		if until > owner._day:
			return {"war": false, "truce_until": until,
				"reason": "停战至%s" % WorldClock.date_text_for_day(until)}
	return {"war": false, "truce_until": -1, "reason": ""}



static func _handle_for_slot(owner: MilitaryViewModel, slot: int) -> int:
	var key := "handle_%d" % slot
	if owner._neighbor_cache.has(key):
		return int(owner._neighbor_cache[key])
	var section := MilitaryViewModel._as_dict(owner._model.get("military", null))
	var handles: Dictionary = MilitaryViewModel._as_dict(section.get("country_handles", null))
	var handle := CountryMapQuery.handle_for_slot(owner._owner_map(), slot,
		owner._country_facade(), handles, owner._slot_first_cells())
	owner._neighbor_cache[key] = handle
	return handle


## 槽位 → 该国领土首格。句柄只能按「拿一个格去问 Country」解析，所以这张表必须
## 一次扫完并缓存：每个槽位重扫一遍归属镜像在十万格地图上是平方级开销。
static func _slot_first_cells(owner: MilitaryViewModel) -> Dictionary:
	if owner._neighbor_cache.has("__slot_cells__"):
		return owner._neighbor_cache["__slot_cells__"]
	var cells := CountryMapQuery.first_cell_by_slot(owner._owner_map())
	owner._neighbor_cache["__slot_cells__"] = cells
	return cells


## 玩家自己在这个会话里的槽位。军事快照最权威；军事机构未接通时退回句柄低 32 位
## 的编码（`make_handle = generation << 32 | slot`），这里只用于排除本国。
static func _player_slot(owner: MilitaryViewModel) -> int:
	var slot := int(owner._snapshot.get("country_slot", -1))
	if slot >= 0:
		return slot
	return CountryMapQuery.slot_of_handle(owner._country_handle)



static func _capital_name(owner: MilitaryViewModel, handle: int) -> String:
	if handle == 0:
		return ""
	var facade = owner._country_facade()
	if facade == null or not facade.has_method("snapshot"):
		return ""
	var snapshot = facade.call("snapshot", handle)
	if not (snapshot is Dictionary) or not bool((snapshot as Dictionary).get("ok", false)):
		return ""
	return owner.cell_name(int((snapshot as Dictionary).get("cell", -1)))


## ── occupied cells for the peace draft (design §12.3) ───────────────────

## Cells of the war's enemy that we currently control. Native
## `get_military_control_snapshot()` carries no owner column, so the owner comes
## from Country's territory map (same seam as declare_candidates).
static func ceded_cells(owner: MilitaryViewModel, war: Dictionary, checked: Dictionary = {}) -> Dictionary:
	if war.is_empty():
		return {"rows": [], "cells": [], "total": 0, "checked": 0}
	var my_slot := int(owner._snapshot.get("country_slot", -1))
	var attacker := int(war.get("attacker_slot", -1)) == my_slot
	var enemy_slot := int(war.get("defender_slot" if attacker else "attacker_slot", -1))
	var control := MilitaryViewModel._as_dict(owner._snapshot.get("control", null))
	# 原生国家快照不带 control 段（它只在自己的 country_snapshot 里），生产环境要
	# 问一次军事 facade：否则议和窗口的割地候选永远是空的。
	if control.is_empty() and owner._facade != null and owner._facade.has_method("control_snapshot"):
		control = MilitaryViewModel._as_dict(owner._facade.call("control_snapshot"))
	var cells = control.get("cells", PackedInt32Array())
	var slots = control.get("controller_slots", PackedInt32Array())
	if not (cells is PackedInt32Array) or not (slots is PackedInt32Array) \
			or cells.size() != slots.size():
		return {"rows": [], "cells": [], "total": 0, "checked": 0}
	var owners = owner._owner_map()
	var rows: Array = []
	var selected: Array = []
	for i in range(cells.size()):
		if int(slots[i]) != my_slot:
			continue
		var cell := int(cells[i])
		# No owner column in the control snapshot: keep the cell when Country
		# cannot say whose it is either, rather than silently dropping the term.
		if enemy_slot >= 0 and cell < owners.size() and int(owners[cell]) != enemy_slot:
			continue
		var is_checked := bool(checked.get(cell, true))
		if is_checked:
			selected.append(cell)
		var owner_label := owner._owner_label(cell, owners)
		rows.append({
			"id": cell,
			"cell": cell,
			"label": owner.cession_label(cell, owners),
			"note": ("原属%s" % owner_label) if not owner_label.is_empty() else "",
			"tooltip": "%s · 我方占领\n勾选后写进和议条款" % owner.zone_name(cell),
		})
	return {"rows": rows, "cells": selected, "total": rows.size(), "checked": selected.size()}



static func _owner_map(owner: MilitaryViewModel) -> PackedInt32Array:
	if owner._neighbor_cache.has("__owners__"):
		return owner._neighbor_cache["__owners__"]
	var owners := CountryMapQuery.owner_map(owner._generator, owner._model, owner._map())
	owner._neighbor_cache["__owners__"] = owners
	return owners


## One occupied cell of the peace draft. The region name alone repeats for every
## cell of a region, so the cell's own name is what tells them apart; the index
## only shows up when neither the generator nor Country can name it.
static func cession_label(owner: MilitaryViewModel, cell: int, owners: PackedInt32Array) -> String:
	var zone := owner.zone_name(cell)
	var settlement := owner.settlement_name(cell)
	if settlement.is_empty():
		return zone
	if zone.ends_with(settlement):
		return zone
	return "%s · %s" % [zone, settlement]



static func _owner_label(owner: MilitaryViewModel, cell: int, owners: PackedInt32Array) -> String:
	if owners.is_empty() or cell < 0 or cell >= owners.size() or int(owners[cell]) < 0:
		return ""
	return owner.country_name(int(owners[cell]))


## Preview of a peace draft. The native evaluator is authoritative; the local
## estimate is only used when the facade is absent (tests, old saves).
static func evaluate_peace(owner: MilitaryViewModel, war_id: int, war_score: float, terms: Array) -> Dictionary:
	if terms.is_empty():
		return {"ok": true, "price": 0.0, "band": -1}
	if owner._facade != null and owner._facade.has_method("evaluate_peace"):
		var result = owner._facade.call("evaluate_peace", war_id, owner._country_handle, terms)
		if result is Dictionary and result.has("price"):
			var band := ["low", "mid", "high"].find(String(result.get("band", "low")))
			return {"ok": bool(result.get("ok", false)), "price": float(result.price),
				"band": maxi(band, 0), "reason": String(result.get("reason", ""))}
	var price := 0.0
	for term_value in terms:
		var term := MilitaryViewModel._as_dict(term_value)
		match String(term.get("kind", "")):
			"annex":
				price += 100.0
			"lump_sum":
				price += float(term.get("amount", 0.0)) / 2000.0
			"installments":
				price += float(term.get("amount", 0.0)) * float(term.get("n", 0)) / 2600.0
			"ceding":
				price += float(term.get("n", 0)) * 2.0
	var available := maxf(0.0, war_score)
	var band := 0
	if available > 0.0:
		band = 2 if price <= available * 0.6 else (1 if price <= available else 0)
	return {"ok": true, "price": price, "band": band}
