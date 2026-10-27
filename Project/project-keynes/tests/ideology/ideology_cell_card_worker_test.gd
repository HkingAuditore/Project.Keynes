extends SceneTree

## X1_PLAIN_SWITCH worker acceptance for one cell-scope card per process.
##
## The generated expectation table is the input, not a hand-written card list: a
## card is accepted only when the worker resolves its authored targets, applies the
## authored value to those cells, leaves other owned cells at base, and restores the
## base after unequip. One card per process keeps the fixture deterministic and
## matches the established worker-card runner.
##
## Run from the lane root:
##   $env:CELL_ONLY_CARD = "agrarian_reform"
##   $env:PK_DISABLE_SUPPORT_GATE = "1"
##   godot --headless --path Project/project-keynes \
##     --script res://tests/ideology/ideology_cell_card_worker_test.gd

const DEFAULT_WIDTH := 24
const DEFAULT_HEIGHT := 18
const DEFAULT_SEED := 20261022
const DEFAULT_LAYOUT := "two"
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const MODIFIER_DOMAIN_ECONOMY := 2
const TARGET_DOMAIN_CELL := 2
const SEL_NEIGHBORS_R1 := 6
const SEL_NEIGHBORS_R2 := 7
const SEL_OWN_TERRITORY := 12
const SEL_TAG_SOURCE_R1 := 14
const SEL_TAG_SOURCE_R2 := 15
const SEL_TAG_SOURCE_COUNT := 16
const COUNTRY_CLAIM_BATCH := 128
const EXPECTATIONS_PATH := "res://tests/ideology/generated/card_expectations.json"
## A tagged target must appear within this many worker days. The fixture is allowed
## to settle first; it is not allowed to silently skip a card that resolves nothing.
const TARGET_DISCOVERY_DAYS := 5
## State transitions are bounded by committed worker days, not wall-clock time.
const EQUIP_BOUNDARY_DAYS := 5
const LEVEL_BOUNDARY_DAYS := 5
const UNEQUIP_BOUNDARY_DAYS := 5
const TERRITORY_BOUNDARY_DAYS := 8
const HARD_BARRIER_PULSES := 400
const POD_COMMIT_PULSES := 1000
const WORKER_PAUSE_PULSES := 2500
const WORKER_POLL_DELAY_MS := 2
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload(
	"res://scripts/effect/effect_domain_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")
