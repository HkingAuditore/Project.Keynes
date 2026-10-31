extends SceneTree
## Minimal probe: which colonization gate is closed, and can a PASSABLE cell be
## colonized without an epoch?
##
## WHY THIS IS DELIBERATELY TINY
##
## The previous probe sampled 29 cells across a 6144-cell world; each quote call is
## costly and the fixture took 10+ minutes per run, twice stalling past the point
## where the answer was already known. This one samples a handful, prints once per
## gate, and exits.
##
## WHAT IT SETTLES
##
## `economy_runtime_colonization.cpp:496` rejects a cell with `passable == 0`
## UNLESS `_epoch_active`. Since the earlier probe showed quotes still failing after
## visibility was fixed, the question is whether ANY cell has passable != 0 -- if
## yes, colonization is reachable without opening an epoch at all.
##
## Run:
##   <godot> --headless --path Project/project-keynes \
##     -s tests/ideology/ideology_colonization_passable_probe.gd

const WIDTH := 96
const HEIGHT := 64
const SEED := 20260227


func _init() -> void:
	_run()


func _run() -> void:
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = WIDTH
	host.map_height = HEIGHT
	host.initial_seed = SEED
	host.generate_test_economy_data = false
	host.runtime_parity_forcing = false
	host.runtime_climate_authority_enabled = false
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)

	var config := NewGameConfig.create_default()
	config.country.name = "Passable Probe"
	config.country.foreign_count = 5
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	host.configure_session({"kind": "new_game", "config": config.to_dictionary()})
	await host.generate_world(SEED)

	var generator: MapGenerator = host.get_generator()
	var ext = generator.get_data_core_world_ext() if generator != null else null
	if ext == null:
		printerr("PROBE: no DCWorldExt")
		quit(1)
		return

	# Restore visibility first: without it every gate probe reads "not visible".
	#
	# ORDER MATTERS, and getting it wrong cost a run: `sync_country_territory_to_map`
	# does NOT write `visible_arr` at all (it only publishes the territory slot,
	# world_ext_country.cpp:1848-1862). Visibility comes from `_refresh_vision()`,
	# which reads the territory plane that sync just published. So: sync FIRST, then
	# refresh. Calling sync alone leaves the plane all-zero and every gate reads
	# "not visible" -- which looks identical to "the sync did nothing".
	ext.sync_country_territory_to_map()
	if host.has_method("_refresh_vision"):
		host._refresh_vision()

	# Find one owned cell's country handle.
	var handle := 0
	for cell in range(0, WIDTH * HEIGHT):
		var cs: Dictionary = ext.get_country_cell_summary(cell)
		if bool(cs.get("ok", false)) and bool(cs.get("owned", false)):
			handle = int(cs.get("country_handle", 0))
			if handle != 0:
				break
	print("[pass] handle=%d" % handle)
	if handle == 0:
		quit(0)
		return

	# ── how many cells are passable at all? ───────────────────────────────
	#
	# A crude but decisive census: walk a spread and count `target_passable`. If the
	# whole map reports 0, gate :496 can only be opened by an epoch, and that becomes
	# the answer instead of another guess.
	var passable_count := 0
	var sampled := 0
	var first_passable := -1
	var step := 53
	var cell2 := 0
	var total_cells: int = WIDTH * HEIGHT
	while cell2 < total_cells:
		var d: Dictionary = ext.diagnose_colonization_target(handle, cell2)
		++sampled
		if bool(d.get("target_passable", false)):
			++passable_count
			if first_passable < 0:
				first_passable = cell2
		cell2 += step
	print("[pass] sampled=%d passable=%d first_passable=%d topology_ready=%s epoch_active=%s"
		% [sampled, passable_count, first_passable,
			str(ext.diagnose_colonization_target(handle, 0).get("topology_ready", "?")),
			str(ext.diagnose_colonization_target(handle, 0).get("epoch_active", "?"))])

	# ── try a quote on the first passable cell ────────────────────────────
	if first_passable >= 0:
		var d2: Dictionary = ext.diagnose_colonization_target(handle, first_passable)
		print("[pass] first_passable diag=%s" % str(d2))
		var q: Dictionary = ext.get_family_colonization_quotes(
			handle, first_passable, 0, -1, 0, 8)
		print("[pass] quote ok=%s code=%s rows=%d"
			% [str(q.get("ok", "?")), str(q.get("code", "-")),
				(q.get("quotes", []) as Array).size()])

		# `ok=true rows=0` means every gate passed but no family can afford THIS
		# cell. Hunt for a cell that returns rows: that is the difference between
		# "colonization is accepted" and "colonization is actionable".
		# ── WHY an arbitrary cell never has quotes ────────────────────────
		#
		# `family_colonization_quotes` runs a route search whose SOURCES must be
		# cells this country OWNS and can SEE (economy_runtime_colonization.cpp:552),
		# then expands outward through passable neighbours. A target picked at random
		# from a 6144-cell map is almost always unreachable inside that expansion
		# budget, so it returns `ok=true rows=0` -- every gate open, no quote.
		#
		# The first owned cell is 1553 while my earlier targets were 0 and 901, i.e.
		# hundreds of cells away. So the right experiment is a target ADJACENT to an
		# owned cell.
		var owned_cells: Array = []
		var oc := 0
		while oc < total_cells and owned_cells.size() < 24:
			var cs3: Dictionary = ext.get_country_cell_summary(oc)
			if bool(cs3.get("ok", false)) and bool(cs3.get("owned", false)):
				owned_cells.append(oc)
			oc += 1
		print("[pass] owned cells found: %d first=%s"
			% [owned_cells.size(), str(owned_cells.slice(0, 6))])
		var best_cell := -1
		var best_rows := 0
		var tried := 0
		for up in owned_cells:
			# Try the owned cell's neighbours (a colony is planted next door).
			for delta in [1, -1, 2, -2, 96, -96, 192, -192]:
				var cand := int(up) + int(delta)
				if cand < 0 or cand >= total_cells:
					continue
				tried += 1
				var qq: Dictionary = ext.get_family_colonization_quotes(
					handle, cand, 0, -1, 0, 8)
				if bool(qq.get("ok", false)):
					var n := (qq.get("quotes", []) as Array).size()
					if n > best_rows:
						best_rows = n
						best_cell = cand
		print("[pass] BEST adjacent quote cell=%d rows=%d after %d tries"
			% [best_cell, best_rows, tried])

		# ── THE LAST FILTER: branch population ────────────────────────────
		#
		# `economy_runtime_colonization.cpp:609`:
		#     if (branch_population <= 1) continue;
		# A family branch needs MORE THAN ONE person in the source cell to fund a
		# colony. A fresh world seeds one founder per family, so every branch is
		# exactly 1 and EVERY family is skipped -- which produces
		# `ok=true rows=0` on every cell, exactly as observed.
		#
		# Print the actual populations so this stops being an inference.
		for up2 in owned_cells.slice(0, 3):
			var fam: Dictionary = ext.get_family_cell_snapshot(int(up2), 0, 16) \
				if ext.has_method("get_family_cell_snapshot") else {}
			print("[pass] family at cell %d -> ok=%s families=%s"
				% [int(up2), str(fam.get("ok", "?")),
					str((fam.get("families", []) as Array).slice(0, 3))])
	else:
		print("[pass] NO passable cell on the map -- colonizing needs an epoch")

	host.queue_free()
	clock.queue_free()
	quit(0)
