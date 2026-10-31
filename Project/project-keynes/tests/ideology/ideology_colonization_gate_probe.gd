extends SceneTree
## Probe: what exactly blocks `family_colonization_quotes` on a generated world?
##
## WHY
##
## M3-6 established that the colonization ISSUE path exists
## (`start_family_colonization` -> `enqueue_family_colonization_pod` ->
## `COMMAND_CLAIM_UNOWNED_TERRITORY`), but every quote attempt returned
## `colonization_target_invalid`. M3-6 GUESSED the visibility gate and explicitly
## said so; this probe replaces the guess with data.
##
## The runtime rejects a quote at several distinct points
## (economy_runtime_colonization.cpp:448-490):
##   * not bootstrapped / fatal / restore active / invalid country handle;
##   * target cell out of range;
##   * `visible == nullptr || visible_count != cell_count`;
##   * `visible[target] == 0`;
##   * trade topology not ready;
##   * `colonization_target_owner_allowed` false.
##
## Each has its own `code`, so printing the code per candidate tells us WHICH gate
## is closed instead of inferring it. That is the whole point: M3-6's mistake was
## inferring a mechanism from a search, and this round's rule is to read the code.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_colonization_gate_probe.gd

const WIDTH := 96
const HEIGHT := 64
const SEED := 20260227

var _host: Node = null
var _clock: Node = null


func _init() -> void:
	_run()