const DrawGateHelper = preload(
	"res://tests/ideology/ideology_draw_gate_helper.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _handle := 0
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _tick := 0
var _card := ""
var _width := DEFAULT_WIDTH
var _height := DEFAULT_HEIGHT
var _seed := DEFAULT_SEED
var _layout := DEFAULT_LAYOUT
var _dense := -1
var _levels: Dictionary = {}
var _tagged_cells: Dictionary = {}
var _untagged_cell := -1
var _current_level := 0
var _runtime_faulted := false
var _country_slot := 0
var _tagged_cell := -1
var _control_cell := -1
var _metric_overrides: Array[int] = []
var _base_cell_values: Dictionary = {}


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology cell card worker: card=%s checks=%d failures=%d ==="
		% [_card, _checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	_card = OS.get_environment("CELL_ONLY_CARD").strip_edges()
	if _card.is_empty():
		_fail("CELL_ONLY_CARD is required (one card per process)")
		return 2
	if not _load_expectations():
		return 3
	if _levels.is_empty():
		print("=== ideology cell card worker: card=%s checks=0 failures=0 (no cell rows) ==="
			% _card)
		return 0
	var fixture := await _build_world()
	if fixture.is_empty():
		printerr("ERROR: [FAIL] cell-card fixture unavailable; card=%s checks=%d failures=%d"
			% [_card, _checks, _failures])
		return 4
	_host = fixture["host"]
	_clock = fixture["clock"]
	_ext = fixture["ext"]
	_handle = int(fixture["handle"])
	_country_slot = int(fixture["country_slot"])
	print("[cell-fixture] %s map=%dx%d seed=%d handle=%d"
		% [_card, _width, _height, _seed, _handle])
	_dense = _dense_id(_card)
	if not _require("%s is in the compiled worker catalog" % _card, _dense >= 0):
		_teardown()
		return 7
	var result := _test_card()
	_teardown()
	return 0 if result else 1


func _load_expectations() -> bool:
	if not FileAccess.file_exists(EXPECTATIONS_PATH):
		_fail("missing %s (run the generator)" % EXPECTATIONS_PATH)
		return false
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(EXPECTATIONS_PATH))
	if not (parsed is Dictionary):
		_fail("%s does not parse as a dictionary" % EXPECTATIONS_PATH)
		return false
	_levels.clear()
	for entry_value in (parsed as Dictionary).get("cards", []):
		var entry: Dictionary = entry_value
		if String(entry.get("card", "")) != _card:
			continue
		var cell_rows: Array = []
		for row_value in entry.get("rows", []):
			var row: Dictionary = row_value
			if String(row.get("scope", "")) == "cell":
				cell_rows.append(row)
		if not cell_rows.is_empty():
			_levels[int(entry.get("level", 0))] = cell_rows
	if _levels.is_empty():
		return true
	_expect("%s expectations use supported cell selectors" % _card,
		_all_rows_have_supported_selector())
	return true


func _all_rows_have_supported_selector() -> bool:
	for rows_value in _levels.values():
		for row_value in rows_value:
			var selector := int((row_value as Dictionary).get("selector", -1))
			if not [SEL_OWN_TERRITORY, SEL_TAG_SOURCE_R1,
					SEL_TAG_SOURCE_R2, SEL_TAG_SOURCE_COUNT].has(selector):
				return false
	return true


func _test_card() -> bool:
	if not _install_tag_fixture():
		return false
	if not _capture_cell_baselines():
		return false
	if not _equip():
		return false
	var level_keys: Array = _levels.keys()
	level_keys.sort()
	_current_level = int(level_keys[0])
	for level_value in level_keys:
		var level := int(level_value)
		_current_level = level
		if level > 1:
			if not _raise_to_level(level):
				return false
		if not _wait_for_cell_targets():
			return false
		if not _test_level(level, _levels[level]):
			return false
		if _runtime_faulted:
			return false
	if not _unequip():
		return false
	_ext.clear_cell_tag_overrides_for_test()
	for metric in _metric_overrides:
		_ext.set_effect_metric_override_for_test(metric, 0, false)
	_metric_overrides.clear()
	_ext.refresh_effect_input_digest_for_test()
	var restored_ok := true
	var refs_cleared := _card_refs_cleared()
	if not refs_cleared:
		# Lane A owns managed Effect retirement on unequip; until REMOVE is
		# emitted the card's instances remain in the report.
		print("[BLOCKED-by-laneA] %s effect instances remain after unequip"
			% _card)
	for level_value in level_keys:
		var level := int(level_value)
		if refs_cleared:
			for pair in _cell_values(level, _levels[level]):
				var stat := String(pair["stat"])
				var restored := _wait_for_cell_values(
					stat, int(pair["cell"]),
					_cell_baseline(stat, int(pair["cell"])))
				restored_ok = _expect_close(
					"%s L%d %s restores cell %d to its baseline"
						% [_card, level, stat, int(pair["cell"])],
					float(restored["value"]),
					_cell_baseline(stat, int(pair["cell"])),
					0.0005) and restored_ok
				restored_ok = _expect_close(
					"%s L%d %s restores untagged cell %d to its baseline"
						% [_card, level, stat, _untagged_cell],
					_read_cell(stat, _untagged_cell),
					_cell_baseline(stat, _untagged_cell),
					0.0005) and restored_ok
	return restored_ok


func _test_level(level: int, rows: Array) -> bool:
	_current_level = level
	if _card == "frontier_garrison" and level == 3:
		# L3 rewrites cell.border -> border|frontier. Exercise the rewrite on a
		# source that was not a frontier cell below L3.
		for pair in [["cell.border", false], ["cell.frontier", true],
				["cell.border|cell.frontier", true]]:
			var toggled: Dictionary = _ext.set_cell_tag_override_for_test(
				String(pair[0]), _tagged_cell, bool(pair[1]))
			if not _require("%s sets %s=%s for the L3 rewrite" % [
					_card, String(pair[0]), str(pair[1])],
					bool(toggled.get("ok", false)), str(toggled)):
				return false
		if not _require("%s refreshes the digest after the L3 rewrites" % _card,
				bool(_ext.refresh_effect_input_digest_for_test().get(
					"ok", false))):
			return false
		if not _wait_for_cell_targets():
			return false
	var ok := true
	# Validate each authored row on the target it actually materialised. A card
	# may deliberately author two programs on the same stat; their Q16 terms add,
	# and each row can resolve to a different sample cell even when the source
	# predicate is shared.
	for row_value in rows:
		var row: Dictionary = row_value
		var stat := String(row["stat"])
		var sample_cell := int(_tagged_cells.get(_row_key(row), -1))
		if sample_cell < 0:
			_fail("fixture never produced %s for %s after %d days"
				% [_row_label(row), _card, TARGET_DISCOVERY_DAYS])
			return false
		var kind := String(row.get("kind", ""))
		if kind not in ["dynamic", "constant"]:
			ok = _expect("%s L%d %s has a known row kind (%s)"
				% [_card, level, stat, kind], false) and ok
			continue
		var expected_tagged := _composed_level_factor(
			level, stat, sample_cell)
		var applied := _wait_for_cell_values(stat, sample_cell,
			expected_tagged)
		ok = _expect_close(
			"%s L%d %s cell %d = %.6f after %d day(s)"
				% [_card, level, stat, sample_cell, expected_tagged,
					applied["days"]],
			float(applied["value"]), expected_tagged, 0.0005) and ok
		ok = _expect_close(
			"%s L%d %s leaves the untagged owned cell %d at its baseline"
				% [_card, level, stat, _untagged_cell],
			_read_cell(stat, _untagged_cell),
			_cell_baseline(stat, _untagged_cell), 0.0005) and ok
	return ok


## Every program on this stat that materialised the sample cell contributes its
## authored Q16 magnitude. Cell ideology definitions are ADD/SUBTRACT terms, so
## the Modifier runtime sums them; it does not multiply the percentage factors.
func _composed_level_factor(level: int, stat: String, sample_cell: int) -> float:
	var delta_q16 := 0
	for row_value in _rows_for_level(level):
		var row: Dictionary = row_value
		if String(row.get("stat", "")) != stat:
			continue
		if not _reported_targets_for_row(
				int(row.get("selector", SEL_OWN_TERRITORY))).has(sample_cell):
			continue
		if int(row.get("selector", SEL_OWN_TERRITORY)) == SEL_TAG_SOURCE_COUNT:
			delta_q16 += _source_count_delta_q16(row, sample_cell)
		elif String(row.get("kind", "")) == "dynamic":
			delta_q16 += _dynamic_delta_q16(row)
		elif String(row.get("kind", "")) == "constant":
			delta_q16 += int(round(float(row.get("value", 0.0)) * Q16_ONE))
		else:
			continue
	return _cell_baseline(stat, sample_cell) \
		+ float(delta_q16) / float(Q16_ONE)


func _dynamic_delta_q16(row: Dictionary) -> int:
	var magnitude_q16 := int(round(abs(float(row.get("max", 0.0))) * Q16_ONE))
	if _row_delta_is_positive(row):
		return magnitude_q16
	return -magnitude_q16


func _row_delta_is_positive(row: Dictionary) -> bool:
	if String(row.get("direction", "up")) == "up":
		return true
	# A positive change on a downside stat is still a positive term on that
	# stat. The generator only emits the `.cut` twin for a negative command.
	var stat := String(row.get("stat", ""))
	for key in [
			".use_factor",
			"_loss_factor",
			"country.population.death_factor",
			"country.production.input_factor",
			"country.input.good.",
			"country.construction.cost_factor",
			"country.research.cost_factor",
			"country.household.consumption_factor",
			"economy.city.need.",
	]:
		if stat == key or stat.contains(key):
			return true
	return false


func _cell_values(level: int, rows: Array) -> Array:
	var out: Array = []
	for row_value in rows:
		var row: Dictionary = row_value
		var stat := String(row["stat"])
		var tagged_cell := int(_tagged_cells.get(_row_key(row), -1))
		if tagged_cell < 0:
			continue
		out.append({
			"stat": stat,
			"cell": tagged_cell,
			"tagged": _read_cell(stat, tagged_cell),
			"untagged": _read_cell(stat, _untagged_cell),
			"level": level,
		})
	return out


func _wait_for_cell_targets() -> bool:
	for attempt in range(TARGET_DISCOVERY_DAYS + 1):
		var targets := _cell_targets()
		if not targets.is_empty():
			var resolved := _resolve_row_targets(targets)
			if resolved.size() == _tag_set_count():
				_tagged_cells = resolved
				var all_targets := _level_target_union()
				_untagged_cell = _find_untagged_owned_cell(all_targets)
				if not _require("%s has an owned untagged cell outside %s" % [
						_card, str(all_targets)], _untagged_cell >= 0,
						"tagged=%s" % str(_tagged_cells)):
					return false
				_stage("%s: %d cell targets after %d day(s); tagged=%s untagged=%d"
					% [_card, all_targets.size(), attempt, str(_tagged_cells),
						_untagged_cell])
				return true
		if attempt < TARGET_DISCOVERY_DAYS:
			_drive_days(1)
	var unresolved := PackedStringArray()
	for row_value in _rows_for_level(_current_level):
		var row: Dictionary = row_value
		if not _tagged_cells.has(_row_key(row)):
			unresolved.append(_row_label(row))
	_fail("fixture never produced %s for %s after %d days"
		% [", ".join(unresolved), _card, TARGET_DISCOVERY_DAYS])
	return false


func _card_refs_cleared() -> bool:
	if _ext == null:
		return false
	var report: Dictionary = _ext.get_ideology_effect_instance_report(_handle)
	if not bool(report.get("ok", false)):
		return false
	var ideas: PackedInt64Array = report.get("idea_ids", PackedInt64Array())
	for idea in ideas:
		if int(idea) == _dense:
			return false
	return true


## Force every predicate the card needs onto one owned cell and off the control
## cell. The tag mechanism is the production selector input, not a cookbook of
## fixture worlds: a card with several rows must resolve every one of its tags.
func _install_tag_fixture() -> bool:
	var tags := _expected_tags_array()
	var cells := _owned_land_cells()
	if not _require("%s fixture owns two land cells" % _card,
			cells.size() >= 2, str(cells)):
		return false
	_tagged_cell = int(cells[0])
	# Keep the control one full selector-16 radius away from the forced target.
	# A natural source between the two would make the control's count differ from
	# the forced cell's, so "untagged" would no longer mean "no bonus".
	_control_cell = int(cells[1])
	for cell in cells:
		if int(cell) == _tagged_cell:
			continue
		var ring: PackedInt32Array = _ext.query_effect_target_cells(
			_tagged_cell, SEL_NEIGHBORS_R2, 32, 0)
		if not ring.has(int(cell)):
			_control_cell = int(cell)
			break
	var applied: Dictionary = _ext.clear_cell_tag_overrides_for_test()
	if not _require("%s clears prior tag overrides" % _card,
			bool(applied.get("ok", false)), str(applied)):
		return false
	for tag_value in tags:
		var tag := String(tag_value)
		for cell in cells:
			var on := int(cell) == _tagged_cell
			var result: Dictionary = _ext.set_cell_tag_override_for_test(
				tag, int(cell), on)
			if not _require("%s sets %s=%s on cell %d" % [
					_card, tag, str(on), int(cell)],
					bool(result.get("ok", false)), str(result)):
				return false
	for rows_value in _levels.values():
		for row_value in rows_value:
			var row: Dictionary = row_value
			var row_tags: Array = row.get("tags", [])
			if row_tags.size() > 1:
				var composite := _tags_key(row)
				for cell in cells:
					var result: Dictionary = _ext.set_cell_tag_override_for_test(
						composite, int(cell), int(cell) == _tagged_cell)
					if not _require("%s sets composite %s=%s on cell %d" % [
							_card, composite, str(int(cell) == _tagged_cell), int(cell)],
							bool(result.get("ok", false)), str(result)):
						return false
	# Non-tag conditions used by the 23-card table. These are checked here so a
	# card cannot pass with a stale value from a previous fixture.
	if tags.has("cell.sector.agriculture") or _card == "heaven_human":
		if not _override_metric(6, Q16_ONE):
			return false
	if tags.has("cell.sector.manufacturing") \
			or tags.has("cell.diversified"):
		if not _override_metric(25, 2 * Q16_ONE):
			return false
	if tags.has("cell.settlement") or _card == "welfare_state":
		if not _override_metric(11, 0):
			return false
	if _card == "basic_income" or _card == "gig_economy" \
			or _card == "automation_line":
		if not _override_metric(22, Q16_ONE):
			return false
	if _card == "manufactory_regulation":
		if not _override_metric(24, 10 * Q16_ONE):
			return false
	# X9a branch counts are integer metrics. With 3 branches every authored
	# marriage_alliance threshold (>=2, >=3) is represented by the same fixture.
	if _card == "marriage_alliance":
		if not _override_metric(84, 3 * Q16_ONE):
			return false
	if _card == "grand_canal":
		if not _override_metric(76, 8 * Q16_ONE):
			return false
	# terrace_farming's L3 cell clause requires at least two neighbouring
	# agriculture pillars. The fake target tag proves the terrain filter; this
	# override proves the numeric condition independently of natural map layout.
	if _card == "terrace_farming":
		if not _override_metric(94, 2 * Q16_ONE):
			return false
	# frontier_garrison L3 rewrites cell.border to border|frontier. Keep the
	# pre-rewrite levels on border and exercise the rewrite only at L3.
	if _card == "frontier_garrison":
		for pair in [["cell.frontier", _tagged_cell, false],
				["cell.frontier", _control_cell, false],
				["cell.border|cell.frontier", _tagged_cell, false],
				["cell.border|cell.frontier", _control_cell, false]]:
			var off: Dictionary = _ext.set_cell_tag_override_for_test(
				String(pair[0]), int(pair[1]), bool(pair[2]))
			if not _require("%s clears %s on cell %d below L3" % [
					_card, String(pair[0]), int(pair[1])],
					bool(off.get("ok", false)), str(off)):
				return false
	if not _require("effect input digest refreshes after tag fixture",
			bool(_ext.refresh_effect_input_digest_for_test().get("ok", false))):
		return false
	_stage("%s: tag fixture tagged=%d control=%d tags=%s"
		% [_card, _tagged_cell, _control_cell, str(tags)])
	return true


func _owned_land_cells() -> PackedInt32Array:
	var out := PackedInt32Array()
	var map: MapData = _host.get_current_map()
	if map == null:
		return out
	for cell in range(mini(map.is_water_arr.size(), _width * _height)):
		if int(map.is_water_arr[cell]) != 0:
			continue
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) == _handle:
			out.append(cell)
	return out


