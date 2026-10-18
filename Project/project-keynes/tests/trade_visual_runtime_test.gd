extends SceneTree

const Fixture = preload("res://tests/trade_visual_fixture.gd")
var failures := 0
var checks := 0

func _init() -> void:
	call_deferred("_run")

func expect(label: String, passed: bool) -> void:
	checks += 1
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed:
		failures += 1

func _run() -> void:
	for sea in [false, true]:
		var context: Dictionary = Fixture.make(4, sea)
		expect("fixture configures (%s)" % sea, bool(context.get("ok", false)))
		if not bool(context.get("ok", false)):
			print(context)
			continue
		var ext: Object = context.ext
		var interest := PackedInt32Array([0, 3])
		var blank: Dictionary = ext.get_trade_visual_snapshot(interest, PackedByteArray(), 0)
		expect("empty trade has no decorative traffic", bool(blank.get("ok", false)) and
			(blank.source_cells as PackedInt32Array).is_empty())
		var day: int = Fixture.find_trade(context)
		expect("real ACTIVE trade dispatches (%s)" % sea, day >= 0)
		if day < 0:
			print(ext.get_economy_report())
			continue
		var before: int = ext.get_economy_state_hash()
		var snapshot: Dictionary = ext.get_trade_visual_snapshot(interest, PackedByteArray(), 0)
		for slice in 12:
			if (snapshot.source_cells as PackedInt32Array).size() > 0:
				break
			snapshot = ext.get_trade_visual_snapshot(interest, PackedByteArray(), 0)
		expect("committed orders publish continuous visual paths", bool(snapshot.get("ok", false)) and
			(snapshot.source_cells as PackedInt32Array).size() > 0)
		expect("observer leaves the authoritative hash unchanged", before == ext.get_economy_state_hash())
		expect("fixed scan and path expansion budgets", int(snapshot.scanned_orders) <= 512 and
			int(snapshot.expanded_nodes) <= 256)
		expect("bounded immutable PackedArray schema", snapshot.snapshot_source == "committed_trade_visual"
			and snapshot.route_offsets is PackedInt32Array and snapshot.edge_modes is PackedByteArray
			and (snapshot.source_cells as PackedInt32Array).size() <= 32)
		if (snapshot.source_cells as PackedInt32Array).size() > 0:
			var cells: PackedInt32Array = snapshot.route_cells
			var continuous := true
			for i in range(1, cells.size()):
				continuous = continuous and absi(cells[i] - cells[i - 1]) == 1
			expect("path never draws a coast portal as a straight jump", continuous)
			var modes: PackedByteArray = snapshot.edge_modes
			expect("transport mode follows geography", modes.has(1) if sea else not modes.has(1))
		var masked: Dictionary = ext.get_trade_visual_snapshot(interest, PackedByteArray([1, 1, 1, 0]), 1)
		expect("new fog mask immediately removes hidden endpoints", (masked.source_cells as PackedInt32Array).is_empty())
		var disabled: Dictionary = ext.get_trade_visual_snapshot(interest, PackedByteArray(), 2, -1, false)
		expect("disabled observer returns no activities", (disabled.source_cells as PackedInt32Array).is_empty())
		# Changing topology invalidates completed paths without touching orders.
		var old_topology := int(snapshot.topology_hash)
		Fixture.capture(ext, 4, sea, true, 9)
		var blocked: Dictionary = ext.get_trade_visual_snapshot(interest, PackedByteArray(), 3)
		expect("topology changes discard stale paths", int(blocked.topology_hash) != old_topology and
			(blocked.source_cells as PackedInt32Array).is_empty())
		var state_before: int = ext.get_economy_state_hash()
		for slice in 10:
			ext.get_trade_visual_snapshot(interest, PackedByteArray(), 3)
		expect("unreachable visual work cannot mutate or fault economy", state_before == ext.get_economy_state_hash()
			and not bool(ext.get_economy_report().get("fatal", false)))
		_bake_checks(ext)
		ext.configure_economy(context.catalog, context.profile, 4, 77331)
		var reset_view: Dictionary = ext.get_trade_visual_snapshot(interest, PackedByteArray(), 4)
		expect("native context rebind clears the published view", not bool(reset_view.get("ok", true)))
	_hash_ab()
	_continuation_checks()
	var no_boats := Fixture.make(4, true, false)
	expect("no-water-technology fixture configures", bool(no_boats.get("ok", false)))
	if bool(no_boats.get("ok", false)):
		for day in 16: Fixture.advance(no_boats.ext, day)
		var restricted: Dictionary = no_boats.ext.get_trade_visual_snapshot(
			PackedInt32Array([0, 3]), PackedByteArray(), 0)
		expect("era appearance never grants navigation capability",
			(restricted.source_cells as PackedInt32Array).is_empty())
	print("=== trade visual native: %d checks, %d failures ===" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _bake_checks(ext: Object) -> void:
	var baked: Dictionary = ext.bake_trade_visual_paths({
		"route_offsets": PackedInt32Array([0, 2]), "route_cells": PackedInt32Array([7, 0]),
		"edge_modes": PackedByteArray([0, 0])}, 8, 22.0)
	expect("GPU path baker allocates fixed capacity", bool(baked.get("ok", false)) and
		(baked.path_bytes as PackedByteArray).size() == 1024 * 32 * 16)
	var lengths: PackedFloat32Array = baked.path_lengths
	expect("cylindrical seam uses the nearest adjacent image", is_equal_approx(lengths[0], sqrt(3.0) * 22.0))
	var invalid: Dictionary = ext.bake_trade_visual_paths({
		"route_offsets": PackedInt32Array([0, 5]), "route_cells": PackedInt32Array([0]),
		"edge_modes": PackedByteArray([0])}, 8, 22.0)
	expect("invalid path buffers fail closed", not bool(invalid.get("ok", true)))

func _hash_ab() -> void:
	var on := Fixture.make(4, false, true, true)
	var off := Fixture.make(4, false, true, true)
	if not bool(on.get("ok", false)) or not bool(off.get("ok", false)):
		expect("A/B fixtures configure", false)
		return
	var equal := true
	var conserved := true
	var money_exact := true
	for day in 24:
		Fixture.advance(on.ext, day)
		Fixture.advance(off.ext, day)
		on.ext.get_trade_visual_snapshot(PackedInt32Array([0, 3]), PackedByteArray(), 0)
		equal = equal and int(on.ext.get_economy_state_hash()) == int(off.ext.get_economy_state_hash())
		var report: Dictionary = on.ext.get_economy_report()
		if not bool(report.get("epoch_active", true)) and not bool(report.get("audit_incomplete", false)):
			if int(report.get("money_error", 0)) != 0 or int(report.get("goods_error", 0)) != 0:
				var baseline: Dictionary = off.ext.get_economy_report()
				print("[trade-ab-audit] ", {"day": day, "on_money": report.get("money_error"),
					"off_money": baseline.get("money_error"), "on_goods": report.get("goods_error"),
					"off_goods": baseline.get("goods_error"), "audit": report.get("audit_incomplete")})
			var baseline: Dictionary = off.ext.get_economy_report()
			conserved = conserved and int(report.get("money_error", 0)) == int(baseline.get("money_error", 0)) \
				and int(report.get("goods_error", 0)) == int(baseline.get("goods_error", 0))
			money_exact = money_exact and int(report.get("money_error", 0)) == 0
	expect("24-day visual on/off authoritative hashes match", equal)
	expect("visual on/off preserves the baseline conservation diagnostics", conserved)
	expect("visual on/off money audit remains exactly zero", money_exact)

func _continuation_checks() -> void:
	for count in [600, 1030]:
		var context := Fixture.make(count)
		var day: int = Fixture.find_trade(context) if bool(context.get("ok", false)) else -1
		expect("long route fixture dispatches (%d)" % count, day >= 0)
		if day < 0: continue
		var ext: Object = context.ext
		var interest := PackedInt32Array([0, count - 1])
		var before: int = ext.get_economy_state_hash()
		var snapshot: Dictionary = ext.get_trade_visual_snapshot(interest, PackedByteArray(), 0)
		expect("long search yields at the 256-pop budget", int(snapshot.expanded_nodes) <= 256
			and (snapshot.source_cells as PackedInt32Array).is_empty())
		var max_usec := int(snapshot.native_usec)
		for slice in 10:
			snapshot = ext.get_trade_visual_snapshot(interest, PackedByteArray(), 0)
			max_usec = maxi(max_usec, int(snapshot.native_usec))
			expect("continued slice stays bounded (%d/%d)" % [count, slice], int(snapshot.expanded_nodes) <= 256)
		var points: PackedInt32Array = snapshot.route_cells
		expect("bounded long path completes or over-cap path is omitted (%d)" % count,
			points.size() == 600 if count == 600 else points.is_empty())
		expect("continued path search remains non-authoritative", before == ext.get_economy_state_hash())
		expect("native visual memory remains below 64MiB", int(snapshot.memory_bytes) < 64 * 1024 * 1024)
		print("[trade-native-budget] ", {"cells": count, "max_native_usec": max_usec,
			"memory_bytes": snapshot.memory_bytes})
