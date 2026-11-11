class_name MilitaryCellStatsPublisher
extends RefCounted

## Publishes Military facts into the two places the ideology channel A/C cards
## can read them (docs/plans/military-system-design.md §17.1):
##
##   * the per-country metric rows `country.at_war` / `country.soldier_share_q16`
##     that card conditions compare against, and
##   * the cell tags `cell.barracks` / `cell.fortified` / `cell.military_industry`
##     / `cell.occupied_by_us` / `cell.occupied_by_enemy` / `cell.garrisoned`
##     that the `OWN_TERRITORY` / `TAG_ANY_CELL` / `TAG_SOURCE_COUNT` target
##     selectors filter on.
##
## WHY A PUBLISHER AND NOT A SELECTOR
## ----------------------------------
## A tag is a compiled predicate over Economy metrics (`target_tag.h`), while
## barracks, fortification tiers, garrison lots and cell controllers live in
## Military. Neither side can read the other directly: Economy must not depend on
## Military's store, and Military must not write another domain's state. So the
## facts are PUSHED through `set_military_cell_tags` /
## `set_military_country_metrics`, exactly like the climate facts Climate pushes
## for the same reason.
##
## WHAT IT DOES NOT DO
## -------------------
## It never advances a military day and never writes a Modifier. It reads the
## snapshot the daily stage already publishes, so it costs one pass over
## `get_military_country_snapshot` per country per military day, and nothing at
## all on a day Military did not run.

## Cell tag bit ids. ABI with `MilitaryCellTagBit` in
## gdext/src/world_ext_military_cell_stats.cpp -- append only, never renumber.
const TAG_BARRACKS := 0
const TAG_FORTIFIED := 1
const TAG_MILITARY_INDUSTRY := 2
const TAG_OCCUPIED_BY_US := 3
const TAG_OCCUPIED_BY_ENEMY := 4
const TAG_GARRISONED := 5

## Tag ids the tag dictionary must declare, in `MilitaryCellStatsPublisher.TAGS`
## order. `target_tag_dictionary.gd` reads this table rather than repeating the
## names, so a rename cannot desynchronise the two.
const TAGS := [
	{tagname = "cell.barracks", bit = TAG_BARRACKS},
	{tagname = "cell.fortified", bit = TAG_FORTIFIED},
	{tagname = "cell.military_industry", bit = TAG_MILITARY_INDUSTRY},
	{tagname = "cell.occupied_by_us", bit = TAG_OCCUPIED_BY_US},
	{tagname = "cell.occupied_by_enemy", bit = TAG_OCCUPIED_BY_ENEMY},
	{tagname = "cell.garrisoned", bit = TAG_GARRISONED},
]

const Q16_ONE := 65536

var _world_ext: Object = null
var _facade: Object = null
var _last_report: Dictionary = {}


func configure(world_ext: Object, facade: Object) -> void:
	_world_ext = world_ext
	_facade = facade
	_last_report = {}


func is_available() -> bool:
	return _world_ext != null and _facade != null


func last_report() -> Dictionary:
	return _last_report.duplicate(true)


## Drops every published row. Called when the map or the military catalog is
## rebuilt: a tag on a rebuilt grid names different cells.
func clear() -> void:
	_last_report = {}
	if _world_ext != null:
		_world_ext.clear_military_cell_stats()