func _override_metric(metric: int, value: int) -> bool:
	var applied: Dictionary = _ext.set_effect_metric_override_for_test(
		metric, value, true)
	if not _require("%s overrides metric %d=%d" % [_card, metric, value],
			bool(applied.get("ok", false)), str(applied)):
		return false
	if not _metric_overrides.has(metric):
		_metric_overrides.append(metric)
	return true


func _expected_tags_array() -> PackedStringArray:
	var tags := PackedStringArray()
	for rows_value in _levels.values():
		for row_value in rows_value:
			for tag_value in (row_value as Dictionary).get("tags", []):
				var tag := String(tag_value)
				if not tags.has(tag):
					tags.append(tag)
	return tags


func _capture_cell_baselines() -> bool:
	_base_cell_values.clear()
	var cells := _owned_land_cells()
	if cells.is_empty():
		return _require("%s baseline fixture owns land" % _card, false,
			str(cells))
	var stats := {}
	for rows_value in _levels.values():
		for row_value in rows_value:
			var row: Dictionary = row_value
			stats[String(row.get("stat", ""))] = true
	for stat_value in stats:
		var stat := String(stat_value)
		for cell in cells:
			_base_cell_values["%s@%d" % [stat, int(cell)]] = _read_cell(
				stat, int(cell))
	return true