func _run() -> void:
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)
	_clock = clock

	var host := WorldRuntimeHost.new()
	host.map_width = WIDTH
	host.map_height = HEIGHT
	host.initial_seed = SEED
	host.generate_test_economy_data = false
	host.runtime_parity_forcing = false
	host.runtime_climate_authority_enabled = false
	get_root().add_child(host)
	_host = host
	await process_frame
	host.configure(null, null, clock)

	var config := NewGameConfig.create_default()
	config.country.name = "Gate Probe"
	config.country.foreign_count = 5
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	host.configure_session({"kind": "new_game", "config": config.to_dictionary()})
	await host.generate_world(SEED)

	var generator: MapGenerator = host.get_generator()
	if generator == null:
		printerr("PROBE: no generator")
		_quit(1)
		return
	var ext = generator.get_data_core_world_ext()
	if ext == null:
		printerr("PROBE: no DCWorldExt")
		_quit(2)
		return
	var map_data = generator.get_map_data() \
		if generator.has_method("get_map_data") else null

	# ── 1. visibility: is the plane actually populated? ────────────────────
	#
	# `_fog_of_war_enabled` defaults to false and `_refresh_vision` sets every
	# visible_arr entry to 1 in that case (world_runtime_host.gd:4880-4886), so the
	# plane should be all-ones. Verify rather than trust.
	if map_data != null:
		var visible: PackedByteArray = map_data.get("visible_arr")
		var ones := 0
		for v in visible:
			if v != 0:
				ones += 1
		print("[gate] visible_arr size=%d nonzero=%d fog_of_war=%s"
			% [visible.size(), ones,
				str(host.is_fog_of_war_enabled()
					if host.has_method("is_fog_of_war_enabled") else "?")])
	else:
		print("[gate] map_data unavailable -- cannot read visible_arr")

	# ── 2. find a real country handle ─────────────────────────────────────
	var territories: Dictionary = ext.get_country_territory_counts()
	var slots: PackedInt64Array = territories.get("slots", PackedInt64Array())
	var handle := 0
	var owned_cell := -1
	for cell in range(0, WIDTH * HEIGHT):
		var cs: Dictionary = ext.get_country_cell_summary(cell)
		if not bool(cs.get("ok", false)):
			continue
		if bool(cs.get("owned", false)):
			handle = int(cs.get("country_handle", 0))
			owned_cell = cell
			if handle != 0:
				break
	print("[gate] first owned cell=%d handle=%d slots=%d"
		% [owned_cell, handle, slots.size()])
	if handle == 0:
		print("[gate] no owned cell found -- nothing to colonize with")
		_quit(0)
		return

	# ── 3. quote every distinct rejection code, grouped ───────────────────
	#
	# Sampling a WIDE spread of cells matters: the first attempt only tried a few
	# and got one code, which read as "nothing works" when in fact one specific gate
	# was closed. Group by (code) so the shape is visible.
	var codes: Dictionary = {}
	var ok_count := 0
	var total_quotes := 0
	var stride := 37
	var cell := 0
	while cell < WIDTH * HEIGHT:
		var quotes: Dictionary = ext.get_family_colonization_quotes(
			handle, cell, 0, -1, 0, 8)
		if bool(quotes.get("ok", false)):
			ok_count += 1
			var rows: Array = quotes.get("quotes", [])
			total_quotes += rows.size()
		else:
			var code := String(quotes.get("code", "unknown"))
			codes[code] = int(codes.get(code, 0)) + 1
		cell += stride
	print("[gate] sampled cells ok=%d quotes=%d" % [ok_count, total_quotes])
	# DECISIVE: per-gate breakdown for one unowned cell. The public quotes call
	# collapses six gates into one code, which is why two rounds of guessing
	# happened; this prints each gate separately.
	var probe_target := 0
	for cell2 in range(0, WIDTH * HEIGHT):
		var cs2: Dictionary = ext.get_country_cell_summary(cell2)
		if bool(cs2.get("ok", false)) and not bool(cs2.get("owned", false)):
			probe_target = cell2
			break
	var diag: Dictionary = ext.diagnose_colonization_target(handle, probe_target)
	print("[gate] DIAGNOSIS cell=%d -> %s" % [probe_target, str(diag)])
	# WHY the plane is empty: a player slot of -1 makes `VisionSolver.solve` return
	# an all-zero plane, which is CORRECT behaviour for "nobody is playing" rather
	# than a defect. Confirm the slot so the cause is data, not inference.
	var slot_now := -99
	if host.has_method("player_country_slot"):
		slot_now = int(host.player_country_slot())
	elif host.has_method("_resolve_player_country_slot"):
		slot_now = int(host._resolve_player_country_slot())
	print("[gate] player_country_slot=%d" % slot_now)
	# The slot comes from `gameplay_start_report()` (world_runtime_host.gd:4822-4839).
	# Print it so the chain -1 is traceable to its first broken link rather than
	# guessed at.
	if generator.has_method("gameplay_start_report"):
		var start_report: Dictionary = generator.gameplay_start_report()
		print("[gate] gameplay_start_report ok=%s cell=%s"
			% [str(start_report.get("ok", "?")), str(start_report.get("cell", "?"))])
	else:
		print("[gate] gameplay_start_report missing")
	# And whether the country map even has slots assigned.
	var csa: PackedInt32Array = map_data.get("country_slot_arr") if map_data != null 		else PackedInt32Array()
	var assigned := 0
	for v in csa:
		if v >= 0:
			assigned += 1
	print("[gate] country_slot_arr size=%d assigned=%d" % [csa.size(), assigned])

	# ── THE FIX ATTEMPT ───────────────────────────────────────────────────
	#
	# `country_slot_arr` is written in exactly ONE place: the country worker read
	# view (`world_runtime_host.gd:1647`), which only runs under worker authority.
	# A headless fixture never triggers it, so the plane stays empty and every
	# vision solve returns all-zero.
	#
	# There IS a direct path: `ext.sync_country_territory_to_map()` pushes the native
	# territory into MapData (`world_runtime_host.gd:4843` calls it). Calling it here
	# tests whether that alone is enough to make polarization reachable.
	var synced: Dictionary = ext.sync_country_territory_to_map()
	print("[gate] sync_country_territory_to_map -> ok=%s code=%s"
		% [str(synced.get("ok", "?")),
			str(synced.get("reason", synced.get("code", "?")))])
	var csa2: PackedInt32Array = map_data.get("country_slot_arr") if map_data != null \
		else PackedInt32Array()
	var assigned2 := 0
	for v in csa2:
		if v >= 0:
			assigned2 += 1
	print("[gate] AFTER sync: country_slot_arr size=%d assigned=%d"
		% [csa2.size(), assigned2])
	# Re-solve vision and re-diagnose.
	if host.has_method("_refresh_vision"):
		host._refresh_vision()
	var diag2: Dictionary = ext.diagnose_colonization_target(handle, probe_target)
	print("[gate] AFTER sync DIAGNOSIS: %s" % str(diag2))
	var quotes2: Dictionary = ext.get_family_colonization_quotes(
		handle, probe_target, 0, -1, 0, 8)
	print("[gate] AFTER sync quotes ok=%s code=%s rows=%s"
		% [str(quotes2.get("ok", "?")), str(quotes2.get("code", "-")),
			str((quotes2.get("quotes", []) as Array).size())])

	# ── SECOND gate: `economy_runtime_colonization.cpp:496` ───────────────
	#
	#     if (_trade_topology.passable[target_cell] == 0 && !_epoch_active)
	#         -> colonization_target_invalid
	#
	# A cell with no trade route is refused unless an epoch is active. So the next
	# thing to try is opening an epoch, which is also what the production daily loop
	# does before any quote is meaningful.
	var epoch_opened := false
	if ext.has_method("begin_or_reuse_economy_input_epoch"):
		var epoch: Dictionary = ext.begin_or_reuse_economy_input_epoch(0, 1)
		epoch_opened = bool(epoch.get("ok", false))
		print("[gate] begin_or_reuse_economy_input_epoch -> ok=%s code=%s"
			% [str(epoch.get("ok", "?")),
				str(epoch.get("reason", epoch.get("code", "-")))])
	var quotes3: Dictionary = ext.get_family_colonization_quotes(
		handle, probe_target, 0, -1, 0, 8)
	print("[gate] AFTER epoch quotes ok=%s code=%s rows=%s"
		% [str(quotes3.get("ok", "?")), str(quotes3.get("code", "-")),
			str((quotes3.get("quotes", []) as Array).size())])
	# And sample a spread again with everything open.
	var ok3 := 0
	var tot3 := 0
	var codes3: Dictionary = {}
	var c3 := 0
	while c3 < WIDTH * HEIGHT:
		var q3: Dictionary = ext.get_family_colonization_quotes(handle, c3, 0, -1, 0, 8)
		if bool(q3.get("ok", false)):
			ok3 += 1
			tot3 += (q3.get("quotes", []) as Array).size()
		else:
			var k3 := String(q3.get("code", "unknown"))
			codes3[k3] = int(codes3.get(k3, 0)) + 1
		c3 += 211
	print("[gate] FINAL sampled ok=%d quotes=%d codes=%s"
		% [ok3, tot3, str(codes3)])
	var keys: Array = codes.keys()
	for k in keys:
		print("[gate]   refused code=%s count=%d" % [String(k), int(codes[k])])

	if _host != null and is_instance_valid(_host):
		_host.queue_free()
	if _clock != null and is_instance_valid(_clock):
		_clock.queue_free()
	_quit(0)


func _quit(code: int) -> void:
	quit(code)