## Reads the committed Military snapshot and publishes it.
##
## `country_handles` is every live country handle the caller wants published.
## `owner_slot_of_cell(cell) -> int` resolves a cell to its Economy owner slot,
## because "occupied by us" only means something relative to who owns the land.
## `population_of(country_handle) -> int` supplies the denominator of the soldier
## share; Economy owns population, so it is injected rather than read here.
## All three are callables so this class stays free of the Economy facade.
func publish(country_handles: PackedInt64Array,
		owner_slot_of_cell: Callable, population_of: Callable) -> Dictionary:
	if not is_available():
		return {"ok": false, "reason": "military_cell_stats_api_unavailable"}
	var barracks_cells := {}
	var fortified_cells := {}
	var garrisoned_cells := {}
	var rows: Array = []
	var at_war_count := 0
	var soldier_rows := 0
	var slots := {}
	for handle in country_handles:
		if int(handle) == 0:
			continue
		var snapshot: Dictionary = _facade.country_snapshot(int(handle))
		if not bool(snapshot.get("ok", false)):
			continue
		var slot := int(snapshot.get("country_slot", -1))
		if slot < 0:
			continue
		slots[int(handle)] = slot
		for row in snapshot.get("barracks", []):
			var cell := int((row as Dictionary).get("cell", -1))
			if cell < 0:
				continue
			# `post_count` is the current barracks capacity: a state building
			# demolished back to 0 posts still leaves a cell state row, and
			# tagging it as a barracks would keep a dead building alive.
			if int((row as Dictionary).get("post_count", 0)) > 0:
				barracks_cells[cell] = true
			if int((row as Dictionary).get("fort_tier", -1)) >= 0:
				fortified_cells[cell] = true
		# A stationed army's cell is the cell a "garrison" card means: the design
		# counts garrison and army lots separately, and both stand on a cell.
		for army in _facade.armies(int(handle)):
			var army_cell := int((army as Dictionary).get("cell", -1))
			if army_cell >= 0:
				garrisoned_cells[army_cell] = true
		var at_war := int(snapshot.get("wars_active", 0)) > 0
		if at_war:
			at_war_count += 1
		var share := _soldier_share_q16(snapshot, population_of)
		if share > 0:
			soldier_rows += 1
		rows.append({
			"handle": int(handle),
			"slot": slot,
			"at_war": 1 if at_war else 0,
			"soldier_share_q16": share,
		})
	var queued: Dictionary = _world_ext.set_military_country_metrics(rows)
	var occupation := _occupation_rows(country_handles, slots, owner_slot_of_cell)
	var tags: Array = [
		{"name": "cell.barracks", "bit": TAG_BARRACKS,
			"cells": _ascending(barracks_cells)},
		{"name": "cell.fortified", "bit": TAG_FORTIFIED,
			"cells": _ascending(fortified_cells)},
		{"name": "cell.garrisoned", "bit": TAG_GARRISONED,
			"cells": _ascending(garrisoned_cells)},
		{"name": "cell.occupied_by_us", "bit": TAG_OCCUPIED_BY_US,
			"cells": occupation["by_us"],
			"owner": occupation["by_us_owner"], "us": occupation["us_slot"]},
		{"name": "cell.occupied_by_enemy", "bit": TAG_OCCUPIED_BY_ENEMY,
			"cells": occupation["by_enemy"],
			"owner": occupation["by_enemy_owner"], "us": occupation["us_slot"]},
	]
	var tagged: Dictionary = _world_ext.set_military_cell_tags(tags)
	_last_report = {
		"ok": bool(queued.get("ok", false)) and bool(tagged.get("ok", false)),
		"countries": rows.size(),
		"at_war": at_war_count,
		"soldier_rows": soldier_rows,
		"barracks_cells": barracks_cells.size(),
		"fortified_cells": fortified_cells.size(),
		"garrisoned_cells": garrisoned_cells.size(),
		"occupied_by_us": occupation["by_us"].size(),
		"occupied_by_enemy": occupation["by_enemy"].size(),
		"metrics_rejected": int(queued.get("rejected", 0)),
		"tags_rejected": int(tagged.get("rejected", 0)),
		"reason": String(queued.get("reason", tagged.get("reason", ""))),
	}
	return _last_report.duplicate(true)


## Soldier share of total population, Q16.
##
## Military counts soldiers; Economy owns population. The share is derived from
## the two committed readings rather than stored, so it cannot drift from
## either authority.
func _soldier_share_q16(snapshot: Dictionary, population_of: Callable) -> int:
	var soldiers := int(snapshot.get("soldiers_total", 0))
	if soldiers <= 0 or not population_of.is_valid():
		return 0
	var population := int(population_of.call(int(snapshot.get("country", 0))))
	if population <= 0:
		return 0
	var share := (soldiers * Q16_ONE) / (population + soldiers)
	return clampi(share, 0, Q16_ONE)


## Cells somebody other than their owner controls, split by whether that
## controller is the querier. The native side re-checks the controller column;
## this pass only decides WHICH cells to ask about.
func _occupation_rows(country_handles: PackedInt64Array, slots: Dictionary,
		owner_slot_of_cell: Callable) -> Dictionary:
	var out := {
		"by_us": PackedInt32Array(), "by_us_owner": PackedInt32Array(),
		"by_enemy": PackedInt32Array(), "by_enemy_owner": PackedInt32Array(),
		"us_slot": -1,
		# The occupation tags are published FOR one country at a time: "by us"
		# is meaningless without knowing who "us" is. The first handle the
		# caller lists is the one the tags are resolved against, which is the
		# player's own handle in every production call site.
	}
	var us_slot := -1
	for handle in country_handles:
		if slots.has(int(handle)):
			us_slot = int(slots[int(handle)])
			break
	out["us_slot"] = us_slot
	if _facade == null or not owner_slot_of_cell.is_valid() or us_slot < 0:
		return out
	var control: Dictionary = _facade.control_snapshot()
	if not bool(control.get("ok", false)):
		return out
	var cells: PackedInt32Array = control.get("cells", PackedInt32Array())
	var controllers: PackedInt32Array = control.get(
		"controller_slots", PackedInt32Array())
	var by_us: PackedInt32Array = out["by_us"]
	var by_us_owner: PackedInt32Array = out["by_us_owner"]
	var by_enemy: PackedInt32Array = out["by_enemy"]
	var by_enemy_owner: PackedInt32Array = out["by_enemy_owner"]
	for index in mini(cells.size(), controllers.size()):
		var cell := int(cells[index])
		var controller := int(controllers[index])
		if cell < 0 or controller < 0:
			continue
		var owner := int(owner_slot_of_cell.call(cell))
		if owner < 0 or owner == controller:
			continue
		# The owner is not the controller, so the cell is occupied. Whose
		# occupation it is decides which tag it lands in.
		if controller == us_slot:
			by_us.append(cell)
			by_us_owner.append(owner)
		else:
			by_enemy.append(cell)
			by_enemy_owner.append(owner)
	out["by_us"] = by_us
	out["by_us_owner"] = by_us_owner
	out["by_enemy"] = by_enemy
	out["by_enemy_owner"] = by_enemy_owner
	return out


static func _ascending(cells: Dictionary) -> PackedInt32Array:
	var keys := cells.keys()
	keys.sort()
	var out := PackedInt32Array()
	out.resize(keys.size())
	for index in keys.size():
		out[index] = int(keys[index])
	return out