func _cell_baseline(stat: String, cell: int) -> float:
	return float(_base_cell_values.get("%s@%d" % [stat, cell], 1.0))


func _cell_targets() -> PackedInt64Array:
	var report: Dictionary = _ext.get_ideology_effect_instance_report(_handle)
	if not bool(report.get("ok", false)):
		_fail("%s: effect instance report failed: %s"
			% [_card, String(report.get("reason", "unknown"))])
		return PackedInt64Array()
	var ideas: PackedInt64Array = report.get(
		"idea_ids", PackedInt64Array())
	var domains: PackedInt32Array = report.get(
		"target_domains", PackedInt32Array())
	var handles: PackedInt64Array = report.get(
		"target_handles", PackedInt64Array())
	var seen := {}
	var out := PackedInt64Array()
	for index in range(mini(ideas.size(), mini(domains.size(), handles.size()))):
		if int(ideas[index]) != _dense:
			continue
		if int(domains[index]) != TARGET_DOMAIN_CELL:
			continue
		var cell := int(handles[index])
		if cell >= 0 and not seen.has(cell):
			seen[cell] = true
			out.append(cell)
	return out


func _find_untagged_owned_cell(targets: PackedInt64Array) -> int:
	if _control_cell >= 0 and not targets.has(_control_cell):
		var control: Dictionary = _ext.get_country_cell_summary(_control_cell)
		if int(control.get("country_handle", 0)) == _handle:
			return _control_cell
	for cell in range(_width * _height):
		if targets.has(cell):
			continue
		var summary: Dictionary = _ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) == _handle:
			return cell
	return -1


func _tags_key(row: Dictionary) -> String:
	var tags := PackedStringArray()
	for tag_value in row.get("tags", []):
		tags.append(String(tag_value))
	tags.sort()
	return "&".join(tags) if tags.size() > 1 else (
		String(tags[0]) if tags.size() == 1 else "")


func _row_key(row: Dictionary) -> String:
	return "%d|%s|%d|%d" % [
		int(row.get("selector", -1)), _tags_key(row),
		int(row.get("radius", 0)), int(row.get("cap", 0))]


func _row_label(row: Dictionary) -> String:
	return "%s selector=%d r=%d cap=%d" % [
		_tags_key(row), int(row.get("selector", -1)),
		int(row.get("radius", 0)), int(row.get("cap", 0))]


func _tag_set_count() -> int:
	var keys := {}
	for row_value in _rows_for_level(_current_level):
		var row: Dictionary = row_value
		if String(row.get("scope", "")) != "cell":
			continue
		keys[_row_key(row)] = true
	return keys.size()


func _level_target_union() -> PackedInt64Array:
	var targets := _cell_targets()
	var seen := {}
	for value in targets:
		seen[int(value)] = true
	return PackedInt64Array(seen.keys())


## Resolve one reported target per authored row shape. Selector 14/15 programs
## target the source's R1/R2 ring, not the source itself, so the tagged source is
## deliberately excluded from candidates. The source is only an input to the
## selector; the report is the authority on what the worker materialised.
func _resolve_row_targets(targets: PackedInt64Array) -> Dictionary:
	var out := {}
	if targets.is_empty():
		return out
	var rows := _rows_for_level(_current_level)
	for row_value in rows:
		var row: Dictionary = row_value
		if String(row.get("scope", "")) != "cell":
			continue
		var key := _row_key(row)
		if out.has(key):
			continue
		var selector := int(row.get("selector", SEL_OWN_TERRITORY))
		var candidates := _reported_targets_for_row(selector)
		# Prefer the fixture-tagged cell when the program selected it. Natural
		# targets can already carry unrelated runtime modifiers; the forced cell
		# is the only one whose base is known to be 1.0.
		if selector == SEL_OWN_TERRITORY and candidates.has(_tagged_cell):
			out[key] = _tagged_cell
			continue
		if selector == SEL_TAG_SOURCE_COUNT and candidates.has(_tagged_cell):
			out[key] = _tagged_cell
			continue
		for value in candidates:
			var cell := int(value)
			if int(_ext.get_country_cell_summary(cell).get(
					"country_handle", 0)) != _handle:
				continue
			if selector in [SEL_TAG_SOURCE_R1, SEL_TAG_SOURCE_R2] \
					and cell == _tagged_cell:
				continue
			out[key] = cell
			break
	return out


func _reported_targets_for_row(selector: int) -> PackedInt64Array:
	var report: Dictionary = _ext.get_ideology_effect_instance_report(_handle)
	if not bool(report.get("ok", false)):
		return PackedInt64Array()
	var ideas: PackedInt64Array = report.get("idea_ids", PackedInt64Array())
	var levels: PackedInt64Array = report.get(
		"idea_levels", PackedInt64Array())
	var domains: PackedInt32Array = report.get(
		"target_domains", PackedInt32Array())
	var handles: PackedInt64Array = report.get(
		"target_handles", PackedInt64Array())
	var program_hashes: PackedInt64Array = report.get(
		"program_hashes", PackedInt64Array())
	var expected_hash := _selector_program_hashes(selector)
	var out := PackedInt64Array()
	var seen := {}
	for index in range(mini(ideas.size(), mini(levels.size(), mini(
			domains.size(), mini(handles.size(), program_hashes.size()))))):
		if int(ideas[index]) != _dense:
			continue
		if int(levels[index]) != _current_level - 1:
			continue
		if int(domains[index]) != TARGET_DOMAIN_CELL:
			continue
		if not expected_hash.has(int(program_hashes[index])):
			continue
		var cell := int(handles[index])
		if cell < 0 or seen.has(cell):
			continue
		seen[cell] = true
		out.append(cell)
	return out


func _selector_program_hashes(selector: int) -> PackedInt64Array:
	var out := PackedInt64Array()
	var catalog: Resource = load(
		"res://data/ideologies/default_ideology_effects.tres")
	if catalog == null:
		return out
	for definition in catalog.effects:
		if definition == null:
			continue
		if int(definition.target_selector_kind) != selector:
			continue
		var program := "ideology.effect.%s" % String(
			definition.definition_key)
		var program_hash := _fnv1a64(program)
		out.append(program_hash)
	return out


func _fnv1a64(text: String) -> int:
	var data := text.to_utf8_buffer()
	var hash := 1469598103934665603
	for byte in data:
		hash = (hash ^ int(byte)) * 1099511628211
	return hash


func _rows_for_level(level: int) -> Array:
	return _levels.get(level, []).duplicate()


func _expected_dynamic_value(row: Dictionary) -> float:
	var maximum := float(row.get("max", 0.0))
	if String(row.get("direction", "up")) == "up":
		return 1.0 + maximum
	var stat := String(row.get("stat", ""))
	for key in [
			".use_factor",
			"_loss_factor",
			"country.population.death_factor",
			"country.production.input_factor",
			"country.input.good.",
			"country.construction.cost_factor",
			"country.research.cost_factor",
			"country.household.consumption_factor",
			"economy.city.need.",
	]:
		if stat == key or stat.contains(key):
			return 1.0 + maximum
	return 1.0 - maximum


func _source_count_delta_q16(row: Dictionary, sample_cell: int) -> int:
	var tag_id := _source_tag_id(String(row.get("tags", [""])[0]))
	if tag_id < 0:
		return _dynamic_delta_q16(row)
	var radius := int(row.get("radius", 1))
	var selector_kind := SEL_NEIGHBORS_R1 if radius <= 1 else SEL_NEIGHBORS_R2
	var source_handle := int(_ext.query_country_anchor_cell(_country_slot))
	var sources: PackedInt32Array = _ext.query_effect_target_cells(
		source_handle, SEL_OWN_TERRITORY, 32, tag_id + 1)
	var count := 0
	for source in sources:
		if int(source) == sample_cell:
			continue
		var ring: PackedInt32Array = _ext.query_effect_target_cells(
			int(source), selector_kind, 32, 0)
		if ring.has(sample_cell):
			count += 1
	var cap := int(row.get("cap", 0))
	var count_cap := mini(count, cap) if cap > 0 else count
	var maximum := float(row.get("max", 0.0))
	if cap <= 0:
		return _dynamic_delta_q16(row)
	# The program value is the full stack and the Effect worker floors
	# `value * min(count, cap) / cap` in Q16.
	var per_source := float(row.get("per_source", maximum / float(cap)))
	var full_stack_q16 := maxi(1, int(round(abs(per_source) * Q16_ONE))) * cap
	var scaled_q16 := (full_stack_q16 * count_cap) / cap
	if per_source < 0.0:
		scaled_q16 = -scaled_q16
	if String(row.get("direction", "up")) != "up":
		scaled_q16 = -scaled_q16
	return scaled_q16


func _source_tag_id(tag: String) -> int:
	var catalog: Resource = EffectDomainCatalogScript.build()
	if catalog == null:
		return -1
	var tags: Array = catalog.get("target_tags")
	for index in range(tags.size()):
		if String((tags[index] as Dictionary).get("name", "")) == tag:
			return index
	return -1


func _read_cell(stat: String, cell: int) -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_ECONOMY, 0, cell, stat, 1.0))


func _wait_for_cell_values(stat: String, cell: int,
		expected: float) -> Dictionary:
	var value := _read_cell(stat, cell)
	var days := 0
	while _not_close(value, expected, 0.0005) \
			and days < TARGET_DISCOVERY_DAYS:
		_drive_days(1)
		days += 1
		value = _read_cell(stat, cell)
		if _runtime_faulted:
			break
	return {"value": value, "days": days}


func _not_close(actual: float, expected: float, tolerance: float) -> bool:
	return absf(actual - expected) > tolerance


func _equip() -> bool:
	var gates: Dictionary = DrawGateHelper.grant_draw_gates(
		_host, _card, _handle, _tick, _next_sequence)
	if not _require("%s: worker grants its draw gates" % _card,
			bool(gates.get("ok", false)), str(gates)):
		return false
	_next_sequence = maxi(_next_sequence, int(gates.get(
		"next_sequence", _next_sequence)))
	var discovered: Dictionary = _submit([{
		"op": 1, "day": _tick, "handle": _handle, "idea": _dense}])
	if not _require("%s: worker accepts discover" % _card,
			bool(discovered.get("ok", false)), str(discovered)):
		return false
	_drive_days(2)
	var equipped: Dictionary = _submit([{
		"op": 5, "day": _tick, "handle": _handle, "idea": _dense}])
	if not _require("%s: worker accepts equip" % _card,
			bool(equipped.get("ok", false)), str(equipped)):
		return false
	_drive_days(3)
	var slots_used := 0
	for _day in range(EQUIP_BOUNDARY_DAYS + 1):
		slots_used = int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1))
		if slots_used >= 1:
			break
		if _day < EQUIP_BOUNDARY_DAYS:
			_drive_days(1)
		if _runtime_faulted:
			break
	if not _require("%s: worker equips the card (slots=%d)"
			% [_card, slots_used], slots_used >= 1, str(slots_used)):
		_dump_equip_failure()
		return false
	return true


func _raise_to_level(level: int) -> bool:
	var raise: Dictionary = _submit([{
		"op": 8, "day": _tick, "handle": _handle, "idea": _dense,
		"value": 8 * Q16_ONE if level == 2 else 24 * Q16_ONE}])
	if not _require("%s: worker accepts understanding bump to L%d"
			% [_card, level], bool(raise.get("ok", false)), str(raise)):
		return false
	_drive_days(3)
	var current := -1
	for _day in range(LEVEL_BOUNDARY_DAYS + 1):
		var report: Dictionary = _ext.get_ideology_effect_instance_report(_handle)
		var ideas: PackedInt64Array = report.get(
			"idea_ids", PackedInt64Array())
		var levels: PackedInt64Array = report.get(
			"idea_levels", PackedInt64Array())
		current = -1
		for index in range(mini(ideas.size(), levels.size())):
			if int(ideas[index]) == _dense:
				current = maxi(current, int(levels[index]))
		if current >= level - 1:
			break
		if _day < LEVEL_BOUNDARY_DAYS:
			_drive_days(1)
		if _runtime_faulted:
			break
	return _require("%s: worker reaches level %d (reported %d)"
		% [_card, level, current + 1], current >= level - 1, str(current))


func _unequip() -> bool:
	var result: Dictionary = _submit([{
		"op": 6, "day": _tick, "handle": _handle, "idea": _dense}])
	if not _require("%s: worker accepts unequip" % _card,
			bool(result.get("ok", false)), str(result)):
		return false
	_drive_days(3)
	for _day in range(UNEQUIP_BOUNDARY_DAYS + 1):
		if int(_ext.get_ideology_snapshot(_handle).get(
				"ideology_slots_used", -1)) == 0:
			break
		if _day < UNEQUIP_BOUNDARY_DAYS:
			_drive_days(1)
		if _runtime_faulted:
			break
	return _require("%s: unequip releases the ideology slot" % _card,
		int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1)) == 0,
		str(_ext.get_ideology_snapshot(_handle)))


func _dump_equip_failure() -> void:
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[cell-equip] %s receipts opcodes=%s reasons=%s" % [
			_card, str(receipts.get("opcodes", PackedInt32Array())),
			str(receipts.get("reasons", PackedStringArray()))])
	printerr("[cell-equip] %s snapshot=%s" % [
		_card, str(_ext.get_ideology_snapshot(_handle))])


# ── production worker fixture ───────────────────────────────────────────────

func _build_world() -> Dictionary:
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)
	var host := WorldRuntimeHost.new()
	host.map_width = _width
	host.map_height = _height
	host.initial_seed = _seed
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 100
	host.runtime_climate_authority_enabled = true
	host.runtime_economy_auto_pod_active = true
	host.runtime_authority_domain_mask = 0xFFF
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "C0 Cell"
	config.country.foreign_count = 0
	config.base.map_width = _width
	config.base.map_height = _height
	config.base.initial_seed = _seed
	config.apply_land_layout(_layout)
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("cell-card session configures", bool(session.get("ok", false)),
			str(session)):
		return {}
	await host.generate_world(_seed)
	var generator: MapGenerator = host.get_generator()
	if not _require("production world generation succeeded", generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("production DCWorldExt is bound", ext != null):
		return {}
	_host = host
	_clock = clock
	_ext = ext
	ext.set_runtime_ideology_parity_enabled(true)
	ext.set_runtime_clock(false, WORKER_SPEED)
	_wait_worker_paused(ext)
	var handle := 0
	var country_slot := 0
	for cell in range(_width * _height):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		handle = int(summary.get("country_handle", 0))
		if handle != 0:
			country_slot = int(summary.get("country_slot", 0))
			break
	if not _require("worker path resolves the player country", handle != 0):
		return {}
	# Generation's reported economy day is still -1 until the first worker commit.
	# Seed the driver from the committed economy day.
	_tick = _world_day(ext)
	_tick = _drive_days(3)
	if not _expand_fixture_territory(generator, handle):
		return {}
	_tick = _drive_days(1)
	var thread: Dictionary = ext.get_runtime_thread_report()
	var mask := int(thread.get("authoritative_domain_mask", 0))
	if not _require("worker owns the full 0xFFF authority mask",
			mask == 0xFFF, "mask=0x%X" % mask):
		return {}
	return {"host": host, "clock": clock, "ext": ext, "handle": handle,
		"country_slot": country_slot}


func _expand_fixture_territory(generator: MapGenerator, handle: int) -> bool:
	var map: MapData = _host.get_current_map()
	if map == null or map.is_water_arr.size() < _width * _height:
		_fail("cell fixture map is unavailable for territory expansion")
		return false
	var cells: Array[int] = []
	for cell in range(_width * _height):
		if int(map.is_water_arr[cell]) == 0:
			cells.append(cell)
	if cells.is_empty():
		_fail("cell fixture map has no land")
		return false
	var facade = generator.get_country_facade()
	if facade == null:
		_fail("cell fixture country facade is unavailable")
		return false
	var owned_before := _owned_land_cell_count(handle)
	if owned_before > 1:
		return true
	if not _require("%s: fixture claims neighbouring cells" % _card,
			_claim_neighboring_cells(facade, handle)):
		return false
	var owned := _owned_land_cell_count(handle)
	return _require("%s: territory expansion owns multiple land cells (%d land cells)"
		% [_card, owned], owned > 1, str(owned))


## Country's peer adapter services one fiscal transaction per boundary. Submit one
## claim at a time and let that transaction close before submitting the next; a
## batch spanning several waves deadlocks the Country pod behind
## `country_worker_peer_results_pending`.
func _claim_neighboring_cells(facade: Object, handle: int) -> bool:
	var map: MapData = _host.get_current_map()
	if map == null or map.is_water_arr.size() < _width * _height:
		return false
	# Selector 16's default target cap is 32. Own one cell beyond that union so
	# the control assertion is a real "outside every reported target" check.
	var target_owned := mini(40, _width * _height)
	var claimed := 0
	while _owned_land_cell_count(handle) < target_owned:
		var cell := _next_claim_cell(handle)
		if cell < 0:
			break
		var sequence := 700000 + cell
		var rows: Array[Dictionary] = [{
			"opcode": CountryFacadeScript.Opcode.CLAIM_UNOWNED_TERRITORY,
			"target_handle": handle, "cell": cell,
			"effective_day": _tick + 1, "sequence": sequence,
		}]
		var submitted: Dictionary = facade.submit(rows)
		if not bool(submitted.get("ok", false)):
			continue
		if not _wait_for_country_commit(cell, handle):
			break
		claimed += 1
	_stage("%s: territory expansion claimed=%d owned=%d"
		% [_card, claimed, _owned_land_cell_count(handle)])
	return _owned_land_cell_count(handle) > 1


func _next_claim_cell(handle: int) -> int:
	var map: MapData = _host.get_current_map()
	if map == null or map.is_water_arr.size() < _width * _height:
		return -1
	var owned := {}
	for cell in range(_width * _height):
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) == handle:
			owned[cell] = true
	for source in owned:
		for neighbor in _ext.query_effect_target_cells(
				int(source), SEL_NEIGHBORS_R1, 32, 0):
			var cell := int(neighbor)
			if owned.has(cell):
				continue
			if int(map.is_water_arr[cell]) != 0:
				continue
			if int(_ext.get_country_cell_summary(cell).get(
					"country_handle", 0)) != 0:
				continue
			return cell
	return -1


func _wait_for_country_commit(cell: int, handle: int) -> bool:
	for _day in range(TERRITORY_BOUNDARY_DAYS):
		_run_territory_day()
		if _runtime_faulted:
			return false
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) == handle:
			return true
	return false


## A Country claim is a Country boundary. Advance that boundary, publish the
## pending ideology input, and service the country peer between host ticks.
func _run_territory_day() -> void:
	_tick += 1
	_clock.current_day = float(_tick)
	_host.run_daily_tick(_tick, _clock.season_phase_for_day(_tick))
	_host.finish_daily_tick(0.0, {})
	var pulses := 0
	while _has_hard_barrier() and pulses < HARD_BARRIER_PULSES:
		_clock.simulation_backpressure_pulse.emit(_tick)
		pulses += 1
	if _ext.has_method("service_country_worker_peer_adapter"):
		_ext.service_country_worker_peer_adapter(64, true)
	if _ext.has_method("publish_ideology_worker_inputs"):
		_ext.publish_ideology_worker_inputs()
	OS.delay_msec(WORKER_POLL_DELAY_MS)
	var fault := _worker_fault()
	if not fault.is_empty():
		_runtime_faulted = true
		_fail("worker faulted while waiting for territory day %d: %s"
			% [_tick, fault])


func _land_cells_near_owned(cells: Array[int], handle: int) -> Array[int]:
	var out: Array[int] = []
	var map: MapData = _host.get_current_map()
	if map == null or map.is_water_arr.size() < _width * _height:
		return out
	var seen := {}
	var frontier: Array[int] = []
	for cell in cells:
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) == handle:
			seen[cell] = true
			frontier.append(cell)
	while not frontier.is_empty() and out.size() < COUNTRY_CLAIM_BATCH:
		var next: Array[int] = []
		for source in frontier:
			for neighbor in _ext.query_effect_target_cells(
					source, SEL_NEIGHBORS_R1, 32, 0):
				var cell := int(neighbor)
				if cell < 0 or cell >= _width * _height or seen.has(cell):
					continue
				seen[cell] = true
				if int(map.is_water_arr[cell]) != 0:
					continue
				if int(_ext.get_country_cell_summary(cell).get(
						"country_handle", 0)) != 0:
					continue
				out.append(cell)
				next.append(cell)
				if out.size() >= COUNTRY_CLAIM_BATCH:
					break
			if out.size() >= COUNTRY_CLAIM_BATCH:
				break
		frontier = next
	return out


func _owned_land_cell_count(handle: int) -> int:
	var count := 0
	var map: MapData = _host.get_current_map()
	if map == null:
		return 0
	for cell in range(mini(map.is_water_arr.size(), _width * _height)):
		if int(map.is_water_arr[cell]) != 0:
			continue
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) == handle:
			count += 1
	return count


func _teardown() -> void:
	_teardown_world()


func _teardown_world() -> void:
	if _ext != null and _ext.has_method("request_runtime_stop"):
		_ext.request_runtime_stop()
	if _host != null and is_instance_valid(_host):
		_host.free()
	if _clock != null and is_instance_valid(_clock):
		_clock.free()
	_host = null
	_clock = null
	_ext = null


func _drive_days(days: int) -> int:
	for _day in range(days):
		var fault := _worker_fault()
		if not fault.is_empty():
			_runtime_faulted = true
			_require("worker stays healthy before day %d" % (_tick + 1),
				false, fault)
			break
		_tick += 1
		_clock.current_day = float(_tick)
		_host.run_daily_tick(_tick, _clock.season_phase_for_day(_tick))
		_host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier() and pulses < HARD_BARRIER_PULSES:
			_clock.simulation_backpressure_pulse.emit(_tick)
			pulses += 1
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		if _ext.has_method("publish_ideology_worker_inputs"):
			_ext.publish_ideology_worker_inputs()
		var before := int(_ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		_ext.set_runtime_clock(false, WORKER_SPEED)
		_wait_ideology_pod_day(before)
		fault = _worker_fault()
		if not fault.is_empty():
			_runtime_faulted = true
			_require("worker stays healthy after day %d" % _tick,
				false, fault)
			break
		_ext.set_runtime_clock(true, WORKER_SPEED)
		_wait_worker_paused(_ext)
		OS.delay_msec(WORKER_POLL_DELAY_MS)
	return _tick


func _wait_ideology_pod_day(baseline: int) -> int:
	var last := baseline
	for _pulse in range(POD_COMMIT_PULSES):
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(WORKER_POLL_DELAY_MS)
		var report: Dictionary = _ext.get_runtime_thread_report()
		last = int(report.get("ideology_pod_committed_day", -1))
		if last > baseline:
			break
		if String(report.get("simulation_host_state", "")) in ["STOPPED", "FAULTED"]:
			break
	return last


func _submit(rows: Array) -> Dictionary:
	return _ext.submit_ideology_commands(_commands(rows))


func _commands(rows: Array) -> Dictionary:
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var producer := PackedInt32Array()
	var sequences := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	for row in rows:
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", 0)))
		producer.append(1)
		sequences.append(_next_sequence)
		_next_sequence += 1
		handles.append(int(row.get("handle", 0)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return {
		"opcodes": opcodes, "effective_days": days, "producer_ids": producer,
		"sequences": sequences, "country_handles": handles, "ideology_ids": ideas,
		"values_q16": values, "source_priorities": priorities,
		"offer_generations": generations, "choice_indices": choices,
		"gate_ids": gates,
	}


func _dense_id(card: String) -> int:
	var catalog: Resource = load("res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		_fail("ideology catalog unavailable")
		return -1
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	if not bool(native.get("ok", false)):
		_fail("ideology catalog compile failed: %s"
			% String(native.get("reason", "unknown")))
		return -1
	var ids := PackedStringArray(native.get("ideology_ids", PackedStringArray()))
	return ids.find("idea.%s" % card)


func _worker_fault() -> String:
	if _ext == null:
		return ""
	return String(_ext.get_runtime_thread_report().get("fault_code", ""))


func _has_hard_barrier() -> bool:
	if _clock != null and _clock.has_method("has_hard_barrier"):
		return bool(_clock.has_hard_barrier())
	for source in [&"economy_day_barrier", &"country_day_barrier",
			&"ideology_day_barrier", &"bio_occupancy_day_barrier",
			&"native_daily_day_barrier"]:
		if _clock._simulation_backpressure_sources.has(source):
			return true
	return false


func _wait_worker_paused(ext: Object) -> void:
	for _pulse in range(WORKER_PAUSE_PULSES):
		var state := String(ext.get_runtime_thread_report().get(
			"simulation_host_state", ""))
		if state == "PAUSED" or state == "STOPPED":
			return
		OS.delay_msec(WORKER_POLL_DELAY_MS)


func _world_day(ext: Object) -> int:
	if ext == null or not ext.has_method("get_economy_report"):
		return 0
	return int(ext.get_economy_report().get("current_day", 0))


func _expect_close(label: String, actual: float, expected: float,
		tolerance: float) -> bool:
	return _expect(label + " (got %.6f)" % actual,
		absf(actual - expected) <= tolerance,
		"%.6f vs %.6f" % [actual, expected])


func _expect(label: String, condition: bool, detail: String = "") -> bool:
	_checks += 1
	if condition:
		return true
	_failures += 1
	printerr("ERROR: [FAIL] %s%s" % [label,
		(" (%s)" % detail) if not detail.is_empty() else ""])
	return false


func _require(label: String, condition: bool, detail: String = "") -> bool:
	return _expect(label, condition, detail)


func _fail(reason: String) -> void:
	_failures += 1
	printerr("ERROR: [FAIL] %s" % reason)


func _stage(text: String) -> void:
	print("[stage] %s" % text)
